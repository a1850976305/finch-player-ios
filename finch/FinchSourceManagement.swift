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
    /// False when the view sits inside a tab's own NavigationStack
    /// (RouteStack): nesting a second NavigationStack would render a
    /// second navigation bar. True for the sheet, which has no stack.
    let embedInNavigationStack: Bool

    init(filter: FinchRuntimeGroup? = nil, embedInNavigationStack: Bool = true) {
        self.filter = filter
        self.embedInNavigationStack = embedInNavigationStack
    }

    @State private var editingSite: Site?
    @State private var editingOrigin: URL?
    @State private var editApi = ""
    @State private var editRemark = ""
    @State private var searchText = ""
    @State private var selectedType: FinchRuntimeGroup? = nil
    @State private var sortMode: FinchSourceSort = .name
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var pendingSiteDelete: [FinchSiteDelete] = []
    @State private var showingSiteDeleteConfirm = false
    @State private var choosesFile = false
    @State private var choosesFolder = false
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
        let type: FinchRuntimeGroup
        let local: Bool
        var rows: [Row]
        var title: String { "\(type.title) · \(local ? "本地导入" : "订阅导入") · \(rows.count) 个" }
        var id: String { "\(type)-\(local)" }
    }

    /// All rows, grouped by source type first (Py / JS / CatPaw / Rex /
    /// TVBox / Web), then by import origin inside a type: 订阅导入 before
    /// 本地导入. A runtime filter (from a "站源订阅" row) keeps only that
    /// runtime's rows. User 2026-11-07: group by type, not by content
    /// category (no more 影视 / 短剧 / 成人 sections).
    private var sections: [SectionData] {
        guard let config = store.subscription else { return [] }
        var bySection: [SectionData] = []
        for group in store.sourceGroups(includeHidden: true) {
            for site in group.sites {
                if let filter, !filter.matches(site: site) { continue }
                let origin = site.origin(or: config.origin)
                let type = FinchSourceGrouping.runtimeGroup(for: site)
                let local = FinchSourceGrouping.isLocal(site: site, fallback: config.origin)
                let row = Row(key: FinchSourceOverrides.shared.key(site: site, origin: origin),
                              site: site, origin: origin, groupTitle: group.title, local: local)
                if let index = bySection.firstIndex(where: { $0.type == type && $0.local == local }) {
                    bySection[index].rows.append(row)
                } else {
                    bySection.append(SectionData(type: type, local: local, rows: [row]))
                }
            }
        }
        let typeRank: [FinchRuntimeGroup: Int] = [.py: 0, .js: 1, .catpaw: 2, .rex: 3, .tvbox: 4, .html: 5]
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return bySection.compactMap { section in
            if let selectedType, section.type != selectedType { return nil }
            var rows = section.rows
            if !query.isEmpty {
                rows = rows.filter { $0.site.name.lowercased().contains(query) }
            }
            guard !rows.isEmpty else { return nil }
            rows.sort { a, b in
                switch sortMode {
                case .name:
                    return a.site.name.localizedStandardCompare(b.site.name) == .orderedAscending
                case .frequency:
                    let ca = FinchSourceUsage.shared.count(forKey: a.key)
                    let cb = FinchSourceUsage.shared.count(forKey: b.key)
                    if ca != cb { return ca > cb }
                    return a.site.name.localizedStandardCompare(b.site.name) == .orderedAscending
                }
            }
            return SectionData(type: section.type, local: section.local, rows: rows)
        }.sorted {
            let ra = typeRank[$0.type] ?? 9, rb = typeRank[$1.type] ?? 9
            if ra != rb { return ra < rb }
            return !$0.local && $1.local
        }
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
    }

    var body: some View {
        if embedInNavigationStack {
            NavigationStack { managementContent }
        } else {
            managementContent
        }
    }

    /// The page without its own NavigationStack, so the tab's RouteStack
    /// can own the bar (see `embedInNavigationStack`).
    private var managementContent: some View {
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
            AnyView(emptyStateWithImport)
        }
    }

    /// Shown when there is no subscription at all: the import chooser is
    /// still reachable here, so the empty state points at it instead of at
    /// Settings (subscription import moved out of Settings 2026-11-06).
    /// Its own small expression, like managementList, for the type-check
    /// budget (see `body`).
    private var emptyStateWithImport: some View {
        List {
            importSection
            Section {
                Text("还没有源，点上面“添加资源”导入一个源。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("源管理")
    }

    /// A type chip or a search query is active: the list shows only
    /// the matching sources, and the import / runtime / subscription
    /// sections step aside until the filter clears.
    private var isFiltering: Bool {
        selectedType != nil || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Type switcher + sort control. Tapping a type shows only that type's
    /// sources; "全部" clears it. The sort picker flips between 按名字
    /// and 按使用频率.
    private var filterBar: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    categoryChip(title: "全部", selected: selectedType == nil) {
                        selectedType = nil
                    }
                    ForEach(FinchRuntimeGroup.ordered, id: \.self) { type in
                        categoryChip(title: type.title, selected: selectedType == type) {
                            selectedType = type
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Picker("排序", selection: $sortMode) {
                Text("按名字").tag(FinchSourceSort.name)
                Text("按使用频率").tag(FinchSourceSort.frequency)
            }
            .pickerStyle(.segmented)
        }
    }

    private func categoryChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    /// The management list, split out of `body`: the single giant body
    /// expression exceeded the Swift 6.2 type-check budget (Xcode 26.3,
    /// 2026-11-06, "unable to type-check this expression in reasonable
    /// time"), so the list, its sections, toolbar and edit sheet are
    /// separate expressions, each with its own type-check budget.
    /// Same UI, same behaviour.
    private var managementList: some View {
        List(selection: $selection) {
            if !editMode.isEditing {
                filterBar
            }
            if filter == nil && !editMode.isEditing && !isFiltering {
                importSection
                runtimeGroupsSection
            }
            sourceSections
            if filter == nil && !editMode.isEditing && !isFiltering {
                subscriptionSection
            }
        }
        .environment(\.editMode, $editMode)
        .searchable(text: $searchText, prompt: "搜索源名称")
        .navigationTitle(filter?.title ?? "源管理")
        .toolbar { managementToolbar }
        .confirmationDialog("删除源", isPresented: $showingSiteDeleteConfirm) {
            siteDeleteDialogActions
        } message: {
            Text("将彻底删除 \(deleteNames)，数据也会一并清除，无法恢复。")
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
                } else if kind == .localFolder {
                    // Folder import moved from Settings 2026-11-06. Its
                    // .fileImporter lives on this row's own Button, never
                    // stacked with the file importer's Button above.
                    Button { choosesFolder = true } label: {
                        importRow(kind: kind)
                    }
                    .buttonStyle(.plain)
                    .fileImporter(isPresented: $choosesFolder, allowedContentTypes: [.folder]) { result in
                        guard case .success(let folder) = result else { return }
                        Task { await importFolder(folder) }
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
            Text("导入的源按类型分组：Py源、JS源、猫源、Rex源、TVBox源；订阅导入和本地导入分开列。")
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

    /// Folder import: every .json/.py/.js file in the folder goes through
    /// the same import path as a picked file. Same result summary as
    /// importFiles, so the row below the chooser says what landed where.
    private func importFolder(_ folder: URL) async {
        let before = Set(store.subscriptions.map(\.address))
        await store.importSubscriptionFolder(folder)
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
    //
    // Subscription management moved here from Settings (2026-11-06), so
    // the Manage tab is the only place for it: Refresh All in the header,
    // per-subscription enable / rename / reorder / remove in the detail
    // page, and bulk remove below. Settings keeps only manga repositories.
    private var subscriptionSection: some View {
        Section {
            ForEach(store.subscriptions) { entry in
                NavigationLink(destination: FinchSubscriptionDetailView(entry: entry)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).lineLimit(1)
                            Text(finchSubscriptionStatus(entry, store: store)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if store.subscriptionErrors[entry.address] != nil {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }
            if store.subscriptions.count > 1 {
                NavigationLink(destination: FinchRemoveSubscriptionsView()) {
                    Label("批量删除订阅", systemImage: "trash.fill").foregroundStyle(.red)
                }
            }
        } header: {
            HStack {
                Text("订阅")
                Spacer()
                if store.importing {
                    ProgressView().controlSize(.small)
                } else if !store.subscriptions.isEmpty {
                    Button { Task { await store.refreshSubscriptions() } } label: {
                        Label("全部刷新", systemImage: "arrow.clockwise")
                    }
                    .font(.footnote.weight(.semibold)).textCase(nil).tint(.secondary)
                }
            }
        } footer: {
            Text("删除整个订阅会删掉它包含的全部源。订阅里的单个源只能删除本地源，远程源请隐藏或删除整个订阅。")
            if let message = store.importError ?? store.notice { Text(message) }
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
            } else if embedInNavigationStack {
                // The tab has nothing to dismiss; there the button would
                // sit dead, so it only exists for the sheet.
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

/// What a subscription row shows as its secondary line: refresh failure,
/// switched off, not loaded yet, or its source count. Same wording as the
/// old Settings row, minus the L10n lookup (this page is Chinese-first).
/// @MainActor: Store is a @MainActor @Observable class, so a global helper
/// touching its properties must be isolated too (build 42208472670 failed
/// here with exit 65 before this was added).
@MainActor
private func finchSubscriptionStatus(_ entry: SubscriptionEntry, store: Store) -> String {
    if store.subscriptionErrors[entry.address] != nil { return "刷新失败" }
    if !entry.enabled { return "已停用" }
    guard let copy = store.documents[entry.address] else { return "未加载" }
    return "\(copy.sites.count) 个源"
}

/// One subscription's settings, moved out of Settings (2026-11-06): the
/// Manage tab is the only place for source import and management, so the
/// enable toggle, rename, reorder and remove live here now. The sections
/// are split out so the body stays inside the type-check budget.
private struct FinchSubscriptionDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: SubscriptionEntry
    @State private var confirmsRemoval = false

    private var current: SubscriptionEntry {
        store.subscriptions.first { $0.address == entry.address } ?? entry
    }

    private var index: Int {
        store.subscriptions.firstIndex { $0.address == entry.address } ?? 0
    }

    var body: some View {
        Form {
            detailMainSection
            if store.subscriptions.count > 1 {
                detailOrderSection
            }
            Section {
                Button("删除订阅", role: .destructive) { confirmsRemoval = true }
            }
        }
        .navigationTitle(current.title)
        .confirmationDialog("删除订阅", isPresented: $confirmsRemoval) {
            Button("删除", role: .destructive) { store.removeSubscription(current); dismiss() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将删除整个订阅及其全部源，数据也会一并清除，无法恢复。")
        }
    }

    private var detailMainSection: some View {
        let failure = store.subscriptionErrors[entry.address]
        let copy = store.documents[entry.address]
        return Section {
            Toggle(isOn: Binding(get: { current.enabled }, set: { on in Task { await store.setSubscription(current, enabled: on) } })) {
                Text("启用订阅")
            }
            .disabled(store.importing)
            LabeledContent("名称") {
                TextField("名称", text: Binding(get: { current.name }, set: { store.renameSubscription(current, to: $0) }),
                          prompt: Text(SubscriptionEntry(address: current.address).title))
                    .labelsHidden().multilineTextAlignment(.trailing)
            }
            LabeledContent("订阅地址") {
                Text(current.address).lineLimit(2).truncationMode(.middle).textSelection(.enabled).foregroundStyle(.secondary)
            }
        } footer: {
            if let failure { Text("刷新失败：\(failure)") }
            else if let copy { Text("源：\(copy.sites.count) 个 · 直播：\(copy.lives.count) 个") }
        }
    }

    private var detailOrderSection: some View {
        Section("顺序") {
            if index > 0 { Button("上移") { store.moveSubscription(current, by: -1) } }
            if index < store.subscriptions.count - 1 { Button("下移") { store.moveSubscription(current, by: 1) } }
        }
    }
}

/// Removing many subscriptions at once: tick them, or take all or the
/// switched-off ones, then remove. Moved out of Settings with the rest of
/// subscription management (2026-11-06).
private struct FinchRemoveSubscriptionsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var confirmsRemoval = false

    private var all: Bool {
        !store.subscriptions.isEmpty && selection.count == store.subscriptions.count
    }

    private var off: [String] {
        store.subscriptions.filter { !$0.enabled }.map(\.address)
    }

    var body: some View {
        Form {
            Section {
                Button(all ? "取消全选" : "全选") {
                    selection = all ? [] : Set(store.subscriptions.map(\.address))
                }
                if !off.isEmpty { Button("选择已停用的订阅") { selection = Set(off) } }
            }
            Section {
                ForEach(store.subscriptions) { entry in
                    let selected = selection.contains(entry.address)
                    Button {
                        if selected { selection.remove(entry.address) } else { selection.insert(entry.address) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            Text(entry.title).lineLimit(1).foregroundStyle(.primary)
                            Spacer(minLength: 6)
                            Text(finchSubscriptionStatus(entry, store: store)).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("删除已选 (\(selection.count))", role: .destructive) { confirmsRemoval = true }
                    .disabled(selection.isEmpty)
            }
        }
        .navigationTitle("批量删除订阅")
        .confirmationDialog("删除订阅", isPresented: $confirmsRemoval) {
            Button("删除", role: .destructive) { store.removeSubscriptions(selection); dismiss() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将删除所选 \(selection.count) 个订阅及其全部源，数据也会一并清除，无法恢复。")
        }
    }
}
