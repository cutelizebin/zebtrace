import AppKit
import SwiftUI
import ZebTraceAnalysis
import ZebTraceCore

@MainActor
struct RecordingLibrarySidebar: View {
    @ObservedObject var model: RecordingLibraryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.string("library.design.search"), text: $model.query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(L10n.string("library.search.accessibility"))
            }
            .font(.system(size: 13))
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)

            if let error = model.scanError {
                Label(L10n.string("library.folder.error"), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .help(error).padding(.horizontal, 14).padding(.bottom, 8)
            }
            List(selection: Binding<String?>(
                get: { model.selectedDirectory?.standardizedFileURL.path },
                set: { model.select($0.map { URL(fileURLWithPath: $0, isDirectory: true) }) }
            )) {
                ForEach(model.groups, id: \.day) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            RecordingLibraryRow(model: model, session: session)
                                .tag(session.id)
                                .contextMenu { RecordingLibrarySessionMenu(model: model, session: session) }
                        }
                    } header: {
                        Text(LibraryText.sectionDate(group.day))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary).textCase(nil)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.groups.isEmpty, !model.scanning {
                    VStack(spacing: 8) {
                        Image(systemName: model.query.isEmpty ? "waveform" : "magnifyingglass")
                            .font(.title2).foregroundStyle(.tertiary)
                        Text(model.query.isEmpty
                             ? L10n.string("library.empty.recordings")
                             : L10n.string("library.empty.search"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                }
            }
            HStack {
                Menu {
                    Button(L10n.string("library.modelsAndStorage"), action: model.actions.manageModels)
                    Button(L10n.string("library.cleanup"), action: model.actions.manageStorage)
                        .keyboardShortcut(",", modifiers: .command)
                    Button(L10n.string("menu.chooseLocation"), action: model.actions.chooseFolder)
                        .disabled(model.live.isRecording || !model.live.canToggleRecording || model.live.analysisBusy)
                    Divider()
                    Toggle(L10n.string("analysis.menu.automatic"), isOn: Binding(
                        get: { model.live.automaticallySummarize },
                        set: { model.actions.setAutomatic($0) }))
                        .disabled(!model.live.modelsReady || model.live.analysisBusy || model.live.isRecording)
                } label: {
                    Label(L10n.string("library.design.settings"), systemImage: "gearshape")
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer(minLength: 6)
                if model.scanning { ProgressView().controlSize(.mini) }
                Text(L10n.string("library.recordingCount", model.sessions.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.locale, LibraryText.locale)
    }
}

@MainActor
private struct RecordingLibraryRow: View {
    @ObservedObject var model: RecordingLibraryModel
    let session: LibrarySession

    private var active: Bool {
        (model.live.isRecording && RecordingLibraryModel.same(model.live.recordingDirectory, session.directory)) ||
        (model.live.analysisBusy && RecordingLibraryModel.same(model.live.analysisDirectory, session.directory))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(LibraryText.time(session.startedAt))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Spacer(minLength: 5)
                if active {
                    Circle().fill(model.live.isRecording && RecordingLibraryModel.same(model.live.recordingDirectory, session.directory)
                                  ? Color.red : Color.accentColor).frame(width: 5, height: 5)
                }
                Text(LibraryText.duration(session.duration))
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(active || session.summaryPreview.isEmpty ? model.status(for: session) : session.summaryPreview)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(2).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityValue(model.status(for: session))
    }
}

/// Secondary actions are shared by the native toolbar and the list context menu.
@MainActor
struct RecordingLibraryActionsMenu: View {
    @ObservedObject var model: RecordingLibraryModel

    var body: some View {
        Menu {
            if let session = model.selectedSession {
                if model.selectedIsProcessing {
                    Button(L10n.string("analysis.menu.cancel"), action: model.actions.cancelAnalysis)
                        .disabled(!model.live.analysisCanCancel)
                } else {
                    Button(session.reviewState == .none ? L10n.string("library.review.generate")
                           : L10n.string("library.review.regenerate"), action: model.analyzeSelection)
                        .disabled(!model.canAnalyzeSelection)
                }
                Button(L10n.string("analysis.reader.copy")) {
                    guard let text = selectedText else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }.disabled(selectedText == nil)
                Divider()
                RecordingLibrarySessionMenu(model: model, session: session)
                Divider()
            }
            Button(L10n.string("library.refresh"), action: model.reload)
                .keyboardShortcut("r", modifiers: [.command, .shift])
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 17))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L10n.string("library.recording.actions"))
        .accessibilityLabel(L10n.string("library.recording.actions"))
    }

    private var selectedText: String? {
        model.readingTab == .summary
            ? (model.selectedIsProcessing ? nil : model.document?.summary)
            : model.document?.transcript
    }
}

@MainActor
private struct RecordingLibrarySessionMenu: View {
    @ObservedObject var model: RecordingLibraryModel
    let session: LibrarySession

    private var inUse: Bool {
        ((model.live.isRecording || !model.live.canToggleRecording) &&
            RecordingLibraryModel.same(model.live.recordingDirectory, session.directory)) ||
            (model.live.analysisBusy && RecordingLibraryModel.same(model.live.analysisDirectory, session.directory))
    }

    var body: some View {
        Button(L10n.string("library.openFolder")) { NSWorkspace.shared.open(session.directory) }
        Divider()
        Button(L10n.string("library.deleteGenerated"), role: .destructive) {
            model.player.stop()
            model.actions.deleteGeneratedContent(session.directory)
        }.disabled(inUse || session.reviewState == .none)
        Button(L10n.string("library.deleteRecording"), role: .destructive) {
            model.player.stop()
            model.actions.deleteRecording(session.directory)
        }.disabled(inUse)
    }
}

@MainActor
struct RecordingLibraryDetailView: View {
    @ObservedObject var model: RecordingLibraryModel

    var body: some View {
        Group {
            if let session = model.selectedSession {
                detail(session)
            } else if model.loadingDetail {
                ProgressView(L10n.string("library.detail.loading"))
            } else if let error = model.detailError {
                empty(symbol: "exclamationmark.triangle", title: L10n.string("library.detail.unavailable"),
                      detail: L10n.string("library.detail.unavailableHint")).help(error)
            } else {
                empty(symbol: "waveform", title: L10n.string("library.detail.emptyTitle"),
                      detail: L10n.string("library.detail.emptyHint"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.locale, LibraryText.locale)
    }

    private func detail(_ session: LibrarySession) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(LibraryText.date(session.startedAt, time: true))
                        .font(.system(size: 21, weight: .semibold)).textSelection(.enabled)
                    Text(LibraryText.duration(session.duration) + " · " + model.status(for: session))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Picker(L10n.string("library.reading.tabs"), selection: $model.readingTab) {
                    Text(L10n.string("analysis.reader.summary")).tag(LibraryReadingTab.summary)
                    Text(L10n.string("analysis.reader.transcript")).tag(LibraryReadingTab.transcript)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.regular).fixedSize()
            }
            .frame(maxWidth: 740, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 18)
            .frame(maxWidth: .infinity)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.selectedIsProcessing { processing }
                    if let document = model.document {
                        if document.notice != nil { unavailableResult(document.notice) }
                        reading(document)
                    } else if model.loadingDetail {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if let error = model.detailError {
                        unavailableResult(error)
                    }
                }
                .frame(maxWidth: 740, alignment: .leading)
                .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
            .id(session.id + model.readingTab.rawValue)
            if let document = model.document, !document.clips.isEmpty {
                Divider().opacity(0.5)
                RecordingLibraryPlaybackBar(player: model.player, document: document,
                                            disabled: model.live.isRecording)
                    .id(session.id)
            }
        }
    }

    /// The window already supplies date/title/context. Keep exported Markdown
    /// complete while avoiding a second document header in the reader.
    private func summaryBody(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.hasPrefix("# ") == true,
              let start = lines.firstIndex(where: { $0.hasPrefix("## ") }) else { return markdown }
        return lines[start...].joined(separator: "\n")
    }

    private var processing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.live.analysisStatus, systemImage: "sparkles").font(.subheadline.weight(.medium))
            if let fraction = model.live.analysisFraction, fraction.isFinite {
                ProgressView(value: min(1, max(0, fraction)))
            } else { ProgressView().controlSize(.small) }
            Text(L10n.string("library.review.progressHint"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func reading(_ document: LibraryDocument) -> some View {
        if model.readingTab == .summary {
            if model.selectedIsProcessing {
                if document.transcript != nil {
                    Button(L10n.string("library.review.savedTranscript")) { model.readingTab = .transcript }
                }
            } else if let summary = document.summary {
                RecordingLibraryMarkdown(markdown: summaryBody(summary))
                    .environment(\.openURL, OpenURLAction { url in
                        if url.lastPathComponent == "transcript.md" {
                            model.readingTab = .transcript
                            return .handled
                        }
                        return .discarded
                    })
                Text(L10n.string("review.summary.note"))
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 20)
            } else {
                VStack(alignment: .leading, spacing: 13) {
                    Image(systemName: "text.bubble").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(document.transcript == nil
                         ? L10n.string("library.review.emptyTitle")
                         : L10n.string("library.review.partialTitle"))
                        .font(.title3.weight(.semibold))
                    Text(model.selectedIsRecording
                         ? L10n.string("library.review.recordingHint")
                         : L10n.string("library.review.localHint"))
                        .foregroundStyle(.secondary)
                    Button(L10n.string("library.review.start"), action: model.analyzeSelection)
                        .buttonStyle(.borderedProminent).disabled(!model.canAnalyzeSelection)
                    if document.transcript != nil {
                        Button(L10n.string("library.review.savedTranscript")) { model.readingTab = .transcript }
                            .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
            }
        } else if !document.entries.isEmpty {
            transcript(document.entries)
        } else if let transcript = document.transcript {
            RecordingLibraryMarkdown(markdown: transcript)
        } else {
            Text(L10n.string("library.transcript.empty"))
                .foregroundStyle(.secondary).padding(.vertical, 24)
        }
    }

    private func transcript(_ entries: [LibraryTranscriptLine]) -> some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            Text(L10n.string("library.transcript.timingHint"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(entries) { line in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Button { model.play(line) } label: {
                            Label(LibraryText.offset(line.start), systemImage: "play.circle")
                                .monospacedDigit()
                        }
                        .buttonStyle(.link).disabled(!model.clipAvailable(for: line))
                        Text(LibraryText.source(line.source)).foregroundStyle(.secondary)
                        if line.possibleDuplicateOf != nil {
                            Text(L10n.string("library.transcript.duplicate")).foregroundStyle(.secondary)
                        }
                    }.font(.caption)
                    Text(line.text).font(.system(size: 14)).lineSpacing(4)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func unavailableResult(_ diagnostic: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.string("library.review.unmatched"), systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.orange)
            if let diagnostic {
                DisclosureGroup(L10n.string("library.diagnostics")) {
                    Text(diagnostic).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.font(.caption)
            }
        }
    }

    private func empty(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(40)
    }
}
