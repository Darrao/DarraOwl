import DarraOwlShared
import Foundation

/// Picks the addresses worth publishing from the Mac's interfaces.
public enum EndpointPicker {
    public struct Interface: Equatable, Sendable {
        public var name: String
        public var ipv4: String

        public init(name: String, ipv4: String) {
            self.name = name
            self.ipv4 = ipv4
        }
    }

    public static func endpoints(from interfaces: [Interface], port: UInt16) -> Endpoints {
        var local: [String] = []
        var tailscale: String?
        for i in interfaces {
            guard let octets = octets(i.ipv4) else { continue }
            if isTailscale(octets) {
                if tailscale == nil { tailscale = i.ipv4 }
            } else if isPrivateLAN(octets), !Self.virtualPrefixes.contains(where: i.name.hasPrefix), !local.contains(i.ipv4) {
                local.append(i.ipv4)
            }
        }
        // The phone refuses a longer list: the first ones (en0 first) stay.
        return Endpoints(port: port, local: Array(local.prefix(Endpoints.maxLocal)), tailscale: tailscale)
    }

    /// Tunnels, bridges, loopback and virtual machines' networks: never
    /// where a phone finds the Mac.
    static let virtualPrefixes = ["utun", "bridge", "lo", "vmnet", "vnic", "vboxnet", "anpi", "awdl", "llw"]

    /// 172.20.10.0/28: the network an iPhone hotspot hands out.
    public static func isHotspot(_ ipv4: String) -> Bool {
        guard let o = octets(ipv4) else { return false }
        return o[0] == 172 && o[1] == 20 && o[2] == 10 && o[3] < 16
    }

    static func octets(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return parts
    }

    /// 100.64.0.0/10.
    static func isTailscale(_ o: [Int]) -> Bool {
        o[0] == 100 && (64...127).contains(o[1])
    }

    static func isPrivateLAN(_ o: [Int]) -> Bool {
        o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
    }
}
