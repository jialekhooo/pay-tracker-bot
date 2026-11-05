import SwiftUI
import HowMuchCore

private let gold = Color(red: 0.97, green: 0.78, blue: 0.29)
private let goldDeep = Color(red: 0.84, green: 0.6, blue: 0.13)
private let goldLight = Color(red: 1.0, green: 0.9, blue: 0.55)
private let jade = Color(red: 0.2, green: 0.6, blue: 0.47)
private let shell = Color(red: 0.86, green: 0.95, blue: 0.9)

/// The HowMuch pet: an egg that hatches into a little coin, grows a sprout, then turns golden.
struct PetFigure: View {
    let stage: PetProgress.Stage
    let mood: PetProgress.Mood
    var size: CGFloat = 96
    /// What Penny is wearing, by slot (backgrounds are drawn by `PetStage`).
    var outfit: [PetSlot: PetItem] = [:]
    @State private var bob = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch stage {
            case .egg: egg
            case .hatchling: hatchling
            case .coinling: coinling
            case .golden: goldenCoin
            }
            accessories
        }
        .frame(width: size, height: size)
        .offset(y: bob ? -size * 0.03 : size * 0.02)
        .onAppear {
            guard !reduceMotion, !Self.automatedTest else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { bob = true }
        }
        .accessibilityElement().accessibilityLabel("\(stage.title), \(mood.rawValue)")
    }

    /// UI tests wait for the app to be idle, which a never-ending animation prevents.
    private static var automatedTest: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--ui-test-account")
        #else
        return false
        #endif
    }

    private var egg: some View {
        ZStack {
            Ellipse().fill(LinearGradient(colors: [.white, shell], startPoint: .top, endPoint: .bottom))
                .overlay(Ellipse().stroke(jade.opacity(0.5), lineWidth: size * 0.025))
                .frame(width: size * 0.68, height: size * 0.86)
            ForEach(Array([(-0.14, -0.2), (0.15, 0.02), (-0.08, 0.24)].enumerated()), id: \.offset) { _, spot in
                Circle().fill(gold).overlay(Circle().stroke(goldDeep, lineWidth: size * 0.012))
                    .frame(width: size * 0.12).offset(x: size * spot.0, y: size * spot.1)
            }
            face(scale: 0.8).offset(y: size * 0.04)
            if mood == .sleepy { zzz }
        }
    }

    private var hatchling: some View {
        ZStack {
            coin(scale: 0.62).offset(y: -size * 0.08)
            ShellCup().fill(shell).overlay(ShellCup().stroke(jade.opacity(0.5), lineWidth: size * 0.025))
                .frame(width: size * 0.74, height: size * 0.36).offset(y: size * 0.27)
        }
    }

    private var coinling: some View {
        ZStack {
            HStack(spacing: size * 0.16) {
                Capsule().fill(goldDeep).frame(width: size * 0.12, height: size * 0.08)
                Capsule().fill(goldDeep).frame(width: size * 0.12, height: size * 0.08)
            }.offset(y: size * 0.4)
            if outfit[.hat] == nil { sprout.offset(y: -size * 0.43) }
            coin(scale: 0.78)
        }
    }

    private var goldenCoin: some View {
        ZStack {
            Circle().fill(goldLight.opacity(0.35)).frame(width: size).blur(radius: size * 0.06)
            coin(scale: 0.8, shine: true)
            if outfit[.hat] == nil {
                Crown().fill(LinearGradient(colors: [goldLight, gold], startPoint: .top, endPoint: .bottom))
                    .overlay(Crown().stroke(goldDeep, lineWidth: size * 0.015))
                    .frame(width: size * 0.34, height: size * 0.18).offset(y: -size * 0.46)
            }
            Image(systemName: "sparkle").font(.system(size: size * 0.14)).foregroundStyle(goldLight).offset(x: size * 0.42, y: -size * 0.3)
            Image(systemName: "sparkle").font(.system(size: size * 0.09)).foregroundStyle(gold).offset(x: -size * 0.44, y: size * 0.18)
        }
    }

    private func coin(scale: CGFloat, shine: Bool = false) -> some View {
        ZStack {
            Circle().fill(LinearGradient(colors: shine ? [goldLight, gold] : [gold, goldDeep.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().stroke(goldDeep, lineWidth: size * 0.03)
            Circle().inset(by: size * scale * 0.1).stroke(goldLight.opacity(0.8), lineWidth: size * 0.015)
            Capsule().fill(.white.opacity(0.45)).frame(width: size * scale * 0.08, height: size * scale * 0.24)
                .rotationEffect(.degrees(35)).offset(x: -size * scale * 0.28, y: -size * scale * 0.2)
            face(scale: scale)
        }.frame(width: size * scale, height: size * scale)
    }

    private func face(scale: CGFloat) -> some View {
        let unit = size * scale
        return ZStack {
            HStack(spacing: unit * 0.2) { eye(unit); eye(unit) }.offset(y: -unit * 0.02)
            HStack(spacing: unit * 0.42) {
                Circle().fill(Color.pink.opacity(0.35)).frame(width: unit * 0.1)
                Circle().fill(Color.pink.opacity(0.35)).frame(width: unit * 0.1)
            }.offset(y: unit * 0.1)
            Mouth(smile: mood == .happy ? 1 : mood == .worried ? -0.6 : 0.2)
                .stroke(Palette.ink, style: StrokeStyle(lineWidth: unit * 0.035, lineCap: .round))
                .frame(width: unit * 0.16, height: unit * 0.07).offset(y: unit * 0.14)
            if mood == .worried {
                Image(systemName: "drop.fill").font(.system(size: unit * 0.12)).foregroundStyle(Color(red: 0.45, green: 0.7, blue: 0.95))
                    .offset(x: unit * 0.3, y: -unit * 0.16)
            }
        }
    }

    @ViewBuilder private func eye(_ unit: CGFloat) -> some View {
        switch mood {
        case .happy: Mouth(smile: -1).stroke(Palette.ink, style: StrokeStyle(lineWidth: unit * 0.04, lineCap: .round)).frame(width: unit * 0.13, height: unit * 0.07)
        case .sleepy: Capsule().fill(Palette.ink).frame(width: unit * 0.13, height: unit * 0.035)
        case .worried: Circle().fill(Palette.ink).frame(width: unit * 0.09)
        }
    }

    private var sprout: some View {
        ZStack {
            Capsule().fill(jade).frame(width: size * 0.03, height: size * 0.12).offset(y: size * 0.04)
            Ellipse().fill(jade).frame(width: size * 0.15, height: size * 0.08).rotationEffect(.degrees(-30)).offset(x: -size * 0.07)
            Ellipse().fill(jade.opacity(0.8)).frame(width: size * 0.15, height: size * 0.08).rotationEffect(.degrees(30)).offset(x: size * 0.07)
        }
    }

    /// Where things sit on each stage, as fractions of `size`: top of the head, eye line, head width, neck.
    private var anchors: (top: CGFloat, eyes: CGFloat, width: CGFloat, neck: CGFloat) {
        switch stage {
        case .egg: return (-0.43, 0.02, 0.62, 0.3)
        case .hatchling: return (-0.39, -0.09, 0.62, 0.17)
        case .coinling: return (-0.39, -0.016, 0.78, 0.36)
        case .golden: return (-0.4, -0.016, 0.8, 0.37)
        }
    }

    @ViewBuilder private var accessories: some View {
        let a = anchors, w = size * a.width
        if let neck = outfit[.neck] { PetAccessory(item: neck, width: w).offset(y: size * a.neck) }
        if let face = outfit[.face] { PetAccessory(item: face, width: w).offset(y: size * a.eyes) }
        // Hats are drawn bottom-aligned in a frame 0.6w tall, sitting slightly down over the head.
        if let hat = outfit[.hat] { PetAccessory(item: hat, width: w).offset(y: size * a.top - w * 0.3 + w * 0.1) }
    }

    private var zzz: some View {
        Text("z z").font(.system(size: size * 0.13, weight: .bold, design: .rounded)).foregroundStyle(jade.opacity(0.7))
            .offset(x: size * 0.36, y: -size * 0.36)
    }
}

/// A curve: `smile` 1 is a smile, -1 a frown (also used upside down for happy closed eyes).
private struct Mouth: Shape {
    var smile: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y = smile >= 0 ? rect.minY : rect.maxY
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: y), control: CGPoint(x: rect.midX, y: y + rect.height * 2 * smile))
        return path
    }
}

/// The bottom half of a cracked eggshell.
private struct ShellCup: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let teeth = 6
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2))
        for i in 1...teeth {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(teeth)
            path.addLine(to: CGPoint(x: x - rect.width / CGFloat(teeth * 2), y: i % 2 == 0 ? rect.minY + rect.height * 0.2 : rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.minY + rect.height * 0.2))
        }
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2), control: CGPoint(x: rect.midX, y: rect.maxY * 1.5))
        return path
    }
}

private struct Crown: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.3))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.6))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.minY + rect.height * 0.6))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.3))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A hat, pair of glasses or neckwear, drawn to fit a head `width` wide.
struct PetAccessory: View {
    let item: PetItem
    let width: CGFloat
    private var w: CGFloat { width }
    private let ink = Color(red: 0.1, green: 0.16, blue: 0.15)

    var body: some View {
        switch item.slot {
        case .hat: hat.frame(width: w, height: w * 0.6, alignment: .bottom)
        case .face: glasses.frame(width: w, height: w * 0.3)
        case .neck: neckwear.frame(width: w, height: w * 0.3)
        case .background: EmptyView()
        }
    }

    @ViewBuilder private var hat: some View {
        switch item.id {
        case "party-hat":
            VStack(spacing: -w * 0.03) {
                Circle().fill(Color.yellow).frame(width: w * 0.11)
                Triangle().fill(LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.6), Color(red: 0.6, green: 0.4, blue: 0.95)], startPoint: .top, endPoint: .bottom))
                    .overlay(Triangle().stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: w * 0.02, dash: [w * 0.05])))
                    .frame(width: w * 0.36, height: w * 0.42)
            }.rotationEffect(.degrees(-8))
        case "beanie":
            VStack(spacing: -w * 0.04) {
                Circle().fill(.white).frame(width: w * 0.13)
                ZStack(alignment: .bottom) {
                    UnevenRoundedRectangle(topLeadingRadius: w * 0.36, topTrailingRadius: w * 0.36).fill(Color(red: 0.16, green: 0.55, blue: 0.62)).frame(width: w * 0.72, height: w * 0.34)
                    Capsule().fill(Color(red: 0.1, green: 0.42, blue: 0.48)).frame(width: w * 0.78, height: w * 0.11)
                }
            }
        case "cap":
            ZStack(alignment: .bottom) {
                UnevenRoundedRectangle(topLeadingRadius: w * 0.3, topTrailingRadius: w * 0.3).fill(jade).frame(width: w * 0.62, height: w * 0.27)
                Circle().fill(jade.opacity(0.7)).frame(width: w * 0.07).offset(y: -w * 0.24)
                Capsule().fill(Color(red: 0.12, green: 0.45, blue: 0.35)).frame(width: w * 0.48, height: w * 0.08).offset(x: w * 0.3, y: w * 0.02)
            }
        case "chef-hat":
            VStack(spacing: -w * 0.06) {
                HStack(spacing: -w * 0.1) { puff(0.24); puff(0.3); puff(0.24) }
                RoundedRectangle(cornerRadius: w * 0.03).fill(.white).overlay(RoundedRectangle(cornerRadius: w * 0.03).stroke(.gray.opacity(0.35), lineWidth: w * 0.015))
                    .frame(width: w * 0.5, height: w * 0.14)
            }
        case "wizard-hat":
            ZStack(alignment: .bottom) {
                Triangle().fill(Color(red: 0.36, green: 0.27, blue: 0.7)).frame(width: w * 0.44, height: w * 0.52).offset(y: -w * 0.05).rotationEffect(.degrees(6))
                Ellipse().fill(Color(red: 0.3, green: 0.22, blue: 0.6)).frame(width: w * 0.86, height: w * 0.13)
                Image(systemName: "star.fill").font(.system(size: w * 0.1)).foregroundStyle(.yellow).offset(x: -w * 0.02, y: -w * 0.24)
                Image(systemName: "moon.fill").font(.system(size: w * 0.08)).foregroundStyle(.yellow.opacity(0.9)).offset(x: w * 0.06, y: -w * 0.36)
            }
        case "flower":
            ZStack {
                ForEach(0..<5, id: \.self) { i in
                    Ellipse().fill(Color(red: 1, green: 0.55, blue: 0.7)).frame(width: w * 0.12, height: w * 0.2)
                        .offset(y: -w * 0.08).rotationEffect(.degrees(Double(i) * 72))
                }
                Circle().fill(Color.yellow).frame(width: w * 0.1)
            }.offset(x: w * 0.26, y: w * 0.02)
        case "royal-crown":
            ZStack(alignment: .bottom) {
                Crown().fill(LinearGradient(colors: [goldLight, gold], startPoint: .top, endPoint: .bottom))
                    .overlay(Crown().stroke(goldDeep, lineWidth: w * 0.02)).frame(width: w * 0.56, height: w * 0.32)
                HStack(spacing: w * 0.08) {
                    Circle().fill(.red).frame(width: w * 0.07); Circle().fill(.blue).frame(width: w * 0.08); Circle().fill(.green).frame(width: w * 0.07)
                }.offset(y: -w * 0.06)
            }
        default: EmptyView()
        }
    }

    private func puff(_ scale: CGFloat) -> some View {
        Circle().fill(.white).overlay(Circle().stroke(.gray.opacity(0.25), lineWidth: w * 0.012)).frame(width: w * scale)
    }

    @ViewBuilder private var glasses: some View {
        switch item.id {
        case "round-glasses":
            HStack(spacing: w * 0.06) {
                Circle().stroke(ink, lineWidth: w * 0.03).frame(width: w * 0.22)
                Circle().stroke(ink, lineWidth: w * 0.03).frame(width: w * 0.22)
            }.overlay(Capsule().fill(ink).frame(width: w * 0.08, height: w * 0.025))
        case "sunglasses":
            HStack(spacing: w * 0.05) {
                lens; lens
            }.overlay(Capsule().fill(ink).frame(width: w * 0.08, height: w * 0.03))
        case "star-glasses":
            HStack(spacing: w * 0.0) {
                Image(systemName: "star.fill").font(.system(size: w * 0.3)).foregroundStyle(Color(red: 1, green: 0.4, blue: 0.65))
                Image(systemName: "star.fill").font(.system(size: w * 0.3)).foregroundStyle(Color(red: 1, green: 0.4, blue: 0.65))
            }
        default: EmptyView()
        }
    }

    private var lens: some View {
        RoundedRectangle(cornerRadius: w * 0.07).fill(ink).frame(width: w * 0.27, height: w * 0.17)
            .overlay(Capsule().fill(.white.opacity(0.35)).frame(width: w * 0.04, height: w * 0.1).rotationEffect(.degrees(30)).offset(x: -w * 0.06))
    }

    @ViewBuilder private var neckwear: some View {
        switch item.id {
        case "bow-tie":
            HStack(spacing: -w * 0.02) {
                Triangle().fill(Color(red: 0.86, green: 0.2, blue: 0.27)).frame(width: w * 0.16, height: w * 0.18).rotationEffect(.degrees(90))
                Circle().fill(Color(red: 0.66, green: 0.12, blue: 0.2)).frame(width: w * 0.08)
                Triangle().fill(Color(red: 0.86, green: 0.2, blue: 0.27)).frame(width: w * 0.16, height: w * 0.18).rotationEffect(.degrees(-90))
            }
        case "scarf":
            ZStack {
                Capsule().fill(Color(red: 0.88, green: 0.3, blue: 0.25)).frame(width: w * 0.66, height: w * 0.13)
                RoundedRectangle(cornerRadius: w * 0.03).fill(Color(red: 0.78, green: 0.24, blue: 0.2)).frame(width: w * 0.12, height: w * 0.24)
                    .rotationEffect(.degrees(12)).offset(x: w * 0.16, y: w * 0.12)
            }
        case "medal":
            ZStack {
                Capsule().fill(Color(red: 0.25, green: 0.45, blue: 0.85)).frame(width: w * 0.07, height: w * 0.24).rotationEffect(.degrees(25)).offset(x: -w * 0.05, y: -w * 0.04)
                Capsule().fill(Color(red: 0.25, green: 0.45, blue: 0.85)).frame(width: w * 0.07, height: w * 0.24).rotationEffect(.degrees(-25)).offset(x: w * 0.05, y: -w * 0.04)
                Circle().fill(LinearGradient(colors: [goldLight, goldDeep], startPoint: .top, endPoint: .bottom)).frame(width: w * 0.16).offset(y: w * 0.1)
                Image(systemName: "star.fill").font(.system(size: w * 0.07)).foregroundStyle(.white).offset(y: w * 0.1)
            }
        default: EmptyView()
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The scene behind Penny.
struct PetBackdrop: View {
    let item: PetItem?
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                switch item?.id {
                case "sunset":
                    LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.45), Color(red: 1, green: 0.55, blue: 0.55), Color(red: 0.6, green: 0.45, blue: 0.75)], startPoint: .bottom, endPoint: .top)
                    Circle().fill(Color(red: 1, green: 0.9, blue: 0.55)).frame(width: w * 0.45).offset(y: h * 0.38)
                case "night-sky":
                    LinearGradient(colors: [Color(red: 0.08, green: 0.12, blue: 0.3), Color(red: 0.2, green: 0.18, blue: 0.45)], startPoint: .top, endPoint: .bottom)
                    ForEach(Array([(0.12, 0.15), (0.8, 0.12), (0.25, 0.7), (0.88, 0.62), (0.55, 0.08), (0.08, 0.45), (0.7, 0.85)].enumerated()), id: \.offset) { _, star in
                        Circle().fill(.white.opacity(0.85)).frame(width: w * 0.025).position(x: w * star.0, y: h * star.1)
                    }
                    Image(systemName: "moon.fill").font(.system(size: w * 0.12)).foregroundStyle(Color(red: 1, green: 0.95, blue: 0.75)).position(x: w * 0.82, y: h * 0.25)
                case "beach":
                    LinearGradient(colors: [Color(red: 0.55, green: 0.82, blue: 0.98), Color(red: 0.8, green: 0.93, blue: 1)], startPoint: .top, endPoint: .bottom)
                    Rectangle().fill(Color(red: 0.98, green: 0.88, blue: 0.66)).frame(height: h * 0.3).frame(maxHeight: .infinity, alignment: .bottom)
                    Capsule().fill(Color(red: 0.4, green: 0.72, blue: 0.9).opacity(0.6)).frame(width: w * 1.2, height: h * 0.08).position(x: w * 0.5, y: h * 0.7)
                    Circle().fill(Color.yellow.opacity(0.9)).frame(width: w * 0.16).position(x: w * 0.15, y: h * 0.2)
                case "confetti":
                    Color(red: 1, green: 0.98, blue: 0.93)
                    ForEach(0..<18, id: \.self) { i in
                        let colors: [Color] = [.pink, .orange, .yellow, .green, .blue, .purple]
                        Capsule().fill(colors[i % colors.count].opacity(0.7)).frame(width: w * 0.05, height: w * 0.018)
                            .rotationEffect(.degrees(Double(i * 37)))
                            .position(x: w * CGFloat((i * 53) % 100) / 100, y: h * CGFloat((i * 31 + 11) % 100) / 100)
                    }
                default:
                    LinearGradient(colors: [Palette.mint, .white], startPoint: .top, endPoint: .bottom)
                }
            }
        }
    }
}

/// Penny on her backdrop. Tap her for a hop, some hearts and a word or two.
struct PetStage: View {
    let pet: PetProgress
    let outfit: [PetSlot: PetItem]
    let name: String
    var size: CGFloat = 96
    var corner: CGFloat = 18
    @State private var hop = false
    @State private var hearts = false
    @State private var line: String?

    var body: some View {
        ZStack {
            PetBackdrop(item: outfit[.background])
            PetFigure(stage: pet.stage, mood: pet.mood, size: size, outfit: outfit.filter { $0.key != .background })
                .offset(y: hop ? -size * 0.14 : 0)
            if hearts {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: "heart.fill").font(.system(size: size * 0.12)).foregroundStyle(.pink)
                        .offset(x: size * CGFloat(i - 1) * 0.28, y: -size * 0.5)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
            }
            if let line {
                Text(line).font(.system(size: max(11, size * 0.1), weight: .semibold, design: .rounded)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(.white, in: Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: size * 1.5, height: size * 1.35)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .contentShape(Rectangle())
        .onTapGesture { react() }
        .accessibilityAddTraits(.isButton).accessibilityHint("Tap to play with \(name)")
    }

    private func react() {
        let lines: [String]
        switch pet.mood {
        case .happy: lines = ["Ka-ching!", "Another shift, another coin!", "You're doing great!", "Wheee!", "Payday vibes!"]
        case .sleepy: lines = ["Five more minutes…", "Wake me for the next shift", "Yawn…"]
        case .worried: lines = ["Can we chase that pay?", "Where's our money?", "Mark it paid soon?"]
        }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { hop = true; hearts = true; line = lines.randomElement() }
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { hop = false }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.3)) { hearts = false; line = nil }
        }
    }
}

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

private func outfit(_ closet: PetCloset, _ pet: PetProgress) -> [PetSlot: PetItem] {
    Dictionary(uniqueKeysWithValues: PetSlot.allCases.compactMap { slot in closet.wearing(slot, pet).map { (slot, $0) } })
}

/// Overview card: Penny in her outfit, her level and a nudge.
struct PetCard: View {
    @EnvironmentObject private var store: TrackerStore
    let now: Date
    var body: some View {
        let pet = PetProgress(shifts: store.data.shifts, now: now)
        let closet = store.petCloset
        let name = store.petPreferences.displayName
        Card {
            HStack(alignment: .center, spacing: 14) {
                PetStage(pet: pet, outfit: outfit(closet, pet), name: name, size: 72, corner: 16)
                NavigationLink { PetDetailView() } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(name).font(.system(.headline, design: .rounded)).foregroundStyle(Palette.ink)
                            Text("Lv \(pet.level)").font(.caption2.weight(.bold)).foregroundStyle(Palette.teal)
                                .padding(.horizontal, 7).padding(.vertical, 3).background(Palette.mint, in: Capsule())
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                        }
                        ProgressView(value: pet.levelProgress).tint(Palette.teal)
                        HStack(spacing: 12) {
                            Label("\(closet.balance(pet))", systemImage: "dollarsign.circle.fill").foregroundStyle(goldDeep)
                            Label("\(pet.streakWeeks) wk", systemImage: "flame.fill").foregroundStyle(.orange)
                            Label("\(pet.achievements.filter(\.earned).count)", systemImage: "rosette").foregroundStyle(Palette.teal)
                        }.font(.caption.weight(.semibold))
                        Text(pet.message(name: name, currency: store.data.rules.currency)).font(.caption).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("pet.card")
            }
        }
    }
}

struct PetDetailView: View {
    @EnvironmentObject private var store: TrackerStore
    @State private var name = ""
    @State private var slot: PetSlot = .hat
    @State private var buying: PetItem?
    @State private var notice: String?
    @FocusState private var naming: Bool

    private var displayName: String { store.petPreferences.displayName }

    var body: some View {
        let pet = PetProgress(shifts: store.data.shifts)
        let closet = store.petCloset
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    VStack(spacing: 12) {
                        PetStage(pet: pet, outfit: outfit(closet, pet), name: displayName, size: 150, corner: 22)
                        TextField("Penny", text: $name).font(.system(.title2, design: .rounded, weight: .bold)).multilineTextAlignment(.center)
                            .submitLabel(.done).focused($naming).accessibilityIdentifier("pet.name")
                            .onSubmit(saveName)
                            .onChange(of: naming) { _, focused in if !focused { saveName() } }
                        Text("Level \(pet.level) · \(pet.stage.title)").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.teal)
                        ProgressView(value: pet.levelProgress).tint(Palette.teal)
                        Text("\(pet.xpToNextLevel) XP to level \(pet.level + 1) · tap \(displayName) to play").font(.caption).foregroundStyle(Palette.muted)
                    }.frame(maxWidth: .infinity)
                }
                HStack(spacing: 12) {
                    stat("\(closet.balance(pet))", "Coins", "dollarsign.circle.fill", goldDeep)
                    stat("\(pet.streakWeeks)", "Week streak", "flame.fill", .orange)
                    stat("\(pet.achievements.filter(\.earned).count)/\(pet.achievements.count)", "Badges", "rosette", Palette.teal)
                }
                SectionHeading(title: "Wardrobe", detail: "\(closet.balance(pet)) coins to spend")
                PillPicker(values: PetSlot.allCases.map(\.title), selection: Binding(get: { slot.title }, set: { title in slot = PetSlot.allCases.first { $0.title == title } ?? .hat }))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(PetItem.catalog.filter { $0.slot == slot }) { item in itemTile(item, pet, closet) }
                }
                SectionHeading(title: "Badges", detail: "+\(PetProgress.coinsPerAchievement) coins each")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(pet.achievements) { badge($0) }
                }
                SectionHeading(title: "How \(displayName) grows")
                Card {
                    Label("+\(PetProgress.xpPerWorkedShift) XP and \(PetProgress.coinsPerWorkedShift) coins for every shift you work", systemImage: "briefcase.fill")
                    Label("+\(PetProgress.xpPerPaidShift) XP and \(PetProgress.coinsPerPaidShift) coins when a shift is marked paid", systemImage: "checkmark.seal.fill")
                    Label("A new level every \(PetProgress.xpPerLevel) XP, with no limit", systemImage: "arrow.up.circle.fill")
                    Label("Badges add \(PetProgress.coinsPerAchievement) coins and unlock special outfits", systemImage: "rosette")
                    Label("Overdue pay makes \(displayName) worried until it's paid", systemImage: "exclamationmark.bubble.fill")
                }.font(.subheadline).foregroundStyle(Palette.ink)
            }.padding(20)
        }
        .detailStyle("Your pet")
        .onAppear { name = displayName }
        .onDisappear(perform: saveName)
        .confirmationDialog(buying.map { "Buy \($0.name) for \($0.requirement)?" } ?? "", isPresented: Binding(get: { buying != nil }, set: { if !$0 { buying = nil } }), titleVisibility: .visible) {
            if let item = buying { Button("Buy \(item.name)") { buy(item, pet) } }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK", role: .cancel) {} }
    }

    private func itemTile(_ item: PetItem, _ pet: PetProgress, _ closet: PetCloset) -> some View {
        let owned = closet.owns(item, pet)
        let wearing = closet.wearing(item.slot, pet)?.id == item.id
        var preview = outfit(closet, pet); preview[item.slot] = item
        return Button { tap(item, pet, closet) } label: {
            VStack(spacing: 6) {
                PetStage(pet: pet, outfit: preview, name: displayName, size: 52, corner: 12).allowsHitTesting(false)
                    .opacity(owned || isCoinItem(item) ? 1 : 0.55)
                Text(item.name).font(.caption.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.8)
                Group {
                    if wearing { Label("Wearing", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.teal) }
                    else if owned { Text("Owned").foregroundStyle(Palette.muted) }
                    else if isCoinItem(item) { Label(item.requirement, systemImage: "dollarsign.circle.fill").foregroundStyle(goldDeep) }
                    else { Label(item.requirement, systemImage: "lock.fill").foregroundStyle(Palette.muted) }
                }.font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(8).frame(maxWidth: .infinity)
            .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(wearing ? Palette.teal : Palette.line.opacity(0.7), lineWidth: wearing ? 2 : 0.6))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityIdentifier("pet.item." + item.id)
    }

    private func isCoinItem(_ item: PetItem) -> Bool { if case .coins = item.unlock { return true }; return false }

    private func tap(_ item: PetItem, _ pet: PetProgress, _ closet: PetCloset) {
        if closet.owns(item, pet) { store.savePet { var updated = $0.closet ?? PetCloset(); try? updated.toggle(item, pet); $0.closet = updated }; return }
        switch item.unlock {
        case .coins(let price):
            if closet.balance(pet) >= price { buying = item }
            else { notice = "\(item.name) costs \(price) coins. Earn \(price - closet.balance(pet)) more by working shifts and getting paid." }
        case .level(let level): notice = "\(item.name) unlocks at level \(level). \(displayName) is level \(pet.level)."
        case .achievement: notice = "\(item.name) unlocks with the \(item.requirement.replacingOccurrences(of: "Badge: ", with: "")) badge."
        case .free: break
        }
    }

    private func buy(_ item: PetItem, _ pet: PetProgress) {
        var closet = store.petCloset
        do { try closet.buy(item, pet); store.savePet { $0.closet = closet } }
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
                if achievement.earned { Text(achievement.detail).font(.caption2).foregroundStyle(Palette.muted).lineLimit(2) }
                else { ProgressView(value: achievement.progress).tint(Palette.teal); Text(achievement.detail).font(.caption2).foregroundStyle(Palette.muted).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(achievement.earned ? 0.95 : 0.6), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine).accessibilityLabel("\(achievement.title), \(achievement.earned ? "earned" : "not earned yet")")
    }

    private func stat(_ value: String, _ title: String, _ symbol: String, _ tint: Color) -> some View {
        Card {
            Label(value, systemImage: symbol).font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(Palette.muted)
        }
    }
}
