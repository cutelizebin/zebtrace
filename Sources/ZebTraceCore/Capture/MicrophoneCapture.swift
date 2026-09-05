import AVFoundation
import CoreAudio
import Foundation

/// Captures the current default microphone. Obtain microphone permission in the
/// app before start(). Samples are owned copies delivered on AVAudioEngine's
/// callback queue; the handler must enqueue work without performing disk I/O.
public final class MicrophoneCapture: AudioCapturing {
    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var observations: [CapturePropertyObservation] = []
    private var sessionID: UUID?
    private var errorHandler: ((Error) -> Void)?

    public init() {}

    public func start(onBuffer: @escaping AudioSampleHandler, onError: @escaping (Error) -> Void) throws {
        precondition(Thread.isMainThread, "Start audio capture on the main thread.")
        guard sessionID == nil else {
            throw CaptureFailure.message("capture.error.microphoneAlreadyRunning")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CaptureFailure.message("capture.error.microphonePermission")
        }
        let session = UUID()
        sessionID = session
        errorHandler = onError

        do {
            let device = try captureDefaultDevice(kAudioHardwarePropertyDefaultInputDevice)
            guard try captureDeviceIsAlive(device) else {
                throw CaptureFailure.message("capture.error.microphoneUnavailable")
            }
            let sampleRate = try captureDeviceSampleRate(device)
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            inputNode = input
            // AVAudioEngine documents hardware availability on the input scope.
            // A usable output format alone does not establish that input is enabled.
            let hardwareFormat = input.inputFormat(forBus: 0)
            guard hardwareFormat.sampleRate.isFinite, hardwareFormat.sampleRate > 0,
                  hardwareFormat.channelCount > 0 else {
                throw CaptureFailure.message("capture.error.microphoneHardwareFormat")
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
                throw CaptureFailure.message("capture.error.microphoneFormat")
            }
            input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, when in
                do {
                    guard let copy = try copyCaptureBuffer(buffer.audioBufferList, format: buffer.format, frameLength: buffer.frameLength) else { return }
                    guard when.isHostTimeValid, when.hostTime != 0 else {
                        throw CaptureFailure.message("capture.error.microphoneTimestamp")
                    }
                    onBuffer(copy, when.hostTime)
                } catch {
                    self?.report(error, session: session)
                }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            try installObservations(device: device, sampleRate: sampleRate, format: format, session: session)
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        precondition(Thread.isMainThread, "Stop audio capture on the main thread.")
        cleanUp()
    }

    private func cleanUp() {
        sessionID = nil
        errorHandler = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine?.stop()
        if tapInstalled {
            inputNode?.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine?.reset()
        inputNode = nil
        engine = nil
    }

    private func installObservations(device: AudioObjectID, sampleRate: Float64, format: AVAudioFormat, session: UUID) throws {
        let changed: () -> Void = { [weak self] in
            guard let self, self.sessionID == session else { return }
            do {
                guard try captureDefaultDevice(kAudioHardwarePropertyDefaultInputDevice) == device,
                      try captureDeviceIsAlive(device),
                      try captureDeviceSampleRate(device) == sampleRate,
                      self.engine?.isRunning == true,
                      self.inputNode?.outputFormat(forBus: 0) == format else {
                    throw CaptureFailure.message("capture.error.microphoneChanged")
                }
            } catch {
                self.report(error, session: session)
            }
        }
        observations.append(try CapturePropertyObservation(
            object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice, changed: changed
        ))
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
            observations.append(try CapturePropertyObservation(object: device, selector: selector, changed: changed))
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in changed() }
    }

    private func report(_ error: Error, session: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionID == session else { return }
            let handler = self.errorHandler
            self.stop()
            handler?(error)
        }
    }

    deinit { cleanUp() }
}
