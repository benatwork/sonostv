import Foundation

// Message shapes for the Sonos local WebSocket API (wss://<player>:1443/websocket/api).
// Only the fields this app reads are modeled; everything else is ignored.

/// The first element of every message.
nonisolated struct SonosHeader: Decodable, Sendable {
    let namespace: String
    let type: String?
    let response: String?
    let success: Bool?
    let groupId: String?
}

/// Every message is a two-element JSON array: `[header, body]`.
nonisolated struct SonosEnvelope<Body: Decodable & Sendable>: Decodable, Sendable {
    let header: SonosHeader
    let body: Body

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        header = try container.decode(SonosHeader.self)
        body = try container.decode(Body.self)
    }
}

/// Decodes only a body's `_objectType`, which says what the rest of the body is.
nonisolated struct SonosObjectType: Decodable, Sendable {
    let objectType: String?

    enum CodingKeys: String, CodingKey {
        case objectType = "_objectType"
    }
}

/// `GET https://<player>:1443/api/v1/players/local/info`
nonisolated struct SonosPlayerInfo: Decodable, Sendable {
    /// The full household id. The shorter `hhid` in the Bonjour TXT record is not accepted.
    let householdId: String
    let playerId: String
    let websocketUrl: URL
}

/// Body of `groups:1` responses and events.
nonisolated struct SonosGroups: Decodable, Sendable {
    let groups: [Group]
    let players: [Player]

    nonisolated struct Group: Decodable, Sendable {
        let id: String
        let name: String
        let coordinatorId: String
        /// Present in `getGroups` responses, missing from subscription events.
        let playbackState: String?
    }

    nonisolated struct Player: Decodable, Sendable {
        let id: String
        let name: String
        let websocketUrl: URL
    }
}

/// Body of `playback:1` events.
nonisolated struct SonosPlaybackStatus: Decodable, Sendable {
    let playbackState: String
}

/// Body of `playbackMetadata:1` events.
nonisolated struct SonosMetadataStatus: Decodable, Sendable, Equatable {
    let container: Container?
    let currentItem: Item?
    /// Free-form "now playing" text some radio stations send instead of a track.
    let streamInfo: String?

    nonisolated struct Container: Decodable, Sendable, Equatable {
        let name: String?
        /// For example `album`, `playlist`, `station` or `linein.homeTheater.hdmi`.
        let type: String?
        let imageUrl: String?
    }

    nonisolated struct Item: Decodable, Sendable, Equatable {
        let track: Track?
    }

    nonisolated struct Track: Decodable, Sendable, Equatable {
        let name: String?
        let imageUrl: String?
        let artist: Named?
        let album: Named?
    }

    nonisolated struct Named: Decodable, Sendable, Equatable {
        let name: String?
    }
}

/// Body of a failed command.
nonisolated struct SonosGlobalError: Decodable, Sendable {
    let errorCode: String
    let reason: String?
}
