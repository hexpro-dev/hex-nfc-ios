import Foundation
import HexNFCKit

/// Format and Remove NDEF setup on a MIFARE DESFire, and the words for what
/// stopped them.
///
/// The work itself is `DESFireNDEFDriver`, reached through the `ConnectedTag`
/// entry points so the frames that ship are the frames the tests replay. What
/// lives here is the translation into this screen's vocabulary, and the one
/// distinction it has to keep: a card that **answered** with a refusal and a
/// card that did **not answer** are different reports. Only the second leaves
/// the outcome unknown, so only the second invites another tap; a refusal
/// tapped again is refused again.
extension OperationsFlowModel {
    /// Tap 1's refusals for Format, before the user is asked to type a UID: a
    /// DESFire this app would refuse on tap 2 is refused here, from the same
    /// reading, with nothing written.
    func preflightDESFireSetup(on tag: ConnectedTag) async throws {
        guard tag.desfireNDEFDriver != nil else {
            throw Self.unsupportedGeneration(tag)
        }
        let state = try await tag.readDESFireNDEFState()
        switch state {
        case .blank, .ours(.inProgress), .ours(.complete):
            return

        default:
            throw Self.report(
                DESFireNDEFError(reason: .refused(state), wroteSomething: false, diagnostics: "\(state)"),
                removing: false
            )
        }
    }

    func setUpDESFireNDEFApplication(on tag: ConnectedTag) async throws -> Summary {
        do {
            switch try await tag.setUpDESFireNDEF() {
            case .created: return .ndefApplicationCreated
            case .alreadySetUp: return .ndefAlreadySetUp
            }
        } catch let error as DESFireNDEFError {
            throw Self.report(error, removing: false)
        }
    }

    /// Tap 1 of Remove NDEF setup: every check the removal makes before it
    /// presents the factory key, read-only, so a card it would refuse is refused
    /// before the user types its UID. A blank card passes and tap 2 reports it
    /// as already blank, with nothing sent that changes it.
    func preflightDESFireRemoval(on tag: ConnectedTag) async throws {
        guard tag.desfireNDEFDriver != nil else {
            throw Self.unsupportedGeneration(tag)
        }
        do {
            _ = try await tag.checkDESFireNDEFRemovable()
        } catch let error as DESFireNDEFError {
            throw Self.report(error, removing: true)
        }
    }

    func removeDESFireNDEFSetup(on tag: ConnectedTag) async throws -> Summary {
        guard tag.desfireNDEFDriver != nil else {
            throw Self.unsupportedGeneration(tag)
        }
        do {
            switch try await tag.removeDESFireNDEF() {
            case .removed: return .ndefSetupRemoved
            case .alreadyBlank: return .alreadyBlank
            }
        } catch let error as DESFireNDEFError {
            throw Self.report(error, removing: true)
        }
    }

    static func unsupportedGeneration(_ tag: ConnectedTag) -> TagError {
        TagError(
            kind: .capabilityUnsupported(.formatCC),
            userMessage: "This works only on MIFARE DESFire EV1, EV2 and EV3 cards.",
            diagnostics: "chip \(tag.chip?.id.description ?? "unidentified")"
        )
    }

    /// The report for a DESFire setup or removal that stopped.
    static func report(_ error: DESFireNDEFError, removing: Bool) -> TagError {
        TagError(
            kind: .protocolError,
            userMessage: removing ? removalMessage(error) : setupMessage(error),
            diagnostics: "\(error.reason) wroteSomething=\(error.wroteSomething) \(error.diagnostics)"
        )
    }

    private static func setupMessage(_ error: DESFireNDEFError) -> LocalizedStringResource {
        switch error.reason {
        case .refused(.otherApplications):
            "This card already has other applications on it, so it can't be set up for NDEF here. Nothing was written."

        case .refused(.applicationsNeedKey):
            "This card needs its master key before anything can be added to it, so it can't be set up for NDEF here. Nothing was written."

        case .refused(.otherNDEFSetup), .refused(.ours(.unrecognisedContent)):
            "This card was set up for NDEF by another app, so Hex NFC leaves it as it is. Nothing was written."

        case .notEnoughMemory where error.wroteSomething:
            "There isn't enough free memory on this card for an NDEF file. Use Remove NDEF setup to clear what was started."

        case .notEnoughMemory:
            "There isn't enough free memory on this card for an NDEF file. Nothing was written."

        case .cardRefused(.createApplication, _):
            "The card refused the setup. Scan it to see what it holds."

        case .cardRefused where error.wroteSomething:
            "The card refused part of the setup. Use Remove NDEF setup to start over."

        case .noAnswer(.writeCC), .noAnswer(.readBack):
            "The card may be partly set up. Scan it to check, or tap Format again."

        case .noAnswer:
            "The card is partly set up. Tap Format again to finish."

        case .readBackMismatch:
            "The card accepted every step, but reading it back didn't show the setup. Scan it to check."

        default:
            "The card didn't answer the way a DESFire does, so nothing was written."
        }
    }

    private static func removalMessage(_ error: DESFireNDEFError) -> LocalizedStringResource {
        switch error.reason {
        case .refused(.otherApplications):
            "This card has other applications on it. Removing the setup would delete them too, so nothing was changed."

        case .refused(.otherNDEFSetup):
            "This card's NDEF setup was made by another app, so Hex NFC won't remove it. Nothing was changed."

        case .piccKeyNotFactory, .factoryKeyRefused:
            "This card's master key isn't the factory key, so the app can't remove its setup. Nothing was changed."

        case .noAnswer:
            "The card may already be blank. Scan it to check."

        case .cardRefused:
            "The card refused to remove the setup. Scan it to see what it holds."

        case .readBackMismatch:
            "The card answered, but reading it back still shows applications on it. Scan it to check."

        default:
            "The card didn't answer the way a DESFire does, so nothing was changed."
        }
    }
}
