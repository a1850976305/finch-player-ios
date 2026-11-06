import SwiftUI
import TVCore
import UniformTypeIdentifiers

/// A list-style source manager: the Sources tab is a card grid, and grids do
/// not support swipe actions, so true left-swipe delete lives here.
///
/// Layout (Arcane reference, layout pattern only): the top is a guided
/// import chooser — one row per source kind, each with an icon, a title and
/// a one-line hint — then "站源订阅" runtime groups (猫源 / Py / Rex /
/// 网页, each with its count and status, tappable to a filtered list),
/// then the sources themselves grouped by content category first
/// (影视 / 短剧 / 动漫 / 成人 / 网盘 / 其他), each row showing its type
/// and origin (订阅/本地) as secondary text. Rex rows also show the
/// component id + version, like a module.
///
/// Delete is a HARD delete: no record is kept, nothing can be restored, and
/// the stored data is freed (Store.hardDeleteSites), with a confirmation
/// dialog because there is no undo. Only local sources offer delete — a
/// remote site would return on the next refresh unless a record of the
/// delete were kept, and the viewer asked for no records; remote sites are
/// hidden, or the whole subscription is removed (see the "订阅" section).
///
/// Batch delete: edit mode with multi-select, select-all, and one
/// destructive delete with confirmation. Selection spans sections, and only
/// local rows are selectable.
///
/// A filtered instance (filter != nil) shows only one runtime's sources,
/// grouped by category; the import and runtime sections are hidden there.
struct FinchSourceManagementView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let filter: FinchRuntimeGroup?

    init(filter: FinchRuntimeGroup? = nil) {
        self.filter = filter
    }

    @State private var editingSite: Site?
    @State private var editingOrigin: URL?
    @State private var editApi = ""
    @State private var editRemark = ""
    @State private var editCategory: FinchSourceCategory?
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var pendingSiteDelete: [FinchSiteDelete] = []
    @State private var showingSiteDeleteConfirm = false
    @State private var pendingSubscriptionDelete: SubscriptionEntry?
    @State private var showingSubscriptionDeleteConfirm = false
    @State private var choosesFile = false
    @State private var fileImportResult: String?

    private struct Row: Identifiable {
        let key: String
        let site: Site
        let origin: URL
        let groupTitle: String
        let local: Bool
        var id: String { key }
    }

    private struct SectionData: Identifiable {
        let category: FinchSourceCategory
        var rows: [Row]
        var title: String { "\(category.title) · \(rows.count) 个" }
        var id: String { category.rawValue }
    }

    /// All rows, grouped by content category first. Inside a category,
    /// rows are in runtime order (Py, web, Rex, JS, other). A runtime
    /// filter (from a "站源订阅" row) keeps only that runtime's rows.
    private var sections: [SectionData] {
        guard let config = store.subscription else { return [] }
        var bySection: [SectionData] = []
        for group in store.sourceGroups(includeHidden: true) {
            for site in group.sites {
                if let filter, !filter.matches(site: site) { continue }
                let origin = site.origin(or: config.origin)
                let category = FinchSourceGrouping.category(for: site, origin: origin)
                let row = Row(key: FinchSourceOverrides.shared.key(site: site, origin: origin),
                              site: site, origin: origin, groupTitle: group.title, local: FinchSourceGrouping.isLocal(site: site, fallback: config.origin))
                if let index = bySection.firstIndex(where: { $0.category == category }) {
                    bySection[index].rows.append(row)
                } else {
                    bySection.append(SectionData(category: category, rows: [row]))
                }
            }
        }
        let rank: [FinchSourceBucket: Int] = [.py: 0, .html: 1, .rex: 2, .js: 3, .other: 4]
        let categoryRank: [FinchSourceCategory: Int] = [.movie: 0, .drama: 1, .anime: 2, .adult: 3, .netdisk: 4, .other: 5]
        return bySection.map { section in
            SectionData(category: section.category, rows: section.rows.sorted {
                (rank[FinchSourceGrouping.bucket(for: $0.site)] ?? 9) < (rank[FinchSourceGrouping.bucket(for: $1.site)] ?? 9)
            })
        }.sorted { (categoryRank[$0.category] ?? 9) < (categoryRank[$1.category] ?? 9) }
    }

    /// Runtime groups over visible (non-hidden) sites, with a status line
    /// each: 猫源 shows NodeMobile 运行中/未运行, the others their count.
    private var runtimeGroups: [(group: FinchRuntimeGroup, status: String)] {
        guard store.subscription != nil else { return [] }
        let visible = store.sourceGroups(includeHidden: false).flatMap(\.sites)
        return FinchSourceGrouping.runtimeCounts(sites: visible).map { group, count in
            switch group {
            case .catpaw:
                (group, "\(count) 个 · \(EmbeddedNodeHost.available ? "运行中" : "未运行")")
            case .rex:
                (group, "\(count) 个组件")
            default:
                (group, "\(count) 个已启用")
            }
        }
    }

    private var localKeys: [String] { sections.flatMap(\.rows).filter(\.local).map(\.key) }

    private var allSelected: Bool { !localKeys.isEmpty && Set(localKeys).isSubset(of: selection) }

    private func selectedDeletes() -> [FinchSiteDelete] {
        let rows = sections.flatMap(\.rows)
        return selection.compactMap { key in
            rows.first(where: { $0.key == key }).map { FinchSiteDelete(site: $0.site, origin: $0.origin) }
        }
    }

    /// Names for the delete confirmation: the single source's name, or
    /// "N 个源（A、B、C等）" for a batch — so the dialog says what is
    /// about to be gone for good.
    private var deleteNames: String {
        let names = pendingSiteDelete.map(\.site.name)
        if names.count == 1 { return "「\(names[0])」" }
        let shown = names.prefix(3).joined(separator: "、")
        return "\(names.count) 个源（\(shown)\(names.count > 3 ? "等" : "")）"
    }

    private func startEdit(_ row: Row) {
        editingSite = row.site
        editingOrigin = row.origin
        editApi = row.site.api
        editRemark = FinchSourceOverrides.shared.edit(for: row.site, origin: row.origin)?.remark ?? ""
        editCategory = FinchSourceOverrides.shared.categoryOverride(for: row.site, origin: row.origin)
    }

    var body: some View {
        NavigationStack {
            if store.subscription != nil {
                // AnyView here is deliberate: the management list's full
                // modifier chain (two confirmation dialogs + sheet) made the
                // Swift 6.2 type checker time out on `body` (Xcode 26.3,
                // 2026-11-06, "unable to type-check this expression in
                // reasonable time"). Erasing the list's type at this seam
                // keeps the checker's budget small; the rows inside the
                // List are unaffected.
                AnyView(managementList)
            } else {
                ContentUnavailableView("还没有源", systemImage: "square.grid.2x2", description: Text("先在设置里添加一个订阅。"))
            }
        }
    }

    /// The management list, split out of `body`: the single giant body
    /// expression exceeded the Swift 6.2 type-check budget (Xcode 26.3,
    /// 2026-11-06, "unable to type-check this expression in reasonable
    /// time"), so the list, its sections, toolbar and edit sheet are
    /// separate expressions, each with its own type-check budget.
    /// Same UI, same behaviour.
    private var managementList: some View {
        List(selection: $selection) {
            if filter == nil && !editMode.isEditing {
                importSection
                runtimeGroupsSection
            }
            sourceSections
            if filter == nil {
                subscriptionSection
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(filter?.title ?? "源管理")
        .toolbar { managementToolbar }
        .confirmationDialog("删除源", isPresented: $showingSiteDeleteConfirm) {
            siteDeleteDialogActions
        } message: {
            Text("将彻底删除 \(deleteNames)，数据也会一并清除，无法恢复。")
        }
        .confirmationDialog("删除订阅", isPresented: $showingSubscriptionDeleteConfirm) {
            subscriptionDeleteDialogActions
        } message: {
            Text("将删除整个订阅及其全部源，数据也会一并清除，无法恢复。")
        }
        .sheet(item: $editingSite) { site in
            editSheet(site: site)
        }
    }

    /// Dialog actions kept as their own expressions so the List's modifier
    /// chain stays inside the type-check budget (see `body`).
    @ViewBuilder
    private var siteDeleteDialogActions: some View {
        Button("删除", role: .destructive) {
            store.hardDeleteSites(pendingSiteDelete.map { ($0.site, $0.origin) })
            pendingSiteDelete = []
            selection.removeAll()
            editMode = .inactive
        }
        Button("取消", role: .cancel) { pendingSiteDelete = [] }
    }

    @ViewBuilder
    private var subscriptionDeleteDialogActions: some View {
        Button("删除", role: .destructive) {
            if let entry = pendingSubscriptionDelete { store.removeSubscription(entry) }
            pendingSubscriptionDelete = nil
        }
        Button("取消", role: .cancel) { pendingSubscriptionDelete = nil }
    }

    /// Guided import chooser: one row per source kind — icon, title, and a
    /// one-line hint. URL kinds push a URL field; Rex 订阅 pushes the .fwd
    /// checkbox list; 本地文件 opens the file picker. The file importer
    /// lives on its own row button, never stacked on the same view as the
    /// edit sheet (SwiftUI rule learned 2026-11-05: two same-kind
    /// presentation modifiers on one view shadow each other).
    @ViewBuilder
    private var importSection: some View {
        Section {
            ForEach(FinchURLImportKind.allCases, id: \.self) { kind in
                if kind == .localFile {
                    Button { choosesFile = true } label: {
                        importRow(kind: kind)
                    }
                    .buttonStyle(.plain)
                    .fileImporter(isPresented: $choosesFile, allowedContentTypes: SubscriptionFile.types, allowsMultipleSelection: true) { result in
                        guard case .success(let files) = result else { return }
                        Task { await importFiles(files) }
                    }
                } else if kind == .rexSubscription {
                    NavigationLink(destination: FinchFwdPickerView()) {
                        importRow(kind: kind)
                    }
                } else {
                    NavigationLink(destination: FinchURLInputView(kind: kind)) {
                        importRow(kind: kind)
                    }
                }
            }
            if let fileImportResult {
                Text(fileImportResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("添加资源")
        } footer: {
            Text("导入的源会按内容自动分组；想换分组可以在编辑里改。")
        }
    }

    private func importRow(kind: FinchURLImportKind) -> some View {
        HStack(spacing: 12) {
            FinchKindIcons.importIcon(kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).lineLimit(1)
                Text(kind.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private func importFiles(_ files: [URL]) async {
        let before = Set(store.subscriptions.map(\.address))
        for file in files { await store.importSubscriptionFile(file) }
        if let error = store.importError {
            fileImportResult = error
            return
        }
        let added = store.subscriptions.filter { !before.contains($0.address) }
            .compactMap { store.documents[$0.address]?.sites }.flatMap { $0 }
        fileImportResult = added.isEmpty
            ? (store.notice ?? "已导入，没有新增源。")
            : FinchImportSummary.text(for: added)
    }

    /// Runtime groups ("站源订阅"): each row taps through to a filtered
    /// list of that runtime's sources, grouped by category inside.
    @ViewBuilder
    private var runtimeGroupsSection: some View {
        Section {
            ForEach(runtimeGroups, id: \.group) { group, status in
                NavigationLink(destination: FinchSourceManagementView(filter: group)) {
                    HStack(spacing: 12) {
                        FinchKindIcons.icon(for: group)
                        Text(group.title).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("站源订阅")
        }
    }

    @ViewBuilder
    private var sourceSections: some View {
        ForEach(sections) { section in
            Section(section.title) {
                ForEach(section.rows) { row in
                    rowContent(row)
                        .swipeActions(edge: .trailing) {
                            rowSwipeActions(row)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func rowSwipeActions(_ row: Row) -> some View {
        if row.local {
            Button(role: .destructive) {
                pendingSiteDelete = [FinchSiteDelete(site: row.site, origin: row.origin)]
                showingSiteDeleteConfirm = true
            } label: { Label("删除", systemImage: "trash") }
        } else {
            HideSourceButton(site: row.site, origin: row.origin)
        }
        Button {
            startEdit(row)
        } label: { Label("编辑", systemImage: "pencil") }
        .tint(.orange)
    }

    // NOTE: SwiftUI has no Section("title") { } footer: { } initializer —
    // the only footer-taking form is Section { } header: { } footer: { }.
    // The title form with a footer failed the build (run 42155633580:
    // "generic parameter 'Content' could not be inferred" at this Section).
    private var subscriptionSection: some View {
        Section {
            ForEach(store.subscriptions) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).lineLimit(1)
                        Text(entry.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        pendingSubscriptionDelete = entry
                        showingSubscriptionDeleteConfirm = true
                    } label: { Label("删除", systemImage: "trash") }
                }
            }
        } header: {
            Text("订阅")
        } footer: {
            Text("删除整个订阅会删掉它包含的全部源。订阅里的单个源只能删除本地源，远程源请隐藏或删除整个订阅。")
        }
    }

    @ToolbarContentBuilder
    private var managementToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if editMode.isEditing {
                Button(allSelected ? "取消全选" : "全选") {
                    if allSelected { selection.removeAll() } else { selection = Set(localKeys) }
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(editMode.isEditing ? "完成" : "编辑") {
                if editMode.isEditing {
                    selection.removeAll()
                    editMode = .inactive
                } else {
                    editMode = .active
                }
            }
            .disabled(sections.isEmpty)
        }
        ToolbarItem(placement: .confirmationAction) {
            if editMode.isEditing {
                Button("删除 (\(selection.count))", role: .destructive) {
                    pendingSiteDelete = selectedDeletes()
                    showingSiteDeleteConfirm = true
                }
                .disabled(selection.isEmpty)
            } else {
                Button("完成") { dismiss() }
            }
        }
    }

    private func editSheet(site: Site) -> some View {
        NavigationStack {
            Form {
                Section("地址") {
                    TextField("源地址", text: $editApi)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("备注") {
                    TextField("显示名称（备注），留空用原名", text: $editRemark)
                }
                Section {
                    Picker("分类", selection: $editCategory) {
                        Text("自动").tag(FinchSourceCategory?.none)
                        ForEach(FinchSourceCategory.ordered, id: \.self) { category in
                            Text(category.title).tag(category as FinchSourceCategory?)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("分类")
                } footer: {
                    Text("自动按源名归类；选一个分类就固定用它。")
                }
            }
            .navigationTitle("编辑源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { editingSite = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let origin = editingOrigin {
                            FinchSourceOverrides.shared.saveEdit(site: site, origin: origin, api: editApi, remark: editRemark)
                            FinchSourceOverrides.shared.saveCategory(editCategory, site: site, origin: origin)
                            store.reloadAfterFinchSourceChange()
                        }
                        editingSite = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowContent(_ row: Row) -> some View {
        HStack(spacing: 12) {
            FinchKindIcons.icon(for: row.site)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.site.name).lineLimit(1)
                Text(row.site.api).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(metaLine(for: row)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        // Only local rows are selectable: remote sites have no delete.
        .modifier(FinchRowTagModifier(local: row.local, key: row.key))
    }

    /// Type · origin · (Rex id + version) · owning subscription, e.g.
    /// "Rex · 本地 · forward.supjav.tut v1.3.1 · 宝宝巴士乐园".
    private func metaLine(for row: Row) -> String {
        let bucket = FinchSourceGrouping.bucket(for: row.site)
        var parts = ["\(bucket.shortTitle) · \(row.local ? "本地" : "订阅")"]
        if let rex = FinchRexInfo.caption(for: row.site) { parts.append(rex) }
        parts.append(row.groupTitle)
        return parts.joined(separator: " · ")
    }
}

/// Applies .tag only for local rows, so only they are selectable in edit
/// mode. A separate modifier keeps rowContent's own expression small.
private struct FinchRowTagModifier: ViewModifier {
    let local: Bool
    let key: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if local {
            content.tag(key)
        } else {
            content
        }
    }
}
