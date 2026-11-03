import Foundation

/// The reader's half of the 2-key 3DES mutual authentication that MIFARE
/// Ultralight C (`1A`) and DESFire's AuthenticateISO (`1A`) share.
///
/// Only the arithmetic lives here. The two chips frame it differently (native
/// `1A 00` / `AF ‖ token` on the Ultralight C, ISO-wrapped `90 1A …` /
/// `90 AF …` on a DESFire), so each driver keeps its own frames, its own status
/// checks and its own wording for a refusal. What must not differ between them
/// is the cipher direction, the IV chaining and the rotate, and those are pinned
/// by the Ultralight C datasheet vector (MF0ICU2 rev 3.3 §7.5.6, Table 9) in
/// `UltralightCCryptoTests`, which drives this code through that driver.
///
///     PICC → ek(RndB)                     8 bytes, zero IV
///     PCD  → ek(RndA ‖ RndB′)             16 bytes, IV = ek(RndB)
///     PICC → ek(RndA′)                    8 bytes, IV = last block of the token
///
/// `ek()` is 2-key 3DES in CBC **encrypt** mode. This is not the DESFire
/// "legacy" (`0A`) convention, where the reader deciphers to send.
public struct ISO3DESHandshake: Sendable {
    public static let blockSize = 8

    let key: Data
    public let rndA: Data
    /// `ek(RndA ‖ RndB′)`, the reader's 16-byte answer to the challenge.
    public let token: Data

    /// Answer the card's challenge `ek(RndB)` with a fresh `RndA`.
    public init(key: Data, challenge ekRndB: Data, rndA: Data) throws {
        guard ekRndB.count == Self.blockSize, rndA.count == Self.blockSize else {
            throw TagError.malformedResponse(
                ekRndB,
                diagnostics: "3DES handshake: challenge and RndA must be \(Self.blockSize) bytes, "
                    + "got \(ekRndB.count) and \(rndA.count)"
            )
        }
        let zeroIV = Data(repeating: 0, count: Self.blockSize)
        let rndB = try EMRTDCrypto.tripleDESCBCDecrypt(key: key, iv: zeroIV, data: ekRndB)
        let rndBPrime = NTAG424Crypto.rotateLeftByOne(rndB)
        // IV chains from the ciphertext just received, per ISO/IEC 10116.
        token = try EMRTDCrypto.tripleDESCBCEncrypt(key: key, iv: ekRndB, data: rndA + rndBPrime)
        self.key = key
        self.rndA = rndA
    }

    /// Whether the card's final cryptogram proves it holds the same key: it must
    /// decrypt to `RndA` rotated left by one byte. A card that answers the
    /// handshake but fails this is keyed differently, and accepting it would
    /// mean trusting a card that was never authenticated.
    public func cardProvesKey(_ ekRndAPrime: Data) throws -> Bool {
        guard ekRndAPrime.count == Self.blockSize else { return false }
        let chainIV = Data(token.suffix(Self.blockSize))
        let rndAPrime = try EMRTDCrypto.tripleDESCBCDecrypt(key: key, iv: chainIV, data: ekRndAPrime)
        return rndAPrime == NTAG424Crypto.rotateLeftByOne(rndA)
    }
}
