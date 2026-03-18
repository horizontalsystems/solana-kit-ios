import Combine
import Foundation
import HsExtensions
import Network

/// Monitors network reachability using `NWPathMonitor` and exposes a Combine publisher.
///
/// Only fires when the connected state actually changes (via `@DistinctPublished`),
/// matching Android's `if (oldValue != isConnected) { listener?.onConnectionChange() }` behaviour.
///
/// Note: `stop()` cancels the underlying `NWPathMonitor` — NWPathMonitor cannot be restarted
/// after cancellation. Call `start()` again to create a fresh monitor.
final class ConnectionManager {
    private var monitor: NWPathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.horizontalsystems.solana-kit.connection-manager")

    @DistinctPublished private(set) var isConnected: Bool = false
}

// MARK: - IConnectionManager

extension ConnectionManager: IConnectionManager {
    var isConnectedPublisher: AnyPublisher<Bool, Never> {
        $isConnected
    }

    func start() {
        // NWPathMonitor cannot be restarted after cancel — create a fresh instance each time.
        monitor = NWPathMonitor()

        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isConnected = connected
            }
        }

        monitor.start(queue: monitorQueue)
    }

    func stop() {
        monitor.cancel()
    }
}
