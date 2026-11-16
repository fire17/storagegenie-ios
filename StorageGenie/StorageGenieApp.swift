import SwiftUI
import Security
import StorageGenieCore

/// Storage Genie for iPhone: pairs with your own genie by a one-time code, exactly like the Android app.
/// Reach on iOS: Photos library only; deleting always through Apple's own sheet; link only while the app is open.
@main
struct StorageGenieApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup { HomeView(link: model.link).environmentObject(model) }
            .onChange(of: phase) { _, p in
                model.visible = (p == .active)
                p == .active ? model.link.start() : model.link.stop()   // no background link on iOS
            }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let keychain: KeychainStore
    let library: PhotosLibrary
    let proposals: Proposals
    let binding: StorageGenieCore.Binding
    let commands: StorageGenieCore.Commands
    let link: Link

    /// Set from scenePhase. Mirrored into a lock-protected flag the link reads from any thread (no main-thread hop, no deadlock).
    @Published var visible = false { didSet { onScreen.set(visible) } }
    let onScreen = Flag()
    @Published var pending: Proposals.Proposal?

    init() {
        let kc = KeychainStore(), lib = PhotosLibrary(), props = Proposals()
        let bind = StorageGenieCore.Binding(store: kc)
        let cmds = StorageGenieCore.Commands(library: lib, proposals: props,
                            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                            appOpen: { false })
        keychain = kc; library = lib; proposals = props; binding = bind; commands = cmds
        link = Link(binding: bind, commands: cmds, keychain: kc)
        // The link answers only while the app is on screen.
        let flag = onScreen
        cmds.appOpen = { flag.get() }
        cmds.onProposal = { [weak self] p in DispatchQueue.main.async { self?.pending = p } }
    }
}

/// A Bool that any thread may read or write.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

/// Binding state + the node key in the Keychain, this device only (never synced to iCloud, never in backups).
final class KeychainStore: BindingStore {
    private let service = "com.fire17.storagegenie"

    func get(_ key: String) -> String? {
        var out: AnyObject?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func set(_ key: String, _ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard let v = value else { return }
        var add = q
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// The iroh node key: 32 random bytes, made once.
    func secretKey() throws -> Data {
        if let s = get("sk"), let d = Data(base64Encoded: s), d.count == 32 { return d }
        let d = Data(StorageGenieCore.Binding.secureRandom(32))
        set("sk", d.base64EncodedString())
        return d
    }
}
