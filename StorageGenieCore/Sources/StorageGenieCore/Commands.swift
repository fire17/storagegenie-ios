import Foundation

/// What the genie may ask an iPhone, and the iPhone's honest answers. Same command names as Android (PROTOCOL.md
/// "## Commands") so the controller needs no iOS branch; what iOS cannot do is answered plainly, never faked.
///
/// iOS limits:
///  - scan sees ONLY the Photos library (incl. media WhatsApp saved there) + folders the person picked. No full disk.
///  - deletion is ALWAYS Apple's own confirm sheet, items go to "Recently Deleted" for 30 days. Never silent.
///  - the link lives only while the app is open (no background service on iOS).
public protocol MediaLibrary: AnyObject {
    /// Biggest items first. `id` = the Photos localIdentifier (or a picked-folder path).
    func scan(top: Int) throws -> [MediaItem]
    var hasAccess: Bool { get }
    var totalBytes: Int64 { get }
    var freeBytes: Int64 { get }
}

public struct MediaItem: Equatable {
    public let id: String, name: String, bytes: Int64, kind: String, date: Date?
    public init(id: String, name: String, bytes: Int64, kind: String, date: Date?) {
        self.id = id; self.name = name; self.bytes = bytes; self.kind = kind; self.date = date
    }
    func json() -> [String: Any] {
        var o: [String: Any] = ["path": id, "name": name, "bytes": bytes, "kind": kind]
        if let d = date { o["mtime"] = Int(d.timeIntervalSince1970) }
        return o
    }
}

/// Proposals: the genie suggests, the PERSON decides in the app, and Apple's sheet is the last word.
public final class Proposals {
    public static let maxItems = 200
    public enum State: String { case pending, done, dismissed }

    public struct Proposal {
        public let id: String
        public let paths: [String]
        public let reason: String
        public var state: State = .pending
        public var deleted: [String] = []
        public var kept: [String] = []
        public var freedBytes: Int64 = 0
    }

    private(set) public var byId: [String: Proposal] = [:]
    private var lastScan: Set<String> = []
    private let newId: () -> String

    public init(newId: @escaping () -> String = { UUID().uuidString.prefix(8).lowercased() }) { self.newId = newId }

    func rememberScan(_ items: [MediaItem]) { lastScan = Set(items.map(\.id)) }

    /// Only items from THIS phone's most recent scan; anything else is rejected, nothing is deleted here.
    func create(paths: [String], reason: String) -> [String: Any] {
        let wanted = Array(paths.prefix(Proposals.maxItems))
        let ok = wanted.filter { lastScan.contains($0) }
        let rejected = wanted.filter { !lastScan.contains($0) }
        if ok.isEmpty { return ["error": "nothing_valid", "rejected": rejected] }
        let id = newId()
        byId[id] = Proposal(id: id, paths: ok, reason: String(reason.prefix(300)))
        return ["ok": true, "id": id, "count": ok.count, "rejected": rejected]
    }

    /// Called by the app AFTER the person ticked items AND Apple's delete sheet returned.
    public func complete(id: String, deleted: [String], freed: Int64) {
        guard var p = byId[id], p.state == .pending else { return }
        let d = deleted.filter { p.paths.contains($0) }
        p.deleted = d; p.kept = p.paths.filter { !d.contains($0) }; p.freedBytes = freed; p.state = .done
        byId[id] = p
    }

    public func dismiss(id: String) {
        guard var p = byId[id], p.state == .pending else { return }
        p.state = .dismissed; p.kept = p.paths; byId[id] = p
    }

    func status(id: String) -> [String: Any] {
        guard let p = byId[id] else { return ["error": "unknown_proposal"] }
        return ["id": p.id, "state": p.state.rawValue, "deleted": p.deleted, "kept": p.kept,
                "freed_bytes": p.freedBytes, "trashed": true]  // iOS: always "Recently Deleted", restorable 30 days
    }
}

/// The phone side of one authenticated connection: a request dict in, a reply dict out.
public final class Commands {
    public let library: MediaLibrary
    public let proposals: Proposals
    public let version: String
    /// The link answers only while the person has the app on screen (iOS has no background link anyway).
    public var appOpen: () -> Bool
    public var onProposal: ((Proposals.Proposal) -> Void)?

    public init(library: MediaLibrary, proposals: Proposals, version: String, appOpen: @escaping () -> Bool) {
        self.library = library; self.proposals = proposals; self.version = version; self.appOpen = appOpen
    }

    public func run(_ cmd: [String: Any], genie: String) -> [String: Any] {
        switch cmd["cmd"] as? String ?? "" {
        case "ping":
            return ["ok": true, "version": version, "genie": genie, "has_access": library.hasAccess,
                    "platform": "ios", "background": false]
        case "scan":
            guard appOpen() else { return ["error": "app_closed"] }
            guard library.hasAccess else { return ["error": "need_permission"] }
            let top = max(1, min(cmd["top"] as? Int ?? 40, 500))
            do {
                let items = try library.scan(top: top)
                proposals.rememberScan(items)
                return ["ok": true, "platform": "ios", "scope": "photos_library",
                        "total_bytes": library.totalBytes, "free_bytes": library.freeBytes,
                        "items": items.map { $0.json() }]
            } catch { return ["error": "scan_failed"] }
        case "propose_delete":
            guard appOpen() else { return ["error": "app_closed"] }
            let paths = cmd["paths"] as? [String] ?? []
            let r = proposals.create(paths: paths, reason: cmd["reason"] as? String ?? "")
            if let id = r["id"] as? String, let p = proposals.byId[id] { onProposal?(p) }
            return r
        case "proposal":
            return proposals.status(id: cmd["id"] as? String ?? "")
        // Android-only commands: answered plainly so the genie knows, never faked.
        case "execute", "update_offer", "update_chunk", "update_commit", "update_status", "update_none":
            return ["error": "unsupported_on_ios"]
        default:
            return ["error": "unknown cmd \(cmd["cmd"] as? String ?? "")"]
        }
    }
}
