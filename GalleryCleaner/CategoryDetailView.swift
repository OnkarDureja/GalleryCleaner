//
//  CategoryDetailView.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import SwiftUI
import Photos

struct CategoryDetailView: View {

    let category: CategoryID

    @Environment(LibraryStore.self) private var store

    /// Resolved once per visit, in a single `fetchAssets(withLocalIdentifiers:)`
    /// call rather than one lookup per cell.
    @State private var assetsByID: [String: PHAsset] = [:]
    @State private var didResolve = false

    /// Cells whose full image lives in iCloud. Only these get the offer to
    /// fetch over the network; lumping every failure in here is what made the
    /// UI claim "not on this device" for a local file that failed to render.
    @State private var cloudPending: Set<String> = []

    /// Cells that failed for any other reason. Nothing the user can do, so
    /// these are reported but not actionable.
    @State private var renderFailures: Set<String> = []

    @State private var allowNetworkPreviews = false

    var body: some View {
        Group {
            switch store.state(for: category) {
            case .unavailable(let reason):
                NoticeView(
                    symbolName: category.symbolName,
                    tint: .secondary,
                    headline: "Not built yet",
                    message: reason
                )

            case .idle, .scanning:
                NoticeView(
                    symbolName: "hourglass",
                    tint: .secondary,
                    headline: "Still scanning",
                    message: "Come back when the scan finishes, or watch the count on the previous screen."
                )

            case .ready(let count, let note):
                if count == 0 {
                    NoticeView(
                        symbolName: category.symbolName,
                        tint: category.tint,
                        headline: emptyHeadline,
                        message: note ?? "Nothing in your library matched this category."
                    )
                } else {
                    content(note: note)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { resolveAssets() }
    }

    private var emptyHeadline: String {
        switch category {
        case .screenshots: return "No screenshots"
        case .videos:      return "No videos"
        case .largeVideos: return "No large videos"
        default:           return "Nothing here"
        }
    }

    // MARK: - Layout

    /// Column count follows the item count. A fixed three-column grid is right
    /// for hundreds of items and wrong for one: it leaves a single small square
    /// in the corner of an otherwise blank screen.
    private enum Layout {
        case solo       // one item, shown large at its real shape
        case pairs      // a handful, two columns
        case dense      // many, three columns
    }

    private func layout(for count: Int) -> Layout {
        if count == 1 { return .solo }
        if count <= 6 { return .pairs }
        return .dense
    }

    @ViewBuilder
    private func content(note: String?) -> some View {
        let records = store.records(for: category)
        let layout = layout(for: records.count)

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                SummaryRow(records: records, category: category)

                if let note {
                    InfoCard(text: note)
                }

                if !cloudPending.isEmpty && !allowNetworkPreviews {
                    PreviewRecoveryCard(count: cloudPending.count) {
                        cloudPending.removeAll()
                        renderFailures.removeAll()
                        allowNetworkPreviews = true
                    }
                }

                if !renderFailures.isEmpty {
                    InfoCard(text: "\(renderFailures.count) preview\(renderFailures.count == 1 ? "" : "s") couldn't be rendered. The sizes and durations below come from the scan and are unaffected.")
                }

                switch layout {
                case .solo:
                    if let record = records.first {
                        SoloItemView(
                            record: record,
                            asset: assetsByID[record.id],
                            category: category,
                            allowNetwork: allowNetworkPreviews,
                            onOutcome: handleOutcome
                        )
                    }

                case .pairs, .dense:
                    LazyVGrid(columns: gridColumns(layout), spacing: AppConfig.gridSpacing) {
                        ForEach(records) { record in
                            AssetCell(
                                record: record,
                                asset: assetsByID[record.id],
                                category: category,
                                allowNetwork: allowNetworkPreviews,
                                onOutcome: handleOutcome
                            )
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func gridColumns(_ layout: Layout) -> [GridItem] {
        let count = (layout == .pairs) ? 2 : AppConfig.gridColumns
        return Array(repeating: GridItem(.flexible(), spacing: AppConfig.gridSpacing), count: count)
    }

    private func handleOutcome(_ id: String, _ outcome: ThumbnailOutcome) {
        if outcome.isCloudPending {
            cloudPending.insert(id)
            renderFailures.remove(id)
        } else if outcome.isFailure {
            renderFailures.insert(id)
            cloudPending.remove(id)
        } else {
            cloudPending.remove(id)
            renderFailures.remove(id)
        }
    }

    // MARK: - Asset resolution

    @MainActor
    private func resolveAssets() {
        guard !didResolve else { return }

        let ids = store.records(for: category).map(\.id)
        guard !ids.isEmpty else {
            didResolve = true
            return
        }

        // One database query. The result is unordered, so it goes into a
        // dictionary and the grid keeps the index's own order.
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var map: [String: PHAsset] = [:]
        map.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            map[asset.localIdentifier] = asset
        }

        ThumbnailDiagnostics.logResolve(category: category.rawValue, requested: ids, resolved: map)

        assetsByID = map
        didResolve = true
    }
}

// MARK: - Single item

/// One item gets a real preview plus everything the index already knows about
/// it. A lone thumbnail in the corner reads as a bug; a preview with its facts
/// underneath reads as the whole point of the screen.
private struct SoloItemView: View {

    let record: AssetRecord
    let asset: PHAsset?
    let category: CategoryID
    let allowNetwork: Bool
    let onOutcome: (String, ThumbnailOutcome) -> Void

    private var ratio: CGFloat {
        guard record.pixelWidth > 0, record.pixelHeight > 0 else { return 1 }
        return CGFloat(record.pixelWidth) / CGFloat(record.pixelHeight)
    }

    var body: some View {
        VStack(spacing: 12) {
            ThumbnailView(
                record: record,
                asset: asset,
                allowNetwork: allowNetwork,
                aspect: .natural(ratio),
                onOutcome: onOutcome
            )
            .frame(maxHeight: 400)
            .frame(maxWidth: .infinity)

            DetailFacts(record: record)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
        }
    }
}

private struct DetailFacts: View {

    let record: AssetRecord

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                if index > 0 { Divider() }
                HStack {
                    Text(fact.0)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(fact.1)
                        .font(.subheadline)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 9)
            }
        }
    }

    private var facts: [(String, String)] {
        var items: [(String, String)] = []

        items.append(("Dimensions", Formatters.dimensions(width: record.pixelWidth, height: record.pixelHeight)))

        if record.kind == .video {
            items.append(("Duration", Formatters.duration(record.duration)))
        }

        items.append(("Size", Formatters.size(record.size)))

        if let created = record.creationDate {
            items.append(("Created", created.formatted(date: .abbreviated, time: .shortened)))
        }

        if let name = record.originalFilename {
            items.append(("File", name))
        }

        return items
    }
}

// MARK: - Grid cell

private struct AssetCell: View {

    let record: AssetRecord
    let asset: PHAsset?
    let category: CategoryID
    let allowNetwork: Bool
    let onOutcome: (String, ThumbnailOutcome) -> Void

    var body: some View {
        ThumbnailView(
            record: record,
            asset: asset,
            allowNetwork: allowNetwork,
            aspect: .square,
            onOutcome: onOutcome
        )
        .overlay(alignment: .bottomLeading) {
            if let caption {
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(5)
            }
        }
    }

    private var caption: String? {
        switch category {
        case .largeVideos: return Formatters.size(record.size)
        case .videos:      return Formatters.duration(record.duration)
        default:           return nil
        }
    }
}

// MARK: - Header pieces

private struct SummaryRow: View {

    let records: [AssetRecord]
    let category: CategoryID

    var body: some View {
        HStack(spacing: 6) {
            Text("\(records.count) item\(records.count == 1 ? "" : "s")")
                .font(.subheadline.weight(.medium))

            if let total = totalBytes {
                Text("·").foregroundStyle(.tertiary)
                Text(Formatters.bytes(total))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
    }

    /// Shown only for two or more items. With one item the total is the same
    /// number the tile already carries, printed twice.
    ///
    /// Also requires every item to have a size, so a partial total never reads
    /// as a complete one.
    private var totalBytes: Int64? {
        guard records.count > 1 else { return nil }
        guard category == .largeVideos || category == .videos else { return nil }

        var sum: Int64 = 0
        for record in records {
            guard let bytes = record.size.bytes else { return nil }
            sum += bytes
        }
        return sum
    }
}

private struct InfoCard: View {

    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Offers the second, network-enabled pass. Deliberately a button rather than
/// an automatic retry, so the grid never stalls on iCloud by itself.
private struct PreviewRecoveryCard: View {

    let count: Int
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(count) full preview\(count == 1 ? "" : "s") in iCloud")
                    .font(.subheadline.weight(.medium))
                Text("Sizes and durations below are accurate either way. Loading previews fetches small images over the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Load previews", action: action)
                    .font(.caption.weight(.semibold))
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Notice

struct NoticeView: View {

    let symbolName: String
    let tint: Color
    let headline: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.16))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: symbolName)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(tint)
                }

            VStack(spacing: 6) {
                Text(headline)
                    .font(.headline)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
