import Foundation

/// Caches the last shaped Home screen to disk so the next launch paints real
/// content immediately instead of a skeleton.
///
/// This is the "instant" half of the launch: the snapshot is a few hundred
/// cards of already-shaped text + artwork URLs (tens of KB), so it decodes in
/// a couple of milliseconds — long before the first database query would have
/// returned. The live rebuild then replaces it in the background.
///
/// Only presentation data lives here. Nothing in it is authoritative: a stale
/// card that no longer exists just fails to resolve when tapped, and the fresh
/// build corrects the screen a moment later.
enum HomeSnapshotStore {

    /// Bump when `HomeContent`'s shape changes so old files are ignored.
    /// v2: `HomeCard.isNew`.
    /// v3: `HomeRow.style`.
    private static let version = 3

    private struct Envelope: Codable {
        let version: Int
        let providerID: String
        let savedAt: Date
        let content: HomeContent
    }

    private static var url: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("AeriaCatalog", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("home-snapshot.json")
    }

    /// A snapshot is a few hundred cards; anything larger is a bug, and reading
    /// it on the main thread would cost more than it saves.
    private static let sizeLimit = 2 * 1024 * 1024

    /// The cached screen for `providerID`, if one was saved by this app version.
    ///
    /// Read synchronously on the main actor by design — it is the first frame,
    /// and a few milliseconds of `Data(contentsOf:)` beats a skeleton.
    static func load(providerID: String) -> HomeContent? {
        guard let url, let data = try? Data(contentsOf: url), data.count <= sizeLimit else { return nil }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == version,
              envelope.providerID == providerID,
              !envelope.content.isEmpty
        else { return nil }
        return envelope.content
    }

    static func save(_ content: HomeContent, providerID: String) {
        guard let url, !content.isEmpty else { return }
        let envelope = Envelope(version: version, providerID: providerID,
                                savedAt: Date(), content: content)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
