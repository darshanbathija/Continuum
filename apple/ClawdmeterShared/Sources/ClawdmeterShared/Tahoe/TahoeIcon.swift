#if canImport(SwiftUI)
import SwiftUI

/// SF Symbol bridge for the JSX icon names used across the design. The JSX
/// `Icon` component (in `glass.jsx`) shipped a custom 24×24 stroke set;
/// we map each name to the nearest SF Symbol so we get crisp native rendering
/// across light/dark and any size. Anything unmapped renders as a small
/// circle so missing names are visible rather than invisible.
public struct TahoeIcon: View {
    public var name: String
    public var size: CGFloat
    public var weight: Font.Weight

    public init(_ name: String, size: CGFloat = 16, weight: Font.Weight = .medium) {
        self.name = name
        self.size = size
        self.weight = weight
    }

    public var body: some View {
        Image(systemName: Self.symbol(for: name))
            .font(.system(size: size, weight: weight))
            .symbolRenderingMode(.monochrome)
    }

    public static func symbol(for name: String) -> String {
        switch name {
        case "sidebar":    return "sidebar.left"
        case "chevR":      return "chevron.right"
        case "chevL":      return "chevron.left"
        case "chevD":      return "chevron.down"
        case "chevU":      return "chevron.up"
        case "plus":       return "plus"
        case "minus":      return "minus"
        case "x":          return "xmark"
        case "check":      return "checkmark"
        case "search":     return "magnifyingglass"
        case "gear":       return "gearshape"
        case "sparkles":   return "sparkles"
        case "bolt":       return "bolt.fill"
        case "folder":     return "folder"
        case "doc":        return "doc"
        case "arrowR":     return "arrow.right"
        case "arrowU":     return "arrow.up"
        case "arrowD":     return "arrow.down"
        case "mic":        return "mic"
        case "paperclip":  return "paperclip"
        case "play":       return "play.fill"
        case "stop":       return "stop.fill"
        case "pause":      return "pause.fill"
        case "refresh":    return "arrow.clockwise"
        case "git":        return "point.3.connected.trianglepath.dotted"
        case "branch":     return "arrow.triangle.branch"
        case "pull":       return "arrow.triangle.pull"
        case "user":       return "person.crop.circle"
        case "chat":       return "bubble.left"
        case "bell":       return "bell"
        case "tray":       return "tray.and.arrow.down"
        case "play2":      return "play"
        case "eye":        return "eye"
        case "sliders":    return "slider.horizontal.3"
        case "code":       return "chevron.left.forwardslash.chevron.right"
        case "gauge":      return "gauge.with.dots.needle.50percent"
        case "bookmark":   return "bookmark"
        case "grid":       return "square.grid.2x2"
        case "terminal":   return "terminal"
        case "diff":       return "arrow.left.arrow.right"
        case "qr":         return "qrcode"
        case "link":       return "link"
        case "pin":        return "pin"
        case "moon":       return "moon"
        case "sun":        return "sun.max"
        case "archive":    return "archivebox"
        case "filter":     return "line.3.horizontal.decrease.circle"
        case "folderPlus": return "folder.badge.plus"
        default:           return "circle"
        }
    }
}
#endif
