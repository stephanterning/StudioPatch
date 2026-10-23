import SwiftUI
import CoreAudio

// Core Audio callbacks only enqueue work; device reads stay on AudioWorker.
// The periodic runtime snapshot remains a fallback if a driver misses a notification.
final class DeviceInventoryObserver {
    private struct Watch {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        var block: AudioObjectPropertyListenerBlock
    }
    private var watches: [Watch] = []
    private var deviceIDs = Set<AudioObjectID>()
    private var pending: DispatchWorkItem?
    private let changed: () -> Void
    init(changed: @escaping () -> Void) {
        self.changed = changed
        watch(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    }
    private func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var address = AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.changed() }
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
        }
        if AudioObjectAddPropertyListenerBlock(object,&address,DispatchQueue.main,block) == noErr {
            watches.append(Watch(object:object,address:address,block:block))
        }
    }
    func update(_ ids: Set<AudioObjectID>) {
        guard ids != deviceIDs else { return }
        for index in watches.indices.reversed() where watches[index].object != AudioObjectID(kAudioObjectSystemObject) && !ids.contains(watches[index].object) {
            var watch = watches.remove(at:index)
            AudioObjectRemovePropertyListenerBlock(watch.object,&watch.address,DispatchQueue.main,watch.block)
        }
        for id in ids.subtracting(deviceIDs) {
            watch(id,kAudioObjectPropertyName)
            watch(id,kAudioDevicePropertyDeviceIsAlive)
            watch(id,kAudioDevicePropertyNominalSampleRate)
            for scope in [kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput] {
                watch(id,kAudioDevicePropertyStreamConfiguration,scope:scope)
                watch(id,kAudioObjectPropertyElementName,scope:scope)
            }
        }
        deviceIDs = ids
    }
    deinit {
        pending?.cancel()
        for var watch in watches {
            AudioObjectRemovePropertyListenerBlock(watch.object,&watch.address,DispatchQueue.main,watch.block)
        }
    }
}

struct Device: Codable, Identifiable, Equatable {
    let id: UInt32
    let uid: String
    let name: String
    let inputs: Int
    let outputs: Int
    let sampleRate: Double
    let aggregate: Bool
    let inputNames: [String]
    let outputNames: [String]
    var sampleRates: [Double]? = nil
    func channelNames(input: Bool) -> [String] {
        let names=input ? inputNames : outputNames
        return (0..<(input ? inputs : outputs)).map { index in
            index < names.count ? names[index] : "\(input ? "Input" : "Output") \(index+1)"
        }
    }
    var snapshot: KnownDevice { KnownDevice(uid:uid,name:name,inputNames:channelNames(input:true),outputNames:channelNames(input:false),sampleRate:sampleRate) }
    var shortName: String {
        if name.contains("UFX") { return "UFX III" }
        if name.contains("ZED") { return "ZED-R16" }
        return name
    }
}
struct Inventory: Decodable {
    let devices: [Device]
    let driverInstalled: Bool
    let driverConfig: String
}
struct LabelEntry: Identifiable {
    let port: Port
    let direction: PortDirection
    let name: String
    let device: String
    var id: Port { port }
}
struct EngineStatus: Decodable {
    let running: Bool
    let invalidated: Bool
    let cycles: UInt64
    let badBuffers: UInt64
    let bufferFrames: Int
    let latencyDiagnostics: String?
}
enum AudioWorker {
    static let queue=DispatchQueue(label:"se.studiopatch.audio-control",qos:.userInitiated)
    static func call(_ operation:@escaping ()->UnsafeMutablePointer<CChar>?) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let pointer=operation() else {
                    continuation.resume(throwing:NSError(domain:"StudioPatch",code:2)); return
                }
                defer { SPFree(pointer) }
                let raw=Data(String(cString:pointer).utf8)
                do {
                    if let obj=try JSONSerialization.jsonObject(with:raw) as? [String:Any], let failure=obj["error"] as? String {
                        throw NSError(domain:"StudioPatch",code:3,userInfo:[NSLocalizedDescriptionKey:failure])
                    }
                    continuation.resume(returning:raw)
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    static func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { SPStop(); continuation.resume() }
        }
    }
}
@MainActor final class Model: ObservableObject {
    @Published var devices: [Device] = []
    @Published var preset = Preset() { didSet { autosave() } }
    @Published var installed = false
    @Published var inventoryKnown = false
    @Published var ioBusy = false
    @Published var ioStatus = ""
    private let inventoryReader: ()->UnsafeMutablePointer<CChar>?
    private var chooseInitialDevices = false
    private var pendingNames = false
    private func beginIO(_ text:String, quiet:Bool = false) -> Task<Void,Never> {
        ioBusy=true; ioStatus=quiet ? "" : text
        return Task { [weak self] in
            do { try await Task.sleep(nanoseconds:5_000_000_000) } catch { return }
            self?.ioStatus="Core Audio has not responded yet. Waiting before sending further audio requests."
        }
    }
    private func endIO(_ watchdog:Task<Void,Never>) {
        watchdog.cancel(); ioBusy=false; ioStatus=""
        updateAutomaticSync()
        if pendingNames { scheduleNamesUpdate() }
    }
    private func performIO(_ text:String, quiet:Bool = false, _ work:@escaping @MainActor () async throws -> Void) {
        guard !ioBusy, syncTask == nil else { return }
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
    @Published var listMode = false
    @Published var showingPresets = false
    @Published var presetSlots: [PresetSlot] = []
    @Published var showingLabels = false
    @Published var showingDeviceOrder = false
    @Published var labelDirection = 0
    @Published var labelSelection: Port?
    @Published var pendingRemoval: Device?
    @Published var saveStatus = ""
    @Published var syncStatus = ""
    private let sessionStore: SessionStore
    private var autosaveReady = false
    private var timer: Timer?
    private var namesUpdate: DispatchWorkItem?
    private var publishedNames: String?
    private var inventoryObserver: DeviceInventoryObserver?
    private var inventoryTicks=0
    private var automaticSyncEnabled=false
    private var service=false
    private var liveRuntime=false
    private var appliedRuntime=""
    private var runtimeLatencyDiagnostics: String?
    private var desiredRuntime=""
    private var nextRuntimeAttempt=Date.distantPast
    private var runtimeRetry=RateRetrySchedule()
    private var loadingRuntime=false
    private var lastDesiredRate=0
    private var pendingPanelRate:Int?
    private var failureNotified=false
    private var driverConfiguration=""
    // Retained through retries: hardware may change before a later stage fails.
    private var pendingFormatNotification:String?
    private var notifiedFormatFailure:String?
    private var syncTask: Task<Void,Never>?
    private var syncKey=""
    private var syncGeneration=0

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
    func ports(input: Bool, includeLabels: Bool = true, multiline: Bool = false, displayOrder: Bool = true) -> [(Port, String)] {
        (displayOrder ? displayDevices : selected).flatMap { d in
            d.channelNames(input:input).enumerated().map { index, name in
                let port = Port(deviceUID:d.uid,channel:index+1)
                let original = "\(d.shortName) · \(name)"
                let label = preset.label(for:port,direction:input ? .input : .output)
                return (port, original + (includeLabels && !label.isEmpty ? (multiline ? "\n" : " — ") + label : ""))
            }
        }
    }
    // Computer labels are derived from routing; only hardware owns editable labels.
    func computerPorts(_ channel: Int, input: Bool) -> [Port] {
        guard channel > 0, channel <= (input ? preset.inputCount : preset.outputCount) else { return [] }
        let connected: Set<Port>
        if input {
            connected = Set(preset.activeInputs.indices.contains(channel-1) ? [preset.activeInputs[channel-1]].compactMap { $0 } : [])
        } else {
            connected = Set(preset.activeOutputs.filter { $0.virtualChannel == channel }.map { Port(deviceUID:$0.deviceUID,channel:$0.channel) })
        }
        return ports(input:input,includeLabels:false,displayOrder:false).map(\.0).filter { connected.contains($0) }
    }
    func computerLabel(_ channel: Int, input: Bool) -> String {
        let originals = Dictionary(uniqueKeysWithValues:ports(input:input,includeLabels:false))
        var labels: [String] = []
        for port in computerPorts(channel,input:input) {
            let custom = preset.label(for:port,direction:input ? .input : .output)
            let label = custom.isEmpty ? (originals[port] ?? "") : custom
            if !label.isEmpty, !labels.contains(label) { labels.append(label) }
        }
        return labels.joined(separator:" · ")
    }
    func computerName(_ channel: Int, input: Bool, multiline: Bool = false) -> String {
        let name="\(input ? "To Computer" : "From Computer") \(channel)"
        let label=computerLabel(channel,input:input)
        return name + (label.isEmpty ? "" : (multiline ? "\n" : " — ") + label)
    }
    func exposedChannelName(_ channel: Int, input: Bool) -> String {
        let label=computerLabel(channel,input:input)
        return label.isEmpty ? "\(input ? "To Computer" : "From Computer") \(channel)" : label
    }
    func channelNamesPayload() throws -> String {
        let names=["inputs":(0..<preset.inputCount).map { exposedChannelName($0+1,input:true) },
                   "outputs":(0..<preset.outputCount).map { exposedChannelName($0+1,input:false) }]
        return String(decoding:try JSONSerialization.data(withJSONObject:names,options:.sortedKeys),as:UTF8.self)
    }
    private func scheduleNamesUpdate() {
        namesUpdate?.cancel()
        guard service, autosaveReady, installed else { return }
        pendingNames=true
        let update=DispatchWorkItem { [weak self] in
            guard let self, !self.ioBusy, self.syncTask == nil else { return }
            self.performIO("Updating channel names…") { try await self.publishChannelNames() }
        }
        namesUpdate=update
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4,execute:update)
    }
    private func publishChannelNames(force: Bool = false) async throws {
        guard installed else { return }
        pendingNames=false
        let raw=try channelNamesPayload()
        guard force || raw != publishedNames else { return }
        let result=try await AudioWorker.call { raw.withCString { SPSetChannelNames($0) } }
        let status=try JSONSerialization.jsonObject(with:result) as? [String:Any]
        if status?["ok"] as? Bool == true { publishedNames=raw }
    }
    func openComputerLabels(_ channel: Int, input: Bool) {
        guard let port=computerPorts(channel,input:input).first else { return }
        openLabels(port:port,direction:input ? 0 : 1)
    }
    func openLabels(port: Port? = nil, direction: Int? = nil) {
        labelSelection=port
        labelDirection=(direction ?? tab) == 0 ? 0 : 1
        showingLabels=true
    }
    var labelEntries: [LabelEntry] {
        let input = labelDirection == 0
        let direction: PortDirection = input ? .input : .output
        return selected.flatMap { device in
            device.channelNames(input:input).enumerated().map {
                LabelEntry(port:Port(deviceUID:device.uid,channel:$0.offset+1),direction:direction,
                           name:$0.element,device:device.shortName)
            }
        }
    }
    var masterSampleRates: [Int] {
        let rates=hardware.first(where:{$0.uid==preset.masterUID})?.sampleRates?.map { Int($0) } ?? []
        return Array(Set(rates + [preset.sampleRate])).sorted()
    }
    var rateMismatch: Bool { selected.filter { isAvailable($0.uid) }.contains { Int($0.sampleRate) != preset.sampleRate } }
    init(store: SessionStore = SessionStore(), discoverDevices: Bool = true, service: Bool = false, inventoryReader:@escaping ()->UnsafeMutablePointer<CChar>? = { SPInventory() }) {
        self.service=service; self.liveRuntime=discoverDevices
        self.inventoryReader=inventoryReader
        sessionStore = store
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
        automaticSyncEnabled=false
        updateAutomaticSync()
        scheduleNamesUpdate()
        if isNewSession { autosave() }
        if discoverDevices && !service {
            do { try restoreActivePreset() }
            catch { self.error="Could not restore the active preset: \(error.localizedDescription)" }
        }
        guard discoverDevices else { return }
        #if !STUDIOPATCH_MODEL_TESTS
        if service {
            inventoryObserver = DeviceInventoryObserver { [weak self] in self?.runtimeTick() }
        }
        #endif
        if service { runtimeTick() }
        else {
            do { try RuntimeConnection.launch() } catch { message="Could not start the background engine: \(error.localizedDescription)" }
            readRuntime()
            RuntimeConnection.requestNotifications()
        }
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }
    private func autosave() {
        guard autosaveReady, !service, !loadingRuntime else { return }
        updateAutomaticSync()
        scheduleNamesUpdate()
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
        if liveRuntime && !service { readRuntime(); return }
        performIO("Reading audio devices from Core Audio…") { try await self.refreshInventory() }
    }
    private func refreshInventory() async throws {
        let raw=try await AudioWorker.call(inventoryReader)
        let inv=try JSONDecoder().decode(Inventory.self,from:raw)
        inventoryObserver?.update(Set(inv.devices.map(\.id)))
        driverConfiguration=inv.driverConfig
        let changed=devices != inv.devices || installed != inv.driverInstalled
        updateInventory(inv.devices); installed=inv.driverInstalled; inventoryKnown=true
        if chooseInitialDevices {
            chooseInitialDevices=false
            preset.devices=hardware.filter { $0.name.contains("UFX") || $0.name.contains("ZED") }.map { Member(uid:$0.uid,drift:false) }
            preset.masterUID=selected.first(where:{$0.name.contains("UFX")})?.uid ?? selected.first?.uid ?? ""
        }
        if changed { publishedNames=nil; scheduleNamesUpdate() }
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
    var isSynchronizing: Bool { syncTask != nil }
    func configure() {
        performIO("Applying channel counts…") {
            let raw=try self.payload()
            _ = try await AudioWorker.call { raw.withCString { SPConfigure($0) } }
            try await self.publishChannelNames(force:true)
            self.message="Channel counts applied. Reselect StudioPatch in Ableton if needed."
            try await self.refreshInventory()
        }
    }
    func requireAvailableDevices() throws {
        guard missingDevices.isEmpty else {
            throw NSError(domain:"StudioPatch",code:4,userInfo:[NSLocalizedDescriptionKey:"Audio interfaces unavailable: " + missingDevices.map(\.name).joined(separator:", ")])
        }
    }
    func start() {
        performIO("Starting routing…") {
            try await self.refreshInventory()
            try self.requireAvailableDevices()
            if self.masterMismatch {
                throw NSError(domain:"StudioPatch",code:5,userInfo:[NSLocalizedDescriptionKey:"Wait for sample rate synchronization before starting."])
            }
            let raw=try self.payload()
            _ = try await AudioWorker.call { raw.withCString { SPConfigure($0) } }
            try await self.publishChannelNames(force:true)
            _ = try await AudioWorker.call { raw.withCString { SPStart($0) } }
            self.running=true; self.message="Routing active · round-trip latency has not been measured yet"
        }
    }
    func stop() {
        performIO("Stopping routing…") {
            await AudioWorker.stop(); self.running=false; self.message="Routing stopped"
        }
    }
    var masterMismatch: Bool {
        guard let master=hardware.first(where: { $0.uid == preset.masterUID }),
              preset.devices.contains(where: { $0.uid == master.uid }) else { return false }
        return Int(master.sampleRate) != preset.sampleRate || selected.contains { !isAvailable($0.uid) || abs($0.sampleRate-master.sampleRate)>0.5 }
    }
    private func updateAutomaticSync() {
        guard automaticSyncEnabled else { return }
        let key="\(preset.followMaster != false)|\(preset.masterUID)|" + preset.devices.map(\.uid).sorted().joined(separator:"|")
        if key != syncKey {
            syncKey=key; syncGeneration += 1; syncTask?.cancel(); syncTask=nil; syncStatus=""
        }
        guard preset.followMaster != false, !preset.devices.isEmpty, !preset.masterUID.isEmpty else { return }
        guard !ioBusy, syncTask == nil, masterMismatch else { return }
        let generation=syncGeneration
        let watchdog=beginIO("Synchronizing to sync source…")
        syncTask=Task { [weak self] in
            defer {
                watchdog.cancel()
                if let self { self.ioBusy=false; self.ioStatus=""; self.syncTask=nil }
            }
            var retry=RateRetrySchedule()
            while !Task.isCancelled {
                guard let self, self.syncGeneration == generation else { return }
                // Hardware cannot change frequency while our audio callbacks are using it.
                if self.running { await AudioWorker.stop(); self.running=false }
                self.syncStatus="Synchronizing to sync source…"
                do {
                    try self.preset.validate(forEditing:true)
                    let raw=String(decoding:try JSONEncoder().encode(self.preset),as:UTF8.self)
                    let result=try await AudioWorker.call { raw.withCString { SPFollowMaster($0) } }
                    guard !Task.isCancelled, self.syncGeneration == generation else { return }
                    let obj=try JSONSerialization.jsonObject(with:result) as? [String:Any]
                    if let failure=obj?["error"] as? String { throw NSError(domain:"StudioPatch",code:5,userInfo:[NSLocalizedDescriptionKey:failure]) }
                    guard let rate=obj?["sampleRate"] as? Int else { throw NSError(domain:"StudioPatch",code:5,userInfo:[NSLocalizedDescriptionKey:"Invalid response during sample rate synchronization."]) }
                    self.preset.sampleRate=rate
                    try await self.refreshInventory()
                    if self.masterMismatch { throw NSError(domain:"StudioPatch",code:5,userInfo:[NSLocalizedDescriptionKey:"The interfaces still report different sample rates."]) }
                    self.syncStatus="Synchronized to sync source · \(rate) Hz"
                    self.syncTask=nil
                    return
                } catch {
                    guard !Task.isCancelled, self.syncGeneration == generation else { return }
                    let delay=retry.failed()
                    self.syncStatus="\(error.localizedDescription) " + (delay == 0 ? "Retrying immediately (\(retry.failures)/3)." : "Retrying in 5 seconds.")
                    if delay > 0 { do { try await Task.sleep(nanoseconds:delay) } catch { return } }
                    else { await Task.yield() }
                }
            }
        }
    }
    func poll() {
        if liveRuntime { if service { runtimeTick() } else { readRuntime() }; return }
        guard !ioBusy, syncTask == nil else { return }
        inventoryTicks += 1
        let readInventory=inventoryTicks % 2 == 0
        guard running || readInventory else { return }
        performIO("Checking audio status…",quiet:true) {
            if self.running {
                let raw=try await AudioWorker.call { SPStatus() }
                let status=try JSONDecoder().decode(EngineStatus.self,from:raw)
                if status.invalidated {
                    await AudioWorker.stop(); self.running=false
                    self.error="The device, channel format or buffer changed. Audio was muted. The device list will update automatically."
                } else {
                    self.message="Routing active · \(status.bufferFrames) samples I/O · \(status.cycles) audio cycles · \(status.badBuffers) buffer errors"
                }
            }
            if readInventory { try await self.refreshInventory() }
        }
    }
    private func readRuntime() {
        do {
            let snapshot=try RuntimeConnection.read()
            let previousDevices=preset.knownDevices
            loadingRuntime=true
            updateInventory(snapshot.devices)
            installed=snapshot.installed; inventoryKnown=true; running=snapshot.running
            message=snapshot.message
            if (8000...384000).contains(snapshot.rate) { preset.sampleRate=snapshot.rate }
            loadingRuntime=false
            if previousDevices != preset.knownDevices { try sessionStore.save(preset) }
        } catch { message=error.localizedDescription }
    }
    private func runtimeTick() {
        guard !ioBusy else { return }
        ioBusy=true
        Task {
            defer {
                ioBusy=false
                RuntimeConnection.write(RuntimeSnapshot(devices:devices,installed:installed,running:running,message:message,rate:preset.sampleRate,latencyDiagnostics:runtimeLatencyDiagnostics))
            }
            do {
                if let desired=try sessionStore.load() {
                    let effective=preset.sampleRate
                    preset=desired
                    if lastDesiredRate != 0 && desired.sampleRate != lastDesiredRate {
                        pendingPanelRate=desired.sampleRate
                        nextRuntimeAttempt = .distantPast
                        runtimeRetry=RateRetrySchedule()
                    }
                    if desired.sampleRate == lastDesiredRate { preset.sampleRate=effective }
                    lastDesiredRate=desired.sampleRate
                }
                try await refreshInventory()
                guard Date()>=nextRuntimeAttempt else { return }
                try requireAvailableDevices()
                guard installed else { throw NSError(domain:"StudioPatch",code:21,userInfo:[NSLocalizedDescriptionKey:"The StudioPatch driver is unavailable in Core Audio."]) }
                guard !preset.devices.isEmpty else { await AudioWorker.stop(); running=false; appliedRuntime=""; message="Select audio interfaces and a sync source."; return }
                var raw=try payload()
                let rates=try await AudioWorker.call { raw.withCString { SPRuntimeRates($0) } }
                let values=try JSONSerialization.jsonObject(with:rates) as! [String:Any]
                let request=(values["requested"] as? Double) ?? 0
                let masterRate=Int((values["masterRate"] as? Double) ?? Double(preset.sampleRate))
                if request>0 { pendingPanelRate=nil; preset.sampleRate=Int(request) }
                else if let panelRate=pendingPanelRate { preset.sampleRate=panelRate }
                else { preset.sampleRate=masterRate }
                raw=try payload()
                if raw != desiredRuntime { desiredRuntime=raw; nextRuntimeAttempt = .distantPast; runtimeRetry=RateRetrySchedule() }
                let status=try await AudioWorker.call { SPStatus() }
                let state=try JSONDecoder().decode(EngineStatus.self,from:status)
                runtimeLatencyDiagnostics=state.latencyDiagnostics
                if state.invalidated { appliedRuntime=""; running=false }
                if raw != appliedRuntime || !running || request>0 {
                    guard Date()>=nextRuntimeAttempt else { return }
                    let current=driverConfiguration.split(separator:" ").compactMap { Int($0) }
                    let formatChanged = current.count < 4 || current[1] != preset.inputCount || current[2] != preset.outputCount || current[3] != preset.sampleRate
                        || selected.contains { abs($0.sampleRate-Double(preset.sampleRate)) > 0.5 }
                    let format="\(preset.sampleRate) Hz · \(preset.inputCount) To Computer · \(preset.outputCount) From Computer (\(selected.map(\.name).joined(separator:", ")))"
                    if formatChanged || pendingFormatNotification != nil { pendingFormatNotification=format }
                    await AudioWorker.stop(); running=false
                    message="Applying routing and audio format…"
                    RuntimeConnection.write(RuntimeSnapshot(devices:devices,installed:installed,running:false,message:message,rate:preset.sampleRate))
                    let hardwareRequest=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as! [String:Any]
                    // Per-device sync locks apply to both panel and client requests.
                    let hardwareRaw=String(decoding:try JSONSerialization.data(withJSONObject:hardwareRequest),as:UTF8.self)
                    _ = try await AudioWorker.call { hardwareRaw.withCString { SPSetHardwareRate($0) } }
                    _ = try await AudioWorker.call { raw.withCString { SPConfigure($0) } }
                    let latest=try await AudioWorker.call { raw.withCString { SPRuntimeRates($0) } }
                    let newer=(try JSONSerialization.jsonObject(with:latest) as? [String:Any])?["requested"] as? Double ?? 0
                    if newer>0 && newer != Double(preset.sampleRate) { throw NSError(domain:"StudioPatch",code:22,userInfo:[NSLocalizedDescriptionKey:"A new sample rate request is pending."]) }
                    try await refreshInventory()
                    try await publishChannelNames(force:true)
                    _ = try await AudioWorker.call { raw.withCString { SPStart($0) } }
                    if request>0 {
                        let ack="{\"ack\":\(request)}"
                        _ = try await AudioWorker.call { ack.withCString { SPAcknowledgeRate($0) } }
                    }
                    if let format=pendingFormatNotification {
                        RuntimeConnection.notifyFormat(format)
                        pendingFormatNotification=nil
                    }
                    notifiedFormatFailure=nil
                    pendingPanelRate=nil
                    appliedRuntime=raw; running=true; failureNotified=false; runtimeRetry=RateRetrySchedule()
                    message="Routing active · \(preset.bufferFrames) samples I/O · \(preset.sampleRate) Hz"
                } else {
                    try await publishChannelNames()
                    message="Routing active · \(state.bufferFrames) samples I/O · \(state.badBuffers) buffer errors"
                }
            } catch {
                await AudioWorker.stop(); running=false; appliedRuntime=""
                message="Audio is muted · \(error.localizedDescription)"
                if let format=pendingFormatNotification {
                    if notifiedFormatFailure != format {
                        RuntimeConnection.notifyFormat(format,failure:error.localizedDescription)
                        notifiedFormatFailure=format
                    }
                    failureNotified=true
                } else if !failureNotified {
                    RuntimeConnection.notifyFailure(error.localizedDescription); failureNotified=true
                }
                let delay=runtimeRetry.failed()
                nextRuntimeAttempt=Date().addingTimeInterval(Double(delay)/1_000_000_000)
                if delay == 0 { DispatchQueue.main.async { self.runtimeTick() } }
            }
        }
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
        configuration.resizeChannels()
        configuration.activePresetID=nil
        try configuration.validate(forEditing:true)
        var slots=presetSlots
        let slot=PresetSlot(id:id ?? UUID(),name:name,configuration:configuration,updatedAt:Date())
        if let id {
            guard let index=slots.firstIndex(where:{$0.id==id}) else { throw NSError(domain:"StudioPatch",code:32,userInfo:[NSLocalizedDescriptionKey:"The preset no longer exists."]) }
            slots[index]=slot
        } else { slots.append(slot) }
        try commitSlots(slots)
        preset.activePresetID=slot.id
        return slot.id
    }
    func renameSlot(_ id: UUID, name: String) throws {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var slots=presetSlots
        guard let index=slots.firstIndex(where:{$0.id==id}) else { return }
        slots[index].name=name
        try commitSlots(slots)
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
                    Button("Save",action:m.saveActivePreset).disabled(!m.presetIsModified || m.activeSlot == nil)
                    Button("Presets…",action:m.openPresets)
                }
                HStack {
                    Picker("Direction",selection:$m.tab) { Text("To Computer").tag(0); Text("From Computer").tag(1) }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Toggle("Channel list",isOn:$m.listMode).toggleStyle(.switch)
                    Button("Device order…") { m.showingDeviceOrder=true }
                    Button("Labels…") { m.openLabels() }
                }
                if m.preset.dormantRouteCount > 0 {
                    Text("\(m.preset.dormantRouteCount) saved routes are inactive. They carry no audio and reactivate when the channel count increases.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if m.listMode { channelList } else { matrix }
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
            if !m.syncStatus.isEmpty { Text(m.syncStatus).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Advanced") {
                Picker("I/O buffer",selection:$m.preset.bufferFrames) {
                    ForEach([32,64,128,256,512,1024],id:\.self) {Text("\($0) samples").tag($0)}
                }
                let outputMargin=Int(ceil(Double(m.preset.sampleRate)/3000.0))
                let inputMargin=max(outputMargin,m.preset.bufferFrames)
                Text("Software margin: \(Double(inputMargin)*1000/Double(m.preset.sampleRate), specifier: "%.3f") ms input · \(Double(outputMargin)*1000/Double(m.preset.sampleRate), specifier: "%.3f") ms output")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Reported latency also includes the Sync Source interface. Larger I/O buffers can exceed 1 ms extra round trip.")
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

            if !m.missingDevices.isEmpty { Text("Unavailable: " + m.missingDevices.map(\.shortName).joined(separator:", ") + ". Saved routes can be removed, but new routes cannot be added.").font(.caption).foregroundStyle(.secondary) }
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
        let ins=m.ports(input:true,multiline:true),outs=m.ports(input:false,multiline:true)
        let rows=m.tab==0 ? (0..<m.preset.inputCount).map {m.computerName($0+1,input:true,multiline:true)} : outs.map(\.1)
        let cols=m.tab==0 ? ins.map(\.1) : (0..<m.preset.outputCount).map {m.computerName($0+1,input:false,multiline:true)}
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
        return Matrix(rows:rows,columns:cols,selected:active,enabled:!m.ioBusy,unavailableRows:unavailableRows,unavailableColumns:unavailableColumns,onHeaderDoubleClick:{row,index in
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
    var channelList: some View {
        ScrollView {
            LazyVStack(alignment:.leading) {
                if m.tab==0 {
                    ForEach(0..<m.preset.inputCount,id:\.self) {r in
                        Picker(m.computerName(r+1,input:true),selection:Binding(get:{m.preset.inputs[r]},set:{m.setInput(r,port:$0)} )) {
                            Text("Not connected").tag(Port?.none)
                            ForEach(m.inputPorts.map(\.0),id:\.self) {p in
                                Text(m.inputPorts.first {$0.0==p}!.1 + (m.canConnect(p,input:true) ? "" : " (unavailable)")).tag(Optional(p)).disabled(!m.canConnect(p,input:true))
                            }
                        }.padding(5)
                    }
                } else {
                    ForEach(m.outputPorts.map(\.0),id:\.self) {p in
                        Picker(m.outputPorts.first {$0.0==p}!.1 + (m.canConnect(p,input:false) ? "" : " (unavailable)"),selection:Binding(get:{m.preset.outputs.first {$0.deviceUID==p.deviceUID && $0.channel==p.channel}?.virtualChannel ?? 0},set:{m.setOutput(p,channel:$0)})) {
                            Text("Not connected").tag(0)
                            if let route=m.preset.outputs.first(where:{$0.deviceUID==p.deviceUID && $0.channel==p.channel}), route.virtualChannel > m.preset.outputCount {
                                Text("From Computer \(route.virtualChannel) (inactive)").tag(route.virtualChannel)
                            }
                            ForEach(0..<m.preset.outputCount,id:\.self) {Text(m.computerName($0+1,input:false)).tag($0+1).disabled(!m.canConnect(p,input:false))}
                        }.padding(5)
                    }
                }
            }
        }.disabled(m.ioBusy)
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
    private var slot: PresetSlot? { m.presetSlots.first {$0.id == selected} }
    private func perform(_ action: () throws -> Void) {
        do { try action(); failure="" } catch { failure=error.localizedDescription }
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
                    perform { selected=try m.saveSlot(name:newName); editedName=newName.trimmingCharacters(in:.whitespacesAndNewlines); newName="" }
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
            Text("Choose which device's channels appear first in the routing matrix and channel list. Changes are saved automatically.")
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
    @FocusState private var focusedPort: Port?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("Custom channel labels").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { m.showingLabels=false }.keyboardShortcut(.defaultAction)
            }
            Text("Labels appear alongside the original channel names. Changes are saved automatically.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Channels",selection:Binding(get:{m.labelDirection},set:{m.labelDirection=$0;m.labelSelection=nil;focusedPort=nil})) {
                Text("Hardware inputs").tag(0)
                Text("Hardware outputs").tag(1)
            }.pickerStyle(.segmented)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:8) {
                        ForEach(m.labelEntries) { entry in
                            HStack {
                                VStack(alignment:.leading,spacing:2) {
                                    Text(entry.name)
                                    Text(entry.device).font(.caption).foregroundStyle(.secondary)
                                }.frame(width:200,alignment:.leading)
                                TextField("Custom label",text:Binding(
                                    get:{m.preset.label(for:entry.port,direction:entry.direction)},
                                    set:{m.preset.setLabel($0,for:entry.port,direction:entry.direction)}))
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedPort,equals:entry.port)
                                    .accessibilityLabel("Label for \(entry.device) \(entry.direction == .input ? "input" : "output") \(entry.name)")
                            }
                            .padding(8)
                            .background(m.labelSelection == entry.port ? Color.cyan.opacity(0.16) : Color.clear,in:RoundedRectangle(cornerRadius:6))
                            .id(entry.port)
                        }
                        if m.labelEntries.isEmpty { Text("No channels to label in this direction.").foregroundStyle(.secondary) }
                    }.padding(.trailing,10)
                }
                .onAppear {
                    if let selected=m.labelSelection {
                        proxy.scrollTo(selected,anchor:.center)
                        DispatchQueue.main.async { focusedPort=selected }
                    }
                }
            }
        }.padding(24).frame(width:680,height:580)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var focusMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Buttons and the native matrix do not normally take keyboard focus on macOS.
        // End channel-count editing before forwarding an outside click to its target.
        focusMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { event in
            if let window=event.window,
               let editor=window.firstResponder as? NSTextView, editor.isFieldEditor,
               let field=editor.delegate as? NSTextField,
               ["To Computer","From Computer"].contains(field.placeholderString ?? ""),
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
