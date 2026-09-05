import AVFoundation
import CoreAudio
import Foundation

enum CaptureFailure: LocalizedError {
    case operation(String, OSStatus)
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .operation(operation, status):
            return L10n.string("capture.error.operationFailed", L10n.string(operation), status)
        case let .message(key):
            return L10n.string(key)
        }
    }
}

func checkAudioStatus(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CaptureFailure.operation(operation, status) }
}

func capturePropertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

func captureDefaultDevice(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
    var address = capturePropertyAddress(selector)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try checkAudioStatus(
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device),
        "capture.operation.readDefaultDevice"
    )
    guard device != kAudioObjectUnknown else {
        throw CaptureFailure.message("capture.error.noDefaultDevice")
    }
    return device
}

func captureDeviceSampleRate(_ device: AudioObjectID) throws -> Float64 {
    var address = capturePropertyAddress(kAudioDevicePropertyNominalSampleRate)
    var sampleRate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    try checkAudioStatus(
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &sampleRate),
        "capture.operation.readSampleRate"
    )
    return sampleRate
}

func captureDeviceIsAlive(_ device: AudioObjectID) throws -> Bool {
    var address = capturePropertyAddress(kAudioDevicePropertyDeviceIsAlive)
    var alive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try checkAudioStatus(
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive),
        "capture.operation.readAvailability"
    )
    return alive != 0
}

/// Property callbacks and removal use the same queue and block identity.
final class CapturePropertyObservation {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var isInstalled = false

    init(object: AudioObjectID, selector: AudioObjectPropertySelector, changed: @escaping () -> Void) throws {
        self.object = object
        address = capturePropertyAddress(selector)
        block = { _, _ in changed() }
        try checkAudioStatus(
            AudioObjectAddPropertyListenerBlock(object, &address, .main, block),
            "capture.operation.observeChanges"
        )
        isInstalled = true
    }

    func invalidate() {
        guard isInstalled else { return }
        isInstalled = false
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }

    deinit { invalidate() }
}

/// Makes a deep copy before HAL/AVAudioEngine recycle their callback memory.
/// Empty callback payloads have no samples to persist and return nil.
func copyCaptureBuffer(
    _ source: UnsafePointer<AudioBufferList>,
    format: AVAudioFormat,
    frameLength: AVAudioFrameCount? = nil
) throws -> AVAudioPCMBuffer? {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source))
    guard let first = buffers.first, first.mDataByteSize > 0 else { return nil }
    let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
    guard bytesPerFrame > 0, first.mDataByteSize % bytesPerFrame == 0 else {
        throw CaptureFailure.message("capture.error.invalidBufferSize")
    }
    let frames = frameLength ?? AVAudioFrameCount(first.mDataByteSize / bytesPerFrame)
    guard frames > 0 else { return nil }
    guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
        throw CaptureFailure.message("capture.error.bufferAllocation")
    }
    copy.frameLength = frames
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard destination.count == buffers.count else {
        throw CaptureFailure.message("capture.error.channelLayoutChanged")
    }
    for index in buffers.indices {
        let input = buffers[index]
        let output = destination[index]
        guard input.mNumberChannels == output.mNumberChannels,
              input.mDataByteSize >= output.mDataByteSize,
              let inputData = input.mData,
              let outputData = output.mData else {
            throw CaptureFailure.message("capture.error.incompleteSamples")
        }
        memcpy(outputData, inputData, Int(output.mDataByteSize))
    }
    return copy
}
