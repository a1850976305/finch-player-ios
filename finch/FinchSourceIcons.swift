import SwiftUI
import TVCore

/// One kind of source, one look: a colored circular SF Symbol, used in the
/// same form in the import chooser rows, the runtime group rows and the
/// source rows, so a kind is recognizable everywhere (Arcane reference).
/// Stock SwiftUI only — no custom design system, no new dependencies.
struct FinchKindIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .accessibilityHidden(true)
    }
}

enum FinchKindIcons {
    /// Icon for a runtime bucket. A CatPaw bundle is a Node server, not a
    /// plain JS spider, so it gets the antenna icon even though its runtime
    /// reads as JavaScript.
    static func icon(for site: Site) -> FinchKindIcon {
        if site.raw["catPawOpen"] != nil {
            return FinchKindIcon(symbol: "antenna.radiowaves.left.and.right", color: .orange)
        }
        return icon(for: FinchSourceGrouping.bucket(for: site))
    }

    static func icon(for bucket: FinchSourceBucket) -> FinchKindIcon {
        switch bucket {
        case .py: return FinchKindIcon(symbol: "braces", color: .blue)
        case .html: return FinchKindIcon(symbol: "globe", color: .green)
        case .rex: return FinchKindIcon(symbol: "sparkles", color: .purple)
        case .js: return FinchKindIcon(symbol: "doc.text", color: .teal)
        case .other: return FinchKindIcon(symbol: "questionmark", color: .gray)
        }
    }

    static func icon(for group: FinchRuntimeGroup) -> FinchKindIcon {
        switch group {
        case .catpaw: return FinchKindIcon(symbol: "antenna.radiowaves.left.and.right", color: .orange)
        case .py: return FinchKindIcon(symbol: "braces", color: .blue)
        case .rex: return FinchKindIcon(symbol: "sparkles", color: .purple)
        case .html: return FinchKindIcon(symbol: "globe", color: .green)
        case .js: return FinchKindIcon(symbol: "doc.text", color: .teal)
        }
    }

    /// Icons for the guided import chooser rows.
    static func importIcon(_ kind: FinchURLImportKind) -> FinchKindIcon {
        switch kind {
        case .subscription: return FinchKindIcon(symbol: "link", color: .blue)
        case .rexComponent: return FinchKindIcon(symbol: "sparkles", color: .purple)
        case .rexSubscription: return FinchKindIcon(symbol: "square.stack.3d.up", color: .purple)
        case .webHome: return FinchKindIcon(symbol: "globe", color: .green)
        case .localFile: return FinchKindIcon(symbol: "doc.badge.plus", color: .indigo)
        case .localFolder: return FinchKindIcon(symbol: "folder.badge.plus", color: .orange)
        }
    }
}
