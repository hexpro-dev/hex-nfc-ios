import Foundation

/// Pure decoder for Suica-family (FeliCa system `0x0003`) transaction history
/// blocks read from service `0x090F`.
///
/// This is the source of truth for the byte-level format and carries **no I/O
/// and no CoreNFC** — it takes raw 16-byte blocks and returns model values, so
/// the chip simulator and the unit tests exercise exactly the same code the
/// device path runs.
///
/// 16-byte block layout (big-endian fields, **except balance which is
/// little-endian** — the classic parsing gotcha):
///
/// ```
/// byte 0      terminal / device type
/// byte 1      process type (fare / charge / bus / goods …)
/// byte 2      payment type
/// byte 3      entry/exit flags
/// byte 4–5    date, bit-packed:  v = (b4<<8)|b5
///               year  = (v >> 9) & 0x7F   (+2000)
///               month = (v >> 5) & 0x0F
///               day   =  v       & 0x1F
/// byte 6–7    entry  line+station code (saibane)   [rail rides only]
/// byte 8–9    exit   line+station code (saibane)   [rail rides only]
/// byte 10–11  balance in yen, LITTLE-ENDIAN: b10 | (b11<<8)  (post-txn)
/// byte 12–14  transaction sequence number (24-bit, big-endian)
/// byte 15     region code
/// ```
///
/// Bytes 6-9 are namespaced by the process/terminal code: they are entry/exit
/// saibane codes only for a rail ride. A bus fare stores a 16-bit bus line code
/// and a 16-bit stop code there; a shop purchase stores a packed time of day in
/// 6-7 and a shop code in 8-9; a charge stores the station of the top-up machine
/// in 6-7 with 8-9 zero. `decodeBlock` only populates `entry`/`exit` when
/// `Kind.legsAreRailStations` is true, so nothing downstream can read a bus stop
/// or a shop code as a station.
///
/// Reference: felicalib `suica.c` (canonical), cross-checked with the
/// farebot/metrodroid Suica format wikis.
public enum SuicaHistoryDecoder {
    /// Length of a single history block, in bytes.
    public static let blockSize = 16

    // MARK: Process codes (byte 1)

    //
    // Values from the felicalib / farebot / metrodroid process table this file's
    // header cites. Classification is by *positive* membership: a byte in none
    // of these sets is not assumed to be anything (see `kind(terminal:process:)`).

    /// Deposits. The balance goes **up**.
    ///
    /// `0x14` and `0x15` are the View-card auto-charges that fire at a gate on
    /// tap-in and tap-out, and `0x48` is a bonus charge; none of the three
    /// appeared in any set before, so they reached `.ride` through the old
    /// blanket default and a top-up drew a tram icon. `0x1F` is a top-up at a bus
    /// terminal and moved here out of `busProcesses`. `0x49` (register deposit at
    /// a convenience store) moved here out of `purchaseProcesses`: metrodroid
    /// groups it with product sales because its bytes 6-9 hold a shop code, but
    /// that no longer decides anything here (`Kind.legsAreRailStations` does),
    /// and to the user it is money going in, not a purchase.
    ///
    /// `0x33` was removed: it matches no entry in the cited tables, so no real
    /// card can produce it. It looks like a decimal/hex slip for 31 (`0x1F`).
    private static let chargeProcesses: Set<UInt8> = [0x02, 0x14, 0x15, 0x1F, 0x48, 0x49]

    /// Bus and tram fares. `0x23` is a bus/tram ticket purchase.
    private static let busProcesses: Set<UInt8> = [0x0D, 0x0F, 0x23]

    /// Shop, vending and ticket-machine purchases. `0x03` is a magnetic ticket
    /// bought at a machine, which is a purchase rather than a journey.
    private static let purchaseProcesses: Set<UInt8> = [0x03, 0x46, 0x4A, 0x4B, 0xC6, 0xCB]

    /// Rail fare events, the only kind whose bytes 6-9 are station codes.
    ///
    /// `0x01` is the ordinary gate-exit fare. `0x04` and `0x05` are fare
    /// adjustments and `0x06` is an exit processed at a staffed window; all three
    /// deduct fare at a station and carry real entry/exit codes. `0x04` and
    /// `0x06` were previously in `chargeProcesses`, so they were labelled top-ups
    /// and their stations were dropped from the row; `0x05` had no entry in any
    /// set and reached `.ride` only through the old blanket default. `0x13` is a
    /// Shinkansen fare. `0x84` and `0x85` are other-company fare settlements,
    /// listed here rather than left to the terminal fallback because they are
    /// commonly written by a standalone fare-adjustment machine rather than a
    /// gate.
    private static let rideProcesses: Set<UInt8> = [0x01, 0x04, 0x05, 0x06, 0x13, 0x84, 0x85]

    /// Card lifecycle events that are neither a journey nor a payment: new issue,
    /// window deduction, re-issue.
    private static let otherProcesses: Set<UInt8> = [0x07, 0x08, 0x11]

    // MARK: Terminal codes (byte 0)

    /// POS and vending consoles.
    private static let purchaseTerminals: Set<UInt8> = [0xC7, 0xC8]
    /// Vehicle (bus / tram) console.
    private static let busTerminals: Set<UInt8> = [0x05]
    /// Station consoles: fare-adjustment machine, ticket gate, simple gate,
    /// window processor, gate terminal, transfer-adjustment and connecting-gate
    /// machines. Used only to rescue an *unrecognised* process byte that came off
    /// one of them, so a regional fare code still reads as a journey rather than
    /// losing its stations.
    private static let rideTerminals: Set<UInt8> = [0x03, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1C, 0x1D]

    /// Decode an ordered list of history blocks (newest first) into
    /// transactions. Blank (all-zero) blocks — unused ring-buffer slots — are
    /// skipped. Malformed (wrong-size) blocks are skipped defensively.
    public static func decode(blocks: [Data]) -> [TransitTransaction] {
        blocks.compactMap { decodeBlock($0) }
    }

    /// Current balance for the card = balance field of the newest non-empty
    /// block. Returns `0` when there is no readable history.
    public static func currentBalance(blocks: [Data]) -> Int {
        for block in blocks where block.count == blockSize && !isBlank(block) {
            return balance(block)
        }
        return 0
    }

    // MARK: - Single block

    /// Decode one 16-byte block. Returns `nil` for blank or malformed blocks.
    public static func decodeBlock(_ block: Data) -> TransitTransaction? {
        guard block.count == blockSize, !isBlank(block) else { return nil }
        // Normalise to a 0-based array regardless of the Data's startIndex.
        let b = [UInt8](block)

        let kind = kind(terminal: b[0], process: b[1])
        let date = date(high: b[4], low: b[5])
        // Bytes 6-9 are only entry/exit *rail station* codes on a rail ride.
        // Every other kind reuses them: bus line and stop codes in their own
        // namespace, a packed time plus a shop code on a purchase, and the
        // top-up machine's own station on a charge. Only a ride's pair describes
        // a journey. Gate here, once, rather than at each of the four consumers
        // downstream. See `Kind.legsAreRailStations`.
        let isRail = kind.legsAreRailStations
        // Byte 15 is the region code. Saibane codes are only unique *within* a
        // region, so both legs carry it into the directory lookup.
        let region = b[15]
        let entry = isRail ? station(line: b[6], station: b[7], region: region) : nil
        let exit = isRail ? station(line: b[8], station: b[9], region: region) : nil
        let balanceYen = Int(b[10]) | (Int(b[11]) << 8)
        let sequence = (Int(b[12]) << 16) | (Int(b[13]) << 8) | Int(b[14])

        return TransitTransaction(
            kind: kind,
            date: date,
            balanceYen: balanceYen,
            entry: entry,
            exit: exit,
            sequence: sequence
        )
    }

    // MARK: - Field decoders (internal for testing)

    static func isBlank(_ block: Data) -> Bool {
        block.allSatisfy { $0 == 0 }
    }

    static func balance(_ block: Data) -> Int {
        let b = [UInt8](block)
        return Int(b[10]) | (Int(b[11]) << 8)
    }

    /// Classify a block from its terminal (byte 0) and process (byte 1) codes.
    ///
    /// The process byte decides when it is one we have a documented meaning for.
    /// Otherwise the terminal byte is consulted, and failing that the block is
    /// `.other` rather than `.ride`.
    ///
    /// That last part matters: `.ride` is the one verdict that makes the app
    /// read bytes 6-9 as station codes, resolve them against the station
    /// directory and invite the user to name them. Guessing it for a block we
    /// cannot identify is the most expensive guess available, so an unknown
    /// block now says so instead. `Kind.other` was unreachable before this.
    static func kind(terminal: UInt8, process: UInt8) -> TransitTransaction.Kind {
        if chargeProcesses.contains(process) {
            return .charge
        }
        if busProcesses.contains(process) {
            return .bus
        }
        if purchaseProcesses.contains(process) {
            return .purchase
        }
        if rideProcesses.contains(process) {
            return .ride
        }
        if otherProcesses.contains(process) {
            return .other
        }

        // Unrecognised process byte (regional or newer than our table): fall
        // back to the console that wrote the block.
        if purchaseTerminals.contains(terminal) {
            return .purchase
        }
        if busTerminals.contains(terminal) {
            return .bus
        }
        if rideTerminals.contains(terminal) {
            return .ride
        }
        return .other
    }

    /// Decode the bit-packed date in bytes 4–5. Returns `nil` if both bytes are
    /// zero (no date recorded).
    static func date(high: UInt8, low: UInt8) -> DateComponents? {
        if high == 0, low == 0 {
            return nil
        }
        let v = (UInt16(high) << 8) | UInt16(low)
        let year = Int((v >> 9) & 0x7F) + 2000
        let month = Int((v >> 5) & 0x0F)
        let day = Int(v & 0x1F)
        guard (1 ... 12).contains(month), (1 ... 31).contains(day) else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// Build a `StationRef` from a line+station pair, or `nil` if both are zero.
    /// `region` is byte 15 of the same block.
    static func station(line: UInt8, station: UInt8, region: UInt8 = 0) -> StationRef? {
        if line == 0, station == 0 {
            return nil
        }
        return StationRef(lineCode: line, stationCode: station, regionCode: region)
    }
}
