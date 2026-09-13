import Foundation

/// The v1 look vocabulary. Builders use local pad names; filter() namespaces
/// every pad before a fragment is spliced into a multi-placement graph.
nonisolated enum EffectCatalog {
    struct ParamSpec: Codable, Sendable, Equatable {
        var name: String
        var min: Double
        var max: Double
        var `default`: Double
    }

    struct Preset: Sendable {
        var id: String
        var name: String
        var group: String
        var params: [ParamSpec] = []
        var requiredFilters: Set<String>
        var builder: @Sendable (EffectSpec, Int, Int) -> String
    }

    static let lutNames = [
        "fuji_superia_200", "fuji_velvia_50", "fuji_xtrans_iii_acros",
        "fuji_xtrans_iii_classic_chrome", "fuji_xtrans_iii_provia", "ilford_hps_800",
        "kodak_2383_constlclip", "kodak_ektachrome_100_vs", "kodak_ektar_100",
        "kodak_kodachrome_64", "kodak_portra_160_vc", "kodak_t-max_400", "polaroid_669"
    ]

    private static func fixed(_ id: String, _ name: String, _ group: String,
                              _ fragment: String, _ filters: Set<String>) -> Preset {
        Preset(id: id, name: name, group: group, requiredFilters: filters,
               builder: { _, _, _ in fragment })
    }

    private static func parameter(_ id: String, _ name: String, _ group: String,
                                  _ key: String, _ min: Double, _ max: Double, _ value: Double,
                                  _ filters: Set<String>,
                                  _ build: @escaping @Sendable (Double) -> String) -> Preset {
        Preset(id: id, name: name, group: group,
               params: [.init(name: key, min: min, max: max, default: value)],
               requiredFilters: filters, builder: { spec, _, _ in build(spec.params[key] ?? value) })
    }

    static let presets: [Preset] = [
        fixed("none", "None", "looks", "", []),
        fixed("bw", "Black & White", "looks", "hue=s=0", ["hue"]),
        fixed("noir", "Noir", "looks", "hue=s=0,eq=contrast=1.35", ["hue", "eq"]),
        fixed("sepia", "Sepia", "looks", "colorchannelmixer=.393:.769:.189:0:.349:.686:.168:0:.272:.534:.131", ["colorchannelmixer"]),
        fixed("faded", "Faded / matte", "looks", "curves=preset=lighter,eq=contrast=0.85:brightness=0.04", ["curves", "eq"]),
        fixed("vivid", "Vivid", "looks", "eq=saturation=1.45:contrast=1.08", ["eq"]),
        fixed("warm", "Warm", "looks", "colortemperature=temperature=4500", ["colortemperature"]),
        fixed("cool", "Cool", "looks", "colortemperature=temperature=8500", ["colortemperature"]),
        fixed("vintage", "Vintage film", "looks", "curves=preset=vintage,vignette=angle=PI/5,noise=alls=10:allf=t+u", ["curves", "vignette", "noise"]),
        fixed("invert", "Invert", "looks", "negate", ["negate"]),
        Preset(id: "duotone", name: "Duotone", group: "looks",
               params: ["shadow_r", "shadow_g", "shadow_b", "highlight_r", "highlight_g", "highlight_b"].map {
                   ParamSpec(name: $0, min: 0, max: 1, default: $0.hasPrefix("shadow") ? 0 : 1)
               }, requiredFilters: ["hue", "lutrgb"], builder: { spec, _, _ in duotone(spec) }),
        parameter("brightness", "Brightness", "adjust", "brightness", -1, 1, 0, ["eq"]) { "eq=brightness=\(number($0))" },
        parameter("contrast", "Contrast", "adjust", "contrast", 0.5, 2, 1, ["eq"]) { "eq=contrast=\(number($0))" },
        parameter("saturation", "Saturation", "adjust", "saturation", 0, 2, 1, ["eq"]) { "eq=saturation=\(number($0))" },
        parameter("gamma", "Gamma", "adjust", "gamma", 0.5, 2, 1, ["eq"]) { "eq=gamma=\(number($0))" },
        parameter("temperature", "Temperature", "adjust", "temperature", 2000, 12000, 6500, ["colortemperature"]) { "colortemperature=temperature=\(number($0)):mix=1" },
        parameter("vignette", "Vignette", "adjust", "strength", 0, 1, 0.5, ["vignette"]) { "vignette=angle=PI/2*\(number($0))" },
        parameter("sharpen", "Sharpen", "detail", "amount", 0, 2, 1, ["unsharp"]) { "unsharp=5:5:\(number($0))" },
        parameter("blur", "Blur", "detail", "sigma", 0, 20, 5, ["gblur"]) { "gblur=sigma=\(number($0))" },
        parameter("pixelate", "Pixelate", "stylize", "block", 4, 40, 12, ["scale"]) { pixelate(block: $0, supported: supportsPixelize) },
        parameter("posterize", "Posterize", "stylize", "levels", 2, 10, 4, ["lutrgb"]) {
            let step = number(256 / $0.rounded())
            return "lutrgb=" + ["r", "g", "b"].map { "\($0)='trunc(val/\(step))*\(step)'" }.joined(separator: ":")
        },
        parameter("grain", "Film grain", "stylize", "amount", 0, 40, 10, ["noise"]) { "noise=alls=\(number($0)):allf=t+u" },
        parameter("rgbsplit", "RGB split / glitch", "stylize", "px", 2, 20, 4, ["rgbashift"]) { "rgbashift=rh=\(Int($0.rounded())):bh=-\(Int($0.rounded()))" },
        fixed("vhs", "VHS", "stylize", "chromashift=cbh=4:crh=-4,noise=alls=14:allf=t+u,huesaturation=saturation=-0.2", ["chromashift", "noise", "huesaturation"]),
        fixed("edges", "Edges / cartoon", "stylize", "edgedetect=mode=colormix:high=0.4:low=0.2", ["edgedetect"]),
        fixed("mirror", "Mirror", "stylize", "crop=iw/2:ih:0:0,split[l][r];[r]hflip[rf];[l][rf]hstack", ["crop", "split", "hflip", "hstack"])
    ] + lutNames.map { name in
        Preset(id: "lut:\(name)", name: name.replacingOccurrences(of: "_", with: " ").capitalized,
               group: "film", requiredFilters: ["lut3d"], builder: { _, _, _ in
                   // validate() refuses missing LUTs before graph construction.
                   guard let url = lutURL(named: name) else { return "" }
                   return "lut3d=file='\(escapeFilterPath(url.path))'"
               })
    }

    static var ids: [String] { presets.map(\.id) }
    static func preset(for id: String) -> Preset? { presets.first { $0.id == id } }

    static func lutURL(named name: String) -> URL? {
        guard lutNames.contains(name) else { return nil }
        return Bundle.main.url(forResource: name, withExtension: "cube", subdirectory: "LUTs")
            // Xcode synchronized resource groups can flatten resource folders.
            ?? Bundle.main.url(forResource: name, withExtension: "cube")
    }

    /// Two parser levels: the filter graph's single quotes, then the filter's
    /// option parser. Mask inputs use argv paths and need no such escaping.
    static func escapeFilterPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "'\\\\\\''")
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
            .grouping(.never).precision(.fractionLength(0...8)))
    }

    static func pixelate(block: Double, supported: Bool) -> String {
        let size = Int(block.rounded())
        return supported ? "pixelize=w=\(size):h=\(size)"
            : "scale=iw/\(size):ih/\(size),scale=iw*\(size):ih*\(size):flags=neighbor"
    }

    private static func duotone(_ spec: EffectSpec) -> String {
        "hue=s=0,lutrgb=" + ["r", "g", "b"].map { channel in
            let shadow = spec.params["shadow_\(channel)"] ?? 0
            let highlight = spec.params["highlight_\(channel)"] ?? 1
            return "\(channel)='\(number(shadow * 255))+val*\(number(highlight - shadow))'"
        }.joined(separator: ":")
    }

    static func filter(for spec: EffectSpec, width: Int, height: Int, namespace: String = "") -> String {
        guard spec.preset != "none", spec.intensity > 0,
              let preset = preset(for: spec.preset) else { return "" }
        var fragment = preset.builder(spec, width, height)
        guard !fragment.isEmpty else { return "" }
        // Preserve placement geometry for odd-sized mirror and scale fallback.
        if spec.preset == "mirror" || (spec.preset == "pixelate" && !supportsPixelize) {
            fragment += ",scale=\(width):\(height):flags=neighbor,setsar=1"
        }
        if spec.preset == "mirror" {
            for pad in ["l", "r", "rf"] {
                fragment = fragment.replacingOccurrences(of: "[\(pad)]", with: "[\(namespace)\(pad)]")
            }
        }
        if spec.intensity < 1 {
            fragment = "split[\(namespace)a][\(namespace)b];[\(namespace)b]\(fragment)[\(namespace)e];"
                + "[\(namespace)a][\(namespace)e]blend=all_mode=normal:all_opacity=\(number(spec.intensity))"
        }
        return fragment
    }

    private static let availabilityLock = NSLock()
    nonisolated(unsafe) private static var filterCache: Set<String>?
    static var availableFilters: Set<String> {
        availabilityLock.lock()
        defer { availabilityLock.unlock() }
        if let filterCache { return filterCache }
        let output = ProcessRunner.filterList()
        let names = parseFilters(output)
        // An empty answer means ffmpeg was missing or failed, not that the
        // build has no filters; leave it uncached so a later install (which
        // also calls resetAvailability) or a transient failure is retried.
        if !names.isEmpty { filterCache = names }
        return names
    }

    /// Forget the probe result — after installing or replacing ffmpeg.
    static func resetAvailability() {
        availabilityLock.lock()
        filterCache = nil
        availabilityLock.unlock()
    }

    /// `ffmpeg -filters` rows look like ` TS gblur  V->V  Apply …`: a flag
    /// column of two (ffmpeg 7/8) or three (older builds) characters, the
    /// name, then the `in->out` signature. The header lines have no arrow.
    static func parseFilters(_ output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, (2...3).contains(fields[0].count),
                  fields[0].allSatisfy({ "TSC.".contains($0) }),
                  fields[2].contains("->") else { return nil }
            return String(fields[1])
        })
    }

    static var supportsPixelize: Bool { availableFilters.contains("pixelize") }
    static func isAvailable(_ id: String) -> Bool { isAvailable(id, filters: availableFilters) }
    static func isAvailable(_ id: String, filters: Set<String>) -> Bool {
        guard let preset = preset(for: id), preset.requiredFilters.isSubset(of: filters) else { return false }
        if id.hasPrefix("lut:") { return lutURL(named: String(id.dropFirst(4))) != nil }
        return true
    }

    static func validate(_ spec: EffectSpec) throws {
        guard let preset = preset(for: spec.preset) else {
            throw BuilderCommandFailure.invalid("Unknown effect preset: \(spec.preset).")
        }
        guard spec.intensity.isFinite, (0...1).contains(spec.intensity) else {
            throw BuilderCommandFailure.bounds("Effect intensity must be within 0…1.")
        }
        for (key, value) in spec.params {
            guard let param = preset.params.first(where: { $0.name == key }) else {
                throw BuilderCommandFailure.invalid("Unknown \(spec.preset) parameter: \(key).")
            }
            guard value.isFinite, (param.min...param.max).contains(value) else {
                throw BuilderCommandFailure.bounds("\(key) must be within \(param.min)…\(param.max).")
            }
        }
        if spec.preset.hasPrefix("lut:"), lutURL(named: String(spec.preset.dropFirst(4))) == nil {
            throw BuilderCommandFailure.invalid("Missing bundled LUT: \(spec.preset).")
        }
    }
}
