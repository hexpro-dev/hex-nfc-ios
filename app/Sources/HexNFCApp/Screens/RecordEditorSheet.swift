#if os(iOS)
import HexNFCDesign
import HexNFCRecords
import SwiftUI

/// Polymorphic editor host. Routes on the record case to a type-specific
/// form. The five types with no form (App link, Bluetooth, Data, Shortcut,
/// Raw) open as JSON instead; the Add record sheet does not offer them, so a
/// record of one of those types gets here only from a scanned tag, a preset or
/// a history row.
struct RecordEditorSheet: View {
    let initial: NDEFRecord
    let onCommit: (NDEFRecord?) -> Void
    /// Called when the user taps "Delete record". `nil` hides the affordance
    /// (e.g. previews / callers without a list behind them); the editor host
    /// removes the record from its working copy and dismisses this sheet.
    let onDelete: (() -> Void)?

    @State private var working: NDEFRecord

    init(
        initial: NDEFRecord,
        onCommit: @escaping (NDEFRecord?) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.initial = initial
        self.onCommit = onCommit
        self.onDelete = onDelete
        _working = State(initialValue: MapSourceChoice.editable(initial))
    }

    var body: some View {
        NavigationStack {
            Form {
                editor
                deleteSection
            }
            .scrollContentBackground(.hidden)
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle(Text(LocalizedStringKey(RecordLocalization.title(for: initial))))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCommit(nil) }
                        .foregroundStyle(HexTokens.Color.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onCommit(working) }
                        .foregroundStyle(HexTokens.Color.primaryLight)
                        .accessibilityIdentifier("record.save")
                }
            }
            .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
    }

    /// Destructive footer that drops this record from the editor's list. Only
    /// shown when the host wired `onDelete`. The tag isn't rewritten until the
    /// user hits Write, so this needs no confirmation — it's an undoable edit.
    @ViewBuilder
    private var deleteSection: some View {
        if let onDelete {
            Section {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete record", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("record.delete")
            }
            .listRowBackground(HexTokens.Color.surface1)
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch working {
        case .text(let r): TextEditorBody(record: bind(r) { .text($0) })
        case .uri(let r): URIEditorBody(record: bind(r) { .uri($0) })
        case .phone(let r): PhoneEditorBody(record: bind(r) { .phone($0) })
        case .sms(let r): SMSEditorBody(record: bind(r) { .sms($0) })
        case .mail(let r): MailEditorBody(record: bind(r) { .mail($0) })
        case .wifiWPS(let r): WiFiEditorBody(record: bind(r) { .wifiWPS($0) })
        case .contact(let r): VCardEditorBody(record: bind(r) { .contact($0) })
        case .social(let r): SocialEditorBody(record: bind(r) { .social($0) })
        case .search(let r): SearchEditorBody(record: bind(r) { .search($0) })
        case .crypto(let r): CryptoEditorBody(record: bind(r) { .crypto($0) })
        case .map(let r): MapEditorBody(record: bind(r) { .map($0) })
        case .file(let r): FileEditorBody(record: bind(r) { .file($0) })
        case .facetime(let r): FaceTimeEditorBody(record: bind(r) { .facetime($0) })

        default:
            GenericJSONEditorBody(record: $working)
        }
    }

    private func bind<R: Hashable>(_ value: R, wrap: @escaping (R) -> NDEFRecord) -> Binding<R> {
        Binding(
            get: { value },
            set: { working = wrap($0) }
        )
    }
}

// MARK: - Text

private struct TextEditorBody: View {
    @Binding var record: TextRecord
    var body: some View {
        Section {
            HexField("Text", text: $record.text, axis: .vertical)
            HexField("Language code", text: $record.languageCode, prompt: "en",
                     footer: "ISO 639-1, e.g. en, fr, ja")
        }
        Section {
            Picker("Encoding", selection: $record.encoding) {
                Text("UTF-8").tag(TextRecord.Encoding.utf8)
                Text("UTF-16").tag(TextRecord.Encoding.utf16)
            }
        }
    }
}

// MARK: - URI

private struct URIEditorBody: View {
    @Binding var record: URIRecord
    var body: some View {
        Section {
            HexField("URL", text: $record.uri,
                     prompt: "https://hex.pro",
                     footer: "Tip: most NFC apps auto-shorten well-known schemes. We do too.",
                     keyboard: .url)
        }
    }
}

// MARK: - Phone / SMS / FaceTime

private struct PhoneEditorBody: View {
    @Binding var record: PhoneRecord
    var body: some View {
        Section {
            HexField("Phone number", text: $record.number, prompt: "+15551234", keyboard: .phonePad)
        }
    }
}

private struct SMSEditorBody: View {
    @Binding var record: SMSRecord
    var body: some View {
        Section {
            HexField("Recipient", text: $record.number, prompt: "+15551234", keyboard: .phonePad)
            HexField("Message", text: $record.body, axis: .vertical)
        }
    }
}

private struct FaceTimeEditorBody: View {
    @Binding var record: FaceTimeRecord
    var body: some View {
        Section {
            HexField("Target", text: $record.target,
                     prompt: "user@icloud.com or +15551234",
                     keyboard: .emailAddress)
            Picker("Mode", selection: $record.mode) {
                Text("Video").tag(FaceTimeRecord.Mode.video)
                Text("Audio").tag(FaceTimeRecord.Mode.audio)
            }
        }
    }
}

// MARK: - Mail

private struct MailEditorBody: View {
    @Binding var record: MailRecord
    @State private var toText: String = ""
    @State private var ccText: String = ""
    @State private var bccText: String = ""

    var body: some View {
        Section {
            HexField("To", text: $toText,
                     prompt: "comma-separated", keyboard: .emailAddress)
                .onChange(of: toText) { _, newValue in record.to = split(newValue) }
                .onAppear { toText = record.to.joined(separator: ", ") }
            HexField("Cc", text: $ccText, keyboard: .emailAddress)
                .onChange(of: ccText) { _, newValue in record.cc = split(newValue) }
                .onAppear { ccText = record.cc.joined(separator: ", ") }
            HexField("Bcc", text: $bccText, keyboard: .emailAddress)
                .onChange(of: bccText) { _, newValue in record.bcc = split(newValue) }
                .onAppear { bccText = record.bcc.joined(separator: ", ") }
        }
        Section {
            HexField("Subject", text: $record.subject)
            HexField("Body", text: $record.body, axis: .vertical)
        }
    }

    private func split(_ string: String) -> [String] {
        string
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Wi-Fi

private struct WiFiEditorBody: View {
    @Binding var record: WiFiWPSRecord
    var body: some View {
        Section {
            HexField("Network name (SSID)", text: $record.ssid)
            HexField("Password", text: $record.password)
            Picker("Authentication", selection: $record.authentication) {
                Text("WPA2 Personal").tag(WiFiWPSRecord.Authentication.wpa2Personal)
                Text("WPA3 Personal").tag(WiFiWPSRecord.Authentication.wpa3Personal)
                Text("WPA Personal").tag(WiFiWPSRecord.Authentication.wpaPersonal)
                Text("WEP").tag(WiFiWPSRecord.Authentication.wep)
                Text("Open").tag(WiFiWPSRecord.Authentication.open)
            }
            Picker("Encryption", selection: $record.encryption) {
                Text("AES").tag(WiFiWPSRecord.Encryption.aes)
                Text("TKIP").tag(WiFiWPSRecord.Encryption.tkip)
                Text("TKIP + AES").tag(WiFiWPSRecord.Encryption.tkipAes)
                Text("WEP").tag(WiFiWPSRecord.Encryption.wep)
                Text("None").tag(WiFiWPSRecord.Encryption.none)
            }
            Toggle("Hidden network", isOn: $record.isHidden)
        }
        Section {
            Text(
                "iPhone will not auto-connect from NFC, but Android readers will. Hex NFC writes the record to spec so any reader can pick it up."
            )
            .font(HexTokens.Font.footnote)
            .foregroundStyle(HexTokens.Color.textSecondary)
        }
    }
}

// MARK: - vCard

private struct VCardEditorBody: View {
    @Binding var record: VCardRecord
    @State private var phonesText = ""
    @State private var emailsText = ""
    @State private var websitesText = ""

    var body: some View {
        Section("Identity") {
            HexField("Full name", text: $record.formattedName)
            HexField("Organization", text: Binding(
                get: { record.organization ?? "" },
                set: { record.organization = $0.isEmpty ? nil : $0 }
            ))
        }
        Section("Reach") {
            HexField("Phones", text: $phonesText, prompt: "comma-separated", keyboard: .phonePad)
                .onChange(of: phonesText) { _, newValue in record.phones = split(newValue) }
                .onAppear { phonesText = record.phones.joined(separator: ", ") }
            HexField("Emails", text: $emailsText, keyboard: .emailAddress)
                .onChange(of: emailsText) { _, newValue in record.emails = split(newValue) }
                .onAppear { emailsText = record.emails.joined(separator: ", ") }
            HexField("Websites", text: $websitesText, keyboard: .url)
                .onChange(of: websitesText) { _, newValue in record.websites = split(newValue) }
                .onAppear { websitesText = record.websites.joined(separator: ", ") }
        }
    }

    private func split(_ string: String) -> [String] {
        string
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Social

private struct SocialEditorBody: View {
    @Binding var record: SocialRecord
    var body: some View {
        Section {
            Picker("Platform", selection: $record.platform) {
                ForEach(SocialPlatform.allCases, id: \.self) { platform in
                    Text(platform.rawValue.capitalized).tag(platform)
                }
            }
            HexField("Handle", text: $record.handle, prompt: "without the @", keyboard: .asciiCapable)
        }
    }
}

// MARK: - Search

private struct SearchEditorBody: View {
    @Binding var record: SearchRecord
    var body: some View {
        Section {
            Picker("Engine", selection: $record.engine) {
                ForEach(SearchEngine.allCases, id: \.self) { engine in
                    Text(displayName(engine)).tag(engine)
                }
            }
            HexField("Query", text: $record.query)
        }
    }

    private func displayName(_ engine: SearchEngine) -> String {
        switch engine {
        case .google: "Google"
        case .googleImages: "Google Images"
        case .bing: "Bing"
        case .yandex: "Yandex"
        case .duckduckgo: "DuckDuckGo"
        case .youtube: "YouTube"
        case .wikipedia: "Wikipedia"
        }
    }
}

// MARK: - Crypto

private struct CryptoEditorBody: View {
    @Binding var record: CryptoURIRecord
    var body: some View {
        Section {
            Picker("Network", selection: $record.network) {
                ForEach(CryptoNetwork.allCases, id: \.self) { network in
                    Text(network.rawValue.capitalized).tag(network)
                }
            }
            HexField("Address", text: $record.address, keyboard: .asciiCapable)
        }
        Section {
            HexField("Amount", text: Binding(
                get: { record.amount ?? "" },
                set: { record.amount = $0.isEmpty ? nil : $0 }
            ))
            HexField("Message", text: Binding(
                get: { record.message ?? "" },
                set: { record.message = $0.isEmpty ? nil : $0 }
            ))
        }
    }
}

// MARK: - Map

private struct MapEditorBody: View {
    @Binding var record: MapRecord
    // What the user typed, kept as typed, the way the Mail and Contact forms
    // keep their lists. The fields used to read back through the parsed
    // `Double`, so a field still being typed in was handed "3.0" for "3", and
    // nothing at all for the lone "-" that starts a negative coordinate.
    @State private var latitudeText = ""
    @State private var longitudeText = ""

    private var urlBinding: Binding<String> {
        Binding(
            get: { record.rawURL ?? "" },
            set: { record.rawURL = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        Section {
            // `RecordEditorSheet` has already moved a record saved with the
            // withdrawn "Current location" source onto one of these, so the
            // selection always has a row.
            Picker("Source", selection: $record.source) {
                ForEach(MapSourceChoice.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice.source)
                }
            }
            if record.source == .coordinate {
                // The prompts show the decimal form a map app copies out.
                // `CoordinateEntry` reads a decimal comma as well.
                HexField("Latitude", text: $latitudeText, prompt: "-33.8688", keyboard: .asciiCapable)
                    .onChange(of: latitudeText) { _, newValue in
                        record.latitude = CoordinateEntry.value(from: newValue)
                    }
                    .onAppear { latitudeText = record.latitude.map { "\($0)" } ?? "" }
                HexField("Longitude", text: $longitudeText, prompt: "151.2093", keyboard: .asciiCapable)
                    .onChange(of: longitudeText) { _, newValue in
                        record.longitude = CoordinateEntry.value(from: newValue)
                    }
                    .onAppear { longitudeText = record.longitude.map { "\($0)" } ?? "" }
            } else {
                HexField("Map URL", text: urlBinding, keyboard: .url)
            }
        }
        // Without both coordinates or a URL the codec would put a real place
        // on the tag (`geo:0,0`), so the write flow refuses the record. This
        // says so before the user gets that far.
        if !record.hasLocation {
            Section {
                Text(
                    "Enter a latitude and a longitude, or a map URL. Until then, this record cannot be written to a tag."
                )
                .font(HexTokens.Font.footnote)
                .foregroundStyle(HexTokens.Color.textSecondary)
            }
        }
    }
}

// MARK: - File

private struct FileEditorBody: View {
    @Binding var record: FileRecord
    var body: some View {
        Section {
            HexField("Path", text: $record.path,
                     prompt: "/Documents/note.txt",
                     footer: "Stored as a file:// URL. iOS limits the directories this can target.")
        }
    }
}

// MARK: - Generic JSON fallback

private struct GenericJSONEditorBody: View {
    @Binding var record: NDEFRecord
    @State private var json: String = ""

    var body: some View {
        Section {
            Text(
                "This record type is edited as JSON. While the text is not a valid record, Save keeps the last valid version."
            )
            .font(HexTokens.Font.footnote)
            .foregroundStyle(HexTokens.Color.textSecondary)
            TextEditor(text: $json)
                .font(HexTokens.Font.mono)
                .frame(minHeight: 200)
                .foregroundStyle(HexTokens.Color.textPrimary)
                .scrollContentBackground(.hidden)
                .background(HexTokens.Color.surface2)
                .cornerRadius(HexTokens.Radius.s)
        }
        .onAppear {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            json = (try? encoder.encode(record))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        .onChange(of: json) { _, newValue in
            guard let data = newValue.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(NDEFRecord.self, from: data) else { return }
            record = decoded
        }
    }
}
#endif
