import Combine
import SwiftUI

struct RootView: View {
    @State private var text: String = SharedStore.loadText()
    @FocusState private var isFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TextEditor(text: $text)
            .focused($isFocused)
            .ignoresSafeArea(.container, edges: .bottom)
            .onAppear {
                isFocused = true
            }
            .task {
                // Ensure the subscription exists and pull the authoritative value.
                await CloudTextStore.shared.start()
            }
            .onChange(of: text) { _, newValue in
                // Write the fast local cache immediately. Only a genuine change
                // schedules a debounced cloud save. A remote value has already
                // written the cache, so this reports no change and never echoes
                // back into another cloud write.
                if SharedStore.saveText(newValue) {
                    Task { await CloudTextStore.shared.scheduleSave(newValue) }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    // Silent pushes are best-effort, so re-pull on foreground to
                    // recover any change that never woke the app.
                    Task { await CloudTextStore.shared.fetchLatest() }
                case .background:
                    // The cache is already current from `onChange(of: text)`, so
                    // just flush the pending debounce to the cloud immediately.
                    Task { [text] in await CloudTextStore.shared.flushSave(text) }
                default:
                    break
                }
            }
            .onReceive(remoteTextChanges) { _ in
                // A remote value was applied to the cache off-screen. Mirror it
                // into the editor. The cache already matches, so the resulting
                // `onChange(of: text)` reports no change and schedules no save.
                text = SharedStore.loadText()
            }
    }

    /// `applyRemoteText(_:)` posts from the `CloudTextStore` actor's executor,
    /// so deliver on the main queue before mutating view state.
    private var remoteTextChanges: AnyPublisher<Notification, Never> {
        NotificationCenter.default
            .publisher(for: SharedStore.textDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}
