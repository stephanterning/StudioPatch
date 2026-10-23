import AppKit
import Darwin

@main struct StudioPatchService {
    @MainActor static func main() {
        let directory=RuntimeConnection.directory
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let lock=open(directory.appendingPathComponent("runtime.lock").path,O_CREAT|O_RDWR,0o600)
        guard lock>=0, flock(lock,LOCK_EX|LOCK_NB)==0 else { return }
        // Keep the lock descriptor for the process lifetime. The panel is not our parent owner.
        let model=Model(discoverDevices:true,service:true)
        withExtendedLifetime(model) { RunLoop.main.run() }
        close(lock)
    }
}
