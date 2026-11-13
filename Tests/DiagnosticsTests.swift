import Foundation

@main struct DiagnosticsTests {
    static func raw(_ generation:Int=1,_ counters:[String:UInt64]=[:],skew:Double=0,timelineVersion:Int=1) throws -> String {
        var member:[String:Any]=["uid":"zed","master":false,"clockSkewFrames":skew,"peakClockSkewFrames":skew]
        for (key,value) in counters { member[key]=value }
        var value:[String:Any]=["diagnosticSchemaVersion":1,"generation":generation,"devices":[member]]
        if timelineVersion>1 { value["timelineCounterVersion"]=timelineVersion }
        return String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)
    }
    static func records(_ files:[URL]) throws -> [[String:Any]] {
        try files.flatMap { file in
            try Data(contentsOf:file).split(separator:10).map { try JSONSerialization.jsonObject(with:Data($0)) as! [String:Any] }
        }
    }
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("StudioPatch-diagnostics-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let device=Device(id:2,uid:"zed",name:"ZED R16",inputs:2,outputs:2,sampleRate:96000,aggregate:false,inputNames:[],outputNames:[])
        let recorder=AudioDiagnosticRecorder(directory:root.appendingPathComponent("Diagnostics"),maxFileBytes:3000,maxFiles:2)
        var summary=recorder.observe(raw:try raw(),fresh:true,devices:[device])
        precondition(summary.available && summary.warning == nil)
        summary=recorder.observe(raw:try raw(1,["missingPlaybackSamples":100,"timelineJumps":2],skew:20000),fresh:true,devices:[device])
        precondition(summary.warning == nil && summary.total("missingPlaybackSamples")==100)
        precondition(summary.devices[0].recent["timelineJumps"]==2) // Observations never claim loss of sync.
        summary=recorder.observe(raw:try raw(1,["missingPlaybackSamples":110,"timelineJumps":2,"incompletePlaybackBlocks":1]),fresh:true,devices:[device])
        precondition(summary.warning == nil && summary.total("incompletePlaybackBlocks")==1)
        precondition(summary.devices[0].recent["incompletePlaybackBlocks"]==1)
        summary=recorder.observe(raw:try raw(1,["bufferErrors":1,"timestampErrors":2,"incompletePlaybackBlocks":2]),fresh:true,devices:[device])
        precondition(summary.warning=="ZED R16: 1 malformed buffers, 2 invalid timestamps")
        precondition(summary.devices[0].recent["timestampErrors"]==2)
        summary=recorder.observe(raw:try raw(1,["timestampErrors":9]),fresh:false,devices:[device])
        precondition(summary.warning == nil && summary.devices[0].recent["timestampErrors"]==0)
        summary=recorder.observe(raw:try raw(1,["timestampErrors":3]),fresh:true,devices:[device])
        precondition(summary.devices[0].recent["timestampErrors"]==1) // Failed reads must not move the baseline.
        summary=recorder.observe(raw:try raw(2,["timestampErrors":1]),fresh:true,devices:[device])
        precondition(summary.generation==2 && summary.devices[0].recent["timestampErrors"]==1)
        precondition(!recorder.observe(raw:"{}",fresh:true,devices:[device]).available)
        summary=recorder.observe(raw:try raw(2,["timelineJumps":100]),fresh:true,devices:[device])
        precondition(summary.timelineCounterVersion==1)
        summary=recorder.observe(raw:try raw(2,["timelineJumps":120,"inputTimelineJumps":120,"outputTimelineJumps":60],timelineVersion:2),fresh:true,devices:[device])
        precondition(summary.timelineCounterVersion==2 && summary.devices[0].recent["timelineJumps"]==120)
        precondition(summary.total("inputTimelineJumps")==120 && summary.total("outputTimelineJumps")==60 && summary.warning == nil)
        let decoded=try JSONDecoder().decode(AudioDiagnostics.self,from:JSONEncoder().encode(summary))
        precondition(decoded.timelineCounterVersion==2 && decoded.total("timelineJumps")==120)

        // Reset is a saved view baseline. Raw observations and real-time clock
        // measurements remain intact, and future increments remain visible.
        let counterStore=DiagnosticCounterStore(directory:root),resetAt=Date(timeIntervalSince1970:1700000000)
        let original=recorder.observe(raw:try raw(2,["bufferErrors":5,"timelineJumps":7,"incompletePlaybackBlocks":3,"missingPlaybackSamples":1818550],skew:4,timelineVersion:2),fresh:true,devices:[device])
        precondition(original.warning=="ZED R16: 5 malformed buffers")
        let baseline=try counterStore.reset(original,at:resetAt)
        let zero=baseline.applying(to:original)
        precondition(AudioDiagnostics.counters.allSatisfy { zero.total($0)==0 })
        precondition(zero.devices[0].recent.values.allSatisfy {$0==0} && original.total("missingPlaybackSamples")==1818550)
        precondition(zero.devices[0].clockSkewFrames==4 && zero.devices[0].peakClockSkewFrames==4)
        let reloadedBaseline=try counterStore.load()
        precondition(reloadedBaseline?.resetAt==resetAt)
        let next=recorder.observe(raw:try raw(2,["bufferErrors":7,"timelineJumps":8,"incompletePlaybackBlocks":4,"missingPlaybackSamples":1818650],skew:6,timelineVersion:2),fresh:true,devices:[device])
        let display=baseline.applying(to:next)
        precondition(display.total("bufferErrors")==2 && display.total("timelineJumps")==1)
        precondition(display.total("incompletePlaybackBlocks")==1 && display.total("missingPlaybackSamples")==100)
        var changed=next;changed.serviceID="replacement"
        precondition(baseline.applying(to:changed).total("bufferErrors")==7)
        changed=next;changed.generation=3
        precondition(baseline.applying(to:changed).total("bufferErrors")==7)
        changed=next;changed.timelineCounterVersion=1
        precondition(baseline.applying(to:changed).total("bufferErrors")==7)
        changed=next;changed.devices[0].totals["bufferErrors"]=1
        precondition(baseline.applying(to:changed).total("bufferErrors")==0)
        let savedBaseline=try Data(contentsOf:counterStore.url)
        changed=next;changed.fresh=false
        var refused=false
        do { _ = try counterStore.reset(changed) } catch { refused=true }
        precondition(refused && (try? Data(contentsOf:counterStore.url))==savedBaseline)

        let configuration="{\"masterUID\":\"ufx\",\"devices\":[{\"uid\":\"zed\",\"drift\":false}]}"
        for i in 0..<8 {
            summary=recorder.observe(raw:try raw(2,["callbackCount":UInt64(i),"bufferErrors":UInt64(i)],timelineVersion:2),fresh:true,devices:[device])
            let snapshot=RuntimeSnapshot(devices:[device],installed:true,running:true,health:.healthy,message:"Routing active",rate:96000,diagnostics:summary)
            recorder.record(snapshot,configuration:configuration,uptime:Double(i))
        }
        recorder.flush()
        precondition(recorder.storageError == nil)
        var files=try AudioDiagnosticRecorder.logFiles(in:recorder.directory)
        precondition(files.count==2,"Retained \(files.count) logs: \(files)")
        for file in files {
            let rows=try records([file])
            precondition(rows.contains {$0["kind"] as? String == "service-segment"})
            precondition(rows.contains {$0["kind"] as? String == "configuration"})
            precondition(rows.contains {$0["kind"] as? String == "observation"})
            let observation=rows.first {$0["kind"] as? String == "observation"}!
            precondition((observation["diagnostics"] as? [String:Any])?["timelineCounterVersion"] as? Int == 2)
        }
        // A replacement service preserves the previous process's history and
        // records a distinct identity even if the engine generation repeats.
        let replacement=AudioDiagnosticRecorder(directory:recorder.directory,maxFileBytes:3000,maxFiles:2)
        let replacementSummary=replacement.observe(raw:try raw(2,timelineVersion:2),fresh:true,devices:[device])
        precondition(replacementSummary.serviceID != summary.serviceID)
        let status=RuntimeSnapshot(devices:[device],installed:true,running:true,health:.healthy,message:"Routing active",rate:96000,diagnostics:replacementSummary)
        replacement.record(status,configuration:configuration,uptime:20);replacement.flush()
        files=try AudioDiagnosticRecorder.logFiles(in:recorder.directory)
        precondition(files.count==2)
        let identities=Set(try records(files).compactMap {$0["serviceID"] as? String})
        precondition(identities.contains(recorder.serviceID) && identities.contains(replacement.serviceID))

        try JSONEncoder().encode(status).write(to:root.appendingPathComponent("runtime-status.json"))
        try Data(configuration.utf8).write(to:root.appendingPathComponent("last-session.json"))
        let append=try FileHandle(forWritingTo:files[0]);try append.seekToEnd();try append.write(contentsOf:Data("{in-progress".utf8));try append.close()
        let archive=root.appendingPathComponent("incident.zip"),markedAt=Date(timeIntervalSince1970:1700000000)
        try DiagnosticReport.save(to:archive,markedAt:markedAt,directory:root)
        let unpacked=root.appendingPathComponent("unpacked"),task=Process()
        task.executableURL=URL(fileURLWithPath:"/usr/bin/ditto");task.arguments=["-x","-k",archive.path,unpacked.path]
        try task.run();task.waitUntilExit();precondition(task.terminationStatus==0)
        let report=unpacked.appendingPathComponent("StudioPatch-Diagnostics")
        let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:report.appendingPathComponent("incident.json"))) as! [String:Any]
        precondition(manifest["markedAt"] as? String == AudioDiagnosticRecorder.timestamp(markedAt))
        precondition((manifest["warnings"] as? [String])?.contains(where:{$0.contains("Incomplete final record")})==true)
        precondition(FileManager.default.fileExists(atPath:report.appendingPathComponent(DiagnosticCounterStore.filename).path))
        let exportedBaseline=try JSONDecoder().decode(DiagnosticCounterBaseline.self,from:Data(contentsOf:report.appendingPathComponent(DiagnosticCounterStore.filename)))
        precondition(exportedBaseline.resetAt==resetAt && exportedBaseline.counters["zed"]?["missingPlaybackSamples"]==1818550)
        let exported=try FileManager.default.contentsOfDirectory(at:report,includingPropertiesForKeys:nil).filter {$0.pathExtension=="jsonl"}
        let exportedRecords=try records(exported)
        precondition(!exportedRecords.isEmpty)
        // A full/unwritable log destination is reported without an audio action.
        let blocked=root.appendingPathComponent("blocked");try Data().write(to:blocked)
        let failed=AudioDiagnosticRecorder(directory:blocked)
        failed.record(status,configuration:configuration);failed.flush();precondition(failed.storageError != nil)
        refused=false
        do { _ = try DiagnosticCounterStore(directory:blocked).reset(next) } catch { refused=true }
        precondition(refused)
        print("PASS: per-interface diagnostics, fresh-read baselines, generation changes, bounded retained history, restart identities, report export and storage failure")
    }
}
