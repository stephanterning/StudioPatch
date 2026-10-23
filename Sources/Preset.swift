import Foundation

struct Port: Codable, Hashable {
    var deviceUID: String
    var channel: Int
}
struct Playback: Codable, Equatable {
    var deviceUID: String
    var channel: Int
    var virtualChannel: Int
}
struct Member: Codable {
    var uid: String
    var drift: Bool
    var syncLocked: Bool? = nil
}
enum PortDirection: String, Codable { case input, output }
struct ChannelLabel: Codable {
    var port: Port
    var direction: PortDirection
    var text: String
}
// Display metadata only. Runtime AudioDeviceIDs are never persisted or reused.
struct KnownDevice: Codable, Equatable {
    var uid: String
    var name: String
    var inputNames: [String]
    var outputNames: [String]
    var sampleRate: Double
}
struct Preset: Codable {
    static let virtualUID = "se.studiopatch.device.v1"
    var inputCount = 18
    var outputCount = 18
    var sampleRate = 96000
    var followMaster: Bool? = true
    var bufferFrames = 64
    var delayFrames = 256
    // Missing in older sessions means automatic; retain the manual value separately.
    var automaticTransportMargin: Bool? = true
    var usesAutomaticTransportMargin: Bool { automaticTransportMargin != false }
    var effectiveDelayFrames: Int { usesAutomaticTransportMargin ? bufferFrames * 4 : delayFrames }
    var transportMarginMilliseconds: Double { Double(effectiveDelayFrames) * 1000 / Double(sampleRate) }
    var activePresetID: UUID? = nil
    var masterUID = ""
    var devices: [Member] = []
    var knownDevices: [KnownDevice]? = nil
    var deviceDisplayOrder: [String]? = nil
    var inputs: [Port?] = Array(repeating: nil, count: 18)
    var outputs: [Playback] = []
    // Optional so presets and sessions saved before labels still decode.
    var channelLabels: [ChannelLabel]? = nil
    // Older sessions inherit the former global setting until each device has its own lock.
    func isSyncLocked(_ uid: String) -> Bool {
        devices.first { $0.uid == uid }?.syncLocked ?? (followMaster != false)
    }
    func label(for port: Port, direction: PortDirection) -> String {
        guard port.deviceUID != Self.virtualUID else { return "" }
        return channelLabels?.first { $0.port == port && $0.direction == direction }?.text ?? ""
    }
    mutating func setLabel(_ text: String, for port: Port, direction: PortDirection) {
        guard port.deviceUID != Self.virtualUID else { return }
        var labels = channelLabels ?? []
        labels.removeAll { $0.port == port && $0.direction == direction }
        if !text.isEmpty { labels.append(ChannelLabel(port:port,direction:direction,text:text)) }
        channelLabels = labels.isEmpty ? nil : labels
    }
    // Routing is persistent; exposed widths only select its active subset.
    mutating func resizeChannels() {
        inputCount = min(128,max(0,inputCount))
        outputCount = min(128,max(0,outputCount))
        while inputs.count < inputCount { inputs.append(nil) }
    }
    var activeInputs: [Port?] { Array(inputs.prefix(inputCount)) }
    var activeOutputs: [Playback] { outputs.filter { $0.virtualChannel <= outputCount } }
    var dormantRouteCount: Int {
        inputs.dropFirst(inputCount).compactMap { $0 }.count + outputs.count - activeOutputs.count
    }
    func encoded(forEngine: Bool = false) throws -> String {
        try validate()
        var configuration = self
        if forEngine {
            for index in configuration.devices.indices {
                configuration.devices[index].syncLocked = isSyncLocked(configuration.devices[index].uid)
            }
            configuration.delayFrames = effectiveDelayFrames
            configuration.activePresetID = nil
            configuration.deviceDisplayOrder = nil
            configuration.knownDevices = nil
            configuration.channelLabels = nil
            configuration.inputs = activeInputs
            configuration.outputs = activeOutputs
        }
        let encoder=JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding:try encoder.encode(configuration),as:UTF8.self)
    }
    func comparisonData() -> Data? {
        var configuration=self
        configuration.activePresetID=nil
        // Discovery metadata is refreshed by Core Audio, not edited by the user.
        configuration.knownDevices=nil
        configuration.resizeChannels()
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        return try? encoder.encode(configuration)
    }
    func validate(forEditing: Bool = false) throws {
        guard (0...128).contains(inputCount), (0...128).contains(outputCount), (forEditing || inputCount + outputCount > 0),
              (8000...384000).contains(sampleRate), [32,64,128,256,512,1024].contains(bufferFrames),
              (32...4096).contains(delayFrames), inputs.count >= inputCount, inputs.count <= 128,
              Set(devices.map(\.uid)).count == devices.count,
              outputs.allSatisfy({ $0.channel > 0 && (1...128).contains($0.virtualChannel) }),
              Set(outputs.map { Port(deviceUID:$0.deviceUID,channel:$0.channel) }).count == outputs.count,
              inputs.allSatisfy({ $0 == nil || $0!.channel > 0 }) else {
            throw NSError(domain: "StudioPatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid preset."])
        }
    }
}

// First attempt plus three immediate retries, then five seconds after each failure.
struct RateRetrySchedule {
    private(set) var failures = 0
    mutating func failed() -> UInt64 {
        failures=min(failures+1,4)
        return failures <= 3 ? 0 : 5_000_000_000
    }
}
