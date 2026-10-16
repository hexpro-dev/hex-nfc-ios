import Foundation
import HexNFCKit
import HexNFCStorage

/// Keeps the device's record of what a tag is holding in step with the frames
/// that change it.
///
/// ## The asymmetry every rule here follows from
///
/// A credential the app holds for a tag that does not have it is harmless
/// clutter. A credential the tag holds and the app does not is a dead tag. So:
///
/// - The record is written **before** the frame that could apply the credential,
///   never after it succeeds. A write that lands while the app is being killed,
///   or while the tag is lifted off the phone, is exactly the case a
///   write-on-success store cannot survive. Taking a ticket is that write, which
///   is why a ticket is taken rather than a flag set: there is no way to ask for
///   one without the record going down first.
/// - The record keeps the **previous** credential behind the new one, because
///   between those two frames either could be the one the tag holds.
/// - The record is deleted only when a read-back has proved both that the gate
///   is down **and** that the tag's credential is back at its published factory
///   value. An acknowledgement is not that proof.
///
/// ## Why a ticket rather than two calls
///
/// The two halves are one rule and were written out by hand at four sites, two
/// in the write flow and none at all in Operations, which is how the standalone
/// protect screen came to persist nothing. Splitting them into "save" and
/// "promote" leaves a caller free to do the second without the first, which is
/// the write-on-success store the asymmetry above rules out. A ticket cannot be
/// settled without having been taken.
///
/// A ticket that is never settled is the interrupted state, and it is recorded
/// as such: the record stays at `.applying` or `.removing`, which says either
/// the new credential or one behind it may be what the tag answers to. A caller
/// that throws between the two therefore needs no cleanup, and must not add any.
struct TagCredentialLedger: Sendable {
    private let store: TagCredentialStoring

    init(_ store: TagCredentialStoring) {
        self.store = store
    }

    /// File `credential` as the one this tag is about to be armed with, and hand
    /// back the ticket that closes the entry.
    func arming(_ credential: TagCredential, forUID uid: Data) -> Ticket {
        open(credential, forUID: uid, intent: .arming)
    }

    /// File `credential` as the one this tag is believed to hold while a removal
    /// is in flight.
    func removing(_ credential: TagCredential, forUID uid: Data) -> Ticket {
        open(credential, forUID: uid, intent: .removing)
    }

    private func open(_ credential: TagCredential, forUID uid: Data, intent: Ticket.Intent) -> Ticket {
        let material = credential.material
        let existing = store.record(forUID: uid)?.candidates ?? []
        // `try?`. A Keychain that refuses the write is a worse record, not a
        // reason to refuse the operation: the tag is about to be changed either
        // way, and failing here would leave the user unable to protect a tag
        // because of a store they never asked for.
        try? store.save(
            TagCredentialRecord(stage: intent.inFlightStage, candidates: [material] + existing),
            forUID: uid
        )
        return Ticket(store: store, uid: uid, material: material, existing: existing, intent: intent)
    }

    /// One filed entry, waiting on the residue that says how it ended.
    struct Ticket: Sendable {
        enum Intent: Sendable {
            case arming
            case removing

            var inFlightStage: TagCredentialRecord.Stage {
                switch self {
                case .arming: .applying
                case .removing: .removing
                }
            }
        }

        let store: TagCredentialStoring
        let uid: Data
        let material: ProtectionCredential.Material
        /// What the record held before this entry. Kept so a removal that did not
        /// prove the tag bare can file the whole candidate list again rather than
        /// a single entry standing in for it.
        let existing: [ProtectionCredential.Material]
        let intent: Intent

        /// Close the entry against what the driver actually established.
        func settle(_ residue: ProtectionResidue) {
            switch intent {
            case .arming:
                // Keep the previous credential behind the new one: if the change
                // tore, either may be the one the tag now answers to.
                try? store.save(
                    (store.record(forUID: uid) ?? TagCredentialRecord(stage: .armed, candidates: [material]))
                        .promoting(material, stage: residue.metItsGoal ? .armed : .applying),
                    forUID: uid
                )

            case .removing:
                // Forget the credential ONLY when a read-back proved the gate
                // down AND the tag's credential is provably back at the factory
                // value. Anything less keeps it: a tag that is open but still
                // holding the user's password cannot be re-keyed without it, and
                // that combination is exactly what the 2026-09-04 incident left.
                if residue.gate == .provenOpen, residue.credential == .factoryDefault {
                    store.delete(forUID: uid)
                } else {
                    try? store.save(
                        TagCredentialRecord(stage: .residue, candidates: [material] + existing),
                        forUID: uid
                    )
                }
            }
        }
    }
}
