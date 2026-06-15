import SwiftUI

struct RootView: View {
    @State private var text: String = SharedStore.loadText()
    @FocusState private var isFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private let externalChange = NotificationCenter.default.publisher(
        for: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
        object: NSUbiquitousKeyValueStore.default
    )

    var body: some View {
        TextEditor(text: $text)
            .focused($isFocused)
            .ignoresSafeArea(.container, edges: .bottom)
            .onAppear {
                SharedStore.start()
                let synced = SharedStore.loadText()
                if synced != text { text = synced }
                isFocused = true
            }
            .onChange(of: text) { _, newValue in
                SharedStore.saveText(newValue)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    SharedStore.saveText(text)
                }
            }
            .onReceive(externalChange) { note in
                if let newValue = SharedStore.applyExternalChange(note), newValue != text {
                    text = newValue
                }
            }
    }
}
