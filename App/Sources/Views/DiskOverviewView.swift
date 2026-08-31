import DiskSleuthKit
import SwiftUI

/// The first space representation after a scan: one ring for the volume's
/// total capacity, with the used portion overlaid in a second color.
/// Clicking the ring (or the button) drills into the scanned folder.
struct DiskOverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var hoveringRing = false

    private var totalColor: Color { Color(nsColor: .quaternaryLabelColor) }
    private var usedColor: Color { .accentColor }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            donut
            legend
            exploreButton
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
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

    private var donut: some View {
        ZStack {
            Circle()
                .stroke(totalColor, lineWidth: ringThickness)
            Circle()
                .trim(from: 0, to: usedFraction)
                .stroke(
                    usedColor,
                    style: StrokeStyle(lineWidth: ringThickness, lineCap: .butt)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 4) {
                Text(volumeName)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text("\(ByteCount.format(usedBytes)) used")
                    .font(.title3)
                    .foregroundStyle(usedColor)
                Text("of \(ByteCount.format(totalBytes))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(usedFraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(ringThickness + 12)
        }
        .frame(width: donutDiameter, height: donutDiameter)
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
        .font(.callout)
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text)
        }
    }

    private var exploreButton: some View {
        Button {
            model.drillIntoScan()
        } label: {
            Label("Explore \(scanName)", systemImage: "arrow.down.circle")
                .frame(minWidth: 200)
        }
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .help("Drill down into the scanned folder")
    }

    private let donutDiameter: CGFloat = 320
    private let ringThickness: CGFloat = 44
}
