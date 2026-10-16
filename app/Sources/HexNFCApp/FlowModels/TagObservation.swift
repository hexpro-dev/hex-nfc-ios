import Foundation
import HexNFCKit
import HexNFCRecords

/// What one flow established about one specific tag, **by reading it**.
///
/// The channel an operation or a write uses to tell the editor what the tag it
/// just touched now holds, so a card that said "Off" before a permanent lock
/// does not keep saying it until the next tap.
///
/// Two rules give this type its shape:
///
/// 1. *Every field is optional, and every `nil` means "not established", never
///    "no".* An operation publishes a field only when a read-back produced it.
///    A summary, an acknowledgement or a spec is not a reading.
/// 2. *The UID travels with it.* Operations is a general tool. It is launched
///    from the editor, but every operation opens its own session against
///    whatever tag the user then presents, so a reading is only about the
///    editor's tag when the UIDs match. `EditFlowModel.apply` is where that is
///    checked; carrying the UID is what makes checking possible.
///
/// Raw `Data` rather than a formatted string, because `Data.hexString`'s own
/// doc comment says "lowercased" over a `%02X` format string. An identity check
/// should not rest on a comment that is wrong about its own code.
public struct TagObservation: Hashable, Sendable {
    public let uid: Data
    /// Protection as a read-back returned it. `nil` when none was taken.
    public let protection: TagProtection?
    /// `nil` when no lock evidence was established.
    public let lock: TagLockReading?
    /// `true` only when a Capability Container was read back as correct.
    ///
    /// A fact about page 3 alone. It does **not** say a reader can find a
    /// message on the tag: a real NTAG213 (2026-09-09) held a byte-perfect
    /// Capability Container above a data area iOS refused outright. See
    /// `TagFormatState`.
    public let formatted: Bool?
    /// `true` only when an NDEF message was read back off the tag, which proves
    /// the whole structure walks: Capability Container, data area and all. The
    /// erase read-back and a verified write are what establish it.
    public let ndefReadable: Bool?
    /// The records the data area now holds, as a read-back returned them. An
    /// empty array is a reading: it says the tag carries no records, which is
    /// what an erase establishes.
    ///
    /// `ndefReadable` is not a substitute and never was. It says the structure
    /// walks, not what is in it, so an erase could report a readable tag and
    /// leave the editor listing the records it had just cleared. Found on an
    /// NTAG213 on 2026-09-22, one operation after the same shape was fixed for
    /// protection: the card kept showing a URI record on a tag whose data area
    /// had been erased, and pressing Write would have put it back, because
    /// `dataAreaChange` is built from the same list.
    public let records: [NDEFRecord]?

    public init(
        uid: Data,
        protection: TagProtection? = nil,
        lock: TagLockReading? = nil,
        formatted: Bool? = nil,
        ndefReadable: Bool? = nil,
        records: [NDEFRecord]? = nil
    ) {
        self.uid = uid
        self.protection = protection
        self.lock = lock
        self.formatted = formatted
        self.ndefReadable = ndefReadable
        self.records = records
    }

    /// `true` when there is nothing here worth delivering.
    public var isEmpty: Bool {
        protection == nil && lock == nil && formatted == nil && ndefReadable == nil
            && records == nil
    }

    /// Fold a later reading into this one, field by field.
    ///
    /// One tap establishes one kind of fact: a permanent lock reads lock bits
    /// and nothing about a password, a protection change reads the configuration
    /// pages and nothing about lock bits. So a later reading's `nil` means "this
    /// run did not look", never "and it is not so", and replacing rather than
    /// folding is how a permanent lock followed by a password removal (the exact
    /// sequence the locked card's own copy invites) lost the lock entirely.
    ///
    /// A reading about a **different** tag replaces rather than merges: there is
    /// nothing to fold two different tags' facts into.
    public func merging(_ later: TagObservation) -> TagObservation {
        guard later.uid == uid else { return later }
        return TagObservation(
            uid: uid,
            protection: later.protection ?? protection,
            lock: later.lock ?? lock,
            formatted: later.formatted ?? formatted,
            ndefReadable: later.ndefReadable ?? ndefReadable,
            records: later.records ?? records
        )
    }
}
