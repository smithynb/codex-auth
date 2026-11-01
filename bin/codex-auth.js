#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { createHash } from "node:crypto";
import os from "node:os";
import readline from "node:readline";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const require = createRequire(import.meta.url);
const rootPackageJsonPath = path.join(__dirname, "..", "package.json");

const packageMap = {
  "linux:x64": "@loongphy/codex-auth-linux-x64",
  "linux:arm64": "@loongphy/codex-auth-linux-arm64",
  "darwin:x64": "@loongphy/codex-auth-darwin-x64",
  "darwin:arm64": "@loongphy/codex-auth-darwin-arm64",
  "win32:x64": "@loongphy/codex-auth-win32-x64",
  "win32:arm64": "@loongphy/codex-auth-win32-arm64"
};

function readRootPackage() {
  try {
    return JSON.parse(fs.readFileSync(rootPackageJsonPath, "utf8"));
  } catch {
    return null;
  }
}

function maybePrintPreviewVersion(argv) {
  if (argv.length !== 1) return false;
  if (argv[0] !== "--version" && argv[0] !== "-V") return false;

  const rootPackage = readRootPackage();
  if (!rootPackage) return false;

  const previewLabel = rootPackage.codexAuthPreviewLabel;
  if (typeof previewLabel !== "string" || previewLabel.length === 0) return false;
  if (typeof rootPackage.version !== "string" || rootPackage.version.length === 0) return false;

  process.stdout.write(`codex-auth ${rootPackage.version} (preview ${previewLabel})\n`);
  return true;
}

if (maybePrintPreviewVersion(process.argv.slice(2))) {
  process.exit(0);
}

function resolveBinary() {
  // Keep native source customizations active when running from a personal checkout.
  const binaryName = process.platform === "win32" ? "codex-auth.exe" : "codex-auth";
  const localBinary = path.join(__dirname, "..", "zig-out", "bin", binaryName);
  if (fs.existsSync(localBinary)) return localBinary;

  const key = `${process.platform}:${process.arch}`;
  const packageName = packageMap[key];
  if (!packageName) {
    console.error(`Unsupported platform: ${process.platform}/${process.arch}`);
    process.exit(1);
  }

  try {
    const packageRoot = path.dirname(require.resolve(`${packageName}/package.json`));
    const binaryPath = path.join(packageRoot, "bin", binaryName);
    if (!fs.existsSync(binaryPath)) {
      console.error(`Missing binary inside ${packageName}: ${binaryPath}`);
      process.exit(1);
    }
    return binaryPath;
  } catch (error) {
    console.error(
      `Missing platform package ${packageName}. Reinstall @loongphy/codex-auth on ${process.platform}/${process.arch}.`
    );
    if (error && error.message) {
      console.error(error.message);
    }
    process.exit(1);
  }
}

// Offer a daemon restart only after an interactive account change.
function authFingerprint() {
  try {
    const home = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
    return createHash("sha256").update(fs.readFileSync(path.join(home, "auth.json"))).digest("hex");
  } catch {
    return null;
  }
}

function activeAccountKey() {
  const home = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
  const key = JSON.parse(fs.readFileSync(path.join(home, "accounts", "registry.json"), "utf8")).active_account_key;
  if (typeof key !== "string" || key.length === 0) throw new Error("Missing active account");
  return key;
}

async function offerDaemonRestart(binaryPath, selectedAuth) {
  let accountKey;
  try {
    accountKey = activeAccountKey();
  } catch {
    console.error("Account switched, but the active account could not be read for daemon recovery.");
    return 1;
  }
  const answer = await new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stderr });
    rl.on("close", () => resolve(null));
    rl.on("SIGINT", () => rl.close());
    rl.question("Restart Codex daemon now? [Y/n] ", (value) => {
      resolve(value);
      rl.close();
    });
  });
  if (answer === null || !/^(y|yes)?$/i.test(answer.trim())) return 0;

  try {
    if (authFingerprint() !== selectedAuth || activeAccountKey() !== accountKey) {
      console.error("The active account changed while awaiting confirmation; daemon recovery was not attempted. Retry the switch.");
      return 1;
    }
  } catch {
    console.error("The active account could not be confirmed; daemon recovery was not attempted. Retry the switch.");
    return 1;
  }

  const restart = spawnSync(binaryPath, ["switch", accountKey, "--json", "--restart-daemon"], {
    stdio: ["ignore", "pipe", "inherit"]
  });
  if (restart.error || restart.signal || restart.status !== 0) {
    console.error(`Account switched, but daemon recovery failed: ${restart.error?.message || restart.signal || `exit ${restart.status}`}`);
    console.error("Retry with: codex-auth switch <account> --restart-daemon");
    return 1;
  }
  return 0;
}

const argv = process.argv.slice(2);

// Personal commands: poke and its aliases ping accounts and are handled entirely in Node.
const POKE_COMMANDS = ['poke', 'tickle', 'ping'];
if (POKE_COMMANDS.includes(argv[0])) {
  const { runPoke } = await import('./personal-poke.mjs');
  const binaryPath = resolveBinary();
  process.exit(await runPoke({ binaryPath, argv: argv.slice(1) }));
}
if (argv[0] === 'help' && POKE_COMMANDS.includes(argv[1])) {
  const { pokeHelp } = await import('./personal-poke.mjs');
  process.stdout.write(pokeHelp);
  process.exit(0);
}

function personalHelpBlock() {
  const color = process.stdout.isTTY && !('NO_COLOR' in process.env) && process.env.TERM !== 'dumb';
  // Magenta distinguishes personal commands from the native cyan help.
  const m = color ? "\x1b[1;35m" : ""; // bold magenta
  const c = color ? "\x1b[35m" : "";   // magenta
  const d = color ? "\x1b[2;35m" : ""; // dim magenta
  const r = color ? "\x1b[0m" : "";    // reset
  return (
    `${m}Personal commands:${r}\n` +
    `  ${c}poke${r} [--dry-run] [--model <name>] [--timeout <secs>]\n` +
    `      ${d}Ping unstarted five-hour windows; skip active ones (aliases: ${POKE_COMMANDS.slice(1).join(', ')})${r}\n`
  );
}

function isTopLevelHelp(args) {
  return args.length === 0 || (args.length === 1 && ['--help', '-h', 'help'].includes(args[0]));
}

const shouldOfferRestart = argv[0] === "switch"
  && !argv.some((arg) => ["--json", "--help", "-h", "--restart-daemon"].includes(arg))
  && process.stdin.isTTY && process.stderr.isTTY;
const previousAuth = shouldOfferRestart ? authFingerprint() : null;
const binaryPath = resolveBinary();

// Print personal commands at the top before native help.
if (isTopLevelHelp(argv)) {
  process.stdout.write("\n" + personalHelpBlock() + "\n");
}

const child = spawnSync(binaryPath, argv, {
  stdio: "inherit"
});

if (child.error) {
  console.error(child.error.message);
  process.exit(1);
}

if (child.signal) {
  process.kill(process.pid, child.signal);
} else {
  if (child.status === 0 && shouldOfferRestart) {
    const currentAuth = authFingerprint();
    if (currentAuth !== null && currentAuth !== previousAuth) process.exit(await offerDaemonRestart(binaryPath, currentAuth));
  }
  process.exit(child.status ?? 1);
}
