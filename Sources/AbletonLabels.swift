import Foundation
import Darwin

struct AbletonLabelRequest: Codable {
    var preferences: String
    var deviceUID: String
    var deviceName: String
    var apply: Bool = true
}
struct AbletonLabelResult: Codable {
    var success: Bool
    var message: String
    var backup: String? = nil
}
struct AbletonLabelFailure: LocalizedError {
    var errorDescription: String?
    init(_ message:String) { errorDescription=message }
}

// Native counterpart of Tools/ableton_preferences.py. Only existing UTF-16
// label spans are edited; reversing those edits must recover every original byte.
enum AbletonPreferences {
    static func require(_ condition:Bool,_ message:String) throws {
        if !condition { throw AbletonLabelFailure(message) }
    }
    struct Span { var start:Int; var end:Int; var value:String }
    struct Channels { var count:Int; var mono:Data; var stereo:Data; var nextID:Int; var rows:[(Int,[Span])] }
    struct Device { var inputs:Channels; var outputs:Channels }
    struct Reader {
        var data:Data; var pos=0
        mutating func take(_ count:Int) throws -> Data {
            try require(count >= 0 && pos <= data.count && count <= data.count-pos,"Truncated Ableton preferences. No changes were made.")
            defer { pos += count }; return data.subdata(in:pos..<pos+count)
        }
        mutating func integer() throws -> Int {
            let bytes=try take(4)
            return bytes.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset*8) }
        }
        mutating func kind() throws -> String {
            let code=try take(1)[0]
            if code != 0 { return "#\(code)" }
            let size=Int(try take(1)[0])
            guard let name=String(data:try take(size),encoding:.ascii) else { throw AbletonLabelFailure("Invalid Ableton schema.") }
            return name
        }
        mutating func string() throws -> Span {
            let start=pos, size=try integer()
            try require(size <= 16384,"Unexpected Ableton string length.")
            guard let value=String(data:try take(size*2),encoding:.utf16LittleEndian), !value.contains("\0") else { throw AbletonLabelFailure("Invalid Ableton channel name.") }
            return Span(start:start,end:pos,value:value)
        }
        mutating func flags() throws -> Data {
            let count=try integer()
            try require(count <= 4096,"Unexpected Ableton channel activation count.")
            let flags=try take(count)
            try require(flags.allSatisfy { $0 <= 1 },"Invalid Ableton channel activation values.")
            return flags
        }
        mutating func channels() throws -> Channels {
            let count=try integer()
            try require(count <= 4096,"Unexpected Ableton channel count.")
            let mono=try flags(), stereo=try flags(), nextID=try integer()
            var rows:[(Int,[Span])]=[], ids=Set<Int>()
            while true {
                let name=try kind()
                if name.isEmpty { break }
                try require(name == "AudioChannelNames","Unsupported Ableton channel layout.")
                let index=try integer()
                try require(index < nextID && ids.insert(index).inserted,"Invalid Ableton channel ID.")
                rows.append((index,[try string(),try string(),try string()]))
                try require(rows.count <= 4096,"Too many Ableton channel names.")
            }
            return Channels(count:count,mono:mono,stereo:stereo,nextID:nextID,rows:rows)
        }
    }
    static let schemas:[String:[String]?] = [
        "AudioLatencyFloat":["Value:#18"],
        "AudioChannelNames":["MonoL:#20","MonoR:#20","Stereo:#20"],
        "AudioChannelData":["NumPhysicalChannels:#17","MonoArray:#80","StereoArray:#80","Names:List<AudioChannelNames>"],
        "CoreAudioDevice":["BufferSize:AudioLatencyFloat","InChannelData:AudioChannelData","OutChannelData:AudioChannelData","ClockSourceIndex:#17","HistoryOpenCount:#17","UniqueId:#20"],
        "List<AudioChannelNames>":nil
    ]
    static func tag(_ name:String) -> Data { Data([0,UInt8(name.utf8.count)]) + Data(name.utf8) }
    static func parse(_ data:Data) throws -> [String:Device] {
        try require(data.count <= 32*1024*1024,"Ableton preferences exceed the supported size.")
        var r=Reader(data:data)
        try require(try r.take(5) == Data([0xab,0x1e,0x56,0x78,5]),"Unsupported Ableton preferences format. No changes were made.")
        _ = try r.take(4)
        try require(try r.kind() == "LivePreferences","This is not an Ableton Preferences.cfg file.")
        let count=try r.integer()
        try require((1...1024).contains(count),"Unsupported Ableton schema count.")
        var seen=Set<String>()
        for _ in 0..<count {
            let name=try r.kind(), size=try r.integer()
            try require(!name.isEmpty && !name.hasPrefix("#") && seen.insert(name).inserted,"Invalid Ableton schema.")
            var fields:[String]?=nil
            if size != 0xffffffff {
                try require(size <= 4096,"Unsupported Ableton schema fields.")
                fields=[]
                for _ in 0..<size { fields!.append("\(try r.string().value):\(try r.kind())") }
            }
            if let expected=schemas[name] { try require(fields == expected,"Unsupported Ableton \(name) schema. No changes were made.") }
        }
        try require(Set(schemas.keys).isSubset(of:seen),"Required Ableton schemas are missing.")
        let marker=tag("CoreAudioDevice")
        guard let first=data.range(of:marker,in:r.pos..<data.count), first.lowerBound >= r.pos+4 else {
            throw AbletonLabelFailure("No saved Core Audio devices. Open Ableton, select the StudioPatch interface in Audio Settings, then quit Ableton and try again.")
        }
        r.pos=first.lowerBound-4
        let nextID=try r.integer()
        var result:[String:Device]=[:], ids=Set<Int>()
        while true {
            let kind=try r.kind()
            if kind.isEmpty { break }
            try require(kind == "CoreAudioDevice","Unsupported Ableton device-list layout.")
            let index=try r.integer()
            try require(index < nextID && ids.insert(index).inserted,"Invalid Ableton device ID.")
            _ = try r.take(4)
            let inputs=try r.channels(), outputs=try r.channels()
            _ = try r.take(8)
            let uid=try r.string().value
            try require(!uid.isEmpty && result[uid] == nil,"Duplicate or empty Ableton device UID.")
            result[uid]=Device(inputs:inputs,outputs:outputs)
            try require(result.count <= 4096,"Too many saved Ableton devices.")
        }
        try require(data.range(of:marker,in:r.pos..<data.count) == nil,"Ambiguous Ableton device data.")
        return result
    }
    static func encoded(_ value:String) throws -> Data {
        let units=Array(value.utf16)
        try require(!value.contains("\0") && units.count <= 16384,"Invalid or oversized channel name.")
        var bytes=(0..<4).map { UInt8((units.count >> ($0*8)) & 255) }
        for unit in units { bytes += [UInt8(unit & 255),UInt8(unit >> 8)] }
        return Data(bytes)
    }
    static func pair(_ left:String,_ right:String) -> [String] {
        func groups(_ text:String,_ pattern:String) -> [String]? {
            let re=try! NSRegularExpression(pattern:pattern,options:.caseInsensitive)
            guard let m=re.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) else { return nil }
            return (1..<m.numberOfRanges).map { Range(m.range(at:$0),in:text).map { String(text[$0]) } ?? "" }
        }
        if let l=groups(left,"^(.+?)\\s+([LR])((?:\\s+\\([^()\\r\\n]*\\))?)$"), let r=groups(right,"^(.+?)\\s+([LR])((?:\\s+\\([^()\\r\\n]*\\))?)$"),
           l[1].uppercased()=="L", r[1].uppercased()=="R", l[0]==r[0], l[2]==r[2] { return ["","",(l[0]+l[2]).trimmingCharacters(in:.whitespaces)] }
        if let l=groups(left,"^(.+?\\s+)([0-9]+)$"), let r=groups(right,"^(.+?\\s+)([0-9]+)$"), l[0]==r[0], left != right { return [left,right,"\(left)/\(r[1])"] }
        return [left,right,left == right ? left : "\(left) / \(right)"]
    }
    static func patch(_ data:Data,uid:String,deviceName:String,inputs:[String],outputs:[String]) throws -> (Data,Int) {
        let instruction="Open Ableton, select “\(deviceName)” as the audio input and output device, then quit Ableton and try again."
        let devices:[String:Device]
        do { devices=try parse(data) }
        catch let error as AbletonLabelFailure where error.localizedDescription.hasPrefix("No saved Core Audio") { throw AbletonLabelFailure(instruction) }
        guard let device=devices[uid] else { throw AbletonLabelFailure("“\(deviceName)” has not been saved in this Ableton settings file. \(instruction)") }
        var edits:[(Span,Data)]=[]
        for (channels,names) in [(device.inputs,inputs),(device.outputs,outputs)] {
            try require(names.count % 2 == 0,"This Ableton format adapter requires even channel counts. No changes were made.")
            let pairs=names.count/2
            try require(channels.count == names.count && channels.mono.count == pairs && channels.stereo.count == pairs && channels.rows.count >= pairs,"Ableton has an outdated channel layout. \(instruction)")
            for index in 0..<pairs {
                for (span,value) in zip(channels.rows[index].1,pair(names[index*2],names[index*2+1])) where span.value != value { edits.append((span,try encoded(value))) }
            }
        }
        var output=data
        for (span,value) in edits.sorted(by:{ $0.0.start > $1.0.start }) { output.replaceSubrange(span.start..<span.end,with:value) }
        let after=try parse(output)[uid]!
        var inverse:[(Span,Data)]=[]
        for (old,new) in [(device.inputs,after.inputs),(device.outputs,after.outputs)] {
            try require(old.count==new.count && old.nextID==new.nextID && old.mono==new.mono && old.stereo==new.stereo && old.rows.count==new.rows.count,"Ableton channel layout changed unexpectedly.")
            for (a,b) in zip(old.rows,new.rows) {
                try require(a.0 == b.0,"Ableton channel IDs changed unexpectedly.")
                for (a,b) in zip(a.1,b.1) { inverse.append((b,try encoded(a.value))) }
            }
        }
        var recovered=output
        for (span,value) in inverse.sorted(by:{$0.0.start > $1.0.start}) { recovered.replaceSubrange(span.start..<span.end,with:value) }
        try require(recovered == data,"Changes escaped the permitted label fields. No changes were made.")
        return (output,edits.count)
    }
}

enum AbletonLabelSync {
    static var state:URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AbletonChannelNames") }
    static func update(_ request:AbletonLabelRequest, state:URL = state,
                       isRunning:() -> Bool, names:() throws -> (inputs:[String],outputs:[String])) throws -> AbletonLabelResult {
        try AbletonPreferences.require(!isRunning(),"Ableton Live is running. Quit Ableton before updating labels, then try again.")
        let path=URL(fileURLWithPath:request.preferences), fm=FileManager.default
        try fm.createDirectory(at:state,withIntermediateDirectories:true)
        let lock=open(state.appendingPathComponent("sync.lock").path,O_CREAT|O_RDWR,0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        defer { close(lock) }
        try AbletonPreferences.require(flock(lock,LOCK_EX|LOCK_NB)==0,"Another Ableton label update is running. Wait for it to finish and try again.")
        defer { flock(lock,LOCK_UN) }
        var original=stat()
        guard lstat(path.path,&original)==0 else {
            if errno == ENOENT { throw AbletonLabelFailure("Ableton settings file not found: \(path.path). Choose Preferences.cfg if it has been moved, or start and quit Ableton once to create it.") }
            throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
        }
        try AbletonPreferences.require((original.st_mode & S_IFMT)==S_IFREG,"Choose the actual Preferences.cfg file, rather than a symbolic link.")
        try AbletonPreferences.require(original.st_size <= 32*1024*1024,"Ableton preferences exceed the supported size.")
        let before=try Data(contentsOf:path), current=try names()
        try AbletonPreferences.require(!isRunning(),"Ableton started during preparation. Quit Ableton and try again; no settings were written.")
        let (after,count)=try AbletonPreferences.patch(before,uid:request.deviceUID,deviceName:request.deviceName,inputs:current.inputs,outputs:current.outputs)
        if count==0 { return AbletonLabelResult(success:true,message:"Labels are already up to date for “\(request.deviceName)”.") }
        if !request.apply { return AbletonLabelResult(success:true,message:"Preview: \(count) labels would change for “\(request.deviceName)”.") }
        let backups=state.appendingPathComponent("Backups")
        try fm.createDirectory(at:backups,withIntermediateDirectories:true)
        let backup=backups.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).cfg")
        try before.write(to:backup,options:.withoutOverwriting)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path)
        let backupFD=open(backup.path,O_RDONLY)
        guard backupFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        let backupSync=fsync(backupFD), backupError=errno
        close(backupFD)
        guard backupSync == 0 else { throw POSIXError(POSIXErrorCode(rawValue:backupError) ?? .EIO) }
        try AbletonPreferences.require(try Data(contentsOf:backup)==before,"Could not verify the preferences backup. No changes were made.")
        var template=Array(path.deletingLastPathComponent().appendingPathComponent(".channel-names-XXXXXX").path.utf8CString)
        let fd=mkstemp(&template)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        let temporary=String(cString:template)
        defer { close(fd); unlink(temporary) }
        try after.withUnsafeBytes { bytes in
            var offset=0
            while offset < bytes.count {
                let n=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
                offset += n
            }
        }
        guard fchmod(fd,original.st_mode & 0o7777)==0, fsync(fd)==0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        try AbletonPreferences.require(!isRunning(),"Ableton started during preparation. No settings were written. Quit Ableton and try again.")
        var latest=stat()
        try AbletonPreferences.require(lstat(path.path,&latest)==0 && latest.st_ino==original.st_ino && latest.st_size==original.st_size && latest.st_mtimespec.tv_sec==original.st_mtimespec.tv_sec && latest.st_mtimespec.tv_nsec==original.st_mtimespec.tv_nsec,"Ableton settings changed during preparation. No settings were written; try again.")
        try AbletonPreferences.require(try Data(contentsOf:path)==before,"Ableton settings changed during preparation. No settings were written; try again.")
        guard rename(temporary,path.path)==0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        try AbletonPreferences.require(try Data(contentsOf:path)==after,"Could not verify the written settings. Original backup: \(backup.path)")
        return AbletonLabelResult(success:true,message:"Updated \(count) labels for “\(request.deviceName)”. Ableton will read them on its next start.",backup:backup.path)
    }
    static func failure(_ error:Error) -> AbletonLabelResult {
        let ns=error as NSError
        let denied=(ns.domain==NSPOSIXErrorDomain && [EACCES,EPERM].contains(Int32(ns.code))) ||
            (ns.domain==NSCocoaErrorDomain && [NSFileReadNoPermissionError,NSFileWriteNoPermissionError].contains(ns.code))
        return AbletonLabelResult(success:false,message:denied
            ? "StudioPatch could not access Ableton’s settings or backup folder. Choose the settings file with Choose file… and grant access if macOS asks. If access is still denied, allow StudioPatch under System Settings → Privacy & Security → Files and Folders or Full Disk Access."
            : error.localizedDescription)
    }
}
