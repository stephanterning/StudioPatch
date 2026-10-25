import SwiftUI
import AppKit

enum LabelSide: CaseIterable {
    case source, destination
    var copyArrow:String { self == .source ? "← " : " →" }
}

enum LabelMatchStatus {
    case matched, mismatch, unavailable, updating
    var nsColor:NSColor {
        switch self {
        case .matched: return .systemGreen
        case .mismatch: return .systemOrange
        case .unavailable, .updating: return .gray
        }
    }
    var help:String {
        switch self {
        case .matched: return "Labels match"
        case .mismatch: return "Label mismatch, click to copy this label to the other side"
        case .unavailable: return "Label comparison unavailable"
        case .updating: return "Updating label…"
        }
    }
}

struct Matrix: NSViewRepresentable {
    let rows: [String]
    let columns: [String]
    let selected: Set<Int>
    let enabled: Bool
    var rowGroups:[MatrixGroup] = []
    var columnGroups:[MatrixGroup] = []
    var unavailableRows: Set<Int> = []
    var unavailableColumns: Set<Int> = []
    var showsInputLabels = false
    var rowLabelStatuses: [LabelMatchStatus] = []
    var onLabelSyncClick: (Int,LabelSide)->Void = { _,_ in }
    let onHeaderDoubleClick: (Bool,Int)->Void
    let onClick: (Int,Int)->Void

    func makeNSView(context: Context) -> FrozenMatrixView { FrozenMatrixView() }
    func updateNSView(_ view: FrozenMatrixView, context: Context) {
        view.update(rows:rows,columns:columns,selected:selected,enabled:enabled,rowGroups:rowGroups,columnGroups:columnGroups,unavailableRows:unavailableRows,unavailableColumns:unavailableColumns,
                    showsInputLabels:showsInputLabels,rowLabelStatuses:rowLabelStatuses,onLabelSyncClick:onLabelSyncClick,
                    onHeaderDoubleClick:onHeaderDoubleClick,onClick:onClick)
    }
}

final class FrozenMatrixView: NSView {
    let sourceWidth:CGFloat = 205, cell:CGFloat = 32, bandSize:CGFloat = 22
    var rowGutter:CGFloat { rowGroups.isEmpty ? 0 : bandSize*2 }
    var columnGutter:CGFloat { columnGroups.isEmpty ? 0 : bandSize*2 }
    var rowWidth:CGFloat { 235+rowGutter }
    var headerHeight:CGFloat { 170+columnGutter }
    private var rowGroups:[MatrixGroup]=[], columnGroups:[MatrixGroup]=[]
    private let foldStore:MatrixFoldStore
    private(set) var collapsed:Set<String>
    private(set) var rowAxis=MatrixAxis(count:0,groups:[],collapsed:[])
    private(set) var columnAxis=MatrixAxis(count:0,groups:[],collapsed:[])
    private var connectionCounts:[Int:Int]=[:], liveConnectionCounts:[Int:Int]=[:]
    private var rowConnectionCounts:[Int:Int]=[:]
    private var sources:[Int:Int]=[:]
    private var unavailableDisplayRows=Set<Int>(), unavailableDisplayColumns=Set<Int>()
    var frozenWidth: CGFloat { rowWidth+sourceWidth }
    let scroll = NSScrollView()
    private let grid = MatrixPane(.grid)
    private let rowHeader = MatrixPane(.rows)
    private let columnHeader = MatrixPane(.columns)
    private let corner = MatrixPane(.corner)
    private var observer: NSObjectProtocol?
    var rows: [String] = [], columns: [String] = []
    var selected = Set<Int>()
    var enabled = true
    var unavailableRows = Set<Int>(), unavailableColumns = Set<Int>()
    var showsInputLabels = false
    var rowLabelStatuses: [LabelMatchStatus] = []
    var onLabelSyncClick: (Int,LabelSide)->Void = { _,_ in }
    var onClick: (Int,Int)->Void = {_,_ in}
    var onHeaderDoubleClick: (Bool,Int)->Void = {_,_ in}
    private(set) var hoveredRow: Int?
    private(set) var hoveredColumn: Int?
    override var isFlipped: Bool { true }

    init(foldStore:MatrixFoldStore = MatrixFoldStore()) {
        self.foldStore=foldStore; collapsed=foldStore.load()
        super.init(frame:.zero)
        wantsLayer = true
        clipsToBounds = true
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = grid
        scroll.contentView.postsBoundsChangedNotifications = true
        for pane in [grid,rowHeader,columnHeader,corner] { pane.matrix = self }
        addSubview(scroll)
        addSubview(rowHeader)
        addSubview(columnHeader)
        addSubview(corner)
        corner.setAccessibilityElement(true)
        corner.setAccessibilityRole(.staticText)
        corner.setAccessibilityLabel("Blue: Core Audio Label. Green: Interface Label. Orange: Label Mismatch.")
        grid.setAccessibilityElement(true)
        grid.setAccessibilityRole(.group)
        grid.setAccessibilityLabel("Routing matrix with frozen destination and source headers.")
        observer = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,
            object:scroll.contentView,queue:.main) { [weak self] _ in
                self?.rowHeader.needsDisplay = true
                self?.columnHeader.needsDisplay = true
                self?.refreshToolTips()
                self?.refreshHover()
            }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func update(rows: [String], columns: [String], selected: Set<Int>, enabled: Bool,
                rowGroups:[MatrixGroup] = [], columnGroups:[MatrixGroup] = [],
                unavailableRows: Set<Int> = [], unavailableColumns: Set<Int> = [],
                showsInputLabels: Bool = false, rowLabelStatuses: [LabelMatchStatus] = [],
                onLabelSyncClick: @escaping (Int,LabelSide)->Void = { _,_ in },
                onHeaderDoubleClick: @escaping (Bool,Int)->Void = {_,_ in},
                onClick: @escaping (Int,Int)->Void) {
        self.rows=rows; self.columns=columns; self.selected=selected
        self.rowGroups=rowGroups; self.columnGroups=columnGroups
        self.enabled=enabled; self.onClick=onClick
        self.unavailableRows=unavailableRows; self.unavailableColumns=unavailableColumns
        self.onHeaderDoubleClick=onHeaderDoubleClick
        self.showsInputLabels=showsInputLabels; self.rowLabelStatuses=rowLabelStatuses
        self.onLabelSyncClick=onLabelSyncClick
        rebuildProjection()
        setHover(at:nil)
        needsLayout=true
        for pane in [grid,rowHeader,columnHeader,corner] { pane.needsDisplay=true }
    }
    func canEdit(row: Int, column: Int) -> Bool {
        guard enabled, rows.indices.contains(row), columns.indices.contains(column) else { return false }
        return !unavailableRows.contains(row) && !unavailableColumns.contains(column)
    }
    func sourceColumn(forRow row: Int) -> Int? {
        sources[row]
    }
    func sourceText(forRow row:Int) -> String? {
        guard rows.indices.contains(row), let source=sourceColumn(forRow:row) else { return nil }
        return columns[source]
    }
    func syncLabelRect(_ row:Int, side:LabelSide) -> NSRect? {
        guard rowLabelStatuses.indices.contains(row), rows.indices.contains(row),
              let position=rowAxis.channelPositions[row], rowAxis.items[position].channel != nil,
              let source=sourceText(forRow:row) else { return nil }
        let labelled=side == .source ? source : rows[row]
        let parts=labelled.components(separatedBy:"\n")
        guard parts.count > 1 else { return nil }
        let label=parts.dropFirst().joined(separator:" ") + (copySide(row:row,side:side)?.copyArrow ?? "")
        let columnWidth=side == .source ? sourceWidth : rowWidth-rowGutter
        let width=min(columnWidth-24,(label as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:10,weight:.medium)]).width+2)
        return NSRect(x:(side == .source ? rowWidth : rowGutter)+12,y:CGFloat(position)*cell-scroll.contentView.bounds.minY+16,width:width,height:13)
    }
    func syncLabelRow(at point:NSPoint) -> Int? {
        guard enabled, let row=headerIndex(row:true,at:point), rowLabelStatuses.indices.contains(row),
              rowLabelStatuses[row] == .mismatch, let rect=syncLabelRect(row,side:point.x < rowWidth ? .destination : .source), rect.contains(point) else { return nil }
        return row
    }
    func copySide(row:Int, side:LabelSide) -> LabelSide? {
        enabled && rowLabelStatuses.indices.contains(row) && rowLabelStatuses[row] == .mismatch ? side : nil
    }
    func labelColor(row:Int, side:LabelSide) -> NSColor {
        guard rowLabelStatuses.indices.contains(row) else { return .systemCyan }
        let status=rowLabelStatuses[row]
        let hardwareSide:LabelSide=showsInputLabels ? .source : .destination
        return status == .matched && side != hardwareSide ? .systemCyan : status.nsColor
    }
    func setHover(at point: NSPoint?) {
        var row: Int?, column: Int?
        if let point, point.x>=0,point.y>=0 {
            let r=Int(point.y/cell),c=Int(point.x/cell)
            if rowAxis.items.indices.contains(r),columnAxis.items.indices.contains(c) { row=r; column=c }
        }
        guard row != hoveredRow || column != hoveredColumn else { return }
        hoveredRow=row; hoveredColumn=column
        for pane in [grid,rowHeader,columnHeader] { pane.needsDisplay=true }
    }
    func refreshHover() {
        guard let window else { setHover(at:nil); return }
        let point=grid.convert(window.mouseLocationOutsideOfEventStream,from:nil)
        setHover(at:grid.visibleRect.contains(point) ? point : nil)
    }
    func visibleIndex(row:Bool,at point:NSPoint) -> Int? {
        let coordinate=row ? point.y+scroll.contentView.bounds.minY : point.x+scroll.contentView.bounds.minX
        guard coordinate>=0 else { return nil }
        let index=Int(coordinate/cell)
        return (row ? rowAxis.items.indices.contains(index) : columnAxis.items.indices.contains(index)) ? index : nil
    }
    func headerIndex(row: Bool, at point: NSPoint) -> Int? {
        guard let position=visibleIndex(row:row,at:point) else { return nil }
        return (row ? rowAxis : columnAxis).items[position].channel
    }
    private func rebuildProjection() {
        rowAxis=MatrixAxis(count:rows.count,groups:rowGroups,collapsed:collapsed)
        columnAxis=MatrixAxis(count:columns.count,groups:columnGroups,collapsed:collapsed)
        connectionCounts=[:]; liveConnectionCounts=[:]; rowConnectionCounts=[:]; sources=[:]
        for route in selected where !columns.isEmpty {
            let row=route/columns.count, column=route%columns.count
            guard let r=rowAxis.channelPositions[row], let c=columnAxis.channelPositions[column] else { continue }
            let key=r*columnAxis.items.count+c
            connectionCounts[key,default:0] += 1
            rowConnectionCounts[r,default:0] += 1
            sources[row]=column
            if !unavailableRows.contains(row) && !unavailableColumns.contains(column) { liveConnectionCounts[key,default:0] += 1 }
        }
        unavailableDisplayRows=Set(rowAxis.items.indices.filter { rowAxis.items[$0].indices.allSatisfy { unavailableRows.contains($0) } })
        unavailableDisplayColumns=Set(columnAxis.items.indices.filter { columnAxis.items[$0].indices.allSatisfy { unavailableColumns.contains($0) } })
    }
    func connectionCount(row:Int,column:Int) -> Int { connectionCounts[row*columnAxis.items.count+column,default:0] }
    func hasLiveConnection(row:Int,column:Int) -> Bool { liveConnectionCounts[row*columnAxis.items.count+column,default:0]>0 }
    func displayUnavailable(row:Int,column:Int) -> Bool { unavailableDisplayRows.contains(row) || unavailableDisplayColumns.contains(column) }
    func mismatchCount(_ indices:[Int]) -> Int { indices.filter { rowLabelStatuses.indices.contains($0) && rowLabelStatuses[$0] == .mismatch }.count }
    func rowSummary(_ position:Int) -> String {
        let count=rowConnectionCounts[position,default:0]
        return "\(count) connection\(count == 1 ? "" : "s")"
    }
    func bandRect(_ band:MatrixAxis.Band,row:Bool) -> NSRect {
        let offset=scroll.contentView.bounds.origin
        if row { return NSRect(x:CGFloat(band.depth)*bandSize,y:CGFloat(band.start)*cell-offset.y,width:bandSize,height:CGFloat(band.count)*cell) }
        return NSRect(x:CGFloat(band.start)*cell-offset.x,y:CGFloat(band.depth)*bandSize,width:CGFloat(band.count)*cell,height:bandSize)
    }
    func band(at point:NSPoint,row:Bool) -> MatrixAxis.Band? {
        (row ? rowAxis : columnAxis).bands.first { bandRect($0,row:row).contains(point) }
    }
    func toggleGroup(_ group:MatrixGroup,row:Bool) {
        var changed=collapsed
        if changed.contains(group.id) { changed.remove(group.id) } else { changed.insert(group.id) }
        applyFolds(changed,anchorRow:row ? group.indices.first : nil,anchorColumn:row ? nil : group.indices.first)
    }
    private func applyFolds(_ changed:Set<String>,anchorRow:Int?,anchorColumn:Int?) {
        var origin=scroll.contentView.bounds.origin
        let oldRow=anchorRow.flatMap { rowAxis.channelPositions[$0] }, oldColumn=anchorColumn.flatMap { columnAxis.channelPositions[$0] }
        collapsed=changed; foldStore.save(changed); rebuildProjection()
        if let channel=anchorRow, let before=oldRow, let after=rowAxis.channelPositions[channel] { origin.y += CGFloat(after-before)*cell
            if rowAxis.items[after].group != nil { origin.y=min(origin.y,CGFloat(after)*cell) }
        }
        if let channel=anchorColumn, let before=oldColumn, let after=columnAxis.channelPositions[channel] { origin.x += CGFloat(after-before)*cell
            if columnAxis.items[after].group != nil { origin.x=min(origin.x,CGFloat(after)*cell) }
        }
        setHover(at:nil); needsLayout=true; layoutSubtreeIfNeeded()
        let viewport=scroll.contentView.bounds.size
        origin.x=max(0,min(origin.x,grid.frame.width-viewport.width)); origin.y=max(0,min(origin.y,grid.frame.height-viewport.height))
        scroll.contentView.scroll(to:origin); scroll.reflectScrolledClipView(scroll.contentView)
        for pane in [grid,rowHeader,columnHeader,corner] { pane.needsDisplay=true }
        refreshToolTips()
    }
    func activateCell(row:Int,column:Int) {
        guard rowAxis.items.indices.contains(row),columnAxis.items.indices.contains(column) else { return }
        let r=rowAxis.items[row], c=columnAxis.items[column]
        if r.group != nil || c.group != nil {
            var changed=collapsed
            if let group=r.group { changed.remove(group.id) }
            if let group=c.group { changed.remove(group.id) }
            applyFolds(changed,anchorRow:r.indices.first,anchorColumn:c.indices.first)
        } else if let originalRow=r.channel, let originalColumn=c.channel, canEdit(row:originalRow,column:originalColumn) {
            onClick(originalRow,originalColumn)
        }
    }
    func refreshToolTips() {
        for pane in [grid,rowHeader,columnHeader] { pane.refreshLabelToolTips() }
    }
    override func layout() {
        super.layout()
        scroll.frame=NSRect(x:frozenWidth,y:headerHeight,width:max(0,bounds.width-frozenWidth),height:max(0,bounds.height-headerHeight))
        scroll.tile()
        grid.setFrameSize(NSSize(width:max(scroll.contentSize.width,CGFloat(columnAxis.items.count)*cell),
                                 height:max(scroll.contentSize.height,CGFloat(rowAxis.items.count)*cell)))
        let viewport=scroll.contentView.bounds
        let origin=NSPoint(x:max(0,min(viewport.minX,grid.frame.width-viewport.width)),
                           y:max(0,min(viewport.minY,grid.frame.height-viewport.height)))
        scroll.contentView.scroll(to:origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        rowHeader.frame=NSRect(x:0,y:headerHeight,width:frozenWidth,height:scroll.contentSize.height)
        columnHeader.frame=NSRect(x:frozenWidth,y:0,width:scroll.contentSize.width,height:headerHeight)
        corner.frame=NSRect(x:0,y:0,width:frozenWidth,height:headerHeight)
        rowHeader.needsDisplay=true; columnHeader.needsDisplay=true
        refreshToolTips()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed:0.075,green:0.09,blue:0.11,alpha:1).setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

private final class MatrixGroupAccessibility: NSAccessibilityElement {
    var press:(()->Void)?
    override func accessibilityPerformPress() -> Bool { press?(); return true }
}

private final class MatrixPane: NSView, NSViewToolTipOwner {
    enum Kind { case grid, rows, columns, corner }
    let kind: Kind
    weak var matrix: FrozenMatrixView?
    private var mouseTracking: NSTrackingArea?
    private var labelToolTipRects: [NSRect] = []
    private var accessibleGroups:[String:MatrixGroupAccessibility]=[:]
    private var lastClickExpandedGroup=false
    override var isFlipped: Bool { true }
    init(_ kind: Kind) {
        self.kind=kind
        super.init(frame:.zero)
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        guard kind == .grid else { return }
        let tracking=NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(tracking); mouseTracking=tracking
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if kind == .grid { window?.acceptsMouseMovedEvents=true }
    }
    override func mouseMoved(with event: NSEvent) { matrix?.setHover(at:convert(event.locationInWindow,from:nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with:event) }
    override func mouseExited(with event: NSEvent) { matrix?.setHover(at:nil) }

    override func scrollWheel(with event: NSEvent) {
        matrix?.scroll.scrollWheel(with:event)
        if kind == .grid { mouseMoved(with:event) }
    }
    override func mouseDown(with event: NSEvent) {
        guard let m=matrix else { return }
        let point=convert(event.locationInWindow,from:nil)
        if event.clickCount > 1 && lastClickExpandedGroup { return }
        lastClickExpandedGroup=false
        if kind == .rows || kind == .columns {
            let row=kind == .rows
            if let band=m.band(at:point,row:row) {
                if event.clickCount == 1 { lastClickExpandedGroup=true; m.toggleGroup(band.group,row:row) }
                return
            }
            if let index=m.visibleIndex(row:row,at:point), let group=(row ? m.rowAxis : m.columnAxis).items[index].group {
                if event.clickCount == 1 { lastClickExpandedGroup=true; m.toggleGroup(group,row:row) }
                return
            }
        }
        if kind == .rows, let row=m.syncLabelRow(at:point) {
            m.onLabelSyncClick(row,point.x < m.rowWidth ? .destination : .source)
            return
        }
        if event.clickCount == 2,kind == .rows || kind == .columns,
           kind != .rows || point.x < m.rowWidth,
           let index=m.headerIndex(row:kind == .rows,at:point) {
            m.onHeaderDoubleClick(kind == .rows,index)
            return
        }
        guard kind == .grid, point.x>=0,point.y>=0 else { return }
        // A double click that opens a bank must never toggle a newly exposed route.
        guard event.clickCount == 1 else { return }
        m.activateCell(row:Int(point.y/m.cell),column:Int(point.x/m.cell))
    }
    func refreshLabelToolTips() {
        guard let m=matrix else { return }
        var rects:[NSRect]=[]
        var children:[MatrixGroupAccessibility]=[], used=Set<String>()
        func accessible(_ key:String,_ label:String,_ rect:NSRect,_ press:@escaping ()->Void) {
            guard let window, !rect.isEmpty else { return }
            let element=accessibleGroups[key] ?? MatrixGroupAccessibility()
            accessibleGroups[key]=element; used.insert(key)
            element.setAccessibilityRole(.button); element.setAccessibilityEnabled(true)
            element.setAccessibilityLabel(label); element.setAccessibilityParent(self)
            element.setAccessibilityFrame(window.convertToScreen(convert(rect,to:nil)))
            element.press=press; children.append(element)
        }
        if kind == .rows {
            rects=m.rowLabelStatuses.indices.flatMap { row in LabelSide.allCases.compactMap { m.syncLabelRect(row,side:$0) } }
        }
        if kind == .rows || kind == .columns {
            let row=kind == .rows, axis=row ? m.rowAxis : m.columnAxis
            rects += axis.bands.map { m.bandRect($0,row:row) }
            for (index,item) in axis.items.enumerated() where item.group != nil {
                if row { rects.append(NSRect(x:m.rowGutter,y:CGFloat(index)*m.cell-m.scroll.contentView.bounds.minY,width:m.frozenWidth-m.rowGutter,height:m.cell)) }
                else { rects.append(NSRect(x:CGFloat(index)*m.cell-m.scroll.contentView.bounds.minX,y:m.columnGutter,width:m.cell,height:m.headerHeight-m.columnGutter)) }
            }
            for band in axis.bands {
                let rect=m.bandRect(band,row:row).intersection(bounds)
                accessible(band.group.id,"\(band.collapsed ? "Expand" : "Collapse") \(row ? "destination" : "source") group: \(band.group.title)",rect) { [weak m] in m?.toggleGroup(band.group,row:row) }
            }
        }
        if kind == .grid {
            rects=[visibleRect]
            for (r,row) in m.rowAxis.items.enumerated() {
                let y=CGFloat(r)*m.cell
                guard y+m.cell>=visibleRect.minY, y<=visibleRect.maxY else { continue }
                for (c,column) in m.columnAxis.items.enumerated() where row.group != nil || column.group != nil {
                    let rect=NSRect(x:CGFloat(c)*m.cell,y:y,width:m.cell,height:m.cell).intersection(visibleRect)
                    let destination=row.group?.title ?? m.rows[row.channel!].components(separatedBy:"\n")[0]
                    let source=column.group?.title ?? m.columns[column.channel!].components(separatedBy:"\n")[0]
                    accessible("cell-\(r)-\(c)","Expand routing groups: \(destination) / \(source). \(m.connectionCount(row:r,column:c)) connections",rect) { [weak m] in m?.activateCell(row:r,column:c) }
                }
            }
        }
        accessibleGroups=accessibleGroups.filter { used.contains($0.key) }
        setAccessibilityChildren(children)
        rects=rects.filter { $0.intersects(bounds) }.map { $0.intersection(bounds) }
        if rects != labelToolTipRects {
            removeAllToolTips(); labelToolTipRects=rects
            for rect in rects { addToolTip(rect,owner:self,userData:nil) }
        }
        window?.invalidateCursorRects(for:self)
    }
    override func resetCursorRects() {
        guard let m=matrix else { return }
        if kind == .rows || kind == .columns {
            let row=kind == .rows
            for band in (row ? m.rowAxis : m.columnAxis).bands {
                let rect=m.bandRect(band,row:row)
                if rect.intersects(bounds) { addCursorRect(rect.intersection(bounds),cursor:.pointingHand) }
            }
        }
        guard kind == .rows, m.enabled else { return }
        for row in m.rowLabelStatuses.indices where m.rowLabelStatuses[row] == .mismatch {
            for side in LabelSide.allCases {
                if let rect=m.syncLabelRect(row,side:side), rect.intersects(bounds) { addCursorRect(rect.intersection(bounds),cursor:.pointingHand) }
            }
        }
    }
    func view(_ view:NSView, stringForToolTip tag:NSView.ToolTipTag, point:NSPoint, userData:UnsafeMutableRawPointer?) -> String {
        guard let m=matrix else { return "" }
        if kind == .grid {
            let r=Int(point.y/m.cell),c=Int(point.x/m.cell)
            guard m.rowAxis.items.indices.contains(r),m.columnAxis.items.indices.contains(c),
                  m.rowAxis.items[r].group != nil || m.columnAxis.items[c].group != nil else { return "" }
            let count=m.connectionCount(row:r,column:c)
            return "\(count) connection\(count == 1 ? "" : "s") — click to expand"
        }
        let row=kind == .rows
        if let band=m.band(at:point,row:row) { return "\(band.group.title) — click to \(band.collapsed ? "expand" : "collapse")" }
        if let index=m.visibleIndex(row:row,at:point), let group=(row ? m.rowAxis : m.columnAxis).items[index].group {
            let mismatches=row ? m.mismatchCount(group.indices) : 0
            return group.title + (mismatches>0 ? " · \(mismatches) label mismatches" : "") + " — click to expand"
        }
        guard row, let channel=m.headerIndex(row:true,at:point), m.rowLabelStatuses.indices.contains(channel) else { return "" }
        return m.rowLabelStatuses[channel].help
    }
    private func drawBands(row:Bool) {
        guard let m=matrix else { return }
        for band in (row ? m.rowAxis : m.columnAxis).bands {
            let rect=m.bandRect(band,row:row)
            guard rect.intersects(bounds) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect:rect.intersection(bounds)).addClip()
            NSColor.white.withAlphaComponent(band.depth == 0 ? 0.07 : 0.035).setFill(); rect.fill()
            NSColor.white.withAlphaComponent(0.18).setStroke(); NSBezierPath(rect:rect.insetBy(dx:0.5,dy:0.5)).stroke()
            let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:10,weight:.medium),.foregroundColor:NSColor.white.withAlphaComponent(0.8)]
            let arrow=band.collapsed ? "▸" : "▾"
            let start=row ? max(0,rect.minY) : max(0,rect.minX)
            (arrow as NSString).draw(at:NSPoint(x:row ? rect.minX+6 : start+5,y:row ? start+4 : rect.minY+4),withAttributes:attributes)
            if row && !band.collapsed {
                let transform=NSAffineTransform(); transform.translateX(by:rect.minX+4,yBy:min(bounds.height,rect.maxY)-5); transform.rotate(byDegrees:-90); transform.concat()
                text(band.group.title,in:NSRect(x:0,y:0,width:min(rect.height,bounds.height)-26,height:14),alpha:0.8)
            } else if !row && rect.width>m.cell {
                text(band.group.title,in:NSRect(x:start+20,y:rect.minY+3,width:rect.maxX-start-24,height:16),alpha:0.8)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    private func text(_ value: String, in rect: NSRect, alpha: CGFloat = 0.85, unavailable: Bool = false, topAligned: Bool = false, labelColor:NSColor = .systemCyan, copySide:LabelSide? = nil) {
        let paragraph=NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let parts=value.components(separatedBy:"\n")
        let hasLabel=parts.count>1
        let originalRect=NSRect(x:rect.minX,y:hasLabel || topAligned ? rect.minY : rect.midY-6.5,width:rect.width,height:13)
        (parts[0] as NSString).draw(in:originalRect,withAttributes:[.font:NSFont.systemFont(ofSize:10),
            .foregroundColor:NSColor.white.withAlphaComponent(unavailable ? 0.35 : alpha),.paragraphStyle:paragraph])
        if hasLabel {
            let label=parts.dropFirst().joined(separator:" ") as NSString
            let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:10,weight:.medium),
                .foregroundColor:unavailable ? NSColor.gray : labelColor,.paragraphStyle:paragraph]
            let arrow=(copySide?.copyArrow ?? "") as NSString
            let arrowWidth=arrow.size(withAttributes:attributes).width
            let labelWidth=min(label.size(withAttributes:attributes).width+2,max(0,rect.width-arrowWidth))
            // Reserve arrow space so even a truncated destination label retains its direction.
            let labelX=rect.minX + (copySide == .source ? arrowWidth : 0)
            label.draw(in:NSRect(x:labelX,y:rect.minY+14,width:labelWidth,height:13),withAttributes:attributes)
            if let copySide {
                arrow.draw(in:NSRect(x:copySide == .source ? rect.minX : labelX+labelWidth,
                                     y:rect.minY+14,width:arrowWidth,height:13),withAttributes:attributes)
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let m=matrix else { return }
        NSColor(calibratedRed:0.075,green:0.09,blue:0.11,alpha:1).setFill()
        bounds.intersection(dirtyRect).fill()
        let offset=m.scroll.contentView.bounds.origin, cell=m.cell
        switch kind {
        case .grid:
            for r in m.rowAxis.items.indices {
                let y=CGFloat(r)*cell
                guard y+cell>=dirtyRect.minY,y<=dirtyRect.maxY else { continue }
                if r%2==0 {
                    NSColor.white.withAlphaComponent(0.025).setFill()
                    NSRect(x:0,y:y,width:bounds.width,height:cell).fill()
                }
                for c in m.columnAxis.items.indices {
                    let rect=NSRect(x:CGFloat(c)*cell,y:y,width:cell,height:cell)
                    guard rect.intersects(dirtyRect) else { continue }
                    let unavailable=m.displayUnavailable(row:r,column:c)
                    if unavailable {
                        NSColor.white.withAlphaComponent(0.035).setFill(); rect.fill()
                    }
                    if r == m.hoveredRow || c == m.hoveredColumn {
                        NSColor.systemCyan.withAlphaComponent(0.10).setFill(); rect.fill()
                    }
                    NSColor.white.withAlphaComponent(0.1).setStroke()
                    let border=NSBezierPath(rect:rect); border.lineWidth=0.5; border.stroke()
                    if m.connectionCount(row:r,column:c)>0 {
                        (m.hasLiveConnection(row:r,column:c) ? NSColor.systemCyan : NSColor.gray).setFill()
                        NSBezierPath(roundedRect:rect.insetBy(dx:5,dy:5),xRadius:3,yRadius:3).fill()
                    }
                    if r == m.hoveredRow && c == m.hoveredColumn {
                        NSColor.systemCyan.setStroke()
                        let focus=NSBezierPath(rect:rect.insetBy(dx:1,dy:1)); focus.lineWidth=1.5; focus.stroke()
                    }
                }
            }
        case .rows:
            for r in m.rowAxis.items.indices {
                let y=CGFloat(r)*cell-offset.y
                guard y+cell>=0,y<=bounds.height else { continue }
                if r == m.hoveredRow {
                    NSColor.systemCyan.withAlphaComponent(0.18).setFill()
                    NSRect(x:0,y:y,width:bounds.width,height:cell).fill()
                }
                let item=m.rowAxis.items[r]
                if let group=item.group {
                    let mismatches=m.mismatchCount(group.indices)
                    let title=group.title + (mismatches>0 ? "\n● \(mismatches) label mismatch\(mismatches == 1 ? "" : "es")" : "")
                    text(title,in:NSRect(x:m.rowGutter+12,y:y+2,width:m.rowWidth-m.rowGutter-24,height:cell-2),labelColor:.systemOrange)
                    text(m.rowSummary(r),in:NSRect(x:m.rowWidth+12,y:y+2,width:m.sourceWidth-24,height:cell-2),alpha:0.6)
                    continue
                }
                guard let channel=item.channel else { continue }
                let source=m.sourceColumn(forRow:channel)
                let topAligned=m.rows[channel].contains("\n") || source.map { m.columns[$0].contains("\n") } == true
                text(m.rows[channel],in:NSRect(x:m.rowGutter+12,y:y+2,width:m.rowWidth-m.rowGutter-24,height:cell-2),unavailable:m.unavailableRows.contains(channel),topAligned:topAligned,
                     labelColor:m.labelColor(row:channel,side:.destination),copySide:m.copySide(row:channel,side:.destination))
                if let source, let sourceText=m.sourceText(forRow:channel) {
                    text(sourceText,in:NSRect(x:m.rowWidth+12,y:y+2,width:m.sourceWidth-24,height:cell-2),
                         alpha:0.7,unavailable:m.unavailableRows.contains(channel) || m.unavailableColumns.contains(source),topAligned:topAligned,
                         labelColor:m.labelColor(row:channel,side:.source),copySide:m.copySide(row:channel,side:.source))
                }
            }
            drawBands(row:true)
            NSColor.white.withAlphaComponent(0.1).setFill()
            NSRect(x:m.rowWidth,y:0,width:1,height:bounds.height).fill()
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSRect(x:bounds.width-1,y:0,width:1,height:bounds.height).fill()
        case .columns:
            for c in m.columnAxis.items.indices {
                let x=CGFloat(c)*cell-offset.x
                guard x+cell>=0,x<=bounds.width else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect:NSRect(x:x,y:m.columnGutter,width:cell,height:bounds.height-m.columnGutter)).addClip()
                if c == m.hoveredColumn {
                    NSColor.systemCyan.withAlphaComponent(0.18).setFill()
                    NSRect(x:x,y:0,width:cell,height:bounds.height).fill()
                }
                let transform=NSAffineTransform()
                transform.translateX(by:x+cell/2,yBy:bounds.height-10)
                transform.rotate(byDegrees:-90)
                transform.concat()
                let item=m.columnAxis.items[c]
                text(item.group?.title ?? m.columns[item.channel!],in:NSRect(x:0,y:-cell/2+2,width:bounds.height-m.columnGutter-18,height:cell-2),alpha:0.8,unavailable:item.indices.allSatisfy { m.unavailableColumns.contains($0) },
                     labelColor:m.showsInputLabels ? .systemGreen : .systemCyan)
                NSGraphicsContext.restoreGraphicsState()
            }
            drawBands(row:false)
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSRect(x:0,y:bounds.height-1,width:bounds.width,height:1).fill()
        case .corner:
            let legend:[(String,NSColor)]=[("Core Audio Label",.systemCyan),("Interface Label",.systemGreen),("Label Mismatch",.systemOrange)]
            var legendX:CGFloat=12
            let legendY=bounds.height-54
            for (name,color) in legend {
                color.setFill()
                NSBezierPath(ovalIn:NSRect(x:legendX,y:legendY+4,width:6,height:6)).fill()
                let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.white.withAlphaComponent(0.65)]
                let width=(name as NSString).size(withAttributes:attributes).width
                (name as NSString).draw(in:NSRect(x:legendX+12,y:legendY,width:width+2,height:14),withAttributes:attributes)
                legendX += width+30
            }
            text("Destination",in:NSRect(x:m.rowGutter+12,y:bounds.height-24,width:m.rowWidth-m.rowGutter-24,height:20),alpha:0.5)
            text("Source",in:NSRect(x:m.rowWidth+12,y:bounds.height-24,width:m.sourceWidth-24,height:20),alpha:0.5)
        }
    }
}
