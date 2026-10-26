import SwiftUI

/// A tiny pixel-art figure drawn from a character map (v4.3). Our own
/// sprites — a long-necked dog, an owl, a heart, a letter — in the spirit
/// of old games, not copies of any.
struct FunSprite: View {
    let rows: [String]
    var pixel: CGFloat = 3
    @Environment(\.colorScheme) private var colorScheme

    private var width: Int { rows.map(\.count).max() ?? 0 }

    var body: some View {
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, character) in row.enumerated() {
                    guard let color = Self.color(character, dark: colorScheme == .dark) else { continue }
                    context.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel)), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(width) * pixel, height: CGFloat(rows.count) * pixel)
        .accessibilityHidden(true)
    }

    /// Palette: # outline · w fur/paper · g shade · e eye · p tongue ·
    /// b owl brown · l owl belly · y eye yellow · k black · o beak · r red.
    static func color(_ character: Character, dark: Bool) -> Color? {
        switch character {
        case "#": return dark ? Color(white: 0.05) : Color(white: 0.12)
        case "w": return Color(white: 0.98)
        case "g": return Color(white: 0.8)
        case "e", "k": return Color(white: 0.08)
        case "p": return Color(red: 0.95, green: 0.45, blue: 0.55)
        case "b": return Color(red: 0.47, green: 0.32, blue: 0.2)
        case "l": return Color(red: 0.86, green: 0.76, blue: 0.6)
        case "y": return Color(red: 0.98, green: 0.82, blue: 0.2)
        case "o": return Color(red: 0.95, green: 0.6, blue: 0.15)
        case "r": return Color(red: 0.9, green: 0.2, blue: 0.25)
        default: return nil
        }
    }
}

enum Sprites {
    /// The same sprite facing the other way.
    static func mirrored(_ rows: [String]) -> [String] {
        let width = rows.map(\.count).max() ?? 0
        return rows.map { String(($0 + String(repeating: ".", count: width - $0.count)).reversed()) }
    }

    /// Sitting dog, its neck leaving at the top right (rows 0–5).
    static let dogBody = [
        "...........######",
        "..........#wwwwww",
        ".........#wwwwwww",
        ".........#wwwwwww",
        "##.......#wwwwwww",
        "#w#....##wwwwwww#",
        ".#w#.##wwwwwwwww#",
        "..#w#wwwwwwwwwww#",
        "..#wwwwwwwwwwwww#",
        "..#wwwwwwwwwwwww#",
        "..#wgwwwwwwwwwgw#",
        "..#wgwwwwwwwwwgw#",
        "...###.#####.###.",
    ]

    /// The head at the far end of the neck (enters on the left, rows 4–9).
    static let dogHead = [
        "..##......##.",
        ".#gw#....#wg#",
        ".#www####www#",
        ".#wwwwwwwwww#",
        "#wwwwwwwwwwww",
        "wwwewwwwewwww",
        "wwwewwwwewww#",
        "wwwwwwwwwwww#",
        "wwwwww##wwww#",
        "#wwwwwppwwww#",
        ".#wwwwppwww#.",
        "..#########..",
    ]

    static let owlWingsUp = [
        "..b........b..",
        ".bb########bb.",
        ".b#bbbbbbbb#b.",
        "..#yk#bb#ky#..",
        "..#yy#oo#yy#..",
        "..#bbbbbbbb#..",
        "bb#bllllllb#bb",
        ".bb#llllll#bb.",
        "..#bllllllb#..",
        "..#bbbbbbbb#..",
        "...#kk..kk#...",
    ]

    static let owlWingsDown = [
        "..b........b..",
        "..b########b..",
        "..#bbbbbbbb#..",
        "..#yk#bb#ky#..",
        "..#yy#oo#yy#..",
        "..#bbbbbbbb#..",
        "..#bllllllb#..",
        "bb#bllllllb#bb",
        "bbb#bbbbbb#bbb",
        "..#bbbbbbbb#..",
        "...#kk..kk#...",
    ]

    static let heart = [
        ".rr.rr.",
        "rrrrrrr",
        "rrrrrrr",
        ".rrrrr.",
        "..rrr..",
        "...r...",
    ]

    static let letter = [
        "#########",
        "##wwwww##",
        "#w#www#w#",
        "#ww#r#ww#",
        "#wwwwwww#",
        "#########",
    ]
}
