# DevWatch bauen und veröffentlichen

Die folgenden Befehle werden im Repository-Verzeichnis ausgeführt. Zum Bauen werden macOS und eine Swift-6-Toolchain benötigt.

### Als Mac-App bauen

```sh
bash scripts/build-app.sh            # App-Bundle nach build/DevWatch.app
bash scripts/build-app.sh install    # zusätzlich nach /Applications kopieren und starten
open build/DevWatch.app
```

Das Script erzeugt ein Release-App-Bundle als Universal Binary für Apple Silicon und Intel (`--arch arm64 --arch x86_64`). Signiert wird mit der ersten „Developer ID Application“ aus dem Schlüsselbund, ersatzweise ad-hoc. Eine gleichbleibende Signatur ist wichtig, weil macOS die einmal erteilten Ordner-Berechtigungen an sie bindet. Die App läuft außerhalb der App Sandbox, damit sie lokale Entwicklungswerkzeuge starten kann.

### Installierbares DMG bauen

```sh
bash scripts/build-app.sh release
```

Das erzeugt `build/DevWatch.dmg` mit dem App-Bundle und einer Verknüpfung auf `/Applications`, sodass die App im geöffneten DMG per Drag-and-drop installiert wird. Der Ablauf signiert mit Developer ID und Hardened Runtime, notarisiert erst die App und nach dem Packen das DMG bei Apple und heftet beide Tickets an („stapling“). Die angehefteten Tickets ermöglichen macOS die Prüfung der Notarisierung auch ohne Internetverbindung.

Die dafür nötigen Angaben stehen in `scripts/release.env`. Diese Datei ist bewusst nicht eingecheckt, weil sie auf jedem Rechner anders aussieht:

```sh
cp scripts/release.env.example scripts/release.env
```

| Einstellung | Bedeutung |
| --- | --- |
| `NOTARY_PROFILE` | Name des `notarytool`-Keychain-Profils. Einmalig anlegen mit `xcrun notarytool store-credentials <name> --apple-id <mail> --team-id <TEAMID>`; abgefragt wird ein app-spezifisches Passwort von appleid.apple.com. Ohne diese Angabe bricht der Release-Lauf mit einem Hinweis ab, statt ein fremdes Profil zu raten. |
| `SIGN_IDENTITY` | Zu verwendende Signatur, zum Beispiel `Developer ID Application: … (TEAMID)`. Ohne Angabe wird die erste passende Identität aus dem Schlüsselbund genommen, siehe `security find-identity -v -p codesigning`. |
| `SKIP_NOTARIZE=1` | Nur signieren und DMG bauen, ohne Apple-Notarisierung. Für schnelle lokale Durchläufe; das Ergebnis ist nicht zur Weitergabe geeignet. |

Jede dieser Einstellungen lässt sich auch als Umgebungsvariable übergeben und hat dann Vorrang vor der Datei: `SKIP_NOTARIZE=1 ./scripts/build-app.sh release`. `DEVWATCH_RELEASE_ENV` wählt eine andere Konfigurationsdatei aus. Die Datei wird gelesen, nicht ausgeführt; unbekannte Schlüssel werden mit einer Warnung übergangen.

### Als GitHub-Release veröffentlichen

```sh
bash scripts/build-app.sh publish
```

Das nimmt das bereits gebaute DMG, legt den Tag `v<Version>` an, schiebt ihn zu `origin` und erzeugt daraus ein GitHub-Release mit dem DMG als Asset. Der Assetname enthält die Version, die Release-Notizen entstehen aus den Commits seit dem letzten Tag.

Bewusst wird dabei nichts neu gebaut: Ein Neubau würde das notarisierte und gestapelte Bundle verwerfen. Der Schritt bricht deshalb vorher ab, wenn das DMG fehlt oder kein gültiges Notarisierungsticket trägt, das Arbeitsverzeichnis nicht sauber ist, `HEAD` noch nicht gepusht wurde oder es den Tag schon gibt. Für eine neue Version wird die Nummer in `Support/Info.plist` erhöht, dann `release` und anschließend `publish` ausgeführt.


[Zurück zur README](../README.md)
