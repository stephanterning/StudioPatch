import Foundation

struct AudioDiagnosticClock: Codable {
    var valid:Bool, entryHost:UInt64, cycleHost:UInt64
    var sample:Double
}
struct AudioDiagnosticDevice: Codable, Identifiable {
    var uid:String, name:String, master:Bool
    var totals:[String:UInt64], recent:[String:UInt64]
    var callbackAgeMs:Double?, clockSkewFrames:Double?, peakClockSkewFrames:Double?
    var mappingOffsetFrames:Double?, lastSampleStepFrames:Double?
    var callbackClock:AudioDiagnosticClock?
    var lastEventHosts:[String:UInt64]
    var nominalSampleRate:Double?,blockFrames:Int?,inputSkewFrames:Int?,outputSkewFrames:Int?
    var lastInputSampleStepFrames:Double?,lastOutputSampleStepFrames:Double?
    var id:String { uid }
}

struct AudioDiagnostics: Codable {
    var serviceID:String
    var generation:UInt64?
    var observedAt:Date
    var fresh:Bool, available:Bool
    var devices:[AudioDiagnosticDevice]
    var timelineCounterVersion:Int?
    static let counters=["callbackCount","bufferErrors","timestampErrors","clockUnavailable","counterResets",
        "timelineJumps","inputTimelineJumps","outputTimelineJumps","realignments","playbackSamples","missingPlaybackSamples","incompletePlaybackBlocks"]
    func total(_ key:String) -> UInt64 { devices.reduce(0) { $0+($1.totals[key] ?? 0) } }
    var warning:String? {
        guard fresh, available else { return nil }
        let problems=devices.compactMap { device -> String? in
            // A partial block can occur when playback starts or stops within a callback.
            let errors=[("bufferErrors","malformed buffers"),("timestampErrors","invalid timestamps")].compactMap { key,label -> String? in
                let count=device.recent[key] ?? 0
                return count>0 ? "\(count) \(label)" : nil
            }
            return errors.isEmpty ? nil : device.name+": "+errors.joined(separator:", ")
        }
        return problems.isEmpty ? nil : problems.joined(separator:" · ")
    }
}

struct DiagnosticCounterBaseline: Codable {
    let resetAt:Date, serviceID:String, generation:UInt64, timelineCounterVersion:Int
    let counters:[String:[String:UInt64]]
    init(_ diagnostics:AudioDiagnostics,at:Date=Date()) throws {
        guard diagnostics.available,diagnostics.fresh,let generation=diagnostics.generation,generation>0,
              !diagnostics.devices.isEmpty,diagnostics.devices.allSatisfy({!$0.uid.isEmpty}),
              Set(diagnostics.devices.map(\.uid)).count==diagnostics.devices.count else {
            throw NSError(domain:"StudioPatch",code:40,userInfo:[NSLocalizedDescriptionKey:"Wait for fresh audio diagnostics before resetting counters."])
        }
        resetAt=at;serviceID=diagnostics.serviceID;self.generation=generation
        timelineCounterVersion=diagnostics.timelineCounterVersion ?? 1
        counters=Dictionary(uniqueKeysWithValues:diagnostics.devices.map { ($0.uid,$0.totals) })
    }
    func matches(_ diagnostics:AudioDiagnostics) -> Bool {
        serviceID==diagnostics.serviceID && generation==diagnostics.generation && timelineCounterVersion==(diagnostics.timelineCounterVersion ?? 1)
    }
    func applying(to diagnostics:AudioDiagnostics) -> AudioDiagnostics {
        guard matches(diagnostics) else { return diagnostics }
        var result=diagnostics
        for index in result.devices.indices {
            let baseline=counters[result.devices[index].uid] ?? [:]
            for (key,total) in diagnostics.devices[index].totals {
                let start=baseline[key] ?? 0
                let value=total>=start ? total-start : 0
                result.devices[index].totals[key]=value
                // A status snapshot can straddle the reset. Only show interval
                // increases that also exist after the new starting point.
                result.devices[index].recent[key]=min(result.devices[index].recent[key] ?? 0,value)
            }
        }
        return result
    }
}

final class DiagnosticCounterStore {
    static let filename="diagnostic-counter-baseline.json"
    let url:URL
    init(directory:URL) { url=directory.appendingPathComponent(Self.filename) }
    func load() throws -> DiagnosticCounterBaseline? {
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        return try JSONDecoder().decode(DiagnosticCounterBaseline.self,from:Data(contentsOf:url))
    }
    func reset(_ diagnostics:AudioDiagnostics,at:Date=Date()) throws -> DiagnosticCounterBaseline {
        let baseline=try DiagnosticCounterBaseline(diagnostics,at:at)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(baseline).write(to:url,options:.atomic)
        return baseline
    }
}

// The service is the only log writer. File work runs on a separate queue,
// never on a callback or while holding the bridge's audio-control mutex.
final class AudioDiagnosticRecorder {
    let serviceID=UUID().uuidString
    let directory:URL
    private let queue=DispatchQueue(label:"se.studiopatch.diagnostic-log",qos:.utility)
    private let errorLock=NSLock()
    private var writeFailure:String?
    var storageError:String? { errorLock.lock(); defer { errorLock.unlock() }; return writeFailure }
    private var previous:AudioDiagnostics?
    private var lastRecordUptime = -Double.infinity
    private var lastState=""
    private var file:FileHandle?, bytes=0, segment=0
    private var lastContext:String?
    private let maxFileBytes:Int, maxFiles:Int

    init(directory:URL=RuntimeConnection.directory.appendingPathComponent("Diagnostics"),
         maxFileBytes:Int=8*1024*1024,maxFiles:Int=16) {
        precondition(maxFileBytes>0 && maxFiles>0)
        self.directory=directory;self.maxFileBytes=maxFileBytes;self.maxFiles=maxFiles
    }

    func observe(raw:String?,fresh:Bool,devices:[Device],now:Date=Date()) -> AudioDiagnostics {
        let values=raw.flatMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) } as? [String:Any] ?? [:]
        let generation=(values["generation"] as? NSNumber)?.uint64Value
        let available=(values["diagnosticSchemaVersion"] as? Int)==1
        let timelineVersion=values["timelineCounterVersion"] as? Int ?? 1
        let sameGeneration=previous?.generation == generation && previous?.available == true && previous?.timelineCounterVersion == timelineVersion
        let members=(values["devices"] as? [[String:Any]] ?? []).compactMap { member -> AudioDiagnosticDevice? in
            guard let uid=member["uid"] as? String else { return nil }
            var totals:[String:UInt64]=[:],recent:[String:UInt64]=[:]
            let old=sameGeneration ? previous?.devices.first(where:{$0.uid==uid}) : nil
            for key in AudioDiagnostics.counters {
                let value=(member[key] as? NSNumber)?.uint64Value ?? 0
                totals[key]=value
                let baseline=old?.totals[key] ?? 0
                recent[key]=fresh ? (value>=baseline ? value-baseline : value) : 0
            }
            return AudioDiagnosticDevice(uid:uid,name:devices.first(where:{$0.uid==uid})?.name ?? uid,
                master:member["master"] as? Bool ?? false,totals:totals,recent:recent,
                callbackAgeMs:member["lastCallbackAgeMs"] as? Double,
                clockSkewFrames:member["clockSkewFrames"] as? Double,peakClockSkewFrames:member["peakClockSkewFrames"] as? Double,
                mappingOffsetFrames:member["mappingOffsetFrames"] as? Double,lastSampleStepFrames:member["lastSampleStepFrames"] as? Double,
                callbackClock:(member["callbackClock"] as? [String:Any]).flatMap { value in
                    (try? JSONSerialization.data(withJSONObject:value)).flatMap { try? JSONDecoder().decode(AudioDiagnosticClock.self,from:$0) }
                },lastEventHosts:(member["lastEventHosts"] as? [String:NSNumber] ?? [:]).mapValues(\.uint64Value),
                nominalSampleRate:devices.first(where:{$0.uid==uid})?.sampleRate,blockFrames:member["blockFrames"] as? Int,
                inputSkewFrames:member["inputSkewFrames"] as? Int,outputSkewFrames:member["outputSkewFrames"] as? Int,
                lastInputSampleStepFrames:member["lastInputSampleStepFrames"] as? Double,lastOutputSampleStepFrames:member["lastOutputSampleStepFrames"] as? Double)
        }
        let result=AudioDiagnostics(serviceID:serviceID,generation:generation,observedAt:fresh ? now : previous?.observedAt ?? now,fresh:fresh,available:available,devices:members,timelineCounterVersion:timelineVersion)
        if fresh { previous=result }
        return result
    }

    func record(_ snapshot:RuntimeSnapshot,configuration:String,uptime:Double=ProcessInfo.processInfo.systemUptime) {
        let observations=snapshot.diagnostics?.devices.map { device in
            ["bufferErrors","timestampErrors","timelineJumps","counterResets","realignments","incompletePlaybackBlocks"].map { "\(device.uid):\($0)=\(device.totals[$0] ?? 0)" }.joined(separator:",")
        }.joined(separator:";") ?? ""
        let state="\(snapshot.running)|\(snapshot.health)|\(snapshot.message)|\(snapshot.diagnostics?.generation ?? 0)|\(snapshot.diagnostics?.timelineCounterVersion ?? 1)|\(observations)|\(configuration)"
        guard uptime-lastRecordUptime>=1 || state != lastState else { return }
        let interval=lastRecordUptime.isFinite ? uptime-lastRecordUptime : 0
        lastRecordUptime=uptime;lastState=state
        do {
            let summary=snapshot.diagnostics.map { try? JSONSerialization.jsonObject(with:JSONEncoder().encode($0)) } ?? nil
            let engine=snapshot.latencyDiagnostics.flatMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) } as? [String:Any] ?? [:]
            var transport=engine.filter { ["rate","bufferFrames","inputPadding","outputPadding","inputSafety","outputSafety",
                "captureMisses","playbackMisses","routingUpdates","clockEpoch","snapshotHost","ticksPerFrame","reportedLatency","timingEnabled","playbackPublications"].contains($0.key) }
            // Timing-only evidence stays bounded to the last failed read per
            // interface and survives later status updates in logs and exports.
            let playbackReadFailures=(engine["devices"] as? [[String:Any]] ?? []).compactMap { member -> [String:Any]? in
                guard let uid=member["uid"] as? String,let failure=member["lastMissingPlayback"] as? [String:Any] else { return nil }
                return ["uid":uid,"lastMissingPlayback":failure]
            }
            if !playbackReadFailures.isEmpty { transport["playbackReadFailures"]=playbackReadFailures }
            let record:[String:Any]=["schemaVersion":1,"kind":"observation","serviceID":serviceID,
                "timestamp":Self.timestamp(snapshot.date),"uptimeSeconds":uptime,"intervalSeconds":interval,
                "running":snapshot.running,"health":snapshot.health.rawValue,"message":snapshot.message,
                "diagnostics":summary ?? NSNull(),"transport":transport]
            let context:[String:Any]=["schemaVersion":1,"kind":"configuration","serviceID":serviceID,
                "timestamp":Self.timestamp(snapshot.date),"uptimeSeconds":uptime,
                "configuration":(try? JSONSerialization.jsonObject(with:Data(configuration.utf8))) ?? NSNull(),
                "devices":snapshot.devices.map { ["uid":$0.uid,"name":$0.name,"sampleRate":$0.sampleRate,"inputs":$0.inputs,"outputs":$0.outputs] }]
            let data=try Self.line(record),contextData=try Self.line(context)
            queue.async { [self] in
                do {
                    if file == nil || bytes+data.count+contextData.count>maxFileBytes { try rotate() }
                    if lastContext != configuration { try append(contextData);lastContext=configuration }
                    try append(data)
                    errorLock.lock();writeFailure=nil;errorLock.unlock()
                } catch {
                    try? file?.close();file=nil
                    errorLock.lock();writeFailure=error.localizedDescription;errorLock.unlock()
                }
            }
        } catch {
            errorLock.lock();writeFailure=error.localizedDescription;errorLock.unlock()
        }
    }
    // Used by isolated tests; the running engine never waits for log storage.
    func flush() { queue.sync {} }
    private func append(_ data:Data) throws { try file?.write(contentsOf:data);bytes+=data.count }
    private func rotate() throws {
        try file?.close();file=nil
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        segment+=1;bytes=0;lastContext=nil
        let url=directory.appendingPathComponent("audio-\(Self.timestamp(Date()).replacingOccurrences(of:":",with:"-"))-\(serviceID)-\(segment).jsonl")
        guard FileManager.default.createFile(atPath:url.path,contents:nil) else { throw CocoaError(.fileWriteUnknown) }
        file=try FileHandle(forWritingTo:url)
        let start:[String:Any]=["schemaVersion":1,"kind":"service-segment","serviceID":serviceID,
            "timestamp":Self.timestamp(Date()),"pid":ProcessInfo.processInfo.processIdentifier,
            "os":ProcessInfo.processInfo.operatingSystemVersionString,"build":Self.buildIdentity()]
        try append(Self.line(start))
        let files=try Self.logFiles(in:directory)
        // Directory listings can canonicalize /var to /private/var. Compare
        // unique filenames so the active file is not counted twice or removed.
        for old in files.filter({$0.lastPathComponent != url.lastPathComponent}).dropFirst(maxFiles-1) { try FileManager.default.removeItem(at:old) }
    }
    static func logFiles(in directory:URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey,.isRegularFileKey])
            .filter { $0.lastPathComponent.hasPrefix("audio-") && $0.pathExtension=="jsonl" && (try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true }
            .sorted { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }
    static func timestamp(_ date:Date) -> String {
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return formatter.string(from:date)
    }
    static func line(_ object:[String:Any]) throws -> Data { var data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);data.append(10);return data }
    static func buildIdentity() -> [String:Any] {
        let executable=URL(fileURLWithPath:CommandLine.arguments[0])
        let attributes=try? FileManager.default.attributesOfItem(atPath:executable.path)
        let resources=executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let panelInfo=resources.appendingPathComponent("panel-build-info.json")
        let resource=executable.lastPathComponent=="StudioPatch" && FileManager.default.fileExists(atPath:panelInfo.path)
            ? panelInfo : resources.appendingPathComponent("build-info.json")
        var identity=(try? Data(contentsOf:resource)).flatMap { try? JSONSerialization.jsonObject(with:$0) } as? [String:Any] ?? [:]
        identity.merge(["version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unbundled",
            "executable":executable.lastPathComponent,"executableBytes":attributes?[.size] ?? NSNull(),
            "executableModified":(attributes?[.modificationDate] as? Date).map(timestamp) ?? "unknown"]) { _,new in new }
        return identity
    }
}

enum DiagnosticReport {
    // A report is a point-in-time copy. An in-progress final JSONL record is
    // omitted and recorded in the manifest; older complete records survive.
    static func save(to destination:URL,markedAt:Date,directory:URL=RuntimeConnection.directory) throws {
        let fm=FileManager.default,temporary=fm.temporaryDirectory.appendingPathComponent("StudioPatch-report-\(UUID().uuidString)")
        let report=temporary.appendingPathComponent("StudioPatch-Diagnostics")
        try fm.createDirectory(at:report,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:temporary) }
        var warnings:[String]=[],copied:[String]=[]
        let baseline=DiagnosticCounterStore.filename
        let optional=FileManager.default.fileExists(atPath:directory.appendingPathComponent(baseline).path) ? [baseline] : []
        for name in ["runtime-status.json","last-session.json"]+optional {
            do { try Data(contentsOf:directory.appendingPathComponent(name)).write(to:report.appendingPathComponent(name));copied.append(name) }
            catch { warnings.append("\(name): \(error.localizedDescription)") }
        }
        let logs=directory.appendingPathComponent("Diagnostics")
        var files:[URL]=[]
        do { files=try AudioDiagnosticRecorder.logFiles(in:logs) }
        catch { warnings.append("Diagnostic history unavailable: \(error.localizedDescription)") }
        for source in files {
            do {
                var data=try Data(contentsOf:source)
                if let newline=data.lastIndex(of:10) {
                    if newline+1<data.count { warnings.append("Incomplete final record omitted: \(source.lastPathComponent)");data=data.prefix(newline+1) }
                } else { warnings.append("No complete records: \(source.lastPathComponent)");continue }
                try data.write(to:report.appendingPathComponent(source.lastPathComponent));copied.append(source.lastPathComponent)
            } catch { warnings.append("\(source.lastPathComponent): \(error.localizedDescription)") }
        }
        let marker:[String:Any]=["schemaVersion":1,"kind":"user-reported-audio-problem",
            "markedAt":AudioDiagnosticRecorder.timestamp(markedAt),"exportedAt":AudioDiagnosticRecorder.timestamp(Date()),
            "build":AudioDiagnosticRecorder.buildIdentity(),"files":copied,"warnings":warnings,
            "notes":"No audio samples are recorded. Missing playback samples can include idle periods. Timestamp deviation does not establish hardware clock lock. Counters reset with each engine generation; serviceID and generation distinguish restarts. Timeline counter version 1 includes callback scheduling variation; version 2 compares input/output buffer frame ranges. The optional diagnostic-counter-baseline.json describes the panel's displayed counter interval; retained observations remain cumulative."]
        try AudioDiagnosticRecorder.line(marker).write(to:report.appendingPathComponent("incident.json"))
        let archive=temporary.appendingPathComponent("report.zip")
        let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/bin/ditto")
        task.arguments=["-c","-k","--keepParent",report.path,archive.path]
        task.standardOutput=FileHandle.nullDevice;task.standardError=FileHandle.nullDevice
        try task.run();task.waitUntilExit()
        guard task.terminationStatus==0 else { throw CocoaError(.fileWriteUnknown) }
        if fm.fileExists(atPath:destination.path) { _ = try fm.replaceItemAt(destination,withItemAt:archive) }
        else { try fm.moveItem(at:archive,to:destination) }
    }
}
