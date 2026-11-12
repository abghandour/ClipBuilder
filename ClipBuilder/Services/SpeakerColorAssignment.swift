import Foundation

/// Which palette slot each speaker name has. A name starts on the slot its
/// hash picks, so it is the same on every Mac; names that appear together
/// (one video's speakers, one list's rows) are then moved apart, so two
/// speakers on screen never share a colour while the palette has room.
nonisolated struct SpeakerColorAssignment: Equatable, Sendable {
    var slots: [String: Int] = [:]
    /// The names each name has been shown with.
    var peers: [String: Set<String>] = [:]

    /// FNV-1a over the name: `hashValue` is seeded per process and would
    /// shuffle the colours on every launch.
    static func hashSlot(_ label: String, count: Int) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in label.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(max(1, count)))
    }

    func slot(_ label: String, count: Int) -> Int {
        slots[label].map { (($0 % count) + count) % count } ?? Self.hashSlot(label, count: count)
    }

    /// `group` is shown together: afterwards no two of its names share a
    /// slot (up to `count` names). In name order, so the same group settles
    /// the same way wherever it is first seen; a name that has to move
    /// takes the nearest slot none of the names it was ever shown with holds.
    mutating func register(_ group: Set<String>, count: Int) {
        guard group.count > 1, count > 1 else { return }
        for label in group { peers[label, default: []].formUnion(group.subtracting([label])) }
        var settled: [String] = []
        for label in group.sorted() {
            let mine = slot(label, count: count)
            if settled.contains(where: { slot($0, count: count) == mine }) {
                let known = Set((peers[label] ?? []).map { slot($0, count: count) })
                let here = Set(settled.map { slot($0, count: count) })
                let order = (1..<count).map { (mine + $0) % count }
                if let free = order.first(where: { !known.contains($0) }) ?? order.first(where: { !here.contains($0) }) {
                    slots[label] = free
                }
            } else if slots[label] == nil {
                slots[label] = mine
            }
            settled.append(label)
        }
    }
}
