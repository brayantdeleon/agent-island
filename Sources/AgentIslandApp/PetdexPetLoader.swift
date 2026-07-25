import AppKit
import Foundation

struct PetdexPetPackage: Equatable {
    let slug: String
    let displayName: String
    let spriteVersionNumber: Int
    let spritesheetURL: URL
}

enum PetdexPetLoader {
    private static let maximumManifestBytes = 64 * 1024
    private static let maximumSpritesheetBytes = 32 * 1024 * 1024
    private static let columns = 8
    private static let runningRow = 7
    private static let runningFrameCount = 6

    private struct ActiveSelection: Decodable {
        let slug: String
    }

    private struct PetManifest: Decodable {
        let id: String?
        let displayName: String?
        let spriteVersionNumber: Int?
        let spritesheetPath: String?
    }

    static func selectedPackage(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> PetdexPetPackage? {
        let roots = [
            homeDirectory.appending(path: ".petdex/pets", directoryHint: .isDirectory),
            homeDirectory.appending(path: ".codex/pets", directoryHint: .isDirectory),
        ]

        if let selectedSlug = selectedSlug(homeDirectory: homeDirectory),
           let package = package(slug: selectedSlug, roots: roots, fileManager: fileManager) {
            return package
        }

        let installedSlugs = Set(roots.flatMap { root in
            (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ))?.compactMap { candidate -> String? in
                guard (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    return nil
                }
                return isValidSlug(candidate.lastPathComponent) ? candidate.lastPathComponent : nil
            } ?? []
        }).sorted()

        for slug in installedSlugs {
            if let package = package(slug: slug, roots: roots, fileManager: fileManager) {
                return package
            }
        }
        return nil
    }

    static func runningFrames(for package: PetdexPetPackage) -> [CGImage] {
        guard let values = try? package.spritesheetURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumSpritesheetBytes,
              let image = NSImage(contentsOf: package.spritesheetURL),
              let atlas = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              atlas.width % columns == 0 else {
            return []
        }

        let rows = package.spriteVersionNumber >= 2 ? 11 : 9
        guard atlas.height % rows == 0, runningRow < rows else {
            return []
        }

        let cellWidth = atlas.width / columns
        let cellHeight = atlas.height / rows
        return (0..<runningFrameCount).compactMap { column in
            atlas.cropping(to: CGRect(
                x: column * cellWidth,
                y: runningRow * cellHeight,
                width: cellWidth,
                height: cellHeight
            ))
        }
    }

    static func selectedRunningFrames(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [CGImage] {
        guard let package = selectedPackage(homeDirectory: homeDirectory, fileManager: fileManager) else {
            return []
        }
        return runningFrames(for: package)
    }

    private static func selectedSlug(homeDirectory: URL) -> String? {
        let activeURL = homeDirectory.appending(path: ".petdex/active.json")
        guard let data = try? Data(contentsOf: activeURL, options: [.mappedIfSafe]),
              data.count <= maximumManifestBytes,
              let selection = try? JSONDecoder().decode(ActiveSelection.self, from: data),
              isValidSlug(selection.slug) else {
            return nil
        }
        return selection.slug
    }

    private static func package(
        slug: String,
        roots: [URL],
        fileManager: FileManager
    ) -> PetdexPetPackage? {
        guard isValidSlug(slug) else { return nil }

        for root in roots {
            let directory = root.appending(path: slug, directoryHint: .isDirectory)
            let manifestURL = directory.appending(path: "pet.json")
            guard let manifestData = try? Data(contentsOf: manifestURL, options: [.mappedIfSafe]),
                  manifestData.count <= maximumManifestBytes,
                  let manifest = try? JSONDecoder().decode(PetManifest.self, from: manifestData) else {
                continue
            }

            let spriteName = validatedSpriteName(manifest.spritesheetPath)
                ?? ["spritesheet.webp", "spritesheet.png"].first(where: {
                    fileManager.fileExists(atPath: directory.appending(path: $0).path)
                })
            guard let spriteName else { continue }

            let spritesheetURL = directory.appending(path: spriteName)
            guard fileManager.fileExists(atPath: spritesheetURL.path) else { continue }

            return PetdexPetPackage(
                slug: slug,
                displayName: manifest.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? manifest.id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? slug,
                spriteVersionNumber: manifest.spriteVersionNumber == 2 ? 2 : 1,
                spritesheetURL: spritesheetURL
            )
        }
        return nil
    }

    private static func validatedSpriteName(_ path: String?) -> String? {
        guard let path,
              path == URL(fileURLWithPath: path).lastPathComponent,
              path == "spritesheet.webp" || path == "spritesheet.png" else {
            return nil
        }
        return path
    }

    private static func isValidSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.count <= 128 else { return false }
        return slug.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
                || value == 45
                || value == 95
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
