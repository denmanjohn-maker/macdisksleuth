import DiskSleuthKit
import SwiftUI

struct ResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.atOverview {
                DiskOverviewView()
            } else {
                HSplitView {
                    SunburstView()
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)

                    VStack(spacing: 0) {
                        BreadcrumbBar()
                        Divider()
                        TreeListView()
                    }
                    .frame(minWidth: 320, maxWidth: .infinity)

                    InspectorView()
                        .frame(minWidth: 260, maxWidth: 320)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.up()
                } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .disabled(!model.canGoUp)
                .help("Go up — to the enclosing folder, or from the top folder back to the disk view (⌘↑)")

                Picker("Lens", selection: $model.lens) {
                    Text("Logical").tag(SizeLens.logical)
                    Text("Physical").tag(SizeLens.physical)
                    Text("Freeable").tag(SizeLens.unique)
                }
                .pickerStyle(.segmented)
                .help("Logical: what files claim · Physical: what the disk holds · Freeable: what deleting frees now")

                Button {
                    model.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { StatusBar() }
    }
}

struct BreadcrumbBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button {
                    model.goToOverview()
                } label: {
                    Label(diskName, systemImage: "internaldrive")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .help("Back to the disk view")

                ForEach(Array(model.breadcrumbs.enumerated()), id: \.element) { _, node in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Button {
                        model.drill(to: node)
                    } label: {
                        Text(crumbName(node))
                            .fontWeight(node == model.focus ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .font(.callout)
    }

    private var diskName: String {
        lastComponent(model.volume?.mountPoint ?? "/")
    }

    private func crumbName(_ node: NodeID) -> String {
        guard let graph = model.graph else { return "" }
        return node == graph.root ? lastComponent(graph.rootPath) : graph.name(of: node)
    }
}

struct TreeListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let rows = listRows()
        List(selection: $model.selection) {
            ForEach(rows) { row in
                TreeRow(row: row)
                    .tag(row.id)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: NodeID.self) { nodes in
            if let node = nodes.first {
                Button("Reveal in Finder") { model.revealInFinder(node) }
            }
        } primaryAction: { nodes in
            if let node = nodes.first {
                model.drill(to: node)
            }
        }
    }

    private func listRows() -> [TreeRowData] {
        guard let graph = model.graph else { return [] }
        let children = graph.children(of: model.focus)
        let ranked = model.lens == .physical
            ? children
            : children.sorted {
                graph.size(of: $0, lens: model.lens) > graph.size(of: $1, lens: model.lens)
            }
        let focusSize = max(graph.size(of: model.focus, lens: model.lens), 1)
        return ranked.map { node in
            TreeRowData(
                id: node,
                name: graph.name(of: node),
                kind: graph.kind(of: node),
                flags: graph.flags(of: node),
                bytes: graph.size(of: node, lens: model.lens),
                fraction: Double(graph.size(of: node, lens: model.lens)) / Double(focusSize)
            )
        }
    }
}

struct TreeRowData: Identifiable {
    var id: NodeID
    var name: String
    var kind: NodeKind
    var flags: NodeFlags
    var bytes: Int64
    var fraction: Double
}

struct TreeRow: View {
    @Environment(AppModel.self) private var model
    var row: TreeRowData

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(row.kind == .directory ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).lineLimit(1)
                    badgeIcons
                }
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor.opacity(0.65))
                                .frame(width: max(proxy.size.width * row.fraction, 1))
                        }
                }
                .frame(height: 3)
            }
            Spacer()
            Text(ByteCount.format(row.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch row.kind {
        case .directory: "folder.fill"
        case .symlink: "arrow.triangle.turn.up.right.diamond"
        case .file: "doc"
        case .other: "questionmark.square.dashed"
        }
    }

    @ViewBuilder private var badgeIcons: some View {
        HStack(spacing: 3) {
            if row.flags.cloned { badge("⧉", "Clone — shares blocks") }
            if row.flags.hardlinked { badge("⛓", "Hard-linked") }
            if row.flags.sparse { badge("▤", "Sparse") }
            if row.flags.dataless { badge("☁", "In cloud, not on disk") }
            if row.flags.compressed { badge("▣", "Compressed") }
            if row.flags.accessDenied { badge("⛔", "Unreadable — undercounted") }
            if row.flags.externalLinks { badge("✳", "Shares bytes with content elsewhere") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func badge(_ symbol: String, _ help: String) -> some View {
        Text(symbol).help(help)
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            if let graph = model.graph {
                let summary = graph.summary
                Text("\(summary.fileCount.formatted()) files")
                Text("logical \(ByteCount.format(summary.totalLogical))")
                Text("physical \(ByteCount.format(summary.totalPhysical))").fontWeight(.medium)
                Text("freeable \(ByteCount.format(summary.totalUnique))")
                if summary.partial {
                    Label("partial scan", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if summary.deniedDirectoryCount > 0 {
                    Label("\(summary.deniedDirectoryCount) unreadable", systemImage: "lock")
                        .foregroundStyle(.orange)
                        .help("Totals undercount. Grant Full Disk Access in System Settings → Privacy & Security.")
                }
                Spacer()
                if !model.snapshots.isEmpty {
                    Label("\(model.snapshots.count) snapshots", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .help("Local Time Machine snapshots exist — freed space may appear gradually as they thin.")
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
