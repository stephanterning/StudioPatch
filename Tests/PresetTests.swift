import Foundation

@main struct PresetTests {
    static func decode(_ raw: String) throws -> Preset {
        try JSONDecoder().decode(Preset.self,from:Data(raw.utf8))
    }
    static func main() throws {
        var retries=RateRetrySchedule()
        precondition((0..<3).map { _ in retries.failed() } == [0,0,0])
        precondition((0..<10).allSatisfy { _ in retries.failed() == 5_000_000_000 })
        var fresh=RateRetrySchedule()
        precondition(fresh.failed() == 0)

        // Legacy global sync is inherited, while explicit per-device choices survive saves
        // and switching the sync source. Engine payloads always carry resolved locks.
        var sync = Preset()
        sync.devices = [Member(uid:"a",drift:false),Member(uid:"b",drift:false)]
        sync.masterUID = "a"
        sync.followMaster = false
        precondition(!sync.isSyncLocked("b"))
        sync.devices[1].syncLocked = true
        sync = try decode(sync.encoded())
        precondition(sync.isSyncLocked("b") && !sync.isSyncLocked("a"))
        sync.masterUID = "b"
        sync.masterUID = "a"
        precondition(sync.isSyncLocked("b"))
        let syncPayload = try decode(sync.encoded(forEngine:true))
        precondition(syncPayload.devices[0].syncLocked == false && syncPayload.devices[1].syncLocked == true)
        sync.followMaster = nil
        sync.devices[1].syncLocked = false
        precondition(sync.isSyncLocked("a") && !sync.isSyncLocked("b"))

        var margin = Preset()
        precondition(margin.usesAutomaticTransportMargin && margin.effectiveDelayFrames == 256)
        margin.delayFrames = 512
        margin.bufferFrames = 128
        let largerPayload = try decode(margin.encoded(forEngine:true))
        precondition(largerPayload.delayFrames == 512)
        margin.bufferFrames = 32
        let automaticPayload = try decode(margin.encoded(forEngine:true))
        precondition(automaticPayload.delayFrames == 128)
        precondition(abs(margin.transportMarginMilliseconds - 4.0/3.0) < 0.000001)
        margin.sampleRate = 48000
        precondition(abs(margin.transportMarginMilliseconds - 8.0/3.0) < 0.000001)
        margin.automaticTransportMargin = false
        let manualPayload = try decode(margin.encoded(forEngine:true))
        precondition(manualPayload.delayFrames == 512)
        margin = try decode(margin.encoded())
        precondition(!margin.usesAutomaticTransportMargin && margin.delayFrames == 512)
        margin.automaticTransportMargin = true
        let restoredAuto = try decode(margin.encoded())
        precondition(restoredAuto.effectiveDelayFrames == 128 && restoredAuto.delayFrames == 512)

        var p = Preset()
        p.inputCount = 37; p.outputCount = 21; p.resizeChannels()
        p.inputs[0] = Port(deviceUID:"ufx",channel:1)
        p.inputs[36] = Port(deviceUID:"zed",channel:7)
        p.outputs = [Playback(deviceUID:"ufx",channel:1,virtualChannel:1),
                     Playback(deviceUID:"zed",channel:2,virtualChannel:21)]
        let savedInputs = p.inputs, savedOutputs = p.outputs

        // Shrinking either direction independently never destroys routes.
        p.inputCount = 2; p.resizeChannels()
        precondition(p.inputs == savedInputs && p.outputs == savedOutputs)
        precondition(p.activeInputs.count == 2 && p.activeOutputs.count == 2)
        p.outputCount = 1; p.resizeChannels()
        precondition(p.dormantRouteCount == 2)
        let active = try decode(p.encoded(forEngine:true))
        precondition(active.inputs.count == 2 && active.inputs[0] == savedInputs[0])
        precondition(active.outputs == [savedOutputs[0]])
        precondition(!active.inputs.contains(savedInputs[36]))

        // Save/reload while reduced, then restore the original widths.
        p = try decode(p.encoded())
        try p.validate()
        precondition(p.inputs == savedInputs && p.outputs == savedOutputs)
        p.inputCount = 37; p.outputCount = 21; p.resizeChannels()
        precondition(p.activeInputs == savedInputs && p.activeOutputs == savedOutputs)
        precondition(p.dormantRouteCount == 0)

        // An entirely disabled direction keeps routes but emits none to the engine.
        p.inputCount = 0; p.resizeChannels()
        let noInput = try decode(p.encoded(forEngine:true))
        precondition(noInput.inputs.isEmpty && noInput.outputs == savedOutputs)
        p.inputCount = 37; p.outputCount = 0; p.resizeChannels()
        let noOutput = try decode(p.encoded(forEngine:true))
        precondition(noOutput.outputs.isEmpty && noOutput.inputs == savedInputs)
        p = try decode(p.encoded())
        p.outputCount = 21; p.resizeChannels()
        precondition(p.activeOutputs == savedOutputs)

        // Explicit disconnects stay disconnected when resized and saved.
        p.inputs[36] = nil
        p.outputs.removeAll { $0.virtualChannel == 21 }
        p.inputCount = 1; p.outputCount = 1; p.resizeChannels()
        p = try decode(p.encoded())
        p.inputCount = 128; p.outputCount = 128; p.resizeChannels()
        precondition(p.inputs.count == 128 && p.inputs[36] == nil)
        precondition(p.outputs == [savedOutputs[0]] && p.inputs[127] == nil)

        // Previous presets with arrays matching the exposed count remain valid.
        var legacy = try JSONSerialization.jsonObject(with:Data(Preset().encoded().utf8)) as! [String:Any]
        legacy.removeValue(forKey:"followMaster")
        legacy.removeValue(forKey:"automaticTransportMargin")
        let old = try JSONDecoder().decode(Preset.self,from:JSONSerialization.data(withJSONObject:legacy))
        try old.validate()
        precondition(old.followMaster == nil && old.inputs.count == 18)
        precondition(old.channelLabels == nil)
        precondition(old.usesAutomaticTransportMargin && old.effectiveDelayFrames == 256)
        // One source may feed several destinations in either direction.
        var fanout = Preset()
        fanout.inputs[0] = Port(deviceUID:"ufx",channel:9)
        fanout.inputs[1] = fanout.inputs[0]
        fanout.outputs = [Playback(deviceUID:"ufx",channel:1,virtualChannel:2),
                          Playback(deviceUID:"zed",channel:1,virtualChannel:2)]
        try fanout.validate()
        let routed = try decode(fanout.encoded(forEngine:true))
        precondition(routed.inputs[0] == routed.inputs[1] && routed.outputs.count == 2)
        // Two sources cannot claim one destination, even when one is dormant.
        fanout.outputs.append(Playback(deviceUID:"ufx",channel:1,virtualChannel:21))
        var rejected = false
        do { try fanout.validate() } catch { rejected = true }
        precondition(rejected)
        print("PASS: persistent routes, active-only engine payload, independent zero widths, JSON restore, explicit disconnect and legacy presets")
    }
}
