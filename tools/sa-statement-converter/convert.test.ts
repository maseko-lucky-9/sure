import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { test } from "node:test";
import { deflateRawSync } from "node:zlib";
import { convert, parseAmount, parseCsv, parseDate, push, readStatement, xlsxToTable } from "./convert.ts";

const fixture = new URL("./fixtures/money_in_out_fee.csv", import.meta.url).pathname;

test("converts the Money In / Money Out / Fee fixture to signed rows", () => {
  const { csv, rows, warnings } = convert(readStatement(fixture));
  assert.equal(rows, 12);
  assert.deepEqual(csv.trim().split("\n"), [
    "date,amount,name,notes",
    "2024-01-01,5000.00,Salary,Monthly Salary Payment",
    "2024-01-02,-2000.00,Rent,Monthly Rent Payment",
    "2024-01-03,-5.50,Coffee,Coffee Shop Purchase",
    "2024-01-04,-15.00,Bank Fee,",
    "2024-01-05,1000.00,Transfer,Internal Transfer",
    "2024-01-05,-1000.00,Transfer,Internal Transfer",
    "2024-01-06,-250.75,Groceries,Supermarket Purchase",
    "2024-01-07,-3.50,ATM Fee,",
    "2024-01-08,1500.00,Freelance,Freelance Payment",
    "2024-01-09,-150.00,Utilities,Electric Bill",
    "2024-01-09,-5.00,Utilities Fee,Electric Bill",
    "2024-01-10,50.00,Refund,Product Refund",
  ]);
  assert.deepEqual(warnings, ["Line 6: has both Money In and Money Out; kept as two transactions."]);
});

test("money out is an outflow whether the bank writes it signed or unsigned", () => {
  const table = [["Date", "Description", "Money In", "Money Out"], ["2024-02-01", "A", "", "40.00"], ["2024-02-01", "B", "", "-40.00"]];
  assert.match(convert(table).csv, /-40\.00,A,\n2024-02-01,-40\.00,B,/);
});

test("skips rows it cannot read and says why", () => {
  const table = [
    ["Posting Date", "Description", "Money In", "Money Out", "Fee"],
    ["not a date", "X", "1", "", ""],
    ["2024-02-01", "", "1", "", ""],
    ["2024-02-01", "Negative in", "-5", "", ""],
    ["2024-02-01", "Nothing", "", "", ""],
    ["2024-02-01", "Kept", "7", "", ""],
  ];
  const { rows, warnings } = convert(table);
  assert.equal(rows, 1);
  assert.equal(warnings.length, 4);
});

test("refuses a file without the split columns", () => {
  assert.throws(() => convert([["Date", "Description", "Amount"], ["2024-01-01", "A", "1"]]), /Money In/);
});

test("parseAmount reads cents and refuses anything ambiguous", () => {
  assert.equal(parseAmount("R 1 234.56"), 123456);
  assert.equal(parseAmount("R\u00A01\u00A0234.5"), 123450);
  assert.equal(parseAmount("(50.00)"), -5000);
  assert.equal(parseAmount("-0.07"), -7);
  assert.equal(parseAmount("1,000.00"), 100000);
  assert.equal(parseAmount("99.500000000001"), 9950);
  assert.equal(parseAmount("2.675"), Number.NaN);
  assert.equal(parseAmount(""), null);
  for (const bad of ["abc", "12,50", "1.234,56", "1,5", "50.00-", "50.00 Dr", "(50.00", "0x10", "1e3", "Infinity"]) {
    assert.ok(Number.isNaN(parseAmount(bad)), bad);
  }
});

test("a row with an unreadable amount is skipped whole, not half-imported", () => {
  const table = [["Date", "Description", "Money In", "Money Out", "Fee"], ["2024-01-01", "A", "", "50.00 Dr", "1"], ["2024-01-01", "B", "12,50", "", ""]];
  const { rows, warnings } = convert(table);
  assert.equal(rows, 0);
  assert.deepEqual(warnings, ['Line 2: skipped, unreadable amount "50.00 Dr".', 'Line 3: skipped, unreadable amount "12,50".']);
});

test("skips future dates, which Sure would reject", () => {
  const table = [["Date", "Description", "Money In", "Money Out"], ["2024-06-02", "Tomorrow", "1", ""], ["2024-06-01", "Today", "1", ""]];
  const { rows, warnings } = convert(table, "2024-06-01");
  assert.equal(rows, 1);
  assert.deepEqual(warnings, ["Line 2: skipped, date 2024-06-02 is in the future."]);
});

test("finds the header below account details, with units in the names and semicolons", () => {
  const text = "Account;1234567890\nPeriod;Jan 2024\n\nPosting Date;Description;Money In (R);Money Out (R);Fee (R)\n2024-01-02;Rent;;-2000.00;\n";
  const { csv, warnings } = convert(parseCsv(text));
  assert.equal(csv, "date,amount,name,notes\n2024-01-02,-2000.00,Rent,\n");
  assert.deepEqual(warnings, []);
});

test("push creates nothing unless Sure's dry run reads every row", async () => {
  const calls: string[] = [];
  const server = (parsed: number, errors: object[] = []): typeof fetch => async (url, init) => {
    calls.push(String(url));
    assert.equal((init!.headers as Record<string, string>)["X-Api-Key"], "key");
    // The reply shape of POST /api/v1/imports/preflight, as Sure's own API test
    // pins it (test/controllers/api/v1/imports_controller_test.rb, "should
    // preflight CSV import without persisting records").
    const preflight = {
      type: "TransactionImport", valid: errors.length === 0, stats: { rows_count: parsed },
      headers: ["date", "amount", "name", "notes"], missing_required_headers: [], errors, warnings: [],
    };
    const data = String(url).endsWith("/preflight") ? preflight : { id: "imp1", status: "importing" };
    return new Response(JSON.stringify({ data }), { status: 200 });
  };

  await assert.rejects(push("csv", 3, "http://sure.test/", "acc", "key", true, server(2)), /read 2 of 3 rows.*Nothing was imported/);
  assert.deepEqual(calls, ["http://sure.test/api/v1/imports/preflight"]);

  calls.length = 0;
  const invalid = [{ code: "validation_failed", message: "Date format is invalid" }];
  await assert.rejects(push("csv", 3, "http://sure.test/", "acc", "key", true, server(3, invalid)), /Date format is invalid.*Nothing was imported/);
  assert.deepEqual(calls, ["http://sure.test/api/v1/imports/preflight"]);

  calls.length = 0;
  const data = await push("csv", 3, "http://sure.test/", "acc", "key", true, server(3));
  assert.equal(data.id, "imp1");
  assert.deepEqual(calls, ["http://sure.test/api/v1/imports/preflight", "http://sure.test/api/v1/imports"]);
});

test("push reports a non-JSON error body", async () => {
  const down: typeof fetch = async () => new Response("<html>Bad gateway</html>", { status: 502 });
  await assert.rejects(push("csv", 1, "http://sure.test", "acc", "key", true, down), /returned 502: <html>Bad gateway/);
});

test("parseDate reads day-first and ISO dates and rejects impossible ones", () => {
  assert.equal(parseDate("2025-03-01 03:24"), "2025-03-01");
  assert.equal(parseDate("01/03/2025"), "2025-03-01");
  assert.equal(parseDate("20250301"), "2025-03-01");
  assert.equal(parseDate("45717"), "2025-03-01");
  assert.equal(parseDate("31/02/2025"), null);
  assert.equal(parseDate("soon"), null);
});

test("parseCsv handles quotes, embedded commas and a byte-order mark", () => {
  assert.deepEqual(parseCsv('﻿a,b\r\n"x, y","say ""hi"""\n'), [["a", "b"], ["x, y", 'say "hi"']]);
});

// Builds a minimal .xlsx (a zip with deflated entries) to exercise the reader.
function zip(entries: Record<string, string>): Buffer {
  const locals: Buffer[] = [];
  const central: Buffer[] = [];
  let offset = 0;
  for (const [name, content] of Object.entries(entries)) {
    const data = deflateRawSync(Buffer.from(content));
    const n = Buffer.from(name);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(8, 8); local.writeUInt32LE(data.length, 18); local.writeUInt16LE(n.length, 26);
    const head = Buffer.alloc(46);
    head.writeUInt32LE(0x02014b50, 0); head.writeUInt16LE(8, 10); head.writeUInt32LE(data.length, 20); head.writeUInt16LE(n.length, 28); head.writeUInt32LE(offset, 42);
    locals.push(local, n, data); central.push(head, n);
    offset += 30 + n.length + data.length;
  }
  const cd = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(central.length / 2, 10); end.writeUInt32LE(cd.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cd, end]);
}

test("reads the first worksheet of an xlsx, with shared strings and gaps", () => {
  const workbook = zip({
    "xl/sharedStrings.xml": "<sst><si><t>Date</t></si><si><t>Description</t></si><si><t>Money In</t></si><si><t>Money Out</t></si><si><t>Pick n Pay&#39;s &amp; Co</t></si></sst>",
    "xl/worksheets/sheet1.xml":
      '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c></row>' +
      '<row r="2"><c r="A2"><v>45717</v></c><c r="B2" t="s"><v>4</v></c><c r="D2"><v>-99.5</v></c></row></sheetData></worksheet>',
  });
  const table = xlsxToTable(workbook);
  assert.deepEqual(table[1], ["45717", "Pick n Pay's & Co", "", "-99.5"]);
  assert.equal(convert(table).csv, "date,amount,name,notes\n2025-03-01,-99.50,Pick n Pay's & Co,\n");
});

// The converted file is also what Sure's own suite pushes through its import
// API (test/controllers/api/v1/sa_statement_converter_contract_test.rb), so the
// two ends are tested against the same bytes.
test("the shipped fixture converts to the file Sure's API contract test imports", () => {
  const { csv, rows } = convert(readStatement(new URL("fixtures/money_in_out_fee.csv", import.meta.url).pathname), "2026-01-01");
  assert.equal(rows, 12);
  assert.equal(csv, readFileSync(new URL("fixtures/money_in_out_fee.converted.csv", import.meta.url), "utf8"));
});

