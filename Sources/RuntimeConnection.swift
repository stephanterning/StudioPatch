import Foundation
import UserNotifications
import AVFoundation
import os

enum RuntimeHealth: String, Codable {
    case idle, healthy, warning, error
}
struct RuntimeSnapshot: Codable {
    var date = Date()
    var devices: [Device]
    var installed: Bool
    var running: Bool
    var health: RuntimeHealth
    var message: String
    var rate: Int
    var latencyDiagnostics: String? = nil
}
enum RuntimeConnection {
    static let directory:URL = ProcessInfo.processInfo.environment["STUDIOPATCH_TEST_DIRECTORY"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("StudioPatch")
    static let status=directory.appendingPathComponent("runtime-status.json")
    static func requestNotifications() {
        // Ask from the visible app, which shares the service's certificate requirement.
        // AudioDeviceStart in a LaunchAgent cannot reliably present the first consent prompt.
        if AVCaptureDevice.authorizationStatus(for:.audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for:.audio) { _ in }
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) { _,_ in }
            }
        }
    }
    // System notifications report problems only; successful changes are shown
    // in the panel's status line.
    @MainActor static func notifyProblem(_ identifier:String,title:String,body:String) {
        notify(identifier:identifier,title:"StudioPatch: "+title,body:body)
    }
    @MainActor static func notifyDisconnected(_ name:String,reason:String) {
        notify(identifier:"device-unavailable",title:"StudioPatch: audio interface disconnected",
               body:"\(name) was removed from Core Audio. \(reason)")
    }
    private static let problemIDs:Set<String> = ["device-unavailable","runtime-failure","format-failed","rate-refused","sync-mismatch"]
    @MainActor private static var notificationIDs:[String:String] = [:]
    @MainActor private static var notificationsCleared=false

    // Unique delivery IDs let a late authorization/add callback discard its old
    // notification without deleting a newer occurrence of the same problem.
    @MainActor private static func obsoleteProblemIDs(_ identifiers:[String]) -> [String] {
        identifiers.filter { id in
            !notificationIDs.values.contains(id) && problemIDs.contains { id == $0 || id.hasPrefix($0+".") }
        }
    }
    @MainActor static func clearProblemNotifications() {
        guard !notificationsCleared else { return }
        notificationsCleared=true;notificationIDs.removeAll()
        if ProcessInfo.processInfo.environment["STUDIOPATCH_TEST_DIRECTORY"] != nil {
            updateTestNotifications { visible in
                for id in obsoleteProblemIDs(Array(visible.keys)) { visible.removeValue(forKey:id) }
            }
            return
        }
        let center=UNUserNotificationCenter.current()
        Task {
            let delivered=await center.deliveredNotifications()
            center.removeDeliveredNotifications(withIdentifiers:obsoleteProblemIDs(delivered.map { $0.request.identifier }))
            let pending=await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers:obsoleteProblemIDs(pending.map(\.identifier)))
        }
    }
    // The isolated runtime records a visible notification set as well as the
    // existing append-only history; tests never touch macOS Notification Center.
    private static func updateTestNotifications(_ update:(inout [String:[String:String]])->Void) {
        let url=directory.appendingPathComponent("visible-notifications.json")
        do {
            var visible=(try? JSONDecoder().decode([String:[String:String]].self,from:Data(contentsOf:url))) ?? [:]
            update(&visible)
            try JSONEncoder().encode(visible).write(to:url,options:.atomic)
        } catch { NSLog("StudioPatch test notifications: %@",error.localizedDescription) }
    }
    @MainActor private static func notify(identifier:String,title:String,body:String) {
        notificationsCleared=false
        let deliveryID=identifier+"."+UUID().uuidString
        let previous=notificationIDs.updateValue(deliveryID,forKey:identifier) ?? identifier
        if ProcessInfo.processInfo.environment["STUDIOPATCH_TEST_DIRECTORY"] != nil {
            let value=["id":identifier,"title":title,"body":body]
            let url=directory.appendingPathComponent("notifications.jsonl")
            do {
                var data=(try? Data(contentsOf:url)) ?? Data()
                data.append(try JSONSerialization.data(withJSONObject:value));data.append(0x0a)
                try data.write(to:url,options:.atomic)
                updateTestNotifications { visible in
                    visible.removeValue(forKey:previous);visible[deliveryID]=value
                }
            } catch { NSLog("StudioPatch test notification: %@",error.localizedDescription) }
            return
        }
        let center=UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers:[previous])
        center.removeDeliveredNotifications(withIdentifiers:[previous])
        Task {
            let logger=Logger(subsystem:"se.studiopatch.app",category:"notifications")
            do {
                let settings=await center.notificationSettings()
                var granted=settings.authorizationStatus == .authorized
                if settings.authorizationStatus == .notDetermined {
                    // The launch agent has its own authorization identity on macOS.
                    granted=try await center.requestAuthorization(options:[.alert,.sound])
                }
                guard granted, notificationIDs[identifier] == deliveryID else { return }
                let content=UNMutableNotificationContent();content.title=title;content.body=body
                try await center.add(UNNotificationRequest(identifier:deliveryID,content:content,trigger:nil))
                if notificationIDs[identifier] != deliveryID {
                    center.removePendingNotificationRequests(withIdentifiers:[deliveryID])
                    center.removeDeliveredNotifications(withIdentifiers:[deliveryID])
                } else { logger.notice("Notification accepted: \(identifier,privacy:.public)") }
            } catch { logger.error("Notification failed: \(String(describing:error),privacy:.public)") }
        }
    }

    // A restart replaces the running service process; only launchd can do that.
    static func launch(restart:Bool=false) throws {
        let agent=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/se.studiopatch.runtime.plist")
        if FileManager.default.fileExists(atPath:agent.path) {
            func launchctl(_ arguments:[String]) throws -> Int32 {
                let task=Process(); task.executableURL=URL(fileURLWithPath:"/bin/launchctl")
                task.arguments=arguments
                task.standardOutput=FileHandle.nullDevice; task.standardError=FileHandle.nullDevice
                try task.run(); task.waitUntilExit(); return task.terminationStatus
            }
            let domain="gui/\(getuid())",job="\(domain)/se.studiopatch.runtime"
            let kickstart=restart ? ["kickstart","-k",job] : ["kickstart",job]
            if try launchctl(kickstart) == 0 { return }
            // A configured service must stay owned by launchd. Falling back to
            // Process.run here leaves an orphan that bootout cannot stop and
            // may run a different app build than the configured service.
            _ = try launchctl(["bootstrap",domain,agent.path])
            if try launchctl(kickstart) == 0 { return }
            throw NSError(domain:"StudioPatch",code:23,userInfo:[NSLocalizedDescriptionKey:
                "The registered background service could not start. Reinstall its launch agent from the matching StudioPatch package."])
        }
        guard !restart else {
            throw NSError(domain:"StudioPatch",code:24,userInfo:[NSLocalizedDescriptionKey:
                "Restarting needs the registered background service. Install it with Scripts/install-service.sh."])
        }
        let executable=Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/StudioPatchService")
        let process=Process(); process.executableURL=executable
        process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
        try process.run()
    }
    static func read() throws -> RuntimeSnapshot {
        let snapshot=try JSONDecoder().decode(RuntimeSnapshot.self,from:Data(contentsOf:status))
        guard Date().timeIntervalSince(snapshot.date)<12 else {
            throw NSError(domain:"StudioPatch",code:20,userInfo:[NSLocalizedDescriptionKey:"The background engine is not responding. Audio status is unknown."])
        }
        return snapshot
    }
    static func write(_ snapshot:RuntimeSnapshot) {
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try JSONEncoder().encode(snapshot).write(to:status,options:.atomic)
        } catch { NSLog("StudioPatch status: %@",error.localizedDescription) }
    }
}
