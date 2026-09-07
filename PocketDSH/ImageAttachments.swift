import Foundation
import ImageIO
import UniformTypeIdentifiers

struct OutgoingImage: Identifiable, Codable, Equatable {
    let id: UUID
    let data: Data
    let mediaType: String
    let name: String
    var part: JSON { .object(["type": .string("image"), "mediaType": .string(mediaType), "data": .string(data.base64EncodedString()), "name": .string(name)]) }
}
struct ImageLimits: Equatable {
    var maxBytes = 5 * 1024 * 1024
    var maxCount = 4
    var maxTotalBytes = 16 * 1024 * 1024
    var maxDimension = 2048
    var maxPixels = 2048 * 2048
    var mediaTypes = ["image/jpeg", "image/png"]
    init(_ value: JSON = .null) {
        if value["maxImageBytes"].int > 0 { maxBytes = min(maxBytes, value["maxImageBytes"].int) }
        if value["maxImagesPerMessage"].int > 0 { maxCount = min(maxCount, value["maxImagesPerMessage"].int) }
        if value["maxMessageImageBytes"].int > 0 { maxTotalBytes = min(maxTotalBytes, value["maxMessageImageBytes"].int) }
        if value["maxImageDimension"].int > 0 { maxDimension = min(maxDimension, value["maxImageDimension"].int) }
        if value["maxImagePixels"].int > 0 { maxPixels = min(maxPixels, value["maxImagePixels"].int) }
        if !value["mediaTypes"].array.isEmpty { mediaTypes = value["mediaTypes"].array.map(\.string) }
    }
    func validate(_ images: [OutgoingImage]) throws {
        guard images.count <= maxCount else { throw HarnessError(message: "You can attach up to \(maxCount) images.") }
        guard images.allSatisfy({ $0.data.count <= maxBytes && mediaTypes.contains($0.mediaType) }), images.reduce(0, { $0 + $1.data.count }) <= maxTotalBytes else { throw HarnessError(message: "These images exceed DSH limits. Attach fewer or smaller images.") }
    }
}
enum ImagePreparation {
    // Decode only a bounded thumbnail; remove location/EXIF metadata by encoding a fresh image.
    static func prepare(_ data: Data, name: String, limits: ImageLimits) throws -> OutgoingImage {
        guard data.count <= 64 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw HarnessError(message: "Could not read the image, or the file exceeds 64 MB.") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let hasAlpha = properties?[kCGImagePropertyHasAlpha] as? Bool ?? false
        let isJPEG = limits.mediaTypes.contains("image/jpeg") && !(hasAlpha && limits.mediaTypes.contains("image/png"))
        guard isJPEG || limits.mediaTypes.contains("image/png") else { throw HarnessError(message: "The host does not accept JPEG or PNG.") }
        let format = isJPEG ? UTType.jpeg : UTType.png
        var dimension = min(limits.maxDimension, Int(Double(limits.maxPixels).squareRoot()))
        for _ in 0..<5 {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(1, dimension), kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw HarnessError(message: "This file could not be opened as an image.") }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil) else { throw HarnessError(message: "Could not prepare the image") }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw HarnessError(message: "Could not save the image") }
            if output.length <= min(limits.maxBytes, limits.maxTotalBytes) {
                let filename = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
                return OutgoingImage(id: UUID(), data: output as Data, mediaType: isJPEG ? "image/jpeg" : "image/png", name: (filename.isEmpty ? "image" : filename) + (isJPEG ? ".jpg" : ".png"))
            }
            dimension = max(1, dimension / 2)
        }
        throw HarnessError(message: "Could not resize the image to fit the host’s limits.")
    }
}
