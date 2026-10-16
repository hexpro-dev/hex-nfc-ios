import HexNFCApp
import HexNFCKit
import HexNFCRecords
import HexNFCShaders
import HexNFCStorage
import SwiftUI

/// App-target entrypoint. Owns the single `AppModel` that lives for the
/// lifetime of the process and is injected with the production CoreNFC
/// session factory — or, when launched from XCUITest with
/// `--useSimulatedNFC`, a lightweight `MockTagSessionFactory`.
struct ContentView: View {
    @State private var model: AppModel = ContentView.makeModel()

    var body: some View {
        RootView(model: model)
    }

    @MainActor
    private static func makeModel() -> AppModel {
        let factory: TagSessionFactory
        let stack: SwiftDataStack
        let fallback: SwiftDataStack.Fallback
        let settings = AppSettings.load()
        HexHapticsEngine.shared.prepare()
        HexHapticsEngine.shared.setEnabled(settings.hapticsEnabled)
        if CommandLine.arguments.contains("--useSimulatedNFC") {
            factory = MockTagSessionFactory(scripted: [
                .uri(URIRecord(uri: "https://hex.pro")),
            ])
            stack = (try? SwiftDataStack.inMemory())
                ?? (try! SwiftDataStack(enableCloudKit: false))
            fallback = .none
        } else {
            factory = CoreNFCSessionFactory()
            // Degrades one rung at a time (see `makeBestEffort`) so a CloudKit
            // problem costs the user their sync, not their library.
            (stack, fallback) = SwiftDataStack.makeBestEffort(
                enableCloudKit: settings.iCloudSyncEnabled
            )
        }
        let library = LibraryRepository(stack: stack)
        return AppModel(
            sessionFactory: factory,
            library: library,
            settings: settings,
            storeFallback: fallback
        )
    }
}

#Preview {
    ContentView()
}
