import SwiftUI
import Vision

/// Avatar picker: every face found across frames where this person appears,
/// offered as candidate circles — click the right one and it becomes the
/// person's avatar everywhere. Fixes the auto-crop grabbing the opponent's
/// face when two fighters share the frame.
struct AvatarPickerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let person: PersonRecord

    struct Candidate: Identifiable {
        let id = UUID()
        var image: NSImage
        var videoID: Int64
        var time: Double
        /// Normalized face box, top-left origin — stored with the pick so
        /// the avatar re-crops deterministically.
        var box: VideoPersonRecord.PortraitBox
    }

    /// Frames sampled across the person's videos and scenes.
    private static let maxFrames = 8
    /// Faces offered per frame (largest first).
    private static let maxFacesPerFrame = 4

    @State private var candidates: [Candidate] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Avatar — \(person.displayName)")
                .font(.title3.bold())
            Text("Every face found in frames where \(person.displayName) appears. Click the right one — it becomes their avatar everywhere. Reset returns to the automatic pick.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning frames for faces…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if candidates.isEmpty {
                ContentUnavailableView("No faces found",
                                       systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("No clear faces in this person's frames. Draw a person marker in the analyze plan's People tab instead — markers are ground truth for the avatar too."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12)],
                              spacing: 12) {
                        ForEach(candidates) { candidate in
                            Button {
                                store.setPersonAvatar(person, videoID: candidate.videoID,
                                                      time: candidate.time, box: candidate.box)
                                dismiss()
                            } label: {
                                Color.clear
                                    .overlay {
                                        Image(nsImage: candidate.image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    }
                                    .frame(width: 76, height: 76)
                                    .clipShape(Circle())
                                    .overlay { Circle().strokeBorder(.quaternary) }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use face at \(candidate.time.timecode) as \(person.displayName)’s avatar")
                            .help("Use this face as the avatar")
                        }
                    }
                    .padding(2)
                }
            }

            HStack {
                Button("Reset to Automatic") {
                    store.setPersonAvatar(person, videoID: nil, time: nil, box: nil)
                    dismiss()
                }
                .help("Back to the automatic pick: a drawn marker's portrait, else the first scene's face")
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 340, idealHeight: 420)
        .modalCloseButton { dismiss() }
        .task { await loadCandidates() }
    }

    /// Frames worth scanning: the AI's per-video portrait moment first, then
    /// scene midpoints — spread across distinct videos so one long fight
    /// doesn't crowd out the rest.
    private func loadCandidates() async {
        let personScenes = store.scenes.filter { !$0.ignored && $0.tags.contains(person.tag) }
        var frames: [(videoID: Int64, url: URL, time: Double)] = []
        var perVideo: [Int64: Int] = [:]
        for video in store.videos where personScenes.contains(where: { $0.videoID == video.id }) {
            let roster = await store.videoPeople(for: video.id)
            if let entry = roster.first(where: { $0.personID == person.id }) {
                frames.append((video.id, video.url, entry.portraitAt))
                perVideo[video.id, default: 0] += 1
            }
        }
        for scene in personScenes {
            guard frames.count < Self.maxFrames, perVideo[scene.videoID, default: 0] < 2 else { continue }
            frames.append((scene.videoID, scene.videoURL, (scene.startTime + scene.endTime) / 2))
            perVideo[scene.videoID, default: 0] += 1
        }

        var found: [Candidate] = []
        for frame in frames.prefix(Self.maxFrames) {
            guard let jpeg = await ThumbnailService.jpegFrame(url: frame.url, at: frame.time,
                                                              maxDimension: 720) else { continue }
            for faceBox in await PersonFaceAvatar.detectFaces(in: jpeg).prefix(Self.maxFacesPerFrame) {
                guard let image = PersonFaceAvatar.avatarImage(from: jpeg, faceBox: faceBox) else { continue }
                found.append(Candidate(image: image,
                                       videoID: frame.videoID,
                                       time: frame.time,
                                       // Vision's bottom-left origin → stored top-left.
                                       box: VideoPersonRecord.PortraitBox(
                                           x: faceBox.minX, y: 1 - faceBox.maxY,
                                           w: faceBox.width, h: faceBox.height)))
            }
        }
        candidates = found
        isLoading = false
    }
}
