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
            // Fall back to a looser search.
            var s = URLComponents(string: "https://lrclib.net/api/search")!
            s.queryItems = [.init(name: "track_name", value: np.title), .init(name: "artist_name", value: np.artist)]
            var req = URLRequest(url: s.url!)
            req.setValue("IntelDocktor/1.0 (personal build)", forHTTPHeaderField: "User-Agent")
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let list = try? JSONDecoder().decode([Response].self, from: data) {
                response = list.first(where: { $0.syncedLyrics != nil }) ?? list.first
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
