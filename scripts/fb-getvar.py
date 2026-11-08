#!/usr/bin/env python3
"""Client fastboot NOMÉS DE LECTURA per al U-Boot de l'Allwinner A133 (1f3a:1010).

L'ordre enviada és sempre `getvar:<nom>`: no hi ha cap camí per enviar flash, erase, boot ni reboot.
Cal `python3-usb` (sudo apt install python3-usb) i que el dispositiu sigui visible a WSL
(usbipd bind/attach de la identitat 1f3a:1010). Idea del fb.py de photo-frame-dashboard (MIT).

Ús: scripts/fb-getvar.py version product serialno partition-size:super max-download-size
"""
import sys

import usb.core
import usb.util

VENDOR = 0x1F3A
PRODUCT = 0x1010
TIMEOUT_MS = 5000


def find_device():
    device = usb.core.find(idVendor=VENDOR, idProduct=PRODUCT)
    if device is None:
        sys.exit("Cap dispositiu 1f3a:1010 (fastboot). Vegeu docs/recovery.md")
    return device


def find_endpoints(device):
    try:
        device.set_configuration()
    except usb.core.USBError:
        pass  # ja configurat
    interface = device.get_active_configuration()[(0, 0)]
    out_ep = usb.util.find_descriptor(
        interface,
        custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT,
    )
    in_ep = usb.util.find_descriptor(
        interface,
        custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN,
    )
    return out_ep, in_ep


def getvar(out_ep, in_ep, name):
    out_ep.write(f"getvar:{name}".encode())
    replies = []
    while True:
        try:
            reply = bytes(in_ep.read(512, timeout=TIMEOUT_MS)).decode(errors="replace")
        except usb.core.USBTimeoutError:
            replies.append("<timeout>")
            break
        replies.append(reply)
        if reply[:4] in ("OKAY", "FAIL"):
            break
    return replies


def main():
    names = sys.argv[1:]
    if not names:
        sys.exit(__doc__)
    out_ep, in_ep = find_endpoints(find_device())
    for name in names:
        if not name.strip():
            continue
        print(f"getvar:{name} -> {getvar(out_ep, in_ep, name)}")


if __name__ == "__main__":
    main()
