#!/usr/bin/env node
/*
 * gen_font_tables.js - generates Source/Font/Pdf.Font.Encodings.pas and Source/Font/Pdf.Font.GlyphList.pas
 * from the pdf.js sources (Apache License 2.0, see NOTICE).
 *
 * Usage (from the repository root):
 *   node Tools/gen_font_tables.js <path to pdf.js src/core> [output folder, default Source/Font]
 *
 * Reads encodings.js (the simple font encodings) and glyphlist.js (the Adobe Glyph List as extended by
 * pdf.js, and the ZapfDingbats glyph list). The pdf.js modules are evaluated with a stub for
 * getLookupTableFactory, so the generated tables follow pdf.js exactly, including its key order and
 * "last assignment wins" for duplicated names.
 */
"use strict";

const fs = require("fs");
const path = require("path");

const MAX_LINE = 160;

function usage() {
  console.error("usage: node Tools/gen_font_tables.js <pdf.js src/core folder> [output folder]");
  process.exit(2);
}

const srcDir = process.argv[2];
if (!srcDir) {
  usage();
}
const outDir = process.argv[3] || path.join(__dirname, "..", "Source", "Font");

/** Loads a pdf.js ES module as a function body (imports and the export list removed) and returns `names`. */
function loadModule(file, names) {
  let src = fs.readFileSync(path.join(srcDir, file), "utf8");
  src = src.replace(/^import[\s\S]*?;\s*$/gm, "").replace(/export\s*\{[\s\S]*?\};/, "");
  const stub =
    "const getLookupTableFactory = function (initializer) {\n" +
    "  let lookup;\n" +
    "  return function () {\n" +
    "    if (initializer) { lookup = Object.create(null); initializer(lookup); initializer = null; }\n" +
    "    return lookup;\n" +
    "  };\n" +
    "};\n";
  // eslint-disable-next-line no-new-func
  return new Function(stub + src + "\nreturn {" + names.join(", ") + "};")();
}

function pasStr(s) {
  return "'" + s.replace(/'/g, "''") + "'";
}

function hex(n, digits) {
  return "$" + n.toString(16).toUpperCase().padStart(digits, "0");
}

/** Joins items into lines of at most MAX_LINE characters, each prefixed by `indent`, separated by ', '. */
function wrap(items, indent) {
  const lines = [];
  let line = "";
  for (let i = 0; i < items.length; i++) {
    const item = items[i] + (i < items.length - 1 ? "," : "");
    if (line.length > 0 && indent.length + line.length + 1 + item.length > MAX_LINE) {
      lines.push(indent + line);
      line = "";
    }
    line += (line.length > 0 ? " " : "") + item;
  }
  if (line.length > 0) {
    lines.push(indent + line);
  }
  return lines.join("\n");
}

function checkAscii(names, what) {
  for (const n of names) {
    if (!/^[\x21-\x7e]+$/.test(n)) {
      throw new Error(`${what}: non-ASCII or empty glyph name ${JSON.stringify(n)}`);
    }
  }
}

/** Ordinal (UTF-16 code unit) comparison, the same order as Delphi's CompareStr for ASCII. */
function ordinal(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

function header(unitName, purpose) {
  return (
    "{*******************************************************************************\n" +
    `  ${unitName}\n` +
    `  ${purpose}\n` +
    "\n" +
    "  GENERATED FILE - DO NOT EDIT. Generated from the pdf.js sources (Mozilla\n" +
    "  Foundation, Apache License 2.0, see NOTICE) by Tools/gen_font_tables.js:\n" +
    "    node Tools/gen_font_tables.js <pdf.js>/src/core\n" +
    "*******************************************************************************}\n"
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Pdf.Font.Encodings
// ---------------------------------------------------------------------------------------------------------------------

function genEncodings() {
  const enc = loadModule("encodings.js", [
    "StandardEncoding",
    "WinAnsiEncoding",
    "MacRomanEncoding",
    "MacExpertEncoding",
    "SymbolSetEncoding",
    "ZapfDingbatsEncoding",
    "ExpertEncoding",
  ]);
  const tables = [
    ["StandardEncoding", "StandardEncodingTable", "Adobe StandardEncoding (PDF 32000-1 Annex D)."],
    ["WinAnsiEncoding", "WinAnsiEncodingTable", "WinAnsiEncoding (Windows code page 1252), as pdf.js fills it (bullet for the undefined codes from 127 up, space at 160, hyphen at 173)."],
    ["MacRomanEncoding", "MacRomanEncodingTable", "MacRomanEncoding (PDF 32000-1 Annex D, plus the Mac OS additions pdf.js uses)."],
    ["MacExpertEncoding", "MacExpertEncodingTable", "MacExpertEncoding."],
    ["SymbolSetEncoding", "SymbolEncodingTable", "Built-in encoding of the Symbol font."],
    ["ZapfDingbatsEncoding", "ZapfDingbatsEncodingTable", "Built-in encoding of the ZapfDingbats font."],
    ["ExpertEncoding", "ExpertEncodingTable", "Adobe ExpertEncoding (CFF predefined encoding 1)."],
  ];
  let consts = "";
  for (const [jsName, pasName, doc] of tables) {
    const arr = enc[jsName];
    if (!Array.isArray(arr) || arr.length > 256) {
      throw new Error(`${jsName}: unexpected table`);
    }
    const full = [];
    for (let i = 0; i < 256; i++) {
      full.push(arr[i] || "");
    }
    checkAscii(full.filter(s => s !== ""), jsName);
    consts += `  /// <summary>${doc}</summary>\n`;
    consts += `  ${pasName}: TPdfEncodingTable = (\n`;
    for (let row = 0; row < 256; row += 16) {
      const items = full.slice(row, row + 16).map(pasStr);
      const last = row + 16 >= 256;
      consts += wrap(items, "    ") + (last ? "" : ",") + `  // ${row}..${row + 15}` + "\n";
    }
    consts += "  );\n\n";
  }

  // Name -> code lookup for StandardEncoding (first code wins; StandardEncoding has no duplicates).
  const std = [];
  const seen = new Set();
  enc.StandardEncoding.forEach((name, code) => {
    if (name && !seen.has(name)) {
      seen.add(name);
      std.push([name, code]);
    }
  });
  std.sort((a, b) => ordinal(a[0], b[0]));
  consts += "  /// <summary>Glyph names of StandardEncoding in ordinal order, for binary search.</summary>\n";
  consts += `  StdNames: array[0..${std.length - 1}] of string = (\n${wrap(std.map(e => pasStr(e[0])), "    ")}\n  );\n`;
  consts += "  /// <summary>Codes matching <c>StdNames</c>.</summary>\n";
  consts += `  StdCodes: array[0..${std.length - 1}] of Byte = (\n${wrap(std.map(e => String(e[1])), "    ")}\n  );\n`;

  const out =
    header("Pdf.Font.Encodings", "The predefined simple font encodings (code -> glyph name).") +
    `unit Pdf.Font.Encodings;

interface

type
  /// <summary>Glyph name for each code 0..255 of a simple font encoding; '' means the code is unmapped.</summary>
  TPdfEncodingTable = array[0..255] of string;
  PPdfEncodingTable = ^TPdfEncodingTable;

/// <summary>Adobe StandardEncoding.</summary>
function PdfStandardEncoding: PPdfEncodingTable;
/// <summary>WinAnsiEncoding.</summary>
function PdfWinAnsiEncoding: PPdfEncodingTable;
/// <summary>MacRomanEncoding.</summary>
function PdfMacRomanEncoding: PPdfEncodingTable;
/// <summary>MacExpertEncoding.</summary>
function PdfMacExpertEncoding: PPdfEncodingTable;
/// <summary>Built-in encoding of the Symbol font.</summary>
function PdfSymbolEncoding: PPdfEncodingTable;
/// <summary>Built-in encoding of the ZapfDingbats font.</summary>
function PdfZapfDingbatsEncoding: PPdfEncodingTable;
/// <summary>Adobe ExpertEncoding.</summary>
function PdfExpertEncoding: PPdfEncodingTable;
/// <summary>The table for a PDF /Encoding or /BaseEncoding name: 'StandardEncoding', 'WinAnsiEncoding',
/// 'MacRomanEncoding' or 'MacExpertEncoding' (case-sensitive); nil for anything else.</summary>
function PdfEncodingByName(const Name: string): PPdfEncodingTable;
/// <summary>Code of a glyph name in StandardEncoding (used by the seac operator), -1 when absent.</summary>
function PdfStandardEncodingCode(const GlyphName: string): Integer;

implementation

uses
  System.SysUtils;

const
${consts}
function PdfStandardEncoding: PPdfEncodingTable;
begin
  Result := @StandardEncodingTable;
end;

function PdfWinAnsiEncoding: PPdfEncodingTable;
begin
  Result := @WinAnsiEncodingTable;
end;

function PdfMacRomanEncoding: PPdfEncodingTable;
begin
  Result := @MacRomanEncodingTable;
end;

function PdfMacExpertEncoding: PPdfEncodingTable;
begin
  Result := @MacExpertEncodingTable;
end;

function PdfSymbolEncoding: PPdfEncodingTable;
begin
  Result := @SymbolEncodingTable;
end;

function PdfZapfDingbatsEncoding: PPdfEncodingTable;
begin
  Result := @ZapfDingbatsEncodingTable;
end;

function PdfExpertEncoding: PPdfEncodingTable;
begin
  Result := @ExpertEncodingTable;
end;

function PdfEncodingByName(const Name: string): PPdfEncodingTable;
begin
  if Name = 'StandardEncoding' then
    Result := @StandardEncodingTable
  else if Name = 'WinAnsiEncoding' then
    Result := @WinAnsiEncodingTable
  else if Name = 'MacRomanEncoding' then
    Result := @MacRomanEncodingTable
  else if Name = 'MacExpertEncoding' then
    Result := @MacExpertEncodingTable
  else
    Result := nil;
end;

function PdfStandardEncodingCode(const GlyphName: string): Integer;
var
  Lo, Hi, Mid, C: Integer;
begin
  Lo := Low(StdNames);
  Hi := High(StdNames);
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) shr 1;
    C := CompareStr(StdNames[Mid], GlyphName);
    if C = 0 then
      Exit(StdCodes[Mid]);
    if C < 0 then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Result := -1;
end;

end.
`;
  return out;
}

// ---------------------------------------------------------------------------------------------------------------------
// Pdf.Font.GlyphList
// ---------------------------------------------------------------------------------------------------------------------

function genGlyphList() {
  const gl = loadModule("glyphlist.js", ["getGlyphsUnicode", "getDingbatsGlyphsUnicode"]);
  const agl = gl.getGlyphsUnicode();
  const dingbats = gl.getDingbatsGlyphsUnicode();

  // AGL order = pdf.js key (first insertion) order.
  const aglOrder = Object.keys(agl);
  checkAscii(aglOrder, "AGL");
  const entries = aglOrder.map((name, order) => ({ name, code: agl[name], order }));
  for (const e of entries) {
    if (!Number.isInteger(e.code) || e.code < 0 || e.code > 0x10ffff) {
      throw new Error(`AGL: bad code for ${e.name}`);
    }
  }
  const byName = entries.slice().sort((a, b) => ordinal(a.name, b.name));
  byName.forEach((e, i) => (e.sortedIndex = i));
  const byCode = entries.slice().sort((a, b) => a.code - b.code || a.order - b.order);
  const n = byName.length;

  const dingNames = Object.keys(dingbats);
  checkAscii(dingNames, "Dingbats");
  const ding = dingNames.map(name => ({ name, code: dingbats[name] })).sort((a, b) => ordinal(a.name, b.name));
  const m = ding.length;

  let consts = "";
  consts += `  AglCount = ${n};\n\n`;
  consts += "  /// <summary>Adobe Glyph List names (as extended by pdf.js) in ordinal order, for binary search.</summary>\n";
  consts += `  AglNames: array[0..AglCount - 1] of string = (\n${wrap(byName.map(e => pasStr(e.name)), "    ")}\n  );\n\n`;
  consts += "  /// <summary>Unicode code points matching <c>AglNames</c>.</summary>\n";
  consts += `  AglCodes: array[0..AglCount - 1] of Integer = (\n${wrap(byName.map(e => hex(e.code, 4)), "    ")}\n  );\n\n`;
  consts += "  /// <summary>Indices into <c>AglNames</c>/<c>AglCodes</c> ordered by code point, ties in AGL (pdf.js) order.</summary>\n";
  consts += `  AglByCode: array[0..AglCount - 1] of Word = (\n${wrap(byCode.map(e => String(e.sortedIndex)), "    ")}\n  );\n\n`;
  consts += `  DingbatsCount = ${m};\n\n`;
  consts += "  /// <summary>ZapfDingbats glyph names in ordinal order.</summary>\n";
  consts += `  DingbatsNames: array[0..DingbatsCount - 1] of string = (\n${wrap(ding.map(e => pasStr(e.name)), "    ")}\n  );\n\n`;
  consts += "  /// <summary>Unicode code points matching <c>DingbatsNames</c>.</summary>\n";
  consts += `  DingbatsCodes: array[0..DingbatsCount - 1] of Integer = (\n${wrap(ding.map(e => hex(e.code, 4)), "    ")}\n  );\n`;

  const out =
    header("Pdf.Font.GlyphList", "Glyph name <-> Unicode: the Adobe Glyph List and the ZapfDingbats list.") +
    `unit Pdf.Font.GlyphList;

interface

/// <summary>Unicode code point for a glyph name, -1 when unknown.</summary>
/// <remarks>In order: the Adobe Glyph List (as extended by pdf.js, so ligatures it lists such as 'f_f_i' map to
/// their presentation form U+FB03, and '.notdef' to 0); a suffix after the first '.' is stripped ('A.sc' -> 'A');
/// 'uniXXXX' with upper-case hex, also a sequence 'uniXXXXYYYY..' (the first code point is returned; a name whose
/// hex part is not a multiple of four digits, such as 'uni0041004', gives -1 as in pdf.js); 'uXXXX' to 'uXXXXXX'
/// (upper-case hex); 'Cdd', 'Cddd', 'cdd' and 'cddd' (decimal, pdf.js's heuristic, e.g. 'C65' -> 65).
/// Surrogates (D800..DFFF) and values above 10FFFF give -1. Names that are glyph or CID indices ('gXX', 'GXX',
/// 'cidXX') and underscore ligatures that are not in the list give -1; the font loader handles those.</remarks>
function PdfGlyphNameToUnicode(const Name: string): Integer;
/// <summary>ZapfDingbats glyph names ('a1' .. 'a191', 'space') to Unicode (pdf.js getDingbatsGlyphsUnicode);
/// -1 when unknown.</summary>
function PdfDingbatsGlyphNameToUnicode(const Name: string): Integer;
/// <summary>Reverse Adobe Glyph List lookup: the glyph name of a code point ('' when none). When several names
/// map to the code point, the first one in AGL order is returned.</summary>
function PdfUnicodeToGlyphName(CodePoint: Integer): string;

implementation

uses
  System.SysUtils;

const
${consts}
function FindName(const Names: array of string; const Name: string): Integer;
var
  Lo, Hi, Mid, C: Integer;
begin
  Lo := 0;
  Hi := High(Names);
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) shr 1;
    C := CompareStr(Names[Mid], Name);
    if C = 0 then
      Exit(Mid);
    if C < 0 then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Result := -1;
end;

/// <summary>Parses Count upper-case hex digits of S starting at Start (1-based); -1 when any is not 0-9/A-F.</summary>
function ParseUpperHex(const S: string; Start, Count: Integer): Integer;
var
  I: Integer;
  Ch: Char;
begin
  Result := 0;
  for I := Start to Start + Count - 1 do
  begin
    Ch := S[I];
    case Ch of
      '0'..'9': Result := Result * 16 + (Ord(Ch) - Ord('0'));
      'A'..'F': Result := Result * 16 + (Ord(Ch) - Ord('A') + 10);
    else
      Exit(-1);
    end;
  end;
end;

function ValidCodePoint(Code: Integer): Integer;
begin
  if (Code < 0) or (Code > $10FFFF) or ((Code >= $D800) and (Code <= $DFFF)) then
    Result := -1
  else
    Result := Code;
end;

function PdfGlyphNameToUnicode(const Name: string): Integer;
var
  Index, Len, Dot, I: Integer;
begin
  Len := Length(Name);
  if Len = 0 then
    Exit(-1);
  Index := FindName(AglNames, Name);
  if Index >= 0 then
    Exit(AglCodes[Index]);
  Dot := Pos('.', Name);
  if Dot > 0 then
  begin
    if Dot = 1 then
      Exit(-1);
    Exit(PdfGlyphNameToUnicode(Copy(Name, 1, Dot - 1)));
  end;
  Result := -1;
  case Name[1] of
    'u':
      if (Len >= 7) and (Name[2] = 'n') and (Name[3] = 'i') then
      begin
        // 'uniXXXX' or a sequence 'uniXXXXYYYY...': every part must be valid, the first is returned.
        if (Len - 3) mod 4 <> 0 then
          Exit(-1);
        I := 4;
        while I <= Len do
        begin
          if ValidCodePoint(ParseUpperHex(Name, I, 4)) < 0 then
            Exit(-1);
          Inc(I, 4);
        end;
        Result := ParseUpperHex(Name, 4, 4);
      end
      else if (Len >= 5) and (Len <= 7) then
        Result := ValidCodePoint(ParseUpperHex(Name, 2, Len - 1));
    'C', 'c':
      if (Len >= 3) and (Len <= 4) then
      begin
        Result := 0;
        for I := 2 to Len do
          if CharInSet(Name[I], ['0'..'9']) then
            Result := Result * 10 + (Ord(Name[I]) - Ord('0'))
          else
            Exit(-1);
        if Result = 0 then
          Result := -1;
      end;
  end;
end;

function PdfDingbatsGlyphNameToUnicode(const Name: string): Integer;
var
  Index: Integer;
begin
  Index := FindName(DingbatsNames, Name);
  if Index >= 0 then
    Result := DingbatsCodes[Index]
  else
    Result := -1;
end;

function PdfUnicodeToGlyphName(CodePoint: Integer): string;
var
  Lo, Hi, Mid, Found: Integer;
begin
  Lo := 0;
  Hi := AglCount - 1;
  Found := -1;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) shr 1;
    if AglCodes[AglByCode[Mid]] < CodePoint then
      Lo := Mid + 1
    else
    begin
      if AglCodes[AglByCode[Mid]] = CodePoint then
        Found := Mid;
      Hi := Mid - 1;
    end;
  end;
  if Found >= 0 then
    Result := AglNames[AglByCode[Found]]
  else
    Result := '';
end;

end.
`;
  return { text: out, n, m };
}

function writeUnit(file, text) {
  fs.writeFileSync(path.join(outDir, file), text, "utf8");
  console.log(`wrote ${path.join(outDir, file)}`);
}

writeUnit("Pdf.Font.Encodings.pas", genEncodings());
const gl = genGlyphList();
writeUnit("Pdf.Font.GlyphList.pas", gl.text);
console.log(`AGL: ${gl.n} names, Dingbats: ${gl.m} names`);
