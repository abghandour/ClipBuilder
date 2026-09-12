import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import Clip_Builder

nonisolated struct PersonFaceAvatarTests {
    @Test(.timeLimit(.minutes(1)))
    func faceDetectionFanOutLeavesAsyncWorkResponsive() async throws {
        let context = try #require(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try #require(context.makeImage())
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let data = encoded as Data
        // Vision loads its face model on first use and every caller waits for that
        // load; warm it once so the fan-out below measures steady-state behaviour.
        _ = await PersonFaceAvatar.detectFaces(in: data)
        let gate = FaceDetectionStartGate(participants: 17)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    _ = await gate.arrive()
                    let faces = await PersonFaceAvatar.detectFaces(in: data)
                    #expect(faces.isEmpty)
                }
            }
            group.addTask {
                // Start with all 16 detections ready. Sleeping forces the unrelated
                // task to resume on the pool while Vision is processing the fan-out.
                let start = await gate.arrive()
                try? await Task.sleep(for: .milliseconds(50))
                let elapsed = start.duration(to: ContinuousClock.now)
                #expect(elapsed < .seconds(2), "Vision fan-out starved unrelated async work")
            }
        }
    }
}

private actor FaceDetectionStartGate {
    private let participants: Int
    private var waiters: [CheckedContinuation<ContinuousClock.Instant, Never>] = []

    init(participants: Int) {
        self.participants = participants
    }

    func arrive() async -> ContinuousClock.Instant {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == participants {
                let start = ContinuousClock.now
                for waiter in waiters { waiter.resume(returning: start) }
                waiters.removeAll()
            }
        }
    }
}
