import Foundation
import SwiftUI

/// Layout parameters for one mode (browsing or playback). Persisted per mode.
/// Grid and list view each persist their own **content** and **detail** column widths (middle vs right split).
struct LayoutParams: Equatable {
    var sidebarWidth: Double
    var contentWidthGrid: Double
    var detailWidthGrid: Double
    var contentWidthList: Double
    var detailWidthList: Double
    /// Height of the list/grid area in the left column (above the bottom filter strip). Per view mode.
    var browserTopPaneHeightGrid: Double
    var browserTopPaneHeightList: Double
    var detailVideoHeight: Double
    var columnCustomizationData: Data?
    var viewMode: String
    var gridSize: String

    static let defaultSidebarWidth: Double = 220
    // Curated Wall bias: give the browsing wall more room for elegant ~5-column gallery.
    static let defaultContentWidth: Double = 620
    static let defaultDetailWidth: Double = 420
    /// Default height for list/grid above the filter strip (left column vertical split).
    static let defaultBrowserTopPaneHeight: Double = 360
    static let defaultDetailVideoHeight: Double = 336

    func contentColumnWidth(for mode: ViewMode) -> Double {
        switch mode {
        case .grid, .storyboard: return contentWidthGrid
        case .list: return contentWidthList
        }
    }

    func detailColumnWidth(for mode: ViewMode) -> Double {
        switch mode {
        case .grid, .storyboard: return detailWidthGrid
        case .list: return detailWidthList
        }
    }

    func browserTopPaneHeight(for mode: ViewMode) -> Double {
        switch mode {
        case .grid, .storyboard: return browserTopPaneHeightGrid
        case .list: return browserTopPaneHeightList
        }
    }

    static func browsingDefaults() -> LayoutParams {
        LayoutParams(
            sidebarWidth: defaultSidebarWidth,
            contentWidthGrid: defaultContentWidth,
            detailWidthGrid: defaultDetailWidth,
            contentWidthList: defaultContentWidth,
            detailWidthList: defaultDetailWidth,
            browserTopPaneHeightGrid: defaultBrowserTopPaneHeight,
            browserTopPaneHeightList: defaultBrowserTopPaneHeight,
            detailVideoHeight: defaultDetailVideoHeight,
            columnCustomizationData: nil,
            viewMode: ViewMode.grid.rawValue,
            gridSize: GridSize.medium.rawValue
        )
    }

    static func from(playback: LayoutParams) -> LayoutParams {
        LayoutParams(
            sidebarWidth: playback.sidebarWidth,
            contentWidthGrid: playback.contentWidthGrid,
            detailWidthGrid: playback.detailWidthGrid,
            contentWidthList: playback.contentWidthList,
            detailWidthList: playback.detailWidthList,
            browserTopPaneHeightGrid: playback.browserTopPaneHeightGrid,
            browserTopPaneHeightList: playback.browserTopPaneHeightList,
            detailVideoHeight: playback.detailVideoHeight,
            columnCustomizationData: playback.columnCustomizationData,
            viewMode: playback.viewMode,
            gridSize: playback.gridSize
        )
    }

    /// Clamps persisted layout to sane ranges so a transient zero/negative geometry or split glitch
    /// cannot corrupt UserDefaults (seen after crashes during heavy list updates).
    func sanitized() -> LayoutParams {
        func clamp(_ x: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
            guard x.isFinite, x > 0 else { return fallback }
            return min(hi, max(lo, x))
        }
        var copy = self
        copy.sidebarWidth = clamp(sidebarWidth, 120, 900, Self.defaultSidebarWidth)
        copy.contentWidthGrid = clamp(contentWidthGrid, 80, 6000, Self.defaultContentWidth)
        copy.detailWidthGrid = clamp(detailWidthGrid, 100, 6000, Self.defaultDetailWidth)
        copy.contentWidthList = clamp(contentWidthList, 80, 6000, Self.defaultContentWidth)
        copy.detailWidthList = clamp(detailWidthList, 100, 6000, Self.defaultDetailWidth)
        copy.browserTopPaneHeightGrid = clamp(browserTopPaneHeightGrid, 100, 8000, Self.defaultBrowserTopPaneHeight)
        copy.browserTopPaneHeightList = clamp(browserTopPaneHeightList, 100, 8000, Self.defaultBrowserTopPaneHeight)
        copy.detailVideoHeight = clamp(detailVideoHeight, 100, 2000, Self.defaultDetailVideoHeight)
        return copy
    }
}

extension LayoutParams: Codable {
    private enum CodingKeys: String, CodingKey {
        case sidebarWidth
        case contentWidthGrid = "contentWidth"
        case detailWidthGrid = "detailWidth"
        case contentWidthList
        case detailWidthList
        case browserTopPaneHeightGrid
        case browserTopPaneHeightList
        case detailVideoHeight
        case columnCustomizationData
        case viewMode
        case gridSize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sidebarWidth = try c.decode(Double.self, forKey: .sidebarWidth)
        contentWidthGrid = try c.decode(Double.self, forKey: .contentWidthGrid)
        detailWidthGrid = try c.decode(Double.self, forKey: .detailWidthGrid)
        let listC = try c.decodeIfPresent(Double.self, forKey: .contentWidthList)
        let listD = try c.decodeIfPresent(Double.self, forKey: .detailWidthList)
        contentWidthList = listC ?? contentWidthGrid
        detailWidthList = listD ?? detailWidthGrid
        let topG = try c.decodeIfPresent(Double.self, forKey: .browserTopPaneHeightGrid)
        let topL = try c.decodeIfPresent(Double.self, forKey: .browserTopPaneHeightList)
        browserTopPaneHeightGrid = topG ?? Self.defaultBrowserTopPaneHeight
        browserTopPaneHeightList = topL ?? Self.defaultBrowserTopPaneHeight
        detailVideoHeight = try c.decode(Double.self, forKey: .detailVideoHeight)
        columnCustomizationData = try c.decodeIfPresent(Data.self, forKey: .columnCustomizationData)
        viewMode = try c.decode(String.self, forKey: .viewMode)
        gridSize = try c.decode(String.self, forKey: .gridSize)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sidebarWidth, forKey: .sidebarWidth)
        try c.encode(contentWidthGrid, forKey: .contentWidthGrid)
        try c.encode(detailWidthGrid, forKey: .detailWidthGrid)
        try c.encode(contentWidthList, forKey: .contentWidthList)
        try c.encode(detailWidthList, forKey: .detailWidthList)
        try c.encode(browserTopPaneHeightGrid, forKey: .browserTopPaneHeightGrid)
        try c.encode(browserTopPaneHeightList, forKey: .browserTopPaneHeightList)
        try c.encode(detailVideoHeight, forKey: .detailVideoHeight)
        try c.encodeIfPresent(columnCustomizationData, forKey: .columnCustomizationData)
        try c.encode(viewMode, forKey: .viewMode)
        try c.encode(gridSize, forKey: .gridSize)
    }
}
