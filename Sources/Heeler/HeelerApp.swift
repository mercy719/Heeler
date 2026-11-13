import SillClient
import SwiftUI

/// App entry point. M0 ships only the buildable skeleton; the Console UI
/// arrives in M1 once the Transport underneath it exists.
@main
struct HeelerApp: App {
    /// APNs delivers device tokens through UIApplicationDelegate callbacks
    /// only, so push bootstrap (#71) needs this adaptor.
    @UIApplicationDelegateAdaptor(PushRegistrationDelegate.self)
    private var pushDelegate
    /// The aggregate phase across every window: active while any one is.
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAccentColor.defaultsKey) private var accentColor = AppAccentColor.defaultRawValue

    init() {
        try? ImagePreparer.cleanupRemnants()
        try? FilePreparer.cleanupRemnants()
    }

    var body: some Scene {
        // Valued by the Agent a window shows, so Open in New Window and a
        // dragged Console row each get a window restored to their Agent. A
        // cold launch opens the Console with no value.
        WindowGroup(for: AgentRoute.self) { $route in
            #if DEBUG && targetEnvironment(simulator)
                if DemoScreenshotMode.isEnabled {
                    DemoScreenshotRootView()
                        .tint(AppAccentColor.color(for: accentColor))
                } else if let debugURL = RemoteDesktopDebugURL.launchURL {
                    // A Simulator run opens Remote Desktop on the URL it was
                    // launched with, skipping SSH.
                    RemoteDesktopView(store: .debug(url: debugURL))
                        .tint(AppAccentColor.color(for: accentColor))
                } else if let address = SillDebugAddress.launchAddress {
                    // `-SillDebugAddress 127.0.0.1:<port>`: the sill stream alone, over
                    // an address the caller already forwards to a Mac.
                    SillStreamView(host: address.host, port: address.port) { _ in }
                        .tint(AppAccentColor.color(for: accentColor))
                } else {
                    productionContent(route: $route)
                }
            #else
                productionContent(route: $route)
            #endif
        }
        .commands { ConsoleCommands() }
        // Keeps the Usage widgets current while the app is closed.
        .backgroundTask(.appRefresh(AgentUsageBackgroundRefresh.identifier)) { [pushDelegate] in
            #if DEBUG && targetEnvironment(simulator)
                guard !DemoScreenshotMode.isEnabled else { return }
            #endif
            await pushDelegate.appModel.refreshUsageInBackground()
        }
        .onChange(of: scenePhase) {
            #if DEBUG && targetEnvironment(simulator)
                guard !DemoScreenshotMode.isEnabled else { return }
            #endif
            pushDelegate.appModel.scenePhaseDidChange(scenePhase)
        }
    }

    private func productionContent(route: Binding<AgentRoute?>) -> some View {
        ContentView(app: pushDelegate.appModel, windowRoute: route)
            .tint(AppAccentColor.color(for: accentColor))
    }
}

#if DEBUG
    /// `-SillDebugAddress host:port`: a Simulator run shows the sill stream alone over
    /// that address, skipping SSH. Release has no such path.
    @MainActor
    enum SillDebugAddress {
        static var launchAddress: (host: String, port: UInt16)? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-SillDebugAddress"),
                case let next = arguments.index(after: index), next < arguments.endIndex,
                let colon = arguments[next].lastIndex(of: ":"),
                let port = UInt16(arguments[next][arguments[next].index(after: colon)...])
            else { return nil }
            return (String(arguments[next][..<colon]), port)
        }
    }
#endif
