import Foundation
import AVFoundation
import AppKit

// MARK: - Video Thumbnail Generation Helper

private struct VideoThumbnail: Identifiable {
    let id = UUID()
    let filename: String
    let data: Data
    let mime: String
}

@MainActor
private func generateVideoThumbnails(url: URL, maxDimension: CGFloat, count: Int) async -> [(filename: String, data: Data, mime: String)] {
    // Guard against invalid count
    let desiredCount = max(1, min(count, 8))

    let asset = AVURLAsset(url: url)
    let duration: CMTime
    do {
        duration = try await asset.load(.duration)
    } catch {
        return []
    }
    let totalSeconds = CMTimeGetSeconds(duration)
    guard totalSeconds.isFinite && totalSeconds > 0 else { return [] }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
    generator.requestedTimeToleranceAfter = CMTime.zero
    generator.requestedTimeToleranceBefore = CMTime.zero

    // Pick evenly spaced times across the duration
    var times: [NSValue] = []
    for i in 1...desiredCount {
        let t = CMTime(seconds: (Double(i) / Double(desiredCount + 1)) * totalSeconds, preferredTimescale: 600)
        times.append(NSValue(time: t))
    }

    // Generate thumbnails off the main actor to avoid blocking UI
    let results: [(String, Data, String)] = await withTaskGroup(of: (String, Data, String)?.self) { group in
        for (index, value) in times.enumerated() {
            group.addTask {
                do {
                    let cgImage: CGImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                        generator.generateCGImageAsynchronously(for: value.timeValue) { image, actualTime, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let image { continuation.resume(returning: image) }
                            else {
                                // Construct a reasonable error if neither image nor error is provided
                                continuation.resume(throwing: NSError(domain: "AVAssetImageGenerator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate CGImage asynchronously"]))
                            }
                        }
                    }

                    let nsImage = NSImage(cgImage: cgImage, size: .zero)

                    // Encode as JPEG with reasonable compression
                    guard let tiff = nsImage.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let jpeg = rep.representation(using: NSBitmapImageRep.FileType.jpeg, properties: [NSBitmapImageRep.PropertyKey.compressionFactor: 0.8]) else {
                        return nil
                    }

                    let base = url.deletingPathExtension().lastPathComponent
                    let filename = "\(base)_thumb_\(index + 1).jpg"
                    return (filename, jpeg, "image/jpeg")
                } catch {
                    return nil
                }
            }
        }

        var collected: [(String, Data, String)] = []
        for await item in group {
            if let item { collected.append(item) }
        }
        return collected.sorted { $0.0 < $1.0 }
    }

    return results.map { (filename: $0.0, data: $0.1, mime: $0.2) }
}

