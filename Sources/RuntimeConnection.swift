import Foundation
import UserNotifications
import AVFoundation
import os

struct RuntimeSnapshot: Codable {
    var date = Date()
    var devices: [Device]
    var installed: Bool
    var running: Bool
    var message: String
    var rate: Int
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
    static func notifyFailure(_ message:String) {
        notify(identifier:"runtime-failure",title:"StudioPatch: audio is muted",body:message)
    }
    static func notifyFormat(_ format:String, failure:String? = nil) {
        notify(identifier:failure == nil ? "format-changed" : "format-failed",
               title:failure == nil ? "StudioPatch: audio format changed" : "StudioPatch: audio format change failed",
               body:failure.map { "Attempted to set \(format). \($0) Audio is muted; StudioPatch will retry automatically." }
                    ?? "\(format). Routing is active.")
    }
    private static func notify(identifier:String,title:String,body:String) {
        if ProcessInfo.processInfo.environment["STUDIOPATCH_TEST_DIRECTORY"] != nil {
            // Exercise the actual service decisions without displaying test notifications.
            let url=directory.appendingPathComponent("notifications.jsonl")
            do {
                var data=(try? Data(contentsOf:url)) ?? Data()
                data.append(try JSONSerialization.data(withJSONObject:["id":identifier,"title":title,"body":body]))
                data.append(0x0a)
                try data.write(to:url,options:.atomic)
            } catch { NSLog("StudioPatch test notification: %@",error.localizedDescription) }
            return
        }
        let center=UNUserNotificationCenter.current()
        let submit = {
            let content=UNMutableNotificationContent(); content.title=title; content.body=body
            center.add(UNNotificationRequest(identifier:identifier,content:content,trigger:nil)) { error in
                let logger=Logger(subsystem:"se.studiopatch.app",category:"notifications")
                if let error { logger.error("Delivery failed: \(String(describing:error),privacy:.public)") }
                else { logger.notice("Notification accepted: \(identifier,privacy:.public)") }
            }
        }
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                // The launch agent has its own authorization identity on macOS.
                center.requestAuthorization(options:[.alert,.sound]) { granted,error in
                    if granted { submit() }
                    else { Logger(subsystem:"se.studiopatch.app",category:"notifications").error("Authorization failed: \(String(describing:error),privacy:.public)") }
                }
            } else if settings.authorizationStatus == .authorized { submit() }
        }
    }

    static func launch() throws {
        let agent=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/se.studiopatch.runtime.plist")
        if FileManager.default.fileExists(atPath:agent.path) {
            let kick=Process(); kick.executableURL=URL(fileURLWithPath:"/bin/launchctl")
            kick.arguments=["kickstart","gui/\(getuid())/se.studiopatch.runtime"]
            kick.standardOutput=FileHandle.nullDevice; kick.standardError=FileHandle.nullDevice
            try kick.run(); kick.waitUntilExit()
            if kick.terminationStatus == 0 { return }
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
