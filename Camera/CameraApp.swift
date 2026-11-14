import SwiftUI

@main
struct CameraApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var storage = StorageManager.shared

    var body: some Scene {
        WindowGroup {
            CameraView()
                .environmentObject(storage)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { storage.refreshStatus() }
        }
    }
}
