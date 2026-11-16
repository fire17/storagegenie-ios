import Foundation
import CryptoKit

/// Where binding state lives. The app passes a Keychain-backed store; tests pass memory.
public protocol BindingStore: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?)
}

/// This iPhone's binding to ONE genie — a line-for-line port of the Android `Binding.kt` (PROTOCOL.md "## Pairing").
///
/// One phone, one genie: the 6-char code is good for exactly one successful pairing. It is then traded for a long
/// random token that only that genie holds, and the code dies. While a binding exists, every other genie is refused
/// ("bound") — only the person tapping "Forget my genie" in the app clears it.
public final class Binding {
    public static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    public static let codeTTL: TimeInterval = 30 * 60
    public static let maxFails = 5

    public enum Auth: Equatable {
        case ok(genie: String, newToken: String?)
        case refused(String)   // "bound" | "auth"
    }

    private let store: BindingStore
    private let now: () -> Date
    private let random: (Int) -> [UInt8]
    private let lock = NSLock()

    public init(store: BindingStore, now: @escaping () -> Date = Date.init,
                random: @escaping (Int) -> [UInt8] = Binding.secureRandom) {
        self.store = store; self.now = now; self.random = random
    }

    public static func secureRandom(_ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        precondition(SecRandomCopyBytes(kSecRandomDefault, n, &b) == errSecSuccess)
        return b
    }

    public var isBound: Bool { store.get("tokenHash") != nil }
    public var genie: String? { store.get("genie") }

    public func code() -> String {
        lock.lock(); defer { lock.unlock() }
        return store.get("code") ?? newCodeLocked()
    }

    /// The pairing line the person sends to their genie: `STORAGE-GENIE <node-id-hex>:<CODE>`.
    public func pairingLine(nodeId: String) -> String { "STORAGE-GENIE \(nodeId):\(code())" }

    /// The screen calls this when it shows the code, so the 30-min clock starts when the person sees it.
    public func freshCodeIfStale() {
        lock.lock(); defer { lock.unlock() }
        if !isBound && stale() { _ = newCodeLocked() }
    }

    /// Decide the first frame of a connection. Constant-time compares; never logs secrets.
    public func authenticate(given: String, genie: String) -> Auth {
        lock.lock(); defer { lock.unlock() }
        if let bound = store.get("tokenHash") {
            return Binding.eq(Binding.hash(given), bound) ? .ok(genie: store.get("genie") ?? "", newToken: nil) : .refused("bound")
        }
        // A code is good for 30 minutes after it is first shown; a stale leaked line pairs nothing.
        if stale() { _ = newCodeLocked() }
        let current = store.get("code") ?? newCodeLocked()
        let g = given.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !given.isEmpty && Binding.eq(g, current) {
            let token = Binding.base64url(random(32))
            store.set("tokenHash", Binding.hash(token))
            store.set("genie", String(genie.prefix(80)))
            store.set("code", nil); store.set("fails", "0")
            store.set("pairedAt", String(now().timeIntervalSince1970))
            return .ok(genie: genie, newToken: token)
        }
        let fails = (Int(store.get("fails") ?? "0") ?? 0) + 1
        if fails >= Binding.maxFails { _ = newCodeLocked() } else { store.set("fails", String(fails)) }
        return .refused("auth")
    }

    public func forget() {
        lock.lock(); defer { lock.unlock() }
        store.set("tokenHash", nil); store.set("genie", nil); store.set("pairedAt", nil)
        _ = newCodeLocked()
    }

    // MARK: - internals

    private func stale() -> Bool {
        let at = Double(store.get("codeAt") ?? "0") ?? 0
        return now().timeIntervalSince1970 - at > Binding.codeTTL
    }

    private func newCodeLocked() -> String {
        let bytes = random(6)
        let c = String(bytes.map { Binding.alphabet[Int($0) % Binding.alphabet.count] })
        store.set("code", c); store.set("fails", "0")
        store.set("codeAt", String(now().timeIntervalSince1970))
        return c
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time equality (length leaks only, as on Android's MessageDigest.isEqual).
    static func eq(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in 0..<x.count { d |= x[i] ^ y[i] }
        return d == 0
    }

    static func base64url(_ b: [UInt8]) -> String {
        Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// In-memory store (tests, previews).
public final class MemoryStore: BindingStore {
    public var values: [String: String] = [:]
    public init() {}
    public func get(_ key: String) -> String? { values[key] }
    public func set(_ key: String, _ value: String?) { values[key] = value }
}
