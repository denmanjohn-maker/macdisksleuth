import DiskSleuthKit
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    private var subject: NodeID? {
        model.hovered ?? model.selection ?? (model.graph != nil ? model.focus : nil)
    }

    var body: some View {
        Group {
            if let graph = model.graph, let node = subject {
                details(graph: graph, node: node)
            } else {
                Text("Select an item")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func details(graph: FileGraph, node: NodeID) -> some View {
        let sizes = graph.sizes(of: node)
        let flags = graph.flags(of: node)
        let isRoot = node == graph.root

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: flags.kind == .directory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(flags.kind == .directory ? Color.accentColor : .secondary)
                        Text(isRoot ? lastComponent(graph.rootPath) : graph.name(of: node))
                            .font(.headline)
                            .lineLimit(2)
                    }
                    Text(graph.path(of: node))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Divider()

                sizeRows(sizes)

                if !badgeLines(flags: flags, graph: graph, node: node).isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(badgeLines(flags: flags, graph: graph, node: node), id: \.self) {
                            Text($0).font(.caption)
                        }
                    }
                }

                Divider()

                freeableHeadline(sizes: sizes, flags: flags)

                if !model.snapshots.isEmpty {
                    Text("◷ \(model.snapshots.count) local snapshots exist — freed space may appear gradually as they thin.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Reveal in Finder") { model.revealInFinder(node) }
                    Spacer()
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    .disabled(isRoot)
                }
                .controlSize(.small)

                if let deleteError {
                    Text(deleteError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            "Move \"\(graph.name(of: node))\" to Trash?",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                deleteError = model.moveToTrash(node)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage(graph: graph, node: node))
        }
    }

    private func sizeRows(_ sizes: Sizes) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Logical").foregroundStyle(.secondary)
                Text(ByteCount.format(sizes.logical)).monospacedDigit()
            }
            GridRow {
                Text("Physical").foregroundStyle(.secondary)
                Text(ByteCount.format(sizes.physical)).monospacedDigit().fontWeight(.medium)
            }
            GridRow {
                Text("Freeable").foregroundStyle(.secondary)
                Text(ByteCount.format(sizes.unique)).monospacedDigit().foregroundStyle(.green)
            }
        }
        .font(.callout)
    }

    private func freeableHeadline(sizes: Sizes, flags: NodeFlags) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Deleting frees ~\(ByteCount.format(sizes.unique)) now")
                .font(.callout.bold())
                .foregroundStyle(sizes.unique > 0 ? Color.green : Color.secondary)
            if sizes.unique < sizes.physical {
                Text("\(ByteCount.format(sizes.physical - sizes.unique)) is shared with clones or hard links elsewhere.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func badgeLines(flags: NodeFlags, graph: FileGraph, node: NodeID) -> [String] {
        var lines: [String] = []
        if flags.cloned { lines.append("⧉ Clone — shares blocks with other files (APFS copy-on-write)") }
        if flags.hardlinked { lines.append("⛓ Hard-linked — one file, several names") }
        if flags.sparse { lines.append("▤ Sparse — holes occupy no disk space") }
        if flags.dataless { lines.append("☁ Content lives in the cloud, not on this disk") }
        if flags.compressed { lines.append("▣ Transparently compressed by macOS") }
        if flags.purgeable { lines.append("♻ Purgeable — macOS can evict this under pressure") }
        if flags.accessDenied { lines.append("⛔ Unreadable — real size unknown, totals undercount") }
        if flags.externalLinks { lines.append("✳ Shares bytes with content outside this folder") }
        if flags.duplicate { lines.append("↩ Counted where it was first seen") }
        if flags.firmlinkSkipped { lines.append("→ Counted at its firmlink location (e.g. /Users)") }
        if flags.otherVolume { lines.append("⇥ A different volume is mounted here — not included") }
        return lines
    }

    private func deleteMessage(graph: FileGraph, node: NodeID) -> String {
        let sizes = graph.sizes(of: node)
        var message = "This really frees about \(ByteCount.format(sizes.unique))"
        if sizes.unique < sizes.physical {
            message += " — \(ByteCount.format(sizes.physical - sizes.unique)) is shared with files elsewhere and stays on disk"
        }
        message += "."
        if !model.snapshots.isEmpty {
            message += " Local snapshots may delay the space appearing."
        }
        return message
    }
}
