import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

struct CustomPositionTests {
    @Test func parsesAndFormatsItsOwnString() {
        let position = CustomPosition(x: 0.25, y: 0.8)
        #expect(position.string == "custom:0.2500,0.8000")
        #expect(CustomPosition(position.string) == position)
        #expect(CustomPosition("custom: 0.5 , 0.5 ") == CustomPosition(x: 0.5, y: 0.5))
        #expect(CustomPosition.isCustom("custom:0.1,0.2"))
    }

    @Test func namedChoicesAndJunkAreNotCustom() {
        for value in [nil, "", "bottom", "topTrailing", "auto", "custom:", "custom:1", "custom:a,b", "custom:0.5,nan"] {
            #expect(CustomPosition(value) == nil, "\(value ?? "nil")")
            #expect(!CustomPosition.isCustom(value))
        }
    }

    @Test func coordinatesAreClampedToTheCanvas() {
        #expect(CustomPosition(x: -2, y: 7) == CustomPosition(x: 0, y: 1))
        #expect(CustomPosition("custom:1.5,-0.5") == CustomPosition(x: 1, y: 0))
        #expect(CustomPosition(x: .nan, y: .infinity) == CustomPosition(x: 0.5, y: 0.5))
    }

    @Test func originKeepsTheBoxInsideTheBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let size = CGSize(width: 400, height: 100)
        let centred = CustomPosition(x: 0.5, y: 0.5).origin(size: size, in: bounds)
        #expect(centred == CGPoint(x: 340, y: 910))
        let corner = CustomPosition(x: 1, y: 1).origin(size: size, in: bounds)
        #expect(corner == CGPoint(x: 680, y: 1820))
        let edge = CustomPosition(x: 0, y: 0.2).origin(size: size, in: bounds)
        #expect(edge == CGPoint(x: 0, y: 334))
        // Inside a smaller bounds rect the same fractions map to that rect.
        let inset = CGRect(x: 100, y: 200, width: 500, height: 500)
        #expect(CustomPosition(x: 0, y: 0).origin(size: size, in: inset) == CGPoint(x: 100, y: 200))
        // A box larger than the bounds is centred on them.
        let huge = CustomPosition(x: 0.9, y: 0.1).origin(size: CGSize(width: 2000, height: 100), in: bounds)
        #expect(huge.x == -460)
    }
}
