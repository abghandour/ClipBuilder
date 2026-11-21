import AVFoundation
import Observation

/// Records one voice-over take from the microphone while a button is held.
@MainActor @Observable
final class VoiceRecorder {
    enum Access: Equatable { case unknown, granted, denied, unavailable }

    private(set) var access = Access.unknown
    private(set) var isRecording = false
    /// 0...1, for the level meter.
    private(set) var level = 0.0
    private(set) var elapsed = 0.0
    /// Where on the reel the recording in progress started, for the lane.
    var startedAtReel: Double?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meter: Task<Void, Never>?

    /// A build without the usage text is killed by the system when it asks
    /// for the microphone, so it must never ask.
    static var hasUsageText: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }

    func refreshAccess() {
        guard Self.hasUsageText else { access = .unavailable; return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: access = .granted
        case .denied, .restricted: access = .denied
        default: access = .unknown
        }
    }

    /// Asks for the microphone the first time.
    func authorize() async -> Bool {
        refreshAccess()
        if access == .unknown {
            access = await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        }
        return access == .granted
    }

    /// Starts recording into `url` (AAC, mono, 48 kHz).
    func start(to url: URL) -> Bool {
        guard !isRecording, access == .granted else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            recorder.isMeteringEnabled = true
            guard recorder.record() else { return false }
            self.recorder = recorder
            isRecording = true
            elapsed = 0
            meter = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                    recorder.updateMeters()
                    // -50 dB and below reads as silence.
                    self.level = min(1, max(0, (Double(recorder.averagePower(forChannel: 0)) + 50) / 50))
                    self.elapsed = recorder.currentTime
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Stops and returns the file and its length; nil if nothing was recording.
    func stop() -> (url: URL, duration: Double)? {
        guard let recorder else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        meter?.cancel()
        meter = nil
        self.recorder = nil
        isRecording = false
        level = 0
        return (recorder.url, duration)
    }
}
