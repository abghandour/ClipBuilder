import CoreGraphics
import Foundation

nonisolated enum PortraitBoxParsing {
    /// The pixel size of the frame the model saw: the source fitted inside a
    /// square of `longestEdge` without upscaling, as `ThumbnailService.jpegFrames`
    /// does. A model answering in pixels means these pixels, not the source's.
    static func frameSize(width: Int, height: Int, longestEdge: Int) -> (width: Int, height: Int) {
        let width = max(1, width), height = max(1, height)
        guard longestEdge > 0, max(width, height) > longestEdge else { return (width, height) }
        let scale = Double(longestEdge) / Double(max(width, height))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// A pixel answer's scale is unknown (the provider may shrink frames), so
    /// the faces Vision sees at the same moment are the truth. Two or more
    /// boxes with at least as many faces pair left to right with the largest
    /// faces, which no scale can disturb; a lone box, or too few faces, take
    /// the nearest unclaimed face by centre, closest pairs first. Each result
    /// is a head-and-shoulders portrait around the face.
    static func snapped(boxes: [(key: String, box: VideoPersonRecord.PortraitBox)], toFaces faces: [CGRect])
        -> [String: VideoPersonRecord.PortraitBox] {
        let faces = faces.filter { !$0.isNull && !$0.isEmpty }
        guard !boxes.isEmpty, !faces.isEmpty else { return [:] }
        var result: [String: VideoPersonRecord.PortraitBox] = [:]
        if boxes.count >= 2, faces.count >= boxes.count {
            let ordered = boxes.sorted { $0.box.x + $0.box.w / 2 < $1.box.x + $1.box.w / 2 }
            let chosen = faces.sorted { $0.width * $0.height > $1.width * $1.height }.prefix(boxes.count).sorted { $0.midX < $1.midX }
            for (entry, face) in zip(ordered, chosen) {
                result[entry.key] = portrait(around: face)
            }
            return result
        }
        var pairs: [(distance: Double, key: String, face: Int)] = []
        for entry in boxes {
            let cx = entry.box.x + entry.box.w / 2, cy = entry.box.y + entry.box.h / 2
            for (index, face) in faces.enumerated() {
                pairs.append((hypot(face.midX - cx, (face.midY - cy) * 0.5), entry.key, index))
            }
        }
        var usedFaces: Set<Int> = []
        for pair in pairs.sorted(by: { $0.distance < $1.distance }) where result[pair.key] == nil && !usedFaces.contains(pair.face) {
            result[pair.key] = portrait(around: faces[pair.face])
            usedFaces.insert(pair.face)
        }
        return result
    }

    /// Head and shoulders around a face, clamped to the frame.
    static func portrait(around face: CGRect) -> VideoPersonRecord.PortraitBox {
        let w = min(1, face.width * 2.2), h = min(1, face.height * 3)
        let x = min(max(0, face.midX - w / 2), 1 - w)
        let y = min(max(0, face.minY - face.height * 0.4), 1 - h)
        func round4(_ value: Double) -> Double { (value * 10000).rounded() / 10000 }
        return .init(x: round4(x), y: round4(y), w: round4(w), h: round4(h))
    }

    static func normalise(_ box: VideoPersonRecord.PortraitBox, width: Int, height: Int)
        -> (box: VideoPersonRecord.PortraitBox, wasPixels: Bool) {
        let wasPixels = [box.x, box.y, box.w, box.h].contains { $0 > 1 }
        let xScale = wasPixels ? Double(max(1, width)) : 1
        let yScale = wasPixels ? Double(max(1, height)) : 1
        return (.init(x: min(max(0, box.x / xScale), 1),
                      y: min(max(0, box.y / yScale), 1),
                      w: min(max(0.02, box.w / xScale), 1),
                      h: min(max(0.02, box.h / yScale), 1)), wasPixels)
    }
}
