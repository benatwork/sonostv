import SwiftUI

/// The whole screen: the playing group's artwork and track, or an idle screen.
struct NowPlayingView: View {
    let household: SonosHousehold

    @State private var artwork: UIImage?

    var body: some View {
        let nowPlaying = household.nowPlaying
        ZStack {
            Color.black

            if let nowPlaying {
                PlayingView(nowPlaying: nowPlaying, artwork: artwork)
                    .transition(.opacity)
            } else {
                IdleView(status: household.status, roomCount: household.groups.count)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: nowPlaying)
        .animation(.easeInOut(duration: 0.6), value: artwork)
        .task(id: nowPlaying?.artworkURL) {
            artwork = await Self.loadImage(nowPlaying?.artworkURL)
        }
        .onChange(of: nowPlaying != nil, initial: true) { _, isShowingMusic in
            // Keep the screen awake while music is showing; let the screensaver run otherwise.
            UIApplication.shared.isIdleTimerDisabled = isShowingMusic
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
                    Label(roomLine, systemImage: "hifispeaker.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.bottom, 12)

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

    private var roomLine: String {
        nowPlaying.isPlaying ? nowPlaying.roomName : "\(nowPlaying.roomName) · Paused"
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
