import Foundation

/// Basic Access Control mutual authentication (ICAO Doc 9303 Part 11 §4.3 /
/// Appendix D). Pure math: the reader supplies the card challenge (from GET
/// CHALLENGE) and fresh randoms, BAC builds the EXTERNAL AUTHENTICATE payload
/// and, from the card's reply, derives the 3DES secure-messaging session.
///
/// Verified against the Doc 9303 Part 11 Appendix D worked example
/// (see `BACTests`).
enum BAC {
    /// The established secure-messaging session material.
    struct Session: Equatable {
        let ksEnc: Data
        let ksMac: Data
        let ssc: Data
    }

    enum Failure: Error, Equatable, Sendable {
        case responseMACInvalid
        case nonceMismatch
        case malformed
    }

    private static var zeroIV: Data {
        Data(repeating: 0, count: 8)
    }

    /// Build the EXTERNAL AUTHENTICATE command data `E.IFD ‖ M.IFD` and return
    /// the derived (K.enc, K.mac) so the response step can reuse them.
    /// `rndIC` is the 8-byte GET CHALLENGE response; `rndIFD` (8) and `kIFD` (16)
    /// are fresh randoms.
    static func buildExternalAuthenticate(
        mrzInformation: String,
        rndIC: Data,
        rndIFD: Data,
        kIFD: Data
    ) throws -> (commandData: Data, kEnc: Data, kMac: Data) {
        precondition(rndIC.count == 8 && rndIFD.count == 8 && kIFD.count == 16)
        let keys = EMRTDCrypto.bacKeys(mrzInformation: mrzInformation)
        let s = rndIFD + rndIC + kIFD
        let eIFD = try EMRTDCrypto.tripleDESCBCEncrypt(key: keys.enc, iv: zeroIV, data: s)
        let mIFD = try EMRTDCrypto.retailMAC(key: keys.mac, data: eIFD)
        return (eIFD + mIFD, keys.enc, keys.mac)
    }

    /// Verify the card's EXTERNAL AUTHENTICATE reply (`E.IC ‖ M.IC`, 40 bytes,
    /// status word already stripped), confirm it echoes our nonce, and derive
    /// the secure-messaging session.
    static func completeMutualAuthentication(
        responseData: Data,
        rndIC: Data,
        rndIFD: Data,
        kIFD: Data,
        kEnc: Data,
        kMac: Data
    ) throws -> Session {
        guard responseData.count >= 40 else { throw Failure.malformed }
        let eIC = responseData.prefix(32)
        let mIC = responseData
            .subdata(in: responseData.startIndex.advanced(by: 32) ..< responseData.startIndex.advanced(by: 40))

        // Authenticate the response before trusting any of its bytes.
        let expectedMAC = try EMRTDCrypto.retailMAC(key: kMac, data: Data(eIC))
        guard constantTimeEqual(expectedMAC, Data(mIC)) else { throw Failure.responseMACInvalid }

        // Decrypt: R = RND.IC ‖ RND.IFD ‖ K.IC (32 bytes).
        let r = try EMRTDCrypto.tripleDESCBCDecrypt(key: kEnc, iv: zeroIV, data: Data(eIC))
        guard r.count == 32 else { throw Failure.malformed }
        let echoedIFD = r.subdata(in: r.startIndex.advanced(by: 8) ..< r.startIndex.advanced(by: 16))
        guard constantTimeEqual(Data(echoedIFD), rndIFD) else { throw Failure.nonceMismatch }
        let kIC = r.subdata(in: r.startIndex.advanced(by: 16) ..< r.startIndex.advanced(by: 32))

        // Session key seed = K.IFD ⊕ K.IC; SSC = last4(RND.IC) ‖ last4(RND.IFD).
        let seed = NTAG424Crypto.xor(kIFD, Data(kIC))
        let ksEnc = EMRTDCrypto.deriveKey(seed: seed, counter: 1)
        let ksMac = EMRTDCrypto.deriveKey(seed: seed, counter: 2)
        let ssc = Data(rndIC.suffix(4)) + Data(rndIFD.suffix(4))
        return Session(ksEnc: ksEnc, ksMac: ksMac, ssc: ssc)
    }
}
