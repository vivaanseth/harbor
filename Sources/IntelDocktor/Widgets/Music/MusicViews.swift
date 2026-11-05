import SwiftUI

struct MusicBarView: View {
    var compact: Bool
    var height: CGFloat
    var width: CGFloat = 400
    @ObservedObject private var music = MusicService.shared
    @State private var hover = false

    var body: some View {
        let s = height / 60
        Group {
            if let np = music.nowPlaying {
                if compact { compactBody(np, s) } else { wideBody(np, s) }
            } else {
                idleBody(s)
            }
        }
        .foregroundStyle(Theme.primary)
        .onHover { hover = $0 }
    }

    private func compactBody(_ np: NowPlaying, _ s: CGFloat) -> some View {
        ZStack {
            ArtworkView(image: music.artwork, size: height - 14 * s, radius: Theme.barRadius(height) - 6 * s, isAppIcon: music.artworkIsAppIcon)
            if hover || !np.isPlaying {
                Button { WidgetInteraction.shared.used(); music.playPause() } label: {
                    SwapGlyph(symbol: np.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18 * s, weight: .semibold))
                        .frame(width: height - 14 * s, height: height - 14 * s)
                        .background(.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.barRadius(height) - 6 * s, style: .continuous))
                }
                .buttonStyle(PressableStyle(scale: 0.92))
                .widgetControl()
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(Motion.snappy, value: hover)
    }

    /// Spacing and controls for the width there is: roomy with all three
    /// controls, then tighter, then play/pause only, then none. The title
    /// always keeps a little room.
    private struct Fit { var pad: CGFloat; var gap: CGFloat; var hit: CGFloat; var spacing: CGFloat; var controls: Int }

    private func fit(_ s: CGFloat) -> Fit {
        let options = [Fit(pad: 11, gap: 11, hit: 2.1, spacing: 4, controls: 3),
                       Fit(pad: 8, gap: 8, hit: 1.7, spacing: 2, controls: 3),
                       Fit(pad: 8, gap: 8, hit: 1.7, spacing: 2, controls: 1)]
        for f in options {
            let controls = f.controls == 3 ? (13 + 16 + 13) * f.hit + 2 * f.spacing : 16 * f.hit
            if width >= (2 * f.pad + 40 + 2 * f.gap + 28 + controls) * s { return f }
        }
        return Fit(pad: 8, gap: 8, hit: 1.45, spacing: 2, controls: 0)
    }

    private func wideBody(_ np: NowPlaying, _ s: CGFloat) -> some View {
        let f = fit(s)
        return HStack(spacing: f.gap * s) {
            ArtworkView(image: music.artwork, size: 40 * s, radius: 10 * s, isAppIcon: music.artworkIsAppIcon)
            VStack(alignment: .leading, spacing: 2 * s) {
                Text(np.title).font(Theme.font(14 * s, .semibold)).lineLimit(1)
                    .contentTransition(.opacity).animation(Motion.content, value: np.title)
                Text(np.artist).font(Theme.font(12.5 * s, .regular)).foregroundStyle(Theme.secondary).lineLimit(1)
                    .contentTransition(.opacity).animation(Motion.content, value: np.artist)
            }
            Spacer(minLength: 0)
            HStack(spacing: f.spacing * s) {
                // Sized like Apple's Now Playing controls: present, not loud.
                if f.controls == 3 { TransportButton(symbol: "backward.fill", size: 13 * s, hit: f.hit, nudges: true) { music.previous() } }
                if f.controls >= 1 { TransportButton(symbol: np.isPlaying ? "pause.fill" : "play.fill", size: 16 * s, hit: f.hit) { music.playPause() } }
                if f.controls == 3 { TransportButton(symbol: "forward.fill", size: 13 * s, hit: f.hit, nudges: true) { music.next() } }
            }
            .animation(Motion.smooth, value: f.controls)
        }
        .padding(.leading, (f.pad - 1) * s)
        .padding(.trailing, (f.pad + 1) * s)
    }

    private func idleBody(_ s: CGFloat) -> some View {
        HStack(spacing: 10 * s) {
            Image(systemName: "music.note")
                .font(.system(size: 18 * s, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
            if !compact {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not Playing").font(Theme.font(14 * s, .bold)).foregroundStyle(Theme.secondary)
                    Text("Open Music or Spotify").font(Theme.font(11 * s, .semibold)).foregroundStyle(Theme.tertiary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, compact ? 0 : 16 * s)
    }
}

private struct TransportButton: View {
    var symbol: String
    var size: CGFloat
    var hit: CGFloat = 1.9
    /// Skip buttons give a small nudge when used; play/pause swaps glyphs instead.
    var nudges = false
    var action: () -> Void
    @State private var hover = false
    @State private var taps = 0

    var body: some View {
        Button {
            WidgetInteraction.shared.used()
            if nudges { taps += 1 }
            action()
        } label: {
            SwapGlyph(symbol: symbol)
                .font(.system(size: size, weight: .semibold))
                .symbolEffect(.bounce.down, options: .speed(1.4), value: taps)
                .frame(width: size * hit, height: size * hit)
                .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.86))
        .onHover { h in
            WidgetInteraction.shared.hovering(h)
            withAnimation(Motion.snappy) { hover = h }
        }
    }
}

// MARK: - Drawer

struct MusicDrawer: View {
    @ObservedObject private var music = MusicService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var drawer = DrawerController.shared

    private let tabs = [
        DrawerTab(id: "upNext", symbol: "list.bullet", label: "Up Next"),
        DrawerTab(id: "playlists", symbol: "music.note.list", label: "Playlists"),
        DrawerTab(id: "lyrics", symbol: "quote.bubble", label: "Lyrics"),
        DrawerTab(id: "recent", symbol: "clock.arrow.circlepath", label: "Recent"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DrawerTabBar(tabs: tabs, selection: $settings.musicDrawerPage) {
                if drawer.searchVisible {
                    IconButton(symbol: "xmark", size: 12) { drawer.searchVisible = false; drawer.searchText = "" }
                } else {
                    IconButton(symbol: "magnifyingglass", size: 12) { drawer.searchVisible = true }
                }
            }
            Group {
                if drawer.searchVisible {
                    SearchPage()
                } else {
                    switch settings.musicDrawerPage {
                    case "playlists": PlaylistsPage()
                    case "lyrics": LyricsPage()
                    case "recent": RecentPage()
                    default: UpNextPage()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            music.refreshUpNext()
            music.refreshPlaylists()
        }
    }
}

private struct TrackRow: View {
    var artwork: NSImage? = nil
    /// A cover to fetch instead (Spotify items).
    var artworkURL: URL? = nil
    var showArtwork = true
    var title: String
    var subtitle: String
    var active = false
    var trailing: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HoverRow(radius: 9, action: action) {
            HStack(spacing: 9) {
                if showArtwork {
                    if let artworkURL {
                        AsyncImage(url: artworkURL, transaction: Transaction(animation: Motion.content)) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                            } else {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.tile)
                            }
                        }
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        ArtworkView(image: artwork, size: 30, radius: 6, isAppIcon: active && MusicService.shared.artworkIsAppIcon)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(Theme.font(12.5, .bold)).lineLimit(1)
                    Text(subtitle).font(Theme.font(10.5, .semibold)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if active {
                    Image(systemName: "waveform").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.mint)
                        .symbolEffect(.variableColor.iterative, isActive: MusicService.shared.nowPlaying?.isPlaying ?? false)
                } else if let trailing {
                    Text(trailing).font(Theme.mono(11, .medium)).foregroundStyle(Theme.tertiary)
                }
            }
        }
        .background(active ? RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.tile) : nil)
    }
}

private struct UpNextPage: View {
    @ObservedObject private var music = MusicService.shared
    @ObservedObject private var spotify = SpotifyAPI.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                if let np = music.nowPlaying {
                    TrackRow(artwork: music.artwork, title: np.title, subtitle: np.artist, active: true) {
                        music.openPlayer()
                    }
                    if music.isSpotify && !spotify.connected {
                        ConnectSpotifyNote(text: "Connect Spotify to see what's playing next.")
                    } else if music.upNext.isEmpty {
                        note("Nothing queued after this track.")
                    } else {
                        Text("Up Next").font(Theme.font(11, .semibold)).foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10).padding(.top, 6)
                    }
                    ForEach(music.upNext) { item in
                        TrackRow(artworkURL: item.artworkURL, showArtwork: item.artworkURL != nil, title: item.title,
                                 subtitle: item.subtitle) { music.playQueueItem(item) }
                    }
                } else {
                    EmptyStateView(symbol: "music.note", title: "Nothing playing",
                                   message: "Start something in Music or Spotify.")
                        .frame(height: 220)
                }
            }
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(Theme.font(12, .medium)).foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
    }
}

private struct PlaylistsPage: View {
    @ObservedObject private var music = MusicService.shared
    @ObservedObject private var spotify = SpotifyAPI.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                if MusicPlayer.spotify.isRunning && !spotify.connected {
                    ConnectSpotifyNote(text: "Connect Spotify to play your playlists from here.")
                }
                if music.playlists.isEmpty && (spotify.connected || !MusicPlayer.spotify.isRunning) {
                    EmptyStateView(symbol: "music.note.list", title: "No playlists",
                                   message: "Open Apple Music or Spotify to browse your playlists.")
                        .frame(height: 200)
                }
                ForEach(music.playlists) { p in
                    TrackRow(artworkURL: p.artworkURL, showArtwork: p.artworkURL != nil, title: p.name, subtitle: p.subtitle,
                             trailing: "\(p.count)") { music.play(playlist: p) }
                }
            }
        }
    }
}

/// Points to Settings for connecting Spotify (queue, playlists, search).
private struct ConnectSpotifyNote: View {
    var text: String

    var body: some View {
        VStack(spacing: 8) {
            Text(text).font(Theme.font(12, .medium)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            PillButton(title: "Connect Spotify…", prominent: true) {
                DrawerController.shared.close()
                SettingsWindowController.shared.show(tab: .widgets)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

private struct RecentPage: View {
    @ObservedObject private var music = MusicService.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                if music.recent.isEmpty {
                    EmptyStateView(symbol: "clock.arrow.circlepath", title: "No history yet",
                                   message: "Tracks you play show up here.")
                        .frame(height: 220)
                }
                ForEach(music.recent, id: \.trackID) { np in
                    TrackRow(title: np.title, subtitle: "\(np.artist) · \(np.player.rawValue)")
                }
            }
        }
    }
}

private struct SearchPage: View {
    @ObservedObject private var music = MusicService.shared
    @ObservedObject private var drawer = DrawerController.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                if drawer.searchText.isEmpty {
                    EmptyStateView(symbol: "magnifyingglass", title: music.searchesSpotify ? "Search Spotify" : "Search your library",
                                   message: music.searchesSpotify ? "Songs on Spotify." : "Songs, artists and albums in Apple Music.")
                        .frame(height: 200)
                } else {
                    Text("Songs").font(Theme.font(12, .bold)).foregroundStyle(Theme.secondary).padding(.leading, 10)
                    ForEach(music.searchResults) { item in
                        TrackRow(artworkURL: item.artworkURL, showArtwork: item.artworkURL != nil, title: item.title,
                                 subtitle: item.subtitle) { music.playSearchResult(item) }
                    }
                }
            }
        }
        .task(id: drawer.searchText) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { music.search(drawer.searchText) }
        }
    }
}

private struct LyricsPage: View {
    @ObservedObject private var lyrics = LyricsService.shared
    @ObservedObject private var music = MusicService.shared

    var body: some View {
        if lyrics.lines.isEmpty {
            if let plain = lyrics.plain, !plain.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(plain).font(Theme.font(15, .semibold)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                EmptyStateView(symbol: "quote.bubble", title: lyrics.loading ? "Finding lyrics…" : "No lyrics for this track")
            }
        } else {
            // Like Apple Music: the line being sung is bright, the rest dim,
            // and the page glides so it stays a little above centre. Lines
            // light up a beat early, as the voice arrives. Click a line to jump there.
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let pos = music.nowPlaying?.livePosition(at: context.date) ?? 0
                let current = lyrics.currentIndex(at: pos + 0.15)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 12) {
                            Color.clear.frame(height: 60)
                            ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { i, line in
                                LyricLineView(text: line.text, state: i == current ? .current : (i < (current ?? 0) ? .past : .upcoming)) {
                                    music.seek(to: line.time)
                                }
                                .id(i)
                            }
                            Color.clear.frame(height: 110)
                        }
                        .padding(.horizontal, 6)
                        .animation(Motion.smooth, value: current)
                    }
                    .onChange(of: current) { _, new in
                        guard let new else { return }
                        withAnimation(Motion.smooth) { proxy.scrollTo(new, anchor: UnitPoint(x: 0, y: 0.4)) }
                    }
                    .onAppear { if let current { proxy.scrollTo(current, anchor: UnitPoint(x: 0, y: 0.4)) } }
                }
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                         .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
    }
}

private struct LyricLineView: View {
    enum State { case past, current, upcoming }
    var text: String
    var state: State
    var seek: () -> Void
    @SwiftUI.State private var hover = false

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Color.white.opacity(state == .current ? 1 : (hover ? 0.7 : (state == .past ? 0.3 : 0.45))))
            .scaleEffect(state == .current ? 1 : 0.95, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: seek)
            .onHover { hover = $0 }
    }
}
