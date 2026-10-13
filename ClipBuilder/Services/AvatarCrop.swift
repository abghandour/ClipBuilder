import CoreGraphics
import Foundation

/// Where a person's avatar is cut out of a frame. Pure geometry, so the
/// choice of crop can be tested without Vision or image decoding.
nonisolated enum AvatarCrop {
    /// How much larger than the face the square crop is: the head with hair
    /// and a little shoulder, not a passport crop and not a torso.
    static let faceZoom: CGFloat = 2.2

    /// Square crop in pixel coordinates (top-left origin). With a face, the
    /// square is `faceZoom` times the face and the face sits a little above
    /// centre so the crop reads as a head shot. Without one, the image is
    /// cropped at its centre.
    static func rect(imageSize: CGSize, faceBox: CGRect?) -> CGRect {
        let width = imageSize.width, height = imageSize.height
        guard width > 0, height > 0 else { return .zero }
        let side: CGFloat
        let center: CGPoint
        if let faceBox {
            // Normalized bottom-left origin → pixel top-left origin.
            let face = CGRect(x: faceBox.minX * width,
                              y: (1 - faceBox.maxY) * height,
                              width: faceBox.width * width,
                              height: faceBox.height * height)
            side = min(max(face.width, face.height) * faceZoom, min(width, height))
            center = CGPoint(x: face.midX, y: face.midY + side * 0.06)
        } else {
            side = min(width, height)
            center = CGPoint(x: width / 2, y: height / 2)
        }
        return square(side: side, center: center, in: imageSize)
    }

    /// Where a person's head is when no face was detected (turned away,
    /// too small): the top of their body box. The square covers the top
    /// third of the box, centred a little below its top edge, so a loose
    /// box still lands on the head rather than on the ceiling or the torso.
    static func headRect(imageSize: CGSize, marker: PersonMarker) -> CGRect {
        let width = imageSize.width, height = imageSize.height
        guard width > 0, height > 0 else { return .zero }
        let boxWidth = marker.width * width, boxHeight = marker.height * height
        let side = min(max(boxWidth * 0.9, boxHeight * 0.32), min(width, height))
        let center = CGPoint(x: (marker.x + marker.width / 2) * width,
                             y: (marker.y + marker.height * 0.16) * height)
        return square(side: side, center: center, in: imageSize)
    }

    private static func square(side: CGFloat, center: CGPoint, in size: CGSize) -> CGRect {
        let origin = CGPoint(x: min(max(0, center.x - side / 2), size.width - side),
                             y: min(max(0, center.y - side / 2), size.height - side))
        return CGRect(origin: origin, size: CGSize(width: side, height: side))
    }

    /// The largest detected face that belongs to the marked person: its
    /// centre lies inside the marker box (normalized top-left origin), with
    /// a little tolerance for a box drawn tight around the body. Faces are
    /// Vision boxes (normalized bottom-left origin).
    static func face(among faces: [CGRect], inside marker: PersonMarker) -> CGRect? {
        let pad = 0.1
        let box = CGRect(x: marker.x - marker.width * pad,
                         y: 1 - marker.y - marker.height * (1 + pad),
                         width: marker.width * (1 + 2 * pad),
                         height: marker.height * (1 + 2 * pad))
        return faces
            .filter { box.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            .max { $0.width < $1.width }
    }
}
