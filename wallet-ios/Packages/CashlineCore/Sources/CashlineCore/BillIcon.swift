import Foundation

/// Bill icons. Ids match the web app so icons survive import/export; the
/// native app draws each as a colored tile with an SF Symbol or a monogram.
public struct BillIcon: Hashable, Sendable {
    public enum Glyph: Hashable, Sendable {
        /// SF Symbol name, drawn white on the tile.
        case symbol(String)
        /// Short brand-style monogram.
        case monogram(String, foreground: UInt32)
    }

    public let id: String
    public let label: String
    /// Tile background, 0xRRGGBB.
    public let background: UInt32
    public let glyph: Glyph

    /// Display order for pickers and filters.
    public static let ordered: [BillIcon] = [
        // banks / card issuers
        BillIcon(id: "chase", label: "Chase", background: 0x1178C5, glyph: .monogram("CH", foreground: 0xFFFFFF)),
        BillIcon(id: "boa", label: "Bank of America", background: 0x012169, glyph: .monogram("BA", foreground: 0xFFFFFF)),
        BillIcon(id: "amex", label: "Amex", background: 0x006FCF, glyph: .monogram("AX", foreground: 0xFFFFFF)),
        BillIcon(id: "citi", label: "Citi", background: 0xFFFFFF, glyph: .monogram("citi", foreground: 0x013B72)),
        BillIcon(id: "discover", label: "Discover", background: 0xF76B1C, glyph: .monogram("D", foreground: 0xFFFFFF)),
        BillIcon(id: "wells", label: "Wells Fargo", background: 0xD71E28, glyph: .monogram("WF", foreground: 0xFFCD41)),
        BillIcon(id: "capone", label: "Capital One", background: 0x013D5B, glyph: .monogram("C1", foreground: 0xFFFFFF)),
        BillIcon(id: "usbank", label: "U.S. Bank", background: 0x0C2074, glyph: .monogram("US", foreground: 0xFFFFFF)),
        // categories
        BillIcon(id: "card", label: "Credit card", background: 0x3B5268, glyph: .symbol("creditcard")),
        BillIcon(id: "bank", label: "Bank", background: 0x5B6B7C, glyph: .symbol("building.columns")),
        BillIcon(id: "bolt", label: "Electricity", background: 0xF59E0B, glyph: .symbol("bolt.fill")),
        BillIcon(id: "drop", label: "Water", background: 0x2F80ED, glyph: .symbol("drop.fill")),
        BillIcon(id: "flame", label: "Gas", background: 0xF2711C, glyph: .symbol("flame.fill")),
        BillIcon(id: "wifi", label: "Internet", background: 0x7C5CE0, glyph: .symbol("wifi")),
        BillIcon(id: "phone", label: "Phone", background: 0x12A594, glyph: .symbol("iphone")),
        BillIcon(id: "trash", label: "Trash", background: 0x7A8494, glyph: .symbol("trash")),
        BillIcon(id: "home", label: "Rent / home", background: 0x2FA36B, glyph: .symbol("house.fill")),
        BillIcon(id: "shield", label: "Insurance", background: 0x4F63D2, glyph: .symbol("shield.fill")),
        BillIcon(id: "car", label: "Car", background: 0xC75146, glyph: .symbol("car.fill")),
        BillIcon(id: "tv", label: "TV / stream", background: 0xD6336C, glyph: .symbol("play.tv.fill")),
        BillIcon(id: "bill", label: "Other bill", background: 0x64748B, glyph: .symbol("doc.text.fill")),
    ]

    public static let all: [String: BillIcon] = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })

    public static func icon(_ id: String) -> BillIcon { all[id] ?? all["bill"]! }

    private static let rules: [(NSRegularExpression, String)] = [
        (#"chase|sapphire|freedom"#, "chase"),
        (#"amex|american\s*express|blue cash|platinum card|gold card"#, "amex"),
        (#"citi\b|citibank|double cash"#, "citi"),
        (#"discover"#, "discover"),
        (#"bank of america|bofa|b of a"#, "boa"),
        (#"wells\s*fargo|wells"#, "wells"),
        (#"capital\s*one|cap\s*one|quicksilver|venture"#, "capone"),
        (#"u\.?s\.?\s*bank"#, "usbank"),
        (#"electr|power|energy|edison|pg&e|pge"#, "bolt"),
        (#"water|sewer|sewage"#, "drop"),
        (#"\bgas\b|propane"#, "flame"),
        (#"internet|wifi|fiber|broadband|xfinity|comcast|spectrum"#, "wifi"),
        (#"phone|mobile|wireless|verizon|t-?mobile|at&t"#, "phone"),
        (#"trash|garbage|waste|recycl"#, "trash"),
        (#"rent|mortgage|hoa|lease|apartment"#, "home"),
        (#"insur|geico|allstate|progressive"#, "shield"),
        (#"\bcar\b|\bauto\b|vehicle"#, "car"),
        (#"tv|cable|stream|netflix|hulu|disney|spotify|youtube"#, "tv"),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]), $0.1) }

    /// Picks an icon from the bill's name, like the web app.
    public static func suggest(name: String, kind: BillKind) -> String {
        let range = NSRange(name.startIndex..., in: name)
        for (re, id) in rules where re.firstMatch(in: name, range: range) != nil { return id }
        return kind == .card ? "card" : "bill"
    }
}
