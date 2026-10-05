import SwiftUI

struct CategoryGridView: View {

    @Environment(LibraryStore.self) private var store

    /// Six fixed cards, so a LazyVGrid buys nothing and actively hurts: its
    /// rows size to their content, which is why cards with no note ended up
    /// shorter than their neighbours and the screen stopped at half height.
    /// Plain rows can be told to share the available height evenly.
    private var rows: [[CategoryID]] {
        let all = CategoryID.allCases
        return stride(from: 0, to: all.count, by: 2).map {
            Array(all[$0 ..< min($0 + 2, all.count)])
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    if store.permission == .limited {
                        LimitedAccessBanner { store.openLimitedPicker() }
                    }

                    if store.libraryChangedSinceScan {
                        StaleBanner { store.startScan() }
                    }

                    ScanStatusView()

                    VStack(spacing: 12) {
                        ForEach(rows, id: \.self) { row in
                            HStack(spacing: 12) {
                                ForEach(row) { category in
                                    cardLink(for: category)
                                }
                            }
                            .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(16)
                // Fills the screen when there is room, scrolls when there is
                // not (large dynamic type, small devices, banners on screen).
                .frame(minHeight: proxy.size.height)
            }
            .background(Color(.systemGroupedBackground))
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.isScanning {
                    Button("Stop") { store.cancelScan() }
                } else {
                    Button("Rescan") { store.startScan() }
                }
            }
        }
    }

    private func cardLink(for category: CategoryID) -> some View {
        let state = store.state(for: category)

        return NavigationLink {
            CategoryDetailView(category: category)
        } label: {
            CategoryCard(category: category, state: state)
        }
        .buttonStyle(CardButtonStyle())
        .disabled(!state.isNavigable)
    }
}

/// Press feedback, since a plain style gives a card no sign it is tappable.
private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Card

struct CategoryCard: View {

    let category: CategoryID
    let state: CategoryState

    private var isPlaceholder: Bool { state.isPlaceholder }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(alignment: .top, spacing: 0) {
                IconBadge(
                    symbolName: category.symbolName,
                    tint: isPlaceholder ? Color.secondary : category.tint
                )

                Spacer(minLength: 0)

                if state.isBusy {
                    ProgressView().controlSize(.mini)
                } else if state.isNavigable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                }
            }

            // Absorbs whatever extra height the row hands this card, so the
            // text block always sits on the baseline rather than floating.
            Spacer(minLength: 12)

            valueRow
                .frame(height: 34, alignment: .leading)

            Text(category.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isPlaceholder ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .padding(.top, 2)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .padding(.top, 3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            if isPlaceholder {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color(.separator), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
            }
        }
    }

    @ViewBuilder
    private var valueRow: some View {
        switch state {
        case .unavailable:
            Text("Not built")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color(.tertiarySystemFill), in: Capsule())

        case .idle:
            Text("–")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)

        case .scanning(let partial):
            countText(partial, dimmed: false)

        case .ready(let count, _):
            countText(count, dimmed: count == 0)
        }
    }

    private func countText(_ value: Int, dimmed: Bool) -> some View {
        Text("\(value)")
            .font(.system(size: 28, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
    }

    /// Falls back to the category's standing description so this line is never
    /// blank. A dynamic note (a zero explained, limited access) wins when there
    /// is one, because it is the more specific thing to say.
    private var subtitle: String {
        switch state {
        case .idle:                    return "Waiting to scan"
        case .scanning:                return "Counting"
        case .unavailable(let reason): return reason
        case .ready(_, let note):      return note ?? category.blurb
        }
    }
}

private struct IconBadge: View {

    let symbolName: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
    }
}

// MARK: - Status and banners

private struct ScanStatusView: View {

    @Environment(LibraryStore.self) private var store

    var body: some View {
        switch store.phase {
        case .idle:
            EmptyView()

        case .scanning:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: store.progressFraction)
                Text("Scanning \(store.progress.processed) of \(store.progress.total)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .finished:
            statusLine("\(store.scannedAssetCount) item\(store.scannedAssetCount == 1 ? "" : "s") scanned")

        case .cancelled:
            statusLine("Scan stopped at \(store.progress.processed) of \(store.progress.total). Counts are partial.")

        case .blocked:
            statusLine("Photo access changed. Rescan once access is back on.")
        }
    }

    private func statusLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LimitedAccessBanner: View {

    let onChange: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye.trianglebadge.exclamationmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("Only some photos are shared")
                    .font(.subheadline.weight(.medium))
                Text("Every count below covers just the items you picked, not your whole library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Change selection", action: onChange)
                    .font(.caption.weight(.semibold))
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
        }
    }
}

private struct StaleBanner: View {

    let onRescan: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("The library changed since this scan.")
                .font(.caption)

            Spacer(minLength: 0)

            Button("Rescan", action: onRescan)
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
        }
    }
}
