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
        // No save action or quit hook: a fresh Model reads every previous edit.
        let reopened = Model(store:SessionStore(url:url),discoverDevices:false)
        precondition(reopened.preset.inputCount == 2 && reopened.preset.outputCount == 1)
        precondition(reopened.preset.dormantRouteCount == 2)
        precondition(reopened.preset.masterUID == "ufx" && reopened.preset.devices.count == 2)
        reopened.devices = [Device(id:123,uid:"ufx",name:"Fireface UFX III",inputs:9,outputs:9,sampleRate:96000,aggregate:false,
            inputNames:(1...9).map { "Analog \($0)" },outputNames:(1...9).map { "Analog \($0)" })]
        reopened.openLabels(port:labelledPort,direction:1)
        precondition(reopened.showingLabels && reopened.labelDirection == 3)
        precondition(reopened.labelEntries.allSatisfy { $0.direction == .output && $0.port.deviceUID == "ufx" })
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
        let libraryURL=slotsURL.deletingLastPathComponent().appendingPathComponent("presets.json")
        let libraryBefore=try Data(contentsOf:libraryURL)
        let reopenedSlots=Model(store:SessionStore(url:slotsURL),discoverDevices:false)
        try reopenedSlots.restoreActivePreset()
        let libraryAfter=try Data(contentsOf:libraryURL)
        precondition(libraryAfter==libraryBefore && reopenedSlots.preset.deviceUID==slotsModel.preset.deviceUID)
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
        let freshURL=directory.appendingPathComponent("fresh/session.json")
        let fresh=Model(store:SessionStore(url:freshURL),discoverDevices:false)
        fresh.labelReader={ _ in preconditionFailure("Restoring a preset must not read labels") }
        fresh.labelWriter={ _ in preconditionFailure("Restoring a preset must not write labels") }
        try fresh.restoreActivePreset()
        let freshID=fresh.preset.activePresetID!
        precondition(fresh.preset.deviceUID==Preset.uid(for:freshID) && !fresh.presetIsModified)
        let freshReopened=Model(store:SessionStore(url:freshURL),discoverDevices:false)
        try freshReopened.restoreActivePreset()
        precondition(freshReopened.preset.activePresetID==freshID && freshReopened.preset.deviceUID==fresh.preset.deviceUID)
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
        precondition(!computer.presetIsModified && computer.pendingLabelCopy==nil)
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
        // Interface aliases persist independently of presets and never change audio configuration.
        let sourcesURL=directory.appendingPathComponent("sources/session.json")
        let sources=Model(store:SessionStore(url:sourcesURL),discoverDevices:false)
        sources.updateInventory(reopened.devices)
        sources.preset.devices=[Member(uid:"ufx",drift:false)]
        sources.preset.inputCount=2; sources.preset.outputCount=1; sources.resize()
        sources.preset.inputs[0]=labelledPort; sources.preset.inputs[1]=labelledPort
        sources.rememberDevices()
        let sourceSlot=try sources.saveSlot(name:"Source A")
        let sourceSession=try Data(contentsOf:sourcesURL), sourceConfig=try sources.preset.encoded(forEngine:true)
        let sourceNames=try sources.channelNamesPayload()
        sources.labelWriter={ _ in preconditionFailure("Editing a source alias must not write to Core Audio") }
        sources.openLabels(port:labelledPort,direction:0)
        precondition(sources.showingLabels && sources.labelDirection == 2)
        let staleInputEntry=sources.labelEntries.first { $0.port == labelledPort }!
        sources.editLabel(ChannelLabel(port:labelledPort,direction:.input,text:"Sång 🎤"))
        // The field's binding may still hold this pre-save row when its draft is removed.
        precondition(staleInputEntry.name != "Sång 🎤" && sources.currentLabelName(staleInputEntry) == "Sång 🎤")
        precondition(sources.inputSourceLabel(labelledPort)=="Sång 🎤" && !sources.presetIsModified)
        precondition((try? Data(contentsOf:sourcesURL)) == sourceSession)
        precondition(tryEngineEquals(sources.preset,sourceConfig) && (try? sources.channelNamesPayload()) == sourceNames)
        _ = try sources.saveSlot(name:"Source B")
        precondition(sources.inputSourceLabel(labelledPort)=="Sång 🎤")
        try sources.loadSlot(sourceSlot)
        precondition(sources.inputSourceLabel(labelledPort)=="Sång 🎤" && !sources.presetIsModified)
        let sourceReopened=Model(store:SessionStore(url:sourcesURL),discoverDevices:false)
        precondition(sourceReopened.inputSourceLabel(labelledPort)=="Sång 🎤")
        precondition(sourceReopened.inputSourceLabel(Port(deviceUID:"ufx",channel:7))=="UFX III · Analog 7")
        sources.updateInventory([])
        precondition(sources.inputSourceLabel(labelledPort)=="Sång 🎤" && sources.inputLabelStatus(0) == .unavailable)
        sources.updateInventory(reopened.devices)
        let sourceUID=sources.preset.deviceUID
        func sourceDevice(_ names:[String]) -> Device {
            Device(id:55,uid:sourceUID,name:"StudioPatch",inputs:2,outputs:1,sampleRate:96000,aggregate:false,inputNames:names,outputNames:["Out"])
        }
        sources.updateInventory(reopened.devices + [sourceDevice(["Sång 🎤","Old"])])
        precondition(sources.inputLabelStatus(0) == .matched && sources.inputLabelStatus(1) == .mismatch)
        var sourceWrites:[ChannelLabel]=[]
        var sourceReadback=["Sång 🎤","Old"]
        sources.labelWriter={ label in
            sourceWrites.append(label)
            // A successful setter alone must not make the label green.
            precondition(sources.inputLabelStatus(1) == .updating)
        }
        sources.labelReader={ uid in
            try await Task.sleep(nanoseconds:10_000_000)
            return CoreAudioLabels(uid:uid,inputs:sourceReadback,outputs:["Out"],defaultInputs:["Auto 1","Auto 2"],defaultOutputs:["Out"])
        }
        sources.updateInputLabel(1)
        sources.updateInputLabel(1) // Repeated clicks cannot queue a second write.
        precondition(sources.inputLabelStatus(1) == .updating)
        for _ in 0..<100 where sources.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(sourceWrites.count == 1 && sources.inputLabelStatus(1) == .mismatch && !sources.error.isEmpty)
        precondition(sourceWrites[0].port == Port(deviceUID:sourceUID,channel:2) && sourceWrites[0].text == "Sång 🎤")
        sourceReadback=["Sång 🎤","Sång 🎤"]
        sources.updateInputLabel(1)
        for _ in 0..<100 where sources.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(sources.inputLabelStatus(0) == .matched && sources.inputLabelStatus(1) == .matched)
        precondition(!sources.presetIsModified && tryEngineEquals(sources.preset,sourceConfig))
        // External changes and clearing a source alias both recompute the comparison.
        sources.updateInventory(reopened.devices + [sourceDevice(["Sång 🎤","External"])])
        precondition(sources.inputLabelStatus(1) == .mismatch)
        sources.editLabel(ChannelLabel(port:labelledPort,direction:.input,text:""))
        precondition(sources.inputSourceLabel(labelledPort)=="UFX III · Analog 9" && sourceWrites.count == 2)
        precondition(sources.inputLabelStatus(0) == .mismatch)
        sourceReadback=["Sång 🎤","UFX III · Analog 9"]
        sources.updateInputLabel(1)
        for _ in 0..<100 where sources.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(sourceWrites.last?.text == "UFX III · Analog 9" && sources.inputLabelStatus(1) == .matched)
        // Failed setters and readbacks cannot manufacture a matching label.
        sources.labelWriter={ _ in throw NSError(domain:"test",code:3) }
        sources.updateInputLabel(0)
        for _ in 0..<100 where sources.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(sources.inputLabelStatus(0) == .mismatch && sources.updatingLabel == nil)
        sources.labelWriter={ sourceWrites.append($0) }
        sources.labelReader={ _ in throw NSError(domain:"test",code:4) }
        sources.updateInputLabel(0)
        for _ in 0..<100 where sources.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(sources.inputLabelStatus(0) == .mismatch)
        let writesBeforeRouteChange=sourceWrites.count
        sources.updateInputLabel(0)
        sources.preset.inputs[0]=Port(deviceUID:"ufx",channel:7)
        for _ in 0..<100 where sources.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(sourceWrites.count == writesBeforeRouteChange) // Captured source checked before asynchronous write.
        sources.preset.inputs[0]=labelledPort
        sources.labelReader={ _ in
            sources.preset.virtualDeviceUID="se.studiopatch.preset.changed"
            return CoreAudioLabels(uid:sourceUID,inputs:["Wrong","Wrong"],outputs:["Out"],defaultInputs:[],defaultOutputs:[])
        }
        sources.updateInputLabel(0)
        for _ in 0..<100 where sources.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(sources.devices.first(where: { $0.uid == sourceUID })?.inputNames[0] == "Sång 🎤")
        precondition(sources.inputLabelStatus(0) == .unavailable)
        // Corrupt source storage is preserved and a failed save leaves the displayed alias intact.
        let sourceFile=sourcesURL.deletingLastPathComponent().appendingPathComponent("source-labels.json")
        let corruptLabels=Data("broken labels".utf8)
        try corruptLabels.write(to:sourceFile)
        var savedSource=true
        sources.editLabel(ChannelLabel(port:labelledPort,direction:.input,text:"Not saved")) { savedSource=$0 }
        precondition(!savedSource && sources.sourceLabels[ChannelLabelKey(port:labelledPort,direction:.input)] == nil)
        precondition((try? Data(contentsOf:sourceFile)) == corruptLabels)
        let corruptSourceModel=Model(store:SessionStore(url:sourcesURL),discoverDevices:false)
        precondition(corruptSourceModel.error.contains("Could not load interface labels"))
        // Physical outputs use a separate direction key, including the same UID/channel as an input.
        let outputsURL=directory.appendingPathComponent("outputs/session.json")
        let outputs=Model(store:SessionStore(url:outputsURL),discoverDevices:false)
        outputs.updateInventory(reopened.devices)
        outputs.preset.devices=[Member(uid:"ufx",drift:false)]
        outputs.preset.inputCount=1; outputs.preset.outputCount=2; outputs.resize()
        let monitor=Port(deviceUID:"ufx",channel:9), cue=Port(deviceUID:"ufx",channel:8), other=Port(deviceUID:"ufx",channel:7)
        outputs.preset.inputs[0]=monitor
        outputs.setOutput(monitor,channel:1); outputs.setOutput(cue,channel:1); outputs.setOutput(other,channel:2)
        outputs.rememberDevices()
        let outputSlot=try outputs.saveSlot(name:"Output A")
        let outputConfig=try outputs.preset.encoded(forEngine:true), outputNames=try outputs.channelNamesPayload()
        let outputSession=try Data(contentsOf:outputsURL)
        outputs.labelWriter={ _ in preconditionFailure("Interface labels must not write to Core Audio") }
        outputs.editLabel(ChannelLabel(port:monitor,direction:.input,text:"Microphone"))
        outputs.labelDirection=3
        let staleOutputEntry=outputs.labelEntries.first { $0.port == monitor }!
        outputs.editLabel(ChannelLabel(port:monitor,direction:.output,text:"Monitor L"))
        precondition(staleOutputEntry.name != "Monitor L" && outputs.currentLabelName(staleOutputEntry) == "Monitor L")
        outputs.editLabel(ChannelLabel(port:cue,direction:.output,text:"Cue L"))
        precondition(outputs.inputSourceLabel(monitor) == "Microphone" && outputs.outputDestinationLabel(monitor) == "Monitor L")
        precondition((try? Data(contentsOf:outputsURL)) == outputSession && !outputs.presetIsModified)
        precondition(tryEngineEquals(outputs.preset,outputConfig) && (try? outputs.channelNamesPayload()) == outputNames)
        _ = try outputs.saveSlot(name:"Output B")
        precondition(outputs.outputDestinationLabel(monitor) == "Monitor L")
        try outputs.loadSlot(outputSlot)
        let outputsReopened=Model(store:SessionStore(url:outputsURL),discoverDevices:false)
        precondition(outputsReopened.outputDestinationLabel(monitor) == "Monitor L")
        precondition(outputsReopened.inputSourceLabel(monitor) == "Microphone")
        precondition(outputsReopened.outputDestinationLabel(other) == "UFX III · Analog 7")
        outputs.updateInventory([])
        precondition(outputs.outputDestinationLabel(monitor) == "Monitor L" && outputs.outputLabelStatus(monitor) == .unavailable)
        let outputUID=outputs.preset.deviceUID
        let outputDevice=Device(id:56,uid:outputUID,name:"StudioPatch",inputs:1,outputs:2,sampleRate:96000,aggregate:false,
                                inputNames:["Microphone"],outputNames:["Old monitor","UFX III · Analog 7"])
        outputs.updateInventory(reopened.devices + [outputDevice])
        precondition(outputs.outputLabelStatus(monitor) == .mismatch && outputs.outputLabelStatus(cue) == .mismatch)
        precondition(outputs.outputLabelStatus(other) == .matched)
        var outputWrites:[ChannelLabel]=[], readbackOutputs=outputDevice.outputNames
        outputs.labelWriter={ label in
            outputWrites.append(label)
            precondition(label.direction == .output && label.port == Port(deviceUID:outputUID,channel:1))
            precondition(outputs.outputLabelStatus(monitor) == .updating && outputs.outputLabelStatus(cue) == .updating)
            readbackOutputs[label.port.channel-1]=label.text
        }
        outputs.labelReader={ uid in CoreAudioLabels(uid:uid,inputs:["Microphone"],outputs:readbackOutputs,
                                                   defaultInputs:["Input"],defaultOutputs:["Output 1","Output 2"]) }
        outputs.updateOutputLabel(monitor); outputs.updateOutputLabel(cue)
        for _ in 0..<100 where outputs.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(outputWrites.count == 1 && outputWrites[0].text == "Monitor L")
        precondition(outputs.outputLabelStatus(monitor) == .matched && outputs.outputLabelStatus(cue) == .mismatch)
        precondition(outputs.outputLabelStatus(other) == .matched && outputs.inputLabelStatus(0) == .matched)
        outputs.updateOutputLabel(cue)
        for _ in 0..<100 where outputs.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(outputWrites.count == 2 && outputWrites[1].text == "Cue L")
        precondition(outputs.outputLabelStatus(monitor) == .mismatch && outputs.outputLabelStatus(cue) == .matched)
        precondition(!outputs.presetIsModified && tryEngineEquals(outputs.preset,outputConfig))
        outputs.editLabel(ChannelLabel(port:monitor,direction:.output,text:""))
        precondition(outputs.outputDestinationLabel(monitor) == "UFX III · Analog 9" && outputs.inputSourceLabel(monitor) == "Microphone")
        outputs.editLabel(ChannelLabel(port:monitor,direction:.output,text:"UFX III · Analog 9"))
        precondition(outputs.sourceLabels[ChannelLabelKey(port:monitor,direction:.output)] == nil)
        let renamedHardware=Device(id:321,uid:"ufx",name:"Fireface UFX III",inputs:9,outputs:9,sampleRate:96000,aggregate:false,
                                   inputNames:reopened.devices[0].inputNames,outputNames:(1...9).map { "Output \($0)" })
        outputs.updateInventory([renamedHardware,outputDevice])
        precondition(outputs.outputDestinationLabel(monitor) == "UFX III · Output 9" && outputs.inputSourceLabel(monitor) == "Microphone")
        outputs.updateInventory(reopened.devices + [outputDevice])
        precondition(outputWrites.count == 2)
        outputs.updateOutputLabel(monitor)
        for _ in 0..<100 where outputs.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(outputWrites.last?.text == "UFX III · Analog 9" && outputs.outputLabelStatus(monitor) == .matched)
        // A moved/disconnected/dormant output must not write to the captured old From Computer channel.
        let outputWritesBefore=outputWrites.count
        outputs.updateOutputLabel(cue)
        outputs.setOutput(cue,channel:2)
        for _ in 0..<100 where outputs.ioBusy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(outputWrites.count == outputWritesBefore)
        outputs.preset.outputCount=1
        precondition(outputs.outputLabelStatus(cue) == .unavailable)
        outputs.updateOutputLabel(cue)
        precondition(!outputs.ioBusy && outputWrites.count == outputWritesBefore)
        outputs.setOutput(monitor,channel:0)
        precondition(outputs.outputLabelStatus(monitor) == .unavailable && outputs.outputSourceChannel(monitor) == nil)
        let outputRegistry=Model(store:SessionStore(url:outputsURL),discoverDevices:false)
        precondition(outputRegistry.inputSourceLabel(monitor) == "Microphone" && outputRegistry.outputDestinationLabel(cue) == "Cue L")
        // Copying the Core Audio side changes only the selected physical alias.
        let bidirectionalURL=directory.appendingPathComponent("bidirectional/session.json")
        let bidirectional=Model(store:SessionStore(url:bidirectionalURL),discoverDevices:false)
        bidirectional.updateInventory(reopened.devices)
        bidirectional.preset.devices=[Member(uid:"ufx",drift:false)]
        bidirectional.preset.inputCount=2; bidirectional.preset.outputCount=2; bidirectional.resize()
        bidirectional.preset.inputs[0]=monitor; bidirectional.preset.inputs[1]=monitor
        bidirectional.setOutput(monitor,channel:1); bidirectional.setOutput(cue,channel:1)
        let bidirectionalDevice=Device(id:57,uid:bidirectional.preset.deviceUID,name:"StudioPatch",inputs:2,outputs:2,
                                      sampleRate:96000,aggregate:false,inputNames:["Capture A","Capture B"],outputNames:["Playback A","Playback B"])
        bidirectional.updateInventory(reopened.devices + [bidirectionalDevice])
        bidirectional.labelWriter={ _ in preconditionFailure("Reverse copy must not write Core Audio") }
        let bidirectionalConfig=try bidirectional.preset.encoded(forEngine:true)
        bidirectional.updateInputLabel(0,from:.destination)
        precondition(bidirectional.inputSourceLabel(monitor) == "Capture A")
        precondition(bidirectional.inputLabelStatus(0) == .matched && bidirectional.inputLabelStatus(1) == .mismatch)
        bidirectional.updateInputLabel(1,from:.destination)
        precondition(bidirectional.inputSourceLabel(monitor) == "Capture B")
        precondition(bidirectional.inputLabelStatus(0) == .mismatch && bidirectional.inputLabelStatus(1) == .matched)
        bidirectional.updateOutputLabel(monitor,from:.source)
        precondition(bidirectional.outputDestinationLabel(monitor) == "Playback A")
        precondition(bidirectional.outputLabelStatus(monitor) == .matched && bidirectional.outputLabelStatus(cue) == .mismatch)
        precondition(bidirectional.outputDestinationLabel(cue) == "UFX III · Analog 8")
        precondition(bidirectional.inputSourceLabel(monitor) == "Capture B")
        let bidirectionalReopened=Model(store:SessionStore(url:bidirectionalURL),discoverDevices:false)
        precondition(bidirectionalReopened.inputSourceLabel(monitor) == "Capture B" && bidirectionalReopened.outputDestinationLabel(monitor) == "Playback A")
        precondition(bidirectional.virtualDevice == bidirectionalDevice && tryEngineEquals(bidirectional.preset,bidirectionalConfig))
        bidirectional.ioBusy=true
        bidirectional.updateInputLabel(0,from:.destination)
        bidirectional.updateOutputLabel(cue,from:.source)
        precondition(bidirectional.inputSourceLabel(monitor) == "Capture B" && bidirectional.outputLabelStatus(cue) == .mismatch)
        bidirectional.ioBusy=false
        bidirectional.setOutput(cue,channel:0)
        bidirectional.updateOutputLabel(cue,from:.source)
        precondition(bidirectional.outputDestinationLabel(cue) == "UFX III · Analog 8")
        bidirectional.updateInventory([])
        bidirectional.updateInputLabel(0,from:.destination)
        precondition(bidirectional.inputSourceLabel(monitor) == "Capture B")
        bidirectional.updateInventory(reopened.devices + [bidirectionalDevice])
        let bidirectionalRegistry=bidirectionalURL.deletingLastPathComponent().appendingPathComponent("source-labels.json")
        try Data("broken".utf8).write(to:bidirectionalRegistry)
        bidirectional.updateInputLabel(0,from:.destination)
        precondition(!bidirectional.error.isEmpty && bidirectional.inputSourceLabel(monitor) == "Capture B")
        precondition((try? Data(contentsOf:bidirectionalRegistry)) == Data("broken".utf8))
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
        // Both orange second lines are clickable, including after vertical scrolling.
        matrix.update(rows:(0..<100).map { "To Computer \($0+1)\nCapture" },columns:["UFX III · Analog 9\nSång"],
                      selected:Set(0..<100),enabled:true,showsInputLabels:true,
                      rowLabelStatuses:(0..<100).map { $0 == 10 ? .mismatch : .matched },onClick:{_,_ in})
        matrix.layoutSubtreeIfNeeded()
        matrix.scroll.contentView.scroll(to:NSPoint(x:0,y:320))
        precondition(matrix.syncLabelRow(at:NSPoint(x:matrix.rowWidth+14,y:20)) == 10)
        precondition(matrix.syncLabelRow(at:NSPoint(x:matrix.rowWidth+14,y:5)) == nil)
        precondition(matrix.syncLabelRow(at:NSPoint(x:matrix.rowWidth+14,y:52)) == nil)
        precondition(matrix.syncLabelRow(at:NSPoint(x:matrix.frozenWidth-2,y:20)) == nil)
        precondition(matrix.syncLabelRow(at:NSPoint(x:14,y:20)) == 10)
        precondition(matrix.syncLabelRow(at:NSPoint(x:14,y:5)) == nil)
        precondition(matrix.labelColor(row:10,side:.source) == .systemOrange && matrix.labelColor(row:10,side:.destination) == .systemOrange)
        matrix.enabled=false
        precondition(matrix.syncLabelRow(at:NSPoint(x:matrix.rowWidth+14,y:20)) == nil)
        matrix.update(rows:["UFX III · Analog 9\nMonitor L","UFX III · Analog 8\nCue L","Unconnected\nSpare"],
                      columns:["From Computer 1\nMonitor L"],selected:[0,1],enabled:true,
                      rowLabelStatuses:[.matched,.mismatch,.unavailable],onClick:{_,_ in})
        matrix.layoutSubtreeIfNeeded()
        matrix.scroll.contentView.scroll(to:.zero)
        precondition(matrix.sourceText(forRow:0) == "From Computer 1\nMonitor L")
        precondition(matrix.sourceText(forRow:1) == "From Computer 1\nMonitor L")
        precondition(matrix.sourceText(forRow:2) == nil)
        precondition(matrix.syncLabelRow(at:NSPoint(x:14,y:52)) == 1)
        precondition(matrix.syncLabelRow(at:NSPoint(x:14,y:37)) == nil) // The hardware name still opens the editor.
        precondition(matrix.syncLabelRow(at:NSPoint(x:14,y:20)) == nil) // Matching Destination label is not actionable.
        precondition(matrix.syncLabelRow(at:NSPoint(x:matrix.rowWidth+14,y:52)) == 1) // Clicking Core Audio copies to this hardware alias.
        precondition(matrix.syncLabelRow(at:NSPoint(x:matrix.rowWidth+14,y:20)) == nil)
        precondition(matrix.labelColor(row:1,side:.source) == .systemOrange && matrix.labelColor(row:1,side:.destination) == .systemOrange)
        precondition(matrix.syncLabelRect(2,side:.destination) == nil) // No pair on an unconnected row.
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
