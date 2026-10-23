import Foundation

// Called under the service singleton lock; reserve durably before replacing the
// process. Injecting the writer lets tests exercise failures without permissions.
enum ServiceRecovery {
    static func reserve(budget:URL,now:Double,
                        write:(Data,URL)throws->Void = { try $0.write(to:$1,options:.atomic) }) -> Bool {
        guard now.isFinite else { return false }
        if FileManager.default.fileExists(atPath:budget.path) {
            guard let data=try? Data(contentsOf:budget),
                  let previous=try? JSONDecoder().decode(Double.self,from:data),
                  previous.isFinite,now-previous>=600 else { return false }
        }
        do {
            try write(JSONEncoder().encode(now),budget)
            return true
        } catch { return false }
    }
}
