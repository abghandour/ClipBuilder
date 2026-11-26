import SwiftUI

/// The drawn face that stands for a stock voice. Illustration colours are
/// fixed: the picture is the same in light and dark appearance.
struct VoiceFaceView: View {
    let face: VoiceFace
    var size: CGFloat = 36

    var body: some View {
        Canvas { context, canvas in
            context.scaleBy(x: canvas.width / 100, y: canvas.height / 100)
            VoiceFaceArt(face: face).draw(in: &context)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Draws in a 100 × 100 space: head centred at (50, 50), shoulders running off the bottom.
private struct VoiceFaceArt {
    let face: VoiceFace

    private static let skins: [(Color, Color)] = [
        (rgb(0xF8D9C0), rgb(0xE5B595)), (rgb(0xF0C49E), rgb(0xD9A379)), (rgb(0xDDA77B), rgb(0xC18A5E)),
        (rgb(0xBF8556), rgb(0xA26B40)), (rgb(0x96603A), rgb(0x7A4A2A)), (rgb(0x6B4226), rgb(0x54321B)),
    ]
    private static let hairs: [Color] = [
        rgb(0x1E1B1A), rgb(0x3D2A1E), rgb(0x6B4423), rgb(0x9C4A22), rgb(0xD9A84E), rgb(0x8E9196), rgb(0xE9E6E0),
    ]
    private static let backgrounds: [(Color, Color)] = [
        (rgb(0xE8674F), rgb(0x2B3A55)), (rgb(0xF2B13C), rgb(0x2E5E4E)), (rgb(0x4FB286), rgb(0x8A3B5C)),
        (rgb(0x4A90D9), rgb(0xF2E3C6)), (rgb(0x8E6FD1), rgb(0xF2C14E)), (rgb(0x35A7A0), rgb(0xE85D4A)),
        (rgb(0xE77FA4), rgb(0x2F4B7C)), (rgb(0x7C8B9A), rgb(0xE8674F)),
    ]
    private static let ink = rgb(0x231C1A)
    private static let steel = rgb(0xAEB6BF), steelDark = rgb(0x76808C)

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    private var skin: Color { Self.skins[face.skin % Self.skins.count].0 }
    private var shade: Color { Self.skins[face.skin % Self.skins.count].1 }
    private var hair: Color { Self.hairs[face.hairColor % Self.hairs.count] }
    private var ground: Color { Self.backgrounds[face.background % Self.backgrounds.count].0 }
    private var shirt: Color { Self.backgrounds[face.background % Self.backgrounds.count].1 }
    private var hatCoversHair: Bool { [.beanie, .cap, .helmet].contains(face.accessory) }

    private static let head = CGRect(x: 27, y: 24, width: 46, height: 52)

    func draw(in context: inout GraphicsContext) {
        context.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)), with: .color(ground))
        backHair(&context)
        context.fill(Path(ellipseIn: CGRect(x: 10, y: 80, width: 80, height: 50)), with: .color(shirt))
        context.fill(Path(roundedRect: CGRect(x: 42, y: 64, width: 16, height: 24), cornerRadius: 7), with: .color(shade))
        for x in [27.0, 73.0] {
            context.fill(Path(ellipseIn: CGRect(x: x - 5, y: 47, width: 10, height: 12)), with: .color(shade))
        }
        context.fill(Path(ellipseIn: Self.head), with: .color(skin))
        facialHair(&context)
        if !hatCoversHair { frontHair(&context) }
        features(&context)
        accessory(&context)
    }

    // MARK: Hair

    private func backHair(_ context: inout GraphicsContext) {
        guard !hatCoversHair || face.hair == .long || face.hair == .bob else { return }
        switch face.hair {
        case .long:
            context.fill(Path(roundedRect: CGRect(x: 20, y: 20, width: 60, height: 74), cornerRadius: 26), with: .color(hair))
        case .bob:
            context.fill(Path(roundedRect: CGRect(x: 19, y: 20, width: 62, height: 50), cornerRadius: 24), with: .color(hair))
        case .bun:
            context.fill(Path(ellipseIn: CGRect(x: 39, y: 6, width: 22, height: 22)), with: .color(hair))
        case .ponytail:
            context.fill(Path(ellipseIn: CGRect(x: 68, y: 26, width: 16, height: 44)), with: .color(hair))
        default: break
        }
    }

    /// The region between the skull's outline and a hairline across the forehead.
    private func cap(left: CGPoint, right: CGPoint, control1: CGPoint, control2: CGPoint, lift: CGFloat = 0) -> Path {
        var path = Path()
        path.move(to: left)
        path.addCurve(to: CGPoint(x: 50, y: 21 - lift), control1: CGPoint(x: 24, y: 30 - lift), control2: CGPoint(x: 34, y: 21 - lift))
        path.addCurve(to: right, control1: CGPoint(x: 66, y: 21 - lift), control2: CGPoint(x: 76, y: 30 - lift))
        path.addCurve(to: left, control1: control2, control2: control1)
        path.closeSubpath()
        return path
    }

    private func frontHair(_ context: inout GraphicsContext) {
        let left = CGPoint(x: 26.5, y: 47), right = CGPoint(x: 73.5, y: 47)
        let even = cap(left: left, right: right, control1: CGPoint(x: 34, y: 33), control2: CGPoint(x: 66, y: 33))
        let parted = cap(left: left, right: right, control1: CGPoint(x: 30, y: 42), control2: CGPoint(x: 56, y: 26))
        switch face.hair {
        case .bald:
            break
        case .buzz:
            context.fill(cap(left: CGPoint(x: 27, y: 43), right: CGPoint(x: 73, y: 43),
                             control1: CGPoint(x: 36, y: 31), control2: CGPoint(x: 64, y: 31)),
                         with: .color(hair.opacity(0.62)))
        case .short, .bun, .ponytail:
            context.fill(even, with: .color(hair))
        case .sidePart, .long:
            context.fill(parted, with: .color(hair))
        case .quiff:
            context.fill(cap(left: left, right: right, control1: CGPoint(x: 34, y: 36), control2: CGPoint(x: 66, y: 34), lift: 7),
                         with: .color(hair))
        case .bob:
            // A straight fringe.
            context.fill(cap(left: left, right: right, control1: CGPoint(x: 30, y: 38), control2: CGPoint(x: 70, y: 38)),
                         with: .color(hair))
        case .curly:
            context.fill(even, with: .color(hair))
            for (x, y, r) in [(29.0, 36.0, 8.0), (36, 26, 9), (46, 21, 9.5), (57, 21, 9.5), (66, 27, 9), (72, 37, 8)] {
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(hair))
            }
        }
    }

    private func facialHair(_ context: inout GraphicsContext) {
        switch face.facialHair {
        case .none:
            break
        case .beard, .stubble:
            // A band along the jaw: the lower head, minus the cheeks and mouth.
            let full = face.facialHair == .beard
            var layer = context
            layer.clip(to: Path(CGRect(x: 0, y: 50, width: 100, height: 50)))
            layer.fill(Path(ellipseIn: Self.head.insetBy(dx: full ? -0.6 : 0, dy: full ? -1.2 : 0)),
                       with: .color(full ? hair : hair.opacity(0.3)))
            context.fill(Path(ellipseIn: full ? CGRect(x: 33, y: 40, width: 34, height: 24)
                                              : CGRect(x: 31, y: 36, width: 38, height: 33)), with: .color(skin))
        case .moustache:
            var path = Path()
            path.move(to: CGPoint(x: 50, y: 60.5))
            path.addQuadCurve(to: CGPoint(x: 39.5, y: 64.5), control: CGPoint(x: 43, y: 59))
            path.addQuadCurve(to: CGPoint(x: 50, y: 63.5), control: CGPoint(x: 45, y: 65.5))
            path.addQuadCurve(to: CGPoint(x: 60.5, y: 64.5), control: CGPoint(x: 55, y: 65.5))
            path.addQuadCurve(to: CGPoint(x: 50, y: 60.5), control: CGPoint(x: 57, y: 59))
            context.fill(path, with: .color(hair))
        }
    }

    // MARK: Features

    private func features(_ context: inout GraphicsContext) {
        let line = StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        if face.accessory != .sunglasses {
            for x in [41.0, 59.0] {
                context.fill(Path(ellipseIn: CGRect(x: x - 2.6, y: 49.4, width: 5.2, height: 5.6)), with: .color(Self.ink))
            }
            for side in [-1.0, 1.0] {
                let x = 50 + side * 9
                var brow = Path()
                switch face.brows {
                case .soft:
                    brow.move(to: CGPoint(x: x - 4, y: 44.5))
                    brow.addQuadCurve(to: CGPoint(x: x + 4, y: 44.5), control: CGPoint(x: x, y: 42.8))
                case .raised:
                    brow.move(to: CGPoint(x: x - 4, y: 43))
                    brow.addQuadCurve(to: CGPoint(x: x + 4, y: 43), control: CGPoint(x: x, y: 40))
                case .stern:
                    // Inner ends pulled down toward the nose.
                    brow.move(to: CGPoint(x: x - side * 4, y: 45.6))
                    brow.addLine(to: CGPoint(x: x + side * 4, y: 42.6))
                }
                let lightHair = face.hairColor >= 4
                context.stroke(brow, with: .color(lightHair ? shade : hair), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        var nose = Path()
        nose.move(to: CGPoint(x: 50, y: 53))
        nose.addQuadCurve(to: CGPoint(x: 51.5, y: 59), control: CGPoint(x: 46.5, y: 59))
        context.stroke(nose, with: .color(shade), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

        // On a full beard a dark mouth disappears: draw it light.
        let lips: Color = face.facialHair == .beard && face.hairColor < 4 ? Self.rgb(0xF4E9E2) : Self.ink
        let y: CGFloat = face.facialHair == .moustache ? 67.5 : 65
        var mouth = Path()
        switch face.mouth {
        case .smile:
            mouth.move(to: CGPoint(x: 43.5, y: y))
            mouth.addQuadCurve(to: CGPoint(x: 56.5, y: y), control: CGPoint(x: 50, y: y + 6))
            context.stroke(mouth, with: .color(lips), style: line)
        case .grin:
            mouth.move(to: CGPoint(x: 42.5, y: y - 0.5))
            mouth.addQuadCurve(to: CGPoint(x: 57.5, y: y - 0.5), control: CGPoint(x: 50, y: y + 10))
            mouth.closeSubpath()
            context.fill(mouth, with: .color(Self.rgb(0xFFFFFF)))
            context.stroke(mouth, with: .color(Self.ink), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        case .neutral:
            mouth.move(to: CGPoint(x: 44.5, y: y + 1.5))
            mouth.addLine(to: CGPoint(x: 55.5, y: y + 1.5))
            context.stroke(mouth, with: .color(lips), style: line)
        case .smirk:
            mouth.move(to: CGPoint(x: 44, y: y + 2))
            mouth.addQuadCurve(to: CGPoint(x: 57, y: y - 1), control: CGPoint(x: 52, y: y + 4.5))
            context.stroke(mouth, with: .color(lips), style: line)
        }
    }

    // MARK: Accessories

    private func accessory(_ context: inout GraphicsContext) {
        switch face.accessory {
        case .none:
            break
        case .glasses, .sunglasses:
            let dark = face.accessory == .sunglasses
            let frame = StrokeStyle(lineWidth: 1.8, lineCap: .round)
            for x in [41.0, 59.0] {
                let lens = Path(roundedRect: CGRect(x: x - 6.5, y: 46.5, width: 13, height: 11), cornerRadius: dark ? 4 : 5)
                if dark { context.fill(lens, with: .color(Self.ink)) }
                context.stroke(lens, with: .color(Self.ink), style: frame)
            }
            var bridge = Path()
            bridge.move(to: CGPoint(x: 47.5, y: 51))
            bridge.addLine(to: CGPoint(x: 52.5, y: 51))
            bridge.move(to: CGPoint(x: 34.5, y: 50.5))
            bridge.addLine(to: CGPoint(x: 27.5, y: 49))
            bridge.move(to: CGPoint(x: 65.5, y: 50.5))
            bridge.addLine(to: CGPoint(x: 72.5, y: 49))
            context.stroke(bridge, with: .color(Self.ink), style: frame)
        case .headphones, .headset:
            var band = Path()
            band.addArc(center: CGPoint(x: 50, y: 50), radius: 29, startAngle: .degrees(184), endAngle: .degrees(356), clockwise: false)
            context.stroke(band, with: .color(Self.ink), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            for x in [17.0, 72.0] {
                context.fill(Path(roundedRect: CGRect(x: x, y: 42, width: 11, height: 21), cornerRadius: 5), with: .color(Self.ink))
                context.fill(Path(roundedRect: CGRect(x: x + 3.5, y: 46, width: 4, height: 13), cornerRadius: 2), with: .color(shirt))
            }
            if face.accessory == .headset {
                var boom = Path()
                boom.move(to: CGPoint(x: 23, y: 61))
                boom.addQuadCurve(to: CGPoint(x: 41, y: 70), control: CGPoint(x: 25, y: 72))
                context.stroke(boom, with: .color(Self.ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: 38.5, y: 67, width: 7, height: 6)), with: .color(Self.ink))
            }
        case .beanie:
            let dome = cap(left: CGPoint(x: 25, y: 38), right: CGPoint(x: 75, y: 38),
                           control1: CGPoint(x: 40, y: 38), control2: CGPoint(x: 60, y: 38), lift: 3)
            context.fill(dome, with: .color(shirt))
            context.fill(Path(roundedRect: CGRect(x: 23, y: 33, width: 54, height: 9), cornerRadius: 4.5), with: .color(shirt))
            context.fill(Path(roundedRect: CGRect(x: 23, y: 33, width: 54, height: 9), cornerRadius: 4.5), with: .color(.black.opacity(0.18)))
            context.fill(Path(ellipseIn: CGRect(x: 44.5, y: 9, width: 11, height: 11)), with: .color(shirt))
        case .cap:
            let dome = cap(left: CGPoint(x: 25.5, y: 38), right: CGPoint(x: 74.5, y: 38),
                           control1: CGPoint(x: 40, y: 38), control2: CGPoint(x: 60, y: 38), lift: 1)
            context.fill(dome, with: .color(shirt))
            var brim = Path()
            brim.move(to: CGPoint(x: 26, y: 38))
            brim.addQuadCurve(to: CGPoint(x: 86, y: 40), control: CGPoint(x: 60, y: 30))
            brim.addQuadCurve(to: CGPoint(x: 26, y: 38), control: CGPoint(x: 58, y: 42))
            context.fill(brim, with: .color(shirt))
            context.fill(brim, with: .color(.black.opacity(0.22)))
        case .helmet:
            let dome = cap(left: CGPoint(x: 24, y: 42), right: CGPoint(x: 76, y: 42),
                           control1: CGPoint(x: 40, y: 40), control2: CGPoint(x: 60, y: 40), lift: 2)
            context.fill(dome, with: .color(Self.steel))
            context.fill(Path(roundedRect: CGRect(x: 23, y: 37, width: 54, height: 6), cornerRadius: 2), with: .color(Self.steelDark))
            context.fill(Path(roundedRect: CGRect(x: 47.5, y: 37, width: 5, height: 19), cornerRadius: 2), with: .color(Self.steelDark))
            context.fill(Path(roundedRect: CGRect(x: 47.5, y: 12, width: 5, height: 14), cornerRadius: 2.5), with: .color(Self.steelDark))
        case .earrings:
            for x in [27.0, 73.0] {
                context.fill(Path(ellipseIn: CGRect(x: x - 2.6, y: 59, width: 5.2, height: 5.2)), with: .color(Self.rgb(0xF2C14E)))
            }
        }
    }
}
