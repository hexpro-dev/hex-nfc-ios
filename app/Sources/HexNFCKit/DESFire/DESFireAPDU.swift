import Foundation

/// ISO 7816 wrapping of native MIFARE DESFire commands, the form NXP AN11004 §8
/// uses throughout: `90 INS 00 00 [Lc data] 00`, answered `data ‖ 91 SS`.
///
/// Wrapped rather than native because the wrapped form is a valid APDU on both
/// transports iOS can deliver a DESFire on. Today that is always `NFCMiFareTag`,
/// which carries native and wrapped frames alike, but a card that hosts the NDEF
/// application is delivered as `NFCISO7816Tag` once the app declares the NDEF
/// AID, and that transport only takes APDUs. Live-confirmed 2026-10-30 on a
/// factory EV3 4K and a transit EV3 (`bench-traces/2026-10-30-df-0-desfire-ev3-readonly.log`):
/// wrapped commands answer normally straight after the native `60 / AF`
/// identification chain.
public enum DESFireAPDU {
    public static func wrap(_ instruction: UInt8, _ data: Data = Data()) -> Data {
        var frame = Data([0x90, instruction, 0x00, 0x00])
        if !data.isEmpty {
            frame.append(UInt8(data.count))
            frame.append(data)
        }
        frame.append(0x00)
        return frame
    }

    /// A response split into its body and the two trailing status bytes.
    public struct Response: Equatable, Sendable {
        public let body: Data
        public let sw1: UInt8
        public let sw2: UInt8

        /// A wrapped native command that completed: `91 00`.
        public var isOK: Bool {
            sw1 == 0x91 && sw2 == 0x00
        }

        /// A wrapped native command that has another frame to give: `91 AF`.
        public var hasMore: Bool {
            sw1 == 0x91 && sw2 == 0xAF
        }

        /// A plain ISO 7816 command that completed: `90 00`.
        public var isISOSuccess: Bool {
            sw1 == 0x90 && sw2 == 0x00
        }

        public var statusHex: String {
            String(format: "%02X %02X", sw1, sw2)
        }
    }

    /// `nil` for an answer too short to carry a status word, which no command
    /// here is ever answered with. The caller treats it as "not done".
    public static func split(_ raw: Data) -> Response? {
        guard raw.count >= 2 else { return nil }
        let bytes = [UInt8](raw)
        return Response(
            body: Data(bytes.dropLast(2)),
            sw1: bytes[bytes.count - 2],
            sw2: bytes[bytes.count - 1]
        )
    }
}
