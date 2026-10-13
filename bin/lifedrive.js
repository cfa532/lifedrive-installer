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
const packageVersion = require("../package.json").version;
// Desktop installers carry Node privately; their users need not have npx.
const pairingCommand = path.basename(path.resolve(__dirname, "..")) === "package"
  ? `${process.platform === "win32" ? "& " : ""}${quoteArgument(process.execPath)} ${quoteArgument(__filename)}`
  : `npx --yes @inoku/lepan@${/^\d+\.\d+\.\d+$/.test(packageVersion) ? packageVersion : "latest"}`;

function quoteArgument(value) {
  return process.platform === "win32"
    ? `'${value.replace(/'/g, "''")}'`
    : `'${value.replace(/'/g, "'\\''")}'`;
}

function pairingQrPayload(pairing) {
  const legacy = pairing.type === "lifedrive-device-identity";
  // Preserve every field consumed by the existing mobile importers. The full
  // original identity stays in the JSON file, including unused metadata.
  const fields = legacy ? [
    "type", "version", "app_id", "uid", "label", "public_username", "key_type",
    "public_key", "private_key", "signer_info", "node_id",
  ] : [
    "type", "version", "app_id", "node_id", "endpoint", "transport",
    "transport_key", "certificate_sha256", "request_id", "secret",
  ];
  const qr = Object.fromEntries(fields.filter(key => Object.hasOwn(pairing, key)).map(key => [key, pairing[key]]));
  if (legacy && typeof qr.private_key === "string" && typeof qr.public_key === "string") {
    // sodium's 64-byte secret includes a duplicate public key. Both Android and
    // iOS already accept the 32-byte seed and verify the derived public key.
    const secret = Buffer.from(qr.private_key, "base64url");
    const publicKey = Buffer.from(qr.public_key, "base64url");
    if (secret.length === 64 && publicKey.length === 32 && secret.subarray(32).equals(publicKey)) {
      qr.private_key = secret.subarray(0, 32).toString("base64url");
    }
    secret.fill(0);
  }
  return JSON.stringify(qr);
}

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

function printTerminalQr(modules, margin) {
  process.stdout.write("\n");
  // Explicit colors and a four-module quiet zone work on light/dark themes.
  const dark = (x, y) => x >= 0 && y >= 0 && x < modules.size && y < modules.size && modules.get(y, x);
  let terminal = "";
  for (let y = -margin; y < modules.size + margin; y += 2) {
    terminal += "\x1b[30;47m";
    for (let x = -margin; x < modules.size + margin; x += 1) {
      terminal += dark(x, y) ? (dark(x, y + 1) ? "█" : "▀") : (dark(x, y + 1) ? "▄" : " ");
    }
    terminal += "\x1b[0m\n";
  }
  process.stdout.write(terminal);
}

async function showPairingCode(resultPath, savedFile = false) {
  if (!fs.existsSync(resultPath)) return;
  const compact = savedFile || (process.argv.includes("--upgrade") && !process.argv.includes("--household"));
  // The child writes this only after setup succeeds. Never scrape its output:
  // it can contain node keys as well as the mobile device's pairing identity.
  const pairing = JSON.parse(fs.readFileSync(resultPath, "utf8"));
  if (pairing.version !== 1 || !["lifedrive-device-identity", "lifedrive-node-setup", "lifedrive-user-identity"].includes(pairing.type)) {
    throw new Error("Unsupported pairing data");
  }
  const directory = savedFile ? path.dirname(resultPath) : fs.readFileSync(`${resultPath}.directory`, "utf8");
  if (!path.isAbsolute(directory)) throw new Error("Invalid pairing image directory");
  const payload = JSON.stringify(pairing);
  const qrPayload = pairingQrPayload(pairing);
  const basename = path.join(directory, `lepan-pairing-${randomUUID()}`);
  const imagePath = `${basename}.png`;
  const identityPath = savedFile ? resultPath : `${basename}.json`;
  // Older mobile releases support importing this file but have no setup scanner.
  // Keep a private copy even when QR generation succeeds.
  if (!savedFile) fs.writeFileSync(identityPath, payload, { flag: "wx", mode: 0o600 });
  const options = { errorCorrectionLevel: "M", margin: 4, scale: 8 };
  const privacyNote = pairing.type !== "lifedrive-device-identity"
    ? "Keep it private. This invitation expires ten minutes after creation."
    : "This is a persistent device identity; it does not expire after ten minutes. It remains usable while the device is authorized.\nIt contains your device private key. Keep the original safe and offline; delete transfer copies after pairing.";
  const expiry = pairing.type !== "lifedrive-device-identity" && Number.isFinite(pairing.expires)
    ? `\nInvitation expiry: ${new Date(pairing.expires * 1000).toISOString()} (UTC).\n${pairing.expires <= Date.now() / 1000 ? "This invitation has expired. Create a fresh invitation before pairing.\n" : ""}` : "";
  const reopenHint = `\nTo show this QR again, run on this computer (on the node for an SSH session):\n  ${pairingCommand} --show-qr ${quoteArgument(identityPath)}\nThis only displays the saved pairing code; it does not install or upgrade LePan.\n`;
  const nodeRoot = process.platform === "win32" && path.basename(directory) === ".lifedrive-household"
    ? path.dirname(directory) : directory;
  // A saved file may have been moved off the node. Its new parent is not proof
  // of the original Leither root; let node discovery choose in that case.
  const renewalRoot = savedFile ? "" : ` --leither-root ${quoteArgument(nodeRoot)}`;
  const renewalHint = pairing.type === "lifedrive-node-setup"
    ? `\nInvitation expired? Run this again on the node before the first owner is created:\n  ${pairingCommand}${renewalRoot} --household\n`
    : pairing.type === "lifedrive-user-identity"
      ? `\nInvitation expired? Run the same reconnect command again on the node${pairing.user_id ? `:\n  ${pairingCommand}${renewalRoot} --recover-device ${quoteArgument(pairing.user_id)}` : "."}\n` : "";
  let modules;
  try {
    const QRCode = require("qrcode");
    // A clean terminal can use lower error correction to reduce its width.
    // Keep medium correction and the full quiet zone in the saved PNG.
    modules = QRCode.create(qrPayload, { ...options, errorCorrectionLevel: "L" }).modules;
    // Unique names and exclusive creation avoid overwriting another device's
    // code or following a pre-existing symlink. Keep this outside the app bundle.
    if (!savedFile) {
      const png = await QRCode.toBuffer(qrPayload, options);
      fs.writeFileSync(imagePath, png, { flag: "wx", mode: 0o600 });
    }
  } catch {
    if (savedFile) {
      process.stderr.write("The QR code could not be displayed. Open the saved QR image instead.\n");
      process.exitCode = 1;
      return;
    }
    // The child no longer prints secrets. Preserve an importable fallback
    // before runInstaller removes the temporary handoff directory.
    if (compact) {
      process.stderr.write(`\nThe QR code could not be created. In LePan, open Settings > Set up users > Choose identity file.\nPairing file: ${identityPath}\nKeep it private.\n`);
      process.stderr.write(expiry);
      process.stderr.write(`\nHelp:\n  ${pairingCommand} --help\n`);
      return;
    }
    process.stderr.write("\nNext: pair your phone\n\nThe QR code could not be created. Use the saved pairing file instead.\n");
    process.stderr.write(`  ${identityPath}\n\n`);
    process.stderr.write("Transfer this file to your phone, then select it in LePan > Settings > Set up users > Choose identity file.\n");
    process.stderr.write(`${privacyNote}\n`);
    process.stderr.write(expiry);
    process.stderr.write(reopenHint);
    process.stderr.write(renewalHint);
    if (pairing.type !== "lifedrive-device-identity") {
      process.stderr.write("Redisplaying the QR does not extend the invitation's ten-minute expiry.\n");
    }
    return;
  }
  // Only print a terminal QR when the complete code fits. Otherwise, explain
  // the required size and offer the saved image instead of a wrapped/clipped QR.
  const width = modules.size + options.margin * 2;
  const widthMarker = `|${"-".repeat(width - 1)}|`;
  const height = Math.ceil(width / 2);
  const fitsWidth = process.stdout.isTTY && process.stdout.columns > width;
  const fitsScreen = fitsWidth && process.stdout.rows >= height + 3;
  // Redisplaying is deliberately quiet and creates no additional files.
  if (savedFile) {
    if (!process.stdout.isTTY) {
      process.stdout.write("Run --show-qr in an interactive terminal.\n");
    } else if (!fitsScreen) {
      process.stdout.write(`Terminal too small for the QR code: ${width + 1} columns and ${height + 3} rows needed.\n${widthMarker}\nResize the terminal, then run the same command again.\n`);
    } else {
      process.stdout.write("Keep it private.\n");
      process.stdout.write(expiry);
      printTerminalQr(modules, options.margin);
    }
    return;
  }
  const imageOpened = !fitsScreen && openPairingImage(imagePath);
  if (compact) {
    process.stdout.write("\nHow to pair your phone:\nOpen LePan > Settings > Set up users > Scan QR code.\n");
    if (imageOpened) process.stdout.write("\nThe QR image has opened automatically.\n");
    if (!fitsScreen) {
      process.stdout.write(process.stdout.isTTY
        ? `\nThe QR code needs ${width + 1} columns and ${height + 3} rows. Resize this terminal or open the saved image.\n${widthMarker}\nTo display it here, resize and run:\n`
        : "\nTo display the QR code, run in an interactive terminal:\n");
      process.stdout.write(`\n  ${pairingCommand} --show-qr ${quoteArgument(identityPath)}\n`);
    }
    process.stdout.write(`\nSaved QR image: ${imagePath}\nPairing file (Choose identity file): ${identityPath}\n`);
    process.stdout.write(expiry);
    process.stdout.write(`\nHelp:\n  ${pairingCommand} --help\n`);
  } else {
    process.stdout.write("\nPair your phone\n\n");
    process.stdout.write("Open LePan > Settings > Set up users > Scan QR code.\n");
    process.stdout.write(imageOpened
      ? "The QR image has opened automatically. Scan it with your phone.\n"
      : fitsScreen ? "Scan the QR code below with your phone.\n"
      : process.stdout.isTTY
        ? `The QR code needs ${width + 1} columns and ${height + 3} rows. Resize this terminal or open the saved image.\n`
        : "A QR code cannot be displayed in this output. Run the --show-qr command below in an interactive terminal, or open the saved QR image.\n");
    if (!fitsScreen && process.stdout.isTTY) process.stdout.write(`${widthMarker}\n`);
    process.stdout.write(`${privacyNote}\n`);
    process.stdout.write(expiry);
    process.stdout.write(`\nSaved QR image: ${imagePath}\n`);
    process.stdout.write(`Pairing file (Choose identity file): ${identityPath}\n`);
    process.stdout.write("To import the file, transfer it privately to your phone, then open\nLePan > Settings > Set up users > Choose identity file.\n");
    process.stdout.write(reopenHint);
    process.stdout.write("Keep this computer on and connected while using LePan.\n");
    process.stdout.write(renewalHint);
    if (pairing.type !== "lifedrive-device-identity") {
      process.stdout.write("Redisplaying the QR does not extend the invitation's ten-minute expiry.\n");
    }
  }
  if (fitsScreen) {
    printTerminalQr(modules, options.margin);
  }
}

async function runInstaller(command, args) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "lepan-pairing-"));
  const resultPath = path.join(work, "pairing.json");
  try {
    const result = spawnSync(command, args, {
      stdio: "inherit",
      env: { ...process.env, LIFEDRIVE_PAIRING_RESULT: resultPath, LIFEDRIVE_PAIRING_COMMAND: pairingCommand },
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
        process.stderr.write(`\nHelp:\n  ${pairingCommand} --help\n`);
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
    ["--recover-device", "-RecoverDevice"],
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
  const argumentsList = process.argv.slice(2);
  if (argumentsList.some(argument => argument === "--show-qr" || argument.startsWith("--show-qr="))) {
    const file = argumentsList[0] === "--show-qr" && argumentsList.length === 2
      ? argumentsList[1]
      : argumentsList.length === 1 && argumentsList[0].startsWith("--show-qr=")
        ? argumentsList[0].slice("--show-qr=".length) : "";
    if (!file || file.startsWith("--")) throw new Error("Use --show-qr FILE by itself to display a saved identity or invitation.");
    const identityPath = path.resolve(file);
    if (!fs.existsSync(identityPath)) throw new Error("The saved identity or invitation file was not found. Use the path printed during setup or upgrade.");
    // JSON parse failures can contain private identity data. Keep them off stderr.
    try { await showPairingCode(identityPath, true); }
    catch { throw new Error("Could not display the pairing file. Choose a readable LePan identity or invitation JSON file."); }
    return;
  }
  if (argumentsList.includes("--help") || argumentsList.includes("-h")) {
    process.stdout.write(`Pairing help:
  --show-qr FILE  Display a saved identity or invitation as a QR code.

  Example:
    ${pairingCommand} --show-qr '/path/to/lepan-pairing.json'

Run pairing commands on the computer running Leither. If the QR does not fit,
resize to the printed columns and rows and run --show-qr again.
You can also open the saved PNG, or transfer the JSON privately to your phone
and use LePan > Settings > Set up users > Choose identity file.

Device identity files contain persistent private keys and have no ten-minute
expiry. Keep the original safe and offline; delete transfer copies after pairing.
Setup and reconnect invitations expire ten minutes after creation. Showing the
QR again does not renew them. Use --household to renew an unclaimed first-owner
invitation, or --recover-device ACCOUNT to reconnect an existing account.
For another household device, use Settings > My devices on a paired phone.
If a saved identity file is missing, restore your private backup or use the
device-management options below.

`);
  }
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
