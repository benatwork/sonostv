import Foundation
import Observation

/// Finds the Sonos household on the local network, keeps a WebSocket open to every
/// group coordinator, and tracks what each group is playing.
///
/// Flow: Bonjour finds players → `players/local/info` gives the household id →
/// one socket subscribes to `groups:1` → each group's coordinator gets a socket
/// subscribed to `playback:1` and `playbackMetadata:1` for that group.
@Observable
final class SonosHousehold {
    enum Status: Equatable {
        case searching
        case localNetworkBlocked
        case connecting
        case connected
    }

    struct Group: Equatable {
        let id: String
        var name: String
        var coordinatorURL: URL
        var playbackState: String?
        var actions: SonosPlaybackStatus.Actions?
        var metadata: SonosMetadataStatus?
        /// For radio: the station's latest "now playing" text, and the song worked out from it.
        var radioText: String?
        var radioSong: RadioSong?
        /// When this group last went from not playing to playing. Picks which group to show.
        var startedPlayingAt = Date.distantPast
        /// When this group last stopped playing. A recently paused group stays on screen.
        var stoppedPlayingAt = Date.distantPast

        var isPlaying: Bool {
            playbackState == "PLAYBACK_STATE_PLAYING" || playbackState == "PLAYBACK_STATE_BUFFERING"
        }
    }

    enum PlaybackCommand: String {
        case play
        case pause
        case skipToNextTrack
        case skipToPreviousTrack
    }

    /// How long a paused group stays on screen, so it can be resumed from the remote.
    static let pausedGroupLingers: TimeInterval = 15 * 60

    private(set) var status = Status.searching
    private(set) var groups: [String: Group] = [:]
    /// Ticks every 30 seconds so `nowPlaying` drops paused groups once they've lingered long enough.
    private(set) var now = Date.now

    /// What to show: the group that most recently started playing something with metadata,
    /// or failing that, one that was paused in the last few minutes.
    var nowPlaying: NowPlaying? {
        let showIdle = UserDefaults.standard.bool(forKey: "ShowIdleGroups")
        let pausedSince = now.addingTimeInterval(-Self.pausedGroupLingers)
        return groups.values
            .filter { $0.isPlaying || $0.stoppedPlayingAt > pausedSince || showIdle }
            .sorted { lhs, rhs in
                if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
                return (lhs.startedPlayingAt, lhs.name) > (rhs.startedPlayingAt, rhs.name)
            }
            .lazy
            .compactMap { group -> NowPlaying? in
                let nowPlaying = group.metadata.flatMap {
                    NowPlaying(
                        groupId: group.id,
                        roomName: group.name,
                        metadata: $0,
                        isPlaying: group.isPlaying,
                        actions: group.actions
                    )
                }
                return group.radioSong.flatMap { nowPlaying?.withSong($0) } ?? nowPlaying
            }
            .first
    }

    @ObservationIgnored private let session = URLSession(
        configuration: .default,
        delegate: LocalNetworkTrust(),
        delegateQueue: nil
    )
    @ObservationIgnored private let discovery = SonosDiscovery()
    @ObservationIgnored private var playerHosts: [String] = []
    @ObservationIgnored private var householdId: String?
    @ObservationIgnored private var sockets: [URL: SonosSocket] = [:]
    /// The socket subscribed to `groups:1`. Also in `sockets`.
    @ObservationIgnored private var topologyURL: URL?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// Radio songs already looked up, keyed by the station's "now playing" text.
    @ObservationIgnored private var radioSongs: [String: RadioSong?] = [:]

    func start() {
        discovery.onPlayersChanged = { [weak self] hosts in
            guard let self else { return }
            playerHosts = hosts
            connect()
        }
        discovery.onBlocked = { [weak self] blocked in
            guard let self, status == .searching || status == .localNetworkBlocked else { return }
            status = blocked ? .localNetworkBlocked : .searching
        }
        discovery.start()
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = .now
            }
        }
        // Radio song titles only come from the older UPnP interface, which has to be asked.
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await refreshRadioSongs()
            }
        }
    }

    /// Asks each playing station's coordinator for its "now playing" text, and looks up
    /// the song when the text changes. Each distinct text is only looked up once.
    private func refreshRadioSongs() async {
        let stations = groups.values.filter { $0.isPlaying && $0.metadata?.container?.type == "station" }
        for group in stations {
            guard let host = group.coordinatorURL.host() else { continue }
            let text = await RadioSong.streamText(fromPlayer: host, session: session)
            guard let current = groups[group.id], current.radioText != text else { continue }
            groups[group.id]?.radioText = text

            let song: RadioSong?
            if let text, let cached = radioSongs[text] {
                song = cached
            } else {
                song = await RadioSong.resolve(text, station: current.metadata?.container?.name, session: session)
                if let text { radioSongs[text] = song }
            }
            // The station may have changed while the lookup ran.
            if groups[group.id]?.radioText == text {
                groups[group.id]?.radioSong = song
            }
        }
    }

    /// Sends a playback command to a group's coordinator.
    func send(_ command: PlaybackCommand, to groupId: String) {
        guard let group = groups[groupId], let socket = sockets[group.coordinatorURL] else { return }
        socket.send(namespace: "playback:1", command: command.rawValue, groupId: groupId)
    }

    // MARK: - Connecting

    private func connect() {
        guard connectTask == nil, topologyURL == nil, !playerHosts.isEmpty else { return }
        status = .connecting
        connectTask = Task {
            // Any player can describe the whole household; use the first one that answers.
            for host in playerHosts {
                guard !Task.isCancelled else { return }
                if let info = try? await fetchInfo(host: host) {
                    connectTask = nil
                    subscribeToGroups(info)
                    return
                }
            }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            connectTask = nil
            connect()
        }
    }

    private func fetchInfo(host: String) async throws -> SonosPlayerInfo {
        var request = URLRequest(
            url: URL(string: "https://\(host):1443/api/v1/players/local/info")!,
            timeoutInterval: 5
        )
        request.setValue(SonosAPI.key, forHTTPHeaderField: "X-Sonos-Api-Key")
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(SonosPlayerInfo.self, from: data)
    }

    private func subscribeToGroups(_ info: SonosPlayerInfo) {
        householdId = info.householdId
        topologyURL = info.websocketUrl
        // Subscribing also delivers the current groups straight away.
        socket(for: info.websocketUrl).send(namespace: "groups:1", command: "subscribe")
    }

    private func socket(for url: URL) -> SonosSocket {
        if let socket = sockets[url] { return socket }
        let socket = SonosSocket(url: url, householdId: householdId ?? "", session: session)
        socket.onMessage = { [weak self] data in self?.handle(data) }
        socket.onClose = { [weak self] _ in self?.connectionLost() }
        socket.connect()
        sockets[url] = socket
        return socket
    }

    /// Any dropped socket resets everything; a display app can afford a clean reconnect.
    private func connectionLost() {
        connectTask?.cancel()
        connectTask = nil
        for socket in sockets.values { socket.close() }
        sockets = [:]
        topologyURL = nil
        groups = [:]
        status = .connecting
        Task {
            try? await Task.sleep(for: .seconds(2))
            connect()
        }
    }

    // MARK: - Messages

    private func handle(_ data: Data) {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(SonosEnvelope<SonosObjectType>.self, from: data) else { return }
        let groupId = envelope.header.groupId

        switch envelope.body.objectType {
        case "groups":
            if let message = try? decoder.decode(SonosEnvelope<SonosGroups>.self, from: data) {
                update(message.body)
            }
        case "playbackStatus":
            if let groupId, let message = try? decoder.decode(SonosEnvelope<SonosPlaybackStatus>.self, from: data) {
                updatePlaybackStatus(message.body, groupId: groupId)
            }
        case "metadataStatus":
            if let groupId, let message = try? decoder.decode(SonosEnvelope<SonosMetadataStatus>.self, from: data) {
                let previous = groups[groupId]?.metadata?.container
                groups[groupId]?.metadata = message.body
                let container = message.body.container
                if previous?.name != container?.name || previous?.type != container?.type {
                    // A different source: forget the old station's song, and check the new one now.
                    groups[groupId]?.radioText = nil
                    groups[groupId]?.radioSong = nil
                    if container?.type == "station" {
                        Task { await refreshRadioSongs() }
                    }
                }
            }
        case "globalError":
            if let message = try? decoder.decode(SonosEnvelope<SonosGlobalError>.self, from: data) {
                print("Sonos error \(message.body.errorCode): \(message.body.reason ?? "")")
            }
        default:
            break
        }
    }

    private func update(_ body: SonosGroups) {
        let playerURLs = Dictionary(body.players.map { ($0.id, $0.websocketUrl) }) { first, _ in first }
        var updated: [String: Group] = [:]

        for group in body.groups {
            guard let url = playerURLs[group.coordinatorId] else { continue }
            let existing = groups[group.id]
            var state = existing ?? Group(id: group.id, name: group.name, coordinatorURL: url)
            state.name = group.name
            if let playbackState = group.playbackState {
                state.playbackState = playbackState
            }
            if existing?.coordinatorURL != url {
                // New group, or its coordinator moved: subscribe on the coordinator's socket.
                state.coordinatorURL = url
                let socket = socket(for: url)
                socket.send(namespace: "playback:1", command: "subscribe", groupId: group.id)
                socket.send(namespace: "playbackMetadata:1", command: "subscribe", groupId: group.id)
            }
            updated[group.id] = state
        }
        groups = updated

        // Close sockets to players that no longer coordinate any group.
        let inUse = Set(updated.values.map(\.coordinatorURL))
        for (url, socket) in sockets where url != topologyURL && !inUse.contains(url) {
            socket.close()
            sockets[url] = nil
        }
        status = .connected
    }

    private func updatePlaybackStatus(_ status: SonosPlaybackStatus, groupId: String) {
        guard var group = groups[groupId] else { return }
        let wasPlaying = group.isPlaying
        group.playbackState = status.playbackState
        group.actions = status.availablePlaybackActions
        if group.isPlaying && !wasPlaying {
            group.startedPlayingAt = .now
        } else if wasPlaying && status.playbackState == "PLAYBACK_STATE_PAUSED" {
            group.stoppedPlayingAt = .now
        }
        groups[groupId] = group
    }
}
