# DevWatch

Arbeitstitel für eine native macOS-App in Swift, die lokale Entwicklungsprozesse automatisch startet, sobald sich relevante Dateien in einem freigegebenen Projekt ändern.

## Projektidee

Bei der lokalen PHP- und Laravel-Entwicklung läuft Laravel Herd im Hintergrund und stellt die grundlegende Entwicklungsumgebung bereit. Die Arbeit am Code findet häufig ausschließlich über einen KI-Agenten im Terminal statt. Frontend-Prozesse wie `bun run dev` müssen bisher zusätzlich von Hand gestartet und im Blick behalten werden.

DevWatch soll diese Lücke schließen: Sobald ein Entwickler oder ein KI-Agent eine relevante Datei verändert, startet die App den zuvor freigegebenen Entwicklungsbefehl des Projekts. Eine kleine Oberfläche in der macOS-Menüleiste zeigt laufende Projekte und Fehler an und erlaubt manuelle Eingriffe.

Die App ergänzt Herd. Sie verwaltet in V1 weder PHP noch Datenbanken und benötigt keine Integration in einen bestimmten KI-Agenten.

## Vereinbarter Umfang für V1

- Native macOS-App mit Swift und SwiftUI, bedienbar über die Menüleiste.
- Lokale Verarbeitung; für die Kernfunktion sind weder Cloudkonto noch Backend erforderlich.
- Nutzer wählen einen oder mehrere Ordner mit ihren Entwicklungsprojekten aus.
- Projekte mit `package.json` und einem geeigneten Entwicklungsscript werden erkannt. Git-Worktrees sollen als eigenständige Arbeitsverzeichnisse berücksichtigt werden.
- Die App schlägt anhand von Scripts, `packageManager` und Lockfiles einen Befehl vor, beispielsweise `bun run dev`, `npm run dev`, `yarn run dev` oder `pnpm run dev`. Mehrdeutige Angaben werden angezeigt und können korrigiert werden.
- Autostart ist für neu erkannte Projekte standardmäßig eingeschaltet: Beim Entdecken wird der vorgeschlagene Befehl zusammen mit dem aktuellen Stand der `package.json` als Freigabe hinterlegt. Das Entdecken selbst führt noch keinen Code aus, die erste relevante Dateiänderung danach aber schon. Wer ein fremdes Repository in einen erfassten Stammordner klont, sollte dessen `dev`- beziehungsweise `build`-Script deshalb vorher lesen oder das Projekt ausblenden. Ein ausdrücklich pausiertes Projekt bleibt pausiert, und jede Änderung an Befehl oder `package.json` macht die Freigabe ungültig.
- Die erste relevante Dateiänderung startet den freigegebenen Befehl im jeweiligen Projektverzeichnis.
- Änderungen werden kurz gebündelt; als Ausgangswert ist etwa eine Sekunde vorgesehen.
- Ein bereits laufender Entwicklungsserver wird durch weitere Dateiänderungen nicht erneut gestartet. Das Nachladen übernimmt der Entwicklungsserver.
- Mehrere Projekte können gleichzeitig laufen.
- Menüaktionen: Start, Stop, Neustart, Logs anzeigen und Website öffnen, sofern eine URL bekannt ist.
- Nach 30 Minuten ohne relevante Dateiänderung wird ein laufender Entwicklungsprozess automatisch beendet. Jede erfasste Änderung setzt die Frist zurück; bei aktivem Autostart startet die nächste Änderung den Prozess wieder.
- Ein manueller Stopp pausiert den Autostart dieses Projekts bis zur ausdrücklichen Reaktivierung.
- Beim Beenden der App werden die von ihr gestarteten Prozesse einschließlich ihrer Kindprozesse sauber beendet.

`dev` und `build` sind unterschiedliche Aufgaben: Bei üblichen Vite-Projekten startet `dev` einen dauerhaften Entwicklungsserver, während `build` einmalig fertige Assets erzeugt. V1 konzentriert sich auf laufende Entwicklungsprozesse. Maßgeblich bleibt die tatsächliche Scriptdefinition des Projekts.

## Auslöser und Grenzen

Relevant sind Änderungen an Quellcode und Projektkonfiguration, ausdrücklich auch PHP- und Blade-Dateien. Erstellen, Ändern, Löschen und Umbenennen sollen berücksichtigt werden. Die genaue Filterlogik wird im Prototyp geprüft.

Ausgeschlossen werden insbesondere:

- Git-Metadaten in `.git`
- Abhängigkeiten in `node_modules` und `vendor`
- Logs, Caches und Laufzeitdaten, beispielsweise `storage` und `bootstrap/cache` bei Laravel
- Generierte Assets wie `public/build` und `dist`
- Laufzeitmarker wie Laravels `public/hot`
- Temporäre Dateien von Editoren und Betriebssystem

Das erstmalige Erfassen eines Ordners zählt nicht als Dateiänderung. Ausgaben eines gestarteten Prozesses dürfen keine Startschleife auslösen.

Ein `git pull` oder Branchwechsel kann relevante Dateien verändern und damit den Server starten. Das ist für aktivierte Projekte in V1 eine akzeptierte Grenze. Reines Lesen eines Projekts löst keinen Start aus; dafür bleibt der manuelle Start verfügbar.

Nicht vorgesehen sind eine Shell-Integration, das Erkennen eines Verzeichniswechsels im Terminal oder das Auslesen von Agentensitzungen. Der Inaktivitätstimer verwendet ausschließlich relevante Dateiänderungen: Reines Lesen im Terminal und die Nutzung im Browser verlängern die 30 Minuten nicht.

## Technischer Entwurf

Der folgende Aufbau ist ein erster Vorschlag, noch keine implementierte Architektur:

| Baustein | Aufgabe |
| --- | --- |
| SwiftUI-Oberfläche mit `MenuBarExtra` | Projektstatus, Aktionen, Einstellungen und Logs |
| Projektverwaltung | Ordner erfassen, Scripts erkennen, Befehle und Freigaben lokal speichern |
| Dateibeobachtung | Dateiereignisse empfangen, filtern und pro Projekt bündeln; FSEvents als Kandidat prüfen |
| Prozessverwaltung | Befehle im richtigen Arbeitsverzeichnis starten, Ausgabe erfassen und eigene Prozessbäume beenden |
| Zustandsverwaltung | Gleichzeitige Starts verhindern und Start, Bereitschaft, Fehler und Pause unterscheiden |

Sinnvolle Zustände sind: bereit für Autostart, startet, läuft, Fehler und pausiert. Die Freigabe des Projekts wird unabhängig vom Prozessstatus gespeichert.

Besonders zu prüfen sind die Auflösung von Bun-/Node-Pfaden und projektspezifischen Versionen: Eine aus dem Finder gestartete App hat nicht automatisch dieselbe Umgebung wie ein interaktives Terminal. Außerdem müssen Portkonflikte und bereits außerhalb der App gestartete Server sichtbar behandelt werden. Fremde Prozesse werden nicht automatisch beendet oder übernommen.

Ein gestarteter Prozess gilt nicht allein deshalb als erreichbarer Server. Für den ersten unterstützten Fall Laravel/Vite soll ein Bereitschaftscheck entwickelt werden. Bei unbekannten Scripts muss die Oberfläche zwischen laufendem Prozess und bestätigter Erreichbarkeit unterscheiden.

## Erste MVP-To-do-Liste

### 1. Native Grundlage und manueller Start

- [x] Mindestversion von macOS und lokalen Verteilungsweg festlegen (macOS 14+, App-Bundle).
- [x] Swift-/SwiftUI-Projekt mit Menüleiste und Projektfenster einschließlich Befehlseinstellung anlegen.
- [x] Ein Projektverzeichnis manuell auswählen und lokal speichern können.
- [x] Einen konfigurierten Befehl starten und dessen Ausgabe begrenzt puffern und anzeigen.
- [ ] Ausführbare Programme und die erforderliche Umgebung zuverlässig auflösen.
- [ ] Stoppen, Neustarten und Beenden einschließlich Kindprozessen umsetzen.

### 2. Automatik für ein Laravel-/Vite-Projekt

- [x] Relevante Dateiänderungen beobachten; initiale Erfassung ignorieren.
- [x] Ausschlüsse für Abhängigkeiten, Laufzeitdaten und Build-Ausgaben implementieren.
- [x] Ereignisse pro Projekt bündeln und parallele oder doppelte Starts verhindern.
- [x] Einmalige Projektfreigabe und manuelle Pause umsetzen.
- [ ] Bereitschaft, Startfehler und unerwartetes Prozessende sichtbar machen.
- [x] Nach einem Fehler den Autostart bis zum manuellen Wiederholen oder Reaktivieren pausieren; keine unendlichen Wiederholungen.

### 3. Mehrere Projekte und Erkennung

- [x] Ausgewählte Stammordner nach Git-Projekten und Worktrees durchsuchen, ohne Abhängigkeitsordner zu durchlaufen.
- [ ] `package.json`, `packageManager` und Lockfiles für Befehlsvorschläge auswerten.
- [ ] Fehlende Scripts, widersprüchliche Lockfiles und fehlende Abhängigkeiten verständlich anzeigen; keine automatische Installation.
- [ ] Mehrere Projekte und Git-Worktrees unabhängig verwalten.
- [x] Verschachtelte Projekte eindeutig zuordnen, damit nicht mehrere Server für dieselbe Änderung starten.
- [ ] Bereits laufende Server und Portkonflikte behandeln.
- [ ] Bekannte oder manuell hinterlegte Projekt-URLs öffnen können.
- [x] Geänderte Scriptdefinitionen erkennen und die Freigabe des Startbefehls erneut prüfen.

### 4. Prüfung im eigenen Alltag

- [ ] Dateiänderung durch einen KI-Agenten startet genau einen Server.
- [ ] Viele schnelle Änderungen lösen keine doppelten Starts aus.
- [ ] Änderungen in ausgeschlossenen Ordnern sowie die initiale Erfassung starten nichts.
- [ ] PHP- und Blade-Änderungen lösen den Start korrekt aus.
- [ ] Manueller Stopp bleibt trotz weiterer Änderungen wirksam.
- [ ] Fehlendes Bun/Node, belegter Port und abstürzender Prozess liefern nachvollziehbare Fehler.
- [ ] Bereits extern gestartete Server werden nicht versehentlich beendet.
- [ ] Zwei gleichzeitig bearbeitete Projekte funktionieren unabhängig voneinander.
- [ ] App-Beendigung hinterlässt keine von ihr gestarteten Entwicklungsserver.
- [ ] Neustart der App, Ruhezustand und verschobene oder entfernte Projektordner prüfen.
- [ ] CPU-Auslastung und Ereignisaufkommen mit realen Repositorys beobachten.

Der erste vertikale Prototyp ist bewusst klein: ein ausgewähltes Laravel-/Vite-Projekt, ein bestätigter Befehl, eine relevante Dateiänderung und ein sichtbarer, sauber stoppbarer Prozess. Danach folgen Erkennung und mehrere Projekte.

## Spätere Möglichkeiten

- Weitere Prozesse pro Projekt, etwa Queue-Worker oder Laravel Reverb.
- Projektprofile und konfigurierbare Ausschlüsse.
- Optionaler Start beim Anmelden am Mac.
- Konfigurierbare Dauer für den automatischen Stopp und zusätzliche Nutzungssignale.
- Unterstützung weiterer Webentwicklungs-Stacks.

## Produktperspektive

Das mögliche Produktversprechen lautet: „Du arbeitest am Projekt. Deine Entwicklungsprozesse starten automatisch.“

Zunächst ist eine lokal arbeitende, kostenpflichtige Mac-App plausibler als ein SaaS mit Cloudbetrieb. Kaufmodell, bezahlte Updates oder ein Abonnement sind offene Geschäftsentscheidungen. Zahlungsbereitschaft und Abgrenzung zu bestehenden Werkzeugen müssen erst mit Nutzern geprüft werden. Der MVP soll zunächst den eigenen Entwicklungsalltag zuverlässig verbessern.

## Aktueller Entwicklungsstand

Implementiert sind SwiftUI-Menüleiste und Projektfenster, Projektauswahl und lokale Speicherung, automatische Erkennung von Bun, Yarn, npm und pnpm, editierbarer Programmpfad, Start/Stop und Live-Logs. Ein FSEvents-Dateiwächter startet freigegebene Projekte bei relevanten Änderungen. Die verbleibenden Punkte der MVP-Liste beschreiben die nächsten Ausbauschritte.

Voraussetzung: macOS 14 oder neuer und zum Bauen eine Swift-6-Toolchain, beispielsweise über Xcode. Das Projekt nutzt Swift Package Manager ohne externe Abhängigkeiten und ist über `Package.swift` in Xcode zu öffnen. Die Quellen werden zunächst im Swift-5-Sprachmodus kompiliert.

### Entwickeln und testen

```sh
swift run DevWatch
swift test
```

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

Das erzeugt `build/DevWatch.dmg` mit dem App-Bundle und einer Verknüpfung auf `/Applications`, sodass die App im geöffneten DMG per Drag-and-drop installiert wird. Der Ablauf signiert mit Developer ID und Hardened Runtime, notarisiert erst die App und nach dem Packen das DMG bei Apple und heftet beide Tickets an („stapling“). Dadurch startet auch eine aus dem DMG gezogene Kopie ohne Gatekeeper-Dialog und ohne Internetverbindung.

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

### Update-Hinweis in der App

Die App fragt beim Start und danach einmal täglich die in `Support/Info.plist` unter `DWReleaseFeedURL` hinterlegte GitHub-Adresse nach dem neuesten Release. Ist dessen Tag höher als die eigene Version, erscheint im Menüleisten-Menü und in den Einstellungen ein Verweis auf die Release-Seite; heruntergeladen und ersetzt wird die App weiterhin von Hand.

Die Prüfung ist absichtlich stumm, wenn sie scheitert: Ohne Netz, bei erreichtem API-Limit oder solange das Repository privat ist (die API antwortet dann mit 404), passiert schlicht nichts. Deshalb wird auch kein „Version ist aktuell“ angezeigt — eine gescheiterte Prüfung wäre davon nicht zu unterscheiden. Wer das Projekt forkt, trägt seine eigene Adresse ein oder entfernt den Schlüssel, um die Prüfung abzuschalten.

### Erste Verwendung

1. Über das Ordnersymbol links unten „Ordner hinzufügen …“ öffnen und beispielsweise `~/gits` wählen. Git-Repositories und Worktrees werden rekursiv gefunden. Alternativ im Menü der Ordnerverwaltung ein einzelnes Webprojekt hinzufügen.
2. Ein Projekt in der durchsuchbaren Liste auswählen. Einstellungen und Ausgaben stehen bei Bedarf unter „Details & Logs“.
3. Falls erforderlich den Programmnamen durch einen absoluten Pfad ersetzen und speichern.
4. Autostart ist für neu erkannte, gültige Projekte standardmäßig eingeschaltet. Bisher unentschiedene Projekte werden beim App-Start ebenfalls freigegeben; bewusst pausierte Projekte bleiben pausiert. Die Freigabe speichert den aktuellen Befehl und Manifeststand. Erst die nächste relevante Dateiänderung startet den Prozess.
5. Alternativ im Projektfenster den Schalter „Autostart“ einschalten: Dort startet die Freigabe allein nichts; erst eine folgende Dateiänderung startet den Prozess. „Starten“ bleibt als manuelle Aktion verfügbar.
6. Mit „Stoppen“ beenden und den Autostart pausieren. Eine Pause bleibt über App-Neustarts erhalten. „Autostart pausieren“ lässt einen bereits laufenden Prozess weiterlaufen.
7. Zum Fortsetzen erneut freigeben. Das Schließen des Fensters lässt die App in der Menüleiste weiterlaufen; „DevWatch beenden“ beendet Beobachtung und Prozesse, ohne eine zuvor aktive Freigabe zu pausieren.

Die Projektliste liegt unter `~/Library/Application Support/DevWatch/projects.json`; Stammordner und ausgeblendete Pfade werden daneben in `roots.json` gespeichert. Logs bleiben im Arbeitsspeicher. Das Entfernen eines Projekts aus der Liste löscht keine Projektdateien.

Der Aktivitätshinweis wird pro Projekt höchstens einmal pro App-Sitzung automatisch geöffnet. „Später“ oder Wegklicken verwirft den sichtbaren Hinweis; weitere Dateiänderungen öffnen ihn nicht erneut. Bewusst pausierte Projekte erhalten keinen Hinweis. Vor dem Ein-Klick-Start wird geprüft, ob Befehl und Manifest noch dem angezeigten Stand entsprechen.

Das Menüleisten-Icon zeigt unten rechts einen grünen Punkt, wenn mindestens ein Entwicklungsprozess läuft, oder einen orangefarbenen Punkt während der Projektsuche. Laufende Prozesse haben Vorrang vor der Suchanzeige. Ohne laufenden Prozess und ohne Suche bleibt das Icon neutral. Grün bestätigt den Prozessstatus, nicht die Erreichbarkeit des Entwicklungsservers.

Geprüft am 8. September 2026: Debug- und Release-Build erfolgreich, 55 Tests bestanden. In der gebauten App wurden Projektauswahl, Speicherung über einen App-Neustart, manueller Start, Live-Ausgabe, Stoppen, Beenden mit laufendem Prozess und Entfernen des Testeintrags geprüft. Zusätzlich wurden die Autostart-Freigabe mit Script-Vorschau, der automatische Start nach PHP-Dateiänderung und die wirksame Pause nach manuellem Stoppen in der App geprüft. Die Tests decken alle vier Paketmanager, Freigabeänderungen, FSEvents, rekursive Repository-Suche, Worktree-Marker, überlappende Suchordner, fehlende Frontend-Konfiguration Stammordner-Persistenz sowie Ablauf und Zurücksetzen des Inaktivitätstimers ab. Die Stammordnerauswahl und die Anzeige realer Repositories wurden zusätzlich in der App geprüft. Der Aktivitätshinweis am Menüleisten-Icon und der anschließende Start wurden mit einem isolierten Bun-Testprojekt geprüft. Hierfür wurde ein isoliertes Bun-Testprojekt verwendet; die Integration mit einem realen Laravel-/Vite-Projekt steht noch aus.

### Bekannte Grenzen dieses ersten Schritts

- Der Entwicklungsbefehl verwendet `run dev` oder als Alternative `run build`; der Programmname beziehungsweise Programmpfad ist editierbar.
- Stammordner werden beim App-Start, auf Knopfdruck und alle 30 Sekunden im Hintergrund geprüft. Git-Projekte ohne erkannten `dev`- oder `build`-Befehl werden aus der Projektliste ausgeblendet.
- Verschachtelte Git-Repositories, Worktree-/Submodul-Verweise per `.git`-Datei und überlappende Stammordner werden berücksichtigt. Symlink-Unterverzeichnisse sowie Abhängigkeits-, Build- und Cache-Ordner werden übersprungen; bare Git-Repositories ohne `.git`-Marker werden nicht erkannt.
- Bestehende Projektbefehle, IDs und Freigaben bleiben beim Scan erhalten. Das Entfernen eines Stammordners beendet dessen Scans und behält bereits übernommene startbare Projekte. „Details & Logs“ → „Ausblenden …“ verhindert, dass ein Eintrag beim nächsten Scan erneut erscheint; Das Menü der Ordnerverwaltung kann ausgeblendete Projekte wieder anzeigen.
- Registrierte verschachtelte Projekte werden dem jeweils tieferen Projekt zugeordnet. Nicht lesbare Suchordner oder Einträge werden als Warnung angezeigt.
- Die Erkennung bevorzugt `packageManager`; ohne diese Angabe werden `bun.lock`/`bun.lockb`, `yarn.lock`, `package-lock.json`/`npm-shrinkwrap.json` und `pnpm-lock.yaml` geprüft. Mehrere unterschiedliche Manager führen zu einem Hinweis. Ohne Angaben wird npm vorgeschlagen. Die Installation von Abhängigkeiten erfolgt nicht automatisch.
- Jede Änderung an `package.json` erfordert eine neue Freigabe, auch eine reine Formatierungsänderung. Die Prüfung erfolgt vor jedem automatischen Start und beim erneuten Beobachten nach einem App-Neustart. Veränderte Quellcodedateien benötigen keine neue Freigabe.
- Symlink-Ziele außerhalb des Projektordners werden nicht beobachtet. Verschobene/entfernte Projektwurzeln oder verlorene Dateiereignisse pausieren die Beobachtung; anschließend muss das Projekt geprüft und erneut freigegeben werden.
- Es gibt noch keinen automatischen Neustart, keine URL-Erkennung und keinen Bereitschaftscheck. „Prozess läuft“ bestätigt nicht die Erreichbarkeit der Website.
- Eine aus dem Finder gestartete App erbt nur den minimalen System-`PATH`. DevWatch fragt deshalb beim Start einmalig die Login-Shell (`$SHELL -l`) nach ihrem `PATH` und stellt ihn voran; damit werden auch nvm, fnm, Volta, mise und asdf gefunden. Ergänzt werden anschließend übliche Bun-, Homebrew- und Herd-Pfade. Antwortet die Shell nicht innerhalb von drei Sekunden, wird sie beendet und nur die bekannten Pfade verwendet. Projektspezifische Node-Versionen per `.nvmrc` werden weiterhin nicht ausgewertet; der Herd-NVM-Fallback greift nur bei einer installierten Version.
- Bereits extern gestartete Server werden weder erkannt noch übernommen. Portkonflikte erscheinen über die Ausgabe des gestarteten Werkzeugs.
- Eigene Prozessgruppen werden beim Stoppen und regulären App-Beenden aufgeräumt. Bewusst daemonisierte Prozesse, die ihre Prozessgruppe verlassen, und ein erzwungenes Beenden der App sind nicht abgedeckt.

### Implementierungsquellen

- [Apple: MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) für die native Menüleiste.
- [Apple: Swift Package Targets](https://developer.apple.com/documentation/PackageDescription/Target) für die Aufteilung in App, Kernmodul und Tests.

Die Oberfläche ist bewusst reduziert: Projektname, Status, Autostart-Schalter und ein gemeinsamer Start-/Stopp-Knopf. Logs, Pfade und Befehlseinstellungen sind standardmäßig eingeklappt. Das Menüleisten-Popup zeigt direkt nur Projekt, Befehl und Freigabeaktion; technische Angaben stehen unter „Details“. Hauptansicht, Detailbereich und Ordnerverwaltung wurden nach dem Umbau im Release-Build visuell geprüft.

Der Inaktivitätstimer beginnt bei jedem erfolgreichen Prozessstart und läuft 30 Minuten ab der letzten erfassten relevanten Dateiänderung. Ausgeschlossene Logs, Build-Dateien und Änderungen in registrierten Unterprojekten verlängern ihn nicht. Die geplante Stoppzeit steht unter „Details & Logs“. Ein automatischer Stopp erhält die bestehende Freigabe; manuelles Stoppen bleibt eine bewusste Pause. Auch manuell gestartete Prozesse haben den Timer. Der Timer zählt Ruhezustand mit und wird beim regulären App-Beenden verworfen. Die Timer-Integration wurde mit verkürzten Fristen an isolierten Prozessen geprüft.

Projekte mit `build`-Script werden ebenfalls erkannt: `dev` hat Vorrang, andernfalls wird `run build` vorgeschlagen. Der erkannte Befehl steht direkt unter dem Projektnamen. Ein erfolgreicher Build behält die Autostart-Freigabe und wird bei der nächsten relevanten Dateiänderung erneut ausgeführt; ein fehlgeschlagener Build pausiert den Autostart. Die Vorschau berücksichtigt die zum gewählten Script gehörenden Lifecycle-Scripts.

Das Menüleisten-Popup zeigt pro verwendetem Projekt eine Zeile mit Script-Labels aus `package.json`. Ein Klick startet das jeweilige Script oder stoppt dessen laufenden Prozess. Zusätzliche Scripts laufen unabhängig vom freigegebenen Standardbefehl und werden ausschließlich manuell gestartet. Ein grüner Punkt steht für einen laufenden Prozess, ein grüner Haken für Exit-Code 0, ein rotes Kreuz für einen Fehler; manuelles Stoppen bleibt neutral. Ergebnisse bleiben für die App-Sitzung sichtbar. Ob ein Script dauerhaft läuft oder einmalig endet, ergibt sich aus seinem tatsächlichen Prozesszustand, nicht aus seinem Namen. Auch zusätzliche laufende Scripts werden beim App-Beenden und mit „Alle stoppen“ beendet.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
