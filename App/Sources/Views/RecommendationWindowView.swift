import MacDiskSleuthKit
import SwiftUI

/// One recommendation in its own window, opened from a card. Looks the live
/// recommendation up by id on every render, so it follows recomputes and
/// says so when the recommendation no longer applies.
struct RecommendationWindowView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.typography) private var type
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    var recommendationID: String?
    @State private var lastTitle = "Recommendation"
    /// Presented from the window root so the summary survives the detail view
    /// being swapped for "no longer applies" once the list recomputes.
    @State private var fixing: Recommendation?

    private var recommendation: Recommendation? {
        guard let recommendationID, let report = model.recommendations else { return nil }
        if let found = report.recommendations.first(where: { $0.id == recommendationID }) { return found }
        if let advice = report.volumeAdvice, advice.id == recommendationID { return advice }
        return nil
    }

    var body: some View {
        Group {
            if let recommendation {
                RecommendationDetailView(recommendation: recommendation) { fixing = $0 }
                    .onAppear { lastTitle = recommendation.title }
                    .onChange(of: recommendation.title) { newTitle in lastTitle = newTitle }
            } else if model.graph == nil {
                placeholder(
                    symbol: "internaldrive", title: "No scan loaded",
                    message: "Scan a folder to see what could be deleted."
                ) {
                    Button("Scan Folder…") { model.pickAndScanFolder() }
                }
            } else if model.recommendations == nil {
                placeholder(
                    symbol: "sparkles", title: "Updating recommendations…",
                    message: "The list is being recomputed for the current scan."
                ) {
                    ProgressView().controlSize(.small)
                }
            } else {
                placeholder(
                    symbol: "checkmark.circle", title: "This recommendation no longer applies",
                    message: "The space was freed, or the list changed after a rescan."
                ) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .navigationTitle(lastTitle)
        .frame(minWidth: 540, minHeight: 420)
        .sheet(item: $fixing) { target in
            FixRecommendationView(recommendation: target, scanGeneration: model.scanGeneration)
                .environmentObject(model)
                .environment(\.typography, type)
        }
        .onAppear { model.openWindow = openWindow }
    }

    private func placeholder<Accessory: View>(
        symbol: String, title: String, message: String, @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title).font(type.title3.bold())
            Text(message)
                .font(type.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            accessory()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The large-format recommendation: everything the card shows, every member
/// listed, and the full set of actions.
struct RecommendationDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.typography) private var type
    var recommendation: Recommendation
    /// Asks the window to present the Fix sheet for this recommendation.
    var onFix: (Recommendation) -> Void
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    private var context: RecommendationContext { model.recommendationContext }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    Text(recommendation.reason)
                        .font(type.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(recommendation.caveats, id: \.self) { caveat in
                        Label(caveat, systemImage: "exclamationmark.triangle")
                            .font(type.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Label(recommendation.action, systemImage: "arrow.turn.down.right")
                        .font(type.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Divider()
                    members
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            buttonBar
                .padding(12)
        }
        .confirmationDialog(
            "Move \"\(recommendation.title)\" to Trash?",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let node = recommendation.node {
                    deleteError = model.moveToTrash(node)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This really frees about \(ByteCount.format(recommendation.freeable)).")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(recommendation.title)
                    .font(type.title2.bold())
                    .lineLimit(3)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteCount.format(recommendation.freeable))
                        .font(type.title2.bold())
                        .foregroundStyle(.green)
                        .monospacedDigit()
                    Text("freeable now")
                        .font(type.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                SafetyBadge(safety: recommendation.safety)
                Text(recommendation.category.displayName)
                    .font(type.caption)
                    .foregroundStyle(.secondary)
                if recommendation.category.ageMatters, let newest = recommendation.newestModified {
                    Text("· " + AgeText.staleness(since: newest, now: context.now))
                        .font(type.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var members: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                recommendation.items.isEmpty
                    ? "No individual files to list."
                    : "\(recommendation.itemCount) item\(recommendation.itemCount == 1 ? "" : "s")")
                .font(type.headline)
            ForEach(recommendation.items) { item in
                memberRow(item)
            }
            if recommendation.hiddenItemCount > 0 {
                Text("\(recommendation.hiddenItemCount) more not listed — scan the folder itself to see them.")
                    .font(type.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func memberRow(_ item: Recommendation.Item) -> some View {
        let removed = item.node.map { model.graph?.isRemoved($0) ?? false } ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(context.displayPath(item.path))
                .lineLimit(1)
                .truncationMode(.middle)
                .strikethrough(removed)
                .help(item.path)
            if removed {
                Text("moved to Trash")
                    .foregroundStyle(.tertiary)
            } else if let note = item.note {
                Text("— \(note)")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(ByteCount.format(item.sizes.unique))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(type.body)
        .foregroundStyle(removed ? .tertiary : .primary)
        .contextMenu {
            if let node = item.node, !removed {
                Button("Reveal in Finder") { model.revealInFinder(node) }
                Button("Show in MacDiskSleuth") { showInMainWindow(node) }
            }
        }
    }

    private var buttonBar: some View {
        HStack(spacing: 8) {
            if let node = recommendation.node {
                Button("Reveal in Finder") { model.revealInFinder(node) }
                Button("Show Here") { showInMainWindow(node) }
            }
            Spacer()
            if recommendation.isFixable {
                Button {
                    onFix(recommendation)
                } label: {
                    Label("Fix…", systemImage: "checklist")
                }
                .keyboardShortcut(.defaultAction)
                .help("Choose which items to move to the Trash")
            }
            if recommendation.canMoveToTrash, recommendation.node != nil {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
            if let deleteError {
                Text(deleteError).font(type.caption).foregroundStyle(.red)
            }
        }
    }

    /// Navigate the results window to the item and bring it forward,
    /// reopening it if the user closed it.
    private func showInMainWindow(_ node: NodeID) {
        model.show(node)
        model.showResultsWindow()
    }
}
