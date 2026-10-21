import CoreGraphics

extension CropRecipePlanner {
    /// Prefer the layout's face centre; the matching roster portrait also
    /// supplies the bounds needed for containment and headroom in every crop.
    nonisolated static func faceFocus(of tile: PodcastTile, roster: [VideoPersonRecord])
        -> (center: (x: Double, y: Double)?, faceBox: CGRect?) {
        let portrait = roster.first { person in
            guard let box = person.portraitBox else { return false }
            return (tile.personKey == nil || tile.personKey == person.key)
                && tile.contains(x: box.x + box.w / 2, y: box.y + box.h / 2)
        }?.portraitBox
        let box = portrait.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
        let center = tile.faceCenter ?? portrait.map { (x: $0.x + $0.w / 2, y: $0.y + $0.h / 2) }
        return (center, box)
    }
}
