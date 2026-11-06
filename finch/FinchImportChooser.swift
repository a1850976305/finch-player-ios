import SwiftUI
import TVCore

/// One row of the guided import chooser (Arcane "添加资源" reference): an
/// icon, a title, and a one-line hint of what to paste — no bare URL field
/// as the only import entry. Tapping a row opens the matching input: a URL
/// field, the file picker, or the .fwd checkbox list.
enum FinchURLImportKind: CaseIterable, Hashable {
    case subscription, rexComponent, rexSubscription, webHome, localFile, localFolder

    var title: String {
        switch self {
        case .subscription: return "TVBox 订阅"
        case .rexComponent: return "Rex 组件"
        case .rexSubscription: return "Rex 订阅"
        case .webHome: return "网页源"
        case .localFile: return "本地文件"
        case .localFolder: return "从文件夹导入"
        }
    }

    var hint: String {
        switch self {
        case .subscription: return "填配置地址，聚合多个站点"
        case .rexComponent: return "单个 .js 组件地址"
        case .rexSubscription: return "填 .fwd 清单地址，勾选导入"
        case .webHome: return "填 .html 网页源地址"
        case .localFile: return "py / js / TVBox 配置 / 网页源，可多选"
        case .localFolder: return "文件夹里的 .json / .py / .js 文件全部导入"
        }
    }

    /// Placeholder for the URL field. nil for rows that open no URL field.
    var placeholder: String? {
        switch self {
        case .subscription: return "https://…/subscription.json"
        case .rexComponent: return "https://…/component.js"
        case .rexSubscription: return "https://…/widgets.fwd"
        case .webHome: return "https://…/page.html"
        case .localFile, .localFolder: return nil
        }
    }

    /// The URL field is only for kinds that take an address.
    var takesURL: Bool { placeholder != nil }
}

/// A plain-language import summary: how many sources, which ones, and
/// which category they landed in — instead of silently returning.
enum FinchImportSummary {
    static func text(for sites: [Site]) -> String {
        let names = sites.map(\.name)
        let shown = names.prefix(3).joined(separator: "、")
        let categories = Array(Set(sites.map { FinchSourceCategory.derive(from: $0.name) }))
            .sorted { (FinchSourceCategory.ordered.firstIndex(of: $0) ?? 9) < (FinchSourceCategory.ordered.firstIndex(of: $1) ?? 9) }
            .map(\.title)
        var text = "已导入 \(sites.count) 个源"
        if !names.isEmpty { text += "：\(shown)\(names.count > 3 ? "等" : "")" }
        if !categories.isEmpty { text += "，已放入\(categories.joined(separator: "、"))分组" }
        return text
    }
}

/// The URL field for one import kind: paste the address, tap 导入, and see
/// a short summary of what arrived and where it landed.
struct FinchURLInputView: View {
    @Environment(Store.self) private var store
    let kind: FinchURLImportKind
    @State private var urlText = ""
    @State private var result: String?
    @State private var isImporting = false

    var body: some View {
        Form {
            Section {
                TextField(kind.placeholder ?? "地址", text: $urlText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("导入") { Task { await importURL() } }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
            } header: {
                Text(kind.title)
            } footer: {
                Text(kind.hint)
            }
            if isImporting {
                Section { ProgressView("正在导入…") }
            }
            if let result {
                Section {
                    Text(result)
                } header: {
                    Text("导入结果")
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func importURL() async {
        let address = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        isImporting = true
        result = nil
        defer { isImporting = false }
        do {
            switch kind {
            case .subscription:
                let before = Set(store.subscriptions.map(\.address))
                await store.importSubscription(address: address)
                if let error = store.importError {
                    result = error
                } else {
                    let added = store.subscriptions.filter { !before.contains($0.address) }
                        .compactMap { store.documents[$0.address]?.sites }.flatMap { $0 }
                    result = added.isEmpty
                        ? (store.notice ?? "已导入，没有新增源。")
                        : FinchImportSummary.text(for: added)
                }
            case .rexComponent, .webHome:
                guard let url = URL(string: address) else { throw FinchImportError.badURL }
                let data = try await Store.fetchBytes(from: url)
                var filename = url.lastPathComponent
                let wanted = kind == .rexComponent ? "js" : "html"
                if URL(string: filename)?.pathExtension.lowercased() != wanted {
                    filename = (filename.isEmpty ? "component" : filename) + "." + wanted
                }
                let sites = try await store.importDownloadedFile(data: data, filename: filename)
                result = sites.isEmpty ? "已导入，没有新增源（可能是重复导入）。" : FinchImportSummary.text(for: sites)
            case .rexSubscription, .localFile, .localFolder:
                // Unreachable: these kinds open no URL field (see
                // takesURL), but the switch must stay exhaustive.
                result = "请用对应的入口导入。"
            }
        } catch {
            result = error.localizedDescription
        }
    }
}

/// The .fwd picker: paste a manifest address, fetch it, and tick the
/// widgets to import, grouped by category with per-category select-all.
/// Already-imported widgets show their version; a newer manifest version
/// shows as an update. Imported components are stored as local Rex
/// sources, one one-site subscription per component — the same mechanism
/// as a single-file Rex import.
struct FinchFwdPickerView: View {
    @Environment(Store.self) private var store
    @State private var manifestURL: String
    @State private var manifest: FinchFwdManifest?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selection = Set<String>()
    @State private var isImporting = false
    @State private var progress = ""
    @State private var result: String?

    init() {
        _manifestURL = State(initialValue: FinchRexSubscriptions.shared.records.last?.manifestURL ?? "")
    }

    private var grouped: [(FinchSourceCategory, [FinchFwdWidget])] {
        guard let manifest else { return [] }
        var ordered: [(FinchSourceCategory, [FinchFwdWidget])] = []
        for widget in manifest.widgets {
            if let index = ordered.firstIndex(where: { $0.0 == widget.category }) {
                ordered[index].1.append(widget)
            } else {
                ordered.append((widget.category, [widget]))
            }
        }
        let rank = FinchSourceCategory.ordered
        return ordered.sorted { (rank.firstIndex(of: $0.0) ?? 9) < (rank.firstIndex(of: $1.0) ?? 9) }
    }

    private func status(for widget: FinchFwdWidget) -> String? {
        guard let record = FinchRexSubscriptions.shared.record(for: manifestURL),
              let imported = record.imported[widget.id] else { return "新增" }
        if imported == widget.version { return "已导入 v\(imported)" }
        return "有更新 v\(imported) → v\(widget.version)"
    }

    private func needsImport(_ widget: FinchFwdWidget) -> Bool {
        guard let record = FinchRexSubscriptions.shared.record(for: manifestURL) else { return true }
        return record.imported[widget.id] != widget.version
    }

    var body: some View {
        List {
            Section {
                TextField("https://…/widgets.fwd", text: $manifestURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("拉取清单") { Task { await fetchManifest() } }
                    .disabled(manifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            } header: {
                Text("Rex 订阅清单")
            } footer: {
                Text("填 .fwd 清单地址，例如 https://rex.uou.qzz.io/widgets.fwd。")
            }
            if isLoading {
                Section { ProgressView("正在拉取清单…") }
            }
            if let loadError {
                Section { Text(loadError).foregroundStyle(.red) }
            }
            if let manifest {
                Section {
                    Text("\(manifest.title.isEmpty ? manifest.name : manifest.title) · \(manifest.widgets.count) 个组件")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(grouped, id: \.0) { category, widgets in
                    Section {
                        ForEach(widgets) { widget in
                            widgetRow(widget)
                        }
                    } header: {
                        HStack {
                            Text(category.title)
                            Spacer()
                            Button(allSelected(in: widgets) ? "取消全选" : "全选") {
                                if allSelected(in: widgets) {
                                    selection.subtract(widgets.map(\.id))
                                } else {
                                    selection.formUnion(widgets.map(\.id))
                                }
                            }
                            .font(.subheadline)
                        }
                    }
                }
                Section {
                    Button("导入已选 (\(selection.count))") { Task { await importSelected() } }
                        .disabled(selection.isEmpty || isImporting)
                    if isImporting {
                        ProgressView(progress)
                    }
                }
            }
            if let result {
                Section {
                    Text(result)
                } header: {
                    Text("导入结果")
                }
            }
        }
        .navigationTitle("Rex 订阅")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !manifestURL.isEmpty && manifest == nil { await fetchManifest() }
        }
    }

    private func allSelected(in widgets: [FinchFwdWidget]) -> Bool {
        !widgets.isEmpty && Set(widgets.map(\.id)).isSubset(of: selection)
    }

    @ViewBuilder
    private func widgetRow(_ widget: FinchFwdWidget) -> some View {
        let selected = selection.contains(widget.id)
        Button {
            if selected { selection.remove(widget.id) } else { selection.insert(widget.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(widget.title.isEmpty ? widget.id : widget.title).lineLimit(1)
                    Text("\(widget.id) · v\(widget.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let status = status(for: widget) {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(status.hasPrefix("有更新") ? Color.orange : Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fetchManifest() async {
        let address = manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address) else {
            loadError = "这个地址打不开，检查一下是不是复制全了。"
            return
        }
        isLoading = true
        loadError = nil
        manifest = nil
        selection = []
        result = nil
        defer { isLoading = false }
        do {
            let data = try await Store.fetchBytes(from: url)
            let decoded = try JSONDecoder().decode(FinchFwdManifest.self, from: data)
            guard !decoded.widgets.isEmpty else {
                loadError = "这个清单里没有组件，换个地址试试。"
                return
            }
            manifest = decoded
            selection = Set(decoded.widgets.filter(needsImport).map(\.id))
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func importSelected() async {
        guard let manifest else { return }
        isImporting = true
        result = nil
        defer { isImporting = false }
        let chosen = manifest.widgets.filter { selection.contains($0.id) }
        var imported: [FinchFwdWidget] = []
        var failed: [(FinchFwdWidget, String)] = []
        for (index, widget) in chosen.enumerated() {
            progress = "正在导入 \(index + 1)/\(chosen.count)：\(widget.title.isEmpty ? widget.id : widget.title)"
            do {
                guard let url = URL(string: widget.url) else { throw FinchImportError.badURL }
                let data = try await Store.fetchBytes(from: url)
                let sites = try await store.importDownloadedFile(data: data, filename: widget.filename)
                for site in sites {
                    if let origin = store.subscription?.origin {
                        FinchSourceOverrides.shared.saveCategory(widget.category, site: site, origin: site.origin(or: origin))
                    }
                }
                FinchRexSubscriptions.shared.markImported(manifestURL: manifestURL, name: manifest.title.isEmpty ? manifest.name : manifest.title, widget: widget)
                imported.append(widget)
            } catch {
                failed.append((widget, error.localizedDescription))
            }
        }
        progress = ""
        selection = []
        var text = ""
        if !imported.isEmpty {
            let categories = Array(Set(imported.map(\.category))).map(\.title).joined(separator: "、")
            text += "已导入 \(imported.count) 个源：\(imported.prefix(3).map { $0.title.isEmpty ? $0.id : $0.title }.joined(separator: "、"))\(imported.count > 3 ? "等" : "")，已放入\(categories)分组。"
        }
        if !failed.isEmpty {
            if !text.isEmpty { text += "\n" }
            text += "\(failed.count) 个失败：\(failed.prefix(3).map { $0.0.title.isEmpty ? $0.0.id : $0.0.title }.joined(separator: "、"))\(failed.count > 3 ? "等" : "")。"
        }
        if imported.isEmpty && failed.isEmpty { text = "没有选中的组件。" }
        text += "\n注意：部分组件需要 Cookie / 代理参数才能播放，本版暂无参数填写入口，装上后可能播不了。"
        result = text
    }
}
