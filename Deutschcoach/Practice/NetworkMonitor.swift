import Foundation
import Network

/// Reports whether the network is reachable (DESIGN.md §1). Faked in tests.
protocol NetworkMonitor: AnyObject {
    var isOnline: Bool { get }
    /// `handler` is called on the main actor whenever reachability changes.
    func start(_ handler: @escaping @MainActor (Bool) -> Void)
}

/// `NWPathMonitor`-based monitor.
final class SystemNetworkMonitor: NetworkMonitor {
    private let monitor = NWPathMonitor()
    private(set) var isOnline = true

    func start(_ handler: @escaping @MainActor (Bool) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                handler(online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.ming.Deutschcoach.network"))
    }

    deinit {
        monitor.cancel()
    }
}
