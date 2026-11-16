import Foundation
@testable import StorageGenieCore

// Storage Genie iOS core selftest — same rules as Android's Binding/PROTOCOL, checked without a phone.
// Run: swift run --scratch-path /tmp/sgcore-build sgcore-selftest   (exit 0 = PASS)

var fails = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "PASS  " : "FAIL  ") + what); if !ok { fails += 1 } }

// ------------------------------------------------------------ pairing (PROTOCOL.md "## Pairing")
var clock = Date(timeIntervalSince1970: 1_800_000_000)
var seq: UInt8 = 0
let store = MemoryStore()
let b = Binding(store: store, now: { clock }, random: { n in (0..<n).map { _ in seq &+= 7; return seq } })

let code = b.code()
check(code.count == 6 && code.allSatisfy { Binding.alphabet.contains($0) }, "code: 6 chars from the no-lookalike alphabet")
check(b.pairingLine(nodeId: "ab12") == "STORAGE-GENIE ab12:\(code)", "pairing line matches Android's shape")
check(b.authenticate(given: "WRONG1", genie: "agent:x") == .refused("auth"), "wrong code refused")
let r = b.authenticate(given: " \(code.lowercased()) ", genie: "agent:alice")
guard case .ok(let g, let tokOpt) = r, let tok = tokOpt else { print("FAIL  right code pairs"); exit(1) }
check(g == "agent:alice" && tok.count == 43 && !tok.contains("=") && !tok.contains("+") && !tok.contains("/"),
      "right code (trimmed, case-insensitive) pairs; 43-char urlsafe token")
check(store.get("tokenHash") != nil && store.get("tokenHash") != tok && store.get("code") == nil,
      "only the token HASH is stored; the code dies")
check(b.authenticate(given: code, genie: "agent:evil") == .refused("bound"), "the used code no longer works (bound)")
check(b.authenticate(given: tok, genie: "agent:alice") == .ok(genie: "agent:alice", newToken: nil), "token reconnects")
check(b.authenticate(given: "x" + tok.dropFirst(), genie: "agent:alice") == .refused("bound"), "wrong token refused")
b.forget()
check(!b.isBound && b.authenticate(given: tok, genie: "agent:alice") == .refused("auth"), "Forget clears the binding")

// expiry + rotation
let s2 = MemoryStore()
let b2 = Binding(store: s2, now: { clock }, random: { n in (0..<n).map { _ in seq &+= 13; return seq } })
let c1 = b2.code()
clock += 31 * 60
check(b2.authenticate(given: c1, genie: "agent:x") == .refused("auth"), "a code older than 30 min pairs nothing")
let c2 = b2.code()
check(c2 != c1, "a stale code is replaced")
// The stale attempt above already counted as wrong try #1 (same as Android): 3 more keep the code, the 5th rotates it.
for _ in 0..<3 { _ = b2.authenticate(given: "ZZZZZZ", genie: "agent:x") }
check(b2.code() == c2, "4 wrong tries keep the code")
_ = b2.authenticate(given: "ZZZZZZ", genie: "agent:x")
check(b2.code() != c2, "the 5th wrong try rotates the code")

check(Binding.eq("abc", "abc") && !Binding.eq("abc", "abd") && !Binding.eq("abc", "abcd"), "constant-time eq")

// ------------------------------------------------------------ frames (byte-compatible with the controller)
do {
    let req = try Frames.request(["cmd": "ping"])
    check([UInt8](req.prefix(4)) == [0, 0, 0, 14] && String(data: req.dropFirst(4), encoding: .utf8) == "{\"cmd\":\"ping\"}",
          "request = u32 BE length + JSON")
    let resp = try Frames.response(["ok": true])
    check([UInt8](resp.prefix(5)) == [0, 0, 0, 12, 0], "response = u32 BE length + 0x00 + JSON")
    check(try Frames.parseResponse(resp.dropFirst(4))["ok"] as? Bool == true, "response round-trips")
    check(try Frames.readLength(Data([0, 0, 1, 0])) == 256, "length decodes big-endian")
    do { _ = try Frames.readLength(Data([0x7f, 0, 0, 0])); check(false, "oversized frame refused") }
    catch { check(error as? Frames.FrameError == .tooBig(0x7f00_0000), "oversized frame refused") }
    do { _ = try Frames.parseResponse(Data([1, 0x7b, 0x7d])); check(false, "non-JSON type byte refused") }
    catch { check(error as? Frames.FrameError == .badType(1), "non-JSON type byte refused") }
} catch { check(false, "frames threw \(error)") }

// ------------------------------------------------------------ commands + delete gate
final class FakeLibrary: MediaLibrary {
    var hasAccess = true
    var totalBytes: Int64 = 256_000_000_000
    var freeBytes: Int64 = 3_000_000_000
    func scan(top: Int) throws -> [MediaItem] {
        Array([MediaItem(id: "PH/A1", name: "IMG_1.MOV", bytes: 4_000_000_000, kind: "video", date: nil),
               MediaItem(id: "PH/B2", name: "IMG_2.HEIC", bytes: 3_000_000, kind: "image", date: nil)].prefix(top))
    }
}
let lib = FakeLibrary()
var open = false
var proposed: Proposals.Proposal?
let props = Proposals(newId: { "p1" })
let cmds = Commands(library: lib, proposals: props, version: "0.1.0-ios", appOpen: { open })
cmds.onProposal = { proposed = $0 }

let ping = cmds.run(["cmd": "ping"], genie: "agent:alice")
check(ping["platform"] as? String == "ios" && ping["background"] as? Bool == false, "ping says iOS, no background link")
check(cmds.run(["cmd": "scan"], genie: "g")["error"] as? String == "app_closed", "scan refused while the app is closed")
open = true
lib.hasAccess = false
check(cmds.run(["cmd": "scan"], genie: "g")["error"] as? String == "need_permission", "scan asks for Photos access first")
lib.hasAccess = true
let scan = cmds.run(["cmd": "scan", "top": 40], genie: "g")
check((scan["items"] as? [[String: Any]])?.count == 2 && scan["scope"] as? String == "photos_library",
      "scan returns the Photos library items and says its scope")
let p = cmds.run(["cmd": "propose_delete", "paths": ["PH/A1", "/etc/passwd"], "reason": "big video"], genie: "g")
check(p["count"] as? Int == 1 && (p["rejected"] as? [String]) == ["/etc/passwd"], "only items from this phone's last scan")
check(proposed?.paths == ["PH/A1"], "the app is told (it shows the review screen)")
check(props.status(id: "p1")["state"] as? String == "pending", "nothing is deleted by the genie's command")
check(cmds.run(["cmd": "propose_delete", "paths": ["nope"]], genie: "g")["error"] as? String == "nothing_valid",
      "a proposal with nothing valid is refused")
check(cmds.run(["cmd": "execute", "id": "p1"], genie: "g")["error"] as? String == "unsupported_on_ios",
      "no remote execute on iOS: the person deletes in the app, through Apple's sheet")
props.complete(id: "p1", deleted: ["PH/A1", "PH/NOT-IN-PROPOSAL"], freed: 4_000_000_000)
let st = props.status(id: "p1")
check(st["state"] as? String == "done" && (st["deleted"] as? [String]) == ["PH/A1"] && st["trashed"] as? Bool == true,
      "completion records only proposed items, as restorable (Recently Deleted)")
check(cmds.run(["cmd": "update_offer"], genie: "g")["error"] as? String == "unsupported_on_ios", "no self-update on iOS")

print(fails == 0 ? "SGCORE SELFTEST PASS" : "SGCORE SELFTEST FAIL (\(fails))")
exit(fails == 0 ? 0 : 1)
