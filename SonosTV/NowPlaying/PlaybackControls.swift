import SwiftUI

/// Where remote focus can be on the now-playing screen.
enum ControlFocus: Hashable {
    /// The full-screen artwork, which has no visible focus state.
    case canvas
    case previous
    case playPause
    case next
    case slideshow
    /// A room in the room picker, by group id.
    case room(String)
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
/// When more than one room is playing, it also has a row for choosing which room the
/// screen shows; otherwise nothing in it can be selected and focus stays on the artwork.
struct InfoPanel: View {
    let nowPlaying: NowPlaying
    /// Every room playing right now, for the picker. Shown only when there's a choice.
    let rooms: [NowPlaying]
    let focus: FocusState<ControlFocus?>.Binding
    let select: (String) -> Void

    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 28) {
                    Image(systemName: nowPlaying.speakerNames.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 80)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.speakers(of: nowPlaying))
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

                if hasChoice {
                    HStack(spacing: 24) {
                        ForEach(rooms, id: \.groupId) { room in
                            Button {
                                select(room.groupId)
                            } label: {
                                RoomChoice(room: room, isShown: room.groupId == nowPlaying.groupId)
                            }
                            .focused(focus, equals: .room(room.groupId))
                        }
                    }
                    // Lines up with the text above, past the speaker icon.
                    .padding(.leading, 108)
                }
            }
            .padding(.horizontal, 140)
            // Clears the top of the 760-point artwork, which starts 160 points down.
            .padding(.top, 44)
            .padding(.bottom, 60)
            .background {
                LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom)
            }
            Spacer()
        }
        .onAppear {
            if hasChoice { focus.wrappedValue = .room(nowPlaying.groupId) }
        }
    }

    var hasChoice: Bool {
        rooms.count > 1
    }

    /// "Sonos Move & Kids Room" for a group, otherwise the room's name.
    static func speakers(of room: NowPlaying) -> String {
        let names = room.speakerNames
        guard names.count > 1 else { return names.first ?? room.roomName }
        return names.dropLast().joined(separator: ", ") + " & " + names.last!
    }

    /// For example "Berliner Rundfunk 91.4 · TuneIn" or "Apple Music · Paused".
    private var source: String? {
        let parts = [nowPlaying.stationName, nowPlaying.serviceName, nowPlaying.isPlaying ? nil : "Paused"]
        let line = parts.compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }
}

/// One room in the room picker: its speakers and what it's playing, with a checkmark on
/// the room the screen is showing.
private struct RoomChoice: View {
    let room: NowPlaying
    let isShown: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isShown ? "checkmark.circle.fill" : "hifispeaker.fill")
                .font(.system(size: 28))
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(InfoPanel.speakers(of: room))
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                Text([room.title, room.artist].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 22))
                    .lineLimit(1)
                    .opacity(0.7)
            }
        }
        .frame(width: 380, alignment: .leading)
        .padding(.vertical, 8)
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
