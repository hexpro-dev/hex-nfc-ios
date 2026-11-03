#if os(iOS)
import HexNFCDesign
import HexNFCKit
import HexNFCRecords
import HexNFCShaders
import SwiftUI
import UIKit

/// Read-only presentation for a scanned electronic passport. Shows the face
/// image (DG2) and the machine-readable-zone fields (DG1), plus any extended
/// details (DG11/DG12). The data is **session-only** — held for this view and
/// dropped, never persisted — and is presented, **not verified** (the app does
/// no Passive Authentication, so it makes no authenticity claim).
struct PassportResultSheet: View {
    let passport: PassportData
    var tagInfo: ScannedTagInfo?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HexTokens.Spacing.l) {
                    hero
                    mrzCard
                    if let report = passport.integrity {
                        integrityCard(report)
                    }
                    if let signature = decodedSignature {
                        signatureCard(signature)
                    }
                    if let bio = passport.biographical, !bio.isEmpty {
                        extendedCard(bio)
                    }
                    TagInfoCard(tag: resolvedTagInfo, extraRows: [])
                    disclaimer
                }
                .padding(HexTokens.Spacing.l)
            }
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle(Text(navigationTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(HexTokens.Color.textSecondary)
                }
            }
            .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
        // The unlock reveal (rainbow lines -> rings around the logo -> burst ->
        // recede) plays on the SCAN screen during the read, not here; the result
        // sheet is the calm landing after it. See `.hexPassportReveal`.
        .accessibilityIdentifier("passport.sheet")
    }

    // MARK: - Hero

    private var hero: some View {
        PassportBookletHero(
            photo: decodedFace.map { Image(uiImage: $0) },
            documentTypeLabel: passportTypeLabel,
            issuingState: passport.issuingState,
            surname: passport.primaryIdentifier,
            givenNames: passport.secondaryIdentifier,
            fullName: heroFullName,
            secondaryFields: heroFields,
            mrzLines: mrzLines,
            statusBadge: integrityBadge
        )
        // The success haptic + reveal are composed at the sheet level via
        // `.hexPassportReveal`, so the hero itself stays presentational.
        .accessibilityIdentifier("passport.hero")
    }

    /// China's travel permits answer as eMRTDs but are not passports, and
    /// their DG1 carries no name, nationality or sex (see `MRZParser`).
    private var isPermit: Bool {
        passport.mrzLayout == .chineseTravelPermit
    }

    private var passportTypeLabel: String {
        if isPermit {
            return String(localized: "Travel permit")
        }
        return passport.documentType.uppercased().hasPrefix("P")
            ? String(localized: "Passport")
            : passport.documentType
    }

    private var navigationTitle: LocalizedStringKey {
        isPermit ? "Travel permit" : "Passport"
    }

    private var documentNumberLabel: LocalizedStringKey {
        isPermit ? "Permit No." : "Passport No."
    }

    /// DG11's full name stands in on the page when the MRZ gave no name at all.
    private var heroFullName: String? {
        guard passport.primaryIdentifier.isEmpty, passport.secondaryIdentifier.isEmpty else { return nil }
        return passport.biographical?.fullName
    }

    /// Fields DG1 did not carry are left off rather than shown as "n/a".
    private var heroFields: [PassportBookletHero.Field] {
        let fields: [(label: LocalizedStringKey, value: String)] = [
            (documentNumberLabel, passport.documentNumber),
            ("Nationality", passport.nationality),
            ("Date of birth", formattedMRZDate(passport.dateOfBirth, isExpiry: false)),
            ("Sex", sexText),
            ("Date of expiry", formattedMRZDate(passport.dateOfExpiry, isExpiry: true)),
        ]
        return fields
            .filter { !$0.value.isEmpty }
            .map { PassportBookletHero.Field(label: $0.label, value: $0.value) }
    }

    private var mrzLines: [String] {
        passport.rawMRZ.split(whereSeparator: \.isNewline).map(String.init)
    }

    private var integrityBadge: PassportBookletHero.StatusBadge? {
        guard let report = passport.integrity else { return nil }
        switch report.status {
        case .verified:
            return .init(text: "Likely untampered", systemImage: "checkmark.shield.fill", tone: .good)

        case .mismatch:
            return .init(text: "Likely tampered", systemImage: "exclamationmark.shield.fill", tone: .bad)
        }
    }

    // MARK: - MRZ card

    private var mrzCard: some View {
        card(title: isPermit ? "Permit details" : "Passport details") {
            row("Surname", passport.primaryIdentifier)
            row("Given names", passport.secondaryIdentifier)
            row(documentNumberLabel, passport.documentNumber)
            row("Nationality", passport.nationality)
            row("Issuing state", passport.issuingState)
            row("Date of birth", formattedMRZDate(passport.dateOfBirth, isExpiry: false))
            row("Sex", sexText)
            row("Date of expiry", formattedMRZDate(passport.dateOfExpiry, isExpiry: true))
            if !passport.optionalData.isEmpty {
                // A permit's optional data is the holder's Hong Kong, Macao or
                // Taiwan identity number (see `MRZParser`).
                row(isPermit ? "Personal number" : "Optional data", passport.optionalData)
            }
        }
    }

    @ViewBuilder
    private func integrityCard(_ report: PassportIntegrityReport) -> some View {
        let ok = report.status == .verified
        card(title: "Data integrity") {
            Label(
                ok ? "Likely untampered" : "Likely tampered",
                systemImage: ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
            )
            .font(HexTokens.Font.heading)
            .foregroundStyle(ok ? HexTokens.Color.success : HexTokens.Color.dangerText)
            if !report.checkedDataGroups.isEmpty {
                row("Checked", report.checkedDataGroups.map { "DG\($0)" }.joined(separator: ", "))
            }
            row("Hash", report.hashAlgorithm)
            if !report.mismatchedDataGroups.isEmpty {
                row("Mismatch", report.mismatchedDataGroups.map { "DG\($0)" }.joined(separator: ", "))
            }
            Text(
                "The data groups match the hash list in the chip's security object. That object's own signature isn't verified, so this is not proof the data is unaltered or a check of the passport's authenticity."
            )
            .font(HexTokens.Font.footnote)
            .foregroundStyle(HexTokens.Color.textSecondary.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func signatureCard(_ image: UIImage) -> some View {
        card(title: "Signature") {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 80)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func extendedCard(_ bio: PassportBiographical) -> some View {
        card(title: "Additional details") {
            if let v = bio.fullName {
                row("Full name", v)
            }
            if let v = bio.fullDateOfBirth {
                row("Date of birth", v)
            }
            if let v = bio.placeOfBirth {
                row("Place of birth", v)
            }
            if let v = bio.permanentAddress {
                row("Address", v)
            }
            if let v = bio.telephone {
                row("Telephone", v)
            }
            if let v = bio.profession {
                row("Profession", v)
            }
            if let v = bio.personalNumber {
                row("Personal number", v)
            }
            if let v = bio.issuingAuthority {
                row("Issuing authority", v)
            }
            if let v = bio.dateOfIssue {
                row("Date of issue", v)
            }
            ForEach(Array(bio.otherNames.enumerated()), id: \.offset) { _, name in
                row("Other name", name)
            }
        }
    }

    private var disclaimer: some View {
        Label(
            "Read from the chip and shown here for this session only: not saved, not sent, and not verified for authenticity.",
            systemImage: "lock.shield"
        )
        .font(HexTokens.Font.footnote)
        .foregroundStyle(HexTokens.Color.textSecondary.opacity(0.85))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Building blocks

    private func card(title: LocalizedStringKey, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: HexTokens.Spacing.s) {
            Text(title)
                .font(HexTokens.Font.heading)
                .foregroundStyle(HexTokens.Color.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HexTokens.Spacing.m)
        .background(
            HexTokens.Color.surface1,
            in: RoundedRectangle(cornerRadius: HexTokens.Radius.l, style: .continuous)
        )
    }

    @ViewBuilder
    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top) {
                Text(label)
                    .font(HexTokens.Font.footnote)
                    .foregroundStyle(HexTokens.Color.textSecondary)
                Spacer(minLength: HexTokens.Spacing.m)
                Text(verbatim: value)
                    .font(HexTokens.Font.body)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Derived values

    /// Empty when DG1 has no sex field at all, so the row drops; `<` and `X`
    /// are the MRZ's own "unspecified".
    private var sexText: String {
        switch passport.sex.uppercased() {
        case "": ""
        case "M": String(localized: "Male")
        case "F": String(localized: "Female")
        default: String(localized: "Unspecified")
        }
    }

    private var decodedFace: UIImage? {
        guard let face = passport.faceImage else { return nil }
        // JPEG decodes natively; JPEG 2000 is unreliable on iOS — UIImage returns
        // nil there and the placeholder shows, which is the graceful fallback.
        return UIImage(data: face.data)
    }

    private var decodedSignature: UIImage? {
        guard let signature = passport.signatureImage else { return nil }
        return UIImage(data: signature.data)
    }

    private var resolvedTagInfo: ScannedTagInfo {
        let live = tagInfo
        return ScannedTagInfo(
            chipName: live?.chipName ?? String(localized: "ePassport"),
            familyName: String(localized: "eMRTD (ISO/IEC 14443-4)"),
            // Chip vendor isn't read from a passport, so the Maker row is dropped
            // rather than showing a placeholder.
            manufacturer: nil,
            uidHex: live?.uidHex,
            totalBytes: live?.totalBytes,
            ndefBytes: live?.ndefBytes
        )
    }

    /// Format a `YYMMDD` MRZ date for display (see `PassportMRZDate`).
    private func formattedMRZDate(_ yymmdd: String, isExpiry: Bool) -> String {
        PassportMRZDate.display(yymmdd, isExpiry: isExpiry)
    }
}
#endif
