# LifeDrive Installer

This public repository contains versioned LifeDrive installation assets built from the private LifeAlbum source repository.

The same `@inoku/lifedrive` npm package supports Linux and macOS on Apple Silicon/ARM64 and Intel/AMD64. Install Node.js 18 or later, then run the commands below as your normal user account (on a Mac, use Terminal). Fresh setup installs and starts Leither when it is missing. macOS includes the required Bash, curl, tar, and SHA-256 tools; Homebrew is not required by the installer.

**New to LifeDrive?** Read the [user manual](USER_MANUAL.md): installing and upgrading a node, users and devices, and what to do when a device or an identity is lost.

On the computer that will host LifeDrive, run:

```bash
npx --yes @inoku/lifedrive
```

To upgrade an existing key-auth installation without changing its authorized devices, public address, or drive data, run:

```bash
npx --yes @inoku/lifedrive@latest --upgrade
```

The installer reuses a running Leither node and finds its directory automatically. If none is running, fresh setup first looks for Leither in the selected directory, the current directory, or on `PATH`. Otherwise it installs a new node in `~/.local/share/lifedrive/leither`. It downloads the matching binary from the [official Leither distribution](http://vzhan.cn/#start.html), verifies its SHA-256 checksum, initializes local configuration and keys, installs and starts a system service, and waits for that service's process and local version endpoint before continuing with LifeDrive. Existing executables, configuration, and keys are never replaced. An existing stopped node can be started by selecting its directory.

Choose another empty directory for a fresh node, select a stopped node, or select among multiple running instances:

```bash
npx --yes @inoku/lifedrive --leither-root /path/to/leither
```

Use `--no-install-leither` to require an already running node. Upgrade and device-management commands always require a running node and never install or start Leither. A nonempty directory without a Leither executable is left untouched. New nodes use port 4800 by default; a port conflict stops setup with instructions. Leither V0.24.11 or newer is required; older existing nodes must be upgraded separately.

### Leither starts automatically at boot

Fresh setup installs a system service using `sudo`. Leither runs as the account invoking setup, using the selected node directory. It starts at boot, survives logout, and is restarted after a crash. The service manager runs `Leither run` in the foreground so it can supervise the process directly. Linux must use systemd; macOS uses a system LaunchDaemon.

| Platform | Service definition | Status and logs |
|---|---|---|
| Linux | `/etc/systemd/system/lifedrive-leither.service` | `systemctl status lifedrive-leither.service`; `journalctl -u lifedrive-leither.service` |
| macOS | `/Library/LaunchDaemons/uk.inoku.leither.plist` | `sudo launchctl print system/uk.inoku.leither`; `<Leither root>/leither-service.log` |

To configure only Leither's startup without changing LifeDrive files:

```bash
npx --yes @inoku/lifedrive --leither-service --leither-root /path/to/leither
```

Run this as the node's normal user, not with `sudo npx`. It can enable an already running service installed by this package without restarting it. A process started manually or by another service manager is left untouched: keep that manager, or stop it in a maintenance window and disable its old boot registration before adopting the package's service. A service definition with different settings or another node/account is never overwritten. Normal LifeDrive upgrades do not change or restart Leither's service. Systems without systemd can supply a running node through their own manager and use `--no-install-leither`.

The npm package contains the versioned installer, checksum, and LifeDrive bundle. After npm supplies the package, LifeDrive's files do not depend on GitHub's release-asset network. Installing a missing Leither runtime additionally needs access to `vzhan.cn`. Its official distribution currently uses HTTP with a same-source checksum; that checksum detects corrupt downloads and is not an authenticated signature. If npm is unavailable, use the GitHub release bootstrap directly (Node.js is still required):

```bash
curl -fLO https://github.com/cfa532/lifedrive-installer/releases/latest/download/lifedrive-install.sh
chmod +x lifedrive-install.sh
./lifedrive-install.sh
```

The bootstrap verifies `lifedrive-bundle.tar.gz` against its SHA-256 file, installs it below the detected Leither root, and runs the interactive terminal setup. The npm launcher reads those assets from its own package; the standalone bootstrap downloads them from the matching GitHub Release. All installer options after the npm package name pass through to that bootstrap.

Setup uses the built-in AV1 registration endpoint and does not ask users for a service URL, AV1 login, or developer-issued code. A user who deliberately chooses `--skip-domain` receives a direct LAN URL containing the detected server address, configured Leither port, published app MID, and `ver=last`.

LifeDrive requires Leither V0.24.11 or newer. Fresh setup creates a separate Ed25519 `sodiumv2` identity for the primary browser and prints the path to a protected identity file. Import that file once from the LifeDrive sign-in screen; afterward the browser signs short-lived PPTs locally and login is automatic. Add another independent device with `npx --yes @inoku/lifedrive --add-device "Device label"`. List or revoke device keys with `--list-devices` and `--revoke-device <uid>`.

An existing installation is backed up before replacement. The explicit `--upgrade` path requires the saved application and key-auth owner state before changing files, synchronizes the same published application MID, and does not rerun device or domain setup. This release intentionally does not migrate the earlier password-owner prototype. Application files are active only after Leither advances the application from `cur` to `last`; a publication timeout leaves the prior `last` version serving users.

Source code and design documentation are maintained separately. No device key, identity bundle, PPT, publisher key, or node-specific application MID is included in these release assets.

## Household users

This release includes the household identity service for Linux and macOS. Existing installations retain their application MID. An ordinary `--upgrade` installs the service files but does not automatically activate household mode.

Household activation uses the existing Leither node address. Run the matching release with `--upgrade --household`. The helper prepares private local configuration and starts the loopback identity service through systemd on Linux or launchd on macOS (sudo may be requested). It prints the one-time mobile invitation after confirming startup. No additional public hostname or TLS certificate is required. On iPhone or Android, use Settings → Set up users. Each user starts with an empty personal drive; older files are not imported.

On macOS, setup installs `/Library/LaunchDaemons/uk.inoku.lifedrive-identity.plist`. The identity service runs as your Leither account, starts at boot, and remains running after Terminal closes or you log out. Leither must also be running for LifeDrive to work. Logs are stored in `<Leither root>/.lifedrive-household/identity.log`. Stop any previously started foreground identity service before activating the daemon. The advanced `--household-config` option continues to print a manual start command for custom configurations.

The shared browser URL remains `http://drive.inoku.uk/?n=<node-id>`. Native identities persist; a paired browser stays signed in until it goes seven days without use. Direct setup requires Leither to enforce private MiMei access and stops if its checks cannot confirm that. See the source deployment notes for the HTTP transport limitations.

Once synchronized, Leither follows new publications of the same application MID. The household browser also loads that published application. Updates to the separate identity-service executable require another npm upgrade and a restart of that service. The installer never restarts Leither. Install mobile application updates separately.

After upgrading on macOS, restart only the identity service:

```bash
sudo launchctl kickstart -k system/uk.inoku.lifedrive-identity
sudo launchctl print system/uk.inoku.lifedrive-identity
curl --fail http://127.0.0.1:4811/health
```

## iPhone photo backup with your own domain

The photo HTTPS helper supports a domain controlled by the node owner. Use a
release whose `lifedrive-identity/setup-photo-https.sh --help` lists `--domain`.
Automatic setup requires an existing Linux/systemd identity service, nginx and
Python 3.9 or later. It is separate from ordinary household pairing and backup.

Create a dedicated A record, such as `photos.example.com`, pointing to the node's
public IPv4 address. Any DNS provider is supported; on Cloudflare use **DNS only**.
Public TCP ports 80 and 443 must reach nginx. Keep port 80 available for certificate
renewal. Carrier-grade NAT requires a separately configured reachable endpoint or
TLS pass-through tunnel; creating DNS does not provide connectivity.

Wait until at least one iPhone is paired with the node and its owner intends to
enable photo sync before creating this record. Node installation and pairing do
not enable iOS background photo upload. The app registers it only after explicit
Photos consent and a successful HTTPS readiness response from the paired node.

From the installed node's `lifedrive-identity` directory, run:

```bash
sudo bash setup-photo-https.sh --domain photos.example.com --agree-acme-terms
```

Replace the example hostname with yours. This accepts Let's Encrypt's subscriber
agreement, obtains a certificate and enables renewal. The helper detects the
existing service and its IPv4 HTTPS bind; if there are several binds, specify
`--https-listen ADDRESS:443`. It configures only the photo hostname, restarts only
LifeDrive identity, and checks the local HTTPS route. Leither is not restarted.
No DNS API key is required. No certificate, private key or node configuration is
included in the installer package.

The iPhone needs a LePan build containing the Photos background-upload extension
and iOS 26.5 or later. Open **Settings → Auto sync**, enable Photos with **Full
Access**, and check the photo-change backup status below **Wi-Fi only**. Paired
phones discover the address from their node; no address needs to be entered on
each phone. iOS decides when uploads run. File and Android backup use their
existing connection.

To change domains, finish pending uploads, point the new name at the node and
rerun the helper with that name. Reopen LePan on each phone after setup. The old
photo hostname is removed from the managed route after successful activation;
jobs already queued to that address may require retries. The helper restores
previous routing and identity configuration if activation fails. Old DNS records
and certificates are not deleted automatically.
