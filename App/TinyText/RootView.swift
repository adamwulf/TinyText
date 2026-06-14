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
            .onChange(of: text) { _, newValue in
                SharedStore.saveText(newValue)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    SharedStore.saveText(text)
                }
            }
    }
}
