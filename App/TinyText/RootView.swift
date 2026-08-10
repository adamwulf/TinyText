import Combine
import SwiftUI
import UIKit

struct RootView: View {
    @State private var text: String = SharedStore.loadText()
    @FocusState private var isFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    // Stored per view instance so `body` does not rebuild it on every render.
    // `applyRemoteText(_:)` posts from the CloudTextStore actor's executor, so
    // deliver on the main queue before mutating view state.
    private let remoteTextChanges = NotificationCenter.default
        .publisher(for: SharedStore.textDidChangeNotification)
        .receive(on: DispatchQueue.main)

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
                    Task { await CloudTextStore.shared.scheduleSave() }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    // Silent pushes are best-effort, so re-pull on foreground to
                    // recover any change that never woke the app.
                    Task { await CloudTextStore.shared.fetchLatest() }
                case .background:
                    // Flush the pending debounce so the latest cache reaches the
                    // cloud immediately, under a background assertion so the write
                    // has time to finish; the save reads the cache at execution time.
                    BackgroundFlush.start()
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
}

/// Runs the scene-background flush inside a UIKit background-task assertion so the
/// immediate cloud write has time to finish before the app is suspended. Begins and
/// ends the assertion on the main actor, ends it exactly once (on completion or
/// expiration), and cancels the flush on expiration. The durable dirty marker
/// remains the recovery fallback if the reserved time runs out.
@MainActor
private final class BackgroundFlush {
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var work: Task<Void, Never>?
    private var ended = false

    static func start() {
        BackgroundFlush().begin()
    }

    private func begin() {
        // Reserve time first so the assertion exists before the flush can finish.
        taskID = UIApplication.shared.beginBackgroundTask(withName: "TinyText.flush") { [weak self] in
            self?.expire()
        }
        // The work task holds self strongly for the run; `end()` drops that
        // reference so the transient cycle never outlives the flush.
        work = Task { [self] in
            await CloudTextStore.shared.flushSave()
            end()
        }
    }

    private func expire() {
        work?.cancel()
        end()
    }

    private func end() {
        guard !ended else { return }
        ended = true
        work = nil
        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
    }
}
