import SwiftUI

/// The whole screen: the playing group's artwork and track, or an idle screen.
///
/// The screen shows only the artwork, title, artist and album. Two panels stay hidden
/// until asked for: clicking or swiping up reveals playback controls at the bottom, and
/// swiping down reveals where the music is playing at the top. Swiping the other way,
/// Back, or 8 seconds without input hides them. The remote's Play/Pause button works at
/// any time without showing either.
struct NowPlayingView: View {
    let household: SonosHousehold

    @State private var artwork: UIImage?
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
                    PlayingView(nowPlaying: nowPlaying, artwork: artwork)
                }
                .buttonStyle(InvisibleButtonStyle())
                .focused($focus, equals: .canvas)
                .disabled(showsControls)
                // The view appears after launch, once speakers connect, so focus doesn't land here by itself.
                .onAppear { focus = .canvas }
                .transition(.opacity)

                if showsControls {
                    ControlBar(nowPlaying: nowPlaying, focus: $focus) { command in
                        lastInteraction = .now
                        household.send(command, to: nowPlaying.groupId)
                    }
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
        .onMoveCommand { direction in
            lastInteraction = .now
            switch direction {
            case .up where showsInfo: showsInfo = false
            case .up where !showsControls: revealControls()
            case .down where showsControls: showsControls = false
            case .down where !showsInfo: showsInfo = true
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
        return UIImage(data: data)
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
