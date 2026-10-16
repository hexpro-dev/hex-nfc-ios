#if os(iOS)
import HexNFCDesign
import HexNFCKit
import HexNFCRecords
import HexNFCShaders
import HexNFCStorage
import SwiftUI

/// Library: Presets + History tabs. Replaces the Phase-2 placeholder.
struct LibrarySheet: View {
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .presets

    /// Bubbled up to RootView when a preset's "Write" action fires — opens
    /// the WriteSheet against this preset's records.
    let onWritePreset: (Preset) -> Void
    /// Bubbled up to RootView when a history entry's tap fires — opens the
    /// TagEditor pre-populated with the snapshot.
    let onOpenHistoryEntry: (HistoryEntry) -> Void

    enum Tab: Hashable { case presets, history }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                Group {
                    switch selectedTab {
                    case .presets:
                        PresetsList(
                            library: appModel.library,
                            onWrite: onWritePreset
                        )

                    case .history:
                        HistoryList(
                            library: appModel.library,
                            onOpen: onOpenHistoryEntry
                        )
                    }
                }
            }
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle(Text("Library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HexTokens.Color.primaryLight)
                        .hexPressHaptic()
                }
            }
            .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Presets", tab: .presets)
            tabButton("History", tab: .history)
        }
        .padding(.horizontal, HexTokens.Spacing.l)
        .padding(.top, HexTokens.Spacing.s)
        // `.contain` keeps the two buttons as their own elements (this is a
        // switcher, not one label) while telling VoiceOver the group is a tab
        // bar, which is what makes it announce "tab 1 of 2".
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }

    private func tabButton(_ title: LocalizedStringKey, tab: Tab) -> some View {
        let isSelected = (tab == selectedTab)
        return Button {
            withAnimation(HexTokens.Motion.snappy) { selectedTab = tab }
        } label: {
            VStack(spacing: HexTokens.Spacing.xs) {
                Text(title)
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(isSelected ? HexTokens.Color.textPrimary : HexTokens.Color.textSecondary)
                Rectangle()
                    .fill(isSelected ? HexTokens.Color.primaryLight : Color.clear)
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HexTokens.Spacing.s)
        }
        .hexPressStyle()
        // Selection is carried by the text colour and the 2pt underline, and
        // VoiceOver reports neither, so both tabs read identically and there was
        // no way to hear which list was on screen.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Presets list

private struct PresetsList: View {
    let library: LibraryRepository
    let onWrite: (Preset) -> Void
    @State private var presets: [Preset] = []
    @State private var shareTarget: ShareItem?

    var body: some View {
        Group {
            if presets.isEmpty {
                ContentUnavailableView(
                    "No saved presets",
                    systemImage: "tray",
                    description: Text("Save the records you're editing as a preset to find them here.")
                )
            } else {
                List {
                    ForEach(presets) { preset in
                        PresetRow(preset: preset)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(preset)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    duplicate(preset)
                                } label: {
                                    Label("Duplicate", systemImage: "plus.square.on.square")
                                }
                                .tint(HexTokens.Color.warning)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    HexHeroMoment.commit.play()
                                    onWrite(preset)
                                } label: {
                                    Label("Write", systemImage: "square.and.arrow.up")
                                }
                                .tint(HexTokens.Color.primaryLight)
                                Button {
                                    share(preset)
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up.on.square")
                                }
                                .tint(HexTokens.Color.success)
                            }
                            .listRowBackground(HexTokens.Color.surface1)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(HexTokens.Color.surface0)
            }
        }
        .task { reload() }
        .sheet(item: $shareTarget) { item in
            ShareSheet(items: [item.url])
        }
    }

    private func reload() {
        presets = (try? library.fetchPresets()) ?? []
    }

    private func delete(_ preset: Preset) {
        try? library.deletePreset(preset)
        reload()
    }

    private func duplicate(_ preset: Preset) {
        _ = try? library.duplicatePreset(preset)
        reload()
    }

    private func share(_ preset: Preset) {
        do {
            let data = try library.exportAsHexnfc(preset)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(preset.name).hexnfc")
            try data.write(to: url)
            shareTarget = ShareItem(url: url)
        } catch {
            // Sharing is best-effort; failures here just dismiss the gesture.
        }
    }
}

private struct PresetRow: View {
    let preset: Preset

    var body: some View {
        HStack(spacing: HexTokens.Spacing.m) {
            HexagonSliceBadge(slice: preset.iconHexSlice)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: HexTokens.Spacing.xs) {
                HStack(spacing: HexTokens.Spacing.xs) {
                    Text(preset.name)
                        .font(HexTokens.Font.heading)
                        .foregroundStyle(HexTokens.Color.textPrimary)
                    // A preset that locks the tags it's written to is a very
                    // different thing to write than one that doesn't, and the row
                    // gave no sign of it.
                    if preset.decodedProtection()?.passwordProtect == true {
                        Image(systemName: "lock.fill")
                            .font(HexTokens.Font.footnote)
                            .foregroundStyle(HexTokens.Color.warning)
                            .accessibilityLabel(Text("Applies protection"))
                    }
                }
                // Inflected via the string catalog rather than an inline
                // `count == 1 ? "" : "s"`, which hardcodes English plural rules
                // into a localized app.
                Text(
                    "^[\(preset.decodedRecords().count) record](inflect: true) · \(preset.updatedAt.formatted(date: .abbreviated, time: .omitted))"
                )
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, HexTokens.Spacing.xs)
    }
}

private struct HexagonSliceBadge: View {
    let slice: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                .fill(HexTokens.Color.primary.opacity(0.16))
            Image(systemName: systemImage)
                .foregroundStyle(HexTokens.Color.primaryLight)
                .imageScale(.medium)
        }
    }

    private var systemImage: String {
        switch slice {
        case 1: "chevron.up"
        case 2: "chevron.down"
        default: "hexagon"
        }
    }
}

// MARK: - History list

private struct HistoryList: View {
    let library: LibraryRepository
    let onOpen: (HistoryEntry) -> Void
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No scan history",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("The last 50 tags you scan show up here. Pin one to keep it.")
                )
            } else {
                List {
                    ForEach(entries) { entry in
                        Button {
                            onOpen(entry)
                        } label: {
                            HistoryRow(entry: entry)
                        }
                        .hexPressStyle(.medium)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                delete(entry)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                togglePin(entry)
                            } label: {
                                Label(entry.pinned ? "Unpin" : "Pin",
                                      systemImage: entry.pinned ? "pin.slash" : "pin")
                            }
                            .tint(HexTokens.Color.warning)
                        }
                        .listRowBackground(HexTokens.Color.surface1)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(HexTokens.Color.surface0)
            }
        }
        .task { reload() }
    }

    private func reload() {
        entries = (try? library.fetchHistory()) ?? []
    }

    private func delete(_ entry: HistoryEntry) {
        try? library.deleteHistory(entry)
        reload()
    }

    private func togglePin(_ entry: HistoryEntry) {
        try? library.togglePin(entry)
        reload()
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: HexTokens.Spacing.m) {
            Image(systemName: entry.pinned ? "pin.fill" : "dot.radiowaves.left.and.right")
                .foregroundStyle(entry.pinned ? HexTokens.Color.warning : HexTokens.Color.primaryLight)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: HexTokens.Radius.s, style: .continuous)
                        .fill((entry.pinned ? HexTokens.Color.warning : HexTokens.Color.primary).opacity(0.16))
                )
            VStack(alignment: .leading, spacing: HexTokens.Spacing.xs) {
                Text(entry.displayName)
                    .font(HexTokens.Font.heading)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                Text("\(entry.displayUID) · \(entry.scannedAt.formatted(.relative(presentation: .named)))")
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, HexTokens.Spacing.xs)
    }
}

// MARK: - Share-sheet bridge (UIActivityViewController)

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#endif
