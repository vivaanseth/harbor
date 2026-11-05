import AppKit
import ApplicationServices

/// What the Spotify app shows in its Now Playing panel, read through
/// Accessibility: the next track and the playlist or album it's playing
/// from. Spotify's Web API needs Premium for this; the app's own window works
/// on any account. Needs Accessibility and Spotify's Now Playing view open
/// (it is by default), and keeps working while Spotify is hidden.
/// Call `read()` off the main thread: the first look takes most of a second.
enum SpotifyScreen {
    struct Snapshot: Equatable {
        var nextTitle: String?
        var nextArtist: String?
        var contextName: String?
        /// "spotify:playlist:…", "spotify:album:…"
        var contextURI: String?
    }

    /// The Now Playing panel from the last read; re-found if it went away.
    nonisolated(unsafe) private static var panel: AXUIElement?

    static func read() -> Snapshot? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: MusicPlayer.spotify.bundleID).first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        if panel == nil || node(panel!).label != "Now playing view" {
            // Spotify's web content only builds its accessibility tree once asked.
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var window: AnyObject?
            guard AXUIElementCopyAttributeValue(root, kAXMainWindowAttribute as CFString, &window) == .success,
                  let window else { return nil }
            // The panel is on the right, so it comes last: search from the end.
            panel = findLast(window as! AXUIElement, depth: 25) { $0.role == "AXGroup" && $0.label == "Now playing view" }?.element
        }
        guard let panel else { return Snapshot() }
        var snap = Snapshot()

        // The first link in the panel is what's playing from.
        if let link = findFirst(panel, depth: 6, { n in n.role == "AXLink" && n.url.flatMap(uri(for:)) != nil }) {
            snap.contextName = link.label
            snap.contextURI = link.url.flatMap(uri(for:))
        }
        // "Next in queue" is a heading; the track is the group after it.
        var section: Node?
        _ = findLast(panel, depth: 12) { n in
            guard n.children.contains(where: { let c = node($0); return c.role == "AXHeading" && c.label.hasPrefix("Next in queue") }) else { return false }
            section = n
            return true
        }
        if let section {
            let kids = section.children.map(node)
            if let h = kids.firstIndex(where: { $0.role == "AXHeading" }),
               let track = kids[(h + 1)...].first(where: { $0.role == "AXGroup" }) {
                snap.nextTitle = track.label
                var artists: [String] = []
                func collect(_ e: AXUIElement, _ depth: Int) {
                    let n = node(e)
                    if n.role == "AXLink", n.url?.path.contains("/artist/") == true, !n.label.isEmpty { artists.append(n.label) }
                    if depth > 0 { n.children.forEach { collect($0, depth - 1) } }
                }
                collect(track.element, 4)
                snap.nextArtist = artists.joined(separator: ", ")
            }
        }
        return snap
    }

    /// "https://…/playlist/ID" → "spotify:playlist:ID"
    static func uri(for url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, ["playlist", "album", "artist", "show"].contains(parts[parts.count - 2]) else { return nil }
        return "spotify:\(parts[parts.count - 2]):\(parts[parts.count - 1])"
    }

    // MARK: - Accessibility helpers

    private struct Node {
        let element: AXUIElement
        let role: String
        let label: String
        let url: URL?
        let children: [AXUIElement]
    }

    private static let keys = [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute,
                               "AXURL", kAXChildrenAttribute] as CFArray

    /// One round trip for everything we look at.
    private static func node(_ e: AXUIElement) -> Node {
        var out: CFArray?
        AXUIElementCopyMultipleAttributeValues(e, keys, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
        let v = (out as? [Any]) ?? []
        func string(_ i: Int) -> String? { i < v.count ? v[i] as? String : nil }
        let label = [string(1), string(2), string(3)].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return Node(element: e, role: string(0) ?? "", label: label, url: v.count > 4 ? v[4] as? URL : nil,
                    children: v.count > 5 ? (v[5] as? [AXUIElement]) ?? [] : [])
    }

    private static func findFirst(_ e: AXUIElement, depth: Int, _ match: (Node) -> Bool) -> Node? {
        let n = node(e)
        if match(n) { return n }
        guard depth > 0 else { return nil }
        for c in n.children { if let hit = findFirst(c, depth: depth - 1, match) { return hit } }
        return nil
    }

    private static func findLast(_ e: AXUIElement, depth: Int, _ match: (Node) -> Bool) -> Node? {
        let n = node(e)
        if match(n) { return n }
        guard depth > 0 else { return nil }
        for c in n.children.reversed() { if let hit = findLast(c, depth: depth - 1, match) { return hit } }
        return nil
    }
}

/// Spotify playlists and albums to play from the drawer without the Web API:
/// the ones you've played from (seen in Spotify's Now Playing panel) and
/// links you've added. Names and covers come from Spotify's public link
/// previews. Kept across launches; added ones stay on top.
@MainActor
final class SpotifyShelf: ObservableObject {
    static let shared = SpotifyShelf()

    struct Item: Codable, Hashable {
        var uri: String
        var name: String
        var artworkURL: URL?
        var pinned: Bool
    }

    @Published private(set) var items: [Item] = []
    private let key = "spotify.shelf"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    /// Something Spotify is playing from.
    func remember(name: String, uri: String) {
        if let i = items.firstIndex(where: { $0.uri == uri }) {
            if !items[i].pinned {
                // Most recent first, below the pinned ones.
                let item = items.remove(at: i)
                items.insert(item, at: items.filter(\.pinned).count)
                save()
            }
            return
        }
        items.insert(Item(uri: uri, name: name, artworkURL: nil, pinned: false), at: items.filter(\.pinned).count)
        let recents = items.indices.filter { !items[$0].pinned }
        if recents.count > 15 { items.remove(at: recents.last!) }
        save()
        fetchPreview(uri)
    }

    /// Adds a copied Spotify link ("https://open.spotify.com/playlist/…" or "spotify:playlist:…").
    /// Returns false if the text isn't one.
    @discardableResult
    func add(link text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var uri: String?
        if trimmed.hasPrefix("spotify:") {
            uri = trimmed.split(separator: "?").first.map(String.init)
        } else if let url = URL(string: trimmed), url.host?.hasSuffix("spotify.com") == true {
            uri = SpotifyScreen.uri(for: url)
        }
        guard let uri, uri.split(separator: ":").count == 3 else { return false }
        items.removeAll { $0.uri == uri }
        items.insert(Item(uri: uri, name: "Spotify", artworkURL: nil, pinned: true), at: 0)
        save()
        fetchPreview(uri)
        return true
    }

    func remove(_ uri: String) {
        items.removeAll { $0.uri == uri }
        save()
    }

    private struct Preview: Decodable { let title: String?; let thumbnail_url: String? }

    /// Name and cover from Spotify's public oEmbed endpoint (no sign-in).
    private func fetchPreview(_ uri: String) {
        let parts = uri.split(separator: ":")
        guard parts.count == 3,
              let url = URL(string: "https://open.spotify.com/oembed?url=https://open.spotify.com/\(parts[1])/\(parts[2])") else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let preview = try? JSONDecoder().decode(Preview.self, from: data),
                  let i = items.firstIndex(where: { $0.uri == uri }) else { return }
            if let title = preview.title, !title.isEmpty { items[i].name = title }
            items[i].artworkURL = preview.thumbnail_url.flatMap(URL.init(string:))
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }
}
