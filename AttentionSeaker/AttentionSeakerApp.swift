import SwiftData
import SwiftUI

@main
struct AttentionSeakerApp: App {
    private let modelContainer: ModelContainer
    @State private var controller: AppController

    init() {
        let container = ModelContainerFactory.makePersistentContainer()
        let transport = URLSessionTransport()
        let cacheStore = SwiftDataAttentionCacheStore(container: container)
        let appController = AppController(
            configuration: AppConfiguration(),
            oauth: GitHubOAuthClient(transport: transport),
            tokenStore: KeychainTokenStore(),
            github: GitHubAPIClient(transport: transport),
            cache: cacheStore,
            launchAtLogin: LaunchAtLoginController()
        )
        modelContainer = container
        _controller = State(initialValue: appController)
    }

    var body: some Scene {
        MenuBarExtra("AttentionSeaker", systemImage: "bell") {
            MenuBarView()
                .environment(controller)
                .modelContainer(modelContainer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(controller)
                .modelContainer(modelContainer)
        }
    }
}
