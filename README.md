# Nextcloud Automated Setup Script

`nextcloud-install.sh` installs [Nextcloud](https://nextcloud.com), the self-hosted file sync and cloud server, with Docker Compose. It sets up Nextcloud with MariaDB and Redis, starts the stack, and prints the URL.

## What it does

- Detects your Linux distro and installs Docker and Docker Compose.
- Writes a Compose stack (Nextcloud 35 + MariaDB + Redis) into `/opt/nextcloud` (default).
- Asks for the host port (default `8080`) and the admin username and password.
- Starts Nextcloud and prints the URL.

## Supported distros

| Distro family | Status |
|---|---|
| Fedora | Tested, works |
| Debian, Ubuntu, Linux Mint, Pop!_OS, Zorin, elementary OS | Not tested, need feedback |
| RHEL, Rocky, AlmaLinux, CentOS, Oracle Linux | Not tested, need feedback |
| Arch, Manjaro, EndeavourOS, Garuda | Not tested, need feedback |
| openSUSE, SLES | Not tested, need feedback |
| Alpine | Not tested, need feedback |

If you try it on a distro marked "Not tested", please open an issue saying whether it worked.

## Install

```bash
bash nextcloud-install.sh
```

Then open `http://<your-server-ip>:8080` and sign in with the admin account you chose. Use a strong admin password.

## Uninstall

```bash
bash nextcloud-install.sh uninstall
```

This stops Nextcloud and asks whether to remove its data too.

## Part of the Proxmox Homelab setup

This installer is used by [Proxmox-Homelab-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/Proxmox-Homelab-Automated-Setup-Script), which creates an LXC for each app on a Proxmox host and runs this script inside it.
