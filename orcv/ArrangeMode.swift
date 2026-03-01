import Foundation

enum ArrangeMode: String, CaseIterable {
    case column
    case row
    case square
}

enum ArrangeLayout {
    struct Tile {
        let id: UUID
        let size: CGSize
        let currentOrigin: CGPoint
    }

    static func arrange(mode: ArrangeMode, tiles: [Tile], padding: CGFloat) -> [UUID: CGPoint] {
        guard !tiles.isEmpty else { return [:] }

        // Sort top-left first: largest Y = topmost in AppKit, then smallest X = leftmost.
        let sorted = tiles.sorted { a, b in
            if abs(a.currentOrigin.y - b.currentOrigin.y) > 1.0 {
                return a.currentOrigin.y > b.currentOrigin.y
            }
            return a.currentOrigin.x < b.currentOrigin.x
        }

        let anchor = sorted[0].currentOrigin

        switch mode {
        case .column:
            return arrangeColumn(sorted: sorted, anchor: anchor, padding: padding)
        case .row:
            return arrangeRow(sorted: sorted, anchor: anchor, padding: padding)
        case .square:
            return arrangeSquare(sorted: sorted, anchor: anchor, padding: padding)
        }
    }

    private static func arrangeColumn(sorted: [Tile], anchor: CGPoint, padding: CGFloat) -> [UUID: CGPoint] {
        var origins: [UUID: CGPoint] = [:]
        var y = anchor.y
        for tile in sorted {
            origins[tile.id] = CGPoint(x: anchor.x, y: y)
            y -= tile.size.height + padding  // stack downward (decreasing Y = visually below)
        }
        return origins
    }

    private static func arrangeRow(sorted: [Tile], anchor: CGPoint, padding: CGFloat) -> [UUID: CGPoint] {
        var origins: [UUID: CGPoint] = [:]
        var x = anchor.x
        for tile in sorted {
            origins[tile.id] = CGPoint(x: x, y: anchor.y)
            x += tile.size.width + padding
        }
        return origins
    }

    private static func arrangeSquare(sorted: [Tile], anchor: CGPoint, padding: CGFloat) -> [UUID: CGPoint] {
        let count = sorted.count
        let cols = Int(ceil(sqrt(Double(count))))
        var origins: [UUID: CGPoint] = [:]

        // Compute max width per column and max height per row.
        var colWidths = [Int: CGFloat]()
        var rowHeights = [Int: CGFloat]()
        for (i, tile) in sorted.enumerated() {
            let col = i % cols
            let row = i / cols
            colWidths[col] = max(colWidths[col, default: 0], tile.size.width)
            rowHeights[row] = max(rowHeights[row, default: 0], tile.size.height)
        }

        for (i, tile) in sorted.enumerated() {
            let col = i % cols
            let row = i / cols
            var x = anchor.x
            for c in 0..<col {
                x += (colWidths[c] ?? 0) + padding
            }
            var y = anchor.y
            for r in 0..<row {
                y -= (rowHeights[r] ?? 0) + padding  // rows go downward
            }
            origins[tile.id] = CGPoint(x: x, y: y)
        }
        return origins
    }
}
