import SwiftUI

/// A screen-crop area as a SwiftUI shape: its normalized vertices scaled
/// into whatever rect it's drawn in (the 9:16 canvas, a preview frame).
struct ScreenCropPolygon: Shape {
    let points: [ScreenCropPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: rect.minX + first.x * rect.width, y: rect.minY + first.y * rect.height))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height))
        }
        path.closeSubpath()
        return path
    }
}

/// Assets > Screen Crop: named layouts of areas drawn on a 9:16 canvas.
/// A layout ("Split") holds one or more named areas ("top", "bottom");
/// the Builder and the AI Wizard apply an area to a clip by its
/// "Layout/Area" name, and only that part of the clip stays visible.
struct ScreenCropsView: View {
    @State private var layouts: [ScreenCropLayout] = []
    @State private var selectedName: String?
    @State private var layout = ScreenCropLayout(name: "")
    @State private var watcher: FolderWatcher?
    @State private var saveTask: Task<Void, Never>?

    @State private var renamePrompt = false
    @State private var renameText = ""
    @State private var deleteTarget: String?
    @State private var operationError: String?

    var body: some View {
        HSplitView {
            layoutList
                .rememberedPaneWidth("pane.screencrops.list", min: 200, initial: 230, max: 300)
                .frame(maxHeight: .infinity)
            if let selectedName,
               layouts.contains(where: { $0.name == selectedName }) || isBuiltInSelected {
                ScreenCropEditor(layout: $layout, readOnly: isBuiltInSelected)
                    .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select a Screen Crop", systemImage: "crop",
                                       description: Text("Pick a built-in layout to see it, or create a custom one and draw named areas — \"top\", \"left fighter\", \"ring\". Clips framed into an area keep the people in focus; the rest of the frame shows the other areas' clips."))
                    .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Screen Crop")
        .navigationSubtitle("\(layouts.count) layout\(layouts.count == 1 ? "" : "s") · "
                            + "\(layouts.reduce(0) { $0 + $1.areas.count }) areas")
        .toolbar {
            ToolbarItemGroup {
                Button("New Screen Crop", systemImage: "plus", action: createLayout)
                    .help("Create a screen-crop layout")
                Button("Show in Finder", systemImage: "folder") {
                    try? FileManager.default.createDirectory(at: ScreenCropStore.directory,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ScreenCropStore.directory)
                }
                .help("Open the screen crops folder in Finder")
            }
        }
        .alert("Rename Screen Crop", isPresented: $renamePrompt) {
            TextField("Name", text: $renameText)
            Button("Rename", action: renameSelected)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Error", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
        .confirmationDialog(
            "Move “\(deleteTarget ?? "layout")” to the Trash?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
        ) {
            Button("Move to Trash", role: .destructive, action: deleteConfirmed)
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
        .onAppear {
            try? FileManager.default.createDirectory(at: ScreenCropStore.directory,
                                                     withIntermediateDirectories: true)
            refresh()
            let watcher = FolderWatcher { refresh() }
            watcher.watch(ScreenCropStore.directory)
            self.watcher = watcher
        }
        .onDisappear {
            watcher?.stop()
            watcher = nil
            saveTask?.cancel()
        }
        .onChange(of: selectedName) { _, name in
            if let name, let match = (layouts + builtInLayouts).first(where: { $0.name == name }) {
                layout = match
            }
        }
        .onChange(of: layout) { _, updated in
            guard updated.name == selectedName, !updated.name.isEmpty, !isBuiltInSelected else { return }
            scheduleSave(updated)
        }
    }

    /// Built-in layouts show above the saved ones; they're read-only
    /// (duplicate one to customize it).
    private var builtInLayouts: [ScreenCropLayout] {
        let shadowed = Set(layouts.map { $0.name.lowercased() })
        return ScreenCropStore.builtIn.filter { !shadowed.contains($0.name.lowercased()) }
    }

    private var isBuiltInSelected: Bool {
        selectedName.map { name in builtInLayouts.contains { $0.name == name } } ?? false
    }

    private var layoutList: some View {
        List(selection: $selectedName) {
            Section("Built-in") {
                ForEach(builtInLayouts) { item in
                    layoutRow(item, builtIn: true)
                }
            }
            Section("Custom") {
                if layouts.isEmpty {
                    Text("None yet — click + to draw one, or duplicate a built-in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(layouts) { item in
                    layoutRow(item, builtIn: false)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func layoutRow(_ item: ScreenCropLayout, builtIn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
            Text(item.areas.isEmpty ? "No areas yet"
                 : item.areas.map(\.name).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .tag(item.name)
        .contextMenu {
            if !builtIn {
                Button("Rename…") {
                    renameText = item.name
                    selectedName = item.name
                    renamePrompt = true
                }
            }
            Button(builtIn ? "Duplicate as Custom" : "Duplicate") { duplicate(item) }
            if !builtIn {
                Divider()
                Button("Move to Trash", role: .destructive) { deleteTarget = item.name }
            }
        }
    }

    private func refresh() {
        layouts = ScreenCropStore.list()
        if let selectedName, let match = layouts.first(where: { $0.name == selectedName }) {
            // Keep unsaved local edits over a stale disk read.
            if layout.name != selectedName { layout = match }
        } else if !isBuiltInSelected {
            selectedName = layouts.first?.name ?? builtInLayouts.first?.name
        }
    }

    private func scheduleSave(_ updated: ScreenCropLayout) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                try ScreenCropStore.save(updated)
                if let index = layouts.firstIndex(where: { $0.name == updated.name }) {
                    layouts[index] = updated
                }
            } catch {
                operationError = error.userMessage
            }
        }
    }

    private func createLayout() {
        let name = ScreenCropStore.uniqueName(base: "Screen Crop")
        let created = ScreenCropLayout(name: name)
        do {
            try ScreenCropStore.save(created)
            refresh()
            selectedName = name
            layout = created
        } catch {
            operationError = error.userMessage
        }
    }

    private func duplicate(_ item: ScreenCropLayout) {
        var copy = item
        copy.name = ScreenCropStore.uniqueName(base: item.name)
        do {
            try ScreenCropStore.save(copy)
            refresh()
            selectedName = copy.name
        } catch {
            operationError = error.userMessage
        }
    }

    private func renameSelected() {
        guard let selectedName else { return }
        do {
            let final = try ScreenCropStore.rename(selectedName, to: renameText)
            refresh()
            self.selectedName = final
        } catch {
            operationError = error.userMessage
        }
    }

    private func deleteConfirmed() {
        guard let target = deleteTarget else { return }
        do {
            try ScreenCropStore.delete(name: target)
            if selectedName == target { selectedName = nil }
            refresh()
        } catch {
            operationError = error.userMessage
        }
        deleteTarget = nil
    }
}

/// The 9:16 drawing canvas plus the area list. Click to place vertices
/// (straight lines); click the first point, double-click, or press Return
/// to close. Points near the canvas edge snap to it, and a shape that
/// starts on one edge and reaches another closes itself along the border.
/// Drag a vertex of the selected area to adjust it.
struct ScreenCropEditor: View {
    @Binding var layout: ScreenCropLayout
    /// Built-in layouts are shown but not editable.
    var readOnly = false

    @State private var drawing: [ScreenCropPoint] = []
    @State private var hoverPoint: CGPoint?
    @State private var selectedArea: String?
    @State private var dragging: (area: Int, vertex: Int)?
    @State private var lastClick: (time: Date, location: CGPoint)?
    @State private var drawMode = false
    @FocusState private var canvasFocused: Bool

    /// Vertices closer than this (points) to an edge snap onto it; clicks
    /// this close to the first vertex close the shape.
    private static let snapDistance: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                let frame = fittedFrame(in: geo.size)
                let origin = CGPoint(x: (geo.size.width - frame.width) / 2,
                                     y: (geo.size.height - frame.height) / 2)
                canvas(size: frame)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: origin.x, y: origin.y)
            }
            .padding(Theme.spaceL)
            .background(Color(nsColor: .underPageBackgroundColor))

            Divider()

            sidePanel
                .frame(width: 250)
        }
    }

    // MARK: - Canvas

    private func fittedFrame(in size: CGSize) -> CGSize {
        let scale = min(size.width / 9, size.height / 16)
        return CGSize(width: scale * 9, height: scale * 16)
    }

    private func canvas(size: CGSize) -> some View {
        let rect = CGRect(origin: .zero, size: size)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(white: 0.12))
            // Thirds guides — the same grid the render composes on.
            Path { path in
                for fraction in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: size.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                    path.move(to: CGPoint(x: 0, y: size.height * fraction))
                    path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                }
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            }
            .stroke(.white.opacity(0.08), lineWidth: 1)

            ForEach(layout.areas) { area in
                let selected = area.name == selectedArea
                ScreenCropPolygon(points: area.points)
                    .fill(selected ? Color.accentColor.opacity(0.4) : Color.accentColor.opacity(0.2))
                ScreenCropPolygon(points: area.points)
                    .stroke(selected ? Color.accentColor : Color.accentColor.opacity(0.7),
                            lineWidth: selected ? 2 : 1.5)
                let center = centroid(of: area.points, in: rect)
                Text(area.name)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.chipRadius))
                    .foregroundStyle(.white)
                    .position(center)
                    .allowsHitTesting(false)
                if selected {
                    ForEach(area.points.indices, id: \.self) { index in
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.white, lineWidth: 1))
                            .position(canvasPoint(area.points[index], in: rect))
                            .allowsHitTesting(false)
                    }
                }
            }

            if !drawing.isEmpty {
                Path { path in
                    path.move(to: canvasPoint(drawing[0], in: rect))
                    for point in drawing.dropFirst() {
                        path.addLine(to: canvasPoint(point, in: rect))
                    }
                    if let hoverPoint {
                        path.addLine(to: hoverPoint)
                    }
                }
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
                ForEach(drawing.indices, id: \.self) { index in
                    Circle()
                        .fill(index == 0 ? Color.yellow : Color.white)
                        .frame(width: index == 0 ? 14 : 8, height: index == 0 ? 14 : 8)
                        .position(canvasPoint(drawing[index], in: rect))
                        .allowsHitTesting(false)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoverPoint = location
            case .ended: hoverPoint = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !readOnly else { return }
                    if dragging == nil, drawing.isEmpty,
                       abs(value.translation.width) + abs(value.translation.height) > 3 {
                        dragging = vertex(at: value.startLocation, in: rect)
                    }
                    if let dragging {
                        moveVertex(dragging, to: value.location, in: rect)
                    }
                }
                .onEnded { value in
                    canvasFocused = true
                    guard !readOnly else { return }
                    if dragging != nil {
                        dragging = nil
                        return
                    }
                    guard abs(value.translation.width) + abs(value.translation.height) <= 4 else { return }
                    handleClick(at: value.location, in: rect)
                }
        )
        .focusable()
        .focused($canvasFocused)
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            guard !drawing.isEmpty else { return .ignored }
            drawing = []
            return .handled
        }
        .onKeyPress(.return) {
            guard drawing.count >= 3 else { return .ignored }
            closeDrawing()
            return .handled
        }
        .onDeleteCommand {
            if !drawing.isEmpty {
                drawing.removeLast()
            } else if let selectedArea {
                removeArea(named: selectedArea)
            }
        }
        .help(drawing.isEmpty
              ? "Click to start drawing an area; click inside an area to select it"
              : "Click to add a corner · click the first point, double-click, or press Return to close · Esc cancels")
    }

    // MARK: - Side panel

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text(layout.name)
                .font(.headline)
                .lineLimit(1)
            if readOnly {
                Label("Built-in layout — duplicate it (right-click in the list) to customize.",
                      systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(drawing.isEmpty
                 ? "Click the canvas to start an area. Straight lines only; edges snap to the border, and a shape that starts and ends on the border closes along it."
                 : "\(drawing.count) point\(drawing.count == 1 ? "" : "s") placed — click the first point, double-click, or press Return to close. Esc cancels, Delete removes the last point.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Always draw", isOn: $drawMode)
                .disabled(readOnly)
                .help("On: every click adds a point, even inside an existing area. Off: clicking inside an area selects it.")

            Divider()

            Text("Areas")
                .font(.subheadline.weight(.semibold))
            if layout.areas.isEmpty {
                Text("None yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            List(selection: $selectedArea) {
                ForEach(layout.areas.indices, id: \.self) { index in
                    let area = layout.areas[index]
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Area name", text: Binding(
                            get: { layout.areas[safe: index]?.name ?? "" },
                            set: { renameArea(at: index, to: $0) }))
                            .textFieldStyle(.plain)
                            .font(.callout.weight(.medium))
                            .disabled(readOnly)
                        Text(area.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text("Use as: \(ScreenCropStore.reference(layout: layout.name, area: area.name))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    .tag(area.name)
                    .contextMenu {
                        if !readOnly {
                            Button("Delete Area", role: .destructive) { removeArea(named: area.name) }
                        }
                    }
                }
            }
            .listStyle(.inset)

            if !readOnly, let selectedArea, layout.areas.contains(where: { $0.name == selectedArea }) {
                Button("Delete “\(selectedArea)”", role: .destructive) {
                    removeArea(named: selectedArea)
                }
                .controlSize(.small)
            }
        }
        .padding(Theme.spaceM)
    }

    // MARK: - Geometry

    private func canvasPoint(_ point: ScreenCropPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    private func centroid(of points: [ScreenCropPoint], in rect: CGRect) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let x = points.reduce(0) { $0 + $1.x } / Double(points.count)
        let y = points.reduce(0) { $0 + $1.y } / Double(points.count)
        return CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }

    /// Canvas location → normalized point, snapped to the border when close.
    private func normalized(_ location: CGPoint, in rect: CGRect) -> ScreenCropPoint {
        var x = (location.x - rect.minX) / rect.width
        var y = (location.y - rect.minY) / rect.height
        let snapX = Self.snapDistance / rect.width
        let snapY = Self.snapDistance / rect.height
        if x < snapX { x = 0 } else if x > 1 - snapX { x = 1 }
        if y < snapY { y = 0 } else if y > 1 - snapY { y = 1 }
        return ScreenCropPoint(x: x, y: y)
    }

    private func vertex(at location: CGPoint, in rect: CGRect) -> (area: Int, vertex: Int)? {
        guard let selectedArea,
              let areaIndex = layout.areas.firstIndex(where: { $0.name == selectedArea }) else { return nil }
        for (index, point) in layout.areas[areaIndex].points.enumerated() {
            let canvas = canvasPoint(point, in: rect)
            if hypot(canvas.x - location.x, canvas.y - location.y) <= Self.snapDistance {
                return (areaIndex, index)
            }
        }
        return nil
    }

    private func moveVertex(_ target: (area: Int, vertex: Int), to location: CGPoint, in rect: CGRect) {
        guard layout.areas.indices.contains(target.area),
              layout.areas[target.area].points.indices.contains(target.vertex) else { return }
        layout.areas[target.area].points[target.vertex] = normalized(location, in: rect)
    }

    // MARK: - Drawing

    private func handleClick(at location: CGPoint, in rect: CGRect) {
        let now = Date()
        let isDoubleClick = lastClick.map {
            now.timeIntervalSince($0.time) < 0.35
                && hypot($0.location.x - location.x, $0.location.y - location.y) < 6
        } ?? false
        lastClick = (now, location)
        let point = normalized(location, in: rect)

        if drawing.isEmpty {
            if !drawMode, let hit = layout.areas.last(where: { $0.contains(x: point.x, y: point.y) }) {
                selectedArea = hit.name
                return
            }
            selectedArea = nil
            drawing = [point]
            return
        }

        // Closing: back on the first point, a double-click, or — when the
        // shape started on the border and just reached it again — along
        // the border itself.
        let first = canvasPoint(drawing[0], in: rect)
        if drawing.count >= 3, hypot(first.x - location.x, first.y - location.y) <= Self.snapDistance {
            closeDrawing()
            return
        }
        if isDoubleClick {
            if drawing.count >= 3 { closeDrawing() }
            return
        }
        drawing.append(point)
        if point.onBorder, drawing[0].onBorder, drawing.count >= 2,
           !(drawing.count == 2 && sameEdge(drawing[0], point)) {
            closeAlongBorder()
        }
    }

    private func sameEdge(_ a: ScreenCropPoint, _ b: ScreenCropPoint) -> Bool {
        (a.x == 0 && b.x == 0) || (a.x == 1 && b.x == 1) || (a.y == 0 && b.y == 0) || (a.y == 1 && b.y == 1)
    }

    private func closeDrawing() {
        guard drawing.count >= 3 else { return }
        commit(drawing)
    }

    /// Position along the perimeter, 0…4: top edge 0→1, right 1→2,
    /// bottom 2→3, left 3→4 (clockwise from the top-left corner).
    private func perimeterPosition(_ point: ScreenCropPoint) -> Double {
        if point.y == 0 { return point.x }
        if point.x == 1 { return 1 + point.y }
        if point.y == 1 { return 2 + (1 - point.x) }
        return 3 + (1 - point.y)
    }

    private func perimeterPoint(_ position: Double) -> ScreenCropPoint {
        let t = position.truncatingRemainder(dividingBy: 4)
        switch t {
        case ..<1: return ScreenCropPoint(x: t, y: 0)
        case ..<2: return ScreenCropPoint(x: 1, y: t - 1)
        case ..<3: return ScreenCropPoint(x: 1 - (t - 2), y: 1)
        default: return ScreenCropPoint(x: 0, y: 1 - (t - 3))
        }
    }

    /// The shape reached the border again: walk the border from the last
    /// point back to the first, taking the shorter way round, adding the
    /// corners passed on the way.
    private func closeAlongBorder() {
        guard let start = drawing.first, let end = drawing.last else { return }
        let from = perimeterPosition(end)
        let to = perimeterPosition(start)
        let clockwise = (to - from + 4).truncatingRemainder(dividingBy: 4)
        let counter = 4 - clockwise
        var corners: [ScreenCropPoint] = []
        if clockwise <= counter {
            var position = ceil(from)
            if position == from { position += 1 }
            while position < from + clockwise {
                corners.append(perimeterPoint(position))
                position += 1
            }
        } else {
            var position = floor(from)
            if position == from { position -= 1 }
            while position > from - counter {
                corners.append(perimeterPoint(position + 4))
                position -= 1
            }
        }
        var points = drawing + corners
        // Drop a duplicate closing vertex if a corner landed on the start.
        if let last = points.last, last == start, points.count > 3 { points.removeLast() }
        guard points.count >= 3 else { drawing = []; return }
        commit(points)
    }

    private func commit(_ points: [ScreenCropPoint]) {
        var index = layout.areas.count + 1
        var name = "Area \(index)"
        while layout.areas.contains(where: { $0.name == name }) {
            index += 1
            name = "Area \(index)"
        }
        layout.areas.append(ScreenCropArea(name: name, points: points))
        drawing = []
        selectedArea = name
    }

    private func renameArea(at index: Int, to raw: String) {
        guard layout.areas.indices.contains(index) else { return }
        // The name is part of the "Layout/Area" reference: keep it
        // reference-safe (no slashes) and unique within the layout.
        var name = raw.replacingOccurrences(of: "/", with: "-")
        if name.isEmpty { name = "Area" }
        let collides = layout.areas.enumerated().contains { $0.offset != index && $0.element.name == name }
        if collides { return }
        let wasSelected = selectedArea == layout.areas[index].name
        layout.areas[index].name = name
        if wasSelected { selectedArea = name }
    }

    private func removeArea(named name: String) {
        layout.areas.removeAll { $0.name == name }
        if selectedArea == name { selectedArea = nil }
    }
}
