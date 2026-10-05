import SwiftUI

struct CategoryGridView: View {

    @Environment(LibraryStore.self) private var store

    /// Drives the card-to-detail zoom on iOS 18 and later.
    @Namespace private var cardTransition

    @State private var hasAppeared = false

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
        .onAppear { hasAppeared = true }
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
        let order = CategoryID.allCases.firstIndex(of: category) ?? 0

        return NavigationLink {
            CategoryDetailView(category: category)
                .zoomDestination(id: category.id, in: cardTransition)
        } label: {
            CategoryCard(category: category, state: state)
        }
        .buttonStyle(CardButtonStyle())
        .disabled(!state.isNavigable)
        .zoomSource(id: category.id, in: cardTransition)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 14)
        .animation(.easeOut(duration: 0.35).delay(Double(order) * 0.04), value: hasAppeared)
    }
}

// MARK: - Transition plumbing

/// The zoom transition landed in iOS 18 and the deployment target is 17, so
/// both halves are behind availability checks. On 17 the push is unchanged.
private extension View {

    @ViewBuilder
    func zoomSource(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func zoomDestination(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

/// Press feedback, since a plain style gives a card no sign it is tappable.
private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

// MARK: - Card

struct CategoryCard: View {

    let category: CategoryID
    let state: CategoryState

    private var isPlaceholder: Bool { state.isPlaceholder }

    private var tint: Color {
        isPlaceholder ? Color.secondary : category.tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(alignment: .top, spacing: 0) {
                IconBadge(symbolName: category.symbolName, tint: tint)

                Spacer(minLength: 0)

                if state.isBusy {
                    ProgressView().controlSize(.mini)
                } else if state.isNavigable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 6)
                }
            }

            // Absorbs whatever extra height the row hands this card, so the
            // text block always sits on the baseline rather than floating.
            Spacer(minLength: 14)

            valueRow
                .frame(height: 36, alignment: .leading)

            Text(category.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isPlaceholder ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .padding(.top, 1)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 164, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if isPlaceholder {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(.separator), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.5)
            }
        }
        .shadow(color: .black.opacity(isPlaceholder ? 0 : 0.05), radius: 8, y: 2)
    }

    @ViewBuilder
    private var valueRow: some View {
        switch state {
        case .unavailable:
            Text("Not built")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: Capsule())

        case .idle:
            Text("–")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)

        case .scanning(let partial, _):
            if let partial {
                countText(partial, dimmed: false)
            } else {
                Text("–")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

        case .ready(let count, _):
            countText(count, dimmed: count == 0)
        }
    }

    private func countText(_ value: Int, dimmed: Bool) -> some View {
        Text("\(value)")
            .font(.system(size: 30, weight: .semibold, design: .rounded))
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
        case .scanning(_, let detail): return detail
        case .unavailable(let reason): return reason
        case .ready(_, let note):      return note ?? category.blurb
        }
    }
}

private struct IconBadge: View {

    let symbolName: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: 44, height: 44)
            .overlay {
                Image(systemName: symbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
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
            statusLine(finishedLine)

        case .cancelled:
            statusLine("Scan stopped at \(store.progress.processed) of \(store.progress.total). Counts are partial.")

        case .blocked:
            statusLine("Photo access changed. Rescan once access is back on.")
        }
    }

    private var finishedLine: String {
        let count = store.scannedAssetCount
        var text = "\(count) item\(count == 1 ? "" : "s") scanned"

        guard AppConfig.showScanTimings else { return text }

        if let index = store.indexDuration {
            text += String(format: " in %.1fs", index)
        }
        if let grouping = store.groupingDuration {
            text += String(format: ", compared in %.1fs", grouping)
        }
        return text
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
                .font(.system(size: 16, weight: .semibold))
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.5)
        }
    }
}

private struct StaleBanner: View {

    let onRescan: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("The library changed since this scan.")
                .font(.caption)

            Spacer(minLength: 0)

            Button("Rescan", action: onRescan)
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.5)
        }
    }
}
