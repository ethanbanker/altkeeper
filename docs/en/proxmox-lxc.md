# Proxmox LXC (Docker inside the container)

AltKeeper runs unchanged inside Docker on a Proxmox LXC. There is no USB passthrough in an
unprivileged container, so the iPhone is reached over Wi-Fi with a pairing file created once on
another computer.

## LXC prerequisites

Docker needs a nesting-capable container. On the Proxmox host:

```bash
# /etc/pve/lxc/<id>.conf — unprivileged container
features: nesting=1,keyctl=1
```

Then install Docker inside the LXC as usual. For multicast to reach the LXC, keep the container
on a bridged interface (`vmbr0`) and do not enable multicast snooping filtering on that bridge.
Do not put AltKeeper on a Docker bridge network: `network_mode: host` is required so that mDNS
(port 5353), AltServer (49500) and the dashboard (8787) are visible on the LAN.

Ports used, all inside the LXC network namespace:

| Port | Purpose |
| --- | --- |
| 8787 | Web dashboard (PIN-protected when bound to `0.0.0.0`) |
| 49500 | AltServer, used by AltStore Classic |
| 5353 | mDNS/Bonjour (shared, UDP) |
| 8788 | Optional local Anisette, loopback only |
| 5533 | Optional DNS-SD, only with `--dns-domain` |

## 1. Pairing file (once)

USB pairing needs `usbmuxd` and the USB bus, which an unprivileged LXC does not expose. Create the
pairing on a Mac/Windows/Linux machine that can see the iPhone over USB:

```bash
altkeeper pair-usb            # writes rp-pairing.plist
```

Copy the resulting `rp-pairing.plist` to `/srv/altkeeper/rp-pairing.plist` on the Proxmox host and
`chmod 600` it. Treat it as a secret: it is enough to talk to that iPhone.

If you run a privileged LXC and pass through `/var/run/usbmuxd` plus `/dev/bus/usb`, the dashboard's
**Pair over USB** action also works; in that case remove `ALTKEEPER_NO_AUTO_PAIR=1` from the Compose
file. Most users should not do this.

## 2. Start it

The installer below does the build, the PIN, the Compose file and the start for you, using
`/opt/altkeeper`:

```bash
curl -fsSL https://raw.githubusercontent.com/ethanbanker/altkeeper/main/install.sh | sudo bash
```

It also copies `rp-pairing.plist` if it is in `/opt/altkeeper/` or passed with `--pairing`. The
manual equivalent follows, using `/srv/altkeeper`:

```bash
mkdir -p /srv/altkeeper
printf 'ALTKEEPER_WEB_PIN=%s\n' "$(openssl rand -hex 8)" > /srv/altkeeper/.env
chmod 600 /srv/altkeeper/.env
cp rp-pairing.plist /srv/altkeeper/
cp examples/docker-compose.lxc.yml /srv/altkeeper/docker-compose.yml
cd /srv/altkeeper
docker compose up -d
```

Build the image from a checkout on the LXC (or on another amd64 machine and `docker save`/`load`
it):

```bash
docker build --platform linux/amd64 -t altkeeper:latest .
```

Open `http://<lxc-ip>:8787/` and enter the PIN as the password (any username).

## 3. Finding the iPhone

Bonjour sometimes cannot cross an LXC bridge. AltKeeper already tolerates that: Bonjour
advertisement failure is logged and the service keeps running. If discovery is slow or fails:

1. Open the dashboard and save the iPhone address (Settings → iPhone addresses), for example
   `192.168.1.42:49152`. The port is the `_remotepairing._tcp` port shown by the pairing tool,
   usually 49152. Give the iPhone a DHCP reservation so the address does not change.
2. Optionally set `ALTKEEPER_NO_MDNS=1` in the Compose file to skip the Bonjour wait on each
   check.

If the log alternates between "phone is unreachable" and "disconnected", check the LXC bridge:
Proxmox bridges with IGMP snooping drop multicast from containers, and Wi-Fi access points with
client isolation block phone-to-container traffic entirely. A wired LXC and a saved iPhone address
is the reliable setup.

The one-minute background check yields to AltServer: while AltStore is using the phone it skips
instead of opening a second pairing session, because iOS drops one of two concurrent sessions.

To let AltStore Classic find AltKeeper from outside the home network, use the DNS-SD mode
(`--dns-domain` / `--dns-address`); see [Remote access](remote-access.md).

## 4. Health and updates

```bash
docker inspect --format '{{.State.Health.Status}}' altkeeper   # healthy
curl -fsS http://127.0.0.1:8787/healthz                        # ok
docker logs -f altkeeper
```

The data volume `/srv/altkeeper` holds pairing, account, `state/`, backups and logs. Back it up.
After `docker compose pull`/rebuild, `docker compose up -d` restarts the container; the health
check waits for the dashboard before reporting healthy. With the installer, re-running the same
command updates the source, rebuilds and restarts, keeping the data and the PIN.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Container exits right after start | No `ALTKEEPER_WEB_PIN` while bound to `0.0.0.0`. Check `docker logs`. |
| Dashboard reachable, phone never found | mDNS blocked, IGMP snooping on the bridge, Wi-Fi client isolation, or a changed iPhone IP. Save the address in the dashboard; try `ALTKEEPER_NO_MDNS=1`. |
| AltStore cannot see the server | `network_mode: host` missing, port 49500 blocked, or multicast blocked. A saved phone address does not fix AltStore discovery — use DNS-SD mode. |
| `Bonjour advertisement failed` in logs | Port 5353 already owned (avahi in the LXC) or multicast blocked. Non-fatal; discovery by address still works. |
| Settings changes do not persist | `/srv/altkeeper` is not mounted at `/data`, or the volume is not writable by root. |
