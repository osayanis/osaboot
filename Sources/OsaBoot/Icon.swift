import SwiftUI
import AppKit

// L'icône de l'app (`OsaBoot icon <dossier>` → AppIcon.iconset) : la mascotte qui serre une clé USB.
struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.14, blue: 0.27), Color(red: 0.05, green: 0.045, blue: 0.07)], startPoint: .top, endPoint: .bottom))
                .frame(width: 1024 - 200, height: 1024 - 200)
            Circle().fill(RadialGradient(colors: [Theme.accent.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: 330))
                .frame(width: 700, height: 700).offset(y: 40)
            // la clé USB, debout derrière la mascotte
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 26).fill(Color(red: 0.85, green: 0.87, blue: 0.9)).frame(width: 150, height: 110)
                    .overlay(HStack(spacing: 34) { ForEach(0..<2, id: \.self) { _ in RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.3, green: 0.32, blue: 0.38)).frame(width: 34, height: 30) } }.offset(y: -14))
                RoundedRectangle(cornerRadius: 44).fill(Theme.pink).frame(width: 230, height: 330).offset(y: 96)
                    .overlay(Image(systemName: "bolt.fill").font(.system(size: 120, weight: .black)).foregroundStyle(.white.opacity(0.95)).offset(y: 230))
            }
            .rotationEffect(.degrees(14)).offset(x: 150, y: -150)
            Mascot(mood: .happy, size: 430).offset(x: -60, y: 120)
        }
        .frame(width: 1024, height: 1024)
    }

    @MainActor static func export(to dir: URL) throws {
        let r = ImageRenderer(content: AppIconView())
        r.scale = 1
        guard let cg = r.cgImage else { throw Fail("Rendu de l'icône impossible.") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"),
                           (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
            let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
            let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
            try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("icon_\(name).png"))
        }
    }
}
