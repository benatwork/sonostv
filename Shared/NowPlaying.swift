import Foundation

/// What the screen shows for one group, flattened from Sonos metadata.
nonisolated struct NowPlaying: Equatable, Sendable {
    let groupId: String
    let roomName: String
    private(set) var title: String
    private(set) var artist: String?
    /// The album, or the station name for radio.
    private(set) var detail: String?
    private(set) var artworkURL: URL?
    /// Where the music comes from, shown after the room name: a radio station's name once its song is known.
    private(set) var source: String?
    /// The station's name when this is radio, so its song can be looked up and shown.
    let stationName: String?
    let isPlaying: Bool
    let canPause: Bool
    let canSkip: Bool
    let canSkipToPrevious: Bool

    /// Returns nil when there is nothing worth showing, such as TV audio or line-in.
    init?(
        groupId: String,
        roomName: String,
        metadata: SonosMetadataStatus,
        isPlaying: Bool,
        actions: SonosPlaybackStatus.Actions?
    ) {
        let container = metadata.container
        let track = metadata.currentItem?.track
        if container?.type?.hasPrefix("linein") == true { return nil }

        self.groupId = groupId
        self.roomName = roomName
        self.isPlaying = isPlaying
        stationName = container?.type == "station" ? container?.name.nonEmpty : nil
        // Until Sonos reports otherwise, assume the usual controls work.
        canPause = actions?.canPause ?? true
        canSkip = actions?.canSkip ?? true
        canSkipToPrevious = actions?.canSkipToPrevious ?? true

        if let name = track?.name.nonEmpty {
            title = name
            artist = track?.artist?.name.nonEmpty
            detail = track?.album?.name.nonEmpty ?? (container?.type == "station" ? container?.name.nonEmpty : nil)
        } else if let streamInfo = metadata.streamInfo.nonEmpty {
            let station = container?.name.nonEmpty
            let parts = streamInfo.components(separatedBy: " - ")
            if let station, RadioSong.isStation(parts[0], station) {
                // The station talking about itself between songs, e.g.
                // "Berliner Rundfunk 91,4 - Die besten Hits aller Zeiten.": station name, then slogan.
                title = station
                artist = nil
                detail = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : nil
            } else {
                title = streamInfo
                artist = nil
                detail = station
            }
        } else if let name = container?.name.nonEmpty {
            title = name
            artist = nil
            detail = nil
        } else {
            return nil
        }

        artworkURL = Self.artworkURL(track: track, container: container)
    }

    /// The room, plus the station when a radio song is showing, e.g. "Kitchen · Berliner Rundfunk 91.4".
    var sourceLine: String {
        [roomName, source].compactMap { $0 }.joined(separator: " · ")
    }

    /// Shows a radio station's current song in place of the station. Keeps the station
    /// logo when no cover was found.
    func withSong(_ song: RadioSong) -> NowPlaying {
        var copy = self
        copy.title = song.title
        copy.artist = song.artist
        copy.detail = song.album
        copy.artworkURL = song.artworkURL ?? artworkURL
        copy.source = stationName
        return copy
    }

    /// Prefers the track's own HTTPS artwork, then album artwork, then whatever the
    /// player proxies (`http://<player>:1400/getaa?...`), then the station or playlist image.
    private static func artworkURL(
        track: SonosMetadataStatus.Track?,
        container: SonosMetadataStatus.Container?
    ) -> URL? {
        let trackImage = track?.imageUrl.nonEmpty
        let containerImage = container?.imageUrl.nonEmpty
        let candidates = [
            trackImage.flatMap { $0.hasPrefix("https:") ? $0 : nil },
            container?.type == "album" ? containerImage : nil,
            trackImage,
            containerImage,
        ]
        guard let string = candidates.compactMap({ $0 }).first else { return nil }
        return URL(string: upscaledAppleMusicArtwork(string))
    }

    /// Apple Music artwork URLs end in a size like `/400x400bb.png`; ask for one fit for a 4K TV.
    /// JPEG, because a 1600px PNG is around 4.5 MB and noticeably slow to appear.
    static func upscaledAppleMusicArtwork(_ string: String) -> String {
        guard string.contains("mzstatic.com") else { return string }
        return string.replacing(/\/\d+x\d+bb\.\w+$/, with: "/1600x1600bb.jpg")
    }
}

nonisolated private extension Optional<String> {
    /// The string, or nil when it is nil or empty.
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
