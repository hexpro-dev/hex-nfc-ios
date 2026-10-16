import Foundation

/// Module marker. The SwiftUI app target — screens, flow models, navigation.
///
/// The Xcode app shell (`HexNFC.xcodeproj`) carries the CoreNFC entitlements
/// and `Info.plist`; this SPM target hosts the actual screens and the root
/// `App.swift` entry point as a SwiftUI App.
public enum HexNFCApp {
    public static let moduleName = "HexNFCApp"
}
