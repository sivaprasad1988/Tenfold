import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipItem: Identifiable {
    enum Content {
        case text(String)
        case image(NSImage)
        case files([URL])
    }

    /// Column in the clipboard view.
    enum Kind: CaseIterable {
        case text, code, link, file, media, color
    }

    let id = UUID()
    let content: Content
    let date: Date
    var isPinned = false
    /// Small preview for copied image files (made once at capture, never in a view body).
    var thumbnail: NSImage?
    /// Pixel size of copied image files (read from the file header at capture).
    var pixelSize: CGSize?

    let kind: Kind
    /// Syntax-coloured preview for `.code` items (made once at capture).
    let highlighted: AttributedString?

    init(content: Content, date: Date, isPinned: Bool = false, thumbnail: NSImage? = nil, pixelSize: CGSize? = nil) {
        self.content = content
        self.date = date
        self.isPinned = isPinned
        self.thumbnail = thumbnail
        self.pixelSize = pixelSize
        self.kind = Self.classify(content)
        if kind == .code, case .text(let s) = content {
            highlighted = Self.highlight(String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)))
        } else {
            highlighted = nil
        }
    }

    /// Text used for search.
    var searchText: String {
        switch content {
        case .text(let s): return s
        case .image: return L("Image")
        case .files(let urls): return urls.map(\.lastPathComponent).joined(separator: " ")
        }
    }

    // MARK: Classification

    private static func classify(_ content: Content) -> Kind {
        switch content {
        case .image:
            return .media
        case .files(let urls):
            let media = urls.allSatisfy { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
            }
            return media ? .media : .file
        case .text(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if isLink(t) { return .link }
            if isColor(t) { return .color }
            if isCode(t) { return .code }
            return .text
        }
    }

    static func isLink(_ t: String) -> Bool {
        (t.hasPrefix("http://") || t.hasPrefix("https://")) && !t.contains(where: \.isWhitespace)
    }

    private static let colorPattern = try! NSRegularExpression(
        pattern: #"^(#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})|(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\([^()]{1,80}\))$"#,
        options: [.caseInsensitive])

    static func isColor(_ t: String) -> Bool {
        guard t.count <= 90 else { return false }
        return colorPattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    private static let codeHints = ["func ", "function ", "=>", "->", "return ", "const ", "let ", "var ", "import ",
                                    "def ", "class ", "struct ", "#include", "<?php", "</", "/>", "SELECT ",
                                    "if (", "for (", "){", ") {", "};", "::", "!==", "==="]

    /// `.env` / shell assignments: `KEY=value`, `export KEY=value`, `# comment`.
    private static let envLine = try! NSRegularExpression(pattern: #"^(export\s+)?[A-Za-z_][A-Za-z0-9_.]*="#)

    /// YAML mapping line: `key:`, `key: value`, `- key: value`, `"quoted key": value`.
    private static let yamlKey = try! NSRegularExpression(pattern: #"^(-\s+)?("[^"]+"|'[^']+'|[A-Za-z0-9_][\w.\-/]*)\s*:(\s|$)"#)

    /// Heuristic: CSS declarations, braces/semicolons, common keywords, .env or YAML.
    private static func isCode(_ t: String) -> Bool {
        let lines = t.split(whereSeparator: \.isNewline)
        let content = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if !content.isEmpty,
           content.allSatisfy({ envLine.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) {
            return true
        }
        // YAML: each line `key:` / `key: value` / `- item` / `---`, with at least two keys.
        // (`Note: …` or a `Todo:` + bullet list stays text.)
        if content.count >= 2 {
            let isKey: (String) -> Bool = { yamlKey.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            let isOther: (String) -> Bool = { $0.hasPrefix("- ") || $0 == "-" || $0 == "---" || $0 == "..." }
            if content.filter(isKey).count >= 2, content.allSatisfy({ isKey($0) || isOther($0) }) { return true }
        }
        let hits = codeHints.filter { t.contains($0) }.count
        let structural = lines.filter {
            let l = $0.trimmingCharacters(in: .whitespaces)
            return l.hasSuffix(";") || l.hasSuffix("{") || l == "}" || l.hasSuffix("};")
        }.count
        if lines.count > 1 { return hits >= 2 || structural >= 2 || (hits >= 1 && structural >= 1) }
        // Single line: `font-size: 1rem;` or `foo(bar);`
        return (t.hasSuffix(";") && (t.contains(":") || t.contains("("))) || hits >= 2
    }

    // MARK: Syntax colouring

    private static let syntaxRules: [(NSRegularExpression, Color)] = [
        // Later rules win: keys/calls < keywords < numbers < strings < comments.
        (#"(?m)^\s*(?:export\s+|-\s+)?[A-Za-z_][\w.-]*(?=\s*[=:])"#, Color(red: 0.55, green: 0.85, blue: 0.95)),   // env keys, CSS properties
        (#"\b[A-Za-z_]\w*(?=\()"#, Color(red: 0.45, green: 0.72, blue: 1.0)),                                    // calls
        (#"\b(func|function|return|const|let|var|import|export|from|def|class|struct|enum|interface|type|if|else|for|while|switch|case|in|of|new|await|async|public|private|static|true|false|null|nil|undefined|self|this)\b"#,
         Color(red: 0.98, green: 0.47, blue: 0.70)),                                                                  // keywords
        (#"(?<![\w#])-?\d+(\.\d+)?(px|rem|em|vh|vw|ms|s|%|deg)?\b"#, Color(red: 1.0, green: 0.72, blue: 0.35)),  // numbers
        (#""[^"\n]*"|'[^'\n]*'|`[^`]*`"#, Color(red: 0.56, green: 0.88, blue: 0.55)),                               // strings
        (#"(?m)((?<!:)//.*$|^\s*#.*$|/\*[\s\S]*?\*/)"#, Color.white.opacity(0.38)),                                    // comments
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static func highlight(_ code: String) -> AttributedString {
        var attr = AttributedString(code)
        attr.foregroundColor = Color.white.opacity(0.85)
        let whole = NSRange(code.startIndex..., in: code)
        for (regex, color) in syntaxRules {
            for match in regex.matches(in: code, range: whole) {
                guard let r = Range(match.range, in: code), let ar = Range(r, in: attr) else { continue }
                attr[ar].foregroundColor = color
            }
        }
        return attr
    }

    /// Parsed swatch colour for `.color` items (hex, rgb(a), hsl(a); others show a neutral swatch).
    var swatch: NSColor? {
        guard kind == .color, case .text(let s) = content else { return nil }
        return Self.parseColor(s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func parseColor(_ t: String) -> NSColor? {
        if t.hasPrefix("#") {
            var hex = String(t.dropFirst())
            if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard let v = UInt64(hex, radix: 16) else { return nil }
            let hasAlpha = hex.count == 8
            let r = hasAlpha ? (v >> 24) & 0xff : (v >> 16) & 0xff
            let g = hasAlpha ? (v >> 16) & 0xff : (v >> 8) & 0xff
            let b = hasAlpha ? (v >> 8) & 0xff : v & 0xff
            let a = hasAlpha ? v & 0xff : 0xff
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
                           alpha: CGFloat(a) / 255)
        }
        guard let open = t.firstIndex(of: "("), t.hasSuffix(")") else { return nil }
        let fn = String(t[..<open])
        var parts = t[t.index(after: open)..<t.index(before: t.endIndex)]
            .split(whereSeparator: { ", /".contains($0) }).map(String.init)
        // color(srgb …) / color(display-p3 …): first token names the space.
        let space = fn == "color" && !parts.isEmpty ? parts.removeFirst() : ""
        // (value, wasPercent) – `none` counts as 0; hue units deg/rad/turn → degrees.
        let nums: [(v: Double, pct: Bool)?] = parts.map { p in
            if p == "none" { return (0, false) }
            if p.hasSuffix("%") { return Double(p.dropLast()).map { ($0 / 100, true) } }
            if p.hasSuffix("turn") { return Double(p.dropLast(4)).map { ($0 * 360, false) } }
            if p.hasSuffix("rad") { return Double(p.dropLast(3)).map { ($0 * 180 / .pi, false) } }
            if p.hasSuffix("deg") { return Double(p.dropLast(3)).map { ($0, false) } }
            return Double(p).map { ($0, false) }
        }
        guard nums.count >= 3, let x = nums[0], let y = nums[1], let z = nums[2] else { return nil }
        let alpha = nums.count > 3 ? (nums[3]?.v ?? 1) : 1
        let (a, b, c) = (x.v, y.v, z.v)
        switch fn {
        case "rgb", "rgba":
            let scale: ((v: Double, pct: Bool)) -> Double = { $0.pct ? $0.v : $0.v / 255 }
            return NSColor(srgbRed: scale(x), green: scale(y), blue: scale(z), alpha: alpha)
        case "hsl", "hsla":
            // HSL → HSB
            let l = c, s = b
            let v = l + s * min(l, 1 - l)
            let sv = v == 0 ? 0 : 2 * (1 - l / v)
            return NSColor(hue: hue01(a), saturation: sv, brightness: v, alpha: alpha)
        case "hwb":
            // Pure hue mixed with white (b) and black (c).
            let (w, k) = b + c >= 1 ? (b / (b + c), c / (b + c)) : (b, c)
            guard let pure = NSColor(hue: hue01(a), saturation: 1, brightness: 1, alpha: 1).usingColorSpace(.sRGB)
            else { return nil }
            let mix: (CGFloat) -> CGFloat = { $0 * (1 - w - k) + w }
            return NSColor(srgbRed: mix(pure.redComponent), green: mix(pure.greenComponent),
                           blue: mix(pure.blueComponent), alpha: alpha)
        case "oklab", "oklch":
            // L: 0–1 (100 % = 1); a/b/C: 100 % = 0.4.
            let L = a
            let (oa, ob) = fn == "oklab" ? (y.pct ? b * 0.4 : b, z.pct ? c * 0.4 : c)
                                         : polar(y.pct ? b * 0.4 : b, c)
            return srgb(fromLinear: oklabToLinearSRGB(L, oa, ob), alpha: alpha)
        case "lab", "lch":
            // CIE Lab (D50). L: 0–100 (100 % = 100); a/b: 100 % = 125; C: 100 % = 150.
            let L = x.pct ? a * 100 : a
            let (la, lb) = fn == "lab" ? (y.pct ? b * 125 : b, z.pct ? c * 125 : c)
                                       : polar(y.pct ? b * 150 : b, c)
            return srgb(fromLinear: labToLinearSRGB(L, la, lb), alpha: alpha)
        case "color":
            switch space {
            case "srgb": return NSColor(srgbRed: a, green: b, blue: c, alpha: alpha)
            case "display-p3": return NSColor(displayP3Red: a, green: b, blue: c, alpha: alpha)
            default: return nil
            }
        default:
            return nil
        }
    }

    // MARK: Colour space maths (CSS Color 4)

    private static func hue01(_ degrees: Double) -> Double {
        let h = degrees.truncatingRemainder(dividingBy: 360)
        return (h < 0 ? h + 360 : h) / 360
    }

    /// Chroma + hue (degrees) → a/b.
    private static func polar(_ chroma: Double, _ hue: Double) -> (Double, Double) {
        let r = hue * .pi / 180
        return (chroma * cos(r), chroma * sin(r))
    }

    /// OKLab → linear sRGB (Björn Ottosson's reference matrices).
    private static func oklabToLinearSRGB(_ L: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return ( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// CIE Lab (D50) → XYZ (D50) → linear sRGB (Bradford-adapted to D65).
    private static func labToLinearSRGB(_ L: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
        let fy = (L + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        let inv: (Double) -> Double = { $0 > 6.0 / 29 ? $0 * $0 * $0 : 3 * pow(6.0 / 29, 2) * ($0 - 4.0 / 29) }
        let X = 0.96422 * inv(fx), Y = inv(fy), Z = 0.82521 * inv(fz)
        return ( 3.1338561 * X - 1.6168667 * Y - 0.4906146 * Z,
                -0.9787684 * X + 1.9161415 * Y + 0.0334540 * Z,
                 0.0719453 * X - 0.2289914 * Y + 1.4052427 * Z)
    }

    /// Linear → gamma-encoded sRGB; out-of-gamut values are clipped.
    private static func srgb(fromLinear c: (Double, Double, Double), alpha: Double) -> NSColor {
        let encode: (Double) -> Double = {
            let v = min(max($0, 0), 1)
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return NSColor(srgbRed: encode(c.0), green: encode(c.1), blue: encode(c.2), alpha: alpha)
    }
}
