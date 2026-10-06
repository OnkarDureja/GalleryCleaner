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

    /// The last completed result for this category.
    ///
    /// The screen renders from this rather than straight from the store. A
    /// background rescan flips the store's state back to `.scanning`, and
    /// reading that live meant a fully loaded screen was replaced mid-browse
    /// by a progress message. Holding the finished result means a rescan is
    /// invisible here until it produces a new one.
    @State private var loaded: LoadedContent?

    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var isDeleting = false
    @State private var deleteAlert: DeleteAlert?

    /// Sets with nothing the app can remove (every extra synced or shared)
    /// start folded away. On a library synced from a Mac they can outnumber
    /// the actionable sets a hundred to one and bury them.
    @State private var showLockedSets = false

    var body: some View {
        Group {
            if let loaded {
                if loaded.count == 0 {
                    NoticeView(
                        symbolName: category.symbolName,
                        tint: category.tint,
                        headline: emptyHeadline,
                        message: loaded.note ?? "Nothing in your library matched this category."
                    )
                } else {
                    content(loaded)
                }
            } else {
                waitingNotice
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: resolveKey) { resolveAssets() }
        .onAppear { adoptResultIfReady() }
        .onChange(of: store.state(for: category)) { _, _ in adoptResultIfReady() }
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                SelectionBar(
                    selectedCount: selection.count,
                    selectedBytes: selectedBytes,
                    bulkTitle: bulkActionTitle,
                    isDeleting: isDeleting,
                    onBulk: applyBulkAction,
                    onDelete: { Task { await performDelete() } }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: isSelecting)
        .fullScreenCover(item: $viewerTarget) { target in
            AssetViewerView(record: target.record, asset: assetsByID[target.record.id])
        }
        .alert(
            deleteAlert?.title ?? "",
            isPresented: Binding(
                get: { deleteAlert != nil },
                set: { if !$0 { deleteAlert = nil } }
            ),
            presenting: deleteAlert
        ) { _ in
            Button("OK", role: .cancel) { deleteAlert = nil }
        } message: { alert in
            Text(alert.message)
        }
    }

    /// Anything the user needs to hear about a delete: a reason nothing
    /// happened, or what was left behind by a partial one.
    struct DeleteAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private static let syncedExplanation = "This was synced from a computer through Finder. iOS doesn't let apps delete synced items. To remove it, sync again from the computer without it."

    // MARK: - Result snapshot

    struct LoadedContent {
        let count: Int
        let note: String?
        let records: [AssetRecord]
        let groups: [AssetGroup]
    }

    /// Only ever called with a finished result. Every other state is ignored,
    /// which is what keeps an in-progress rescan from clearing the screen.
    private func adoptResultIfReady() {
        guard case .ready(let count, let note) = store.state(for: category) else { return }

        loaded = LoadedContent(
            count: count,
            note: note,
            records: store.records(for: category),
            groups: store.groups(for: category)
        )

        // A rescan or a deletion can retire items that are still ticked.
        let surviving = Set(displayedIDs)
        selection.formIntersection(surviving)
        if selection.isEmpty && isSelecting && count == 0 { isSelecting = false }
    }

    @ViewBuilder
    private var waitingNotice: some View {
        switch store.state(for: category) {
        case .unavailable(let reason):
            NoticeView(
                symbolName: category.symbolName,
                tint: .secondary,
                headline: "Not built yet",
                message: reason
            )
        case .scanning(_, let detail):
            NoticeView(
                symbolName: "hourglass",
                tint: .secondary,
                headline: detail,
                message: "This screen fills in as soon as the scan finishes."
            )
        case .idle, .ready:
            NoticeView(
                symbolName: "hourglass",
                tint: .secondary,
                headline: "Nothing scanned yet",
                message: "Start a scan from the previous screen."
            )
        }
    }

    // MARK: - Selection

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if canSelect {
                Button(isSelecting ? "Cancel" : "Select") {
                    isSelecting.toggle()
                    selection.removeAll()
                }
                .disabled(isDeleting)
            }
        }

    }

    /// Nothing to select when every item is synced or shared: the button
    /// would only lead to a screen where no tap does anything.
    private var canSelect: Bool { !selectableIDs.isEmpty }

    private var selectedBytes: Int64? {
        guard !selection.isEmpty else { return nil }
        let total = displayedRecords
            .filter { selection.contains($0.id) }
            .compactMap(\.size.bytes)
            .reduce(0, +)
        return total > 0 ? total : nil
    }

    /// Grouping categories get the one action that actually saves tapping:
    /// take every copy except the one marked to keep, across every set.
    private var bulkActionTitle: String {
        if category.detection == .grouping { return "Select extras" }
        return selection.count == selectableIDs.count ? "Deselect all" : "Select all"
    }

    private func applyBulkAction() {
        if category.detection == .grouping {
            var extras: Set<String> = []
            for group in loaded?.groups ?? [] {
                for member in group.members.dropFirst() where member.canDelete {
                    extras.insert(member.id)
                }
            }
            selection = extras
        } else {
            selection = selection.count == selectableIDs.count ? [] : Set(selectableIDs)
        }
    }

    /// Only what the app can actually delete. Synced and shared items are on
    /// screen so nothing silently disappears, but they never enter a selection.
    private var selectableIDs: [String] {
        displayedRecords.filter(\.canDelete).map(\.id)
    }

    private var displayedRecords: [AssetRecord] {
        guard let loaded else { return [] }
        switch category.detection {
        case .streaming: return loaded.records
        case .grouping:  return loaded.groups.flatMap(\.members)
        }
    }

    private func tap(_ record: AssetRecord) {
        guard isSelecting else {
            viewerTarget = ViewerTarget(record: record)
            return
        }
        guard record.canDelete else {
            deleteAlert = DeleteAlert(
                title: "Can't be deleted here",
                message: record.isSynced
                    ? Self.syncedExplanation
                    : "This item belongs to a shared album or another library, so this app can't remove it."
            )
            return
        }
        if selection.contains(record.id) {
            selection.remove(record.id)
        } else {
            selection.insert(record.id)
        }
    }

    private func performDelete() async {
        isDeleting = true
        let outcome = await store.delete(ids: selection)
        isDeleting = false

        switch outcome {
        case .deleted(let count, let notice):
            selection.removeAll()
            isSelecting = false
            if let notice {
                deleteAlert = DeleteAlert(
                    title: "Deleted \(count), some stayed",
                    message: notice
                )
            }
        case .nothingRemoved(let reason):
            deleteAlert = DeleteAlert(title: "Nothing was deleted", message: reason)
        case .cancelled:
            break
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
    private func content(_ loaded: LoadedContent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                VStack(alignment: .leading, spacing: 10) {
                    header(loaded)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                switch category.detection {
                case .grouping:
                    groupList(loaded.groups)
                        .padding(.horizontal, 16)
                case .streaming:
                    // Photos-style: the grid runs nearly edge to edge.
                    flatList(loaded.records)
                        .padding(.horizontal, layout(for: loaded.records.count) == .dense ? 2 : 16)
                }

                if let footnote = methodFootnote {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func header(_ loaded: LoadedContent) -> some View {
        SummaryRow(category: category, records: loaded.records, groups: loaded.groups)

        // Grouping categories skip the note: the summary row above already
        // carries the set count and the reclaimable total, and repeating it in
        // a card directly underneath was the same sentence twice.
        if let note = loaded.note, category.detection == .streaming {
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

        if syncedNoticeCount > 0 {
            SyncedNoticeRow(count: syncedNoticeCount) {
                deleteAlert = DeleteAlert(title: "Synced items", message: Self.syncedExplanation)
            }
        }
    }

    /// Synced items the user will actually run into on this screen, each
    /// counted once.
    ///
    /// For sets this used to count every member of every set, Keep copies and
    /// folded-away locked sets included, which is how a category with a few
    /// hundred sets reported thousands of synced items. Now it counts synced
    /// extras in the sets that are on screen. Locked sets have their own row.
    private var syncedNoticeCount: Int {
        guard let loaded else { return 0 }
        switch category.detection {
        case .streaming:
            return Set(loaded.records.filter(\.isSynced).map(\.id)).count
        case .grouping:
            var ids = Set<String>()
            for group in loaded.groups where group.removableCount > 0 {
                for member in group.members.dropFirst() where member.isSynced {
                    ids.insert(member.id)
                }
            }
            return ids.count
        }
    }

    /// How the matching was done, kept small and at the bottom. It matters for
    /// trust but it is not what the user came to read.
    private var methodFootnote: String? {
        switch category {
        case .duplicatePhotos:
            return "Exact copies are confirmed by comparing every byte of both files. Sets marked as saved again are the same picture stored as a different file, such as a re-save from a messaging app, found by comparing the images themselves at any date apart. In those, the highest-resolution copy is the one marked Keep. Screenshots are left out of that comparison."
        case .duplicateVideos:
            return "Confirmed by comparing every byte of both files."
        case .similarPhotos:
            return "Compared only against photos taken within \(Int(AppConfig.Similarity.timeWindowSeconds)) seconds of each other, or in the same burst."
        default:
            return nil
        }
    }

    // MARK: - Grouped layout

    /// Actionable sets first and always visible. Sets the app can't clean
    /// sit behind one row at the end, still reachable, so nothing is hidden
    /// without the user knowing it is there.
    @ViewBuilder
    private func groupList(_ groups: [AssetGroup]) -> some View {
        let actionable = groups.filter { $0.removableCount > 0 }
        let locked = groups.filter { $0.removableCount == 0 }

        LazyVStack(spacing: 12) {
            ForEach(actionable) { group in
                groupCard(group)
            }

            if !locked.isEmpty {
                LockedSetsRow(count: locked.count, isExpanded: showLockedSets) {
                    withAnimation(.easeOut(duration: 0.2)) { showLockedSets.toggle() }
                }

                if showLockedSets {
                    ForEach(locked) { group in
                        groupCard(group)
                    }
                }
            }
        }
    }

    private func groupCard(_ group: AssetGroup) -> some View {
        GroupCard(
            category: category,
            group: group,
            assetsByID: assetsByID,
            allowNetwork: allowNetworkPreviews,
            onOutcome: handleOutcome,
            isSelecting: isSelecting,
            selection: selection,
            onTap: tap,
            onView: { viewerTarget = ViewerTarget(record: $0) }
        )
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
    private func flatList(_ records: [AssetRecord]) -> some View {
        switch layout(for: records.count) {
        case .solo:
            if let record = records.first {
                SoloItemView(
                    record: record,
                    asset: assetsByID[record.id],
                    allowNetwork: allowNetworkPreviews,
                    onOutcome: handleOutcome,
                    isSelecting: isSelecting,
                    selection: selection,
                    onTap: tap
                )
            }

        case .pairs, .dense:
            LazyVGrid(columns: gridColumns(records.count), spacing: AppConfig.gridSpacing) {
                ForEach(records) { record in
                    AssetCell(
                        record: record,
                        asset: assetsByID[record.id],
                        caption: caption(for: record),
                        showsVideoGlyph: record.kind == .video,
                        allowNetwork: allowNetworkPreviews,
                        onOutcome: handleOutcome,
                        isSelecting: isSelecting,
                        isSelected: selection.contains(record.id),
                        onTap: tap
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
        guard let loaded else { return [] }
        switch category.detection {
        case .streaming: return loaded.records.map(\.id)
        case .grouping:  return loaded.groups.flatMap { $0.members.map(\.id) }
        }
    }

    /// Changes whenever the displayed set does, which re-runs resolution.
    /// The old one-shot guard meant grouping categories never resolved at all
    /// when their groups arrived after the view appeared.
    private var resolveKey: String {
        "\(displayedIDs.count)|\(displayedIDs.first ?? "")"
    }

    @MainActor
    private func resolveAssets() {
        let missing = displayedIDs.filter { assetsByID[$0] == nil }
        guard !missing.isEmpty else { return }

        // One database query for whatever is not already resolved. The result
        // is unordered, so it goes into a dictionary and the views keep the
        // index's own order.
        let result = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
        var map = assetsByID
        result.enumerateObjects { asset, _, _ in
            map[asset.localIdentifier] = asset
        }

        ThumbnailDiagnostics.logResolve(category: category.rawValue, requested: missing, resolved: map)

        assetsByID = map
    }
}

// MARK: - Group card

private struct GroupCard: View {

    let category: CategoryID
    let group: AssetGroup
    let assetsByID: [String: PHAsset]
    let allowNetwork: Bool
    let onOutcome: (String, ThumbnailOutcome) -> Void
    let isSelecting: Bool
    let selection: Set<String>
    let onTap: (AssetRecord) -> Void
    /// Opens the viewer regardless of select mode. The Keep copy uses it:
    /// it is never part of a cleanup, so in select mode it shows no
    /// checkbox and a tap previews it instead of doing nothing.
    let onView: (AssetRecord) -> Void

    /// Fills the card's width for the common two- and three-copy sets
    /// instead of leaving a third of it empty, and drops to rows of three
    /// for anything bigger.
    private var columns: [GridItem] {
        let count = min(max(group.members.count, 2), 3)
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private var memberNoun: String {
        category == .similarPhotos ? "similar shots" : "copies"
    }

    private var groupCaption: String? {
        var parts: [String] = []
        parts.append(Formatters.dimensions(
            width: group.representative.pixelWidth,
            height: group.representative.pixelHeight
        ))
        if let created = group.representative.creationDate {
            parts.append(created.formatted(date: .abbreviated, time: .omitted))
        }
        if let note = group.note {
            parts.append(note)
        }
        return parts.joined(separator: " · ")
    }

    /// Never a zero. A set with nothing removable says so; a set whose
    /// extras have no known size says how many can go instead of a size.
    private var trailing: (text: String, symbol: String?) {
        if group.removableCount == 0 {
            return ("Locked", "lock.fill")
        }
        if let bytes = group.reclaimableBytes, bytes > 0 {
            return ("\(Formatters.bytes(bytes)) to free", nil)
        }
        return ("\(group.removableCount) can go", nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(group.members.count) \(memberNoun)")
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    if let symbol = trailing.symbol {
                        Image(systemName: symbol).font(.caption2)
                    }
                    Text(trailing.text)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(group.members) { member in
                    memberTile(member)
                }
            }

            if let caption = groupCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func memberTile(_ member: AssetRecord) -> some View {
        let isKeep = member.id == group.representative.id

        return Button {
            if isKeep && isSelecting { onView(member) } else { onTap(member) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ThumbnailView(
                    record: member,
                    asset: assetsByID[member.id],
                    allowNetwork: allowNetwork,
                    aspect: .square,
                    onOutcome: onOutcome
                )
                .overlay {
                    // Keep is outlined in green; extras get nothing, so the
                    // one that stays is obvious without reading a badge.
                    if isKeep {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.green, lineWidth: 2.5)
                    }
                }
                .selectionDim(
                    isSelecting: isSelecting,
                    isSelected: selection.contains(member.id)
                )
                .overlay(alignment: .bottomTrailing) {
                    if !isKeep {
                        SelectionMark(
                            isSelecting: isSelecting,
                            isSelected: selection.contains(member.id),
                            isLocked: !member.canDelete
                        )
                    }
                }

                tileLabel(member, isKeep: isKeep)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ThumbnailButtonStyle())
    }

    /// Under each copy: what happens to it, and its size. This is what
    /// tells you which one goes, not just which one stays.
    private func tileLabel(_ member: AssetRecord, isKeep: Bool) -> some View {
        HStack(spacing: 4) {
            if isKeep {
                Label(group.representativeLabel, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if member.canDelete {
                Label("Extra", systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label(member.isSynced ? "Synced" : "Shared", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            if let bytes = member.size.bytes, bytes > 0 {
                Text(Formatters.bytes(bytes))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .labelStyle(CompactLabelStyle())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
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
    let isSelecting: Bool
    let selection: Set<String>
    let onTap: (AssetRecord) -> Void

    private var ratio: CGFloat {
        guard record.pixelWidth > 0, record.pixelHeight > 0 else { return 1 }
        return CGFloat(record.pixelWidth) / CGFloat(record.pixelHeight)
    }

    var body: some View {
        VStack(spacing: 12) {
            Button {
                onTap(record)
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
                    if record.kind == .video, !isSelecting {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.35), radius: 4)
                    }
                }
                .selectionDim(
                    isSelecting: isSelecting,
                    isSelected: selection.contains(record.id),
                    cornerRadius: 12
                )
                .overlay(alignment: .bottomTrailing) {
                    SelectionMark(
                        isSelecting: isSelecting,
                        isSelected: selection.contains(record.id),
                        isLocked: !record.canDelete,
                        size: 26
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ThumbnailButtonStyle())

            DetailFacts(record: record)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5)
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

/// A Photos-style tile: the thumbnail is the whole cell, with duration or
/// size in a small badge in the corner and no play button.
private struct AssetCell: View {

    let record: AssetRecord
    let asset: PHAsset?
    let caption: String?
    var showsVideoGlyph: Bool = false
    let allowNetwork: Bool
    let onOutcome: (String, ThumbnailOutcome) -> Void
    let isSelecting: Bool
    let isSelected: Bool
    let onTap: (AssetRecord) -> Void

    var body: some View {
        Button {
            onTap(record)
        } label: {
            ThumbnailView(
                record: record,
                asset: asset,
                allowNetwork: allowNetwork,
                aspect: .square,
                onOutcome: onOutcome
            )
            .overlay(alignment: .bottomLeading) {
                if let caption {
                    CaptionBadge(text: caption, showsVideoGlyph: showsVideoGlyph)
                        .padding(4)
                }
            }
            .selectionDim(isSelecting: isSelecting, isSelected: isSelected)
            .overlay(alignment: .bottomTrailing) {
                SelectionMark(isSelecting: isSelecting, isSelected: isSelected, isLocked: !record.canDelete)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ThumbnailButtonStyle())
        .accessibilityLabel(record.kind == .video ? "Video\(caption.map { ", \($0)" } ?? "")" : "Photo")
    }
}

/// Duration or size on a tile. Sits on its own small dark capsule, so it
/// reads on a white thumbnail as well as a dark one, and stays compact so it
/// covers as little of the frame as possible.
private struct CaptionBadge: View {

    let text: String
    var showsVideoGlyph: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            if showsVideoGlyph {
                Image(systemName: "video.fill")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.55), in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

/// Dims and slightly shrinks a selected thumbnail.
///
/// A 22-point tick on an 84-point tile is easy to miss when half a screen of
/// them look otherwise identical. Photos leans on the whole tile changing, not
/// the badge, and that is what makes a selection readable at a glance.
private struct SelectionDim: ViewModifier {

    let isSelecting: Bool
    let isSelected: Bool
    var cornerRadius: CGFloat = 6

    private var isDimmed: Bool { isSelecting && isSelected }

    func body(content: Content) -> some View {
        content
            .overlay {
                if isDimmed {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.white.opacity(0.25))
                }
            }
            .animation(.easeOut(duration: 0.15), value: isDimmed)
    }
}

private extension View {
    func selectionDim(isSelecting: Bool, isSelected: Bool, cornerRadius: CGFloat = 6) -> some View {
        modifier(SelectionDim(isSelecting: isSelecting, isSelected: isSelected, cornerRadius: cornerRadius))
    }
}

/// The blue tick that appears on a thumbnail in selection mode.
///
/// Items the app can't delete get a lock instead, in and out of selection
/// mode. Outside it, the lock is how the user learns before trying; inside
/// it, an empty circle that never fills would read as a broken tap.
private struct SelectionMark: View {

    let isSelecting: Bool
    let isSelected: Bool
    var isLocked: Bool = false
    /// Photos uses a small mark in the corner. Anything bigger starts to
    /// cover the picture it is marking.
    var size: CGFloat = 19

    var body: some View {
        if isLocked {
            Image(systemName: "lock.fill")
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 1.5)
                .padding(6)
        } else if isSelecting {
            ZStack {
                Circle()
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.black.opacity(0.18)))
                Circle()
                    .strokeBorder(.white, lineWidth: 1.5)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.25), radius: 1.5)
            .padding(5)
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

/// One line, same shape on every screen, matching the home card. Flat
/// screens say "items" because the nav title already names the category;
/// set screens keep the qualifier, since their number counts extras.
/// "218 items · 1.2 GB", "10 extra copies · 15.5 MB to free".
private struct SummaryRow: View {

    let category: CategoryID
    let records: [AssetRecord]
    let groups: [AssetGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(primary)
                .font(.headline)
                .monospacedDigit()
            if let secondary {
                Text(secondary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var count: Int {
        category.detection == .grouping
            ? groups.reduce(0) { $0 + $1.removableCount }
            : records.count
    }

    private var primary: String {
        let noun = category.qualifier(count) ?? (count == 1 ? "item" : "items")
        guard let size = sizeText else { return "\(count) \(noun)" }
        return "\(count) \(noun) · \(size)"
    }

    private var sizeText: String? {
        if category.detection == .grouping {
            let actionable = groups.filter { $0.removableCount > 0 }
            let reclaim = actionable.compactMap(\.reclaimableBytes).reduce(0, +)
            guard reclaim > 0 else { return nil }
            let allKnown = actionable.allSatisfy { $0.reclaimableBytes != nil }
            return "\(Formatters.bytes(reclaim))\(allKnown ? "" : "+") to free"
        }
        var sum: Int64 = 0
        var allKnown = true
        for record in records {
            if let bytes = record.size.bytes { sum += bytes } else { allKnown = false }
        }
        guard sum > 0 else { return nil }
        return "\(Formatters.bytes(sum))\(allKnown ? "" : "+")"
    }

    private var secondary: String? {
        guard category.detection == .grouping else { return nil }
        let sets = groups.filter { $0.removableCount > 0 }.count
        guard sets > 0 else { return "Nothing this app can remove" }
        return "Across \(sets) set\(sets == 1 ? "" : "s")"
    }
}

/// The fold between sets the user can act on and sets they can't.
private struct LockedSetsRow: View {

    let count: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "lock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) locked set\(count == 1 ? "" : "s")")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(isExpanded ? "Hide" : "Synced or shared copies only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One line instead of a paragraph. The full explanation is a tap away.
private struct SyncedNoticeRow: View {

    let count: Int
    let onInfo: () -> Void

    var body: some View {
        Button(action: onInfo) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("\(count) synced from a computer, can't be deleted here")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Image(systemName: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The select-mode bar: one surface, three clearly different roles. The
/// count is plain text, the bulk action is a plain button, and Delete is red
/// and filled so it can't be mistaken for anything else.
private struct SelectionBar: View {

    let selectedCount: Int
    let selectedBytes: Int64?
    let bulkTitle: String
    let isDeleting: Bool
    let onBulk: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(bulkTitle, action: onBulk)
                .font(.subheadline.weight(.medium))
                .disabled(isDeleting)

            Spacer(minLength: 4)

            VStack(spacing: 1) {
                if isDeleting {
                    ProgressView()
                } else {
                    Text(selectedCount == 0 ? "Select items" : "\(selectedCount) selected")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    if let selectedBytes {
                        Text(Formatters.bytes(selectedBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Spacer(minLength: 4)

            // Straight to PhotoKit, which shows its own confirmation.
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selectedCount == 0 || isDeleting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Notice

struct NoticeView: View {

    let symbolName: String
    let tint: Color
    let headline: String
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 18) {
                // Layered rings rather than one flat square. An empty screen
                // has nothing else on it, so the one element that is there
                // has to carry the weight.
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.10))
                        .frame(width: 104, height: 104)

                    Circle()
                        .fill(tint.opacity(0.16))
                        .frame(width: 72, height: 72)

                    Image(systemName: symbolName)
                        .font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(spacing: 7) {
                    Text(headline)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)

                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, 34)
            .padding(.horizontal, 26)
            .frame(maxWidth: .infinity)
            // Sitting the message on a card stops it reading as a screen that
            // failed to load something.
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.5)
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
