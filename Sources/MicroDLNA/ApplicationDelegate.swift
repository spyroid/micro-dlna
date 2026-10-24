import AppKit

#if canImport(Sparkle)
    import Sparkle
#endif

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let mediaDirectory: URL
    private let requestedIP: String?
    private let supportURL = URL(string: "https://ko-fi.com/spyroid")!
    private var statusItem: NSStatusItem?
    #if canImport(Sparkle)
        private var updaterController: SPUStandardUpdaterController?
    #endif

    init(mediaDirectory: URL, requestedIP: String?) {
        self.mediaDirectory = mediaDirectory
        self.requestedIP = requestedIP
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image =
            NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "play.tv", accessibilityDescription: "μDLNA server")
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = "μDLNA server"
        // Template images adapt automatically to the menu bar's appearance.
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "μDLNA server — \(mediaDirectory.path)"

        let menu = NSMenu()
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
        let heading = NSMenuItem(title: "μDLNA server \(version)", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(mediaFolderMenuItem())
        menu.addItem(.separator())
        let aboutItem = NSMenuItem(
            title: "About", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        let supportItem = NSMenuItem(
            title: "Support Development…", action: #selector(openSupportPage(_:)), keyEquivalent: "")
        supportItem.target = self
        menu.addItem(supportItem)
        #if canImport(Sparkle)
            // Local builds without a configured feed must not contact an update server.
            if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
                Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String
            {
                let updater = SPUStandardUpdaterController(
                    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
                updaterController = updater
                let updateItem = NSMenuItem(
                    title: "Check for Updates…",
                    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                    keyEquivalent: "")
                updateItem.target = updater
                menu.addItem(updateItem)
            }
        #endif
        let quitItem = NSMenuItem(
            title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item

        // Keep the main thread free for the menu while the server accepts connections.
        DispatchQueue.global().async { [mediaDirectory, requestedIP] in
            do {
                try runMediaServer(directory: mediaDirectory, requestedIP: requestedIP)
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "Could not start μDLNA server"
                    alert.informativeText = message
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    private func mediaFolderMenuItem() -> NSMenuItem {
        var path = mediaDirectory.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Abbreviate in Swift to preserve Unicode and the end of very long paths.
        if path == home || path.hasPrefix(home + "/") {
            path = "~" + path.dropFirst(home.count)
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        var title = "Media folder: \(path)"
        // Bound both the rendered width and the work needed for very long Unicode paths.
        var visibleCharacters = min(path.count, 80)
        while title.size(withAttributes: attributes).width > 320, visibleCharacters > 0 {
            visibleCharacters -= 1
            let start = path.prefix((visibleCharacters + 1) / 2)
            let end = path.suffix(visibleCharacters / 2)
            title = "Media folder: \(start)…\(end)"
        }

        let item = NSMenuItem(
            title: title, action: #selector(openMediaFolder(_:)), keyEquivalent: "")
        item.target = self
        item.toolTip = mediaDirectory.path
        return item
    }

    @objc private func openMediaFolder(_ sender: Any?) {
        NSWorkspace.shared.open(mediaDirectory)
    }

    @objc private func openSupportPage(_ sender: Any?) {
        NSWorkspace.shared.open(supportURL)
    }

    @objc private func showAbout(_ sender: Any?) {
        // Use Greek mu in the About panel while keeping file and executable names ASCII.
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "Support development on Ko-fi", attributes: [.link: supportURL])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "μDLNA server", .credits: credits
        ])
    }
}
