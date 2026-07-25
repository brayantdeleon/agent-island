import AppKit
import Foundation
import Testing
@testable import AgentIslandApp

struct PetdexPetLoaderTests {
    @Test
    func selectedPackageUsesPetdexActiveSlugAndCodexPetRoot() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try writePet(slug: "alpha", displayName: "Alpha", home: home)
        try writePet(slug: "null-signal", displayName: "Null Signal", version: 2, home: home)
        let petdex = home.appending(path: ".petdex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: petdex, withIntermediateDirectories: true)
        try Data(#"{"slug":"null-signal"}"#.utf8).write(to: petdex.appending(path: "active.json"))

        let package = PetdexPetLoader.selectedPackage(homeDirectory: home)

        #expect(package?.slug == "null-signal")
        #expect(package?.displayName == "Null Signal")
        #expect(package?.spriteVersionNumber == 2)
        #expect(package?.spritesheetURL.lastPathComponent == "spritesheet.png")
    }

    @Test
    func invalidActiveSlugFallsBackToFirstInstalledPet() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try writePet(slug: "safe-pet", displayName: "Safe Pet", home: home)
        let petdex = home.appending(path: ".petdex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: petdex, withIntermediateDirectories: true)
        try Data(#"{"slug":"../escape"}"#.utf8).write(to: petdex.appending(path: "active.json"))

        #expect(PetdexPetLoader.selectedPackage(homeDirectory: home)?.slug == "safe-pet")
    }

    @Test
    func runningFramesExtractSixFramesFromV2RunningRow() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try writePet(slug: "v2-pet", displayName: "V2 Pet", version: 2, home: home)
        let package = try #require(PetdexPetLoader.selectedPackage(homeDirectory: home))
        let frames = PetdexPetLoader.runningFrames(for: package)

        #expect(frames.count == 6)
        #expect(frames.allSatisfy { $0.width == 2 && $0.height == 2 })
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "agent-island-petdex-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePet(
        slug: String,
        displayName: String,
        version: Int = 1,
        home: URL
    ) throws {
        let directory = home.appending(path: ".codex/pets/\(slug)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = """
        {"id":"\(slug)","displayName":"\(displayName)","spriteVersionNumber":\(version),"spritesheetPath":"spritesheet.png"}
        """
        try Data(manifest.utf8).write(to: directory.appending(path: "pet.json"))

        let rows = version == 2 ? 11 : 9
        let width = 8 * 2
        let height = rows * 2
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(path: "spritesheet.png"))
    }
}
