import AppKit
import Combine

enum MusicPlayer: String {
    case music = "Music"
    case spotify = "Spotify"

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
}

struct PlaylistItem: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var subtitle: String
    var count: Int
}

/// Apple Music and Spotify over Apple Events. Never launches a player that
/// isn't already running.
@MainActor
final class MusicService: ObservableObject {
    static let shared = MusicService()

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isPlayerAvailable = false
    @Published private(set) var upNext: [QueueItem] = []
    @Published private(set) var playlists: [PlaylistItem] = []
    @Published private(set) var recent: [NowPlaying] = []
    @Published private(set) var searchResults: [QueueItem] = []
    @Published private(set) var automationDenied = false

    private let queue = DispatchQueue(label: "music.applescript", qos: .userInitiated)
    private var timer: Timer?
    private var artworkTrackID: String?
    private let settings = AppSettings.shared
    private var artworkCache: [String: NSImage] = [:]

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
        if isPlayerAvailable == running.isEmpty { isPlayerAvailable = !running.isEmpty }
        guard !running.isEmpty else {
            if nowPlaying != nil { nowPlaying = nil; artwork = nil }
            return
        }
        queue.async { [weak self] in
            var best: NowPlaying?
            for p in running {
                guard let np = Self.fetchNowPlaying(p) else { continue }
                if best == nil || (np.isPlaying && !(best!.isPlaying)) { best = np }
            }
            Task { @MainActor in self?.apply(best) }
        }
    }

    private func apply(_ np: NowPlaying?) {
        let previous = nowPlaying
        // Skip no-op updates so the widgets don't re-render every second.
        if let p = previous, let n = np, p.trackID == n.trackID, p.isPlaying == n.isPlaying,
           p.title == n.title, abs(p.livePosition(at: n.sampledAt) - n.position) < 1.5 {
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
            if DrawerController.shared.openKind == .music { refreshUpNext() }
        }
    }

    nonisolated private static func fetchNowPlaying(_ p: MusicPlayer) -> NowPlaying? {
        let sep = "‖"
        let source: String
        switch p {
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
        guard let result = AppleScriptRunner.run(source), result != "stopped" else { return nil }
        let parts = result.components(separatedBy: sep)
        guard parts.count >= 8 else { return nil }
        let num: (String) -> Double = { Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return NowPlaying(player: p, trackID: parts[1].isEmpty ? parts[2] + parts[3] : parts[1],
                          title: parts[2], artist: parts[3], album: parts[4],
                          duration: num(parts[5]), position: num(parts[6]),
                          isPlaying: parts[0] == "playing",
                          artworkURL: parts[7].isEmpty ? nil : parts[7], sampledAt: Date())
    }

    private func loadArtwork(_ np: NowPlaying) {
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
        guard let np = nowPlaying else { return }
        run("tell application \"\(np.player.rawValue)\" to set player position to \(Int(seconds))")
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
        run("tell application \"\(player.rawValue)\" to \(cmd)") { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.poll() }
        }
    }

    func openPlayer() {
        guard let p = nowPlaying?.player ?? preferredPlayers.first(where: \.isRunning),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: - Drawer data

    func refreshUpNext() {
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

    func playQueueItem(_ item: QueueItem) {
        run("tell application \"Music\" to play track \(item.index) of current playlist") { [weak self] _ in self?.poll() }
    }

    func refreshPlaylists() {
        guard MusicPlayer.music.isRunning else { playlists = []; return }
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
            self?.playlists = (result ?? "").components(separatedBy: rec).compactMap { line in
                let f = line.components(separatedBy: sep)
                guard f.count >= 2, !f[0].isEmpty else { return nil }
                return PlaylistItem(name: f[0], subtitle: "Apple Music", count: Int(f[1]) ?? 0)
            }
        }
    }

    func play(playlist: PlaylistItem) {
        let name = playlist.name.replacingOccurrences(of: "\"", with: "\\\"")
        run("tell application \"Music\" to play user playlist \"\(name)\"") { [weak self] _ in self?.poll() }
    }

    func search(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
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
        run("tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"\(item.id)\")") { [weak self] _ in
            self?.poll()
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
