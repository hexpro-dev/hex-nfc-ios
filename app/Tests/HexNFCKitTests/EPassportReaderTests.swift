@testable import HexNFCKit
@testable import HexNFCRecords
import HexNFCTagSim
import XCTest

/// Drives `EPassportReader` against `EPassportSimulator` — the whole BAC read
/// path (SELECT AID → GET CHALLENGE → EXTERNAL AUTHENTICATE → secure-messaging
/// SELECT/READ of EF.COM + DG1 + DG2 + DG11/DG12 → decode) with no entitlements.
final class EPassportReaderTests: XCTestCase {
    func test_reader_defaultRandoms_readsSpecimenPassport() async throws {
        // System randoms — proves the handshake works for arbitrary reader
        // nonces, not just fixed test vectors.
        let sim = EPassportSimulator()
        let tag = SimulatedConnectedTag(simulator: sim)

        let data = try await EPassportReader().read(tag, mrz: EPassportSimulator.specimenMRZ)

        XCTAssertEqual(data.documentType, "P")
        XCTAssertEqual(data.issuingState, "UTO")
        XCTAssertEqual(data.primaryIdentifier, "ERIKSSON")
        XCTAssertEqual(data.secondaryIdentifier, "ANNA MARIA")
        XCTAssertEqual(data.documentNumber, "L898902C")
        XCTAssertEqual(data.nationality, "UTO")
        XCTAssertEqual(data.dateOfBirth, "690806")
        XCTAssertEqual(data.sex, "F")
        XCTAssertEqual(data.dateOfExpiry, "940623")

        // DG2 face image extracted.
        XCTAssertEqual(data.faceImage?.format, .jpeg)
        XCTAssertNotNil(data.faceImage?.data)

        // DG7 signature image extracted.
        XCTAssertEqual(data.signatureImage?.format, .jpeg)

        // DG11 / DG12 extended detail.
        XCTAssertEqual(data.biographical?.placeOfBirth, "UTOPIA CITY")
        XCTAssertEqual(data.biographical?.issuingAuthority, "UTOPIA PASSPORT OFFICE")
        XCTAssertEqual(data.biographical?.dateOfIssue, "20200101")

        // Integrity: every read DG hash matched the signed security object.
        XCTAssertEqual(data.integrity?.status, .verified)
        XCTAssertEqual(data.integrity?.hashAlgorithm, "SHA-256")
        XCTAssertEqual(data.integrity?.checkedDataGroups, [1, 2, 7, 11, 12])
        XCTAssertEqual(data.integrity?.mismatchedDataGroups, [])
    }

    // MARK: - Integrity (EF.SOD data-group hashes)

    func test_integrityReport_detectsTamperedDataGroup() throws {
        // A DG file and its correct security object.
        let dg1 = Data([0x61, 0x05, 0x5F, 0x1F, 0x02, 0x41, 0x42])
        let dg2 = Data([0x75, 0x04, 0x7F, 0x2E, 0x01, 0xAA])
        let sodData = EPassportSimulator.buildSOD(dataGroupFiles: [1: dg1, 2: dg2])
        let sod = try XCTUnwrap(LDSSecurityObject.parse(sodData))
        XCTAssertEqual(sod.hashAlgorithm, .sha256)

        // Untouched files verify.
        let good = EPassportReader.integrityReport(sod: sod, dataGroupFiles: [1: dg1, 2: dg2])
        XCTAssertEqual(good?.status, .verified)
        XCTAssertEqual(good?.checkedDataGroups, [1, 2])

        // A single altered byte in DG2 is caught, and only DG2 is flagged.
        let tampered = Data(dg2.dropLast()) + Data([0xBB])
        let bad = EPassportReader.integrityReport(sod: sod, dataGroupFiles: [1: dg1, 2: tampered])
        XCTAssertEqual(bad?.status, .mismatch)
        XCTAssertEqual(bad?.checkedDataGroups, [1, 2])
        XCTAssertEqual(bad?.mismatchedDataGroups, [2])
    }

    func test_reader_wrongMRZ_throwsAuthFailed() async {
        let sim = EPassportSimulator()
        let tag = SimulatedConnectedTag(simulator: sim)
        let wrong = PassportMRZ(documentNumber: "X1234567", dateOfBirth: "800101", dateOfExpiry: "300101")

        do {
            _ = try await EPassportReader().read(tag, mrz: wrong)
            XCTFail("expected authentication failure with wrong MRZ")
        } catch let error as TagError {
            XCTAssertEqual(error.kind, .authFailed)
        } catch {
            XCTFail("expected TagError, got \(error)")
        }
    }

    func test_reader_skipExtendedDetails_readsCoreOnly() async throws {
        let sim = EPassportSimulator()
        let tag = SimulatedConnectedTag(simulator: sim)
        let options = EPassportReader.Options(includeFaceImage: false, includeExtendedDetails: false)

        let data = try await EPassportReader(options: options).read(tag, mrz: EPassportSimulator.specimenMRZ)
        XCTAssertEqual(data.documentNumber, "L898902C")
        XCTAssertNil(data.faceImage)
        XCTAssertNil(data.signatureImage)
        XCTAssertNil(data.biographical)
    }

    func test_simulatedTag_advertisesEPassportCapability() {
        let tag = SimulatedConnectedTag(simulator: EPassportSimulator())
        XCTAssertTrue(tag.capabilities.contains(.epassportRead))
        XCTAssertEqual(tag.chip?.id, .ePassport)
    }

    // MARK: - PACE path (EF.CardAccess advertises PACE-ECDH-GM-AES-128)

    func test_reader_pacePath_readsSpecimenPassport() async throws {
        let sim = EPassportSimulator(advertisesPACE: true)
        let tag = SimulatedConnectedTag(simulator: sim)

        // Drives the whole PACE flow: EF.CardAccess → MSE:Set AT → 4-step
        // GENERAL AUTHENTICATE (ECDH GM) → AES secure messaging → DG decode.
        let data = try await EPassportReader().read(tag, mrz: EPassportSimulator.specimenMRZ)

        XCTAssertEqual(data.documentNumber, "L898902C")
        XCTAssertEqual(data.primaryIdentifier, "ERIKSSON")
        XCTAssertEqual(data.nationality, "UTO")
        XCTAssertEqual(data.faceImage?.format, .jpeg)
        XCTAssertEqual(data.signatureImage?.format, .jpeg)
        XCTAssertEqual(data.biographical?.issuingAuthority, "UTOPIA PASSPORT OFFICE")
        XCTAssertEqual(data.integrity?.status, .verified)
    }

    func test_reader_pacePath_wrongMRZ_throwsAuthFailed() async {
        let sim = EPassportSimulator(advertisesPACE: true)
        let tag = SimulatedConnectedTag(simulator: sim)
        let wrong = PassportMRZ(documentNumber: "X1234567", dateOfBirth: "800101", dateOfExpiry: "300101")

        do {
            _ = try await EPassportReader().read(tag, mrz: wrong)
            XCTFail("expected PACE authentication failure with wrong MRZ")
        } catch let error as TagError {
            XCTAssertEqual(error.kind, .authFailed)
        } catch {
            XCTFail("expected TagError, got \(error)")
        }
    }

    // MARK: - PACE Integrated Mapping + large curves / AES-192/256 (real-passport shapes)

    /// Integrated Mapping end-to-end (BrainpoolP256r1 / AES-128) — proves the IM
    /// message flow (terminal nonce t in 0x81, empty 0x82) and that reader + card
    /// derive the same mapped generator without a key exchange.
    func test_reader_pace_integratedMapping_readsSpecimen() async throws {
        let sim = EPassportSimulator(advertisesPACE: true, paceMapping: .integrated,
                                     paceParameterId: 13, paceKeyBytes: 16)
        let data = try await EPassportReader().read(SimulatedConnectedTag(simulator: sim),
                                                    mrz: EPassportSimulator.specimenMRZ)
        XCTAssertEqual(data.documentNumber, "L898902C")
        XCTAssertEqual(data.faceImage?.format, .jpeg)
        XCTAssertEqual(data.integrity?.status, .verified)
    }

    /// Generic Mapping with BrainpoolP512r1 + AES-256 — the Australian passport's
    /// shape. Exercises the large curve and AES-256 secure messaging end-to-end.
    func test_reader_pace_genericMapping_aes256_brainpoolP512() async throws {
        let sim = EPassportSimulator(advertisesPACE: true, paceMapping: .generic,
                                     paceParameterId: 17, paceKeyBytes: 32)
        let data = try await EPassportReader().read(SimulatedConnectedTag(simulator: sim),
                                                    mrz: EPassportSimulator.specimenMRZ)
        XCTAssertEqual(data.documentNumber, "L898902C")
        XCTAssertEqual(data.primaryIdentifier, "ERIKSSON")
        XCTAssertEqual(data.faceImage?.format, .jpeg)
        XCTAssertEqual(data.integrity?.status, .verified)
    }

    /// Generic Mapping with BrainpoolP384r1 + AES-192 — the Australian passport's
    /// other advertised config. Exercises AES-192 secure messaging + SHA-256 KDF.
    func test_reader_pace_genericMapping_aes192_brainpoolP384() async throws {
        let sim = EPassportSimulator(advertisesPACE: true, paceMapping: .generic,
                                     paceParameterId: 16, paceKeyBytes: 24)
        let data = try await EPassportReader().read(SimulatedConnectedTag(simulator: sim),
                                                    mrz: EPassportSimulator.specimenMRZ)
        XCTAssertEqual(data.documentNumber, "L898902C")
        XCTAssertEqual(data.faceImage?.format, .jpeg)
    }

    /// Integrated Mapping with BrainpoolP384r1 + AES-256 — the Nepalese passport's
    /// shape.
    func test_reader_pace_integratedMapping_aes256_brainpoolP384() async throws {
        let sim = EPassportSimulator(advertisesPACE: true, paceMapping: .integrated,
                                     paceParameterId: 16, paceKeyBytes: 32)
        let data = try await EPassportReader().read(SimulatedConnectedTag(simulator: sim),
                                                    mrz: EPassportSimulator.specimenMRZ)
        XCTAssertEqual(data.documentNumber, "L898902C")
        XCTAssertEqual(data.integrity?.status, .verified)
    }
}
