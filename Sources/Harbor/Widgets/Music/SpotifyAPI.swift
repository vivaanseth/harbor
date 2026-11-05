import AppKit
import CryptoKit
import Network
import Security

/// Spotify's Web API, for what Spotify's AppleScript can't reach: the queue,
/// playlists and search. Signs in on Spotify's own page (PKCE, so no secret
/// is stored here) with the Client ID of the user's free Spotify developer
/// app; the refresh token lives in the Keychain. Playback itself still goes
/// through the Spotify app, which works on free accounts too.
@MainActor
final class SpotifyAPI: ObservableObject {
    static let shared = SpotifyAPI()
    static let port: UInt16 = 43821
    static let redirectURI = "http://127.0.0.1:43821/callback"
    static let dashboardURL = URL(string: "https://developer.spotify.com/dashboard")!
    private static let scopes = "user-read-playback-state user-read-currently-playing playlist-read-private playlist-read-collaborative"

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "spotify.clientID") }
    }
    @Published private(set) var connected: Bool
    @Published private(set) var accountName: String?
    /// Progress or a problem to show next to the Connect button.
    @Published private(set) var status: String?

    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var refreshTask: Task<String?, Never>?
    private var verifier = ""
    private var state = ""
    private var listener: NWListener?

    private init() {
        clientID = UserDefaults.standard.string(forKey: "spotify.clientID") ?? ""
        connected = Keychain.read() != nil
        accountName = UserDefaults.standard.string(forKey: "spotify.account")
    }

    // MARK: - Signing in

    func connect() {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { status = "Paste your app's Client ID first."; return }
        verifier = Self.randomString(64)
        state = Self.randomString(16)
        guard startListener() else { status = "Couldn't listen for Spotify's reply on port \(Self.port)."; return }
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = [
            .init(name: "client_id", value: id),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
            .init(name: "state", value: state),
            .init(name: "scope", value: Self.scopes),
        ]
        status = "Finish signing in to Spotify in your browser…"
        NSWorkspace.shared.open(url.url!)
    }

    func disconnect() {
        Keychain.delete()
        UserDefaults.standard.removeObject(forKey: "spotify.account")
        accessToken = nil
        connected = false
        accountName = nil
        status = nil
    }

    /// A one-request web server on the loopback address for Spotify's redirect.
    private func startListener() -> Bool {
        listener?.cancel()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return false }
        l.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                MainActor.assumeIsolated { self?.handle(request, on: connection) }
            }
        }
        l.start(queue: .main)
        listener = l
        // Stop waiting after a few minutes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self, weak l] in
            guard let self, let l, self.listener === l else { return }
            l.cancel()
            self.listener = nil
            if !self.connected { self.status = nil }
        }
        return true
    }

    private func handle(_ request: String, on connection: NWConnection) {
        // "GET /callback?code=…&state=… HTTP/1.1"
        let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard target.hasPrefix("/callback"), let query = URLComponents(string: target)?.queryItems else {
            respond(connection, status: "404 Not Found", message: "")
            return
        }
        let value = { (name: String) in query.first { $0.name == name }?.value }
        listener?.cancel()
        listener = nil
        guard value("state") == state, let code = value("code") else {
            respond(connection, status: "200 OK", message: "Spotify didn't allow access. You can close this tab.")
            status = value("error") == "access_denied" ? "Spotify access wasn't allowed." : "Spotify sign-in didn't complete."
            return
        }
        respond(connection, status: "200 OK", message: "Harbor is connected to Spotify. You can close this tab.")
        Task { await exchange(code: code) }
    }

    private func respond(_ connection: NWConnection, status: String, message: String) {
        let body = message.isEmpty ? "" :
            "<html><body style=\"font: 15px -apple-system; text-align: center; padding-top: 90px; color: #333\">\(message)</body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func exchange(code: String) async {
        let (token, _) = await tokenRequest([
            "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
            "client_id": clientID.trimmingCharacters(in: .whitespacesAndNewlines), "code_verifier": verifier,
        ])
        guard let token, let refresh = token.refresh_token else {
            status = "Spotify didn't accept the sign-in. Check the Client ID and redirect URI."
            return
        }
        Keychain.save(refresh)
        accessToken = token.access_token
        expiresAt = Date().addingTimeInterval(token.expires_in)
        connected = true
        status = nil
        if let me: Me = await get("/me") {
            accountName = me.display_name ?? me.id
            UserDefaults.standard.set(accountName, forKey: "spotify.account")
        }
        MusicService.shared.refreshUpNext()
        MusicService.shared.refreshPlaylists()
    }

    // MARK: - Tokens

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
    }

    private func tokenRequest(_ fields: [String: String]) async -> (TokenResponse?, Int) {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (nil, 0) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (code == 200 ? try? JSONDecoder().decode(TokenResponse.self, from: data) : nil, code)
    }

    /// A current access token, refreshing it (once, however many callers ask) when needed.
    private func token(forceRefresh: Bool = false) async -> String? {
        if !forceRefresh, let accessToken, Date() < expiresAt.addingTimeInterval(-60) { return accessToken }
        if let refreshTask { return await refreshTask.value }
        guard let refresh = Keychain.read() else { return nil }
        let task = Task<String?, Never> {
            let (token, code) = await tokenRequest([
                "grant_type": "refresh_token", "refresh_token": refresh,
                "client_id": clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
            guard let token else {
                // Revoked or the app was deleted: sign out. Network trouble: try again later.
                if code == 400 || code == 401 { disconnect() }
                return nil
            }
            accessToken = token.access_token
            expiresAt = Date().addingTimeInterval(token.expires_in)
            if let new = token.refresh_token { Keychain.save(new) }  // PKCE refresh tokens rotate
            return token.access_token
        }
        refreshTask = task
        let value = await task.value
        refreshTask = nil
        return value
    }

    private func get<T: Decodable>(_ path: String, retried: Bool = false) async -> T? {
        guard connected, let token = await token(forceRefresh: retried) else { return nil }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 && !retried { return await get(path, retried: true) }
        guard code == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - What the drawer shows

    struct Image: Decodable { let url: String }
    struct Artist: Decodable { let name: String }
    struct Album: Decodable { let images: [Image]? }
    struct Show: Decodable { let name: String }
    /// A track, or a podcast episode (which has a show and images instead).
    struct Item: Decodable {
        let name: String
        let uri: String
        let artists: [Artist]?
        let album: Album?
        let show: Show?
        let images: [Image]?

        var subtitle: String { artists?.map(\.name).joined(separator: ", ") ?? show?.name ?? "" }
        /// The smallest cover is plenty for a 30 pt thumbnail.
        var artworkURL: URL? { (album?.images ?? images)?.last.flatMap { URL(string: $0.url) } }
    }
    struct Playlist: Decodable {
        struct Count: Decodable { let total: Int }
        struct Owner: Decodable { let display_name: String? }
        let name: String
        let uri: String
        let images: [Image]?
        let tracks: Count?
        let owner: Owner?

        var artworkURL: URL? { images?.last.flatMap { URL(string: $0.url) } }
    }
    private struct Me: Decodable { let id: String; let display_name: String? }
    private struct Queue: Decodable { let queue: [Item?] }
    private struct Page<T: Decodable>: Decodable { let items: [T?] }
    private struct Search: Decodable { let tracks: Page<Item> }

    func queue() async -> [Item]? {
        (await get("/me/player/queue") as Queue?)?.queue.compactMap { $0 }
    }

    func playlists() async -> [Playlist]? {
        (await get("/me/playlists?limit=50") as Page<Playlist>?)?.items.compactMap { $0 }
    }

    func searchTracks(_ text: String) async -> [Item]? {
        guard let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return (await get("/search?type=track&limit=20&q=\(q)") as Search?)?.tracks.items.compactMap { $0 }
    }

    // MARK: - Helpers

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The Spotify refresh token, in the login keychain.
private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.vivaanseth.harbor.spotify",
        kSecAttrAccount as String: "refresh-token",
    ]

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        delete()
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
