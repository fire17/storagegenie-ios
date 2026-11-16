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
        WindowGroup { HomeView().environmentObject(model) }
            .onChange(of: phase) { p in
                model.visible = (p == .active)
                p == .active ? model.link.start() : model.link.stop()   // no background link on iOS
            }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let keychain = KeychainStore()
    let library = PhotosLibrary()
    let proposals = Proposals()
    lazy var binding = Binding(store: keychain)
    lazy var commands = Commands(library: library, proposals: proposals,
                                 version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                                 appOpen: { [weak self] in self?.visible ?? false })
    lazy var link = Link(binding: binding, commands: commands, keychain: keychain)

    @Published var visible = false
    @Published var pending: Proposals.Proposal?

    init() {
        commands.onProposal = { [weak self] p in DispatchQueue.main.async { self?.pending = p } }
    }
}

/// Binding state + the node key in the Keychain, this device only (never synced to iCloud, never in backups).
final class KeychainStore: Binding.Store {
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
        let d = Data(Binding.secureRandom(32))
        set("sk", d.base64EncodedString())
        return d
    }
}
