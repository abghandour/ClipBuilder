import BugReporterKit
import SwiftUI

struct QAToolbarMenu: View {
    var body: some View {
        Menu {
            Button("Report a Bug…") { BugReporting.presentReport() }
            Button("Take Screenshot") { BugReporting.takeScreenshot() }
            Button("My Reports…") { MyReportsWindowPresenter.show() }
        } label: {
            // The VerticalCorn mark, cropped to a circle exactly like the kit's
            // iOS floating button (scaled past the circle so the rounded-square
            // canvas falls away). Falls back to the ladybug if the resource is missing.
            Group {
                if let logo = QAButtonLogo.image {
                    logo
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 22 * 1.16, height: 22 * 1.16)
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "ladybug.fill")
                }
            }
                .accessibilityLabel("Bug reporting")
                .overlay(alignment: .topTrailing) {
                    if ScreenshotStore.shared.count > 0 {
                        Text(ScreenshotStore.shared.count, format: .number)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(.red, in: Capsule())
                            .offset(x: 8, y: -6)
                    }
                }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Bug reporting, \(ScreenshotStore.shared.count) screenshots")
        .help("Report a bug, take a screenshot, or view your reports")
    }
}
