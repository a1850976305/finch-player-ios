#!/bin/bash
# Apply Finch branding to a fresh Yingxia checkout.
# Run by the GitHub Actions workflow, NOT by hand on a phone.
# Only the visible name and the iOS bundle ID change. Internal
# identifiers (yingxia:// URL scheme, _yingxia._tcp Bonjour type,
# TVBox scheme/target names) are deliberately left alone, because
# app code references them for handoff and Play On discovery.
set -euo pipefail
ROOT="${1:-yingxia}"
cd "$ROOT"

# Display name: Yingxia -> Finch Player (project.yml, base + template).
sed -i '' 's/INFOPLIST_KEY_CFBundleDisplayName: Yingxia/INFOPLIST_KEY_CFBundleDisplayName: Finch Player/' project.yml 2>/dev/null \
  || sed -i 's/INFOPLIST_KEY_CFBundleDisplayName: Yingxia/INFOPLIST_KEY_CFBundleDisplayName: Finch Player/' project.yml
sed -i '' 's/CFBundleDisplayName: Yingxia/CFBundleDisplayName: Finch Player/' project.yml 2>/dev/null \
  || sed -i 's/CFBundleDisplayName: Yingxia/CFBundleDisplayName: Finch Player/' project.yml

# iOS bundle ID only (macOS/tvOS targets untouched).
sed -i '' 's/com\.jo32\.yingxia\.ios/com.finch.player.ios/' project.yml 2>/dev/null \
  || sed -i 's/com\.jo32\.yingxia\.ios/com.finch.player.ios/' project.yml

# Swift 6.2 type-check fix (Xcode 26.3 runner, 2026-11-04): the one-line
# map expression in Pan115Files.derive exceeds the compiler's
# type-check budget ("unable to type-check this expression in
# reasonable time"). Rewrite it as an explicit loop with typed
# intermediates. Semantics are identical:
#   result[i] = (seed[i] &+ table[size*i]) ^ table[size*(size-i-1)]
python3 - <<'PYEOF'
import pathlib, sys
p = pathlib.Path("Sources/TVCore/Pan115Files.swift")
text = p.read_text()
old = """    static func derive(_ seed: [UInt8], _ size: Int) -> [UInt8] {
        (0..<size).map { (seed[$0] &+ table[size * $0]) ^ table[size * (size - $0 - 1)] }
    }
"""
new = """    static func derive(_ seed: [UInt8], _ size: Int) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(size)
        for i in 0..<size {
            let a: UInt8 = seed[i] &+ table[size * i]
            let b: UInt8 = table[size * (size - i - 1)]
            result.append(a ^ b)
        }
        return result
    }
"""
if old not in text:
    print("Pan115Files.derive pattern not found; refusing to patch blindly", file=sys.stderr)
    sys.exit(1)
p.write_text(text.replace(old, new, 1))
print("Pan115Files.derive rewritten as an explicit loop")
PYEOF

# Swift 6 capture fix (Xcode 26.3 runner, 2026-11-04): in
# Subscription.sniffingScripts, the closure on the `pending` line
# captures `sites` textually before the local `var sites = sites`
# that shadows the property, so the compiler rejects it
# ("closure captures 'sites' before it is declared"). Moving the
# local copy above the `pending` line is semantics-identical:
# the copy is initialized from the property and nothing mutates
# either one in between, so the filter sees the same elements,
# and the early-return path still returns `self` untouched.
python3 - <<'PYEOF'
import pathlib, sys
p = pathlib.Path("Sources/TVCore/ScriptSniffing.swift")
text = p.read_text()
old = """    func sniffingScripts(http: HTTPClient) async -> Subscription {
        let pending = sites.indices.filter { sites[$0].needsSniffing }
        guard !pending.isEmpty else { return self }
        var sites = sites
"""
new = """    func sniffingScripts(http: HTTPClient) async -> Subscription {
        var sites = sites
        let pending = sites.indices.filter { sites[$0].needsSniffing }
        guard !pending.isEmpty else { return self }
"""
if old not in text:
    print("ScriptSniffing.sniffingScripts pattern not found; refusing to patch blindly", file=sys.stderr)
    sys.exit(1)
p.write_text(text.replace(old, new, 1))
print("ScriptSniffing.sniffingScripts reordered so the local sites copy precedes the closure")
PYEOF

# iOS 26 build fixes (Xcode 26.3 / SDK 26.2 runner, 2026-11-04):
# the user's phone is iOS 26, so iOS 27-only code paths would never
# run there anyway (#available(iOS 27) is false on iOS 26). Stubbing
# them to their iOS 26 fallback is semantics-identical on iOS 26,
# and it lets the released SDK compile upstream main at all.
# The other four are Swift 6.2 strictness/type-inference fixes.
python3 - <<'PYEOF'
import pathlib, sys

def patch(path, old, new, label):
    p = pathlib.Path(path)
    text = p.read_text()
    if old not in text:
        print(f"{label}: pattern not found in {path}; refusing to patch blindly", file=sys.stderr)
        sys.exit(1)
    p.write_text(text.replace(old, new, 1))
    print(f"{label}: patched")

# 1. ExternalDisplay: iOS 27 scene accessory does not exist in SDK 26.2.
# On iOS 26 the registrar already returned a plain UIViewController,
# so always returning one is identical on the user's phone.
patch("App/ExternalDisplay.swift",
      "        if #available(iOS 27.0, *) { return ExternalDisplayAccessoryController() }\n        return UIViewController()",
      "        return UIViewController()",
      "ExternalDisplay registrar")
patch("App/ExternalDisplay.swift",
      "    private var registration: UISceneAccessoryRegistration?",
      "    private var registration: Any?",
      "ExternalDisplay registration type")
patch("App/ExternalDisplay.swift",
      "        registration = registerSceneAccessory(UISceneAccessory.externalNonInteractive(sceneConfiguration: configuration))",
      "        registration = nil // iOS 27 accessory removed for iOS 26 SDK build",
      "ExternalDisplay register call")
patch("App/ExternalDisplay.swift",
      "        unregisterSceneAccessory(registration)",
      "        // iOS 27 accessory removed for iOS 26 SDK build",
      "ExternalDisplay unregister call")

# 2. VideoEnhancement: iOS 27 interpolator limit query does not exist
# in SDK 26.2. On iOS 26 the function already fell through to this
# 1280x720 bound, so returning it directly is identical there.
patch("App/VideoEnhancement.swift",
      """    private static func interpolationFits(width: Int, height: Int) -> Bool {
        if #available(macOS 27, iOS 27, tvOS 27, *) {
            guard let side = VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: 1),
                  let pixels = VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: 1) else { return false }
            return max(width, height) <= side && width * height <= pixels
        }
        return max(width, height) <= 1280 && width * height <= 1280 * 720
    }""",
      """    private static func interpolationFits(width: Int, height: Int) -> Bool {
        // iOS 27 query removed for iOS 26 SDK build; on iOS 26 this
        // fallback was already the path taken.
        return max(width, height) <= 1280 && width * height <= 1280 * 720
    }""",
      "VideoEnhancement interpolationFits")

# 3. DiscoverArtwork: CGFloat vs Double '-' ambiguity. All operands
# are CGFloat, so annotate the literals as CGFloat explicitly.
patch("App/DiscoverArtwork.swift",
      "                    .opacity(max(0, 1 - max(0, scrollY - heroHeight * 0.45) / (heroHeight * 0.55)))",
      "                    .opacity(max(CGFloat(0), CGFloat(1) - max(CGFloat(0), scrollY - heroHeight * CGFloat(0.45)) / (heroHeight * CGFloat(0.55))))",
      "DiscoverArtwork opacity")

# 4. DiscoverSearchView: erfc overload ambiguity. Make `outside`
# explicitly CGFloat so the CGFloat erfc overload is unambiguous.
patch("App/DiscoverSearchView.swift",
      "            let outside = (location * reach - half) / blur",
      "            let outside: CGFloat = (CGFloat(location) * reach - half) / blur",
      "DiscoverSearchView erfc")

# 5. LiveRoomsView: Result's closure is synchronous, so `try await`
# inside it cannot be passed as a synchronous function. Restructure
# to do/catch inside the async task closure; same success/failure
# values are delivered to the task group.
patch("App/LiveRoomsView.swift",
      "group.addTask { await (platform, Result { try await LiveCatalog.search(platform, keyword: query) }) }",
      "group.addTask { do { return (platform, .success(try await LiveCatalog.search(platform, keyword: query))) } catch { return (platform, .failure(error)) } }",
      "LiveRoomsView task group")

# 6. DiscoverView (DiscoverHero): break the body up the way the
# compiler asks ("distinct sub-expressions"). The subtitle and
# overview strings are computed once as typed String lets before
# the GeometryReader, then used as plain Text(String) values.
patch("App/DiscoverView.swift",
      """    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    if let logo = details?.logo {
                        TMDBArtwork(url: logo, maxPixels: 1000, fill: false)
                            .accessibilityLabel(item.name)
                    } else {
                        Text(item.name).font(.system(size: 40, weight: .semibold))
                            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    }
                }""",
      """    var body: some View {
        let subtitle: String = [details?.genres.prefix(2).joined(separator: " / ") ?? item.genreNames,
                      details?.date ?? item.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let overview: String = "「\\(item.name)」" + item.overview
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    if let logo = details?.logo {
                        TMDBArtwork(url: logo, maxPixels: 1000, fill: false)
                            .accessibilityLabel(item.name)
                    } else {
                        Text(item.name).font(.system(size: 40, weight: .semibold))
                            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    }
                }""",
      "DiscoverView hero lets")
patch("App/DiscoverView.swift",
      """                Text([details?.genres.prefix(2).joined(separator: " / ") ?? item.genreNames,
                      details?.date ?? item.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 14)).lineLimit(1).frame(height: 17)""",
      """                Text(subtitle)
                    .font(.system(size: 14)).lineLimit(1).frame(height: 17)""",
      "DiscoverView hero subtitle")
patch("App/DiscoverView.swift",
      """                Text("「\\(item.name)」" + item.overview)
                    .font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)""",
      """                Text(overview)
                    .font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)""",
      "DiscoverView hero overview")
PYEOF

# Follow-up fixes (2026-11-04, run 41833962542): the iOS 26 patch
# cleared 8 of the 10 step-9 errors, leaving 2 in the same two files.
# DiscoverArtwork had a second, unpatched opacity expression with
# the same CGFloat/Double '-' ambiguity (line 162, trailer branch);
# the erfc fix alone was not enough, because the argument itself
# was still convertible to both Double and CGFloat, so force the
# whole erfc argument to Double (the C erfc overload) explicitly.
python3 - <<'PYEOF'
import pathlib, sys

def patch(path, old, new, label):
    p = pathlib.Path(path)
    text = p.read_text()
    if old not in text:
        print(f"{label}: pattern not found in {path}; refusing to patch blindly", file=sys.stderr)
        sys.exit(1)
    p.write_text(text.replace(old, new, 1))
    print(f"{label}: patched")

patch("App/DiscoverArtwork.swift",
      "                    .opacity(max(0, 1 - max(0, scrollY) / (heroHeight * 0.35)))",
      "                    .opacity(max(CGFloat(0), CGFloat(1) - max(CGFloat(0), scrollY) / (heroHeight * CGFloat(0.35))))",
      "DiscoverArtwork trailer opacity")
patch("App/DiscoverSearchView.swift",
      "erfc(outside / 2.squareRoot())",
      "erfc(Double(outside) / Double(2).squareRoot())",
      "DiscoverSearchView erfc Double")
PYEOF


# WebHome step 1 (2026-11-05): WKWebView + fm bridge for homePage sites.
# New files live in the starter repo's webhome/ directory; the CI layout is
# starter-root/webhome/ next to starter-root/yingxia/, so from inside the
# upstream checkout they are at ../webhome/. The App target's SharedApp
# template globs the whole App/ directory, so dropped-in files need no
# project.yml change.
if [ -d ../webhome ]; then
  cp ../webhome/WebHomeSite.swift ../webhome/WebHomeGateway.swift ../webhome/WebHomeView.swift App/
else
  echo "webhome/ directory not found next to the upstream checkout; refusing to patch blindly" >&2
  exit 1
fi

# SiteView hook: a site declaring homePage renders the WebHome view instead
# of the native recommendation page. All other sites keep the exact old path
# (the else-if chain preserves the canLoad / native branches untouched).
python3 - <<'PYEOF'
import pathlib, sys
p = pathlib.Path("App/SitesView.swift")
text = p.read_text()
old = """    var body: some View {
        Group {
            if !canLoad {
                ContentUnavailableView {
"""
new = """    var body: some View {
        Group {
            if site.webHomePage {
                WebHomeView(site: site, origin: origin)
            } else if !canLoad {
                ContentUnavailableView {
"""
if old not in text:
    print("SitesView SiteView body pattern not found; refusing to patch blindly", file=sys.stderr)
    sys.exit(1)
p.write_text(text.replace(old, new, 1))
print("SitesView: WebHome hook added")
PYEOF
# Source management (2026-11-05, user request): WebHome sites are browsable,
# per-source delete/edit, multi-file and folder import.
python3 - <<'PYEOF'
import pathlib, sys

def patch(path, old, new, label):
    p = pathlib.Path(path)
    text = p.read_text()
    if old not in text:
        print(f"{label} pattern not found; refusing to patch blindly", file=sys.stderr)
        sys.exit(1)
    p.write_text(text.replace(old, new, 1))
    print(label)

# --- Finch source files into App/ ---
import shutil, os
for name in ("FinchSourceOverrides.swift", "FinchSourceManagement.swift", "FinchSourceBucket.swift", "FinchSourceCategory.swift", "FinchSourceIcons.swift", "FinchRexSubscription.swift", "FinchImportChooser.swift"):
    src = pathlib.Path("../finch") / name
    if not src.exists():
        print(f"finch/{name} missing; refusing to patch blindly", file=sys.stderr)
        sys.exit(1)
    shutil.copy(src, pathlib.Path("App") / name)
print("Finch source management files copied")

# --- Rex runtime files into TVCore (RexRuntime + adapter). The adapter is
# bundled under ScriptAssets/rex, which Package.swift copies whole, so it
# ships as assets://rex/rex-adapter.js. ---
for name, dest in (("RexRuntime.swift", "Sources/TVCore/RexRuntime.swift"),
                   ("rex-adapter.js", "Sources/TVCore/ScriptAssets/rex/rex-adapter.js")):
    src = pathlib.Path("../rex") / name
    if not src.exists():
        print(f"rex/{name} missing; refusing to patch blindly", file=sys.stderr)
        sys.exit(1)
    target = pathlib.Path(dest)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(src, target)
print("Rex runtime files copied")

# --- WebHome sites are browsable: a .html api classifies as JAR and iOS
# filters JAR sites without a spider out of every list, which is why the
# test subscription imported (1 source) but showed no source. A homePage
# site browses through its web page, not its api runtime. ---
patch("Sources/TVCore/Discovery.swift",
      """    public func canBrowse(jarURL: URL?) -> Bool {
        if isCloudFiles { return true }
""",
      """    public func canBrowse(jarURL: URL?) -> Bool {
        // A WebHome site browses through its web page, not its api runtime.
        for key in ["homePage", "home_page", "webHome", "web_home"] {
            if let text = raw[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return true }
        }
        if isCloudFiles { return true }
""",
      "Discovery WebHome browsable")

# --- TVCore helper: apply Finch per-source deletes/edits to a merged
# subscription. Construction must stay in TVCore: Site/Subscription
# memberwise inits are not public to the App target. ---
p = pathlib.Path("Sources/TVCore/SubscriptionMerge.swift")
text = p.read_text()
if "FinchSiteEdit" not in text:
    p.write_text(text + """
/// A Finch per-source edit: a new address, and a display remark (empty
/// remark keeps the original name). Defined here so the App target can
/// construct it; applied by Subscription.applyingFinchSourceChanges.
public struct FinchSiteEdit: Sendable {
    public let api: String
    public let remark: String
    public init(api: String, remark: String) { self.api = api; self.remark = remark }
}

extension Subscription {
    /// Rewrites Finch-edited sources (address and display name), keeping
    /// each site's provenance. Edit keys are "<subscription origin>|<sourceKey>".
    /// Deletion is NOT done here: delete is a hard delete in Store
    /// (Store.hardDeleteSites), which removes the stored data too, so a
    /// deleted source leaves no record behind.
    public func applyingFinchSourceChanges(edits: [String: FinchSiteEdit]) -> Subscription {
        var sites: [Site] = []
        for site in self.sites {
            let key = "\\(site.origin(or: origin).absoluteString)|\\(site.sourceKey)"
            if let edit = edits[key] {
                var raw = site.raw
                let newName = edit.remark.isEmpty ? site.name : edit.remark
                let newApi = edit.api.isEmpty ? site.api : edit.api
                raw["name"] = .string(newName)
                raw["api"] = .string(newApi)
                var newSite = Site(key: site.key, name: newName, type: site.type, api: newApi, raw: raw, detectedRuntime: site.detectedRuntime, detectedRex: site.detectedRex)
                newSite.provenance = site.provenance
                sites.append(newSite)
            } else {
                sites.append(site)
            }
        }
        return Subscription(origin: origin, importedAt: importedAt, sites: sites, lives: lives, raw: raw)
    }

    /// The same subscription without the sites whose keys are in `keys`
    /// ("<subscription origin>|<sourceKey>"). Used by hard delete to
    /// rewrite a local multi-site document without its deleted sites.
    public func removingSites(withKeys keys: Set<String>) -> Subscription {
        let kept = sites.filter { !keys.contains("\\($0.origin(or: origin).absoluteString)|\\($0.sourceKey)") }
        return Subscription(origin: origin, importedAt: importedAt, sites: kept, lives: lives, raw: raw)
    }
}
""")
    print("SubscriptionMerge Finch source changes")
else:
    print("SubscriptionMerge Finch source changes (already present)")

# --- Store: apply Finch changes on every rebuild, reload without refetch,
# and import a whole folder. ---
patch("App/Store.swift",
      "        subscription = Subscription.merge(subscriptions.filter(\\.enabled).compactMap { documents[$0.address] })?.withCloudSources(extrasUnlocked ? cloudDocument : nil)\n",
      "        subscription = Subscription.merge(subscriptions.filter(\\.enabled).compactMap { documents[$0.address] })?.applyingFinchSourceChanges(edits: FinchSourceOverrides.shared.tvCoreEdits).withCloudSources(extrasUnlocked ? cloudDocument : nil)\n",
      "Store apply Finch source changes")
patch("App/Store.swift",
      """    }
    /// Fetches Yingxia's own subscription while a subscription works: at once when there is no copy, else
""",
      """    }
    /// Re-applies the viewer's per-source deletes/edits without refetching.
    func reloadAfterFinchSourceChange() { rebuildSubscription() }
    /// Hard-deletes local sources: no record is kept and nothing can be
    /// restored, so a deleted source frees its stored data for good. A local
    /// single-site subscription loses the whole entry (file copy, cached
    /// document and stored data go with it, via removeSubscriptions); a
    /// local multi-site subscription is rewritten without the deleted sites.
    /// Remote sites are never accepted here: a remote site would return on
    /// the next refresh unless a record of the delete were kept, and the
    /// viewer asked for no records — remote sites are hidden, or the whole
    /// subscription is removed.
    func hardDeleteSites(_ sites: [(site: Site, origin: URL)]) {
        guard !sites.isEmpty, subscription != nil else { return }
        var byAddress: [String: [(site: Site, origin: URL)]] = [:]
        for item in sites {
            guard let address = documents.first(where: { $0.value.origin == item.origin })?.key,
                  ImportedFiles.isImported(address) else { continue }
            byAddress[address, default: []].append(item)
        }
        var whole: Set<String> = []
        for (address, items) in byAddress {
            guard let doc = documents[address] else { continue }
            let keys = Set(items.map { FinchSourceOverrides.shared.key(site: $0.site, origin: $0.origin) })
            if keys.count >= doc.sites.count {
                whole.insert(address)
            } else {
                let kept = doc.removingSites(withKeys: keys)
                if let entry = subscriptions.first(where: { $0.address == address }) { keep(kept, for: entry) }
            }
            FinchSourceOverrides.shared.removeEdits(forKeys: keys)
            FinchSourceOverrides.shared.removeCategories(forKeys: keys)
        }
        if !whole.isEmpty { removeSubscriptions(whole) }
        rebuildSubscription()
    }
    /// Fetches Yingxia's own subscription while a subscription works: at once when there is no copy, else
""",
      "Store reload after source change")
patch("App/Store.swift",
      """    /// Fetches every enabled subscription again; one that fails keeps its last good copy.
""",
      """    /// Imports every supported file in a folder the viewer picked: JSON
    /// subscriptions and .py / .js spiders, in filename order. Files that
    /// add nothing are not kept, exactly like single-file imports.
    func importSubscriptionFolder(_ folder: URL) async {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var files: [URL] = []
        collectImportFiles(in: folder, into: &files)
        files.sort { $0.path < $1.path }
        for file in files { await importSubscriptionFile(file) }
    }
    /// Folder walk without DirectoryEnumerator: its iterator is unavailable
    /// from async contexts under Swift 6. contentsOfDirectory is recursive
    /// here so nested folders import too.
    private func collectImportFiles(in folder: URL, into files: inout [URL]) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for item in items {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { collectImportFiles(in: item, into: &files) }
            else if ["json", "py", "js"].contains(item.pathExtension.lowercased()) { files.append(item) }
        }
    }
    /// Fetches every enabled subscription again; one that fails keeps its last good copy.
""",
      "Store folder import")

# --- SitesView: Manage button + sheet, and Delete in the card menu. ---
patch("App/SitesView.swift",
      "    @State private var choosingHidden = false\n",
      "    @State private var choosingHidden = false\n    @State private var managingSources = false\n    @State private var pendingSiteDelete: [FinchSiteDelete] = []\n    @State private var showingSiteDeleteConfirm = false\n",
      "SitesView managing state")
patch("App/SitesView.swift",
      """                .sheet(isPresented: $choosingHidden) { HiddenSourcesEditor() }
""",
      """                .sheet(isPresented: $choosingHidden) { HiddenSourcesEditor() }
                .sheet(isPresented: $managingSources) { FinchSourceManagementView() }
""",
      "SitesView management sheet")
patch("App/SitesView.swift",
      """        .modifier(SitesTitle(picking: pick != nil))
        .task(id: store.section) {
""",
      """        .modifier(SitesTitle(picking: pick != nil))
        .toolbar {
            if pick == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("管理") { managingSources = true }
                }
            }
        }
        .task(id: store.section) {
""",
      "SitesView manage toolbar")
patch("App/SitesView.swift",
      """                                            .contextMenu {
                                                PinSourceButton(site: site, origin: config.origin)
                                                HideSourceButton(site: site, origin: config.origin)
                                                if store.sourceOrder.enabled { MoveSourceButtons(site: site, sites: sites) }
                                            }
""",
      """                                            .contextMenu {
                                                PinSourceButton(site: site, origin: config.origin)
                                                HideSourceButton(site: site, origin: config.origin)
                                                if store.sourceOrder.enabled { MoveSourceButtons(site: site, sites: sites) }
                                                if FinchSourceGrouping.isLocal(site: site, fallback: config.origin) {
                                                    Button(role: .destructive) {
                                                        pendingSiteDelete = [FinchSiteDelete(site: site, origin: site.origin(or: config.origin))]
                                                        showingSiteDeleteConfirm = true
                                                    } label: { Label("删除源", systemImage: "trash") }
                                                }
                                            }
""",
      "SitesView card delete menu")

# --- SitesView: group sites by content category first inside each group
# (影视 / 短剧 / 动漫 / 成人 / 网盘 / 其他), sites in runtime order
# inside a category, and mark local (imported-file) groups with a
# "本地 ·" prefix, so category, subscription vs local and Py vs HTML are
# visible at a glance. Group structure, fold state, drag-reorder and
# search all stay upstream's. ---
patch("App/SitesView.swift",
      """                                LazyVGrid(columns: Layout.cardColumns, spacing: Layout.cardSpacing) {
                                    ForEach(group.sites) { site in
                                        if let pick {
                                            Button { pick(site); dismiss() } label: { SiteCard(site: site, chosen: site.key == picked) }.tileButton()
                                                .accessibilityAddTraits(site.key == picked ? .isSelected : [])
                                                .focused($focusedSite, equals: site.key)
                                                .id(site.key)
                                        } else {
                                        RouteLink { SiteView(site: site, origin: config.origin, jarURL: config.spiderURL) } label: { SiteCard(site: site, dimmed: group.kind == .hidden) }.tileButton()
                                            .contextMenu {
                                                PinSourceButton(site: site, origin: config.origin)
                                                HideSourceButton(site: site, origin: config.origin)
                                                if store.sourceOrder.enabled { MoveSourceButtons(site: site, sites: sites) }
                                                if FinchSourceGrouping.isLocal(site: site, fallback: config.origin) {
                                                    Button(role: .destructive) {
                                                        pendingSiteDelete = [FinchSiteDelete(site: site, origin: site.origin(or: config.origin))]
                                                        showingSiteDeleteConfirm = true
                                                    } label: { Label("删除源", systemImage: "trash") }
                                                }
                                            }
                                        }
                                    }
                                }
""",
      """                                LazyVGrid(columns: Layout.cardColumns, spacing: Layout.cardSpacing) {
                                    ForEach(FinchSourceGrouping.categorized(group.sites, origin: config.origin), id: \\.0) { category, categorySites in
                                        Section {
                                            ForEach(categorySites) { site in
                                                if let pick {
                                                    Button { pick(site); dismiss() } label: { SiteCard(site: site, chosen: site.key == picked) }.tileButton()
                                                        .accessibilityAddTraits(site.key == picked ? .isSelected : [])
                                                        .focused($focusedSite, equals: site.key)
                                                        .id(site.key)
                                                } else {
                                                RouteLink { SiteView(site: site, origin: config.origin, jarURL: config.spiderURL) } label: { SiteCard(site: site, dimmed: group.kind == .hidden) }.tileButton()
                                                    .contextMenu {
                                                        PinSourceButton(site: site, origin: config.origin)
                                                        HideSourceButton(site: site, origin: config.origin)
                                                        if store.sourceOrder.enabled { MoveSourceButtons(site: site, sites: sites) }
                                                        if FinchSourceGrouping.isLocal(site: site, fallback: config.origin) {
                                                            Button(role: .destructive) {
                                                                pendingSiteDelete = [FinchSiteDelete(site: site, origin: site.origin(or: config.origin))]
                                                                showingSiteDeleteConfirm = true
                                                            } label: { Label("删除源", systemImage: "trash") }
                                                        }
                                                    }
                                                }
                                            }
                                        } header: {
                                            Text("\(category.title) · \(categorySites.count) 个")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
""",
      "SitesView category sub-sections")
patch("App/SitesView.swift",
      "                            groupHeader(group)\n",
      "                            groupHeader(group, origin: config.origin)\n",
      "SitesView group header origin")
patch("App/SitesView.swift",
      "    private func groupHeader(_ group: SourceGroup) -> some View {\n",
      "    private func groupHeader(_ group: SourceGroup, origin: URL) -> some View {\n",
      "SitesView group header signature")
# groupHeader is a separate function, so the `config` local from body is
# NOT in scope there (Xcode 26.3, 2026-11-06: "cannot find 'config' in
# scope"). The subscription origin is passed in from the call site.
patch("App/SitesView.swift",
      """                Text(L10n.text(group.title)).font(.headline).lineLimit(1)
""",
      """                Text((FinchSourceGrouping.isLocalGroup(group, fallback: origin) ? "本地 · " : "") + L10n.text(group.title)).font(.headline).lineLimit(1)
""",
      "SitesView local group badge")
# --- SiteCard: show type + origin under the name ("Py · 本地"), so the
# card says what kind of source it is without opening it. The original
# expression is kept intact and the suffix appended. ---
patch("App/SitesView.swift",
      """        let detail = runs ? (label.parts.dropFirst() + [engine].compactMap { $0 }).joined(separator: " · ") : site.compatibility
""",
      """        let detail = (runs ? (label.parts.dropFirst() + [engine].compactMap { $0 }).joined(separator: " · ") : site.compatibility) + (FinchSourceGrouping.cardSuffix(for: site, fallback: store.subscription?.origin).map { " · \\($0)" } ?? "")
""",
      "SiteCard Finch detail suffix")
patch("App/SitesView.swift",
      """        .onChange(of: query) { old, new in
            if old.isEmpty && !new.isEmpty {
                foldBeforeSearch = collapsed
                collapsed = []
            } else if !old.isEmpty && new.isEmpty, let saved = foldBeforeSearch {
                collapsed = saved
                foldBeforeSearch = nil
            }
        }
    }
""",
      """        .onChange(of: query) { old, new in
            if old.isEmpty && !new.isEmpty {
                foldBeforeSearch = collapsed
                collapsed = []
            } else if !old.isEmpty && new.isEmpty, let saved = foldBeforeSearch {
                collapsed = saved
                foldBeforeSearch = nil
            }
        }
        .confirmationDialog("删除源", isPresented: $showingSiteDeleteConfirm) {
            Button("删除", role: .destructive) {
                store.hardDeleteSites(pendingSiteDelete.map { ($0.site, $0.origin) })
                pendingSiteDelete = []
            }
            Button("取消", role: .cancel) { pendingSiteDelete = [] }
        } message: {
            Text("将彻底删除 \\(pendingSiteDelete.count == 1 ? "「\\(pendingSiteDelete[0].site.name)」" : "\\(pendingSiteDelete.count) 个源（\\(pendingSiteDelete.prefix(3).map(\\.site.name).joined(separator: "、"))\\(pendingSiteDelete.count > 3 ? "等" : "")）")，数据也会一并清除，无法恢复。")
        }
    }
""",
      "SitesView delete confirmation")

# --- Settings (iOS Add Subscription sheet): multi-file pick + folder pick. ---
# SwiftUI rule learned 2026-11-05: two .fileImporter modifiers on ONE view
# shadow each other and neither presents (that is why Add from File did
# nothing). Each importer lives on its own view: file on the sheet root,
# folder on its Section.
patch("App/SettingsView.swift",
      """private struct AddSubscriptionSheet: View {
    @Environment(Store.self) private var store
    @Environment(\\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var choosesFile = false
""",
      """private struct AddSubscriptionSheet: View {
    @Environment(Store.self) private var store
    @Environment(\\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var choosesFile = false
    @State private var choosesFolder = false
""",
      "Settings folder state")
patch("App/SettingsView.swift",
      """                Section {
                    Button { choosesFile = true } label: {
                        FormLabel(symbol: "doc.badge.plus", tint: .orange, title: L10n.text("Add from File…"))
                            .foregroundStyle(.primary)
                    }
                    .disabled(store.importing)
                } footer: { Text(L10n.text("A TVBox JSON subscription, or one Python (.py) or JavaScript (.js) spider.")) }
""",
      """                Section {
                    Button { choosesFile = true } label: {
                        FormLabel(symbol: "doc.badge.plus", tint: .orange, title: L10n.text("Add from File…"))
                            .foregroundStyle(.primary)
                    }
                    .disabled(store.importing)
                } footer: { Text(L10n.text("A TVBox JSON subscription, or one Python (.py) or JavaScript (.js) spider. Pick several files at once.")) }
                Section {
                    Button { choosesFolder = true } label: {
                        FormLabel(symbol: "folder.badge.plus", tint: .orange, title: L10n.text("Add from Folder…"))
                            .foregroundStyle(.primary)
                    }
                    .disabled(store.importing)
                } footer: { Text(L10n.text("Every JSON, Python (.py) and JavaScript (.js) file in the folder is imported.")) }
                .fileImporter(isPresented: $choosesFolder, allowedContentTypes: [.folder]) { result in
                    guard case .success(let folder) = result else { return }
                    Task {
                        await store.importSubscriptionFolder(folder)
                        if store.importError == nil { dismiss() }
                    }
                }
""",
      "Settings folder button")
patch("App/SettingsView.swift",
      """        .fileImporter(isPresented: $choosesFile, allowedContentTypes: SubscriptionFile.types) { result in
            guard case .success(let file) = result else { return }
            Task {
                await store.importSubscriptionFile(file)
                if store.importError == nil { dismiss() }
            }
        }
""",
      """        .fileImporter(isPresented: $choosesFile, allowedContentTypes: SubscriptionFile.types, allowsMultipleSelection: true) { result in
            guard case .success(let files) = result else { return }
            Task {
                for file in files { await store.importSubscriptionFile(file) }
                if store.importError == nil { dismiss() }
            }
        }
""",
      "Settings multi-file + folder importers")
PYEOF

# Settings subscription import removed (2026-11-06): the Manage view now
# covers every import path (TVBox URL, file, folder, .fwd), so the
# "Add Subscription" row in Settings is redundant. Only the entry point
# (the row + its sheet presentation) is removed: the per-subscription
# detail rows, "Remove Subscriptions", and the "Refresh All" header stay,
# and AddSubscriptionSheet itself stays in the file as dead code — the
# Finch folder/multi-file patches above still apply to it, and deleting
# the whole struct would only add patch risk for no behaviour change.
python3 - <<'PYEOF'
import pathlib, sys

def patch(path, old, new, label):
    p = pathlib.Path(path)
    text = p.read_text()
    if old not in text:
        print(f"{label}: pattern not found in {path}; refusing to patch blindly", file=sys.stderr)
        sys.exit(1)
    p.write_text(text.replace(old, new, 1))
    print(f"{label}: patched")

patch("App/SettingsView.swift",
      """                #if os(iOS)
                // One row instead of an always-open field and three text buttons; the address goes in a sheet.
                Button { addingSubscription = true } label: {
                    FormLabel(symbol: "plus", tint: .green, title: L10n.text("Add Subscription")).foregroundStyle(.primary)
                }
                #else
""",
      """                #if os(iOS)
                // Finch: subscription import moved to the Manage view
                // (TVBox URL, file, folder, .fwd) — no add row here.
                #else
""",
      "Settings remove Add Subscription row")
patch("App/SettingsView.swift",
      "        .sheet(isPresented: $addingSubscription) { AddSubscriptionSheet() }\n",
      "",
      "Settings remove AddSubscriptionSheet presentation")
PYEOF

# Rex components (2026-11-06): a Rex component is a .js file, but it is NOT
# a TVBox spider, so it must be detected by its WidgetMetadata marker and
# run through RexRuntime (rex-adapter.js defines the Widget global), never
# through the spider path. Detection happens at import (singleSpider) and
# at refresh (sniffingScripts) for JSON-listed sites, with a request-time
# probe as a fallback in CatalogClient.perform.
python3 - <<'PYEOF'
import pathlib, sys

def patch(path, old, new, label):
    p = pathlib.Path(path)
    text = p.read_text()
    if old not in text:
        print(f"{label} pattern not found; refusing to patch blindly", file=sys.stderr)
        sys.exit(1)
    p.write_text(text.replace(old, new, 1))
    print(label)

# --- Site.detectedRex: a .js api that turned out to be a Rex component. ---
patch("Sources/TVCore/Models.swift",
      """    public var detectedRuntime: SourceRuntime? = nil
""",
      """    public var detectedRuntime: SourceRuntime? = nil
    /// A `.js` api that turned out to be a Rex component (WidgetMetadata);
    /// see `Site.sniffedRex`. Rex is checked before the api runtime.
    public var detectedRex: Bool? = nil
""",
      "Site detectedRex")

# --- Rex sniffing: a bare global `WidgetMetadata = {...}` assignment in the
# first 256 KB. `var/let/const WidgetMetadata` is not one. ---
patch("Sources/TVCore/ScriptSniffing.swift",
      """    /// What a downloaded spider is, when its content says so. Python spiders all build on the
""",
      """    /// A type 3 `.js` api whose content has not been checked for a Rex
    /// component yet. Rex files are `.js`, so they never reach needsSniffing.
    var needsRexSniffing: Bool {
        guard type == 3, detectedRex == nil, runtime == .javascript else { return false }
        let scheme = URL(string: api.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// Whether a downloaded script is a Rex component: a bare global
    /// `WidgetMetadata = {...}` assignment. `var/let/const WidgetMetadata`
    /// is not one, and neither is a TVBox spider (its marker is a spider
    /// object, not a WidgetMetadata global).
    static func sniffedRex(_ data: Data) -> Bool {
        guard !data.starts(with: Data("PK".utf8)) else { return false }
        let text = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
        return text.contains(#/(?:^|[;\\n])[ \\t]*WidgetMetadata[ \\t]*=/#)
    }

    /// What a downloaded spider is, when its content says so. Python spiders all build on the
""",
      "Site sniffedRex")
# NOTE: the rewritten body below MUST keep `var sites = sites` above the
# `pending` line. Swift 6 rejects a closure that captures `sites` before
# the local is declared ("closure captures 'sites' before it is declared");
# the Nov 4 reorder fixed this once, and a rewrite that puts `pending`
# first reintroduces it (build 42139969047 failed exactly this way).
patch("Sources/TVCore/ScriptSniffing.swift",
      """        var sites = sites
        let pending = sites.indices.filter { sites[$0].needsSniffing }
        guard !pending.isEmpty else { return self }
        let found = await withTaskGroup(of: (Int, SourceRuntime?).self) { group in
            for index in pending {
                let site = sites[index], origin = origin
                group.addTask {
                    guard let url = try? site.scriptURL(origin: origin),
                          let (data, _) = try? await http.get(url) else { return (index, nil) }
                    return (index, Site.sniffedRuntime(data))
                }
            }
            var found: [(Int, SourceRuntime?)] = []
            for await result in group { found.append(result) }
            return found
        }
        for (index, runtime) in found {
            sites[index].detectedRuntime = runtime
            Diagnostics.shared.record(.info, "subscription", "sniffed source=\\(sites[index].key) host=\\(URL(string: sites[index].api)?.host() ?? "-") runtime=\\(runtime.map { "\\($0)" } ?? "unknown")")
        }
""",
      """        var sites = sites
        let pending = sites.indices.filter { sites[$0].needsSniffing || sites[$0].needsRexSniffing }
        guard !pending.isEmpty else { return self }
        let found = await withTaskGroup(of: (Int, SourceRuntime?, Bool).self) { group in
            for index in pending {
                let site = sites[index], origin = origin
                group.addTask {
                    guard let url = try? site.scriptURL(origin: origin),
                          let (data, _) = try? await http.get(url) else { return (index, nil, false) }
                    return (index, Site.sniffedRuntime(data), Site.sniffedRex(data))
                }
            }
            var found: [(Int, SourceRuntime?, Bool)] = []
            for await result in group { found.append(result) }
            return found
        }
        for (index, runtime, rex) in found {
            sites[index].detectedRuntime = runtime
            if rex { sites[index].detectedRex = true }
            else if sites[index].needsRexSniffing { sites[index].detectedRex = false }
            Diagnostics.shared.record(.info, "subscription", "sniffed source=\\(sites[index].key) host=\\(URL(string: sites[index].api)?.host() ?? "-") runtime=\\(runtime.map { "\\($0)" } ?? "unknown") rex=\\(rex)")
        }
""",
      "sniffingScripts Rex")

# --- Lone Rex file import: today singleSpider returns nil for a Rex file
# (it is neither a Python spider nor a CatVod spider), so importing the
# 17RIP component would fail. A Rex file imports as a one-site subscription
# named after its WidgetMetadata title. ---
patch("Sources/TVCore/SingleSpider.swift",
      """    /// The name a Python spider gives itself in `getName`, when it returns a plain string.
""",
      """    /// The title a Rex component declares in WidgetMetadata, for the
    /// one-site subscription a lone component file imports as.
    static func rexTitle(_ data: Data) -> String? {
        let text = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
        guard let meta = text.range(of: "WidgetMetadata") else { return nil }
        let rest = text[meta.upperBound...]
        guard let match = rest.firstMatch(of: #/title[ \\t]*:[ \\t]*["']([^"'\\n]{1,60})["']/#) else { return nil }
        let title = String(match.1).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// The name a Python spider gives itself in `getName`, when it returns a plain string.
""",
      "Site rexTitle")
patch("Sources/TVCore/SingleSpider.swift",
      """        let runtime: SourceRuntime
        if Site.sniffedRuntime(data) == .python { runtime = .python }
        else if Site.isJavaScriptSpider(data) { runtime = .javascript }
        else { return nil }
        let file = origin.deletingPathExtension().lastPathComponent
        let key = file.isEmpty || file == "/" ? "spider" : file
        let name = (runtime == .python ? Site.pythonSpiderName(data) : nil) ?? key
        let api = origin.absoluteString
        let raw: [String: JSONValue] = ["key": .string(key), "name": .string(name), "type": .number(3), "api": .string(api),
                                        "searchable": .number(1), "quickSearch": .number(1), "filterable": .number(1)]
        var site = Site(key: key, name: name, type: 3, api: api, raw: raw)
        // An address that names no `.py` or `.js` file runs as what its content showed.
        if site.runtime != runtime { site.detectedRuntime = runtime }
""",
      """        let runtime: SourceRuntime
        var detectedRex = false
        if Site.sniffedRuntime(data) == .python { runtime = .python }
        else if Site.sniffedRex(data) { runtime = .javascript; detectedRex = true }
        else if Site.isJavaScriptSpider(data) { runtime = .javascript }
        else { return nil }
        let file = origin.deletingPathExtension().lastPathComponent
        let key = file.isEmpty || file == "/" ? "spider" : file
        let name = (runtime == .python ? Site.pythonSpiderName(data) : nil) ?? (detectedRex ? Site.rexTitle(data) : nil) ?? key
        let api = origin.absoluteString
        let raw: [String: JSONValue] = ["key": .string(key), "name": .string(name), "type": .number(3), "api": .string(api),
                                        "searchable": .number(1), "quickSearch": .number(1), "filterable": .number(1)]
        var site = Site(key: key, name: name, type: 3, api: api, raw: raw)
        if detectedRex { site.detectedRex = true }
        // An address that names no `.py` or `.js` file runs as what its content showed.
        if site.runtime != runtime { site.detectedRuntime = runtime }
""",
      "singleSpider Rex")

# --- Catalog dispatch: a detected Rex component runs through RexRuntime.
# An undetected .js source is probed once (cached in RexRuntime) so a
# component listed in a JSON subscription still lands on the Rex path. ---
patch("Sources/TVCore/Catalog.swift",
      """    private func perform(_ params: [String: String]) async throws -> [String: JSONValue] {
        if site.isCloudFiles { return try await CloudFilesSource.request(site, params: params) }
""",
      """    private func perform(_ params: [String: String]) async throws -> [String: JSONValue] {
        if site.isCloudFiles { return try await CloudFilesSource.request(site, params: params) }
        // A Rex component is a .js file, but it is not a TVBox spider: it
        // runs through RexRuntime, which defines the Widget global the
        // component calls. Already-detected components go straight there;
        // an undetected .js source is probed once (cached in RexRuntime).
        if site.detectedRex == true {
            return try await RexRuntime.shared.request(site: site, scriptURL: site.scriptURL(origin: origin), params: params, http: http, origin: origin)
        }
        if site.runtime == .javascript, site.detectedRex == nil {
            if let scriptURL = try? site.scriptURL(origin: origin),
               await RexRuntime.shared.isRex(site: site, scriptURL: scriptURL, http: http) {
                return try await RexRuntime.shared.request(site: site, scriptURL: scriptURL, params: params, http: http, origin: origin)
            }
        }
""",
      "Catalog Rex dispatch")
PYEOF


# Local WebHome pages (2026-11-05, user report): a .html file on its own is
# not a subscription, so the file picker rejected it. Now .html is offered,
# and importing one wraps the copied page in a one-site subscription whose
# homePage is the page itself; the WebView renders the copied file because
# WKWebView cannot fetch the importer's reserved host.
python3 - <<'PYEOF'
import pathlib, sys

def patch(path, old, new, label):
    p = pathlib.Path(path)
    text = p.read_text()
    if old not in text:
        print(f"{label} pattern not found; refusing to patch blindly", file=sys.stderr)
        sys.exit(1)
    p.write_text(text.replace(old, new, 1))
    print(label)

patch("Sources/TVCore/SingleSpider.swift",
      "    public static func isImported(_ address: String) -> Bool { URL(string: address)?.host()?.lowercased() == host }\n",
      """    public static func isImported(_ address: String) -> Bool { URL(string: address)?.host()?.lowercased() == host }

    /// The copied file behind a reserved-host address, as text, for views
    /// that must render it themselves (a WebHome page in a WKWebView cannot
    /// fetch the reserved host).
    public static func localHTML(at url: URL) -> String? {
        guard let data = try? data(at: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
""",
      "ImportedFiles localHTML")
patch("App/SettingsView.swift",
      "    static let types: [UTType] = [.json, .pythonScript, .javaScript]\n",
      "    static let types: [UTType] = [.json, .pythonScript, .javaScript, .html]\n",
      "SubscriptionFile html type")
patch("App/SettingsView.swift",
      "A TVBox JSON subscription, or one Python (.py) or JavaScript (.js) spider. Pick several files at once.",
      "A TVBox JSON subscription, one Python (.py) or JavaScript (.js) spider, or a WebHome (.html) page. Pick several files at once.",
      "Settings html footer")
patch("App/Store.swift",
      """        let address = url.absoluteString, known = subscriptions.contains { $0.address == address }
        await importSubscription(address: address)
""",
      """        let address = url.absoluteString, known = subscriptions.contains { $0.address == address }
        if url.pathExtension.lowercased() == "html" {
            // A WebHome page on its own is not a subscription: wrap it in one
            // whose only site renders the copied page as its homePage.
            let base = url.deletingPathExtension().lastPathComponent
            let key = "webhome-" + base.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
            do {
                let doc: [String: Any] = ["sites": [["key": key, "name": "Finch·\\(base)", "type": 3, "api": address, "homePage": address]]]
                let data = try JSONSerialization.data(withJSONObject: doc)
                let value = try Subscription.parse(data, origin: url)
                let entry = SubscriptionEntry(address: address)
                if let index = subscriptions.firstIndex(where: { $0.address == entry.address }) {
                    subscriptions[index].enabled = true
                } else { subscriptions.append(entry) }
                keep(value, for: entry)
                notice = L10n.text("Imported sources: %lld · Live playlists: %lld", value.sites.count, value.lives.count)
                saveSubscriptionList()
                rebuildSubscription()
            } catch {
                importError = L10n.text("Import failed: %@", error.localizedDescription)
            }
            return
        }
        await importSubscription(address: address)
""",
      "Store local html import")
PYEOF

# --- Bottom "管理" tab: the management screen as its own tab after Sources. ---
# The phone's tab bar is user-arranged (PhoneTabs, App/MoreView.swift) with
# four slots, and a newer section would otherwise land in More, where it is
# not a tab at all — so Manage is inserted after Sources once, mirroring the
# Discover migration upstream already does. The tab reuses
# FinchSourceManagementView with embedInNavigationStack: false: the tab's
# RouteStack already owns a NavigationStack, and nesting a second one would
# render a second navigation bar. The SitesView "管理" button stays as a
# shortcut opening the same screen as a sheet.
python3 - <<'PYEOF'
import pathlib, sys

def patch(path, old, new, label):
    p = pathlib.Path(path)
    text = p.read_text()
    if old not in text:
        print(f"{label}: pattern not found in {path}; refusing to patch blindly", file=sys.stderr)
        sys.exit(1)
    p.write_text(text.replace(old, new, 1))
    print(f"{label}: patched")

# AppSection.manage: raw value "Manage" so L10n resolves it to 管理 (the key
# is added to the strings tables below). Icon is a wrench — Settings already
# uses slider.horizontal.3, so that one is not available.
patch("App/RootView.swift",
      "case home = \"Watch Now\", discover = \"Discover\", live = \"Live TV\", music = \"Music\", manga = \"Manga\", search = \"Global Search\", sites = \"Sources\", files = \"Cloud Files\", favorites = \"Favorites\", history = \"Playback History\", downloads = \"Downloads\", settings = \"Settings\", more = \"More\"",
      "case home = \"Watch Now\", discover = \"Discover\", live = \"Live TV\", music = \"Music\", manga = \"Manga\", search = \"Global Search\", sites = \"Sources\", manage = \"Manage\", files = \"Cloud Files\", favorites = \"Favorites\", history = \"Playback History\", downloads = \"Downloads\", settings = \"Settings\", more = \"More\"",
      "AppSection manage case")
patch("App/RootView.swift",
      "        case .sites: \"square.grid.2x2.fill\"\n",
      "        case .sites: \"square.grid.2x2.fill\"\n        case .manage: \"wrench.and.screwdriver\"\n",
      "AppSection manage icon")
patch("App/RootView.swift",
      "        case .sites: SitesView()\n",
      "        case .sites: SitesView()\n        case .manage: FinchSourceManagementView(embedInNavigationStack: false)\n",
      "sectionRoot manage tab")
# PhoneTabs: Manage sits after Sources everywhere the order is defined.
patch("App/MoreView.swift",
      "    static let standard = PhoneTabs(bar: [.home, .discover, .live, .search], more: [.music, .manga, .sites, .files, .history, .favorites, .downloads, .messages, .settings])",
      "    static let standard = PhoneTabs(bar: [.home, .discover, .live, .search], more: [.music, .manga, .sites, .manage, .files, .history, .favorites, .downloads, .messages, .settings])",
      "PhoneTabs standard manage")
patch("App/MoreView.swift",
      "    static let sidebarStandard: [AppSection] = [.home, .discover, .live, .music, .manga, .search, .sites, .files, .history, .favorites, .downloads, .settings]",
      "    static let sidebarStandard: [AppSection] = [.home, .discover, .live, .music, .manga, .search, .sites, .manage, .files, .history, .favorites, .downloads, .settings]",
      "PhoneTabs sidebar manage")
patch("App/MoreView.swift",
      """        // Add Discover once to an existing installation's visible tabs. Preserve their relative
        // order; arranged(slots:) carries the last tab into More when the bar is full.
        if !(halves[0] + halves[1]).contains(.discover) { bar.insert(.discover, at: min(1, bar.count)) }
""",
      """        // Add Discover once to an existing installation's visible tabs. Preserve their relative
        // order; arranged(slots:) carries the last tab into More when the bar is full.
        if !(halves[0] + halves[1]).contains(.discover) { bar.insert(.discover, at: min(1, bar.count)) }
        // Add Manage once the same way, right after Sources (2026-11-06): the
        // viewer asked for a bottom 管理 tab. If Sources is not in the bar,
        // append to the bar instead — the best possible position, since the
        // bar comes before More in the combined order.
        if !(halves[0] + halves[1]).contains(.manage) {
            if let sites = bar.firstIndex(of: .sites) { bar.insert(.manage, at: sites + 1) }
            else { bar.append(.manage) }
        }
""",
      "PhoneTabs manage migration")
patch("App/MoreView.swift",
      "        case .sites: Color(red: 0.60, green: 0.46, blue: 1.0)\n",
      "        case .sites: Color(red: 0.60, green: 0.46, blue: 1.0)\n        case .manage: Color(red: 0.15, green: 0.65, blue: 0.35)\n",
      "AppSection manage tint")
patch("App/MoreView.swift",
      "        case .sites: store.subscription.map { store.orderedSites($0).count }\n",
      "        case .sites: store.subscription.map { store.orderedSites($0).count }\n        case .manage: store.subscription.map { store.orderedSites($0).count }\n",
      "MoreView manage count")
# "Manage" -> 管理, so the tab reads 管理 in Chinese (the raw value alone
# would fall back to the English "Manage").
patch("Sources/TVCore/Resources/zh-Hans.lproj/Localizable.strings",
      "\"Manage Sources\" = \"管理点播源\";",
      "\"Manage Sources\" = \"管理点播源\";\n\"Manage\" = \"管理\";",
      "zh-Hans Manage string")
patch("Sources/TVCore/Resources/zh-Hant.lproj/Localizable.strings",
      "\"Manage Sources\" = \"管理隨選來源\";",
      "\"Manage Sources\" = \"管理隨選來源\";\n\"Manage\" = \"管理\";",
      "zh-Hant Manage string")
patch("Sources/TVCore/Resources/ja.lproj/Localizable.strings",
      "\"Manage Sources\" = \"配信ソースを管理\";",
      "\"Manage Sources\" = \"配信ソースを管理\";\n\"Manage\" = \"管理\";",
      "ja Manage string")
patch("Sources/TVCore/Resources/en.lproj/Localizable.strings",
      "\"Manage Sources\" = \"Manage Sources\";",
      "\"Manage Sources\" = \"Manage Sources\";\n\"Manage\" = \"Manage\";",
      "en Manage string")
PYEOF

echo "Finch branding applied. Changed lines:"
grep -n "Finch Player\|com.finch.player.ios" project.yml || true
