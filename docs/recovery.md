# Provar el camí de tornada (sense escriure res)

Abans de tocar res al marc cal saber que en podem sortir. Hi ha tres nivells, de més a menys còmode:

1. **ADB** (USB `1f3a:1001`): el que fem servir ara.
2. **U-Boot fastboot** (`1f3a:1010`): s'hi arriba amb `adb reboot bootloader`. Només lectura amb `scripts/fb-getvar.py`.
3. **FEL** (`1f3a:efe8`): ROM de l'SoC, independent del contingut de l'eMMC. S'hi arriba amb el forat de reset.

Referència (un altre model, mateixa plataforma A133): `saatxi/photo-frame-dashboard` → `docs/allwinner-a133-loofii-c3.md`, secció "Recovery ladder". Segons la seva fitxa, al Xoro FEL i fastboot són *no provats*; al nostre exemplar hem provat els dos des de WSL (vegeu "Resultats").

## Preparació (una vegada)
```bash
sudo apt install -y python3-usb sunxi-tools
```
A PowerShell (admin) ens caldrà fer `bind` de cada identitat quan aparegui, perquè canvia de USB ID:
`usbipd list` → `usbipd bind --busid <ID> --force` → `usbipd attach --wsl --busid <ID>`.

## Prova 2: U-Boot fastboot
```bash
adb reboot bootloader          # el marc reinicia; la pantalla queda negra o fixa
```
Quan `usbipd list` mostri `1f3a:1010`, fer `bind` + `attach`, i a WSL:
```bash
scripts/fb-getvar.py version product serialno max-download-size partition-size:super partition-size:UDISK
```
Sortir-ne: desconnectar l'alimentació i tornar-la a connectar (no hi ha escriptures; `fb-getvar.py` no sap fer `reboot`).
Esperat: només `version`, `max-download-size` i similars; `partition-size:*` no està suportat (vegeu "Resultats").

## Prova 3: FEL
Amb el marc apagat i **sense USB ni alimentació connectats**, mantenir premut el forat de reset, connectar, deixar anar als 3–5 s. Pantalla negra i `1f3a:efe8` a `usbipd list`; llavors `bind` + `attach` i:
```bash
sunxi-fel version              # esperat: soc=00001855
```
Només `version`: res d'`write*`/`exec`. Per sortir, desconnectar i reconnectar l'alimentació.

## Resultats (provat al nostre exemplar, 2026-11-08)

| Nivell | Resultat |
|---|---|
| ADB `1f3a:1001` | Funciona (adbd root d'origen). |
| U-Boot fastboot `1f3a:1010` | Funciona des de WSL. `version`=0.5, `max-download-size`=0x02000000 (32 MiB). `partition-size:super` i `partition-size:UDISK` retornen `not supported`: és un fastboot mínim, i no sabem quines altres ordres admet. `product` retorna el número de sèrie. |
| FEL `1f3a:efe8` | Funciona des de WSL amb el forat de reset. `sunxi-fel version` → `soc=00001855 ver=0001 scratchpad=00002200`. L'avís `no 'soc_sram_info'` d'sunxi-tools és inofensiu (no coneix aquest SoC). Només s'ha executat `version`. |

Notes pràctiques:
- Cada identitat USB necessita el seu `bind --force` + `attach`, i el busid pot canviar.
- Després de sortir de fastboot o FEL (desconnectar i reconnectar l'alimentació) cal tornar a fer `attach` de `1f3a:1001`.
- No s'ha provat cap escriptura per fastboot ni FEL.

## Què en traiem
Si 2 o 3 no funcionen des de WSL, ho sabrem **abans** d'escriure res al marc, i el pla de canvis s'ha d'ajustar (només canvis que es puguin desfer per ADB).
