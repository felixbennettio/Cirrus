import CirrusKit
import LocalAuthentication
import SwiftUI

enum Biometrics {
    /// Whether this device can ask for biometrics or the device passcode.
    static var available: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    static func authenticate(_ reason: String) async -> Bool {
        do {
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// Covers the app until the user unlocks it, when app lock is on: at start
/// and after more than a minute in the background.
struct AppLockModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked = true
    @State private var authenticating = false
    @State private var backgroundedAt: Date?

    private var enabled: Bool { model.settings.appLock }

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled && locked {
                    LockScreen(unlock: unlock)
                        .transition(.opacity)
                }
            }
            .task { if enabled { await unlock() } }
            .onChange(of: scenePhase) { _, phase in
                guard enabled else { return }
                switch phase {
                case .background:
                    if backgroundedAt == nil { backgroundedAt = Date() }
                case .active:
                    if let since = backgroundedAt, Date().timeIntervalSince(since) > 60, !authenticating {
                        locked = true
                        Task { await unlock() }
                    }
                    backgroundedAt = nil
                default:
                    break
                }
            }
    }

    private func unlock() async {
        guard !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        if await Biometrics.authenticate(L("Unlock Cirrus", "解锁 Cirrus")) {
            withAnimation { locked = false }
        }
    }
}

struct LockScreen: View {
    let unlock: () async -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 20) {
                Image("Logo")
                    .resizable()
                    .frame(width: 88, height: 88)
                    .clipShape(.rect(cornerRadius: 20))
                Text("Cirrus").font(.title.weight(.semibold))
                Button {
                    Task { await unlock() }
                } label: {
                    Label(L("Unlock", "解锁"), systemImage: "lock.open")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
    }
}
