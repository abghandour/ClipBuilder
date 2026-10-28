import Foundation

/// The only translation from a framing request to shot and transition parameters.
nonisolated enum FramingPlanner {
    /// The request's own VIP choice applies before anything reads `vipIDs`.
    static func applying(_ framing: Framing, to context: FramingContext) -> FramingContext {
        var context = context
        if let vips = framing.vips { context.vipOverride = Set(vips) }
        return context
    }

    static func subject(framing: Framing, context: FramingContext) -> Framing.Subject {
        let context = applying(framing, to: context)
        guard framing.subject == .auto else { return framing.subject }
        let allowed = available(type: context.type, hasTurns: !context.turns.isEmpty, hasVIP: !context.vipIDs.isEmpty)
        if let chosen = context.chosenSubject, allowed.contains(chosen) { return chosen }
        let defaultSubject = FramingMenu.default(type: context.type).subject
        let preferred: Framing.Subject = defaultSubject == .auto ? .speakerFocus : defaultSubject
        return allowed.contains(preferred) ? preferred : (allowed.contains(.centerStage) ? .centerStage : .original)
    }

    static func unavailableReason(_ subject: Framing.Subject, type: VideoType, hasTurns: Bool, hasVIP: Bool) -> String? {
        if subject == .speakerFocus && !hasTurns { return "Speaker focus needs speaker turns. Analyze speech first." }
        if subject == .vipFocus && type != .fight && !hasVIP { return "VIP focus needs a VIP tagged in People." }
        return nil
    }

    static func available(type: VideoType, hasTurns: Bool, hasVIP: Bool) -> [Framing.Subject] {
        FramingMenu.allowed(type: type).filter {
            $0 != .auto && unavailableReason($0, type: type, hasTurns: hasTurns, hasVIP: hasVIP) == nil
        }
    }

    static func resolve(framing: Framing, context: FramingContext) -> FramingPlan {
        let subject = subject(framing: framing, context: context)
        let frame = subject == .layout ? nil : framing.focusFrame.map { FocusFrame.resolved($0) }
        let hadEvidence = !context.roster.isEmpty || !context.feeds.isEmpty
        var context = applying(framing, to: frame.map { FocusFrame.filtered(context, frame: $0) } ?? context)
        guard subject != .original, !(frame != nil && hadEvidence && context.roster.isEmpty && context.feeds.isEmpty) else {
            return .static(window: frame, fit: framing.fit, feather: framing.feather, blur: framing.blur)
        }
        context.sourceRoles = framing.sourceRoles ?? [:]
        if subject == .layout {
            let name = framing.layout ?? (context.type == .screen ? "Screen + presenter" : "Split")
            if let grid = virtualLayout(name: name, context: context) {
                return .composed(layout: grid.layout, areas: LayoutRoleFiller.plan(layout: grid.layout, context: grid.context), fit: framing.fit)
            }
            let layout = (context.layouts + ScreenCropStore.builtIn).first { $0.name == name }
                ?? ScreenCropStore.builtIn[0]
            return .composed(layout: layout, areas: LayoutRoleFiller.plan(layout: layout, context: context), fit: framing.fit)
        }
        var recipe: CropRecipe
        switch subject {
        case .centerStage:
            recipe = CropRecipe(kind: .talker)
            recipe.centerStage = true
            if framing.people == .vips, !context.vipIDs.isEmpty {
                recipe.centerStageVIPs = true
                recipe.centerStageVIPKeys = framing.vips?.sorted()
            }
        case .vipFocus:
            recipe = CropRecipe(kind: context.hasBRoll && context.type != .fight ? .vipBRoll : .vip)
            if context.type == .fight { recipe.fighterFocus = true }
        case .speakerFocus:
            recipe = CropRecipe(kind: context.vipIDs.isEmpty ? .talker : .interview)
        case .layout:
            recipe = CropRecipe(kind: .grid)
            recipe.layout = framing.layout
        case .auto, .original:
            // `subject` resolves Auto before shot selection.
            return .static(window: framing.focusFrame, fit: framing.fit, feather: framing.feather, blur: framing.blur)
        }
        // Shot selection is independent of whether the camera glides or cuts.
        recipe.interviewZoom = min(1, max(0, framing.pullBack))
        recipe.interviewZoomMoves = false
        recipe.interviewPunchIn = .talker
        recipe.interviewCuts = framing.moves == .cuts
        return .tracked(recipe, region: frame, fit: framing.fit, feather: framing.feather, blur: framing.blur)
    }

    /// "Everyone" and "VIPs" are grids sized per scene: one cell per feed, or per VIP feed.
    /// The snapshot keeps the entry's name so the picker and the stored plan agree.
    static func virtualLayout(name: String, context: FramingContext) -> (layout: ScreenCropLayout, context: FramingContext)? {
        guard FramingMenu.virtualLayouts.contains(name) else { return nil }
        let tiles = LayoutRoleFiller.tiles(context: context)
        var context = context
        var shown = tiles
        if name == FramingMenu.vipsLayout {
            let vips = tiles.filter { context.vipIDs.contains($0.personKey ?? "") }
            if !vips.isEmpty { shown = vips }
        }
        if shown != tiles { context.feeds = shown }
        let gridName = CropRecipePlanner.layoutName(kind: .grid, people: max(1, shown.count)) ?? "2x3 Grid"
        var layout = ScreenCropStore.builtIn.first { $0.name == gridName }
            ?? ScreenCropLayout(name: gridName, areas: [ScreenCropArea(name: "Full", points: [
                ScreenCropPoint(x: 0, y: 0), ScreenCropPoint(x: 1, y: 0), ScreenCropPoint(x: 1, y: 1), ScreenCropPoint(x: 0, y: 1)])])
        layout.name = name
        return (layout, context)
    }

    static func warning(framing: Framing, context: FramingContext) -> String? {
        let context = applying(framing, to: context)
        let subject = subject(framing: framing, context: context)
        if case .composed(let layout, _, _) = resolve(framing: framing, context: context) {
            var context = context
            context.sourceRoles = framing.sourceRoles ?? [:]
            var noVIPTile = false
            if let grid = virtualLayout(name: layout.name, context: context) {
                noVIPTile = layout.name == FramingMenu.vipsLayout
                    && !LayoutRoleFiller.tiles(context: context).contains { context.vipIDs.contains($0.personKey ?? "") }
                context = grid.context
            }
            var notes = LayoutRoleFiller.resolve(layout: layout, context: context).notes
            if noVIPTile { notes.insert("No VIP in this recording: showing everyone.", at: 0) }
            if let name = framing.layout, name != layout.name { notes.insert("Layout \(name) is missing; using \(layout.name).", at: 0) }
            return notes.isEmpty ? nil : notes.joined(separator: " ")
        }
        guard subject != .original, subject != .layout, let frame = framing.focusFrame,
              !context.roster.isEmpty || !context.feeds.isEmpty else { return nil }
        let filtered = FocusFrame.filtered(context, frame: FocusFrame.resolved(frame))
        return filtered.roster.isEmpty && filtered.feeds.isEmpty ? FocusFrame.nobodyInside : nil
    }

    /// Shared composition, including independent source ranges for role layouts.
    static func composition(plan: FramingPlan, context: FramingContext) throws -> CropRecipePlanner.Plan? {
        if case .composed(let layout, let areas, _) = plan {
            let slots = layout.areas.map { area in
                let segment = areas.first { $0.areaID == area.id }
                return CropRecipePlanner.Slot(subject: .talker, window: nil, path: nil,
                    region: segment?.region, focus: segment?.focus.map { ($0.x, $0.y) })
            }
            return CropRecipePlanner.Plan(layout: CropLayoutRef(name: layout.name), slots: slots,
                tiles: VIPRecipePlanning.namedTiles(context.feeds, roster: context.roster), areas: areas, snapshot: layout, framingPlan: plan, sources: context.sources,
                programSource: context.video, programRange: context.range)
        }
        guard case .tracked(var recipe, let region, _, _, _) = plan, recipe.centerStage != true, recipe.fighterFocus != true else { return nil }
        let context = region.map { FocusFrame.filtered(context, frame: $0) } ?? context
        if recipe.layout == "Split", !context.layouts.contains(where: { $0.name == "Split" }) {
            recipe.layout = nil
        }
        var composition = try CropRecipePlanner.plan(recipe, video: context.video, range: context.range,
            turns: context.turns, roster: context.roster, layouts: context.layouts, canvasAspect: context.canvasAspect,
            availableTiles: region == nil ? nil : context.feeds)
        if let region {
            for index in composition.slots.indices {
                var slot = composition.slots[index]
                slot.region = FitSpec.intersection(slot.region ?? region, region)
                slot.window = nil
                slot.path = slot.path?.map { key in
                    let shot = FocusFrame.fitting(FreeCropRect(xFrac: key.x, yFrac: key.y, wFrac: key.w, hFrac: key.h), inside: region)
                    return CameraPathKeyframe(t: key.t, x: shot.xFrac, y: shot.yFrac, w: shot.wFrac, h: shot.hFrac)
                }
                if let focus = slot.focus, !FocusFrame.contains(region, x: focus.x, y: focus.y) { slot.focus = nil }
                slot.trackingSpans = slot.trackingSpans?.map { span in
                    var span = span
                    span.region = FitSpec.intersection(span.region, region)
                    if let focus = span.focus, !FocusFrame.contains(region, x: focus.x, y: focus.y) { span.focus = nil }
                    return span
                }
                composition.slots[index] = slot
            }
        }
        return composition
    }
}

nonisolated extension FramingPlan {
    var recipe: CropRecipe? {
        if case .tracked(let recipe, _, _, _, _) = self { return recipe }
        return nil
    }
    var isStatic: Bool { if case .static = self { return true }; return false }
    var camera: String { recipe?.fighterFocus == true ? "fast" : recipe?.centerStage == true ? "balanced" : "conversation" }
}

nonisolated extension WizardOptions {
    var requestedFraming: Framing { framing ?? Framing.legacy(from: self) }

    /// B-roll is part of the run, so VIP focus takes its B-roll breaks. The
    /// render decides from the actual sources; the preview only has the request.
    var requestsBRollBreaks: Bool {
        useBRoll && (manualBRoll == true || !brollInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
