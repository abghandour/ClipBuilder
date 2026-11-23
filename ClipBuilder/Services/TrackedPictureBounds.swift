import CoreGraphics

/// Keep camera windows inside actual picture pixels, preserving their aspect.
/// Valid windows are returned verbatim, including their floating-point values.
nonisolated enum TrackedPictureBounds {
    static func clamped(_ path: [CameraPathKeyframe], to picture: FreeCropRect = FreeCropRect()) -> [CameraPathKeyframe] {
        // An invalid sample invalidates the path: dropping it would invent a
        // camera ramp over the missing interval. Empty means no usable path.
        guard valid(picture), path.allSatisfy({ key in
            key.t.isFinite && key.x.isFinite && key.y.isFinite
                && key.w.isFinite && key.h.isFinite && key.w > 0 && key.h > 0
                && (key.x + key.w).isFinite && (key.y + key.h).isFinite
        }) else { return [] }
        return path.map { key in
            guard key.x < picture.xFrac || key.y < picture.yFrac
                || key.x + key.w > picture.xFrac + picture.wFrac
                || key.y + key.h > picture.yFrac + picture.hFrac else { return key }
            let window = FocusFrame.fitting(.init(xFrac: key.x, yFrac: key.y, wFrac: key.w, hFrac: key.h), inside: picture)
            return CameraPathKeyframe(t: key.t, x: window.xFrac, y: window.yFrac, w: window.wFrac, h: window.hFrac)
        }
    }

    private static func valid(_ picture: FreeCropRect) -> Bool {
        picture.xFrac.isFinite && picture.yFrac.isFinite
            && picture.wFrac.isFinite && picture.hFrac.isFinite
            && picture.wFrac > 0 && picture.hFrac > 0
            && picture.xFrac >= 0 && picture.yFrac >= 0
            && picture.xFrac + picture.wFrac <= 1 && picture.yFrac + picture.hFrac <= 1
    }

    static func clamped(_ crop: CGRect, size: CGSize, picture: FreeCropRect = FreeCropRect()) -> CGRect? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              crop.origin.x.isFinite, crop.origin.y.isFinite,
              crop.size.width.isFinite, crop.size.height.isFinite,
              crop.size.width > 0, crop.size.height > 0 else { return nil }
        let key = CameraPathKeyframe(t: 0, x: crop.minX / size.width, y: crop.minY / size.height,
            w: crop.width / size.width, h: crop.height / size.height)
        let path = clamped([key], to: picture)
        guard let corrected = path.first else { return nil }
        guard corrected != key else { return crop }
        return CGRect(x: corrected.x * size.width, y: corrected.y * size.height,
            width: corrected.w * size.width, height: corrected.h * size.height)
    }
}
