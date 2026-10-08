# Claude subscription metadata verification

Subscription dates use the existing provider fetch and shared menu/Settings subscription row. The app and CLI
receive the same snapshot fields. Billing no longer has an app-only worker or a second publication path.

`ClaudeSubscriptionCLITests` drives the production Web and OAuth strategies with synthetic HTTP and quota fixtures.
OAuth uses the normal environment-credential route, including when no accepted memory-cache record exists.
The billing requests verify the selected cookie's account and organization before and after fetching dates.
OAuth additionally verifies its profile before and after billing, using the token accepted for that quota fetch.
The profile and browser-account checks bypass response caches.

The cases cover renewal, cancellation, empty and malformed payloads, unavailable billing permissions, a browser
account change, and OAuth organization reassignment while both browser memberships remain present. Rejected billing
metadata preserves the successful quota. Cookie source Off performs no billing or profile requests. A controlled
zero-budget test exercises optional timeout without a wall-clock assertion.

Billing is bounded to two seconds in total after quota succeeds. Its result returns through normal provider
publication, which retains the existing selected-account, credential, configuration and refresh-generation checks.
There is no independent task that can overwrite a newer published snapshot, saved-account cache or widget.

`ClaudeSubscriptionMetadataTests` covers timestamp/calendar precision, ending-date precedence, strict malformed
input handling, authoritative empty metadata, JSON compatibility and value-preserving snapshot replacement.
`ClaudeSubscriptionPresentationTests` covers missing-date rows for Pro/Max/Team/Enterprise labels, date-only display,
and optional headless renders of the production card using synthetic data.

Run the focused suites with the repository's scrubbed test environment:

```sh
source Scripts/test_environment.sh
swift test --build-system native --jobs 4 -Xswiftc -gnone --filter ClaudeSubscription
```

All fixtures are synthetic. These tests establish behavior for the reported billing response schema, not endpoint
availability for every plan or organization role. The contributor reported live renewal proof; a live cancelled
subscription and Team/Enterprise billing access have not been independently verified in this lane. No real provider
account, credential store, browser session or running app is used by this proof.
