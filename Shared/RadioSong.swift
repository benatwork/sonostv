import Foundation

/// The song a radio station is playing, worked out from the text the station sends.
///
/// Sonos's newer API only reports the station. The song comes from the stream's
/// `StreamTitle` (ICY metadata), which players expose through the older UPnP interface
/// as `r:streamContent`, usually as "ARTIST - TITLE". The album and artwork aren't in
/// the stream, so they're looked up with Apple's iTunes Search API.
nonisolated struct RadioSong: Equatable, Sendable {
    let artist: String?
    let title: String
    let album: String?
    let artworkURL: URL?

    /// The song for a station's "now playing" text, or nil when the text isn't a song
    /// (empty, or the station's own name or slogan).
    static func resolve(_ text: String?, station: String?, session: URLSession) async -> RadioSong? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let fields = labeledFields(text) {
            return await resolve(fields, session: session)
        }
        let parts = text.components(separatedBy: " - ")
        guard parts.count >= 2 else {
            return isStation(text, station) ? nil : RadioSong(artist: nil, title: tidy(text), album: nil, artworkURL: nil)
        }
        let first = parts[0]
        let rest = parts.dropFirst().joined(separator: " - ")
        if isStation(first, station) { return nil }

        // Most stations send "artist - title"; some send it the other way round.
        if let match = await lookUp(artist: first, title: rest, session: session) {
            return match
        }
        if let match = await lookUp(artist: rest, title: first, session: session) {
            return match
        }
        return RadioSong(artist: tidy(first), title: tidy(rest), album: nil, artworkURL: nil)
    }

    /// BBC Sounds labels its fields: "BR P|TYPE=SNG|TITLE Nao in conversation|ARTIST Gilles Peterson 15:00 – 18:00|ALBUM ".
    private static func resolve(_ fields: [String: String], session: URLSession) async -> RadioSong? {
        guard let title = fields["TITLE"] else { return nil }
        guard let artist = fields["ARTIST"] else {
            return RadioSong(artist: nil, title: tidy(title), album: nil, artworkURL: nil)
        }
        if hasTimeSlot(artist) {
            // A show segment, not a song: the "artist" is the show and its time slot. Keep the
            // station's own image, since there's no record to look up.
            return RadioSong(artist: withoutTimeSlot(artist), title: title, album: nil, artworkURL: nil)
        }
        if let match = await lookUp(artist: artist, title: title, session: session) {
            return match
        }
        return RadioSong(artist: tidy(artist), title: tidy(title), album: fields["ALBUM"], artworkURL: nil)
    }

    /// TITLE, ARTIST and ALBUM from text in the labeled format, or nil for other text.
    private static func labeledFields(_ text: String) -> [String: String]? {
        var fields: [String: String] = [:]
        for part in text.components(separatedBy: "|") {
            for label in ["TITLE", "ARTIST", "ALBUM"] where part.hasPrefix(label + " ") {
                let value = part.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { fields[label] = value }
            }
        }
        return fields["TITLE"] == nil ? nil : fields
    }

    // MARK: - Show slots

    /// BBC Sounds puts the show's name and time slot where the artist goes during talk:
    /// "Gilles Peterson 15:00 – 18:00".
    static func hasTimeSlot(_ text: String) -> Bool {
        text.contains(timeSlot)
    }

    /// "Gilles Peterson 15:00 – 18:00" → "Gilles Peterson".
    static func withoutTimeSlot(_ text: String) -> String {
        text.replacing(timeSlot, with: "")
    }

    nonisolated(unsafe) private static let timeSlot = /\s+\d{1,2}[:.]\d{2}\s*[–—-]\s*\d{1,2}[:.]\d{2}\s*$/

    // MARK: - BBC Sounds

    /// The text to work out the song from: what the stream sent, unless this is a BBC
    /// Sounds station whose own feed says a song is playing. BBC often reports only the
    /// show to Sonos, but its feed knows each song.
    static func currentText(streamText: String?, stationId: String?, session: URLSession) async -> String? {
        guard let stationId, let service = bbcService(in: stationId),
              let song = await bbcNowPlaying(service: service, session: session)
        else { return streamText }
        return "\(song.artist) - \(song.title)"
    }

    /// "stations~playable~~bbc_6music~~urn:bbc:radio:network:bbc_6music" → "bbc_6music".
    private static func bbcService(in stationId: String) -> String? {
        stationId.firstMatch(of: /~~(bbc_[a-z0-9_]+)~~/).map { String($0.1) }
    }

    private struct BBCSegments: Decodable {
        let data: [Segment]

        struct Segment: Decodable {
            let titles: Titles
            let offset: Offset?

            struct Titles: Decodable {
                let primary: String?
                let secondary: String?
            }

            struct Offset: Decodable {
                let nowPlaying: Bool?

                enum CodingKeys: String, CodingKey {
                    case nowPlaying = "now_playing"
                }
            }
        }
    }

    /// The song BBC's feed says is playing right now, if any. Between songs it lists the
    /// recent ones without marking any as playing.
    private static func bbcNowPlaying(service: String, session: URLSession) async -> (artist: String, title: String)? {
        guard let url = URL(string: "https://rms.api.bbc.co.uk/v2/services/\(service)/segments/latest?experience=domestic&offset=0&limit=1"),
              let (data, _) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 5)),
              let segments = try? JSONDecoder().decode(BBCSegments.self, from: data),
              let segment = segments.data.first, segment.offset?.nowPlaying == true,
              let artist = segment.titles.primary, let title = segment.titles.secondary
        else { return nil }
        return (artist, title)
    }

    // MARK: - Reading the station text

    /// The "now playing" text the speaker has from the stream, e.g. "DERMOT KENNEDY - POWER OVER ME".
    static func streamText(fromPlayer host: String, session: URLSession) async -> String? {
        let body = """
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
            <u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetPositionInfo>\
            </s:Body></s:Envelope>
            """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/AVTransport/Control") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo\"", forHTTPHeaderField: "SOAPACTION")
        guard let (data, _) = try? await session.data(for: request) else { return nil }

        // The track metadata is XML escaped inside the SOAP response, and its values are escaped again.
        let response = String(decoding: data, as: UTF8.self)
        guard let metadata = firstMatch(of: "TrackMetaData", in: response).map(unescape),
              let content = firstMatch(of: "r:streamContent", in: metadata).map(unescape)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty
        else { return nil }
        return content
    }

    private static func firstMatch(of tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    private static func unescape(_ text: String) -> String {
        var result = text
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Looking up the song

    private struct SearchResults: Decodable {
        let results: [Item]

        struct Item: Decodable {
            let artistName: String
            let trackName: String
            let collectionName: String?
            let artworkUrl100: String?
        }
    }

    /// The best iTunes match, only if its artist and title actually match the station's text.
    private static func lookUp(artist: String, title: String, session: URLSession) async -> RadioSong? {
        let wantedArtist = normalized(artist)
        let wantedTitle = normalized(title)
        guard !wantedArtist.isEmpty, !wantedTitle.isEmpty else { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
        ]
        guard let url = components.url,
              let (data, _) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 5)),
              let search = try? JSONDecoder().decode(SearchResults.self, from: data)
        else { return nil }

        // Loose on both sides: "X FEAT. Y" should match "X", and "Song" should match "Song (Radio Edit)".
        let candidates = search.results.filter { item in
            let foundArtist = normalized(item.artistName)
            let foundTitle = normalized(item.trackName)
            return (foundArtist.contains(wantedArtist) || wantedArtist.contains(foundArtist))
                && (foundTitle.hasPrefix(wantedTitle) || wantedTitle.hasPrefix(foundTitle))
        }
        // An exact title beats a "(Remastered)" or "(Single Version)" variant from a compilation.
        let exact = candidates.first { normalized($0.trackName) == wantedTitle }
        guard let match = exact ?? candidates.first else { return nil }
        return RadioSong(
            artist: match.artistName,
            title: match.trackName,
            album: match.collectionName,
            artworkURL: match.artworkUrl100.flatMap { URL(string: NowPlaying.upscaledAppleMusicArtwork($0)) }
        )
    }

    // MARK: - Text helpers

    /// Whether the text is just the station talking about itself, e.g. "BERLINER RUNDFUNK" on Berliner Rundfunk 91.4.
    static func isStation(_ text: String, _ station: String?) -> Bool {
        guard let station else { return false }
        let plainText = normalized(text)
        let plainStation = normalized(station)
        return !plainText.isEmpty && (plainStation.contains(plainText) || plainText.contains(plainStation))
    }

    /// Lowercase letters and digits only, without accents, for comparing names.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Stations often send ALL CAPS; show it in title case instead.
    static func tidy(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed == trimmed.uppercased(), trimmed.contains(where: \.isLetter) else { return trimmed }
        return trimmed.capitalized(with: Locale.current)
    }
}
