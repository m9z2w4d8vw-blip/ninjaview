import Foundation
import Network

/// The phone's connection — Wi-Fi or cellular, a VPN, IPv4 or IPv6, Low Data Mode — for the debug
/// log. tik.ninja's limits are per connection, and a shared one (campus or public Wi-Fi, a
/// carrier's shared address, a VPN's exit) can be limited by other people's traffic.
@MainActor
final class NetworkStatus {
    static let shared = NetworkStatus()

    private(set) var summary = "not known yet"
    private let monitor = NWPathMonitor()
    private var started = false
    private var known = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { @Sendable (path: NWPath) in
            let text = NetworkStatus.describe(path)
            Task { @MainActor in NetworkStatus.shared.update(text) }
        }
        monitor.start(queue: DispatchQueue(label: "com.parv.ninjaview.network"))
    }

    private func update(_ text: String) {
        guard !known || text != summary else { return }
        let first = !known
        known = true
        summary = text
        DebugLog.shared.add(.app, first ? "Network: \(text)" : "Network changed: \(text)")
    }

    nonisolated static func describe(_ path: NWPath) -> String {
        var parts: [String] = []
        switch path.status {
        case .satisfied: parts.append("online")
        case .unsatisfied: parts.append("offline")
        case .requiresConnection: parts.append("waiting for a connection")
        @unknown default: parts.append("status unknown")
        }
        if path.usesInterfaceType(.wifi) { parts.append("Wi-Fi") }
        if path.usesInterfaceType(.cellular) { parts.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { parts.append("wired") }
        if path.usesInterfaceType(.other) { parts.append("other interface") }
        let names = path.availableInterfaces.map { $0.name }
        if names.contains(where: { $0.hasPrefix("utun") || $0.hasPrefix("ipsec") || $0.hasPrefix("ppp") }) {
            parts.append("tunnel interface in use (likely a VPN)")
        }
        var ip: [String] = []
        if path.supportsIPv4 { ip.append("IPv4") }
        if path.supportsIPv6 { ip.append("IPv6") }
        if !ip.isEmpty { parts.append(ip.joined(separator: " + ")) }
        if path.isExpensive { parts.append("expensive (cellular or a hotspot)") }
        if path.isConstrained { parts.append("Low Data Mode") }
        if !names.isEmpty { parts.append("interfaces " + names.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}
