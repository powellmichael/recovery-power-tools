import CoreLocation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FileRecoveryApp

/// Writes a 1x1 JPEG carrying the given EXIF/TIFF/GPS dictionaries.
private func makeJPEG(properties: [CFString: Any]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("meta-test-\(UUID().uuidString).jpg")
    let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    let image = try #require(context?.makeImage())
    let destination = try #require(
        CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

@Suite struct ImageMetadataTests {
    /// GPS stores unsigned degrees plus a hemisphere ref, so S/W must come back
    /// negative — getting this wrong puts the pin in the wrong hemisphere.
    @Test func readsSouthWestCoordinateAsNegative() throws {
        let url = try makeJPEG(properties: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 33.8688,
                kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 151.2093,
                kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any],
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let coordinate = try #require(RecoveryViewModel.imageMetadata(at: url).coordinate)
        #expect(coordinate.latitude == -33.8688)
        #expect(coordinate.longitude == -151.2093)
        #expect(coordinate.label == "33.86880° S, 151.20930° W")
        #expect(coordinate.mapsURL?.absoluteString.contains("ll=-33.8688,-151.2093") == true)
    }

    @Test func readsNorthEastCoordinateAsPositive() throws {
        let url = try makeJPEG(properties: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 48.8584,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 2.2945,
                kCGImagePropertyGPSLongitudeRef: "E",
            ] as [CFString: Any],
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let coordinate = try #require(RecoveryViewModel.imageMetadata(at: url).coordinate)
        #expect(coordinate.latitude == 48.8584)
        #expect(coordinate.longitude == 2.2945)
    }

    /// Models usually already contain the make; "Canon Canon EOS R5" is wrong.
    @Test func doesNotRepeatMakeInsideModel() throws {
        let url = try makeJPEG(properties: [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon",
                kCGImagePropertyTIFFModel: "Canon EOS R5",
            ] as [CFString: Any],
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(RecoveryViewModel.imageMetadata(at: url).camera == "Canon EOS R5")
    }

    @Test func joinsMakeAndModelWhenModelOmitsMake() throws {
        let url = try makeJPEG(properties: [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "NIKON",
                kCGImagePropertyTIFFModel: "D850",
            ] as [CFString: Any],
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(RecoveryViewModel.imageMetadata(at: url).camera == "NIKON D850")
    }

    /// A photo with no EXIF still has dimensions; the optional rows stay absent.
    @Test func omitsAbsentFieldsButKeepsDimensions() throws {
        let url = try makeJPEG(properties: [:])
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = RecoveryViewModel.imageMetadata(at: url)
        #expect(metadata.coordinate == nil)
        #expect(metadata.camera == nil)
        #expect(metadata.pixelSize == "1 x 1")
    }

    @Test func returnsEmptyForNonImageBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-test-\(UUID().uuidString).jpg")
        try Data([UInt8](repeating: 0xAA, count: 64)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(RecoveryViewModel.imageMetadata(at: url).isEmpty)
    }
}
