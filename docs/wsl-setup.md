# Configuració de WSL2 per veure el marc per USB

Provat sobre: Ubuntu 24.04, WSL2 kernel 6.18 (té `CONFIG_USBIP_VHCI_HCD=m`).
Dispositiu esperat: XORO CPF 10PF (Allwinner A133), USB `1f3a:1001`, ADB root d'origen.

## 1. Windows (PowerShell com a administrador)
```powershell
winget install --interactive --exact dorssel.usbipd-win
```
Reinicieu si ho demana. Cable **USB-A → USB-C de dades** (USB-C a USB-C pot no donar dades).

## 2. WSL
```bash
sudo apt update
sudo apt install -y android-sdk-platform-tools-common usbutils linux-tools-generic hwdata pigz
# Eines addicionals per a scripts/webview.sh install (re-signatura d'APK):
sudo apt install -y apksigner aapt openssl curl
sudo modprobe vhci_hcd
```
Regla udev perquè `adb` funcioni sense root:
```bash
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="1f3a", MODE="0666", GROUP="plugdev"' | sudo tee /etc/udev/rules.d/51-android.rules
sudo usermod -aG plugdev $USER
sudo udevadm control --reload-rules && sudo udevadm trigger
```

## 3. Compartir el dispositiu amb WSL
A PowerShell (admin per al `bind`):
```powershell
usbipd list
usbipd bind --busid <BUSID>          # un sol cop per identitat USB
usbipd attach --wsl --busid <BUSID>  # cada cop que es connecta
```
- Cada identitat USB (`1f3a:1001` ADB, `1f3a:efe8` FEL, `1f3a:1010` fastboot) es fa `bind` per separat; en canviar de mode el BUSID/ID pot canviar.
- Mentre està *attached*, Windows no el veu. Tanqueu `adb` de Windows (`adb kill-server`) per evitar conflictes.
- Si no voleu repetir l'attach: `usbipd attach --wsl --busid <BUSID> --auto-attach`.

## 4. Comprovar
```bash
scripts/wsl-usb-check.sh
adb kill-server && adb devices   # accepteu el prompt a la pantalla si surt
adb shell id                      # esperat: uid=0(root)
```
`/sys/bus/usb` no existeix a WSL fins que hi ha un attach amb `vhci_hcd` carregat.

## Problemes habituals
- **`Device in error state` a `usbipd attach`:** desconnecteu i torneu a connectar el cable (el BUSID pot canviar), feu `adb kill-server` a Windows, i si cal `usbipd unbind` + `usbipd bind --busid <ID> --force`. Proveu un port USB directe a la placa.
- **`adb devices` es penja a WSL:** el dimoni no arrenca des d'algunes shells. Engegueu el servidor a part i torneu-ho a provar:
  ```bash
  pkill -x adb
  setsid nohup adb -L tcp:5037 server nodaemon >/dev/null 2>&1 </dev/null &
  adb devices -l
  ```
- **`adb push`/`adb install` des de WSL gairebé no avancen** (provat el 2026-11-14: un APK de 94 MB anava a ~1% cada 30 min). El sentit marc → PC (backups) va bé, però el PC → marc per usbipd no. Per enviar fitxers grans: `adb kill-server` a WSL, `usbipd detach --busid <BUSID>` i feu servir l'`adb.exe` de Windows (`winget install Google.PlatformTools`). Després torneu a fer l'attach.
- **`vhci_hcd` no carregat:** `sudo modprobe vhci_hcd` (cal fer-ho cada cop que es reinicia WSL).
