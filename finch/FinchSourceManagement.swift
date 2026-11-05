import SwiftUI
import TVCore

/// A list-style source manager: the Sources tab is a card grid, and grids do
/// not support swipe actions, so true left-swipe delete lives here. Each row
/// swipes to delete or edit; deleted sources wait in their own section where
/// they can be restored. Reached from the Sources tab's Manage button.
struct FinchSourceManagementView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editingSite: Site?
    @State private var editingOrigin: URL?
    @State private var editApi = ""
    @State private var editRemark = ""

    var body: some View {
        NavigationStack {
            if let config = store.subscription {
                List {
                    ForEach(store.sourceGroups(includeHidden: true)) { group in
                        if !group.sites.isEmpty {
                            Section(group.title) {
                                ForEach(group.sites) { site in
                                    let origin = site.origin(or: config.origin)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(site.name).lineLimit(1)
                                        Text(site.api).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            FinchSourceOverrides.shared.delete(site: site, origin: origin)
                                            store.reloadAfterFinchSourceChange()
                                        } label: { Label("删除", systemImage: "trash") }
                                        Button {
                                            editingSite = site
                                            editingOrigin = origin
                                            editApi = site.api
                                            editRemark = FinchSourceOverrides.shared.edit(for: site, origin: origin)?.remark ?? ""
                                        } label: { Label("编辑", systemImage: "pencil") }
                                        .tint(.orange)
                                    }
                                }
                            }
                        }
                    }
                    let deleted = FinchSourceOverrides.shared.deleted.sorted { $0.value.name < $1.value.name }
                    if !deleted.isEmpty {
                        Section("已删除的源") {
                            ForEach(deleted, id: \.key) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.value.name).lineLimit(1)
                                        Text(item.value.api).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Button("恢复") {
                                        FinchSourceOverrides.shared.restore(key: item.key)
                                        store.reloadAfterFinchSourceChange()
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("源管理")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
                .sheet(item: $editingSite) { site in
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
            } else {
                ContentUnavailableView("还没有源", systemImage: "square.grid.2x2", description: Text("先在设置里添加一个订阅。"))
            }
        }
    }
}
