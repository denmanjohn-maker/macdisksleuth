import DiskSleuthKit
import SwiftUI

struct SunburstView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    @State private var segments: [SunburstSegment] = []
    @State private var hoveredSegmentID: String?

    private let ringCount = 4

    private var layoutKey: String {
        "\(model.graphStamp)-\(model.focus.raw)-\(model.lens.rawValue)"
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let minDim = min(size.width, size.height)
            let centerRadius = minDim * 0.14
            let ringThickness = (minDim / 2 - centerRadius - 8) / CGFloat(ringCount)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            ZStack {
                Canvas { context, _ in
                    for segment in segments {
                        let path = arcPath(
                            segment: segment, center: center,
                            centerRadius: centerRadius, ringThickness: ringThickness)
                        context.fill(path, with: .color(fillColor(for: segment)))
                        context.stroke(
                            path, with: .color(Color(nsColor: .windowBackgroundColor)),
                            lineWidth: 1)
                        if segment.id == hoveredSegmentID {
                            context.stroke(path, with: .color(.primary.opacity(0.8)), lineWidth: 2)
                        }
                    }
                }

                centerLabel(radius: centerRadius)

                if let hovered = hoveredSegment {
                    VStack {
                        Spacer()
                        hoverCaption(hovered)
                    }
                    .padding(.bottom, 4)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    handleTap(
                        at: value.location, center: center,
                        centerRadius: centerRadius, ringThickness: ringThickness)
                }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let segment = segmentAt(
                        location, center: center, centerRadius: centerRadius,
                        ringThickness: ringThickness)
                    hoveredSegmentID = segment?.id
                    if case .node(let node) = segment?.target {
                        model.hovered = node
                    } else {
                        model.hovered = nil
                    }
                case .ended:
                    hoveredSegmentID = nil
                    model.hovered = nil
                }
            }
        }
        .task(id: layoutKey) { relayout() }
    }

    private var hoveredSegment: SunburstSegment? {
        hoveredSegmentID.flatMap { id in segments.first { $0.id == id } }
    }

    private func relayout() {
        guard let graph = model.graph else {
            segments = []
            return
        }
        segments = SunburstLayout.segments(
            graph: graph, focus: model.focus, lens: model.lens, rings: ringCount)
    }

    // MARK: - Geometry

    private func angle(for fraction: Double) -> Angle {
        .radians(fraction * 2 * .pi - .pi / 2)
    }

    private func arcPath(
        segment: SunburstSegment, center: CGPoint,
        centerRadius: CGFloat, ringThickness: CGFloat
    ) -> Path {
        let inner = centerRadius + CGFloat(segment.ring) * ringThickness + 1
        let outer = inner + ringThickness - 2
        var path = Path()
        path.addArc(
            center: center, radius: outer,
            startAngle: angle(for: segment.startFraction),
            endAngle: angle(for: segment.endFraction), clockwise: false)
        path.addArc(
            center: center, radius: inner,
            startAngle: angle(for: segment.endFraction),
            endAngle: angle(for: segment.startFraction), clockwise: true)
        path.closeSubpath()
        return path
    }

    private func segmentAt(
        _ point: CGPoint, center: CGPoint, centerRadius: CGFloat, ringThickness: CGFloat
    ) -> SunburstSegment? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = sqrt(dx * dx + dy * dy)
        guard radius > centerRadius else { return nil }
        let ring = Int((radius - centerRadius) / ringThickness)
        guard ring >= 0 && ring < ringCount else { return nil }
        var fraction = atan2(dx, -dy) / (2 * .pi)  // 0 at 12 o'clock, clockwise
        if fraction < 0 { fraction += 1 }
        return SunburstLayout.hitTest(segments: segments, fraction: fraction, ring: ring)
    }

    private func handleTap(
        at point: CGPoint, center: CGPoint, centerRadius: CGFloat, ringThickness: CGFloat
    ) {
        let dx = point.x - center.x
        let dy = point.y - center.y
        if sqrt(dx * dx + dy * dy) <= centerRadius {
            model.up()
            return
        }
        guard let segment = segmentAt(
            point, center: center, centerRadius: centerRadius, ringThickness: ringThickness)
        else { return }
        if case .node(let node) = segment.target {
            if segment.isDirectory {
                model.drill(to: node)
            } else {
                model.selection = node
            }
        }
    }

    // MARK: - Color & labels

    private func fillColor(for segment: SunburstSegment) -> Color {
        if case .other = segment.target {
            return Color(white: colorScheme == .dark ? 0.32 : 0.82)
        }
        if segment.flags.accessDenied {
            return Color(white: colorScheme == .dark ? 0.4 : 0.65)
        }
        if segment.flags.dataless {
            return Color(hue: 0.58, saturation: 0.18, brightness: colorScheme == .dark ? 0.55 : 0.88)
        }
        let saturation = max(0.62 - Double(segment.ring) * 0.1, 0.25)
        let brightness = colorScheme == .dark
            ? min(0.62 + Double(segment.ring) * 0.06, 0.85)
            : min(0.82 + Double(segment.ring) * 0.035, 0.95)
        return Color(hue: segment.hue, saturation: saturation, brightness: brightness)
    }

    private func centerLabel(radius: CGFloat) -> some View {
        VStack(spacing: 2) {
            if let graph = model.graph {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.large)
                Text(model.focus == graph.root ? lastComponent(graph.rootPath) : graph.name(of: model.focus))
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(ByteCount.format(graph.size(of: model.focus, lens: model.lens)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: radius * 1.8, height: radius * 1.8)
        .contentShape(Circle())
    }

    private func hoverCaption(_ segment: SunburstSegment) -> some View {
        HStack(spacing: 6) {
            Text(segment.name).fontWeight(.medium).lineLimit(1)
            Text(ByteCount.format(segment.bytes)).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
    }
}

func lastComponent(_ path: String) -> String {
    path == "/" ? "Macintosh HD" : (path.split(separator: "/").last.map(String.init) ?? path)
}
