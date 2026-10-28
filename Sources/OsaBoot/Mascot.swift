import SwiftUI

// La mascotte OsaLabs, vue de face : un petit corps crème, deux yeux, des joues roses.
struct Mascot: View {
    enum Mood { case calm, busy, happy, sad }
    var mood: Mood = .calm
    var size: CGFloat = 90
    @State private var bob = false

    private let ink = Color(red: 0.106, green: 0.114, blue: 0.141)
    private let light = Color(red: 0.995, green: 0.99, blue: 0.97)
    private let shade = Color(red: 0.84, green: 0.81, blue: 0.76)

    var body: some View {
        let w = size, h = size * 0.95
        ZStack {
            Ellipse().fill(.black.opacity(0.28)).frame(width: w * 0.8, height: w * 0.12).offset(y: h * 0.55).blur(radius: 2)
            RoundedRectangle(cornerRadius: w * 0.42, style: .continuous)
                .fill(RadialGradient(colors: [light, light, shade], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: w * 0.75))
                .frame(width: w, height: h)
            face.frame(width: w, height: h)
        }
        .offset(y: mood == .busy && bob ? -size * 0.06 : 0)
        .onAppear { updateBob() }
        .onChange(of: mood) { _ in updateBob() }
        .accessibilityHidden(true)
    }

    private func updateBob() {
        // l'animation ne tourne que pendant l'écriture (une animation permanente coûte du CPU)
        if mood == .busy { withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { bob = true } }
        else { withAnimation(.easeOut(duration: 0.2)) { bob = false } }
    }

    private var face: some View {
        let w = size
        return ZStack {
            HStack(spacing: w * 0.22) {
                ForEach(0..<2, id: \.self) { _ in eye }
            }
            .offset(y: mood == .busy ? w * 0.02 : -w * 0.04)
            HStack(spacing: w * 0.5) {
                ForEach(0..<2, id: \.self) { _ in
                    Ellipse().fill(Color(red: 1, green: 0.5, blue: 0.59).opacity(0.55)).frame(width: w * 0.16, height: w * 0.08)
                }
            }
            .offset(y: w * 0.12)
            mouth.offset(y: w * 0.2)
        }
    }

    @ViewBuilder private var eye: some View {
        let w = size
        switch mood {
        case .happy:
            Arc(up: true).stroke(ink, style: StrokeStyle(lineWidth: w * 0.045, lineCap: .round)).frame(width: w * 0.16, height: w * 0.09)
        case .sad:
            Capsule().fill(ink).frame(width: w * 0.12, height: w * 0.12)
        default:
            Capsule().fill(ink).frame(width: w * 0.12, height: w * 0.2)
                .overlay(Circle().fill(.white.opacity(0.9)).frame(width: w * 0.05).offset(x: w * 0.015, y: -w * 0.04))
        }
    }

    @ViewBuilder private var mouth: some View {
        let w = size
        if mood == .sad {
            Arc(up: true).stroke(ink, style: StrokeStyle(lineWidth: w * 0.035, lineCap: .round)).frame(width: w * 0.16, height: w * 0.06)
        } else if mood == .busy {
            Ellipse().fill(ink).frame(width: w * 0.08, height: w * 0.07)
        } else {
            Arc(up: false).stroke(ink, style: StrokeStyle(lineWidth: w * 0.035, lineCap: .round)).frame(width: w * 0.2, height: w * 0.08)
        }
    }
}

/// Un arc simple : sourire (`up` faux) ou œil fermé de joie / bouche triste (`up` vrai).
private struct Arc: Shape {
    var up: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: up ? r.maxY : r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: up ? r.maxY : r.minY), control: CGPoint(x: r.midX, y: up ? r.minY - r.height : r.maxY + r.height))
        return p
    }
}
