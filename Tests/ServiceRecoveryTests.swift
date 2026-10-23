import Foundation

@main struct ServiceRecoveryTests {
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("budget.json")
        assert(ServiceRecovery.reserve(budget:file,now:1000))
        let original=try Data(contentsOf:file)
        assert(!ServiceRecovery.reserve(budget:file,now:1599.999))
        assert(!ServiceRecovery.reserve(budget:file,now:900)) // backward clock
        assert(tryData(file)==original)
        assert(ServiceRecovery.reserve(budget:file,now:1600))
        let renewed=try Data(contentsOf:file)
        enum WriteFailure:Error {case denied}
        assert(!ServiceRecovery.reserve(budget:file,now:2200,write:{_,_ in throw WriteFailure.denied}))
        assert(tryData(file)==renewed)
        try Data("not JSON".utf8).write(to:file)
        assert(!ServiceRecovery.reserve(budget:file,now:9999))
        try Data("\"1000\"".utf8).write(to:file)
        assert(!ServiceRecovery.reserve(budget:file,now:9999))
        try FileManager.default.removeItem(at:file)
        assert(!ServiceRecovery.reserve(budget:file,now:.nan))
        assert(!ServiceRecovery.reserve(budget:file,now:.infinity))
        assert(!FileManager.default.fileExists(atPath:file.path))
        assert(!ServiceRecovery.reserve(budget:root.appendingPathComponent("missing/budget"),now:1000))
        try FileManager.default.createDirectory(at:file,withIntermediateDirectories:true)
        assert(!ServiceRecovery.reserve(budget:file,now:1000))
        print("PASS: recovery budget boundary, rollback, corrupt/wrong-type/unreadable state, failed write and invalid clock")
    }
    static func tryData(_ file:URL)->Data? {try? Data(contentsOf:file)}
}
