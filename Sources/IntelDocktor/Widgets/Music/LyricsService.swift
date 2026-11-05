import Foundation

struct LyricLine: Identifiable, Hashable {
    var time: Double
    var text: String
    var id: Double { time }
}

/// Synced lyrics from LRCLIB (free, no account).
@MainActor
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plain: String?
    @Published private(set) var loading = false
    private var currentKey: String?
    private var cache: [String: ([LyricLine], String?)] = [:]

    private init() {}

    func load(for np: NowPlaying) {
        let key = "\(np.artist)|\(np.title)"
        guard key != currentKey else { return }
        currentKey = key
        if let hit = cache[key] {
            lines = hit.0
            plain = hit.1
            return
        }
        lines = []
        plain = nil
        loading = true
        Task {
            let result = await fetch(np)
            guard currentKey == key else { return }
            cache[key] = result
            lines = result.0
            plain = result.1
            loading = false
        }
    }

    func currentIndex(at position: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        var idx: Int?
        for (i, l) in lines.enumerated() {
            if l.time <= position + 0.25 { idx = i } else { break }
        }
        return idx
    }

    private struct Response: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
    }

    /// "Song (feat. X) - Remastered 2011" → "Song".
    static func bareTitle(_ title: String) -> String {
        var t = title
        if let dash = t.range(of: " - ") { t = String(t[..<dash.lowerBound]) }
        t = t.replacingOccurrences(of: #"\s*[\(\[](feat\.|ft\.|with |remaster|live|mono|stereo|radio edit)[^\)\]]*[\)\]]"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespaces)
    }

    private func fetch(_ np: NowPlaying) async -> ([LyricLine], String?) {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [
            .init(name: "track_name", value: np.title),
            .init(name: "artist_name", value: np.artist),
            .init(name: "album_name", value: np.album),
            .init(name: "duration", value: String(Int(np.duration.rounded()))),
        ]
        var request = URLRequest(url: comps.url!)
        request.setValue("IntelDocktor/1.0 (personal build)", forHTTPHeaderField: "User-Agent")
        var response: Response?
        if let (data, resp) = try? await URLSession.shared.data(for: request),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            response = try? JSONDecoder().decode(Response.self, from: data)
        }
        if response == nil {
            // Fall back to a looser search, without the "- Remastered 2011" or
            // "(feat. …)" Spotify adds to titles, preferring a synced result
            // of about the same length.
            let bare = Self.bareTitle(np.title)
            for title in bare == np.title ? [np.title] : [np.title, bare] {
                var s = URLComponents(string: "https://lrclib.net/api/search")!
                s.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: np.artist)]
                var req = URLRequest(url: s.url!)
                req.setValue("IntelDocktor/1.0 (personal build)", forHTTPHeaderField: "User-Agent")
                guard let (data, _) = try? await URLSession.shared.data(for: req),
                      let list = try? JSONDecoder().decode([Response].self, from: data), !list.isEmpty else { continue }
                let synced = list.filter { $0.syncedLyrics != nil }
                response = synced.min(by: { abs(($0.duration ?? 0) - np.duration) < abs(($1.duration ?? 0) - np.duration) })
                    ?? list.first
                break
            }
        }
        guard let response else { return ([], nil) }
        return (Self.parse(response.syncedLyrics ?? ""), response.plainLyrics)
    }

    static func parse(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in lrc.split(separator: "\n") {
            let line = String(raw)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let stamp = line[line.index(after: line.startIndex)..<close]
            let parts = stamp.split(separator: ":")
            guard parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) else { continue }
            let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            out.append(LyricLine(time: m * 60 + s, text: text.isEmpty ? "♪" : text))
        }
        return out.sorted { $0.time < $1.time }
    }
}
