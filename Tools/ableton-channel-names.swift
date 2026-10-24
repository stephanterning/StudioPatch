import AppKit
import CoreAudio
import Foundation

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: UInt32 = 0) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func audioString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 _ element: UInt32 = 0) -> String? {
    var key = address(selector, scope, element)
    var result: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout.size(ofValue: result))
    guard AudioObjectGetPropertyData(id, &key, 0, nil, &size, &result) == noErr else { return nil }
    return result?.takeRetainedValue() as String?
}

struct AudioDevice: Codable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputs: [String]
    let outputs: [String]
}

func channelNames(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) throws -> [String] {
    var key = address(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &key, 0, nil, &size) == noErr else {
        throw Failure("Cannot read channel count for device \(id).")
    }
    if size == 0 { return [] }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    guard AudioObjectGetPropertyData(id, &key, 0, nil, &size, memory) == noErr else {
        throw Failure("Cannot read channels for device \(id).")
    }
    let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
    let count = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    guard count <= 4096 else { throw Failure("Unexpected channel count: \(count).") }
    return (0..<count).map { index in
        let name = audioString(id, kAudioObjectPropertyElementName, scope, UInt32(index + 1))
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? "\(index + 1)"
    }
}

func audioDevices() throws -> [AudioDevice] {
    var key = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &size) == noErr else {
        throw Failure("Cannot enumerate Core Audio devices.")
    }
    guard size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    let status = ids.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &size, $0.baseAddress!)
    }
    guard status == noErr else { throw Failure("Cannot enumerate Core Audio devices (\(status)).") }
    return try ids.map { id in
        AudioDevice(id: id, uid: audioString(id, kAudioDevicePropertyDeviceUID) ?? "",
                    name: audioString(id, kAudioObjectPropertyName) ?? "Device \(id)",
                    inputs: try channelNames(id, kAudioObjectPropertyScopeInput),
                    outputs: try channelNames(id, kAudioObjectPropertyScopeOutput))
    }
}

// This helper only reads Core Audio and the running application inventory.
struct Snapshot: Encodable {
    let liveRunning: Bool
    let devices: [AudioDevice]
}

do {
    let running = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier?.hasPrefix("com.ableton.live") == true
    }
    let mode = CommandLine.arguments.dropFirst().first ?? "--list"
    guard ["--list", "--snapshot", "--running"].contains(mode) else {
        throw Failure("Expected --list, --snapshot or --running.")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if mode == "--running" {
        print(running ? "true" : "false")
    } else {
        let devices = try audioDevices()
        guard !devices.isEmpty else { throw Failure("Core Audio returned no devices. Run outside a sandbox.") }
        let data = mode == "--list" ? try encoder.encode(devices) : try encoder.encode(Snapshot(liveRunning: running, devices: devices))
        print(String(decoding: data, as: UTF8.self))
    }
} catch { fputs("Error: \(error)\n", stderr); exit(1) }
