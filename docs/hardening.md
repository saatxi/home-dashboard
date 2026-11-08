# Hardening reversible

Només canvis que es desfan per ADB: no es toquen particions, ni Device Owner, ni res per fastboot/FEL. Abans de cada sessió: `scripts/harden.sh snapshot` (només lectura, desa l'estat a `diagnostics/<data>-pre-hardening/`).

```bash
scripts/harden.sh snapshot          # estat actual, només lectura
scripts/harden.sh status            # enabled/desactivat dels paquets dels passos
scripts/harden.sh apply example     # desactiva com.example (app de test de fàbrica)
scripts/harden.sh apply uhale       # desactiva Uhale (com.zeasn.frame); exigeix un altre HOME
scripts/harden.sh revert <pas>      # torna a activar el paquet
```

## Què es canvia i per què

| Pas | Canvi | Per què | Desfer |
|---|---|---|---|
| `example` | `pm disable-user --user 0 com.example` | App de test de fàbrica (`TS8ProdutionTest`) que pot enviar dades | `scripts/harden.sh revert example` |
| `uhale` | `pm disable-user --user 0 com.zeasn.frame` | Uhale és el launcher de fàbrica i envia dades | `scripts/harden.sh revert uhale` |

**Estat 2026-11-08: el pas `uhale` està aplicat de nou, amb el kiosk propi (`kiosk/`) com a HOME.** Sense un HOME amb finestra pròpia el tàctil no funciona (vegeu «Lliçons»); no el torneu a aplicar si desinstal·leu el kiosk.

`apply` demana confirmació (o `-y`), comprova que el canvi arriba a `package-restrictions.xml` i el registra a `frames/xoro/changes.jsonl`. `revert` fa `pm enable`, que deixa el paquet a `enabled=1`, no al valor per defecte (`enabled=0`); funcionalment és el mateix.

## Lliçons al nostre exemplar

- **No reinicieu just després de canviar.** Android escriu `package-restrictions.xml` amb retard: el primer cop vam reiniciar massa aviat i el canvi es va perdre. Ara el script espera fins a 30 s que el fitxer tingui `enabled="3"` i s'atura si no el veu. Un cop desat, el canvi sobreviu als reinicis.
- **Sense Uhale, l'únic HOME és `Settings FallbackHome`.** Es dibuixa buit i no tanca l'animació d'arrencada: el logo amb punts es queda en pantalla. `adb shell setprop service.bootanim.exit 1` l'atura (de memòria; torna a passar a cada reinici fins que hi hagi un launcher/kiosk propi). Aleshores es veu el fons de pantalla per defecte.
- **Sense un HOME propi, el tàctil no fa res, però no és cosa dels eixos.** Provat el 2026-11-08: amb Uhale desactivat i `FallbackHome` com a únic HOME, el `InputDispatcher` no té cap finestra registrada (`dumpsys input`: `FocusedWindows: <none>`, `Displays: <none>`) i descarta tots els tocs, reals i injectats (`adb shell input tap`), amb `Dropping event because there is no touchable window or gesture monitor` al `logcat`. Persisteix després d'un reinici net i el gestor de finestres sí que veu Settings amb focus: l'entrada i el gestor de finestres no coincideixen. Amb Uhale activat (`scripts/harden.sh revert uhale`) el despatxador registra les finestres i el tàctil funciona: un toc real a la fila *Pantalla* de Settings va arribar en cru a X=1163, Y=1374 i va obrir els ajustes de Pantalla. **No sabem encara si el que ho arregla és que Uhale sigui el HOME o només que estigui activat.**
- **Resolt amb el kiosk (`kiosk/`, `scripts/build-kiosk.sh`):** amb `local.homedashboard.kiosk/.Home` com a HOME i Uhale desactivat, després d'un reinici el despatxador té la finestra del kiosk, l'animació d'arrencada es tanca (`setprop sys.bootanim.exit 1` des de l'app) i el tàctil funciona: cinc tocs (quatre cantonades i centre) sobre la pàgina de prova 0.2 surten on toca, sense cap `Dropping event`. Per activar-lo: `pm enable local.homedashboard.kiosk/.Home` i `cmd package set-home-activity local.homedashboard.kiosk/.Home` (esperar uns 30 s abans de reiniciar). Per desfer-ho: `adb uninstall local.homedashboard.kiosk` i `scripts/harden.sh revert uhale`.
- **Els eixos del tàctil són correctes.** El panell `gslX680` reporta X 0–1200 i Y 0–1920, però Android ja l'estira a la pantalla (`SurfaceOrientation: 0`, 1920×1200): X→X i Y→Y. Cantonades mesurades en cru (X 16–1184, Y 51–1881) i un toc a la dreta de la fila *Pantalla* (≈1125, 1350 esperat; 1163, 1374 mesurat) hi encaixen. No cal `.idc` ni tocar `/vendor`/`/system`.
- **Eines que no serveixen per veure el tàctil:** `settings put system pointer_location 1` no dibuixa res al marc i `screencap` torna la mateixa imatge sempre (mateixa mida en bytes). Per mesurar, `adb shell getevent -l /dev/input/event3` (en cru) i `dumpsys input` / `logcat | grep InputDispatcher`.
- **No injecteu tocs si el despatxador no té finestres:** cada toc injectat espera 5 s i genera un ANR (`Waiting because no window has focus`).
- **Animació d'arrencada d'Uhale (resolt, sense tocar `/system`):** és `/system/media/bootanimation.zip` (17 MB, 1920×1200 a 30 fps, `sha256` `8b13f763…ca4840`; còpia a `backups/bootanimation-original/`) i la dibuixa `bootanim`, per això desactivar l'app Uhale no la treu. Android 10 (build `eng`) llegeix **`/data/local/bootanimation.zip` abans que la de `/system`**: un zip negre (`desc.txt` = `1920 1200 30` / `p 0 0 part0`, un PNG negre a `part0/001.png`, guardat sense compressió, `zip -0`) fa que l'encesa sigui negra fins que el kiosk tanca l'animació (uns 12 s a l'arrencada). Per instal·lar-lo: `adb push bootanimation.zip /data/local/` i `chmod 644`; per desfer-ho: `adb shell rm /data/local/bootanimation.zip`. Es perd amb un factory reset. El logo de Xoro del carregador d'arrencada és d'una altra partició i no s'ha tocat. Compte: el kiosk tanca l'animació amb `setprop sys.bootanim.exit 1`, que SELinux denega (`avc: denied`) i només funciona perquè la build és `Permissive`.
- **Android 10: no hi ha `cmd wifi connect-network`** (és de l'11). Connectar el Wi-Fi sense tàctil vol editar `/data/misc/wifi/WifiConfigStore.xml` o navegar amb `input`.
- **El rellotge:** després d'un reinici sense xarxa l'hora era correcta (el RTC sembla conservar-la en un reinici; no provat amb pèrdua total de corrent). Abans: **el rellotge del marc no es manté** (apareix a gener del 2026 després de reiniciar sense xarxa); caldrà NTP o ajustar-lo pel dashboard.
- `ro.adb.secure=1` i `ro.debuggable=1`, però ADB per USB funciona sense prompt i és root.

## Pendent (no fet)

- **`svc wifi disable` no sobreviu a un reinici**: la xarxa desada es reconnecta a cada arrencada, amb accés a internet si el router el dona. Ajornat. Wi-Fi només local, amb la sortida a internet bloquejada al router. **Ajornat** fins que hi hagi dashboard/kiosk amb la seva gestió de pantalla. Es farà amb la regla del router feta abans de connectar (MAC a `frames/xoro/SETUP.md`).
- ADB per Wi-Fi (opcional): adbd root escoltaria a la LAN.
- `su` setuid a `/system/xbin/su` (`-rwsr-sr-x`): treure'l requereix escriure a `/system`; decisió a part.
