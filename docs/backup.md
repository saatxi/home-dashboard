# Backup

Regles: només lectura al dispositiu; cap escriptura fins tenir un backup verificat (mida exacta + SHA-256 coincident amb el dispositiu).

```bash
scripts/identify.sh                          # confirma el model (para si ro.hardware != sun50iw10p1)
scripts/backup.sh                            # tot excepte /data
scripts/backup.sh --with-data                # afegeix UDISK (còpia en calent) i media_data
scripts/backup.sh --only-data                # només UDISK i media_data
scripts/verify-backup.sh backups/<carpeta>
```

## Què desa `backup.sh`

Tot a `backups/<data-hora>/`, cada peça com a `<nom>.img.gz` + `<nom>.sha256` (hash, mida en bytes i origen).

| Peça | Origen | Per què |
|---|---|---|
| `mmcblk0boot0`, `mmcblk0boot1` | particions de hardware de l'eMMC | a aquest exemplar són zeros, però es desen igual |
| `disk-head` | sectors 0 fins a l'inici de la primera partició (≈36 MiB) | MBR/GPT i bootloader (`eGON.BT0`), que cap partició cobreix |
| `part-<nom>` | cada entrada de `/dev/block/by-name` | les particions del sistema |
| `disk-tail` | des del final de l'última partició fins al final del disc | còpia de seguretat de la GPT |
| `part-UDISK`, `part-media_data` | només amb `--with-data` o `--only-data` | dades d'usuari |

`disk-head` i `disk-tail` es calculen de la geometria real del disc, no amb números fixos. No es desa `mmcblk0rpmb` (àrea protegida).

## Verificació

- Cada peça: el hash del flux es compara amb el que calcula el propi marc (`dd | sha256sum`); si no coincideix, el script s'atura amb codi 3.
- `verify-backup.sh` rellegeix cada `.img.gz`: comprova SHA-256 i mida contra el `.sha256`, i que no hi hagi 64 KiB seguits de `0xCC` (símptoma d'un loader que restringeix lectures).

## `/data` és una còpia en calent

`UDISK` és una partició f2fs muntada en lectura-escriptura i canvia mentre es llegeix, així que el hash del marc no pot coincidir amb el del flux. Per això es desa en una sola passada i s'hi afegeix `part-UDISK.NOTE.txt`.

- Garantit: el fitxer és íntegre (mida i hash del flux rebut).
- No garantit: la consistència del sistema de fitxers. Abans de restaurar-la cal passar `fsck.f2fs`.

## Consells

- Deseu-ho al disc ext4 de WSL, no a `/mnt/c` (lent). `backups/` és ignorat per git: conté dades privades i firmware.
- Una còpia sense `/data` són uns 3,3 GiB (≈610 MB comprimits) i triga uns 6 minuts; amb `/data`, uns 45 minuts més.
- Si `adb` es penja a WSL en arrencar el servidor, engegueu-lo a part: `setsid nohup adb -L tcp:5037 server nodaemon &`.
- No munteu la partició `bootloader` al marc (capçalera FAT16 inconsistent, segons el doc de referència).
