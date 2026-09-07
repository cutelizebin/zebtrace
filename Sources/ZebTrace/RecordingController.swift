import AVFoundation
import Foundation
import ZebTraceCore

@MainActor
final class RecordingController {
    enum Phase { case idle, starting, recording, stopping, failed }
    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    private(set) var lastDirectory: URL?
    private var describeLastError: (() -> String)?
    var lastError: String? { describeLastError?() }
    private(set) var activity: [AudioSource: SourceActivity] = [:]
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    /// Only a successful, explicit Pause and Save may trigger optional analysis.
    var onSaved: ((URL) -> Void)?
    private let recordingLocation: RecordingLocation
    private let preferences: RecordingPreferences
    private let system: AudioCapturing = SystemAudioCapture()
    private let microphone: AudioCapturing = MicrophoneCapture()
    private var pipeline: RecordingPipeline?
    private var attempt: UUID?
    private var stopCompletions: [() -> Void] = []
    private var notifySavedAfterStop = false

    var canStartRecording: Bool { phase == .idle || phase == .failed }

    init(recordingLocation: RecordingLocation, preferences: RecordingPreferences) {
        self.recordingLocation = recordingLocation
        self.preferences = preferences
    }

    func start() {
        guard canStartRecording else { return }
        do { _ = try recordingLocation.prepareForRecording() }
        catch {
            fail { error.localizedDescription }
            return
        }
        let currentAttempt = UUID()
        let chunkDuration = preferences.segmentLength.duration
        attempt = currentAttempt
        describeLastError = nil
        activity = [:]
        phase = .starting
        onChange?()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
            default: allowed = false
            }
            guard self.attempt == currentAttempt else { return }
            guard allowed else {
                self.fail { L10n.string("controller.error.permission") }
                return
            }
            do {
                // Permission dialogs may stay open while a selected disk goes offline.
                let recordingRoot = try self.recordingLocation.prepareForRecording()
                let pipeline = try RecordingPipeline(root: recordingRoot, chunkDuration: chunkDuration) { [weak self] error in
                    Task { @MainActor in
                        guard self?.attempt == currentAttempt else { return }
                        self?.fail { L10n.string("controller.error.write", error.localizedDescription) }
                    }
                }
                self.pipeline = pipeline
                self.lastDirectory = pipeline.directory
                let captureError: (Error) -> Void = { [weak self] error in
                    Task { @MainActor in
                        guard self?.attempt == currentAttempt else { return }
                        self?.fail { L10n.string("controller.error.capture", error.localizedDescription) }
                    }
                }
                // Start the microphone first: Bluetooth inputs can change the output
                // format when opened. Build the system tap against that final format.
                try self.microphone.start(onBuffer: { buffer, time in
                    pipeline.append(buffer, source: .microphone, hostTime: time)
                }, onError: captureError)
                try self.system.start(onBuffer: { buffer, time in
                    pipeline.append(buffer, source: .system, hostTime: time)
                }, onError: captureError)
                self.startedAt = Date()
                self.phase = .recording
                self.onChange?()
            } catch {
                self.fail { L10n.string("controller.error.start", error.localizedDescription) }
            }
        }
    }

    func stop(reason: String = "userPaused", failed: Bool = false, completion: (() -> Void)? = nil) {
        if let completion { stopCompletions.append(completion) }
        if phase == .stopping {
            if reason != "userPaused" || failed { notifySavedAfterStop = false }
            return
        }
        attempt = nil
        system.stop()
        microphone.stop()
        guard let pipeline else {
            phase = failed ? .failed : .idle
            startedAt = nil
            onChange?()
            completeStop()
            return
        }
        phase = .stopping
        notifySavedAfterStop = reason == "userPaused" && !failed
        onChange?()
        pipeline.finish(status: failed ? .failed : .completed, reason: reason) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.pipeline = nil
                self.startedAt = nil
                switch result {
                case .success(let directory):
                    self.lastDirectory = directory
                    self.phase = failed ? .failed : .idle
                case .failure(let error):
                    let message = { L10n.string("controller.error.finish", error.localizedDescription) }
                    self.describeLastError = message
                    self.phase = .failed
                    self.onError?(message())
                }
                let notifySaved = self.notifySavedAfterStop
                self.notifySavedAfterStop = false
                self.onChange?()
                self.completeStop()
                if case .success(let directory) = result, notifySaved {
                    self.onSaved?(directory)
                }
            }
        }
    }

    func tick() {
        guard phase == .recording, let pipeline, let startedAt else { return }
        activity = pipeline.snapshot()
        let now = Date()
        let lastMicrophoneBuffer = activity[.microphone]?.lastReceivedAt ?? startedAt
        if now.timeIntervalSince(startedAt) > 12 && now.timeIntervalSince(lastMicrophoneBuffer) > 12 {
            fail { L10n.string("controller.error.timeout") }
            return
        }
        // A system tap may stop delivering buffers while nothing is playing.
        // Waiting for playback is not evidence of a capture failure.
        onChange?()
    }

    private func fail(_ message: @escaping () -> String) {
        guard phase != .stopping else { return }
        describeLastError = message
        stop(reason: "captureFailed", failed: true)
        onError?(message())
    }

    private func completeStop() {
        let callbacks = stopCompletions
        stopCompletions = []
        callbacks.forEach { $0() }
    }
}
