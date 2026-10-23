import Foundation
import AppKit

@main struct SessionTests {
    static func tryEngineEquals(_ preset: Preset, _ expected: String) -> Bool { (try? preset.encoded(forEngine:true)) == expected }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StudioPatch-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("last-session.json")
        let app = Model(store:SessionStore(url:url),discoverDevices:false)
        app.preset.inputCount = 37
        app.preset.outputCount = 21
        app.resize()
        app.preset.inputs[36] = Port(deviceUID:"ufx",channel:9)
        app.preset.outputs = [Playback(deviceUID:"zed",channel:7,virtualChannel:21)]
        app.preset.inputCount = 2
        app.preset.outputCount = 1
        app.preset.masterUID = "ufx"
        app.preset.devices = [Member(uid:"ufx",drift:false),Member(uid:"zed",drift:false)]
        let labelledPort = Port(deviceUID:"ufx",channel:9)
        app.preset.setLabel("Sångmikrofon",for:labelledPort,direction:.input)
        app.preset.setLabel("Monitor vänster",for:labelledPort,direction:.output)
        app.preset.setLabel("Synth",for:Port(deviceUID:"zed",channel:9),direction:.input)
        // No save action or quit hook: a fresh Model reads every previous edit.
        let reopened = Model(store:SessionStore(url:url),discoverDevices:false)
        precondition(reopened.preset.inputCount == 2 && reopened.preset.outputCount == 1)
        precondition(reopened.preset.dormantRouteCount == 2)
        precondition(reopened.preset.masterUID == "ufx" && reopened.preset.devices.count == 2)
        precondition(reopened.preset.label(for:labelledPort,direction:.input) == "Sångmikrofon")
        precondition(reopened.preset.label(for:labelledPort,direction:.output) == "Monitor vänster")
        reopened.devices = [Device(id:123,uid:"ufx",name:"Fireface UFX III",inputs:9,outputs:9,sampleRate:96000,aggregate:false,
            inputNames:(1...9).map { "Analog \($0)" },outputNames:(1...9).map { "Analog \($0)" })]
        reopened.openLabels(port:labelledPort,direction:1)
        precondition(reopened.showingLabels && reopened.labelSelection == labelledPort)
        precondition(reopened.labelEntries[8].port == labelledPort && reopened.labelEntries[8].direction == .output)
        // Named slots are durable snapshots, independent of the working session.
        let slotsURL=directory.appendingPathComponent("library-test/session.json")
        let slotsModel=Model(store:SessionStore(url:slotsURL),discoverDevices:false)
        slotsModel.preset=app.preset
        slotsModel.openPresets()
        let slotID=try slotsModel.saveSlot(name:"  Studio  ")
        precondition(slotsModel.preset.activePresetID==slotID && !slotsModel.presetIsModified)
        let savedSlot=try slotsModel.preset.encoded()
        slotsModel.preset.inputCount=1
        slotsModel.preset.deviceDisplayOrder=["zed","ufx"]
        let reopenedSlots=Model(store:SessionStore(url:slotsURL),discoverDevices:false)
        try reopenedSlots.restoreActivePreset()
        precondition(reopenedSlots.preset.activePresetID==slotID && reopenedSlots.presetIsModified)
        precondition(reopenedSlots.preset.inputCount==1 && reopenedSlots.activePresetTitle=="Studio *")
        reopenedSlots.openPresets()
        precondition(reopenedSlots.presetSlots.count==1 && reopenedSlots.presetSlots[0].name=="Studio")
        let expectedSlotEngine=try app.preset.encoded(forEngine:true)
        precondition(tryEngineEquals(reopenedSlots.presetSlots[0].configuration,expectedSlotEngine))
        try reopenedSlots.loadSlot(slotID)
        precondition((try? reopenedSlots.preset.encoded()) == savedSlot)
        precondition(!reopenedSlots.presetIsModified)
        try reopenedSlots.renameSlot(slotID,name:"Live")
        precondition(reopenedSlots.activePresetTitle=="Live")
        reopenedSlots.preset.inputCount=5; reopenedSlots.preset.resizeChannels()
        let sameID=try reopenedSlots.saveSlot(name:"Live",replacing:slotID)
        precondition(sameID==slotID && reopenedSlots.presetSlots.count==1)
        precondition(!reopenedSlots.presetIsModified)
        reopenedSlots.preset.outputCount=3
        precondition(reopenedSlots.presetIsModified)
        reopenedSlots.saveActivePreset()
        precondition(!reopenedSlots.presetIsModified)
        var blockedActiveDelete=false
        do { try reopenedSlots.deleteSlot(slotID) } catch { blockedActiveDelete=true }
        precondition(blockedActiveDelete)
        let otherID=try reopenedSlots.saveSlot(name:"Backup")
        precondition(otherID != slotID && reopenedSlots.presetSlots.count==2)
        let currentBeforeDelete=try reopenedSlots.preset.encoded()
        try reopenedSlots.deleteSlot(slotID)
        precondition((try? reopenedSlots.preset.encoded()) == currentBeforeDelete)
        let stored=try PresetLibraryStore(url:slotsURL.deletingLastPathComponent().appendingPathComponent("presets.json")).load()
        precondition(stored.count==1 && stored[0].id==otherID && stored[0].configuration.inputCount==5)
        let orderURL=directory.appendingPathComponent("order.json")
        let ordered=Model(store:SessionStore(url:orderURL),discoverDevices:false)
        ordered.devices=[
            Device(id:1,uid:"a",name:"A",inputs:1,outputs:1,sampleRate:96000,aggregate:false,inputNames:["In"],outputNames:["Out"]),
            Device(id:2,uid:"b",name:"B",inputs:1,outputs:1,sampleRate:96000,aggregate:false,inputNames:["In"],outputNames:["Out"])]
        ordered.preset.devices=[Member(uid:"a",drift:false),Member(uid:"b",drift:false)]
        ordered.preset.inputs[0]=Port(deviceUID:"a",channel:1)
        ordered.preset.outputs=[Playback(deviceUID:"b",channel:1,virtualChannel:1)]
        ordered.rememberDevices()
        let engineBefore=try ordered.preset.encoded(forEngine:true)
        ordered.moveDisplayDevice("b",by:-1)
        precondition(ordered.inputPorts.map { $0.0.deviceUID } == ["b","a"])
        precondition(ordered.outputPorts.map { $0.0.deviceUID } == ["b","a"])
        precondition(tryEngineEquals(ordered.preset,engineBefore))
        let orderReloaded=Model(store:SessionStore(url:orderURL),discoverDevices:false)
        precondition(orderReloaded.displayDevices.map(\.uid) == ["b","a"])
        ordered.updateInventory(Array(ordered.devices.prefix(1)))
        precondition(ordered.displayDevices.map(\.uid) == ["b","a"])
        precondition(ordered.inputPorts.first?.0.deviceUID == "b")
        ordered.moveDisplayDevice("b",by:-1) // Boundary is a no-op.
        precondition(tryEngineEquals(ordered.preset,engineBefore))
        let computer = Model(store:SessionStore(url:directory.appendingPathComponent("computer.json")),discoverDevices:false)
        computer.devices = reopened.devices
        computer.preset.devices = reopened.preset.devices
        computer.preset.inputs[0] = labelledPort
        computer.preset.setLabel("Sång",for:labelledPort,direction:.input)
        computer.preset.outputs = [Playback(deviceUID:"ufx",channel:8,virtualChannel:1),Playback(deviceUID:"ufx",channel:9,virtualChannel:1)]
        computer.preset.setLabel("Monitor L",for:Port(deviceUID:"ufx",channel:8),direction:.output)
        computer.preset.setLabel("Monitor R",for:labelledPort,direction:.output)
        precondition(computer.computerName(1,input:true,multiline:true) == "To Computer 1\nSång")
        precondition(computer.computerName(1,input:false,multiline:true) == "From Computer 1\nMonitor L · Monitor R")
        precondition(computer.computerName(2,input:true) == "To Computer 2")
        precondition(computer.exposedChannelName(1,input:true) == "Sång")
        precondition(computer.exposedChannelName(1,input:false) == "Monitor L · Monitor R")
        precondition(computer.exposedChannelName(2,input:true) == "To Computer 2")
        let names=try JSONSerialization.jsonObject(with:Data(computer.channelNamesPayload().utf8)) as! [String:[String]]
        precondition(names["inputs"]?.count == 18 && names["outputs"]?.count == 18)
        precondition(names["inputs"]?[0] == "Sång" && names["outputs"]?[0] == "Monitor L · Monitor R")

        // Legacy computer labels are ignored, and new ones cannot be set.
        let virtualPort=Port(deviceUID:Preset.virtualUID,channel:1)
        computer.preset.channelLabels?.append(ChannelLabel(port:virtualPort,direction:.input,text:"Old computer label"))
        computer.preset.setLabel("New computer label",for:virtualPort,direction:.input)
        precondition(computer.preset.label(for:virtualPort,direction:.input).isEmpty)
        precondition(computer.computerName(1,input:true) == "To Computer 1 — Sång")
        computer.openComputerLabels(1,input:true)
        precondition(computer.labelSelection == labelledPort && computer.labelDirection == 0)
        precondition(computer.labelEntries.allSatisfy { $0.port.deviceUID != Preset.virtualUID })
        computer.openComputerLabels(1,input:false)
        precondition(computer.labelSelection == Port(deviceUID:"ufx",channel:8) && computer.labelDirection == 1)
        computer.showingLabels=false
        computer.openComputerLabels(2,input:true)
        precondition(!computer.showingLabels)
        computer.preset.inputCount=0; computer.preset.outputCount=0
        precondition(computer.computerPorts(1,input:true).isEmpty && computer.computerPorts(1,input:false).isEmpty)
        computer.preset.inputCount=18; computer.preset.outputCount=18
        precondition(computer.computerName(1,input:true) == "To Computer 1 — Sång")
        computer.preset.setLabel("Ny sång",for:labelledPort,direction:.input)
        precondition(computer.computerName(1,input:true) == "To Computer 1 — Ny sång")
        computer.preset.setLabel("",for:labelledPort,direction:.input)
        precondition(computer.computerName(1,input:true) == "To Computer 1 — UFX III · Analog 9")
        computer.preset.inputs[0]=nil; computer.preset.outputs=[]
        precondition(computer.computerName(1,input:true) == "To Computer 1")
        precondition(computer.computerName(1,input:false) == "From Computer 1")
        precondition(reopened.preset.label(for:Port(deviceUID:"zed",channel:9),direction:.input) == "Synth")
        let exported = try JSONDecoder().decode(Preset.self,from:Data(reopened.preset.encoded().utf8))
        precondition(exported.label(for:labelledPort,direction:.input) == "Sångmikrofon")
        precondition(reopened.inputPorts[8].1 == "UFX III · Analog 9 — Sångmikrofon")
        precondition(reopened.outputPorts[8].1 == "UFX III · Analog 9 — Monitor vänster")
        reopened.preset.setLabel("",for:labelledPort,direction:.input)
        precondition(reopened.inputPorts[8].1 == "UFX III · Analog 9")
        precondition(reopened.preset.label(for:labelledPort,direction:.output) == "Monitor vänster")
        reopened.preset.inputCount = 37; reopened.preset.outputCount = 21
        precondition(reopened.preset.activeInputs[36] == Port(deviceUID:"ufx",channel:9))
        precondition(reopened.preset.activeOutputs[0].virtualChannel == 21)
        // Deselecting routed hardware needs confirmation, including dormant routes.
        let device=reopened.devices[0]
        reopened.preset.inputCount=2
        reopened.requestToggle(device)
        precondition(reopened.pendingRemoval?.uid == device.uid)
        precondition(reopened.preset.devices.contains { $0.uid == device.uid })
        precondition(reopened.preset.inputs[36]?.deviceUID == device.uid)
        reopened.pendingRemoval=nil // Cancel leaves every route intact.
        precondition(reopened.preset.inputs[36]?.deviceUID == device.uid)
        reopened.requestToggle(device)
        reopened.confirmRemoval()
        precondition(!reopened.preset.devices.contains { $0.uid == device.uid })
        precondition(reopened.preset.inputs[36] == nil)
        precondition(reopened.preset.outputs.count == 1) // Other card is untouched.
        reopened.requestToggle(device) // Selecting does not need confirmation.
        precondition(reopened.pendingRemoval == nil)
        reopened.requestToggle(device) // Unrouted card deselects immediately.
        precondition(reopened.pendingRemoval == nil && !reopened.preset.devices.contains { $0.uid == device.uid })
        reopened.preset.inputs[36]=Port(deviceUID:"ufx",channel:9)
        // Empty device selection and 0/0 are legitimate editing state.
        reopened.preset.devices = []
        reopened.preset.inputCount = 0; reopened.preset.outputCount = 0
        let empty = Model(store:SessionStore(url:url),discoverDevices:false)
        precondition(empty.preset.devices.isEmpty && empty.preset.inputCount == 0 && empty.preset.outputCount == 0)
        var rejected = false
        do { try empty.preset.validate() } catch { rejected = true }
        precondition(rejected) // Still forbidden as an engine configuration.
        // A rapid increase is durable even before UI resize() runs.
        empty.preset.inputCount = 128
        let grown = try SessionStore(url:url).load()!
        precondition(grown.inputs.count == 128 && grown.inputs[36]?.channel == 9)
        // Preserve corrupt data for recovery; surface load/write errors.
        let bad = Data("broken json".utf8)
        try bad.write(to:url)
        let recovery = Model(store:SessionStore(url:url),discoverDevices:false)
        precondition(recovery.saveStatus.contains("Could not load"))
        let preserved = try Data(contentsOf:url)
        precondition(preserved == bad)
        recovery.preset.inputCount = 8
        let backups = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasPrefix("unreadable-session-") }
        precondition(backups.count == 1)
        let backedUp = try Data(contentsOf:backups[0])
        precondition(backedUp == bad)
        let restored = try SessionStore(url:url).load()!
        precondition(restored.inputCount == 8)
        let impossible = Model(store:SessionStore(url:url.appendingPathComponent("child.json")),discoverDevices:false)
        impossible.preset.inputCount = 7
        precondition(impossible.saveStatus.contains("Could not save"))
        // Cache the full layout, including channels with no routes, across disconnect/relaunch.
        let offlineURL=directory.appendingPathComponent("offline.json")
        let offline=Model(store:SessionStore(url:offlineURL),discoverDevices:false)
        let card=Device(id:25,uid:"offline-card",name:"Offline test card",inputs:4,outputs:3,sampleRate:96000,aggregate:false,
                        inputNames:["Mic", "Line", "ADAT 1", "ADAT 2"],outputNames:["Monitor L", "Monitor R", "Send"])
        offline.updateInventory([card])
        offline.requestToggle(card)
        let input=Port(deviceUID:card.uid,channel:2), output=Port(deviceUID:card.uid,channel:3)
        offline.preset.setLabel("Synth",for:input,direction:.input)
        offline.preset.setLabel("Echo",for:output,direction:.output)
        offline.setInput(0,port:input); offline.setOutput(output,channel:2)
        offline.preset.inputs[17]=input // Dormant routes are retained too.
        offline.preset.inputCount=2
        offline.updateInventory([])
        precondition(offline.missingDevices.count == 1 && offline.listedHardware[0].name == card.name)
        precondition(offline.inputPorts.count == 4 && offline.outputPorts.count == 3)
        precondition(offline.inputPorts[1].1 == "Offline test card · Line — Synth")
        precondition(offline.outputPorts[2].1 == "Offline test card · Send — Echo")
        precondition(offline.computerLabel(1,input:true) == "Synth")
        precondition(offline.computerLabel(2,input:false) == "Echo")
        let relaunched=Model(store:SessionStore(url:offlineURL),discoverDevices:false)
        precondition(relaunched.inputPorts.count == 4 && relaunched.outputPorts.count == 3)
        precondition(relaunched.selected[0].id == 0 && relaunched.selected[0].name == card.name)
        precondition(relaunched.preset.inputs[17] == input)
        let presetCopy=try JSONDecoder().decode(Preset.self,from:Data(relaunched.preset.encoded().utf8))
        precondition(presetCopy.knownDevices?.first?.inputNames == card.inputNames)
        relaunched.setInput(1,port:input); relaunched.setOutput(output,channel:3)
        precondition(relaunched.preset.inputs[1] == nil && relaunched.preset.outputs[0].virtualChannel == 2)
        relaunched.setInput(0,port:nil); relaunched.setOutput(output,channel:0)
        relaunched.setInput(0,port:input); relaunched.setOutput(output,channel:2)
        precondition(relaunched.preset.inputs[0] == nil && relaunched.preset.outputs.isEmpty)
        relaunched.requestToggle(relaunched.selected[0])
        precondition(relaunched.pendingRemoval?.name == card.name) // Dormant route triggers warning offline.
        relaunched.pendingRemoval=nil
        precondition(relaunched.preset.inputs[17] == input)
        let returned=Device(id:99,uid:card.uid,name:card.name,inputs:4,outputs:3,sampleRate:96000,aggregate:false,
                            inputNames:card.inputNames,outputNames:card.outputNames)
        relaunched.updateInventory([returned])
        precondition(relaunched.missingDevices.isEmpty && relaunched.selected[0].id == 99 && relaunched.listedHardware.count == 1)
        relaunched.setInput(0,port:input); relaunched.setOutput(output,channel:2)
        precondition(relaunched.preset.inputs[0] == input && relaunched.preset.outputs.count == 1)
        relaunched.updateInventory([])
        relaunched.requestToggle(relaunched.selected[0]); relaunched.confirmRemoval()
        precondition(relaunched.selected.isEmpty && relaunched.listedHardware.isEmpty)
        precondition(relaunched.preset.inputs[17] == nil && relaunched.preset.outputs.isEmpty)
        // Hover and header hit testing use document coordinates after scrolling.
        let matrix=FrozenMatrixView()
        matrix.frame=NSRect(x:0,y:0,width:900,height:500)
        matrix.update(rows:(0..<100).map {"Row \($0)"},columns:(0..<100).map {"Col \($0)"},
                      selected:[0],enabled:true,onClick:{_,_ in preconditionFailure("Hover must not route")})
        matrix.layoutSubtreeIfNeeded()
        matrix.scroll.contentView.scroll(to:NSPoint(x:160,y:320))
        precondition(matrix.headerIndex(row:true,at:NSPoint(x:12,y:16)) == 10)
        precondition(matrix.headerIndex(row:false,at:NSPoint(x:16,y:12)) == 5)
        matrix.setHover(at:NSPoint(x:176,y:336))
        precondition(matrix.hoveredRow == 10 && matrix.hoveredColumn == 5)
        precondition(matrix.selected == [0])
        matrix.setHover(at:NSPoint(x:-1,y:336))
        precondition(matrix.hoveredRow == nil && matrix.hoveredColumn == nil)
        matrix.setHover(at:NSPoint(x:4000,y:4000))
        precondition(matrix.hoveredRow == nil)
        matrix.update(rows:["Offline", "Online"],columns:["Offline", "Online"],selected:[0,2],enabled:true,
                      unavailableRows:[0],unavailableColumns:[0],onClick:{_,_ in})
        precondition(matrix.canEdit(row:0,column:0)) // Existing route can be removed.
        precondition(!matrix.canEdit(row:0,column:1)) // No new route to missing destination.
        precondition(matrix.canEdit(row:1,column:0)) // Existing route from missing source can be removed.
        precondition(matrix.canEdit(row:1,column:1)) // Live ports remain editable.
        matrix.update(rows:["Offline", "Online"],columns:["Offline", "Online"],selected:[],enabled:true,
                      unavailableRows:[0],unavailableColumns:[0],onClick:{_,_ in})
        precondition(!matrix.canEdit(row:0,column:0) && !matrix.canEdit(row:1,column:0))
        // A blocked native inventory must leave MainActor responsive and must
        // not accumulate requests from Refresh or periodic polling.
        let gate=DispatchSemaphore(value:0)
        let entered=DispatchSemaphore(value:0)
        let probe=Model(store:SessionStore(url:directory.appendingPathComponent("async.json")),discoverDevices:false,inventoryReader:{
            entered.signal()
            _ = gate.wait(timeout:.now()+8)
            return strdup("{\"devices\":[],\"driverInstalled\":false,\"driverConfig\":\"\"}")
        })
        probe.refresh()
        precondition(probe.ioBusy && !probe.inventoryKnown)
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(entered.wait(timeout:.now()) == .success)
        probe.refresh(); probe.poll(); probe.poll()
        precondition(entered.wait(timeout:.now()) == .timedOut)
        precondition(probe.ioBusy && !probe.inventoryKnown)
        gate.signal()
        for _ in 0..<100 where probe.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(!probe.ioBusy && probe.inventoryKnown && !probe.installed)
        // Routine polling retains serialization without inserting a status row.
        probe.poll(); probe.poll()
        precondition(probe.ioBusy && probe.ioStatus.isEmpty)
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(entered.wait(timeout:.now()) == .success)
        probe.poll()
        precondition(entered.wait(timeout:.now()) == .timedOut)
        gate.signal()
        for _ in 0..<100 where probe.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(!probe.ioBusy && probe.ioStatus.isEmpty)
        print("PASS: actual Model autosave/reopen, dormant routes, empty edits, growth, corrupt backup and write failure")
    }
}
