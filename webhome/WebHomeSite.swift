import Foundation
import TVCore

// WebHome (FongMi homePage) support, step 1.
// A site's homePage lives in its subscription JSON entry; Subscription.parse
// keeps the site's full JSON object in Site.raw, so no Site struct change is
// needed. Relative homePage values resolve against the site's own origin,
// exactly like its api does.
extension Site {
    /// The site's WebHome page, if it declares one (aliases match webhtv).
    func webHomePageURL(origin: URL) -> URL? {
        for key in ["homePage", "home_page", "webHome", "web_home"] {
            guard let text = raw[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  let url = try? WebAddress.resolve(text, relativeTo: origin) else { continue }
            return url
        }
        return nil
    }

    var webHomePage: Bool {
        // Used by the SiteView hook: true when any homePage alias is present.
        // The resolved URL itself is built by webHomePageURL(origin:) at the
        // call site, where the subscription origin is available.
        ["homePage", "home_page", "webHome", "web_home"].contains { key in
            guard let text = raw[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !text.isEmpty
        }
    }

    /// The site's preferred chrome mode, if it declares one (webhtv: chromeMode
    /// / webHomeChrome). Values: normal / edge / immersive. Unknown values are
    /// ignored by the view, which falls back to edge.
    var webHomeChromeMode: String? {
        for key in ["chromeMode", "webHomeChrome"] {
            if let text = raw[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
