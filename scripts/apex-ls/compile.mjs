#!/usr/bin/env node
// Compiles every package folder in sfdx-project.json with apex-ls. No org is necessary.
// Needs Java, apex-ls (scripts/apex-ls/fetch-apex-ls.sh) and the submodules
// (git submodule update --init --recursive).
// Set REQUIRE_APEX_LS=1 to fail when Java or apex-ls is missing.
// Set APEX_PACKAGES to a comma list of package folders to compile only those.
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const LIB = join(ROOT, "scripts", "apex-ls", ".apex-ls", "lib");

/** The apex-ls classpath, or null when apex-ls is not downloaded. */
export function classpath() {
  if (process.env.APEX_LS_CLASSPATH) return process.env.APEX_LS_CLASSPATH;
  return existsSync(LIB) ? join(LIB, "*") : null;
}

/** Makes a temp workspace that links each package folder that has files. */
export function makeWorkspace(root = ROOT) {
  const project = JSON.parse(readFileSync(join(root, "sfdx-project.json"), "utf8"));
  const found = [];
  const missing = [];
  // APEX_PACKAGES=force-app compiles only the core, with no Revenant (AC-RV-4).
  const only = process.env.APEX_PACKAGES ? process.env.APEX_PACKAGES.split(",") : null;
  if (only) project.packageDirectories = project.packageDirectories.filter((d) => only.includes(d.path));
  for (const { path } of project.packageDirectories) {
    const dir = join(root, path);
    (existsSync(dir) && readdirSync(dir).length > 0 ? found : missing).push(path);
  }
  const ws = mkdtempSync(join(tmpdir(), "hook-apex-"));
  for (const path of found) {
    mkdirSync(dirname(join(ws, path)), { recursive: true });
    symlinkSync(join(root, path), join(ws, path), "dir");
  }
  const kept = {
    ...project,
    packageDirectories: project.packageDirectories.filter((d) => found.includes(d.path)),
  };
  writeFileSync(join(ws, "sfdx-project.json"), `${JSON.stringify(kept, null, 2)}\n`);
  return { ws, found, missing };
}

/** Runs apex-ls. Returns "File.cls:line Category: message" rows. */
export function issues(cp, ws) {
  const run = spawnSync(
    "java",
    ["-cp", cp, "io.github.apexdevtools.apexls.CheckForIssues", "-n", "-f", "json", "-w", ws],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  );
  if (run.error) throw run.error;
  // apex-ls gives exit 0 with no issue and exit 4 with issues.
  if (![0, 4].includes(run.status) || !run.stdout.includes("{")) {
    throw new Error(`apex-ls failed (exit ${run.status}): ${run.stderr}`);
  }
  const json = JSON.parse(run.stdout.slice(run.stdout.indexOf("{")));
  return json.files.flatMap((f) =>
    f.messages.map(
      (m) => `${f.path.split(/[\\/]/).pop()}:${m.start.line} ${m.category}: ${m.message}`,
    ),
  );
}

export function main() {
  const cp = classpath();
  const java = spawnSync("java", ["-version"]);
  if (!cp || java.status !== 0) {
    const why = "needs Java and apex-ls (run scripts/apex-ls/fetch-apex-ls.sh)";
    if (process.env.REQUIRE_APEX_LS) {
      console.error(`::error::${why}`);
      return 1;
    }
    console.log(`Skipped: ${why}`);
    return 0;
  }
  const { ws, found, missing } = makeWorkspace();
  try {
    if (missing.length) {
      console.log(`Note: not compiled (empty or missing): ${missing.join(", ")}.`);
      if (process.env.REQUIRE_SUBMODULES) return 1;
    }
    const rows = issues(cp, ws);
    for (const row of rows) console.log(`::error::${row}`);
    console.log(`apex-ls compiled ${found.join(", ")}: ${rows.length} issue(s).`);
    return rows.length === 0 ? 0 : 1;
  } finally {
    rmSync(ws, { recursive: true, force: true });
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exit(main());
}
