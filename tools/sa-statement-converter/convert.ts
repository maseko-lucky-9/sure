#!/usr/bin/env node
// Converts a South African bank statement export (separate Money In / Money Out /
// Fee columns, CSV or .xlsx) into the signed-amount CSV that Sure's transaction
// import reads, and optionally pushes it through POST /api/v1/imports.
//
// Runs on Node 22.18+ with no dependencies: node convert.ts <file> [options]
import { readFileSync, realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { inflateRawSync } from "node:zlib";

export type Row = Record<string, string>;
export type Converted = { csv: string; rows: number; warnings: string[] };

const DATE_HEADERS = ["posting date", "posted date", "date"];
const NAME_HEADERS = ["description", "details", "memo"];
const NOTES_HEADERS = ["original description"];

export function parseCsv(text: string): string[][] {
  // Some exports are semicolon-separated; the first line with either tells which.
  const firstLine = text.split(/\r?\n/).find((l) => /[;,]/.test(l)) ?? "";
  const sep = (firstLine.match(/;/g)?.length ?? 0) > (firstLine.match(/,/g)?.length ?? 0) ? ";" : ",";
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  const src = text.replace(/^﻿/, "");
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (quoted) {
      if (c === '"' && src[i + 1] === '"') { cell += '"'; i++; }
      else if (c === '"') quoted = false;
      else cell += c;
    } else if (c === '"') quoted = true;
    else if (c === sep) { row.push(cell); cell = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && src[i + 1] === "\n") i++;
      row.push(cell); cell = "";
      rows.push(row); row = [];
    } else cell += c;
  }
  if (cell !== "" || row.length) { row.push(cell); rows.push(row); }
  return rows.filter((r) => r.some((v) => v.trim() !== ""));
}

// Reads "R 1 234.56", "1,234.56", "(50.00)" and "-50.00" into cents. Returns null
// for a blank cell and NaN for anything else, including decimal commas ("12,50"),
// which cannot be told apart from thousands separators safely.
export function parseAmount(raw: string | undefined): number | null {
  const s = (raw ?? "").replace(/ZAR|[R$£€\s\u00A0\u202F]/gi, "");
  if (s === "") return null;
  const m = s.match(/^(\()?(-)?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?(\))?$/);
  if (!m || Boolean(m[1]) !== Boolean(m[5])) return Number.NaN;
  // Spreadsheets store 99.5 as 99.500000000001; real sub-cent amounts are refused.
  const fraction = Number(`0.${m[4] ?? "0"}`) * 100;
  if (Math.abs(fraction - Math.round(fraction)) > 1e-6) return Number.NaN;
  const cents = Number(m[3].replace(/,/g, "")) * 100 + Math.round(fraction);
  return m[1] || m[2] ? -cents : cents;
}

// Day-first, as South African banks export. Returns ISO yyyy-mm-dd or null.
export function parseDate(raw: string | undefined): string | null {
  const s = (raw ?? "").trim().split(/[ T]/)[0];
  let m = s.match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$/);
  let y: string, mo: string, d: string;
  if (m) [, y, mo, d] = m;
  else if ((m = s.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$/))) [, d, mo, y] = m;
  else if ((m = s.match(/^(\d{4})(\d{2})(\d{2})$/))) [, y, mo, d] = m;
  else if (/^\d{5}(\.\d+)?$/.test(s)) {
    // Excel serial date (days since 1899-12-30).
    return new Date(Date.UTC(1899, 11, 30) + Math.floor(Number(s)) * 86400000).toISOString().slice(0, 10);
  } else return null;
  const iso = `${y}-${mo.padStart(2, "0")}-${d.padStart(2, "0")}`;
  const check = new Date(`${iso}T00:00:00Z`);
  return Number.isNaN(check.getTime()) || check.toISOString().slice(0, 10) !== iso ? null : iso;
}

function csvCell(v: string): string {
  return /[",\n\r]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v;
}

const normalizeHeader = (h: string) => h.replace(/\(.*?\)/g, "").trim().toLowerCase();

export function convert(table: string[][], today = new Date().toISOString().slice(0, 10)): Converted {
  // Bank exports often put account details above the header row.
  const headerAt = table.slice(0, 20).findIndex((r) => {
    const names = r.map(normalizeHeader);
    return names.includes("money in") && names.includes("money out");
  });
  if (headerAt < 0) throw new Error('Expected columns: a date ("Posting Date" or "Date"), "Description", "Money In" and "Money Out".');
  const index = new Map(table[headerAt].map((h, i) => [normalizeHeader(h), i]));
  const body = table.slice(headerAt + 1);
  const col = (names: string[]) => names.map((n) => index.get(n)).find((i) => i !== undefined);
  const dateCol = col(DATE_HEADERS);
  const nameCol = col(NAME_HEADERS);
  const inCol = index.get("money in")!;
  const outCol = index.get("money out")!;
  const feeCol = index.get("fee");
  const notesCol = col(NOTES_HEADERS);
  if (dateCol === undefined || nameCol === undefined) {
    throw new Error('Expected columns: a date ("Posting Date" or "Date"), "Description", "Money In" and "Money Out".');
  }

  const out: string[] = ["date,amount,name,notes"];
  const warnings: string[] = [];
  const emit = (date: string, cents: number, name: string, notes: string) =>
    out.push([date, `${cents < 0 ? "-" : ""}${Math.floor(Math.abs(cents) / 100)}.${String(Math.abs(cents) % 100).padStart(2, "0")}`, csvCell(name), csvCell(notes)].join(","));

  body.forEach((cells, i) => {
    const line = headerAt + i + 2;
    const skip = (why: string) => void warnings.push(`Line ${line}: skipped, ${why}.`);
    const date = parseDate(cells[dateCol]);
    const name = (cells[nameCol] ?? "").trim();
    const notes = notesCol === undefined ? "" : (cells[notesCol] ?? "").trim();
    const amounts = [cells[inCol], cells[outCol], feeCol === undefined ? "" : cells[feeCol]].map(parseAmount);
    const unreadable = amounts.findIndex((a) => Number.isNaN(a));
    // One unreadable amount drops the whole row: importing half a row would be worse.
    if (unreadable >= 0) return skip(`unreadable amount "${[cells[inCol], cells[outCol], cells[feeCol ?? -1]][unreadable]}"`);
    const moneyIn = amounts[0] ?? 0;
    const moneyOut = Math.abs(amounts[1] ?? 0);
    const fee = Math.abs(amounts[2] ?? 0);

    if (!date) return skip(`unreadable date "${cells[dateCol] ?? ""}"`);
    if (date > today) return skip(`date ${date} is in the future`);
    if (!name) return skip("no description");
    if (moneyIn < 0) return skip("negative Money In");
    if (!moneyIn && !moneyOut && !fee) return skip("no amount");

    if (moneyIn) emit(date, moneyIn, name, notes);
    if (moneyOut) emit(date, -moneyOut, name, notes);
    if (moneyIn && moneyOut) warnings.push(`Line ${line}: has both Money In and Money Out; kept as two transactions.`);
    // Sure matches re-imported rows on date, amount and name, so a fee needs its own name.
    if (fee) emit(date, -fee, moneyIn || moneyOut ? `${name} Fee` : name, notes);
  });

  return { csv: `${out.join("\n")}\n`, rows: out.length - 1, warnings };
}

// ponytail: reads the first worksheet of a plain .xlsx (stored or deflated zip
// entries, shared or inline strings). Use a spreadsheet library if a bank's
// export needs formulas, styles-based dates or zip64.
export function xlsxToTable(buf: Buffer): string[][] {
  const eocd = buf.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
  if (eocd < 0) throw new Error("Not an .xlsx file.");
  const files = new Map<string, Buffer>();
  let p = buf.readUInt32LE(eocd + 16);
  for (let n = buf.readUInt16LE(eocd + 10); n > 0; n--) {
    const method = buf.readUInt16LE(p + 10);
    const size = buf.readUInt32LE(p + 20);
    const nameLen = buf.readUInt16LE(p + 28);
    const local = buf.readUInt32LE(p + 42);
    const name = buf.toString("utf8", p + 46, p + 46 + nameLen);
    const start = local + 30 + buf.readUInt16LE(local + 26) + buf.readUInt16LE(local + 28);
    const data = buf.subarray(start, start + size);
    files.set(name, method === 8 ? inflateRawSync(data, { maxOutputLength: 200 * 1024 * 1024 }) : data);
    p += 46 + nameLen + buf.readUInt16LE(p + 30) + buf.readUInt16LE(p + 32);
  }
  const text = (xml: string) =>
    [...xml.matchAll(/<t[^>]*>([^<]*)<\/t>/g)].map((m) => m[1]).join("")
      .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(Number.parseInt(h, 16)))
      .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
      .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, "&");
  const shared = [...(files.get("xl/sharedStrings.xml")?.toString("utf8") ?? "").matchAll(/<si>([\s\S]*?)<\/si>/g)].map((m) => text(m[1]));
  const sheetName = [...files.keys()].filter((k) => /^xl\/worksheets\/sheet\d+\.xml$/.test(k))
    .sort((a, b) => Number(a.match(/\d+/)![0]) - Number(b.match(/\d+/)![0]))[0];
  if (!sheetName) throw new Error("The workbook has no worksheet.");
  const sheet = files.get(sheetName)!.toString("utf8");
  const table: string[][] = [];
  for (const r of sheet.matchAll(/<row[^>]*>([\s\S]*?)<\/row>/g)) {
    const row: string[] = [];
    for (const c of r[1].matchAll(/<c\s([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const ref = c[1].match(/r="([A-Z]+)\d+"/)?.[1] ?? "";
      const colIndex = [...ref].reduce((a, ch) => a * 26 + ch.charCodeAt(0) - 64, 0) - 1;
      const type = c[1].match(/t="(\w+)"/)?.[1];
      const v = c[2]?.match(/<v>([^<]*)<\/v>/)?.[1] ?? "";
      row[colIndex < 0 ? row.length : colIndex] = type === "s" ? shared[Number(v)] ?? "" : type === "inlineStr" ? text(c[2] ?? "") : v;
    }
    table.push(Array.from(row, (v) => v ?? ""));
  }
  return table.filter((r) => r.some((v) => v.trim() !== ""));
}

export function readStatement(path: string): string[][] {
  const buf = readFileSync(path);
  return /\.xlsx$/i.test(path) ? xlsxToTable(buf) : parseCsv(buf.toString("utf8"));
}

type Fetch = typeof fetch;

export async function push(csv: string, rows: number, baseUrl: string, accountId: string, apiKey: string, publish: boolean, fetchFn: Fetch = fetch) {
  const body = {
    type: "TransactionImport", account_id: accountId, raw_file_content: csv,
    date_col_label: "date", amount_col_label: "amount", name_col_label: "name", notes_col_label: "notes",
    date_format: "%Y-%m-%d", number_format: "1,234.56", signage_convention: "inflows_positive",
  };
  const call = async (path: string, payload: object) => {
    const res = await fetchFn(`${baseUrl.replace(/\/+$/, "")}${path}`, {
      method: "POST", headers: { "Content-Type": "application/json", "X-Api-Key": apiKey }, body: JSON.stringify(payload),
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`${path} returned ${res.status}: ${text.slice(0, 300)}`);
    return JSON.parse(text);
  };
  // Nothing is created until Sure's dry run reads every row cleanly: creating
  // with publish starts the import at once, so a later check would be too late.
  const dry = (await call("/api/v1/imports/preflight", body)).data ?? {};
  const read = dry.stats?.rows_count;
  if (read !== rows || dry.valid === false || dry.errors?.length) {
    throw new Error(`Sure's dry run read ${read} of ${rows} rows${dry.errors?.length ? `: ${JSON.stringify(dry.errors)}` : ""}. Nothing was imported.`);
  }
  return (await call("/api/v1/imports", { ...body, publish: publish ? "true" : "false" })).data;
}

async function main() {
  const usage = "Usage: node convert.ts <statement.csv|.xlsx> [--account-id <id>] [--base-url http://localhost:3000] [--no-publish]\n" +
    "Without --account-id the converted CSV is printed. With it, the CSV is pushed to Sure using SURE_API_KEY.";
  let parsed: ReturnType<typeof parseArgs>;
  try {
    parsed = parseArgs({
      allowPositionals: true,
      options: { "account-id": { type: "string" }, "base-url": { type: "string", default: "http://localhost:3000" }, "no-publish": { type: "boolean", default: false } },
    });
  } catch (e) {
    console.error(`${(e as Error).message}\n${usage}`);
    process.exit(2);
  }
  const { values, positionals } = parsed;
  const accountId = values["account-id"] as string | undefined;
  if (positionals.length !== 1 || accountId?.startsWith("--") || accountId === "") {
    console.error(usage);
    process.exit(2);
  }
  const { csv, rows, warnings } = convert(readStatement(positionals[0]));
  for (const w of warnings) console.error(w);
  if (!accountId) return void process.stdout.write(csv);
  if (!rows) throw new Error("No rows to import.");
  const apiKey = process.env.SURE_API_KEY;
  if (!apiKey) throw new Error("Set SURE_API_KEY to a Sure API key with read-write scope.");
  const data = await push(csv, rows, values["base-url"] as string, accountId, apiKey, !values["no-publish"]);
  console.error(`Sent ${rows} rows. Import ${data.id} is ${data.status}.`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  main().catch((e) => { console.error(e.message); process.exit(1); });
}
