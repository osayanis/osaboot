import SwiftUI

// La mascotte OsaLabs : un petit corps crème avec des bras, des pieds, des joues roses.
// Elle cligne des yeux, regarde où on lui dit (`look`, de -1 à 1), lève les bras, travaille,
// et saute quand `hop` change.
struct Mascot: View {
    enum Mood { case calm, curious, excited, busy, happy, worried, sad }
    enum Arms { case rest, up, wave, work }

    var mood: Mood = .calm
    var arms: Arms = .rest
    var look: CGSize = .zero
    var size: CGFloat = 90
    var hop = 0

    @State private var blink = false
    @State private var swing = false

    private let ink = Color(red: 0.106, green: 0.114, blue: 0.141)
    private let light = Color(red: 0.995, green: 0.99, blue: 0.97)
    private let shade = Color(red: 0.84, green: 0.81, blue: 0.76)
    private let cheek = Color(red: 1, green: 0.5, blue: 0.59)

    var body: some View {
        let w = size, h = size * 0.92
        ZStack {
            Ellipse().fill(.black.opacity(0.55)).frame(width: w * 0.85, height: w * 0.12).blur(radius: w * 0.03).offset(y: h * 0.56)
            ForEach([-1.0, 1.0], id: \.self) { s in
                Ellipse().fill(LinearGradient(colors: [shade, Color(red: 0.7, green: 0.67, blue: 0.62)], startPoint: .top, endPoint: .bottom))
                    .frame(width: w * 0.24, height: w * 0.13).offset(x: s * w * 0.2, y: h * 0.47)
            }
            arm(side: -1)
            arm(side: 1)
            RoundedRectangle(cornerRadius: w * 0.42, style: .continuous)
                .fill(RadialGradient(colors: [light, light, shade], center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: w * 0.78))
                .frame(width: w, height: h)
                .overlay(RoundedRectangle(cornerRadius: w * 0.42, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 1).blur(radius: 0.5))
            face.offset(x: look.width * w * 0.05, y: look.height * w * 0.035)
        }
        .frame(width: w * 1.6, height: h * 1.35)
        .keyframeAnimator(initialValue: 0.0, trigger: hop) { view, y in
            view.offset(y: y).scaleEffect(x: 1 - y / (w * 6), y: 1 + y / (w * 8), anchor: .bottom)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(w * 0.04, duration: 0.08)
                SpringKeyframe(-w * 0.3, duration: 0.22, spring: .snappy)
                SpringKeyframe(0, duration: 0.25, spring: .bouncy)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: look)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: arms)
        .animation(.easeInOut(duration: 0.25), value: mood)
        .onAppear { updateSwing() }
        .onChange(of: arms) { _ in updateSwing() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.4...5)))
                withAnimation(.easeIn(duration: 0.06)) { blink = true }
                try? await Task.sleep(for: .milliseconds(110))
                withAnimation(.easeOut(duration: 0.1)) { blink = false }
            }
        }
        .accessibilityHidden(true)
    }

    // Les bras ne bougent en boucle que pendant le travail (sinon ça coûte du CPU pour rien).
    private func updateSwing() {
        if arms == .wave || arms == .work {
            swing = false
            // le coucou s'arrête main levée après quelques battements ; le travail continue
            let a = Animation.easeInOut(duration: arms == .work ? 0.32 : 0.28)
            withAnimation(arms == .work ? a.repeatForever(autoreverses: true) : a.repeatCount(7, autoreverses: true)) { swing = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { swing = false }
        }
    }

    private func angle(_ side: Double) -> Double {
        // 0° = bras qui pend ; on tourne autour de l'épaule
        let out: Double
        switch arms {
        case .rest: out = 18
        case .up: out = 150
        case .wave: out = side > 0 ? (swing ? 165 : 125) : 18
        case .work: out = side > 0 ? (swing ? 70 : 100) : (swing ? 95 : 65)
        }
        return -side * out
    }

    private func arm(side: Double) -> some View {
        let w = size, len = w * 0.36
        return Capsule()
            .fill(LinearGradient(colors: [light, shade], startPoint: .top, endPoint: .bottom))
            .frame(width: w * 0.15, height: len)
            .rotationEffect(.degrees(angle(side)), anchor: .top)
            .offset(x: side * w * 0.44, y: w * 0.02 + len / 2)
    }

    private var face: some View {
        let w = size
        return ZStack {
            ForEach([-1.0, 1.0], id: \.self) { s in
                eye(s).offset(x: s * w * 0.17, y: -w * 0.05)
                if mood == .worried || mood == .sad {
                    Capsule().fill(ink).frame(width: w * 0.13, height: w * 0.03)
                        .rotationEffect(.degrees(s * (mood == .sad ? 20 : 16)))
                        .offset(x: s * w * 0.18, y: -w * 0.2)
                }
                Ellipse().fill(cheek.opacity(0.55)).frame(width: w * 0.16, height: w * 0.08).offset(x: s * w * 0.3, y: w * 0.1)
            }
            mouth.offset(y: w * 0.16)
        }
    }

    @ViewBuilder private func eye(_ s: Double) -> some View {
        let w = size
        switch mood {
        case .happy:
            Smile(up: true).stroke(ink, style: StrokeStyle(lineWidth: w * 0.045, lineCap: .round)).frame(width: w * 0.15, height: w * 0.08)
        default:
            let big = mood == .excited ? 1.2 : 1
            let round = mood == .worried || mood == .sad
            Capsule().fill(ink)
                .frame(width: w * 0.12 * big, height: (round ? w * 0.13 : w * 0.2) * big)
                .overlay(Circle().fill(.white.opacity(0.92)).frame(width: w * 0.045 * big).offset(x: w * 0.015, y: -w * 0.035 * big))
                .scaleEffect(x: 1, y: blink ? 0.1 : 1)
        }
    }

    @ViewBuilder private var mouth: some View {
        let w = size
        switch mood {
        case .sad:
            Smile(up: true).stroke(ink, style: StrokeStyle(lineWidth: w * 0.035, lineCap: .round)).frame(width: w * 0.15, height: w * 0.05)
        case .worried:
            Capsule().fill(ink).frame(width: w * 0.1, height: w * 0.03)
        case .excited:
            Ellipse().fill(ink).frame(width: w * 0.15, height: w * 0.12)
                .overlay(Ellipse().fill(cheek).frame(width: w * 0.08, height: w * 0.045).offset(y: w * 0.03))
                .clipShape(Ellipse())
        case .curious, .busy:
            Ellipse().fill(ink).frame(width: w * 0.07, height: w * 0.07)
        case .calm, .happy:
            Smile(up: false).stroke(ink, style: StrokeStyle(lineWidth: w * 0.035, lineCap: .round))
                .frame(width: mood == .happy ? w * 0.24 : w * 0.18, height: w * 0.07)
        }
    }
}

/// Un arc : sourire (`up` faux) ou œil fermé de joie / bouche triste (`up` vrai).
struct Smile: Shape {
    var up: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: up ? r.maxY : r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: up ? r.maxY : r.minY), control: CGPoint(x: r.midX, y: up ? r.minY - r.height : r.maxY + r.height))
        return p
    }
}
