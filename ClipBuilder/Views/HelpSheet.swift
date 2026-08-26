import SwiftUI
import WebKit

/// In-app training guide: renders the bundled TrainingGuide.html in a sheet,
/// so users can learn the review → distill → generate loop without leaving
/// the wizard.
struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var page = WebPage()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Training Guide")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            WebView(page)
        }
        .frame(width: 680, height: 760)
        .modalCloseButton { dismiss() }
        .task {
            // Load the file URL (not an HTML string) so the guide's bundled
            // screenshots resolve as sibling resources.
            guard let url = Bundle.main.url(forResource: "TrainingGuide", withExtension: "html") else { return }
            page.load(URLRequest(url: url))
        }
    }
}
