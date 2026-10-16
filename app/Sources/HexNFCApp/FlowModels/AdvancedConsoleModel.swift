import Foundation
import HexNFCDesign
import HexNFCKit
import Observation

/// State + behaviour for the Advanced Console — the always-visible REPL on
/// Home. Holds the preset library (filtered + sorted by relevance), the
/// command input buffer, and the running scrollback log. `run()` opens a
/// fresh NFC session, transceives the parsed `RawCommandSequence`, and
/// appends TX/RX rows to the log.
@Observable
@MainActor
public final class AdvancedConsoleModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case polling
        case connected(uidHex: String, chip: String)
        case running
        case finished
        /// A run reached the session's time limit with nothing in the field, on
        /// a console that has never had a tag. Nothing was sent, so it is a
        /// status rather than an error, and `run()` may start again from it. A
        /// run the user cancelled the same way goes back to `.idle`.
        case noTagFound
        case error(message: String, diagnostics: String)
    }

    public var input: String = ""
    public var searchText: String = ""
    public var selectedFamilyFilter: TagFamily?

    public private(set) var entries: [HexConsoleEntry] = []
    public private(set) var phase: Phase = .idle
    public let presets: [CommandPreset]

    /// The chip identified via the "Identify" affordance, if any. When set, the
    /// preset list sinks off-family presets to the bottom and greys them, and the
    /// header shows the identified chip. `nil` = no identify scan yet (all presets
    /// render normally, in catalog order).
    public private(set) var identifiedChip: ChipProfile?

    /// `true` while an identify scan is polling — drives the Identify button's
    /// spinner and blocks a concurrent command run.
    public private(set) var isIdentifying: Bool = false

    /// The full scrollback rendered as plain text, one line per entry — backs
    /// the console's "copy all" affordance.
    public var logPlainText: String {
        entries.map(\.plainTextLine).joined(separator: "\n")
    }

    private let factory: TagSessionFactory
    private var currentSession: TagSession?
    /// Whether any session this console has opened, for Identify or for a run,
    /// has had a tag. Kept for the life of the console, like the log it
    /// governs: once a tag has been in play, a cancel is logged as the error it
    /// always was. See `TagContact`.
    private var contact = TagContact()

    /// Send commands without identifying the chip first.
    ///
    /// Identification costs a `GET_VERSION`, and a chip that doesn't implement
    /// it NAKs — which HALTs a Type-2 tag and makes every command in the
    /// session fail with "tag connection lost", including a plain READ of page
    /// 0. Turning this on is the only way to reach such a chip, at the cost of
    /// `chip` being `nil` (generic command set, no page map assumed).
    public var skipIdentification = false {
        didSet {
            // Only the CoreNFC factory has a probe to skip; simulators never
            // had one. The type exists only where CoreNFC does.
            #if canImport(CoreNFC) && os(iOS)
            (factory as? CoreNFCSessionFactory)?.skipIdentification = skipIdentification
            #endif
        }
    }

    public init(
        factory: TagSessionFactory,
        presets: [CommandPreset] = CommandPresetCatalog.builtIn
    ) {
        self.factory = factory
        self.presets = presets
    }

    /// Apply the search-text and family filter to the preset list. Once a tag
    /// has been identified, presets are re-ordered so compatible ones (exact
    /// chip first) lead and off-family ones sink to the bottom; the relative
    /// order within each tier is the catalog order.
    public var filteredPresets: [CommandPreset] {
        let lowered = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let matched = presets.filter { preset in
            if let family = selectedFamilyFilter, preset.family != family {
                return false
            }
            if lowered.isEmpty {
                return true
            }
            return preset.name.lowercased().contains(lowered)
                || preset.sequenceText.lowercased().contains(lowered)
                || (preset.notes ?? "").lowercased().contains(lowered)
        }
        guard let chip = identifiedChip else { return matched }
        // Stable sort: higher match rank first, ties broken by catalog index so
        // presets keep their curated order within each tier.
        return matched.enumerated()
            .map { (offset: $0.offset, preset: $0.element,
                    rank: $0.element.matches(identifiedChip: chip.family).sortRank) }
            .sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.offset < $1.offset }
            .map(\.preset)
    }

    /// Match quality of `preset` against the identified chip — `.unscored` when
    /// no tag has been identified (the console then greys nothing). The view uses
    /// `.isCompatible` to decide whether to grey the row.
    public func compatibility(of preset: CommandPreset) -> PresetMatch {
        guard let chip = identifiedChip else { return .unscored }
        return preset.matches(identifiedChip: chip.family)
    }

    /// Preset → input buffer. Doesn't run; user can review/edit then tap Run.
    public func loadPreset(_ preset: CommandPreset) {
        input = preset.sequenceText
        appendNote("Loaded preset: \(preset.name)")
    }

    /// Scan a tag purely to identify it, then prioritise chip-appropriate
    /// presets. Independent of `run()` — it never touches the command `phase` or
    /// the input buffer, only `identifiedChip`. Guarded against overlapping with
    /// a command run (`currentSession != nil`) or a second identify scan.
    public func identify() async {
        guard !isIdentifying, currentSession == nil else { return }
        isIdentifying = true
        defer { isIdentifying = false }

        let session = factory.makeSession()
        currentSession = session
        appendNote("Identifying tag…")
        do {
            let tag = try await session.start(alert: "Hold tag to identify.")
            contact.tagArrived()
            let chip = tag.chip
            let uidHex = tag.uid.hexString
            await session.invalidate(error: nil)
            currentSession = nil
            if let chip {
                identifiedChip = chip
                appendNote("Identified: \(chip.displayName) · \(uidHex)")
            } else {
                identifiedChip = nil
                // Say what the chip said about itself. The scan card already
                // shows this ("Reported" / "Version bytes"); the console — the
                // screen someone opens *because* a tag is behaving oddly — was
                // the one place that threw it away and printed only "unknown".
                if let report = tag.unidentifiedReport {
                    appendNote("Tag connected but the chip is unknown · \(uidHex)")
                    if let summary = report.summary {
                        appendNote("Reported: \(summary)")
                    }
                    appendNote("GET_VERSION: \(report.versionHex)")
                } else {
                    appendNote("Tag connected but the chip is unknown · \(uidHex)")
                }
            }
        } catch let error as TagError {
            // Nothing in the field and nothing ever was: a note, not an ERROR
            // line. Identify never moves the command phase, so neither does this.
            if let ending = contact.quietEnding(for: error) {
                await session.invalidate(error: nil)
                currentSession = nil
                appendNote(Self.note(for: ending))
                return
            }
            await session.invalidate(error: String(localized: error.userMessage))
            currentSession = nil
            appendErrorEntry(
                String(localized: error.userMessage),
                diagnostics: error.diagnostics
            )
        } catch {
            _ = contact.quietEnding(for: error)
            await session.invalidate(error: nil)
            currentSession = nil
            appendErrorEntry(
                "Couldn't identify the tag.",
                diagnostics: "\(error)"
            )
        }
    }

    /// Forget the identified chip — the preset list returns to catalog order with
    /// nothing greyed.
    public func clearIdentification() {
        identifiedChip = nil
    }

    /// Parse the input as a `RawCommandSequence`, open a session, transceive,
    /// and surface each TX/RX pair in the log. Idempotent against re-entrant
    /// calls — guards on the phase.
    public func run() async {
        guard !isIdentifying else { return }
        guard phase == .idle || phase == .finished || phase == .noTagFound || isErrorPhase else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appendError("Empty input.", diagnostics: "no commands to send")
            return
        }
        let sequence: RawCommandSequence
        do {
            sequence = try RawCommandSequence.parse(trimmed)
        } catch {
            appendError(
                "Could not parse command.",
                diagnostics: "parse error: \(error)"
            )
            return
        }

        let session = factory.makeSession()
        currentSession = session
        phase = .polling
        appendNote("Polling for tag…")

        do {
            let tag = try await session.start(alert: "Hold tag for command.")
            contact.tagArrived()
            phase = .connected(
                uidHex: tag.uid.hexString,
                chip: tag.chip?.id.description ?? "unknown"
            )
            appendNote("Connected: \(tag.uid.hexString) · \(tag.chip?.id.description ?? "unknown")")

            phase = .running
            let bound = try sequence.bind(to: .init(uid: tag.uid))
            for command in bound {
                appendTX(command)
                let response: Data
                do {
                    response = try await tag.transceive(command)
                } catch let error as TagError {
                    appendError(
                        String(localized: error.userMessage),
                        diagnostics: error.diagnostics
                    )
                    await session.invalidate(error: String(localized: error.userMessage))
                    currentSession = nil
                    return
                }
                appendRX(response, for: command)
            }
            await session.invalidate(error: nil)
            currentSession = nil
            phase = .finished
            appendNote("Done.")
        } catch let error as TagError {
            // The run never reached a tag, so not one command frame went out.
            // Say that, in a neutral line, and leave the status where a run
            // that never started would: idle after a cancel, "no tag found"
            // after a timeout.
            if let ending = contact.quietEnding(for: error) {
                await session.invalidate(error: nil)
                currentSession = nil
                phase = ending == .cancelled ? .idle : .noTagFound
                appendNote(Self.note(for: ending))
                return
            }
            await session.invalidate(error: String(localized: error.userMessage))
            currentSession = nil
            appendError(
                String(localized: error.userMessage),
                diagnostics: error.diagnostics
            )
        } catch {
            _ = contact.quietEnding(for: error)
            await session.invalidate(error: nil)
            currentSession = nil
            appendError(
                "Something unexpected went wrong.",
                diagnostics: "\(error)"
            )
        }
    }

    public func clear() {
        entries.removeAll()
        phase = .idle
    }

    // MARK: - Private

    private var isErrorPhase: Bool {
        if case .error = phase {
            return true
        }
        return false
    }

    private func appendTX(_ command: RawCommand) {
        entries.append(HexConsoleEntry(
            kind: .tx,
            label: command.name,
            body: command.bytes.hexString
        ))
    }

    private func appendRX(_ data: Data, for command: RawCommand) {
        entries.append(HexConsoleEntry(
            kind: .rx,
            label: "\(data.count) bytes",
            body: data.isEmpty ? "(empty)" : data.hexString
        ))
    }

    /// The log line for a session that ended with no tag. Localised, unlike
    /// the console's older progress notes, because it is the whole of what the
    /// user is told about a run that never started.
    static func note(for ending: NoTagEnd) -> String {
        switch ending {
        case .cancelled:
            String(localized: "Cancelled before a tag was found. Nothing was sent.")

        case .timedOut:
            String(
                localized: "No tag found, so nothing was sent. Hold the tag flat against the top of your iPhone and try again."
            )
        }
    }

    private func appendNote(_ text: String) {
        entries.append(HexConsoleEntry(kind: .note, body: text))
    }

    private func appendError(_ message: String, diagnostics: String) {
        appendErrorEntry(message, diagnostics: diagnostics)
        phase = .error(message: message, diagnostics: diagnostics)
    }

    /// Append an error row to the log *without* moving the command `phase`. Used
    /// by `identify()`, which runs its own scan outside the run state machine.
    private func appendErrorEntry(_ message: String, diagnostics: String) {
        entries.append(HexConsoleEntry(
            kind: .error,
            label: "ERROR",
            body: "\(message): \(diagnostics)"
        ))
    }
}
