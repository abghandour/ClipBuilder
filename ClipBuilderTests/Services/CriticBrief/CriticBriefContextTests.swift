import Foundation
import Testing
@testable import Clip_Builder

@MainActor
struct CriticBriefContextTests {
    private actor BuildSpy {
        private(set) var calls = 0

        func build(pool: [CriticExemplars.Candidate], store: CriticBriefStore,
                   profile: BrandProfile) throws -> CriticBrief? {
            calls += 1
            var brief = CriticBriefFixtures.brief()
            brief.key = try CriticBriefStore.key(pool: pool, profile: profile)
            brief.exemplars = pool.enumerated().map { index, row in
                .init(id: row.id, label: "REFERENCE \(index)", why: row.why,
                      duration: row.duration, traits: nil, sheetPath: "sheet-\(index).jpg")
            }
            try store.save(brief)
            for exemplar in brief.exemplars {
                try Data([1, 2, 3]).write(to: store.directory.appendingPathComponent(exemplar.sheetPath))
            }
            return brief
        }
    }

    private func seedTeachers(_ temp: TempDatabase) async throws -> [CriticExemplars.Candidate] {
        for index in 1...2 {
            let file = temp.directory.url.appendingPathComponent("teacher-\(index).mp4")
            try Data([UInt8(index)]).write(to: file)
            let id = try await temp.database.insertGeneratedVideo(path: file.path, duration: 20,
                timelineJSON: "{}", wizardProvider: nil, wizardModel: nil)
            try await temp.database.setGeneratedVideoFavorite(id, favorite: true)
        }
        return try await temp.database.criticExemplarCandidates()
    }

    @Test(arguments: [CriticBriefUse.off, .automatic])
    func disabledRunsNeverBuildEvenWithEligibleTeachers(use: CriticBriefUse) async throws {
        let temp = try TempDatabase()
        _ = try await seedTeachers(temp)
        var profile = Fixtures.brand()
        profile.criticBriefUse = use
        let store = CriticBriefStore(profile: profile, root: temp.directory.url)
        let spy = BuildSpy()
        let snapshot = profile
        let context = try await CriticBriefContext.loadForRun(database: temp.database, profile: profile,
            generatedID: 999, store: store, build: { pool in
                try await spy.build(pool: pool, store: store, profile: snapshot)
            }, emit: { _ in })
        #expect(context == nil)
        #expect(await spy.calls == 0)
        #expect(store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test(arguments: [CriticBriefUse.off, .automatic])
    func cachedBriefDoesNotBypassDisabledDecision(use: CriticBriefUse) async throws {
        let temp = try TempDatabase()
        let pool = try await seedTeachers(temp)
        var profile = Fixtures.brand()
        profile.criticBriefUse = use
        let store = CriticBriefStore(profile: profile, root: temp.directory.url)
        let spy = BuildSpy()
        let brief = try #require(try await spy.build(pool: pool, store: store, profile: profile))
        // Off must win even over a passed keep rule; automatic must reject a failed rule.
        try store.saveDecision(.init(briefKey: brief.key, measuredAt: .now, passed: use == .off,
                                     reportPath: "fixture", briefBuiltAt: brief.builtAt))
        let snapshot = profile
        let context = try await CriticBriefContext.loadForRun(database: temp.database, profile: profile,
            generatedID: 999, store: store, build: { pool in
                try await spy.build(pool: pool, store: store, profile: snapshot)
            }, emit: { _ in })
        #expect(context == nil)
        #expect(await spy.calls == 1, "Only the fixture setup may build")
    }

    @Test func onBuildsOnceThenUsesCacheWithoutAnAgreementDecision() async throws {
        let temp = try TempDatabase()
        _ = try await seedTeachers(temp)
        var profile = Fixtures.brand()
        profile.criticBriefUse = .on
        let store = CriticBriefStore(profile: profile, root: temp.directory.url)
        let spy = BuildSpy()
        let snapshot = profile
        let first = try #require(try await CriticBriefContext.loadForRun(database: temp.database, profile: profile,
            generatedID: 999, store: store, build: { pool in
                try await spy.build(pool: pool, store: store, profile: snapshot)
            }, emit: { _ in }))
        #expect(first.frames.count == 2)
        #expect(first.frames.allSatisfy { $0.jpeg == Data([1, 2, 3]) })
        #expect(store.load() == first.brief)
        #expect(store.decision() == nil)
        let second = try #require(try await CriticBriefContext.loadForRun(database: temp.database, profile: profile,
            generatedID: 999, store: store, build: { pool in
                try await spy.build(pool: pool, store: store, profile: snapshot)
            }, emit: { _ in }))
        #expect(second.brief == first.brief)
        #expect(await spy.calls == 1)

        // Forcing use still excludes a teacher that is itself being reviewed.
        let teacher = try #require(try await temp.database.fetchGeneratedVideos().first)
        let excluded = try await CriticBriefContext.loadForRun(database: temp.database, profile: profile,
            generatedID: teacher.id, store: store, build: { pool in
                try await spy.build(pool: pool, store: store, profile: snapshot)
            }, emit: { _ in })
        #expect(excluded == nil)
        #expect(await spy.calls == 1)
    }

    @Test func automaticUsesOnlyTheMeasuredCachedBrief() async throws {
        let temp = try TempDatabase()
        let pool = try await seedTeachers(temp)
        let profile = Fixtures.brand()
        let store = CriticBriefStore(profile: profile, root: temp.directory.url)
        let spy = BuildSpy()
        let brief = try #require(try await spy.build(pool: pool, store: store, profile: profile))
        let unevaluated = try await CriticBriefContext.loadForRun(database: temp.database, profile: profile,
            generatedID: 999, store: store, build: { pool in
                try await spy.build(pool: pool, store: store, profile: profile)
            }, emit: { _ in })
        #expect(unevaluated == nil)
        #expect(await spy.calls == 1)
        try store.saveDecision(.init(briefKey: brief.key, measuredAt: .now, passed: true,
                                     reportPath: "fixture", briefBuiltAt: brief.builtAt))
        let context = try await CriticBriefContext.loadForRun(database: temp.database, profile: profile,
            generatedID: 999, store: store, build: { pool in
                try await spy.build(pool: pool, store: store, profile: profile)
            }, emit: { _ in })
        #expect(context?.brief == brief)
        #expect(await spy.calls == 1)
    }

    @Test func preferenceDecodesLegacyProfilesAndRoundTripsPerProfile() throws {
        let legacy = try JSONDecoder().decode(BrandProfile.self, from: Data("{}".utf8))
        #expect(legacy.criticBriefUse == .automatic)
        for use in CriticBriefUse.allCases {
            var profile = Fixtures.brand()
            profile.criticBriefUse = use
            let encoded = try JSONEncoder().encode(profile)
            let decoded = try JSONDecoder().decode(BrandProfile.self, from: encoded)
            #expect(decoded.criticBriefUse == use)
            #expect(BrandProfile(name: "Another profile").criticBriefUse == .automatic)
        }
    }

    @Test func usageStatusReflectsTheResolvedRule() {
        #expect(CriticBriefUse.automatic.status(keepRulePassed: false) == "Used: automatic (keep rule not passed yet)")
        #expect(CriticBriefUse.automatic.status(keepRulePassed: true) == "Used: automatic (keep rule passed)")
        #expect(CriticBriefUse.on.status(keepRulePassed: false) == "Used: always")
        #expect(CriticBriefUse.off.status(keepRulePassed: true) == "Off")
    }
}
