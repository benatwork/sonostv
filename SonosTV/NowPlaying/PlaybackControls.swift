import SwiftUI

/// Where remote focus can be on the now-playing screen.
enum ControlFocus: Hashable {
    /// The full-screen artwork, which has no visible focus state.
    case canvas
    case previous
    case playPause
    case next
    case slideshow
}

/// The hidden control bar along the bottom of the screen: playback, plus a button that
/// starts or stops the artist photo slideshow.
struct ControlBar: View {
    let nowPlaying: NowPlaying
    let focus: FocusState<ControlFocus?>.Binding
    let hasPhotos: Bool
    let isSlideshowOn: Bool
    let perform: (SonosHousehold.PlaybackCommand) -> Void
    let toggleSlideshow: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 48) {
                control("backward.fill", focus: .previous, enabled: nowPlaying.canSkipToPrevious) {
                    perform(.skipToPreviousTrack)
                }
                control(
                    nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                    focus: .playPause,
                    enabled: canPlayPause
                ) {
                    perform(nowPlaying.isPlaying ? .pause : .play)
                }
                control("forward.fill", focus: .next, enabled: nowPlaying.canSkip) {
                    perform(.skipToNextTrack)
                }
                // A toggle: the same symbol, filled while slideshow mode is on.
                control(
                    isSlideshowOn ? "play.rectangle.on.rectangle.fill" : "play.rectangle.on.rectangle",
                    focus: .slideshow,
                    enabled: canSlideshow,
                    action: toggleSlideshow
                )
                // Set apart from playback: it controls the screen, not the music.
                .padding(.leading, 48)
            }
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            }
        }
        // Focus can't land on a disabled button. Radio, for example, can't pause or skip,
        // so the slideshow button may be the only one that works.
        .onAppear { focus.wrappedValue = canPlayPause ? .playPause : canSlideshow ? .slideshow : nil }
    }

    private var canPlayPause: Bool {
        !nowPlaying.isPlaying || nowPlaying.canPause
    }

    private var canSlideshow: Bool {
        hasPhotos || isSlideshowOn
    }

    private func control(
        _ symbol: String,
        focus value: ControlFocus,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .frame(width: 120, height: 84)
        }
        .focused(focus, equals: value)
        .disabled(!enabled)
    }
}

/// The hidden panel along the top of the screen: which speakers are playing, and from where.
/// Nothing in it can be selected, so remote focus stays on the artwork.
struct InfoPanel: View {
    let nowPlaying: NowPlaying

    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: 28) {
                Image(systemName: nowPlaying.speakerNames.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 80)

                VStack(alignment: .leading, spacing: 6) {
                    Text(speakers)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                    if let source {
                        Text(source)
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 140)
            // Clears the top of the 760-point artwork, which starts 160 points down.
            .padding(.top, 44)
            .padding(.bottom, 60)
            .background {
                LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
            }
            Spacer()
        }
    }

    /// "Sonos Move & Kids Room" for a group, otherwise the room's name.
    private var speakers: String {
        let names = nowPlaying.speakerNames
        guard names.count > 1 else { return names.first ?? nowPlaying.roomName }
        return names.dropLast().joined(separator: ", ") + " & " + names.last!
    }

    /// For example "Berliner Rundfunk 91.4 · TuneIn" or "Apple Music · Paused".
    private var source: String? {
        let parts = [nowPlaying.stationName, nowPlaying.serviceName, nowPlaying.isPlaying ? nil : "Paused"]
        let line = parts.compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }
}

/// Briefly confirms a Play/Pause press while the control bar is hidden.
struct PlayPauseFlash: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 80, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 180, height: 180)
            .background(.ultraThinMaterial, in: .circle)
    }
}

/// A button that looks exactly like its label, with no focus effect, so the artwork
/// view can receive remote clicks without anything changing on screen.
struct InvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
