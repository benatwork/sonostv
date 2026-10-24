import Foundation
import Network

/// A one-off look at what every Sonos room is playing.
///
/// The Top Shelf extension only runs for a moment, so instead of the app's WebSocket
/// subscriptions it makes plain HTTPS requests: player info for the household id, the
/// household's groups, then each playing group's metadata from its coordinator.
struct SonosSnapshot {
    let session = URLSession(configuration: .ephemeral, delegate: LocalNetworkTrust(), delegateQueue: nil)

    /// Players that answered last time, tried before searching the network again.
    private static let rememberedHostsKey = "PlayerHosts"

    /// The rooms currently playing something worth showing, ordered by room name.
    func playingRooms() async -> [NowPlaying] {
        let remembered = UserDefaults.standard.stringArray(forKey: Self.rememberedHostsKey) ?? []
        if let rooms = await playingRooms(trying: remembered) {
            return rooms
        }
        let discovered = await Self.browseForPlayers(seconds: 2)
        if let rooms = await playingRooms(trying: discovered.filter { !remembered.contains($0) }) {
            UserDefaults.standard.set(discovered, forKey: Self.rememberedHostsKey)
            return rooms
        }
        return []
    }

    /// Asks each host in turn until one describes the household.
    private func playingRooms(trying hosts: [String]) async -> [NowPlaying]? {
        for host in hosts {
            if let rooms = try? await playingRooms(via: host) {
                return rooms
            }
        }
        return nil
    }

    private func playingRooms(via host: String) async throws -> [NowPlaying] {
        let info: SonosPlayerInfo = try await get("https://\(host):1443/api/v1/players/local/info")
        let household: SonosGroups = try await get("https://\(host):1443/api/v1/households/\(info.householdId)/groups")
        let coordinators = Dictionary(household.players.map { ($0.id, $0.websocketUrl) }) { first, _ in first }
        let playing = household.groups.filter {
            $0.playbackState == "PLAYBACK_STATE_PLAYING" || $0.playbackState == "PLAYBACK_STATE_BUFFERING"
        }

        return await withTaskGroup(of: NowPlaying?.self) { tasks in
            for group in playing {
                guard let websocketURL = coordinators[group.coordinatorId] else { continue }
                tasks.addTask {
                    // Metadata only comes from the group's coordinator, at the same host as its WebSocket.
                    var components = URLComponents(url: websocketURL, resolvingAgainstBaseURL: false)
                    components?.scheme = "https"
                    components?.path = "/api/v1/groups/\(group.id)/playbackMetadata"
                    guard let url = components?.string,
                          let metadata: SonosMetadataStatus = try? await get(url),
                          let room = NowPlaying(groupId: group.id, roomName: group.name, metadata: metadata, isPlaying: true, actions: nil)
                    else { return nil }
                    // For radio, the song comes from the coordinator's older UPnP interface.
                    guard let station = room.stationName, let host = websocketURL.host() else { return room }
                    let text = await RadioSong.streamText(fromPlayer: host, session: session)
                    let song = await RadioSong.resolve(text, station: station, session: session)
                    return song.map(room.withSong) ?? room
                }
            }
            var rooms: [NowPlaying] = []
            for await room in tasks {
                if let room { rooms.append(room) }
            }
            return rooms.sorted { $0.roomName < $1.roomName }
        }
    }

    private func get<Body: Decodable & Sendable>(_ url: String) async throws -> Body {
        guard let url = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.setValue(SonosAPI.key, forHTTPHeaderField: "X-Sonos-Api-Key")
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(Body.self, from: data)
    }

    /// Browses Bonjour for `_sonos._tcp` for a few seconds and returns the players' IP addresses.
    private static func browseForPlayers(seconds: Double) async -> [String] {
        final class Found: @unchecked Sendable {
            // Only touched on `queue`.
            var hosts: [String] = []
        }
        let queue = DispatchQueue(label: "SonosTVTopShelf.browse")
        let found = Found()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sonos._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            // Each player advertises `location=http://<ip>:1400/...` in its TXT record.
            found.hosts = Set(results.compactMap { result -> String? in
                guard case .bonjour(let txt) = result.metadata, let location = txt["location"] else { return nil }
                return URL(string: location)?.host()
            }).sorted()
        }
        browser.start(queue: queue)
        return await withCheckedContinuation { continuation in
            queue.asyncAfter(deadline: .now() + seconds) {
                browser.cancel()
                continuation.resume(returning: found.hosts)
            }
        }
    }
}
