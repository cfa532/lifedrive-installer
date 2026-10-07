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

function openPairingImage(imagePath) {
  // A remote server must not open a window in another user's desktop session.
  if (process.env.SSH_CONNECTION || process.env.SSH_TTY) return false;
  let command;
  let args;
  if (process.platform === "darwin") {
    command = "/usr/bin/open";
    args = [imagePath];
  } else if (process.platform === "win32") {
    command = "powershell.exe";
    args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
      "Start-Process -FilePath $env:LEPAN_PAIRING_IMAGE -ErrorAction Stop"];
  } else if (process.platform === "linux" && (process.env.DISPLAY || process.env.WAYLAND_DISPLAY)) {
    command = "xdg-open";
    args = [imagePath];
  } else {
    return false;
  }
  const result = spawnSync(command, args, {
    stdio: "ignore", timeout: 5000,
    env: { ...process.env, LEPAN_PAIRING_IMAGE: imagePath },
  });
  return !result.error && result.status === 0;
}

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
  const payload = JSON.stringify(pairing);
  // Only encode fields consumed by the existing Android and iOS setup parsers.
  // The node enforces expiry and returns account details after a successful claim.
  // Keep the full invitation in the import file, and leave legacy identities intact.
  // iOS still requires certificate_sha256 even when Leither transport uses a key.
  const qrPayload = pairing.type === "lifedrive-node-setup"
    ? JSON.stringify(Object.fromEntries([
      "type", "version", "app_id", "node_id", "endpoint", "transport",
      "transport_key", "certificate_sha256", "request_id", "secret",
    ].filter(key => Object.hasOwn(pairing, key)).map(key => [key, pairing[key]])))
    : payload;
  const basename = path.join(directory, `lepan-pairing-${randomUUID()}`);
  const imagePath = `${basename}.png`;
  const identityPath = `${basename}.json`;
  // Older mobile releases support importing this file but have no setup scanner.
  // Keep a private copy even when QR generation succeeds.
  fs.writeFileSync(identityPath, payload, { flag: "wx", mode: 0o600 });
  const options = { errorCorrectionLevel: "M", margin: 4, scale: 8 };
  const privacyNote = pairing.type === "lifedrive-node-setup"
    ? "Keep it private. This invitation expires ten minutes after creation."
    : "This contains your device private key. Keep it private and delete it after pairing.";
  const renewalHint = pairing.type === "lifedrive-node-setup"
    ? "\nInvitation expired? Run this again on the node:\n  npx --yes @inoku/lepan@latest --household\n"
    : "";
  let modules;
  try {
    const QRCode = require("qrcode");
    const png = await QRCode.toBuffer(qrPayload, options);
    modules = QRCode.create(qrPayload, options).modules;
    // Unique names and exclusive creation avoid overwriting another device's
    // code or following a pre-existing symlink. Keep this outside the app bundle.
    fs.writeFileSync(imagePath, png, { flag: "wx", mode: 0o600 });
  } catch {
    // The child no longer prints secrets. Preserve an importable fallback
    // before runInstaller removes the temporary handoff directory.
    process.stderr.write("\nNext: pair your phone\n\nThe QR code could not be created. Use the saved pairing file instead.\n");
    process.stderr.write(`  ${identityPath}\n\n`);
    process.stderr.write("Transfer this file to your phone, then select it in LePan > Settings > Set up users > Choose identity file.\n");
    process.stderr.write(`${privacyNote}\n`);
    process.stderr.write(renewalHint);
    return;
  }
  // Never hide a terminal code just because the window is short. Open the PNG
  // automatically when the whole code cannot be visible at once, and put the
  // terminal code last so subsequent instructions cannot scroll it away.
  const width = modules.size + options.margin * 2;
  const height = Math.ceil(width / 2);
  const fitsWidth = process.stdout.isTTY && process.stdout.columns > width;
  const fitsScreen = fitsWidth && process.stdout.rows >= height + 3;
  const imageOpened = !fitsScreen && openPairingImage(imagePath);
  process.stdout.write("\nPair your phone\n\n");
  process.stdout.write("Open LePan > Settings > Set up users > Scan QR code.\n");
  process.stdout.write(imageOpened
    ? "The QR image has opened automatically. Scan it with your phone.\n"
    : fitsWidth ? "Scan the QR code below with your phone.\n"
    : "This terminal is too narrow for the QR code and no image viewer could be opened. Open the saved image below.\n");
  process.stdout.write(`${privacyNote}\n`);
  process.stdout.write(`\nSaved QR image: ${imagePath}\n`);
  process.stdout.write(`Pairing file (Choose identity file): ${identityPath}\n`);
  process.stdout.write("Keep this computer on and connected while using LePan.\n");
  process.stdout.write(renewalHint);
  if (fitsWidth) {
    process.stdout.write("\n");
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
        process.stderr.write("\nPhone pairing could not be prepared. Use your existing identity file, or create a new setup invitation from the node.\n");
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
