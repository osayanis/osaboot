import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "OsaBoot"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.05, green: 0.045, blue: 0.07, alpha: 1)
        window.contentView = NSHostingView(rootView: ContentView(model: model, flasher: model.flasher))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("OsaBoot")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Updater.shared.canRelaunch = { [weak self] in self?.model.flasher.running != true }
        Updater.shared.startAutomaticChecks()
        let env = ProcessInfo.processInfo.environment
        if let img = env["OSABOOT_IMAGE"] { model.open(URL(fileURLWithPath: img)) }
        if let p = env["OSABOOT_PREVIEW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [model] in
                switch p {
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
    @objc private func pickDrive() { if !model.flasher.running { model.picking = true } }
}
