import AppKit
import SwiftUI

/// The state of one in-app Antigravity sign-in (`AntigravitySignIn`).
@MainActor @Observable
final class AntigravitySignInModel: Identifiable {
    enum Phase: Equatable {
        case starting
        /// The page is open in the browser; the code can be pasted.
        case waiting
        /// The code was typed to the CLI; Google is checking it.
        case checking
        case signedIn
        case failed(String)
    }

    let id = UUID()
    private(set) var phase: Phase = .starting
    private(set) var page: URL?
    /// When the CLI stops waiting for the code.
    private(set) var deadline: Date?
    var code = ""

    @ObservationIgnored private let binary: URL
    @ObservationIgnored private var session: AntigravitySignIn?
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private let signedIn: @MainActor () -> Void
    /// Counts starts and stops: an answer that comes back for an older one is dropped.
    @ObservationIgnored private var run = 0

    init(binary: URL, signedIn: @escaping @MainActor () -> Void) {
        self.binary = binary
        self.signedIn = signedIn
    }

    var canSubmit: Bool {
        phase == .waiting && !AntigravitySignIn.codeLine(code).isEmpty
    }

    /// Starts the CLI's sign-in, which opens the Google page in the browser.
    /// The store starts it when it shows the sheet, and Start Again does.
    func start() {
        stop()
        phase = .starting
        page = nil
        code = ""
        do {
            let session = try AntigravitySignIn(binary: binary)
            self.session = session
            deadline = Date().addingTimeInterval(AntigravitySignIn.wait)
            listening = Task { [weak self] in
                for await event in session.events {
                    guard !Task.isCancelled else { return }
                    await self?.handle(event, from: session)
                }
            }
        } catch {
            fail("The Antigravity CLI could not be started (\(error.localizedDescription)).")
        }
    }

    func submit() {
        guard canSubmit, let session else { return }
        phase = .checking
        session.submit(code: code)
    }

    /// Ends the CLI if it is still waiting, and whatever of this run is
    /// still being worked out. The store calls it when the sheet goes.
    func stop() {
        run += 1
        listening?.cancel()
        listening = nil
        session?.cancel()
        session = nil
        deadline = nil
    }

    private func handle(_ event: AntigravitySignIn.Event, from session: AntigravitySignIn) async {
        guard session === self.session else { return }
        switch event {
        case .page(let url):
            page = url
            if phase == .starting { phase = .waiting }
        case .finished(let outcome):
            deadline = nil
            switch outcome {
            case .timedOut:
                self.session = nil
                fail("The sign-in page was open for a minute without a code. Start again and paste the code within a minute.")
            case .failed(let message):
                self.session = nil
                fail(message)
            case .signedIn, .unclear:
                // The CLI's exit alone does not prove it: ask it.
                phase = .checking
                let run = run
                let state = await Self.status(of: binary)
                // Closed or started again meanwhile: this answer is nobody's.
                guard run == self.run, !Task.isCancelled else { return }
                self.session = nil
                switch (outcome, state) {
                case (_, .signedIn), (.signedIn, .unknown):
                    phase = .signedIn
                    signedIn()
                case (.unclear(let message), _):
                    fail("The sign-in could not be confirmed. \(message)")
                default:
                    fail("The sign-in did not complete. Start again.")
                }
            }
        }
    }

    /// The CLI's own answer, or `.unknown` when it has not come in half a
    /// minute: the sheet must never wait on it for good.
    private nonisolated static func status(of binary: URL) async -> ProviderAuth.State {
        let answer = Answer()
        return await withCheckedContinuation { continuation in
            Task.detached {
                let state = await ProviderAuth.status(provider: "antigravity", binary: binary)
                answer.give(state, to: continuation)
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(30))
                answer.give(.unknown, to: continuation)
            }
        }
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var given = false
        func give(_ state: ProviderAuth.State, to continuation: CheckedContinuation<ProviderAuth.State, Never>) {
            let first = lock.withLock { () -> Bool in
                defer { given = true }
                return !given
            }
            if first { continuation.resume(returning: state) }
        }
    }

    private func fail(_ message: String) {
        ErrorLog.record("Antigravity sign-in", message)
        phase = .failed(message)
    }
}

/// Sign in to the Antigravity CLI without a Terminal: the CLI opens the
/// Google page, the page shows a code, and the code is pasted here.
struct AntigravitySignInSheet: View {
    @Bindable var model: AntigravitySignInModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Sign in to Antigravity").font(.headline)
            Text("The Google sign-in page has opened in your browser. Sign in there; the last page shows a code. Copy it and paste it here.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.spaceS) {
                TextField("Code from the sign-in page", text: $model.code)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($codeFocused)
                    .disabled(model.phase != .waiting)
                    .onSubmit { model.submit() }
                Button("Paste") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        model.code = AntigravitySignIn.codeLine(text)
                    }
                }
                .disabled(model.phase != .waiting)
                .help("Paste the code you copied on the sign-in page")
            }
            status
            HStack(spacing: Theme.spaceS) {
                if let page = model.page, model.phase == .waiting {
                    Button("Open the Page Again") { NSWorkspace.shared.open(page) }
                        .help("Opens the same Google sign-in page in your browser")
                }
                Spacer()
                Button(model.phase == .signedIn ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if case .failed = model.phase {
                    Button("Start Again") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .help("Opens a new sign-in page; the old code no longer works")
                } else if model.phase != .signedIn {
                    Button("Sign In") { model.submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canSubmit)
                }
            }
        }
        .padding(Theme.spaceL)
        .frame(width: 460)
        // The store starts and stops the sign-in, not this view: a second
        // window showing the same sheet must not restart or end it.
        .onAppear { codeFocused = true }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .starting:
            line { ProgressView().controlSize(.small) } text: { Text("Opening the sign-in page…") }
        case .waiting:
            if let deadline = model.deadline {
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                    Text("The CLI waits \(left) s more for the code.")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
        case .checking:
            line { ProgressView().controlSize(.small) } text: { Text("Checking the code with Google…") }
        case .signedIn:
            line { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } text: { Text("Signed in.") }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(@ViewBuilder icon: () -> some View, @ViewBuilder text: () -> some View) -> some View {
        HStack(spacing: Theme.spaceS) {
            icon()
            text().font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
