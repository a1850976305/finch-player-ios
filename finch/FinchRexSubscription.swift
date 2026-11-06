import Foundation
import TVCore

/// A Rex subscription manifest (".fwd", ForwardWidget format), e.g.
/// https://rex.uou.qzz.io/widgets.fwd:
/// {name, title, description, icon, widgets: [{id, title, description,
/// version, author, icon, url}]} — each url is one .js component.
/// Decoding is tolerant: a missing field defaults instead of failing the
/// whole manifest, because third-party manifests are not all tidy.
struct FinchFwdManifest: Decodable {
    var name: String
    var title: String
    var widgets: [FinchFwdWidget]

    private enum CodingKeys: String, CodingKey { case name, title, widgets }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        widgets = try container.decodeIfPresent([FinchFwdWidget].self, forKey: .widgets) ?? []
    }
}

struct FinchFwdWidget: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var description: String
    var version: String
    var author: String
    var url: String

    private enum CodingKeys: String, CodingKey { case id, title, description, version, author, url }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
    }

    /// The widget's content category: its manifest title prefix first
    /// ("AV&国产", "短剧", "影视", "网盘"), else keyword derivation.
    var category: FinchSourceCategory {
        FinchSourceCategory.fromManifestPrefix(title) ?? FinchSourceCategory.derive(from: title)
    }

    /// The local filename the component is stored under: its manifest id,
    /// so re-importing the same widget replaces the same copy.
    var filename: String {
        let base = id.isEmpty ? title : id
        let clean = base.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: .whitespaces)
        return (clean.isEmpty ? "rex-component" : clean) + ".js"
    }
}

/// What was imported from a .fwd manifest, so a refresh can offer new or
/// updated widgets: the manifest URL, its name, and per-widget the version
/// that was last imported. Stored in UserDefaults — this is a record of
/// what the viewer imported, not a deleted-source record.
struct FinchRexSubscriptionRecord: Codable {
    var manifestURL: String
    var name: String
    var imported: [String: String]

    var importedCount: Int { imported.count }
}

final class FinchRexSubscriptions: @unchecked Sendable {
    static let shared = FinchRexSubscriptions()

    private let defaults = UserDefaults.standard
    private(set) var records: [FinchRexSubscriptionRecord] = []

    private init() {
        if let data = defaults.data(forKey: "finch.rexSubscriptions"),
           let value = try? JSONDecoder().decode([FinchRexSubscriptionRecord].self, from: data) {
            records = value
        }
    }

    func record(for manifestURL: String) -> FinchRexSubscriptionRecord? {
        records.first { $0.manifestURL == manifestURL }
    }

    func markImported(manifestURL: String, name: String, widget: FinchFwdWidget) {
        if let index = records.firstIndex(where: { $0.manifestURL == manifestURL }) {
            records[index].imported[widget.id] = widget.version
            if !name.isEmpty { records[index].name = name }
        } else {
            records.append(FinchRexSubscriptionRecord(manifestURL: manifestURL, name: name, imported: [widget.id: widget.version]))
        }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(records), forKey: "finch.rexSubscriptions")
    }
}

/// The (id, version) a local Rex component declares in WidgetMetadata,
/// for the module-style row treatment: "forward.supjav.tut · v1.3.1".
/// Read from the imported file copy; nil when the component declares
/// neither, or the source is not a local file.
enum FinchRexInfo {
    static func info(for site: Site) -> (id: String?, version: String?) {
        guard site.detectedRex == true, let url = URL(string: site.api) else { return (nil, nil) }
        guard let text = ImportedFiles.localHTML(at: url) else { return (nil, nil) }
        let head = String(text.prefix(256 * 1024))
        guard let meta = head.range(of: "WidgetMetadata") else { return (nil, nil) }
        let rest = head[meta.upperBound...].prefix(8192)
        let id = rest.firstMatch(of: #/(?:^|\n)[ \t]*id[ \t]*:[ \t]*["']([^"'\n]{1,80})["']/#).map { String($0.1) }
        let version = rest.firstMatch(of: #/(?:^|\n)[ \t]*version[ \t]*:[ \t]*["']([^"'\n]{1,40})["']/#).map { String($0.1) }
        return (id, version)
    }

    /// One-line caption for a Rex row, e.g. "forward.supjav.tut · v1.3.1".
    static func caption(for site: Site) -> String? {
        let info = info(for: site)
        switch (info.id, info.version) {
        case let (id?, version?): return "\(id) · v\(version)"
        case let (id?, nil): return id
        case let (nil, version?): return "v\(version)"
        case (nil, nil): return nil
        }
    }
}

enum FinchImportError: LocalizedError {
    case badURL
    case downloadFailed(String)
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "这个地址打不开，检查一下是不是复制全了。"
        case .downloadFailed(let detail): return "下载失败：\(detail)"
        case .importFailed(let detail): return "导入失败：\(detail)"
        }
    }
}

extension Store {
    /// Fetches a URL's bytes with a 30-second timeout. Plain URLSession —
    /// no TVCore http client needed for a one-off download.
    static func fetchBytes(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("FinchPlayer/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw FinchImportError.downloadFailed("服务器返回了异常状态")
            }
            return data
        } catch let error as FinchImportError {
            throw error
        } catch {
            throw FinchImportError.downloadFailed(error.localizedDescription)
        }
    }

    /// Downloads a remote file and imports it through the normal file-import
    /// path (ImportedFiles copy + singleSpider sniffing), so a .js URL
    /// becomes a Rex source and an .html URL becomes a WebHome source
    /// exactly like picking the same file. Returns the imported sites.
    func importDownloadedFile(data: Data, filename: String) async throws -> [Site] {
        let before = Set(subscriptions.map(\.address))
        let clean = filename.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { throw FinchImportError.badURL }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(clean)
        do {
            try data.write(to: tmp, options: .atomic)
        } catch {
            throw FinchImportError.downloadFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        await importSubscriptionFile(tmp)
        if let error = importError {
            throw FinchImportError.importFailed(error)
        }
        let added = subscriptions.filter { !before.contains($0.address) }
        return added.compactMap { documents[$0.address]?.sites }.flatMap { $0 }
    }
}
