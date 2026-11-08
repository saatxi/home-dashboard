# El nostre exemplar: XORO CPF 10PF

Fitxa de referència d'un altre exemplar (còpia sense canvis): [xoro-cpf10pf-reference.md](xoro-cpf10pf-reference.md).
Aquí hi ha només el que hem **observat nosaltres**, separat de les hipòtesis que vénen de la referència.

## Observacions (08/11/2026, via ADB; serial i identificadors únics omesos)

| | Valor |
|---|---|
| Model | `ro.product.model=CPF10PF`, marca `Allwinner`, dispositiu `uhale` |
| USB | `1f3a:1001` (Allwinner CPF10PF) |
| SoC / maquinari | `ro.hardware=sun50iw10p1` (A133), `ro.board.platform=ceres`, `ro.product.board=exdroid` |
| Software | Android 10, build `eng` amb `test-keys`: `Allwinner/uhale/uhale:10/QP1A.191105.004/eng.ctk.20260130.093021:eng/test-keys` |
| ADB | `adbd` root (`uid=0`), `ro.secure=0`, `ro.debuggable=1`, sense prompt d'autorització |
| `su` | `/system/xbin/su` amb `-rwsr-sr-x root shell` (setuid) |
| eMMC | 61.071.360 sectors (≈31,3 GB), 17 particions de `bootloader` (p1, sector 73.728) a `UDISK` (p17, f2fs) |
| `/data` | 1,1 GB usats de 26 GB; `/data/data` 1,7 MB; `/data/media` 48 MB (logs d'`awlog`) |
| Paquets | 68 |
| Host | WSL2 (Ubuntu 24.04, kernel 6.18), `usbipd-win` amb xarxa *mirrored*, `adb` 34.0.4 |

Detalls de com s'ha obtingut: [wsl-setup.md](wsl-setup.md) i `scripts/identify.sh`. L'estat del nostre marc i dels backups és privat: `frames/xoro/` (ignorat per git); el procediment és a [backup.md](backup.md).

## Coincideix amb la referència
Maquinari `sun50iw10p1`, Android 10 `eng`, ADB root d'origen, `su` setuid, 32 GB d'eMMC i el disseny de particions (`bootloader` … `UDISK`).

## Per comprovar a la referència (no verificat al nostre marc)
- Uhale (`com.zeasn.frame`) i `com.example` envien dades: no connecteu el marc a internet encara.
- Capçalera FAT16 de `bootloader` inconsistent: no el munteu al marc.
- 1 GB de RAM, Wi-Fi Realtek RTL8189FS (només 2,4 GHz, sense WPA3), ranura microSD, sense sensor de llum.
- Suspensió trencada amb Wi-Fi i rellotge sense RTC (són problemes descrits a la referència, que cal provar abans de dependre'n).
