import SwiftUI

/// A compact preview of the actual eligible pool, without loading new media.
struct WizardSourceEvidence: View {
    let scenes: [SceneRecord]
    let people: [PersonRecord]

    var body: some View {
        if !people.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(people) { person in
                        HStack(spacing: 6) {
                            PersonFaceAvatar(person: person, size: 28)
                            Text(person.displayName).font(.caption).lineLimit(1)
                        }
                    }
                }
            }
        }
        if !scenes.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(scenes) { scene in
                        VideoThumbnail(url: scene.videoURL, time: scene.startTime, cornerRadius: 4)
                            .frame(width: 56, height: 36)
                            .accessibilityLabel("\(scene.videoFilename), \(scene.startTime.timecode)")
                    }
                }
            }
        }
    }
}
