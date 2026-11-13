# Dashboard permanent amb systemd (unitats d'usuari)

Plantilles per executar el dashboard de manera contínua en un equip Linux que està sempre encès.

- `home-dashboard-web.service`: serveix `dashboard/` amb `server/static_server.py` (port 8080, només `127.0.0.1` per defecte).
- `home-dashboard-generate.service` + `.timer`: regenera `dashboard/data/data.json` cada 10 minuts (primera execució 1 minut després d'arrencar).

Les unitats suposen el repositori a `~/home-dashboard`. Si és en un altre lloc, edita `WorkingDirectory`, `ExecStart` (`%h` és la carpeta personal).

## Instal·lació

```bash
cd ~/home-dashboard
make venv                      # crea server/.venv (el necessita el generador)
cp server/config.example.json server/config.json   # i edita'l

mkdir -p ~/.config/systemd/user
cp server/systemd/home-dashboard-* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now home-dashboard-web.service home-dashboard-generate.timer

# perquè s'executin sense cap sessió oberta (i en arrencar l'equip)
loginctl enable-linger "$USER"
```

El generador es pot llançar a mà amb `systemctl --user start home-dashboard-generate.service`.

## Xarxa

Per defecte el servidor només escolta a `127.0.0.1`, i el marc hi arriba amb `adb reverse`. Si el marc ha d'accedir-hi per Wi-Fi, canvia `--bind` per l'adreça LAN de l'equip a `home-dashboard-web.service`; llavors el calendari i les tasques queden visibles per a tota la xarxa local.

## Registres i estat

```bash
systemctl --user status home-dashboard-web.service home-dashboard-generate.timer
journalctl --user -u home-dashboard-web.service -f
journalctl --user -u home-dashboard-generate.service -n 50
systemctl --user list-timers
```

## WSL2

Cal activar systemd a `/etc/wsl.conf` i reiniciar WSL (`wsl --shutdown`):

```ini
[boot]
systemd=true
```

Els serveis només funcionen mentre WSL està en marxa: si WSL s'atura (o Windows s'apaga), el dashboard s'atura amb ell.

## Desinstal·lació

```bash
systemctl --user disable --now home-dashboard-web.service home-dashboard-generate.timer
rm ~/.config/systemd/user/home-dashboard-*
systemctl --user daemon-reload
```
