import Foundation

/// One WebSocket connection to a Sonos player's local control API.
final class SonosSocket {
    let url: URL
    /// Called with the raw JSON of every message the player sends.
    var onMessage: ((Data) -> Void)?
    /// Called once if the connection drops. Not called after `close()`.
    var onClose: ((any Error) -> Void)?

    private let task: URLSessionWebSocketTask
    private let householdId: String
    private var nextCommandId = 0
    private var receiveTask: Task<Void, Never>?

    init(url: URL, householdId: String, session: URLSession) {
        self.url = url
        self.householdId = householdId
        var request = URLRequest(url: url)
        request.setValue(SonosAPI.key, forHTTPHeaderField: "X-Sonos-Api-Key")
        request.setValue(SonosAPI.webSocketProtocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        task = session.webSocketTask(with: request)
    }

    func connect() {
        task.resume()
        receiveTask = Task { [weak self, task] in
            do {
                while true {
                    let data = switch try await task.receive() {
                    case .string(let text): Data(text.utf8)
                    case .data(let data): data
                    @unknown default: Data()
                    }
                    self?.onMessage?(data)
                }
            } catch {
                self?.onClose?(error)
            }
        }
    }

    /// Sends a command. Commands sent before the connection opens are queued.
    func send(namespace: String, command: String, groupId: String? = nil) {
        nextCommandId += 1
        var header = [
            "namespace": namespace,
            "command": command,
            "householdId": householdId,
            "cmdId": String(nextCommandId),
        ]
        header["groupId"] = groupId
        guard let data = try? JSONSerialization.data(withJSONObject: [header, [String: String]()]) else { return }
        let text = String(decoding: data, as: UTF8.self)
        // A failed send also fails `receive()`, which reports the drop through `onClose`.
        Task { [task] in try? await task.send(.string(text)) }
    }

    func close() {
        onMessage = nil
        onClose = nil
        receiveTask?.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }
}
