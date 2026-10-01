import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Clip_Builder

struct ContactSheetTests {
    @Test func fourSlotsKeepSizeAndMissingSlotsStayGray() throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let sheet = try ContactSheet.image(frames: [encoded as Data, nil, encoded as Data, nil])
        #expect(sheet.width == 1400 && sheet.height == 384)
        let bytes = try #require(sheet.dataProvider?.data)
        let pointer = try #require(CFDataGetBytePtr(bytes))
        for slot in 0..<4 {
            let offset = 192 * sheet.bytesPerRow + (slot * 350 + 175) * 4
            if slot % 2 == 0 {
                #expect(pointer[offset] > 240 && pointer[offset + 1] < 80, "color-managed red keeps a little green")
            } else {
                #expect(abs(Int(pointer[offset]) - Int(pointer[offset + 1])) <= 1)
                #expect(pointer[offset] > 60 && pointer[offset] < 100)
            }
        }
        let full = try ContactSheet.image(frames: Array<Data?>(repeating: encoded as Data, count: 4))
        #expect(full.width == 1400 && full.height == 384)
        #expect(ContactSheet.times(duration: 20) == [0.3, 1.8, 10, 19.6])
    }
}
