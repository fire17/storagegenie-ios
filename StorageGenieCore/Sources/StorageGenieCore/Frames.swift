import Foundation

/// The wire format, byte-compatible with Android + controller/storage-genie.py (PROTOCOL.md):
/// request  = u32 BE length ‖ UTF-8 JSON
/// response = u32 BE length ‖ 0x00 ‖ UTF-8 JSON   (type byte 0 = json)
public enum Frames {
    /// Same cap as the controller's reader; a bigger length is a broken or hostile peer.
    public static let maxFrame = 8 * 1024 * 1024

    public enum FrameError: Error, Equatable { case tooBig(Int), short, badJSON, badType(UInt8) }

    public static func request(_ obj: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return length(body.count) + body
    }

    public static func response(_ obj: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return length(body.count + 1) + Data([0]) + body
    }

    /// Reads the 4-byte header; nil when fewer than 4 bytes.
    public static func readLength(_ header: Data) throws -> Int? {
        guard header.count >= 4 else { return nil }
        let b = [UInt8](header.prefix(4))
        let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        if n > maxFrame { throw FrameError.tooBig(n) }
        return n
    }

    /// Parses a request payload (no type byte).
    public static func parseRequest(_ payload: Data) throws -> [String: Any] {
        guard let o = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw FrameError.badJSON }
        return o
    }

    /// Parses a response payload (type byte 0 + JSON).
    public static func parseResponse(_ payload: Data) throws -> [String: Any] {
        guard let t = payload.first else { throw FrameError.short }
        guard t == 0 else { throw FrameError.badType(t) }
        guard let o = try? JSONSerialization.jsonObject(with: payload.dropFirst()) as? [String: Any] else { throw FrameError.badJSON }
        return o
    }

    static func length(_ n: Int) -> Data {
        Data([UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
    }
}
