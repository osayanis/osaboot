import Foundation

// autounattend.xml posé à la racine de la clé : l'installateur de Windows le lit tout seul.
// Il ajoute les clés « LabConfig » qui sautent les vérifications de Windows 11 (TPM 2.0,
// Secure Boot, 4 Go de RAM), comme le fait Rufus. Le reste de l'installation reste normal.
enum Unattend {
    static var bypassChecks: String {
        let commands = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck"].enumerated().map { i, key in
            """
                    <RunSynchronousCommand wcm:action="add">
                      <Order>\(i + 1)</Order>
                      <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \(key) /t REG_DWORD /d 1 /f</Path>
                    </RunSynchronousCommand>
            """
        }.joined(separator: "\n")
        // un composant par architecture : l'installateur ne lit que celui qui le concerne
        let components = ["amd64", "arm64"].map { arch in
            """
                <component name="Microsoft-Windows-Setup" processorArchitecture="\(arch)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
                  <RunSynchronous>
            \(commands)
                  </RunSynchronous>
                </component>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <settings pass="windowsPE">
        \(components)
          </settings>
        </unattend>

        """
    }
}
