import SwiftUI

/// The in-app legal documents, surfaced from Settings > Legal.
///
/// The body text is deliberately English-only and rendered with
/// `Text(verbatim:)`: legal wording is binding in the language it was drafted
/// in and is versioned by effective date, so it is exempt from the
/// `Localizable.xcstrings` rule. The chrome around it (row labels, titles,
/// buttons) localizes as normal.
///
/// Each document exists in three places: these literals, the markdown mirror
/// at the repo root (`TERMS.md`, `PRIVACY.md`), and the published copy on
/// hex-web at `apps.hex.pro/hex-nfc/terms` and `/privacy`. App Store Connect's
/// Privacy Policy URL field is mandatory and an in-app copy cannot satisfy it,
/// so the third copy is not optional. Changing a document means changing all
/// three and bumping the effective date; see CLAUDE.md, "Legal documents".
///
/// The markdown is authored in the small subset hex-web's renderer accepts:
/// a title, a two-line masthead, numbered `##` sections, paragraphs, `- `
/// lists and bold. No blockquotes, no code spans, no tables. Anything richer
/// renders as literal punctuation on the web.
enum LegalDocument: String, CaseIterable, Identifiable {
    case terms
    case privacy

    var id: String {
        rawValue
    }

    var title: LocalizedStringKey {
        switch self {
        case .terms: "Terms & Conditions"
        case .privacy: "Privacy Policy"
        }
    }

    /// Shown under the title, and part of the document's version identity.
    var effectiveDate: String {
        "7 July 2026"
    }

    var publisherLine: String {
        "Ars Vitae Pty Ltd, trading as Hex Pro (Australia)"
    }

    var sections: [LegalSection] {
        switch self {
        case .terms: Self.termsSections
        case .privacy: Self.privacySections
        }
    }
}

struct LegalSection {
    let heading: String
    /// Paragraphs render in order. A paragraph starting with a bullet
    /// ("\u{2022} ") is indented as a list item.
    let paragraphs: [String]
}

// MARK: - Terms & Conditions

extension LegalDocument {
    private static let termsSections: [LegalSection] = [
        LegalSection(heading: "1. Who we are", paragraphs: [
            "Hex NFC: Reader & Writer (\u{201C}Hex NFC\u{201D}, \u{201C}the app\u{201D}) is published by Ars Vitae Pty Ltd, an Australian company trading as Hex Pro (\u{201C}we\u{201D}, \u{201C}us\u{201D}, \u{201C}our\u{201D}). These terms are an agreement between you and Ars Vitae Pty Ltd about your use of the app.",
        ]),
        LegalSection(heading: "2. Agreeing to these terms", paragraphs: [
            "By installing or using Hex NFC you agree to these terms. If you do not agree, do not use the app.",
        ]),
        LegalSection(heading: "3. The app is free", paragraphs: [
            "Hex NFC costs nothing. There are no accounts, subscriptions, in-app purchases, or paid features.",
            "The home screen shows a progress figure for the project's development costs and links to a page on our website where you can contribute if you want to. Contributions are voluntary gifts processed on our website by a third-party payment provider. They unlock nothing in the app, and they are not refundable except where the law requires.",
        ]),
        LegalSection(heading: "4. Your licence to use the app", paragraphs: [
            "We grant you a personal, non-exclusive, non-transferable licence to install and use the app on Apple devices you own or control, as permitted by the App Store terms. Apple's standard Licensed Application End User License Agreement also applies to the copy you download from the App Store.",
        ]),
        LegalSection(heading: "5. Source code and trademarks", paragraphs: [
            "The app's source code is separately available under the Business Source License 1.1, which automatically converts to the Apache License 2.0 on 1 June 2030. That licence covers the code only; it does not change these terms for the app you installed.",
            "The Hex Pro name, the app icon, and the hexagon-split logo are trademarks of Ars Vitae Pty Ltd. Neither these terms nor the code licence grants you any right to use them.",
        ]),
        LegalSection(heading: "6. NFC tags are physical hardware", paragraphs: [
            "Writing to a tag changes a physical chip, and some changes cannot be undone:",
            "\u{2022} Permanently locking a tag is irreversible. Certain formatting and configuration changes are also one-way on some chips.",
            "\u{2022} Password-protecting a tag makes it unreadable or unwritable without the password. Keep track of passwords you set: if the stored copy is lost, the tag may become permanently inaccessible.",
            "\u{2022} Chip behaviour varies between manufacturers and production batches. The app takes extensive precautions, but a write can still fail or leave a tag unusable.",
            "Only scan or write tags you own or have the owner's permission to modify. You are responsible for what you write to a tag and for where you leave it. To the extent the law allows, we are not responsible for tags that end up locked, damaged, or unusable, or for data lost from a tag.",
        ]),
        LegalSection(heading: "7. Passports and identity documents", paragraphs: [
            "The passport feature reads the chip in electronic travel documents and displays what it finds for the current session only.",
            "Read only documents that belong to you, or documents you have the holder's clear permission to read, and always comply with the law where you are.",
            "The integrity indicator checks that the chip's data files are internally consistent. It does not verify the document against government certificates, and it is not proof that a document is genuine or fake. Hex NFC is an informational tool, not an official identity-verification instrument, and must not be used as one.",
        ]),
        LegalSection(heading: "8. Transit cards", paragraphs: [
            "Transit card reading is informational and read-only. Balances, trips, and station names are decoded from the card and may be incomplete, outdated, or wrong. We are not affiliated with, or endorsed by, any transit operator or card issuer.",
        ]),
        LegalSection(heading: "9. Acceptable use", paragraphs: [
            "Do not use the app to break the law, to read or modify tags, cards, or documents you are not authorised to access, to infringe anyone's rights, or to disrupt or abuse the small online services the app talks to.",
            "We may change, suspend, or retire those online services at any time. The core of the app works fully offline.",
        ]),
        LegalSection(heading: "10. Station-name suggestions", paragraphs: [
            "If you submit a station name, you grant us a perpetual, worldwide, royalty-free licence to use, edit, publish, and redistribute the suggestion, including bundling it into future versions of the app and its data files. Submit only information you are entitled to share, and do not include personal information in the name field.",
        ]),
        LegalSection(heading: "11. Third-party services", paragraphs: [
            "Optional iCloud sync is provided by Apple under Apple's own terms and privacy policy. Banners and links in the app may open external websites, which have their own terms.",
        ]),
        LegalSection(heading: "12. No warranty", paragraphs: [
            "The app is provided \u{201C}as is\u{201D} and \u{201C}as available\u{201D}, without warranties of any kind beyond those the law requires.",
            "Nothing in these terms excludes, restricts, or modifies any consumer guarantee or other right you have under the Australian Consumer Law, or any similar right under the law where you live, that cannot be excluded by agreement.",
        ]),
        LegalSection(heading: "13. Limitation of liability", paragraphs: [
            "To the extent the law allows: we are not liable for indirect or consequential loss, loss of data, or loss arising from modified, locked, or unusable tags; and our total liability to you in connection with the app is limited to AU$50.",
            "Where our liability under a non-excludable consumer guarantee can lawfully be limited, it is limited to re-supplying the app or paying the cost of re-supply. Nothing in these terms limits liability that cannot lawfully be limited.",
        ]),
        LegalSection(heading: "14. Changes", paragraphs: [
            "We may update the app and these terms. When the terms change, the new version appears here with a new effective date. Using the app after a change means you accept the updated terms.",
        ]),
        LegalSection(heading: "15. Ending this agreement", paragraphs: [
            "You may stop using the app at any time by deleting it. Your licence ends automatically if you materially breach these terms. Sections that by their nature should survive termination (including 6, 10, 12, and 13) survive it.",
        ]),
        LegalSection(heading: "16. General", paragraphs: [
            "If part of these terms turns out to be unenforceable, the rest still applies. These terms, together with the documents they reference, are the entire agreement between you and us about the app. Not enforcing a provision is not a waiver of it.",
        ]),
        LegalSection(heading: "17. Governing law", paragraphs: [
            "These terms are governed by the laws of Queensland, Australia, and you and we submit to the non-exclusive jurisdiction of the courts of Queensland and the courts able to hear appeals from them.",
        ]),
        LegalSection(heading: "18. Contact", paragraphs: [
            "Questions about these terms: support@hex.pro",
        ]),
    ]
}

// MARK: - Privacy Policy

extension LegalDocument {
    private static let privacySections: [LegalSection] = [
        LegalSection(heading: "1. The short version", paragraphs: [
            "Hex NFC has no accounts, no analytics, no advertising trackers, and nothing to sell. What you scan stays on your device. The app makes exactly three kinds of internet request, none of which carries personal information, and all of which are described below.",
        ]),
        LegalSection(heading: "2. What stays on your device", paragraphs: [
            "\u{2022} Scan history and saved presets live in a local database on your device.",
            "\u{2022} App settings (haptics, motion, compatibility mode, sync) are stored locally.",
            "\u{2022} Tag passwords you set or use are stored only in the iOS Keychain on this device. They are never synced, never included in exported files, and never sent anywhere.",
            "Deleting an item in the app removes it from the local database. Deleting the app removes the app's local data from your device.",
        ]),
        LegalSection(heading: "3. Electronic passports", paragraphs: [
            "When you read a passport or identity document, the chip's contents (including name, date of birth, and photo) are shown on screen for that session only. Nothing from a passport is ever saved, synced, exported, or transmitted. The keys needed to talk to the chip are derived on your device from the document's machine-readable zone and are discarded when the session ends.",
        ]),
        LegalSection(heading: "4. Transit cards", paragraphs: [
            "Transit cards are read-only. The balance and trip information shown comes straight from the card. Like other scans, a transit read is kept in your local scan history so you can reopen it later; it stays on your device unless you turn on iCloud sync.",
        ]),
        LegalSection(heading: "5. iCloud sync (optional, off by default)", paragraphs: [
            "If you turn on iCloud sync, your presets and scan history are mirrored into your private iCloud database, which is operated by Apple and protected by your Apple ID. We cannot read it. Turning sync off stops the mirroring, and deleting items removes them from sync. Tag passwords are never synced.",
        ]),
        LegalSection(heading: "6. When the app talks to the internet", paragraphs: [
            "There are exactly three cases. None of them runs in the background, and none carries anything that identifies you.",
            "\u{2022} Development-costs figure. The home screen fetches one public number (contributions received versus project cost) from our API at api.apps.hex.pro. The request contains no personal data.",
            "\u{2022} Station-name suggestions. Sent only when you tap Submit. The payload is the numeric line, station, and area codes, the card system code, and the station name you typed. Your card's serial number, balance, and travel history are never sent. Suggestions are reviewed by the maintainer and treated as anonymous; please do not put personal information in the name field.",
            "\u{2022} Hex Pro app banner. The home screen may show a banner for another Hex Pro app. Fetching it sends this app's bundle identifier, the platform (\u{201C}ios\u{201D}), and a slot name to our API at api.p.hex.pro, and returns an image or video that is cached on your device. There are no third-party ad networks, no tracking identifiers, and no personalisation: everyone sees the same banner.",
            "Like every internet request, these necessarily expose your IP address to our servers. We keep only standard, short-lived operational logs and do not use IP addresses to identify or profile anyone.",
        ]),
        LegalSection(heading: "7. Device permissions", paragraphs: [
            "Every permission is optional, and everything captured is processed on your device:",
            "\u{2022} NFC: used only while a scan or write sheet is open.",
            "\u{2022} Camera: only for scanning QR codes you choose to import. Frames are never saved or uploaded.",
            "\u{2022} Contacts: only when you pick a contact to build a record. The picked details go onto your tag, not to us.",
            "\u{2022} Location: only when you tap \u{201C}use current location\u{201D} while building a map record.",
            "\u{2022} Bluetooth: only when you choose a device while building a Bluetooth handover record.",
        ]),
        LegalSection(heading: "8. What we never do", paragraphs: [
            "No analytics or telemetry SDKs. No third-party advertising. No fingerprinting. No selling, renting, or sharing of personal information. No accounts, and no profile of you anywhere on our servers.",
        ]),
        LegalSection(heading: "9. Data you write to tags", paragraphs: [
            "Anything you write to an NFC tag lives on hardware outside your device, and anyone with a reader can read an unprotected tag. Treat tag contents as public unless you protect the tag.",
        ]),
        LegalSection(heading: "10. Exported files", paragraphs: [
            "Files you export or share contain the records and presets you selected. They never include tag passwords.",
        ]),
        LegalSection(heading: "11. Children", paragraphs: [
            "The app is not directed at children, and we knowingly collect no personal information from anyone, children included.",
        ]),
        LegalSection(heading: "12. Your rights", paragraphs: [
            "Because almost nothing about you ever reaches us, most privacy requests can be satisfied on your own device by deleting items or the app. For anything involving our servers (for example, a station suggestion you regret submitting), contact us and we will help. You can also complain to the Office of the Australian Information Commissioner or your local data-protection authority.",
        ]),
        LegalSection(heading: "13. Changes to this policy", paragraphs: [
            "When this policy changes, the new version appears here with a new effective date.",
        ]),
        LegalSection(heading: "14. Contact", paragraphs: [
            "Privacy questions: support@hex.pro",
        ]),
    ]
}
