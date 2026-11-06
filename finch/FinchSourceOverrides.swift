import Foundation
import TVCore

/// The viewer's own per-source edits (address / remark). Upstream only
/// manages whole subscriptions, so per-source edits are Finch's own
/// UserDefaults records, keyed by "<subscription origin>|<sourceKey>".
///
/// Delete is NOT recorded here: delete is a hard delete
/// (Store.hardDeleteSites), which removes the stored data, so there is
/// nothing to restore and no deleted-sources record to keep. Old installs
/// may still have a "finch.deletedSources" key; it is removed on first launch.
final class FinchSourceOverrides: @unchecked Sendable {
    static let shared = FinchSourceOverrides()

    struct Edit: Codable {
        var api: String
        var remark: String
    }

    private let defaults = UserDefaults.standard
    private(set) var edits: [String: Edit] = [:]

    private init() {
        defaults.removeObject(forKey: "finch.deletedSources")
        if let data = defaults.data(forKey: "finch.sourceEdits"),
           let value = try? JSONDecoder().decode([String: Edit].self, from: data) {
            edits = value
        }
    }

    func key(site: Site, origin: URL) -> String {
        "\(site.origin(or: origin).absoluteString)|\(site.sourceKey)"
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

    /// Drops the edit records of hard-deleted sources, so a deleted source
    /// leaves no trace at all.
    func removeEdits(forKeys keys: Set<String>) {
        guard !keys.isEmpty else { return }
        for key in keys { edits.removeValue(forKey: key) }
        save()
    }

    var tvCoreEdits: [String: FinchSiteEdit] {
        edits.mapValues { FinchSiteEdit(api: $0.api, remark: $0.remark) }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(edits), forKey: "finch.sourceEdits")
    }
}
