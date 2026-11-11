import SwiftUI

struct TrophiesView: View {
    @EnvironmentObject var controller: CoreController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @State private var snapshot = TrophySnapshot()
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        TrophyCollectionList(snapshot: snapshot)
            .navigationTitle("trophy.title").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                if let collection = snapshot.collections.first(where: { $0.id == id }) {
                    TrophyDetailView(collection: collection).refreshable { await reload() }
                }
            }
            .overlay {
                if loading && snapshot.collections.isEmpty { ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
            }
            .safeAreaInset(edge: .top) {
                if let error { Text(error).font(.subheadline).foregroundStyle(.orange).padding().frame(maxWidth: .infinity).background(EmulatorTheme.panel) }
            }
            .toolbar {
                Button { Task { await reload() } } label: { Label("trophy.refresh", systemImage: "arrow.clockwise") }
                    .disabled(loading || controller.isGamePresented)
            }
            .refreshable { await reload() }
            .task(id: "\(controller.sessionInitialized)-\(controller.isGamePresented)-\(locale.identifier)") {
                await reload()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await reload() } }
            }
    }

    @MainActor private func reload() async {
        guard controller.sessionInitialized, !controller.isGamePresented, !loading else { return }
        loading = true
        defer { loading = false }
        let language = AppLanguage(rawValue: locale.identifier) ?? .saved()
        // Dismissing the game can precede native teardown by a short time.
        // Let it finish before showing an error; never read progress mid-write.
        for attempt in 0..<6 {
            guard !Task.isCancelled, !controller.isGamePresented else { return }
            do {
                let result = try await Task.detached(priority: .utility) {
                    try Vita3KCore.trophySnapshot(language: language)
                }.value
                guard !Task.isCancelled else { return }
                snapshot = result
                error = nil
                return
            } catch TrophyReadError.unavailable(let code) {
                if code == -3 && attempt < 5 {
                    try? await Task.sleep(for: .milliseconds(400))
                    continue
                }
                self.error = L10n.text(code == -3 ? "trophy.busy" : "trophy.readWarning")
                return
            } catch {
                self.error = L10n.text("trophy.readWarning")
                return
            }
        }
    }
}
