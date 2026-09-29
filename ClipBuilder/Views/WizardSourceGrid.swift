import SwiftUI

/// The Wizard's footage picker: one thumbnail per video in a grid. Hovering
/// a thumbnail skims the video (a frame every 10 s), clicking toggles it, and
/// the grid collapses to a one-line list of the selected names.
struct WizardSourceGrid: View {
    let videos: [VideoRecord]
    let selectedPaths: Set<String>
    @Binding var isExpanded: Bool
    /// One line under the name: duration, exchange count, batch count.
    var subtitle: (VideoRecord) -> String? = { _ in nil }
    let onToggle: (VideoRecord) -> Void

    private var selectedNames: [String] {
        videos.filter { selectedPaths.contains($0.path) }.map(\.filename)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(isExpanded ? "Footage" : Self.collapsedTitle(selectedNames))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(selectedNames.isEmpty ? "None selected"
                         : selectedNames.count == 1 ? "1 selected" : "\(selectedNames.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide the thumbnails" : "Show the thumbnails")
            .accessibilityLabel(isExpanded ? "Hide footage" : "Show footage")

            if isExpanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 12, alignment: .top)],
                          spacing: 12) {
                    ForEach(videos) { video in
                        cell(video)
                    }
                }
            }
        }
    }

    /// "Podcast 01.mp4, Modestino Podcast 02.mp4" for the collapsed row.
    static func collapsedTitle(_ names: [String]) -> String {
        names.isEmpty ? "No footage selected" : names.joined(separator: ", ")
    }

    private func cell(_ video: VideoRecord) -> some View {
        let selected = selectedPaths.contains(video.path)
        return Button {
            onToggle(video)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HoverScrubThumbnail(url: video.url, duration: video.duration)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 3)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.body)
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(5)
                        }
                    }
                Text(video.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let line = subtitle(video) {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(video.filename)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(selected ? "Click to deselect" : "Click to select")
        .help(selected ? "Click to deselect" : "Click to select · hover to skim the video")
    }
}

/// A poster frame that, while the pointer rests on it, steps through the
/// video 10 seconds at a time so the user can tell what it is about.
struct HoverScrubThumbnail: View {
    let url: URL
    let duration: Double
    static let step: Double = 10
    static let dwell: Duration = .milliseconds(700)

    @State private var hovering = false
    @State private var time: Double = 1

    var body: some View {
        VideoThumbnail(url: url, time: time, cornerRadius: 6)
            .overlay(alignment: .bottomLeading) {
                if hovering {
                    Text(time.timecode)
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .onHover { hovering = $0 }
            .task(id: hovering) {
                guard hovering, duration > Self.step else { return }
                // Sleep throws on cancellation, so a pointer leaving stops the
                // loop instead of letting it overwrite a later state.
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.dwell)
                    guard !Task.isCancelled else { break }
                    time = Self.next(after: time, duration: duration)
                }
                time = 1
            }
    }

    /// The next skim position: 10 s on, wrapping before the end.
    static func next(after time: Double, duration: Double) -> Double {
        let candidate = time + step
        return candidate >= duration - 1 ? 1 : candidate
    }
}
