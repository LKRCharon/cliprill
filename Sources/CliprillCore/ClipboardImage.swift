// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Snapshots contain only this immutable reference, never base64 image data.
public struct ClipboardImage: Codable, Sendable, Equatable {
    public let id: String
    public let width: Int
    public let height: Int
    public let byteCount: Int
    public var metadata: JSONValue {
        .object(["id": .string(id), "width": .integer(width), "height": .integer(height),
                 "byte_count": .integer(byteCount), "media_type": .string("image/png")])
    }
}

public struct PreparedClipboardImage: Sendable {
    public static let maxInputBytes = 128 * 1024 * 1024
    public static let maxPNGBytes = 64 * 1024 * 1024
    public static let maxPixels = 40_000_000
    public let image: ClipboardImage
    public let png: Data
    public let thumbnail: Data

    /// Call off the main actor. Normalize orientation and retain full-resolution alpha.
    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maxInputBytes else {
            throw CoreError("image_size", "The copied image exceeds the 128 MiB input limit.")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= Self.maxPixels / height else {
            throw CoreError("invalid_image", "The copied image is unreadable or exceeds 40 megapixels.")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CoreError("invalid_image", "The copied image could not be decoded.")
        }
        png = try Self.encode(decoded, type: UTType.png.identifier)
        guard png.count <= Self.maxPNGBytes else { throw CoreError("image_size", "The normalized image exceeds 64 MiB.") }
        var thumbOptions = options; thumbOptions[kCGImageSourceThumbnailMaxPixelSize] = 128
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            throw CoreError("invalid_image", "The image thumbnail could not be created.")
        }
        thumbnail = try Self.encode(thumb, type: UTType.png.identifier)
        image = ClipboardImage(id: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
                               width: decoded.width, height: decoded.height, byteCount: png.count)
    }
    public static func tiff(fromPNG data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CoreError("invalid_image", "The saved image could not be decoded.")
        }
        return try encode(image, type: UTType.tiff.identifier)
    }
    private static func encode(_ image: CGImage, type: String) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw CoreError("invalid_image", "An image encoder is unavailable.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CoreError("invalid_image", "The image could not be encoded.") }
        return data as Data
    }
}
