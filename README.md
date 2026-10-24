# Sonos TV

A tvOS app that shows the cover art and track of whatever your Sonos system is playing. Display only, no controls.

## Run it

Open `SonosTV.xcodeproj`, pick an Apple TV simulator, and Run. The simulator shares your Mac's network, so it finds your speakers directly.

To run on a real Apple TV, set your team under Signing & Capabilities and change the bundle identifier from `com.example.SonosTV`. On first launch, tvOS asks for Local Network access. The app can't find speakers without it.

**See the layout when nothing is playing:** add `-ShowIdleGroups YES` under Product › Scheme › Edit Scheme › Arguments. Paused and idle rooms then show their last track, marked "Paused".

## Remote controls

The screen shows only the artwork, title, artist and album. Everything else stays hidden until you ask for it:

| Remote | What happens |
|---|---|
| Click, or swipe up | A ⏮ ⏯ ⏭ bar slides up from the bottom |
| Swipe down | A panel slides down from the top with the speakers playing and the source, e.g. "Sonos Move & Stereo" and "Berliner Rundfunk 91.4 · TuneIn" |
| Swipe the other way, Back, or 8 seconds idle | The bar or panel slides away |
| Swipe left or right | Pages through photos of the artist (from TheAudioDB and Deezer), then back to the artwork |
| Slideshow button (right of ⏮ ⏯ ⏭ in the bar) | Toggles slideshow mode; the symbol is filled while it's on. On: the photos and artwork advance every 8 seconds, and swiping still works and restarts the 8 seconds. Off: back to the album artwork. The setting is remembered |
| Play/Pause button | Plays or pauses straight away; a symbol flashes briefly |

Buttons the current source doesn't support, such as skipping on TV audio, are disabled. A room you pause stays on screen for 15 minutes so you can resume it, but the screensaver is allowed to start.

## How it works

It uses the Sonos **local WebSocket API**, the same one the Sonos app uses. Nothing goes through the cloud.

1. `SonosDiscovery` browses Bonjour for `_sonos._tcp`. Each player's TXT record includes its IP address.
2. `SonosHousehold` calls `https://<ip>:1443/api/v1/players/local/info` to get the full household id.
3. It opens `wss://<ip>:1443/websocket/api` and subscribes to `groups:1`.
4. For every group, it subscribes to `playback:1` and `playbackMetadata:1` on that group's **coordinator**. Other players won't send a group's metadata.
5. `NowPlaying` turns the metadata into title, artist, album and an artwork URL. `NowPlayingView` shows the room that most recently started playing.

Things the code depends on:

- The players accept the public sample API key from Sonos's docs (`X-Sonos-Api-Key`). It isn't an official contract; the legacy UPnP API on port 1400 is the fallback if Sonos ever blocks it.
- The players' TLS certificates are self-signed. `LocalNetworkTrust` accepts them, but only for private IP addresses.
- TV audio and line-in carry no metadata, so the app treats them as "nothing playing".
- Apple Music artwork is fetched as a 1600px JPEG. The default 400px is too small for a TV, and the PNG version is too large.
- The screen stays awake while music is showing. When nothing is playing, the screensaver can run.
