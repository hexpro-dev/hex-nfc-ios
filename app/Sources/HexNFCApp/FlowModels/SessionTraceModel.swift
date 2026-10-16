import Foundation
import HexNFCDesign
import HexNFCKit
import Observation

/// Mirrors the process-wide `NFCTrace` into `[HexConsoleEntry]` for the Advanced
/// Console's live-trace tab. Unlike `AdvancedConsoleModel` — which logs only the
/// REPL's own command run — this surfaces *every* frame the app exchanges with a
/// tag, across all flows (scan, write, operations, identification).
///
/// Frames are recorded on the NFC session's background queue; this model
/// subscribes on the `MainActor`, so the view updates safely.
@MainActor
@Observable
public final class SessionTraceModel {
    public private(set) var entries: [HexConsoleEntry] = []

    private let trace: NFCTrace
    private let capacity: Int
    /// Assigned once in `init` (on the MainActor), cancelled once in the
    /// nonisolated `deinit`, which may read it with no `unsafe` opt-out because
    /// nothing else holds a strong reference by then. Ignored by observation
    /// because no view reads it, and so that it stays a stored property rather
    /// than the computed one `@Observable` would make of it.
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(trace: NFCTrace = .shared, capacity: Int = 500) {
        self.trace = trace
        self.capacity = capacity
        entries = trace.snapshot().map(Self.entry(from:))

        let trace = self.trace
        task = Task { [weak self] in
            for await event in trace.events() {
                guard let self else { break }
                append(event)
            }
        }
    }

    deinit { task?.cancel() }

    /// The whole scrollback as plain text — backs the console's "copy all".
    public var logPlainText: String {
        entries.map(\.plainTextLine).joined(separator: "\n")
    }

    public func clear() {
        entries.removeAll()
        trace.clear()
    }

    private func append(_ event: NFCTrace.Event) {
        entries.append(Self.entry(from: event))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    private static func entry(from event: NFCTrace.Event) -> HexConsoleEntry {
        HexConsoleEntry(
            id: event.id,
            kind: kind(for: event.direction),
            timestamp: event.timestamp,
            label: event.label ?? event.byteCount.map { "\($0) bytes" },
            body: event.body
        )
    }

    private static func kind(for direction: NFCTrace.Event.Direction) -> HexConsoleEntry.Kind {
        switch direction {
        case .tx: .tx
        case .rx: .rx
        case .note: .note
        case .error: .error
        }
    }
}
