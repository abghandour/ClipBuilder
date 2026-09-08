import SwiftUI

/// The explanation behind one Wizard control: a tooltip for hover and
/// VoiceOver, and an optional caption shown under the control when the
/// label alone does not say how the choice changes the reel.
nonisolated struct FieldHelp: Sendable {
    let tooltip: String
    let caption: String?

    init(_ tooltip: String, caption: String? = nil) {
        self.tooltip = tooltip
        self.caption = caption
    }
}

/// One table for every field in the AI Wizard, so the hover tip, the
/// caption, and VoiceOver all say the same thing.
nonisolated enum WizardFieldHelp {
    // What should we make?
    static let instructions = FieldHelp(
        "Tell the planner what the reel should achieve: the hook, the moments it must include, the mood.")

    // Plan
    static let recipe = FieldHelp(
        "The reel's format: what it opens on, roughly how long it runs, and what text it carries.")
    static let podcastFraming = FieldHelp(
        "How the reel frames the speakers.")
    static let length = FieldHelp(
        "How long the finished reel should be.",
        caption: "Auto lets the recipe, your account's best-performing length, and any reference reel decide. A fixed length is a hard limit the planner must hit.")
    static let customLength = FieldHelp(
        "Exact reel length, from 3 to 180 seconds.")
    static let cutCadence = FieldHelp(
        "How often the reel cuts to a new clip.",
        caption: "Automatic lets the planner cut on the action and the music. A fixed cadence keeps every clip near that length.")
    static let paceCurve = FieldHelp(
        "How the cutting speed changes from the start of the reel to the end.",
        caption: "Steady keeps clips even. Accelerate shortens them toward the end, Decelerate lengthens them, and Build, then drop speeds up and then settles for the payoff. Applies with a fixed cadence.")
    static let sources = FieldHelp(
        "Which analyzed footage the planner may pick from.",
        caption: "Every analyzed scene in this project, only the curated scenes, or specific Analyze batches, optionally narrowed to certain people.")

    // Output
    static let canvas = FieldHelp(
        "The output size and aspect ratio.",
        caption: "9:16 for Reels, TikTok, and Shorts. 16:9 for YouTube. 1:1 and 4:5 for feed posts.")
    static let customSize = FieldHelp(
        "Width and height in pixels.")
    static let encodeQuality = FieldHelp(
        "Trades file size against picture quality.",
        caption: "High keeps the most detail, Balanced suits uploads, Compact makes the smallest file.")
    static let customCRF = FieldHelp(
        "The encoder's constant rate factor. Lower is higher quality and a larger file.")
    static let audio = FieldHelp(
        "What the viewer hears.",
        caption: "Original audio keeps the footage's sound. Original + music mixes a track under it. Music only mutes the footage.")
    static let musicFolder = FieldHelp(
        "Only songs in this Music folder (and its subfolders) are offered to the planner.")
    static let onScreenText = FieldHelp(
        "Which kind of text is burned into the reel.",
        caption: "Captions subtitle what is said and need a transcript. Headlines are short editorial titles. Automatic picks by recipe: captions for interviews and podcasts, headlines otherwise.")
    static let captionLanguage = FieldHelp(
        "The language the captions appear in.",
        caption: "Original audio language keeps the transcript as spoken; any other choice translates it. The choices come from the profile's caption languages.")
    static let quality = FieldHelp(
        "How many versions the AI critic may ask for after watching the render.")
    static let reviewProposedCuts = FieldHelp(
        "Pause after planning so you can approve or adjust the cuts before anything renders.",
        caption: "The proposed cuts appear for review and nothing renders until you accept them. On by default for podcast reels.")

    // More options
    static let modelOverride = FieldHelp(
        "Ask the AI provider for a specific model by name. Leave empty for its default.",
        caption: "Use the exact model name the provider's command-line tool accepts. Empty lets the provider choose.")
    static let styleReference = FieldHelp(
        "Which learned taste guides the plan.",
        caption: "Profile taste applies what the Wizard has learned from your reviews and studied reels. A learned video type applies only that type's rubric. No style reference plans from the recipe alone.")
    static let layouts = FieldHelp(
        "Whether clips may share the frame through Screen Crop layouts.")
    static let bumperIntro = FieldHelp(
        "Start the reel with one of your bumper videos.")
    static let bumperOutro = FieldHelp(
        "End the reel with one of your bumper videos.")
    static let bumperMiddle = FieldHelp(
        "Drop one bumper video at a random cut inside the reel.")
    static let branding = FieldHelp(
        "Which brand elements are burned into the reel.",
        caption: "Standard adds the watermark, the headline, and the outro. Minimal keeps only the watermark. Saved default uses the profile's setting.")
}

/// The caption line under a control, in the form's secondary caption style.
struct FieldCaption: View {
    let help: FieldHelp

    init(_ help: FieldHelp) { self.help = help }

    var body: some View {
        if let caption = help.caption {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// Attaches the field's tooltip (also read by VoiceOver as the hint).
    func fieldHelp(_ help: FieldHelp) -> some View {
        self.help(help.tooltip)
    }
}
