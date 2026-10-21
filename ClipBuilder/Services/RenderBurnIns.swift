import Foundation

/// The extract and segment passes share one overlay clock and animation graph.
nonisolated enum RenderBurnIns {
    static func intersecting(_ overlays: [RenderEngine.ClipOverlay], start: Double,
                             duration: Double, totalDuration: Double) -> [RenderEngine.ClipOverlay] {
        overlays.filter {
            // extractClip only gates an overlay when both bounds are supplied.
            if let lower = $0.start, let upper = $0.end {
                return lower < start + duration && upper > start
            }
            return start < totalDuration && start + duration > 0
        }
    }

    static func append(_ overlays: [RenderEngine.ClipOverlay], duration: Double, offset: Double,
                       firstInput: Int, previous: String, output: String, filters: inout [String]) {
        var previous = previous
        let time = String(format: "(t+%.6f)", offset)
        for (index, overlay) in overlays.enumerated() {
            let label = index == overlays.count - 1 ? output : "[burn\(index)]"
            var input = "[\(firstInput + index):v]"
            var x = "\(overlay.x)", y = "\(overlay.y)"
            if let animation = overlay.animation {
                let anim = min(0.4, max(0.15, duration / 3))
                let fadeIn = animation == "fade" ? anim : min(0.18, anim)
                let animated = "[burnanim\(index)]"
                // Evaluate fades on the document clock, then restore the local
                // segment clock. A fade spanning a cut continues at that cut.
                filters.append(input + String(format:
                    "setpts=PTS+%.6f/TB,format=rgba,fade=t=in:st=0:d=%.3f:alpha=1,fade=t=out:st=%.3f:d=%.3f:alpha=1,setpts=PTS-%.6f/TB",
                    offset, fadeIn, duration - anim, anim, offset) + animated)
                input = animated
                switch animation {
                case "pop": y = String(format: "if(lt(%@,%.3f),round(H*0.05*pow(1-%@/%.3f,3)),0)", time, anim, time, anim)
                case "slide_up": y = String(format: "if(lt(%@,%.3f),H-H*%@/%.3f,0)", time, anim, time, anim)
                case "slide_left": x = String(format: "if(lt(%@,%.3f),-W+W*%@/%.3f,0)", time, anim, time, anim)
                case "slide_right": x = String(format: "if(lt(%@,%.3f),W-W*%@/%.3f,0)", time, anim, time, anim)
                default: break
                }
            }
            var step = "\(previous)\(input)overlay=x='\(x)':y='\(y)'"
            if let start = overlay.start, let end = overlay.end {
                step += String(format: ":enable='gte(t,%.6f)*lt(t,%.6f)'", start - offset, end - offset)
            }
            filters.append(step + label)
            previous = label
        }
    }
}
