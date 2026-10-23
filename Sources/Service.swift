import AppKit
import Darwin

@main struct StudioPatchService {
    @MainActor static func main() {
        let directory=RuntimeConnection.directory
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let lock=open(directory.appendingPathComponent("runtime.lock").path,O_CREAT|O_RDWR|O_CLOEXEC,0o600)
        guard lock>=0, flock(lock,LOCK_EX|LOCK_NB)==0 else { return }
        // Keep the lock descriptor for the process lifetime. The panel is not our parent owner.
        let model=RuntimeController()
        model.recover = { [weak model] reason in
            // Replace only this process, at most once per ten minutes across
            // process lifetimes. Never restart HAL, the broker or other clients.
            let budget=directory.appendingPathComponent("recovery-attempt.json")
            let allowed=ServiceRecovery.reserve(budget:budget,now:Date().timeIntervalSince1970)
            guard allowed else {
                model?.publishStopped("Automatic recovery stopped to avoid repeated restarts. "+reason,suspended:true)
                _exit(0) // launchd's SuccessfulExit=false must not restart us.
            }
            model?.publishStopped("Restarting the StudioPatch service once. "+reason)
            let executable=CommandLine.arguments[0]
            guard let arg=strdup(executable) else {
                model?.publishStopped("StudioPatch service recovery could not allocate its arguments.",suspended:true)
                _exit(0)
            }
            var args:[UnsafeMutablePointer<CChar>?]=[arg,nil]
            executable.withCString { path in _ = execv(path,&args) }
            free(arg)
            model?.publishStopped("StudioPatch service recovery could not restart the executable. "+reason,suspended:true)
            _exit(0)
        }
        withExtendedLifetime(model) { RunLoop.main.run() }
        close(lock)
    }
}
