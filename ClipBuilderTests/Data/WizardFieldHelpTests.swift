import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard field help")
struct WizardFieldHelpTests {
    private static let all: [(String, FieldHelp)] = [
        ("instructions", WizardFieldHelp.instructions), ("recipe", WizardFieldHelp.recipe),
        ("podcastFraming", WizardFieldHelp.podcastFraming), ("length", WizardFieldHelp.length),
        ("customLength", WizardFieldHelp.customLength), ("cutCadence", WizardFieldHelp.cutCadence),
        ("paceCurve", WizardFieldHelp.paceCurve), ("sources", WizardFieldHelp.sources),
        ("canvas", WizardFieldHelp.canvas), ("customSize", WizardFieldHelp.customSize),
        ("encodeQuality", WizardFieldHelp.encodeQuality), ("customCRF", WizardFieldHelp.customCRF),
        ("audio", WizardFieldHelp.audio), ("musicFolder", WizardFieldHelp.musicFolder),
        ("onScreenText", WizardFieldHelp.onScreenText), ("captionLanguage", WizardFieldHelp.captionLanguage),
        ("quality", WizardFieldHelp.quality), ("reviewProposedCuts", WizardFieldHelp.reviewProposedCuts),
        ("modelOverride", WizardFieldHelp.modelOverride), ("styleReference", WizardFieldHelp.styleReference),
        ("layouts", WizardFieldHelp.layouts), ("bumperIntro", WizardFieldHelp.bumperIntro),
        ("bumperOutro", WizardFieldHelp.bumperOutro), ("bumperMiddle", WizardFieldHelp.bumperMiddle),
        ("branding", WizardFieldHelp.branding),
    ]

    @Test("Every field has a full-sentence tooltip; captions are full sentences too and never repeat the tooltip")
    func wording() {
        for (name, help) in Self.all {
            #expect(help.tooltip.hasSuffix("."), "\(name) tooltip should be a sentence")
            #expect(help.tooltip.count > 20, "\(name) tooltip is too short to explain anything")
            #expect(!help.tooltip.contains("\n"), "\(name) tooltip must be one line")
            if let caption = help.caption {
                #expect(caption.hasSuffix("."), "\(name) caption should end in a period")
                #expect(caption != help.tooltip, "\(name) caption duplicates the tooltip")
            }
        }
    }

    @Test("Captions name every option of the pickers they explain")
    func captionsCoverOptions() throws {
        let audio = try #require(WizardFieldHelp.audio.caption)
        for mode in WizardAudioMode.allCases { #expect(audio.contains(mode.title)) }
        let branding = try #require(WizardFieldHelp.branding.caption)
        for option in WizardBrandingOverride.allCases where option != .none {
            #expect(branding.contains(option.title))
        }
        let curve = try #require(WizardFieldHelp.paceCurve.caption)
        for option in PaceCurve.allCases { #expect(curve.contains(option.label)) }
        let quality = try #require(WizardFieldHelp.encodeQuality.caption)
        for option in EncodeQuality.allCases where option != .custom { #expect(quality.contains(option.label)) }
    }
}
