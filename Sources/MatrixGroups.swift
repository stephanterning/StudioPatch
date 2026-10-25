import Foundation

// Indices always refer to the original channel arrays, never display positions.
struct MatrixGroup: Equatable {
    let id:String
    let title:String
    let indices:[Int]
    var children:[MatrixGroup] = []
}

enum MatrixGrouping {
    private static let numbered = try! NSRegularExpression(pattern:"^(.+?)\\s*([0-9]+)$")
    private static func parts(_ name:String) -> (String,Int)? {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let match=numbered.firstMatch(in:name,range:NSRange(name.startIndex...,in:name)),
              let prefixRange=Range(match.range(at:1),in:name), let numberRange=Range(match.range(at:2),in:name),
              let number=Int(name[numberRange]) else { return nil }
        let prefix=String(name[prefixRange]).trimmingCharacters(in:.whitespaces)
        guard prefix.rangeOfCharacter(from:.letters) != nil, !prefix.uppercased().contains("AES") else { return nil }
        return (prefix,number)
    }
    private static func key(_ parts:[String]) -> String {
        // Length framing avoids UID/name separator collisions. End numbers are deliberately
        // excluded, so a shorter bank at a different sample rate keeps its display preference.
        parts.map { "\($0.utf8.count):\($0)" }.joined()
    }
    static func hardware(uid:String,name:String,input:Bool,names:[String],offset:Int) -> [MatrixGroup] {
        var groups:[MatrixGroup]=[], index=0
        var occurrences:[String:Int]=[:]
        while index < names.count {
            guard let (prefix,first)=parts(names[index]) else { index += 1; continue }
            var end=index+1
            while end < names.count, let (nextPrefix,number)=parts(names[end]), nextPrefix==prefix, number==first+end-index { end += 1 }
            guard end-index >= 2 else { index=end; continue }
            let occurrenceKey=key([prefix,String(first)])
            let occurrence=occurrences[occurrenceKey,default:0]
            occurrences[occurrenceKey]=occurrence+1
            let scope=["hardware",uid,input ? "input" : "output",prefix,String(first),String(occurrence)]
            func bank(_ start:Int,_ stop:Int,_ level:String) -> MatrixGroup {
                MatrixGroup(id:key(scope+[level,String(start-index)]),
                    title:"\(name) – \(prefix) \(first+start-index)–\(first+stop-index-1)",indices:Array((offset+start)..<(offset+stop)))
            }
            var group=bank(index,end,"root")
            if end-index > 16 {
                group.children=stride(from:index,to:end,by:16).map { bank($0,min($0+16,end),"bank") }
            }
            groups.append(group); index=end
        }
        return groups
    }
    static func computer(uid:String,input:Bool,count:Int) -> [MatrixGroup] {
        guard count > 0 else { return [] }
        let name=input ? "To Computer" : "From Computer"
        return stride(from:0,to:count,by:16).map { start in
            MatrixGroup(id:key(["computer",uid,name,String(start)]),title:"\(name) \(start+1)–\(min(start+16,count))",
                        indices:Array(start..<min(start+16,count)))
        }
    }
}

struct MatrixAxis {
    struct Item {
        let indices:[Int]
        let group:MatrixGroup?
        var channel:Int? { group == nil ? indices.first : nil }
    }
    struct Band {
        let group:MatrixGroup
        let depth:Int
        let start:Int
        let count:Int
        let collapsed:Bool
    }
    var items:[Item]=[]
    var bands:[Band]=[]
    var channelPositions:[Int:Int]=[:]
    init(count:Int,groups:[MatrixGroup],collapsed:Set<String>) {
        func append(_ group:MatrixGroup,_ depth:Int) {
            let start=items.count, folded=collapsed.contains(group.id)
            if folded { items.append(Item(indices:group.indices,group:group)) }
            else if group.children.isEmpty { items += group.indices.map { Item(indices:[$0],group:nil) } }
            else { for child in group.children { append(child,depth+1) } }
            bands.append(Band(group:group,depth:depth,start:start,count:items.count-start,collapsed:folded))
        }
        let starts=Dictionary(uniqueKeysWithValues:groups.compactMap { group in group.indices.first.map { ($0,group) } })
        var index=0
        while index < count {
            if let group=starts[index] { append(group,0); index=(group.indices.last ?? index)+1 }
            else { items.append(Item(indices:[index],group:nil)); index += 1 }
        }
        for (position,item) in items.enumerated() { for channel in item.indices { channelPositions[channel]=position } }
    }
}

// Display preferences are independent of the audio session and preset files.
final class MatrixFoldStore {
    private let defaults:UserDefaults
    private let key="CollapsedMatrixGroups.v1"
    init(defaults:UserDefaults = .standard) { self.defaults=defaults }
    func load() -> Set<String> { Set(defaults.stringArray(forKey:key) ?? []) }
    func save(_ groups:Set<String>) { defaults.set(groups.sorted(),forKey:key) }
}
