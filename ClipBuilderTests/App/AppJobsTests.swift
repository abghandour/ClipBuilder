import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("App jobs", .serialized)
struct AppJobsTests {
    private func finish(_ jobs: AppJobs) async throws {
        try await waitUntil { !jobs.hasLiveTasks }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Job did not reach the expected state")
    }

    private func makeStore() -> AppStore {
        let settings = AppSettings()
        let profile = Fixtures.brand(name: "Jobs")
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai))
        store.diagnosticLogSink = { _, _ in }
        return store
    }

    /// Holds work after Stop so tests exercise the draining-task state deterministically.
    @MainActor private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var entered = false

        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    @Test func resultSurvivesClosingReview() async throws {
        let jobs = AppJobs()
        let id = jobs.start(.resourceExport, title: "Export", project: nil, profileGeneration: 0) { _ in
            .resourceExport(url: URL(fileURLWithPath: "/tmp/result.zip"))
        }
        try await finish(jobs)
        #expect(jobs.items.first?.status == .done)
        #expect(jobs.presentedReview?.id == id)
        jobs.presentedReview = nil
        #expect(jobs.presentedReview == nil)
        #expect(jobs.awaitingReview.map(\.id) == [id])
        jobs.markReviewed(id)
        #expect(jobs.awaitingReview.isEmpty)
        #expect(jobs.items.isEmpty)
        #expect(jobs.latest(.resourceExport)?.result == nil)
    }

    @Test func failureHasNoResult() async throws {
        let jobs = AppJobs()
        jobs.start(.resourceExport, title: "Export", project: nil, profileGeneration: 0) { _ in
            throw AIError.notConfigured("Test failure")
        }
        try await finish(jobs)
        guard case .failed = jobs.items.first?.status else { Issue.record("Expected failure"); return }
        #expect(jobs.items.first?.result == nil)
        #expect(jobs.reviewQueue.isEmpty)
    }

    @Test func stopCancelsWork() async throws {
        let jobs = AppJobs()
        let id = jobs.start(.resourceExport, title: "Export", project: nil, profileGeneration: 0) { _ in
            try await Task.sleep(for: .seconds(60))
            return .resourceExport(url: URL(fileURLWithPath: "/tmp/late.zip"))
        }
        jobs.cancel(id)
        await Task.yield()
        #expect(jobs.items.first?.status == .cancelled)
        #expect(jobs.items.first?.result == nil)
        #expect(jobs.reviewQueue.isEmpty)
    }

    @Test func rootSheetBlocksAndReviewsAreOrdered() async throws {
        let jobs = AppJobs()
        jobs.presentationBlocked = true
        let first = jobs.start(.resourceExport, title: "First", project: nil, profileGeneration: 0) { _ in
            .resourceExport(url: URL(fileURLWithPath: "/tmp/first.zip"))
        }
        try await finish(jobs)
        let second = jobs.start(.resourceExport, title: "Second", project: nil, profileGeneration: 0) { _ in
            .resourceExport(url: URL(fileURLWithPath: "/tmp/second.zip"))
        }
        try await finish(jobs)
        #expect(jobs.presentedReview == nil)
        jobs.presentationBlocked = false
        #expect(jobs.presentedReview?.id == first)
        jobs.presentedReview = nil
        #expect(jobs.presentedReview?.id == second)
    }

    @Test func otherProjectWaitsForReview() async throws {
        let jobs = AppJobs()
        let project = ProjectRecord(id: 42, profileName: "test", name: "Other", archived: false,
                                    isHome: false, sourceCount: 0, timelineCount: 0, outputCount: 0, thumbnailPaths: [])
        jobs.activeProjectID = 1
        jobs.start(.resourceExport, title: "Export", project: project, profileGeneration: 0) { _ in
            .resourceExport(url: URL(fileURLWithPath: "/tmp/result.zip"))
        }
        try await finish(jobs)
        #expect(jobs.presentedReview == nil)
        #expect(jobs.awaitingReview.count == 1)
        jobs.activeProjectID = 42
        #expect(jobs.presentedReview != nil)
        if let id = jobs.presentedReview?.id { jobs.reviewDidAppear(id) }
        jobs.activeProjectID = 1
        #expect(jobs.presentedReview == nil)
        #expect(jobs.awaitingReview.count == 1)
    }

    @Test func nextReviewWaitsForSheetDismissal() async throws {
        let jobs = AppJobs()
        let first = jobs.start(.resourceExport, title: "First", project: nil, profileGeneration: 0) { _ in
            .resourceExport(url: URL(fileURLWithPath: "/tmp/first.zip"))
        }
        try await finish(jobs)
        jobs.reviewDidAppear(first)
        let second = jobs.start(.resourceExport, title: "Second", project: nil, profileGeneration: 0) { _ in
            .resourceExport(url: URL(fileURLWithPath: "/tmp/second.zip"))
        }
        try await finish(jobs)
        jobs.markReviewed(first)
        #expect(jobs.presentedReview?.id == first)
        jobs.presentedReview = nil
        #expect(jobs.presentedReview == nil)
        jobs.reviewDidDismiss()
        #expect(jobs.presentedReview?.id == second)
    }

    @Test func onlyOverlayPostsAnOrdinaryCompletionNotice() async throws {
        let store = makeStore()
        for kind in AppJobKind.allCases where kind != .overlayTemplate {
            #expect(!kind.postsNotice)
            store.jobs.start(kind, title: kind.shortTitle, project: nil, profileGeneration: 0) { log in
                log("Finished silently")
                return nil
            }
            try await finish(store.jobs)
            #expect(store.jobs.latest(kind)?.status == .done)
            #expect(store.jobs.latest(kind)?.statusLine == "Finished silently")
            #expect(store.jobs.items.isEmpty)
            #expect(store.currentNotice == nil)
        }
        store.jobs.start(.imageSearch, title: "Search", project: nil, profileGeneration: 0) { _ in
            .imageSearch(query: "fighter", paths: ["/tmp/fighter.png"], folder: [])
        }
        try await finish(store.jobs)
        #expect(store.currentNotice == nil)
        #expect(store.jobs.latestFinished(.imageSearch, projectID: nil)?.result != nil)
        store.jobs.start(.overlayTemplate, title: "Extract Overlay", project: nil, profileGeneration: 0) { log in
            log("Created template name")
            return nil
        }
        try await finish(store.jobs)
        #expect(AppJobKind.overlayTemplate.postsNotice)
        #expect(store.currentNotice?.message == "Created template name")
        #expect(store.jobs.latest(.overlayTemplate)?.statusLine == "Created template name")
    }

    @Test func automaticFailureIsSilentButExplicitFailureReports() async throws {
        let store = makeStore()
        store.jobs.start(.cameraPath, title: "Automatic", project: nil, profileGeneration: 0,
                         reportsFailure: false) { _ in
            throw AIError.notConfigured("No trackable subject")
        }
        try await finish(store.jobs)
        guard case .failed = store.jobs.latest(.cameraPath)?.status else {
            Issue.record("Expected retained failure"); return
        }
        #expect(store.currentError == nil)
        #expect(store.currentNotice == nil)
        store.jobs.start(.cameraPath, title: "Explicit", project: nil, profileGeneration: 0) { _ in
            throw AIError.notConfigured("No trackable subject")
        }
        try await finish(store.jobs)
        #expect(store.currentError != nil)
    }

    @Test func changedCameraRangeSupersedesOnlyThatScene() async throws {
        let jobs = AppJobs()
        let firstGate = Gate(), replacementGate = Gate(), otherGate = Gate()
        defer { firstGate.release(); replacementGate.release(); otherGate.release() }
        let key = CameraPathJobKey(sceneID: 42, start: 0, end: 10, camera: "balanced")
        let changed = CameraPathJobKey(sceneID: 42, start: 2, end: 8, camera: "balanced")
        #expect(key.subjectID != changed.subjectID)
        #expect(key.subjectID != CameraPathJobKey(sceneID: 42, start: 0, end: 9, camera: "balanced").subjectID)
        #expect(key.subjectID != CameraPathJobKey(sceneID: 42, start: 0, end: 10, camera: "fast").subjectID)
        let first = jobs.start(.cameraPath, title: "First", project: nil, profileGeneration: 0,
                              subjectID: key.subjectID, subjectGroupID: key.groupID) { _ in
            await firstGate.wait()
            return nil
        }
        try await waitUntil { firstGate.entered }
        let same = jobs.start(.cameraPath, title: "Same", project: nil, profileGeneration: 0,
                             subjectID: key.subjectID, subjectGroupID: key.groupID) { _ in
            Issue.record("Identical running camera request should be reused")
            return nil
        }
        #expect(same == first)
        let other = jobs.start(.cameraPath, title: "Other scene", project: nil, profileGeneration: 0,
                              subjectID: "43|0|10|balanced", subjectGroupID: "43") { _ in
            await otherGate.wait()
            return nil
        }
        let replacement = jobs.start(.cameraPath, title: "New range", project: nil, profileGeneration: 0,
                                    subjectID: changed.subjectID, subjectGroupID: changed.groupID) { _ in
            await replacementGate.wait()
            return nil
        }
        #expect(replacement != first)
        #expect(jobs.items.first { $0.id == first }?.status == .cancelled)
        #expect(jobs.items.first { $0.id == other }?.status == .running)
        #expect(jobs.latest(.cameraPath, subjectGroupID: key.groupID)?.id == replacement)
        firstGate.release(); replacementGate.release(); otherGate.release()
        try await finish(jobs)
        #expect(jobs.latest(.cameraPath, subjectGroupID: key.groupID)?.id == replacement)
        #expect(jobs.latest(.cameraPath, subjectGroupID: key.groupID)?.status == .done)
    }

    @Test func stopThenRestartDoesNotReuseDrainingTask() async throws {
        let jobs = AppJobs()
        let oldGate = Gate(), newGate = Gate()
        defer { oldGate.release(); newGate.release() }
        let project = ProjectRecord(id: 42, profileName: "test", name: "Other", archived: false,
                                    isHome: false, sourceCount: 0, timelineCount: 0, outputCount: 0, thumbnailPaths: [])
        let first = jobs.start(.cameraPath, title: "First", project: project, profileGeneration: 0,
                              subjectID: "same") { _ in
            await oldGate.wait()
            return nil
        }
        try await waitUntil { oldGate.entered }
        jobs.cancel(first)
        jobs.dismiss(first)
        #expect(jobs.items.isEmpty)
        #expect(jobs.hasLiveTask(kind: .cameraPath))
        #expect(jobs.busyProjectIDs == [42])
        let replacement = jobs.start(.cameraPath, title: "Restart", project: project, profileGeneration: 0,
                                    subjectID: "same") { _ in
            await newGate.wait()
            return nil
        }
        #expect(replacement != first)
        try await waitUntil { newGate.entered }
        newGate.release()
        try await waitUntil { jobs.terminalIDs(.cameraPath).contains(replacement) }
        #expect(jobs.hasLiveTask(kind: .cameraPath))
        oldGate.release()
        try await finish(jobs)
        #expect(!jobs.hasLiveTask(kind: .cameraPath))
        #expect(jobs.busyProjectIDs.isEmpty)
        #expect(!jobs.items.contains { $0.id == first })
        #expect(jobs.latest(.cameraPath, subjectID: "same")?.id == replacement)
        #expect(jobs.completionRevision(.cameraPath) == 2)
        #expect(jobs.completionRevision(.cameraPath, successfulOnly: true) == 1)
    }

    @Test func publishingRemainsBusyAfterStopAndDismissUntilTaskExits() async throws {
        let store = makeStore()
        let gate = Gate()
        defer { gate.release() }
        let id = store.jobs.start(.instagramPublish, title: "Publish", project: nil, profileGeneration: 0,
                                  subjectID: "publish") { _ in
            await gate.wait()
            return .instagramPublished(permalink: nil)
        }
        try await waitUntil { gate.entered }
        store.jobs.cancel(id)
        store.jobs.dismiss(id)
        #expect(store.jobs.items.isEmpty)
        #expect(store.isPublishingToInstagram)
        gate.release()
        try await finish(store.jobs)
        #expect(!store.isPublishingToInstagram)
        #expect(store.jobs.items.isEmpty)
        #expect(store.jobs.reviewQueue.isEmpty)
    }

    @Test func emptySearchPostsNoticeWithoutReplacingTheGridResult() async throws {
        let store = makeStore()
        let old = store.jobs.start(.imageSearch, title: "Previous search", project: nil, profileGeneration: 0) { _ in
            .imageSearch(query: "fighter", paths: ["/tmp/fighter.png"], folder: [])
        }
        try await finish(store.jobs)
        let empty = store.jobs.start(.imageSearch, title: "Empty search", project: nil, profileGeneration: 0) { _ in
            throw AppJobEmptyResult(message: "No tagged images matched that request.")
        }
        try await finish(store.jobs)
        let latest = store.jobs.latestFinished(.imageSearch, projectID: nil)
        #expect(latest?.id == empty)
        #expect(latest?.status == .done)
        #expect(latest?.result == nil)
        #expect(latest?.statusLine == "No tagged images matched that request.")
        #expect(!store.jobs.items.contains { $0.id == old || $0.id == empty })
        #expect(store.jobs.reviewQueue.isEmpty)
        #expect(store.currentError == nil)
        #expect(store.currentNotice?.message == "No tagged images matched that request.")
    }

    @Test func historyIsBoundedWithoutRemovingRunningWork() async throws {
        let jobs = AppJobs()
        let gate = Gate()
        defer { gate.release() }
        let running = jobs.start(.mapSpeakers, title: "Long run", project: nil, profileGeneration: 0) { _ in
            await gate.wait()
            return nil
        }
        var finished: [UUID] = []
        for index in 0..<25 {
            let id = jobs.start(.resourceExport, title: "Export \(index)", project: nil, profileGeneration: 0) { _ in
                .resourceExport(url: URL(fileURLWithPath: "/tmp/result.zip"))
            }
            finished.append(id)
            try await waitUntil { !jobs.hasLiveTask(kind: .resourceExport) }
        }
        #expect(jobs.running.map(\.id) == [running])
        #expect(jobs.items.count == AppJobs.finishedLimit + 1)
        #expect(jobs.awaitingReview.map(\.id) == Array(finished.suffix(AppJobs.finishedLimit)))
        #expect(jobs.reviewQueue == Array(finished.suffix(AppJobs.finishedLimit)))
        #expect(jobs.terminalIDs(.resourceExport).count == AppJobs.finishedLimit)
        for id in finished { jobs.markReviewed(id) }
        #expect(jobs.items.map(\.id) == [running])
        #expect(jobs.reviewQueue.isEmpty)
        gate.release()
        try await finish(jobs)
        #expect(jobs.items.isEmpty)
        for _ in 0..<25 {
            jobs.start(.cameraPath, title: "Automatic", project: nil, profileGeneration: 0) { _ in nil }
            try await finish(jobs)
        }
        #expect(jobs.items.isEmpty)
        #expect(jobs.terminalIDs(.cameraPath).count == AppJobs.finishedLimit)
    }

    @Test func consumingSearchDoesNotExposeAnOlderResult() async throws {
        let jobs = AppJobs()
        jobs.start(.imageSearch, title: "Old", project: nil, profileGeneration: 0) { _ in
            .imageSearch(query: "old", paths: ["/tmp/old.png"], folder: [])
        }
        try await finish(jobs)
        let newest = jobs.start(.imageSearch, title: "New", project: nil, profileGeneration: 0) { _ in
            .imageSearch(query: "new", paths: ["/tmp/new.png"], folder: [])
        }
        try await finish(jobs)
        jobs.markReviewed(newest)
        #expect(!jobs.items.contains { $0.id == newest })
        #expect(jobs.latestFinished(.imageSearch, projectID: nil)?.id == newest)
        #expect(jobs.latestFinished(.imageSearch, projectID: nil)?.reviewed == true)
        #expect(jobs.latestFinished(.imageSearch, projectID: nil)?.result == nil)
    }

    @Test func progressMarkersNeverReachDisplayLogs() async throws {
        let store = makeStore()
        store.appendLog(\.pipelineLog, ["PROGRESS:0.25", "Visible\nPROGRESS:0.5"])
        let relay = LogRelay { lines in store.appendLog(\.pipelineLog, lines) }
        relay.post("PROGRESS:0.75")
        relay.post("Done")
        relay.flush()
        store.recordUnifiedLog(channel: "app", text: "PROGRESS:1")
        #expect(store.pipelineLog == ["Visible", "Done"])
        #expect(!store.unifiedLog.contains { $0.text.contains("PROGRESS:") })
        store.jobs.start(.cameraPath, title: "Progress", project: nil, profileGeneration: 0) { log in
            log("PROGRESS:0.5")
            log("Camera path saved.")
            return nil
        }
        try await finish(store.jobs)
        #expect(store.jobs.latest(.cameraPath)?.statusLine == "Camera path saved.")
        #expect(!store.unifiedLog.contains { $0.text.contains("PROGRESS:") })
    }
}
