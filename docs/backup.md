# Backup

Regles: només lectura al dispositiu; cap escriptura fins tenir un backup verificat (mida exacta + SHA-256 coincident amb el dispositiu).

```bash
scripts/identify.sh                 # confirma el model (para si ro.hardware != sun50iw10p1)
scripts/backup.sh                   # boot0/boot1 + cada partició, excepte UDISK i media_data
scripts/backup.sh --with-data       # inclou /data (~26 GB, dades privades)
scripts/verify-backup.sh backups/<data>
```
Cada partició: `part-<nom>.img.gz` + `part-<nom>.sha256` (hash i mida en bytes). El hash local (del flux) es compara amb `sha256sum` calculat al propi dispositiu; si no coincideix l'script s'atura.
Guardeu-ho al disc ext4 de WSL (no a `/mnt/c`). `backups/` és ignorat per git: conté Wi-Fi, tokens i firmware amb drets.

Avís heretat del doc Xoro: no munteu la partició `bootloader` al marc (capçalera FAT16 inconsistent).
