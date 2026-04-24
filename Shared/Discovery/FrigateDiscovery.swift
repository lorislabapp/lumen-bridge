import Foundation
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "Discovery")

/// Discovers Frigate instances on the local network via Bonjour. Frigate
/// publishes a `_frigate._tcp` record at startup when `mdns: true` is set in
/// its config. The first instance we find becomes the default target; users
/// with multiple instances will later be able to pick from the list in the
/// Settings window.
final class FrigateDiscovery: NSObject {
    private let browser = NetServiceBrowser()
    private var pendingServices: [NetService] = []

    /// Called on the main actor when a new Frigate service finishes resolving.
    var onFound: (@MainActor (DiscoveredFrigate) -> Void)?

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_frigate._tcp.", inDomain: "local.")
        logger.info("started Bonjour search for _frigate._tcp")
    }

    func stop() {
        browser.stop()
        for service in pendingServices {
            service.stop()
        }
        pendingServices.removeAll()
    }
}

extension FrigateDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.resolve(withTimeout: 5.0)
        pendingServices.append(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        pendingServices.removeAll { $0 === service }
    }
}

extension FrigateDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName ?? "unknown"
        let port = sender.port
        let name = sender.name
        let id = "\(name).\(sender.type)"

        logger.info("resolved Frigate instance: \(name) at \(host):\(port)")

        let result = DiscoveredFrigate(id: id, host: host, port: port, netServiceName: name)
        // Capture the callback before the Task hop so we don't need to send
        // `self` (which isn't Sendable — NetServiceDelegate is a classic Obj-C
        // pattern that predates Swift 6 concurrency) across the MainActor
        // boundary. The callback itself is MainActor-isolated and Sendable.
        let callback = onFound
        Task { @MainActor in
            callback?(result)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        logger.error("failed to resolve \(sender.name): \(errorDict)")
    }
}
