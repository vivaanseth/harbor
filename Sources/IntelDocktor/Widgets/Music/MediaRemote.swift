import AppKit

/// What any app is playing (Safari, Chrome, podcasts…), via the private
/// MediaRemote framework behind the system Now Playing menu. Works on macOS 14.
enum MediaRemote {
    private typealias InfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias PIDFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    private typealias SendFn = @convention(c) (UInt32, CFDictionary?) -> Bool

    private static let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
    private static let info: InfoFn? = handle.flatMap { dlsym($0, "MRMediaRemoteGetNowPlayingInfo") }.map { unsafeBitCast($0, to: InfoFn.self) }
    private static let appPID: PIDFn? = handle.flatMap { dlsym($0, "MRMediaRemoteGetNowPlayingApplicationPID") }.map { unsafeBitCast($0, to: PIDFn.self) }
    private static let send: SendFn? = handle.flatMap { dlsym($0, "MRMediaRemoteSendCommand") }.map { unsafeBitCast($0, to: SendFn.self) }
    private static let callbackQueue = DispatchQueue(label: "mediaremote")

    /// Artwork as the system reports it, with whether the source described
    /// its media (an artist or album) alongside it.
    struct Artwork {
        var data: Data
        var identifier: String
        var described: Bool
    }

    /// Called from MusicService's background queue; waits briefly for the reply.
    static func nowPlaying() -> (NowPlaying, Artwork?)? {
        guard let info else { return nil }
        let done = DispatchSemaphore(value: 0)
        var dict: [String: Any] = [:]
        var pid: Int32 = 0
        info(callbackQueue) { d in dict = (d as? [String: Any]) ?? [:]; done.signal() }
        guard done.wait(timeout: .now() + 0.4) == .success else { return nil }
        if let appPID {
            appPID(callbackQueue) { p in pid = p; done.signal() }
            _ = done.wait(timeout: .now() + 0.2)
        }
        guard let title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else { return nil }
        let artist = dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        var elapsed = (dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
        if let stamp = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date, rate > 0 {
            elapsed += Date().timeIntervalSince(stamp) * rate
        }
        let source = NSRunningApplication(processIdentifier: pid)?.localizedName
        let np = NowPlaying(player: .system, trackID: "\(title)|\(artist)", title: title,
                            artist: artist.isEmpty ? (source ?? "") : artist,
                            album: dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "",
                            duration: (dict["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0,
                            position: elapsed, isPlaying: rate > 0, artworkURL: nil, sampledAt: Date(),
                            sourcePID: pid)
        let album = dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let artwork = (dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data).map { data in
            Artwork(data: data,
                    identifier: dict["kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] as? String ?? "\(data.count)-\(data.hashValue)",
                    described: !artist.isEmpty || !album.isEmpty)
        }
        return (np, artwork)
    }

    enum Command: UInt32 { case play = 0, pause = 1, toggle = 2, next = 4, previous = 5 }

    static func send(_ command: Command) { _ = send?(command.rawValue, nil) }
}
