<p align="center">
  <img src="Support/Brand/devwatch-logo.png" alt="DevWatch App-Logo" width="180" />
</p>

# DevWatch

**Du arbeitest am Projekt. Deine Entwicklungsprozesse starten automatisch.**

DevWatch ist eine kostenlose, quelloffene macOS-App für die Menüleiste. Sie beobachtet deine lokalen Webprojekte und startet bei relevanten Dateiänderungen den passenden Entwicklungsbefehl – etwa `bun run dev`. Laufende Scripts, Status und Logs behältst du direkt in der App im Blick.

Praktisch für die Arbeit mit Laravel, Vite und KI-Coding-Assistenten: Ob du selbst oder ein Agent eine Datei änderst, spielt keine Rolle. DevWatch ergänzt Werkzeuge wie Laravel Herd und funktioniert ohne Integration in einen bestimmten Editor oder Agenten.

**[DevWatch 1.0.0 herunterladen](https://github.com/twdnhfr/devwatch/releases/download/v1.0.0/DevWatch-1.0.0.dmg)** · [Alle Releases](https://github.com/twdnhfr/devwatch/releases) · [Fehler melden](https://github.com/twdnhfr/devwatch/issues)

macOS 14 oder neuer · Apple Silicon und Intel · MIT-Lizenz

## Installation

1. Das DMG herunterladen und öffnen.
2. **DevWatch** in den Ordner **Programme** ziehen und starten.
3. Über das Menüleisten-Icon das Projektfenster öffnen und einen Projektordner hinzufügen.

Die benötigten Entwicklungswerkzeuge wie Bun oder Node.js sowie die Projektabhängigkeiten müssen bereits installiert sein. DevWatch installiert sie nicht selbst.

## Funktionen

- **Automatischer Start bei Dateiänderungen:** Startet das erkannte `dev`-Script, alternativ `build`. Ein bereits laufender Prozess wird durch weitere Änderungen nicht doppelt gestartet.
- **Projekte automatisch finden:** Durchsucht ausgewählte Stammordner nach Git-Repositories und Worktrees mit einem passenden `package.json`-Script. Einzelne Webprojekte lassen sich auch direkt hinzufügen.
- **Bun, npm, Yarn und pnpm:** Erkennt den Paketmanager anhand von `packageManager` und Lockfiles. Der Programmname oder Programmpfad lässt sich anpassen.
- **Scripts direkt in der Menüleiste:** Weitere Scripts aus `package.json`, etwa `lint` oder `test`, lassen sich unabhängig vom Standardbefehl manuell starten und stoppen.
- **Mehrere Projekte gleichzeitig:** Kompakte Projektübersicht mit Prozessstatus, Script-Ergebnissen und Live-Logs.
- **Automatischer Stopp nach 30 Minuten:** Ohne relevante Dateiänderung wird der Standardprozess beendet. Bei aktivem Autostart startet ihn die nächste Änderung wieder.
- **Kontrolle pro Projekt:** Starten, stoppen, Autostart pausieren und Projekte ausblenden. Bewusste Pausen bleiben über App-Neustarts erhalten.
- **Start beim Anmelden und Update-Hinweise:** Optional mit macOS starten und auf neue GitHub-Releases hingewiesen werden.

## Erste Schritte

1. Über **„Ordner hinzufügen …“** beispielsweise `~/gits` auswählen. DevWatch findet passende Projekte rekursiv und prüft die Stammordner regelmäßig erneut.
2. Den erkannten Befehl kontrollieren. Unter **„Details & Logs“** findest du Einstellungen und Prozessausgaben.
3. Eine Quelldatei ändern: Bei aktivem Autostart läuft der Entwicklungsbefehl automatisch an. **„Starten“** steht auch manuell zur Verfügung.
4. Mit **„Stoppen“** den Prozess beenden und den Autostart pausieren. Zum Fortsetzen den Autostart wieder einschalten.

**Autostart ist für neu erkannte, gültige Projekte standardmäßig eingeschaltet.** Das Hinzufügen allein startet noch keinen Prozess; die nächste relevante Dateiänderung führt den erkannten Befehl aus. Prüfe deshalb die Scripts fremder Repositories, bevor du sie in einen beobachteten Stammordner aufnimmst. Änderungen am Befehl oder an `package.json` erfordern eine erneute Freigabe.

Das Schließen des Fensters lässt DevWatch in der Menüleiste weiterlaufen. Beim regulären Beenden der App werden die von ihr gestarteten Prozesse einschließlich ihrer Kindprozesse innerhalb der eigenen Prozessgruppen beendet.

## Welche Änderungen zählen?

DevWatch reagiert auf Änderungen an Quellcode und Projektkonfiguration, einschließlich PHP- und Blade-Dateien. Ausgeschlossen sind unter anderem:

- Git-Metadaten und Abhängigkeiten: `.git`, `node_modules`, `vendor`
- Laufzeitdaten und Caches: etwa `storage` und `bootstrap/cache`
- Generierte Assets: etwa `public/build` und `dist`
- Laufzeitmarker wie `public/hot` sowie temporäre Editor- und Systemdateien

Die erstmalige Erfassung eines Ordners löst keinen Start aus. Ein `git pull` oder Branchwechsel kann dagegen relevante Dateien verändern und damit einen Prozess starten.

Der Inaktivitätstimer berücksichtigt ausschließlich relevante Dateiänderungen. Lesen im Editor oder Terminal und die Nutzung der Website im Browser verlängern die 30 Minuten nicht.

## Lokale Daten und Updates

Projektverwaltung und Dateibeobachtung arbeiten lokal und benötigen kein Konto. Projekte, Stammordner und ausgeblendete Pfade werden unter `~/Library/Application Support/DevWatch/` gespeichert. Logs bleiben im Arbeitsspeicher. Das Entfernen eines Projekts aus der App löscht keine Projektdateien.

Für Update-Hinweise fragt DevWatch beim Start und anschließend einmal täglich die GitHub-API nach dem neuesten Release. Der Hinweis öffnet die Release-Seite; Download und Installation erfolgen manuell. Eine fehlgeschlagene Prüfung bleibt ohne Fehlermeldung. Die gestarteten Projektscripts können unabhängig davon eigene Netzwerkverbindungen aufbauen.

## Bekannte Grenzen

- Der automatische Standardbefehl ist `run dev` oder alternativ `run build`. Weitere Scripts werden manuell gestartet. Ein erfolgreicher Build bleibt für die nächste Änderung freigegeben; ein Fehler pausiert den Autostart.
- „Prozess läuft“ bestätigt keine erreichbare Website. Es gibt keinen Bereitschaftscheck und keine automatische URL-Erkennung.
- Bereits außerhalb von DevWatch gestartete Server werden weder erkannt noch übernommen. Portkonflikte erscheinen in der Ausgabe des gestarteten Werkzeugs.
- DevWatch ergänzt den Suchpfad um die Login-Shell und übliche Werkzeugpfade. Projektspezifische Node-Versionen über `.nvmrc` werden nicht automatisch ausgewählt. Bei Bedarf lässt sich ein absoluter Programmpfad hinterlegen.
- Symlink-Unterverzeichnisse werden bei der Projektsuche übersprungen; Ziele außerhalb des Projektordners werden nicht beobachtet. Verschobene oder entfernte Projektwurzeln und verlorene Dateiereignisse erfordern eine erneute Prüfung und Freigabe.
- Bewusst daemonisierte Prozesse, die ihre Prozessgruppe verlassen, sowie ein erzwungenes Beenden von DevWatch sind vom regulären Aufräumen der Prozesse nicht abgedeckt.

## Entwicklung

DevWatch nutzt Swift, SwiftUI und FSEvents. Das Projekt verwendet Swift Package Manager ohne externe Paketabhängigkeiten. Benötigt werden macOS 14 oder neuer und eine Swift-6-Toolchain; kompiliert wird im Swift-5-Sprachmodus.

```sh
git clone https://github.com/twdnhfr/devwatch.git
cd devwatch
swift run DevWatch
swift test
```

Alternativ `Package.swift` in Xcode öffnen. App-Bundle, DMG, Signierung, Notarisierung und Veröffentlichung sind in der **[Build- und Release-Anleitung](docs/RELEASE.md)** beschrieben.

Bei einem Fork kann `DWReleaseFeedURL` in `Support/Info.plist` auf das eigene Repository zeigen oder entfernt werden, um die Update-Prüfung abzuschalten.

## Mitmachen

Fehlerberichte und Verbesserungsvorschläge sind über [GitHub Issues](https://github.com/twdnhfr/devwatch/issues) willkommen, ebenso Pull Requests. Bei Fehlern helfen die macOS-Version, der verwendete Paketmanager, Schritte zum Nachstellen und relevante Logauszüge ohne vertrauliche Daten.

## Lizenz

DevWatch ist Open Source unter der [MIT-Lizenz](LICENSE).
