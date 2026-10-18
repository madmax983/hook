// Reads the global API surface from Apex source. No parser dependency.
// It reads comments out, then reads declarations statement by statement.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const MODIFIERS = new Set([
  "global", "public", "private", "protected", "static", "final", "virtual",
  "abstract", "override", "transient", "webservice", "with", "without",
  "inherited", "sharing",
]);

/** Replaces comments with spaces and empties string literals. */
export function stripComments(src) {
  let out = "";
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    const n = src[i + 1];
    if (c === "/" && n === "/") {
      while (i < src.length && src[i] !== "\n") i++;
      out += "\n";
    } else if (c === "/" && n === "*") {
      i += 2;
      while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) i++;
      i++;
      out += " ";
    } else if (c === "'") {
      i++;
      while (i < src.length && src[i] !== "'") i += src[i] === "\\" ? 2 : 1;
      out += "''";
    } else {
      out += c;
    }
  }
  return out;
}

const norm = (t) =>
  t.replace(/\s+/g, " ").replace(/\s*<\s*/g, "<").replace(/\s*>/g, ">").replace(/\s*,\s*/g, ", ").trim();

/** Splits on commas outside angle brackets. */
function splitTop(text) {
  const parts = [];
  let depth = 0;
  let cur = "";
  for (const c of text) {
    if (c === "<") depth++;
    if (c === ">") depth--;
    if (c === "," && depth === 0) {
      parts.push(cur);
      cur = "";
    } else cur += c;
  }
  if (cur.trim()) parts.push(cur);
  return parts.map((p) => p.trim()).filter(Boolean);
}

function paramTypes(text) {
  return splitTop(text)
    .map((p) => {
      const words = p.replace(/\bfinal\b/g, "").trim().split(/\s+/);
      words.pop();
      return norm(words.join(" "));
    })
    .join(", ");
}

/** Splits leading annotations from a header. Returns [annotations, rest]. */
function annotations(header) {
  const found = [];
  let rest = header.trim();
  for (;;) {
    const m = rest.match(/^@(\w+)\s*(\(([^)]*)\))?/);
    if (!m) break;
    let label = `@${m[1]}`;
    const args = (m[3] || "").toLowerCase();
    if (/required\s*=\s*true/.test(args)) label += "(required=true)";
    if (/callout\s*=\s*true/.test(args)) label += "(callout=true)";
    found.push(label);
    rest = rest.slice(m[0].length).trim();
  }
  return [found, rest];
}

function splitWords(text) {
  const words = text.split(/\s+/).filter(Boolean);
  const mods = [];
  while (words.length && MODIFIERS.has(words[0].toLowerCase())) mods.push(words.shift().toLowerCase());
  return { mods, words };
}

/** Returns the manifest lines for one Apex file. */
export function surfaceOf(src) {
  const text = stripComments(src);
  const lines = [];
  const stack = [];
  let buf = "";
  const typeFrame = () => (stack.length && stack[stack.length - 1].kind === "type" ? stack[stack.length - 1] : null);
  const fullName = (name) => {
    const types = stack.filter((f) => f.kind === "type").map((f) => f.name);
    return [...types, name].join(".");
  };

  function header(raw, opensBlock) {
    const [annos, rest] = annotations(raw);
    const parent = typeFrame();
    const typeMatch = rest.match(/^(.*?)\b(class|interface|enum)\s+(\w+)(.*)$/s);
    if (opensBlock && typeMatch && !typeMatch[1].includes("(")) {
      const { mods } = splitWords(typeMatch[1]);
      const kind = typeMatch[2];
      const name = typeMatch[3];
      const isGlobal = mods.includes("global");
      const frame = { kind: "type", name, isGlobal, isInterface: kind === "interface" };
      if (isGlobal) {
        const ext = norm(typeMatch[4]);
        const prefix = annos.length ? `${annos.join(" ")} ` : "";
        lines.push(`${prefix}global ${kind} ${fullName(name)}${ext ? ` ${ext}` : ""}`);
      }
      return frame;
    }
    if (!parent) return { kind: "block" };
    const { mods, words } = splitWords(rest.replace(/\(.*$/s, (m) => m));
    const paren = rest.indexOf("(");
    const isGlobal = mods.includes("global") || (parent.isInterface && parent.isGlobal);
    const prefix = annos.length ? `${annos.join(" ")} ` : "";
    const stat = mods.includes("static") ? "static " : "";
    const owner = fullName("").replace(/\.$/, "");
    if (paren >= 0) {
      const before = splitWords(rest.slice(0, paren)).words;
      const name = before.pop();
      const params = paramTypes(rest.slice(paren + 1, rest.lastIndexOf(")")));
      if (isGlobal && parent.isGlobal) {
        if (before.length === 0 && name === parent.name) lines.push(`${prefix}new ${owner}(${params})`);
        else lines.push(`${prefix}${stat}${owner}.${name}(${params}): ${norm(before.join(" "))}`);
      }
      return { kind: "block" };
    }
    // A property (opens a block) or a field (ends with a semicolon).
    const name = words.pop()?.replace(/=.*$/, "");
    const assign = rest.indexOf("=");
    const decl = assign >= 0 ? rest.slice(0, assign) : rest;
    const dw = splitWords(decl).words;
    const fieldName = dw.pop();
    const type = norm(dw.join(" "));
    if (opensBlock) {
      const frame = { kind: "property", accessors: [], record: null };
      if (isGlobal && parent.isGlobal) frame.record = { prefix, stat, owner, name: fieldName, type };
      return frame;
    }
    if (isGlobal && parent.isGlobal && name) {
      const fin = mods.includes("final") ? "final " : "";
      lines.push(`${prefix}${stat}${fin}${owner}.${fieldName}: ${type}`);
    }
    return null;
  }

  function accessor(frame, raw) {
    const t = raw.trim().toLowerCase();
    const m = t.match(/^(private|public|protected|global)?\s*(get|set)\b/);
    if (m) frame.accessors.push({ which: m[2], hidden: m[1] === "private" || m[1] === "protected" || m[1] === "public" });
  }

  for (const c of text) {
    if (c === "{") {
      const top = stack[stack.length - 1];
      if (top && top.kind === "property") {
        accessor(top, buf);
        stack.push({ kind: "block" });
      } else if (top && top.kind === "block") {
        stack.push({ kind: "block" });
      } else {
        stack.push(header(buf, true) || { kind: "block" });
      }
      buf = "";
    } else if (c === ";") {
      const top = stack[stack.length - 1];
      if (top && top.kind === "property") accessor(top, buf);
      else if (top && top.kind === "type") header(buf, false);
      buf = "";
    } else if (c === "}") {
      const frame = stack.pop();
      if (frame && frame.kind === "property" && frame.record) {
        const r = frame.record;
        const vis = ["get", "set"].filter((w) => frame.accessors.some((a) => a.which === w && !a.hidden));
        lines.push(`${r.prefix}${r.stat}${r.owner}.${r.name}: ${r.type} { ${vis.join("; ")} }`);
      }
      buf = "";
    } else {
      buf += c;
    }
  }
  return lines;
}

function walk(dir) {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    return statSync(p).isDirectory() ? walk(p) : p.endsWith(".cls") ? [p] : [];
  });
}

/** Returns the manifest lines for every class in a folder. */
export function surfaceOfFolder(dir) {
  return walk(dir).flatMap((f) => surfaceOf(readFileSync(f, "utf8")));
}

/** Reads the manifest block from docs/api.md. */
export function manifest(markdown) {
  const m = markdown.match(/```hook-global-api\n([\s\S]*?)```/);
  if (!m) throw new Error("No hook-global-api block");
  return m[1].split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
}
