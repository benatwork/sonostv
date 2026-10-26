# Plan: shared SonosCore, optional server, iPad display

Status: approved direction, not started. Written 2026-10-26.

## Goal

Show the same "now playing" content on more screens without keeping two copies of the logic:

- **Apple TV app** (exists) keeps working **standalone**. It may one day go on the App Store, so it must never require a server.
- **Old iPad** (being restored to iOS 9, model still to confirm) mounted as an always-on display. It can't run a modern native app, so it shows a **web page** served by a small server.
- **Server** runs in Docker on the user's **Synology DS220+** (Intel x86_64, Container Manager). It is optional: it exists only for screens that can't run the logic themselves.

Rule of thumb: every "what is playing and how do we present it" rule lives in **one Swift package, `SonosCore`**, used by both the tvOS app and the server. Only the iPad page's look and touch handling are written separately, in old-style web code.

## Target architecture

```
SonosCore  (Swift package; tvOS + macOS + Linux)
  • Sonos connection, rooms, playback state, playback commands
  • radio songs (TuneIn ICY text, BBC Sounds format + BBC feed), iTunes album/cover lookup
  • artist photos (TheAudioDB, Deezer)
  • room ordering ("most recently started first", paused rooms linger 15 min)
  • NowPlaying: what to show for a room (title, artist, album, artwork, source)

 ├── SonosTV (tvOS app)       → SonosCore directly. No server needed.
 │     └── SonosTVTopShelf    → SonosCore directly
 │
 └── Server/ sonostv-server   → SonosCore + HTTP API + static web page, Docker on DS220+
       └── web/ iPad page     → ES5 HTML/JS/CSS for iOS 9 Safari, data from the server
```

## Proposed repo layout

```
sonostv/
  SonosTV.xcodeproj
  SonosTV/                     tvOS app UI (views, remote input, slideshow, panels)
  SonosTVTopShelf/             Top Shelf extension (slide drawing stays here; Apple-only)
  Packages/SonosCore/
    Package.swift              platforms: tvOS 26, macOS 14; also builds on Linux
    Sources/SonosCore/         platform-neutral logic (no Network, CoreGraphics, CryptoKit, SwiftUI)
      Models/                  SonosModels.swift, NowPlaying.swift
      Household/               actor that tracks groups, playback, metadata, radio refresh
      Radio/                   RadioSong (TuneIn / BBC / iTunes lookup)
      Photos/                  ArtistPhotos (TheAudioDB, Deezer)
      Transport/               protocols: HTTPTransport, WebSocketTransport, PlayerDiscovery
    Sources/SonosCoreApple/    URLSession transport + LocalNetworkTrust, Bonjour (NWBrowser) discovery
    Tests/SonosCoreTests/      parsing and mapping tests from recorded JSON fixtures
  Server/
    Package.swift              executable; depends on SonosCore, Hummingbird 2, AsyncHTTPClient, WebSocketKit (or NIO WebSocket)
    Sources/SonosServer/       Linux transports, API routes, SSE, image proxy, config
    web/                       index.html, app.js (ES5), styles.css
    Dockerfile                 swift:6.x build stage → slim runtime
    compose.yaml               for Synology Container Manager
  .github/workflows/server-image.yml   builds linux/amd64 image → ghcr.io/benatwork/sonostv-server
  docs/PLAN-shared-core.md     this file
```

## Where today's code goes

| Today | Moves to | Notes |
|---|---|---|
| `Shared/SonosModels.swift` | `SonosCore/Models` | as is |
| `Shared/NowPlaying.swift` | `SonosCore/Models` | as is |
| `Shared/RadioSong.swift` | `SonosCore/Radio` | replace `URLSession` calls with `HTTPTransport` |
| `Shared/LocalNetworkTrust.swift` | `SonosCoreApple` | Apple-only TLS trust for self-signed speaker certs |
| `SonosTV/Sonos/SonosHousehold.swift` | `SonosCore/Household` (logic) + thin `@Observable` wrapper in `SonosTV` | core becomes an `actor` that publishes `HouseholdState` snapshots (`AsyncStream`); no Observation in core |
| `SonosTV/Sonos/SonosSocket.swift` | `WebSocketTransport` protocol in core; URLSession implementation in `SonosCoreApple` | |
| `SonosTV/Sonos/SonosDiscovery.swift` | `SonosCoreApple` (Bonjour) | server uses configured seed hosts instead |
| `SonosTV/NowPlaying/ArtistPhotos.swift` | `SonosCore/Photos` | uses `HTTPTransport` |
| `SonosTVTopShelf/SonosSnapshot.swift` | replaced by a one-shot "fetch state" API in core | extension keeps `CarouselArtwork` (CoreGraphics) |
| `SonosTV/NowPlaying/*View*.swift`, `PlaybackControls.swift` | stay in `SonosTV` | UI only; reads the wrapper |

Per-screen state stays in each client, not in the core: chosen room (room picker), slideshow mode, panels, photo page. The core provides all rooms in ranked order plus a `nowPlaying(selected:)` helper.

## Portability rules for SonosCore (must build on Linux)

- No `Network`, `CoreGraphics`, `CryptoKit`, `SwiftUI`, `Observation`, `UIKit` imports in `SonosCore`.
- All network I/O goes through protocols (`HTTPTransport`: GET/POST with headers and timeout; `WebSocketTransport`: connect with headers and subprotocol, send text, async stream of messages, close).
- Self-signed TLS for speakers on port 1443: Apple uses `LocalNetworkTrust` (private IPs only); Linux transport must disable verification for private IPs only as well.
- `Regex`, `Foundation` (`JSONDecoder`, `Date`, `Locale`) are fine on Linux. If `URL`/`URLRequest` types are used, Linux needs `import FoundationNetworking` only in the Linux transport, not in core.
- Add a CI or local check early: `docker run --rm -v "$PWD":/src -w /src/Packages/SonosCore swift:6.1 swift build` so Linux breakage shows up in Phase 1, not Phase 2.

## Server API (sketch)

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/state` | `{ rooms: [Room], updatedAt }` |
| GET | `/api/events` | Server-Sent Events: full state on every change (iOS 9 Safari supports `EventSource`) |
| POST | `/api/rooms/{groupId}/play` `pause` `next` `previous` | playback commands |
| GET | `/img?u=<url>&w=<px>` | image proxy; allowlist of hosts (mzstatic, theaudiodb, deezer, bbci, tunein, speaker IPs); caches on disk |
| GET | `/` | the iPad page |

`Room`: `id, name, speakers[], isPlaying, title, artist?, album?, source?, service?, artwork (proxied url), photos[] (proxied urls), canPause, canSkip, canSkipToPrevious`.

Image sizing: ask the source for a small size (mzstatic `/NxNbb.jpg`, Deezer `picture_big`/`_xl`, TheAudioDB `/preview`), proxy so iOS 9 never does modern TLS. Real resizing (libvips) only if needed later.

Config (env): `PORT` (default 8080), `SONOS_SEED_HOSTS` (comma-separated speaker IPs; reserve them in the router), `AUDIODB_KEY` (default `123`), `COUNTRY` for iTunes (default from locale, e.g. `de`).

Networking on the NAS: bridge networking is enough with seed hosts. `network_mode: host` only if Bonjour discovery is wanted.

## iPad page (iOS 9 Safari) requirements

- ES5 only: no arrow functions, `let/const`, template literals, `fetch`, Promises (use `XMLHttpRequest`, `EventSource`).
- CSS: `-webkit-` prefixed flexbox, no CSS variables or grid; test in landscape and portrait.
- `apple-mobile-web-app-capable` + Home Screen icon, so it runs full screen.
- Same screen as the TV: artwork, title, artist, album. Tap → controls; swipe down → speakers/source panel with room picker; swipe left/right → artist photos; slideshow toggle. Room choice and slideshow stored in `localStorage`.
- Keep images ≤ 1024 px (old iPads have 512 MB–1 GB RAM).
- Device setup notes for the user: Auto-Lock → Never, Guided Access to pin the page.

## Phases and acceptance checks

**Phase 0.** Branch `shared-core` off `main`.

**Phase 1: extract SonosCore (no visible change).**
- Create the package, move code per the table, add transports/discovery protocols and Apple implementations.
- tvOS app + Top Shelf use the package; delete moved files from the targets.
- Unit tests from fixtures: TuneIn "ARTIST - TITLE", station slogan, BBC labeled format (talk vs song), BBC feed mapping, NowPlaying mapping (Apple Music track, station, TV audio excluded), room ordering.
- Done when: `swift test` passes on macOS; `swift build` passes in the Linux Docker image; tvOS app and Top Shelf behave exactly as before in the simulator (now playing, radio song, swipe-down panel and picker via `-ShowIdleGroups YES`, artist photos, slideshow, Top Shelf slide).

**Phase 2: server.**
- Linux transports (AsyncHTTPClient + NIO WebSocket), seed-host discovery, Hummingbird routes, SSE, image proxy, Dockerfile, compose, GitHub Actions image build.
- Done when: running locally with `docker compose up` shows live state at `/api/state` and pushes updates via `/api/events` on track change; then running on the DS220+ from the GHCR image.

**Phase 3: iPad page.**
- Done when: works in a desktop Safari user-agent check and on the real iOS 9 iPad (user tests), including swipes, room picker and slideshow.

**Phase 4 (optional, later).** Settings toggle in the TV app to read from a server instead of local, only if ever useful.

## Working notes for whoever builds this

- Verification habits that worked: tvOS Simulator screenshots via `xcrun simctl io … screenshot`; real TV via `xcrun devicectl device capture screenshot` and `devicectl device info files`; installing on the Apple TV needs the Bonjour re-advertise workaround (see memory `apple-tv-pairing-network`).
- The simulator's remote input is flaky after `simctl launch`. Reopening the app from the Home Screen helps. Panels auto-hide after 8 s, so chain key presses quickly.
- Don't play, pause or skip the user's speakers without asking.
- Known Sonos gotchas (also in memory `sonos-local-api-findings`): full householdId from `/players/local/info`; metadata only from the group's coordinator; status namespace is `playback:1`; `groups:1` events lack `playbackState`; radio song text only via UPnP `r:streamContent` (or pushed `streamInfo`); BBC Sounds uses `TITLE …|ARTIST …|ALBUM …` with show time slots as the artist.
- Top Shelf gotchas (memory `tvos-top-shelf-extension-gotchas`): `app-extension` product type, ~60 MB memory limit, images as `data:` URLs.

## Cautions before any App Store release (not blockers for this plan)

1. **Sonos API key and local API.** The app uses Sonos's public **sample** API key and the local WebSocket/REST API, which isn't officially offered to third-party apps. Distribution likely needs the Sonos developer program and the official **cloud Control API** (user signs in to Sonos via OAuth), or Sonos's explicit permission. Keep the core's Sonos connection modular so a signed-in cloud mode can be added beside local mode.
2. **Undocumented interfaces.** UPnP on port 1400 (radio song text, `r:streamContent`), `history:1` and `loadContent` are undocumented and could change with firmware.
3. **BBC Sounds feed** (`rms.api.bbc.co.uk`) is unofficial and unauthenticated; terms of use unclear for a distributed app.
4. **TheAudioDB key `123`** is a test/personal key; a released app needs a paid key or a different source. Deezer and iTunes Search API terms also need checking (attribution/affiliate rules).
5. **Trademark.** "Sonos" in the app name or icon would likely be rejected (App Review guideline 5.2). Pick a neutral name.
6. **Signing.** The project currently signs with the free Personal Team (7-day installs). Distribution needs a paid Apple Developer membership.

## Open questions for the user

- Exact iPad model (sets the maximum iOS: iPad 2/3/mini 1 → 9.3.x; iPad 4 → 10.3.3; Air/mini 2/3 → 12.5.x).
- NAS IP address (fixed?) and preferred port.
- Which speaker IPs to use as seeds (reserve them in the router).
