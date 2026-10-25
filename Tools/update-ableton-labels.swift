import AppKit
import Foundation

@main struct UpdateAbletonLabels {
    static func main() {
        let result:AbletonLabelResult
        do {
            let request=try JSONDecoder().decode(AbletonLabelRequest.self,from:FileHandle.standardInput.readDataToEndOfFile())
            result=try AbletonLabelSync.update(request,isRunning:{
                NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.hasPrefix("com.ableton.live") == true }
            },names:{
                guard let device=try audioDevices().first(where:{$0.uid==request.deviceUID}) else {
                    throw AbletonLabelFailure("“\(request.deviceName)” is unavailable in Core Audio. Select its preset in StudioPatch, wait for the interface to appear, then try again.")
                }
                return (device.inputs,device.outputs)
            })
        } catch { result=AbletonLabelSync.failure(error) }
        let data=try! JSONEncoder().encode(result)
        FileHandle.standardOutput.write(data)
        exit(result.success ? 0 : 1)
    }
}
