import Foundation
import CoreAudio

@MainActor final class RuntimeController {
    var devices:[Device]=[], preset=Preset()
    var installed=false, running=false, ioBusy=false
    var driverErrorStatus:Int?
    var message="Starting audio service"
    let sessionStore=SessionStore()
    var appliedRuntime="",desiredRuntime="",driverConfiguration=""
    var runtimeLatencyDiagnostics:String?,publishedNames:String?
    var lastDesiredRate=0,pendingPanelRate:Int?
    var nextRuntimeAttempt=Date.distantPast,runtimeRetry=RateRetrySchedule()
    var pendingFormatNotification:String?,notifiedFormatFailure:String?
    var failureNotified=false
    var observer:DeviceInventoryObserver?,timer:Timer?,sessionObserver:DirectoryObserver?
    var inventoryDirty=true,lastInventory=Date.distantPast
    var workStarted=ProcessInfo.processInfo.systemUptime
    var badObjectSince:Double?,badObjectFailures=0
    var recover:((String)->Void)?
    func publishStopped(_ reason:String, suspended:Bool=false) {
        running=false;runtimeLatencyDiagnostics=nil
        RuntimeConnection.write(RuntimeSnapshot(devices:devices,installed:installed,running:false,message:reason,rate:preset.sampleRate,recoveryStopped:suspended ? true : nil))
    }
    init() {
        #if !STUDIOPATCH_FAKE_AUDIO
        observer=DeviceInventoryObserver { [weak self] in self?.inventoryDirty=true;self?.runtimeTick() }
        #endif
        try? FileManager.default.createDirectory(at:RuntimeConnection.directory,withIntermediateDirectories:true)
        sessionObserver=DirectoryObserver(sessionStore.url) { [weak self] in self?.inventoryDirty=true;self?.runtimeTick() }
        runtimeTick()
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in Task { @MainActor in self?.runtimeTick() } }
    }
    func payload() throws -> String {preset.resizeChannels();return try preset.encoded(forEngine:true)}
    func requireAvailableDevices() throws {
        let missing=selected.filter { !isAvailable($0.uid) }
        if !missing.isEmpty {throw NSError(domain:"StudioPatch",code:4,userInfo:[NSLocalizedDescriptionKey:"Audio interfaces unavailable: "+missing.map(\.name).joined(separator:", ")])}
    }
    func refreshInventory() async throws {
        guard inventoryDirty || Date().timeIntervalSince(lastInventory)>5 else { return }
        let raw=try await AudioWorker.call {SPInventory()}
        let inv=try JSONDecoder().decode(Inventory.self,from:raw)
        devices=inv.devices;installed=inv.driverInstalled;driverConfiguration=inv.driverConfig;driverErrorStatus=inv.driverErrorStatus
        observer?.update(Set(devices.map(\.id)));inventoryDirty=false;lastInventory=Date()
    }
    func publishChannelNames(force:Bool=false) async throws {
        var names=try JSONSerialization.jsonObject(with:Data(runtimeChannelNames(preset:preset,devices:selected).utf8)) as! [String:Any]
        names["uid"]=preset.deviceUID; names["deviceName"]=preset.deviceName
        let raw=String(decoding:try JSONSerialization.data(withJSONObject:names,options:.sortedKeys),as:UTF8.self)
        guard force || raw != publishedNames else {return}
        let result=try await AudioWorker.call {raw.withCString {SPSetChannelNames($0)}}
        if (try JSONSerialization.jsonObject(with:result) as? [String:Any])?["ok"] as? Bool == true {publishedNames=raw}
    }
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
    func runtimeTick() {
        guard !ioBusy else {
            if ProcessInfo.processInfo.systemUptime-workStarted>30 {
                recover?("Audio control did not finish within 30 seconds.")
            }
            return
        }
        ioBusy=true;workStarted=ProcessInfo.processInfo.systemUptime
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
                // A disconnected studio still has its own (silent) virtual device.
                // Do not leave the previous preset exposed while waiting for hardware.
                if installed, preset.inputCount+preset.outputCount>0,
                   preset.devices.isEmpty || selected.contains(where: { !isAvailable($0.uid) }) {
                    await AudioWorker.stop(); running=false; appliedRuntime="";runtimeLatencyDiagnostics=nil
                    let fields=driverConfiguration.split(separator:" ")
                    let uid=fields.first == "2" && fields.count==6 ? String(fields[5]) : Preset.virtualUID
                    let shape=fields.prefix(5).compactMap { Int($0) }
                    if uid != preset.deviceUID || shape.count<5 || shape[1] != preset.inputCount || shape[2] != preset.outputCount || shape[3] != preset.sampleRate {
                        let raw=try payload()
                        _ = try await AudioWorker.call { raw.withCString { SPConfigure($0) } }
                        inventoryDirty=true;try await refreshInventory()
                        publishedNames=nil
                    }
                    try await publishChannelNames()
                }
                try requireAvailableDevices()
                if let status=driverErrorStatus {
                    throw NSError(domain:"StudioPatch.CoreAudio",code:status,userInfo:[NSLocalizedDescriptionKey:
                        "StudioPatch driver lookup failed (Core Audio \(status))."])
                }
                guard installed else { throw NSError(domain:"StudioPatch",code:21,userInfo:[NSLocalizedDescriptionKey:"The StudioPatch driver is unavailable in Core Audio."]) }
                guard !preset.devices.isEmpty else { runtimeLatencyDiagnostics=nil
                    await AudioWorker.stop(); running=false; appliedRuntime=""; message="Select audio interfaces and a sync source."; return }
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
                if state.invalidated || !state.running { appliedRuntime=""; running=false }
                if raw != appliedRuntime || !running || request>0 {
                    guard Date()>=nextRuntimeAttempt else { return }
                    let fields=driverConfiguration.split(separator:" ")
                    let current=fields.prefix(5).compactMap { Int($0) }
                    let currentUID=fields.first == "2" && fields.count == 6 ? String(fields[5]) : Preset.virtualUID
                    let formatChanged = currentUID != preset.deviceUID || current.count < 4 || current[1] != preset.inputCount || current[2] != preset.outputCount || current[3] != preset.sampleRate
                        || selected.contains { abs($0.sampleRate-Double(preset.sampleRate)) > 0.5 }
                    let format="\(preset.sampleRate) Hz · \(preset.inputCount) To Computer · \(preset.outputCount) From Computer (\(selected.map(\.name).joined(separator:", ")))"
                    if formatChanged || pendingFormatNotification != nil { pendingFormatNotification=format }
                    if running && !state.invalidated && !formatChanged && request == 0 {
                        let result=try await AudioWorker.call { raw.withCString { SPUpdateRouting($0) } }
                        if (try JSONSerialization.jsonObject(with:result) as? [String:Any])?["applied"] as? Bool == true {
                            appliedRuntime=raw
                            try await publishChannelNames()
                            message="Routing updated · audio remains active"
                            return
                        }
                    }
                    runtimeLatencyDiagnostics=nil
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
                    inventoryDirty=true
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
                    if let raw=state.latencyDiagnostics,let data=raw.data(using:.utf8),
                       let timing=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                       let members=timing["devices"] as? [[String:Any]],members.contains(where:{$0["mutedClockFault"] as? Bool == true}) {
                        message="Secondary interface muted: clock alignment was lost. Check digital clock synchronization, then restart the service."
                    }
                }
                badObjectSince=nil;badObjectFailures=0
            } catch {
                inventoryDirty=true
                publishStopped("Audio is muted · \(error.localizedDescription)")
                runtimeLatencyDiagnostics=nil
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
                let hal=error as NSError
                if hal.domain=="StudioPatch.CoreAudio" && hal.code==Int(kAudioHardwareBadObjectError) {
                    let now=ProcessInfo.processInfo.systemUptime
                    if badObjectSince == nil { badObjectSince=now }
                    badObjectFailures+=1
                    if badObjectFailures>=3 && now-(badObjectSince ?? now)>=10 {
                        recover?("Core Audio object lookup remained unavailable after retries.")
                    }
                } else { badObjectSince=nil;badObjectFailures=0 }
                let delay=runtimeRetry.failed()
                nextRuntimeAttempt=Date().addingTimeInterval(Double(delay)/1_000_000_000)
                if delay == 0 { DispatchQueue.main.async { self.runtimeTick() } }
            }
        }
    }
}
