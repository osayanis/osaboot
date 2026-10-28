import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

enum Theme {
    static let bg = Color(red: 0.035, green: 0.035, blue: 0.045)       // fond noir fixe, comme OsaWallpaper
    static let surface = Color.white.opacity(0.055)
    static let line = Color.white.opacity(0.1)
    static let dim = Color.white.opacity(0.5)
    static let lilac = Color(red: 0.77, green: 0.71, blue: 0.99)
    static let pink = Color(red: 0.96, green: 0.45, blue: 0.71)
    static let accent = Color(red: 0.53, green: 0.94, blue: 0.67)       // menthe
    static let blue = Color(red: 0.36, green: 0.72, blue: 1)
    static func title(_ s: CGFloat) -> Font { .system(size: s, weight: .heavy, design: .rounded) }
}

// L'état de l'app : l'image, la clé, les options.
final class AppModel: ObservableObject {
    @Published var image: SourceImage?
    @Published var inspecting = false
    @Published var imageError: String?
    @Published var drive: Drive?
    @Published var options = FlashOptions()
    @Published var confirming = false
    @Published var choosingDrive = false
    let drives = DriveList()
    let flasher = Flasher()
    private var bag = Set<AnyCancellable>()

    init() {
        // la clé choisie a disparu ? on l'oublie. Une seule clé branchée ? on la choisit.
        drives.$drives.sink { [weak self] list in
            guard let self, !self.flasher.running else { return }
            if let d = self.drive, !list.contains(d) { self.drive = list.first { $0.id == d.id && $0.size == d.size } }
            if self.drive == nil, list.count == 1, list[0].writable { self.drive = list[0] }
        }.store(in: &bag)
    }

    func pickImage() {
        guard !flasher.running else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = SourceImage.extensions.compactMap { UTType(filenameExtension: $0) }
        p.message = "Choisis une image disque (.iso, .img)"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let url = p.url { open(url) }
    }

    func open(_ url: URL) {
        guard !flasher.running else { return }
        if case .done = flasher.phase { flasher.reset() }
        if case .failed = flasher.phase { flasher.reset() }
        inspecting = true
        imageError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try SourceImage.inspect(url) }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                    self.inspecting = false
                    switch r {
                    case .success(let img): self.image = img
                    case .failure(let e): self.image = nil; self.imageError = e.localizedDescription
                    }
                }
            }
        }
    }

    func chooseDrive() { if !flasher.running && !drives.drives.isEmpty { choosingDrive = true } }

    var tooSmall: Bool { if let image, let drive { return drive.size < image.needed }; return false }
    var canFlash: Bool { image != nil && drive?.writable == true && !tooSmall && !flasher.running }

    func flash() { if canFlash { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { confirming = true } } }

    func confirmFlash() {
        guard canFlash, let image, let drive else { return }
        withAnimation(.easeOut(duration: 0.2)) { confirming = false }
        flasher.start(image: image, drive: drive, options: options)
    }
}

/// Position de la souris, à part pour que seul le regard de la mascotte se redessine.
final class Pointer: ObservableObject { @Published var location: CGPoint? }

// MARK: - Fenêtre

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flasher: Flasher
    @ObservedObject var drives: DriveList
    @StateObject private var pointer = Pointer()
    @State private var dropping = false
    @State private var hoveringFlash = false
    @State private var hop = 0
    @State private var confettiAt: Date?

    static let size = CGSize(width: 860, height: 600)
    // centres des trois éléments de la scène (coordonnées de la fenêtre)
    static let disc = CGPoint(x: 165, y: 270)
    static let mascot = CGPoint(x: 430, y: 255)
    static let key = CGPoint(x: 695, y: 270)
    static let flowY: CGFloat = 245

    var body: some View {
        ZStack {
            Theme.bg
            // un rond de lumière très doux sous la mascotte, comme une scène
            Ellipse().fill(EllipticalGradient(colors: [.white.opacity(0.075), .clear], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                .frame(width: 560, height: 170).position(x: Self.mascot.x, y: Self.mascot.y + 110)

            FlowView(running: flasher.running, ready: model.canFlash || flasher.running, done: isDone)
                .allowsHitTesting(false)

            header.position(x: Self.size.width / 2, y: 26)

            DiscSlot(model: model, dropping: dropping, spinning: flasher.running)
                .position(Self.disc)
            KeySlot(model: model, drives: drives, flasher: flasher)
                .position(Self.key)
            MascotStage(model: model, flasher: flasher, pointer: pointer, dropping: dropping, hoveringFlash: hoveringFlash, hop: hop)
                .position(Self.mascot)

            BottomBar(model: model, flasher: flasher, hoveringFlash: $hoveringFlash)
                .frame(width: Self.size.width - 120)
                .position(x: Self.size.width / 2, y: 505)

            if let at = confettiAt {
                ConfettiView(start: at, origin: CGPoint(x: Self.key.x, y: Self.key.y - 60))
                    .allowsHitTesting(false)
            }
            if model.confirming { ConfirmView(model: model).transition(.opacity) }
            if dropping {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.lilac.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 7]))
                    .padding(10).allowsHitTesting(false).transition(.opacity)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .coordinateSpace(name: "root")
        .onContinuousHover(coordinateSpace: .named("root")) { phase in
            switch phase {
            case .active(let p): pointer.location = p
            case .ended: pointer.location = nil
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping.animation(.spring(response: 0.3, dampingFraction: 0.7))) { providers in
            guard !flasher.running, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { DispatchQueue.main.async { model.open(url) } } }
            return true
        }
        // la mascotte saute quand il se passe quelque chose de bien
        .onChange(of: model.image) { img in if img != nil { hop += 1 } }
        .onChange(of: model.drive) { d in if d != nil { hop += 1 } }
        .onChange(of: flasher.phase) { p in
            if case .done = p {
                hop += 1
                confettiAt = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { hop += 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { confettiAt = nil }
            }
        }
    }

    private var isDone: Bool { if case .done = flasher.phase { return true }; return false }

    private var header: some View {
        HStack(spacing: 8) {
            Text("OsaBoot").font(Theme.title(15))
            Text("v\(Updater.current)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.3))
            Spacer()
            Text("Linux · Raspberry Pi · Windows").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.3))
        }
        .padding(.leading, 84).padding(.trailing, 24)
    }
}

// MARK: - La mascotte et sa bulle

struct MascotStage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flasher: Flasher
    @ObservedObject var pointer: Pointer
    let dropping: Bool
    let hoveringFlash: Bool
    let hop: Int

    var body: some View {
        VStack(spacing: 4) {
            Bubble(text: message, tone: tone)
                .frame(width: 280, height: 110, alignment: .bottom)
            Mascot(mood: mood, arms: arms, look: look, size: 112, hop: hop)
        }
    }

    private var look: CGSize {
        if dropping || model.inspecting { return CGSize(width: -1, height: 0.2) }
        if flasher.running { return CGSize(width: 0.9, height: 0.3) }
        if hoveringFlash { return CGSize(width: 0, height: 1) }
        guard let p = pointer.location else { return .zero }
        let c = CGPoint(x: ContentView.mascot.x, y: ContentView.mascot.y + 60)
        return CGSize(width: max(-1, min(1, (p.x - c.x) / 260)), height: max(-1, min(1, (p.y - c.y) / 200)))
    }

    private var mood: Mascot.Mood {
        if model.confirming { return .worried }
        switch flasher.phase {
        case .running: return .busy
        case .done: return .happy
        case .failed: return .sad
        case .idle: break
        }
        if dropping { return .excited }
        if model.inspecting { return .curious }
        if model.imageError != nil || model.tooSmall { return .worried }
        if hoveringFlash && model.canFlash { return .excited }
        return .calm
    }

    private var arms: Mascot.Arms {
        switch flasher.phase {
        case .running: return .work
        case .done: return .up
        case .failed: return .rest
        case .idle: break
        }
        if dropping { return .up }
        if model.image == nil && model.drive == nil && !model.inspecting { return .wave }
        return .rest
    }

    private var tone: Bubble.Tone {
        switch flasher.phase {
        case .failed: return .bad
        case .done: return .good
        default: return model.imageError != nil || model.tooSmall ? .bad : .normal
        }
    }

    private var message: String {
        switch flasher.phase {
        case .running: return Self.say(stage: flasher.stage)
        case .done(let m): return "C'est prêt ! " + m
        case .failed(let m): return m
        case .idle: break
        }
        if dropping { return "Lâche-la, je l'attrape !" }
        if model.inspecting { return "Je regarde ce qu'il y a dedans…" }
        if let e = model.imageError { return e }
        let key = model.drive.map { "« \($0.name) »" }
        guard let img = model.image else {
            if let key { return "J'ai vu ta clé \(key). Glisse-moi une image .iso ou .img !" }
            return "Salut ! Glisse-moi une image .iso ou .img, puis branche une clé USB."
        }
        if model.drive == nil {
            return img.isWindows ? "Windows, super ! Branche une clé d'au moins \(img.needed.bytes)." : "Parfait. Branche la clé USB à utiliser."
        }
        if let d = model.drive, !d.writable { return "\(key ?? "Cette clé") est protégée en écriture. Regarde s'il y a un petit verrou dessus." }
        if model.tooSmall { return "\(key ?? "La clé") est trop petite : il faut au moins \(img.needed.bytes)." }
        if hoveringFlash { return "Clique, je m'occupe de tout !" }
        if case .raw(false) = img.kind { return "Cette image n'a pas de table de partitions : elle risque de ne pas démarrer. Je peux quand même la copier." }
        return img.isWindows ? "Je prépare \(key ?? "la clé") en FAT32 et j'y mets Windows. On y va ?" : "Je copie l'image sur \(key ?? "la clé"), puis je vérifie tout. On y va ?"
    }

    static func say(stage: String) -> String {
        switch stage {
        case "Écriture": return "J'écris l'image sur la clé…"
        case "Vérification": return "Je relis tout pour être sûr…"
        case "Formatage de la clé": return "Je prépare la clé en FAT32…"
        case "Copie des fichiers": return "Je copie les fichiers de Windows…"
        case "Ouverture de l'ISO": return "J'ouvre l'ISO…"
        case "Finalisation": return "Je range les derniers fichiers…"
        case "Éjection": return "J'éjecte la clé…"
        default:
            if stage.hasPrefix("Découpage") { return "install.wim est trop gros pour FAT32 : je le coupe en morceaux…" }
            return "Je prépare tout…"
        }
    }
}

struct Bubble: View {
    enum Tone { case normal, good, bad }
    let text: String
    let tone: Tone

    var body: some View {
        ZStack(alignment: .bottom) {
            content
                .id(text)
                .transition(.asymmetric(insertion: .scale(scale: 0.85, anchor: .bottom).combined(with: .opacity), removal: .opacity))
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: text)
    }

    private var content: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.1, green: 0.1, blue: 0.12))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill))
            Triangle().fill(fill).frame(width: 16, height: 9)
        }
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }

    private var fill: Color {
        switch tone {
        case .normal: return Color(red: 0.99, green: 0.98, blue: 0.96)
        case .good: return Color(red: 0.8, green: 0.98, blue: 0.86)
        case .bad: return Color(red: 1, green: 0.85, blue: 0.88)
        }
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Le disque (l'image)

struct DiscSlot: View {
    @ObservedObject var model: AppModel
    let dropping: Bool
    let spinning: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                if let img = model.image {
                    SpinningDisc(windows: img.isWindows, spinning: spinning)
                        .transition(.asymmetric(insertion: .scale(scale: 0.3).combined(with: .opacity).combined(with: .offset(x: -40)),
                                                removal: .scale(scale: 0.6).combined(with: .opacity)))
                        .id(img.url)
                } else {
                    Circle()
                        .strokeBorder(.white.opacity(dropping ? 0.7 : hover ? 0.4 : 0.2), style: StrokeStyle(lineWidth: 2, dash: [7, 7]))
                        .background(Circle().fill(.white.opacity(hover || dropping ? 0.05 : 0.02)))
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: model.inspecting ? "hourglass" : "plus").font(.system(size: 26, weight: .semibold))
                                Text("Image").font(.system(size: 12, weight: .semibold))
                            }.foregroundStyle(.white.opacity(hover || dropping ? 0.8 : 0.45))
                        )
                        .frame(width: 140, height: 140)
                        .transition(.opacity)
                }
            }
            .frame(width: 150, height: 150)
            .scaleEffect(dropping ? 1.08 : hover && !spinning ? 1.04 : 1)
            .shadow(color: dropping ? Theme.lilac.opacity(0.5) : .clear, radius: 24)
            .contentShape(Circle())
            .onTapGesture { model.pickImage() }
            .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hover = h } }
            .help("Choisir une image")

            VStack(spacing: 4) {
                Text(model.image?.name ?? "Choisis une image")
                    .font(.system(size: 14, weight: .bold)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1)
                if model.image != nil && !spinning {
                    Button("Changer") { model.pickImage() }.buttonStyle(LinkStyle()).padding(.top, 2)
                }
            }
            .frame(width: 220).frame(height: 58, alignment: .top)
        }
    }

    private var subtitle: String {
        guard let img = model.image else { return "glisse-la ici ou clique" }
        switch img.kind {
        case .windows(let w): return "Windows \(w.arch) · \(img.size.bytes)"
        case .raw: return "Image disque · \(img.size.bytes)"
        }
    }
}

/// Le disque tourne pendant l'écriture (TimelineView en pause le reste du temps).
struct SpinningDisc: View {
    let windows: Bool
    let spinning: Bool
    @State private var since = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !spinning)) { tl in
            Disc(windows: windows)
                .rotationEffect(.degrees(spinning ? tl.date.timeIntervalSince(since) * 220 : 0))
        }
        .onChange(of: spinning) { s in if s { since = Date() } }
    }
}

/// Un disque irisé, avec le logo de Windows au centre pour les ISO Windows.
struct Disc: View {
    let windows: Bool
    var body: some View {
        ZStack {
            Circle().fill(AngularGradient(colors: [Color(white: 0.82), Theme.lilac, Color(white: 0.9), Theme.blue.opacity(0.8), Color(white: 0.85),
                                                   Theme.pink.opacity(0.75), Color(white: 0.92), Theme.accent.opacity(0.8), Color(white: 0.82)], center: .center))
            ForEach([10.0, 20.0, 30.0], id: \.self) { inset in Circle().stroke(.white.opacity(0.2), lineWidth: 0.8).padding(inset) }
            Circle().fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .topLeading, endPoint: .center)).blendMode(.screen)
            Circle().fill(Color(white: 0.1)).frame(width: 52, height: 52)
            if windows { WindowsLogo().frame(width: 22, height: 22) }
            else { Image(systemName: "terminal.fill").font(.system(size: 18)).foregroundStyle(Theme.accent) }
            // un repère pour voir le disque tourner
            Capsule().fill(.white.opacity(0.55)).frame(width: 3, height: 14).offset(y: -50)
        }
        .frame(width: 140, height: 140)
        .shadow(color: .black.opacity(0.6), radius: 14, y: 8)
    }
}

struct WindowsLogo: View {
    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow { tile; tile }
            GridRow { tile; tile }
        }
    }
    private var tile: some View { Rectangle().fill(Theme.blue) }
}

// MARK: - La clé USB

struct KeySlot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drives: DriveList
    @ObservedObject var flasher: Flasher
    @State private var hover = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                if let d = model.drive {
                    UsbKey(fill: fill, state: keyState, label: d.size.bytes)
                        .transition(.asymmetric(insertion: .offset(y: 90).combined(with: .opacity), removal: .offset(y: 90).combined(with: .opacity)))
                        .id(d.id)
                } else {
                    WaitingKey().transition(.opacity)
                }
            }
            .frame(width: 150, height: 150)
            .scaleEffect(hover && model.drive != nil && drives.drives.count > 1 && !flasher.running ? 1.04 : 1)
            .contentShape(Rectangle())
            .onTapGesture { model.chooseDrive() }
            .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hover = h } }
            .popover(isPresented: $model.choosingDrive, arrowEdge: .leading) { DriveMenu(model: model, drives: drives) }

            VStack(spacing: 4) {
                Text(model.drive?.name ?? "Branche une clé USB").font(.system(size: 14, weight: .bold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(model.tooSmall ? Theme.pink : Theme.dim).lineLimit(1).truncationMode(.middle)
                if drives.drives.count > 1 && !flasher.running {
                    Button("\(drives.drives.count) clés branchées · changer") { model.chooseDrive() }.buttonStyle(LinkStyle()).padding(.top, 2)
                }
            }
            .frame(width: 220).frame(height: 58, alignment: .top)
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: model.drive)
    }

    private var fill: Double {
        switch flasher.phase {
        case .running: return flasher.fraction
        case .done: return 1
        default: return 0
        }
    }
    private var keyState: UsbKey.State {
        switch flasher.phase {
        case .done: return .done
        case .failed: return .failed
        default: return model.tooSmall || model.drive?.writable == false ? .failed : .plugged
        }
    }
    private var subtitle: String {
        guard let d = model.drive else { return "elle apparaîtra ici toute seule" }
        if d.virtual { return "image de test · \(d.size.bytes)" }
        return d.volumes.isEmpty ? "\(d.bus) · \(d.size.bytes)" : d.volumes.joined(separator: ", ")
    }
}

/// L'emplacement vide : une clé en pointillés.
struct WaitingKey: View {
    var body: some View { UsbKey(fill: 0, state: .empty, label: "") }
}

/// Une clé USB dessinée, qui se remplit pendant l'écriture.
struct UsbKey: View {
    enum State { case empty, plugged, done, failed }
    let fill: Double
    let state: State
    let label: String

    var body: some View {
        VStack(spacing: 0) {
            // la prise métallique
            ZStack {
                if state == .empty {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.62)], startPoint: .leading, endPoint: .trailing))
                    HStack(spacing: 10) { ForEach(0..<2, id: \.self) { _ in RoundedRectangle(cornerRadius: 1.5).fill(Color(white: 0.3)).frame(width: 8, height: 7) } }
                        .offset(y: -3)
                }
            }
            .frame(width: 44, height: 30)
            // le corps
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(bodyFill)
                if state == .empty {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                    Image(systemName: "arrow.up").font(.system(size: 20, weight: .bold)).foregroundStyle(.white.opacity(0.35))
                } else {
                    GeometryReader { g in
                        Rectangle().fill(LinearGradient(colors: [Theme.accent, Color(red: 0.36, green: 0.85, blue: 0.75)], startPoint: .top, endPoint: .bottom))
                            .frame(height: g.size.height * fill).frame(maxHeight: .infinity, alignment: .bottom)
                            .animation(.easeOut(duration: 0.3), value: fill)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .topLeading, endPoint: .center))
                    VStack(spacing: 4) {
                        Image(systemName: state == .done ? "checkmark" : state == .failed ? "exclamationmark" : "bolt.fill")
                            .font(.system(size: 22, weight: .heavy))
                            .contentTransition(.symbolEffect(.replace))
                        if state != .done {
                            Text(fill > 0 ? "\(Int(fill * 100)) %" : label).font(.system(size: 12, weight: .heavy, design: .rounded)).monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    .foregroundStyle(.white.opacity(0.95))
                }
            }
            .frame(width: 80, height: 112)
        }
        .shadow(color: state == .done ? Theme.accent.opacity(0.55) : .black.opacity(state == .empty ? 0 : 0.5), radius: state == .done ? 22 : 12, y: 6)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: state)
    }

    private var bodyFill: AnyShapeStyle {
        switch state {
        case .empty: return AnyShapeStyle(Color.white.opacity(0.02))
        case .failed: return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.55, green: 0.2, blue: 0.3), Color(red: 0.35, green: 0.12, blue: 0.2)], startPoint: .top, endPoint: .bottom))
        default: return AnyShapeStyle(LinearGradient(colors: [Theme.pink, Color(red: 0.78, green: 0.3, blue: 0.58)], startPoint: .top, endPoint: .bottom))
        }
    }
}

/// La liste des clés branchées (popover).
struct DriveMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drives: DriveList

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sur quelle clé ?").font(Theme.title(15))
            Text("Seuls les disques externes apparaissent ici.").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(drives.drives) { d in
                let ok = d.writable && !(model.image.map { d.size < $0.needed } ?? false)
                Button {
                    guard ok else { return }
                    model.drive = d
                    model.choosingDrive = false
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 5).fill(Theme.pink).frame(width: 16, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name).font(.system(size: 13, weight: .bold))
                            Text(([d.size.bytes] + d.volumes).joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        if model.drive == d { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                        else if !ok { Text(d.writable ? "trop petite" : "protégée").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.pink) }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(model.drive == d ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.05)))
                    .opacity(ok ? 1 : 0.5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Le flux de données entre disque, mascotte et clé

struct FlowView: View {
    let running: Bool
    let ready: Bool
    let done: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !running)) { tl in
            Canvas { ctx, _ in
                let t = tl.date.timeIntervalSinceReferenceDate
                let y = ContentView.flowY
                let segments = [(CGPoint(x: ContentView.disc.x + 88, y: y), CGPoint(x: ContentView.mascot.x - 88, y: y)),
                                (CGPoint(x: ContentView.mascot.x + 88, y: y), CGPoint(x: ContentView.key.x - 66, y: y))]
                for (a, b) in segments {
                    var p = Path(); p.move(to: a); p.addLine(to: b)
                    let color: Color = done ? Theme.accent.opacity(0.55) : .white.opacity(ready ? 0.25 : 0.1)
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 9], dashPhase: running ? -CGFloat(t * 40) : 0))
                    guard running else { continue }
                    // les petits morceaux de données qui voyagent
                    let colors = [Theme.lilac, Theme.pink, Theme.accent, Theme.blue]
                    for i in 0..<6 {
                        let k = (t * 0.55 + Double(i) / 6).truncatingRemainder(dividingBy: 1)
                        let x = a.x + (b.x - a.x) * k
                        let wob = sin(k * .pi * 2 + Double(i)) * 6
                        let fade = min(1, min(k, 1 - k) * 6)
                        let r = CGRect(x: x - 4, y: y - 4 + wob, width: 8, height: 8)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 2.5), with: .color(colors[i % colors.count].opacity(fade)))
                    }
                }
            }
        }
    }
}

// MARK: - En bas : options, bouton, progression

struct BottomBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flasher: Flasher
    @Binding var hoveringFlash: Bool

    var body: some View {
        VStack(spacing: 14) {
            switch flasher.phase {
            case .running:
                progress
            case .done, .failed:
                Button(isFailed ? "Réessayer" : "Flasher une autre clé") { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { flasher.reset() } }
                    .buttonStyle(BigButton(enabled: true)).keyboardShortcut(.defaultAction)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            case .idle:
                options.frame(height: 32)
                Button { model.flash() } label: {
                    HStack(spacing: 8) { Image(systemName: "bolt.fill"); Text("Flasher") }
                }
                .buttonStyle(BigButton(enabled: model.canFlash))
                .disabled(!model.canFlash)
                .keyboardShortcut(.return, modifiers: [.command])
                .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { hoveringFlash = h } }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: flasher.phase)
    }

    private var isFailed: Bool { if case .failed = flasher.phase { return true }; return false }

    @ViewBuilder private var options: some View {
        if let img = model.image {
            HStack(spacing: 10) {
                if img.isWindows {
                    Chip(on: $model.options.bypassChecks, title: "Windows 11 sans TPM ni Secure Boot",
                         help: "Ajoute un fichier qui fait sauter à l'installateur ses vérifications de matériel (TPM 2.0, Secure Boot, 4 Go de RAM).")
                    if case .windows(let w) = img.kind, w.needsSplit {
                        Label("install.wim sera découpé", systemImage: "scissors").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.dim)
                            .help("\(w.install) fait \(w.installSize.bytes), plus que les 4 Go permis par FAT32 : il sera coupé en morceaux que Windows réunit tout seul.")
                    }
                } else {
                    Chip(on: $model.options.verify, title: "Vérifier après l'écriture", help: "Relit toute la clé et compare son empreinte SHA-256 à celle de l'image.")
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var progress: some View {
        VStack(spacing: 10) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(LinearGradient(colors: [Theme.lilac, Theme.pink, Theme.accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(10, g.size.width * flasher.fraction))
                        .animation(.easeOut(duration: 0.3), value: flasher.fraction)
                }
            }
            .frame(width: 460, height: 8)
            HStack(spacing: 14) {
                Text("\(Int(flasher.fraction * 100)) %").font(.system(size: 13, weight: .heavy, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.dim).monospacedDigit().lineLimit(1)
                Spacer()
                Button("Annuler") { flasher.cancel() }.buttonStyle(LinkStyle())
            }
            .frame(width: 460)
        }
        .padding(.top, 20)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var detail: String {
        var parts = [flasher.stage]
        if flasher.speed > 0 { parts.append("\(Int64(flasher.speed).bytes)/s") }
        if let r = flasher.remaining, r.isFinite, r > 1 {
            let f = DateComponentsFormatter()
            f.allowedUnits = r >= 3600 ? [.hour, .minute] : [.minute, .second]
            f.unitsStyle = .abbreviated
            parts.append("encore \(f.string(from: r) ?? "")")
        }
        return parts.joined(separator: " · ")
    }
}

struct Chip: View {
    @Binding var on: Bool
    let title: String
    let help: String
    var body: some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { on.toggle() } } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle().strokeBorder(on ? Theme.accent : .white.opacity(0.35), lineWidth: 1.5)
                    if on { Circle().fill(Theme.accent).padding(3.5).transition(.scale) }
                }
                .frame(width: 15, height: 15)
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(on ? Theme.accent.opacity(0.12) : Theme.surface))
            .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.35) : Theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct BigButton: ButtonStyle {
    let enabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .heavy, design: .rounded))
            .foregroundStyle(enabled ? Color(red: 0.1, green: 0.05, blue: 0.08) : .white.opacity(0.3))
            .frame(width: 240, height: 50)
            .background(Capsule().fill(enabled ? AnyShapeStyle(LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.82), Theme.pink], startPoint: .top, endPoint: .bottom))
                                               : AnyShapeStyle(Color.white.opacity(0.07))))
            .overlay(Capsule().strokeBorder(.white.opacity(enabled ? 0.35 : 0.06), lineWidth: 1))
            .shadow(color: enabled ? Theme.pink.opacity(configuration.isPressed ? 0.2 : 0.45) : .clear, radius: 18, y: 6)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .contentShape(Capsule())
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.25), value: enabled)
    }
}

struct LinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.9 : 0.55))
            .underline(true, color: .white.opacity(0.25))
            .contentShape(Rectangle())
    }
}

// MARK: - Confirmation

struct ConfirmView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).onTapGesture { cancel() }
            if let d = model.drive {
                VStack(spacing: 14) {
                    Mascot(mood: .worried, arms: .rest, size: 70)
                    Text("On efface « \(d.name) » ?").font(Theme.title(21)).multilineTextAlignment(.center)
                    Text(info(d)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Annuler") { cancel() }.buttonStyle(SoftButton()).keyboardShortcut(.cancelAction)
                        Button("Effacer et flasher") { model.confirmFlash() }.buttonStyle(SoftButton(danger: true)).keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 30).padding(.vertical, 24)
                .frame(width: 400)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.085)))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.line))
                .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
            }
        }
    }

    private func cancel() { withAnimation(.easeOut(duration: 0.2)) { model.confirming = false } }

    private func info(_ d: Drive) -> String {
        var s = "Tout ce qu'elle contient (\(d.size.bytes)) va disparaître"
        s += d.volumes.isEmpty ? "." : " : \(d.volumes.joined(separator: ", "))."
        if d.large { s += "\n\nElle fait plus de 128 Go : vérifie bien que ce n'est pas un disque de sauvegarde." }
        return s
    }
}

struct SoftButton: ButtonStyle {
    var danger = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(danger ? Color(red: 0.12, green: 0.04, blue: 0.08) : .white)
            .padding(.vertical, 10).frame(maxWidth: .infinity)
            .background(Capsule().fill(danger ? AnyShapeStyle(Theme.pink) : AnyShapeStyle(Color.white.opacity(0.1))))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Confettis

struct ConfettiView: View {
    struct Piece { let vx, vy, spin, w: Double; let color: Color }
    let start: Date
    let origin: CGPoint
    private static let pieces: [Piece] = (0..<70).map { i in
        let a = Double.random(in: -.pi * 0.95 ... -.pi * 0.05)
        let v = Double.random(in: 220...480)
        return Piece(vx: cos(a) * v, vy: sin(a) * v, spin: Double.random(in: -8...8), w: Double.random(in: 5...9),
                     color: [Theme.pink, Theme.lilac, Theme.accent, Theme.blue, Color.yellow][i % 5])
    }

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, _ in
                let t = tl.date.timeIntervalSince(start)
                for p in Self.pieces {
                    var c = ctx
                    c.translateBy(x: origin.x + p.vx * t, y: origin.y + p.vy * t + 420 * t * t)
                    c.rotate(by: .radians(p.spin * t))
                    c.fill(Path(roundedRect: CGRect(x: -p.w / 2, y: -p.w / 4, width: p.w, height: p.w / 2), cornerRadius: 1),
                           with: .color(p.color.opacity(max(0, 1 - t / 3))))
                }
            }
        }
    }
}
