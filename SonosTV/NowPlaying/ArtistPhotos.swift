import Foundation

/// Finds photos of an artist for the swipe-through carousel: TheAudioDB's widescreen
/// "fanart" and other pictures first, then Deezer's artist photo. A result is only used
/// when its artist name matches, so a common name doesn't bring up someone else.
enum ArtistPhotos {
    /// TheAudioDB's free key, meant for testing and personal use.
    private static let audioDBKey = "123"

    /// Photo URLs, best first, without duplicates. Empty when nothing matches.
    static func urls(for artist: String) async -> [URL] {
        let name = mainArtist(artist)
        async let audioDB = fromAudioDB(name)
        async let deezer = fromDeezer(name)
        var seen = Set<URL>()
        return (await audioDB + deezer).filter { seen.insert($0).inserted }
    }

    // MARK: - TheAudioDB

    private struct AudioDBResults: Decodable {
        let artists: [Artist]?

        struct Artist: Decodable {
            let strArtist: String
            let strArtistFanart: String?
            let strArtistFanart2: String?
            let strArtistFanart3: String?
            let strArtistFanart4: String?
            let strArtistWideThumb: String?
            let strArtistThumb: String?
        }
    }

    private static func fromAudioDB(_ name: String) async -> [URL] {
        var components = URLComponents(string: "https://www.theaudiodb.com/api/v1/json/\(audioDBKey)/search.php")!
        components.queryItems = [URLQueryItem(name: "s", value: name)]
        guard let results: AudioDBResults = await get(components.url),
              let artist = results.artists?.first(where: { matches($0.strArtist, name) })
        else { return [] }
        // Widescreen photos first; they fill a TV screen best.
        return [
            artist.strArtistFanart, artist.strArtistFanart2, artist.strArtistFanart3, artist.strArtistFanart4,
            artist.strArtistWideThumb, artist.strArtistThumb,
        ]
        .compactMap { $0.flatMap { URL(string: $0) } }
    }

    // MARK: - Deezer

    private struct DeezerResults: Decodable {
        let data: [Artist]

        struct Artist: Decodable {
            let name: String
            let pictureXL: String

            enum CodingKeys: String, CodingKey {
                case name
                case pictureXL = "picture_xl"
            }
        }
    }

    private static func fromDeezer(_ name: String) async -> [URL] {
        var components = URLComponents(string: "https://api.deezer.com/search/artist")!
        components.queryItems = [URLQueryItem(name: "q", value: name), URLQueryItem(name: "limit", value: "5")]
        guard let results: DeezerResults = await get(components.url),
              let artist = results.data.first(where: { matches($0.name, name) }),
              // Artists without a photo get a placeholder whose path has no image hash: ".../artist//...".
              !artist.pictureXL.contains("/artist//"),
              let url = URL(string: artist.pictureXL)
        else { return [] }
        return [url]
    }

    // MARK: - Helpers

    private static func get<Body: Decodable>(_ url: URL?) async -> Body? {
        guard let url, let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)) else {
            return nil
        }
        return try? JSONDecoder().decode(Body.self, from: data)
    }

    /// "Calvin Harris feat. Rihanna" → "Calvin Harris": photo services know the main artist.
    private static func mainArtist(_ artist: String) -> String {
        artist.replacing(/(?i)\s+(feat\.?|ft\.?|featuring)\s.*$/, with: "")
    }

    /// Same artist, ignoring case, accents, punctuation and a leading "The".
    private static func matches(_ found: String, _ wanted: String) -> Bool {
        func key(_ name: String) -> String {
            let plain = RadioSong.normalized(name)
            return plain.hasPrefix("the") && plain.count > 3 ? String(plain.dropFirst(3)) : plain
        }
        return key(found) == key(wanted)
    }
}
