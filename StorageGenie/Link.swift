import Foundation
import IrohLib            // n0's official Swift package: https://github.com/n0-computer/iroh-ffi (SPM, v1.1.0)
import StorageGenieCore

/// The iPhone's end of the link to its ONE genie — same as Android's Link.kt: the phone is an iroh node with a stable
/// id (key in the Keychain), it LISTENS on ALPN storagegenie/1, the genie dials. First frame = auth (code or token).
///
/// iOS difference: no background service. The link runs while the app is in the foreground and is closed when the app
/// goes to the background (scenePhase), so the genie can only look while the person has the app open.
/// API calls follow IrohLib.swift v1.1.0 (Endpoint.bind / acceptNext / Incoming.accept / Accepting.connect / acceptBi).
@MainActor
final class Link: ObservableObject {
    static let alpn = Data("storagegenie/1".utf8)
    static let maxFrame = 1_000_000   // same cap as Android's Link.kt

    @Published private(set) var online = false
    @Published private(set) var nodeId = ""
    private var endpoint: Endpoint?
    private var task: Task<Void, Never>?

    let binding: StorageGenieCore.Binding
    let commands: Commands
    private let keychain: KeychainStore

    init(binding: StorageGenieCore.Binding, commands: Commands, keychain: KeychainStore) {
        self.binding = binding; self.commands = commands; self.keychain = keychain
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    /// App went to the background (or the person tapped Stop): close, so the genie can no longer reach the phone.
    func stop() {
        task?.cancel(); task = nil
        let ep = endpoint; endpoint = nil; online = false
        Task.detached { try? await ep?.close() }
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                let key = try keychain.secretKey()          // 32 bytes, generated once, Keychain (this device only)
                let ep = try await Endpoint.bind(options: EndpointOptions(
                    preset: presetN0(), bindAddr: nil, secretKey: key, alpns: [Link.alpn], relayMode: nil, protocols: nil))
                endpoint = ep
                nodeId = ep.id().description
                online = true
                while !Task.isCancelled {
                    guard let incoming = await ep.acceptNext() else { try await Task.sleep(nanoseconds: 200_000_000); continue }
                    Task { await self.serve(incoming) }
                }
            } catch {
                online = false
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    /// One connection: auth frame, then commands until the genie closes.
    private func serve(_ incoming: Incoming) async {
        do {
            let accepting = try await incoming.accept()
            guard try await accepting.alpn() == Link.alpn else { return }
            let conn = try await accepting.connect()
            let bi = try await conn.acceptBi()
            let recv = bi.recv(), send = bi.send()

            func next() async throws -> [String: Any] {
                guard let n = try Frames.readLength(try await recv.readExact(size: 4)) else { throw Frames.FrameError.short }
                if n > Link.maxFrame { throw Frames.FrameError.tooBig(n) }
                let body = n == 0 ? Data() : try await recv.readExact(size: UInt32(n))
                return try Frames.parseRequest(body)
            }
            func reply(_ o: [String: Any]) async throws { try await send.writeAll(buf: try Frames.response(o)) }

            let hello = try await next()
            let genie = String((hello["genie"] as? String ?? "").prefix(80))
            switch binding.authenticate(given: hello["auth"] as? String ?? "", genie: genie) {
            case .refused(let e):
                try await reply(["error": e])
                try await send.finish()
            case .ok(let g, let token):
                var o: [String: Any] = ["ok": true, "app": "storagegenie", "platform": "ios", "genie": g,
                                        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"]
                if let t = token { o["paired"] = true; o["token"] = t }
                try await reply(o)
                while !Task.isCancelled {
                    let cmd = try await next()
                    // A forget in the app ends every session on the next command (same as Android).
                    if !binding.isBound { try await reply(["error": "unpaired"]); break }
                    try await reply(commands.run(cmd, genie: g))
                }
            }
        } catch {
            // the genie hung up, or a frame was bad: just drop this connection
        }
    }
}
