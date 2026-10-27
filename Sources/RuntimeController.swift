import Foundation
import CoreAudio

// Only two things stop running audio: confirmed physical disconnection, and an
// applied configuration change that needs a rebuild. Settings, label, inventory,
// status and publication failures are reported while audio keeps running. An
// applied change that then fails leaves audio off with a message and is retried
// while audio is off; it is never rolled back automatically.
@MainActor final class RuntimeController {
    var devices:[Device]=[], preset=Preset()
    var installed=false, running=false, published=false, ioBusy=false
    var driverErrorStatus:Int?
    var message="Starting audio service", notes:[String]=[]
    let sessionStore=SessionStore()
    var appliedRuntime="",desiredRuntime="",driverConfiguration=""
    var runtimeLatencyDiagnostics:String?,publishedNames:String?
    var lastDesiredRate=0,pendingPanelRate:Int?
    var nextRuntimeAttempt=Date.distantPast,runtimeRetry=RateRetrySchedule()
    var waitingForHardware=false
    var rateWarnings:[String]=[], notices=Set<String>()
    var handledRequest=0.0, rejectedRuntime="", rejection=""
    struct PendingConfiguration {
        var raw:String; var request:Double; var panelRate:Int?; var deviceName:String
        // The only rate write this change may undo: our own write to the running Sync Source.
        var wroteSyncSource=false
        // This limits polling cost, not the lifetime of the HAL request.
        var followUntil=ProcessInfo.processInfo.systemUptime+1
    }
    var pendingConfiguration:PendingConfiguration?
    // The Sync Source rate StudioPatch itself wrote while audio ran. Kept until
    // that change resolves, so an unreadable readback cannot hide our write.
    var ownSyncWrite:Int?
    var publishedUID="", activeDeviceName="StudioPatch"
    var publicationFollowUntil=0.0
    var configurationTimer:Timer?, pollConfiguration=false
    var observer:DeviceInventoryObserver?,timer:Timer?,sessionObserver:DirectoryObserver?
    var inventoryDirty=true,lastInventory=Date.distantPast
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
    func refreshInventory() async throws {
        guard inventoryDirty || Date().timeIntervalSince(lastInventory)>5 else { return }
        let raw=try await AudioWorker.call {SPInventory()}
        let inv=try JSONDecoder().decode(Inventory.self,from:raw)
        devices=inv.devices;installed=inv.driverInstalled;driverConfiguration=inv.driverConfig;driverErrorStatus=inv.driverErrorStatus
        observer?.update(Set(devices.map(\.id)));inventoryDirty=false;lastInventory=Date()
    }
    // The configuration that is actually running. It differs from `preset`
    // while a requested change is pending or rejected.
    var effective: Preset {
        guard running, let applied=try? JSONDecoder().decode(Preset.self,from:Data(appliedRuntime.utf8)) else { return preset }
        return applied
    }
    var effectiveRate: Int { running ? (Self.rate(of:appliedRuntime) ?? preset.sampleRate) : preset.sampleRate }
    // Engine payloads omit the display name; keep the running identity's name
    // when the desired preset already names another identity.
    var effectiveDeviceName:String {
        running && preset.deviceUID != effective.deviceUID ? activeDeviceName : preset.deviceName
    }
    func publishChannelNames(force:Bool=false) async throws {
        var names=try JSONSerialization.jsonObject(with:Data(runtimeChannelNames(preset:effective,devices:selectedDevices(for:effective)).utf8)) as! [String:Any]
        let name=effectiveDeviceName
        names["uid"]=effective.deviceUID; names["deviceName"]=name
        let raw=String(decoding:try JSONSerialization.data(withJSONObject:names,options:.sortedKeys),as:UTF8.self)
        guard force || raw != publishedNames else {return}
        let result=try await AudioWorker.call {raw.withCString {SPSetChannelNames($0)}}
        if (try JSONSerialization.jsonObject(with:result) as? [String:Any])?["ok"] as? Bool == true {publishedNames=raw;if running {activeDeviceName=name}}
    }
    func setDeviceAvailable(_ available:Bool, reason:String = "", notify:Bool = false) async throws {
        let raw=String(decoding:try JSONSerialization.data(withJSONObject:["available":available,"uid":effective.deviceUID]),as:UTF8.self)
        let result=try await AudioWorker.call { raw.withCString { SPSetDeviceAvailable($0) } }
        published=available
        if let value=try JSONSerialization.jsonObject(with:result) as? [String:Any] {
            publishedUID=value["uid"] as? String ?? effective.deviceUID
            if value["changed"] as? Bool == true {
                inventoryDirty=true
                if notify && !available { RuntimeConnection.notifyDisconnected(value["deviceName"] as? String ?? effectiveDeviceName,reason:reason) }
            }
        }
    }
    // One system notification per problem; a key is cleared when its problem is resolved.
    func notifyOnce(_ key:String,_ identifier:String,title:String,body:String) {
        guard notices.insert(key).inserted else { return }
        RuntimeConnection.notifyProblem(identifier,title:title,body:body)
    }
    var hardware: [Device] { devices.filter { !$0.aggregate && !$0.uid.hasPrefix("se.studiopatch.") } }
    func isAvailable(_ uid: String) -> Bool { hardware.contains { $0.uid == uid } }
    var selected: [Device] { selectedDevices(for:preset) }
    func selectedDevices(for preset:Preset) -> [Device] { preset.devices.map { member in
        if let live=hardware.first(where: { $0.uid == member.uid }) { return live }
        if let known=preset.knownDevices?.first(where: { $0.uid == member.uid }) {
            return Device(id:0,uid:known.uid,name:known.name,inputs:known.inputNames.count,outputs:known.outputNames.count,
                          sampleRate:known.sampleRate,aggregate:false,inputNames:known.inputNames,outputNames:known.outputNames)
        }
        // Old presets may never have seen this device. Do not invent last-known metadata.
        return Device(id:0,uid:member.uid,name:member.uid,inputs:0,outputs:0,sampleRate:0,aggregate:false,inputNames:[],outputNames:[])
    } }
    var currentUID: String {
        let fields=driverConfiguration.split(separator:" ")
        return fields.first == "2" && fields.count == 6 ? String(fields[5]) : Preset.virtualUID
    }
    func formatChanged() -> Bool {
        let current=driverConfiguration.split(separator:" ").prefix(5).compactMap { Int($0) }
        return currentUID != preset.deviceUID || current.count < 4 || current[1] != preset.inputCount || current[2] != preset.outputCount || current[3] != preset.sampleRate
    }
    func formatDescription() -> String {
        "\(preset.sampleRate) Hz · \(preset.inputCount) To Computer · \(preset.outputCount) From Computer (\(selected.map(\.name).joined(separator:", ")))"
    }
    func stopEngine() async {
        await AudioWorker.stop(); running=false; appliedRuntime=""; runtimeLatencyDiagnostics=nil
    }
    func loadDesired() throws {
        guard let desired=try sessionStore.load() else { return }
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
    // Inventory omits a device whose metadata could not be read. The bridge
    // decides physical absence from the UID lookup and alive flag alone.
    func confirmedMissing() async throws -> [Device] {
        let candidates=selected.filter { !isAvailable($0.uid) }
        guard !candidates.isEmpty else { return [] }
        let raw=String(decoding:try JSONSerialization.data(withJSONObject:["uids":candidates.map(\.uid)]),as:UTF8.self)
        let result=try await AudioWorker.call { raw.withCString { SPMissingDevices($0) } }
        let missing=Set((try JSONSerialization.jsonObject(with:result) as? [String:Any])?["missing"] as? [String] ?? [])
        return candidates.filter { missing.contains($0.uid) }
    }
    func withdrawIfDisconnected() async throws -> Bool {
        guard installed else { return false }
        let reason:String, disconnected:Bool
        if preset.devices.isEmpty { reason="Select audio interfaces and a sync source."; disconnected=false }
        else {
            let missing=try await confirmedMissing()
            guard !missing.isEmpty else { return false }
            reason="Audio interfaces unavailable: "+missing.map(\.name).joined(separator:", "); disconnected=true
        }
        await stopEngine()
        waitingForHardware=true;pendingConfiguration=nil;ownSyncWrite=nil
        message="StudioPatch interface unavailable · \(reason)"
        do { try await setDeviceAvailable(false,reason:reason,notify:disconnected) } catch { notes.append(error.localizedDescription) }
        return true
    }
    func runtimeTick() {
        guard !ioBusy else { return }
        configurationTimer?.invalidate();configurationTimer=nil
        ioBusy=true;notes=[];pollConfiguration=false
        Task { [self] in
            defer {
                ioBusy=false
                RuntimeConnection.write(RuntimeSnapshot(devices:devices,installed:installed,running:running,
                    message:([message]+notes).joined(separator:" · "),rate:effectiveRate,latencyDiagnostics:runtimeLatencyDiagnostics))
                // One short burst per accepted transaction / started engine.
                // Expiry only reduces polling to the ordinary heartbeat; it
                // never cancels the request, withdraws a device or stops audio.
                let now=ProcessInfo.processInfo.systemUptime
                let confirming=pollConfiguration && pendingConfiguration.map { now<$0.followUntil } == true
                let publishing=running && !published && now<publicationFollowUntil
                if confirming || publishing {
                    configurationTimer=Timer.scheduledTimer(withTimeInterval:0.025,repeats:false) { [weak self] _ in
                        Task { @MainActor in self?.runtimeTick() }
                    }
                }
            }
            do { try loadDesired() }
            catch { notes.append("Settings could not be read; keeping the current configuration (\(error.localizedDescription))") }
            do { try await refreshInventory() }
            catch { inventoryDirty=true; notes.append("Device inventory failed: \(error.localizedDescription)") }
            do { if try await withdrawIfDisconnected() { return } }
            catch { notes.append("Interface availability could not be confirmed: \(error.localizedDescription)") }
            if waitingForHardware { nextRuntimeAttempt = .distantPast;runtimeRetry=RateRetrySchedule();waitingForHardware=false }
            if let problem = !installed ? "The StudioPatch driver is unavailable in Core Audio." :
                driverErrorStatus.map({ "StudioPatch driver lookup failed (Core Audio \($0))." }) {
                if running { notes.append(problem) } else { message="Audio is off · "+problem }
                return
            }
            await update()
        }
    }
    func update() async {
        var applying=false
        do {
            var raw=try payload()
            // Without fresh rate information the current rate stays in effect.
            var request=0.0, masterRate=effectiveRate
            var observedMasterRate:Int?
            do {
                let rates=try await AudioWorker.call { raw.withCString { SPRuntimeRates($0) } }
                let values=try JSONSerialization.jsonObject(with:rates) as? [String:Any] ?? [:]
                request=values["requested"] as? Double ?? 0
                if let rate=values["masterRate"] as? Double { masterRate=Int(rate); observedMasterRate=Int(rate) }
            } catch { notes.append("Sample-rate status unavailable; keeping the current rate (\(error.localizedDescription))") }
            if request>0 && request == handledRequest {
                // Already applied or refused; only the acknowledgement is outstanding.
                await acknowledge(request)
                request=0
            }
            if request>0 { pendingPanelRate=nil; preset.sampleRate=Int(request) }
            else if let panelRate=pendingPanelRate { preset.sampleRate=panelRate }
            else { preset.sampleRate=masterRate }
            raw=try payload()
            if raw != desiredRuntime { desiredRuntime=raw; nextRuntimeAttempt = .distantPast; runtimeRetry=RateRetrySchedule() }
            var status:EngineStatus?
            do {
                status=try JSONDecoder().decode(EngineStatus.self,from:try await AudioWorker.call { SPStatus() })
                runtimeLatencyDiagnostics=status?.running == true ? status?.latencyDiagnostics : nil
                if status?.running == false { running=false; appliedRuntime="" }
            } catch { notes.append("Engine status unavailable: \(error.localizedDescription)") }
            // Resolve an accepted HAL request even if the user edits back to
            // the old preset meanwhile. Never abandon a committed generation.
            if let pending=pendingConfiguration {
                guard Date()>=nextRuntimeAttempt else { return }
                applying=true
                try await applyConfiguration(pending)
                return
            }
            let stale=status?.stale == true
            let hardwareRateChanged=running && preset.masterUID == effective.masterUID && observedMasterRate.map { $0 != effectiveRate } == true
            if raw != rejectedRuntime || (hardwareRateChanged && Self.rate(of:rejectedRuntime) != observedMasterRate) { rejectedRuntime=""; rejection="" }
            if running && !stale && request == 0 && ((raw == appliedRuntime && !hardwareRateChanged) || raw == rejectedRuntime) {
                await maintain()
                if let status {
                    let problems=[syncProblem,rejection].compactMap { $0?.isEmpty == false ? $0 : nil }
                    message=(["Routing active · \(status.bufferFrames) samples I/O · \(status.badBuffers) buffer errors"]+status.warnings+rateWarnings+problems).joined(separator:" · ")
                }
                return
            }
            guard Date()>=nextRuntimeAttempt else { return }
            if running && !stale && !hardwareRateChanged && !formatChanged() && request == 0 {
                do {
                    let result=try await AudioWorker.call { raw.withCString { SPUpdateRouting($0) } }
                    if (try JSONSerialization.jsonObject(with:result) as? [String:Any])?["applied"] as? Bool == true {
                        appliedRuntime=raw
                        await maintain()
                        message="Routing updated · audio remains active"
                        return
                    }
                } catch {
                    notes.append("Routing update failed; the previous routing remains active (\(error.localizedDescription))")
                    return
                }
            }
            applying=true
            try await rebuild(raw,request:request,force:stale,hardwareRateChanged:hardwareRateChanged)
        } catch {
            if applying {
                if running { deferChange(error.localizedDescription) } else { applyFailed(error) }
            } else { notes.append(error.localizedDescription) }
        }
    }
    func maintain() async {
        do { try await publishChannelNames() }
        catch { notes.append("Channel names were not updated: \(error.localizedDescription)") }
        do { _ = try await AudioWorker.call { SPPublishLatency() } }
        catch { notes.append("Latency report was not updated: \(error.localizedDescription)") }
        let problem=syncProblem
        notices=notices.filter { !$0.hasPrefix("sync:") || $0 == "sync:"+(problem ?? "") }
        if let problem { notifyOnce("sync:"+problem,"sync-mismatch",title:"sample rate not in sync",body:problem) }
        guard !published else { return }
        do { try await setDeviceAvailable(true) }
        catch { notes.append("StudioPatch device not yet published: \(error.localizedDescription)") }
    }
    // Sync lock follows the Sync Source when StudioPatch changes the rate. A
    // locked interface changed elsewhere is reported, never set back while running.
    var syncProblem: String? {
        let active=effective
        guard let source=hardware.first(where:{$0.uid==active.masterUID})?.sampleRate, source>0 else { return nil }
        let outOfSync=hardware.filter { member in
            member.uid != active.masterUID && active.devices.contains(where: { $0.uid == member.uid }) && active.isSyncLocked(member.uid) &&
                member.sampleRate>0 && abs(member.sampleRate-source)>0.5
        }
        guard !outOfSync.isEmpty else { return nil }
        return outOfSync.map { "\($0.name) runs at \(Int($0.sampleRate)) Hz" }.joined(separator:", ")+"; the Sync Source runs at \(Int(source)) Hz (not in sync)."
    }
    func acknowledge(_ request:Double) async {
        let ack="{\"ack\":\(request)}"
        do { _ = try await AudioWorker.call { ack.withCString { SPAcknowledgeRate($0) } }; handledRequest=0 }
        catch { handledRequest=request; notes.append("Sample-rate request was not acknowledged: \(error.localizedDescription)") }
    }
    static func rate(of raw:String) -> Int? {
        (try? JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any])?["sampleRate"] as? Int
    }
    func deferChange(_ reason:String) {
        message=pendingConfiguration == nil
            ? "Requested change not yet applied: \(reason) The current configuration remains active."
            : "Configuration confirmation failed: \(reason) The hardware engine is still running; audio through the new session is not yet confirmed."
        let delay=runtimeRetry.failed()
        nextRuntimeAttempt=Date().addingTimeInterval(Double(delay)/1_000_000_000)
    }
    // The Sync Source did not reach the requested rate. StudioPatch keeps the rate it runs at.
    func refuseRate(_ wanted:Int,staying:Int,request:Double,reason:String) async {
        pendingPanelRate=nil
        if request>0 { await acknowledge(request) }
        let text="The Sync Source could not change to \(wanted) Hz; StudioPatch stays at \(staying) Hz."
        message=([text]+rateWarnings).joined(separator:" · ")
        notifyOnce("rate:\(wanted)","rate-refused",title:"sample rate not changed",body:([text,reason]).filter { !$0.isEmpty }.joined(separator:" "))
    }
    func rebuild(_ requested:String,request:Double,force:Bool=false,hardwareRateChanged:Bool=false) async throws {
        var raw=requested
        let wanted=preset.sampleRate
        var actual=wanted
        let sameSource=running && preset.masterUID == effective.masterUID
        // Hardware rates are set only when the rate changes or audio starts.
        // An unrelated change must not set back a locked interface that was
        // changed elsewhere; that is only reported.
        if !running || wanted != effectiveRate || hardwareRateChanged {
            if running && wanted != effectiveRate {
                // Do not touch hardware when the control path is known to be
                // unavailable. This is not permission to stop the old engine.
                _ = try await AudioWorker.call { raw.withCString { SPPrepareChange($0) } }
            }
            let rates=try JSONSerialization.jsonObject(with:try await AudioWorker.call { raw.withCString { SPSetHardwareRate($0) } }) as? [String:Any] ?? [:]
            rateWarnings=rates["warnings"] as? [String] ?? []
            if sameSource && rates["wroteSyncSource"] as? Bool == true { ownSyncWrite=wanted }
            guard let confirmed=(rates["rate"] as? Double).map({Int($0.rounded())}), confirmed>0 else {
                let reason=(["The Sync Source rate could not be confirmed."]+rateWarnings).joined(separator:" ")
                guard running else { throw NSError(domain:"StudioPatch",code:25,userInfo:[NSLocalizedDescriptionKey:reason]) }
                // Keep the running engine; a later readable rate decides what runs.
                await refuseRate(wanted,staying:effectiveRate,request:request,reason:reason)
                return
            }
            actual=confirmed
            if actual != wanted {
                await refuseRate(wanted,staying:actual,request:request,reason:rateWarnings.joined(separator:" "))
                preset.sampleRate=actual; raw=try payload()
            }
        }
        if running && raw == appliedRuntime && !force {
            ownSyncWrite=nil
            pendingPanelRate=nil
            if request>0 { await acknowledge(request) }
            if actual == wanted { message=(["Routing remains active at \(effectiveRate) Hz"]+rateWarnings).joined(separator:" · ") }
            return
        }
        try await applyConfiguration(PendingConfiguration(raw:raw,request:request,panelRate:pendingPanelRate,deviceName:preset.deviceName,
                                                          wroteSyncSource:sameSource && ownSyncWrite == actual))
    }
    func applyConfiguration(_ change:PendingConfiguration) async throws {
        let raw=change.raw
        let configuration=try JSONSerialization.jsonObject(with:try await AudioWorker.call { raw.withCString { SPConfigure($0) } }) as? [String:Any] ?? [:]
        pendingConfiguration=configuration["pending"] as? Bool == true ? change : nil
        if let failure=configuration["failure"] as? String {
            throw NSError(domain:"StudioPatch",code:27,userInfo:[NSLocalizedDescriptionKey:failure])
        }
        if configuration["rejected"] as? Bool == true {
            if running { await reject(change); return }
            throw NSError(domain:"StudioPatch",code:26,userInfo:[NSLocalizedDescriptionKey:"Core Audio rejected the configuration."])
        }
        guard configuration["ok"] as? Bool == true else {
            pollConfiguration=true
            message="Waiting for Core Audio to finish the configuration; audio through the new session is not yet confirmed."
            return
        }
        // HAL has now applied the new generation. Only this commit boundary
        // permits replacing the old hardware graph. A start failure from here
        // leaves audio off and is retried while audio is off.
        let target=try JSONDecoder().decode(Preset.self,from:Data(raw.utf8))
        // The driver's UID commit withdraws the old endpoint and leaves the
        // replacement unpublished until its engine clock is available.
        if published && publishedUID != target.deviceUID { published=false }
        ownSyncWrite=nil
        await stopEngine()
        inventoryDirty=true
        do { try await refreshInventory() }
        catch { notes.append("Device inventory failed: \(error.localizedDescription)") }
        _ = try await AudioWorker.call { raw.withCString { SPStart($0) } }
        appliedRuntime=raw; desiredRuntime=raw; activeDeviceName=change.deviceName; running=true
        publicationFollowUntil=ProcessInfo.processInfo.systemUptime+1
        do { try await publishChannelNames(force:true) }
        catch { notes.append("Channel names were not updated: \(error.localizedDescription)") }
        if pendingPanelRate == change.panelRate { pendingPanelRate=nil }
        notices=notices.filter { $0.hasPrefix("sync:") }; runtimeRetry=RateRetrySchedule()
        if change.request>0 { await acknowledge(change.request) }
        do { try await setDeviceAvailable(true) }
        catch { notes.append("StudioPatch device not yet published: \(error.localizedDescription)") }
        message=(["Routing active · \(effective.bufferFrames) samples I/O · \(effectiveRate) Hz"]+rateWarnings).joined(separator:" · ")
    }
    // HAL refused the change before commit, so the old engine never stopped.
    // Undo only our own Sync Source write from this attempt, once.
    func reject(_ change:PendingConfiguration) async {
        var parts=["Requested change not applied: Core Audio rejected the configuration. The previous configuration remains active."]
        if change.wroteSyncSource {
            let previous=appliedRuntime
            let data=try? await AudioWorker.call { previous.withCString { SPSetHardwareRate($0) } }
            let result=data.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
            if let rate=result?["rate"] as? Double, Int(rate.rounded())==effectiveRate { parts.append("Hardware restored to \(effectiveRate) Hz.") }
            else { parts.append("The hardware rate could not be restored to \(effectiveRate) Hz.") }
            rateWarnings+=result?["warnings"] as? [String] ?? []
            inventoryDirty=true
        }
        ownSyncWrite=nil
        rejectedRuntime=change.raw
        rejection=parts.joined(separator:" ")
        message=rejection
        if change.request>0 { await acknowledge(change.request) }
        notifyOnce("rejected:"+change.raw,"format-failed",title:"audio format change failed",body:"Could not set \(formatDescription()). "+rejection)
        runtimeRetry=RateRetrySchedule()
    }
    func applyFailed(_ error:Error) {
        message="Audio is off · \(error.localizedDescription)"
        inventoryDirty=true
        notifyOnce("failure","runtime-failure",title:"audio is off",
                   body:"Could not apply \(formatDescription()). \(error.localizedDescription) StudioPatch will retry automatically.")
        let delay=runtimeRetry.failed()
        nextRuntimeAttempt=Date().addingTimeInterval(Double(delay)/1_000_000_000)
        if delay == 0 { DispatchQueue.main.async { self.runtimeTick() } }
    }
}
