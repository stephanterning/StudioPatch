import SwiftUI
import AppKit

struct Matrix: NSViewRepresentable {
    let rows: [String]
    let columns: [String]
    let selected: Set<Int>
    let enabled: Bool
    var unavailableRows: Set<Int> = []
    var unavailableColumns: Set<Int> = []
    let onHeaderDoubleClick: (Bool,Int)->Void
    let onClick: (Int,Int)->Void

    func makeNSView(context: Context) -> FrozenMatrixView { FrozenMatrixView() }
    func updateNSView(_ view: FrozenMatrixView, context: Context) {
        view.update(rows:rows,columns:columns,selected:selected,enabled:enabled,unavailableRows:unavailableRows,unavailableColumns:unavailableColumns,onHeaderDoubleClick:onHeaderDoubleClick,onClick:onClick)
    }
}

final class FrozenMatrixView: NSView {
    let rowWidth: CGFloat = 235, headerHeight: CGFloat = 170, cell: CGFloat = 32
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
        grid.setAccessibilityElement(true)
        grid.setAccessibilityRole(.group)
        grid.setAccessibilityLabel("Routing matrix with frozen channel headers. Use the channel list for accessible editing.")
        observer = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,
            object:scroll.contentView,queue:.main) { [weak self] _ in
                self?.rowHeader.needsDisplay = true
                self?.columnHeader.needsDisplay = true
                self?.refreshHover()
            }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func update(rows: [String], columns: [String], selected: Set<Int>, enabled: Bool,
                unavailableRows: Set<Int> = [], unavailableColumns: Set<Int> = [],
                onHeaderDoubleClick: @escaping (Bool,Int)->Void = {_,_ in},
                onClick: @escaping (Int,Int)->Void) {
        self.rows=rows; self.columns=columns; self.selected=selected
        self.enabled=enabled; self.onClick=onClick
        self.unavailableRows=unavailableRows; self.unavailableColumns=unavailableColumns
        self.onHeaderDoubleClick=onHeaderDoubleClick
        setHover(at:nil)
        needsLayout=true
        for pane in [grid,rowHeader,columnHeader,corner] { pane.needsDisplay=true }
    }
    func canEdit(row: Int, column: Int) -> Bool {
        guard enabled, rows.indices.contains(row), columns.indices.contains(column) else { return false }
        return (!unavailableRows.contains(row) && !unavailableColumns.contains(column)) || selected.contains(row*columns.count+column)
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
        scroll.frame=NSRect(x:rowWidth,y:headerHeight,width:max(0,bounds.width-rowWidth),height:max(0,bounds.height-headerHeight))
        scroll.tile()
        grid.setFrameSize(NSSize(width:max(scroll.contentSize.width,CGFloat(columns.count)*cell),
                                 height:max(scroll.contentSize.height,CGFloat(rows.count)*cell)))
        let viewport=scroll.contentView.bounds
        let origin=NSPoint(x:max(0,min(viewport.minX,grid.frame.width-viewport.width)),
                           y:max(0,min(viewport.minY,grid.frame.height-viewport.height)))
        scroll.contentView.scroll(to:origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        rowHeader.frame=NSRect(x:0,y:headerHeight,width:rowWidth,height:scroll.contentSize.height)
        columnHeader.frame=NSRect(x:rowWidth,y:0,width:scroll.contentSize.width,height:headerHeight)
        corner.frame=NSRect(x:0,y:0,width:rowWidth,height:headerHeight)
        rowHeader.needsDisplay=true; columnHeader.needsDisplay=true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed:0.075,green:0.09,blue:0.11,alpha:1).setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

private final class MatrixPane: NSView {
    enum Kind { case grid, rows, columns, corner }
    let kind: Kind
    weak var matrix: FrozenMatrixView?
    private var mouseTracking: NSTrackingArea?
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
        if event.clickCount == 2,kind == .rows || kind == .columns,
           let index=m.headerIndex(row:kind == .rows,at:point) {
            m.onHeaderDoubleClick(kind == .rows,index)
            return
        }
        guard kind == .grid,m.enabled else { return }
        guard point.x>=0,point.y>=0 else { return }
        let column=Int(point.x/m.cell),row=Int(point.y/m.cell)
        if m.canEdit(row:row,column:column) { m.onClick(row,column) }
    }
    private func text(_ value: String, in rect: NSRect, alpha: CGFloat = 0.85, unavailable: Bool = false) {
        let paragraph=NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let parts=value.components(separatedBy:"\n")
        let hasLabel=parts.count>1
        let originalRect=NSRect(x:rect.minX,y:hasLabel ? rect.minY : rect.midY-6.5,width:rect.width,height:13)
        (parts[0] as NSString).draw(in:originalRect,withAttributes:[.font:NSFont.systemFont(ofSize:10),
            .foregroundColor:NSColor.white.withAlphaComponent(unavailable ? 0.35 : alpha),.paragraphStyle:paragraph])
        if hasLabel {
            // Draw separately: paragraph truncation must not swallow the custom label.
            (parts.dropFirst().joined(separator:" ") as NSString).draw(in:NSRect(x:rect.minX,y:rect.minY+14,width:rect.width,height:13),
                withAttributes:[.font:NSFont.systemFont(ofSize:10,weight:.medium),
                    .foregroundColor:unavailable ? NSColor.gray : NSColor.systemCyan,.paragraphStyle:paragraph])
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
                text(m.rows[r],in:NSRect(x:12,y:y+2,width:bounds.width-24,height:cell-2),unavailable:m.unavailableRows.contains(r))
            }
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
                text(m.columns[c],in:NSRect(x:0,y:-cell/2+2,width:bounds.height-18,height:cell-2),alpha:0.8,unavailable:m.unavailableColumns.contains(c))
                NSGraphicsContext.restoreGraphicsState()
            }
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSRect(x:0,y:bounds.height-1,width:bounds.width,height:1).fill()
        case .corner:
            text("Routing",in:NSRect(x:12,y:bounds.height-24,width:bounds.width-24,height:20),alpha:0.5)
        }
    }
}
