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

    /// Set when a thumbnail is tapped. Thumbnails were never wired to anything
    /// before this, which is why tapping one did nothing at all.
    @State private var viewerTarget: ViewerTarget?

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

            case .idle:
                NoticeView(
                    symbolName: "hourglass",
                    tint: .secondary,
                    headline: "Nothing scanned yet",
                    message: "Start a scan from the previous screen."
                )

            case .scanning(_, let detail):
                NoticeView(
                    symbolName: "hourglass",
                    tint: .secondary,
                    headline: detail,
                    message: "Come back when this finishes, or watch the card on the previous screen."
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
        .fullScreenCover(item: $viewerTarget) { target in
            AssetViewerView(record: target.record, asset: assetsByID[target.record.id])
        }
    }

    private var emptyHeadline: String {
        switch category {
        case .screenshots:     return "No screenshots"
        case .videos:          return "No videos"
        case .largeVideos:     return "No large videos"
        case .duplicatePhotos: return "No duplicate photos"
        case .duplicateVideos: return "No duplicate videos"
        case .similarPhotos:   return "Nothing here"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(note: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                header(note: note)

                switch category.detection {
                case .grouping:  groupList
                case .streaming: flatList
                }

                if let footnote = methodFootnote {
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                        .padding(.horizontal, 4)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func header(note: String?) -> some View {
        SummaryRow(category: category, records: store.records(for: category), groups: store.groups(for: category))

        // Grouping categories skip the note: the summary row above already
        // carries the set count and the reclaimable total, and repeating it in
        // a card directly underneath was the same sentence twice.
        if let note, category.detection == .streaming {
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
            InfoCard(text: "\(renderFailures.count) preview\(renderFailures.count == 1 ? "" : "s") couldn't be rendered. The sizes and durations here come from the scan and are unaffected.")
        }
    }

    /// How the matching was done, kept small and at the bottom. It matters for
    /// trust but it is not what the user came to read.
    private var methodFootnote: String? {
        switch category {
        case .duplicatePhotos:
            return "Matched on dimensions, exact file size and the first \(AppConfig.duplicateFingerprintBytes / 1024) KB of file data. Sets marked as an identical image saved as a different file were found by comparing pixels instead, so they only cover photos saved around the same time."
        case .duplicateVideos:
            return "Matched on dimensions, duration, exact file size and the first \(AppConfig.duplicateFingerprintBytes / 1024) KB of file data."
        case .similarPhotos:
            return "Compared only against photos taken within \(Int(AppConfig.Similarity.timeWindowSeconds)) seconds of each other, or in the same burst."
        default:
            return nil
        }
    }

    // MARK: - Grouped layout

    @ViewBuilder
    private var groupList: some View {
        LazyVStack(spacing: 12) {
            ForEach(store.groups(for: category)) { group in
                GroupCard(
                    category: category,
                    group: group,
                    assetsByID: assetsByID,
                    allowNetwork: allowNetworkPreviews,
                    onOutcome: handleOutcome,
                    onOpen: open
                )
            }
        }
    }

    // MARK: - Flat layout

    /// Column count follows the item count. A fixed three-column grid is right
    /// for hundreds of items and wrong for one: it leaves a single small square
    /// in the corner of an otherwise blank screen.
    private enum Layout {
        case solo
        case pairs
        case dense
    }

    private func layout(for count: Int) -> Layout {
        if count == 1 { return .solo }
        if count <= 6 { return .pairs }
        return .dense
    }

    @ViewBuilder
    private var flatList: some View {
        let records = store.records(for: category)

        switch layout(for: records.count) {
        case .solo:
            if let record = records.first {
                SoloItemView(
                    record: record,
                    asset: assetsByID[record.id],
                    allowNetwork: allowNetworkPreviews,
                    onOutcome: handleOutcome,
                    onOpen: open
                )
            }

        case .pairs, .dense:
            LazyVGrid(columns: gridColumns(records.count), spacing: 10) {
                ForEach(records) { record in
                    AssetCell(
                        record: record,
                        asset: assetsByID[record.id],
                        caption: caption(for: record),
                        allowNetwork: allowNetworkPreviews,
                        onOutcome: handleOutcome,
                        onOpen: open
                    )
                }
            }
        }
    }

    private func gridColumns(_ count: Int) -> [GridItem] {
        let columns = count <= 6 ? 2 : AppConfig.gridColumns
        return Array(repeating: GridItem(.flexible(), spacing: AppConfig.gridSpacing), count: columns)
    }

    private func caption(for record: AssetRecord) -> String? {
        switch category {
        case .largeVideos: return Formatters.size(record.size)
        case .videos:      return Formatters.duration(record.duration)
        default:           return nil
        }
    }

    // MARK: - Outcomes and resolution

    private func open(_ record: AssetRecord) {
        viewerTarget = ViewerTarget(record: record)
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

    private var displayedIDs: [String] {
        switch category.detection {
        case .streaming: return store.records(for: category).map(\.id)
        case .grouping:  return store.groups(for: category).flatMap { $0.members.map(\.id) }
        }
    }

    @MainActor
    private func resolveAssets() {
        guard !didResolve else { return }

        let ids = displayedIDs
        guard !ids.isEmpty else { return }   // grouping may still be running

        // One database query. The result is unordered, so it goes into a
        // dictionary and the views keep the index's own order.
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

// MARK: - Group card

private struct GroupCard: View {

    let category: CategoryID
    let group: AssetGroup
    let assetsByID: [String: PHAsset]
    let allowNetwork: Bool
    let onOutcome: (String, ThumbnailOutcome) -> Void
    let onOpen: (AssetRecord) -> Void

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 4)]

    private var memberNoun: String {
        category == .similarPhotos ? "similar shots" : "copies"
    }

    private var groupCaption: String? {
        var parts: [String] = []
        if let created = group.representative.creationDate {
            parts.append("Earliest \(created.formatted(date: .abbreviated, time: .omitted))")
        }
        if let note = group.note {
            parts.append(note)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack(spacing: 6) {
                Text("\(group.members.count) \(memberNoun)")
                    .font(.subheadline.weight(.semibold))

                Text("·").foregroundStyle(.tertiary)

                Text(Formatters.dimensions(
                    width: group.representative.pixelWidth,
                    height: group.representative.pixelHeight
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if let bytes = group.reclaimableBytes {
                    Text("\(Formatters.bytes(bytes)) to free")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(group.members) { member in
                    Button {
                        onOpen(member)
                    } label: {
                        ThumbnailView(
                            record: member,
                            asset: assetsByID[member.id],
                            allowNetwork: allowNetwork,
                            aspect: .square,
                            onOutcome: onOutcome
                        )
                        .overlay(alignment: .center) {
                            if member.kind == .video {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .shadow(color: .black.opacity(0.35), radius: 3)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if member.id == group.representative.id {
                                Text(group.representativeLabel)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor, in: Capsule())
                                    .padding(5)
                            }
                        }
                    }
                    .buttonStyle(ThumbnailButtonStyle())
                }
            }

            if let caption = groupCaption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
        }
    }
}

// MARK: - Single item

/// One item gets a real preview plus everything the index already knows about
/// it. A lone thumbnail in the corner reads as a bug; a preview with its facts
/// underneath reads as the whole point of the screen.
private struct SoloItemView: View {

    let record: AssetRecord
    let asset: PHAsset?
    let allowNetwork: Bool
    let onOutcome: (String, ThumbnailOutcome) -> Void
    let onOpen: (AssetRecord) -> Void

    private var ratio: CGFloat {
        guard record.pixelWidth > 0, record.pixelHeight > 0 else { return 1 }
        return CGFloat(record.pixelWidth) / CGFloat(record.pixelHeight)
    }

    var body: some View {
        VStack(spacing: 12) {
            Button {
                onOpen(record)
            } label: {
                ThumbnailView(
                    record: record,
                    asset: asset,
                    allowNetwork: allowNetwork,
                    aspect: .natural(ratio),
                    onOutcome: onOutcome
                )
                .frame(maxHeight: 400)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .center) {
                    if record.kind == .video {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.35), radius: 4)
                    }
                }
            }
            .buttonStyle(ThumbnailButtonStyle())

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
    let caption: String?
    let allowNetwork: Bool
    let onOutcome: (String, ThumbnailOutcome) -> Void
    let onOpen: (AssetRecord) -> Void

    var body: some View {
        // The caption sits under the thumbnail, not on it. As an overlay it
        // covered the middle of the frame, which on screen recordings and
        // other text-heavy videos hid the very thing the thumbnail is for.
        VStack(spacing: 5) {
            Button {
                onOpen(record)
            } label: {
                ThumbnailView(
                    record: record,
                    asset: asset,
                    allowNetwork: allowNetwork,
                    aspect: .square,
                    onOutcome: onOutcome
                )
                .overlay(alignment: .center) {
                    if record.kind == .video {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.35), radius: 3)
                    }
                }
            }
            .buttonStyle(ThumbnailButtonStyle())

            if let caption {
                Text(caption)
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Press feedback on a thumbnail. Without it a tap gives no sign it landed,
/// which is most of what "nothing happens" felt like.
private struct ThumbnailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Header pieces

private struct SummaryRow: View {

    let category: CategoryID
    let records: [AssetRecord]
    let groups: [AssetGroup]

    var body: some View {
        HStack(spacing: 6) {
            Text(leading)
                .font(.subheadline.weight(.medium))

            if let trailing {
                Text("·").foregroundStyle(.tertiary)
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
    }

    private var leading: String {
        if category.detection == .grouping {
            return "\(groups.count) set\(groups.count == 1 ? "" : "s")"
        }
        return "\(records.count) item\(records.count == 1 ? "" : "s")"
    }

    /// For groups: what deleting the extras would free. For flat lists: the
    /// total size, and only with two or more items, since with one item the
    /// total is the same number the tile already carries.
    private var trailing: String? {
        if category.detection == .grouping {
            let copies = groups.reduce(0) { $0 + $1.removableCount }
            guard copies > 0 else { return nil }

            let reclaim = groups.compactMap(\.reclaimableBytes).reduce(0, +)
            guard reclaim > 0 else { return "\(copies) can go" }

            let allKnown = groups.allSatisfy { $0.reclaimableBytes != nil }
            return "\(copies) can go, \(Formatters.bytes(reclaim))\(allKnown ? "" : "+")"
        }

        guard records.count > 1 else { return nil }
        guard category == .largeVideos || category == .videos else { return nil }

        var sum: Int64 = 0
        for record in records {
            guard let bytes = record.size.bytes else { return nil }
            sum += bytes
        }
        return Formatters.bytes(sum)
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
                Text("Sizes and durations here are accurate either way. Loading previews fetches small images over the network.")
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
