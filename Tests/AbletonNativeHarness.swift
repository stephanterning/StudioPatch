import Foundation

struct NativeFixture:Decodable {
    var request:AbletonLabelRequest
    var inputs:[String]
    var outputs:[String]
    var state:String
    var runningAt:Int?
    var changeAt:Int?
}
@main struct AbletonNativeHarness {
    static func main() throws {
        let fixture=try JSONDecoder().decode(NativeFixture.self,from:FileHandle.standardInput.readDataToEndOfFile())
        var checks=0
        let result:AbletonLabelResult
        do {
            result=try AbletonLabelSync.update(fixture.request,state:URL(fileURLWithPath:fixture.state),isRunning:{
                checks += 1
                if checks == fixture.changeAt { try! Data("Concurrent save".utf8).write(to:URL(fileURLWithPath:fixture.request.preferences)) }
                return checks == fixture.runningAt
            },names:{ (fixture.inputs,fixture.outputs) })
        } catch { result=AbletonLabelSync.failure(error) }
        FileHandle.standardOutput.write(try JSONEncoder().encode(result))
    }
}
