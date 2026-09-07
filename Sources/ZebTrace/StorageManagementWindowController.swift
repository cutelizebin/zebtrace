import AppKit
import SwiftUI
import ZebTraceAnalysis
import ZebTraceCore

@MainActor
final class StorageManagementWindowController: NSWindowController {
    private let model: StorageManagementModel
    init(location: RecordingLocation, chooseFolder: @escaping () -> Void, manageModels: @escaping () -> Void,
         cleanup: @escaping (Bool, Bool) -> Void, languageChanged: @escaping () -> Void) {
        model = StorageManagementModel(location: location, chooseFolder: chooseFolder, manageModels: manageModels,
                                       cleanup: cleanup, languageChanged: languageChanged)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 650),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 620, height: 520)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: StorageManagementView(model: model))
        window.setContentSize(NSSize(width: 720, height: 650))
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func present() {
        window?.title = L10n.string("storage.title")
        reload(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func reload() { model.reload() }
}

@MainActor
private final class StorageManagementModel: ObservableObject {
    struct Folder: Identifiable {
        var id: String { url.path }
        let url: URL
        let count: Int
        let recordingBytes: Int64
        let modelBytes: Int64
        let generatedBytes: Int64
        let error: String?
    }
    @Published var folders: [Folder] = []
    @Published var scanning = false
    @Published var eraseRecordings = false
    @Published var language = LanguagePreferences().selection
    let location: RecordingLocation
    let chooseFolder: () -> Void
    let manageModels: () -> Void
    let cleanup: (Bool, Bool) -> Void
    let languageChanged: () -> Void
    private var scanTask: Task<Void, Never>?
    init(location: RecordingLocation, chooseFolder: @escaping () -> Void, manageModels: @escaping () -> Void,
         cleanup: @escaping (Bool, Bool) -> Void, languageChanged: @escaping () -> Void) {
        self.location = location; self.chooseFolder = chooseFolder; self.manageModels = manageModels
        self.cleanup = cleanup; self.languageChanged = languageChanged
    }
    func reload() {
        scanTask?.cancel(); scanning = true
        let roots = location.knownDirectories
        scanTask = Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                roots.map { root -> Folder in
                    do {
                        let info = try ManagedStorage.inventory(root: root)
                        return Folder(url: root, count: info.recordingCount, recordingBytes: info.recordingBytes,
                                      modelBytes: info.modelBytes, generatedBytes: info.generatedBytes, error: nil)
                    } catch {
                        return Folder(url: root, count: 0, recordingBytes: 0, modelBytes: 0, generatedBytes: 0, error: error.localizedDescription)
                    }
                }
            }.value
            guard !Task.isCancelled else { return }
            self.folders = result; self.scanning = false
        }
    }
}

private struct StorageManagementView: View {
    @ObservedObject var model: StorageManagementModel
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("storage.title")).font(.largeTitle.bold())
                    Text(L10n.string("storage.subtitle")).foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(L10n.string("storage.location")).font(.headline)
                            Spacer()
                            Button(L10n.string("menu.chooseLocation"), action: model.chooseFolder)
                        }
                        Text(model.location.directory.path).textSelection(.enabled).font(.callout)
                        Text(L10n.string("storage.layout")).font(.callout).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Text(L10n.string("storage.files")).font(.headline)
                    if model.scanning { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(L10n.string("storage.refresh"), action: model.reload)
                    Button(L10n.string("storage.models"), action: model.manageModels)
                }
                ForEach(model.folders) { folder in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(folder.url == model.location.directory ? L10n.string("storage.current") : L10n.string("storage.previous"))
                                .font(.headline)
                            Spacer()
                            Button(L10n.string("storage.open")) { NSWorkspace.shared.open(folder.url) }
                        }
                        Text(folder.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let error = folder.error { Text(error).foregroundStyle(.orange).font(.callout) }
                        else {
                            Text(L10n.string("storage.usage", folder.count, bytes(folder.recordingBytes), bytes(folder.generatedBytes), bytes(folder.modelBytes)))
                                .font(.callout)
                        }
                    }.padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
                Picker(L10n.string("menu.language"), selection: $model.language) {
                    ForEach(AppLanguage.allCases, id: \.rawValue) { language in
                        Text(L10n.string(language.titleKey)).tag(language)
                    }
                }.onChange(of: model.language) { _, language in
                    LanguagePreferences().selection = language
                    model.languageChanged()
                }.frame(maxWidth: 340)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.string("storage.cleanup.section")).font(.headline)
                    Text(L10n.string("storage.cleanup.explanation")).font(.callout).foregroundStyle(.secondary)
                    Toggle(L10n.string("storage.cleanup.eraseToggle"), isOn: $model.eraseRecordings)
                    Text(L10n.string("storage.cleanup.trashNote")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(L10n.string("storage.cleanup.button")) { model.cleanup(false, model.eraseRecordings) }
                        Spacer()
                        Button(L10n.string("storage.uninstall.button"), role: .destructive) { model.cleanup(true, model.eraseRecordings) }
                    }
                }
            }.padding(26)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
