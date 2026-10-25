import Foundation

// Physical channel aliases belong to the interface, independently of preset UIDs.
final class SourceLabelStore {
    let url: URL
    init(url: URL) { self.url=url }
    func load() throws -> [ChannelLabelKey:String] {
        guard FileManager.default.fileExists(atPath:url.path) else { return [:] }
        let labels=try JSONDecoder().decode([ChannelLabel].self,from:Data(contentsOf:url))
        var result:[ChannelLabelKey:String]=[:]
        for label in labels {
            let key=ChannelLabelKey(port:label.port,direction:label.direction)
            guard !label.port.deviceUID.isEmpty, label.port.channel > 0,
                  !label.text.isEmpty, label.text.utf8.count <= 4096, !label.text.contains("\0"),
                  result[key] == nil else {
                throw NSError(domain:"StudioPatch",code:35,userInfo:[NSLocalizedDescriptionKey:"Invalid interface labels. The file has not been changed."])
            }
            result[key]=label.text
        }
        return result
    }
    func set(_ label:ChannelLabel) throws -> [ChannelLabelKey:String] {
        // Reload before writing: an unreadable file must never be replaced with an empty registry.
        var labels=try load()
        let port=label.port, text=label.text
        guard !port.deviceUID.isEmpty, port.channel > 0, text.utf8.count <= 4096, !text.contains("\0"),
              !text.contains("\n"), !text.contains("\r") else {
            throw NSError(domain:"StudioPatch",code:35,userInfo:[NSLocalizedDescriptionKey:"Enter a single-line label of at most 4096 UTF-8 bytes."])
        }
        labels[ChannelLabelKey(port:port,direction:label.direction)]=text.isEmpty ? nil : text
        var entries:[ChannelLabel]=labels.map { ChannelLabel(port:$0.key.port,direction:$0.key.direction,text:$0.value) }
        entries.sort { a,b in
            if a.port.deviceUID == b.port.deviceUID {
                if a.direction != b.direction { return a.direction.rawValue < b.direction.rawValue }
                return a.port.channel < b.port.channel
            }
            return a.port.deviceUID < b.port.deviceUID
        }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(entries).write(to:url,options:.atomic)
        return labels
    }
}

final class SessionStore {
    let url: URL
    private var preserveUnreadable = false

    init(url: URL = (ProcessInfo.processInfo.environment["STUDIOPATCH_TEST_DIRECTORY"].map { URL(fileURLWithPath:$0).appendingPathComponent("last-session.json") }) ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        .appendingPathComponent("StudioPatch/last-session.json")) {
        self.url = url
    }
    func load() throws -> Preset? {
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        do {
            let preset = try JSONDecoder().decode(Preset.self,from:Data(contentsOf:url))
            try preset.validate(forEditing:true)
            return preset
        } catch {
            preserveUnreadable = true
            throw error
        }
    }
    func save(_ preset: Preset) throws {
        // A count field can publish its new value before the UI extends inputs.
        // Save a normalized copy, including all dormant routing and empty 0/0 edits.
        var snapshot = preset
        snapshot.resizeChannels()
        try snapshot.validate(forEditing:true)
        let data = try JSONEncoder().encode(snapshot)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if preserveUnreadable {
            let backup = directory.appendingPathComponent("unreadable-session-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at:url,to:backup)
            preserveUnreadable = false
        }
        try data.write(to:url,options:.atomic)
    }
}

struct PresetSlot: Codable, Identifiable {
    var id: UUID
    var name: String
    var configuration: Preset
    var updatedAt: Date
}

final class PresetLibraryStore {
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> [PresetSlot] {
        guard FileManager.default.fileExists(atPath:url.path) else { return [] }
        let slots = try JSONDecoder().decode([PresetSlot].self,from:Data(contentsOf:url))
        try validate(slots)
        return slots
    }
    private func validate(_ slots: [PresetSlot]) throws {
        guard Set(slots.map(\.id)).count == slots.count,
              Set(slots.map { $0.configuration.deviceUID }).count == slots.count,
              slots.allSatisfy({ !$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) else {
            throw NSError(domain:"StudioPatch",code:30,userInfo:[NSLocalizedDescriptionKey:"Invalid preset library."])
        }
        for slot in slots { try slot.configuration.validate(forEditing:true) }
    }
    func save(_ slots: [PresetSlot]) throws {
        try validate(slots)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let data = try JSONEncoder().encode(slots)
        try data.write(to:url,options:.atomic)
    }
}
