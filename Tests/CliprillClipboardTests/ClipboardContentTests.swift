// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import AppKit
import CliprillCore
import CliprillClipboard

final class ClipboardContentTests: XCTestCase {
    // Two pixels: half-transparent red and opaque blue. No real clipboard or visible window.
    private func png() throws -> Data {
        let pixels: [UInt8] = [128, 0, 0, 128, 0, 0, 255, 255]
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
    @MainActor func testImagePasteWritesPNGAndTIFFWithOriginalDimensionsAndAlpha() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try ClipboardWrite.text("old clipboard").write(to: board)
        let saved = try PreparedClipboardImage(data: png())
        try ClipboardWrite.image(png: saved.png).write(to: board)
        XCTAssertNil(board.string(forType: .string))
        XCTAssertEqual(board.data(forType: .png), saved.png)
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let data = try XCTUnwrap(board.data(forType: type))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(bitmap.pixelsWide, 2); XCTAssertEqual(bitmap.pixelsHigh, 1)
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 128.0 / 255.0, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 1, y: 0)).blueComponent, 1, accuracy: 0.01)
        }
    }
    @MainActor func testBrowserImageWinsOverAccompanyingURL() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let data = try png(), item = NSPasteboardItem()
        item.setString("https://example.com/photo.png", forType: .string); item.setData(data, forType: .png)
        XCTAssertTrue(board.writeObjects([item]))
        guard case .image(let captured) = ClipboardReader.read(from: board) else { return XCTFail("Expected image") }
        XCTAssertEqual(captured, data)
    }
    @MainActor func testTIFFOnlyCaptureAndTextWriteRemovePreviousImage() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let item = NSPasteboardItem(); item.setData(try PreparedClipboardImage.tiff(fromPNG: png()), forType: .tiff)
        XCTAssertTrue(board.writeObjects([item]))
        guard case .image(let bytes) = ClipboardReader.read(from: board) else { return XCTFail("Expected TIFF capture") }
        let saved = try PreparedClipboardImage(data: bytes)
        XCTAssertEqual(saved.image.width, 2); XCTAssertEqual(saved.image.height, 1)
        try ClipboardWrite.text("after image").write(to: board)
        XCTAssertNil(board.data(forType: .png)); XCTAssertNil(board.data(forType: .tiff))
        guard case .text(let text) = ClipboardReader.read(from: board) else { return XCTFail("Expected text") }
        XCTAssertEqual(text, "after image")
    }
    @MainActor func testConcealedImageIsNotCaptured() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let item = NSPasteboardItem(); item.setData(try png(), forType: .png)
        item.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        XCTAssertTrue(board.writeObjects([item])); XCTAssertNil(ClipboardReader.read(from: board))
    }
}
