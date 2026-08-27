#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const https = require("node:https");
const os = require("node:os");
const path = require("node:path");
const { pipeline } = require("node:stream");
const { spawnSync } = require("node:child_process");

const DEFAULT_INSTALLER_URL =
  "https://github.com/cfa532/lifedrive-installer/releases/latest/download/lifedrive-install.sh";
const installerUrl = process.env.LIFEDRIVE_INSTALLER_URL || DEFAULT_INSTALLER_URL;
const maximumRedirects = 8;

function download(url, destination, redirects = 0) {
  if (redirects > maximumRedirects) {
    return Promise.reject(new Error("The installer download used too many redirects."));
  }

  return new Promise((resolve, reject) => {
    const request = https.get(
      url,
      {
        headers: {
          Accept: "application/octet-stream",
          "User-Agent": "inoku-lifedrive-installer"
        }
      },
      response => {
        const status = response.statusCode || 0;
        if (status >= 300 && status < 400 && response.headers.location) {
          response.resume();
          resolve(download(new URL(response.headers.location, url).toString(), destination, redirects + 1));
          return;
        }
        if (status !== 200) {
          response.resume();
          reject(new Error(`GitHub returned HTTP ${status || "unknown"}.`));
          return;
        }

        const output = fs.createWriteStream(destination, { mode: 0o700 });
        pipeline(response, output, error => (error ? reject(error) : resolve()));
      }
    );
    request.setTimeout(30000, () => request.destroy(new Error("The installer download timed out.")));
    request.on("error", reject);
  });
}

function leitherServiceIsRunning() {
  const result = spawnSync("ps", ["-axo", "comm="], { encoding: "utf8" });
  if (result.error || result.status !== 0) {
    throw result.error || new Error("LifeDrive could not inspect the running services on this server.");
  }
  return result.stdout
    .split(/\r?\n/)
    .some(command => path.basename(command.trim()) === "Leither");
}

async function main() {
  if (process.platform !== "linux" && process.platform !== "darwin") {
    throw new Error("LifeDrive setup currently supports Linux and macOS Leither servers.");
  }
  if (!fs.existsSync("/bin/bash")) {
    throw new Error("LifeDrive setup requires /bin/bash.");
  }
  if (!leitherServiceIsRunning()) {
    throw new Error("Leither is not running. Start the Leither service, then run this command again.");
  }

  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "lifedrive-npx-"));
  const installerPath = path.join(temporaryDirectory, "lifedrive-install.sh");
  try {
    process.stdout.write("Downloading the LifeDrive installer from GitHub...\n");
    await download(installerUrl, installerPath);
    fs.chmodSync(installerPath, 0o700);

    const result = spawnSync("/bin/bash", [installerPath, ...process.argv.slice(2)], {
      stdio: "inherit",
      env: process.env
    });
    if (result.error) throw result.error;
    if (typeof result.status === "number") process.exitCode = result.status;
    else if (result.signal === "SIGINT") process.exitCode = 130;
    else if (result.signal === "SIGTERM") process.exitCode = 143;
    else process.exitCode = 1;
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

main().catch(error => {
  process.stderr.write(`LifeDrive installer stopped: ${error.message}\n`);
  process.exitCode = 1;
});
