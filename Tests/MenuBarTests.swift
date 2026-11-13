import AppKit
import ServiceManagement

@MainActor final class FakeLoginItem: LoginItemService {
    var status:SMAppService.Status = .notRegistered
    var registrations=0, removals=0
    var legacyRemovals=0
    var failure:Error?
    func register() throws {
        registrations += 1
        if let failure { throw failure }
        status = .enabled
    }
    func removeLegacyLoginItem() throws { legacyRemovals += 1 }
    func start() async throws {}
    func unregister() throws {
        removals += 1
        if let failure { throw failure }
        status = .notRegistered
    }
}

@main struct MenuBarTests {
    @MainActor static func main() throws {
        let suite="StudioPatch.MenuBarTests.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:directory) }
        let diagnosticPreview=CommandLine.arguments.contains("--diagnostics-preview") || Bundle.main.bundleIdentifier == "se.studiopatch.preview.diagnostics"
        if CommandLine.arguments.contains("--preview") || diagnosticPreview || Bundle.main.bundleIdentifier == "se.studiopatch.preview" {
            let app=NSApplication.shared
            let preferences=AppPreferences(defaults:defaults,loginItem:FakeLoginItem(),notifyChanged:{})
            let model=Model(store:SessionStore(url:directory.appendingPathComponent("session.json")),discoverDevices:false)
            model.health = .healthy; model.message="Routing active · 32 samples · 96 kHz"
            model.running=true; model.inventoryKnown=true; model.installed=true
            if diagnosticPreview {
                model.devices=[Device(id:1,uid:"preview-ufx",name:"Fireface UFX III",inputs:2,outputs:2,sampleRate:96000,aggregate:false,inputNames:[],outputNames:[]),
                    Device(id:2,uid:"preview-zed",name:"ZED R16 — ASFW",inputs:2,outputs:2,sampleRate:96000,aggregate:false,inputNames:[],outputNames:[])]
                let raw="""
                {"diagnosticSchemaVersion":1,"timelineCounterVersion":2,"generation":123,"devices":[
                {"uid":"preview-ufx","master":true,"bufferErrors":0,"timestampErrors":0,"timelineJumps":0,"incompletePlaybackBlocks":0,"missingPlaybackSamples":0,"lastCallbackAgeMs":0.3},
                {"uid":"preview-zed","master":false,"bufferErrors":0,"timestampErrors":2,"timelineJumps":1,"inputTimelineJumps":1,"outputTimelineJumps":0,"incompletePlaybackBlocks":1,"missingPlaybackSamples":64,"lastCallbackAgeMs":0.7,"clockSkewFrames":-1.4,"peakClockSkewFrames":-19.5}]}
                """
                model.diagnostics=AudioDiagnosticRecorder(directory:directory).observe(raw:raw,fresh:true,devices:model.devices)
                model.showingDiagnostics=true
            }
            let controller=AppDelegate(preferences:preferences,makeModel:{model})
            app.delegate=controller
            withExtendedLifetime(controller) { app.run() }
            return
        }
        // Upgrade from the previous version, which already configured the main-app login item.
        defaults.set(true,forKey:"menuBarLoginItemConfigured")
        let login=FakeLoginItem()
        let preferences=AppPreferences(defaults:defaults,loginItem:login,notifyChanged:{})
        precondition(preferences.showInMenuBar && preferences.monochromeIcon)
        preferences.prepareLoginItem()
        precondition(login.registrations==1 && login.status == .enabled && login.legacyRemovals==1)
        preferences.prepareLoginItem()
        precondition(login.registrations==1)
        // A choice made in macOS must survive ordinary app launches.
        login.status = .requiresApproval
        let restored=AppPreferences(defaults:defaults,loginItem:login,notifyChanged:{})
        restored.prepareLoginItem()
        precondition(login.registrations==1 && restored.loginNeedsAttention)
        restored.setShowInMenuBar(false)
        precondition(login.removals==1 && !restored.showInMenuBar)
        restored.setShowInMenuBar(true)
        precondition(login.registrations==2 && !restored.loginNeedsAttention)
        restored.monochromeIcon=true
        let persisted=AppPreferences(defaults:defaults,loginItem:login,notifyChanged:{})
        precondition(persisted.showInMenuBar && persisted.monochromeIcon)
        // A registration error must not prevent hiding the icon or lose the preference.
        login.failure=NSError(domain:"MenuBarTests",code:1,userInfo:[NSLocalizedDescriptionKey:"Test registration failure"])
        persisted.setShowInMenuBar(false)
        precondition(!persisted.showInMenuBar && persisted.loginNeedsAttention && persisted.loginMessage.contains("Test registration failure"))
        login.failure=nil
        persisted.setShowInMenuBar(true)
        persisted.didShowPanel()

        var time=Date(),panelAlive=true,serviceFails=false
        let reader=MenuBarStatusReader(read:{
            if serviceFails { throw NSError(domain:"MenuBarTests",code:2,userInfo:[NSLocalizedDescriptionKey:"Service unavailable"]) }
            return RuntimeSnapshot(devices:[],installed:true,running:true,health:.healthy,message:"Routing active",rate:96000)
        },panelIsRunning:{_ in panelAlive},now:{time})
        reader.receivePanelStatus(["health":"warning","message":"Panel warning","pid":NSNumber(value:42)])
        precondition(reader.current().health == .warning)
        panelAlive=false
        precondition(reader.current().health == .healthy)
        panelAlive=true
        reader.receivePanelStatus(["health":"warning","message":"Panel warning","pid":Int32(42)])
        time=time.addingTimeInterval(4); serviceFails=true
        precondition(reader.current().health == .error && reader.current().message == "Service unavailable")

        let app=NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let model=Model(store:SessionStore(url:directory.appendingPathComponent("session.json")),discoverDevices:false)
        var modelCreations=0
        var panelController:AppDelegate?
        var settingsActions=0,restartActions=0
        let menu=MenuBarController(openPanel:{panelController?.showPanel()},
            openSettings:{settingsActions += 1},restartAudio:{restartActions += 1})
        menu.start(monochrome:true)
        let statusItem=menu.statusItem!
        let nativeMenu=statusItem.menu!
        precondition(nativeMenu.items.map(\.title).contains("Open StudioPatch"))
        precondition(nativeMenu.items.first!.isEnabled == false)
        menu.update(health:.warning,message:"Test warning")
        precondition(statusItem.button!.toolTip!.contains("warning: Test warning"))
        precondition(nativeMenu.items.first!.title == "Test warning")
        let controller=AppDelegate(preferences:persisted,makeModel:{modelCreations += 1;return model})
        panelController=controller; app.delegate=controller
        controller.start()
        defer { controller.closeControlPanel(); menu.stop(); controller.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification)) }
        precondition(app.activationPolicy() == .regular)
        let panel=controller.panel!
        precondition(panel.isVisible && modelCreations==1)
        controller.closeControlPanel()
        precondition(!panel.isVisible && menu.statusItem === statusItem)
        nativeMenu.performActionForItem(at:2)
        precondition(panel.isVisible && controller.panel === panel && modelCreations==1)
        nativeMenu.performActionForItem(at:3); nativeMenu.performActionForItem(at:5)
        precondition(settingsActions==1 && restartActions==1)
        // Command-Q uses the native terminate action. The app never cancels termination.
        let quit=app.mainMenu!.items.first!.submenu!.items.first { $0.keyEquivalent == "q" }!
        precondition(quit.action == #selector(NSApplication.terminate(_:)))
        precondition(controller.applicationShouldTerminate(app) == .terminateNow)
        precondition(!controller.applicationShouldTerminateAfterLastWindowClosed(app))
        panel.performClose(nil)
        precondition(!panel.isVisible && app.activationPolicy() == .regular)
        _ = controller.applicationShouldHandleReopen(app,hasVisibleWindows:false)
        precondition(panel.isVisible && controller.panel === panel)
        controller.application(app,open:[URL(string:"studiopatch://settings")!])
        precondition(controller.settingsWindow!.isVisible)
        let sessionBefore=try Data(contentsOf:directory.appendingPathComponent("session.json"))
        persisted.setShowInMenuBar(false)
        precondition(panel.isVisible && app.activationPolicy() == .regular)
        menu.setMonochrome(false)
        precondition(statusItem.button!.image!.isTemplate == false)
        menu.setMonochrome(true)
        precondition(statusItem.button!.image!.isTemplate == true)
        let sessionAfter=try Data(contentsOf:directory.appendingPathComponent("session.json"))
        precondition(sessionAfter == sessionBefore)
        controller.closeControlPanel()
        controller.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
        menu.update(health:.healthy,message:"Still running after panel termination")
        precondition(menu.statusItem === statusItem && nativeMenu.items.first!.title == "Still running after panel termination")
        print("PASS: login migration, native status menu, regular app, quit contract, independent status and no audio-session edits")
    }
}
