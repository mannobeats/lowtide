import SwiftUI

/// The view for a page. Each space's pages live in `Spaces/<Space>/`.
struct PageView: View {
    let page: Page

    var body: some View {
        switch page {
        case .home: HomePage()
        case .appsInstalled: InstalledPage()
        case .appsUpdates: UpdatesPage()
        case .appsAddons: AddonsPage()
        case .cleanup: CleanupPage()
        case .leftovers: LeftoversPage()
        case .spaceLens: SpaceLensPage()
        case .duplicates: DuplicatesPage()
        case .protectionOverview: ProtectionOverviewPage()
        case .threats: ThreatsPage()
        case .secrets: SecretsPage()
        case .permissions: PermissionsPage()
        case .installWatch: InstallWatchPage()
        case .networkLive: NetworkLivePage()
        case .packets: PacketsPage()
        case .dns: DNSPage()
        case .localhost: LocalhostPage()
        case .overnight: OvernightPage()
        case .systemOverview: SiliconPage()
        case .processes: ProcessesPage()
        case .sensors: SensorsPage()
        case .sessions: SessionsPage()
        case .snippets: SnippetsPage()
        case .history: HistoryPage()
        case .hosts: HostsPage()
        case .credentials: CredentialsPage()
        case .forwards: ForwardsPage()
        case .toolchain: ToolchainPage()
        case .inventory: InventoryPage()
        case .runtimes: RuntimesPage()
        case .doctor: DoctorPage()
        case .recipe: RecipePage()
        case .extensionsGallery: ExtensionsGalleryPage()
        case .dictation: DictationPage()
        case .menuBarManager: MenuBarManagerPage()
        case .widgets: WidgetsPage()
        case .commandBar: CommandBarPage()
        }
    }
}

/// A page that hasn't been built yet.
struct PlaceholderPage: View {
    let page: Page
    var body: some View {
        EmptyState(page.title, symbol: "hammer", message: "This page is being built.")
    }
}
