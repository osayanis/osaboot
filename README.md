# OsaBoot

Une image, une clé USB, et c'est parti. **Même pour Windows.**

OsaBoot fait ce que fait balenaEtcher (copier une image `.iso` ou `.img` sur une clé et vérifier le résultat), et sait en plus préparer une **clé d'installation Windows** à partir d'une ISO officielle, ce qu'Etcher ne fait pas. App macOS native en SwiftUI, de la famille [OsaLabs](https://osalabs.fr).

> **Statut : en test.** Écriture brute (avec mot de passe via authopen et vérification SHA-256) et préparation d’une clé Windows vérifiées sur une vraie clé USB. Reste à démarrer un vrai PC sur une vraie ISO Windows. Pas encore de version téléchargeable.

## Ce que ça fait

1. **Choisir une image** (bouton ou glisser-déposer) : `.iso`, `.img`, `.raw`, `.bin`. OsaBoot reconnaît tout seul un installateur Windows.
2. **Choisir la clé** : seuls les disques externes sont proposés. Le disque du Mac et les images disque montées n'apparaissent jamais. Une seule clé branchée ? Elle est choisie d'office.
3. **Flasher** : une confirmation qui nomme la clé et ses volumes, puis l'écriture avec le pourcentage, la vitesse et le temps restant. Le Mac ne se met pas en veille pendant ce temps.

### Images Linux, Raspberry Pi, outils…
Copiées octet par octet sur la clé (comme Etcher), puis **relues et comparées** par empreinte SHA-256. L'accès en écriture à la clé passe par `authopen` : macOS demande le mot de passe administrateur dans sa propre fenêtre, l'app ne tourne jamais en root.

### ISO Windows 10 / 11
Une ISO Windows ne démarre pas si on la copie telle quelle. OsaBoot :
1. formate la clé en **FAT32 / MBR**, lisible au démarrage par tous les PC en UEFI ;
2. copie les fichiers de l'ISO ;
3. découpe `install.wim` s'il dépasse 4 Go (limite de FAT32) en `install.swm`, `install2.swm`…, que l'installateur de Windows réunit tout seul ;
4. en option, ajoute un `autounattend.xml` qui permet d'installer **Windows 11 sur un PC sans TPM 2.0 ni Secure Boot** (mêmes clés `LabConfig` que Rufus).

Les PC en BIOS ancien (sans UEFI) ne sont pas pris en charge pour Windows.

## Sécurité
- Jamais de disque interne, jamais le disque de démarrage, jamais une image disque montée (coffres chiffrés, simulateurs…).
- Juste avant d'effacer, la clé est relue : si elle a changé (débranchée, autre numéro), on s'arrête.
- Si une ISO Windows a besoin d'être découpée et que l'outil manque, OsaBoot refuse **avant** de toucher à la clé.

## Compiler

```bash
./scripts/build-wimlib.sh   # une fois : compile wimlib-imagex dans vendor/ (source officielle vérifiée)
./build.sh                  # OsaBoot.app
```

Sans `vendor/wimlib-imagex`, l'app utilise celui de Homebrew s'il existe (`brew install wimlib`).

## Tests sans vraie clé

Une ligne de commande reprend la même mécanique. `flash` n'accepte **que** des images disque nommées dans `OSABOOT_TEST_DISKS` :

```bash
D=$(diskutil image attach --noMount ram://204800)      # disque de 100 Mo en mémoire
B=OsaBoot.app/Contents/MacOS/OsaBoot
$B inspect ubuntu.iso
OSABOOT_TEST_DISKS=${D#/dev/} $B flash test.img ${D#/dev/} --no-eject
OSABOOT_TEST_DISKS=${D#/dev/} OSABOOT_SPLIT_AT=10000000 $B flash win.iso ${D#/dev/}   # force la découpe
```

`OSABOOT_TEST_DISKS=disk14 OSABOOT_IMAGE=win.iso open OsaBoot.app` ouvre l'interface en mode test. `OSABOOT_PREVIEW=confirm|working|done|failed` affiche directement un état (captures d'écran).

## Licences
Le code d'OsaBoot est public. L'app embarque **wimlib-imagex** ([wimlib](https://wimlib.net), GPLv3, © Eric Biggers), lancé comme programme séparé ; sa licence est copiée dans l'app (`Contents/Resources/wimlib-LICENCE-GPLv3.txt`) et sa source est sur wimlib.net.
