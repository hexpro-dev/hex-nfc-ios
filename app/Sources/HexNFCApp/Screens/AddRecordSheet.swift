#if os(iOS)
import HexNFCDesign
import HexNFCRecords
import SwiftUI

/// Category-grid picker. Tap a category, get a new record of that kind
/// (with default values), and route immediately into the record editor.
///
/// The tiles are `AddRecordKind.offered`, which says which kinds are left out
/// and why.
struct AddRecordSheet: View {
    let onPick: (NDEFRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingQR = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: HexTokens.Spacing.m),
                        GridItem(.flexible(), spacing: HexTokens.Spacing.m),
                    ],
                    spacing: HexTokens.Spacing.m
                ) {
                    Button {
                        showingQR = true
                    } label: {
                        HexCard {
                            VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
                                Image(systemName: "qrcode.viewfinder")
                                    .foregroundStyle(HexTokens.Color.primaryLight)
                                    .imageScale(.large)
                                Text("Scan QR")
                                    .font(HexTokens.Font.heading)
                                    .foregroundStyle(HexTokens.Color.textPrimary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("add.qr")
                    ForEach(AddRecordKind.offered, id: \.self) { kind in
                        tile(for: kind)
                    }
                }
                .padding(HexTokens.Spacing.l)
            }
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle(Text("Add record"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(HexTokens.Color.textSecondary)
                }
            }
            .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingQR) {
            QRImportSheet { record in
                onPick(record)
            }
        }
    }

    private func tile(for kind: AddRecordKind) -> some View {
        Button {
            onPick(kind.makeRecord())
        } label: {
            HexCard {
                VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
                    Image(systemName: kind.systemImage)
                        .foregroundStyle(HexTokens.Color.primaryLight)
                        .imageScale(.large)
                    Text(kind.title)
                        .font(HexTokens.Font.heading)
                        .foregroundStyle(HexTokens.Color.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("add.\(kind.identifier)")
    }
}
#endif
