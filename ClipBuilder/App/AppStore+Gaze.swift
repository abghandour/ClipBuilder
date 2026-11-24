import Foundation

extension AppStore {
    func measureGaze(video: VideoRecord) {
        guard let database, GazeAnalysis.supports(video) else { return }
        let generation = profileGeneration
        jobs.start(.gaze, title: "Measure gaze — \(video.filename)", project: activeProject,
                   profileGeneration: generation, subjectID: String(video.id)) { [self] log in
            // Synced rows are a receipt too. Never re-measure just because this
            // Mac has no local analysis_passes entry.
            if try await database.gazeMeasured(videoID: video.id, meterVersion: GazeMeter.meterVersion) {
                log("Gaze already measured")
                return nil
            }
            let recording = try await database.gazeRecording(videoID: video.id) ?? video
            let pass = try await database.startAnalysisPass(videoID: video.id, pass: .gaze,
                                                            version: GazeAnalysis.passVersion)
            do {
                let tiles = try await GazeAnalysis.measure(video: recording, log: log)
                try Task.checkCancellation()
                try await database.finishGazeMeasurement(pass, tiles: tiles)
                log("Gaze measured")
            } catch {
                try? await database.finishAnalysisPass(pass, status: error is CancellationError ? .cancelled : .failed)
                if let passes = try? await database.fetchAnalysisPasses(),
                   generation == profileGeneration, self.database === database { analysisPasses = passes }
                throw error
            }
            let passes = try await database.fetchAnalysisPasses()
            if generation == profileGeneration, self.database === database { analysisPasses = passes }
            return nil
        }
    }
}
