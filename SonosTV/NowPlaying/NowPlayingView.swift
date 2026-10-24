import SwiftUI

/// The whole screen: the playing group's artwork and track, or an idle screen.
///
/// The screen shows only the artwork, title, artist and album. Two panels stay hidden
/// until asked for: clicking or swiping up reveals playback controls at the bottom, and
/// swiping down reveals where the music is playing at the top. Swiping the other way,
/// Back, or 8 seconds without input hides them. The remote's Play/Pause button works at
/// any time without showing either. Swiping left or right pages through photos of the
/// artist, fetched in the background when the artist changes.
struct NowPlayingView: View {
    let household: SonosHousehold

    @State private var artwork: UIImage?
    /// Photos of the current artist, added as they download.
    @State private var artistPhotos: [UIImage] = []
    /// 0 is the artwork screen; 1 and up are artist photos.
    @State private var page = 0
    /// Steps through the pages on its own, including the artwork, until turned off.
    /// Remembered between launches.
    @AppStorage("SlideshowOn") private var isSlideshowOn = false
    @State private var showsControls = false
    @State private var showsInfo = false
    @State private var lastInteraction = Date.now
    /// A play or pause symbol shown briefly after the Play/Pause button.
    @State private var flashSymbol: String?
    @FocusState private var focus: ControlFocus?

    var body: some View {
        let nowPlaying = household.nowPlaying
        ZStack {
            Color.black

            if let nowPlaying {
                // One invisible, full-screen button: clicking the remote reveals the controls.
                Button(action: revealControls) {
                    if page > 0, artistPhotos.indices.contains(page - 1) {
                        ArtistPhotoView(
                            photo: artistPhotos[page - 1],
                            nowPlaying: nowPlaying,
                            page: page,
                            pageCount: artistPhotos.count + 1
                        )
                        .id(page)
                        .transition(.opacity)
                    } else {
                        PlayingView(nowPlaying: nowPlaying, artwork: artwork)
                            .transition(.opacity)
                    }
                }
                .buttonStyle(InvisibleButtonStyle())
                .focused($focus, equals: .canvas)
                .disabled(showsControls)
                // The view appears after launch, once speakers connect, so focus doesn't land here by itself.
                .onAppear { focus = .canvas }
                .transition(.opacity)

                if showsControls {
                    ControlBar(
                        nowPlaying: nowPlaying,
                        focus: $focus,
                        hasPhotos: !artistPhotos.isEmpty,
                        isSlideshowOn: isSlideshowOn,
                        perform: { command in
                            lastInteraction = .now
                            household.send(command, to: nowPlaying.groupId)
                        },
                        toggleSlideshow: toggleSlideshow
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if showsInfo {
                    InfoPanel(nowPlaying: nowPlaying)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let flashSymbol {
                    PlayPauseFlash(symbol: flashSymbol)
                        .transition(.opacity)
                }
            } else {
                IdleView(status: household.status, roomCount: household.groups.count)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: nowPlaying)
        .animation(.easeInOut(duration: 0.6), value: artwork)
        .animation(.easeOut(duration: 0.3), value: showsControls)
        .animation(.easeOut(duration: 0.3), value: showsInfo)
        .animation(.easeOut(duration: 0.3), value: flashSymbol)
        .animation(.easeInOut(duration: 0.5), value: page)
        .onMoveCommand { direction in
            lastInteraction = .now
            switch direction {
            case .up where showsInfo: showsInfo = false
            case .up where !showsControls: revealControls()
            case .down where showsControls: showsControls = false
            case .down where !showsInfo: showsInfo = true
            // With the control bar up, left and right move between its buttons instead.
            case .left where !showsControls: turnPage(by: -1)
            case .right where !showsControls: turnPage(by: 1)
            default: break
            }
        }
        .onPlayPauseCommand(perform: togglePlayPause)
        // While a panel is up, Back hides it; otherwise Back leaves the app as usual.
        .onExitCommand(perform: showsControls || showsInfo ? { hidePanels() } : nil)
        .onChange(of: focus) { lastInteraction = .now }
        .onChange(of: showsControls) { _, shown in
            if !shown { focus = .canvas }
        }
        .onChange(of: nowPlaying == nil) { _, isIdle in
            if isIdle { hidePanels() }
        }
        .task(id: lastInteraction) {
            guard showsControls || showsInfo else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { hidePanels() }
        }
        .task(id: flashSymbol) {
            guard flashSymbol != nil else { return }
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { flashSymbol = nil }
        }
        .task(id: nowPlaying?.artworkURL) {
            artwork = await Self.loadImage(nowPlaying?.artworkURL)
        }
        .task(id: [isSlideshowOn ? 1 : 0, page, artistPhotos.count]) {
            // Restarts whenever the page changes, so a manual swipe gets the full interval too.
            guard isSlideshowOn, !artistPhotos.isEmpty else { return }
            try? await Task.sleep(for: Self.slideshowInterval)
            if !Task.isCancelled { turnPage(by: 1) }
        }
        .task(id: nowPlaying?.artist) {
            // A new artist: back to the artwork, and fetch their photos one by one.
            page = 0
            artistPhotos = []
            guard let artist = nowPlaying?.artist else { return }
            for url in await ArtistPhotos.urls(for: artist) {
                guard !Task.isCancelled else { return }
                if let photo = await Self.loadImage(url) {
                    artistPhotos.append(photo)
                }
            }
        }
        .onChange(of: nowPlaying?.isPlaying == true, initial: true) { _, isPlaying in
            // Keep the screen awake while music plays; let the screensaver run when paused or idle.
            UIApplication.shared.isIdleTimerDisabled = isPlaying
        }
    }

    private func revealControls() {
        lastInteraction = .now
        showsInfo = false
        showsControls = true
    }

    private func hidePanels() {
        showsControls = false
        showsInfo = false
    }

    private static let slideshowInterval = Duration.seconds(8)

    /// Slideshow mode is a toggle. Turning it on goes straight to a photo; turning it off
    /// goes back to the album artwork. Either way the control bar closes.
    private func toggleSlideshow() {
        isSlideshowOn.toggle()
        hidePanels()
        if isSlideshowOn {
            if page == 0 { turnPage(by: 1) }
        } else {
            page = 0
        }
    }

    /// Steps through the artwork and the artist photos, wrapping around at either end.
    private func turnPage(by step: Int) {
        let count = artistPhotos.count + 1
        guard count > 1 else { return }
        page = (page + step + count) % count
    }

    private func togglePlayPause() {
        guard let nowPlaying = household.nowPlaying else { return }
        lastInteraction = .now
        if nowPlaying.isPlaying {
            guard nowPlaying.canPause else { return }
            household.send(.pause, to: nowPlaying.groupId)
        } else {
            household.send(.play, to: nowPlaying.groupId)
        }
        // The bar's button already shows the new state; flash only when the bar is hidden.
        if !showsControls {
            flashSymbol = nowPlaying.isPlaying ? "pause.fill" : "play.fill"
        }
    }

    private static func loadImage(_ url: URL?) async -> UIImage? {
        guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        // Decode now rather than on first draw, so paging doesn't stutter.
        return await UIImage(data: data)?.byPreparingForDisplay()
    }
}

/// One artist photo filling the screen, with a small caption of what's playing and dots
/// showing where it sits among the pages.
private struct ArtistPhotoView: View {
    let photo: UIImage
    let nowPlaying: NowPlaying
    let page: Int
    let pageCount: Int

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay {
                    if isWidescreen {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                    } else {
                        // Square or portrait photos would lose faces if cropped to fill;
                        // show them whole over a blurred copy instead.
                        ZStack {
                            // Inside its own clipped layer, so the fill doesn't make the stack larger than the screen.
                            Color.clear
                                .overlay {
                                    Image(uiImage: photo)
                                        .resizable()
                                        .scaledToFill()
                                        .blur(radius: 90)
                                        .overlay(Color.black.opacity(0.5))
                                }
                                .clipped()
                            Image(uiImage: photo)
                                .resizable()
                                .scaledToFit()
                                .clipShape(.rect(cornerRadius: 28))
                                .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
                                .padding(.vertical, 120)
                        }
                    }
                }
                .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(nowPlaying.title)
                        .font(.system(size: 40, weight: .bold))
                        .lineLimit(1)
                    if let artist = nowPlaying.artist {
                        Text(artist)
                            .font(.system(size: 30))
                            .lineLimit(1)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                Spacer()
                PageDots(page: page, count: pageCount)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 100)
            .padding(.bottom, 70)
        }
    }

    private var isWidescreen: Bool {
        photo.size.width / max(photo.size.height, 1) > 1.4
    }
}

private struct PageDots: View {
    let page: Int
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(index == page ? 0.9 : 0.35))
                    .frame(width: 12, height: 12)
            }
        }
    }
}

private struct PlayingView: View {
    let nowPlaying: NowPlaying
    let artwork: UIImage?

    var body: some View {
        ZStack {
            // Blurred artwork fills the background.
            Color.clear
                .overlay {
                    if let artwork {
                        Image(uiImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 90)
                            .overlay(Color.black.opacity(0.45))
                    }
                }
                .clipped()

            HStack(spacing: 90) {
                ArtworkTile(image: artwork)
                    .frame(width: 760, height: 760)

                VStack(alignment: .leading, spacing: 18) {
                    Text(nowPlaying.title)
                        .font(.system(size: 76, weight: .bold))
                        .lineLimit(3)
                        .foregroundStyle(.white)

                    if let artist = nowPlaying.artist {
                        Text(artist)
                            .font(.system(size: 50, weight: .medium))
                            .lineLimit(2)
                            .foregroundStyle(.white.opacity(0.85))
                    }

                    if let detail = nowPlaying.detail {
                        Text(detail)
                            .font(.system(size: 38))
                            .lineLimit(2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(nowPlaying.title)
                .transition(.opacity)
            }
            .padding(.horizontal, 140)
        }
    }
}

private struct ArtworkTile: View {
    let image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(.white.opacity(0.08))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 200))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .clipShape(.rect(cornerRadius: 28))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
    }
}

private struct IdleView: View {
    let status: SonosHousehold.Status
    let roomCount: Int

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "hifispeaker.2")
                .font(.system(size: 120))
                .foregroundStyle(.white.opacity(0.35))
            Text("Nothing playing")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(statusText)
                .font(.system(size: 30))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(80)
    }

    private var statusText: String {
        switch status {
        case .searching:
            "Looking for Sonos speakers…"
        case .localNetworkBlocked:
            "Can't search the local network. Turn on Local Network access for Sonos TV in Settings."
        case .connecting:
            "Connecting to Sonos…"
        case .connected:
            roomCount == 1 ? "Connected to 1 room" : "Connected to \(roomCount) rooms"
        }
    }
}
