import AppKit
import SwiftUI

/// Telemetry configuration page. Reached from the About pane in Settings.
///
/// Kept in its own file (and its own window) so the feature is easy to carry across
/// upstream merges. Strings are inline English rather than `L(...)` keys to avoid
/// touching the shared Localizable.strings catalogs.
@MainActor
struct TelemetrySettingsView: View {
    private let service = TelemetryService.shared

    @AppStorage(TelemetryConstants.DefaultsKey.enabled) private var enabled = false
    @AppStorage(TelemetryConstants.DefaultsKey.serverURL) private var serverURL = TelemetryConstants.defaultServerURL

    @State private var token = ""
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case sending
        case success(String)
        case failure(String)
    }

    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Telemetry")
                    .font(.title2).bold()
                Text("Report anonymous usage metrics to your self-hosted telemetry server.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Toggle("Enable telemetry", isOn: self.$enabled)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                Text("Server URL")
                    .font(.subheadline).bold()
                TextField(TelemetryConstants.defaultServerURL, text: self.$serverURL)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .disabled(!self.enabled)
                Text("Telemetry is posted to \(self.serverURLDisplay)\(TelemetryConstants.ingestPath).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Auth token")
                    .font(.subheadline).bold()
                SecureField("tlm_…", text: self.$token)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!self.enabled)
                    .onChange(of: self.token) { _, newValue in
                        self.service.storeToken(newValue)
                    }
                Text("Sent as the HTTP Bearer token. Stored securely in your login keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Send latest usage now") {
                    self.sendNow()
                }
                .disabled(!self.enabled || self.testState == .sending)

                self.testStatusView
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Done") { self.onClose?() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 420)
        .onAppear {
            self.token = self.service.loadToken() ?? ""
        }
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch self.testState {
        case .idle:
            EmptyView()
        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Sending…").font(.footnote).foregroundStyle(.secondary)
            }
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case let .failure(message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private var serverURLDisplay: String {
        let trimmed = self.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? TelemetryConstants.defaultServerURL : trimmed
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    private func sendNow() {
        self.testState = .sending
        Task {
            do {
                let count = try await self.service.sendLatestUsage()
                self.testState = count == 0
                    ? .success("No usage history to send yet")
                    : .success("Sent \(count) usage record\(count == 1 ? "" : "s")")
            } catch {
                self.testState = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - About link

/// A row styled like `AboutLinkRow` but triggering an in-app action instead of opening a URL.
@MainActor
struct AboutActionRow: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 8) {
                Image(systemName: self.icon)
                Text(self.title)
                    .underline(self.hovering, color: .accentColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { self.hovering = $0 }
    }
}

// MARK: - Standalone window

/// Opens the telemetry configuration page in its own window. Linked from `AboutPane`.
@MainActor
enum TelemetrySettingsWindow {
    private static var controller: NSWindowController?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)

        if let existing = self.controller, let window = existing.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Telemetry"
        window.isReleasedWhenClosed = false
        window.center()

        let view = TelemetrySettingsView(onClose: { self.controller?.close() })
        window.contentView = NSHostingView(rootView: view)

        let controller = NSWindowController(window: window)
        self.controller = controller
        controller.showWindow(nil)
    }
}
