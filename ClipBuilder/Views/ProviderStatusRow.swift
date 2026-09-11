import Combine
import SwiftUI

struct ProviderStatusRow: View {
    @Environment(AppStore.self) private var store
    @State private var model = ProviderStatusModel()

    private var binaries: [String: String] {
        Dictionary(uniqueKeysWithValues: AICatalog.providers.map { provider in
            let configured = store.settings.ai.providers[provider.key]?.bin
            let binary = configured.flatMap { $0.isEmpty ? nil : $0 } ?? provider.bin
            return (provider.key, binary)
        })
    }

    var body: some View {
        HStack(spacing: model.items.count > 5 ? Theme.spaceXS : Theme.spaceS) {
            ForEach(model.items) { item in
                if item.canSignIn {
                    Button {
                        store.openProviderSignIn(item.id)
                        model.didOpenSignIn()
                        Task { await model.refresh(binaries: binaries) }
                    } label: {
                        indicator(item)
                    }
                    .buttonStyle(.plain)
                    .help(item.accessibilityLabel)
                    .accessibilityLabel(item.accessibilityLabel)
                } else {
                    indicator(item)
                        .help(item.accessibilityLabel)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.accessibilityLabel)
                }
            }
        }
        .font(.caption)
        .controlSize(.mini)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.spaceM)
        .padding(.bottom, model.items.isEmpty ? 0 : Theme.spaceS)
        .task(id: binaries) {
            await model.refresh(binaries: binaries, force: true)
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            Task { await model.refresh(binaries: binaries) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh(binaries: binaries, force: true) }
        }
    }

    private func indicator(_ item: ProviderStatusItem) -> some View {
        HStack(spacing: 3) {
            Image(systemName: item.symbol)
                .foregroundStyle(.secondary)
            Circle()
                .fill(item.color)
                .frame(width: 6, height: 6)
        }
        .contentShape(.rect)
    }
}
