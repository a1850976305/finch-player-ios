import Foundation
import TVCore

/// The viewer's own per-source deletes and edits. Upstream only manages whole
/// subscriptions (add / rename / remove / move) and per-source pin / hide /
/// order; it has no per-source delete or address / remark edit. These records
/// are applied to the merged subscription in Store.rebuildSubscription, so a
/// deleted source disappears from every list and an edited source runs under
/// its new address and display name, and both survive a subscription refresh
/// (a refetch rebuilds the merge and the records re-apply).
/// Read and written only from the main actor (Store and the management UI),
/// so the shared instance is safe to share; Swift 6 still needs this said
/// out loud because the class itself is not Sendable.
final class FinchSourceOverrides: @unchecked Sendable {
    static let shared = FinchSourceOverrides()

    struct Edit: Codable {
        var api: String
        var remark: String
    }

    struct DeletedRecord: Codable {
        var name: String
        var api: String
        var origin: String
    }

    private let defaults = UserDefaults.standard
    private(set) var deleted: [String: DeletedRecord] = [:]
    private(set) var edits: [String: Edit] = [:]

    private init() {
        if let data = defaults.data(forKey: "finch.deletedSources"),
           let value = try? JSONDecoder().decode([String: DeletedRecord].self, from: data) {
            deleted = value
        }
        if let data = defaults.data(forKey: "finch.sourceEdits"),
           let value = try? JSONDecoder().decode([String: Edit].self, from: data) {
            edits = value
        }
    }

    func key(site: Site, origin: URL) -> String {
        "\(site.origin(or: origin).absoluteString)|\(site.sourceKey)"
    }

    func delete(site: Site, origin: URL) {
        deleted[key(site: site, origin: origin)] = DeletedRecord(name: site.name, api: site.api, origin: origin.absoluteString)
        save()
    }

    func restore(key: String) {
        deleted.removeValue(forKey: key)
        save()
    }

    func edit(for site: Site, origin: URL) -> Edit? {
        edits[key(site: site, origin: origin)]
    }

    func saveEdit(site: Site, origin: URL, api: String, remark: String) {
        let key = key(site: site, origin: origin)
        let cleanApi = api.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRemark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        if (cleanApi.isEmpty || cleanApi == site.api) && (cleanRemark.isEmpty || cleanRemark == site.name) {
            edits.removeValue(forKey: key)
        } else {
            edits[key] = Edit(api: cleanApi.isEmpty ? site.api : cleanApi, remark: cleanRemark)
        }
        save()
    }

    var deletedKeys: Set<String> { Set(deleted.keys) }

    var tvCoreEdits: [String: FinchSiteEdit] {
        edits.mapValues { FinchSiteEdit(api: $0.api, remark: $0.remark) }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(deleted), forKey: "finch.deletedSources")
        defaults.set(try? JSONEncoder().encode(edits), forKey: "finch.sourceEdits")
    }
}
