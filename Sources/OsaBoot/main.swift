import AppKit

// `OsaBoot inspect <image>`, `OsaBoot drives` et `OsaBoot flash <image> <diskN>` : la même
// mécanique sans interface, pour les tests. `flash` n'accepte que les images disque nommées
// dans OSABOOT_TEST_DISKS, jamais une vraie clé.
let args = CommandLine.arguments
if args.count > 1, let code = CLI.run(Array(args.dropFirst())) {
    exit(code)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
