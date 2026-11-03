import Foundation
import HexNFCKit

/// What a scan learned about a personal health device: who made it, and where
/// to send someone who wants what is on it.
///
/// **Session-only**, like `PassportData`. A History row recording that someone
/// scanned an insulin pen is health information about them, and there is
/// nothing in one worth reopening, so `ScanFlowModel` never persists it.
///
/// It lives in `FlowModels` rather than beside the sheet that shows it because
/// every file in `Screens` is `#if os(iOS)` and `swift test` on macOS skips it.
public struct HealthDeviceScan: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// The association request identification read, or `nil` when the device
    /// opened with a PHD record that did not parse.
    public let association: PHDAssociation?

    public init(association: PHDAssociation?) {
        self.association = association
    }

    public var maker: HealthDeviceMaker? {
        association?.maker
    }

    /// Colon-delimited system ID, for the info card and bug reports.
    public var systemIDHex: String? {
        association.map(\.systemID.hexString)
    }

    /// Software that reads this device in full, when its maker is one the app
    /// can name. `nil` for an unnamed maker: pointing at the wrong app is worse
    /// than pointing at none.
    public var referral: HealthDeviceReferral? {
        maker.map(HealthDeviceReferral.init(maker:))
    }
}

/// Where to send someone whose health device Hex NFC can name but not read.
///
/// One app, chosen because it is free, sold in every storefront as a single
/// listing, and on the maker's own list of apps that read the device, plus that
/// list itself, because which app suits a person depends on what else they use
/// (a glucose sensor's app, their clinic's platform) and the maker keeps it
/// current.
public struct HealthDeviceReferral: Equatable, Sendable {
    /// The app's name as its developer writes it. Not translated.
    public let appName: String
    /// Storefront-neutral App Store link, so the reader lands in their own store.
    public let appStoreURL: URL
    /// The maker's page listing every app that reads the device.
    public let compatibleAppsURL: URL

    public init(maker: HealthDeviceMaker) {
        switch maker {
        case .novoNordisk:
            // mySugr (Roche): one global listing, id 516509211, free. Novo
            // Nordisk lists it alongside Glooko and FreeStyle LibreLink at
            // novonordisk.com/novopenapps. LibreLink is a separate app per
            // region and only for Libre sensor users, and Glooko is not in
            // every store, which is why neither leads. Checked 2026-10-22.
            appName = "mySugr"
            appStoreURL = Self.url("https://apps.apple.com/app/id516509211")
            compatibleAppsURL = Self.url("https://www.novonordisk.com/novopenapps")
        }
    }

    private static func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { preconditionFailure("malformed referral URL \(string)") }
        return url
    }
}
