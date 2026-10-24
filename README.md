# Sonos TV

A tvOS app that shows the cover art and track of whatever your Sonos system is playing. Display only, no controls.

## Run it

Open `SonosTV.xcodeproj`, pick an Apple TV simulator, and Run. The simulator shares your Mac's network, so it finds your speakers directly.

To run on a real Apple TV, set your team under Signing & Capabilities and change the bundle identifier from `com.example.SonosTV`. On first launch, tvOS asks for Local Network access. The app can't find speakers without it.

**See the layout when nothing is playing:** add `-ShowIdleGroups YES` under Product › Scheme › Edit Scheme › Arguments. Paused and idle rooms then show their last track, marked "Paused".

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
