#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { randomUUID } = require("node:crypto");
const { spawnSync } = require("node:child_process");
const { pathToFileURL } = require("node:url");

const distributionDirectory = path.resolve(__dirname, "..", "dist");
const bundlePath = path.join(distributionDirectory, "lifedrive-bundle.tar.gz");
const checksumPath = `${bundlePath}.sha256`;

async function showPairingCode(resultPath) {
  if (!fs.existsSync(resultPath)) return;
  // The child writes this only after setup succeeds. Never scrape its output:
  // it can contain node keys as well as the mobile device's pairing identity.
  const pairing = JSON.parse(fs.readFileSync(resultPath, "utf8"));
  if (pairing.version !== 1 || !["lifedrive-device-identity", "lifedrive-node-setup"].includes(pairing.type)) {
    throw new Error("Unsupported pairing data");
  }
  const directory = fs.readFileSync(`${resultPath}.directory`, "utf8");
  if (!path.isAbsolute(directory)) throw new Error("Invalid pairing image directory");
  const QRCode = require("qrcode");
  const payload = JSON.stringify(pairing);
  const options = { errorCorrectionLevel: "M", margin: 4, scale: 8 };
  const png = await QRCode.toBuffer(payload, options);
  // Unique names and exclusive creation avoid overwriting another device's
  // code or following a pre-existing symlink. Keep this outside the app bundle.
  const imagePath = path.join(directory, `lepan-pairing-${randomUUID()}.png`);
  fs.writeFileSync(imagePath, png, { flag: "wx", mode: 0o600 });
  process.stdout.write(`\nPair your phone: open LePan → Settings → Set up users → Scan QR code.\n`);
  process.stdout.write(`Pairing image saved: ${imagePath}\n`);
  process.stdout.write(pairing.type === "lifedrive-node-setup"
    ? "Keep this code private. The invitation expires ten minutes after creation.\n"
    : "This code contains your device private key. Keep it private and delete the image after pairing.\n");
  // Small terminal codes use half-height blocks. If the terminal would wrap,
  // direct the user to the full-resolution PNG instead of a broken code.
  const modules = QRCode.create(payload, options).modules;
  const width = modules.size + options.margin * 2;
  if (process.stdout.isTTY && (!process.stdout.columns || process.stdout.columns > width)) {
    // Explicit colors and a four-module quiet zone work on light/dark themes.
    const dark = (x, y) => x >= 0 && y >= 0 && x < modules.size && y < modules.size && modules.get(y, x);
    let terminal = "";
    for (let y = -options.margin; y < modules.size + options.margin; y += 2) {
      terminal += "\x1b[30;47m";
      for (let x = -options.margin; x < modules.size + options.margin; x += 1) {
        terminal += dark(x, y) ? (dark(x, y + 1) ? "█" : "▀") : (dark(x, y + 1) ? "▄" : " ");
      }
      terminal += "\x1b[0m\n";
    }
    process.stdout.write(terminal);
  } else {
    process.stdout.write("Open the saved PNG on this computer to scan it.\n");
  }
}

async function runInstaller(command, args) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "lepan-pairing-"));
  const resultPath = path.join(work, "pairing.json");
  try {
    const result = spawnSync(command, args, {
      stdio: "inherit",
      env: { ...process.env, LIFEDRIVE_PAIRING_RESULT: resultPath },
    });
    if (result.error) throw result.error;
    if (typeof result.status === "number") process.exitCode = result.status;
    else if (result.signal === "SIGINT") process.exitCode = 130;
    else if (result.signal === "SIGTERM") process.exitCode = 143;
    else process.exitCode = 1;
    if (process.exitCode === 0) {
      try { await showPairingCode(resultPath); }
      catch {
        // Parser errors may contain identity text; never print them.
        process.stderr.write("LePan is installed, but its pairing QR code could not be created. Use the identity file or invitation shown above.\n");
      }
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

function windowsArguments(values) {
  const valueOptions = new Map([
    ["--leither-root", "-LeitherRoot"],
    ["--storage-max-gb", "-StorageMaxGB"],
  ]);
  const switches = new Map([
    ["--no-install-leither", "-NoInstallLeither"],
    ["--leither-service", "-LeitherService"],
    ["--upgrade", "-Upgrade"],
    ["--household", "-Household"],
    ["--help", "-Help"],
    ["-h", "-Help"],
  ]);
  const translated = [];
  for (let index = 0; index < values.length; index += 1) {
    const argument = values[index];
    const equals = argument.indexOf("=");
    const option = equals >= 0 ? argument.slice(0, equals) : argument;
    if (valueOptions.has(option)) {
      const value = equals >= 0 ? argument.slice(equals + 1) : values[++index];
      if (!value || value.startsWith("-")) throw new Error(`${option} needs a value.`);
      translated.push(valueOptions.get(option), value);
    } else if (switches.has(argument)) {
      translated.push(switches.get(argument));
    } else {
      throw new Error(`Unsupported Windows installer option: ${argument}`);
    }
  }
  return translated;
}

async function main() {
  if (process.platform === "win32") {
    const installerPath = path.join(distributionDirectory, "lifedrive-install.ps1");
    if (![installerPath, bundlePath, checksumPath].every(candidate => fs.existsSync(candidate))) {
      throw new Error("The npm package is incomplete. Reinstall @inoku/lepan and try again.");
    }
    await runInstaller(
      "powershell.exe",
      ["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", installerPath,
        "-PackageDirectory", distributionDirectory, ...windowsArguments(process.argv.slice(2))]
    );
    return;
  }

  if (process.platform !== "linux" && process.platform !== "darwin") {
    throw new Error("LePan setup supports native Linux, macOS, and x64 Windows Leither servers.");
  }
  const installerPath = path.join(distributionDirectory, "lifedrive-install.sh");
  if (!fs.existsSync("/bin/bash")) {
    throw new Error("LePan setup requires /bin/bash.");
  }
  if (![installerPath, bundlePath, checksumPath].every(candidate => fs.existsSync(candidate))) {
    throw new Error("The npm package is incomplete. Reinstall @inoku/lepan and try again.");
  }

  const localReleaseBase = pathToFileURL(distributionDirectory).href.replace(/\/$/, "");
  await runInstaller(
    "/bin/bash",
    [installerPath, "--release-base", localReleaseBase, ...process.argv.slice(2)]
  );
}

main().catch(error => {
  process.stderr.write(`LePan installer stopped: ${error.message}\n`);
  process.exitCode = 1;
});
