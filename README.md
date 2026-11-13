# Home Dashboard

Dashboard familiar per a un marc de fotos Android (Xoro CPF 10PF, Allwinner A133, Android 10, Uhale): hora, temps, agenda i tasques. Treballem des de WSL2.
Basat en <https://github.com/wesbos/photo-frame-dashboard>.

El marc no surt mai a internet: un servidor a la xarxa de casa prepara les dades (`server/`) i el marc només les mostra.

> **Regla: no es fa cap escriptura al dispositiu fins tenir un backup verificat.**
> `backups/`, `diagnostics/` i `frames/` són privats i ignorats per git.

## Mapa del repositori

- `dashboard/`: la pàgina (HTML, CSS i JS). `dashboard/data/data.json` el genera el servidor i no és a git.
- `server/`: `generate.py` (prepara les dades), `static_server.py` (serveix la pàgina) i les plantilles de configuració.
- `kiosk/`: app Android mínima amb WebView, que fa de HOME del marc.
- `scripts/`: eines per parlar amb el marc per ADB (identificar, backup, hardening, kiosk) i per al servidor.
- `docs/`: documentació (vegeu [Docs](#docs)).

## Ordre de feina

Abans d'escriure res al marc, comproveu que en podeu tornar: [docs/recovery.md](docs/recovery.md).

1. [Configurar WSL i veure el marc per USB](docs/wsl-setup.md): `scripts/wsl-usb-check.sh`
2. Identificar el dispositiu: `scripts/identify.sh`
3. Fer el backup i verificar-lo ([docs/backup.md](docs/backup.md)):
   ```bash
   scripts/backup.sh               # tot excepte /data: boot0/1, capçalera i cua del disc, particions
   scripts/backup.sh --with-data   # afegeix /data (UDISK és còpia en calent) i media_data
   scripts/verify-backup.sh backups/<carpeta>
   ```
4. Hardening reversible ([docs/hardening.md](docs/hardening.md)): `scripts/harden.sh`. El pas `uhale` només es pot aplicar quan el kiosk (pas 5) és instal·lat i el seu `.Home` és activat.
5. Kiosk propi com a HOME: `scripts/build-kiosk.sh` i instal·lació a [docs/dashboard.md](docs/dashboard.md) (apartat 4)
6. Dashboard: [docs/dashboard.md](docs/dashboard.md)

## Backup, en resum

- Una sola ordre desa en una carpeta nova `backups/<data-hora>/` totes les peces, cada una com a `.img.gz` + `.sha256`, i un `MANIFEST` que acaba amb `complete=yes` només si tot ha anat bé.
- Es compara el hash del flux amb el calculat al propi marc; si no coincideix, el script s'atura.
- `/data` (UDISK) canvia mentre es llegeix: es desa en una sola passada, marcada amb una `.NOTE.txt` com a còpia en calent, íntegra però sense consistència de f2fs garantida.
- `verify-backup.sh` comprova el `MANIFEST`, les peces i cada `.img.gz` (hash, mida i que no hi hagi filler `0xCC`).
- Si `adb devices` es penja a WSL, vegeu [docs/wsl-setup.md](docs/wsl-setup.md).

## Comprovacions

`make check` fa el lint (shellcheck, `bash -n` i `py_compile`) i els tests del servidor i dels scripts. Els tests dels scripts usen un adb fals i no toquen cap dispositiu. `make help` en mostra tots els objectius.

## Docs

- [docs/wsl-setup.md](docs/wsl-setup.md): instal·lar eines i compartir el marc amb WSL (usbipd).
- [docs/backup.md](docs/backup.md): procediment, què cobreix el backup i què no, i com verificar-lo.
- [docs/recovery.md](docs/recovery.md): camí de tornada (ADB, fastboot, FEL) i resultats.
- [docs/hardening.md](docs/hardening.md): canvis reversibles al marc i com desfer-los.
- [docs/dashboard.md](docs/dashboard.md): des de zero fins al dashboard: servidor, kiosk i què vol dir el peu de la pàgina.
- [docs/xoro-cpf10pf.md](docs/xoro-cpf10pf.md): notes del nostre exemplar (observacions nostres).
- [docs/xoro-cpf10pf-reference.md](docs/xoro-cpf10pf-reference.md): notes copiades sense canvis d'un altre projecte, sobre una altra unitat de la mateixa plataforma. No són observacions nostres.
