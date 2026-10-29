import Testing

@testable import Clip_Builder

struct LookThumbnailCacheTests {
    @Test func sameDecorRendersOnceIncludingConcurrentRequests() async throws {
        let cache = LookThumbnailCache()
        let decor = TextDecor(color: "#FFD60A", shadowOn: true)
        async let first = cache.image(decor: decor, fontFamily: nil)
        async let second = cache.image(decor: decor, fontFamily: nil)
        let (a, b) = try await (first, second)
        let third = try await cache.image(decor: decor, fontFamily: nil)
        #expect(!a.isEmpty)
        #expect(a == b)
        #expect(a == third)
        #expect(await cache.renderCount == 1)
    }

    @Test func changedLookAndFontHaveDistinctCacheEntries() async throws {
        let cache = LookThumbnailCache()
        _ = try await cache.image(decor: TextDecor(color: "#FFFFFF"), fontFamily: nil)
        _ = try await cache.image(decor: TextDecor(color: "#FFD60A"), fontFamily: nil)
        _ = try await cache.image(decor: TextDecor(color: "#FFD60A"), fontFamily: "Helvetica")
        #expect(await cache.renderCount == 3)
    }
}
