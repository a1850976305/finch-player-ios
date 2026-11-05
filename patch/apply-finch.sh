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


# Infinite scroll (2026-11-05, user request): category/search lists load the
# next page when the last card appears, appending instead of replacing.
# The source still only supplies page/pageCount; the UI no longer uses the
# arrow pager. The end is an empty next page, not pageCount alone, because
# some sources report pageCount loosely.
python3 - <<'PYEOF'
import pathlib, re, sys

def patch(path, old, new, label):
    p = pathlib.Path(path)
    text = p.read_text()
    if old not in text:
        print(f"{label} pattern not found; refusing to patch blindly", file=sys.stderr)
        sys.exit(1)
    p.write_text(text.replace(old, new, 1))
    print(label)

# --- CatalogBrowser: append-only next page ---
patch("Sources/TVCore/CatalogBrowser.swift",
      "    public private(set) var loaded = false\n",
      "    public private(set) var loaded = false\n    public private(set) var loadingMore = false\n    public private(set) var reachedEnd = false\n",
      "CatalogBrowser loadingMore/reachedEnd")
patch("Sources/TVCore/CatalogBrowser.swift",
      "        busy = !refreshing; loaded = false; error = nil\n",
      "        busy = !refreshing; loaded = false; error = nil; reachedEnd = false\n",
      "CatalogBrowser reset reachedEnd on new load")
patch("Sources/TVCore/CatalogBrowser.swift",
      """    public func load(_ request: Request, client: CatalogClient) async {
        await load(request, context: client.reportContext) { request in
            switch request {
            case .home: return try await client.home()
            case let .list(category, query, page, filters): return try await client.list(category: category, query: query, page: page, filters: filters)
            }
        }
    }
""",
      """    public func load(_ request: Request, client: CatalogClient) async {
        await load(request, context: client.reportContext) { request in
            switch request {
            case .home: return try await client.home()
            case let .list(category, query, page, filters): return try await client.list(category: category, query: query, page: page, filters: filters)
            }
        }
    }

    /// Append the next page of the current category/search list, if any.
    /// Home has no next page. The end is reached when the next page comes
    /// back empty (or repeats the same items) -- some sources report
    /// pageCount loosely, so pageCount alone must not decide the end, and a
    /// failed next page must not wipe the list or block a retry.
    public func loadMore(client: CatalogClient) async {
        guard case let .list(category, query, currentPage, filters) = request else { return }
        guard !busy, !loadingMore, !reachedEnd, !videos.isEmpty else { return }
        guard currentPage < pageCount else { return }
        loadingMore = true
        defer { loadingMore = false }
        let current = generation
        do {
            let result = try await client.list(category: category, query: query, page: currentPage + 1, filters: filters)
            guard generation == current, !Task.isCancelled else { return }
            if result.videos.isEmpty {
                reachedEnd = true
                return
            }
            let fresh = result.videos.filter { video in !videos.contains(where: { $0.id == video.id }) }
            if fresh.isEmpty {
                reachedEnd = true
                return
            }
            videos.append(contentsOf: fresh)
            self.page = currentPage + 1
            pageCount = max(result.pageCount, self.page)
        } catch {
            Diagnostics.shared.failure("catalog", "list \\(client.reportContext)", error)
        }
    }
""",
      "CatalogBrowser loadMore")

# --- SitesView: trigger on the last card, footer spinner, drop the pager ---
patch("App/SitesView.swift",
      """                                if isIndex {
                                    Button { store.searchVideos(video.name) } label: { PosterCard(video: video) }.cardButton()
                                } else {
                                    RouteLink { CatalogDestination(video: video, client: client) } label: { PosterCard(video: video) }.cardButton()
                                }
""",
      """                                if isIndex {
                                    Button { store.searchVideos(video.name) } label: { PosterCard(video: video) }.cardButton()
                                        .onAppear { if video.id == browser.videos.last?.id { startRequest { await browser.loadMore(client: client) } } }
                                } else {
                                    RouteLink { CatalogDestination(video: video, client: client) } label: { PosterCard(video: video) }.cardButton()
                                        .onAppear { if video.id == browser.videos.last?.id { startRequest { await browser.loadMore(client: client) } } }
                                }
""",
      "SitesView last-card loadMore trigger")
patch("App/SitesView.swift",
      """                        .opacity(browser.busy && !browser.videos.isEmpty ? 0.55 : 1).animation(.smooth, value: browser.busy)
""",
      """                        .opacity(browser.busy && !browser.videos.isEmpty ? 0.55 : 1).animation(.smooth, value: browser.busy)
                        if browser.loadingMore {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
""",
      "SitesView loadMore footer")
patch("App/SitesView.swift",
      "                .safeAreaInset(edge: .bottom) { if browser.pageCount > 1 { pager } }\n",
      "",
      "SitesView remove pager inset")
p = pathlib.Path("App/SitesView.swift")
text = p.read_text()
text2, n1 = re.subn(r"    private var pager: some View \{.*?    private func home\(\) async", "    private func home() async", text, count=1, flags=re.S)
if n1 != 1:
    print("SitesView pager block pattern not found; refusing to patch blindly", file=sys.stderr)
    sys.exit(1)
text2, n2 = re.subn(r"    private func load\(page next: Int\) async \{.*?\n    \}\n\}", "}", text2, count=1, flags=re.S)
if n2 != 1:
    print("SitesView load(page:) pattern not found; refusing to patch blindly", file=sys.stderr)
    sys.exit(1)
p.write_text(text2)
print("SitesView pager + load(page:) removed")
PYEOF

echo "Finch branding applied. Changed lines:"
grep -n "Finch Player\|com.finch.player.ios" project.yml || true
