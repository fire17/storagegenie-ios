import Foundation
import Photos
import StorageGenieCore

/// What iOS lets an app see: the Photos library (incl. media WhatsApp saved there), sized per asset.
/// Deletion goes ONLY through `PHAssetChangeRequest.deleteAssets` = Apple's own confirm sheet → "Recently Deleted"
/// (restorable 30 days). There is no way to delete silently, and this file never tries.
final class PhotosLibrary: MediaLibrary {
    var hasAccess: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in done(s == .authorized || s == .limited) }
    }

    var totalBytes: Int64 { volume(.volumeTotalCapacityKey) }
    var freeBytes: Int64 { volume(.volumeAvailableCapacityForImportantUsageKey) }

    private func volume(_ key: URLResourceKey) -> Int64 {
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [key])
        if key == .volumeTotalCapacityKey { return Int64(v?.volumeTotalCapacity ?? 0) }
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func scan(top: Int) throws -> [MediaItem] {
        var items: [MediaItem] = []
        let all = PHAsset.fetchAssets(with: nil)
        all.enumerateObjects { asset, _, _ in
            // fileSize is the documented-but-unofficial key everyone uses; missing → 0 (sorted last, never guessed).
            let res = PHAssetResource.assetResources(for: asset)
            let bytes = res.reduce(Int64(0)) { $0 + ((($1.value(forKey: "fileSize") as? NSNumber)?.int64Value) ?? 0) }
            let name = res.first?.originalFilename ?? asset.localIdentifier
            let kind = asset.mediaType == .video ? "video" : asset.mediaType == .image ? "image" : "audio"
            items.append(MediaItem(id: asset.localIdentifier, name: name, bytes: bytes, kind: kind, date: asset.creationDate))
        }
        return Array(items.sorted { $0.bytes > $1.bytes }.prefix(top))
    }

    /// The person ticked [ids] and tapped Delete. Apple shows its sheet; on Cancel nothing changes.
    func delete(ids: [String], done: @escaping (_ deleted: [String], _ freed: Int64) -> Void) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var freed: Int64 = 0
        var found: [String] = []
        assets.enumerateObjects { a, _, _ in
            found.append(a.localIdentifier)
            freed += PHAssetResource.assetResources(for: a)
                .reduce(Int64(0)) { $0 + ((($1.value(forKey: "fileSize") as? NSNumber)?.int64Value) ?? 0) }
        }
        PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.deleteAssets(assets) }) { ok, _ in
            DispatchQueue.main.async { ok ? done(found, freed) : done([], 0) }
        }
    }
}
