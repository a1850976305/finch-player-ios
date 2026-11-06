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
}
