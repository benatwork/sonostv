import SwiftUI

/// Where remote focus can be on the now-playing screen.
enum ControlFocus: Hashable {
    /// The full-screen artwork, which has no visible focus state.
    case canvas
    case previous
    case playPause
    case next
}

/// The hidden control bar along the bottom of the screen.
struct ControlBar: View {
    let nowPlaying: NowPlaying
    let focus: FocusState<ControlFocus?>.Binding
    let perform: (SonosHousehold.PlaybackCommand) -> Void

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
                    enabled: !nowPlaying.isPlaying || nowPlaying.canPause
                ) {
                    perform(nowPlaying.isPlaying ? .pause : .play)
                }
                control("forward.fill", focus: .next, enabled: nowPlaying.canSkip) {
                    perform(.skipToNextTrack)
                }
            }
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            }
        }
        .onAppear { focus.wrappedValue = .playPause }
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
