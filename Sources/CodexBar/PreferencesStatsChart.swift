import AppKit
import CodexBarCore

// MARK: - Multi-series time chart (port of AITokensMultiLineChart)

final class StatsMultiLineChart: NSView {
    struct Series {
        let name: String
        let color: NSColor
        let points: [StatsSample]
        let upcomingReset: Date?
        let windowMinutes: Int
        let windowName: String
        let providerId: String
    }

    private struct Projected {
        let point: CGPoint
        let value: Double
        let date: Date
        let name: String
        let color: NSColor
        let providerId: String
        let windowName: String
    }

    private struct ResetMarker {
        let x: CGFloat
        let date: Date
        let label: String
        let color: NSColor
        let providerId: String
        let windowName: String
    }

    private var series: [Series] = []
    /// Pre-sorted points and per-series reset timestamps, rebuilt in `setData` so `draw` stays cheap.
    private var preparedSeries: [(series: Series, points: [StatsSample], resetTimes: [TimeInterval])] = []
    private var now = Date()
    private var historicalResets: [StatsHistoricalReset] = []
    private let fixedYMax: Double?
    private let yFormatter: (Double) -> String
    private let axisFormatter = DateFormatter()
    private let markerFormatter = DateFormatter()
    private let tooltipFormatter = DateFormatter()

    private var highlightedSeriesKey: (providerId: String, windowName: String)?

    func setHighlightedSeries(providerId: String?, windowName: String?) {
        if let providerId, let windowName {
            self.highlightedSeriesKey = (providerId, windowName)
        } else {
            self.highlightedSeriesKey = nil
        }
        self.needsDisplay = true
    }

    // Viewport: the single source of truth (unix seconds).
    private var viewStart: TimeInterval = 0
    private var viewEnd: TimeInterval = 0
    private var targetViewStart: TimeInterval = 0
    private var targetViewEnd: TimeInterval = 0
    private var viewportInitialized = false
    private var prevContentMax: TimeInterval?

    private let minSpan: TimeInterval = 3600
    private let fiveHourSpan: TimeInterval = 18000

    private var isScrollingHorizontal = false
    var onZoomOrPan: ((StatsRange) -> Void)?

    private var displayLink: DisplayLinkDriver?
    private var lastFrameTime: CFTimeInterval = 0

    private var projected: [Projected] = []
    private var resetMarkers: [ResetMarker] = []
    private var hoverLocation: CGPoint?
    private var trackingArea: NSTrackingArea?

    init(fixedYMax: Double?, yFormatter: @escaping (Double) -> String) {
        self.fixedYMax = fixedYMax
        self.yFormatter = yFormatter
        super.init(frame: .zero)
        self.axisFormatter.dateFormat = "d MMM"
        self.markerFormatter.dateFormat = "d MMM"
        self.tooltipFormatter.dateFormat = "d MMM, HH:mm"
        self.wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window == nil { self.stopAnimating() }
    }

    // MARK: Content bounds & viewport clamping

    private func contentBounds() -> (min: TimeInterval, max: TimeInterval) {
        let dataTS = self.series.flatMap { $0.points.map(\.ts.timeIntervalSince1970) }
        let resetTS = self.series.compactMap { $0.upcomingReset?.timeIntervalSince1970 }
        let nowTS = self.now.timeIntervalSince1970
        let mn = dataTS.min() ?? (nowTS - self.fiveHourSpan)
        var mx = max(dataTS.max() ?? nowTS, nowTS)
        if let reset = resetTS.max() { mx = max(mx, reset) }
        if mx - mn < self.minSpan { mx = mn + self.minSpan }
        return (mn, mx)
    }

    private var maxSpan: TimeInterval {
        let (mn, mx) = self.contentBounds()
        return max(mx - mn, self.fiveHourSpan)
    }

    private func clampViewport(_ start: inout TimeInterval, _ end: inout TimeInterval) {
        let (cMin, cMax) = self.contentBounds()
        var span = end - start
        span = min(max(span, self.minSpan), self.maxSpan)
        let maxStart = cMax - span
        if maxStart <= cMin {
            start = cMax - span
        } else {
            start = min(max(start, cMin), maxStart)
        }
        end = start + span
    }

    // MARK: Data in

    func setData(
        series: [Series],
        now: Date,
        historicalResets: [StatsHistoricalReset],
        initialPreset: StatsRange)
    {
        self.series = series.filter { !$0.points.isEmpty }
        self.now = now
        self.historicalResets = historicalResets
        self.preparedSeries = self.series.map { series in
            let points = series.points.sorted { $0.ts < $1.ts }
            let hasUsage = points.contains { $0.value > 0.5 }
            var resetDates: [Date] = []
            if hasUsage {
                resetDates = self.historicalResets
                    .filter { $0.providerId == series.providerId && $0.windowName == series.windowName }
                    .map(\.date)
            }
            if let upcoming = series.upcomingReset {
                resetDates.append(upcoming)
            }
            let resetTimes = statsCoalescedResetDates(resetDates, windowMinutes: series.windowMinutes)
                .map(\.timeIntervalSince1970)
            return (series, points, resetTimes)
        }

        guard !self.series.isEmpty else {
            self.preparedSeries = []
            self.needsDisplay = true
            return
        }

        let (_, cMax) = self.contentBounds()
        if !self.viewportInitialized {
            self.applyPreset(initialPreset, animated: false)
            self.viewportInitialized = true
        } else if let prev = self.prevContentMax, self.targetViewEnd >= prev - 1 {
            let span = self.targetViewEnd - self.targetViewStart
            self.targetViewEnd = cMax
            self.targetViewStart = cMax - span
            self.viewStart = self.targetViewStart
            self.viewEnd = self.targetViewEnd
            self.clampViewport(&self.viewStart, &self.viewEnd)
            self.targetViewStart = self.viewStart
            self.targetViewEnd = self.viewEnd
        } else {
            self.clampViewport(&self.viewStart, &self.viewEnd)
            self.clampViewport(&self.targetViewStart, &self.targetViewEnd)
        }
        self.prevContentMax = cMax
        self.needsDisplay = true
    }

    func applyPreset(_ range: StatsRange, animated: Bool) {
        guard !self.series.isEmpty else { return }
        let nowTS = self.now.timeIntervalSince1970
        var start = nowTS - range.lookback
        var end = nowTS + range.lookforward
        // Extend the forward edge to reveal the soonest upcoming reset (e.g. Cursor's monthly reset),
        // as long as it is within reach of this preset (≤ 1.5× its lookback) so short views stay tight.
        let reach = nowTS + range.lookback * 1.5
        let upcoming = self.series
            .compactMap { $0.upcomingReset?.timeIntervalSince1970 }
            .filter { $0 > nowTS && $0 <= reach }
            .min()
        if let upcoming {
            end = max(end, upcoming + (upcoming - nowTS) * 0.05)
        }
        self.clampViewport(&start, &end)
        self.targetViewStart = start
        self.targetViewEnd = end
        if animated {
            self.ensureAnimating()
        } else {
            self.viewStart = start
            self.viewEnd = end
        }
        self.needsDisplay = true
    }

    // MARK: Animation (preset transitions only)

    private func ensureAnimating() {
        guard self.displayLink == nil else { return }
        self.lastFrameTime = CACurrentMediaTime()
        let driver = DisplayLinkDriver { [weak self] in self?.animationTick() }
        driver.start(fps: 60)
        self.displayLink = driver
    }

    private func stopAnimating() {
        self.displayLink?.stop()
        self.displayLink = nil
    }

    private func animationTick() {
        let time = CACurrentMediaTime()
        let dt = min(time - self.lastFrameTime, 1.0 / 30.0)
        self.lastFrameTime = time

        let lerp = 1.0 - pow(0.0009, dt)
        let dStart = self.targetViewStart - self.viewStart
        let dEnd = self.targetViewEnd - self.viewEnd
        let thresh = max(1.0, (self.targetViewEnd - self.targetViewStart) * 1e-5)

        if abs(dStart) > thresh || abs(dEnd) > thresh {
            self.viewStart += dStart * lerp
            self.viewEnd += dEnd * lerp
            self.needsDisplay = true
        } else if dStart != 0 || dEnd != 0 {
            self.viewStart = self.targetViewStart
            self.viewEnd = self.targetViewEnd
            self.needsDisplay = true
        } else {
            self.stopAnimating()
        }
    }

    // MARK: Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = self.trackingArea { self.removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: self.bounds,
            options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil)
        self.addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        self.hoverLocation = self.convert(event.locationInWindow, from: nil)
        self.needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) {
        self.hoverLocation = nil
        self.needsDisplay = true
    }

    // MARK: Pan (scroll)

    private func currentTimePerPixel() -> TimeInterval {
        let yAxisWidth: CGFloat = 34
        let chartWidth = max(1, self.bounds.width - yAxisWidth - 4)
        let span = max(self.viewEnd - self.viewStart, 1)
        return span / Double(chartWidth)
    }

    private func panBy(_ dxPoints: CGFloat) {
        let delta = TimeInterval(dxPoints) * self.currentTimePerPixel()
        self.viewStart -= delta
        self.viewEnd -= delta
        self.clampViewport(&self.viewStart, &self.viewEnd)
        self.targetViewStart = self.viewStart
        self.targetViewEnd = self.viewEnd
        self.needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard self.viewportInitialized else { super.scrollWheel(with: event); return }
        let hasPhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty

        if hasPhase {
            if event.phase == .began {
                self.isScrollingHorizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            }
            if self.isScrollingHorizontal {
                if event.scrollingDeltaX != 0 {
                    let dx = event.scrollingDeltaX
                    let absDx = abs(dx)
                    let threshold: CGFloat = 2.0
                    var multiplier: CGFloat = 1.0
                    if absDx > threshold {
                        multiplier = min(10.0, 1.0 + (absDx - threshold) * 0.25)
                    }
                    self.panBy(dx * multiplier)
                }
                if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
                    self.isScrollingHorizontal = false
                    self.notifyZoomOrPan()
                }
                return
            }
        } else {
            let dx = event.scrollingDeltaX
            if dx != 0 {
                self.panBy(dx * 10.0)
                self.notifyZoomOrPan()
                return
            }
        }

        super.scrollWheel(with: event)
    }

    // MARK: Zoom (pinch)

    override func magnify(with event: NSEvent) {
        guard self.viewportInitialized else { return }
        let loc = self.convert(event.locationInWindow, from: nil)
        let yAxisWidth: CGFloat = 34
        let chartMinX = yAxisWidth
        let chartWidth = max(1, self.bounds.width - yAxisWidth - 4)
        let pct = min(max(Double((loc.x - chartMinX) / chartWidth), 0.0), 1.0)

        let curSpan = max(self.viewEnd - self.viewStart, self.minSpan)
        let tMouse = self.viewStart + pct * curSpan

        let k = 1.0 / (1.0 + Double(event.magnification))
        var newSpan = curSpan * k
        newSpan = min(max(newSpan, self.minSpan), self.maxSpan)

        var newStart = tMouse - pct * newSpan
        var newEnd = newStart + newSpan
        self.clampViewport(&newStart, &newEnd)

        self.viewStart = newStart
        self.viewEnd = newEnd
        self.targetViewStart = newStart
        self.targetViewEnd = newEnd
        self.needsDisplay = true

        if event.phase == .ended || event.phase == .cancelled {
            self.notifyZoomOrPan()
        }
    }

    private func notifyZoomOrPan() {
        let currentSpan = self.viewEnd - self.viewStart
        var closest = StatsRange.day
        var minDiff = Double.greatestFiniteMagnitude
        for range in StatsRange.allCases {
            let rSpan = range.lookback + range.lookforward
            let diff = abs(currentSpan - rSpan)
            if diff < minDiff { minDiff = diff; closest = range }
        }
        self.onZoomOrPan?(closest)
    }

    private var darkMode: Bool {
        self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: Draw

    // swiftlint:disable:next function_body_length
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard NSGraphicsContext.current?.cgContext != nil else { return }
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)

        let textColor = self.darkMode ? NSColor.white : NSColor.textColor
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .light)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont, .foregroundColor: textColor.withAlphaComponent(0.5),
        ]

        guard !self.series.isEmpty else {
            let str = L("No history yet") as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .light),
                .foregroundColor: textColor.withAlphaComponent(0.5),
            ]
            let size = str.size(withAttributes: attrs)
            str.draw(
                at: CGPoint(x: (self.bounds.width - size.width) / 2, y: (self.bounds.height - size.height) / 2),
                withAttributes: attrs)
            return
        }

        let yAxisWidth: CGFloat = 34
        let xAxisHeight: CGFloat = 13
        let topMargin: CGFloat = 4
        let chartRect = NSRect(
            x: yAxisWidth,
            y: xAxisHeight,
            width: max(1, self.bounds.width - yAxisWidth - 4),
            height: max(1, self.bounds.height - xAxisHeight - topMargin - 2))

        let yMax = max(1, self.fixedYMax ?? (self.series.flatMap { $0.points.map(\.value) }.max() ?? 1))

        let nowTS = self.now.timeIntervalSince1970
        let tMin = self.viewStart
        let tMax = self.viewEnd
        let span = max(tMax - tMin, 1)

        if span <= 2 * 86400 {
            self.axisFormatter.dateFormat = "HH:mm"
            self.markerFormatter.dateFormat = "HH:mm"
        } else {
            self.axisFormatter.dateFormat = "d MMM"
            self.markerFormatter.dateFormat = "d MMM"
        }

        func xFor(_ ts: Double) -> CGFloat {
            chartRect.minX + CGFloat((ts - tMin) / span) * chartRect.width
        }
        func yFor(_ value: Double) -> CGFloat {
            chartRect.minY + CGFloat(min(max(value, 0), yMax) / yMax) * chartRect.height
        }

        let hairline = 1 / (NSScreen.main?.backingScaleFactor ?? 1)

        let gridColor = (self.darkMode ? NSColor.white : NSColor.black).withAlphaComponent(0.06)
        for step in [0, 25, 50, 75, 100] {
            let ly = chartRect.minY + CGFloat(step) / 100 * chartRect.height
            gridColor.setStroke()
            let grid = NSBezierPath()
            grid.move(to: CGPoint(x: chartRect.minX, y: ly))
            grid.line(to: CGPoint(x: chartRect.maxX, y: ly))
            grid.lineWidth = hairline
            grid.stroke()
            (self.yFormatter(yMax * Double(step) / 100) as NSString)
                .draw(at: CGPoint(x: 0, y: ly - 5), withAttributes: labelAttrs)
        }

        let tickCount = 4
        var lastLabelMaxX: CGFloat = -.greatestFiniteMagnitude
        for i in 0..<tickCount {
            let t = tMin + span * Double(i) / Double(tickCount - 1)
            let str = self.axisFormatter.string(from: Date(timeIntervalSince1970: t)) as NSString
            let size = str.size(withAttributes: labelAttrs)
            var lx = xFor(t) - size.width / 2
            lx = max(chartRect.minX, min(lx, self.bounds.width - size.width))
            guard lx > lastLabelMaxX + 6 else { continue }
            str.draw(at: CGPoint(x: lx, y: 0), withAttributes: labelAttrs)
            lastLabelMaxX = lx + size.width
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: chartRect).addClip()

        self.resetMarkers.removeAll()
        let nowX = min(max(xFor(nowTS), chartRect.minX), chartRect.maxX)

        let usageSeriesKeys = Set(
            self.preparedSeries
                .filter { $0.points.contains { $0.value > 0.5 } }
                .map { "\($0.series.providerId)\u{1f}\($0.series.windowName)" })
        for reset in self.historicalResets {
            guard usageSeriesKeys.contains("\(reset.providerId)\u{1f}\(reset.windowName)") else { continue }
            let ts = reset.date.timeIntervalSince1970
            guard ts >= tMin, ts <= tMax else { continue }
            let x = xFor(ts)
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: chartRect.minY))
            line.line(to: CGPoint(x: x, y: chartRect.maxY))
            line.lineWidth = hairline
            let isHighlighted = self.highlightedSeriesKey == nil
                || (self.highlightedSeriesKey?.providerId == reset.providerId
                    && self.highlightedSeriesKey?.windowName == reset.windowName)
            reset.color.withAlphaComponent(isHighlighted ? 0.35 : 0.05).setStroke()
            line.stroke()
            self.resetMarkers.append(ResetMarker(
                x: x,
                date: reset.date,
                label: "\(reset.name) · \(L("Past reset"))",
                color: reset.color,
                providerId: reset.providerId,
                windowName: reset.windowName))
        }

        var drawnResetMinutes = Set<Int>()
        for prepared in self.preparedSeries {
            let series = prepared.series
            guard let reset = series.upcomingReset else { continue }
            let ts = reset.timeIntervalSince1970
            guard ts >= tMin, ts <= tMax else { continue }
            let minuteKey = Int(ts / 60)
            guard drawnResetMinutes.insert(minuteKey).inserted else { continue }
            let x = xFor(ts)
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: chartRect.minY))
            line.line(to: CGPoint(x: x, y: chartRect.maxY))
            line.lineWidth = max(hairline, 1)
            let dash: [CGFloat] = series.windowMinutes >= 1440 ? [2, 9] : [1, 3]
            line.setLineDash(dash, count: 2, phase: 0)
            let isHighlighted = self.highlightedSeriesKey == nil
                || (self.highlightedSeriesKey?.providerId == series.providerId
                    && self.highlightedSeriesKey?.windowName == series.windowName)
            let opacity: CGFloat = isHighlighted ? 0.9 : 0.1
            series.color.withAlphaComponent(opacity).setStroke()
            line.stroke()
            if abs(x - nowX) >= 10 {
                self.drawVerticalLabel(
                    self.markerFormatter.string(from: reset),
                    atX: x,
                    chartRect: chartRect,
                    color: series.color.withAlphaComponent(opacity),
                    font: labelFont)
            }
            self.resetMarkers.append(ResetMarker(
                x: x,
                date: reset,
                label: "\(series.name) \(L("resets"))",
                color: series.color,
                providerId: series.providerId,
                windowName: series.windowName))
        }

        let nowLine = NSBezierPath()
        nowLine.move(to: CGPoint(x: nowX, y: chartRect.minY))
        nowLine.line(to: CGPoint(x: nowX, y: chartRect.maxY))
        nowLine.lineWidth = hairline
        nowLine.setLineDash([1, 2], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        nowLine.stroke()

        self.projected.removeAll(keepingCapacity: true)
        for prepared in self.preparedSeries {
            let series = prepared.series
            let pts = prepared.points
            let isHighlighted = self.highlightedSeriesKey == nil
                || (self.highlightedSeriesKey?.providerId == series.providerId
                    && self.highlightedSeriesKey?.windowName == series.windowName)
            let strokeColor = series.color.withAlphaComponent(isHighlighted ? 1.0 : 0.15)
            strokeColor.setStroke()
            strokeColor.setFill()
            for point in pts {
                self.projected.append(Projected(
                    point: CGPoint(x: xFor(point.ts.timeIntervalSince1970), y: yFor(point.value)),
                    value: point.value,
                    date: point.ts,
                    name: series.name,
                    color: series.color,
                    providerId: series.providerId,
                    windowName: series.windowName))
            }
            if pts.count == 1 {
                let p = CGPoint(x: xFor(pts[0].ts.timeIntervalSince1970), y: yFor(pts[0].value))
                NSBezierPath(ovalIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)).fill()
                continue
            }
            let resetTimes = prepared.resetTimes
            let yZero = yFor(0)

            let path = NSBezierPath()
            path.move(to: CGPoint(x: xFor(pts[0].ts.timeIntervalSince1970), y: yFor(pts[0].value)))
            if resetTimes.isEmpty {
                for i in 1..<pts.count {
                    let b = pts[i]
                    path.line(to: CGPoint(x: xFor(b.ts.timeIntervalSince1970), y: yFor(b.value)))
                }
            } else {
                for i in 1..<pts.count {
                    let a = pts[i - 1], b = pts[i]
                    let aTS = a.ts.timeIntervalSince1970, bTS = b.ts.timeIntervalSince1970
                    if let reset = resetTimes.first(where: { $0 > aTS && $0 < bTS }) {
                        let rx = xFor(reset)
                        path.line(to: CGPoint(x: rx, y: yFor(a.value)))
                        path.line(to: CGPoint(x: rx, y: yZero))
                        path.line(to: CGPoint(x: xFor(bTS), y: yFor(b.value)))
                    } else {
                        path.line(to: CGPoint(x: xFor(bTS), y: yFor(b.value)))
                    }
                }
            }
            let isSession = series.windowName.lowercased().contains("session") || series.windowMinutes < 1440
            path.lineWidth = isSession ? hairline : max(hairline, 1)
            path.lineJoinStyle = .round
            path.stroke()
        }

        NSGraphicsContext.restoreGraphicsState()

        self.drawHoverTooltip(chartRect: chartRect, textColor: textColor)
    }

    private func drawHoverTooltip(chartRect: NSRect, textColor: NSColor) {
        guard let loc = self.hoverLocation else { return }

        var nearestPoint: Projected?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for point in self.projected {
            if let highlighted = self.highlightedSeriesKey,
               point.providerId != highlighted.providerId || point.windowName != highlighted.windowName
            {
                continue
            }
            let dx = point.point.x - loc.x
            let dy = point.point.y - loc.y
            let dist = dx * dx * 2 + dy * dy
            if dist < bestDist { bestDist = dist; nearestPoint = point }
        }
        let pointDX = nearestPoint.map { abs($0.point.x - loc.x) } ?? .greatestFiniteMagnitude

        var nearestMarker: ResetMarker?
        var markerDX = CGFloat.greatestFiniteMagnitude
        for marker in self.resetMarkers {
            if let highlighted = self.highlightedSeriesKey,
               marker.providerId != highlighted.providerId || marker.windowName != highlighted.windowName
            {
                continue
            }
            let dx = abs(marker.x - loc.x)
            if dx < markerDX { markerDX = dx; nearestMarker = marker }
        }

        if let marker = nearestMarker, markerDX <= 4, markerDX < pointDX {
            let highlight = NSBezierPath()
            highlight.move(to: CGPoint(x: marker.x, y: chartRect.minY))
            highlight.line(to: CGPoint(x: marker.x, y: chartRect.maxY))
            highlight.lineWidth = 1
            marker.color.setStroke()
            highlight.stroke()
            let text = "\(marker.label) · \(statsAbsoluteDate(marker.date))"
            self.drawTooltipBox(text, anchorX: marker.x, anchorY: loc.y, textColor: textColor)
            return
        }

        guard let hit = nearestPoint, pointDX < 40 else { return }

        hit.color.setFill()
        NSBezierPath(ovalIn: CGRect(x: hit.point.x - 2.5, y: hit.point.y - 2.5, width: 5, height: 5)).fill()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let ring = NSBezierPath(ovalIn: CGRect(x: hit.point.x - 2.5, y: hit.point.y - 2.5, width: 5, height: 5))
        ring.lineWidth = 1
        ring.stroke()

        let text = "\(hit.name) · \(Int(hit.value.rounded()))% · \(self.tooltipFormatter.string(from: hit.date))"
        self.drawTooltipBox(text, anchorX: hit.point.x, anchorY: hit.point.y, textColor: textColor)
    }

    private func drawTooltipBox(_ text: String, anchorX: CGFloat, anchorY: CGFloat, textColor: NSColor) {
        let ns = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: textColor,
        ]
        let textSize = ns.size(withAttributes: attrs)
        let padding: CGFloat = 5
        let boxW = textSize.width + padding * 2
        let boxH = textSize.height + padding
        var boxX = anchorX + 8
        if boxX + boxW > self.bounds.width { boxX = anchorX - 8 - boxW }
        var boxY = anchorY + 8
        if boxY + boxH > self.bounds.height { boxY = anchorY - 8 - boxH }
        boxX = max(0, boxX)
        boxY = max(0, boxY)

        let box = NSBezierPath(
            roundedRect: NSRect(x: boxX, y: boxY, width: boxW, height: boxH), xRadius: 4, yRadius: 4)
        (self.darkMode ? NSColor.black : NSColor.white).withAlphaComponent(0.9).setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.lineWidth = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
        box.stroke()
        ns.draw(at: CGPoint(x: boxX + padding, y: boxY + padding / 2), withAttributes: attrs)
    }

    private func drawVerticalLabel(
        _ text: String, atX x: CGFloat, chartRect: NSRect, color: NSColor, font: NSFont)
    {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let nearRight = x > self.bounds.width - 14
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: x + (nearRight ? -3 : 4), yBy: chartRect.minY + 2)
        transform.rotate(byDegrees: 90)
        transform.concat()
        (text as NSString).draw(at: .zero, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}
