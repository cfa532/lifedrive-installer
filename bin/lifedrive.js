#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { pathToFileURL } = require("node:url");

const distributionDirectory = path.resolve(__dirname, "..", "dist");
const installerPath = path.join(distributionDirectory, "lifedrive-install.sh");
const bundlePath = path.join(distributionDirectory, "lifedrive-bundle.tar.gz");
const checksumPath = `${bundlePath}.sha256`;

function leitherServiceIsRunning() {
  const result = spawnSync("ps", ["-axo", "comm="], { encoding: "utf8" });
  if (result.error || result.status !== 0) {
    throw result.error || new Error("LifeDrive could not inspect the running services on this server.");
  }
  return result.stdout
    .split(/\r?\n/)
    .some(command => path.basename(command.trim()) === "Leither");
}

function main() {
  if (process.platform !== "linux" && process.platform !== "darwin") {
    throw new Error("LifeDrive setup currently supports Linux and macOS Leither servers.");
  }
  if (!fs.existsSync("/bin/bash")) {
    throw new Error("LifeDrive setup requires /bin/bash.");
  }
  if (!leitherServiceIsRunning()) {
    throw new Error("Leither is not running. Start the Leither service, then run this command again.");
  }
  if (![installerPath, bundlePath, checksumPath].every(candidate => fs.existsSync(candidate))) {
    throw new Error("The npm package is incomplete. Reinstall @inoku/lifedrive and try again.");
  }

  const localReleaseBase = pathToFileURL(distributionDirectory).href.replace(/\/$/, "");
  const result = spawnSync(
    "/bin/bash",
    [installerPath, "--release-base", localReleaseBase, ...process.argv.slice(2)],
    { stdio: "inherit", env: process.env }
  );
  if (result.error) throw result.error;
  if (typeof result.status === "number") process.exitCode = result.status;
  else if (result.signal === "SIGINT") process.exitCode = 130;
  else if (result.signal === "SIGTERM") process.exitCode = 143;
  else process.exitCode = 1;
}

try {
  main();
} catch (error) {
  process.stderr.write(`LifeDrive installer stopped: ${error.message}\n`);
  process.exitCode = 1;
}
