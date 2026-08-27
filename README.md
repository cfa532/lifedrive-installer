# LifeDrive Installer

This public repository contains versioned LifeDrive installation assets built from the private LifeAlbum source repository.

On the Leither server, run:

```bash
npx --yes @inoku/lifedrive
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

The bootstrap verifies `lifedrive-bundle.tar.gz` against its SHA-256 file, installs it below the detected Leither root, and runs the interactive SSH setup. The npm launcher reads those assets from its own package; the standalone bootstrap downloads them from the matching GitHub Release. All installer options after the npm package name pass through to that bootstrap.

Setup uses the built-in AV1 registration endpoint and does not ask users for a service URL. A user who deliberately chooses `--skip-domain` receives a direct LAN URL containing the detected server address, configured Leither port, published app MID, and `ver=last`.

Source code and design documentation are maintained separately. No private key, password, enrollment code, or node-specific application MID is included in these release assets.
