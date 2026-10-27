import Foundation
import CoreAudio

#if STUDIOPATCH_FAKE_AUDIO
// No HAL listener registration/removal in the isolated runtime executable.
final class DeviceInventoryObserver {
    init(changed:@escaping ()->Void) {}
    func update(_ ids:Set<AudioObjectID>) {}
}
#else
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
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        var address = AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:element)
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
                watch(id,kAudioObjectPropertyElementName,scope:scope,element:kAudioObjectPropertyElementWildcard)
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

#endif

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
    let driverErrorStatus: Int?
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
    let stale: Bool
    let warnings: [String]
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
                        let code=(obj["coreAudioStatus"] as? NSNumber)?.intValue
                        throw NSError(domain:code == nil ? "StudioPatch" : "StudioPatch.CoreAudio",code:code ?? 3,userInfo:[NSLocalizedDescriptionKey:failure])
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

func runtimeChannelNames(preset:Preset,devices:[Device]) throws -> String {
    func name(_ channel:Int,input:Bool)->String {
        let connected:Set<Port> = input ? Set(preset.activeInputs.indices.contains(channel-1) ? [preset.activeInputs[channel-1]].compactMap{$0} : []) : Set(preset.activeOutputs.filter{$0.virtualChannel==channel}.map{Port(deviceUID:$0.deviceUID,channel:$0.channel)})
        var labels:[String]=[]
        for device in devices {
            for (index,original) in device.channelNames(input:input).enumerated() {
                let port=Port(deviceUID:device.uid,channel:index+1)
                guard connected.contains(port) else {continue}
                let text="\(device.shortName) · \(original)"
                if !labels.contains(text){labels.append(text)}
            }
        }
        return labels.isEmpty ? "\(input ? "To Computer" : "From Computer") \(channel)" : labels.joined(separator:" · ")
    }
    let names=["inputs":(0..<preset.inputCount).map{name($0+1,input:true)},"outputs":(0..<preset.outputCount).map{name($0+1,input:false)}]
    return String(decoding:try JSONSerialization.data(withJSONObject:names,options:.sortedKeys),as:UTF8.self)
}

// Observe the parent because session saves use atomic rename. Status writes in
// the same directory must not feed back into another runtime tick.
final class DirectoryObserver {
    private var source:DispatchSourceFileSystemObject?
    private let file:URL
    private var stamp=""
    private func currentStamp()->String {
        let a=(try? FileManager.default.attributesOfItem(atPath:file.path)) ?? [:]
        return "\(String(describing:a[.systemFileNumber]))|\(String(describing:a[.modificationDate]))"
    }
    init(_ file:URL,changed:@escaping ()->Void) {
        self.file=file;stamp=currentStamp()
        let fd=open(file.deletingLastPathComponent().path,O_EVTONLY)
        guard fd>=0 else{return}
        let s=DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.rename,.delete],queue:.main)
        s.setEventHandler { [weak self] in
            guard let self else{return};let next=self.currentStamp()
            if next != self.stamp {self.stamp=next;changed()}
        }
        s.setCancelHandler {close(fd)};source=s;s.resume()
    }
    deinit {source?.cancel()}
}

// Ephemeral snapshot of HAL's effective names and the driver's current defaults.
// Equality is deliberately the copy rule; HAL does not expose alias provenance.
struct CoreAudioLabels: Codable {
    var uid: String
    var inputs: [String]
    var outputs: [String]
    var defaultInputs: [String]
    var defaultOutputs: [String]
    var overrides: [ChannelLabel] {
        var result: [ChannelLabel] = []
        for input in [true,false] {
            let names=input ? inputs : outputs, defaults=input ? defaultInputs : defaultOutputs
            for (index,name) in names.enumerated() where defaults.indices.contains(index) && name != defaults[index] {
                result.append(ChannelLabel(port:Port(deviceUID:uid,channel:index+1),direction:input ? .input : .output,text:name))
            }
        }
        return result
    }
    static func read(_ uid:String) async throws -> CoreAudioLabels {
        let data=try await AudioWorker.call { uid.withCString { SPReadChannelLabels($0) } }
        return try JSONDecoder().decode(Self.self,from:data)
    }
    static func write(_ label:ChannelLabel) async throws {
        let data=try JSONSerialization.data(withJSONObject:["uid":label.port.deviceUID,"channel":label.port.channel,"direction":label.direction.rawValue,"text":label.text])
        let raw=String(decoding:data,as:UTF8.self)
        _ = try await AudioWorker.call { raw.withCString { SPSetChannelLabel($0) } }
    }
}
