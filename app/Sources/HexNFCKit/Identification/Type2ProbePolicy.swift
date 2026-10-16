import Foundation

/// What the identification probe learned, split into what the **chip** said and
/// what the **radio** did.
///
/// These are not the same thing, and conflating them cost a real removal.
/// `MiFareTagIdentifier` used to decide with `(version?.count ?? 0) < 8`, which
/// is true both when a chip answers a one-byte NAK and when the send never
/// completes at all. On 2026-09-21 an NTAG213's `60` failed at the transport
/// ("Tag connection lost") in the middle of an Operations removal. That was
/// filed as a refusal, so the session re-polled into the second pass, which
/// deliberately never re-sends `GET_VERSION` and decodes from memory shape
/// instead. The only decoder on that pass recognises MIFARE Ultralight C, so
/// the NTAG213 came back with no chip profile at all and every Type-2
/// protection command refused it with "This tag does not support that
/// operation.", after the owner had typed fourteen characters of its UID.
///
/// The chip had refused nothing. It answered `60` cleanly sixteen seconds
/// earlier and again two minutes later. A transport failure is evidence about
/// the radio and about nothing else, and the right answer to it is to ask
/// again once the tag is back.
public enum Type2ProbeVerdict: String, Sendable, Equatable {
    /// The chip answered the probe. Whether the answer decoded to a known model
    /// is a separate question, and not this one.
    case answered
    /// The chip answered, and its answer was a refusal: a NAK, or a frame too
    /// short to be a version block. Per ISO 14443-3 that returns a Type-2 tag
    /// to HALT, so it answers nothing more on this activation.
    case chipRefused
    /// The send never completed, so the chip said nothing at all. The tag is
    /// not halted; the handle is dead.
    case transportLost
}

/// What one probe frame did, as opposed to what it said.
///
/// The branch is on whether the send resumed with bytes or with an error, never
/// on an `NFCReaderError` code and never on its localised text. CLAUDE.md
/// forbids branching on an error code no real tag has been seen emitting, and
/// this stays clear of that rule by not reading the error at all.
public enum Type2ProbeOutcome: Sendable, Equatable {
    case answered(Data)
    case transportFailed
}

/// What the session should do next with a tag whose identification probe did
/// not land.
public enum Type2ProbeNextStep: Sendable, Equatable {
    /// Hand the tag to the caller with whatever was decoded.
    case handUp
    /// Restart polling, then run identification again from the top. Only ever
    /// chosen after a transport failure, where nothing is known about the chip.
    case repollAndRetryGetVersion
    /// Restart polling, then identify from memory shape without re-sending
    /// `GET_VERSION`. Only ever chosen after the chip itself refused it.
    case repollAndDecodeShape
}

/// The rule for how many times one tap may go back to a tag that did not
/// identify.
///
/// Pure, and deliberately in its own file with no CoreNFC import, because
/// `CoreNFCSession` and `MiFareTagIdentifier` are both `#if os(iOS)` and
/// `swift test` on macOS skips them entirely. The decision this type makes is
/// the load-bearing half, so it is the half that has to be testable in CI.
public enum Type2ProbePolicy {
    /// How many passes of each kind this tap has already spent.
    public struct Attempts: Sendable, Equatable {
        /// Full identification passes, each of which sends `GET_VERSION`.
        public var getVersion: Int
        /// Memory-shape passes, which send reads only.
        public var shape: Int

        public init(getVersion: Int = 0, shape: Int = 0) {
            self.getVersion = getVersion
            self.shape = shape
        }
    }

    /// Two invariants, and the ceiling falls out of them.
    ///
    /// A chip that refused `GET_VERSION` is never asked again. The refusal is
    /// the chip telling us it does not implement the command, and asking twice
    /// only halts it twice (live-confirmed 2026-08-06 on an unidentified
    /// Ultralight-family chip: `RX GET_VERSION 00`, then every later command
    /// failed, including a READ of page 0, which no Type-2 chip can refuse).
    ///
    /// A transport failure earns exactly one more ask, because it is the one
    /// case where nothing has been learned about the chip and the next attempt
    /// starts from a freshly selected tag.
    ///
    /// So the deepest sequence a single tap can reach is three activations:
    /// ask, lose the transport, ask again, get refused, decode the shape.
    public static func nextStep(
        after verdict: Type2ProbeVerdict,
        attempts: Attempts
    ) -> Type2ProbeNextStep {
        switch verdict {
        case .answered:
            .handUp

        case .chipRefused:
            attempts.shape == 0 ? .repollAndDecodeShape : .handUp

        case .transportLost:
            attempts.getVersion <= 1 ? .repollAndRetryGetVersion : .handUp
        }
    }
}
