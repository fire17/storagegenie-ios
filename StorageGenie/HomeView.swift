import SwiftUI
import StorageGenieCore

/// One screen, like Android: pairing code (until paired) · link state · Photos access · the genie's suggestion.
/// Every suggested item starts UNTICKED; Delete opens Apple's own sheet; nothing happens without both.
struct HomeView: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject var link: Link
    @State private var ticked: Set<String> = []
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Circle().fill(link.online ? .green : .gray).frame(width: 10, height: 10)
                        Text(link.online ? (m.binding.isBound ? "Connected to \(m.binding.genie ?? "your genie")" : "Waiting for your genie")
                                           : "Offline")
                    }
                    Text("Your genie can look only while this app is open.").font(.footnote).foregroundStyle(.secondary)
                }
                if !m.library.hasAccess {
                    Section("Photos") {
                        Button("Allow access to Photos") { m.library.requestAccess { _ in DispatchQueue.main.async { m.objectWillChange.send() } } }
                        Text("iPhone apps can only see your photos and videos (including what WhatsApp saved there).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !m.binding.isBound {
                    Section("Pair with your genie") {
                        Text(m.binding.code()).font(.system(size: 34, weight: .bold, design: .monospaced))
                        ShareLink(item: m.binding.pairingLine(nodeId: link.nodeId)) { Label("Send to my genie", systemImage: "paperplane") }
                            .disabled(link.nodeId.isEmpty)
                        Text("Send this line to your genie on WhatsApp. The code works once, for 30 minutes.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let p = m.pending { suggestion(p) }
                if m.binding.isBound {
                    Section { Button("Forget my genie", role: .destructive) { confirmForget = true } }
                }
            }
            .navigationTitle("Storage Genie")
            .onAppear { m.binding.freshCodeIfStale() }
            .confirmationDialog("Forget your genie? It will no longer be able to reach this iPhone.", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) { m.binding.forget(); m.objectWillChange.send() }
            }
        }
    }

    @ViewBuilder private func suggestion(_ p: Proposals.Proposal) -> some View {
        Section("Your genie suggests") {
            Text(p.reason).font(.callout)
            ForEach(p.paths, id: \.self) { id in
                Toggle(isOn: SwiftUI.Binding(get: { ticked.contains(id) }, set: { on in if on { ticked.insert(id) } else { ticked.remove(id) } })) {
                    Text(id).lineLimit(1).font(.footnote.monospaced())
                }
            }
            Button("Delete \(ticked.count) — iPhone will ask you", role: .destructive) {
                let ids = Array(ticked)
                m.library.delete(ids: ids) { deleted, freed in
                    m.proposals.complete(id: p.id, deleted: deleted, freed: freed)
                    ticked = []; m.pending = nil
                }
            }.disabled(ticked.isEmpty)
            Button("Not now") { m.proposals.dismiss(id: p.id); ticked = []; m.pending = nil }
            Text("Deleted items go to Recently Deleted in Photos for 30 days.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
