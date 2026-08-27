# LifeDrive Installer

This public repository contains versioned LifeDrive installation assets built from the private LifeAlbum source repository.

On the Leither server, run:

```bash
npx --yes @inoku/lifedrive
```

Run the command from the Leither root, or identify it explicitly:

```bash
npx --yes @inoku/lifedrive --leither-root /path/to/leither
```

The npm package is a dependency-free launcher for the versioned GitHub Release installer. If npm is unavailable, use the release bootstrap directly:

```bash
curl -fLO https://github.com/cfa532/lifedrive-installer/releases/latest/download/lifedrive-install.sh
chmod +x lifedrive-install.sh
./lifedrive-install.sh --leither-root /path/to/leither
```

The bootstrap downloads `lifedrive-bundle.tar.gz`, verifies it against the SHA-256 file attached to the same GitHub Release, installs it below the selected Leither root, and runs the interactive SSH setup. All installer options after the npm package name pass through to that bootstrap.

Source code and design documentation are maintained separately. No private key, password, enrollment code, or node-specific application MID is included in these release assets.
