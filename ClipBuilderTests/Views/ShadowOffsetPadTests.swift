import Foundation
import Testing

@testable import Clip_Builder

struct ShadowOffsetPadTests {
    @Test func padRoundTripsOffsets() {
        for x in stride(from: -3.0, through: 3.0, by: 0.25) {
            for y in stride(from: -3.0, through: 3.0, by: 0.25) {
                let point = ShadowOffsetMapping.position(x: x, y: y)
                let offset = ShadowOffsetMapping.offset(at: point)
                #expect(abs(offset.x - x) < 0.000001)
                #expect(abs(offset.y - y) < 0.000001)
            }
        }
    }
    @Test func draggingOutsidePadClampsAndYPointsUp() {
        #expect(ShadowOffsetMapping.offset(at: CGPoint(x: -44, y: 88)) == CGPoint(x: -3, y: -3))
        #expect(ShadowOffsetMapping.offset(at: CGPoint(x: 88, y: -44)) == CGPoint(x: 3, y: 3))
        #expect(ShadowOffsetMapping.position(x: 0, y: 0) == CGPoint(x: 22, y: 22))
        #expect(ShadowOffsetMapping.offset(at: .zero, side: 0) == .zero)
    }
}
