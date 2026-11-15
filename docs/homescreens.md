# HomeScreens

Avaluació d'alternatives al dashboard propi, configuració de HomeScreens en Docker i procediment d'actualització del WebView.

## Per què HomeScreens

Avui `server/generate.py` escriu `dashboard/data/data.json` i el kiosk mostra la URL que li diem. Qualsevol aplicació servida per HTTP funciona igual. Les alternatives estudiades:

| Projecte | Stack | Docker | URL de la pantalla | Llicència | Funciona avui al marc |
|---|---|---|---|---|---|
| **HomeScreens** | Next.js 16, React 19, Tailwind 4, config JSON | Sí | `:3000/display` | MIT | ✓ amb WebView 156 (prova de nit superada, vegeu [Resultats](#resultats-2026-11-14)) |
| Magic Frame | Next.js 16, Postgres, Prisma, Caddy | Sí | `:80` | PolyForm NC | Parcialment |
| Kinboard | Next.js 16, Supabase Postgres, 6 contenidors | Sí | `:3001` | PolyForm NC | Parcialment |
| MagicMirror² | Node/Electron, mòduls JS | Comunitat | `:8080` | MIT | Per verificar |

HomeScreens és MIT i no necessita base de dades, l'editor és un WebUI separat i el display és una URL clara. Amb el WebView de fàbrica (Chromium 74) només es va provar la pantalla de benvinguda buida, que es veia bé. Amb pantalles reals s'ha provat amb el WebView 156.

## Limitacions a tenir en compte

- **Rellotge:** el marc no té un RTC fiable. El nostre dashboard treu l'hora de la capçalera `Date` del servidor; el mòdul de rellotge de HomeScreens usa l'hora del dispositiu. Comprovat el 2026-11-14: el marc era al 30 de gener i HomeScreens mostrava *viernes, 30 de enero* amb l'hora equivocada.
- **Idioma:** HomeScreens agafa el locale del marc, que està en castellà («sáb», «viernes»).
- **Sense internet al marc:** el marc no surt a internet. Qualsevol mòdul que faci peticions des del navegador (imatges de Google Photos, Immich, API externes) fallarà llevat que HomeScreens ho proxegui. Comproveu si cada mòdul fa les peticions des del servidor o des del navegador.
- **RAM:** el marc té 1 GB de RAM. `MemFree` és baix (~40 MB), però el que compta és `MemAvailable`, que es manté per sobre de 300 MB fins i tot amb HomeScreens. Vegeu els [resultats](#resultats-2026-11-14).
- **Túnel USB:** el marc arriba al servidor per `adb reverse`. Si l'adbd del marc es penja (ho va fer el 2026-11-14 amb `Check failed: payload.size() <= bytes_left` a `UsbFfs-worker`), es perden els túnels. La pàgina continua carregada però deixa de rebre dades: HomeScreens mostra «Not updating since …» i el kiosk no ho detecta. Es recupera amb `adb reverse tcp:3000 tcp:3000`. Per a ús permanent, el marc hauria d'arribar al servidor per la Wi-Fi de casa.

## 1. Posar en marxa HomeScreens en Docker

```bash
docker compose -f services/homescreens/compose.yaml up -d --build
```

- Editor: `http://127.0.0.1:3000/editor` (des del PC)
- Pantalla: `http://127.0.0.1:3000/display` (la que veurà el marc)
- Dades i configuració: `services/homescreens/data/` (ignorat per git)
- Fotos de fons: `services/homescreens/backgrounds/` (ignorat per git)

```bash
# Aturar
docker compose -f services/homescreens/compose.yaml down
# Veure logs
docker compose -f services/homescreens/compose.yaml logs -f
```

**Actualitzar:** atureu, feu una còpia de `services/homescreens/data/` i `backgrounds/`, canvieu el commit al `compose.yaml` i torneu a construir.

## 2. Connectar el marc a HomeScreens

```bash
adb reverse tcp:3000 tcp:3000
adb shell am start -n local.homedashboard.kiosk/.MainActivity --es url "http://127.0.0.1:3000/display"
# Seguir els logs del kiosk:
adb logcat -s HomeDashboard chromium
```

Per tornar al dashboard propi (port 8080):
```bash
adb shell am start -n local.homedashboard.kiosk/.MainActivity --es url "http://127.0.0.1:8080/"
```

## 3. Actualitzar el WebView (opcional, escriu al marc)

**Prerequisit:** backup verificat (vegeu [backup.md](backup.md)).

El marc té WebView 74.0.3729.186 (Chromium 74), signat amb la testkey pública d'AOSP. Podeu instal·lar un WebView de 32 bits més nou sense tocar `/system`:

```bash
# Comprovar la versió actual
scripts/webview.sh status

# Baixar un APK com.android.webview arm 32-bit (armeabi-v7a, minSdk ≤ 29)
# Fonts candidates: LineageOS prebuilts (android_external_chromium-webview_prebuilt_arm)

# Instal·lar (descarrega i verifica la testkey AOSP, re-signa i instal·la)
scripts/webview.sh install /ruta/al/webview.apk

# Desfer (torna a la 74 de /product, sense tocar /system)
scripts/webview.sh revert
```

Si `adb install` es queda a `Performing Streamed Install`, és l'usbipd de WSL, que va massa lent en el sentit PC → marc. L'APK signat ja és a `<apk>-signed.apk`: instal·leu-lo amb l'`adb.exe` de Windows (vegeu [wsl-setup.md](wsl-setup.md#problemes-habituals)) i afegiu la línia a `changes.jsonl` a mà.

Per descarregar l'APK de LineageOS cal `git lfs pull`: si el baixeu directament de GitHub, obteniu el punter de text de Git LFS, no el binari.

L'script verifica que l'APK és `com.android.webview`, té `minSdkVersion ≤ 29`, `versionCode > 373018605` i conté `armeabi-v7a`. El canvi es registra a `frames/xoro/changes.jsonl` com qualsevol altra modificació reversible.

## 4. Prova d'estabilitat (fase C del pla)

Mesureu memòria, kills del renderitzador i captures periòdiques amb:

```bash
# Línia base: dashboard propi, 2 h
scripts/soak.sh --minutes 120 --label baseline

# Escenari 1: dashboard propi amb WebView nou
scripts/soak.sh --minutes 120 --label dashboard-webview-nou

# Escenari 2: HomeScreens, 2 h + nit sencera (8 h)
scripts/soak.sh --minutes 120 --label homescreens-2h
scripts/soak.sh --minutes 480 --label homescreens-night
```

Els resultats van a `diagnostics/soak-<data>-<label>/SUMMARY.txt`. Criteris d'acceptació:

- 0 `onRenderProcessGone` i 0 kills del LMK durant la nit
- `MemAvailable` mínim ≥ 100 MB i sense tendència creixent del PSS
- Les captures de pantalla mostren la pàgina sencera

Si no es compleixen, `scripts/webview.sh revert` i continueu amb el dashboard propi.

El `RESULTAT: OK` no detecta un túnel perdut: el renderitzador no mor i no hi ha errors de càrrega. Mireu també l'última captura, que ha de mostrar dades actuals i cap «Not updating».

## Resultats (2026-11-14)

WebView 156.0.8078.47 (`versionCode` 807804700, prebuilt arm de LineageOS) instal·lat amb l'`adb.exe` de Windows. No hi ha línia base amb el WebView 74: amb el marge mesurat no ha calgut.

| Prova | Durada | Morts renderer / recàrregues / errors | MemAvailable mín. | PSS kiosk |
|---|---|---|---|---|
| Dashboard propi, WebView 156 | 2 h | 0 / 0 / 0 | 451 MB | 165–179 MB, pla |
| HomeScreens (rellotge, temps, tasques, agenda, trànsit; 2 pantalles) | 2 h | 0 / 0 / 0 | 339 MB | 207–266 MB (pic 311) |
| HomeScreens, nit | 8 h | 0 / 0 / 0 | 323 MB | 214–262 MB (pic 318), sense tendència |

- El PSS de HomeScreens puja i baixa amb la rotació de pantalles i torna a uns 210–220 MB: no hi ha fuga.
- Les captures mostren la pàgina sencera i dades que s'actualitzen (el trànsit passa de 58 a 34 min durant la nit).
- HomeScreens fa servir uns 100 MB més que el dashboard propi, amb més de 3× el marge mínim.

**Conclusió:** el marc amb WebView 156 fa anar HomeScreens de manera estable. Abans de deixar-lo de manera permanent cal resoldre el rellotge del marc i, idealment, connectar-lo per Wi-Fi en lloc del túnel USB. El dashboard propi no té cap dels dos problemes.

## 5. Protecció del kiosk contra morts del renderitzador

El kiosk inclou un retard exponencial: si el renderitzador mor 3 vegades en 10 minuts, el kiosk espera 1, 2, 4… fins a 30 minuts i mostra la pàgina empaquetada (rellotge) mentre espera. Això evita un bucle de recàrregues infinit si el WebView és massa pesat. El comportament és visible a `adb logcat -s HomeDashboard`.
