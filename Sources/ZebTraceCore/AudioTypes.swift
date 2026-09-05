import AVFoundation

public enum AudioSource: String, Codable, CaseIterable {
    case system
    case microphone
}

/// The buffer owns its samples. The timestamp is the sample start in mach host-clock ticks.
public typealias AudioSampleHandler = (AVAudioPCMBuffer, UInt64) -> Void

/// Start/stop on the main thread. Delivery may occur on a background audio queue.
public protocol AudioCapturing: AnyObject {
    func start(onBuffer: @escaping AudioSampleHandler, onError: @escaping (Error) -> Void) throws
    func stop()
}
