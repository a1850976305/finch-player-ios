import Foundation
import TVCore

/// Per-source open counts, for "按使用频率" sorting in the Manage view.
/// Keyed like FinchSourceOverrides ("<origin>|<sourceKey>"), stored in
/// UserDefaults as [String: Int]. Counts opens from the Sources tab
/// (SitesView card tap); a source that was never opened counts as 0 and
/// sorts by name among the never-opened, so a fresh install reads exactly
/// like name order.
final class FinchSourceUsage: @unchecked Sendable {
    static let shared = FinchSourceUsage()

    private let defaults = UserDefaults.standard
    private(set) var counts: [String: Int] = [:]

    private init() {
        if let data = defaults.data(forKey: "finch.sourceUsage"),
           let value = try? JSONDecoder().decode([String: Int].self, from: data) {
            counts = value
        }
    }

    func count(forKey key: String) -> Int { counts[key] ?? 0 }

    func record(site: Site, origin: URL) {
        let key = FinchSourceOverrides.shared.key(site: site, origin: origin)
        counts[key, default: 0] += 1
        save()
    }

    /// Drops the counts of hard-deleted sources, so a deleted source
    /// leaves no trace at all.
    func removeCounts(forKeys keys: Set<String>) {
        guard !keys.isEmpty else { return }
        for key in keys { counts.removeValue(forKey: key) }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(counts), forKey: "finch.sourceUsage")
    }
}
