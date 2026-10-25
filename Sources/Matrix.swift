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
    var unavailableRows: Set<Int> = []
    var unavailableColumns: Set<Int> = []
    var showsInputLabels = false
    var rowLabelStatuses: [LabelMatchStatus] = []
    var onLabelSyncClick: (Int,LabelSide)->Void = { _,_ in }
    let onHeaderDoubleClick: (Bool,Int)->Void
    let onClick: (Int,Int)->Void

    func makeNSView(context: Context) -> FrozenMatrixView { FrozenMatrixView() }
    func updateNSView(_ view: FrozenMatrixView, context: Context) {
        view.update(rows:rows,columns:columns,selected:selected,enabled:enabled,unavailableRows:unavailableRows,unavailableColumns:unavailableColumns,
                    showsInputLabels:showsInputLabels,rowLabelStatuses:rowLabelStatuses,onLabelSyncClick:onLabelSyncClick,
                    onHeaderDoubleClick:onHeaderDoubleClick,onClick:onClick)
    }
}

final class FrozenMatrixView: NSView {
    let rowWidth: CGFloat = 235, sourceWidth: CGFloat = 205, headerHeight: CGFloat = 170, cell: CGFloat = 32
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

    init() {
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
                self?.rowHeader.refreshLabelToolTips()
                self?.refreshHover()
            }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func update(rows: [String], columns: [String], selected: Set<Int>, enabled: Bool,
                unavailableRows: Set<Int> = [], unavailableColumns: Set<Int> = [],
                showsInputLabels: Bool = false, rowLabelStatuses: [LabelMatchStatus] = [],
                onLabelSyncClick: @escaping (Int,LabelSide)->Void = { _,_ in },
                onHeaderDoubleClick: @escaping (Bool,Int)->Void = {_,_ in},
                onClick: @escaping (Int,Int)->Void) {
        self.rows=rows; self.columns=columns; self.selected=selected
        self.enabled=enabled; self.onClick=onClick
        self.unavailableRows=unavailableRows; self.unavailableColumns=unavailableColumns
        self.onHeaderDoubleClick=onHeaderDoubleClick
        self.showsInputLabels=showsInputLabels; self.rowLabelStatuses=rowLabelStatuses
        self.onLabelSyncClick=onLabelSyncClick
        setHover(at:nil)
        needsLayout=true
        for pane in [grid,rowHeader,columnHeader,corner] { pane.needsDisplay=true }
    }
    func canEdit(row: Int, column: Int) -> Bool {
        guard enabled, rows.indices.contains(row), columns.indices.contains(column) else { return false }
        return !unavailableRows.contains(row) && !unavailableColumns.contains(column)
    }
    func sourceColumn(forRow row: Int) -> Int? {
        columns.indices.first { selected.contains(row*columns.count+$0) }
    }
    func sourceText(forRow row:Int) -> String? {
        guard rows.indices.contains(row), let source=sourceColumn(forRow:row) else { return nil }
        return columns[source]
    }
    func syncLabelRect(_ row:Int, side:LabelSide) -> NSRect? {
        guard rowLabelStatuses.indices.contains(row), rows.indices.contains(row),
              let source=sourceText(forRow:row) else { return nil }
        let labelled=side == .source ? source : rows[row]
        let parts=labelled.components(separatedBy:"\n")
        guard parts.count > 1 else { return nil }
        let label=parts.dropFirst().joined(separator:" ") + (copySide(row:row,side:side)?.copyArrow ?? "")
        let columnWidth=side == .source ? sourceWidth : rowWidth
        let width=min(columnWidth-24,(label as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:10,weight:.medium)]).width+2)
        return NSRect(x:(side == .source ? rowWidth : 0)+12,y:CGFloat(row)*cell-scroll.contentView.bounds.minY+16,width:width,height:13)
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
            if rows.indices.contains(r),columns.indices.contains(c) { row=r; column=c }
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
    func headerIndex(row: Bool, at point: NSPoint) -> Int? {
        let coordinate = row ? point.y+scroll.contentView.bounds.minY : point.x+scroll.contentView.bounds.minX
        guard coordinate>=0 else { return nil }
        let index=Int(coordinate/cell)
        return (row ? rows.indices.contains(index) : columns.indices.contains(index)) ? index : nil
    }
    override func layout() {
        super.layout()
        scroll.frame=NSRect(x:frozenWidth,y:headerHeight,width:max(0,bounds.width-frozenWidth),height:max(0,bounds.height-headerHeight))
        scroll.tile()
        grid.setFrameSize(NSSize(width:max(scroll.contentSize.width,CGFloat(columns.count)*cell),
                                 height:max(scroll.contentSize.height,CGFloat(rows.count)*cell)))
        let viewport=scroll.contentView.bounds
        let origin=NSPoint(x:max(0,min(viewport.minX,grid.frame.width-viewport.width)),
                           y:max(0,min(viewport.minY,grid.frame.height-viewport.height)))
        scroll.contentView.scroll(to:origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        rowHeader.frame=NSRect(x:0,y:headerHeight,width:frozenWidth,height:scroll.contentSize.height)
        columnHeader.frame=NSRect(x:frozenWidth,y:0,width:scroll.contentSize.width,height:headerHeight)
        corner.frame=NSRect(x:0,y:0,width:frozenWidth,height:headerHeight)
        rowHeader.needsDisplay=true; columnHeader.needsDisplay=true
        rowHeader.refreshLabelToolTips()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed:0.075,green:0.09,blue:0.11,alpha:1).setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

private final class MatrixPane: NSView, NSViewToolTipOwner {
    enum Kind { case grid, rows, columns, corner }
    let kind: Kind
    weak var matrix: FrozenMatrixView?
    private var mouseTracking: NSTrackingArea?
    private var labelToolTipRects: [NSRect] = []
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
        guard kind == .grid,m.enabled else { return }
        guard point.x>=0,point.y>=0 else { return }
        let column=Int(point.x/m.cell),row=Int(point.y/m.cell)
        if m.canEdit(row:row,column:column) { m.onClick(row,column) }
    }
    func refreshLabelToolTips() {
        guard kind == .rows, let m=matrix else { return }
        let rects=m.rowLabelStatuses.indices.flatMap { row in
            LabelSide.allCases.compactMap { side -> NSRect? in
                guard let rect=m.syncLabelRect(row,side:side), rect.intersects(bounds) else { return nil }
                return rect.intersection(bounds)
            }
        }
        // Routine status refreshes must not continually restart the hover delay.
        if rects != labelToolTipRects {
            removeAllToolTips()
            labelToolTipRects=rects
            for rect in rects { addToolTip(rect,owner:self,userData:nil) }
        }
        window?.invalidateCursorRects(for:self)
    }
    override func resetCursorRects() {
        guard kind == .rows, let m=matrix, m.enabled else { return }
        for row in m.rowLabelStatuses.indices where m.rowLabelStatuses[row] == .mismatch {
            for side in LabelSide.allCases {
                if let rect=m.syncLabelRect(row,side:side), rect.intersects(bounds) { addCursorRect(rect.intersection(bounds),cursor:.pointingHand) }
            }
        }
    }
    func view(_ view:NSView, stringForToolTip tag:NSView.ToolTipTag, point:NSPoint, userData:UnsafeMutableRawPointer?) -> String {
        guard let m=matrix, let row=m.headerIndex(row:true,at:point), m.rowLabelStatuses.indices.contains(row) else { return "" }
        return m.rowLabelStatuses[row].help
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
            for r in m.rows.indices {
                let y=CGFloat(r)*cell
                guard y+cell>=dirtyRect.minY,y<=dirtyRect.maxY else { continue }
                if r%2==0 {
                    NSColor.white.withAlphaComponent(0.025).setFill()
                    NSRect(x:0,y:y,width:bounds.width,height:cell).fill()
                }
                for c in m.columns.indices {
                    let rect=NSRect(x:CGFloat(c)*cell,y:y,width:cell,height:cell)
                    guard rect.intersects(dirtyRect) else { continue }
                    let unavailable=m.unavailableRows.contains(r) || m.unavailableColumns.contains(c)
                    if unavailable {
                        NSColor.white.withAlphaComponent(0.035).setFill(); rect.fill()
                    }
                    if r == m.hoveredRow || c == m.hoveredColumn {
                        NSColor.systemCyan.withAlphaComponent(0.10).setFill(); rect.fill()
                    }
                    NSColor.white.withAlphaComponent(0.1).setStroke()
                    let border=NSBezierPath(rect:rect); border.lineWidth=0.5; border.stroke()
                    if m.selected.contains(r*m.columns.count+c) {
                        (unavailable ? NSColor.gray : NSColor.systemCyan).setFill()
                        NSBezierPath(roundedRect:rect.insetBy(dx:5,dy:5),xRadius:3,yRadius:3).fill()
                    }
                    if r == m.hoveredRow && c == m.hoveredColumn {
                        NSColor.systemCyan.setStroke()
                        let focus=NSBezierPath(rect:rect.insetBy(dx:1,dy:1)); focus.lineWidth=1.5; focus.stroke()
                    }
                }
            }
        case .rows:
            for r in m.rows.indices {
                let y=CGFloat(r)*cell-offset.y
                guard y+cell>=0,y<=bounds.height else { continue }
                if r == m.hoveredRow {
                    NSColor.systemCyan.withAlphaComponent(0.18).setFill()
                    NSRect(x:0,y:y,width:bounds.width,height:cell).fill()
                }
                let source=m.sourceColumn(forRow:r)
                let topAligned=m.rows[r].contains("\n") || source.map { m.columns[$0].contains("\n") } == true
                text(m.rows[r],in:NSRect(x:12,y:y+2,width:m.rowWidth-24,height:cell-2),unavailable:m.unavailableRows.contains(r),topAligned:topAligned,
                     labelColor:m.labelColor(row:r,side:.destination),copySide:m.copySide(row:r,side:.destination))
                if let source, let sourceText=m.sourceText(forRow:r) {
                    text(sourceText,in:NSRect(x:m.rowWidth+12,y:y+2,width:m.sourceWidth-24,height:cell-2),
                         alpha:0.7,unavailable:m.unavailableRows.contains(r) || m.unavailableColumns.contains(source),topAligned:topAligned,
                         labelColor:m.labelColor(row:r,side:.source),copySide:m.copySide(row:r,side:.source))
                }
            }
            NSColor.white.withAlphaComponent(0.1).setFill()
            NSRect(x:m.rowWidth,y:0,width:1,height:bounds.height).fill()
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSRect(x:bounds.width-1,y:0,width:1,height:bounds.height).fill()
        case .columns:
            for c in m.columns.indices {
                let x=CGFloat(c)*cell-offset.x
                guard x+cell>=0,x<=bounds.width else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect:NSRect(x:x,y:0,width:cell,height:bounds.height)).addClip()
                if c == m.hoveredColumn {
                    NSColor.systemCyan.withAlphaComponent(0.18).setFill()
                    NSRect(x:x,y:0,width:cell,height:bounds.height).fill()
                }
                let transform=NSAffineTransform()
                transform.translateX(by:x+cell/2,yBy:bounds.height-10)
                transform.rotate(byDegrees:-90)
                transform.concat()
                text(m.columns[c],in:NSRect(x:0,y:-cell/2+2,width:bounds.height-18,height:cell-2),alpha:0.8,unavailable:m.unavailableColumns.contains(c),
                     labelColor:m.showsInputLabels ? .systemGreen : .systemCyan)
                NSGraphicsContext.restoreGraphicsState()
            }
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
            text("Destination",in:NSRect(x:12,y:bounds.height-24,width:m.rowWidth-24,height:20),alpha:0.5)
            text("Source",in:NSRect(x:m.rowWidth+12,y:bounds.height-24,width:m.sourceWidth-24,height:20),alpha:0.5)
        }
    }
}
