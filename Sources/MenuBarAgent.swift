import AppKit

@MainActor final class MenuBarAgentDelegate: NSObject, NSApplicationDelegate {
    private let defaults=UserDefaults(suiteName:MenuBarSettings.domain)!
    private let status=MenuBarStatusReader()
    private var controller:MenuBarController?
    private var timer:Timer?
    private var statusObserver:DirectoryObserver?
    private var observers:[NSObjectProtocol]=[]

    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard defaults.object(forKey:"showInMenuBar") as? Bool ?? true else { NSApp.terminate(nil); return }
        let menu=MenuBarController(openPanel:{ [weak self] in self?.openApp(settings:false) },
            openSettings:{ [weak self] in self?.openApp(settings:true) },restartAudio:{ [weak self] in self?.restartService() })
        controller=menu
        menu.start(monochrome:defaults.object(forKey:"monochromeMenuBarIcon") as? Bool ?? true)
        refreshStatus()
        statusObserver=DirectoryObserver(RuntimeConnection.status) { [weak self] in self?.refreshStatus() }
        let center=DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName:MenuBarSettings.preferencesNotification,object:MenuBarSettings.domain,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.reloadPreferences() }
        })
        observers.append(center.addObserver(forName:MenuBarSettings.statusNotification,object:MenuBarSettings.domain,queue:.main) { [weak self] notification in
            Task { @MainActor in
                if let info=notification.userInfo { self?.status.receivePanelStatus(info) }
                self?.refreshStatus()
            }
        })
        let timer=Timer(timeInterval:1,repeats:true) { [weak self] _ in Task { @MainActor in self?.refreshStatus() } }
        self.timer=timer; RunLoop.main.add(timer,forMode:.common)
    }

    private func refreshStatus() {
        let current=status.current()
        controller?.update(health:current.health,message:current.message)
    }
    private func reloadPreferences() {
        defaults.synchronize()
        guard defaults.object(forKey:"showInMenuBar") as? Bool ?? true else { NSApp.terminate(nil); return }
        controller?.setMonochrome(defaults.object(forKey:"monochromeMenuBarIcon") as? Bool ?? true)
    }
    private func openApp(settings:Bool) {
        var appURL=Bundle.main.bundleURL
        for _ in 0..<4 { appURL.deleteLastPathComponent() }
        let configuration=NSWorkspace.OpenConfiguration()
        let completion:@Sendable (NSRunningApplication?,Error?) -> Void = { _,error in
            if let error { Task { @MainActor in Self.showError(error) } }
        }
        if settings {
            NSWorkspace.shared.open([URL(string:"studiopatch://settings")!],withApplicationAt:appURL,configuration:configuration,completionHandler:completion)
        } else {
            NSWorkspace.shared.openApplication(at:appURL,configuration:configuration,completionHandler:completion)
        }
    }
    private func restartService() {
        do { try RuntimeConnection.launch(restart:true) }
        catch { Self.showError(error) }
    }
    private static func showError(_ error:Error) {
        let alert=NSAlert(); alert.messageText="StudioPatch"; alert.informativeText=error.localizedDescription
        alert.runModal()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification:Notification) {
        timer?.invalidate(); controller?.stop()
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}

#if !STUDIOPATCH_MODEL_TESTS
@main struct StudioPatchMenuApp {
    @MainActor static func main() {
        let app=NSApplication.shared
        let delegate=MenuBarAgentDelegate(); app.delegate=delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
