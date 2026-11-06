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
        case "rainbow":
            light = .white; deep = rgb(0.62, 0.48, 0.90); outline = rgb(0.30, 0.22, 0.45); rainbow = true
        default: break
        }
    }

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
            if skin.rainbow {
                let row = Int((Double(y) - (cy - s.ry)) / (2 * s.ry) * Double(PetSkin.rainbowRows.count))
                return PetSkin.rainbowRows[min(max(row, 0), PetSkin.rainbowRows.count - 1)]
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
            case "star-glasses": stamp([".p...p.", "ppp.ppp", ".p...p."], x: lx - 1, y: eyeY - 1, p)
            case "scarf":
                for x in (cx - Int(s.rx) + 1)...(cx + Int(s.rx) - 1) where neckY + 1 < grid && canvas[neckY][x] != nil {
                    put(x, neckY, PetPalette.red); put(x, neckY + 1, PetPalette.redDark)
                }
                stamp(["rR", "rR", "R."], x: cx + 2, y: neckY + 1, p)
            case "bow-tie": stamp(["ro.or", "rrorr", "ro.or"], x: cx - 2, y: neckY, p)
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
                case "confetti":
                    ForEach(0..<16, id: \.self) { i in
                        let colors: [Color] = [.pink, .orange, .yellow, .green, .blue, .purple]
                        Rectangle().fill(colors[i % colors.count].opacity(0.75)).frame(width: 5, height: 5)
                            .position(x: geo.size.width * CGFloat((i * 29 + 7) % 100) / 100, y: ground * CGFloat((i * 41) % 80 + 6) / 100)
                    }
                default:
                    // A little window in the mint room.
                    let pane = Color.white.opacity(0.75), frame = Color(red: 0.72, green: 0.86, blue: 0.80)
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

    private var sky: [Color] {
        switch item?.id {
        case "sunset": [Color(red: 0.6, green: 0.45, blue: 0.75), Color(red: 1, green: 0.6, blue: 0.55), Color(red: 1, green: 0.8, blue: 0.5)]
        case "night-sky": [Color(red: 0.08, green: 0.10, blue: 0.25), Color(red: 0.20, green: 0.22, blue: 0.42)]
        case "beach": [Color(red: 0.55, green: 0.82, blue: 0.97), Color(red: 0.80, green: 0.93, blue: 0.99)]
        case "confetti": [Color(red: 1, green: 0.97, blue: 0.9), Color(red: 1, green: 0.99, blue: 0.95)]
        default: [Palette.mint, Color(red: 0.95, green: 0.98, blue: 0.96)]
        }
    }

    private var floor: Color {
        switch item?.id {
        case "sunset": Color(red: 0.55, green: 0.42, blue: 0.5)
        case "night-sky": Color(red: 0.18, green: 0.30, blue: 0.28)
        case "beach": Color(red: 0.96, green: 0.86, blue: 0.62)
        case "confetti": Color(red: 0.98, green: 0.85, blue: 0.75)
        default: Color(red: 0.72, green: 0.86, blue: 0.80)
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
            .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 22))
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
                missions(pet)
                shop(pet, closet)
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
                            .font(.title3).foregroundStyle(mission.done ? PetPalette.leaf : Palette.muted).frame(width: 30)
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
                ForEach(PetItem.catalog.filter { $0.slot == slot && (!$0.pioneerOnly || closet.owns($0, pet)) }) { item in itemTile(item, pet, closet) }
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
            .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
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
                .frame(width: 38, height: 38).background(achievement.earned ? Palette.teal : Palette.mint, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(achievement.title).font(.caption.weight(.bold)).foregroundStyle(Palette.ink)
                if !achievement.earned { ProgressView(value: achievement.progress).tint(Palette.teal) }
                Text(achievement.detail).font(.caption2).foregroundStyle(Palette.muted).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(achievement.earned ? 0.95 : 0.6), in: RoundedRectangle(cornerRadius: 14))
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
