import AppKit
import AVFoundation
import SwiftUI
import ZebTraceAnalysis
import ZebTraceCore

enum LibraryText {
    static var locale: Locale { Locale(identifier: LanguagePreferences().resolvedLanguage().rawValue) }

    static func date(_ date: Date, time: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .long
        formatter.timeStyle = time ? .short : .none
        return formatter.string(from: date)
    }

    static func sectionDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func searchDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func duration(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(min(max(0, seconds), 31_536_000)) : 0
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    /// Segment positions belong to the session timeline, including small negative starts.
    static func offset(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let tenths = Int(min(abs(seconds), 31_536_000) * 10)
        let prefix = seconds < 0 ? "−" : ""
        return prefix + String(format: "%02d:%02d:%04.1f", tenths / 36000, tenths / 600 % 60,
                               Double(tenths % 600) / 10)
    }

    static func source(_ source: String) -> String {
        if source == "system" { return L10n.string("source.system") }
        if source == "microphone" { return L10n.string("source.microphone") }
        return source
    }
}

enum LibraryReviewState { case none, transcript, complete, unavailable }

struct LibrarySession: Identifiable {
    var id: String { directory.standardizedFileURL.path }
    let directory: URL
    let sessionID: UUID
    let startedAt: Date
    let duration: Double
    let recordingStatus: String
    let reviewState: LibraryReviewState
    let summaryPreview: String
    let sources: [String]
    let catalogRecording: LibraryRecording

    init(_ recording: LibraryRecording) {
        catalogRecording = recording
        directory = recording.directory
        sessionID = recording.id
        startedAt = recording.startedAt
        duration = recording.durationSeconds
        recordingStatus = recording.recordingStatus
        summaryPreview = recording.summaryPreview
        sources = (recording.hasSystemAudio ? ["system"] : []) + (recording.hasMicrophone ? ["microphone"] : [])
        switch recording.resultStatus {
        case .none: reviewState = .none
        case .transcriptOnly: reviewState = .transcript
        case .ready: reviewState = .complete
        case .unavailable: reviewState = .unavailable
        }
    }
}

struct LibraryAudioClip: Identifiable, Hashable {
    var id: String { url.standardizedFileURL.path }
    let url: URL
    let source: String
    let filename: String
    let startOffset: Double
    let duration: Double
    let playable: Bool
}

struct LibraryDocument {
    let session: LibrarySession
    let summary: String?
    let transcript: String?
    let clips: [LibraryAudioClip]
    let notice: String?
    let entries: [LibraryTranscriptLine]

    init(_ details: LibraryRecordingDetails) {
        session = LibrarySession(details.recording)
        summary = details.summary
        transcript = details.transcript
        notice = details.warning
        entries = details.entries
        clips = details.chunks.map {
            LibraryAudioClip(url: $0.url, source: $0.source, filename: $0.id,
                             startOffset: $0.startOffsetSeconds, duration: $0.durationSeconds,
                             playable: $0.finalized)
        }
    }
}

enum LibraryReadingTab: String, CaseIterable { case summary, transcript }

/// Plays only an explicitly selected, catalog-validated local segment. No mixing or autoplay.
@MainActor
final class LibraryAudioPlayer: ObservableObject {
    @Published private(set) var clip: LibraryAudioClip?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var error: String?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var generation = UUID()

    var duration: Double { max(0, clip?.duration ?? 0) }

    func toggle(_ clip: LibraryAudioClip) {
        guard clip.playable else { return }
        if self.clip?.id == clip.id, let player {
            if isPlaying { player.pause(); isPlaying = false }
            else {
                if elapsed >= max(0, duration - 0.1) { seek(to: 0) }
                player.play()
                isPlaying = true
            }
            return
        }
        stop()
        self.clip = clip
        let current = generation
        let item = AVPlayerItem(url: clip.url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? L10n.string("library.audio.error")
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.error = message
                self.isPlaying = false
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
                                                       queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.elapsed = max(0, seconds) }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                              object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.isPlaying = false
                self.elapsed = self.duration
            }
        }
        player.play()
        isPlaying = true
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, let player else { return }
        elapsed = min(max(0, seconds), duration)
        player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play(_ clip: LibraryAudioClip, atSessionTime seconds: Double) {
        guard clip.playable else { return }
        if self.clip?.id != clip.id { toggle(clip) }
        seek(to: seconds - clip.startOffset)
        player?.play()
        isPlaying = true
    }

    func stop() {
        generation = UUID()
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObserver = nil
        timeObserver = nil
        endObserver = nil
        player = nil
        clip = nil
        elapsed = 0
        isPlaying = false
        error = nil
    }
}
