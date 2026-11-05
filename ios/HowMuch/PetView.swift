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
            sprout.offset(y: -size * 0.43)
            coin(scale: 0.78)
        }
    }

    private var goldenCoin: some View {
        ZStack {
            Circle().fill(goldLight.opacity(0.35)).frame(width: size).blur(radius: size * 0.06)
            coin(scale: 0.8, shine: true)
            Crown().fill(LinearGradient(colors: [goldLight, gold], startPoint: .top, endPoint: .bottom))
                .overlay(Crown().stroke(goldDeep, lineWidth: size * 0.015))
                .frame(width: size * 0.34, height: size * 0.18).offset(y: -size * 0.46)
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

/// Overview card: the pet, its level and a nudge.
struct PetCard: View {
    @EnvironmentObject private var store: TrackerStore
    @AppStorage("pet.name") private var name = "Penny"
    let now: Date
    var body: some View {
        let pet = PetProgress(shifts: store.data.shifts, now: now)
        NavigationLink { PetDetailView() } label: {
            Card {
                HStack(alignment: .center, spacing: 16) {
                    PetFigure(stage: pet.stage, mood: pet.mood, size: 84)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(name).font(.system(.headline, design: .rounded)).foregroundStyle(Palette.ink)
                            Text(pet.stage.title).font(.caption2.weight(.semibold)).foregroundStyle(Palette.teal)
                                .padding(.horizontal, 7).padding(.vertical, 3).background(Palette.mint, in: Capsule())
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                        }
                        ProgressView(value: pet.progress).tint(Palette.teal)
                        HStack(spacing: 12) {
                            Label("\(pet.coins)", systemImage: "dollarsign.circle.fill").foregroundStyle(goldDeep)
                            Label(counted(pet.streakWeeks, "week") + " streak", systemImage: "flame.fill").foregroundStyle(.orange)
                        }.font(.caption.weight(.semibold))
                        Text(pet.message(name: name, currency: store.data.rules.currency)).font(.caption).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.buttonStyle(.plain).accessibilityIdentifier("pet.card")
    }
}

struct PetDetailView: View {
    @EnvironmentObject private var store: TrackerStore
    @AppStorage("pet.name") private var name = "Penny"
    var body: some View {
        let pet = PetProgress(shifts: store.data.shifts)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    VStack(spacing: 12) {
                        PetFigure(stage: pet.stage, mood: pet.mood, size: 160)
                        TextField("Name", text: $name).font(.system(.title2, design: .rounded, weight: .bold)).multilineTextAlignment(.center)
                            .submitLabel(.done).accessibilityIdentifier("pet.name")
                        Text("\(pet.stage.title) · \(pet.xp) XP").font(.subheadline).foregroundStyle(Palette.muted)
                        ProgressView(value: pet.progress).tint(Palette.teal)
                        Text(pet.message(name: name.isEmpty ? "Your pet" : name, currency: store.data.rules.currency)).font(.subheadline).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity)
                }
                HStack(spacing: 12) {
                    stat("\(pet.coins)", "Coins", "dollarsign.circle.fill", goldDeep)
                    stat("\(pet.streakWeeks)", "Week streak", "flame.fill", .orange)
                }
                SectionHeading(title: "How \(name.isEmpty ? "your pet" : name) grows")
                Card {
                    Label("+\(PetProgress.xpPerWorkedShift) XP for every shift you work", systemImage: "briefcase.fill")
                    Label("+\(PetProgress.xpPerPaidShift) XP and a coin when a shift is marked paid", systemImage: "checkmark.seal.fill")
                    Label("Your streak counts weeks in a row with a shift", systemImage: "flame.fill")
                    Label("Overdue pay makes \(name.isEmpty ? "your pet" : name) worried until it's paid", systemImage: "exclamationmark.bubble.fill")
                }.font(.subheadline).foregroundStyle(Palette.ink)
                SectionHeading(title: "Stages")
                Card {
                    ForEach(PetProgress.Stage.allCases, id: \.rawValue) { stage in
                        HStack(spacing: 12) {
                            PetFigure(stage: stage, mood: .happy, size: 40)
                            VStack(alignment: .leading) {
                                Text(stage.title).font(.subheadline.weight(.semibold))
                                Text(stage.threshold == 0 ? "Where every pet starts" : "\(stage.threshold) XP").font(.caption).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            if pet.xp >= stage.threshold { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.teal) }
                        }
                    }
                }
            }.padding(20)
        }.detailStyle("Your pet")
    }
    private func stat(_ value: String, _ title: String, _ symbol: String, _ tint: Color) -> some View {
        Card {
            Label(value, systemImage: symbol).font(.system(.title2, design: .rounded, weight: .bold)).foregroundStyle(tint)
            Text(title).font(.caption).foregroundStyle(Palette.muted)
        }
    }
}
