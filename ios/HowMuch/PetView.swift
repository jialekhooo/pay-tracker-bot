import SwiftUI
import HowMuchCore

// MARK: - Colours

enum PetPalette {
    static let outline = Color(red: 0.13, green: 0.20, blue: 0.22)
    static let cheek = Color(red: 1.0, green: 0.62, blue: 0.62)
    static let leaf = Color(red: 0.30, green: 0.70, blue: 0.32)
    static let leafDark = Color(red: 0.18, green: 0.50, blue: 0.22)
    static let shell = Color(red: 0.99, green: 0.96, blue: 0.88)
    static let shellShade = Color(red: 0.90, green: 0.85, blue: 0.74)
    static let tear = Color(red: 0.45, green: 0.70, blue: 1.0)
    static let gold = Color(red: 1.0, green: 0.80, blue: 0.20)
    static let goldDark = Color(red: 0.85, green: 0.60, blue: 0.10)
    static let red = Color(red: 0.90, green: 0.27, blue: 0.27)
    static let redDark = Color(red: 0.70, green: 0.15, blue: 0.18)
    static let pink = Color(red: 1.0, green: 0.55, blue: 0.72)
    static let jade = Color(red: 0.06, green: 0.45, blue: 0.52)
    static let purple = Color(red: 0.42, green: 0.32, blue: 0.78)
    static let purpleDark = Color(red: 0.30, green: 0.22, blue: 0.60)
    static let white = Color.white
    static let flower = Color(red: 1.0, green: 0.72, blue: 0.82)
    static let straw = Color(red: 0.96, green: 0.84, blue: 0.52)
    static let strawDark = Color(red: 0.78, green: 0.62, blue: 0.30)
    static let navy = Color(red: 0.18, green: 0.24, blue: 0.45)
    static let blue = Color(red: 0.30, green: 0.55, blue: 0.90)
    static let glow = Color(red: 0.40, green: 0.95, blue: 0.95)
    static let charcoal = Color(red: 0.20, green: 0.22, blue: 0.25)
    static let cream = Color(red: 0.93, green: 0.90, blue: 0.84)
}

/// Penny's coin colours: the classic gold, or a skin from the shop.
struct PetSkin {
    var base = Color(red: 0.99, green: 0.80, blue: 0.30)
    var light = Color(red: 1.0, green: 0.94, blue: 0.62)
    var deep = Color(red: 0.88, green: 0.60, blue: 0.14)
    var outline = Color(red: 0.36, green: 0.22, blue: 0.06)
    /// Eyes and mouth.
    var ink = PetPalette.outline
    /// A little mark on the forehead.
    var badge: Character?
    var rainbow = false, sparkles = false
    /// Colour bands down the body (rainbow and holographic skins).
    var rows: [Color]?

    init(_ item: PetItem?) {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        switch item?.id {
        case "pioneer":
            base = rgb(0.20, 0.66, 0.54); light = rgb(0.60, 0.90, 0.78); deep = rgb(0.08, 0.44, 0.36); outline = rgb(0.03, 0.22, 0.18); badge = "*"
        case "rose-gold":
            base = rgb(0.97, 0.72, 0.66); light = rgb(1, 0.90, 0.86); deep = rgb(0.82, 0.48, 0.43); outline = rgb(0.42, 0.18, 0.16)
        case "silver":
            base = rgb(0.80, 0.83, 0.88); light = rgb(0.97, 0.98, 0.99); deep = rgb(0.56, 0.60, 0.67); outline = rgb(0.24, 0.27, 0.32)
        case "matcha":
            base = rgb(0.64, 0.80, 0.47); light = rgb(0.87, 0.95, 0.74); deep = rgb(0.40, 0.58, 0.28); outline = rgb(0.17, 0.30, 0.12)
        case "sakura":
            base = rgb(1, 0.78, 0.85); light = rgb(1, 0.93, 0.95); deep = rgb(0.90, 0.52, 0.65); outline = rgb(0.45, 0.18, 0.28); badge = "f"
        case "midnight":
            base = rgb(0.24, 0.28, 0.50); light = rgb(0.46, 0.52, 0.80); deep = rgb(0.13, 0.15, 0.32); outline = rgb(0.05, 0.06, 0.16)
            ink = .white; badge = "m"; sparkles = true
        case "copper":
            base = rgb(0.86, 0.53, 0.33); light = rgb(0.99, 0.77, 0.57); deep = rgb(0.63, 0.34, 0.18); outline = rgb(0.32, 0.14, 0.06)
        case "bubblegum":
            base = rgb(1, 0.64, 0.82); light = rgb(1, 0.88, 0.95); deep = rgb(0.88, 0.42, 0.64); outline = rgb(0.45, 0.12, 0.30); badge = "o"
        case "ocean":
            base = rgb(0.32, 0.64, 0.88); light = rgb(0.72, 0.91, 0.99); deep = rgb(0.16, 0.42, 0.68); outline = rgb(0.05, 0.18, 0.36); badge = "~"
        case "lava":
            // Dark rock with a glowing ring and glowing eyes.
            base = rgb(0.32, 0.14, 0.11); light = rgb(1, 0.58, 0.22); deep = rgb(0.92, 0.36, 0.08); outline = rgb(0.12, 0.03, 0.02)
            ink = rgb(1, 0.78, 0.30); badge = "^"
        case "blaze":
            // The Unstoppable badge: flame colours from yellow to red.
            light = rgb(1, 1, 0.85); deep = rgb(0.72, 0.18, 0.10); outline = rgb(0.42, 0.08, 0.04); rows = PetSkin.blazeRows; badge = "^"
        case "frost":
            // Gift-code special: icy blues with a snowflake.
            light = .white; deep = rgb(0.55, 0.75, 0.92); outline = rgb(0.20, 0.40, 0.62); ink = rgb(0.12, 0.24, 0.42)
            rows = PetSkin.frostRows; sparkles = true; badge = "x"
        case "rainbow":
            light = .white; deep = rgb(0.62, 0.48, 0.90); outline = rgb(0.30, 0.22, 0.45); rainbow = true
        case "terminal":
            // Developer only: a dark screen with green text.
            base = rgb(0.10, 0.13, 0.13); light = rgb(0.24, 0.30, 0.29); deep = rgb(0.05, 0.07, 0.07); outline = rgb(0.10, 0.75, 0.40)
            ink = rgb(0.30, 1, 0.55); badge = ">"
        case "galaxy":
            // Gift-code special: deep space with stars.
            light = rgb(0.55, 0.45, 0.95); deep = rgb(0.10, 0.06, 0.25); outline = rgb(0.04, 0.02, 0.12)
            ink = .white; rows = PetSkin.galaxyRows; sparkles = true
        case "holo":
            // Developer only: shimmering like a hologram sticker.
            light = .white; deep = rgb(0.45, 0.55, 0.85); outline = rgb(0.20, 0.25, 0.45); rows = PetSkin.holoRows; sparkles = true
        default: break
        }
    }

    static let galaxyRows: [Color] = [
        Color(red: 0.12, green: 0.08, blue: 0.32), Color(red: 0.22, green: 0.12, blue: 0.48), Color(red: 0.38, green: 0.20, blue: 0.62),
        Color(red: 0.30, green: 0.22, blue: 0.66), Color(red: 0.16, green: 0.20, blue: 0.52), Color(red: 0.10, green: 0.10, blue: 0.34),
    ]
    static let holoRows: [Color] = [
        Color(red: 0.75, green: 0.95, blue: 1), Color(red: 0.80, green: 0.80, blue: 1), Color(red: 0.95, green: 0.80, blue: 1),
        Color(red: 1, green: 0.85, blue: 0.92), Color(red: 0.85, green: 1, blue: 0.92), Color(red: 0.75, green: 0.90, blue: 1),
    ]
    static let blazeRows: [Color] = [
        Color(red: 1, green: 0.95, blue: 0.55), Color(red: 1, green: 0.85, blue: 0.35), Color(red: 1, green: 0.68, blue: 0.25),
        Color(red: 0.98, green: 0.52, blue: 0.18), Color(red: 0.92, green: 0.36, blue: 0.15), Color(red: 0.78, green: 0.22, blue: 0.12),
    ]
    static let frostRows: [Color] = [
        Color(red: 0.93, green: 0.98, blue: 1), Color(red: 0.86, green: 0.95, blue: 1), Color(red: 0.79, green: 0.91, blue: 0.99),
        Color(red: 0.73, green: 0.87, blue: 0.98), Color(red: 0.67, green: 0.83, blue: 0.96), Color(red: 0.61, green: 0.79, blue: 0.94),
    ]
    static let rainbowRows: [Color] = [
        Color(red: 1, green: 0.62, blue: 0.62), Color(red: 1, green: 0.78, blue: 0.5), Color(red: 1, green: 0.92, blue: 0.5),
        Color(red: 0.62, green: 0.9, blue: 0.62), Color(red: 0.55, green: 0.8, blue: 1), Color(red: 0.78, green: 0.64, blue: 1),
    ]
}

// MARK: - Sprite

/// Penny drawn as pixel art on a 24×24 grid. Shapes are generated, so every stage, mood, skin and
/// accessory lines up without a hand-drawn bitmap for each combination.
struct PetSprite: View {
    let stage: PetProgress.Stage
    let mood: PetProgress.Mood
    /// What Penny is wearing, by slot (scenes are drawn by `PetScene`).
    var outfit: [PetSlot: PetItem] = [:]
    var animate = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Penny settles down after a little while, so the screen isn't redrawn forever.
    @State private var resting = false

    private var moving: Bool {
        animate && !resting && !reduceMotion && scenePhase == .active && !Self.automatedTest && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !moving)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let live = moving
            // Blink for 0.15 s roughly every 3.5 s; bob gently (slower when down).
            let blink = live && t.truncatingRemainder(dividingBy: 3.5) < 0.15
            let slow = [.sad, .hungry].contains(mood)
            let bob = live ? (sin(t * (slow ? 1.4 : 2.6)) > 0 ? 1 : 0) : 0
            let wobble = stage == .egg && live ? (t.truncatingRemainder(dividingBy: 2.4) < 0.4 ? sin(t * 30) * 4 : 0) : 0
            Canvas { ctx, size in
                let cell = min(size.width, size.height) / CGFloat(PetPixels.grid)
                let originX = (size.width - cell * CGFloat(PetPixels.grid)) / 2
                let originY = (size.height - cell * CGFloat(PetPixels.grid)) / 2
                for p in PetPixels.make(stage: stage, mood: mood, outfit: outfit, blink: blink, bob: bob) {
                    let rect = CGRect(x: originX + CGFloat(p.x) * cell, y: originY + CGFloat(p.y) * cell, width: cell + 0.5, height: cell + 0.5)
                    ctx.fill(Path(rect), with: .color(p.color))
                }
            }
            .rotationEffect(.degrees(wobble), anchor: .bottom)
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: animate) {
            resting = false
            try? await Task.sleep(for: .seconds(25))
            resting = true
        }
        .accessibilityElement()
        .accessibilityLabel("\(stage.title), feeling \(mood.label.lowercased())")
    }

    /// UI tests wait for the app to be idle, which a never-ending animation prevents.
    static var automatedTest: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--ui-test-account")
        #else
        return false
        #endif
    }
}

struct PetPixel {
    let x: Int
    let y: Int
    let color: Color
}

enum PetPixels {
    static let grid = 24

    private struct Shape { var cx: Double; var cy: Double; var rx: Double; var ry: Double }

    static func make(stage: PetProgress.Stage, mood: PetProgress.Mood, outfit: [PetSlot: PetItem], blink: Bool, bob: Int) -> [PetPixel] {
        let skin = PetSkin(outfit[.skin])
        var canvas = [[Color?]](repeating: [Color?](repeating: nil, count: grid), count: grid)
        func put(_ x: Int, _ y: Int, _ c: Color) {
            guard x >= 0, y >= 0, x < grid, y < grid else { return }
            canvas[y][x] = c
        }
        func stamp(_ rows: [String], x: Int, y: Int, _ palette: [Character: Color]) {
            for (dy, row) in rows.enumerated() {
                for (dx, ch) in row.enumerated() { if let c = palette[ch] { put(x + dx, y + dy, c) } }
            }
        }

        if stage == .egg {
            ellipse(Shape(cx: 12, cy: 13.5, rx: 6, ry: 7.5), into: &canvas, outline: PetPalette.outline) { x, y, d in
                // Little gold coins peeking through the shell.
                if [(9, 10), (14, 13), (10, 16), (15, 9), (12, 18)].contains(where: { $0 == (x, y) }) { return skin.base }
                if [(10, 10), (15, 13), (11, 16)].contains(where: { $0 == (x, y) }) { return skin.deep }
                if d < 0.45 && x < 11 && y < 11 { return PetPalette.white }
                return y > 17 ? PetPalette.shellShade : PetPalette.shell
            }
            return flatten(canvas)
        }

        let s: Shape = switch stage {
        case .hatchling: Shape(cx: 12, cy: 15.5, rx: 5, ry: 4.8)
        case .coinling: Shape(cx: 12, cy: 15, rx: 6.2, ry: 5.8)
        default: Shape(cx: 12, cy: 14.5, rx: 7.6, ry: 7)
        }
        let lift = bob
        let cy = s.cy - Double(lift)
        var top = Int((cy - s.ry).rounded(.down))
        let eyeY = Int(cy - s.ry * 0.15)
        let eyeDX = Int((s.rx * 0.45).rounded())
        let cx = Int(s.cx)

        // Feet for bigger stages.
        if stage >= .coinling {
            let footY = Int(s.cy + s.ry)
            for fx in [cx - eyeDX - 1, cx + eyeDX] { put(fx, footY, skin.outline); put(fx + 1, footY, skin.outline) }
        }

        // The coin body: highlight top-left, an inner milled ring, darker underneath.
        let ringed = stage >= .coinling
        ellipse(Shape(cx: s.cx, cy: cy, rx: s.rx, ry: s.ry), into: &canvas, outline: skin.outline) { x, y, d in
            if ringed && d > 0.66 && d < 0.84 { return skin.deep }
            if d < 0.4 && Double(x) < s.cx - s.rx * 0.2 && Double(y) < cy - s.ry * 0.2 { return skin.light }
            if let bands = skin.rows ?? (skin.rainbow ? PetSkin.rainbowRows : nil) {
                let row = Int((Double(y) - (cy - s.ry)) / (2 * s.ry) * Double(bands.count))
                return bands[min(max(row, 0), bands.count - 1)]
            }
            if Double(y) > cy + s.ry * 0.5 { return skin.deep }
            return skin.base
        }
        if let first = (0..<grid).first(where: { canvas[$0][cx] != nil }) { top = first }
        if skin.sparkles {
            for (dx, dy) in [(-3, 3), (4, 5), (2, -1), (-4, -2)] where canvas[safe: Int(cy) + dy]?[safe: cx + dx] != nil {
                put(cx + dx, Int(cy) + dy, PetPalette.white)
            }
        }

        // Something on top: a sprout for a coinling, sparkles for a golden coin, a crown for a treasure.
        let p: [Character: Color] = [
            "o": PetPalette.outline, "y": PetPalette.gold, "Y": PetPalette.goldDark, "r": PetPalette.red,
            "R": PetPalette.redDark, "p": PetPalette.pink, "j": PetPalette.jade, "w": PetPalette.white,
            "k": Color.black, "b": PetPalette.tear, "l": PetPalette.leaf, "L": PetPalette.leafDark,
            "f": PetPalette.flower, "v": PetPalette.purple, "V": PetPalette.purpleDark, "g": Color.gray.opacity(0.45),
            "s": PetPalette.straw, "S": PetPalette.strawDark, "n": PetPalette.navy, "c": PetPalette.blue, "q": PetPalette.glow,
            "e": PetPalette.charcoal, "W": PetPalette.cream,
        ]
        if outfit[.hat] == nil {
            switch stage {
            case .hatchling: stamp([".l", "L."], x: cx, y: top - 2, p)
            case .coinling: stamp(["..ll", ".lL.", ".L.."], x: cx - 1, y: top - 3, p)
            case .golden: stamp(["ll...ll", ".lL.Ll.", "...L..."], x: cx - 3, y: top - 3, p)
            case .treasure: stamp(["y.y.y.y", "yoyoyoy", "yyyryyy", "YYYYYYY"], x: cx - 3, y: top - 3, p)
            case .egg: break
            }
        }
        if stage >= .golden {
            stamp([".w.", "wyw", ".w."], x: cx - Int(s.rx) - 3, y: top + 1, p)
            stamp(["w"], x: cx + Int(s.rx) + 1, y: top + 4, p)
            if stage == .treasure { stamp([".y.", "yYy", ".y."], x: cx + Int(s.rx), y: Int(cy) + 3, p) }
        }

        // Forehead mark for special skins.
        switch skin.badge {
        case "*": stamp([".y.", "yyy", ".y."], x: cx - 1, y: top + 1, p)
        case "f": stamp([".f.", "fyf", ".f."], x: cx - 1, y: top + 1, p)
        case "m": stamp(["yy", "y."], x: cx - 1, y: top + 2, p)
        case "o": stamp([".w.", "w.w", ".w."], x: cx - 1, y: top + 1, p)
        case "~": stamp([".w..", "w.ww"], x: cx - 2, y: top + 2, p)
        case "^": stamp([".y.", "yry", "yry"], x: cx - 1, y: top + 1, p)
        case "x": stamp(["b.b", ".b.", "b.b"], x: cx - 1, y: top + 1, p)
        case ">": stamp(["g...", ".g..", "g.gg"], x: cx - 2, y: top + 1, [Character("g"): skin.ink])
        default: break
        }

        // Face.
        let ink = skin.ink
        let lx = cx - eyeDX, rx = cx + eyeDX - 1
        if blink || mood == .thriving {
            for ex in [lx, rx] { put(ex - 1, eyeY + 1, ink); put(ex, eyeY, ink); put(ex + 1, eyeY + 1, ink) }
        } else if mood == .sad || mood == .worried {
            for ex in [lx, rx] { put(ex, eyeY + 1, ink); put(ex + 1, eyeY + 1, ink) }
            if mood == .sad { put(lx, eyeY + 2, PetPalette.tear); put(lx, eyeY + 3, PetPalette.tear) }
        } else {
            let tall = stage >= .coinling
            for ex in [lx, rx] {
                put(ex, eyeY, ink)
                if tall { put(ex, eyeY + 1, ink) }
                if stage >= .golden { put(ex + 1, eyeY, ink); put(ex + 1, eyeY + 1, ink); put(ex, eyeY, ink == .white ? skin.deep : PetPalette.white) }
            }
        }
        if mood == .worried {
            // A bead of sweat by the head.
            stamp([".b", "bb", "bb"], x: cx + Int(s.rx) - 1, y: eyeY - 3, p)
        }
        if mood != .sad && mood != .worried {
            put(lx - 2, eyeY + 2, PetPalette.cheek); put(rx + 2 + (stage >= .golden ? 1 : 0), eyeY + 2, PetPalette.cheek)
        }
        let my = eyeY + 3
        switch mood {
        case .thriving, .happy:
            put(cx - 1, my, ink); put(cx, my + 1, ink); put(cx + 1, my, ink)
            if stage >= .golden { put(cx - 2, my, ink); put(cx - 1, my + 1, ink); put(cx + 1, my + 1, ink) }
        case .okay:
            put(cx - 1, my, ink); put(cx, my, ink)
        case .hungry:
            put(cx - 1, my, ink); put(cx, my, ink); put(cx - 1, my + 1, ink); put(cx, my + 1, ink)
        case .sad, .worried:
            put(cx - 1, my + 1, ink); put(cx, my, ink); put(cx + 1, my + 1, ink)
        }

        // A cracked eggshell cup for hatchlings.
        if stage == .hatchling {
            let shellTop = my + 2
            let halfWidths = [6, 6, 6, 5, 4]
            for (i, half) in halfWidths.enumerated() {
                let y = shellTop + i
                for x in (cx - half)..<(cx + half) {
                    if i == 0 { put(x, y, (x - cx) % 2 == 0 ? PetPalette.outline : PetPalette.shell); continue }
                    let edge = i == halfWidths.count - 1 || x == cx - half || x == cx + half - 1
                        || ((x < cx - halfWidths[i - 1] + 1 || x >= cx + halfWidths[i - 1] - 1) && i >= 3)
                    put(x, y, edge ? PetPalette.outline : (i >= 3 ? PetPalette.shellShade : PetPalette.shell))
                }
            }
        }

        // Accessories.
        let neckY = Int(cy + s.ry * 0.45)
        for slot in [PetSlot.neck, .face, .hat] {
            guard let item = outfit[slot] else { continue }
            switch item.id {
            case "cap": stamp(["..oooo..", ".ojjjjo.", "ojjwjjjoooo", "oooooooooo."], x: cx - 4, y: top - 3, p)
            case "party-hat": stamp(["...y...", "..oro..", "..oyo..", ".oryro.", ".oyryo.", ".ooooo."], x: cx - 3, y: top - 4, p)
            case "beanie": stamp(["...w...", "..ojo..", ".ojjjo.", "ojjjjjo", "owwwwwo"], x: cx - 3, y: top - 4, p)
            case "chef-hat": stamp([".ooooo.", "owwwwwo", "owwwwwo", "owgwgwo", ".owwwo.", ".ooooo."], x: cx - 3, y: top - 4, p)
            case "wizard-hat": stamp(["....oo...", "...ovo...", "...ovvo..", "..ovyvo..", "..ovvvvo.", ".oVVVVVVo", "ooooooooo"], x: cx - 4, y: top - 6, p)
            case "flower": stamp([".p.p.", "ppypp", ".p.p."], x: cx + 1, y: top - 2, p)
            case "royal-crown": stamp(["y.y.y.y", "yoyoyoy", "yyyryyy", "YYYYYYY"], x: cx - 3, y: top - 3, p)
            case "round-glasses": stamp(["ooo.ooo", "o.ooo.o", "ooo.ooo"], x: lx - 1, y: eyeY - 1, p)
            case "sunglasses": stamp(["oooooooo", "okkookko", ".kk..kk."], x: lx - 2, y: eyeY - 1, p)
            case "halo": stamp([".yyyyy.", "y.....y", ".yyyyy."], x: cx - 3, y: top - 5, p)
            case "heart-glasses": stamp(["r.r.r.r", "rrr.rrr", ".r...r."], x: lx - 1, y: eyeY - 1, p)
            case "lei":
                let colors = [PetPalette.pink, PetPalette.gold, PetPalette.flower, PetPalette.red]
                for (i, x) in ((cx - Int(s.rx) + 1)...(cx + Int(s.rx) - 1)).enumerated() where neckY < grid && canvas[neckY][x] != nil {
                    put(x, neckY, colors[i % colors.count])
                }
            case "star-glasses": stamp([".p...p.", "ppp.ppp", ".p...p."], x: lx - 1, y: eyeY - 1, p)
            case "scarf":
                for x in (cx - Int(s.rx) + 1)...(cx + Int(s.rx) - 1) where neckY + 1 < grid && canvas[neckY][x] != nil {
                    put(x, neckY, PetPalette.red); put(x, neckY + 1, PetPalette.redDark)
                }
                stamp(["rR", "rR", "R."], x: cx + 2, y: neckY + 1, p)
            case "bow-tie": stamp(["ro.or", "rrorr", "ro.or"], x: cx - 2, y: neckY, p)
            case "straw-hat": stamp(["...ooooo...", "..osssSso..", "..orrrrro..", "osssssssSso", ".ooooooooo."], x: cx - 5, y: top - 4, p)
            case "beret": stamp(["......o...", "..ooooooo.", ".orrrrrrro", "orrrrrrrRo", "oRRRRRRRRo", ".oooooooo."], x: cx - 5, y: top - 4, p)
            case "headphones":
                // A band that follows the top of the head, with a cup over each side.
                let r = Int(s.rx)
                for x in (cx - r + 1)...(cx + r - 2) {
                    if let y = (0..<grid).first(where: { canvas[$0][x] != nil }), y - 1 < eyeY - 1 { put(x, y - 1, PetPalette.red) }
                }
                for x in [cx - r - 1, cx + r - 1] { stamp(["ee", "rr", "rr", "ee"], x: x, y: eyeY - 2, p) }
            case "top-hat": stamp(["..ooooo..", "..okkko..", "..okkko..", "..okkko..", "..orrro..", "okkkkkkko", "ooooooooo"], x: cx - 4, y: top - 6, p)
            case "hard-hat": stamp(["...ooooo...", "..oyyYyyo..", ".oyyyYyyyo.", ".oyyyyyyyo.", "oYYYYYYYYYo"], x: cx - 5, y: top - 4, p)
            case "bunny-ears": stamp([".oo...oo.", "owpo.opwo", "owpo.opwo", "owpo.opwo", ".owo.owo."], x: cx - 4, y: top - 5, p)
            case "square-specs": stamp(["VVVVVVVVV", "V..VVV..V", "V..V.V..V", "VVVV.VVVV"], x: lx - 1, y: eyeY - 1, p)
            case "monocle": stamp(["oooo", "o..o", "o..o", "oooo", "...Y", "...Y", "..Y."], x: rx - 1, y: eyeY - 1, p)
            case "visor": stamp(["oooooooooo", "oqwqqqqwqo", "oooooooooo"], x: lx - 2, y: eyeY - 1, p)
            case "sleep-mask": stamp([".vvvvvvvvvv.", "VvwvwvvwvwvV", ".vvwvvvvwvv."], x: lx - 3, y: eyeY - 1, p)
            case "3d-glasses": stamp(["wwwwwwwww", "wrrwwwccw", "wrrw.wccw", "wwww.wwww"], x: lx - 1, y: eyeY - 1, p)
            case "necktie": stamp(["ono", ".n.", "nnn", "nnn", ".n."], x: cx - 1, y: neckY, p)
            case "bandana":
                for (i, x) in ((cx - Int(s.rx) + 1)...(cx + Int(s.rx) - 1)).enumerated() where neckY < grid && canvas[neckY][x] != nil {
                    put(x, neckY, i % 3 == 1 ? PetPalette.white : PetPalette.blue)
                }
                stamp(["cwcccwc", ".ccwcc.", "..ccc.."], x: cx - 3, y: neckY + 1, p)
            case "pearls":
                for (i, x) in ((cx - Int(s.rx) + 1)...(cx + Int(s.rx) - 1)).enumerated() where neckY < grid && canvas[neckY][x] != nil {
                    put(x, neckY, i % 2 == 0 ? PetPalette.white : PetPalette.cream)
                }
                stamp(["w", "p"], x: cx, y: neckY + 1, p)
            case "gold-chain":
                for (i, x) in ((cx - Int(s.rx) + 1)...(cx + Int(s.rx) - 1)).enumerated() where neckY < grid && canvas[neckY][x] != nil {
                    put(x, neckY, i % 2 == 0 ? PetPalette.gold : PetPalette.goldDark)
                }
                stamp([".ooo.", "oyYyo", "oYyYo", ".ooo."], x: cx - 2, y: neckY + 1, p)
            case "lanyard": stamp(["j.....j", ".j...j.", "..owo..", "..oco..", "..ooo.."], x: cx - 3, y: neckY, p)
            case "bell-collar":
                for x in (cx - Int(s.rx) + 1)...(cx + Int(s.rx) - 1) where neckY < grid && canvas[neckY][x] != nil { put(x, neckY, PetPalette.red) }
                stamp([".yy.", "yyyy", "YYYY", ".oo."], x: cx - 2, y: neckY + 1, p)
            case "medal": stamp(["j...j", ".j.j.", "..y..", ".yYy.", "..y.."], x: cx - 2, y: neckY, p)
            default: break
            }
        }
        return flatten(canvas)
    }

    /// Fills an ellipse with an outline ring; `fill` picks the inner colour per cell.
    private static func ellipse(_ s: Shape, into canvas: inout [[Color?]], outline: Color, fill: (Int, Int, Double) -> Color) {
        func inside(_ x: Int, _ y: Int) -> Double {
            let dx = (Double(x) + 0.5 - s.cx) / s.rx, dy = (Double(y) + 0.5 - s.cy) / s.ry
            return dx * dx + dy * dy
        }
        for y in 0..<grid {
            for x in 0..<grid {
                let d = inside(x, y)
                guard d <= 1 else { continue }
                let edge = inside(x - 1, y) > 1 || inside(x + 1, y) > 1 || inside(x, y - 1) > 1 || inside(x, y + 1) > 1
                canvas[y][x] = edge ? outline : fill(x, y, d)
            }
        }
    }

    private static func flatten(_ canvas: [[Color?]]) -> [PetPixel] {
        var result: [PetPixel] = []
        for (y, row) in canvas.enumerated() {
            for (x, c) in row.enumerated() { if let c { result.append(PetPixel(x: x, y: y, color: c)) } }
        }
        return result
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Scene

/// Penny's surroundings: a mint room, or a scene bought in the shop.
struct PetScene: View {
    let item: PetItem?

    var body: some View {
        GeometryReader { geo in
            let ground = geo.size.height * 0.78
            ZStack(alignment: .top) {
                LinearGradient(colors: sky, startPoint: .top, endPoint: .bottom)
                switch item?.id {
                case "fireworks":
                    ForEach(0..<5, id: \.self) { i in
                        let colors: [Color] = [.pink, .yellow, .cyan, .orange, .green]
                        let x = geo.size.width * CGFloat([18, 42, 66, 84, 30][i]) / 100, y = ground * CGFloat([22, 12, 26, 14, 48][i]) / 100
                        ForEach(0..<8, id: \.self) { ray in
                            let angle = Double(ray) * .pi / 4
                            Rectangle().fill(colors[i]).frame(width: 3, height: 3)
                                .position(x: x + CGFloat(cos(angle)) * 9, y: y + CGFloat(sin(angle)) * 9)
                        }
                        Rectangle().fill(.white).frame(width: 3, height: 3).position(x: x, y: y)
                    }
                case "night-sky":
                    ForEach(0..<14, id: \.self) { i in
                        Rectangle().fill(.white.opacity(0.85)).frame(width: 3, height: 3)
                            .position(x: geo.size.width * CGFloat((i * 37) % 100) / 100, y: ground * CGFloat((i * 53) % 70 + 5) / 100)
                    }
                    Rectangle().fill(Color(red: 1, green: 0.95, blue: 0.75)).frame(width: 14, height: 14).position(x: geo.size.width * 0.84, y: ground * 0.22)
                case "beach":
                    Rectangle().fill(Color(red: 1, green: 0.85, blue: 0.4)).frame(width: 30, height: 30).position(x: geo.size.width * 0.82, y: ground * 0.28)
                    Rectangle().fill(Color(red: 0.4, green: 0.72, blue: 0.9).opacity(0.7)).frame(height: 8).position(x: geo.size.width / 2, y: ground - 4)
                case "sunset":
                    Rectangle().fill(Color(red: 1, green: 0.88, blue: 0.5)).frame(width: 40, height: 20).position(x: geo.size.width * 0.5, y: ground - 10)
                case "rainy-day":
                    cloud(at: CGPoint(x: geo.size.width * 0.26, y: ground * 0.2), color: .white.opacity(0.85))
                    cloud(at: CGPoint(x: geo.size.width * 0.74, y: ground * 0.12), color: .white.opacity(0.7))
                    ForEach(0..<18, id: \.self) { i in
                        Rectangle().fill(Color(red: 0.55, green: 0.72, blue: 0.92)).frame(width: 2, height: 7)
                            .position(x: geo.size.width * CGFloat((i * 31 + 5) % 100) / 100, y: ground * CGFloat((i * 47) % 60 + 32) / 100)
                    }
                    Rectangle().fill(Color(red: 0.50, green: 0.66, blue: 0.82)).frame(width: 46, height: 5).position(x: geo.size.width * 0.78, y: ground + 8)
                case "snowfall":
                    ForEach(0..<20, id: \.self) { i in
                        Rectangle().fill(.white).frame(width: i % 3 == 0 ? 4 : 3, height: i % 3 == 0 ? 4 : 3)
                            .position(x: geo.size.width * CGFloat((i * 37 + 11) % 100) / 100, y: ground * CGFloat((i * 43) % 85 + 6) / 100)
                    }
                    // A little pine tree in the snow.
                    let pine = Color(red: 0.20, green: 0.48, blue: 0.40)
                    VStack(spacing: 0) {
                        pine.frame(width: 8, height: 8); pine.frame(width: 16, height: 8); pine.frame(width: 24, height: 8)
                        Color(red: 0.45, green: 0.30, blue: 0.20).frame(width: 6, height: 6)
                    }.position(x: geo.size.width * 0.14, y: ground - 15)
                case "city-lights":
                    ForEach(0..<8, id: \.self) { i in
                        Rectangle().fill(.white.opacity(0.7)).frame(width: 2, height: 2)
                            .position(x: geo.size.width * CGFloat((i * 41 + 9) % 100) / 100, y: ground * CGFloat((i * 29) % 30 + 6) / 100)
                    }
                    Rectangle().fill(Color(red: 1, green: 0.95, blue: 0.80)).frame(width: 12, height: 12).position(x: geo.size.width * 0.16, y: ground * 0.18)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(0..<9, id: \.self) { i in
                            let height = CGFloat([34, 52, 26, 44, 60, 30, 48, 38, 56][i])
                            Rectangle().fill(Color(red: 0.16, green: 0.18, blue: 0.34)).frame(maxWidth: .infinity).frame(height: height)
                                .overlay(alignment: .top) {
                                    VStack(spacing: 5) {
                                        ForEach(0..<Int(height / 12), id: \.self) { row in
                                            HStack(spacing: 4) {
                                                ForEach(0..<2, id: \.self) { col in
                                                    Color(red: 1, green: 0.85, blue: 0.40).opacity((i + row + col) % 3 == 0 ? 0.25 : 0.9).frame(width: 3, height: 3)
                                                }
                                            }
                                        }
                                    }.padding(.top, 5)
                                }
                        }
                    }
                    .frame(width: geo.size.width).position(x: geo.size.width / 2, y: ground - 30)
                case "vault":
                    // A round vault door on the wall, and stacks of coins.
                    let steel = Color(red: 0.55, green: 0.56, blue: 0.60), coin = PetPalette.gold, coinDark = PetPalette.goldDark
                    Rectangle().fill(steel).frame(width: 44, height: 44).overlay(Rectangle().stroke(Color(red: 0.32, green: 0.33, blue: 0.38), lineWidth: 4))
                        .overlay(Rectangle().fill(Color(red: 0.36, green: 0.37, blue: 0.42)).frame(width: 14, height: 14))
                        .position(x: geo.size.width * 0.15, y: ground * 0.42)
                    ForEach(0..<4, id: \.self) { i in
                        let count = [5, 8, 3, 6][i]
                        VStack(spacing: 0) {
                            ForEach(0..<count, id: \.self) { n in (n % 2 == 0 ? coin : coinDark).frame(width: 16, height: 3) }
                        }
                        .position(x: geo.size.width * CGFloat([66, 76, 86, 94][i]) / 100, y: ground - CGFloat(count) * 1.5)
                    }
                    ForEach(0..<5, id: \.self) { i in
                        Rectangle().fill(.white.opacity(0.9)).frame(width: 3, height: 3)
                            .position(x: geo.size.width * CGFloat([62, 72, 84, 90, 80][i]) / 100, y: ground * CGFloat([70, 52, 74, 58, 40][i]) / 100)
                    }
                case "sunrise":
                    Rectangle().fill(Color(red: 1, green: 0.78, blue: 0.40)).frame(width: 44, height: 22).position(x: geo.size.width * 0.78, y: ground - 11)
                    Rectangle().fill(Color(red: 1, green: 0.88, blue: 0.55)).frame(width: 30, height: 8).position(x: geo.size.width * 0.78, y: ground - 26)
                    ForEach(0..<6, id: \.self) { i in
                        let angle = Double(i + 1) * .pi / 7
                        Rectangle().fill(Color(red: 1, green: 0.90, blue: 0.62)).frame(width: 4, height: 4)
                            .position(x: geo.size.width * 0.78 - CGFloat(cos(angle)) * 40, y: ground - 10 - CGFloat(sin(angle)) * 36)
                    }
                    cloud(at: CGPoint(x: geo.size.width * 0.18, y: ground * 0.3), color: .white.opacity(0.75))
                case "aurora":
                    ForEach(0..<12, id: \.self) { i in
                        Rectangle().fill(.white.opacity(0.8)).frame(width: 2, height: 2)
                            .position(x: geo.size.width * CGFloat((i * 37 + 3) % 100) / 100, y: ground * CGFloat((i * 53) % 75 + 5) / 100)
                    }
                    ForEach(0..<3, id: \.self) { band in
                        let colors: [Color] = [Color(red: 0.30, green: 0.95, blue: 0.65), Color(red: 0.35, green: 0.85, blue: 0.95), Color(red: 0.70, green: 0.50, blue: 0.95)]
                        ForEach(0..<24, id: \.self) { i in
                            let x = geo.size.width * CGFloat(i) / 23
                            let y = ground * (0.22 + 0.1 * CGFloat(band)) + CGFloat(sin(Double(i) * 0.55 + Double(band))) * 10
                            Rectangle().fill(colors[band].opacity(0.4)).frame(width: geo.size.width / 23 + 1, height: 7).position(x: x, y: y)
                        }
                    }
                case "confetti":
                    ForEach(0..<16, id: \.self) { i in
                        let colors: [Color] = [.pink, .orange, .yellow, .green, .blue, .purple]
                        Rectangle().fill(colors[i % colors.count].opacity(0.75)).frame(width: 5, height: 5)
                            .position(x: geo.size.width * CGFloat((i * 29 + 7) % 100) / 100, y: ground * CGFloat((i * 41) % 80 + 6) / 100)
                    }
                default:
                    // A little window in the mint room.
                    let pane = Palette.adaptive((1, 1, 1), dark: (1, 0.84, 0.48)).opacity(0.75), frame = Palette.adaptive((0.72, 0.86, 0.80), dark: (0.16, 0.30, 0.27))
                    VStack(spacing: 2) {
                        HStack(spacing: 2) { pane.frame(width: 11, height: 9); pane.frame(width: 11, height: 9) }
                        HStack(spacing: 2) { pane.frame(width: 11, height: 9); pane.frame(width: 11, height: 9) }
                    }
                    .padding(2).background(frame).position(x: geo.size.width * 0.18, y: ground * 0.32)
                }
                Rectangle().fill(floor).frame(height: geo.size.height - ground).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    /// A blocky pixel cloud.
    private func cloud(at point: CGPoint, color: Color) -> some View {
        VStack(spacing: 0) {
            color.frame(width: 18, height: 6)
            color.frame(width: 36, height: 8)
        }.position(point)
    }

    private var sky: [Color] {
        switch item?.id {
        case "rainy-day": [Color(red: 0.52, green: 0.58, blue: 0.68), Color(red: 0.70, green: 0.75, blue: 0.82)]
        case "snowfall": [Color(red: 0.70, green: 0.80, blue: 0.92), Color(red: 0.88, green: 0.92, blue: 0.97)]
        case "city-lights": [Color(red: 0.06, green: 0.08, blue: 0.22), Color(red: 0.30, green: 0.20, blue: 0.42)]
        case "vault": [Color(red: 0.36, green: 0.27, blue: 0.20), Color(red: 0.50, green: 0.38, blue: 0.26)]
        case "sunrise": [Color(red: 0.55, green: 0.75, blue: 0.95), Color(red: 1, green: 0.82, blue: 0.70), Color(red: 1, green: 0.70, blue: 0.50)]
        case "aurora": [Color(red: 0.03, green: 0.06, blue: 0.16), Color(red: 0.08, green: 0.16, blue: 0.30)]
        case "sunset": [Color(red: 0.6, green: 0.45, blue: 0.75), Color(red: 1, green: 0.6, blue: 0.55), Color(red: 1, green: 0.8, blue: 0.5)]
        case "night-sky": [Color(red: 0.08, green: 0.10, blue: 0.25), Color(red: 0.20, green: 0.22, blue: 0.42)]
        case "fireworks": [Color(red: 0.05, green: 0.04, blue: 0.18), Color(red: 0.16, green: 0.10, blue: 0.34)]
        case "beach": [Color(red: 0.55, green: 0.82, blue: 0.97), Color(red: 0.80, green: 0.93, blue: 0.99)]
        case "confetti": [Color(red: 1, green: 0.97, blue: 0.9), Color(red: 1, green: 0.99, blue: 0.95)]
        // Penny's room by day, or by night in Dark Mode.
        default: [Palette.adaptive((0.89, 0.95, 0.92), dark: (0.04, 0.09, 0.15)), Palette.adaptive((0.95, 0.98, 0.96), dark: (0.07, 0.15, 0.19))]
        }
    }

    private var floor: Color {
        switch item?.id {
        case "rainy-day": Color(red: 0.40, green: 0.48, blue: 0.52)
        case "snowfall": Color(red: 0.96, green: 0.98, blue: 1)
        case "city-lights": Color(red: 0.12, green: 0.12, blue: 0.20)
        case "vault": Color(red: 0.28, green: 0.20, blue: 0.14)
        case "sunrise": Color(red: 0.52, green: 0.72, blue: 0.40)
        case "aurora": Color(red: 0.80, green: 0.88, blue: 0.94)
        case "sunset": Color(red: 0.55, green: 0.42, blue: 0.5)
        case "night-sky": Color(red: 0.18, green: 0.30, blue: 0.28)
        case "fireworks": Color(red: 0.12, green: 0.14, blue: 0.24)
        case "beach": Color(red: 0.96, green: 0.86, blue: 0.62)
        case "confetti": Color(red: 0.98, green: 0.85, blue: 0.75)
        default: Palette.adaptive((0.72, 0.86, 0.80), dark: (0.10, 0.23, 0.20))
        }
    }
}

// MARK: - Shared pieces

struct CoinLabel: View {
    let amount: Int
    var font: Font = .subheadline.weight(.bold)

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.hexagongrid.circle.fill").symbolRenderingMode(.palette)
                .foregroundStyle(PetPalette.goldDark, PetPalette.gold)
            Text("\(amount)").monospacedDigit().foregroundStyle(amount < 0 ? AnyShapeStyle(Color.red) : AnyShapeStyle(Palette.ink))
        }
        .font(font)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(amount) coins")
    }
}

/// Penny in her scene. Tap her for a hop, some hearts and a word or two.
struct PetStage: View {
    let pet: PetProgress
    let outfit: [PetSlot: PetItem]
    let name: String
    var size: CGFloat = 96
    var corner: CGFloat = 18
    /// Penny's page: the scene fills the width and is taller, with room for her speech bubble underneath.
    var wide = false
    @State private var hop = false
    @State private var hearts: [UUID] = []
    @State private var line: String?

    var body: some View {
        ZStack {
            PetScene(item: outfit[.background])
            PetSprite(stage: pet.stage, mood: pet.mood, outfit: outfit.filter { $0.key != .background })
                .frame(width: size, height: size)
                .offset(y: (hop ? -size * 0.12 : size * 0.06) - (wide ? size * 0.16 : 0))
            ForEach(Array(hearts.enumerated()), id: \.element) { index, _ in FloatingHeart(offset: CGFloat(index % 3 - 1) * size * 0.25, size: size) }
            if let line {
                Text(line).font(.system(size: max(11, size * 0.09), weight: .semibold, design: .rounded)).foregroundStyle(PetPalette.outline)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(.white.opacity(0.92), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: wide ? .infinity : size * 1.5).frame(width: wide ? nil : size * 1.5, height: size * (wide ? 1.6 : 1.35))
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .contentShape(Rectangle())
        .onTapGesture { react() }
        .sensoryFeedback(.impact(weight: .light), trigger: hearts.count)
        .accessibilityAddTraits(.isButton).accessibilityHint("Tap to play with \(name)")
    }

    private func react() {
        let lines: [String]
        switch pet.mood {
        case .thriving: lines = ["On a roll!", "Ka-ching!", "Unstoppable!", "Payday vibes!"]
        case .happy: lines = ["Ka-ching!", "Another shift, another coin!", "You're doing great!", "Wheee!"]
        case .okay: lines = ["Got a shift for me?", "A little peckish…", "Feed me shifts!"]
        case .hungry: lines = ["So hungry…", "Book a shift?", "Tummy rumbling…"]
        case .sad: lines = ["I missed you!", "Where did you go?", "Let's work again soon"]
        case .worried: lines = ["Can we chase that pay?", "Where's our money?", "Mark it paid soon?"]
        }
        let id = UUID()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { hop = true; hearts.append(id); line = lines.randomElement() }
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { hop = false }
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut(duration: 0.3)) { hearts.removeAll { $0 == id }; if hearts.isEmpty { line = nil } }
        }
    }
}

private struct FloatingHeart: View {
    let offset: CGFloat
    let size: CGFloat
    @State private var rise = false

    var body: some View {
        Image(systemName: "heart.fill").font(.system(size: max(14, size * 0.14))).foregroundStyle(PetPalette.pink)
            .offset(x: offset, y: rise ? -size * 0.75 : -size * 0.25)
            .opacity(rise ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 1.1)) { rise = true } }
            .allowsHitTesting(false)
    }
}

// MARK: - Storage

/// Where Penny lived before she synced with the account; moved into the account on first open.
enum PetLegacyStorage {
    static let nameKey = "pet.name"
    static func closetKey(_ accountID: String) -> String { "pet.closet.\(accountID)" }
    static func closet(_ json: String?) -> PetCloset? { json.flatMap { try? JSONDecoder().decode(PetCloset.self, from: Data($0.utf8)) } }
}

extension TrackerStore {
    var petPreferences: PetPreferences { data.settings.pet ?? PetPreferences() }
    var petCloset: PetCloset { petPreferences.closet ?? PetCloset() }
    @discardableResult
    func savePet(_ change: (inout PetPreferences) -> Void) -> Bool {
        updatePreferences { settings in var pet = settings.pet ?? PetPreferences(); change(&pet); settings.pet = pet }
    }
}

func petOutfit(_ closet: PetCloset, _ pet: PetProgress) -> [PetSlot: PetItem] {
    Dictionary(uniqueKeysWithValues: PetSlot.allCases.compactMap { slot in closet.wearing(slot, pet).map { (slot, $0) } })
}

extension PetProgress.Stage: @retroactive Identifiable { public var id: Int { rawValue } }

private func nextStageLine(_ pet: PetProgress) -> String? {
    guard let toNext = pet.xpToNext, let next = pet.next else { return nil }
    return "\(toNext) XP to \(next == .hatchling ? "hatch" : "become a \(next.title.lowercased())")"
}

// MARK: - Overview card

/// Overview card: Penny in her scene, her streak and coins, and progress to the next stage.
struct PetCard: View {
    @EnvironmentObject private var store: TrackerStore
    let now: Date
    @State private var celebrate: PetProgress.Stage?
    @State private var gained = 0

    var body: some View {
        let pet = store.petProgress(now: now)
        let closet = store.petCloset
        let name = store.petPreferences.displayName
        let balance = closet.balance(pet)
        NavigationLink { PetDetailView() } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    PetScene(item: petOutfit(closet, pet)[.background])
                    PetSprite(stage: pet.stage, mood: pet.mood, outfit: petOutfit(closet, pet).filter { $0.key != .background })
                        .frame(width: 150, height: 150).frame(maxWidth: .infinity).padding(.top, 10)
                    if pet.streakWeeks > 0 {
                        Label("\(pet.streakWeeks) wk", systemImage: "flame.fill").font(.caption.weight(.bold)).foregroundStyle(.orange)
                            .padding(.horizontal, 10).padding(.vertical, 6).background(.white.opacity(0.88), in: Capsule()).padding(12)
                            .accessibilityLabel("\(pet.streakWeeks)-week streak")
                    }
                    if gained > 0 {
                        Text("+\(gained)").font(.headline.weight(.heavy)).foregroundStyle(PetPalette.goldDark)
                            .padding(.horizontal, 10).padding(.vertical, 6).background(.white, in: Capsule())
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(height: 170).clipped()
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.system(.headline, design: .rounded, weight: .bold)).foregroundStyle(Palette.ink)
                            Text(pet.stage == .egg ? "Work shifts to hatch me" : "\(pet.stage.title) · Lv \(pet.level) · \(pet.mood.label)")
                                .font(.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        CoinLabel(amount: balance)
                        Image(systemName: "chevron.right").font(.chevron).foregroundStyle(Palette.muted)
                    }
                    ProgressView(value: pet.progress).tint(PetPalette.leaf)
                    if let line = nextStageLine(pet) { Text(line).font(.caption2).foregroundStyle(Palette.muted) }
                    if pet.mood == .worried || pet.mood == .hungry || pet.mood == .sad {
                        Text(pet.message(name: name, currency: store.data.rules.currency)).font(.caption).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.line.opacity(0.7), lineWidth: 0.6).allowsHitTesting(false))
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain).accessibilityIdentifier("pet.card")
        .onAppear { check(pet, balance) }
        .onChange(of: [pet.xp, balance]) { check(pet, balance) }
        .sheet(item: $celebrate) { stage in EvolutionSheet(stage: stage, name: name, outfit: petOutfit(closet, pet)) }
    }

    /// Celebrates a new stage and shows coins gained since the last look, going by the balance you can
    /// spend (so buying something, or coins moving on another device, never shows a misleading "+N").
    private func check(_ pet: PetProgress, _ balance: Int) {
        // Until the account's records have arrived on this iPhone (a new phone, a reinstall), Penny's
        // numbers are only the empty starting state: comparing against them would celebrate old progress.
        guard store.lastSyncedData != nil else { return }
        let defaults = UserDefaults.standard
        let stageKey = "pet.seenStage.\(store.accountID)", balanceKey = "pet.seenBalance.\(store.accountID)"
        let seenStage = defaults.object(forKey: stageKey) as? Int
        let seenBalance = defaults.object(forKey: balanceKey) as? Int
        defaults.set(pet.stage.rawValue, forKey: stageKey)
        defaults.set(balance, forKey: balanceKey)
        // The first look on this iPhone (or the account's data still loading) only sets the starting point.
        guard !PetSprite.automatedTest, store.isWritable, let seenStage, let seenBalance else { return }
        if pet.stage.rawValue > seenStage { celebrate = pet.stage }
        if balance > seenBalance {
            withAnimation(.spring) { gained = balance - seenBalance }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation { gained = 0 }
            }
        }
    }
}

struct EvolutionSheet: View {
    let stage: PetProgress.Stage
    let name: String
    var outfit: [PetSlot: PetItem] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text(stage == .hatchling ? "\(name) hatched!" : "\(name) evolved!")
                .font(.system(.largeTitle, design: .rounded, weight: .heavy)).foregroundStyle(Palette.ink)
            PetSprite(stage: stage, mood: .thriving, outfit: outfit.filter { $0.key != .background }).frame(width: 200, height: 200)
            Text("\(name) is now a \(stage.title.lowercased()).").font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
            Text("Keep working shifts and getting paid to help \(name) grow. New items are now in the shop.")
                .multilineTextAlignment(.center).foregroundStyle(Palette.muted).padding(.horizontal, 32)
            Spacer()
            Button { dismiss() } label: { Text("Yay!") }.primaryButton()
                .padding(.horizontal, 24).padding(.bottom, 12)
        }
        .background { AppBackdrop() }
        .sensoryFeedback(.success, trigger: stage)
        .presentationDetents([.large])
    }
}

// MARK: - Penny's page

/// Penny's page: stats, this week's missions, the shop and wardrobe, badges and the rules.
struct PetDetailView: View {
    @EnvironmentObject private var store: TrackerStore
    @EnvironmentObject private var auth: AppleAccountStore
    @State private var redeeming = false
    @State private var giftCode = ""
    @State private var checkingCode = false
    @State private var name = ""
    @State private var slot: PetSlot = .hat
    @State private var buying: PetItem?
    @State private var notice: String?
    @State private var purchased = 0
    @FocusState private var naming: Bool

    private var displayName: String { store.petPreferences.displayName }

    var body: some View {
        let pet = store.petProgress()
        let closet = store.petCloset
        let balance = closet.balance(pet)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                stage(pet, closet)
                nameRow
                if balance < 0 { owedNote(balance) }
                statsCard(pet)
                NavigationLink { FriendsView() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2.fill").font(.title3).frame(width: 40, height: 40).foregroundStyle(.white)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Friends").font(.appHeadline).foregroundStyle(Palette.ink)
                            Text("Visit friends' pets and say hi. You both get 2 coins.").font(.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.chevron).foregroundStyle(Palette.muted)
                    }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 18)).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("pet.friends")
                missions(pet)
                shop(pet, closet)
                codes
                SectionHeading(title: "Badges", detail: "+\(PetProgress.coinsPerAchievement) coins each")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(pet.achievements) { badge($0) }
                }
                howItWorks
            }.padding(20)
        }
        .scrollIndicators(.hidden)
        .detailStyle("Your pet")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { CoinLabel(amount: balance) } }
        .onAppear { name = displayName }
        .onDisappear(perform: saveName)
        .sensoryFeedback(.success, trigger: purchased)
        .confirmationDialog(buying.map { "Buy \($0.name) for \($0.requirement)?" } ?? "", isPresented: Binding(get: { buying != nil }, set: { if !$0 { buying = nil } }), titleVisibility: .visible) {
            if let item = buying { Button("Buy \(item.name)") { buy(item, pet) } }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK", role: .cancel) {} }
        .alert("Redeem a gift code", isPresented: $redeeming) {
            TextField("PENNY-XXXX-XXXX", text: $giftCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                .accessibilityIdentifier("pet.code.field")
            Button("Redeem") { Task { await redeem() } }
            Button("Cancel", role: .cancel) { giftCode = "" }
        } message: { Text("Codes unlock special outfits, skins and scenes for \(displayName).") }
    }

    /// Gift codes: anyone can redeem one; developers can also make them.
    private var codes: some View {
        Card {
            Button { giftCode = ""; redeeming = true } label: {
                Label(checkingCode ? "Checking code…" : "Redeem a gift code", systemImage: "gift.fill")
            }.rowAction().disabled(checkingCode).accessibilityIdentifier("pet.code.redeem")
            if store.developer {
                NavigationLink { PetCodesView() } label: {
                    HStack { Label("Make gift codes", systemImage: "wand.and.stars"); Spacer(); Image(systemName: "chevron.right").font(.chevron).foregroundStyle(Palette.muted) }
                        .font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(Palette.teal).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("pet.code.make")
            }
        }
    }

    private func redeem() async {
        let code = giftCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !checkingCode else { return }
        checkingCode = true; defer { checkingCode = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["code": code])
            let result = try JSONDecoder().decode(RedeemedCode.self, from: await auth.api.request("/v1/pet/redeem", method: "POST", body: body))
            store.setPetUnlocks(result.unlocked)
            let names = result.items.compactMap { PetItem.named($0)?.name }
            notice = names.isEmpty ? "Code redeemed." : "Unlocked " + ListFormatter.localizedString(byJoining: names) + (names.count > 1 ? "! Find them in the wardrobe." : "! Find it in the wardrobe.")
            if let first = result.items.compactMap({ PetItem.named($0) }).first { slot = first.slot }
            purchased += 1; giftCode = ""
        } catch { notice = error.localizedDescription }
    }

    private func stage(_ pet: PetProgress, _ closet: PetCloset) -> some View {
        ZStack(alignment: .bottom) {
            PetStage(pet: pet, outfit: petOutfit(closet, pet), name: displayName, size: 200, corner: 24, wide: true)
            Text(pet.message(name: displayName, currency: store.data.rules.currency))
                .font(.footnote.weight(.semibold)).foregroundStyle(PetPalette.outline).multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 8).background(.white.opacity(0.92), in: Capsule())
                .padding(.horizontal, 14).padding(.bottom, 12).allowsHitTesting(false)
        }
    }

    private var nameRow: some View {
        HStack(spacing: 6) {
            // The field hugs the name, with a pencil beside it, so renaming is easy to find.
            Text(name.isEmpty ? "Penny" : name).font(.appTitle).lineLimit(1)
                .padding(.horizontal, 2).hidden()
                .overlay {
                    TextField("Penny", text: $name).font(.appTitle).multilineTextAlignment(.center)
                        .submitLabel(.done).focused($naming).accessibilityIdentifier("pet.name")
                        .onSubmit(saveName)
                        .onChange(of: naming) { _, focused in if !focused { saveName() } }
                }
            if !naming {
                Image(systemName: "pencil").font(.callout.weight(.semibold)).foregroundStyle(Palette.muted)
                    .onTapGesture { naming = true }.accessibilityLabel("Rename")
            }
        }.foregroundStyle(Palette.ink).frame(maxWidth: .infinity)
    }

    /// Shown instead of quietly showing 0 when coins were taken back after they were spent.
    private func owedNote(_ balance: Int) -> some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                Text("You're \(-balance) coins short. Some coins were taken back because shifts were deleted or marked unpaid after you'd spent them. Keep working shifts to earn them back.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
        }
    }

    private func statsCard(_ pet: PetProgress) -> some View {
        Card {
            HStack {
                Text("\(pet.stage.title) · Level \(pet.level)").font(.system(.headline, design: .rounded, weight: .bold)).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(pet.xp) XP").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted)
            }
            ProgressView(value: pet.progress).tint(PetPalette.leaf)
            if let line = nextStageLine(pet) { Text(line).font(.caption).foregroundStyle(Palette.muted) }
            HStack(spacing: 8) {
                tile("Streak", "\(pet.streakWeeks) wk", "flame.fill", .orange)
                tile("Best", "\(pet.bestStreakWeeks) wk", "trophy.fill", PetPalette.goldDark)
                tile("Days worked", "\(pet.daysWorked)", "calendar", Palette.teal)
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.callout).foregroundStyle(tint)
            Text(value).font(.system(.headline, design: .rounded, weight: .bold)).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(Palette.muted).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Palette.mint.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func missions(_ pet: PetProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "This week's missions", detail: "Coins add up automatically")
            Card {
                ForEach(pet.missions) { mission in
                    HStack(spacing: 12) {
                        Image(systemName: mission.done ? "checkmark.circle.fill" : mission.symbol)
                            .font(.body).foregroundStyle(mission.done ? PetPalette.leaf : Palette.muted).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mission.title).font(.subheadline).strikethrough(mission.done, color: Palette.muted)
                                .foregroundStyle(mission.done ? Palette.muted : Palette.ink)
                            if let detail = mission.detail { Text(detail).font(.caption).foregroundStyle(Palette.muted) }
                        }
                        Spacer()
                        CoinLabel(amount: mission.reward, font: .caption.weight(.bold))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func shop(_ pet: PetProgress, _ closet: PetCloset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Shop & wardrobe", detail: "Tap to buy or wear")
            PillPicker(values: PetSlot.allCases.map(\.title), selection: Binding(get: { slot.title }, set: { title in slot = PetSlot.allCases.first { $0.title == title } ?? .hat }))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(PetItem.catalog.filter { $0.slot == slot && (!$0.exclusive || closet.owns($0, pet)) }) { item in itemTile(item, pet, closet) }
            }
        }
    }

    private func itemTile(_ item: PetItem, _ pet: PetProgress, _ closet: PetCloset) -> some View {
        let owned = closet.owns(item, pet)
        let locked = closet.locked(item, pet)
        let wearing = closet.wearing(item.slot, pet)?.id == item.id
        var preview = petOutfit(closet, pet).filter { $0.key == .skin && item.slot != .skin }
        if item.slot != .background { preview[item.slot] = item }
        return Button { tap(item, pet, closet) } label: {
            VStack(spacing: 8) {
                ZStack {
                    PetScene(item: item.slot == .background ? item : nil)
                    PetSprite(stage: max(pet.stage, .coinling), mood: .happy, outfit: preview, animate: false)
                        .frame(width: 84, height: 84).opacity(locked ? 0.35 : 1)
                    if locked { Image(systemName: "lock.fill").font(.title2).foregroundStyle(Palette.muted) }
                }
                .frame(height: 96).clipShape(RoundedRectangle(cornerRadius: 14))
                Text(item.name).font(.caption.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.8)
                Group {
                    if wearing { Label("Wearing", systemImage: "checkmark").foregroundStyle(PetPalette.leaf) }
                    else if owned { Text("Owned · tap to wear").foregroundStyle(Palette.muted) }
                    else if locked { Text("Unlocks at \(item.stage.title)").foregroundStyle(Palette.muted) }
                    else if let price = item.price { CoinLabel(amount: price, font: .caption.weight(.bold)) }
                    else { Label(item.requirement, systemImage: "rosette").foregroundStyle(Palette.muted) }
                }.font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(10).frame(maxWidth: .infinity)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(wearing ? PetPalette.leaf : Palette.line.opacity(0.7), lineWidth: wearing ? 2 : 0.6))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityIdentifier("pet.item." + item.id)
    }

    private func tap(_ item: PetItem, _ pet: PetProgress, _ closet: PetCloset) {
        if closet.owns(item, pet) { store.savePet { var updated = $0.closet ?? PetCloset(); try? updated.toggle(item, pet); $0.closet = updated }; return }
        if closet.locked(item, pet) { notice = "\(item.name) is for sale once \(displayName) becomes a \(item.stage.title.lowercased()). \(displayName) is a \(pet.stage.title.lowercased()) now."; return }
        switch item.unlock {
        case .coins(let price):
            let balance = closet.balance(pet)
            if balance >= price { buying = item }
            else { notice = "\(item.name) costs \(price) coins. Earn \(price - balance) more by working shifts and finishing missions." }
        case .code: notice = "\(item.name) is a gift-code special. Redeem a code below to unlock it."
        case .achievement: notice = "\(item.name) comes with the \(item.requirement.replacingOccurrences(of: "Badge: ", with: "")) badge."
        case .free: break
        }
    }

    private func buy(_ item: PetItem, _ pet: PetProgress) {
        var closet = store.petCloset
        do { try closet.buy(item, pet); store.savePet { $0.closet = closet }; purchased += 1 }
        catch { notice = "Not enough coins for \(item.name)." }
        buying = nil
    }

    private func saveName() {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard trimmed != (store.petPreferences.name ?? "") else { return }
        store.savePet { $0.name = trimmed.isEmpty ? nil : trimmed }
    }

    private func badge(_ achievement: PetAchievement) -> some View {
        HStack(spacing: 10) {
            Image(systemName: achievement.symbol).font(.system(size: 18, weight: .semibold))
                .foregroundStyle(achievement.earned ? .white : Palette.muted)
                .frame(width: 38, height: 38).background(achievement.earned ? Palette.accent : Palette.mint, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(achievement.title).font(.caption.weight(.bold)).foregroundStyle(Palette.ink)
                if !achievement.earned { ProgressView(value: achievement.progress).tint(Palette.teal) }
                Text(achievement.detail).font(.caption2).foregroundStyle(Palette.muted).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.opacity(achievement.earned ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine).accessibilityLabel("\(achievement.title), \(achievement.earned ? "earned" : "not earned yet")")
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "How \(displayName) grows")
            Card {
                rule("briefcase", "+\(PetProgress.xpPerWorkedShift) XP and \(PetProgress.coinsPerWorkedShift) coins for every shift you work, +\(PetProgress.xpPerWorkedDay) XP for each day you work")
                rule("checkmark.seal", "+\(PetProgress.xpPerPaidShift) XP and \(PetProgress.coinsPerPaidShift) coins when a shift is marked paid")
                rule("list.number", "+\(PetProgress.coinsBusyWeek) coins for a week with \(PetProgress.busyWeekShifts) or more shifts")
                rule("flame", "+\(PetProgress.coinsStreakMilestone) coins for every \(PetProgress.streakMilestone) weeks in a row with a shift")
                rule("rosette", "Badges add \(PetProgress.coinsPerAchievement) coins, and some unlock special outfits")
                rule("cart", "The shop opens up as \(displayName) grows: egg, hatchling, coinling, golden coin, treasure")
                rule("heart", "Go a couple of weeks without a shift and \(displayName) gets hungry. Overdue pay makes \(displayName) worried")
            }
        }
    }

    private func rule(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Palette.teal).frame(width: 22)
            Text(text).font(.subheadline).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RedeemedCode: Decodable { let items: [String]; let unlocked: [String] }

struct PetGiftCode: Decodable, Identifiable {
    let code: String
    let items: [String]
    let label: String
    let maxUses: Int
    let uses: Int
    let expires: Int
    let disabled: Bool
    var id: String { code }
    var itemNames: String { ListFormatter.localizedString(byJoining: items.map { PetItem.named($0)?.name ?? $0 }) }
    var shareText: String { "Use the code \(code) in HowMuch (Penny → Redeem a gift code) to unlock \(itemNames)." }
}
private struct PetGiftCodes: Decodable { let codes: [PetGiftCode] }

/// Developers only: make codes that unlock wardrobe items, then share them.
struct PetCodesView: View {
    @EnvironmentObject private var auth: AppleAccountStore
    @State private var selected: Set<String> = []
    @State private var uses = 1
    @State private var days = 0
    @State private var label = ""
    @State private var custom = ""
    @State private var made: PetGiftCode?
    @State private var codes: [PetGiftCode] = []
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        AppForm {
            Section {
                Text("Choose up to 12 items. Items marked ✦ are specials that only a code can unlock.")
                    .font(.caption).foregroundStyle(Palette.muted)
            } header: { FormHeader("What the code unlocks · \(selected.count) chosen") }
            ForEach(PetSlot.allCases, id: \.self) { slot in
                Section(slot.title) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(PetItem.catalog.filter { $0.slot == slot }) { item in chip(item) }
                    }.padding(.vertical, 4)
                }
            }
            Section(styled: "Code") {
                Picker("How many people can use it", selection: $uses) { ForEach([1, 5, 10, 50, 100, 1000], id: \.self) { Text("\($0)").tag($0) } }
                Picker("Expires", selection: $days) { Text("Never").tag(0); Text("In 7 days").tag(7); Text("In 30 days").tag(30); Text("In 90 days").tag(90) }
                TextField("Note for you (optional)", text: $label)
                TextField("Custom code, e.g. LAUNCH2026 (optional)", text: $custom).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .accessibilityIdentifier("code.custom")
                Button(busy ? "Making…" : "Make code") { Task { await make() } }.primaryButton().disabled(busy || selected.isEmpty)
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).accessibilityIdentifier("code.make")
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            if let made {
                Section(styled: "New code") {
                    Text(made.code).font(.system(.title2, design: .monospaced, weight: .bold)).textSelection(.enabled).accessibilityIdentifier("code.new")
                    Text(made.itemNames).font(.caption).foregroundStyle(Palette.muted)
                    Button("Copy code", systemImage: "doc.on.doc") { UIPasteboard.general.string = made.code }.rowAction()
                    ShareLink(item: made.shareText) { Label("Share code", systemImage: "square.and.arrow.up") }
                }
            }
            Section(styled: "Your codes") {
                if codes.isEmpty { Text("No codes yet.").font(.caption).foregroundStyle(Palette.muted) }
                ForEach(codes) { code in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            // No text selection here: its press-and-drag gesture swallows the swipe that revokes a code.
                            Text(code.code).font(.system(.subheadline, design: .monospaced, weight: .semibold))
                            Spacer()
                            Text(code.disabled ? "Revoked" : "\(code.uses)/\(code.maxUses) used").font(.caption.weight(.semibold))
                                .foregroundStyle(code.disabled ? Palette.muted : Palette.teal).accessibilityIdentifier("code.status." + code.code)
                        }
                        Text([code.label, code.itemNames].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Palette.muted)
                        if code.expires > 0 { Text("Expires " + Date(timeIntervalSince1970: TimeInterval(code.expires)).formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(Palette.muted) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .accessibilityElement(children: .contain).accessibilityIdentifier("code.row." + code.code)
                    .contextMenu {
                        Button("Copy code", systemImage: "doc.on.doc") { UIPasteboard.general.string = code.code }
                        // Only revoked codes can be deleted; anyone who redeemed one keeps its items.
                        if code.disabled { Button("Delete code", systemImage: "trash", role: .destructive) { Task { await remove(code) } } }
                    }
                    // Revoking stops new redemptions; people who already redeemed keep their items.
                    .swipeActions(allowsFullSwipe: false) {
                        if !code.disabled { Button("Revoke", systemImage: "nosign", role: .destructive) { Task { await turnOff(code) } } }
                    }
                }
            }
        }
        .detailStyle("Gift codes")
        .task { await load() }
    }

    /// A compact tap-to-choose chip for one wardrobe item.
    private func chip(_ item: PetItem) -> some View {
        let chosen = selected.contains(item.id)
        return Button { if chosen { selected.remove(item.id) } else if selected.count < 12 { selected.insert(item.id) } } label: {
            HStack(spacing: 6) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle").font(.footnote)
                Text(item.name).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                if item.unlock == .code { Image(systemName: "sparkles").font(.caption2).foregroundStyle(PetPalette.goldDark) }
                Spacer(minLength: 0)
            }
            .foregroundStyle(chosen ? Color.white : Palette.ink)
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 40)
            .background(chosen ? Palette.accent : Palette.mint.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityIdentifier("code.item." + item.id)
            .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func load() async {
        do { codes = try JSONDecoder().decode(PetGiftCodes.self, from: await auth.api.request("/v1/pet/codes")).codes }
        catch { message = error.localizedDescription }
    }

    private func make() async {
        busy = true; defer { busy = false }; message = ""
        var payload: [String: Any] = ["items": PetItem.catalog.map(\.id).filter(selected.contains), "max_uses": uses, "days": days, "label": label]
        let trimmed = custom.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { payload["code"] = trimmed }
        do {
            made = try JSONDecoder().decode(PetGiftCode.self, from: await auth.api.request("/v1/pet/codes", method: "POST", body: JSONSerialization.data(withJSONObject: payload)))
            custom = ""; await load()
        } catch { message = error.localizedDescription }
    }

    private func turnOff(_ code: PetGiftCode) async {
        do {
            _ = try await auth.api.request("/v1/pet/codes/" + code.code, method: "DELETE")
            // A revoked code must not stay on the New code card, ready to copy or share.
            if made?.code == code.code { made = nil }
            await load()
        }
        catch { message = error.localizedDescription }
    }

    private func remove(_ code: PetGiftCode) async {
        do {
            _ = try await auth.api.request("/v1/pet/codes/" + code.code + "/forever", method: "DELETE")
            codes.removeAll { $0.code == code.code }
            await load()
        }
        catch { message = error.localizedDescription }
    }
}

// MARK: - Friends

/// Penny as friends see her: her look and progress only, never shifts, pay, payers or places.
struct FriendCard: Codable, Equatable {
    var petName = "Penny"
    var ownerName = ""
    var stage = 0
    var level = 1
    var mood = "okay"
    var streakWeeks = 0
    var outfit: [String: String] = [:]
    var badges: [String] = []

    var progressStage: PetProgress.Stage { PetProgress.Stage(rawValue: stage) ?? .egg }
    var progressMood: PetProgress.Mood { PetProgress.Mood(rawValue: mood) ?? .okay }
    var items: [PetSlot: PetItem] {
        Dictionary(uniqueKeysWithValues: outfit.compactMap { key, id in
            guard let slot = PetSlot(rawValue: key), let item = PetItem.named(id) else { return nil }
            return (slot, item)
        })
    }
    var owner: String { ownerName.trimmingCharacters(in: .whitespaces).isEmpty ? "A friend" : ownerName }
}

struct FriendPerson: Codable, Identifiable, Equatable {
    var code: String
    var card: FriendCard
    var saidHiToday: Bool
    var theySaidHiToday: Bool
    var id: String { code }
}

struct FriendsOverview: Codable {
    var code: String
    var link: String
    var friends: [FriendPerson]
    var incoming: [FriendPerson]
    var outgoing: [FriendPerson]
    var helloCoins: Int
}

private struct HelloResult: Decodable { let friend: FriendPerson; let helloCoins: Int }

extension TrackerStore {
    var petCard: FriendCard {
        let pet = petProgress()
        let outfit = petOutfit(petCloset, pet)
        return FriendCard(petName: petPreferences.displayName, ownerName: String(data.settings.displayName.prefix(60)),
                       stage: pet.stage.rawValue, level: pet.level, mood: pet.mood.rawValue, streakWeeks: pet.streakWeeks,
                       outfit: Dictionary(uniqueKeysWithValues: outfit.map { ($0.key.rawValue, $0.value.id) }),
                       badges: pet.achievements.filter(\.earned).map(\.id))
    }
}

extension AppleAccountStore {
    /// Sends Penny's card when it has changed since the last send, so friends see her as she is now.
    func publishPetCard() async {
        guard let store = tracker, let id = account?.id else { return }
        let card = store.petCard
        let key = "petCard.\(id)"
        guard let body = try? JSONEncoder().encode(["card": card]),
              UserDefaults.standard.data(forKey: key) != body else { return }
        if (try? await api.request("/v1/friends/card", method: "PUT", body: body)) != nil {
            UserDefaults.standard.set(body, forKey: key)
        }
    }
}

/// Draws Penny for the Home Screen widget when she changes (stage, mood, outfit, streak).
private var lastPennyWidget: (info: PennyWidgetInfo, outfit: [String])?
extension TrackerStore {
    func publishPennyWidget() {
        let pet = petProgress()
        let outfit = petOutfit(petCloset, pet)
        let info = PennyWidgetInfo(accountID: accountID.lowercased(), name: petPreferences.displayName, stage: pet.stage.title,
                                   level: pet.level, mood: pet.mood.label, streakWeeks: pet.streakWeeks, hatched: pet.stage != .egg)
        let worn = outfit.map { $0.key.rawValue + "=" + $0.value.id }.sorted()
        guard lastPennyWidget?.info != info || lastPennyWidget?.outfit != worn || PennyWidgetFile.imageURL(dark: false) == nil else { return }
        func draw(_ scheme: ColorScheme) -> Data? {
            let room = ZStack {
                PetScene(item: outfit[.background])
                PetSprite(stage: pet.stage, mood: pet.mood, outfit: outfit.filter { $0.key != .background }, animate: false)
                    .frame(width: 112, height: 112).offset(y: -34)  // above the widget's name bar
            }.frame(width: 180, height: 180).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: room)
            renderer.scale = 3
            return renderer.uiImage?.pngData()
        }
        guard let light = draw(.light), let dark = draw(.dark) else { return }
        do { try PennyWidgetFile.write(info, light: light, dark: dark); lastPennyWidget = (info, worn) } catch {}
    }
}

/// You and your friends' pets ranked by streak, then level. Pets only: no shifts or pay.
struct FriendBoardEntry: Identifiable, Equatable {
    var id: String
    var card: FriendCard
    var isYou: Bool
    var rank: Int

    static func ranked(you: FriendCard, friends: [FriendPerson]) -> [FriendBoardEntry] {
        let all = [FriendBoardEntry(id: "you", card: you, isYou: true, rank: 0)]
            + friends.map { FriendBoardEntry(id: $0.code, card: $0.card, isYou: false, rank: 0) }
        // Ties stay in a steady order (you first, then by name) and share a rank.
        let sorted = all.enumerated().sorted { a, b in
            let (x, y) = (a.element.card, b.element.card)
            if x.streakWeeks != y.streakWeeks { return x.streakWeeks > y.streakWeeks }
            if x.level != y.level { return x.level > y.level }
            if a.element.isYou != b.element.isYou { return a.element.isYou }
            return x.petName.localizedCaseInsensitiveCompare(y.petName) == .orderedAscending
        }.map(\.element)
        var result: [FriendBoardEntry] = []
        for (index, var entry) in sorted.enumerated() {
            if let previous = result.last, previous.card.streakWeeks == entry.card.streakWeeks, previous.card.level == entry.card.level {
                entry.rank = previous.rank
            } else { entry.rank = index + 1 }
            result.append(entry)
        }
        return result
    }
}

private struct FriendBoardRow: View {
    let entry: FriendBoardEntry
    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch entry.rank {
                case 1: Text("🥇"); case 2: Text("🥈"); case 3: Text("🥉")
                default: Text("\(entry.rank)").font(.subheadline.weight(.bold)).foregroundStyle(Palette.muted)
                }
            }.frame(width: 28)
            FriendPennyThumb(card: entry.card, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.isYou ? "\(entry.card.petName) (you)" : entry.card.petName).font(.subheadline.weight(.semibold))
                Text(entry.isYou ? "Lv \(entry.card.level)" : "\(entry.card.owner)'s pet · Lv \(entry.card.level)").font(.caption).foregroundStyle(Palette.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(entry.card.streakWeeks) wk").font(.subheadline.weight(.bold)).foregroundStyle(entry.card.streakWeeks > 0 ? .orange : Palette.muted)
                Text("streak").font(.caption2).foregroundStyle(Palette.muted)
            }
        }
        .listRowBackground(entry.isYou ? Palette.mint : nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Number \(entry.rank): \(entry.isYou ? "your pet " : "\(entry.card.owner)'s pet ")\(entry.card.petName), level \(entry.card.level), \(entry.card.streakWeeks) week streak")
        .accessibilityIdentifier(entry.isYou ? "friends.board.you" : "friends.board." + entry.id)
    }
}

/// A friend's Penny, small, for lists.
private struct FriendPennyThumb: View {
    let card: FriendCard
    var size: CGFloat = 52
    var body: some View {
        ZStack {
            PetScene(item: card.items[.background])
            PetSprite(stage: card.progressStage, mood: card.progressMood, outfit: card.items.filter { $0.key != .background }, animate: false)
                .frame(width: size * 0.8, height: size * 0.8)
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }
}

/// Penny's friends: your code to share, requests, and friends to visit.
struct FriendsView: View {
    @EnvironmentObject private var auth: AppleAccountStore
    @EnvironmentObject private var store: TrackerStore
    var invite: String?
    @State private var overview: FriendsOverview?
    @State private var code = ""
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        AppForm {
            if let friends = overview?.friends, !friends.isEmpty {
                Section {
                    ForEach(FriendBoardEntry.ranked(you: store.petCard, friends: friends)) { FriendBoardRow(entry: $0) }
                    Text("Ranked by weekly streak, then level. Work a shift each week to keep yours going.").formFootnote()
                } header: { FormHeader("Leaderboard") }
            }
            Section {
                Text(overview?.code ?? "Loading…").font(.system(.title2, design: .monospaced, weight: .bold)).textSelection(.enabled)
                    .accessibilityIdentifier("friends.myCode")
                if let overview, let link = URL(string: overview.link) {
                    ShareLink(item: link, message: Text("Be my friend on HowMuch! Visit my pet \(store.petPreferences.displayName) and say hi. My friend code is \(overview.code).")) {
                        Label("Invite a friend", systemImage: "square.and.arrow.up")
                    }.accessibilityIdentifier("friends.invite")
                }
                Text("Friends can visit \(store.petPreferences.displayName) and say hi. They never see your shifts or pay.").formFootnote()
            } header: { FormHeader("Your friend code") }

            Section(styled: "Add a friend") {
                TextField("PENNY-XXXXXX", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced)).accessibilityIdentifier("friends.codeField")
                Button(busy ? "Adding…" : "Add friend", systemImage: "person.badge.plus") { Task { await add(code) } }
                    .disabled(busy || code.trimmingCharacters(in: .whitespaces).count < 4).accessibilityIdentifier("friends.add")
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Palette.warning).accessibilityIdentifier("friends.message") }
            }

            if let incoming = overview?.incoming, !incoming.isEmpty {
                Section(styled: "Friend requests") {
                    ForEach(incoming) { person in
                        HStack(spacing: 12) {
                            FriendPennyThumb(card: person.card, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.card.owner).font(.subheadline.weight(.semibold))
                                Text("\(person.card.petName) · Lv \(person.card.level)").font(.caption).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Button { Task { await add(person.code) } } label: { Text("Accept").foregroundStyle(.white) }.buttonStyle(.borderedProminent).tint(Palette.accent)
                                .accessibilityIdentifier("friends.accept." + person.code)
                            Button("Decline", systemImage: "xmark") { Task { await remove(person.code) } }.labelStyle(.iconOnly).buttonStyle(.bordered)
                        }
                    }
                }
            }

            Section(styled: "Friends") {
                if let friends = overview?.friends, !friends.isEmpty {
                    ForEach(friends) { friend in
                        NavigationLink { FriendPetView(friend: friend, onChange: { overview = $0 ?? overview; Task { await load() } }) } label: {
                            HStack(spacing: 12) {
                                FriendPennyThumb(card: friend.card)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(friend.card.petName).font(.subheadline.weight(.semibold))
                                    Text("\(friend.card.owner)'s pet · Lv \(friend.card.level)").font(.caption).foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                if friend.theySaidHiToday { Text("👋").accessibilityLabel("Said hi to you today") }
                                if friend.saidHiToday { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.teal).accessibilityLabel("You said hi today") }
                            }
                        }.accessibilityIdentifier("friends.friend." + friend.code)
                    }
                } else {
                    Text(overview == nil ? "Loading…" : "No friends yet. Share your code to add one.").font(.subheadline).foregroundStyle(Palette.muted)
                }
            }

            if let outgoing = overview?.outgoing, !outgoing.isEmpty {
                Section(styled: "Waiting for them to accept") {
                    ForEach(outgoing) { person in
                        HStack {
                            Text(person.card.ownerName.isEmpty ? person.code : person.card.ownerName).font(.subheadline)
                            Spacer()
                            Button("Cancel") { Task { await remove(person.code) } }.font(.subheadline)
                        }
                    }
                }
            }

            Section(styled: "How it works") {
                Text("Say hi to each friend once a day. You both get \(2) coins, and they get a notification. Remove a friend any time from their page.")
                    .formFootnote()
            }
        }
        .detailStyle("Friends")
        .task {
            if let invite { code = invite }
            await auth.publishPetCard()
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let result = try JSONDecoder().decode(FriendsOverview.self, from: await auth.api.request("/v1/friends"))
            overview = result; store.setHelloCoins(result.helloCoins)
        } catch { message = error.localizedDescription }
    }

    private func add(_ value: String) async {
        busy = true; defer { busy = false }; message = ""
        do {
            let before = overview?.friends.count ?? 0
            let body = try JSONSerialization.data(withJSONObject: ["code": value.trimmingCharacters(in: .whitespacesAndNewlines)])
            let result = try JSONDecoder().decode(FriendsOverview.self, from: await auth.api.request("/v1/friends", method: "POST", body: body))
            overview = result; code = ""
            message = result.friends.count > before ? "You're now friends! 🎉" : "Request sent. You'll be friends once they accept."
        } catch { message = error.localizedDescription }
    }

    private func remove(_ value: String) async {
        do { overview = try JSONDecoder().decode(FriendsOverview.self, from: await auth.api.request("/v1/friends/" + value, method: "DELETE")) }
        catch { message = error.localizedDescription }
    }
}

/// Visiting a friend's Penny.
struct FriendPetView: View {
    @EnvironmentObject private var auth: AppleAccountStore
    @EnvironmentObject private var store: TrackerStore
    @Environment(\.dismiss) private var dismiss
    @State var friend: FriendPerson
    var onChange: (FriendsOverview?) -> Void
    @State private var waving = false
    @State private var message = ""
    @State private var confirmingRemove = false
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ZStack {
                    PetScene(item: friend.card.items[.background])
                    PetSprite(stage: friend.card.progressStage, mood: friend.card.progressMood, outfit: friend.card.items.filter { $0.key != .background })
                        .frame(width: 180, height: 180)
                        .offset(y: waving ? -16 : 8)
                        .animation(.spring(response: 0.3, dampingFraction: 0.45), value: waving)
                    if waving {
                        Text("👋").font(.system(size: 44)).offset(x: 80, y: -60).transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 24))

                VStack(spacing: 4) {
                    Text(friend.card.petName).font(.title2.weight(.bold)).foregroundStyle(Palette.ink)
                    Text("\(friend.card.owner)'s pet").font(.subheadline).foregroundStyle(Palette.muted)
                }
                HStack(spacing: 10) {
                    stat("Level", "\(friend.card.level)")
                    stat("Stage", friend.card.progressStage.title)
                    stat("Streak", friend.card.streakWeeks == 0 ? "—" : "\(friend.card.streakWeeks) wk")
                }
                Text("Feeling \(friend.card.progressMood.label.lowercased()) · \(friend.card.badges.count) badge\(friend.card.badges.count == 1 ? "" : "s")")
                    .font(.subheadline).foregroundStyle(Palette.muted)
                if friend.theySaidHiToday {
                    Label("\(friend.card.owner) said hi to you today", systemImage: "hand.wave.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.teal)
                }
                Button(friend.saidHiToday ? "You said hi today" : "👋 Say hi", systemImage: friend.saidHiToday ? "checkmark.circle" : "") {
                    Task { await sayHi() }
                }
                .primaryButton().disabled(friend.saidHiToday || busy).accessibilityIdentifier("friend.hello")
                Text(message.isEmpty ? "Once a day. You both get 2 coins." : message).font(.caption).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center).accessibilityIdentifier("friend.helloMessage")
                Button("Remove friend", role: .destructive) { confirmingRemove = true }.font(.subheadline).foregroundStyle(.red).padding(.top, 20).disabled(busy)
            }.padding(20)
        }
        .detailStyle(friend.card.petName)
        .sensoryFeedback(.success, trigger: waving)
        .confirmationDialog("Remove \(friend.card.owner) as a friend?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove() } }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).foregroundStyle(Palette.ink)
            Text(title).font(.caption).foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity).padding(.vertical, 10).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func sayHi() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let result = try JSONDecoder().decode(HelloResult.self, from: await auth.api.request("/v1/friends/\(friend.code)/hello", method: "POST"))
            friend = result.friend
            store.setHelloCoins(result.helloCoins)
            withAnimation { waving = true }
            message = "\(friend.card.petName) waved back! You and \(friend.card.owner) each got 2 coins."
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation { waving = false }
            onChange(nil)
        } catch { message = error.localizedDescription }
    }

    private func remove() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let result = try JSONDecoder().decode(FriendsOverview.self, from: await auth.api.request("/v1/friends/" + friend.code, method: "DELETE"))
            onChange(result)
            dismiss()
        } catch {
            message = "Couldn't remove this friend. \(error.localizedDescription) Try again."
        }
    }
}
