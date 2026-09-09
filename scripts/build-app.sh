#!/bin/bash
# Baut DevWatch.app und auf Wunsch ein installierbares DMG.
#
#   ./scripts/build-app.sh            App-Bundle nach build/DevWatch.app
#   ./scripts/build-app.sh install    zusätzlich nach /Applications kopieren und starten
#   ./scripts/build-app.sh release    Developer-ID-Signatur mit Hardened Runtime,
#                                     Notarisierung, Stapling und DMG mit
#                                     Applications-Verknüpfung zum Hineinziehen
#
# Einstellungen für release stehen in scripts/release.env (nicht im Repository,
# Vorlage: scripts/release.env.example). Eine bereits gesetzte Umgebungsvariable
# hat Vorrang vor der Datei. DEVWATCH_RELEASE_ENV wählt eine andere Datei aus.
#
#   SIGN_IDENTITY    "Developer ID Application: … (TEAMID)"; ohne Angabe wird die
#                    erste passende Identität aus dem Schlüsselbund genommen
#   NOTARY_PROFILE   Name des notarytool-Keychain-Profils; ohne Angabe bricht der
#                    Release-Lauf mit einer Anleitung ab
#   SKIP_NOTARIZE=1  nur signieren und DMG bauen, ohne Apple-Notarisierung
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-app}"

# Bewusst kein "source": die Datei wird gelesen, nicht ausgeführt.
load_release_config() {
    local file="$1" line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in ''|'#'*) continue ;; esac
        line="${line#export }"
        key="${line%%=*}"
        if [ "$key" = "$line" ]; then
            printf '%s: Zeile ohne "=" übersprungen: %s\n' "$file" "$line" >&2
            continue
        fi
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac
        case "$key" in
            SIGN_IDENTITY|NOTARY_PROFILE|SKIP_NOTARIZE) ;;
            *)
                printf '%s: unbekannter Schlüssel %s wird ignoriert\n' "$file" "$key" >&2
                continue
                ;;
        esac
        [ -n "${!key+set}" ] || export "$key=$value"
    done < "$file"
}

release_config="${DEVWATCH_RELEASE_ENV:-$PWD/scripts/release.env}"
[ -f "$release_config" ] && load_release_config "$release_config"
app_dir="$PWD/build/DevWatch.app"
dmg_path="$PWD/build/DevWatch.dmg"
iconset="$PWD/build/DevWatch.iconset"

# Beide Architekturen, damit das DMG auch auf Intel-Macs läuft.
architectures=(--arch arm64 --arch x86_64)
swift build -c release "${architectures[@]}"
binary_dir="$(swift build -c release "${architectures[@]}" --show-bin-path)"

rm -rf "$app_dir" "$iconset"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Support/Brand/devwatch-logo.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" Support/Brand/devwatch-logo.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app_dir/Contents/Resources/DevWatch.icns"
cp "$binary_dir/DevWatch" "$app_dir/Contents/MacOS/DevWatch"
cp Support/Info.plist "$app_dir/Contents/Info.plist"

# Eine stabile Signatur hält die einmal erteilten Ordner-Berechtigungen (TCC) über
# Builds hinweg gültig; ad-hoc ("-") wechselt bei jedem Build die Identität.
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"

if [ "$mode" != "release" ]; then
    codesign --force --sign "${identity:--}" "$app_dir"
    printf 'App erstellt: %s (signiert: %s)\n' "$app_dir" "${identity:-ad-hoc}"
fi

if [ "$mode" = "install" ]; then
    pkill -x DevWatch || true
    ditto "$app_dir" /Applications/DevWatch.app
    open /Applications/DevWatch.app
    printf 'Installiert: /Applications/DevWatch.app\n'
fi

if [ "$mode" = "release" ]; then
    if [ -z "$identity" ]; then
        printf 'Keine "Developer ID Application"-Identität im Schlüsselbund gefunden.\n' >&2
        printf 'Zertifikat installieren oder SIGN_IDENTITY setzen.\n' >&2
        exit 1
    fi
    version="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)"
    profile="${NOTARY_PROFILE:-}"
    staging="$PWD/build/dmg-staging"

    if [ "${SKIP_NOTARIZE:-0}" != "1" ] && [ -z "$profile" ]; then
        printf 'Kein NOTARY_PROFILE gesetzt.\n' >&2
        printf 'Vorlage kopieren und eintragen:\n' >&2
        printf '  cp scripts/release.env.example scripts/release.env\n' >&2
        printf 'Profil einmalig anlegen:\n' >&2
        printf '  xcrun notarytool store-credentials <name> --apple-id <mail> --team-id <TEAMID>\n' >&2
        printf 'Zum Bauen ohne Notarisierung: SKIP_NOTARIZE=1 ./scripts/build-app.sh release\n' >&2
        exit 1
    fi

    codesign --force --options runtime --timestamp --sign "$identity" "$app_dir"
    codesign --verify --strict --verbose=2 "$app_dir"

    if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
        # Erst die App selbst notarisieren und stapeln. Nur dann trägt die aus dem
        # DMG gezogene Kopie ihr Ticket bei sich und startet auch ohne Internet
        # ohne Gatekeeper-Dialog.
        archive="$PWD/build/DevWatch-notarize.zip"
        rm -f "$archive"
        ditto -c -k --keepParent "$app_dir" "$archive"
        printf 'Notarisiere App …\n'
        xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
        xcrun stapler staple "$app_dir"
        rm -f "$archive"
    fi

    rm -rf "$staging" "$dmg_path"
    mkdir -p "$staging"
    ditto "$app_dir" "$staging/DevWatch.app"
    ln -s /Applications "$staging/Applications"   # Ziel zum Hineinziehen im DMG
    hdiutil create -volname "DevWatch $version" -srcfolder "$staging" \
        -ov -format UDZO "$dmg_path" >/dev/null
    rm -rf "$staging"
    codesign --force --timestamp --sign "$identity" "$dmg_path"

    if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
        # Das DMG braucht ein eigenes Ticket, sonst prüft Gatekeeper es beim
        # Öffnen online nach.
        printf 'Notarisiere DMG …\n'
        xcrun notarytool submit "$dmg_path" --keychain-profile "$profile" --wait
        xcrun stapler staple "$dmg_path"
        spctl -a -vv -t open --context context:primary-signature "$dmg_path" || true
    else
        printf 'HINWEIS: ohne Notarisierung — beim ersten Start meldet sich Gatekeeper.\n'
    fi

    printf 'Release: %s (v%s, %s)\n' "$dmg_path" "$version" \
        "$(du -h "$dmg_path" | cut -f1 | tr -d ' ')"
fi
