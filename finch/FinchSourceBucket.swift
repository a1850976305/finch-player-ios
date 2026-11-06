import Foundation
import TVCore

/// Which kind of source a site is, for grouping in the Sources tab and the
/// management list. Rex is checked before JavaScript: a Rex component's api
/// also ends in `.js`. WebHome is checked first: a homePage site browses as
/// a web page whatever its api suffix is.
enum FinchSourceBucket: String, CaseIterable {
    case py, html, rex, js, other

    var title: String {
        switch self {
        case .py: return "Py 源"
        case .html: return "网页源"
        case .rex: return "Rex"
        case .js: return "JS 源"
        case .other: return "其他"
        }
    }

    /// Short label for a card/row caption, e.g. "Py · 本地".
    var shortTitle: String {
        switch self {
        case .py: return "Py"
        case .html: return "网页"
        case .rex: return "Rex"
        case .js: return "JS"
        case .other: return "其他"
        }
    }
}

/// One runtime group in the management view's "站源订阅" section (Arcane
/// reference): each row shows its count and status, and taps through to a
/// filtered list of that runtime's sources.
enum FinchRuntimeGroup: Hashable {
    case catpaw, py, rex, html, js

    var title: String {
        switch self {
        case .catpaw: return "猫源"
        case .py: return "Py 站源"
        case .rex: return "Rex 站源"
        case .html: return "网页站源"
        case .js: return "JS 站源"
        }
    }

    /// Whether a site belongs to this runtime group. A CatPaw bundle reads
    /// as JavaScript at runtime, so it is claimed by .catpaw first and
    /// excluded from .js — otherwise it would be counted twice.
    func matches(site: Site) -> Bool {
        let isCatPaw = site.raw["catPawOpen"] != nil
        switch self {
        case .catpaw: return isCatPaw
        case .py: return FinchSourceGrouping.bucket(for: site) == .py
        case .rex: return FinchSourceGrouping.bucket(for: site) == .rex
        case .html: return FinchSourceGrouping.bucket(for: site) == .html
        case .js: return FinchSourceGrouping.bucket(for: site) == .js && !isCatPaw
        }
    }
}

/// One site queued for a hard delete: the site plus the origin of the
/// subscription that owns it (the same site can appear under several origins).
struct FinchSiteDelete: Hashable {
    let site: Site
    let origin: URL
}

enum FinchSourceGrouping {
    /// A site's bucket. WebHome first, then Rex, then the api runtime.
    static func bucket(for site: Site) -> FinchSourceBucket {
        if site.webHomePage { return .html }
        if site.detectedRex == true { return .rex }
        switch site.runtime {
        case .python: return .py
        case .javascript: return .js
        default: return .other
        }
    }

    /// Whether the site came from a file on this device: its subscription's
    /// address is on the importer's reserved host.
    static func isLocal(site: Site, fallback: URL) -> Bool {
        ImportedFiles.isImported(site.origin(or: fallback).absoluteString)
    }

    /// Whether a whole source group is local (imported from a file on this
    /// device). A group is local when its first site's subscription is.
    static func isLocalGroup(_ group: SourceGroup, fallback: URL) -> Bool {
        guard let site = group.sites.first else { return false }
        return isLocal(site: site, fallback: fallback)
    }

    /// Splits already-ordered sites into non-empty buckets, keeping the
    /// upstream order inside each bucket. Bucket order is fixed:
    /// Py, web, Rex, JS, other.
    static func bucketed(_ sites: [Site]) -> [(FinchSourceBucket, [Site])] {
        var ordered: [(FinchSourceBucket, [Site])] = []
        for site in sites {
            let bucket = bucket(for: site)
            if let index = ordered.firstIndex(where: { $0.0 == bucket }) {
                ordered[index].1.append(site)
            } else {
                ordered.append((bucket, [site]))
            }
        }
        let rank: [FinchSourceBucket: Int] = [.py: 0, .html: 1, .rex: 2, .js: 3, .other: 4]
        return ordered.sorted { (rank[$0.0] ?? 9) < (rank[$1.0] ?? 9) }
    }

    /// Section title for a (local?, bucket) pair, e.g. "本地源 · Py".
    static func sectionTitle(local: Bool, bucket: FinchSourceBucket) -> String {
        (local ? "本地源 · " : "订阅源 · ") + bucket.title
    }

    /// A site's content category: the viewer's override, else keyword
    /// derivation from the title.
    static func category(for site: Site, origin: URL) -> FinchSourceCategory {
        FinchSourceOverrides.shared.categoryOverride(for: site, origin: origin)
            ?? FinchSourceCategory.derive(from: site.name)
    }

    /// Splits already-ordered sites into non-empty categories in the fixed
    /// category order. Inside a category, sites stay in bucket order
    /// (Py, web, Rex, JS, other) via the existing bucketed() logic.
    static func categorized(_ sites: [Site], origin: URL) -> [(FinchSourceCategory, [Site])] {
        var ordered: [(FinchSourceCategory, [Site])] = []
        for site in sites {
            let category = category(for: site, origin: origin)
            if let index = ordered.firstIndex(where: { $0.0 == category }) {
                ordered[index].1.append(site)
            } else {
                ordered.append((category, [site]))
            }
        }
        let rank: [FinchSourceCategory: Int] = [.movie: 0, .drama: 1, .anime: 2, .adult: 3, .netdisk: 4, .other: 5]
        return ordered
            .map { (category, sites) in (category, bucketed(sites).flatMap(\.1)) }
            .sorted { (rank[$0.0] ?? 9) < (rank[$1.0] ?? 9) }
    }

    /// The "Py · 本地" caption for a source card/row: type first, then
    /// origin. nil when there is no subscription origin to judge local
    /// against (the card is shown without a subscription).
    static func cardSuffix(for site: Site, fallback: URL?) -> String? {
        guard let fallback else { return nil }
        let local = isLocal(site: site, fallback: fallback)
        return "\(bucket(for: site).shortTitle) · \(local ? "本地" : "订阅")"
    }

    /// Runtime-group counts over visible (non-hidden) sites, in display
    /// order: 猫源, Py, Rex, 网页, JS. The JS row is only listed when it
    /// has sites — most installs have none.
    static func runtimeCounts(sites: [Site]) -> [(FinchRuntimeGroup, Int)] {
        let groups: [FinchRuntimeGroup] = [.catpaw, .py, .rex, .html, .js]
        var counts: [(FinchRuntimeGroup, Int)] = []
        for group in groups {
            let count = sites.count(where: group.matches)
            if group == .js && count == 0 { continue }
            counts.append((group, count))
        }
        return counts
    }
}

/// Sort for the source lists (Manage and the Sources tab): by name, or by
/// how often the source was opened (Sources tab card tap). Frequency falls
/// back to name for ties and for never-opened sources, so a fresh install
/// reads as name order.
enum FinchSourceSort: Hashable {
    case name, frequency
}
