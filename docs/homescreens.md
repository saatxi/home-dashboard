# HomeScreens

Avaluació d'alternatives al dashboard propi, configuració de HomeScreens en Docker i procediment d'actualització del WebView.

## Per què HomeScreens

Avui `server/generate.py` escriu `dashboard/data/data.json` i el kiosk mostra la URL que li diem. Qualsevol aplicació servida per HTTP funciona igual. Les alternatives estudiades:

| Projecte | Stack | Docker | URL de la pantalla | Llicència | Funciona avui al marc |
|---|---|---|---|---|---|
| **HomeScreens** | Next.js 16, React 19, Tailwind 4, config JSON | Sí | `:3000/display` | MIT | ✓ (pantalla de benvinguda OK amb WebView 74) |
| Magic Frame | Next.js 16, Postgres, Prisma, Caddy | Sí | `:80` | PolyForm NC | Parcialment |
| Kinboard | Next.js 16, Supabase Postgres, 6 contenidors | Sí | `:3001` | PolyForm NC | Parcialment |
| MagicMirror² | Node/Electron, mòduls JS | Comunitat | `:8080` | MIT | Per verificar |

HomeScreens és MIT i no necessita base de dades, l'editor és un WebUI separat i el display és una URL clara. Les proves del 2026-11-14 mostren que la pantalla de benvinguda es renderitza correctament amb Chromium 74 (el WebView de fàbrica del marc). Els mòduls amb animations i CSS avançat probablement necessiten una versió més nova.

## Limitacions a tenir en compte

- **Rellotge:** el marc no té un RTC fiable. El nostre dashboard treu l'hora de la capçalera `Date` del servidor; el mòdul de rellotge de HomeScreens usa l'hora del dispositiu i mostrarà l'hora equivocada després d'un tall de corrent fins que el marc es sincronitzi.
- **Sense internet al marc:** el marc no surt a internet. Qualsevol mòdul que faci peticions des del navegador (imatges de Google Photos, Immich, API externes) fallarà llevat que HomeScreens ho proxegui. Comproveu si cada mòdul fa les peticions des del servidor o des del navegador.
- **RAM:** el marc té 1 GB de RAM (~40 MB lliures en repòs). Un WebView modern amb React 19 pot consumir tot el marge. Vegeu la fase C de la prova d'estabilitat.

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

## 5. Protecció del kiosk contra morts del renderitzador

El kiosk inclou un retard exponencial: si el renderitzador mor 3 vegades en 10 minuts, el kiosk espera 1, 2, 4… fins a 30 minuts i mostra la pàgina empaquetada (rellotge) mentre espera. Això evita un bucle de recàrregues infinit si el WebView és massa pesat. El comportament és visible a `adb logcat -s HomeDashboard`.
