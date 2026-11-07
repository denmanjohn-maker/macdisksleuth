import MacDiskSleuthKit
import SwiftUI

/// "Fix": tick the members of a recommendation to move to the Trash, confirm
/// with Touch ID / Apple Watch / password, then do it in one batch. Works
/// from a member snapshot, so a recompute underneath never changes what the
/// user is looking at.
struct FixRecommendationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.typography) private var type
    @Environment(\.dismiss) private var dismiss

    let recommendation: Recommendation
    @State private var items: [Recommendation.Item]
    @State private var checked: Set<String>
    @State private var phase: Phase = .choosing

    private enum Phase {
        case choosing
        case authenticating
        case deleting
        case refused(String)
        case done(BatchTrashResult)
    }

    init(recommendation: Recommendation) {
        self.recommendation = recommendation
        _items = State(initialValue: recommendation.items)
        _checked = State(initialValue: recommendation.preselectedItemIDs)
    }

    private var context: RecommendationContext { model.recommendationContext }
    private var actionable: [Recommendation.Item] { items.filter { $0.node != nil } }
    private var checkedItems: [Recommendation.Item] { actionable.filter { checked.contains($0.id) } }
    private var checkedBytes: Int64 { checkedItems.reduce(Int64(0)) { $0 + $1.sizes.unique } }

    private var isChoosing: Bool {
        switch phase {
        case .choosing, .refused: true
        default: false
        }
    }

    private var isDone: Bool {
        if case .done = phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if case .done(let result) = phase {
                summary(result)
            } else {
                picker
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 440, idealHeight: 560)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Fix: \(recommendation.title)", systemImage: "checklist")
                    .font(type.title3.bold())
                    .lineLimit(2)
                Spacer()
                SafetyBadge(safety: recommendation.safety)
            }
            Text("Checked items are moved to the Trash, not deleted — you can put them back.")
                .font(type.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Select All") { checked = Set(actionable.map(\.id)) }
                Button("Select None") { checked = [] }
                Spacer()
                Text("\(checkedItems.count) of \(actionable.count) checked")
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .controlSize(.small)
            .disabled(!isChoosing)

            List(items) { item in
                row(item)
            }
            .listStyle(.inset)
            .frame(minHeight: 200)

            if recommendation.hiddenItemCount > 0 {
                Text("\(recommendation.hiddenItemCount) more not listed — scan the folder itself to see them.")
                    .font(type.caption2)
                    .foregroundStyle(.tertiary)
            }
            if case .refused(let message) = phase {
                Label(message, systemImage: "lock.slash")
                    .font(type.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ item: Recommendation.Item) -> some View {
        let canAct = item.node != nil
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: binding(for: item.id))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!canAct || !isChoosing)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.displayPath(item.path))
                    .font(type.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = item.note {
                    Text(note)
                        .font(type.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(ByteCount.format(item.sizes.unique))
                .font(type.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(canAct ? .primary : .tertiary)
        .help(canAct ? item.path : "Not in the scanned tree — can't be moved to the Trash from here")
        .contextMenu {
            if let node = item.node {
                Button("Reveal in Finder") { model.revealInFinder(node) }
            }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { checked.contains(id) },
            set: { on in
                if on { checked.insert(id) } else { checked.remove(id) }
            })
    }

    private func summary(_ result: BatchTrashResult) -> some View {
        let count = result.trashed.count
        return VStack(alignment: .leading, spacing: 10) {
            Label(
                "Moved \(count) item\(count == 1 ? "" : "s") to the Trash — \(ByteCount.format(result.freed)) freeable",
                systemImage: "checkmark.circle")
                .font(type.headline)
                .foregroundStyle(.green)
            if !result.failures.isEmpty {
                Text("\(result.failures.count) couldn't be moved:")
                    .font(type.callout)
                List(result.failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.displayPath(failure.path))
                            .font(type.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(failure.message)
                            .font(type.caption)
                            .foregroundStyle(.red)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 120)
            }
            if !model.snapshots.isEmpty {
                Text("◷ Local snapshots exist — freed space may appear gradually as they thin.")
                    .font(type.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("The recommendations update once they are recomputed for the edited scan.")
                .font(type.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !isDone {
                Text("Frees about \(ByteCount.format(checkedBytes)) now")
                    .font(type.callout.bold())
                    .foregroundStyle(checkedBytes > 0 ? Color.green : Color.secondary)
                if recommendation.sizes.physical > recommendation.sizes.unique {
                    Text("Bytes shared with clones or hard links elsewhere stay on disk; shared bytes charged at a common folder aren't counted here.")
                        .font(type.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.snapshots.isEmpty {
                    Text("◷ Local snapshots exist — freed space may appear gradually as they thin.")
                        .font(type.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Spacer()
                switch phase {
                case .done:
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                case .authenticating:
                    ProgressView().controlSize(.small)
                    Text("Waiting for authentication…").font(type.caption).foregroundStyle(.secondary)
                case .deleting:
                    ProgressView().controlSize(.small)
                    Text("Moving to the Trash…").font(type.caption).foregroundStyle(.secondary)
                case .choosing, .refused:
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(role: .destructive) {
                        startDeletion()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checkedItems.isEmpty)
                }
            }
        }
    }

    // MARK: - Actions

    private func startDeletion() {
        let nodes = checkedItems.compactMap(\.node)
        guard !nodes.isEmpty else { return }
        phase = .authenticating
        Task { @MainActor in
            let reason = "move \(nodes.count) item\(nodes.count == 1 ? "" : "s") to the Trash"
            switch await DeletionAuthenticator.authenticate(reason: reason) {
            case .failure(let message):
                phase = .refused(message)
            case .success:
                phase = .deleting
                let result = await model.moveToTrash(nodes)
                phase = .done(result)
            }
        }
    }
}
