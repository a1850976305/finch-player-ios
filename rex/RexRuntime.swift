import Foundation
import TVCore

/// Runs Rex components (WidgetMetadata + loadList/loadDetail/search/
/// loadResource) in the same QuickJS host TVBox spiders use. A component is
/// NOT a TVBox spider, so it runs through the generic module session
/// (ScriptSession.start(module:supplied:), as Manga and LX do) with the
/// bundled rex-adapter.js defining the `Widget` global and translating TVBox
/// catalog calls into Rex handler calls.
///
/// Sessions are keyed by script address + site key and kept at most 10,
/// LRU-evicted — the same shape as ScriptRuntime's cache. Re-importing a
/// changed component file under the same address needs an app restart to
/// pick it up, exactly like a changed TVBox spider.
actor RexRuntime {
    static let shared = RexRuntime()

    private var sessions: [String: ScriptSession] = [:]
    private var recent: [String] = []
    private var probes: [String: Bool] = [:]
    private static let maximumSessions = 10

    /// Whether the script at this address is a Rex component, cached per
    /// address. Used for `.js` sources whose type was not decided at import.
    func isRex(site: Site, scriptURL: URL, http: HTTPClient) async -> Bool {
        let key = scriptURL.absoluteString
        if let cached = probes[key] { return cached }
        let result: Bool
        do {
            let (data, _) = try await http.get(scriptURL)
            result = Site.sniffedRex(data)
        } catch {
            result = false
        }
        probes[key] = result
        return result
    }

    /// Runs one TVBox catalog call through the component and returns the
    /// decoded TVBox-shaped JSON ({class, list, pagecount} / {url, header}).
    func request(site: Site, scriptURL: URL, params: [String: String], http: HTTPClient, origin: URL) async throws -> [String: JSONValue] {
        let session = try await self.session(site: site, scriptURL: scriptURL, http: http)
        let json = (try? String(decoding: JSONSerialization.data(withJSONObject: params), as: UTF8.self)) ?? "{}"
        let envelope = await session.evaluate("__rex.call(\(json))", within: 60)
        if let message = envelope["value"]?.object?["error"]?.string ?? envelope["error"]?.string {
            Diagnostics.shared.record(.error, "rex.request", "source=\(site.key) \(message.prefix(200))")
            throw TVError.unsupported(message)
        }
        guard let text = envelope["value"]?.object?["result"]?.string, !text.isEmpty else {
            throw TVError.unsupported(L10n.text("The plugin returned no content. Try another source."))
        }
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
    }

    private func session(site: Site, scriptURL: URL, http: HTTPClient) async throws -> ScriptSession {
        let key = PluginChecksum.sha256(Data((scriptURL.absoluteString + "\n" + site.key).utf8))
        if let existing = sessions[key] {
            recent.removeAll { $0 == key }
            recent.append(key)
            return existing
        }
        let (data, _) = try await http.get(scriptURL)
        let source = String(decoding: data, as: UTF8.self)
        let profile = ScriptAssets.profiles.appendingPathComponent(
            "rex-" + PluginChecksum.sha256(Data((site.key + "\n" + scriptURL.absoluteString).utf8)), isDirectory: true)
        let session = try await ScriptSession.start(
            module: "assets://rex/rex-adapter.js",
            supplied: ["rex://component": source],
            profile: profile,
            label: "rex " + site.key)
        let booted = await session.evaluate("__rex.load()", within: 30)
        if booted["value"]?.object?["ready"] == nil {
            session.close()
            let reason = booted["value"]?.object?["error"]?.string ?? booted["error"]?.string ?? "The Rex component did not start"
            throw TVError.unsupported(L10n.text("Plugin error: %@", String(reason.prefix(300))))
        }
        sessions[key] = session
        recent.append(key)
        while recent.count > Self.maximumSessions {
            let evicted = recent.removeFirst()
            sessions.removeValue(forKey: evicted)?.close()
        }
        return session
    }
}
