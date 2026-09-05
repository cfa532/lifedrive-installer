# LifeDrive Installer

This public repository contains versioned LifeDrive installation assets built from the private LifeAlbum source repository.

On the Leither server, run:

```bash
npx --yes @inoku/lifedrive
```

To upgrade an existing key-auth installation without changing its authorized devices, public address, or drive data, run:

```bash
npx --yes @inoku/lifedrive@latest --upgrade
```

The installer first confirms that the Leither service is running, then finds its executable directory automatically. It stops without downloading or installing LifeDrive when Leither is absent. If the server deliberately runs multiple Leither instances, select one explicitly:

```bash
npx --yes @inoku/lifedrive --leither-root /path/to/leither
```

The npm package contains the versioned installer, checksum, and LifeDrive bundle. After npm supplies the package, setup does not depend on GitHub's release-asset network. If npm is unavailable, use the GitHub release bootstrap directly:

```bash
curl -fLO https://github.com/cfa532/lifedrive-installer/releases/latest/download/lifedrive-install.sh
chmod +x lifedrive-install.sh
./lifedrive-install.sh
```

The bootstrap verifies `lifedrive-bundle.tar.gz` against its SHA-256 file, installs it below the detected Leither root, and runs the interactive terminal setup. The npm launcher reads those assets from its own package; the standalone bootstrap downloads them from the matching GitHub Release. All installer options after the npm package name pass through to that bootstrap.

Setup uses the built-in AV1 registration endpoint and does not ask users for a service URL, AV1 login, or developer-issued code. A user who deliberately chooses `--skip-domain` receives a direct LAN URL containing the detected server address, configured Leither port, published app MID, and `ver=last`.

LifeDrive requires Leither V0.24.11 or newer. Fresh setup creates a separate Ed25519 `sodiumv2` identity for the primary browser and prints the path to a protected identity file. Import that file once from the LifeDrive sign-in screen; afterward the browser signs short-lived PPTs locally and login is automatic. Add another independent device with `npx --yes @inoku/lifedrive --add-device "Device label"`. List or revoke device keys with `--list-devices` and `--revoke-device <uid>`.

An existing installation is backed up before replacement. The explicit `--upgrade` path requires the saved application and key-auth owner state before changing files, republishes the same application MID, and does not rerun device or domain setup. This release intentionally does not migrate the earlier password-owner prototype. Application files are active only after Leither advances the application from `cur` to `last`; a publication timeout leaves the prior `last` version serving users.

Source code and design documentation are maintained separately. No device key, identity bundle, PPT, publisher key, or node-specific application MID is included in these release assets.
