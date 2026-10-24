import Foundation
import Network

/// Browses Bonjour for `_sonos._tcp` and reports the IP address of every player it finds.
final class SonosDiscovery {
    /// Called with the sorted IP addresses of all players currently advertised.
    var onPlayersChanged: (([String]) -> Void)?
    /// Called when browsing cannot proceed, usually because Local Network access is off.
    var onBlocked: ((Bool) -> Void)?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_sonos._tcp", domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = Set(results.compactMap(Self.host(from:))).sorted()
            MainActor.assumeIsolated { self?.onPlayersChanged?(hosts) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            onBlocked?(false)
        case .waiting:
            onBlocked?(true)
        case .failed:
            // Restart after a pause; failures are usually transient network changes.
            stop()
            Task {
                try? await Task.sleep(for: .seconds(5))
                start()
            }
        default:
            break
        }
    }

    /// Each player advertises `location=http://<ip>:1400/xml/device_description.xml` in its TXT record.
    nonisolated private static func host(from result: NWBrowser.Result) -> String? {
        guard case .bonjour(let txt) = result.metadata,
              let location = txt["location"]
        else { return nil }
        return URL(string: location)?.host()
    }
}
