import SwiftUI
import UIKit
import ImageIO
import CryptoKit

/// Decoded `UIImage`s kept in memory for instant redisplay while scrolling.
/// Split out of the actor so views can read it synchronously; `NSCache` is
/// itself thread-safe.
/// How large an image needs to actually be decoded, by where it's shown.
///
/// This is the single biggest lever on scroll smoothness: a poster renders at
/// 258 pt (≈516 px at 2×), so decoding it at 900 px was three times the pixels
/// for no visible gain — 4.9 MB of bitmap instead of 1.7 MB. A channel logo sits
/// in a 300×169 card and Live TV shows 90 of them per page.
public enum ImageSize: Int, Sendable {
    /// Channel logos, cast portraits, small chips.
    case logo = 320
    /// Poster cards, episode stills, history rows.
    case poster = 560
    /// The Home hero and detail backdrops — full-bleed, so worth the pixels.
    case backdrop = 1280
}

final class DecodedImageMemoryCache: @unchecked Sendable {
    static let shared = DecodedImageMemoryCache()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        // Sized against the *decoded* footprint above: a 560 px poster is
        // ~1.7 MB, a logo ~0.2 MB. 64 MB therefore holds a couple of screens of
        // posters plus every logo on a Live TV page — where the old 40-item cap
        // couldn't even hold one screen, so scrolling back always re-decoded.
        // The raw bytes stay on disk, so an eviction costs a decode, never a
        // download. NSCache drops everything on a system memory warning.
        c.totalCostLimit = 64 * 1024 * 1024
        c.countLimit = 140
        return c
    }()

    private static func key(_ url: URL, _ size: ImageSize) -> NSString {
        "\(size.rawValue)|\(url.absoluteString)" as NSString
    }

    func image(for url: URL, size: ImageSize) -> UIImage? {
        cache.object(forKey: Self.key(url, size))
    }

    func store(_ image: UIImage, for url: URL, size: ImageSize) {
        cache.setObject(image, forKey: Self.key(url, size), cost: image.estimatedBytes)
    }

    func removeAll() { cache.removeAllObjects() }
}

/// Bounds how many images decode concurrently. A fast scroll or a rebuild storm
/// can otherwise kick off dozens of `CGImageSourceCreateThumbnail` calls at
/// once, each holding a multi-MB uncompressed bitmap — enough to jetsam the app
/// on device. A small permit count keeps the transient decode footprint flat.
actor DecodeLimiter {
    static let shared = DecodeLimiter(permits: 3)

    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) { self.available = permits }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}

/// Two-tier image cache: decoded images in memory (`DecodedImageMemoryCache`)
/// and raw bytes on disk (survives relaunch, no re-download). `AsyncImage` does
/// neither, which is why a 40k-poster grid felt slow.
actor ImageCache {
    static let shared = ImageCache()

    private let directory: URL
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    init() {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)) ?? URL.temporaryDirectory
        directory = base.appendingPathComponent("PosterImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config)

        // Crude cap: if the on-disk cache has grown past ~350 MB, wipe it.
        // Walking thousands of files is slow, and `init` runs on whichever
        // thread first asks for an image — usually the first poster on screen —
        // so the check runs in the background a little after launch instead.
        let dir = directory
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(20))
            if let size = try? FileManager.default.allocatedSizeOfDirectory(at: dir),
               size > 350 * 1024 * 1024 {
                try? FileManager.default.removeItem(at: dir)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    /// URLs that came back 404 / unreachable, and when. Provider artwork is full
    /// of dead links; without this every scroll past a broken poster fires the
    /// request again, competing with the images that *do* load.
    ///
    /// Bounded — a provider with tens of thousands of dead logos would otherwise
    /// grow this forever. When it fills, the oldest half goes; the worst case is
    /// that a long-dead URL gets retried once more.
    private var failures: [String: Date] = [:]
    private static let failureCooldown: TimeInterval = 10 * 60
    private static let failureLimit = 600

    private func noteFailure(_ key: String) {
        if failures.count >= Self.failureLimit {
            let keep = failures.sorted { $0.value > $1.value }.prefix(Self.failureLimit / 2)
            failures = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        failures[key] = Date()
    }

    func image(for url: URL, size: ImageSize = .poster) async -> UIImage? {
        if let hit = DecodedImageMemoryCache.shared.image(for: url, size: size) { return hit }

        let urlKey = url.absoluteString
        if let failedAt = failures[urlKey] {
            if Date().timeIntervalSince(failedAt) < Self.failureCooldown { return nil }
            failures[urlKey] = nil
        }

        // Keyed by size: two shelves wanting the same poster at different sizes
        // share the download but not the decode.
        let key = "\(size.rawValue)|\(urlKey)"
        if let running = inFlight[key] { return await running.value }

        let dir = directory
        let session = self.session
        // Detached on purpose: a plain `Task {}` here inherits this actor, which
        // ran every disk read and decode for every image one at a time on the
        // actor's single executor — posters filled in one by one even when all
        // of them were already on disk. Detached, they load in parallel, with
        // `DecodeLimiter` (finally effective) capping the concurrent decodes.
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            // Raw bytes on disk are keyed by URL alone, so switching size never
            // re-downloads.
            let fileURL = dir.appendingPathComponent(Self.filename(for: url))
            var bytes = try? Data(contentsOf: fileURL)
            if bytes == nil {
                if let (data, response) = try? await session.data(from: url),
                   let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) {
                    bytes = data
                    try? data.write(to: fileURL, options: .atomic)
                }
            }
            guard let bytes else { return nil }

            // Gate the expensive part — the decode holds a big uncompressed bitmap.
            await DecodeLimiter.shared.acquire()
            let image = Self.decode(bytes, maxPixel: size.rawValue)
            await DecodeLimiter.shared.release()
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            DecodedImageMemoryCache.shared.store(image, for: url, size: size)
        } else {
            noteFailure(urlKey)
        }
        return image
    }

    /// Warm the cache for URLs about to scroll into view. Bounded to a couple of
    /// workers so a big grid doesn't spawn hundreds of concurrent decodes.
    nonisolated func prefetch(_ urls: [URL], size: ImageSize = .poster) {
        let pending = urls.filter { DecodedImageMemoryCache.shared.image(for: $0, size: size) == nil }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var it = pending.makeIterator()
                let workers = min(2, pending.count)
                for _ in 0 ..< workers {
                    if let u = it.next() { group.addTask { _ = await ImageCache.shared.image(for: u, size: size) } }
                }
                while await group.next() != nil {
                    if let u = it.next() { group.addTask { _ = await ImageCache.shared.image(for: u, size: size) } }
                }
            }
        }
    }

    /// Drop the in-memory decoded images (e.g. on a memory warning).
    nonisolated func flushMemory() {
        DecodedImageMemoryCache.shared.removeAll()
    }

    // MARK: - Helpers

    /// Downsample to the size the view actually renders at. Provider artwork is
    /// frequently many megapixels; this is where that gets paid for exactly once.
    private static func decode(_ data: Data, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        // Fallback: plain decode, forced off the main thread.
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    private static func filename(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension UIImage {
    var estimatedBytes: Int {
        guard let cg = cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}

private extension FileManager {
    func allocatedSizeOfDirectory(at url: URL) throws -> Int {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            total += values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
        }
        return total
    }
}

/// Drop-in replacement for `AsyncImage` backed by `ImageCache`. Shows `fallback`
/// while loading and if the load fails.
struct CachedImage<Fallback: View>: View {
    private let url: URL?
    private let contentMode: ContentMode
    private let size: ImageSize
    private let fallback: () -> Fallback

    @State private var image: UIImage?
    @State private var didFail = false

    init(url: URL?, contentMode: ContentMode = .fill, size: ImageSize = .poster,
         @ViewBuilder fallback: @escaping () -> Fallback) {
        self.url = url
        self.contentMode = contentMode
        self.size = size
        self.fallback = fallback
    }

    /// A cache hit must render on the very first frame — going through `.task`
    /// would blank the cell for a frame and make a fast scroll flicker.
    private var cached: UIImage? {
        guard let url else { return nil }
        return DecodedImageMemoryCache.shared.image(for: url, size: size)
    }

    var body: some View {
        ZStack {
            if let shown = image ?? cached {
                Image(uiImage: shown).resizable().aspectRatio(contentMode: contentMode)
            } else if didFail {
                fallback()
            }
        }
        .task(id: taskID) {
            didFail = false
            guard let url else { image = nil; return }
            if let hit = DecodedImageMemoryCache.shared.image(for: url, size: size) {
                image = hit
                return
            }
            image = nil
            let loaded = await ImageCache.shared.image(for: url, size: size)
            guard !Task.isCancelled else { return }
            // Only cross-fade a genuine load; a cache hit is already on screen.
            withAnimation(.easeOut(duration: 0.22)) {
                image = loaded
                didFail = loaded == nil
            }
        }
    }

    private var taskID: String { "\(size.rawValue)|\(url?.absoluteString ?? "")" }
}

extension CachedImage where Fallback == Color {
    init(url: URL?, contentMode: ContentMode = .fill, size: ImageSize = .poster) {
        self.init(url: url, contentMode: contentMode, size: size, fallback: { Color.clear })
    }
}
