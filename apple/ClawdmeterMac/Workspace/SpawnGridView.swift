import SwiftUI
import AppKit
import ClawdmeterShared

/// Center-pane surface for an open spawn group: a BridgeMind-style grid of
/// agent terminal tiles. One tile is the typing target (border highlight +
/// keyboard focus); any tile can expand to fill the pane and compact back
/// into the grid. The right review pane never renders for spawn groups —
/// the grid owns the full center width.
struct SpawnGridView: View {
    @ObservedObject var store: SpawnModeStore
    let group: SpawnGroup

    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Per-tile focus request counter. Bumping a tile's token makes its
    /// terminal first responder (header tap / select without clicking
    /// inside the terminal itself).
    @State private var focusTokens: [UUID: Int] = [:]
    @State private var showingCloseConfirm = false

    private var selectedTileId: UUID? { store.selectedTileByGroup[group.id] }
    private var expandedTileId: UUID? {
        guard let id = store.expandedTileByGroup[group.id],
              group.tiles.contains(where: { $0.id == id })
        else { return nil }
        return id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TahoeHairline()
            tilesSurface
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.spawn.grid")
        .onAppear {
            // Hand the keyboard to the selected tile as soon as the grid
            // opens — the border highlight and the typing target must agree.
            if let selected = selectedTileId {
                focusTokens[selected, default: 0] += 1
            }
        }
        // Keep keyboard focus tracking store-driven selection changes too
        // (e.g. closeTile falls back to the first remaining tile) so the
        // border and the typing target never diverge.
        .onChange(of: selectedTileId) { _, newValue in
            if let newValue {
                focusTokens[newValue, default: 0] += 1
            }
        }
        .confirmationDialog(
            "Close \(group.name)?",
            isPresented: $showingCloseConfirm
        ) {
            Button("End \(liveTileCount) running \(liveTileCount == 1 ? "agent" : "agents")", role: .destructive) {
                store.closeGroup(id: group.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every terminal in this spawn ends immediately. Sessions are not recoverable.")
        }
    }

    private var liveTileCount: Int {
        store.liveTileCount(in: group)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(t.fg2)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(TahoeFont.body(15, weight: .bold))
                    .foregroundStyle(t.fg)
                Text("\(group.tiles.count) \(group.tiles.count == 1 ? "terminal" : "terminals") · \(group.agentSummary) · in ~")
                    .font(TahoeFont.mono(10.5))
                    .foregroundStyle(t.fg3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if expandedTileId != nil {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        store.expandedTileByGroup[group.id] = nil
                    }
                } label: {
                    Label("Back to grid", systemImage: "square.grid.2x2")
                        .font(TahoeFont.body(11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(t.fg2)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(t.hairline, lineWidth: 0.5)
                )
                .help("Send the expanded session back into the grid")
                .accessibilityIdentifier("code.spawn.header.compact")
            }
            Button {
                // One misclick must not kill up to 8 mid-task agents —
                // confirm when any tile is still live. All-exited groups
                // close instantly (nothing left to lose).
                if liveTileCount > 0 {
                    showingCloseConfirm = true
                } else {
                    store.closeGroup(id: group.id)
                }
            } label: {
                Label("Close spawn", systemImage: "xmark")
                    .font(TahoeFont.body(11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(t.fg2)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(t.hairline, lineWidth: 0.5)
            )
            .help("End every terminal in \(group.name)")
            .accessibilityIdentifier("code.spawn.header.close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Tiles

    /// One flat ForEach inside a custom Layout so every tile keeps its
    /// SwiftUI identity across expand/compact AND grid reflow after a tile
    /// closes. Recreating a tile tears down its SwiftTerm view and replays
    /// only the 128KB PTY ring — losing scrollback and garbling TUI state —
    /// so structural identity here is load-bearing, not stylistic.
    private var tilesSurface: some View {
        SpawnTilesLayout(
            columns: SpawnPlan.gridColumns(forTileCount: group.tiles.count),
            expandedIndex: expandedTileId.flatMap { id in
                group.tiles.firstIndex(where: { $0.id == id })
            }
        ) {
            ForEach(group.tiles) { tile in
                tileView(tile, isExpanded: expandedTileId == tile.id)
                    // Parked tiles draw offscreen (clipped) but their
                    // AppKit frames still exist — block hit-testing so a
                    // click can never reach an invisible terminal.
                    .allowsHitTesting(expandedTileId == nil || expandedTileId == tile.id)
            }
        }
        // Explicit flexible frame: sizeThatFits echoes the proposal, so
        // an unspecified proposal must not collapse the grid to zero.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
        .clipped()  // parked (offscreen) tiles must not paint outside
    }

    @ViewBuilder
    private func tileView(_ tile: SpawnTile, isExpanded: Bool) -> some View {
        let isSelected = selectedTileId == tile.id
        let providerColor = tile.agent.tahoeProvider.dot
        VStack(spacing: 0) {
            tileHeader(tile, isExpanded: isExpanded, isSelected: isSelected)
            SpawnTerminalView(
                host: tile.host,
                focusToken: focusTokens[tile.id] ?? 0,
                onDidFocus: { store.selectTile(groupId: group.id, tileId: tile.id) }
            )
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            // Selection = the typing target. Provider color carries the
            // highlight (color-as-identity per DESIGN.md); unselected tiles
            // sit behind the standard hairline.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isSelected ? providerColor.opacity(0.9) : t.hairline,
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isSelected)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.spawn.tile.\(tile.title)")
        .accessibilityValue(isSelected ? "selected" : "")
    }

    private func tileHeader(_ tile: SpawnTile, isExpanded: Bool, isSelected: Bool) -> some View {
        let exited = store.exitedTileIds.contains(tile.id)
        return HStack(spacing: 7) {
            ProviderDot(tile.agent.tahoeProvider, size: 6)
            TahoeProviderGlyph(provider: tile.agent.tahoeProvider, size: 16)
            Text(tile.title)
                .font(TahoeFont.body(11.5, weight: .semibold))
                .foregroundStyle(isSelected ? t.fg : t.fg2)
                .lineLimit(1)
            if exited {
                Text("exited")
                    .font(TahoeFont.mono(9.5))
                    .foregroundStyle(t.paused)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(t.hairline, lineWidth: 0.5))
            }
            Spacer(minLength: 4)
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    store.toggleExpanded(groupId: group.id, tileId: tile.id)
                }
                requestFocus(tile)
            } label: {
                Image(systemName: isExpanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(t.fg3)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .help(isExpanded ? "Compact back into the grid" : "Expand this session")
            .accessibilityLabel(isExpanded ? "Compact \(tile.title) back into the grid" : "Expand \(tile.title)")
            .accessibilityIdentifier("code.spawn.tile.expand.\(tile.title)")
            Button {
                store.closeTile(groupId: group.id, tileId: tile.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(t.fg3)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .help("End this terminal")
            .accessibilityLabel("End \(tile.title)")
            .accessibilityIdentifier("code.spawn.tile.close.\(tile.title)")
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(isSelected ? t.surface3 : t.surface2)
        .contentShape(Rectangle())
        .onTapGesture {
            requestFocus(tile)
        }
    }

    /// Select the tile AND hand its terminal the keyboard.
    private func requestFocus(_ tile: SpawnTile) {
        store.selectTile(groupId: group.id, tileId: tile.id)
        focusTokens[tile.id, default: 0] += 1
    }
}

// MARK: - Layout

/// Grid layout with an expand mode that PRESERVES subview identity.
///
/// Grid mode: rows × columns filling the bounds evenly. Expanded mode: the
/// expanded tile gets the full bounds; every other tile keeps its normal
/// grid size but is parked just below the visible bounds (clipped by the
/// container). Parking — instead of removing or zero-sizing — means the
/// SwiftTerm views are never torn down or resized, so no PTY-ring replay,
/// no scrollback loss, and no mid-escape garbling on expand/compact.
struct SpawnTilesLayout: Layout {
    var columns: Int
    var expandedIndex: Int?
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let cols = max(1, columns)
        let rows = max(1, Int(ceil(Double(subviews.count) / Double(cols))))
        let tileWidth = max(1, (bounds.width - spacing * CGFloat(cols - 1)) / CGFloat(cols))
        let tileHeight = max(1, (bounds.height - spacing * CGFloat(rows - 1)) / CGFloat(rows))
        let tileProposal = ProposedViewSize(width: tileWidth, height: tileHeight)

        if let expandedIndex, subviews.indices.contains(expandedIndex) {
            for (index, subview) in subviews.enumerated() {
                if index == expandedIndex {
                    subview.place(
                        at: bounds.origin,
                        proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
                    )
                } else {
                    // Parked below the clipped bounds at normal grid size.
                    subview.place(
                        at: CGPoint(x: bounds.minX, y: bounds.maxY + spacing),
                        proposal: tileProposal
                    )
                }
            }
            return
        }

        for (index, subview) in subviews.enumerated() {
            let row = index / cols
            let col = index % cols
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(col) * (tileWidth + spacing),
                    y: bounds.minY + CGFloat(row) * (tileHeight + spacing)
                ),
                proposal: tileProposal
            )
        }
    }
}
