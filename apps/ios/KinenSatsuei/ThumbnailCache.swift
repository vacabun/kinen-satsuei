import AVFoundation
import ImageIO

struct MediaThumbnail: Sendable {
    var image: CGImage?
    var seconds: Int?
    var cacheable = true
}

actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private final class CachedImage: NSObject {
        let value: MediaThumbnail
        init(_ value: MediaThumbnail) { self.value = value }
    }

    private let cache = NSCache<NSString, CachedImage>()
    private struct Work {
        let generation: UUID
        let task: Task<MediaThumbnail, Never>
        var readers: Set<UUID>
    }

    private var pending: [String: Work] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 240
    }

    func image(at url: URL, fallback: URL?, pixels: Int, contentID: String?) async -> CGImage? {
        let key = "image|\(pixels)|\(contentID ?? "")|\(url.absoluteString)|\(fallback?.absoluteString ?? "")"
        return await load(key) {
            let image = Self.decode(CGImageSourceCreateWithURL(url as CFURL, nil), pixels: pixels)
            let fallbackImage = image == nil ? fallback.flatMap {
                Self.decode(CGImageSourceCreateWithURL($0 as CFURL, nil), pixels: pixels)
            } : nil
            return MediaThumbnail(image: image ?? fallbackImage, cacheable: image != nil)
        }.image
    }

    func avatar(_ data: Data, pixels: Int, identity: String?) async -> CGImage? {
        let key = "avatar|\(pixels)|\(identity ?? String(data.hashValue))"
        return await load(key) {
            MediaThumbnail(image: Self.decode(CGImageSourceCreateWithData(data as CFData, nil), pixels: pixels))
        }.image
    }

    func video(at url: URL, filenameExtension: String) async -> MediaThumbnail {
        await load("video|\(filenameExtension)|" + url.absoluteString) {
            var playbackURL = url
            if url.pathExtension.isEmpty, !filenameExtension.isEmpty {
                let temporary = URL.temporaryDirectory.appending(path: UUID().uuidString)
                    .appendingPathExtension(filenameExtension)
                if (try? FileManager.default.linkItem(at: url, to: temporary)) != nil {
                    playbackURL = temporary
                }
            }
            defer {
                if playbackURL != url { try? FileManager.default.removeItem(at: playbackURL) }
            }
            let asset = AVURLAsset(url: playbackURL)
            let duration = try? await asset.load(.duration).seconds
            let seconds = duration.flatMap {
                $0.isFinite && $0 >= 0 && $0 <= Double(Int32.max) ? Int($0.rounded(.down)) : nil
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            let image = try? await generator.image(at: .zero).image
            return MediaThumbnail(image: image, seconds: seconds)
        }
    }

    private func load(_ key: String, produce: @escaping @Sendable () async -> MediaThumbnail) async -> MediaThumbnail {
        if let value = cache.object(forKey: key as NSString)?.value { return value }
        let reader = UUID()
        let work: Work
        if var existing = pending[key] {
            existing.readers.insert(reader)
            pending[key] = existing
            work = existing
        } else {
            let task = Task.detached(priority: .utility) {
                await self.reserve()
                let value = Task.isCancelled ? MediaThumbnail() : await produce()
                await self.release()
                return value
            }
            work = Work(generation: UUID(), task: task, readers: [reader])
            pending[key] = work
        }
        let value = await withTaskCancellationHandler {
            await work.task.value
        } onCancel: {
            Task { await self.cancelReader(reader, for: key, generation: work.generation) }
        }
        if pending[key]?.generation == work.generation {
            if let image = value.image, value.cacheable {
                cache.setObject(CachedImage(value), forKey: key as NSString, cost: image.bytesPerRow * image.height)
            }
            pending[key] = nil
        }
        return value
    }

    private func cancelReader(_ reader: UUID, for key: String, generation: UUID) {
        guard var work = pending[key], work.generation == generation else { return }
        work.readers.remove(reader)
        if work.readers.isEmpty {
            work.task.cancel()
            pending[key] = nil
        } else {
            pending[key] = work
        }
    }

    private func reserve() async {
        if active < 3 { active += 1 }
        else { await withCheckedContinuation { waiting.append($0) } }
    }

    private func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().resume() }
    }

    private static func decode(_ source: CGImageSource?, pixels: Int) -> CGImage? {
        guard let source else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ] as CFDictionary)
    }
}
