import AVFoundation
import Foundation
import ObjectiveC

/// Retained by an AVURLAsset (and therefore its player/image generator). An
/// off-load cannot unlink the media while AVFoundation is still using it.
nonisolated final class DriveMediaLease: Sendable {
    let path: String
    init(path: String) { self.path = path }
    deinit {
        let path = path
        Task { await DriveMediaResolver.shared.release(path) }
    }
}

nonisolated enum DriveLocalAsset {
    private nonisolated(unsafe) static var leaseKey: UInt8 = 0

    static func retainSources(_ sources: [AVURLAsset], on item: AVPlayerItem) {
        objc_setAssociatedObject(item, &leaseKey, sources, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func make(_ url: URL) async throws -> AVURLAsset {
        let lease = try await DriveMediaResolver.shared.acquire(url)
        let asset = AVURLAsset(url: url)
        objc_setAssociatedObject(asset, &leaseKey, lease, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }
}
