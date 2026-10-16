import Foundation

/// The Type-2 (NTAG21x / MIFARE Ultralight) NDEF storage envelope: the NDEF
/// message lives in user memory wrapped in a TLV — `0x03 <length> <message…>
/// 0xFE`. Messages of 255+ bytes use the 3-byte length form
/// `0x03 0xFF <hi> <lo>`.
///
/// This mirrors the `NDEFEnvelope` the chip simulators use, so the raw
/// page-write path `CoreNFCConnectedTag` takes on an *authenticated* tag — where
/// the high-level CoreNFC NDEF write can't be used (it doesn't carry the
/// `PWD_AUTH` state and nfcd reports "Stack Error / Connection Closed") —
/// produces the exact same bytes the simulator and high-level path do.
public enum Type2NDEF {
    public enum ParseError: Error, Equatable, Sendable {
        case noNDEFTLV
        case truncated
    }

    /// Wrap a raw NDEF message (as produced by `NDEFCodec.encode`) in the
    /// Type-2 TLV envelope, ready to write to user memory.
    public static func wrap(message: Data) -> Data {
        var out = Data()
        out.append(0x03)
        if message.count < 0xFF {
            out.append(UInt8(message.count))
        } else {
            out.append(0xFF)
            out.append(UInt8((message.count >> 8) & 0xFF))
            out.append(UInt8(message.count & 0xFF))
        }
        out.append(message)
        out.append(0xFE)
        return out
    }

    /// Extract the NDEF-message bytes from a Type-2 memory image, skipping any
    /// leading lock-control (`0x01`), memory-control (`0x02`), or proprietary
    /// (`0xFD`) TLVs. Throws `.noNDEFTLV` when the region holds no message (a
    /// blank or freshly-cleared tag).
    public static func unwrap(_ memory: Data) throws -> Data {
        // Normalise to a 0-based byte array so index arithmetic is safe even
        // when `memory` is a slice with a non-zero start index.
        let bytes = [UInt8](memory)
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case 0x00:
                // NULL TLV — single byte, skip.
                i += 1

            case 0xFE:
                // Terminator before any NDEF TLV — no message present.
                throw ParseError.noNDEFTLV

            case 0x01, 0x02, 0xFD:
                // Lock / Memory / Proprietary TLV — skip its length-prefixed body.
                i += 1
                guard i < bytes.count else { throw ParseError.truncated }
                i += 1 + Int(bytes[i])

            case 0x03:
                // NDEF Message TLV.
                i += 1
                guard i < bytes.count else { throw ParseError.truncated }
                let lengthByte = bytes[i]
                let length: Int
                if lengthByte == 0xFF {
                    guard i + 2 < bytes.count else { throw ParseError.truncated }
                    length = (Int(bytes[i + 1]) << 8) | Int(bytes[i + 2])
                    i += 3
                } else {
                    length = Int(lengthByte)
                    i += 1
                }
                guard i + length <= bytes.count else { throw ParseError.truncated }
                return Data(bytes[i ..< (i + length)])

            default:
                // An RFU tag value. The NFC Forum reserves 04h-FCh and every
                // reserved block still carries a length byte, so skip it the
                // same way the defined length-prefixed tags above are skipped.
                //
                // This used to advance a single byte, which is worse than it
                // sounds: it does not skip the block, it *lands inside it* and
                // then reads the block's own length byte as the next tag. A
                // real NTAG213 (UID 04:5D:E5:FA:2A:14:90, 2026-09-09) whose
                // factory Lock Control TLV had a corrupt tag byte reads
                // `04 03 A0 0C 34 03 00 FE`; skipping one byte lands on the
                // `03`, takes `A0` for a length, and claims a 160-byte NDEF
                // message. On this chip that overruns the region and throws
                // `.truncated`; on a larger one it returns 160 bytes of
                // whatever follows, as a message. Leniency may not invent
                // records out of bytes nobody wrote.
                i += 1
                guard i < bytes.count else { throw ParseError.truncated }
                i += 1 + Int(bytes[i])
            }
        }
        throw ParseError.noNDEFTLV
    }
}

public extension Type2NDEF {
    /// Whether the TLV chain in `bytes` **completes** inside them: a Terminator
    /// TLV (`FE`) was actually served, not merely implied.
    ///
    /// This is a question about the read, not about the message. It answers "did
    /// everything a reader needs arrive", which is what lets a caller say a later
    /// failure was not the tag gating pages it had not yet served. A message
    /// whose declared length happens to fill the window exactly, with the
    /// terminator sitting on the next unserved page, must answer `false`: that is
    /// precisely the case where the read was cut short.
    ///
    /// Returns `false` for a malformed or truncated chain, because nothing was
    /// established either way and the honest answer to "was this proven" is no.
    static func chainCompletes(within bytes: Data) -> Bool {
        let b = [UInt8](bytes)
        var i = 0
        while i < b.count {
            switch b[i] {
            case 0x00:
                i += 1

            case 0xFE:
                // The terminator was served. Everything a reader walks lay inside
                // the bytes given.
                return true

            case 0x01, 0x02, 0xFD:
                i += 1
                guard i < b.count else { return false }
                i += 1 + Int(b[i])

            case 0x03:
                i += 1
                guard i < b.count else { return false }
                let lengthByte = b[i]
                let length: Int
                if lengthByte == 0xFF {
                    guard i + 2 < b.count else { return false }
                    length = (Int(b[i + 1]) << 8) | Int(b[i + 2])
                    i += 3
                } else {
                    length = Int(lengthByte)
                    i += 1
                }
                // Step over the message and keep walking. Reaching its end is not
                // the same as reaching the terminator, and only the terminator
                // proves the chain was served whole.
                guard i + length <= b.count else { return false }
                i += length

            default:
                i += 1
                guard i < b.count else { return false }
                i += 1 + Int(b[i])
            }
        }
        return false
    }
}
