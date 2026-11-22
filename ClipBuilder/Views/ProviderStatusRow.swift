import Combine
import SwiftUI

struct ProviderStatusRow: View {
    @Environment(AppStore.self) private var store
    @State private var model = ProviderStatusModel()
    /// Inline in the status bar: no leading-aligned fill or bottom padding.
    var compact = false
    /// Providers the AI service is skipping, with the reason.
    @State private var problems: [String: String] = [:]
    @State private var showingList = false

    private var binaries: [String: String] {
        Dictionary(uniqueKeysWithValues: AICatalog.providers.map { provider in
            let configured = store.settings.ai.providers[provider.key]?.bin
            let binary = configured.flatMap { $0.isEmpty ? nil : $0 } ?? provider.bin
            return (provider.key, binary)
        })
    }

    private var health: ProviderHealth { ProviderHealth(items: model.items, problems: problems) }

    var body: some View {
        // One stop light for every signed-in provider; the list is a click away.
        Button { showingList = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(Self.color(health.light))
                    .frame(width: 8, height: 8)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(health.tooltip + "\nClick for the list")
        .accessibilityLabel("AI providers: \(health.summary)")
        .popover(isPresented: $showingList, arrowEdge: .top) { list }
        .font(.caption)
        .controlSize(.mini)
        .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 0 : Theme.spaceM)
        .padding(.bottom, compact || model.items.isEmpty ? 0 : Theme.spaceS)
        .task(id: binaries) {
            await model.refresh(binaries: binaries, force: true)
            problems = await store.ai.providerProblems()
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            Task {
                await model.refresh(binaries: binaries)
                problems = await store.ai.providerProblems()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh(binaries: binaries, force: true) }
        }
    }

    static func color(_ light: ProviderHealth.Light) -> Color {
        switch light {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        case .off: .gray
        }
    }

    /// Every installed provider: working, failing and why, or how to sign in.
    private var list: some View {
        let health = health
        return VStack(alignment: .leading, spacing: Theme.spaceS) {
            Text(health.summary).font(.headline)
            ForEach(health.counted) { entry in
                HStack(alignment: .firstTextBaseline, spacing: Theme.spaceS) {
                    Circle().fill(entry.problem == nil ? Color.green : Color.red).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.label).lineLimit(1)
                        if let problem = entry.problem {
                            Text(problem).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !health.ignored.isEmpty {
                Divider()
                Text("Not counted").font(.caption).foregroundStyle(.secondary)
                ForEach(health.ignored) { item in
                    HStack(spacing: Theme.spaceS) {
                        Circle().fill(Color.gray).frame(width: 7, height: 7)
                        Text("\(item.label): \(item.statusLabel)").lineLimit(1)
                        Spacer(minLength: Theme.spaceM)
                        Button("Sign In…") {
                            showingList = false
                            store.openProviderSignIn(item.id)
                            model.didOpenSignIn()
                            Task { await model.refresh(binaries: binaries) }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .font(.callout)
        .padding(Theme.spaceM)
        .frame(width: 320, alignment: .leading)
    }
}
