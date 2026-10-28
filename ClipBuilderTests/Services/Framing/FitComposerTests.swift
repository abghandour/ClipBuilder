import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Framing fit filter graphs")
struct FitComposerTests {
    private func spec(source: CGSize = CGSize(width: 1920, height: 1080),
                      fit: Framing.Fit = .blurredFill, feather: Double = 0.08, blur: Double = 0.5) -> FitSpec {
        FitSpec(sourceSize: source, destination: CGRect(x: 0, y: 0, width: 540, height: 960),
            canvasSize: CGSize(width: 540, height: 960), fit: fit, feather: feather, blur: blur)
    }

    @Test func fillCoversWithoutExtraInputs() throws {
        var inputs: [URL] = []
        let graph = try FitComposer.graph(spec(fit: .fill), inputLabel: "0:v", outputLabel: "out", extraInputs: &inputs)
        #expect(graph.contains("scale=540:960:force_original_aspect_ratio=increase,crop=540:960"))
        #expect(graph.hasSuffix("format=yuv420p[out]"))
        #expect(!graph.contains("boxblur") && inputs.isEmpty)
    }

    @Test(arguments: [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1080), CGSize(width: 400, height: 1200)])
    func mismatchedAspectHasBackgroundAndFeather(_ source: CGSize) throws {
        let spec = spec(source: source)
        var inputs: [URL] = []
        let graph = try FitComposer.graph(spec, inputLabel: "[source]", outputLabel: "[out]", extraInputs: &inputs)
        #expect(graph.contains("split=2") && graph.contains("boxblur=luma_radius=12.1500"))
        #expect(graph.contains("colorchannelmixer=rr=0.75:gg=0.75:bb=0.75"))
        #expect(graph.contains("scale=\(Int(spec.foreground.width)):\(Int(spec.foreground.height))"))
        #expect(graph.contains("format=rgba,alphaextract") && graph.contains("alphamerge"))
        #expect(inputs.count == 1)
        #expect(spec.horizontalBars != spec.verticalBars)
    }

    @Test func sameAspectNeedsNoFeatherOrBackground() throws {
        let spec = spec(source: CGSize(width: 1080, height: 1920))
        var inputs: [URL] = []
        let graph = try FitComposer.graph(spec, inputLabel: "0:v", outputLabel: "out", extraInputs: &inputs)
        #expect(!spec.horizontalBars && !spec.verticalBars)
        #expect(!graph.contains("boxblur") && !graph.contains("alphamerge") && inputs.isEmpty)
    }

    @Test(arguments: [FreeCropRect(xFrac: 0.25, yFrac: 0.25, wFrac: 0.5, hFrac: 0.5),
                      FreeCropRect(xFrac: 0.25, yFrac: 0.125, wFrac: 0.125, hFrac: 0.75)])
    func freeWindowIsContainedWithBlurredFeatheredFill(_ window: FreeCropRect) throws {
        var spec = spec()
        spec.sourceWindow = window
        #expect(spec.window == FocusFrame.rect(window))
        #expect(spec.destination.contains(spec.foreground))
        #expect(spec.foreground.midX == spec.destination.midX && spec.foreground.midY == spec.destination.midY)
        if spec.pixels.width / spec.pixels.height > spec.destination.width / spec.destination.height {
            #expect(spec.foreground.width == spec.destination.width && spec.foreground.height < spec.destination.height)
        } else {
            #expect(spec.foreground.height == spec.destination.height && spec.foreground.width < spec.destination.width)
        }
        var inputs: [URL] = []
        let graph = try FitComposer.graph(spec, inputLabel: "0:v", outputLabel: "out", extraInputs: &inputs)
        #expect(graph.hasPrefix("[0:v]crop="))
        #expect(graph.contains("split=2") && graph.contains("boxblur") && graph.contains("alphamerge"))
        #expect(graph.contains("scale=\(Int(spec.foreground.width)):\(Int(spec.foreground.height)),setsar=1,format=rgba"))
    }

    @Test(arguments: [0.0, 0.2])
    func featherEndpoints(_ feather: Double) throws {
        let spec = spec(feather: feather)
        var inputs: [URL] = []
        let graph = try FitComposer.graph(spec, inputLabel: "0:v", outputLabel: "out", extraInputs: &inputs)
        #expect(abs(spec.featherPixels - feather * 540) < 0.001)
        #expect(graph.contains("alphamerge") == (feather > 0))
        #expect(inputs.count == (feather > 0 ? 1 : 0))
        let mask = try ScreenCropStore.gradientMask(spec: spec)
        let edge = try FitTestImage.pixel(mask, x: mask.width / 2, y: 0)
        let centre = try FitTestImage.pixel(mask, x: mask.width / 2, y: mask.height / 2)
        #expect(edge[3] == (feather == 0 ? 255 : 0))
        #expect(centre[3] == 255)
    }

    @Test(arguments: [0.0, 1.0])
    func blurEndpointsAndSmallDestination(_ blur: Double) throws {
        var spec = spec(blur: blur)
        #expect(abs(spec.blurRadius - (blur == 0 ? 2.7 : 21.6)) < 0.0001)
        spec.destination = CGRect(x: 20, y: 40, width: 40, height: 80)
        #expect(spec.blurRadius == 2)
        var inputs: [URL] = []
        let graph = try FitComposer.graph(spec, inputLabel: "0:v", outputLabel: "out", extraInputs: &inputs)
        #expect(graph.contains("boxblur=luma_radius=2.0000"))
        #expect(graph.contains("pad=540:960:20:40"))
        spec.destination = CGRect(x: 0, y: 0, width: 4000, height: 8000)
        spec.blur = 1
        #expect(spec.blurRadius == 60)
    }

    @Test func cacheNamesIncludeOutputSizeAndFeatherAndLabelsAreUnique() throws {
        let directory = try TempDirectory()
        var spec = spec()
        let first = try ScreenCropStore.gradientMaskFile(spec: spec, in: directory.url)
        #expect(first.lastPathComponent.contains("540x960") && first.lastPathComponent.contains("feather0.080000"))
        #expect(try ScreenCropStore.gradientMaskFile(spec: spec, in: directory.url) == first)
        spec.canvasSize = CGSize(width: 1080, height: 1920)
        let resized = try ScreenCropStore.gradientMaskFile(spec: spec, in: directory.url)
        spec.feather = 0.2
        let softened = try ScreenCropStore.gradientMaskFile(spec: spec, in: directory.url)
        #expect(Set([first, resized, softened]).count == 3)
        var inputs: [URL] = []
        let a = try FitComposer.graph(spec, inputLabel: "0:v", outputLabel: "a", extraInputs: &inputs, inputOffset: 4)
        let b = try FitComposer.graph(spec, inputLabel: "1:v", outputLabel: "b", extraInputs: &inputs, inputOffset: 4)
        #expect(a.contains("[4:v]") && b.contains("[5:v]"))
        let namespaceA = try #require(a.range(of: "fit_"))
        let namespaceB = try #require(b.range(of: "fit_"))
        #expect(a[namespaceA.lowerBound...].prefix(36) != b[namespaceB.lowerBound...].prefix(36))
    }

    @Test func sourceWindowPrecedesSplitAndPolygonMaskUsesCanvasSize() throws {
        var spec = spec()
        spec.sourceWindow = FreeCropRect(xFrac: 0.1, yFrac: 0.1, wFrac: 0.8, hFrac: 0.8)
        spec.mask = ScreenCropArea(name: "Triangle", points: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 0.5, y: 1)])
        var inputs: [URL] = []
        let graph = try FitComposer.graph(spec, inputLabel: "0:v", outputLabel: "out", extraInputs: &inputs)
        #expect(graph.hasPrefix("[0:v]crop=iw*0.800000000:ih*0.800000000:iw*0.100000000:ih*0.100000000,split"))
        #expect(inputs.count == 2 && inputs[1].lastPathComponent.contains("540x960"))
        #expect(graph.contains("format=gray") && graph.contains("format=yuv420p[out]"))
    }
}
