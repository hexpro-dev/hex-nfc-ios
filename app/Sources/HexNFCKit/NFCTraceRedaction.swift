import Foundation

/// Which frames may not appear in the trace with their payload intact.
///
/// Lifted out of `CoreNFCConnectedTag` so it can be tested. `CoreNFCSession.swift`
/// is `#if os(iOS)` from its first line, and `swift test` on the macOS host skips
/// such files entirely, so for as long as this rule lived there nothing in CI
/// ever evaluated it. It decides whether a user's password reaches an os_log line
/// and the in-app "All NFC traffic" tab, which is a poor thing to take on faith.
///
/// Covers all three families: Type-2 `PWD_AUTH` (`0x1B`) and the WRITEs that put
/// the PWD and PACK on the tag, Type-4 EV2 auth + ChangeKey cryptogram (CLA
/// `0x90`, INS `71/AF/C4`), Type-5 SLIX `SET/WRITE_PASSWORD` + `ENABLE_PRIVACY` /
/// `DESTROY` (`B3/B4/BA/B9`), the Ultralight C 3DES handshake and its plaintext
/// key-page writes, and the eMRTD access-control frames.
///
/// `ChangeFileSettings` (`5F`) is deliberately **not** masked: its CmdData is
/// access-rights, not key material, and seeing the full frame is load-bearing for
/// diagnosing a real-silicon PARAMETER_ERROR. `ChangeKey` (`C4`) stays masked,
/// because it carries the encrypted new key.
///
/// Chip-dependent rather than static, because the page a WRITE addresses means
/// different things on different dies: `A2 2C` writes a quarter of the 3DES key
/// on an Ultralight C and ordinary user memory on an NTAG215, and the PWD page is
/// 43 on an NTAG213 and 133 on an NTAG216.
public enum NFCTraceRedaction {
    public static func isSecretFrame(_ bytes: Data, chip: ChipProfile?) -> Bool {
        let isUltralightC = if case .type2(.mifareUltralightC) = chip?.family {
            true
        } else {
            false
        }
        guard let first = bytes.first else { return false }
        if first == 0x1B {
            return true
        }
        // MIFARE Ultralight C 3DES authentication. `1Ah` opens the handshake and
        // `AFh` carries `ek(RndA ‖ RndB′)`, a cryptogram computed directly under
        // the 16-byte key. Not the key itself, but the input to any offline
        // attack on it, and this trace is surfaced in-app and pasted into bug
        // reports.
        if isUltralightC {
            if first == UltralightCProtectionDriver.authenticateCommand {
                return true
            }
            if first == UltralightCProtectionDriver.continueCommand {
                return true
            }
            // A WRITE to pages 2Ch-2Fh carries the new key **in plaintext**:
            // this chip has no secure channel for key programming, so the bytes
            // really do go out in the clear and would otherwise be printed
            // verbatim. Gated on the chip because these page numbers are
            // ordinary user memory on the larger NTAG dies, and over-redacting
            // there would blind the traffic view for no benefit.
            if bytes.count >= 2, first == 0xA2,
               UltralightCLayout.keyPages.contains(Int(bytes[bytes.startIndex + 1]))
            {
                return true
            }
        }
        // The NTAG21x / UL EV1 twin of the rule above, and it was missing. A
        // `PWD_AUTH` (`1B`) was masked from the start, but the WRITE that puts
        // the password ON the tag was not, so `A2 <pwdPage> <4 password bytes>`
        // reached the os_log line and the in-app traffic view in the clear, on
        // the one operation whose whole subject is a secret. The PACK write is
        // the same: it is the value the tag answers a successful authentication
        // with, so it is half of the credential pair.
        //
        // Page numbers come from `Type2ConfigLayout` and are chip-specific, which
        // is why this is instance-bound: page 43 is the PWD on an NTAG213 and
        // ordinary user memory on an NTAG216. A chip with no password hardware
        // has no layout and nothing to mask.
        if bytes.count >= 2, first == 0xA2, let layout = chip?.type2ConfigLayout {
            let page = Int(bytes[bytes.startIndex + 1])
            if page == layout.pwdPage || page == layout.packPage {
                return true
            }
        }
        guard bytes.count >= 2 else { return false }
        let second = bytes[bytes.startIndex + 1]
        if first == 0x90, [0x71, 0xAF, 0xC4].contains(second) {
            return true
        }
        if [0xB3, 0xB4, 0xB9, 0xBA].contains(second) {
            return true
        }
        // eMRTD access-control frames (ISO 7816): EXTERNAL AUTHENTICATE (BAC),
        // GENERAL AUTHENTICATE (PACE) and MSE:Set AT carry MRZ-derived /
        // ephemeral key material, so redact them. The MRZ itself is never sent
        // over the air, and is never written to the trace as a note.
        //
        // The class byte is matched with **bit 5 (`0x10`), command chaining,
        // cleared**, and that bit is the whole point. PACE sends GENERAL
        // AUTHENTICATE as a chain and only the last step carries CLA `00`
        // (`EPassportReader.generalAuthenticate`), so matching `00`/`0C` alone
        // masked the last frame and published the rest. The first of them is
        // the one that matters: its response carries the nonce encrypted under
        // the MRZ-derived key, and that is the input to an offline attack on a
        // document number, date of birth and expiry date, which together hold
        // far less entropy than a key. Masking the whole chain also covers the
        // mapping and key-agreement steps.
        if [0x00, 0x0C].contains(first & ~0x10), [0x82, 0x86, 0x22].contains(second) {
            return true
        }
        return false
    }
}
