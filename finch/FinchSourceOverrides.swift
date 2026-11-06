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
    /// Per-source category overrides, keyed like edits. nil (no entry)
    /// means "自动" — derive from the title by keywords.
    private(set) var categoryOverrides: [String: FinchSourceCategory] = [:]

    private init() {
        defaults.removeObject(forKey: "finch.deletedSources")
        if let data = defaults.data(forKey: "finch.sourceEdits"),
           let value = try? JSONDecoder().decode([String: Edit].self, from: data) {
            edits = value
        }
        if let data = defaults.data(forKey: "finch.sourceCategories"),
           let value = try? JSONDecoder().decode([String: FinchSourceCategory].self, from: data) {
            categoryOverrides = value
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

    /// The category override for a source, if the viewer picked one.
    func categoryOverride(for site: Site, origin: URL) -> FinchSourceCategory? {
        categoryOverrides[key(site: site, origin: origin)]
    }

    /// The category override for a raw "<origin>|<sourceKey>" key — used at
    /// .fwd import time, before the imported site object is in hand.
    func categoryOverride(forKey key: String) -> FinchSourceCategory? {
        categoryOverrides[key]
    }

    /// Saves a category override; nil clears it back to "自动" (derive).
    func saveCategory(_ category: FinchSourceCategory?, site: Site, origin: URL) {
        saveCategory(category, forKey: key(site: site, origin: origin))
    }

    func saveCategory(_ category: FinchSourceCategory?, forKey key: String) {
        if let category {
            categoryOverrides[key] = category
        } else {
            categoryOverrides.removeValue(forKey: key)
        }
        save()
    }

    /// Drops the category overrides of hard-deleted sources too.
    func removeCategories(forKeys keys: Set<String>) {
        guard !keys.isEmpty else { return }
        for key in keys { categoryOverrides.removeValue(forKey: key) }
        save()
    }

    var tvCoreEdits: [String: FinchSiteEdit] {
        edits.mapValues { FinchSiteEdit(api: $0.api, remark: $0.remark) }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(edits), forKey: "finch.sourceEdits")
        defaults.set(try? JSONEncoder().encode(categoryOverrides), forKey: "finch.sourceCategories")
    }
}
