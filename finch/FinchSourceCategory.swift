import Foundation
import TVCore

/// What a source is *about*, for grouping sources by content first — the
/// viewer asked for sources to be categorized, not just split by runtime.
/// Order is fixed: 影视, 短剧, 动漫, 成人, 网盘, 其他.
///
/// Derivation is by keywords in the source title/name; a per-source
/// override (edit sheet) beats derivation and is stored in
/// FinchSourceOverrides. The keyword lists are deliberately the ones the
/// viewer approved — do not extend them by guessing (e.g. a lone "Hanime1"
/// component derives as 其他 unless its .fwd prefix says otherwise or the
/// viewer picks a category; the picker exists for exactly that).
enum FinchSourceCategory: String, CaseIterable, Codable, Hashable {
    case movie, drama, anime, adult, netdisk, other

    /// Display order: 影视, 短剧, 动漫, 成人, 网盘, 其他.
    static let ordered: [FinchSourceCategory] = [.movie, .drama, .anime, .adult, .netdisk, .other]

    var title: String {
        switch self {
        case .movie: return "影视"
        case .drama: return "短剧"
        case .anime: return "动漫"
        case .adult: return "成人"
        case .netdisk: return "网盘"
        case .other: return "其他"
        }
    }

    /// Derive from the source title/name. Check order matters: "短剧"
    /// contains "剧", so drama is checked before movie; "91成人" under a
    /// "短剧 -" prefix is still drama because the prefix mapping below
    /// runs first for .fwd widgets.
    static func derive(from name: String) -> FinchSourceCategory {
        let text = name.lowercased()
        if text.contains("短剧") { return .drama }
        if ["动漫", "番剧", "里番"].contains(where: text.contains) { return .anime }
        if ["网盘", "盘搜", "全盘", "木偶", "玩偶", "花卷", "蜗牛"].contains(where: text.contains) { return .netdisk }
        if ["av", "jav", "成人", "国产", "麻豆", "蜜桃", "花都", "17rip", "missav", "jable", "supjav", "123av", "134x", "肉视频"].contains(where: text.contains) { return .adult }
        if ["影视", "剧", "影院", "韩剧", "低端", "荐片"].contains(where: text.contains) { return .movie }
        return .other
    }

    /// A .fwd manifest widget title's prefix ("AV&国产 - 123AV" → "AV&国产")
    /// maps to a category; nil means fall back to keyword derivation.
    static func fromManifestPrefix(_ title: String) -> FinchSourceCategory? {
        let prefix = title.split(separator: "-").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? title
        switch prefix.lowercased() {
        case "av&国产": return .adult
        case "短剧": return .drama
        case "影视": return .movie
        case "网盘": return .netdisk
        default: return nil
        }
    }
}
