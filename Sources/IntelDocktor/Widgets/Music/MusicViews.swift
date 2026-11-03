import SwiftUI

struct MusicBarView: View {
    var compact: Bool
    var height: CGFloat
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
            ArtworkView(image: music.artwork, size: height - 14 * s, radius: Theme.barRadius(height) - 6 * s)
            if hover || !np.isPlaying {
                Button { music.playPause() } label: {
                    Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18 * s, weight: .bold))
                        .frame(width: height - 14 * s, height: height - 14 * s)
                        .background(Color.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.barRadius(height) - 6 * s, style: .continuous))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hover)
    }

    private func wideBody(_ np: NowPlaying, _ s: CGFloat) -> some View {
        HStack(spacing: 11 * s) {
            ArtworkView(image: music.artwork, size: 40 * s, radius: 10 * s)
            VStack(alignment: .leading, spacing: 2 * s) {
                Text(np.title).font(Theme.font(15 * s, .bold)).lineLimit(1)
                Text(np.artist).font(Theme.font(12.5 * s, .semibold)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 6 * s)
            HStack(spacing: 6 * s) {
                TransportButton(symbol: "backward.fill", size: 17 * s) { music.previous() }
                TransportButton(symbol: np.isPlaying ? "pause.fill" : "play.fill", size: 20 * s) { music.playPause() }
                TransportButton(symbol: "forward.fill", size: 17 * s) { music.next() }
            }
        }
        .padding(.leading, 10 * s)
        .padding(.trailing, 12 * s)
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
    var action: () -> Void
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .frame(width: size * 1.9, height: size * 1.9)
                .background(Circle().fill(Color.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
                .scaleEffect(pressed ? 0.88 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
            .onEnded { _ in withAnimation(.spring(response: 0.25)) { pressed = false } })
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
    var showArtwork = true
    var title: String
    var subtitle: String
    var active = false
    var trailing: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HoverRow(radius: 9, action: action) {
            HStack(spacing: 9) {
                if showArtwork { ArtworkView(image: artwork, size: 30, radius: 6) }
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

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                if let np = music.nowPlaying {
                    TrackRow(artwork: music.artwork, title: np.title, subtitle: np.artist, active: true) {
                        music.openPlayer()
                    }
                    if np.player == .spotify {
                        note("Spotify doesn't share its queue with other apps.")
                    } else if music.upNext.isEmpty {
                        note("Nothing queued after this track.")
                    }
                    ForEach(music.upNext) { item in
                        TrackRow(title: item.title, subtitle: item.subtitle) { music.playQueueItem(item) }
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

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                if music.playlists.isEmpty {
                    EmptyStateView(symbol: "music.note.list", title: "No playlists",
                                   message: MusicPlayer.music.isRunning ? "Create playlists in Apple Music." : "Open Apple Music to browse playlists.")
                        .frame(height: 220)
                }
                ForEach(music.playlists) { p in
                    TrackRow(title: p.name, subtitle: p.subtitle, trailing: "\(p.count)") { music.play(playlist: p) }
                }
            }
        }
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
                    EmptyStateView(symbol: "magnifyingglass", title: "Search your library",
                                   message: "Songs, artists and albums in Apple Music.")
                        .frame(height: 200)
                } else {
                    Text("Songs").font(Theme.font(12, .bold)).foregroundStyle(Theme.secondary).padding(.leading, 10)
                    ForEach(music.searchResults) { item in
                        TrackRow(title: item.title, subtitle: item.subtitle) { music.playSearchResult(item) }
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
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let pos = music.nowPlaying?.livePosition(at: context.date) ?? 0
                let current = lyrics.currentIndex(at: pos)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            Color.clear.frame(height: 60)
                            ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { i, line in
                                Text(line.text)
                                    .font(Theme.font(i == current ? 19 : 16, .bold))
                                    .foregroundStyle(i == current ? Theme.primary : (i < (current ?? 0) ? Theme.tertiary : Theme.secondary))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                                    .onTapGesture { music.seek(to: line.time) }
                            }
                            Color.clear.frame(height: 100)
                        }
                        .padding(.horizontal, 6)
                    }
                    .onChange(of: current) { _, new in
                        guard let new else { return }
                        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(new, anchor: .center) }
                    }
                    .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
                }
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                         .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
    }
}
