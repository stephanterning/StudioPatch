import AppKit
import SwiftUI

extension RuntimeHealth {
    var statusColor: Color {
        switch self {
        case .healthy: return .green
        case .warning: return .orange
        case .error: return .red
        case .idle: return .gray
        }
    }
}

enum MenuBarSettings {
    static let domain="se.studiopatch.app"
    static let helperIdentifier="se.studiopatch.menubar"
    static let preferencesNotification=Notification.Name("se.studiopatch.menu-preferences")
    static let statusNotification=Notification.Name("se.studiopatch.panel-status")
    static func preferencesChanged() {
        DistributedNotificationCenter.default().postNotificationName(preferencesNotification,object:domain,userInfo:nil,deliverImmediately:true)
    }
    static func publishStatus(health:RuntimeHealth,message:String) {
        DistributedNotificationCenter.default().postNotificationName(statusNotification,object:domain,
            userInfo:["health":health.rawValue,"message":message,"pid":ProcessInfo.processInfo.processIdentifier],deliverImmediately:true)
    }
}

enum MenuBarLogo {
    static let statusDotFrame=NSRect(x:19,y:6.75,width:4.5,height:4.5)
    static func image(monochrome:Bool) -> NSImage {
        // The two cable paths from the app logo, without its background tile.
        // Reserve the trailing space for the separately colored status dot.
        let image=NSImage(size:NSSize(width:statusDotFrame.maxX,height:18),flipped:false) { _ in
            let transform=NSAffineTransform(); transform.translateX(by:0,yBy:1); transform.scale(by:0.16); transform.concat()
            (monochrome ? NSColor.black : NSColor(srgbRed:0,green:0.83,blue:0.90,alpha:1)).set()
            let cables=NSBezierPath()
            cables.lineWidth=10; cables.lineCapStyle = .round; cables.lineJoinStyle = .round
            cables.move(to:NSPoint(x:17,y:83)); cables.line(to:NSPoint(x:64,y:83))
            cables.curve(to:NSPoint(x:82,y:65),controlPoint1:NSPoint(x:78,y:83),controlPoint2:NSPoint(x:82,y:79))
            cables.line(to:NSPoint(x:82,y:39))
            cables.move(to:NSPoint(x:11,y:31)); cables.line(to:NSPoint(x:11,y:55))
            cables.curve(to:NSPoint(x:18,y:62),controlPoint1:NSPoint(x:11,y:61),controlPoint2:NSPoint(x:12,y:62))
            cables.line(to:NSPoint(x:37,y:62))
            cables.curve(to:NSPoint(x:51,y:46),controlPoint1:NSPoint(x:50,y:62),controlPoint2:NSPoint(x:51,y:58))
            cables.line(to:NSPoint(x:51,y:24))
            cables.curve(to:NSPoint(x:64,y:11),controlPoint1:NSPoint(x:51,y:12),controlPoint2:NSPoint(x:53,y:11))
            cables.line(to:NSPoint(x:72,y:11)); cables.stroke()
            for rect in [NSRect(x:6,y:73,width:22,height:22),NSRect(x:71,y:28,width:22,height:22),
                         NSRect(x:0,y:20,width:22,height:22),NSRect(x:61,y:0,width:22,height:22)] {
                NSBezierPath(roundedRect:rect,xRadius:4,yRadius:4).fill()
            }
            return true
        }
        image.isTemplate=monochrome
        return image
    }
}

final class StatusDotView: NSView {
    var color:NSColor = .gray { didSet { needsDisplay=true } }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect:NSRect) {
        guard let button=superview as? NSStatusBarButton,
              let imageFrame=button.cell?.imageRect(forBounds:button.bounds) else { return }
        let dot=NSBezierPath(ovalIn:MenuBarLogo.statusDotFrame.offsetBy(dx:imageFrame.minX,dy:imageFrame.minY))
        color.setFill(); dot.fill()
    }
}

@MainActor final class MenuBarController {
    private(set) var statusItem: NSStatusItem?
    private let statusDot=StatusDotView()
    private let statusMessage=NSMenuItem(title:"Audio status unknown",action:nil,keyEquivalent:"")
    private let openPanel: () -> Void
    private let openSettings: () -> Void
    private let restartAudio: () -> Void

    init(openPanel:@escaping () -> Void,openSettings:@escaping () -> Void,restartAudio:@escaping () -> Void) {
        self.openPanel=openPanel; self.openSettings=openSettings; self.restartAudio=restartAudio
    }
    func start(monochrome:Bool) {
        guard statusItem == nil else { return }
        let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        statusItem=item
        let menu=NSMenu()
        menu.autoenablesItems=false
        statusMessage.isEnabled=false; menu.addItem(statusMessage); menu.addItem(.separator())
        menu.addItem(action("Open StudioPatch",#selector(showPanel)))
        menu.addItem(action("Settings…",#selector(showSettings)))
        menu.addItem(.separator()); menu.addItem(action("Restart Audio Service",#selector(restartService)))
        item.menu=menu
        if let button=item.button {
            button.image=MenuBarLogo.image(monochrome:monochrome)
            statusDot.frame=button.bounds; statusDot.autoresizingMask=[.width,.height]
            statusDot.setAccessibilityElement(false); button.addSubview(statusDot)
        }
    }
    func stop() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem=nil; statusDot.removeFromSuperview()
    }
    func setMonochrome(_ monochrome:Bool) { statusItem?.button?.image=MenuBarLogo.image(monochrome:monochrome) }
    func update(health:RuntimeHealth,message:String) {
        statusDot.color=NSColor(health.statusColor)
        statusMessage.title=message; statusMessage.toolTip=message
        let description="StudioPatch — \(health.rawValue): \(message)"
        statusItem?.button?.toolTip=description
        statusItem?.button?.setAccessibilityLabel(description)
    }
    private func action(_ title:String,_ selector:Selector) -> NSMenuItem {
        let item=NSMenuItem(title:title,action:selector,keyEquivalent:""); item.target=self; return item
    }
    @objc private func showPanel() { openPanel() }
    @objc private func showSettings() { openSettings() }
    @objc private func restartService() { restartAudio() }
}

// While the panel is open, mirror its presentation, including local UI warnings.
// Once it quits or stops publishing, the service snapshot remains authoritative.
@MainActor final class MenuBarStatusReader {
    private let read: () throws -> RuntimeSnapshot
    private let panelIsRunning: (Int32) -> Bool
    private let now: () -> Date
    private var panelStatus: (pid:Int32,health:RuntimeHealth,message:String,date:Date)?
    init(read:@escaping () throws -> RuntimeSnapshot = RuntimeConnection.read,
         panelIsRunning:@escaping (Int32) -> Bool = { pid in
             NSRunningApplication.runningApplications(withBundleIdentifier:MenuBarSettings.domain).contains { $0.processIdentifier == pid }
         }, now:@escaping () -> Date = Date.init) {
        self.read=read; self.panelIsRunning=panelIsRunning; self.now=now
    }
    func receivePanelStatus(_ info:[AnyHashable:Any]) {
        guard let raw=info["health"] as? String,let health=RuntimeHealth(rawValue:raw),
              let message=info["message"] as? String,let pid=info["pid"] as? Int32,
              panelIsRunning(pid) else { return }
        panelStatus=(pid,health,message,now())
    }
    func current() -> (health:RuntimeHealth,message:String) {
        if let panelStatus,now().timeIntervalSince(panelStatus.date)<3,panelIsRunning(panelStatus.pid) {
            return (panelStatus.health,panelStatus.message)
        }
        do { let snapshot=try read(); return (snapshot.health,snapshot.message) }
        catch { return (.error,error.localizedDescription) }
    }
}
