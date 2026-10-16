#if os(iOS)
import HexNFCDesign
import SwiftUI

/// Full-text card for one legal document, presented from Settings > Legal.
/// Pure reading surface: scrollable typographic layout, no interaction beyond
/// Done. The document text itself lives in `LegalDocuments.swift`.
struct LegalSheet: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HexTokens.Spacing.xl) {
                    preamble
                    ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, HexTokens.Spacing.xl)
                .padding(.top, HexTokens.Spacing.l)
                .padding(.bottom, HexTokens.Spacing.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle(Text(document.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HexTokens.Color.primaryLight)
                }
            }
            .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
    }

    /// Effective date + publisher. Part of the document's identity, so the
    /// strings come from the model verbatim rather than the string catalog.
    private var preamble: some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.xs) {
            Text(verbatim: "Effective \(document.effectiveDate)")
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
            Text(verbatim: document.publisherLine)
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func sectionView(_ section: LegalSection) -> some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
            Text(verbatim: section.heading)
                .font(HexTokens.Font.heading)
                .foregroundStyle(HexTokens.Color.textPrimary)
            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                paragraphView(paragraph)
            }
        }
    }

    private func paragraphView(_ paragraph: String) -> some View {
        Text(verbatim: paragraph)
            .font(HexTokens.Font.body)
            .foregroundStyle(HexTokens.Color.textPrimary)
            .lineSpacing(3)
            .padding(.leading, paragraph.hasPrefix("\u{2022}") ? HexTokens.Spacing.m : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif
