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

`apply` demana confirmació (o `-y`), comprova que el canvi arriba a `package-restrictions.xml` i el registra a `frames/xoro/changes.jsonl`. `revert` fa `pm enable`, que deixa el paquet a `enabled=1`, no al valor per defecte (`enabled=0`); funcionalment és el mateix.

## Lliçons al nostre exemplar

- **No reinicieu just després de canviar.** Android escriu `package-restrictions.xml` amb retard: el primer cop vam reiniciar massa aviat i el canvi es va perdre. Ara el script espera fins a 30 s que el fitxer tingui `enabled="3"` i s'atura si no el veu. Un cop desat, el canvi sobreviu als reinicis.
- **Sense Uhale, l'únic HOME és `Settings FallbackHome`.** Es dibuixa buit i no tanca l'animació d'arrencada: el logo amb punts es queda en pantalla. `adb shell setprop service.bootanim.exit 1` l'atura (de memòria; torna a passar a cada reinici fins que hi hagi un launcher/kiosk propi). Aleshores es veu el fons de pantalla per defecte.
- **El tàctil no encerta.** El panell `gslX680` reporta eixos en vertical (X 0–1200, Y 0–1920) i la pantalla és horitzontal (1920×1200); sense Uhale, que ho compensava, els tocs no cauen on toca (hipòtesi, no provat amb tocs injectats). Arreglar-ho vol un `.idc` o rotació a `/vendor`/`/system`: fora d'abast ara. Mentrestant, `adb shell am start -a android.settings.WIFI_SETTINGS` obre pantalles de Settings i `adb shell input` hi injecta tocs.
- **Android 10: no hi ha `cmd wifi connect-network`** (és de l'11). Connectar el Wi-Fi sense tàctil vol editar `/data/misc/wifi/WifiConfigStore.xml` o navegar amb `input`.
- **El rellotge del marc no es manté** (apareix a gener del 2026 després de reiniciar sense xarxa); caldrà NTP o ajustar-lo pel dashboard.
- `ro.adb.secure=1` i `ro.debuggable=1`, però ADB per USB funciona sense prompt i és root.

## Pendent (no fet)

- Wi-Fi només local, amb la sortida a internet bloquejada al router. **Ajornat** fins que hi hagi dashboard/kiosk amb la seva gestió de pantalla. Es farà amb la regla del router feta abans de connectar (MAC a `frames/xoro/SETUP.md`).
- ADB per Wi-Fi (opcional): adbd root escoltaria a la LAN.
- `su` setuid a `/system/xbin/su` (`-rwsr-sr-x`): treure'l requereix escriure a `/system`; decisió a part.
