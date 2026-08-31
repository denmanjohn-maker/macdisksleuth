import DiskSleuthKit
import SwiftUI

/// The first space representation after a scan: one ring for the volume's
/// total capacity, with the used portion overlaid in a second color.
/// Clicking the ring (or the button) drills into the scanned folder.
/// The donut sizes itself to the window.
struct DiskOverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.typography) private var type
    @State private var hoveringRing = false

    private var totalColor: Color { Color(nsColor: .quaternaryLabelColor) }
    private var usedColor: Color { .accentColor }

    var body: some View {
        GeometryReader { proxy in
            // Leave room for the legend and button below the ring.
            let diameter = max(min(proxy.size.width * 0.8, proxy.size.height - 140), 220)
            VStack(spacing: 24) {
                Spacer(minLength: 0)
                donut(diameter: diameter)
                legend
                exploreButton
                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(24)
    }

    // MARK: - Numbers

    private var totalBytes: Int64 {
        model.volume?.totalBytes ?? model.capacities?.totalCapacity ?? 0
    }

    private var usedBytes: Int64 {
        model.volume?.usedBytes ?? model.capacities?.usedBytes ?? 0
    }

    private var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    private var volumeName: String {
        lastComponent(model.volume?.mountPoint ?? "/")
    }

    private var scanName: String {
        guard let graph = model.graph else { return "" }
        return lastComponent(graph.rootPath)
    }

    // MARK: - Pieces

    private func donut(diameter: CGFloat) -> some View {
        let thickness = diameter * 0.14
        return ZStack {
            Circle()
                .stroke(totalColor, lineWidth: thickness)
            Circle()
                .trim(from: 0, to: usedFraction)
                .stroke(
                    usedColor,
                    style: StrokeStyle(lineWidth: thickness, lineCap: .butt)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 4) {
                Text(volumeName)
                    .font(type.title2.bold())
                    .lineLimit(1)
                Text("\(ByteCount.format(usedBytes)) used")
                    .font(type.title3)
                    .foregroundStyle(usedColor)
                Text("of \(ByteCount.format(totalBytes))")
                    .font(type.callout)
                    .foregroundStyle(.secondary)
                Text(usedFraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(type.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(thickness + 12)
        }
        .padding(thickness / 2)
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .scaleEffect(hoveringRing ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hoveringRing)
        .onHover { hoveringRing = $0 }
        .onTapGesture { model.drillIntoScan() }
        .help("Click to explore what's using the space")
    }

    private var legend: some View {
        HStack(spacing: 20) {
            legendDot(color: usedColor, text: "Used \(ByteCount.format(usedBytes))")
            legendDot(
                color: totalColor,
                text: "Total \(ByteCount.format(totalBytes)) · free \(ByteCount.format(max(totalBytes - usedBytes, 0)))")
        }
        .font(type.callout)
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: type.size(10), height: type.size(10))
            Text(text)
        }
    }

    private var exploreButton: some View {
        Button {
            model.drillIntoScan()
        } label: {
            Label("Explore \(scanName)", systemImage: "arrow.down.circle")
                .font(type.body)
                .frame(minWidth: 200)
        }
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .help("Drill down into the scanned folder")
    }
}
