import DiskSleuthKit
import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 6) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("DiskSleuth").font(.largeTitle.bold())
                Text("The disk analyzer that tells you the truth on APFS.")
                    .foregroundStyle(.secondary)
            }

            bootDiskCard

            if model.fdaStatus == .denied {
                fdaBanner
            }

            HStack(spacing: 12) {
                Button {
                    model.startScan(path: NSHomeDirectory())
                } label: {
                    Label("Scan Home Folder", systemImage: "house")
                        .frame(minWidth: 150)
                }
                .keyboardShortcut(.defaultAction)

                Button {
                    model.startScan(path: "/")
                } label: {
                    Label("Scan Whole Disk", systemImage: "internaldrive")
                        .frame(minWidth: 150)
                }

                Button {
                    model.pickAndScanFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                        .frame(minWidth: 150)
                }
            }
            .controlSize(.large)

            if let error = model.scanError {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            Spacer()
            Spacer()
        }
        .padding(40)
    }

    private var bootDiskCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Boot Disk").font(.headline)
                Spacer()
                if !model.snapshots.isEmpty {
                    Label("\(model.snapshots.count) local snapshots", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let cap = model.capacities {
                CapacityBar(capacities: cap)
                HStack(spacing: 14) {
                    legend(color: .accentColor, text: "Used \(ByteCount.format(cap.usedBytes - cap.purgeable))")
                    legend(
                        color: .orange.opacity(0.65),
                        text: "Purgeable \(ByteCount.format(cap.purgeable))")
                    legend(
                        color: Color(nsColor: .quaternaryLabelColor),
                        text: "Free \(ByteCount.format(cap.availableNow))")
                    Spacer()
                    Text("Finder sees \(ByteCount.format(cap.availableForImportantUsage)) available")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(16)
        .frame(maxWidth: 640)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }

    private var fdaBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access not granted").fontWeight(.semibold)
                Text("Protected folders (Mail, Messages, Photos…) will be skipped and honestly reported as unreadable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                if let url = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 640)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// used | purgeable | free, to scale.
struct CapacityBar: View {
    var capacities: VolumeCapacities

    var body: some View {
        GeometryReader { proxy in
            let total = max(Double(capacities.totalCapacity), 1)
            let usedFraction = Double(capacities.usedBytes - capacities.purgeable) / total
            let purgeableFraction = Double(capacities.purgeable) / total
            HStack(spacing: 1) {
                Rectangle().fill(Color.accentColor)
                    .frame(width: max(proxy.size.width * usedFraction, 2))
                Rectangle().fill(Color.orange.opacity(0.65))
                    .frame(width: max(proxy.size.width * purgeableFraction, 1))
                Rectangle().fill(Color(nsColor: .quaternaryLabelColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(height: 14)
    }
}

struct ScanProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("\(model.progress.filesSeen.formatted()) files · \(ByteCount.format(model.progress.physicalBytes)) physical")
                .font(.title3.monospacedDigit())
            Text(model.progress.currentPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
            if model.progress.deniedCount > 0 {
                Text("\(model.progress.deniedCount) folders unreadable so far")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button("Cancel") { model.cancelScan() }
                .keyboardShortcut(.cancelAction)
            Spacer()
        }
        .padding(40)
    }
}
