import AppKit
import ImageIO
import UniformTypeIdentifiers

struct DraftAttachment: Identifiable {
    let id = UUID()
    var filename: String
    var mime: String
    var data: Data
    var thumbnail: NSImage
}

enum ImageTools {
    /// Jira's default attachment limit is 10 MB.
    static let maxUploadBytes = 9_000_000

    /// Images on a pasteboard: image files (copied in Finder) or raw image data (screenshots).
    static func attachments(from pb: NSPasteboard) -> [DraftAttachment] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty {
            let files = urls.compactMap { attachment(fromFile: $0) }
            if !files.isEmpty { return files }
        }
        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let first = images.first, let a = attachment(from: first) {
            return [a]
        }
        return []
    }

    static func attachment(fromFile url: URL) -> DraftAttachment? {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        if data.count > maxUploadBytes, let jpeg = jpeg(from: image, quality: 0.85) {
            let name = url.deletingPathExtension().lastPathComponent + ".jpg"
            return DraftAttachment(filename: name, mime: "image/jpeg", data: jpeg, thumbnail: thumbnail(of: image))
        }
        return DraftAttachment(
            filename: url.lastPathComponent,
            mime: type?.preferredMIMEType ?? "application/octet-stream",
            data: data, thumbnail: thumbnail(of: image)
        )
    }

    static func attachment(from image: NSImage) -> DraftAttachment? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = "screenshot-\(stamp.string(from: Date()))"
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        if let png = rep.representation(using: .png, properties: [:]), png.count <= maxUploadBytes {
            return DraftAttachment(filename: base + ".png", mime: "image/png", data: png, thumbnail: thumbnail(of: image))
        }
        guard let jpg = jpeg(from: image, quality: 0.85) else { return nil }
        return DraftAttachment(filename: base + ".jpg", mime: "image/jpeg", data: jpg, thumbnail: thumbnail(of: image))
    }

    static func jpeg(from image: NSImage, quality: CGFloat) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Smaller JPEG for the vision model (keeps requests fast and cheap).
    static func jpegForAI(_ data: Data, maxDimension: Int = 1280) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    static func thumbnail(of image: NSImage, side: CGFloat = 64) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = side / max(size.width, size.height)
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let out = NSImage(size: target)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}
