import Foundation

/// A short-form ISO 7816 command APDU, decomposed for secure-messaging wrapping.
/// eMRTD reading only issues short-form commands (SELECT, GET CHALLENGE,
/// EXTERNAL AUTHENTICATE, READ BINARY, MSE, GENERAL AUTHENTICATE), so extended
/// length is intentionally not modelled.
struct APDU: Equatable, Sendable {
    var cla: UInt8
    var ins: UInt8
    var p1: UInt8
    var p2: UInt8
    /// Command data (the `Nc`/`Lc` field), if any.
    var data: Data?
    /// Expected response length byte (`Le`); `0x00` means 256.
    var le: UInt8?

    var header: Data {
        Data([cla, ins, p1, p2])
    }

    /// Parse a short-form command APDU. Anything that doesn't fit the short-form
    /// shapes eMRTD uses is decoded best-effort (never throws) — malformed input
    /// simply yields empty data / no Le.
    static func parse(_ bytes: Data) -> APDU {
        let b = [UInt8](bytes)
        guard b.count >= 4 else {
            return APDU(cla: b.first ?? 0, ins: b.count > 1 ? b[1] : 0,
                        p1: b.count > 2 ? b[2] : 0, p2: b.count > 3 ? b[3] : 0)
        }
        var apdu = APDU(cla: b[0], ins: b[1], p1: b[2], p2: b[3])
        let rest = Array(b[4...])
        if rest.isEmpty {
            return apdu
        }
        if rest.count == 1 {
            apdu.le = rest[0] // case 2: only Le
            return apdu
        }
        let lc = Int(rest[0])
        if rest.count >= 1 + lc {
            apdu.data = Data(rest[1 ..< (1 + lc)])
            if rest.count > 1 + lc {
                apdu.le = rest[1 + lc] // case 4: data + Le
            }
        }
        return apdu
    }

    /// Serialise back to wire bytes (short form).
    func serialize() -> Data {
        var out = header
        if let data, !data.isEmpty {
            out.append(UInt8(data.count))
            out.append(data)
            if let le {
                out.append(le)
            }
        } else if let le {
            out.append(le)
        }
        return out
    }
}

/// BER length encoding for a value of `count` octets (short form, or `0x81`/
/// `0x82` long form), used when hand-building secure-messaging data objects.
func berLength(_ count: Int) -> Data {
    if count < 0x80 {
        return Data([UInt8(count)])
    }
    if count < 0x100 {
        return Data([0x81, UInt8(count)])
    }
    return Data([0x82, UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)])
}
