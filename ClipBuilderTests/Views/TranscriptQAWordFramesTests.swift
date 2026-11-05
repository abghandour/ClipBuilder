import Foundation
import Testing
@testable import Clip_Builder

@MainActor
struct TranscriptQAWordFramesTests {
    private let placed: [Int: CGRect] = [3: CGRect(x: 0, y: 0, width: 20, height: 15), 4: CGRect(x: 23, y: 0, width: 30, height: 15)]

    @Test func aLinePublishesOnceItIsOnScreenPlacedAndPositioned() {
        let store = TranscriptQAWordFrames()
        store.place(line: 1, frames: placed)
        store.flush()
        #expect(store.frames.isEmpty)
        store.move(line: 1, to: CGPoint(x: 10, y: 100))
        #expect(store.frames.isEmpty)
        store.appear(line: 1)
        #expect(store.frames[3] == CGRect(x: 10, y: 100, width: 20, height: 15))
        #expect(store.frames[4] == CGRect(x: 33, y: 100, width: 30, height: 15))
    }

    @Test func scrollingMovesTheWordsAndLeavingTheScreenRemovesThem() {
        let store = TranscriptQAWordFrames()
        store.appear(line: 1)
        store.move(line: 1, to: .zero)
        store.place(line: 1, frames: placed); store.flush()
        store.move(line: 1, to: CGPoint(x: 0, y: -40))
        #expect(store.frames[3]?.minY == -40)
        store.disappear(line: 1)
        #expect(store.frames.isEmpty)
        // A view that comes back keeps the placement; only the origin is new.
        store.appear(line: 1)
        store.move(line: 1, to: CGPoint(x: 0, y: 60))
        #expect(store.frames[4] == CGRect(x: 23, y: 60, width: 30, height: 15))
    }

    @Test func aNewPlacementReplacesTheOldWordsOfTheLine() {
        let store = TranscriptQAWordFrames()
        store.appear(line: 2)
        store.move(line: 2, to: .zero)
        store.place(line: 2, frames: placed); store.flush()
        store.place(line: 2, frames: [9: CGRect(x: 0, y: 0, width: 5, height: 15)]); store.flush()
        #expect(store.frames.keys.sorted() == [9])
    }

    @Test func keepDropsWordsThatNoLongerExistAndKeepsTheRest() {
        let store = TranscriptQAWordFrames()
        store.appear(line: 1)
        store.move(line: 1, to: .zero)
        store.place(line: 1, frames: placed); store.flush()
        store.keep(wordIDs: [3])
        #expect(store.frames.keys.sorted() == [3])
        store.move(line: 1, to: CGPoint(x: 0, y: 5))
        #expect(store.frames.keys.sorted() == [3])
        #expect(store.frames[3]?.minY == 5)
    }
}
