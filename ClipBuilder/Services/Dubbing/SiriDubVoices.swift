import Foundation

/// Which speech engine dubs a timeline. Mac voices speak in-process through
/// AVSpeechSynthesizer. Siri voices are hidden from third-party processes, so
/// they speak through a Shortcuts shortcut (an Apple-signed binary) that
/// writes the audio file; see `SiriDubSynthesizer`.
nonisolated enum DubVoiceEngine: String, Codable, Sendable, CaseIterable {
    case mac, siri

    var title: String {
        switch self {
        case .mac: "Mac voices"
        case .siri: "Siri voices"
        }
    }
}

/// The Siri voices on this Mac and what each one still needs before it can
/// dub: the voice download (System Settings) and its shortcut (Shortcuts app).
/// Every check reads disk or `shortcuts list`; nothing here needs the database.
nonisolated enum SiriDubVoices {
    static let identifierPrefix = "com.apple.siri.natural."
    static let shortcutPrefix = "Clip Builder Dub "
    static let assetDirectory = "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/purpose_auto"
    static let spokenContentSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!
    static let shortcutsExecutable = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// Siri voice names Apple ships, by the gender the voice speaks with. The
    /// voices the Shortcuts picker lists as "Voice 1 / Voice 2" per language.
    static let knownGenders: [String: DubVoiceGender] = [
        "nando": .male, "sandra": .female,
        "aaron": .male, "nicky": .female, "evan": .male, "zoe": .female, "noelle": .female,
    ]

    /// The order the Shortcuts voice picker shows the voices of a language.
    static let shortcutsOrder: [String: [String]] = ["pt-BR": ["Nando", "Sandra"]]

    static func isSiri(_ identifier: String) -> Bool { identifier.hasPrefix(identifierPrefix) }

    static func name(of identifier: String) -> String { String(identifier.dropFirst(identifierPrefix.count)) }

    static func shortcutName(for identifier: String) -> String { shortcutPrefix + name(of: identifier) }

    /// The label the Shortcuts voice picker uses for this voice, when known.
    static func shortcutsLabel(for voice: DubSynthesizer.Voice) -> String? {
        guard let index = shortcutsOrder[voice.language]?.firstIndex(of: voice.name) else { return nil }
        return "Voice \(index + 1)"
    }

    /// One voice per downloaded natural Siri voice asset. The accessibility
    /// download (System Settings › Spoken Content) installs the "natural"
    /// variant; Siri's own "gryphon" assets never reach Shortcuts.
    static func voices(fromSpecifiers specifiers: [String]) -> [DubSynthesizer.Voice] {
        var result: [DubSynthesizer.Voice] = []
        for specifier in specifiers {
            // com.apple.siri.tts.voice.pt_BR.nando.natural.premium
            let parts = specifier.split(separator: ".")
            guard parts.count >= 9, parts[0...4].joined(separator: ".") == "com.apple.siri.tts.voice",
                  parts[7] == "natural" else { continue }
            let language = parts[5].replacingOccurrences(of: "_", with: "-")
            let lower = String(parts[6]).lowercased()
            let name = lower.prefix(1).uppercased() + lower.dropFirst()
            let identifier = identifierPrefix + name
            guard !result.contains(where: { $0.identifier == identifier }) else { continue }
            result.append(.init(identifier: identifier, language: language, name: name, quality: 3,
                                gender: knownGenders[lower] ?? DubVoiceGender.inferred(voiceName: name)))
        }
        return DubSynthesizer.ranked(result)
    }

    /// Reads the asset catalog on disk. World-readable; no privileges needed.
    static func downloadedVoices(language: String? = nil) -> [DubSynthesizer.Voice] {
        let manager = FileManager.default
        let assets = (try? manager.contentsOfDirectory(atPath: assetDirectory)) ?? []
        let specifiers = assets.compactMap { asset -> String? in
            let plist = URL(fileURLWithPath: assetDirectory).appendingPathComponent(asset).appendingPathComponent("Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let properties = root["MobileAssetProperties"] as? [String: Any] else { return nil }
            return properties["AssetSpecifier"] as? String
        }
        return voices(fromSpecifiers: specifiers).filter { voice in
            guard let language else { return true }
            return DubLanguageChoices.matches(voice.language, requested: language)
        }
    }

    /// Names of the shortcuts in the user's library.
    static func installedShortcuts() async -> Set<String> {
        guard FileManager.default.isExecutableFile(atPath: shortcutsExecutable.path),
              let result = try? await ProcessRunner.run(executable: shortcutsExecutable, arguments: ["list"], timeout: 20),
              result.exitCode == 0 else { return [] }
        return Set(result.stdoutText.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) })
    }

    /// Downloaded voices whose shortcut exists: the ones a dub can use now.
    static func readyVoices(downloaded: [DubSynthesizer.Voice], shortcuts: Set<String>) -> [DubSynthesizer.Voice] {
        downloaded.filter { shortcuts.contains(shortcutName(for: $0.identifier)) }
    }

    static func readyVoices(language: String? = nil) async -> [DubSynthesizer.Voice] {
        readyVoices(downloaded: downloadedVoices(language: language), shortcuts: await installedShortcuts())
    }

    struct Status: Sendable, Equatable {
        var language: String
        var ffmpegInstalled: Bool
        var downloaded: [DubSynthesizer.Voice]
        var shortcuts: Set<String>

        var ready: [DubSynthesizer.Voice] { SiriDubVoices.readyVoices(downloaded: downloaded, shortcuts: shortcuts) }
        var missingShortcuts: [DubSynthesizer.Voice] { downloaded.filter { !shortcuts.contains(SiriDubVoices.shortcutName(for: $0.identifier)) } }
        var isReady: Bool { ffmpegInstalled && !ready.isEmpty }
    }

    static func status(language: String) async -> Status {
        Status(language: language, ffmpegInstalled: ProcessRunner.locate("ffmpeg") != nil,
               downloaded: downloadedVoices(language: language), shortcuts: await installedShortcuts())
    }

    static func setupMessage(language: String) -> String {
        "No Siri voice is ready for \(DubLanguageChoices.name(language)). "
            + "Choose Siri voices in the dub settings and follow Set up: download the voice in System Settings › "
            + "Accessibility › Spoken Content, then add its shortcut in the Shortcuts app."
    }

    /// The unsigned shortcut that speaks with one Siri voice. Shortcuts refuses
    /// to import unsigned files; `scripts/sign_siri_shortcuts.sh` signs these
    /// on a Mac that is signed into iCloud and places them in the app bundle.
    static func shortcutDefinition(for voice: DubSynthesizer.Voice) -> [String: Any] {
        let speak = UUID().uuidString
        let input: [String: Any] = [
            "Value": ["attachmentsByRange": ["{0, 1}": ["Type": "ExtensionInput"]], "string": "\u{FFFC}"],
            "WFSerializationType": "WFTextTokenString",
        ]
        let output: [String: Any] = [
            "Value": ["attachmentsByRange": ["{0, 1}": ["OutputName": "Spoken Audio", "OutputUUID": speak, "Type": "ActionOutput"]],
                      "string": "\u{FFFC}"],
            "WFSerializationType": "WFTextTokenString",
        ]
        return [
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowClientVersion": "2607.0.3",
            "WFWorkflowHasShortcutInputVariables": true,
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowImportQuestions": [],
            "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
            "WFWorkflowTypes": [],
            "WFWorkflowActions": [
                ["WFWorkflowActionIdentifier": "is.workflow.actions.makespokenaudiofromtext",
                 "WFWorkflowActionParameters": ["UUID": speak, "WFInput": input,
                                                "WFSpeakTextLanguage": voice.language,
                                                "WFSpeakTextVoice": voice.identifier]],
                ["WFWorkflowActionIdentifier": "is.workflow.actions.output",
                 "WFWorkflowActionParameters": ["UUID": UUID().uuidString, "WFOutput": output]],
            ],
        ]
    }

    /// A signed shortcut file shipped in the app bundle, when the release
    /// included one for this voice.
    static func bundledShortcut(for voice: DubSynthesizer.Voice) -> URL? {
        let name = shortcutName(for: voice.identifier)
        return Bundle.main.url(forResource: name, withExtension: "shortcut", subdirectory: "Shortcuts")
            ?? Bundle.main.url(forResource: name, withExtension: "shortcut")
    }

    /// Steps the user follows in the Shortcuts app when no signed file is bundled.
    static func manualSteps(for voice: DubSynthesizer.Voice) -> [String] {
        let picker = shortcutsLabel(for: voice).map { "“\($0)” under Siri" } ?? "the Siri voice named \(voice.name)"
        return [
            "In Shortcuts, create a new shortcut (File › New Shortcut).",
            "Add the action “Make Spoken Audio from Text”.",
            "Open its options (the chevron) and set Language to \(DubLanguageChoices.name(voice.language)) and Voice to \(picker).",
            "Right-click the text field, choose Insert Variable › Shortcut Input.",
            "Name the shortcut exactly “\(shortcutName(for: voice.identifier))” and close it.",
            "The first dub line asks “Allow … to output 1 media item?”: choose Always Allow.",
        ]
    }
}
