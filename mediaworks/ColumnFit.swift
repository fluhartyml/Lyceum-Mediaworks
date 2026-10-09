//
//  ColumnFit.swift
//  mediaworks
//
//  Double-click the edge between two column headers to fit the column to its longest entry, as in Finder.
//
// REM  HIS ASK, 2026-10-09: "when i go to the end of a colum to resize and give it more room to show a file name
// REM  without truncating it i cant double click it to auto expand". The Mac's own table offers this through a
// REM  delegate method SwiftUI's Table does not implement, so it does nothing there. This catches the
// REM  double-click itself: a double-click on a header within a few points of a column's right edge fits that
// REM  column. The pane works out the width (CommanderView.fitWidth) from the same text the cells show.
// REM  ⚠️ It reaches the Mac table under SwiftUI's Table — if a future macOS changes that, the double-click
// REM  simply does nothing again; dragging the edge always still works.
//

import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformFont = NSFont

/// Placed behind a pane's Table: owns the double-click watcher for that one table.
struct ColumnFit: NSViewRepresentable {
    /// The width to give the shown column at this index, or nil to leave it.
    let fit: (Int) -> CGFloat?

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.fit = fit }

    final class Marker: NSView {
        var fit: (Int) -> CGFloat? = { _ in nil }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.check(event)
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never takes a click itself

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        private func check(_ event: NSEvent) {
            guard event.clickCount == 2, let window, event.window === window,
                  let hit = window.contentView?.superview?.hitTest(event.locationInWindow) else { return }
            var view: NSView? = hit
            while let v = view, !(v is NSTableHeaderView) { view = v.superview }
            guard let header = view as? NSTableHeaderView, let table = header.tableView,
                  belongsHere(table) else { return }
            let point = header.convert(event.locationInWindow, from: nil)
            guard let index = (0..<table.numberOfColumns).first(where: {
                abs(point.x - header.headerRect(ofColumn: $0).maxX) <= 5
            }) else { return }
            // After the header has finished its own click handling.
            DispatchQueue.main.async { [weak self, weak table] in
                guard let self, let table, let width = self.fit(index),
                      table.tableColumns.indices.contains(index) else { return }
                let column = table.tableColumns[index]
                column.width = min(max(width, column.minWidth), column.maxWidth)
            }
        }

        /// True when that table is the one this marker sits behind (each pane has its own).
        private func belongsHere(_ table: NSTableView) -> Bool {
            let mine = convert(bounds, to: nil)
            let theirs = (table.enclosingScrollView ?? table).convert((table.enclosingScrollView ?? table).bounds, to: nil)
            return mine.contains(NSPoint(x: theirs.midX, y: theirs.midY))
        }
    }
}
#else
import UIKit
typealias PlatformFont = UIFont
#endif
