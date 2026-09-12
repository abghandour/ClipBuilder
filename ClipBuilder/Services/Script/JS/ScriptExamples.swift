import Foundation

/// Stable IDs are shared across profiles; installation never matches by name.
nonisolated enum ScriptExamples {
    static let all: [(id: UUID, source: String)] = [
        (UUID(uuid: (0x53, 0x34, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1)), splitSelection),
        (UUID(uuid: (0x53, 0x34, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 2)), removePerson),
        (UUID(uuid: (0x53, 0x34, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 3)), muteBRoll),
        (UUID(uuid: (0x53, 0x34, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 4)), addBRoll)
    ]

    static let splitSelection = """
    /** clipbuilder-script
    {"name":"Split selection evenly","description":"Split the selected clip into equal pieces with millisecond speech precision.","mode":"edit","params":[{"name":"parts","type":"number","min":2,"max":12,"step":1,"default":6}],"requires":[]}
    */
    const selection = builder.selection;
    if (!selection || selection.kind !== "clip") throw new Error("Select a clip to split.");
    builder.ops.split_clip_evenly({clip: selection.id, parts: params.parts, precision: "speech"});
    const summary = `Split selection into ${params.parts} pieces.`;
    return { summary };
    """

    static let removePerson = """
    /** clipbuilder-script
    {"name":"Remove clips with a person","description":"Remove clips matching a known person's roster key or name, ignoring case.","mode":"edit","params":[{"name":"person","type":"string","label":"Person key or name"}],"requires":[]}
    */
    const wanted = params.person.trim().toLowerCase();
    const matches = [];
    let offset = 0;
    do {
        const page = builder.query({kind: "people", includeHidden: true, offset, limit: 200});
        matches.push(...page.people.filter(p => p.key.toLowerCase() === wanted || p.name.toLowerCase() === wanted));
        offset = page.nextOffset;
    } while (offset != null);
    if (!wanted || matches.length === 0) throw new Error("Unknown person. Enter a roster key or name from Library People.");
    if (matches.length !== 1) throw new Error("That name is ambiguous. Enter a unique roster key.");
    builder.ops.remove_clips({filter: {people: [matches[0].key]}});
    const summary = `Removed clips with ${matches[0].name}.`;
    return { summary };
    """

    static let muteBRoll = """
    /** clipbuilder-script
    {"name":"Mute all B-roll","description":"Mute every B-roll clip; already-muted clips can stay unchanged.","mode":"edit","params":[],"requires":[]}
    */
    const clips = [];
    let offset = 0;
    do {
        const page = builder.query({kind: "clips", filter: {role: "cutaway"}, offset, limit: 200});
        clips.push(...page.clips);
        offset = page.nextOffset;
    } while (offset != null);
    // Collect first, then mutate. Skip already-muted clips to conserve the edit budget.
    // Any unchanged outcomes are also successful no-ops.
    const changes = clips.filter(clip => !clip.muted);
    for (let i = 0; i < changes.length; i += 200) {
        builder.run(changes.slice(i, i + 200).map(clip => ({op: "set_clip_muted", clip: clip.id, muted: true})));
    }
    const summary = `Muted ${clips.length} B-roll clips (including any already muted).`;
    return { summary };
    """

    static let addBRoll = """
    /** clipbuilder-script
    {"name":"Add B-roll from a tag at the playhead","description":"Add the first matching scene as B-roll at the chosen time and track.","mode":"edit","params":[{"name":"tag","type":"string","label":"Library tag"},{"name":"time","type":"time","label":"Timeline time (seconds)"},{"name":"track","type":"track","default":0}],"requires":[]}
    */
    const tag = params.tag.trim();
    if (!tag) throw new Error("Enter a Library tag.");
    const page = builder.query({kind: "scenes", sceneFilter: {tags: [tag]}, limit: 1});
    if (page.scenes.length === 0) throw new Error("No available scene matches that tag.");
    builder.ops.add_cutaway({scene: page.scenes[0].id, at: params.time, track: params.track, cover_all: false});
    const summary = `Added B-roll tagged ${tag} at ${params.time} seconds.`;
    return { summary };
    """
}
