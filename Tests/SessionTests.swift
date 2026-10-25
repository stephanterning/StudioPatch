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
        app.preset.setLabel("Vocal microphone",for:labelledPort,direction:.input)
        app.preset.setLabel("Monitor left",for:labelledPort,direction:.output)
        app.preset.setLabel("Synth",for:Port(deviceUID:"zed",channel:9),direction:.input)
        // No save action or quit hook: a fresh Model reads every previous edit.
        let reopened = Model(store:SessionStore(url:url),discoverDevices:false)
        precondition(reopened.preset.inputCount == 2 && reopened.preset.outputCount == 1)
        precondition(reopened.preset.dormantRouteCount == 2)
        precondition(reopened.preset.masterUID == "ufx" && reopened.preset.devices.count == 2)
        precondition(reopened.preset.label(for:labelledPort,direction:.input) == "Vocal microphone")
        precondition(reopened.preset.label(for:labelledPort,direction:.output) == "Monitor left")
        reopened.devices = [Device(id:123,uid:"ufx",name:"Fireface UFX III",inputs:9,outputs:9,sampleRate:96000,aggregate:false,
            inputNames:(1...9).map { "Analog \($0)" },outputNames:(1...9).map { "Analog \($0)" })]
        reopened.openLabels(port:labelledPort,direction:1)
        precondition(!reopened.showingLabels) // Physical names are read-only.
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
        var expectedSlot=app.preset;expectedSlot.virtualDeviceUID=slotsModel.preset.deviceUID
        let expectedSlotEngine=try expectedSlot.encoded(forEngine:true)
        precondition(tryEngineEquals(reopenedSlots.presetSlots[0].configuration,expectedSlotEngine))
        try reopenedSlots.loadSlot(slotID)
        precondition((try? reopenedSlots.preset.encoded()) == savedSlot)
        let stableUID=reopenedSlots.preset.deviceUID
        precondition(!reopenedSlots.presetIsModified)
        try reopenedSlots.renameSlot(slotID,name:"Live")
        precondition(reopenedSlots.activePresetTitle=="Live" && reopenedSlots.preset.deviceUID==stableUID && !reopenedSlots.presetIsModified)
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
        precondition(otherID != slotID && reopenedSlots.presetSlots.count==2 && reopenedSlots.preset.deviceUID != stableUID)
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
        computer.preset.outputs = [Playback(deviceUID:"ufx",channel:8,virtualChannel:1),Playback(deviceUID:"ufx",channel:9,virtualChannel:1)]
        precondition(computer.computerName(1,input:true,multiline:true) == "To Computer 1\nUFX III · Analog 9")
        precondition(computer.exposedChannelName(1,input:false) == "UFX III · Analog 8 · UFX III · Analog 9")
        let names=try JSONSerialization.jsonObject(with:Data(computer.channelNamesPayload().utf8)) as! [String:[String]]
        precondition(names["inputs"]?.count == 18 && names["outputs"]?.count == 18)
        precondition(names["inputs"]?[0] == "UFX III · Analog 9")
        computer.rememberDevices()
        _ = try computer.saveSlot(name:"Virtual labels")
        let clean=computer.preset.comparisonData(), sessionBefore=try Data(contentsOf:directory.appendingPathComponent("computer.json"))
        let uid=computer.preset.deviceUID
        let virtual=Device(id:44,uid:uid,name:"StudioPatch",inputs:18,outputs:18,sampleRate:96000,aggregate:false,
                           inputNames:["Changed in Audio MIDI Setup"],outputNames:["Monitors"])
        computer.updateInventory(computer.devices + [virtual])
        precondition(computer.exposedChannelName(1,input:true)=="Changed in Audio MIDI Setup")
        precondition(computer.exposedChannelName(1,input:false)=="Monitors")
        precondition(computer.preset.comparisonData()==clean && !computer.presetIsModified)
        let sessionAfter=try Data(contentsOf:directory.appendingPathComponent("computer.json"))
        precondition(sessionAfter == sessionBefore)
        computer.openComputerLabels(1,input:true)
        precondition(computer.labelSelection==Port(deviceUID:uid,channel:1) && computer.labelDirection==0)
        computer.openComputerLabels(2,input:false) // Unrouted channels are editable too.
        precondition(computer.showingLabels && computer.labelDirection==1)
        precondition(computer.labelEntries.allSatisfy { $0.port.deviceUID == uid })
        var writes:[ChannelLabel]=[]
        computer.labelWriter={ writes.append($0) }
        computer.labelReader={ requested in
            CoreAudioLabels(uid:requested,inputs:requested==uid ? ["Custom"] + Array(repeating:"Automatic",count:17) : Array(repeating:"Automatic",count:18),
                            outputs:Array(repeating:"Automatic",count:18),defaultInputs:Array(repeating:"Automatic",count:18),defaultOutputs:Array(repeating:"Automatic",count:18))
        }
        let copied=try await computer.saveAsNew(name:"Copied",copyLabels:true)
        precondition(computer.preset.activePresetID==copied && computer.preset.deviceUID != uid)
        precondition(writes.count==1 && writes[0].text=="Custom" && writes[0].port.deviceUID==computer.preset.deviceUID)
        precondition(computer.preset.channelLabels==nil && !computer.presetIsModified && computer.pendingLabelCopy==nil)
        let storedNew=try String(contentsOf:directory.appendingPathComponent("computer.json"),encoding:.utf8)
        precondition(!storedNew.contains("Custom") && !storedNew.contains("channelLabels"))
        writes=[]
        _ = try await computer.saveAsNew(name:"Without",copyLabels:false)
        precondition(writes.isEmpty && !computer.presetIsModified)
        // A source read failure must not create a preset or switch identities.
        let beforeFailure=computer.preset.deviceUID, slotCount=computer.presetSlots.count
        computer.labelReader={ _ in throw NSError(domain:"test",code:1) }
        do { _ = try await computer.saveAsNew(name:"Read failure",copyLabels:true);preconditionFailure() } catch {}
        precondition(computer.preset.deviceUID==beforeFailure && computer.presetSlots.count==slotCount)
        // A destination write failure retains the remaining in-memory copy for retry.
        computer.labelReader={ requested in CoreAudioLabels(uid:requested,inputs:["Custom"]+Array(repeating:"Automatic",count:17),outputs:Array(repeating:"Automatic",count:18),defaultInputs:Array(repeating:"Automatic",count:18),defaultOutputs:Array(repeating:"Automatic",count:18)) }
        computer.labelWriter={ _ in throw NSError(domain:"test",code:2) }
        do { _ = try await computer.saveAsNew(name:"Write failure",copyLabels:true);preconditionFailure() } catch {}
        precondition(computer.preset.deviceUID != beforeFailure && computer.presetSlots.count==slotCount+1)
        precondition(computer.pendingLabelCopy?.count==1 && computer.labelNotice.contains("not copied"))
        precondition(!computer.presetIsModified)
        computer.labelWriter={ writes.append($0) }
        computer.retryLabelCopy()
        for _ in 0..<100 where computer.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(computer.pendingLabelCopy==nil && !computer.ioBusy)
        let beforeLabelEdit=computer.preset.comparisonData()
        let target=Port(deviceUID:computer.preset.deviceUID,channel:1)
        computer.editLabel(ChannelLabel(port:target,direction:.input,text:""))
        for _ in 0..<100 where computer.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(writes.last?.text=="" && writes.last?.port==target)
        precondition(computer.preset.comparisonData()==beforeLabelEdit && !computer.presetIsModified)
        precondition(computer.preset.channelLabels==nil)
        // Existing aliases win migration. Fan-out maps one legacy physical label
        // to each exposed virtual channel; never write to that physical port.
        let migrationURL=directory.appendingPathComponent("migration/session.json")
        let migration=Model(store:SessionStore(url:migrationURL),discoverDevices:false)
        migration.devices=reopened.devices
        migration.preset.devices=reopened.preset.devices
        migration.preset.inputs[0]=labelledPort;migration.preset.inputs[1]=labelledPort
        migration.preset.setLabel("Old label",for:labelledPort,direction:.input)
        try migration.restoreActivePreset()
        precondition(migration.preset.deviceUID==Preset.virtualUID)
        let base=try JSONSerialization.jsonObject(with:Data(migration.channelNamesPayload().utf8)) as! [String:[String]]
        var actual=base["inputs"]!;actual[0]="Existing Core Audio label"
        migration.updateInventory(migration.devices+[Device(id:46,uid:migration.preset.deviceUID,name:"StudioPatch",inputs:18,outputs:18,sampleRate:96000,aggregate:false,inputNames:actual,outputNames:base["outputs"]!)])
        migration.labelReader={ uid in CoreAudioLabels(uid:uid,inputs:actual,outputs:base["outputs"]!,defaultInputs:base["inputs"]!,defaultOutputs:base["outputs"]!) }
        var migrated:[ChannelLabel]=[]
        migration.labelWriter={ migrated.append($0) }
        migration.migrateLegacyLabelsIfReady()
        for _ in 0..<100 where migration.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(migration.preset.channelLabels==nil && migration.activeSlot?.configuration.channelLabels==nil)
        precondition(migrated.count==1 && migrated[0].port==Port(deviceUID:Preset.virtualUID,channel:2) && migrated[0].text=="Old label")
        let backup=try String(contentsOf:migrationURL.appendingPathExtension("before-core-audio-labels"),encoding:.utf8)
        precondition(backup.contains("Old label"))
        precondition(reopened.inputPorts[8].1=="UFX III · Analog 9") // Legacy labels do not rename hardware.
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
        precondition(offline.inputPorts[1].1 == "Offline test card · Line")
        precondition(offline.outputPorts[2].1 == "Offline test card · Send")
        precondition(offline.computerLabel(1,input:true) == "Offline test card · Line")
        precondition(offline.computerLabel(2,input:false) == "Offline test card · Send")
        let relaunched=Model(store:SessionStore(url:offlineURL),discoverDevices:false)
        precondition(relaunched.inputPorts.count == 4 && relaunched.outputPorts.count == 3)
        precondition(relaunched.selected[0].id == 0 && relaunched.selected[0].name == card.name)
        precondition(relaunched.preset.inputs[17] == input)
        let presetCopy=try JSONDecoder().decode(Preset.self,from:Data(relaunched.preset.encoded().utf8))
        precondition(presetCopy.knownDevices?.first?.inputNames == card.inputNames)
        // Replacing an unavailable source affects only the chosen destination.
        let replacement=Model(store:SessionStore(url:directory.appendingPathComponent("replacement.json")),discoverDevices:false)
        replacement.preset=presetCopy
        let liveCard=Device(id:26,uid:"live-card",name:"Live card",inputs:1,outputs:1,sampleRate:96000,aggregate:false,
                            inputNames:["Mic"],outputNames:["Monitor"])
        replacement.updateInventory([liveCard]); replacement.requestToggle(liveCard)
        let liveInput=Port(deviceUID:liveCard.uid,channel:1)
        replacement.setInput(0,port:liveInput)
        precondition(replacement.preset.inputs[0] == liveInput && replacement.preset.inputs[17] == input)
        precondition(replacement.preset.outputs == presetCopy.outputs)
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
        precondition(!matrix.canEdit(row:0,column:0)) // Existing unavailable route stays locked.
        precondition(!matrix.canEdit(row:0,column:1)) // No new route to missing destination.
        precondition(!matrix.canEdit(row:1,column:0)) // Clicking the unavailable source cannot remove its route.
        precondition(matrix.canEdit(row:1,column:1)) // A live source can replace it on the same destination row.
        matrix.update(rows:["Online"],columns:["Online"],selected:[0],enabled:true,onClick:{_,_ in})
        precondition(matrix.canEdit(row:0,column:0)) // Available routes can still be toggled off.
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

// Test fixtures for the old serialized format; production has no label mutator.
extension Preset {
    mutating func setLabel(_ text: String, for port: Port, direction: PortDirection) {
        guard port.deviceUID != Self.virtualUID else { return }
        var labels = channelLabels ?? []
        labels.removeAll { $0.port == port && $0.direction == direction }
        if !text.isEmpty { labels.append(ChannelLabel(port:port,direction:direction,text:text)) }
        channelLabels = labels.isEmpty ? nil : labels
    }
}
