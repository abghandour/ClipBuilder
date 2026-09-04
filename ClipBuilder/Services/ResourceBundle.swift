import Foundation

/// What a resource bundle can carry: the Resources libraries, brand
/// profiles, and the Wizard/analysis preferences.
nonisolated enum ResourceCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case music
    case fonts
    case images
    case overlays
    case screenCrops = "screen_crops"
    case profiles
    case preferences

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: "Music"
        case .fonts: "Fonts"
        case .images: "Images"
        case .overlays: "Overlay templates"
        case .screenCrops: "Screen crop layouts"
        case .profiles: "Brand profiles"
        case .preferences: "Wizard & analysis preferences"
        }
    }

    var systemImage: String {
        switch self {
        case .music: "music.note"
        case .fonts: "textformat"
        case .images: "photo.on.rectangle.angled"
        case .overlays: "square.2.layers.3d"
        case .screenCrops: "crop"
        case .profiles: "person.crop.rectangle"
        case .preferences: "slider.horizontal.3"
        }
    }

    /// Folder inside the bundle.
    var folderName: String { rawValue }

    /// Local folder the category's files live in (nil for preferences).
    var localRoot: URL? {
        switch self {
        case .music: AssetKind.music.rootURL
        case .fonts: AssetKind.fonts.rootURL
        case .images: AssetKind.images.rootURL
        case .overlays: OverlayTemplateStore.directory
        case .screenCrops: ScreenCropStore.directory
        case .profiles: ProfileStore.profilesDirectory
        case .preferences: nil
        }
    }

    var allowedExtensions: Set<String>? {
        switch self {
        case .music: AssetKind.music.allowedExtensions
        case .fonts: AssetKind.fonts.allowedExtensions
        case .images: AssetKind.images.allowedExtensions
        case .overlays, .screenCrops, .profiles: ["json"]
        case .preferences: nil
        }
    }

    /// Profiles sit at the top of the ClipBuilder folder next to `assets`
    /// and `data`; only the top-level JSON files are profiles.
    var recursive: Bool { self != .profiles }
}

/// One item counted for export or import.
nonisolated struct ResourceItem: Sendable, Hashable {
    var category: ResourceCategory
    /// Path relative to the category folder (in the bundle and locally).
    var relativePath: String
    var bytes: Int64
}

/// `manifest.json` at the bundle root.
nonisolated struct ResourceManifest: Codable, Sendable {
    var format: Int = 1
    var appVersion: String
    var exportedAt: Date
    var categories: [ResourceCategory]
    var counts: [String: Int]
}

nonisolated enum ResourceImportPolicy: String, CaseIterable, Identifiable, Sendable {
    case skip
    case replace
    case keepBoth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skip: "Skip existing"
        case .replace: "Replace existing"
        case .keepBoth: "Keep both"
        }
    }

    var detail: String {
        switch self {
        case .skip: "Items that already exist here are left untouched."
        case .replace: "Items in the bundle overwrite local items with the same name."
        case .keepBoth: "Conflicting items are imported under a numbered name."
        }
    }
}

/// An unpacked bundle ready to import: where it was extracted, what it
/// declares, and how it compares to the local libraries.
nonisolated struct ResourceBundlePreview: Sendable {
    var sourceURL: URL
    var root: URL
    var manifest: ResourceManifest
    var items: [ResourceCategory: [ResourceItem]]
    var conflicts: [ResourceCategory: Int]
    var preferenceKeys: Int
}

nonisolated struct ResourceImportSummary: Sendable {
    var imported = 0
    var replaced = 0
    var skipped = 0
    var renamed = 0
    var preferencesApplied = 0
    var fontsChanged = false
    var profilesChanged = false
    var screenCropsChanged = false

    var message: String {
        var parts: [String] = []
        if imported > 0 { parts.append("\(imported) added") }
        if replaced > 0 { parts.append("\(replaced) replaced") }
        if renamed > 0 { parts.append("\(renamed) kept alongside existing") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if preferencesApplied > 0 { parts.append("\(preferencesApplied) preferences applied") }
        return parts.isEmpty ? "Nothing to import." : parts.joined(separator: ", ") + "."
    }
}

nonisolated enum ResourceBundleError: LocalizedError {
    case toolFailed(String)
    case noManifest
    case unsupportedFormat(Int)

    var errorDescription: String? {
        switch self {
        case .toolFailed(let output): "Archiving failed: \(output)"
        case .noManifest: "This zip is not a Clip Builder resource bundle (no manifest.json)."
        case .unsupportedFormat(let format): "This bundle uses format \(format), which this version cannot read."
        }
    }
}

/// Export and import of everything under Resources (plus profiles and
/// preferences) as one zip: `ClipBuilder Resources/manifest.json` and one
/// folder per category. Overlay image references and profile logos travel
/// inside the bundle and are re-pointed on import, so a bundle made on one
/// Mac works on another.
nonisolated enum ResourceBundle {
    static let rootFolderName = "ClipBuilder Resources"

    /// Preference keys that describe how the user works (exported); the
    /// selection state tied to one database is left out.
    private static let preferencePrefixes = ["wizard.", "analysis.", "pipeline."]
    private static let excludedPreferenceKeys: Set<String> = [
        "wizard.selectedRunIDs", "wizard.sourcePeople", "wizard.limitToSelection", "wizard.curatedOnly",
    ]

    private static let imageMarker = "$images/"
    private static let bundledImageMarker = "$bundled-images/"
    private static let logoMarker = "$logos/"

    // MARK: - Inventory

    /// Local items per category, for the export dialog.
    static func inventory() -> [ResourceCategory: [ResourceItem]] {
        var result: [ResourceCategory: [ResourceItem]] = [:]
        for category in ResourceCategory.allCases {
            if category == .preferences {
                let count = preferences().count
                result[category] = count == 0 ? [] : [ResourceItem(category: category, relativePath: "preferences.json", bytes: 0)]
                continue
            }
            guard let root = category.localRoot else { continue }
            result[category] = files(in: root, category: category)
        }
        return result
    }

    private static func files(in root: URL, category: ResourceCategory) -> [ResourceItem] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var items: [ResourceItem] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let urls: [URL]
        if category.recursive {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles]) else { return [] }
            urls = enumerator.compactMap { $0 as? URL }
        } else {
            urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        }
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if let allowed = category.allowedExtensions, !allowed.contains(url.pathExtension.lowercased()) { continue }
            var relative = url.path
            if relative.hasPrefix(root.path + "/") { relative = String(relative.dropFirst(root.path.count + 1)) }
            items.append(ResourceItem(category: category, relativePath: relative,
                                      bytes: Int64(values?.fileSize ?? 0)))
        }
        return items.sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
    }

    static func preferences() -> [String: Any] {
        UserDefaults.standard.dictionaryRepresentation().filter { key, value in
            guard preferencePrefixes.contains(where: key.hasPrefix), !excludedPreferenceKeys.contains(key) else {
                return false
            }
            return value is String || value is Bool || value is Int || value is Double
        }
    }

    // MARK: - Export

    static func export(categories: Set<ResourceCategory>, to destination: URL,
                       progress: @escaping @Sendable (String) -> Void) throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb_export_\(UUID().uuidString)", isDirectory: true)
        let root = staging.appendingPathComponent(rootFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var counts: [String: Int] = [:]
        let imagesRoot = AssetKind.images.rootURL
        for category in ResourceCategory.allCases where categories.contains(category) {
            progress("Collecting \(category.title.lowercased())…")
            let folder = root.appendingPathComponent(category.folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            switch category {
            case .music, .fonts, .images, .screenCrops:
                let items = files(in: category.localRoot!, category: category)
                for item in items {
                    let target = folder.appendingPathComponent(item.relativePath)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: category.localRoot!.appendingPathComponent(item.relativePath),
                                                     to: target)
                }
                counts[category.rawValue] = items.count
            case .overlays:
                // Image references leave as bundle-relative markers; images
                // outside the library ride along in `_images`.
                let bundledImages = folder.appendingPathComponent("_images", isDirectory: true)
                var count = 0
                for template in OverlayTemplateStore.list() {
                    var composition = template.composition
                    for index in composition.images.indices {
                        let path = composition.images[index].path
                        guard !path.isEmpty else { continue }
                        let expanded = (path as NSString).expandingTildeInPath
                        if expanded.hasPrefix(imagesRoot.path + "/") {
                            composition.images[index].path = imageMarker + String(expanded.dropFirst(imagesRoot.path.count + 1))
                        } else if FileManager.default.fileExists(atPath: expanded) {
                            try FileManager.default.createDirectory(at: bundledImages, withIntermediateDirectories: true)
                            let name = (expanded as NSString).lastPathComponent
                            let target = bundledImages.appendingPathComponent(name)
                            if !FileManager.default.fileExists(atPath: target.path) {
                                try FileManager.default.copyItem(at: URL(fileURLWithPath: expanded), to: target)
                            }
                            composition.images[index].path = bundledImageMarker + name
                        }
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(composition)
                        .write(to: folder.appendingPathComponent(ProfileStore.sanitize(template.name) + ".json"))
                    count += 1
                }
                counts[category.rawValue] = count
            case .profiles:
                let logos = folder.appendingPathComponent("_logos", isDirectory: true)
                var count = 0
                for var profile in ProfileStore.listProfiles() {
                    if let logo = profile.logoURL, FileManager.default.fileExists(atPath: logo.path) {
                        try FileManager.default.createDirectory(at: logos, withIntermediateDirectories: true)
                        let target = logos.appendingPathComponent(logo.lastPathComponent)
                        if !FileManager.default.fileExists(atPath: target.path) {
                            try FileManager.default.copyItem(at: logo, to: target)
                        }
                        profile.logoPath = logoMarker + logo.lastPathComponent
                    } else {
                        profile.logoPath = ""
                    }
                    // Exemplar frames are derived data on this Mac's disk.
                    profile.tasteExemplarFrames = []
                    for index in profile.tasteCategories.indices {
                        profile.tasteCategories[index].exemplarFrames = []
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(profile)
                        .write(to: folder.appendingPathComponent(ProfileStore.sanitize(profile.profileName) + ".json"))
                    count += 1
                }
                counts[category.rawValue] = count
            case .preferences:
                let values = preferences()
                let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: folder.appendingPathComponent("preferences.json"))
                counts[category.rawValue] = values.count
            }
        }

        let manifest = ResourceManifest(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            exportedAt: Date(),
            categories: ResourceCategory.allCases.filter(categories.contains),
            counts: counts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"))

        progress("Compressing…")
        try? FileManager.default.removeItem(at: destination)
        try runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, destination.path])
    }

    // MARK: - Import

    /// Unpack the zip and compare it with the local libraries. The caller
    /// owns `root` until `discard` is called.
    static func inspect(_ zip: URL) throws -> ResourceBundlePreview {
        let extracted = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb_import_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try runDitto(["-x", "-k", zip.path, extracted.path])
        guard let root = findRoot(in: extracted, depth: 0) else {
            try? FileManager.default.removeItem(at: extracted)
            throw ResourceBundleError.noManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ResourceManifest.self,
                                          from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard manifest.format <= 1 else {
            try? FileManager.default.removeItem(at: extracted)
            throw ResourceBundleError.unsupportedFormat(manifest.format)
        }
        var items: [ResourceCategory: [ResourceItem]] = [:]
        var conflicts: [ResourceCategory: Int] = [:]
        var preferenceKeys = 0
        for category in manifest.categories {
            let folder = root.appendingPathComponent(category.folderName, isDirectory: true)
            if category == .preferences {
                if let data = try? Data(contentsOf: folder.appendingPathComponent("preferences.json")),
                   let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    preferenceKeys = values.count
                }
                continue
            }
            let found = files(in: folder, category: category)
                .filter { !$0.relativePath.hasPrefix("_images/") && !$0.relativePath.hasPrefix("_logos/") }
            items[category] = found
            if let local = category.localRoot {
                conflicts[category] = found.filter {
                    FileManager.default.fileExists(atPath: local.appendingPathComponent($0.relativePath).path)
                }.count
            }
        }
        return ResourceBundlePreview(sourceURL: zip, root: root, manifest: manifest,
                                     items: items, conflicts: conflicts, preferenceKeys: preferenceKeys)
    }

    static func discard(_ preview: ResourceBundlePreview) {
        // The extraction folder is the root's parent (or the root itself
        // when the zip had no wrapping folder).
        let parent = preview.root.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: parent.lastPathComponent.hasPrefix("cb_import_") ? parent : preview.root)
    }

    private static func findRoot(in folder: URL, depth: Int) -> URL? {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) { return folder }
        guard depth < 2 else { return nil }
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let root = findRoot(in: child, depth: depth + 1) { return root }
        }
        return nil
    }

    static func importBundle(_ preview: ResourceBundlePreview, categories: Set<ResourceCategory>,
                             policy: ResourceImportPolicy,
                             progress: @escaping @Sendable (String) -> Void) throws -> ResourceImportSummary {
        var summary = ResourceImportSummary()
        let imagesRoot = AssetKind.images.rootURL
        for category in preview.manifest.categories where categories.contains(category) {
            progress("Importing \(category.title.lowercased())…")
            let folder = preview.root.appendingPathComponent(category.folderName, isDirectory: true)
            switch category {
            case .preferences:
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("preferences.json")),
                      let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                for (key, value) in values where preferencePrefixes.contains(where: key.hasPrefix) {
                    UserDefaults.standard.set(value, forKey: key)
                    summary.preferencesApplied += 1
                }
            case .music, .fonts, .images, .screenCrops:
                let local = category.localRoot!
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                for item in preview.items[category] ?? [] {
                    let source = folder.appendingPathComponent(item.relativePath)
                    let target = local.appendingPathComponent(item.relativePath)
                    try place(source, at: target, policy: policy, summary: &summary)
                }
                if category == .fonts { summary.fontsChanged = true }
                if category == .screenCrops { summary.screenCropsChanged = true }
            case .overlays:
                let local = OverlayTemplateStore.directory
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                let bundledImages = folder.appendingPathComponent("_images", isDirectory: true)
                for item in preview.items[category] ?? [] {
                    let source = folder.appendingPathComponent(item.relativePath)
                    guard let data = try? Data(contentsOf: source),
                          var composition = try? JSONDecoder().decode(OverlayComposition.self, from: data) else { continue }
                    for index in composition.images.indices {
                        let path = composition.images[index].path
                        if path.hasPrefix(imageMarker) {
                            composition.images[index].path = imagesRoot.appendingPathComponent(String(path.dropFirst(imageMarker.count))).path
                        } else if path.hasPrefix(bundledImageMarker) {
                            let name = String(path.dropFirst(bundledImageMarker.count))
                            let target = imagesRoot.appendingPathComponent("Imported").appendingPathComponent(name)
                            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                                    withIntermediateDirectories: true)
                            if !FileManager.default.fileExists(atPath: target.path) {
                                try? FileManager.default.copyItem(at: bundledImages.appendingPathComponent(name), to: target)
                            }
                            composition.images[index].path = target.path
                        }
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let rewritten = folder.appendingPathComponent("_rewritten_" + (item.relativePath as NSString).lastPathComponent)
                    try encoder.encode(composition).write(to: rewritten)
                    try place(rewritten, at: local.appendingPathComponent(item.relativePath), policy: policy, summary: &summary)
                }
            case .profiles:
                let local = ProfileStore.profilesDirectory
                let logos = folder.appendingPathComponent("_logos", isDirectory: true)
                for item in preview.items[category] ?? [] {
                    let source = folder.appendingPathComponent(item.relativePath)
                    guard let data = try? Data(contentsOf: source),
                          var profile = try? JSONDecoder().decode(BrandProfile.self, from: data) else { continue }
                    if profile.logoPath.hasPrefix(logoMarker) {
                        let name = String(profile.logoPath.dropFirst(logoMarker.count))
                        let target = imagesRoot.appendingPathComponent("Logos").appendingPathComponent(name)
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                        if !FileManager.default.fileExists(atPath: target.path) {
                            try? FileManager.default.copyItem(at: logos.appendingPathComponent(name), to: target)
                        }
                        profile.logoPath = target.path
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let rewritten = folder.appendingPathComponent("_rewritten_" + (item.relativePath as NSString).lastPathComponent)
                    let target = local.appendingPathComponent(item.relativePath)
                    // The profile's name must match its file name, including
                    // a "keep both" rename.
                    let finalTarget = resolvedTarget(for: target, policy: policy)
                    if finalTarget == nil {
                        summary.skipped += 1
                        continue
                    }
                    profile.profileName = finalTarget!.deletingPathExtension().lastPathComponent
                    try encoder.encode(profile).write(to: rewritten)
                    try place(rewritten, at: target, policy: policy, summary: &summary)
                    ProfileStore.ensureFolders(for: profile)
                }
                summary.profilesChanged = true
            }
        }
        return summary
    }

    /// Where a file lands under the policy: nil = skip it.
    private static func resolvedTarget(for target: URL, policy: ResourceImportPolicy) -> URL? {
        guard FileManager.default.fileExists(atPath: target.path) else { return target }
        switch policy {
        case .skip: return nil
        case .replace: return target
        case .keepBoth:
            let base = target.deletingPathExtension().lastPathComponent
            let ext = target.pathExtension
            let folder = target.deletingLastPathComponent()
            var counter = 2
            while true {
                let candidate = folder.appendingPathComponent("\(base) \(counter)" + (ext.isEmpty ? "" : ".\(ext)"))
                if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                counter += 1
            }
        }
    }

    private static func place(_ source: URL, at target: URL, policy: ResourceImportPolicy,
                              summary: inout ResourceImportSummary) throws {
        let existed = FileManager.default.fileExists(atPath: target.path)
        guard let final = resolvedTarget(for: target, policy: policy) else {
            summary.skipped += 1
            return
        }
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.copyItem(at: source, to: final)
        if !existed {
            summary.imported += 1
        } else if final == target {
            summary.replaced += 1
        } else {
            summary.renamed += 1
        }
    }

    // MARK: - ditto

    private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ResourceBundleError.toolFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
