import SwiftUI
import UIKit

struct RootView: View {
    @State private var text: String = SharedStore.loadText()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TextEditorView(text: $text)
            .ignoresSafeArea(.container, edges: .bottom)
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

struct TextEditorView: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.alwaysBounceVertical = true
        textView.autocapitalizationType = .sentences
        textView.smartQuotesType = .yes
        textView.smartDashesType = .yes
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.backgroundColor = .systemBackground
        textView.text = text
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            SharedStore.saveText(textView.text)
        }
    }
}
