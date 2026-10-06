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

                    // Hidden while a scan runs, since that scan is already
                    // the answer to it.
                    if store.libraryChangedSinceScan && !store.isScanning {
                        LibraryChangedBanner { store.startScan() }
                    }

                    ScanStatusView()

                    VStack(spacing: 14) {
                        ForEach(rows, id: \.self) { row in
                            HStack(spacing: 14) {
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
                } else if !store.libraryChangedSinceScan {
                    // The banner carries its own Rescan while it is up.
                    Button("Rescan") { store.startScan() }
                }
            }
        }
    }

    private func cardLink(for category: CategoryID) -> some View {
        let state = store.state(for: category)
        let order = CategoryID.allCases.firstIndex(of: category) ?? 0

        // Never disabled. This used to switch off every card that was still
        // scanning, which on a rescan meant all six, and taps simply did
        // nothing until the scan ended. A card with results opens them; one
        // still on its first scan opens a screen that fills in by itself.
        return NavigationLink {
            CategoryDetailView(category: category)
                .zoomDestination(id: category.id, in: cardTransition)
        } label: {
            CategoryCard(
                category: category,
                state: state,
                bytes: bytes(for: category),
                isRefreshing: store.isRefreshing(category)
            )
        }
        .buttonStyle(CardButtonStyle())
        .zoomSource(id: category.id, in: cardTransition)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 14)
        .animation(.easeOut(duration: 0.35).delay(Double(order) * 0.04), value: hasAppeared)
    }
}

extension CategoryGridView {

    /// The size shown on a card. Summed here rather than in the store since
    /// it is presentation only. Sets count what a cleanup frees; flat lists
    /// count everything in them. Unknown sizes are skipped, so a figure can
    /// be low but never inflated.
    func bytes(for category: CategoryID) -> Int64? {
        guard case .ready = store.state(for: category) else { return nil }
        switch category.detection {
        case .grouping:
            let total = store.groups(for: category)
                .filter { $0.removableCount > 0 }
                .compactMap(\.reclaimableBytes)
                .reduce(0, +)
            return total > 0 ? total : nil
        case .streaming:
            let total = store.records(for: category).compactMap(\.size.bytes).reduce(0, +)
            return total > 0 ? total : nil
        }
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
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

// MARK: - Card

/// One tappable tile per category.
///
/// Full colour, toned down. Each card is filled with its category's tint, but
/// the tint is desaturated slightly and deepened toward the bottom, so the
/// grid reads as six distinct, calm surfaces rather than six bright stickers.
/// The symbol leads the card. Depth comes from a soft top light, a thin rim
/// and a short, low-opacity shadow; there is no coloured glow.
struct CategoryCard: View {

    let category: CategoryID
    let state: CategoryState
    var bytes: Int64? = nil
    var isRefreshing: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    private var isPlaceholder: Bool { state.isPlaceholder }
    private var base: Color { isPlaceholder ? Color(.systemGray) : category.tint }
    private var isDark: Bool { colorScheme == .dark }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Icon and accessory share one top row: icon leading, accessory
            // trailing, both pinned to the same top edge. The row spans the
            // card, so the right side is anchored instead of empty.
            HStack(alignment: .top, spacing: 0) {
                symbol
                Spacer(minLength: 8)
                accessory
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)

            Spacer(minLength: 12)

            textBlock
        }
        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: .infinity)
        .background { fill }
        .clipShape(shape)
        .overlay {
            // Thin rim, brighter along the top edge, so the card has an edge
            // to catch light on without any glow around it.
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(isDark ? 0.18 : 0.30), .white.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 0.75
            )
        }
        .shadow(color: .black.opacity(isDark ? 0.40 : 0.12), radius: 8, y: 4)
        .shadow(color: .black.opacity(isDark ? 0.25 : 0.06), radius: 1, y: 1)
        .opacity(isPlaceholder ? 0.65 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Pieces

    private var fill: some View {
        ZStack {
            base
            // Takes the edge off the system tints. Mixing in a little grey
            // reads as "less saturated" in both modes without losing the hue.
            Color(.systemGray).opacity(isDark ? 0.22 : 0.14)
            // Deepens toward the bottom: gives the card volume and gives the
            // white text a darker band to sit on, on every colour.
            LinearGradient(
                colors: [.white.opacity(isDark ? 0.06 : 0.10), .clear, .black.opacity(isDark ? 0.38 : 0.28)],
                startPoint: .top, endPoint: .bottom
            )
            if isDark {
                // Dark mode needs the whole card a step down, or the tints
                // glare against a black background.
                Color.black.opacity(0.18)
            }
        }
    }

    /// Every icon sits centred in the same fixed square, so the visual block
    /// is identical on all six cards however wide or tall the glyph is.
    /// 72pt leaves the top row, the chevron and the text block their room at
    /// the card's 190pt minimum height.
    private var symbol: some View {
        CardIconView(icon: category.cardIcon)
            .frame(width: Self.iconSide, height: Self.iconSide)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
            .accessibilityHidden(true)
    }

    private static let iconSide: CGFloat = 72

    /// The standard iOS sign that a tile opens something, top right where
    /// Settings and Health put theirs. A spinner takes its place while the
    /// category is working, so busy cards keep the same balance.
    @ViewBuilder
    private var accessory: some View {
        Group {
            if state.isBusy || isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else if state.isNavigable {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: 20, height: 20)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(countText)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let qualifier {
                    Text(qualifier)
                        .font(.footnote.weight(.semibold))
                        .opacity(0.85)
                        .lineLimit(1)
                }
            }

            Text(category.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text(detailText)
                .font(.caption.weight(.medium))
                .opacity(0.85)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: Copy

    private var count: Int? {
        switch state {
        case .ready(let count, _):       return count
        case .scanning(let partial?, _): return partial
        default:                         return nil
        }
    }

    private var countText: String { count.map { "\($0)" } ?? "–" }

    /// Only the set categories get a word next to the number. On the others
    /// the title below already says what is counted.
    private var qualifier: String? { count.flatMap { category.qualifier($0) } }

    private var detailText: String {
        switch state {
        case .idle:                    return "Waiting to scan"
        case .scanning(_, let detail): return detail
        case .unavailable:             return "Not available"
        case .ready(let count, _):
            if count > 0, let bytes, bytes > 0 { return category.sizePhrase(bytes) }
            return category.blurb
        }
    }

    private var accessibilityText: String {
        [countText, qualifier, category.title, detailText].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Draws a `CardIcon` inside whatever square it is given. Composite icons
/// are built from proportions of that square, so they scale with it and keep
/// the same footprint as a single symbol.
///
/// Gaps between layers are real cut-outs (`destinationOut` inside a
/// compositing group), not strokes in a guessed colour, so the card's own
/// gradient shows through and they match on every tint in both modes.
private struct CardIconView: View {

    let icon: CardIcon

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                switch icon {
                case .symbol(let name):
                    glyph(name)

                case .stacked(let name):
                    let copy = side * 0.76
                    glyph(name)
                        .frame(width: copy, height: copy)
                        .opacity(0.55)
                        .offset(x: -side * 0.11, y: -side * 0.11)
                    // Cut a margin round the front copy out of the back one.
                    glyph(name, color: .black)
                        .frame(width: copy, height: copy)
                        .scaleEffect(1.14)
                        .offset(x: side * 0.11, y: side * 0.11)
                        .blendMode(.destinationOut)
                    glyph(name)
                        .frame(width: copy, height: copy)
                        .offset(x: side * 0.11, y: side * 0.11)

                case .badged(let name, let badge):
                    let badgeSide = side * 0.46
                    let badgeOffset = CGSize(width: side * 0.27, height: side * 0.25)
                    glyph(name)
                        .frame(width: side * 0.86, height: side * 0.86)
                        .offset(x: -side * 0.06, y: -side * 0.06)
                    // Ring of card colour round the badge.
                    Circle()
                        .fill(.black)
                        .frame(width: badgeSide * 1.2, height: badgeSide * 1.2)
                        .offset(badgeOffset)
                        .blendMode(.destinationOut)
                    Circle()
                        .fill(.white.opacity(0.95))
                        .frame(width: badgeSide, height: badgeSide)
                        .offset(badgeOffset)
                    // Badge glyph cut out of the white disc.
                    glyph(badge, color: .black, weight: .bold)
                        .frame(width: badgeSide * 0.58, height: badgeSide * 0.58)
                        .offset(badgeOffset)
                        .blendMode(.destinationOut)

                case .storageBar(let filled):
                    storageBar(side: side, filled: filled)

                case .sizeBadge(let name, let label):
                    sizeBadge(side: side, symbol: name, label: label)
                }
            }
            .frame(width: side, height: side)
            .compositingGroup()
        }
    }

    /// A wide capsule outline with a solid segment filling most of it, and a
    /// play triangle cut out of that segment. Every part is large: the bar is
    /// nearly the full icon width and the triangle is half the bar's height,
    /// so nothing depends on a detail too small to make out.
    private func storageBar(side: CGFloat, filled: CGFloat) -> some View {
        let width = side * 0.96
        let height = side * 0.50
        let stroke = side * 0.055
        let gap = side * 0.045
        let inset = stroke + gap
        let innerWidth = width - inset * 2
        let innerHeight = height - inset * 2
        let segmentWidth = innerWidth * filled
        let outerRadius = height * 0.30
        let innerRadius = max(outerRadius - inset, 2)

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.95), lineWidth: stroke)
                .frame(width: width, height: height)

            ZStack {
                RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                    .fill(.white.opacity(0.95))
                Image(systemName: "play.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.black)
                    .frame(height: innerHeight * 0.52)
                    // Optical centring: a triangle's mass sits left of its box.
                    .offset(x: innerHeight * 0.04)
                    .blendMode(.destinationOut)
            }
            .frame(width: segmentWidth, height: innerHeight)
            .padding(.leading, inset)
        }
        .frame(width: width, height: height)
    }

    /// Camera up and to the left, badge in the bottom-right corner. The badge
    /// only overlaps the lower corner of the lens, so the camera's outline
    /// stays whole and it still reads as a camera.
    ///
    /// The badge is a solid white disc with dark text: the highest contrast
    /// available on a tinted card, and neutral, so it stands out on teal
    /// without adding another colour. A cut-out ring separates it from the
    /// camera. Text is heavy rounded at about 15pt on a 36pt disc, which is
    /// the smallest size that still reads cleanly.
    private func sizeBadge(side: CGFloat, symbol: String, label: String) -> some View {
        let badgeSide = side * 0.50
        let badgeOffset = CGSize(width: side * 0.25, height: side * 0.25)

        return ZStack {
            glyph(symbol)
                .frame(width: side * 0.84, height: side * 0.84)
                .offset(x: -side * 0.08, y: -side * 0.12)

            Circle()
                .fill(.black)
                .frame(width: badgeSide * 1.18, height: badgeSide * 1.18)
                .offset(badgeOffset)
                .blendMode(.destinationOut)

            Circle()
                .fill(.white)
                .frame(width: badgeSide, height: badgeSide)
                .offset(badgeOffset)

            Text(label)
                .font(.system(size: badgeSide * 0.42, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: badgeSide * 0.82)
                .offset(badgeOffset)
                // Fixed size: the badge is artwork, it must not grow with
                // Dynamic Type and push out of the icon box.
                .dynamicTypeSize(.large)
        }
    }

    private func glyph(_ name: String, color: Color = .white.opacity(0.95), weight: Font.Weight = .medium) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .fontWeight(weight)
            .foregroundStyle(color)
    }
}

// MARK: - Status and banners

private struct ScanStatusView: View {

    @Environment(LibraryStore.self) private var store

    var body: some View {
        switch store.phase {
        case .idle:
            // Was EmptyView, which left the screen looking frozen between
            // launch and the first batch of results.
            busyLine("Getting ready")

        case .scanning:
            // `total` is zero until PhotoKit answers the fetch. A determinate
            // bar stuck at zero reads as a hang, so it only appears once there
            // is a real total to divide by.
            if store.progress.total == 0 {
                busyLine("Reading your library")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: store.progressFraction)
                    Text(scanningLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .finished:
            statusLine(finishedLine)

        case .cancelled:
            statusLine("Scan stopped at \(store.progress.processed) of \(store.progress.total). Counts are partial.")

        case .blocked:
            statusLine("Photo access changed. Rescan once access is back on.")
        }
    }

    /// Says up front that a rescan does not take anything away, since the
    /// old behaviour taught that a running scan locks the screen.
    private var scanningLine: String {
        let counts = "\(store.progress.processed) of \(store.progress.total)"
        guard store.hasResults else { return "Scanning \(counts)" }
        return "Rescanning \(counts). Current results stay open meanwhile."
    }

    private var finishedLine: String {
        let count = store.scannedAssetCount
        var text = "\(count) item\(count == 1 ? "" : "s") in your library"

        guard AppConfig.showScanTimings else { return text }

        if let index = store.indexDuration {
            text += String(format: ", scanned in %.1fs", index)
        }
        if let grouping = store.groupingDuration {
            text += String(format: ", compared in %.1fs", grouping)
        }
        return text
    }

    private func busyLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func statusLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LibraryChangedBanner: View {

    let onRescan: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Your library changed")
                    .font(.subheadline.weight(.medium))
                Text("New or removed items aren't in these results yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Rescan", action: onRescan)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.5)
        }
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
