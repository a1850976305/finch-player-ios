import SwiftUI
import TVCore

/// A list-style source manager: the Sources tab is a card grid, and grids do
/// not support swipe actions, so true left-swipe delete lives here.
///
/// Rows are flattened by (origin, type) — "订阅源 · Py", "本地源 · 网页",
/// "本地源 · Rex", … — each row showing the subscription it belongs to, so
/// subscription vs local and Py vs HTML are visible at a glance.
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
/// local rows are selectable. Reached from the Sources tab's Manage button.
struct FinchSourceManagementView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editingSite: Site?
    @State private var editingOrigin: URL?
    @State private var editApi = ""
    @State private var editRemark = ""
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var pendingSiteDelete: [FinchSiteDelete] = []
    @State private var showingSiteDeleteConfirm = false
    @State private var pendingSubscriptionDelete: SubscriptionEntry?
    @State private var showingSubscriptionDeleteConfirm = false

    private struct Row: Identifiable {
        let key: String
        let site: Site
        let origin: URL
        let groupTitle: String
        let local: Bool
        var id: String { key }
    }

    private struct SectionData: Identifiable {
        let local: Bool
        let bucket: FinchSourceBucket
        var rows: [Row]
        var title: String { FinchSourceGrouping.sectionTitle(local: local, bucket: bucket) }
        var id: String { title }
    }

    /// All rows, flattened into (local, bucket) sections. Subscription
    /// buckets first, then local buckets; within each, Py, web, Rex, JS, other.
    private var sections: [SectionData] {
        guard let config = store.subscription else { return [] }
        var bySection: [SectionData] = []
        for group in store.sourceGroups(includeHidden: true) {
            for site in group.sites {
                let origin = site.origin(or: config.origin)
                let local = FinchSourceGrouping.isLocal(site: site, fallback: config.origin)
                let bucket = FinchSourceGrouping.bucket(for: site)
                let row = Row(key: FinchSourceOverrides.shared.key(site: site, origin: origin),
                              site: site, origin: origin, groupTitle: group.title, local: local)
                if let index = bySection.firstIndex(where: { $0.local == local && $0.bucket == bucket }) {
                    bySection[index].rows.append(row)
                } else {
                    bySection.append(SectionData(local: local, bucket: bucket, rows: [row]))
                }
            }
        }
        let rank: [FinchSourceBucket: Int] = [.py: 0, .html: 1, .rex: 2, .js: 3, .other: 4]
        return bySection.sorted {
            ($0.local ? 1 : 0, rank[$0.bucket] ?? 9) < ($1.local ? 1 : 0, rank[$1.bucket] ?? 9)
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

    private func startEdit(_ row: Row) {
        editingSite = row.site
        editingOrigin = row.origin
        editApi = row.site.api
        editRemark = FinchSourceOverrides.shared.edit(for: row.site, origin: row.origin)?.remark ?? ""
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
            sourceSections
            subscriptionSection
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("源管理")
        .toolbar { managementToolbar }
        .confirmationDialog("删除源", isPresented: $showingSiteDeleteConfirm) {
            siteDeleteDialogActions
        } message: {
            Text("将彻底删除 \(pendingSiteDelete.count) 个源，数据也会一并清除，无法恢复。")
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
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(row.site.name).lineLimit(1)
            Text(row.site.api).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(row.groupTitle).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        // Only local rows are selectable: remote sites have no delete.
        if row.local { content.tag(row.key) } else { content }
    }
}
