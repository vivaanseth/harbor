import AppKit
import Combine

enum MusicPlayer: String {
    case music = "Music"
    case spotify = "Spotify"
    /// Any other app, through the system Now Playing service.
    case system = "Now Playing"

    var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
}

struct NowPlaying: Equatable {
    var player: MusicPlayer
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var isPlaying: Bool
    var artworkURL: String?
    var sampledAt: Date
    var sourcePID: pid_t = 0

    /// Position extrapolated from the last poll.
    func livePosition(at date: Date = Date()) -> Double {
        isPlaying ? min(duration, position + date.timeIntervalSince(sampledAt)) : position
    }
}

struct QueueItem: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String
    var index: Int
    /// Spotify items: what to play, and a small cover.
    var uri: String? = nil
    var artworkURL: URL? = nil
}

struct PlaylistItem: Identifiable, Hashable {
    var id: String { uri ?? name }
    var name: String
    var subtitle: String
    var count: Int
    var uri: String? = nil
    var artworkURL: URL? = nil
}

/// Apple Music and Spotify over Apple Events. Never launches a player that
/// isn't already running.
@MainActor
final class MusicService: ObservableObject {
    static let shared = MusicService()

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    /// The artwork is the playing app's icon (no trustworthy cover art).
    @Published private(set) var artworkIsAppIcon = false
    @Published private(set) var isPlayerAvailable = false
    @Published private(set) var upNext: [QueueItem] = []
    /// What Spotify is playing from, as its own window shows it (no Web API).
    @Published private(set) var spotifyContext: (name: String, uri: String)?
    @Published private(set) var playlists: [PlaylistItem] = []
    private var musicPlaylists: [PlaylistItem] = []
    private var spotifyPlaylists: [PlaylistItem] = []
    @Published private(set) var recent: [NowPlaying] = []
    @Published private(set) var searchResults: [QueueItem] = []
    @Published private(set) var automationDenied = false

    private let queue = DispatchQueue(label: "music.applescript", qos: .userInitiated)
    private let screenQueue = DispatchQueue(label: "music.spotify-screen", qos: .utility)
    private var timer: Timer?
    private var artworkTrackID: String?
    private let settings = AppSettings.shared
    private var artworkCache: [String: NSImage] = [:]
    /// The artist and album each system artwork image first arrived with (kept across launches),
    /// to spot a browser handing one page's artwork to the next.
    private var artworkOwners: [String: String] = UserDefaults.standard.dictionary(forKey: "music.artworkOwners") as? [String: String] ?? [:]
    private var appIcons: [pid_t: NSImage] = [:]

    private init() {}

    var automationState: PermissionState {
        if automationDenied { return .denied }
        return nowPlaying != nil ? .granted : .notDetermined
    }

    func setActive(_ active: Bool) {
        if active, timer == nil {
            poll()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        } else if !active {
            timer?.invalidate()
            timer = nil
        }
    }

    func requestAutomation() {
        // Running any script against a running player triggers the TCC prompt.
        for p in [MusicPlayer.music, .spotify] where p.isRunning {
            run("tell application \"\(p.rawValue)\" to get player state") { _ in }
        }
    }

    private var preferredPlayers: [MusicPlayer] {
        switch settings.musicSource {
        case "music": return [.music]
        case "spotify": return [.spotify]
        default: return [.spotify, .music]
        }
    }

    // MARK: - Polling

    private func poll() {
        let running = preferredPlayers.filter(\.isRunning)
        // In Automatic mode, anything else that's playing (Safari, Chrome…) counts too.
        let anyApp = settings.musicSource == "auto"
        if !anyApp && running.isEmpty {
            if isPlayerAvailable { isPlayerAvailable = false }
            if nowPlaying != nil { nowPlaying = nil; artwork = nil }
            return
        }
        queue.async { [weak self] in
            var best: NowPlaying?
            var reached: [MusicPlayer] = []
            for p in running {
                guard let np = Self.fetchNowPlaying(p) else { continue }
                reached.append(p)
                if best == nil || (np.isPlaying && !(best!.isPlaying)) { best = np }
            }
            // The system's Now Playing covers everything else, including a
            // player we couldn't script (Automation not allowed, say).
            var art: MediaRemote.Artwork?
            if anyApp, best?.isPlaying != true, let (np, data) = MediaRemote.nowPlaying(),
               np.sourcePID == 0 || !reached.contains(where: { $0.bundleID == NSRunningApplication(processIdentifier: np.sourcePID)?.bundleIdentifier }),
               best == nil || np.isPlaying {
                best = np
                art = data
            }
            let available = !running.isEmpty || best != nil
            Task { @MainActor in
                guard let self else { return }
                if self.isPlayerAvailable != available { self.isPlayerAvailable = available }
                self.apply(best)
                if let np = best, np.player == .system { self.showSystemArtwork(np, art) }
            }
        }
    }

    private func apply(_ np: NowPlaying?) {
        let previous = nowPlaying
        // Skip no-op updates so the widgets don't re-render every second.
        // Small drift counts as a change so synced lyrics stay in step.
        if let p = previous, let n = np, p.trackID == n.trackID, p.isPlaying == n.isPlaying,
           p.title == n.title, abs(p.livePosition(at: n.sampledAt) - n.position) < 0.3 {
            return
        }
        nowPlaying = np
        guard let np else { artwork = nil; return }
        if previous?.trackID != np.trackID {
            if let p = previous, !recent.contains(where: { $0.trackID == p.trackID }) {
                recent.insert(p, at: 0)
                if recent.count > 20 { recent.removeLast() }
            }
            loadArtwork(np)
            LyricsService.shared.load(for: np)
            if isSpotify && !SpotifyAPI.shared.connected {
                // Learn what's next and what it's playing from as Spotify's
                // own panel catches up with the new track.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.readSpotifyScreen() }
            } else if DrawerController.shared.openKind == .music {
                refreshUpNext()
            }
        }
    }

    nonisolated private static func fetchNowPlaying(_ p: MusicPlayer) -> NowPlaying? {
        let sep = "‖"
        let source: String
        switch p {
        case .system:
            return MediaRemote.nowPlaying()?.0
        case .music:
            source = """
            tell application "Music"
                if player state is stopped then return "stopped"
                set t to current track
                set pid to ""
                try
                    set pid to persistent ID of t
                end try
                return (player state as string) & "\(sep)" & pid & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(sep)" & (album of t) & "\(sep)" & ((duration of t) as string) & "\(sep)" & ((player position) as string) & "\(sep)" & ""
            end tell
            """
        case .spotify:
            source = """
            tell application "Spotify"
                if player state is stopped then return "stopped"
                set t to current track
                return (player state as string) & "\(sep)" & (id of t) & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(sep)" & (album of t) & "\(sep)" & (((duration of t) / 1000) as string) & "\(sep)" & ((player position) as string) & "\(sep)" & (artwork url of t)
            end tell
            """
        }
        let started = Date()
        guard let result = AppleScriptRunner.run(source), result != "stopped" else { return nil }
        // The position was read somewhere during the call; assume halfway.
        let sampledAt = started.addingTimeInterval(Date().timeIntervalSince(started) / 2)
        let parts = result.components(separatedBy: sep)
        guard parts.count >= 8 else { return nil }
        let num: (String) -> Double = { Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return NowPlaying(player: p, trackID: parts[1].isEmpty ? parts[2] + parts[3] : parts[1],
                          title: parts[2], artist: parts[3], album: parts[4],
                          duration: num(parts[5]), position: num(parts[6]),
                          isPlaying: parts[0] == "playing",
                          artworkURL: parts[7].isEmpty ? nil : parts[7], sampledAt: sampledAt)
    }

    /// Artwork from the system's Now Playing info, checked on every update.
    /// Browsers keep the last page's artwork when the next one (Netflix, say)
    /// sends none, so an image only shows when the page described its media
    /// (artist or album) and it hasn't already come with other media.
    /// Otherwise the playing app's icon shows, as in Apple's Now Playing.
    private func showSystemArtwork(_ np: NowPlaying, _ art: MediaRemote.Artwork?) {
        // Tracks from one album share a cover, so the owner is artist and album.
        let media = np.artist + "|" + np.album
        var image: NSImage?
        if let art, art.described {
            let owner = artworkOwners[art.identifier]
            if owner == nil {
                if artworkOwners.count > 200 { artworkOwners.removeAll() }
                artworkOwners[art.identifier] = media
                UserDefaults.standard.set(artworkOwners, forKey: "music.artworkOwners")
            }
            if owner == nil || owner == media {
                image = artworkCache[art.identifier] ?? NSImage(data: art.data)
                artworkCache[art.identifier] = image
            }
        }
        let isIcon = image == nil
        if isIcon, np.sourcePID != 0 {
            image = appIcons[np.sourcePID] ?? NSRunningApplication(processIdentifier: np.sourcePID)?.icon
            appIcons[np.sourcePID] = image
        }
        if artwork !== image { artwork = image }
        if artworkIsAppIcon != isIcon { artworkIsAppIcon = isIcon }
    }

    private func loadArtwork(_ np: NowPlaying) {
        // System Now Playing artwork is checked on every poll instead.
        guard np.player != .system else { return }
        artworkIsAppIcon = false
        if let cached = artworkCache[np.trackID] { artwork = cached; return }
        artwork = nil
        artworkTrackID = np.trackID
        if let urlString = np.artworkURL, let url = URL(string: urlString) {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let img = NSImage(data: data) else { return }
                Task { @MainActor in self.setArtwork(img, for: np.trackID) }
            }.resume()
        } else if np.player == .music {
            queue.async {
                let desc = AppleScriptRunner.descriptor("tell application \"Music\" to get raw data of artwork 1 of current track")
                guard let data = desc?.data, let img = NSImage(data: data) else { return }
                Task { @MainActor in self.setArtwork(img, for: np.trackID) }
            }
        }
    }

    private func setArtwork(_ img: NSImage, for id: String) {
        artworkCache[id] = img
        if artworkCache.count > 30 { artworkCache.removeAll() }
        if nowPlaying?.trackID == id { artwork = img }
    }

    // MARK: - Transport

    func playPause() { command("playpause"); optimisticToggle() }
    func next() { command("next track") }
    func previous() { command("previous track") }

    func seek(to seconds: Double) {
        guard let np = nowPlaying, np.player != .system else { return }
        run("tell application \"\(np.player.rawValue)\" to set player position to \(seconds)") { [weak self] _ in self?.poll() }
    }

    private func optimisticToggle() {
        guard var np = nowPlaying else { return }
        np.position = np.livePosition()
        np.isPlaying.toggle()
        np.sampledAt = Date()
        nowPlaying = np
    }

    private func command(_ cmd: String) {
        let player = nowPlaying?.player ?? preferredPlayers.first(where: \.isRunning)
        guard let player else { return }
        if player == .system {
            MediaRemote.send(cmd == "playpause" ? .toggle : cmd == "next track" ? .next : .previous)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.poll() }
            return
        }
        run("tell application \"\(player.rawValue)\" to \(cmd)") { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.poll() }
        }
    }

    func openPlayer() {
        if let np = nowPlaying, np.player == .system {
            NSRunningApplication(processIdentifier: np.sourcePID)?.activate()
            return
        }
        guard let p = nowPlaying?.player ?? preferredPlayers.first(where: \.isRunning),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: - Drawer data

    /// Whether Spotify is what's playing (scripted, or seen through Now Playing).
    var isSpotify: Bool {
        guard let np = nowPlaying else { return false }
        return np.player == .spotify ||
            (np.player == .system && NSRunningApplication(processIdentifier: np.sourcePID)?.bundleIdentifier == MusicPlayer.spotify.bundleID)
    }

    func refreshUpNext() {
        if isSpotify && !SpotifyAPI.shared.connected {
            readSpotifyScreen()
            return
        }
        if isSpotify {
            Task {
                let items = await SpotifyAPI.shared.queue() ?? []
                upNext = items.prefix(20).enumerated().map { i, item in
                    QueueItem(id: "\(i)-\(item.uri)", title: item.name, subtitle: item.subtitle, index: i + 1,
                              uri: item.uri, artworkURL: item.artworkURL)
                }
            }
            return
        }
        guard let np = nowPlaying, np.player == .music else { upNext = []; return }
        let sep = "‖", rec = "¶"
        let source = """
        tell application "Music"
            set out to ""
            try
                set p to current playlist
                set i to index of current track
                set n to count of tracks of p
                set lastI to i + 12
                if lastI > n then set lastI to n
                repeat with k from (i + 1) to lastI
                    set t to track k of p
                    set out to out & k & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(rec)"
                end repeat
            end try
            return out
        end tell
        """
        run(source) { [weak self] result in
            let items = (result ?? "").components(separatedBy: rec).compactMap { line -> QueueItem? in
                let f = line.components(separatedBy: sep)
                guard f.count >= 3, let idx = Int(f[0]) else { return nil }
                return QueueItem(id: "\(idx)-\(f[1])", title: f[1], subtitle: f[2], index: idx)
            }
            self?.upNext = items
        }
    }

    /// Whether Spotify's next track can be read from its window (needs Accessibility).
    var canReadSpotifyScreen: Bool { PermissionCache.shared.accessibility }

    /// Without the Web API: the next track and what it's playing from, as the
    /// Spotify app shows them. Playlists seen here join the drawer's list.
    private func readSpotifyScreen() {
        guard canReadSpotifyScreen else { upNext = []; spotifyContext = nil; return }
        screenQueue.async {
            let snap = SpotifyScreen.read()
            Task { @MainActor in
                guard self.isSpotify, !SpotifyAPI.shared.connected else { return }
                if let title = snap?.nextTitle, !title.isEmpty {
                    self.upNext = [QueueItem(id: "next-\(title)", title: title, subtitle: snap?.nextArtist ?? "",
                                             index: 1, uri: "spotify:queue")]
                } else {
                    self.upNext = []
                }
                if let name = snap?.contextName, let uri = snap?.contextURI {
                    self.spotifyContext = (name, uri)
                    SpotifyShelf.shared.remember(name: name, uri: uri)
                } else {
                    self.spotifyContext = nil
                }
            }
        }
    }

    func playQueueItem(_ item: QueueItem) {
        if item.uri != nil {
            // Spotify can't jump into its queue; skipping ahead gets there.
            run("tell application \"Spotify\"\nrepeat \(item.index) times\nnext track\nend repeat\nend tell") { [weak self] _ in
                self?.poll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.refreshUpNext() }
            }
            return
        }
        run("tell application \"Music\" to play track \(item.index) of current playlist") { [weak self] _ in self?.poll() }
    }

    func refreshPlaylists() {
        Task {
            let spotify = (MusicPlayer.spotify.isRunning ? await SpotifyAPI.shared.playlists() : nil) ?? []
            spotifyPlaylists = spotify.map { p in
                PlaylistItem(name: p.name, subtitle: "Spotify" + (p.owner?.display_name.map { " · \($0)" } ?? ""),
                             count: p.tracks?.total ?? 0, uri: p.uri, artworkURL: p.artworkURL)
            }
            playlists = isSpotify ? spotifyPlaylists + musicPlaylists : musicPlaylists + spotifyPlaylists
        }
        guard MusicPlayer.music.isRunning else { musicPlaylists = []; return }
        let sep = "‖", rec = "¶"
        let source = """
        tell application "Music"
            set out to ""
            repeat with p in (user playlists whose special kind is none)
                try
                    set out to out & (name of p) & "\(sep)" & ((count of tracks of p) as string) & "\(rec)"
                end try
            end repeat
            return out
        end tell
        """
        run(source) { [weak self] result in
            guard let self else { return }
            self.musicPlaylists = (result ?? "").components(separatedBy: rec).compactMap { line in
                let f = line.components(separatedBy: sep)
                guard f.count >= 2, !f[0].isEmpty else { return nil }
                return PlaylistItem(name: f[0], subtitle: "Apple Music", count: Int(f[1]) ?? 0)
            }
            self.playlists = self.isSpotify ? self.spotifyPlaylists + self.musicPlaylists : self.musicPlaylists + self.spotifyPlaylists
        }
    }

    func play(playlist: PlaylistItem) {
        if let uri = playlist.uri {
            playSpotify(uri)
            return
        }
        let name = playlist.name.replacingOccurrences(of: "\"", with: "\\\"")
        run("tell application \"Music\" to play user playlist \"\(name)\"") { [weak self] _ in self?.poll() }
    }

    /// Search is about Spotify when that's what's playing (or the only player).
    var searchesSpotify: Bool {
        MusicPlayer.spotify.isRunning && (isSpotify || !MusicPlayer.music.isRunning)
    }

    /// Opens Spotify's own search for `text` (works on any account).
    func searchInSpotify(_ text: String) {
        guard let q = text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "spotify:search:\(q)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Replays something from the Recent list.
    func play(recent np: NowPlaying) {
        switch np.player {
        case .spotify where np.trackID.hasPrefix("spotify:"):
            playSpotify(np.trackID)
        case .music:
            let id = np.trackID.replacingOccurrences(of: "\"", with: "")
            run("tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"\(id)\")") { [weak self] _ in
                self?.poll()
            }
        default:
            openPlayer()
        }
    }

    /// Plays a Spotify playlist, album or track by URI.
    func play(spotifyURI uri: String) { playSpotify(uri) }

    func search(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
        if searchesSpotify && !SpotifyAPI.shared.connected {
            // No Web API: match what's been played and saved here; the page
            // also offers Spotify's own search.
            let lower = q.lowercased()
            searchResults = q.isEmpty ? [] : recent.filter {
                $0.player == .spotify && $0.trackID.hasPrefix("spotify:") &&
                    ($0.title.lowercased().contains(lower) || $0.artist.lowercased().contains(lower))
            }.enumerated().map { i, np in
                QueueItem(id: np.trackID, title: np.title, subtitle: np.artist, index: i, uri: np.trackID)
            }
            return
        }
        if searchesSpotify, !q.isEmpty {
            Task {
                let items = await SpotifyAPI.shared.searchTracks(q) ?? []
                guard DrawerController.shared.searchText.trimmingCharacters(in: .whitespaces) == q else { return }
                searchResults = items.enumerated().map { i, item in
                    QueueItem(id: item.uri, title: item.name, subtitle: item.subtitle, index: i, uri: item.uri, artworkURL: item.artworkURL)
                }
            }
            return
        }
        guard !q.isEmpty, MusicPlayer.music.isRunning else { searchResults = []; return }
        let escaped = q.replacingOccurrences(of: "\"", with: "\\\"")
        let sep = "‖", rec = "¶"
        let source = """
        tell application "Music"
            set out to ""
            set hits to search library playlist 1 for "\(escaped)"
            set n to count of hits
            if n > 25 then set n to 25
            repeat with k from 1 to n
                set t to item k of hits
                set out to out & (persistent ID of t) & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(rec)"
            end repeat
            return out
        end tell
        """
        run(source) { [weak self] result in
            guard DrawerController.shared.searchText.trimmingCharacters(in: .whitespaces) == q else { return }
            self?.searchResults = (result ?? "").components(separatedBy: rec).enumerated().compactMap { i, line in
                let f = line.components(separatedBy: sep)
                guard f.count >= 3 else { return nil }
                return QueueItem(id: f[0], title: f[1], subtitle: f[2], index: i)
            }
        }
    }

    func playSearchResult(_ item: QueueItem) {
        if let uri = item.uri {
            playSpotify(uri)
            return
        }
        run("tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"\(item.id)\")") { [weak self] _ in
            self?.poll()
        }
    }

    /// Plays a Spotify track or playlist URI in the Spotify app.
    private func playSpotify(_ uri: String) {
        run("tell application \"Spotify\" to play track \"\(uri)\"") { [weak self] _ in
            self?.poll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refreshUpNext() }
        }
    }

    // MARK: - Script plumbing

    private func run(_ source: String, completion: (@MainActor (String?) -> Void)? = nil) {
        queue.async {
            var denied = false
            let result = AppleScriptRunner.run(source, permissionDenied: &denied)
            Task { @MainActor in
                if denied { self.automationDenied = true }
                completion?(result)
            }
        }
    }
}

enum AppleScriptRunner {
    private static var cache: [String: NSAppleScript] = [:]
    private static let lock = NSLock()

    static func descriptor(_ source: String) -> NSAppleEventDescriptor? {
        var denied = false
        return execute(source, permissionDenied: &denied)
    }

    static func run(_ source: String) -> String? {
        var denied = false
        return run(source, permissionDenied: &denied)
    }

    static func run(_ source: String, permissionDenied: inout Bool) -> String? {
        execute(source, permissionDenied: &permissionDenied)?.stringValue
    }

    private static func execute(_ source: String, permissionDenied: inout Bool) -> NSAppleEventDescriptor? {
        lock.lock()
        let script: NSAppleScript
        if let s = cache[source] {
            script = s
        } else {
            guard let s = NSAppleScript(source: source) else { lock.unlock(); return nil }
            if cache.count > 64 { cache.removeAll() }
            cache[source] = s
            script = s
        }
        lock.unlock()
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error, let code = error[NSAppleScript.errorNumber] as? Int {
            if code == -1743 { permissionDenied = true }
            return nil
        }
        return result
    }
}
