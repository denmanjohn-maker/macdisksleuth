import MacDiskSleuthKit
import SwiftUI

/// "Top 5 things to delete" — the first thing to read after a scan.
struct RecommendationsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.typography) private var type
    /// The Fix sheet is presented from here, not from a card: a card can vanish
    /// when the list recomputes after the deletion, and the summary must outlive it.
    @State private var fixing: Recommendation?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let report = model.recommendations {
                if report.recommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing obvious to delete here.")
                            .font(type.body)
                        ForEach(report.notes, id: \.self) { note in
                            Text(note).font(type.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(report.recommendations.enumerated()), id: \.element.id) { index, recommendation in
                                RecommendationCard(recommendation: recommendation, rank: index + 1) { fixing = $0 }
                            }
                            if let advice = report.volumeAdvice {
                                VolumeAdviceCard(advice: advice)
                            }
                            ForEach(report.notes, id: \.self) { note in
                                Text(note)
                                    .font(type.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            } else if model.graph != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for things to delete…")
                        .font(type.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(14)
        .sheet(item: $fixing) { target in
            FixRecommendationView(recommendation: target, scanGeneration: model.scanGeneration)
                .environment(model)
                .environment(\.typography, type)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Top ways to free space", systemImage: "sparkles")
                .font(type.headline)
            Spacer()
            if let report = model.recommendations, report.totalFreeable > 0 {
                Text("up to \(ByteCount.format(report.totalFreeable))")
                    .font(type.headline)
                    .foregroundStyle(.green)
                    .monospacedDigit()
            }
        }
    }
}

struct RecommendationCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.typography) private var type
    @Environment(\.openWindow) private var openWindow
    var recommendation: Recommendation
    var rank: Int
    /// Asks the owning list to present the Fix sheet for this recommendation.
    var onFix: (Recommendation) -> Void
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    private var context: RecommendationContext { model.recommendationContext }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The title row opens the recommendation in its own window. Only
            // the row, not the whole card: the card holds selectable text and
            // buttons that a card-wide tap would fight with.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(rank)")
                    .font(type.title3.bold())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(recommendation.title)
                    .font(type.headline)
                    .lineLimit(2)
                Spacer()
                Text(ByteCount.format(recommendation.freeable))
                    .font(type.headline)
                    .foregroundStyle(.green)
                    .monospacedDigit()
                Button {
                    openInWindow()
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help("Open in its own window")
            }
            .contentShape(Rectangle())
            .onTapGesture { openInWindow() }
            .accessibilityAddTraits(.isButton)
            .help("Open in its own window")

            HStack(spacing: 8) {
                SafetyBadge(safety: recommendation.safety)
                if recommendation.category.ageMatters, let newest = recommendation.newestModified {
                    Text(AgeText.staleness(since: newest, now: context.now))
                        .font(type.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(recommendation.reason)
                .font(type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !recommendation.items.isEmpty && !(recommendation.items.count == 1 && recommendation.node != nil) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(recommendation.items.prefix(4)) { item in
                        itemRow(item)
                    }
                    if recommendation.itemCount > 4 {
                        Text("… \(recommendation.itemCount - 4) more")
                            .font(type.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else if let only = recommendation.items.first {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(context.displayPath(only.path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let note = only.note, note != recommendation.title {
                        Text("— \(note)")
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
                .font(type.caption)
            }

            ForEach(recommendation.caveats, id: \.self) { caveat in
                Label(caveat, systemImage: "exclamationmark.triangle")
                    .font(type.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(recommendation.action, systemImage: "arrow.turn.down.right")
                .font(type.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                if let node = recommendation.node {
                    Button("Reveal in Finder") { model.revealInFinder(node) }
                    Button("Show Here") { model.show(node) }
                }
                Spacer()
                if recommendation.isFixable {
                    Button {
                        onFix(recommendation)
                    } label: {
                        Label("Fix…", systemImage: "checklist")
                    }
                    .help("Choose which items to move to the Trash")
                }
                if recommendation.canMoveToTrash, recommendation.node != nil {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                }
            }
            .controlSize(.small)

            if let deleteError {
                Text(deleteError).font(type.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
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
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        var message = "This really frees about \(ByteCount.format(recommendation.freeable))."
        if !model.snapshots.isEmpty {
            message += " Local snapshots may delay the space appearing."
        }
        return message
    }

    private func itemRow(_ item: Recommendation.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(context.displayPath(item.path))
                .lineLimit(1)
                .truncationMode(.middle)
            if let note = item.note {
                Text("— \(note)")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(ByteCount.format(item.sizes.unique))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(type.caption)
        .contextMenu {
            if let node = item.node {
                Button("Reveal in Finder") { model.revealInFinder(node) }
                Button("Show in MacDiskSleuth") { model.show(node) }
            }
        }
    }

    private func openInWindow() {
        openWindow(value: recommendation.id)
    }
}

/// "Safe" / "Likely safe" / "Review first" pill, shared by cards, the detail window and Fix.
struct SafetyBadge: View {
    @Environment(\.typography) private var type
    var safety: CleanupSafety

    var body: some View {
        let (text, color, symbol): (String, Color, String) =
            switch safety {
            case .safe: ("Safe", .green, "checkmark.seal")
            case .likelySafe: ("Likely safe", .yellow, "hand.thumbsup")
            case .review: ("Review first", .blue, "eye")
            }
        return Label(text, systemImage: symbol)
            .font(type.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// Snapshot advice: no byte figure, because macOS reports none.
struct VolumeAdviceCard: View {
    @Environment(\.typography) private var type
    var advice: Recommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text(advice.title)
                    .font(type.headline)
                    .lineLimit(2)
                Spacer()
                Text("size unknown")
                    .font(type.caption)
                    .foregroundStyle(.secondary)
            }
            Text(advice.reason)
                .font(type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(advice.caveats, id: \.self) { caveat in
                Label(caveat, systemImage: "exclamationmark.triangle")
                    .font(type.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(advice.action, systemImage: "arrow.turn.down.right")
                .font(type.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The toolbar / menu entry point: the same list in a sheet.
struct RecommendationsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.typography) private var type

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            RecommendationsView()
            Divider()
            HStack {
                if let report = model.recommendations {
                    Text("Scanned \(model.scannedPath) · \(report.consideredCount) candidates considered")
                        .font(type.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Done") { model.showRecommendations = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 640)
    }
}
