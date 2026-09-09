import Foundation
import CryptoKit

nonisolated enum LocalDuplicates {
    struct Signature: Sendable {
        var id: Int64
        var size: Int
        var digest: String?
        var duration: Double
        var width: Int
        var height: Int
        var hashes: [UInt64]
        var created: Date
    }
    static func digest(_ url: URL) -> (Int, String)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        do {
            var data = try file.read(upToCount: 1_048_576) ?? Data()
            try file.seek(toOffset: UInt64(max(0, size - 1_048_576)))
            data.append(try file.read(upToCount: 1_048_576) ?? Data())
            return (size, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        } catch { return nil }
    }
    static func matches(_ a: Signature, _ b: Signature) -> Bool {
        if a.size == b.size, let digest = a.digest, digest == b.digest { return true }
        return abs(a.duration - b.duration) <= 0.5 && a.width == b.width && a.height == b.height
            && a.hashes.count == 5 && b.hashes.count == 5
            && zip(a.hashes, b.hashes).allSatisfy { ($0 ^ $1).nonzeroBitCount <= 4 }
    }
    static func groups(_ signatures: [Signature]) -> [DuplicateFinder.Group] {
        var groups: [[Signature]] = []
        for signature in signatures {
            if let index = groups.firstIndex(where: { $0.allSatisfy { matches($0, signature) } }) {
                groups[index].append(signature)
            } else { groups.append([signature]) }
        }
        return groups.filter { $0.count > 1 }.map { group in
            let keep = group.sorted {
                if $0.created != $1.created { return $0.created < $1.created }
                if $0.size != $1.size { return $0.size > $1.size }
                return $0.id < $1.id
            }[0]
            return DuplicateFinder.Group(videoIDs: group.map(\.id), keepID: keep.id, reason: "Matching file or five-frame hashes")
        }
    }
}

extension DuplicateFinder {
    nonisolated static func local(videos: [VideoRecord]) async throws -> [Group] {
        let signatures = try await BoundedConcurrency.map(videos, limit: FFmpeg.jobLimit) { _, video in
            let digest = await Task.detached { LocalDuplicates.digest(video.url) }.value
            return LocalDuplicates.Signature(id: video.id, size: digest?.0 ?? -1, digest: digest?.1,
                duration: video.duration, width: video.width, height: video.height, hashes: [], created: video.createdDate)
        }
        let byteGroups = LocalDuplicates.groups(signatures)
        let grouped = Set(byteGroups.flatMap(\.videoIDs))
        let remaining = signatures.filter { !grouped.contains($0.id) }
        let hashed = try await BoundedConcurrency.map(remaining, limit: FFmpeg.jobLimit) { _, signature in
            var signature = signature
            guard let video = videos.first(where: { $0.id == signature.id }) else { return signature }
            let frames = await ThumbnailService.jpegFrames(url: video.url, at: [0.1, 0.3, 0.5, 0.7, 0.9].map { $0 * video.duration })
            signature.hashes = await Task.detached { frames.compactMap { $0.flatMap(FrameQuality.differenceHash) } }.value
            return signature
        }
        return byteGroups + LocalDuplicates.groups(hashed)
    }
}
