import Foundation
import Testing
@testable import Clip_Builder

/// Music-library folders: moving items between folders and scoping the
/// Wizard's music choice to one folder.
@Suite("Asset library folders", .serialized)
struct AssetLibraryFoldersTests {
    private func makeLibrary() throws -> (scope: DataFolderOverride, root: URL) {
        let scope = try DataFolderOverride()
        AssetStore.ensureRoots()
        let root = AssetKind.music.rootURL
        for relative in ["Intro.mp3", "Fights/Heavy.mp3", "Fights/Loud.wav", "Fights/Slow/Calm.m4a", "Calm/Soft.mp3"] {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        AssetStore.invalidateCatalog()
        return (scope, root)
    }

    @Test("folder scoping keeps only tracks under the folder, subfolders included, case-insensitively")
    func scopedMusic() throws {
        let library = try makeLibrary()
        defer { withExtendedLifetime(library.scope) {} }

        #expect(WizardEngine.availableMusic().map(\.name) == ["Calm/Soft", "Fights/Heavy", "Fights/Loud", "Fights/Slow/Calm", "Intro"])
        #expect(WizardEngine.availableMusic(inFolder: "fights").map(\.name) == ["Fights/Heavy", "Fights/Loud", "Fights/Slow/Calm"])
        #expect(WizardEngine.availableMusic(inFolder: "Fights/Slow").map(\.name) == ["Fights/Slow/Calm"])
        #expect(WizardEngine.availableMusic(inFolder: nil).count == 5)
        #expect(WizardEngine.availableMusic(inFolder: "").count == 5)
        #expect(WizardEngine.availableMusic(inFolder: "Nope").isEmpty)
    }

    @Test("populated folders come from the catalog; every folder on disk feeds Move to…")
    func folderNames() throws {
        let library = try makeLibrary()
        defer { withExtendedLifetime(library.scope) {} }

        #expect(WizardEngine.musicFolders() == ["Calm", "Fights", "Fights/Slow"])
        // Synchronous on purpose: the data-folder override is process-global and
        // other suites swap it during any await, which moved the root under the
        // async accessor mid-test. folderNamesAsync is this same composition.
        let names = AssetStore.folders(of: .music).subtracting([library.root])
            .map { AssetStore.relativeFolderName($0, of: .music) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #expect(names == ["Calm", "Empty", "Fights", "Fights/Slow"])
        #expect(AssetStore.relativeFolderName(library.root, of: .music) == "")
        #expect(AssetStore.relativeFolderName(library.root.appendingPathComponent("Fights/Slow"), of: .music) == "Fights/Slow")
    }

    @Test("folder names resolve exactly, then by unique last component")
    func resolveFolder() throws {
        let library = try makeLibrary()
        defer { withExtendedLifetime(library.scope) {} }

        #expect(AssetStore.resolveFolderName("fights/slow", of: .music) == "Fights/Slow")
        #expect(AssetStore.resolveFolderName("slow", of: .music) == "Fights/Slow")
        #expect(AssetStore.resolveFolderName(" Calm ", of: .music) == "Calm")
        #expect(AssetStore.resolveFolderName("Empty", of: .music) == nil)
        #expect(AssetStore.resolveFolderName("", of: .music) == nil)
    }

    @Test("music groups by immediate folder with the root first")
    func groupedMusic() throws {
        let library = try makeLibrary()
        defer { withExtendedLifetime(library.scope) {} }

        let groups = WizardEngine.musicByFolder()
        #expect(groups.map(\.folder) == ["", "Calm", "Fights", "Fights/Slow"])
        #expect(groups[2].tracks.map(\.name) == ["Fights/Heavy", "Fights/Loud"])
    }

    @Test("moving a file renames on collision and moving into the same folder is a no-op")
    func moveFile() throws {
        let library = try makeLibrary()
        defer { withExtendedLifetime(library.scope) {} }
        let root = library.root

        let calm = AssetItem(url: root.appendingPathComponent("Fights/Slow/Calm.m4a"), isFolder: false)
        let moved = try AssetStore.move(calm, into: root.appendingPathComponent("Calm"))
        #expect(moved.lastPathComponent == "Calm.m4a")
        #expect(WizardEngine.availableMusic(inFolder: "Calm").map(\.name) == ["Calm/Calm", "Calm/Soft"])

        let soft = AssetItem(url: root.appendingPathComponent("Calm/Soft.mp3"), isFolder: false)
        #expect(try AssetStore.move(soft, into: root.appendingPathComponent("Calm")) == soft.url)

        try Data("y".utf8).write(to: root.appendingPathComponent("Soft.mp3"))
        let collided = try AssetStore.move(soft, into: root)
        #expect(collided.lastPathComponent == "Soft 2.mp3")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Soft.mp3").path))
    }

    @Test("moving a folder carries its tree and refuses its own subtree")
    func moveFolder() throws {
        let library = try makeLibrary()
        defer { withExtendedLifetime(library.scope) {} }
        let root = library.root

        let fights = AssetItem(url: root.appendingPathComponent("Fights"), isFolder: true)
        #expect(throws: AssetStore.MoveError.self) {
            try AssetStore.move(fights, into: root.appendingPathComponent("Fights/Slow"))
        }
        #expect(throws: AssetStore.MoveError.self) {
            try AssetStore.move(fights, into: root.appendingPathComponent("Fights"))
        }

        try AssetStore.move(fights, into: root.appendingPathComponent("Calm"))
        #expect(WizardEngine.availableMusic(inFolder: "Calm/Fights").map(\.name)
                == ["Calm/Fights/Heavy", "Calm/Fights/Loud", "Calm/Fights/Slow/Calm"])
        #expect(WizardEngine.musicFolders() == ["Calm", "Calm/Fights", "Calm/Fights/Slow"])
    }

    @Test("wizard options round-trip the music folder and the saved default validates it")
    func optionsAndDefaults() throws {
        let library = try makeLibrary()
        defer { withExtendedLifetime(library.scope) {} }

        var options = WizardOptions()
        options.musicFolder = "Fights"
        let data = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(WizardOptions.self, from: data).musicFolder == "Fights")

        let defaults = try #require(UserDefaults(suiteName: "AssetLibraryFoldersTests-\(UUID().uuidString)"))
        #expect(WizardDefaults.musicFolder(defaults: defaults) == nil)
        defaults.set("fights", forKey: WizardDefaults.musicFolderKey)
        #expect(WizardDefaults.musicFolder(defaults: defaults) == "Fights")
        defaults.set("Gone", forKey: WizardDefaults.musicFolderKey)
        #expect(WizardDefaults.musicFolder(defaults: defaults) == nil)
    }
}
