import AppKit
import SwiftUI
import ZebTraceCore

@MainActor
struct ModelManagementActions {
    var prepare: () -> Void = {}
    var selectASRModel: (String) -> Void = { _ in }
    var cancelAndRelease: () -> Void = {}
    var removeModel: (String) -> Void = { _ in }
    var removeAllModels: () -> Void = {}
    var openModelFolder: () -> Void = {}
    var manageStorage: () -> Void = {}
}

struct ModelManagementItem: Identifiable {
    /// The catalog filename, passed unchanged to removeModel.
    var id: String
    var name: String
    /// Supported roles are asr, summary, and vad.
    var role: String
    var downloadBytes: Int64
    /// Bytes on disk, including an incomplete download when applicable.
    var installedBytes: Int64
    /// A verified local model file; this does not mean it is loaded in memory.
    var isReady: Bool
    var license: String
    var path: String = ""
}

struct ModelManagementState {
    var models: [ModelManagementItem] = []
    var isBusy = false
    var status = ""
    var fraction: Double? = nil
    /// True while an inference helper is running or still exiting.
    var runtimeActive = false
    var modelDirectoryPath = ""
    var canModifyModels = true
    var canCancel = false
    var selectedASRFilename = ""
    /// Readiness of the selected ASR, summarizer, and auxiliary assets only.
    var selectedModelsReady = false
}

/// Displays state supplied by the owner. Opening this window never starts inference.
@MainActor
final class ModelManagementWindowController: NSWindowController {
    private let model: ModelManagementViewModel

    init(actions: ModelManagementActions) {
        model = ModelManagementViewModel(actions: actions)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 560, height: 520)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: ModelManagementView(model: model))
        window.title = L10n.string("modelManager.title")
        window.setContentSize(NSSize(width: 680, height: 740))
        window.center()
    }

    required init?(coder: NSCoder) { return nil }

    func present(state: ModelManagementState) {
        refresh(state: state)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func refresh(state: ModelManagementState) {
        model.state = state
        window?.title = L10n.string("modelManager.title")
    }
}

private enum ModelManagementFormat {

    static func bytes(_ value: Int64) -> String {
        let count = Double(max(0, value))
        let units = ["B", "KB", "MB", "GB", "TB"]
        var scaled = count
        var unit = 0
        while scaled >= 1000, unit < units.count - 1 { scaled /= 1000; unit += 1 }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: LanguagePreferences().resolvedLanguage().rawValue)
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = scaled < 10 && unit > 0 ? 2 : 0
        return "\(formatter.string(from: NSNumber(value: scaled)) ?? String(Int(scaled))) \(units[unit])"
    }
}

@MainActor
private final class ModelManagementViewModel: ObservableObject {
    @Published var state = ModelManagementState()
    let actions: ModelManagementActions

    init(actions: ModelManagementActions) { self.actions = actions }

    var canModify: Bool { state.canModifyModels && !state.isBusy && !state.runtimeActive }
    var hasFiles: Bool { state.models.contains { $0.installedBytes > 0 || $0.isReady } }
    var ready: Bool { state.selectedModelsReady }
    var installedBytes: Int64 {
        state.models.reduce(0) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(max(0, item.installedBytes))
            return overflow ? Int64.max : sum
        }
    }

    func selection(for role: String) -> Binding<String> {
        Binding(get: {
            let choices = self.state.models.filter { $0.role == role }
            if role == "asr", choices.contains(where: { $0.id == self.state.selectedASRFilename }) {
                return self.state.selectedASRFilename
            }
            return choices.first?.id ?? ""
        }, set: { value in
            guard self.canModify, role == "asr",
                  self.state.models.contains(where: { $0.role == role && $0.id == value }) else { return }
            self.actions.selectASRModel(value)
        })
    }

}

@MainActor
private struct ModelManagementView: View {
    @ObservedObject var model: ModelManagementViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("modelManager.heading"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.string("modelManager.description"))
                        .font(.callout).foregroundStyle(.secondary)
                }

                runtimeCard

                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.string("modelManager.selection.title")).font(.headline)
                    Text(L10n.string("modelManager.selection.description"))
                        .font(.caption).foregroundStyle(.secondary)
                    modelGroup(role: "asr", title: L10n.string("modelManager.role.asr"), picker: true)
                    modelGroup(role: "summary", title: L10n.string("modelManager.role.summary"), picker: true)
                    modelGroup(role: "vad", title: L10n.string("modelManager.role.vad"), picker: false)
                }

                HStack(alignment: .center, spacing: 12) {
                    Button(L10n.string(model.ready ? "modelManager.download.ready" : "modelManager.download.prepare"), action: model.actions.prepare)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canModify || model.ready || model.state.models.isEmpty)
                    Text(L10n.string("modelManager.download.note"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                storageCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var runtimeCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L10n.string("modelManager.memory.title"), systemImage: "memorychip")
                            .font(.headline)
                        Text(model.state.runtimeActive
                             ? L10n.string("modelManager.memory.active")
                             : L10n.string("modelManager.memory.idle"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button(model.state.isBusy
                           ? L10n.string("modelManager.cancel")
                           : L10n.string("modelManager.memory.release"),
                           action: model.actions.cancelAndRelease)
                        .disabled(!model.state.canCancel)
                }
                if !model.state.status.isEmpty {
                    Text(model.state.status).font(.callout).textSelection(.enabled)
                }
                if model.state.isBusy {
                    if let fraction = model.state.fraction, fraction.isFinite {
                        ProgressView(value: min(1, max(0, fraction)))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(L10n.string("modelManager.memory.note"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func modelGroup(role: String, title: String, picker: Bool) -> some View {
        let items = model.state.models.filter { $0.role == role }
        if !items.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if picker {
                        Picker(title, selection: model.selection(for: role)) {
                            ForEach(items) { item in Text(item.name).tag(item.id) }
                        }
                        .pickerStyle(.menu)
                        .disabled(!model.canModify || items.count < 2)
                        .accessibilityLabel(title)
                    } else {
                        Text(title).font(.headline)
                    }
                    ForEach(items) { item in
                        modelDetails(item, showsName: !picker || items.count > 1)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func modelDetails(_ item: ModelManagementItem, showsName: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsName { Text(item.name).font(.subheadline.weight(.medium)) }
            HStack(alignment: .center, spacing: 10) {
                Label(item.isReady ? L10n.string("modelManager.state.ready")
                      : item.installedBytes > 0 ? L10n.string("modelManager.state.partial")
                      : L10n.string("modelManager.state.missing"),
                      systemImage: item.isReady ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(item.isReady ? Color.green : Color.secondary)
                Spacer(minLength: 4)
                Text("\(ModelManagementFormat.bytes(item.downloadBytes)) · \(item.license)")
                    .foregroundStyle(.secondary)
                Button(L10n.string("modelManager.delete"), role: .destructive) { model.actions.removeModel(item.id) }
                    .disabled(!model.canModify || (item.installedBytes <= 0 && !item.isReady))
                    .help(L10n.string("modelManager.delete.help"))
                    .accessibilityLabel(L10n.string("modelManager.delete.accessibility", item.name))
            }
            .font(.caption)
            Text(L10n.string("modelManager.diskUsage", ModelManagementFormat.bytes(item.installedBytes)))
                .font(.caption).foregroundStyle(.secondary)
            if !item.path.isEmpty {
                Text(item.path).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle).help(item.path)
            }
        }
    }

    private var storageCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L10n.string("modelManager.storage.title"), systemImage: "internaldrive")
                        .font(.headline)
                    Spacer()
                    Text(ModelManagementFormat.bytes(model.installedBytes)).foregroundStyle(.secondary)
                }
                if !model.state.modelDirectoryPath.isEmpty {
                    Text(model.state.modelDirectoryPath).font(.caption.monospaced())
                        .textSelection(.enabled).foregroundStyle(.secondary)
                }
                Text(L10n.string("modelManager.storage.note"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(L10n.string("modelManager.folder.open"), action: model.actions.openModelFolder)
                    Button(L10n.string("modelManager.storage.manage"), action: model.actions.manageStorage)
                    Spacer(minLength: 0)
                    Button(L10n.string("modelManager.deleteAll"), role: .destructive,
                           action: model.actions.removeAllModels)
                        .disabled(!model.canModify || !model.hasFiles)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
