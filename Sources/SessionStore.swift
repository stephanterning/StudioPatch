import Foundation

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
