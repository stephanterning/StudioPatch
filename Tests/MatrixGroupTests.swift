import AppKit

@main struct MatrixGroupTests {
    @MainActor static func main() throws {
        let suite="StudioPatch.MatrixGroupTests.\(UUID().uuidString)"
        // This suite is isolated from the user's actual collapse preferences.
        let isolated=UserDefaults(suiteName:suite)!
        defer { isolated.removePersistentDomain(forName:suite) }
        let store=MatrixFoldStore(defaults:isolated)
        let names=(1...8).map { "Analog \($0)" } + (9...12).map { "Mic \($0)" } + ["AES L","AES R"] + (1...16).map { "ADAT \($0)" } + (1...64).map { "MADI \($0)" }
        let groups=MatrixGrouping.hardware(uid:"ufx",name:"UFX III",input:true,names:names,offset:0)
        precondition(groups.map(\.title)==["UFX III – Analog 1–8","UFX III – Mic 9–12","UFX III – ADAT 1–16","UFX III – MADI 1–64"])
        let madi=groups[3]
        precondition(madi.children.map(\.indices.count)==[16,16,16,16])
        precondition(madi.children.map(\.title)==["UFX III – MADI 1–16","UFX III – MADI 17–32","UFX III – MADI 33–48","UFX III – MADI 49–64"])
        let zed=MatrixGrouping.hardware(uid:"zed",name:"ZED-R16",input:true,names:(1...18).map { "Input \($0)" },offset:94)
        precondition(zed[0].children.map(\.indices.count)==[16,2] && zed[0].indices.first==94)
        let irregular=MatrixGrouping.hardware(uid:"x",name:"X",input:true,names:["Analog 1","Analog 2","Analog 4","Analog 5","AES 1","AES 2","Left","Right","10","11"],offset:0)
        precondition(irregular.map(\.indices)==[[0,1],[2,3]])
        let output=MatrixGrouping.hardware(uid:"ufx",name:"UFX III",input:false,names:names,offset:0)
        precondition(Set(groups.map(\.id)).isDisjoint(with:output.map(\.id)))
        let moved=MatrixGrouping.hardware(uid:"ufx",name:"Renamed interface",input:true,names:names,offset:18)
        precondition(moved.map(\.id)==groups.map(\.id))
        let fewer=MatrixGrouping.hardware(uid:"ufx",name:"UFX III",input:true,names:Array(names.prefix(14))+(1...8).map { "ADAT \($0)" }+(1...32).map { "MADI \($0)" },offset:0)
        precondition(fewer.last!.id==madi.id && fewer.last!.children[1].id==madi.children[1].id)
        let computer=MatrixGrouping.computer(uid:"preset-a",input:true,count:46)
        precondition(computer.map(\.indices.count)==[16,16,14])
        precondition(computer.map(\.id) != MatrixGrouping.computer(uid:"preset-b",input:true,count:46).map(\.id))
        precondition(computer[2].id==MatrixGrouping.computer(uid:"preset-a",input:true,count:40)[2].id)
        let axis=MatrixAxis(count:112,groups:groups+zed,collapsed:[madi.id,zed[0].children[0].id])
        precondition(axis.items.flatMap(\.indices)==Array(0..<112))
        precondition(axis.items[12].channel==12 && axis.items[13].channel==13) // AES remains individual.
        precondition(axis.items.filter { $0.group != nil }.count==2)
        let rows=(1...46).map { "To Computer \($0)\nLabel \($0)" }
        let columns=names.map { "UFX III · \($0)\nHardware label" }
        // Fan-out: three destinations use the same MADI source, including two hidden rows.
        let routes:Set<Int>=[0*94+30,1*94+30,17*94+30,31*94+47]
        var clicks:[(Int,Int)]=[]
        let matrix=FrozenMatrixView(foldStore:store)
        matrix.frame=NSRect(x:0,y:0,width:1100,height:600)
        func update(_ enabled:Bool=true) {
            matrix.update(rows:rows,columns:columns,selected:routes,enabled:enabled,rowGroups:computer,columnGroups:groups,
                unavailableRows:[1],unavailableColumns:[47],showsInputLabels:true,
                rowLabelStatuses:(0..<46).map { [0,1,17].contains($0) ? .mismatch : .matched },onClick:{ clicks.append(($0,$1)) })
            matrix.layoutSubtreeIfNeeded()
        }
        update()
        matrix.toggleGroup(computer[0],row:true)
        matrix.toggleGroup(madi,row:false)
        precondition(matrix.rowAxis.items.count==31 && matrix.columnAxis.items.count==31)
        precondition(matrix.connectionCount(row:0,column:30)==2 && matrix.hasLiveConnection(row:0,column:30))
        precondition(matrix.rowSummary(0)=="2 connections" && matrix.mismatchCount(computer[0].indices)==2)
        precondition(matrix.syncLabelRect(0,side:.source)==nil && matrix.headerIndex(row:true,at:NSPoint(x:60,y:2))==nil)
        precondition(matrix.sourceText(forRow:17)==columns[30]) // Exact source survives hidden source bank.
        precondition(matrix.syncLabelRect(17,side:.source) != nil)
        matrix.activateCell(row:0,column:30) // Both axes open, with no routing edit.
        precondition(clicks.isEmpty && matrix.selected==routes && matrix.rowAxis.items.count==46 && matrix.columnAxis.items.count==94)
        matrix.toggleGroup(computer[1],row:true)
        matrix.toggleGroup(madi.children[1],row:false)
        let hiddenColumn=matrix.columnAxis.channelPositions[47]!
        precondition(matrix.connectionCount(row:16,column:hiddenColumn)==1 && !matrix.hasLiveConnection(row:16,column:hiddenColumn))
        matrix.activateCell(row:16,column:hiddenColumn)
        precondition(clicks.isEmpty)
        matrix.toggleGroup(computer[0],row:true)
        matrix.toggleGroup(groups[0],row:false)
        // The visible row/column no longer equal physical channel indices.
        matrix.activateCell(row:2,column:2)
        precondition(clicks.last!.0==17 && clicks.last!.1==9)
        let count=clicks.count
        matrix.activateCell(row:0,column:0) // Empty collapsed intersection only expands.
        precondition(clicks.count==count)
        matrix.activateCell(row:1,column:0) // Unavailable destination is still locked.
        matrix.activateCell(row:31,column:47) // Unavailable source is still locked.
        precondition(clicks.count==count)
        update(false)
        matrix.toggleGroup(madi,row:false)
        matrix.activateCell(row:0,column:30) // Browsing works while audio controls are busy.
        matrix.activateCell(row:0,column:30)
        precondition(clicks.count==count)
        update()
        matrix.scroll.contentView.scroll(to:NSPoint(x:1000,y:100))
        matrix.toggleGroup(madi.children[1],row:false)
        let before=matrix.columnAxis.channelPositions[46]!
        precondition(matrix.scroll.contentView.bounds.minX <= CGFloat(before)*matrix.cell)
        let rect=matrix.syncLabelRect(17,side:.source)!
        precondition(matrix.syncLabelRow(at:NSPoint(x:rect.midX,y:rect.midY))==17)
        let band=matrix.columnAxis.bands.first { $0.group.id==madi.children[1].id }!
        let bandRect=matrix.bandRect(band,row:false)
        precondition(matrix.band(at:NSPoint(x:bandRect.midX,y:bandRect.midY),row:false)?.group.id==band.group.id)
        let saved=store.load()
        precondition(saved.contains(madi.children[1].id))
        update() // Routine polling must not reset folds.
        precondition(matrix.collapsed==saved)
        let reopened=FrozenMatrixView(foldStore:MatrixFoldStore(defaults:isolated))
        precondition(reopened.collapsed==saved)
        // Changing direction or preset does not erase other devices' display preferences.
        reopened.update(rows:["Other"],columns:["Other"],selected:[],enabled:true,onClick:{_,_ in})
        precondition(store.load()==saved)
        print("PASS: inferred banks, stable identity, projection, safe expansion, routing indices, availability, labels and persistence")
    }
}
