import SwiftUI
import ZebTraceCore

/// One explicitly chosen source and segment, with transport always in the same place.
/// Source changes never start playback; transcript links share this same player.
@MainActor
struct RecordingLibraryPlaybackBar: View {
    @ObservedObject var player: LibraryAudioPlayer
    let document: LibraryDocument
    let disabled: Bool
    @State private var selectedID = ""
    @State private var pendingSeek = 0.0

    private var selection: LibraryAudioClip? {
        if let clip = player.clip, document.clips.contains(where: { $0.id == clip.id }) { return clip }
        return document.clips.first { $0.id == selectedID }
            ?? document.clips.first { $0.source == "microphone" && $0.playable }
            ?? document.clips.first { $0.playable }
            ?? document.clips.first
    }
    private var sources: [String] {
        Array(Set(document.clips.map(\.source))).sorted {
            if $0 == "microphone" { return true }
            if $1 == "microphone" { return false }
            return $0 < $1
        }
    }
    private var isLoaded: Bool { selection != nil && player.clip?.id == selection?.id }
    private var elapsed: Double { isLoaded ? player.elapsed : pendingSeek }
    private var duration: Double { max(0, selection?.duration ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 14) {
                Button {
                    if let selection {
                        if !isLoaded, pendingSeek > 0 {
                            player.play(selection, atSessionTime: selection.startOffset + pendingSeek)
                        } else { player.toggle(selection) }
                    }
                } label: {
                    Image(systemName: isLoaded && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string(isLoaded && player.isPlaying ? "library.audio.pause" : "library.audio.play"))
                .help(L10n.string(isLoaded && player.isPlaying ? "library.audio.pause" : "library.audio.play"))
                .disabled(disabled || selection?.playable != true)

                VStack(spacing: 3) {
                    Slider(value: Binding(get: { min(duration, elapsed) }, set: {
                        if isLoaded { player.seek(to: $0) } else { pendingSeek = $0 }
                    }),
                           in: 0...max(0.001, duration))
                        .controlSize(.mini).disabled(disabled || selection?.playable != true)
                        .accessibilityLabel(L10n.string("library.audio.position"))
                    HStack {
                        Text(LibraryText.duration(elapsed))
                        Spacer()
                        Text(LibraryText.duration(duration))
                    }
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(minWidth: 75)

                Menu {
                    ForEach(sources, id: \.self) { source in
                        let clips = document.clips.filter { $0.source == source }
                        if clips.count == 1, let clip = clips.first {
                            clipButton(clip, title: LibraryText.source(source))
                        } else {
                            Menu(LibraryText.source(source)) {
                                ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                                    clipButton(clip, title: L10n.string("library.audio.segment", index + 1) + " · " +
                                               LibraryText.offset(clip.startOffset) + " – " +
                                               LibraryText.offset(clip.startOffset + clip.duration))
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: selection?.source == "system" ? "speaker.wave.2" : "mic")
                        Text(selection.map { LibraryText.source($0.source) } ?? L10n.string("library.audio.title"))
                            .lineLimit(1)
                    }.font(.system(size: 12))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(disabled)
                .help(L10n.string("library.design.audioSource"))
                .accessibilityLabel(L10n.string("library.design.audioSource"))
            }
            if let clip = selection, document.clips.filter({ $0.source == clip.source }).count > 1 {
                Text(L10n.string("library.design.segmentRange", LibraryText.offset(clip.startOffset),
                                 LibraryText.offset(clip.startOffset + clip.duration)))
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 46)
            }
            if let error = player.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: 740)
        .padding(.horizontal, 26).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .onChange(of: player.clip?.id) { _, value in
            if let value { selectedID = value }
        }
    }

    private func clipButton(_ clip: LibraryAudioClip, title: String) -> some View {
        Button {
            if selection?.id != clip.id {
                player.stop()
                selectedID = clip.id
                pendingSeek = 0
            }
        } label: {
            if selection?.id == clip.id { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }.disabled(!clip.playable)
    }
}
