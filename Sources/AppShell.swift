import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func removeLegacyLoginItem() throws
    func start() async throws
}

@MainActor struct MenuBarLoginItem: LoginItemService {
    private var service:SMAppService { .loginItem(identifier:MenuBarSettings.helperIdentifier) }
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func removeLegacyLoginItem() throws {
        if [.enabled,.requiresApproval].contains(SMAppService.mainApp.status) { try SMAppService.mainApp.unregister() }
    }
    func start() async throws {
        guard status == .enabled else { return }
        let helper=Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/StudioPatchMenu.app")
        let configuration=NSWorkspace.OpenConfiguration(); configuration.activates=false
        _ = try await NSWorkspace.shared.openApplication(at:helper,configuration:configuration)
    }
}

@MainActor final class AppPreferences: ObservableObject {
    @Published private(set) var showInMenuBar: Bool
    @Published var monochromeIcon: Bool { didSet {
        defaults.set(monochromeIcon,forKey:"monochromeMenuBarIcon"); defaults.synchronize(); notifyChanged()
    } }
    @Published private(set) var loginMessage = ""
    @Published private(set) var loginNeedsAttention = false
    private let defaults: UserDefaults
    private let loginItem: LoginItemService
    private let notifyChanged: () -> Void

    init(defaults:UserDefaults = .standard, loginItem:LoginItemService? = nil,
         notifyChanged:@escaping () -> Void = MenuBarSettings.preferencesChanged) {
        self.defaults=defaults; self.loginItem=loginItem ?? MenuBarLoginItem(); self.notifyChanged=notifyChanged
        showInMenuBar=defaults.object(forKey:"showInMenuBar") as? Bool ?? true
        monochromeIcon=defaults.object(forKey:"monochromeMenuBarIcon") as? Bool ?? true
    }

    var hasShownPanel: Bool { defaults.bool(forKey:"hasShownControlPanel") }
    func didShowPanel() { defaults.set(true,forKey:"hasShownControlPanel") }

    func prepareLoginItem() {
        // Do not undo a later choice made in macOS Login Items on every launch.
        if !defaults.bool(forKey:"menuBarUsesHelper") || !defaults.bool(forKey:"menuBarLoginItemConfigured") {
            updateLoginItem()
        } else if !showInMenuBar && loginItem.status != .notRegistered {
            updateLoginItem()
        } else {
            refreshLoginStatus()
            startMenuBarIfEnabled()
        }
    }

    func setShowInMenuBar(_ show:Bool) {
        showInMenuBar=show
        defaults.set(show,forKey:"showInMenuBar")
        // The login helper can start immediately after registration in another process.
        defaults.synchronize()
        updateLoginItem()
        notifyChanged()
    }

    private func updateLoginItem() {
        do {
            if showInMenuBar {
                if [.notRegistered,.notFound].contains(loginItem.status) { try loginItem.register() }
            } else if ![.notRegistered,.notFound].contains(loginItem.status) {
                try loginItem.unregister()
            }
            if !defaults.bool(forKey:"menuBarUsesHelper") {
                try loginItem.removeLegacyLoginItem()
                defaults.set(true,forKey:"menuBarUsesHelper")
            }
            defaults.set(true,forKey:"menuBarLoginItemConfigured")
            refreshLoginStatus()
            startMenuBarIfEnabled()
        } catch {
            loginNeedsAttention=true
            loginMessage="Could not update launch at login: \(error.localizedDescription)"
        }
    }

    private func startMenuBarIfEnabled() {
        guard showInMenuBar,loginItem.status == .enabled else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await loginItem.start() }
            catch {
                loginNeedsAttention=true
                loginMessage="Could not open the menu bar: \(error.localizedDescription)"
            }
        }
    }

    func refreshLoginStatus() {
        loginNeedsAttention=false
        if showInMenuBar {
            switch loginItem.status {
            case .enabled: loginMessage="StudioPatch opens in the menu bar at login, without opening the control panel."
            case .requiresApproval:
                loginNeedsAttention=true
                loginMessage="Allow StudioPatch in macOS Login Items to show the menu bar icon at login."
            case .notRegistered:
                loginNeedsAttention=true
                loginMessage="Launch at login is off. Turn Show in menu bar off and on to enable it again."
            case .notFound:
                loginNeedsAttention=true
                loginMessage="macOS could not find StudioPatch for launch at login. Reopen the installed app and try again."
            @unknown default:
                loginNeedsAttention=true
                loginMessage="Could not read the launch at login status."
            }
        } else {
            loginMessage="Open StudioPatch from Finder or Spotlight to return to the control panel."
        }
    }
}

struct AppSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Menu Bar").font(.title2.weight(.semibold))
            Toggle("Show in menu bar",isOn:Binding(get:{preferences.showInMenuBar},set:preferences.setShowInMenuBar))
            Text(preferences.loginMessage).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if preferences.loginNeedsAttention {
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
            Divider()
            Toggle("Use system appearance for logo",isOn:$preferences.monochromeIcon)
            Text("The logo follows the menu bar appearance. Turn this off to use turquoise.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text("The status dot keeps its color and shows the same audio status as the control panel.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Divider()
            Text("StudioPatch appears in the Dock and ⌘Tab. Quitting it keeps the menu bar and audio running.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
        .padding(24).frame(width:420).preferredColorScheme(.dark)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let preferences: AppPreferences
    private let makeModel: @MainActor () -> Model
    private(set) var model: Model?
    private(set) var panel: NSWindow?
    private(set) var settingsWindow: NSWindow?
    private var statusSubscription: AnyCancellable?
    private var focusMonitor: Any?

    init(preferences:AppPreferences? = nil, makeModel:@escaping @MainActor () -> Model = { Model() }) {
        self.preferences=preferences ?? AppPreferences(); self.makeModel=makeModel
        super.init()
    }

    func applicationDidFinishLaunching(_ notification:Notification) { start() }

    func start() {
        NSApp.setActivationPolicy(.regular)
        model=makeModel()
        buildMainMenu()
        preferences.prepareLoginItem()
        if let model {
            statusSubscription=model.$health.combineLatest(model.$message).sink { health,message in
                MenuBarSettings.publishStatus(health:health,message:message)
            }
        }
        // Keep inline label commits working when native matrix/buttons take an outside click.
        focusMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { event in
            if let window=event.window,
               let editor=window.firstResponder as? NSTextView, editor.isFieldEditor,
               let field=editor.delegate as? NSTextField,
               ["To Computer","From Computer","Empty uses routing name","Empty uses interface name"].contains(field.placeholderString ?? ""),
               !field.bounds.contains(field.convert(event.locationInWindow,from:nil)) {
                window.makeFirstResponder(nil)
            }
            return event
        }
        showPanel()
    }

    @objc func showPanel() {
        guard let model else { return }
        if panel == nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:800),
                                styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            window.title="StudioPatch"; window.minSize=NSSize(width:1050,height:690)
            window.isReleasedWhenClosed=false; window.delegate=self
            window.contentView=NSHostingView(rootView:ContentView(m:model,openSettings:{ [weak self] in self?.showSettings() }))
            window.center(); window.setFrameAutosaveName("StudioPatchControlPanel")
            window.setFrameUsingName("StudioPatchControlPanel")
            panel=window
        }
        panel?.deminiaturize(nil); panel?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        if !preferences.hasShownPanel {
            preferences.didShowPanel()
        }
        if model.liveRuntime { RuntimeConnection.requestNotifications() }
    }

    @objc func showSettings() {
        preferences.refreshLoginStatus()
        if settingsWindow == nil {
            let window=NSWindow(contentRect:.zero,styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title="StudioPatch Settings"; window.isReleasedWhenClosed=false; window.delegate=self
            let content=NSHostingView(rootView:AppSettingsView(preferences:preferences))
            window.contentView=content; window.setContentSize(content.fittingSize); window.center()
            settingsWindow=window
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }

    @objc func closeControlPanel() {
        settingsWindow?.makeFirstResponder(nil); settingsWindow?.orderOut(nil)
        panel?.attachedSheet?.makeFirstResponder(nil); panel?.makeFirstResponder(nil); panel?.orderOut(nil)
    }

    @objc private func restartService() { model?.restartService() }

    func windowShouldClose(_ sender:NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        if sender == panel, sender.attachedSheet != nil { return false }
        return true
    }

    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool {
        showPanel(); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        panel?.attachedSheet?.makeFirstResponder(nil); panel?.makeFirstResponder(nil)
        return .terminateNow
    }
    func application(_ application:NSApplication,open urls:[URL]) {
        if urls.contains(where:{$0.scheme == "studiopatch" && $0.host == "settings"}) { showSettings() }
    }
    func applicationWillBecomeActive(_ notification:Notification) { preferences.refreshLoginStatus() }
    func applicationWillTerminate(_ notification:Notification) {
        if let focusMonitor { NSEvent.removeMonitor(focusMonitor) }
        focusMonitor=nil; statusSubscription=nil
    }

    private func item(_ title:String,_ action:Selector,key:String) -> NSMenuItem {
        let item=NSMenuItem(title:title,action:action,keyEquivalent:key); item.target=self; return item
    }
    private func buildMainMenu() {
        let main=NSMenu()
        let app=NSMenu(title:"StudioPatch")
        let appRoot=NSMenuItem(); appRoot.submenu=app; main.addItem(appRoot)
        let about=NSMenuItem(title:"About StudioPatch",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        app.addItem(about); app.addItem(.separator())
        app.addItem(item("Settings…",#selector(showSettings),key:","))
        app.addItem(item("Restart Audio Service",#selector(restartService),key:"")); app.addItem(.separator())
        app.addItem(NSMenuItem(title:"Hide StudioPatch",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h"))
        let hideOthers=NSMenuItem(title:"Hide Others",action:#selector(NSApplication.hideOtherApplications(_:)),keyEquivalent:"h")
        hideOthers.keyEquivalentModifierMask=[.command,.option]; app.addItem(hideOthers)
        app.addItem(NSMenuItem(title:"Show All",action:#selector(NSApplication.unhideAllApplications(_:)),keyEquivalent:""))
        app.addItem(.separator()); app.addItem(NSMenuItem(title:"Quit StudioPatch",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"))
        let file=NSMenu(title:"File"), fileRoot=NSMenuItem(); fileRoot.submenu=file; main.addItem(fileRoot)
        file.addItem(NSMenuItem(title:"Close Window",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w"))
        let edit=NSMenu(title:"Edit"), editRoot=NSMenuItem(); editRoot.submenu=edit; main.addItem(editRoot)
        for (title,action,key) in [("Undo","undo:","z"),("Redo","redo:","Z"),("Cut","cut:","x"),
                                   ("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] {
            edit.addItem(NSMenuItem(title:title,action:Selector(action),keyEquivalent:key))
        }
        let window=NSMenu(title:"Window"), windowRoot=NSMenuItem(); windowRoot.submenu=window; main.addItem(windowRoot)
        window.addItem(item("Open StudioPatch",#selector(showPanel),key:""))
        window.addItem(NSMenuItem(title:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m"))
        window.addItem(NSMenuItem(title:"Zoom",action:#selector(NSWindow.performZoom(_:)),keyEquivalent:""))
        NSApp.mainMenu=main; NSApp.windowsMenu=window
    }
}

#if !STUDIOPATCH_MODEL_TESTS
@main struct StudioPatchApp {
    @MainActor static func main() {
        let app=NSApplication.shared
        let delegate=AppDelegate()
        app.delegate=delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
