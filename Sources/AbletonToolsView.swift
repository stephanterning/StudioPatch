import SwiftUI
import AppKit

@MainActor final class AbletonToolsModel: ObservableObject {
    @Published var files:[URL]=[]
    @Published var selected=""
    @Published var busy=false
    @Published var result:AbletonLabelResult?
    private var grantedURL:URL?
    private var accessing=false
    init() {
        findSettings()
        if let saved=UserDefaults.standard.string(forKey:"AbletonPreferencesPath"), !saved.isEmpty {
            let url=URL(fileURLWithPath:saved)
            if !files.contains(url) { files.append(url) }
            selected=saved; result=nil
        }
    }
    func rememberSelection() {
        UserDefaults.standard.set(selected,forKey:"AbletonPreferencesPath")
        result=nil
    }
    func findSettings() {
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/Ableton")
        do {
            files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
                .filter { $0.lastPathComponent.hasPrefix("Live 12.") }
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent,options:.numeric) == .orderedDescending }
                .map { $0.appendingPathComponent("Preferences.cfg") }
                .filter { FileManager.default.fileExists(atPath:$0.path) }
            selected=files.first?.path ?? ""
            if selected.isEmpty { result=AbletonLabelResult(success:false,message:"No Ableton Live 12 settings file was found in \(root.path). Start and quit Ableton once, or use Choose file… if Preferences.cfg is stored elsewhere.") }
        } catch {
            if (error as NSError).code == NSFileReadNoSuchFileError {
                result=AbletonLabelResult(success:false,message:"Ableton settings file not found. Start and quit Ableton once, or use Choose file… to locate Preferences.cfg.")
            } else { result=AbletonLabelSync.failure(error) }
        }
    }
    func chooseFile() {
        let panel=NSOpenPanel()
        panel.title="Choose Ableton Preferences.cfg"
        panel.message="Select the Preferences.cfg file for the Ableton Live version you use."
        panel.canChooseFiles=true; panel.canChooseDirectories=false; panel.allowsMultipleSelection=false
        panel.directoryURL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/Ableton")
        guard panel.runModal() == .OK, let url=panel.url else { return }
        if accessing { grantedURL?.stopAccessingSecurityScopedResource() }
        grantedURL=url; accessing=url.startAccessingSecurityScopedResource()
        if !files.contains(url) { files.append(url) }
        selected=url.path; rememberSelection()
    }
    func releaseAccess() {
        if accessing { grantedURL?.stopAccessingSecurityScopedResource(); accessing=false }
    }
    func update(uid:String,name:String) {
        guard !busy else { return }
        guard !NSWorkspace.shared.runningApplications.contains(where:{$0.bundleIdentifier?.hasPrefix("com.ableton.live") == true}) else {
            result=AbletonLabelResult(success:false,message:"Ableton Live is running. Quit Ableton before updating labels, then try again."); return
        }
        guard !selected.isEmpty else {
            result=AbletonLabelResult(success:false,message:"Ableton settings file not found. Use Choose file… to locate Preferences.cfg."); return
        }
        guard let helper=Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("StudioPatchAbletonLabels"),
              FileManager.default.isExecutableFile(atPath:helper.path) else {
            result=AbletonLabelResult(success:false,message:"The bundled Ableton tool is missing. Reinstall or rebuild StudioPatch."); return
        }
        let request=AbletonLabelRequest(preferences:selected,deviceUID:uid,deviceName:name)
        busy=true; result=nil
        Task {
            result=await Self.execute(helper:helper,request:request)
            busy=false
        }
    }
    nonisolated static func execute(helper:URL,request:AbletonLabelRequest) async -> AbletonLabelResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async {
                do {
                    let process=Process(), input=Pipe(), output=Pipe()
                    process.executableURL=helper
                    process.standardInput=input; process.standardOutput=output; process.standardError=FileHandle.nullDevice
                    try process.run()
                    input.fileHandleForWriting.write(try JSONEncoder().encode(request))
                    try input.fileHandleForWriting.close()
                    let data=output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard let result=try? JSONDecoder().decode(AbletonLabelResult.self,from:data),
                          !result.success || process.terminationStatus == 0 else {
                        throw AbletonLabelFailure("The Ableton tool did not return a valid result. Check the settings file and try again.")
                    }
                    continuation.resume(returning:result)
                } catch { continuation.resume(returning:AbletonLabelSync.failure(error)) }
            }
        }
    }
}

struct ToolsEditor: View {
    @ObservedObject var m:Model
    @StateObject private var tool=AbletonToolsModel()
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Text("Tools").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { m.showingTools=false }.keyboardShortcut(.cancelAction).disabled(tool.busy)
            }
            Text("Update labels in Ableton").font(.headline)
            Text("Copy current Core Audio channel labels for \(m.preset.deviceName) to Ableton Live 12. Quit Ableton first and keep it closed until the update finishes. A backup is created before any changes.")
                .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            VStack(alignment:.leading,spacing:8) {
                Text("Ableton settings file").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if !tool.files.isEmpty {
                        Picker("Settings file",selection:$tool.selected) {
                            ForEach(tool.files,id:\.path) { file in Text(file.deletingLastPathComponent().lastPathComponent).tag(file.path) }
                        }.labelsHidden().frame(maxWidth:.infinity)
                    } else { Text("Not found").foregroundStyle(.secondary); Spacer() }
                    Button("Choose file…",action:tool.chooseFile)
                }.disabled(tool.busy)
                if !tool.selected.isEmpty { Text(tool.selected).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2).help(tool.selected) }
            }
            HStack(spacing:12) {
                Button("Update labels in Ableton") { tool.update(uid:m.preset.deviceUID,name:m.preset.deviceName) }
                    .disabled(tool.busy || m.ioBusy)
                if tool.busy { ProgressView().controlSize(.small); Text("Updating labels…").foregroundStyle(.secondary) }
            }
            ScrollView {
                VStack(alignment:.leading,spacing:10) {
                    if let result=tool.result {
                        Text(result.message).foregroundStyle(result.success ? Color.green : Color.orange).textSelection(.enabled)
                        if let backup=result.backup {
                            Button("Show backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:backup)]) }
                        }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxHeight:.infinity)
        }.padding(24).frame(width:680,height:450)
        .interactiveDismissDisabled(tool.busy)
        .onChange(of:tool.selected) { _,_ in tool.rememberSelection() }
        .onDisappear { tool.releaseAccess() }
    }
}
