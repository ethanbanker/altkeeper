# AltKeeper

AltKeeper keeps apps installed on an iPhone available by renewing their provisioning profiles.
It can also act as an AltServer for AltStore Classic, so apps can be refreshed or installed over
Wi-Fi. It runs on a home server, a Mac, or Windows.

> **Experimental software.** AltKeeper uses private Apple APIs and protocols that may change
> without notice. JIT activation and some installation flows have not been verified end to end on
> physical devices. Use it with your own devices and Apple ID; it is not affiliated with Apple or
> AltStore.

## Quick install (Docker)

On a Proxmox VE host, create the container first (the installer refuses to run on the host):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ethanbanker/altkeeper/main/ct/altkeeper.sh)"
```

It picks a free container ID, downloads a Debian 12 template, creates an unprivileged LXC with
Docker support (`nesting=1,keyctl=1`), installs AltKeeper inside and prints the dashboard URL and
PIN. `--destroy <id>` removes it.

Inside an existing Debian/Ubuntu container or VM, the installer does the rest:

```bash
curl -fsSL https://raw.githubusercontent.com/ethanbanker/altkeeper/main/install.sh | sudo bash
```

The script builds the image, creates `/opt/altkeeper` with a generated dashboard PIN, and starts
the service. Re-run the same command to update. Options can be passed after `-s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/ethanbanker/altkeeper/main/install.sh \
  | sudo bash -s -- --pairing /root/rp-pairing.plist
```

A cloned checkout can run `./install.sh --help`.

To remove it (container, image, generated config; keeps pairing/account/backups):

```bash
curl -fsSL https://raw.githubusercontent.com/ethanbanker/altkeeper/main/uninstall.sh | sudo bash
```

Add `--purge` to delete the data too, and `--docker` if the installer also installed Docker.

## Choose a guide

| I want to… | Guide |
| --- | --- |
| Set up AltKeeper and pair my iPhone | [Quick start](docs/en/quick-start.md) |
| Choose Docker, Windows, or macOS deployment | [Deployment](docs/en/deployment.md) |
| Run it in Docker inside a Proxmox LXC | [Proxmox LXC](docs/en/proxmox-lxc.md) |
| Install with one command | [`install.sh`](install.sh) (see Quick install above) |
| Host my own Anisette V3 server | [Local Anisette server](docs/en/anisette-server.md) |
| Sign in, renew apps, or manage multiple devices | [Accounts and renewals](docs/en/accounts-and-renewals.md) |
| Use the web dashboard, install an IPA, or enable JIT | [Web and JIT](docs/en/web-and-jit.md) |
| Connect from outside my home network | [Remote access](docs/en/remote-access.md) |
| Diagnose a problem or protect my data | [Troubleshooting and security](docs/en/troubleshooting-and-security.md) |

Prefer Italian? Start at [README in italiano](README.it.md) or browse the [Italian guides](docs/it/README.md).

## At a glance

- **AltServer mode:** AltStore Classic can refresh and install apps through AltKeeper.
- **Independent renewal:** renew profiles from the CLI, dashboard, or an optional schedule.
- **Device profiles:** keep pairing, account, settings, and renewal state separate for each iPhone.
- **Local Anisette V3:** a server on `127.0.0.1:8788` for Linux (Docker included), macOS, and
  Windows; its native libraries are downloaded automatically when missing.
- **JIT:** dashboard actions and an HTTP API are available to compatible clients. Developer Mode
  and a compatible mounted Developer Disk Image are required.

The CLI and server support Linux, macOS, and Windows; the tray app is available on macOS and
Windows. Docker is intended for Linux hosts that support host networking and Bonjour.

For private vulnerability reports, see [SECURITY.md](SECURITY.md). Third-party licenses are listed
in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
