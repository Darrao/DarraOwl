import Foundation

public enum LinkProtocol {
    public static let version = 1
    public static let bonjourType = "_darraowl._tcp"
    public static let defaultPort: UInt16 = 52_525
    /// A frame larger than this closes the connection.
    public static let maxFrameSize = 256 * 1024
}

/// Phone to Mac, over the encrypted direct link.
public enum ClientMessage: Codable, Equatable, Sendable {
    /// First message on a connection. Nothing else is answered before it.
    case hello(protocolVersion: Int, deviceID: UUID)
    case getState
    case command(SignedCommand)
    case pair(PairingRequest)
}

/// Mac to phone.
public enum ServerMessage: Codable, Equatable, Sendable {
    case hello(protocolVersion: Int, macID: UUID)
    case state(MacState)
    case result(CommandResult)
    case paired(PairingResponse)
    case error(String)
}

/// Length-prefixed frames: 4 bytes big-endian length, then JSON.
public struct Framer: Sendable {
    public enum FrameError: Error, Equatable, Sendable {
        case tooLarge(Int)
    }

    private var buffer = Data()

    public init() {}

    public static func frame<T: Encodable>(_ value: T) throws -> Data {
        let body = try LinkCoding.encoder().encode(value)
        var length = UInt32(body.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(body)
        return out
    }

    /// Adds received bytes and returns every complete frame body.
    public mutating func push(_ data: Data) throws(FrameError) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length <= LinkProtocol.maxFrameSize else { throw .tooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }
}
