import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ContentView.size.width, height: ContentView.size.height),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "OsaBoot"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.035, green: 0.035, blue: 0.045, alpha: 1)
        // la vue SwiftUI dessine aussi sous la barre de titre : la fenêtre entière fait ContentView.size
        let host = NSHostingView(rootView: ContentView(model: model, flasher: model.flasher, drives: model.drives))
        host.sizingOptions = []
        window.contentView = host
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("OsaBoot")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Updater.shared.canRelaunch = { [weak self] in self?.model.flasher.running != true }
        Updater.shared.startAutomaticChecks()
        let env = ProcessInfo.processInfo.environment
        if let img = env["OSABOOT_IMAGE"] { model.open(URL(fileURLWithPath: img)) }
        if env["OSABOOT_DEMO"] != nil {
            model.demo = true
            model.image = SourceImage(url: URL(fileURLWithPath: "/Win11_25H2_French_x64.iso"), size: 7_340_000_000,
                                      kind: .windows(.init(label: "CCCOMA_X64FRE_FR-FR_DV9", install: "install.wim",
                                                           installSize: 6_210_000_000, totalSize: 7_290_000_000, arch: "x64")))
            model.drive = Drive(id: "demo", name: "SanDisk Ultra", size: 32_010_000_000, bus: "USB", volumes: ["CLÉ PERSO"], writable: true, virtual: false)
        }
        if let p = env["OSABOOT_PREVIEW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [model] in
                switch p {
                case "confirm": model.flash()
                case "working": model.flasher.preview(.running)
                case "done": model.flasher.preview(.done("Branche la clé sur le PC, allume-le et choisis-la au démarrage (F12, F11, F8 ou Échap selon la marque)."))
                case "failed": model.flasher.preview(.failed("La vérification a échoué : la clé ne contient pas exactement l'image. Elle est peut-être abîmée ou contrefaite."))
                default: break
                }
            }
        }
    }

    // une image glissée sur l'icône de l'app
    func application(_ app: NSApplication, open urls: [URL]) {
        if let u = urls.first { model.open(u) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard model.flasher.running else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "Une clé est en cours d'écriture"
        a.informativeText = "Si tu quittes maintenant, la clé sera inutilisable jusqu'au prochain flash."
        a.addButton(withTitle: "Continuer l'écriture")
        a.addButton(withTitle: "Quitter quand même")
        guard a.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.flasher.cancel()
        return .terminateNow
    }

    func windowShouldClose(_ w: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "À propos d'OsaBoot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Rechercher des mises à jour…", action: #selector(checkUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Masquer OsaBoot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quitter OsaBoot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "Fichier")
        file.addItem(withTitle: "Ouvrir une image…", action: #selector(openImage), keyEquivalent: "o").target = self
        file.addItem(withTitle: "Choisir la clé…", action: #selector(pickDrive), keyEquivalent: "k").target = self
        fileItem.submenu = file

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let win = NSMenu(title: "Fenêtre")
        win.addItem(withTitle: "Réduire", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = win
        NSApp.mainMenu = main
    }

    @objc private func checkUpdates() { Updater.shared.checkNow() }
    @objc private func openImage() { model.pickImage() }
    @objc private func pickDrive() { model.chooseDrive() }
}
