import AVFoundation
import CoreAudio
import Foundation

/// Captures the system's outgoing audio without changing the user's output device.
/// Call start/stop on the main thread. onBuffer runs on an audio callback queue and
/// must only enqueue work; onError runs on the main thread after capture stops.
@available(macOS 14.2, *)
public final class SystemAudioCapture: AudioCapturing {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var deviceStarted = false
    private var observations: [CapturePropertyObservation] = []
    private var sessionID: UUID?
    private var errorHandler: ((Error) -> Void)?
    private let callbackQueue = DispatchQueue(label: "zebtrace.capture.system", qos: .userInteractive)

    public init() {}

    public func start(onBuffer: @escaping AudioSampleHandler, onError: @escaping (Error) -> Void) throws {
        precondition(Thread.isMainThread, "Start audio capture on the main thread.")
        guard sessionID == nil else {
            throw CaptureFailure.message("capture.error.systemAlreadyRunning")
        }
        let session = UUID()
        sessionID = session
        errorHandler = onError

        do {
            let outputDevice = try captureDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
            let outputSampleRate = try captureDeviceSampleRate(outputDevice)
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = L10n.string("capture.name.systemAudio")
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try checkAudioStatus(AudioHardwareCreateProcessTap(description, &tapID), "capture.operation.createSystemTap")
            let format = try readTapFormat()

            // A tap-only private aggregate avoids adding microphone channels from
            // a duplex output device. Do not change the system's default routing.
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: L10n.string("capture.name.audioCapture"),
                kAudioAggregateDeviceUIDKey: "zebtrace.capture.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]],
                // Nonzero can make AudioDeviceStart wait for an app to play sound.
                kAudioAggregateDeviceTapAutoStartKey: false
            ]
            try checkAudioStatus(
                AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                "capture.operation.createCaptureDevice"
            )
            try checkAudioStatus(
                AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, callbackQueue) {
                    [weak self] _, input, inputTime, _, _ in
                    do {
                        guard let copy = try copyCaptureBuffer(input, format: format) else { return }
                        guard inputTime.pointee.mFlags.contains(.hostTimeValid), inputTime.pointee.mHostTime != 0 else {
                            throw CaptureFailure.message("capture.error.systemTimestamp")
                        }
                        onBuffer(copy, inputTime.pointee.mHostTime)
                    } catch {
                        self?.report(error, session: session)
                    }
                },
                "capture.operation.createSystemCallback"
            )
            try checkAudioStatus(AudioDeviceStart(aggregateID, ioProc), "capture.operation.startSystemRecording")
            deviceStarted = true
            try installObservations(outputDevice: outputDevice, sampleRate: outputSampleRate, format: format, session: session)
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
        if deviceStarted, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProc)
        }
        deviceStarted = false
        if let ioProc, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
        }
        ioProc = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func readTapFormat() throws -> AVAudioFormat {
        var address = capturePropertyAddress(kAudioTapPropertyFormat)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkAudioStatus(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description),
            "capture.operation.readSystemFormat"
        )
        guard description.mFormatID == kAudioFormatLinearPCM,
              description.mSampleRate > 0, description.mChannelsPerFrame > 0,
              description.mBytesPerFrame > 0,
              let format = AVAudioFormat(streamDescription: &description) else {
            throw CaptureFailure.message("capture.error.systemFormat")
        }
        return format
    }

    private func installObservations(outputDevice: AudioObjectID, sampleRate: Float64, format: AVAudioFormat, session: UUID) throws {
        let changed: () -> Void = { [weak self] in
            guard let self, self.sessionID == session else { return }
            do {
                guard try captureDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice) == outputDevice,
                      try captureDeviceIsAlive(outputDevice),
                      try captureDeviceSampleRate(outputDevice) == sampleRate,
                      try self.readTapFormat() == format else {
                    throw CaptureFailure.message("capture.error.systemChanged")
                }
            } catch {
                self.report(error, session: session)
            }
        }
        observations.append(try CapturePropertyObservation(
            object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, changed: changed
        ))
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
            observations.append(try CapturePropertyObservation(object: outputDevice, selector: selector, changed: changed))
        }
        observations.append(try CapturePropertyObservation(object: tapID, selector: kAudioTapPropertyFormat, changed: changed))
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
