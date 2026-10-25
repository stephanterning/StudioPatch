import SwiftUI
import CoreAudio

@MainActor final class Model: ObservableObject {
    @Published var devices: [Device] = []
    @Published var preset = Preset() { didSet { autosave() } }
    @Published var installed = false
    @Published var inventoryKnown = false
    @Published var ioBusy = false
    @Published var ioStatus = ""
    private let inventoryReader: ()->UnsafeMutablePointer<CChar>?
    private var chooseInitialDevices = false
    private func beginIO(_ text:String, quiet:Bool = false) -> Task<Void,Never> {
        ioBusy=true; ioStatus=quiet ? "" : text
        return Task { [weak self] in
            do { try await Task.sleep(nanoseconds:5_000_000_000) } catch { return }
            self?.ioStatus="Core Audio has not responded yet. Waiting before sending further audio requests."
        }
    }
    private func endIO(_ watchdog:Task<Void,Never>) {
        watchdog.cancel(); ioBusy=false; ioStatus=""
    }
    private func performIO(_ text:String, quiet:Bool = false, _ work:@escaping @MainActor () async throws -> Void) {
        guard !ioBusy else { return }
        let watchdog=beginIO(text,quiet:quiet)
        Task {
            defer { endIO(watchdog) }
            do { try await work() } catch { self.error=error.localizedDescription }
        }
    }
    @Published var running = false
    @Published var message = "Audio latency has not been measured yet"
    @Published var error = ""
    @Published var tab = 0
    @Published var showingPresets = false
    @Published var presetSlots: [PresetSlot] = []
    @Published var showingLabels = false
    @Published var showingTools = false
    @Published var showingDeviceOrder = false
    @Published var labelDirection = 0
    @Published var labelSelection: Port?
    @Published var pendingRemoval: Device?
    @Published var saveStatus = ""
    private let sessionStore: SessionStore
    private let sourceLabelStore: SourceLabelStore
    @Published private(set) var sourceLabels: [ChannelLabelKey:String] = [:]
    @Published private(set) var updatingLabel: ChannelLabelKey?
    private var autosaveReady = false
    private var timer: Timer?
    private var inventoryTicks=0
    private var liveRuntime=false
    private var statusObserver: DirectoryObserver?
    var labelReader: (String) async throws -> CoreAudioLabels = CoreAudioLabels.read
    var labelWriter: (ChannelLabel) async throws -> Void = CoreAudioLabels.write
    @Published var pendingLabelCopy: [ChannelLabel]? = nil
    @Published var labelNotice = ""
    private var copyUID: String?
    var virtualDevice: Device? { devices.first { $0.uid == preset.deviceUID } }

    @Published private var runtimeLatencyDiagnostics: String?
    var interfaceTimingText: String {
        guard let raw=runtimeLatencyDiagnostics,let data=raw.data(using:.utf8),
              let timing=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let members=timing["devices"] as? [[String:Any]] else{return ""}
        return members.filter{$0["master"] as? Bool != true}.map { member in
            let id=(member["deviceID"] as? NSNumber)?.uint32Value ?? 0
            let name=devices.first{$0.id==id}?.shortName ?? "Secondary"
            let input=(member["inputSkewFrames"] as? NSNumber)?.intValue ?? 0
            let output=(member["outputSkewFrames"] as? NSNumber)?.intValue ?? 0
            return "\(name): input +\(input), output +\(output) samples relative to Sync Source" + (member["mutedClockFault"] as? Bool == true ? " · MUTED: clock alignment lost" : "")
        }.joined(separator:"\n")
    }
    var softwareMarginText: String {
        guard running, let raw=runtimeLatencyDiagnostics, let data=raw.data(using:.utf8),
              let values=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let input=values["inputPadding"] as? Double, let output=values["outputPadding"] as? Double,
              let rate=values["rate"] as? Double, rate>0 else { return "Software margin: waiting for engine status" }
        return String(format:"Software margin: %.3f ms input · %.3f ms output",input*1000/rate,output*1000/rate)
    }
    private var loadingRuntime=false

    var hardware: [Device] { devices.filter { !$0.aggregate && !$0.uid.hasPrefix("se.studiopatch.") } }
    func isAvailable(_ uid: String) -> Bool { hardware.contains { $0.uid == uid } }
    var selected: [Device] { preset.devices.map { member in
        if let live=hardware.first(where: { $0.uid == member.uid }) { return live }
        if let known=preset.knownDevices?.first(where: { $0.uid == member.uid }) {
            return Device(id:0,uid:known.uid,name:known.name,inputs:known.inputNames.count,outputs:known.outputNames.count,
                          sampleRate:known.sampleRate,aggregate:false,inputNames:known.inputNames,outputNames:known.outputNames)
        }
        // Old presets may never have seen this device. Do not invent last-known metadata.
        return Device(id:0,uid:member.uid,name:member.uid,inputs:0,outputs:0,sampleRate:0,aggregate:false,inputNames:[],outputNames:[])
    } }
    var displayDevices: [Device] {
        let selectedDevices = selected
        let order = preset.deviceDisplayOrder ?? []
        return selectedDevices.enumerated().sorted { a,b in
            let ai = order.firstIndex(of:a.element.uid) ?? (order.count+a.offset)
            let bi = order.firstIndex(of:b.element.uid) ?? (order.count+b.offset)
            return ai < bi
        }.map(\.element)
    }
    func moveDisplayDevice(_ uid: String, by offset: Int) {
        var order = displayDevices.map(\.uid)
        guard let index = order.firstIndex(of:uid), order.indices.contains(index+offset) else { return }
        order.swapAt(index,index+offset)
        // Keep preferences for devices temporarily removed from the selection.
        preset.deviceDisplayOrder = order + (preset.deviceDisplayOrder ?? []).filter { !order.contains($0) }
    }
    var missingDevices: [Device] { selected.filter { !isAvailable($0.uid) } }
    var listedHardware: [Device] { hardware + missingDevices }
    func rememberDevices() {
        var known=preset.knownDevices ?? []
        for device in hardware where preset.devices.contains(where: { $0.uid == device.uid }) {
            known.removeAll { $0.uid == device.uid }
            known.append(device.snapshot)
        }
        known.sort { $0.uid < $1.uid }
        if known != (preset.knownDevices ?? []) { preset.knownDevices=known }
    }
    func updateInventory(_ found: [Device]) {
        rememberDevices()
        if devices != found { devices=found }
        rememberDevices()
    }
    func canConnect(_ port: Port, input: Bool) -> Bool {
        guard preset.devices.contains(where: { $0.uid == port.deviceUID }),
              let device=hardware.first(where: { $0.uid == port.deviceUID }) else { return false }
        return port.channel > 0 && port.channel <= (input ? device.inputs : device.outputs)
    }
    func setInput(_ index: Int, port: Port?) {
        guard preset.activeInputs.indices.contains(index) else { return }
        guard port == nil || canConnect(port!,input:true) else { return }
        preset.inputs[index]=port
    }
    func setOutput(_ port: Port, channel: Int) {
        guard channel == 0 || (channel > 0 && channel <= preset.outputCount && canConnect(port,input:false)) else { return }
        preset.outputs.removeAll { $0.deviceUID == port.deviceUID && $0.channel == port.channel }
        if channel > 0 { preset.outputs.append(Playback(deviceUID:port.deviceUID,channel:port.channel,virtualChannel:channel)) }
    }
    var inputPorts: [(Port, String)] {
        ports(input:true)
    }
    var outputPorts: [(Port, String)] {
        ports(input:false)
    }
    func ports(input: Bool, displayOrder: Bool = true) -> [(Port, String)] {
        (displayOrder ? displayDevices : selected).flatMap { d in
            d.channelNames(input:input).enumerated().map { index, name in
                let port = Port(deviceUID:d.uid,channel:index+1)
                let original = "\(d.shortName) · \(name)"
                return (port, original)
            }
        }
    }
    func interfaceLabel(_ port:Port, input:Bool) -> String {
        sourceLabels[ChannelLabelKey(port:port,direction:input ? .input : .output)] ??
            ports(input:input).first(where: { $0.0 == port })?.1 ?? "\(port.deviceUID) · \(input ? "Input" : "Output") \(port.channel)"
    }
    func inputSourceLabel(_ port:Port) -> String { interfaceLabel(port,input:true) }
    func outputDestinationLabel(_ port:Port) -> String { interfaceLabel(port,input:false) }
    func outputSourceChannel(_ port:Port) -> Int? {
        preset.activeOutputs.first { $0.deviceUID == port.deviceUID && $0.channel == port.channel }?.virtualChannel
    }
    private func labelStatus(_ port:Port, channel:Int, input:Bool) -> LabelMatchStatus {
        let key=ChannelLabelKey(port:Port(deviceUID:preset.deviceUID,channel:channel),direction:input ? .input : .output)
        if updatingLabel == key { return .updating }
        guard canConnect(port,input:input), let device=virtualDevice else { return .unavailable }
        let names=input ? device.inputNames : device.outputNames
        guard channel > 0, channel <= (input ? device.inputs : device.outputs),
              names.indices.contains(channel-1), !names[channel-1].isEmpty else { return .unavailable }
        return interfaceLabel(port,input:input) == names[channel-1] ? .matched : .mismatch
    }
    func inputLabelStatus(_ row:Int) -> LabelMatchStatus {
        guard preset.activeInputs.indices.contains(row), let port=preset.activeInputs[row] else { return .unavailable }
        return labelStatus(port,channel:row+1,input:true)
    }
    func outputLabelStatus(_ port:Port) -> LabelMatchStatus {
        guard let channel=outputSourceChannel(port) else { return .unavailable }
        return labelStatus(port,channel:channel,input:false)
    }
    func updateInputLabel(_ row:Int, from side:LabelSide = .source) {
        guard inputLabelStatus(row) == .mismatch, let port=preset.activeInputs[row] else { return }
        updateRoutedLabel(port,channel:row+1,input:true,fromHardware:side == .source)
    }
    func updateOutputLabel(_ port:Port, from side:LabelSide = .destination) {
        guard outputLabelStatus(port) == .mismatch, let channel=outputSourceChannel(port) else { return }
        updateRoutedLabel(port,channel:channel,input:false,fromHardware:side == .destination)
    }
    private func updateRoutedLabel(_ port:Port, channel:Int, input:Bool, fromHardware:Bool) {
        guard !ioBusy else { return }
        if !fromHardware {
            // Copy the displayed Core Audio name to this physical channel's shared alias.
            // Other routes using that physical channel recompute their comparisons.
            error=""
            editLabel(ChannelLabel(port:port,direction:input ? .input : .output,
                                   text:exposedChannelName(channel,input:input)))
            return
        }
        let uid=preset.deviceUID, text=interfaceLabel(port,input:input)
        let target=ChannelLabelKey(port:Port(deviceUID:uid,channel:channel),direction:input ? .input : .output)
        updatingLabel=target
        performIO("Updating name in Core Audio…") {
            defer { self.updatingLabel=nil }
            @MainActor func checkRoute() throws {
                let connected=input
                    ? (self.preset.activeInputs.indices.contains(channel-1) && self.preset.activeInputs[channel-1] == port)
                    : self.outputSourceChannel(port) == channel
                guard self.preset.deviceUID == uid, connected, self.interfaceLabel(port,input:input) == text else {
                    throw self.labelError("The preset, routing or label changed. Check the routing and try again.")
                }
            }
            try checkRoute()
            try await self.labelWriter(ChannelLabel(port:target.port,direction:target.direction,text:text))
            let snapshot=try await self.labelReader(uid)
            try checkRoute()
            guard snapshot.uid == uid, snapshot.inputs.count == self.preset.inputCount,
                  snapshot.outputs.count == self.preset.outputCount,
                  let index=self.devices.firstIndex(where: { $0.uid == uid }) else {
                throw self.labelError("Could not verify the updated name in Core Audio. Try again when the device is ready.")
            }
            let device=self.devices[index]
            self.devices[index]=Device(id:device.id,uid:device.uid,name:device.name,inputs:device.inputs,outputs:device.outputs,
                                       sampleRate:device.sampleRate,aggregate:device.aggregate,inputNames:snapshot.inputs,
                                       outputNames:snapshot.outputs,sampleRates:device.sampleRates)
            let names=input ? snapshot.inputs : snapshot.outputs
            guard names[channel-1] == text else { throw self.labelError("Core Audio has not applied the name. Click the orange label to retry.") }
        }
    }
    // Hardware names remain read-only; source aliases are stored separately.
    func computerPorts(_ channel: Int, input: Bool) -> [Port] {
        guard channel > 0, channel <= (input ? preset.inputCount : preset.outputCount) else { return [] }
        let connected: Set<Port>
        if input {
            connected = Set(preset.activeInputs.indices.contains(channel-1) ? [preset.activeInputs[channel-1]].compactMap { $0 } : [])
        } else {
            connected = Set(preset.activeOutputs.filter { $0.virtualChannel == channel }.map { Port(deviceUID:$0.deviceUID,channel:$0.channel) })
        }
        return ports(input:input,displayOrder:false).map(\.0).filter { connected.contains($0) }
    }
    func automaticName(_ channel: Int, input: Bool) -> String {
        let originals=Dictionary(uniqueKeysWithValues:ports(input:input))
        var names:[String]=[]
        for port in computerPorts(channel,input:input) {
            if let name=originals[port], !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? "\(input ? "To Computer" : "From Computer") \(channel)" : names.joined(separator:" · ")
    }
    func computerLabel(_ channel: Int, input: Bool) -> String {
        let name=exposedChannelName(channel,input:input)
        return name == "\(input ? "To Computer" : "From Computer") \(channel)" ? "" : name
    }
    func computerName(_ channel: Int, input: Bool, multiline: Bool = false) -> String {
        let name="\(input ? "To Computer" : "From Computer") \(channel)"
        if multiline { return name + "\n" + exposedChannelName(channel,input:input) }
        let label=computerLabel(channel,input:input)
        return name + (label.isEmpty ? "" : " — " + label)
    }
    func exposedChannelName(_ channel: Int, input: Bool) -> String {
        if let device=virtualDevice {
            let names=device.channelNames(input:input)
            if names.indices.contains(channel-1) { return names[channel-1] }
        }
        return automaticName(channel,input:input)
    }
    func channelNamesPayload() throws -> String { try runtimeChannelNames(preset:preset,devices:selected) }
    func openComputerLabels(_ channel: Int, input: Bool) {
        openLabels(port:Port(deviceUID:preset.deviceUID,channel:channel),direction:input ? 0 : 1)
    }
    func openLabels(port: Port? = nil, direction: Int? = nil) {
        if let port, port.deviceUID != preset.deviceUID {
            let input=(direction ?? tab) == 0
            guard ports(input:input).contains(where: { $0.0 == port }) else { return }
            labelDirection=input ? 2 : 3
        } else { labelDirection=(direction ?? tab) == 0 ? 0 : 1 }
        labelSelection=port
        showingLabels=true
    }
    var labelEntries: [LabelEntry] {
        if labelDirection >= 2 {
            let input=labelDirection == 2
            return ports(input:input).map { LabelEntry(port:$0.0,direction:input ? .input : .output,name:interfaceLabel($0.0,input:input),device:$0.1) }
        }
        let input=labelDirection == 0
        return (0..<(input ? preset.inputCount : preset.outputCount)).map { index in
            LabelEntry(port:Port(deviceUID:preset.deviceUID,channel:index+1),direction:input ? .input : .output,
                       name:exposedChannelName(index+1,input:input),device:"\(input ? "To Computer" : "From Computer") \(index+1)")
        }
    }
    func currentLabelName(_ entry:LabelEntry) -> String {
        let input=entry.direction == .input
        return entry.port.deviceUID == preset.deviceUID
            ? exposedChannelName(entry.port.channel,input:input)
            : interfaceLabel(entry.port,input:input)
    }
    func editLabel(_ label:ChannelLabel, completion:@escaping (Bool)->Void = { _ in }) {
        if label.port.deviceUID != preset.deviceUID {
            do {
                guard let original=ports(input:label.direction == .input).first(where: { $0.0 == label.port })?.1 else {
                    throw labelError("The interface channel is no longer available in this preset.")
                }
                let text=label.text.trimmingCharacters(in:.whitespacesAndNewlines)
                // The field can publish its displayed fallback again after clearing/focus loss.
                // A name equal to the current interface name must remain automatic.
                sourceLabels=try sourceLabelStore.set(ChannelLabel(port:label.port,direction:label.direction,text:text == original ? "" : text))
                completion(true)
            } catch { self.error=error.localizedDescription; completion(false) }
            return
        }
        performIO("Updating label in Core Audio…") {
            guard label.port.deviceUID == self.preset.deviceUID else { throw self.labelError("The preset changed. Reopen the label editor.") }
            do {
                try await self.labelWriter(label)
                if self.liveRuntime { try await self.refreshInventory() }
                completion(true)
            } catch { completion(false);throw error }
        }
    }
    private func labelError(_ text:String) -> NSError { NSError(domain:"StudioPatch",code:34,userInfo:[NSLocalizedDescriptionKey:text]) }
    func saveAsNew(name:String,copyLabels:Bool) async throws -> UUID {
        guard !ioBusy else { throw labelError("An audio operation is still in progress.") }
        let watchdog=beginIO("Creating preset…")
        defer { endIO(watchdog) }
        guard pendingLabelCopy == nil else { throw labelError("Finish or discard the pending label copy before creating another preset.") }
        let sourceUID=preset.deviceUID
        var labels:[ChannelLabel]=[]
        if copyLabels {
            let snapshot=try await labelReader(sourceUID)
            guard snapshot.uid==sourceUID, snapshot.inputs.count==preset.inputCount, snapshot.outputs.count==preset.outputCount else {
                throw labelError("Wait until Core Audio has applied the current channel counts before copying labels.")
            }
            labels=snapshot.overrides
        }
        guard sourceUID == preset.deviceUID else { throw labelError("The preset changed before labels could be read.") }
        let id=try saveSlot(name:name)
        copyUID=preset.deviceUID
        pendingLabelCopy=labels.isEmpty ? nil : labels
        if !labels.isEmpty { try await applyPendingLabels() }
        return id
    }
    func discardLabelCopy() { pendingLabelCopy=nil; copyUID=nil; labelNotice="" }
    func retryLabelCopy() {
        performIO("Copying channel labels…") { try await self.applyPendingLabels() }
    }
    private func applyPendingLabels() async throws {
        guard let labels=pendingLabelCopy, let uid=copyUID, uid == preset.deviceUID else {
            throw labelError("Load the destination preset before retrying its label copy.")
        }
        var ready=false
        for _ in 0..<60 {
            if let snapshot=try? await labelReader(uid), snapshot.uid==uid, snapshot.inputs.count==preset.inputCount, snapshot.outputs.count==preset.outputCount { ready=true;break }
            try await Task.sleep(nanoseconds:250_000_000)
        }
        guard ready else {
            labelNotice="Preset saved. Labels have not been copied: its audio device is unavailable. Retry after the device is ready."
            throw labelError(labelNotice)
        }
        var remaining=labels
        do {
            for var label in labels {
                label.port.deviceUID=uid
                try await labelWriter(label)
                remaining.removeFirst(); pendingLabelCopy=remaining
            }
        } catch {
            pendingLabelCopy=remaining
            labelNotice="Preset saved, but \(remaining.count) labels were not copied. Retry to finish. \(error.localizedDescription)"
            throw labelError(labelNotice)
        }
        pendingLabelCopy=nil;copyUID=nil;labelNotice=""
        if liveRuntime {
            do { try await refreshInventory() }
            catch { self.error="Labels were copied, but the display could not refresh: \(error.localizedDescription)" }
        }
    }
    var masterSampleRates: [Int] {
        let rates=hardware.first(where:{$0.uid==preset.masterUID})?.sampleRates?.map { Int($0) } ?? []
        return Array(Set(rates + [preset.sampleRate])).sorted()
    }
    var rateMismatch: Bool { selected.filter { isAvailable($0.uid) }.contains { Int($0.sampleRate) != preset.sampleRate } }
    init(store: SessionStore = SessionStore(), discoverDevices: Bool = true, inventoryReader:@escaping ()->UnsafeMutablePointer<CChar>? = { SPInventory() }) {
        self.liveRuntime=discoverDevices
        self.inventoryReader=inventoryReader
        sessionStore = store
        sourceLabelStore=SourceLabelStore(url:store.url.deletingLastPathComponent().appendingPathComponent("source-labels.json"))
        do { sourceLabels=try sourceLabelStore.load() }
        catch { self.error="Could not load interface labels: \(error.localizedDescription)" }
        var isNewSession = false
        do {
            if let restored = try store.load() {
                preset = restored
                saveStatus = ""
            } else { isNewSession = true }
        } catch {
            saveStatus = "Could not load the last session: \(error.localizedDescription). The original file is preserved."
        }
        chooseInitialDevices=isNewSession
        autosaveReady = true
        rememberDevices()
        if isNewSession { autosave() }
        if discoverDevices {
            do { try restoreActivePreset() }
            catch { self.error="Could not restore the active preset: \(error.localizedDescription)" }
        }
        guard discoverDevices else { return }
        do { try RuntimeConnection.launch() } catch { message="Could not start the background engine: \(error.localizedDescription)" }
        readRuntime()
        statusObserver=DirectoryObserver(RuntimeConnection.status) { [weak self] in self?.readRuntime() }
        RuntimeConnection.requestNotifications()
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }
    private func autosave() {
        guard autosaveReady, !loadingRuntime else { return }
        do {
            try sessionStore.save(preset)
            saveStatus = ""
        } catch {
            saveStatus = "Could not save automatically: \(error.localizedDescription)"
        }
    }
    func data(_ pointer: UnsafeMutablePointer<CChar>?) throws -> Data {
        guard let pointer else { throw NSError(domain:"StudioPatch",code:2) }
        defer { SPFree(pointer) }
        let raw = Data(String(cString:pointer).utf8)
        if let obj = try JSONSerialization.jsonObject(with:raw) as? [String:Any], let message = obj["error"] as? String {
            throw NSError(domain:"StudioPatch",code:3,userInfo:[NSLocalizedDescriptionKey:message])
        }
        return raw
    }
    func refresh() {
        if liveRuntime { readRuntime(); return }
        performIO("Reading audio devices from Core Audio…") { try await self.refreshInventory() }
    }
    private func refreshInventory() async throws {
        let raw=try await AudioWorker.call(inventoryReader)
        let inv=try JSONDecoder().decode(Inventory.self,from:raw)
        updateInventory(inv.devices); installed=inv.driverInstalled; inventoryKnown=true
        if chooseInitialDevices {
            chooseInitialDevices=false
            preset.devices=hardware.filter { $0.name.contains("UFX") || $0.name.contains("ZED") }.map { Member(uid:$0.uid,drift:false) }
            preset.masterUID=selected.first(where:{$0.name.contains("UFX")})?.uid ?? selected.first?.uid ?? ""
        }
    }
    func requestToggle(_ device: Device) {
        let selected=preset.devices.contains { $0.uid == device.uid }
        let hasRoutes=preset.inputs.contains { $0?.deviceUID == device.uid } || preset.outputs.contains { $0.deviceUID == device.uid }
        if selected && hasRoutes { pendingRemoval=device }
        else { toggle(device) }
    }
    func confirmRemoval() {
        guard let device=pendingRemoval else { return }
        pendingRemoval=nil
        if preset.devices.contains(where: { $0.uid == device.uid }) { toggle(device) }
    }
    private func toggle(_ device: Device) {
        if preset.devices.contains(where:{$0.uid==device.uid}) {
            preset.devices.removeAll {$0.uid==device.uid}
            preset.inputs = preset.inputs.map {$0?.deviceUID==device.uid ? nil : $0}
            preset.outputs.removeAll {$0.deviceUID==device.uid}
        } else { preset.devices.append(Member(uid:device.uid,drift:false)) }
        rememberDevices()
        if !preset.devices.contains(where:{$0.uid==preset.masterUID}) { preset.masterUID=preset.devices.first?.uid ?? "" }
    }
    func resize() { preset.resizeChannels() }
    func payload(forEngine: Bool = true) throws -> String {
        resize()
        return try preset.encoded(forEngine:forEngine)
    }
    func poll() {
        if liveRuntime { readRuntime(); return }
        guard !ioBusy else { return }
        inventoryTicks += 1
        let readInventory=inventoryTicks % 2 == 0
        guard readInventory else { return }
        performIO("Checking audio devices…",quiet:true) { try await self.refreshInventory() }
    }

    private func readRuntime() {
        do {
            let snapshot=try RuntimeConnection.read()
            let previousDevices=preset.knownDevices
            loadingRuntime=true
            updateInventory(snapshot.devices)
            installed=snapshot.installed; inventoryKnown=true; running=snapshot.running
            message=snapshot.message
            runtimeLatencyDiagnostics=snapshot.latencyDiagnostics
            if virtualDevice != nil, (8000...384000).contains(snapshot.rate) { preset.sampleRate=snapshot.rate }
            loadingRuntime=false
            if previousDevices != preset.knownDevices { try sessionStore.save(preset) }
        } catch { message=error.localizedDescription }
    }
    private var libraryStore: PresetLibraryStore {
        PresetLibraryStore(url:sessionStore.url.deletingLastPathComponent().appendingPathComponent("presets.json"))
    }
    var activeSlot: PresetSlot? { presetSlots.first { $0.id == preset.activePresetID } }
    var presetIsModified: Bool {
        guard let activeSlot else { return true }
        return preset.comparisonData() != activeSlot.configuration.comparisonData()
    }
    var activePresetTitle: String { (activeSlot?.name ?? "Current configuration") + (presetIsModified ? " *" : "") }
    func restoreActivePreset() throws {
        presetSlots=try libraryStore.load()
        if let slot=activeSlot {
            preset.virtualDeviceUID=slot.configuration.deviceUID
            preset.virtualDeviceName=slot.configuration.deviceName
        }
        if activeSlot == nil {
            _ = try saveSlot(name:presetSlots.isEmpty ? "Default" : "Current configuration")
        }
    }
    func saveActivePreset() {
        guard let activeSlot else { return }
        do { _ = try saveSlot(name:activeSlot.name,replacing:activeSlot.id) }
        catch { self.error=error.localizedDescription }
    }
    func openPresets() {
        do { presetSlots=try libraryStore.load(); showingPresets=true }
        catch { self.error="Could not read presets: \(error.localizedDescription). The saved library has not been changed." }
    }
    private func commitSlots(_ slots: [PresetSlot]) throws {
        try libraryStore.save(slots)
        presetSlots=slots
    }
    func saveSlot(name: String, replacing id: UUID? = nil) throws -> UUID {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty else { throw NSError(domain:"StudioPatch",code:31,userInfo:[NSLocalizedDescriptionKey:"Enter a preset name."]) }
        var configuration=preset
        let slotID=id ?? UUID()
        configuration.virtualDeviceUID = id.flatMap { selected in presetSlots.first { $0.id == selected }?.configuration.deviceUID } ?? Preset.uid(for:slotID)
        configuration.virtualDeviceName="StudioPatch (\(name))"
        configuration.resizeChannels()
        configuration.activePresetID=nil
        try configuration.validate(forEditing:true)
        var slots=presetSlots
        let slot=PresetSlot(id:slotID,name:name,configuration:configuration,updatedAt:Date())
        if let id {
            guard let index=slots.firstIndex(where:{$0.id==id}) else { throw NSError(domain:"StudioPatch",code:32,userInfo:[NSLocalizedDescriptionKey:"The preset no longer exists."]) }
            slots[index]=slot
        } else { slots.append(slot) }
        try commitSlots(slots)
        configuration.activePresetID=slot.id
        do { try sessionStore.save(configuration) }
        catch { throw labelError("The preset was saved, but could not be activated: \(error.localizedDescription)") }
        loadingRuntime=true; preset=configuration; loadingRuntime=false
        saveStatus=""
        return slot.id
    }
    func renameSlot(_ id: UUID, name: String) throws {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var slots=presetSlots
        guard let index=slots.firstIndex(where:{$0.id==id}) else { return }
        slots[index].name=name
        slots[index].configuration.virtualDeviceName="StudioPatch (\(name))"
        try commitSlots(slots)
        if preset.activePresetID==id { preset.virtualDeviceName=slots[index].configuration.deviceName }
    }
    func deleteSlot(_ id: UUID) throws {
        guard id != preset.activePresetID else {
            throw NSError(domain:"StudioPatch",code:33,userInfo:[NSLocalizedDescriptionKey:"Load another preset before deleting the active preset."])
        }
        try commitSlots(presetSlots.filter {$0.id != id})
    }
    func loadSlot(_ id: UUID) throws {
        guard let slot=presetSlots.first(where:{$0.id==id}) else { return }
        try slot.configuration.validate(forEditing:true)
        // Persist first so a failed write never applies a configuration only to the panel.
        var configuration=slot.configuration
        configuration.activePresetID=slot.id
        try sessionStore.save(configuration)
        preset=configuration
        rememberDevices()
    }
}

struct ContentView: View {
    @ObservedObject var m: Model
    var body: some View {
        HStack(spacing:0) {
            sidebar.frame(width:285)
            Divider()
            VStack(alignment:.leading,spacing:14) {
                HStack(spacing:18) {
                    Text("StudioPatch").font(.system(size:28,weight:.semibold)).fixedSize()
                    HStack(spacing:8) {
                        Circle().fill(m.running ? Color.green : Color.gray).frame(width:7,height:7)
                        Text(m.message).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(2).help(m.message)
                    }
                    .frame(maxWidth:.infinity,alignment:.leading)
                    Text(m.activePresetTitle).lineLimit(1).help(m.activePresetTitle)
                    Button("Save",action:m.saveActivePreset).disabled(m.ioBusy || !m.presetIsModified || m.activeSlot == nil)
                    Button("Presets…",action:m.openPresets).disabled(m.ioBusy)
                }
                HStack {
                    Picker("Direction",selection:$m.tab) { Text("To Computer").tag(0); Text("From Computer").tag(1) }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Button("Device order…") { m.showingDeviceOrder=true }
                    Button("Labels…") { m.openLabels() }
                    Button("Tools") { m.showingTools=true }
                }
                if m.preset.dormantRouteCount > 0 {
                    Text("\(m.preset.dormantRouteCount) saved routes are inactive. They carry no audio and reactivate when the channel count increases.")
                        .font(.caption).foregroundStyle(.orange)
                }
                matrix
                if !m.labelNotice.isEmpty {
                    HStack {
                        Text(m.labelNotice).font(.caption).foregroundStyle(.orange)
                        if m.pendingLabelCopy != nil {
                            Button("Retry label copy",action:m.retryLabelCopy).disabled(m.ioBusy)
                            Button("Discard remaining copy") { m.discardLabelCopy() }.disabled(m.ioBusy)
                        }
                    }
                }
                if !m.ioStatus.isEmpty {
                    Text(m.ioStatus).font(.callout).foregroundStyle(.orange).lineLimit(2)
                }
                if !m.inventoryKnown {
                    Text("Audio device status has not been read yet.").font(.caption).foregroundStyle(.secondary)
                } else if !m.installed {
                    Text("The StudioPatch device is unavailable in Core Audio. Check that the driver is installed and loaded. You can still edit and save routing.")
                        .font(.callout).padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.orange.opacity(0.1),in:RoundedRectangle(cornerRadius:8))
                }
            }.padding(22)
        }
        .frame(minWidth:1050,minHeight:690)
        .preferredColorScheme(.dark)
        .sheet(isPresented:$m.showingPresets) { PresetLibraryEditor(m:m) }
        .sheet(isPresented:$m.showingLabels) { LabelEditor(m:m) }
        .sheet(isPresented:$m.showingTools) { ToolsEditor(m:m) }
        .sheet(isPresented:$m.showingDeviceOrder) { DeviceOrderEditor(m:m) }
        .alert("Remove audio interface?",isPresented:Binding(get:{m.pendingRemoval != nil},set:{if !$0 {m.pendingRemoval=nil}})) {
            Button("Cancel",role:.cancel) { m.pendingRemoval=nil }
            Button("Remove",role:.destructive) { m.confirmRemoval() }
        } message: {
            Text("All routes to and from \(m.pendingRemoval?.name ?? "the audio interface") will be removed, including inactive routes. Do you want to continue?")
        }
        .alert("StudioPatch",isPresented:Binding(get:{!m.error.isEmpty},set:{if !$0 {m.error=""}})) {
            Button("OK") {m.error=""}
        } message: {Text(m.error)}
    }
    var sidebar: some View {
        VStack(alignment:.leading,spacing:16) {
            VStack(alignment:.leading,spacing:16) {
            Text("VIRTUAL DEVICE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                countField("To Computer",value:$m.preset.inputCount)
                countField("From Computer",value:$m.preset.outputCount)
            }
            Picker("Sync Source",selection:$m.preset.masterUID) {
                Text("Select interface").tag("")
                ForEach(m.selected,id:\.uid) {Text($0.shortName).tag($0.uid)}
            }
            Picker("Sample Rate",selection:$m.preset.sampleRate) {
                ForEach(m.masterSampleRates,id:\.self) {Text("\($0) Hz").tag($0)}
            }
            DisclosureGroup("Advanced") {
                Picker("I/O buffer",selection:$m.preset.bufferFrames) {
                    ForEach([32,64,128,256,512,1024],id:\.self) {Text("\($0) samples").tag($0)}
                }
                if !m.interfaceTimingText.isEmpty {Text(m.interfaceTimingText).font(.caption).foregroundStyle(.secondary)}
                Text(m.softwareMarginText)
                    .font(.caption).foregroundStyle(.secondary)
                Text("Reported latency also includes the Sync Source interface. The software margin can exceed 1 ms round trip depending on sample rate and I/O buffer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("AUDIO INTERFACES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing:8) {
                Text("Use").frame(width:28)
                Text("Audio Device").frame(maxWidth:.infinity,alignment:.leading)
                Text("Sync").frame(width:32)
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    ForEach(m.listedHardware,id:\.uid) { d in
                        HStack(alignment:.top,spacing:8) {
                            Toggle("Use \(d.name)",isOn:Binding(get:{m.preset.devices.contains {$0.uid==d.uid}},set:{_ in m.requestToggle(d)}))
                                .labelsHidden().toggleStyle(.checkbox).frame(width:28)
                            VStack(alignment:.leading,spacing:5) {
                                Text(d.name).font(.callout).fixedSize(horizontal:false,vertical:true)
                                Text(m.isAvailable(d.uid) ? "\(d.inputs) in · \(d.outputs) out · \(Int(d.sampleRate)) Hz" : (m.preset.knownDevices?.contains(where: { $0.uid == d.uid }) == true ? "Unavailable · \(d.inputs) in · \(d.outputs) out (last known)" : "Unavailable · no channel information"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let i=m.preset.devices.firstIndex(where:{$0.uid==d.uid}) {
                                    Toggle("Drift correction",isOn:$m.preset.devices[i].drift).font(.caption).disabled(d.uid==m.preset.masterUID || !m.isAvailable(d.uid))
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading)
                            Group {
                                if m.preset.devices.contains(where:{$0.uid==d.uid}) {
                                    if d.uid == m.preset.masterUID {
                                        Image(systemName:"clock").foregroundStyle(.secondary)
                                            .frame(width:28,height:26).accessibilityLabel("Sync source: \(d.name)").help("Sync source")
                                    } else {
                                        let locked=m.preset.isSyncLocked(d.uid)
                                        Button {
                                            if let i=m.preset.devices.firstIndex(where:{$0.uid==d.uid}) { m.preset.devices[i].syncLocked = !locked }
                                        } label: {
                                            Image(systemName:locked ? "lock.fill" : "lock.open")
                                                .frame(width:28,height:26)
                                                .foregroundStyle(locked ? Color.white : Color.secondary)
                                                .background(locked ? Color.accentColor : Color.secondary.opacity(0.15),in:RoundedRectangle(cornerRadius:6))
                                        }.buttonStyle(.plain)
                                        .accessibilityLabel("\(locked ? "Unlock" : "Lock") sample rate sync for \(d.name)")
                                        .help(locked ? "Locked: StudioPatch follows the sync source's sample rate. Click to unlock." : "Unlocked: StudioPatch will not change this device's sample rate. Click to lock.")
                                    }
                                } else { Color.clear.frame(width:28,height:26) }
                            }.frame(width:32)
                        }.opacity(m.isAvailable(d.uid) ? 1 : 0.45)
                    }
                }
            }

            if !m.missingDevices.isEmpty { Text("Unavailable: " + m.missingDevices.map(\.shortName).joined(separator:", ") + ". Greyed-out matrix routes cannot be clicked. Select an available source to replace a To Computer route.").font(.caption).foregroundStyle(.secondary) }
            if !m.saveStatus.isEmpty { Text(m.saveStatus).font(.caption).foregroundStyle(.orange) }
            }.disabled(m.ioBusy)

        }
        .padding(20)
        .background(.black.opacity(0.15))
    }
    func countField(_ name:String,value:Binding<Int>) -> some View {
        VStack(alignment:.leading) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            TextField(name,value:Binding(get:{value.wrappedValue},set:{
                value.wrappedValue=min(128,max(0,$0)); m.resize()
            }),format:.number).textFieldStyle(.roundedBorder)
                .onSubmit { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }
    var matrix: some View {
        let ins=m.ports(input:true),outs=m.ports(input:false)
        let rows=m.tab==0 ? (0..<m.preset.inputCount).map {m.computerName($0+1,input:true,multiline:true)} : outs.map { $0.1 + "\n" + m.outputDestinationLabel($0.0) }
        let cols=m.tab==0 ? ins.map { $0.1 + "\n" + m.inputSourceLabel($0.0) } : (0..<m.preset.outputCount).map {m.computerName($0+1,input:false,multiline:true)}
        var active=Set<Int>()
        if m.tab==0 {
            for(r,p) in m.preset.activeInputs.enumerated() {if let c=ins.firstIndex(where:{$0.0==p}) {active.insert(r*cols.count+c)}}
        } else {
            for route in m.preset.activeOutputs {
                if let r=outs.firstIndex(where:{$0.0==Port(deviceUID:route.deviceUID,channel:route.channel)}) {active.insert(r*cols.count+route.virtualChannel-1)}
            }
        }
        let unavailableRows = m.tab == 0 ? Set<Int>() : Set(outs.indices.filter { !m.canConnect(outs[$0].0,input:false) })
        let unavailableColumns = m.tab == 0 ? Set(ins.indices.filter { !m.canConnect(ins[$0].0,input:true) }) : Set<Int>()
        return Matrix(rows:rows,columns:cols,selected:active,enabled:!m.ioBusy,unavailableRows:unavailableRows,unavailableColumns:unavailableColumns,
                      showsInputLabels:m.tab == 0,
                      rowLabelStatuses:m.tab == 0 ? (0..<m.preset.inputCount).map { m.inputLabelStatus($0) } : outs.map { m.outputLabelStatus($0.0) },
                      onLabelSyncClick:{ row,side in
                          if m.tab == 0 { m.updateInputLabel(row,from:side) }
                          else { m.updateOutputLabel(outs[row].0,from:side) }
                      },onHeaderDoubleClick:{row,index in
            if m.tab == 0 {
                if row { m.openComputerLabels(index+1,input:true) }
                else { m.openLabels(port:ins[index].0,direction:0) }
            } else {
                if row { m.openLabels(port:outs[index].0,direction:1) }
                else { m.openComputerLabels(index+1,input:false) }
            }
        }) {r,c in
            if m.tab==0 {m.setInput(r,port:m.preset.inputs[r]==ins[c].0 ? nil : ins[c].0)}
            else {m.setOutput(outs[r].0,channel:active.contains(r*cols.count+c) ? 0 : c+1)}
        }
    }

}
struct PresetLibraryEditor: View {
    @ObservedObject var m: Model
    @State private var selected: UUID?
    @State private var newName = ""
    @State private var editedName = ""
    @State private var failure = ""
    @State private var overwrite = false
    @State private var deleting = false
    @State private var renaming = false
    @State private var copying = false
    private var slot: PresetSlot? { m.presetSlots.first {$0.id == selected} }
    private func perform(_ action: () throws -> Void) {
        do { try action(); failure="" } catch { failure=error.localizedDescription }
    }
    private func create(copyLabels:Bool) {
        Task { @MainActor in
            do {
                selected=try await m.saveAsNew(name:newName,copyLabels:copyLabels)
                editedName=newName.trimmingCharacters(in:.whitespacesAndNewlines);newName="";failure=""
            } catch { failure=error.localizedDescription }
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("Presets").font(.title2.weight(.semibold))
                Text(m.activePresetTitle).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Done") { m.showingPresets=false }.keyboardShortcut(.defaultAction)
            }
            HStack {
                TextField("New preset name",text:$newName).textFieldStyle(.roundedBorder)
                Button("Save current as new") {
                    copying=true
                }.disabled(newName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
            List {
                ForEach(m.presetSlots) { item in
                    HStack(spacing:12) {
                        VStack(alignment:.leading,spacing:4) {
                            HStack {
                                Text(item.name + (item.id == m.preset.activePresetID && m.presetIsModified ? " *" : "")).font(.headline).lineLimit(1).help(item.name)
                                if item.id == m.preset.activePresetID { Text("Active").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text("\(item.configuration.inputCount) To Computer · \(item.configuration.outputCount) From Computer · \(item.configuration.sampleRate) Hz")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength:12)
                        if item.id == m.preset.activePresetID && m.presetIsModified {
                            Button("Save") { perform { _ = try m.saveSlot(name:item.name,replacing:item.id) } }
                                .accessibilityLabel("Save \(item.name)")
                        }
                        Button("Load") { perform { try m.loadSlot(item.id); m.showingPresets=false } }
                            .accessibilityLabel("Load \(item.name)")
                        Button {
                            selected=item.id; editedName=item.name; renaming=true
                        } label: { Image(systemName:"pencil") }
                            .help("Rename preset").accessibilityLabel("Rename \(item.name)")
                        if item.id != m.preset.activePresetID {
                            Button {
                                selected=item.id; deleting=true
                            } label: { Image(systemName:"trash") }
                                .help("Delete preset").accessibilityLabel("Delete \(item.name)")
                        }
                    }.buttonStyle(.bordered).padding(.vertical,6)
                    .contextMenu {
                        Button("Overwrite with current…") { selected=item.id; overwrite=true }
                    }
                }
            }.overlay {
                if m.presetSlots.isEmpty { Text("Save your current configuration to create a preset.").foregroundStyle(.secondary).allowsHitTesting(false) }
            }
            Text("Loading applies the saved configuration immediately. Editing the current configuration does not overwrite saved presets.")
                .font(.caption).foregroundStyle(.secondary)
            if !failure.isEmpty { Text(failure).foregroundStyle(.orange).font(.callout) }
        }.padding(24).frame(width:760,height:510)
        .disabled(m.ioBusy)
        .alert("Copy channel labels?",isPresented:$copying) {
            Button("Copy labels") { create(copyLabels:true) }
            Button("Without labels") { create(copyLabels:false) }
            Button("Cancel",role:.cancel) { }
        } message: { Text("The new preset gets its own audio device. Copy current labels that differ from its automatic routing names?") }
        .alert("Rename preset",isPresented:$renaming) {
            TextField("Preset name",text:$editedName)
            Button("Cancel",role:.cancel) { }
            Button("Rename") {
                if let selected { perform { try m.renameSlot(selected,name:editedName) } }
            }.disabled(editedName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
        }
        .alert("Overwrite preset?",isPresented:$overwrite) {
            Button("Cancel",role:.cancel) { }
            Button("Overwrite",role:.destructive) {
                if let slot { perform { _ = try m.saveSlot(name:slot.name,replacing:slot.id) } }
            }
        } message: { Text("Replace ‘\(slot?.name ?? "")’ with the current configuration?") }
        .alert("Delete preset?",isPresented:$deleting) {
            Button("Cancel",role:.cancel) { }
            Button("Delete",role:.destructive) {
                if let selected { perform { try m.deleteSlot(selected); self.selected=nil } }
            }
        } message: { Text("Delete ‘\(slot?.name ?? "")’? Your current routing will remain unchanged.") }
    }
}

struct DeviceOrderEditor: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("Device display order").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { m.showingDeviceOrder=false }.keyboardShortcut(.defaultAction)
            }
            Text("Choose which device's channels appear first in the routing matrix. Changes are saved automatically.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing:8) {
                    ForEach(Array(m.displayDevices.enumerated()),id:\.element.uid) { index,device in
                        HStack(spacing:12) {
                            Text("\(index+1)").monospacedDigit().foregroundStyle(.secondary).frame(width:24)
                            VStack(alignment:.leading) {
                                Text(device.name)
                                if !m.isAvailable(device.uid) { Text("Unavailable").font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth:.infinity,alignment:.leading)
                            Button { m.moveDisplayDevice(device.uid,by:-1) } label: { Image(systemName:"chevron.up") }
                                .disabled(index==0).help("Move up").accessibilityLabel("Move \(device.name) up")
                            Button { m.moveDisplayDevice(device.uid,by:1) } label: { Image(systemName:"chevron.down") }
                                .disabled(index==m.displayDevices.count-1).help("Move down").accessibilityLabel("Move \(device.name) down")
                        }.padding(10).background(Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:8))
                    }
                    if m.displayDevices.isEmpty { Text("Select audio interfaces to arrange their channels.").foregroundStyle(.secondary) }
                }
            }
        }.padding(24).frame(width:560,height:400)
    }
}
struct LabelEditor: View {
    @ObservedObject var m: Model
    @State private var drafts: [String:ChannelLabel] = [:]
    @State private var saving=false
    @State private var failed=false
    @State private var closing=false
    @FocusState private var focused: String?
    private func key(_ entry:LabelEntry) -> String { "\(entry.port.deviceUID):\(entry.direction.rawValue):\(entry.port.channel)" }
    private func commit() {
        guard !saving, !failed, !m.ioBusy else { return }
        guard let id=drafts.keys.sorted().first, let label=drafts[id] else {
            if closing { m.showingLabels=false }
            return
        }
        saving=true
        m.editLabel(label) { success in
            saving=false
            if success {
                if drafts[id]?.text == label.text { drafts.removeValue(forKey:id) }
                Task { @MainActor in commit() }
            } else { failed=true; closing=false }
            // Model ends its I/O operation after this completion callback.
        }
    }
    private func finish() {
        closing=true; failed=false; focused=nil
        commit()
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("StudioPatch channel labels").font(.title2.weight(.semibold))
                Spacer()
                Button("Done",action:finish).keyboardShortcut(.defaultAction)
            }
            Text(m.labelDirection >= 2
                 ? "Interface input and output labels are shared by all presets and saved in StudioPatch. Clear a field to use the interface channel name. When labels differ, both are orange. Click either label to copy it to the other side."
                 : "Labels are saved to Core Audio when you leave a field or press Return. Clear a field to use its routing name.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth:.infinity,alignment:.leading)
                .frame(height:48,alignment:.topLeading)
            VStack(alignment:.leading,spacing:6) {
                Text("Channels").font(.callout).foregroundStyle(.secondary)
                Picker("Channels",selection:$m.labelDirection) {
                    Text("To Computer (Core Audio)").tag(0)
                    Text("From Computer (Core Audio)").tag(1)
                    Text("Interface inputs").tag(2)
                    Text("Interface outputs").tag(3)
                }.pickerStyle(.segmented).labelsHidden()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:8) {
                        ForEach(m.labelEntries) { entry in
                            HStack {
                                VStack(alignment:.leading,spacing:2) {
                                    Text(entry.device)
                                    Text(entry.name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(width:220,alignment:.leading)
                                TextField(m.labelDirection >= 2 ? "Empty uses interface name" : "Empty uses routing name",text:Binding(
                                    // A synchronous interface save can finish before this row is rebuilt.
                                    // Read the model, not the old entry captured by the binding.
                                    get:{ drafts[key(entry)]?.text ?? m.currentLabelName(entry) },
                                    set:{ drafts[key(entry)]=ChannelLabel(port:entry.port,direction:entry.direction,text:$0); failed=false }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .focused($focused,equals:key(entry))
                                .onSubmit { failed=false; commit() }
                                .accessibilityLabel("Label for \(entry.device)")
                            }.padding(8)
                            .background(m.labelSelection == entry.port ? Color.cyan.opacity(0.16) : Color.clear,in:RoundedRectangle(cornerRadius:6))
                            .id(entry.port)
                        }
                    }.id(m.labelDirection)
                }.onAppear { if let selected=m.labelSelection { proxy.scrollTo(selected,anchor:.center) } }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            HStack(spacing:8) {
                if saving {
                    ProgressView().progressViewStyle(.circular).controlSize(.small)
                        .frame(width:16,height:16)
                    Text("Saving labels…").font(.caption).foregroundStyle(.secondary)
                }
                if !m.error.isEmpty {
                    Text(m.error).font(.caption).foregroundStyle(.orange)
                        .lineLimit(2).help(m.error)
                }
                Spacer(minLength:0)
            }.frame(height:40,alignment:.top)
        }
        // Reserve the same space for help and status in every tab, including while saving.
        .frame(width:852,height:592,alignment:.topLeading)
        .padding(24)
        .interactiveDismissDisabled()
        .onExitCommand(perform:finish)
        .onChange(of:focused) { old,_ in if old != nil { failed=false; commit() } }
        .onChange(of:m.labelDirection) { _,_ in focused=nil; failed=false; commit() }
        .onChange(of:m.ioBusy) { _,busy in if !busy { commit() } }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var focusMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Buttons and the native matrix do not normally take keyboard focus on macOS.
        // End field editing before forwarding an outside click to its target.
        focusMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { event in
            if let window=event.window,
               let editor=window.firstResponder as? NSTextView, editor.isFieldEditor,
               let field=editor.delegate as? NSTextField,
               ["To Computer","From Computer","Empty uses routing name","Empty uses interface name"].contains(field.placeholderString ?? ""),
               !field.bounds.contains(field.convert(event.locationInWindow,from:nil)) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let focusMonitor { NSEvent.removeMonitor(focusMonitor) }
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply { .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
}
#if !STUDIOPATCH_MODEL_TESTS
@main struct StudioPatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model=Model()
    var body: some Scene {
        WindowGroup {ContentView(m:model)}.defaultSize(width:1200,height:800)
    }
}

#endif
