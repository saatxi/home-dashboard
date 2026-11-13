# Dashboard: des de zero fins a la pantalla

Guia per posar en marxa el dashboard al marc: el servidor que prepara les dades, el kiosk que les mostra i el que vol dir cada cosa del peu de la pàgina. Abans d'instal·lar el kiosk al marc cal tenir el backup verificat (vegeu el [README](../README.md)).

## 1. Com funciona

- `server/generate.py` escriu `dashboard/data/data.json`. Hi posa:
  - el temps d'[Open-Meteo](https://open-meteo.com/) per a les coordenades de la configuració (no cal clau d'API);
  - els esdeveniments d'un calendari iCal, des d'un fitxer o des d'una URL;
  - les tasques, d'un fitxer de text.
  Cada secció és independent: si una falla, es conserva l'última dada bona i l'error s'anota a `errors`.
- `server/static_server.py` serveix `dashboard/`. No mostra el llistat de les carpetes.
- La pàgina demana `data/data.json` cada 30 s. El rellotge del marc no és fiable, així que l'hora surt de la capçalera `Date` de la resposta del servidor.
- Cada `data.json` porta `site_version`, un hash del contingut de `index.html`, `css/` i `js/`. Quan canvia, la pàgina es recarrega sola. El hash només es recalcula quan s'executa `generate.py`: un canvi als fitxers arriba al marc en la següent generació (cada 600 s amb `scripts/serve-dashboard.sh`) i després en la següent petició de 30 s.

## 2. Preparar el servidor

Des de l'arrel del repositori:

```bash
python3 -m venv server/.venv
server/.venv/bin/pip install -r server/requirements.txt
cp server/config.example.json server/config.json
cp server/tasks.example.txt server/tasks.txt
```

Amb `make venv` es crea el mateix `server/.venv` en un sol pas, però instal·la `server/requirements-dev.txt` (també pytest, per a les proves).

`server/.venv/`, `server/config.json`, `server/tasks.txt` i `dashboard/data/data.json` són ignorats per git.

### Configuració (`server/config.json`)

Canvieu `place`, `latitude`, `longitude` i `timezone` pels de casa vostra. Només es valida que `latitude`, `longitude`, `timezone` i `calendar_days_ahead` (si hi és) siguin correctes; la resta s'usa tal com és.

| Clau | Obligatòria | Per defecte | Què fa |
|---|---|---|---|
| `latitude` | sí | — | Latitud en graus, entre -90 i 90. Serveix per al temps. |
| `longitude` | sí | — | Longitud en graus, entre -180 i 180. Serveix per al temps. |
| `timezone` | sí | — | Zona horària IANA, p. ex. `Europe/Madrid`. S'usa per al temps, per als esdeveniments i per a l'hora del peu. |
| `place` | no | `""` | Text que es mostra sota el temps. |
| `calendar_ical_file` | no | `""` | Fitxer iCal. Si és una ruta relativa, es compta des de l'arrel del repositori. Té prioritat sobre `calendar_ical_url`. |
| `calendar_ical_url` | no | `""` | URL d'un calendari iCal, que es descarrega a cada generació. **És secreta**: qui la té pot llegir el calendari. No la poseu en cap lloc públic. |
| `calendar_days_ahead` | no | `14` | Quants dies es mostren a partir d'avui. Ha de ser un enter positiu. |
| `tasks_file` | no | `server/tasks.txt` | Fitxer de tasques. Si és una ruta relativa, es compta des de l'arrel del repositori. |

Si no hi ha ni `calendar_ical_file` ni `calendar_ical_url` (o són buits), no hi ha agenda i no és un error.

### Tasques (`server/tasks.txt`)

- Una tasca per línia.
- `[ ]` al principi marca una tasca pendent, i `[x]` (o `[X]`) una de feta. Una línia sense cap d'aquests prefixos és pendent.
- Les línies buides i les que comencen per `#` s'ignoren.
- La pàgina mostra primer les pendents i com a màxim 8 tasques.

## 3. Executar el servidor

### Per provar: `scripts/serve-dashboard.sh`

```bash
scripts/serve-dashboard.sh
```

(`make serve` fa el mateix.)

- Serveix `dashboard/` a `http://127.0.0.1:8080/`.
- Si hi ha `server/.venv` i `server/config.json`, regenera `data.json` cada 600 s. Si falta alguna de les dues coses, ho avisa i no el regenera.
- Si `dashboard/data/data.json` no existeix, en crea una còpia a partir de `data.example.json`. Són dades d'exemple de l'1 de gener de 2026, i el peu surt en ambre fins que hi hagi dades noves.
- Opcions: `-p|--port N` (de 1 a 65535, per defecte 8080), `--lan` (escolta a totes les interfícies, és a dir, a la xarxa local; per al marc no cal) i `--no-refresh` (no regenera `data.json`).
- Ctrl+C l'atura.

### Connectar el marc

El marc arriba al servidor del PC amb `adb reverse`. Amb el port per defecte:

```bash
adb reverse tcp:8080 tcp:8080
```

Així el marc veu el servidor a `http://127.0.0.1:8080/`. Si useu un altre port amb `-p`, canvieu els dos números.

### Permanent: systemd

Per deixar el servidor en marxa sense una terminal oberta hi ha unitats de systemd d'usuari a `server/systemd/`. Els detalls són a [server/systemd/README.md](../server/systemd/README.md).

## 4. El kiosk

### Què és

`kiosk/` és una app mínima: un WebView a pantalla completa, compilada sense Gradle.

- Mostra la URL que li heu indicat. Si no n'hi ha cap, mostra la pàgina empaquetada (rellotge i data, sense xarxa).
- La URL es desa, i les obertures següents la fan servir.
- Només deixa navegar dins de l'origen de la URL, i el botó «enrere» no fa res.
- Si el servidor no respon o respon amb un error 5xx, mostra «Esperant el servidor…» i ho torna a provar cada 5 s.
- Es recarrega una vegada cada 24 h.

### Compilar: `scripts/build-kiosk.sh`

Requisits:

- `javac` i `zip` al `PATH`.
- Un SDK d'Android amb build-tools 34.0.0 (`aapt2`, `d8`, `zipalign`, `apksigner`) i la plataforma android-34 (`android.jar`). Per defecte és a `/usr/lib/android-sdk`; si és en un altre lloc, useu `ANDROID_HOME`, o bé `BUILD_TOOLS` i `ANDROID_JAR`.
- `keytool`, només si cal generar la clau.

Clau de signatura:

- Per defecte és `~/.android/debug.keystore` (es pot canviar amb `KIOSK_KEYSTORE`), amb les contrasenyes de depuració. Per canviar-les useu `KIOSK_KS_PASS`, `KIOSK_KEY_ALIAS` i `KIOSK_KEY_PASS`.
- Si el keystore no existeix, el script s'atura. No en crea un de nou tret que indiqueu `--generate-key` o `KIOSK_GENERATE_KEY=1`.
- Useu sempre la mateixa clau. Una de nova fa que `adb install -r` falli amb `INSTALL_FAILED_UPDATE_INCOMPATIBLE` si el kiosk ja és al marc.

```bash
scripts/build-kiosk.sh
```

(`make kiosk` fa el mateix.) El resultat és `kiosk/build/kiosk.apk`, signat i verificat amb `apksigner`.

### Instal·lar i indicar-li la URL

Des de l'arrel del repositori:

```bash
adb install -r kiosk/build/kiosk.apk
adb shell am start -n local.homedashboard.kiosk/.MainActivity --es url "http://127.0.0.1:8080/"
```

- El component és el de `kiosk/AndroidManifest.xml`. L'extra `url` és el que documenta la Javadoc de `MainActivity.java` (`--es url <url>`).
- Només s'accepten URLs `http` o `https` amb servidor. Les altres s'ignoren i ho registra el log.
- `--es url ""` torna a la pàgina empaquetada.
- Per veure què fa el kiosk: `adb logcat -s HomeDashboard` (és el tag de `MainActivity.java`).

### Fer-lo el HOME del marc

El `activity-alias` `.Home` (categories `HOME` i `DEFAULT`) és a `kiosk/AndroidManifest.xml` i està desactivat per defecte: instal·lar l'APK no canvia el HOME ni mostra cap selector. Per activar-lo:

```bash
adb shell pm enable local.homedashboard.kiosk/.Home
```

Per fer-lo servir com a HOME, i per desfer-ho, seguiu [docs/hardening.md](hardening.md). Tingueu en compte que `scripts/harden.sh apply uhale` només es fa si el kiosk està instal·lat **i activat**.

## 5. Què vol dir el peu

| Text del peu | Vol dir |
|---|---|
| `dades de HH:MM` | Hora, a la zona de `timezone`, en què el servidor va generar les dades. |
| `sense dades del servidor · hora sense verificar` | La pàgina encara no ha carregat cap `data.json`. |
| ` · error: weather, events` | Seccions que han fallat en l'última generació (`errors`). Les claus són `weather`, `events` i `tasks`. |
| ` · error de pintat: tasks` | La pàgina no ha pogut dibuixar una secció. |

El peu surt en ambre quan passa alguna d'aquestes coses:

- Les dades tenen més de 25 minuts, comptats des que el servidor les va generar.
- L'última descàrrega correcta de `data.json` és de fa més de 20 minuts.
- Hi ha errors de generació o de pintat.

Fins que no arriba una resposta amb la capçalera `Date`, l'hora i la data es mostren atenuades. El temps també s'atenua quan fa més de 3 hores que el servidor no l'ha pogut refrescar.

## 6. Problemes habituals

- **El peu diu «sense dades del servidor».** La pàgina no ha pogut carregar `data/data.json` mai. Comproveu que el servidor és en marxa i que `dashboard/data/data.json` existeix.
- **El kiosk mostra «Esperant el servidor…».** No aconsegueix carregar la URL (error de xarxa o HTTP 5xx). Comproveu el servidor i el `adb reverse`. Ho torna a provar cada 5 s, no cal reiniciar-lo.
- **`generate.py` diu que falta o és invàlid `server/config.json`.** El fitxer no existeix o no és JSON. Copieu `server/config.example.json`. Si el missatge és d'una clau concreta (p. ex. «Config: «latitude» ha de ser un nombre entre -90 i 90»), corregiu-la. El script surt amb error i no regenera `data.json`.
- **El peu surt en ambre amb dades de l'1 de gener de 2026.** És la còpia de `data.example.json`. Falta `server/config.json` o el servidor no regenera les dades.
- **L'agenda diu «Res previst» i no hi ha cap error.** No hi ha calendari configurat (`calendar_ical_file` i `calendar_ical_url` són buits). Si l'agenda diu «Sense dades» i el peu mostra `error: events`, el calendari ha fallat.
- **`adb install -r` falla amb `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.** La clau de signatura és diferent de la del kiosk que ja és al marc. Useu la clau original (`KIOSK_KEYSTORE`). Si igualment cal una clau nova, cal desinstal·lar el kiosk, i en el mateix ordre, perquè el marc no es quedi sense HOME:
  1. Si Uhale està desactivat, torneu-lo a activar amb `scripts/harden.sh revert uhale`. Sense un HOME propi el marc es queda sense pantalla d'inici (vegeu [hardening.md](hardening.md)).
  2. `adb uninstall local.homedashboard.kiosk`
  3. `adb install kiosk/build/kiosk.apk`
  4. `adb shell pm enable local.homedashboard.kiosk/.Home` i, com que la instal·lació nova no recorda la URL, torneu a indicar-la amb `am start` (apartat 4). Després, si ho voleu, torneu a aplicar `scripts/harden.sh apply uhale`.
