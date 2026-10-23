{*******************************************************************************
  Pdf.Font.CFF
  Compact Font Format (CFF, Adobe TN #5176) font program parser with a Type 2
  charstring interpreter (Adobe TN #5177). Handles plain (name-keyed) and
  CID-keyed fonts: Header, Name/Top DICT/String/Global Subr INDEXes, Private
  DICTs with local Subrs, charsets (predefined and formats 0/1/2), built-in
  encodings (Standard/Expert and custom formats 0/1 with supplements), FDArray
  and FDSelect (formats 0 and 3).

  Outlines are produced in glyph units; the FontMatrix maps them to text space.
  Structure follows pdf.js (cff_parser.js, font_renderer.js; Apache 2.0, see
  NOTICE). All structures are bounds-checked: corrupt data makes a glyph empty
  or a lookup return -1; the constructor raises EPdfFontError only when the
  header or the Name/Top DICT INDEX is unusable.
*******************************************************************************}
unit Pdf.Font.CFF;

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections, Pdf.Core.Types, Pdf.Font.Glyphs;

const
  /// <summary>The 391 CFF standard strings (SID 0..390), from the CFF specification Appendix A.</summary>
  PdfCFFStandardStrings: array[0..390] of string = (
    '.notdef', 'space', 'exclam', 'quotedbl', 'numbersign', 'dollar', 'percent', 'ampersand', 'quoteright',
    'parenleft', 'parenright', 'asterisk', 'plus', 'comma', 'hyphen', 'period', 'slash', 'zero', 'one', 'two',
    'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'colon', 'semicolon', 'less', 'equal', 'greater',
    'question', 'at', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S',
    'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'bracketleft', 'backslash', 'bracketright', 'asciicircum', 'underscore',
    'quoteleft', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't',
    'u', 'v', 'w', 'x', 'y', 'z', 'braceleft', 'bar', 'braceright', 'asciitilde', 'exclamdown', 'cent', 'sterling',
    'fraction', 'yen', 'florin', 'section', 'currency', 'quotesingle', 'quotedblleft', 'guillemotleft',
    'guilsinglleft', 'guilsinglright', 'fi', 'fl', 'endash', 'dagger', 'daggerdbl', 'periodcentered', 'paragraph',
    'bullet', 'quotesinglbase', 'quotedblbase', 'quotedblright', 'guillemotright', 'ellipsis', 'perthousand',
    'questiondown', 'grave', 'acute', 'circumflex', 'tilde', 'macron', 'breve', 'dotaccent', 'dieresis', 'ring',
    'cedilla', 'hungarumlaut', 'ogonek', 'caron', 'emdash', 'AE', 'ordfeminine', 'Lslash', 'Oslash', 'OE',
    'ordmasculine', 'ae', 'dotlessi', 'lslash', 'oslash', 'oe', 'germandbls', 'onesuperior', 'logicalnot', 'mu',
    'trademark', 'Eth', 'onehalf', 'plusminus', 'Thorn', 'onequarter', 'divide', 'brokenbar', 'degree', 'thorn',
    'threequarters', 'twosuperior', 'registered', 'minus', 'eth', 'multiply', 'threesuperior', 'copyright', 'Aacute',
    'Acircumflex', 'Adieresis', 'Agrave', 'Aring', 'Atilde', 'Ccedilla', 'Eacute', 'Ecircumflex', 'Edieresis',
    'Egrave', 'Iacute', 'Icircumflex', 'Idieresis', 'Igrave', 'Ntilde', 'Oacute', 'Ocircumflex', 'Odieresis',
    'Ograve', 'Otilde', 'Scaron', 'Uacute', 'Ucircumflex', 'Udieresis', 'Ugrave', 'Yacute', 'Ydieresis', 'Zcaron',
    'aacute', 'acircumflex', 'adieresis', 'agrave', 'aring', 'atilde', 'ccedilla', 'eacute', 'ecircumflex',
    'edieresis', 'egrave', 'iacute', 'icircumflex', 'idieresis', 'igrave', 'ntilde', 'oacute', 'ocircumflex',
    'odieresis', 'ograve', 'otilde', 'scaron', 'uacute', 'ucircumflex', 'udieresis', 'ugrave', 'yacute', 'ydieresis',
    'zcaron', 'exclamsmall', 'Hungarumlautsmall', 'dollaroldstyle', 'dollarsuperior', 'ampersandsmall', 'Acutesmall',
    'parenleftsuperior', 'parenrightsuperior', 'twodotenleader', 'onedotenleader', 'zerooldstyle', 'oneoldstyle',
    'twooldstyle', 'threeoldstyle', 'fouroldstyle', 'fiveoldstyle', 'sixoldstyle', 'sevenoldstyle', 'eightoldstyle',
    'nineoldstyle', 'commasuperior', 'threequartersemdash', 'periodsuperior', 'questionsmall', 'asuperior',
    'bsuperior', 'centsuperior', 'dsuperior', 'esuperior', 'isuperior', 'lsuperior', 'msuperior', 'nsuperior',
    'osuperior', 'rsuperior', 'ssuperior', 'tsuperior', 'ff', 'ffi', 'ffl', 'parenleftinferior', 'parenrightinferior',
    'Circumflexsmall', 'hyphensuperior', 'Gravesmall', 'Asmall', 'Bsmall', 'Csmall', 'Dsmall', 'Esmall', 'Fsmall',
    'Gsmall', 'Hsmall', 'Ismall', 'Jsmall', 'Ksmall', 'Lsmall', 'Msmall', 'Nsmall', 'Osmall', 'Psmall', 'Qsmall',
    'Rsmall', 'Ssmall', 'Tsmall', 'Usmall', 'Vsmall', 'Wsmall', 'Xsmall', 'Ysmall', 'Zsmall', 'colonmonetary',
    'onefitted', 'rupiah', 'Tildesmall', 'exclamdownsmall', 'centoldstyle', 'Lslashsmall', 'Scaronsmall',
    'Zcaronsmall', 'Dieresissmall', 'Brevesmall', 'Caronsmall', 'Dotaccentsmall', 'Macronsmall', 'figuredash',
    'hypheninferior', 'Ogoneksmall', 'Ringsmall', 'Cedillasmall', 'questiondownsmall', 'oneeighth', 'threeeighths',
    'fiveeighths', 'seveneighths', 'onethird', 'twothirds', 'zerosuperior', 'foursuperior', 'fivesuperior',
    'sixsuperior', 'sevensuperior', 'eightsuperior', 'ninesuperior', 'zeroinferior', 'oneinferior', 'twoinferior',
    'threeinferior', 'fourinferior', 'fiveinferior', 'sixinferior', 'seveninferior', 'eightinferior', 'nineinferior',
    'centinferior', 'dollarinferior', 'periodinferior', 'commainferior', 'Agravesmall', 'Aacutesmall',
    'Acircumflexsmall', 'Atildesmall', 'Adieresissmall', 'Aringsmall', 'AEsmall', 'Ccedillasmall', 'Egravesmall',
    'Eacutesmall', 'Ecircumflexsmall', 'Edieresissmall', 'Igravesmall', 'Iacutesmall', 'Icircumflexsmall',
    'Idieresissmall', 'Ethsmall', 'Ntildesmall', 'Ogravesmall', 'Oacutesmall', 'Ocircumflexsmall', 'Otildesmall',
    'Odieresissmall', 'OEsmall', 'Oslashsmall', 'Ugravesmall', 'Uacutesmall', 'Ucircumflexsmall', 'Udieresissmall',
    'Yacutesmall', 'Thornsmall', 'Ydieresissmall', '001.000', '001.001', '001.002', '001.003', 'Black', 'Bold',
    'Book', 'Light', 'Medium', 'Regular', 'Roman', 'Semibold');

type
  /// <summary>A CFF (Type1C / CIDFontType0C) font program. Glyph indexes are CharStrings INDEX positions.</summary>
  TPdfCFFFont = class(TPdfGlyphSource)
  private type
    /// <summary>An INDEX: Offsets holds Count + 1 absolute positions in the font data (clamped to the data).</summary>
    TCFFIndex = record
      Count: Integer;
      Offsets: TArray<Integer>;
      function ItemStart(I: Integer): Integer; inline;
      function ItemLength(I: Integer): Integer; inline;
    end;
    /// <summary>One DICT operator with its operands. Escaped operators (12 x) are stored as 1200 + x.</summary>
    TDictEntry = record
      Op: Integer;
      Operands: TArray<Double>;
    end;
    TDictEntries = TArray<TDictEntry>;
    /// <summary>The parts of a Private DICT the outline interpreter needs.</summary>
    TCFFPrivate = record
      Subrs: TCFFIndex;
      Bias: Integer;
      DefaultWidthX: Double;
      NominalWidthX: Double;
    end;
  private
    FData: TBytes;
    FFontName: string;
    FCharstringType: Integer;
    FCIDKeyed: Boolean;
    FCharStrings: TCFFIndex;
    FStrings: TCFFIndex;
    FGSubrs: TCFFIndex;
    FGBias: Integer;
    /// <summary>Non-CID: one element (Top DICT Private). CID: one per FDArray entry.</summary>
    FPrivates: TArray<TCFFPrivate>;
    /// <summary>CID: FD index per glyph, $FF when the glyph has no usable Font DICT.</summary>
    FFDSelect: TArray<Byte>;
    /// <summary>CID: per FD, a correction from that FD's glyph space to the space of FontMatrix (when they differ).</summary>
    FFDCorrection: TArray<TPdfMatrix>;
    FFDCorrect: TArray<Boolean>;
    /// <summary>Glyph index to SID (non-CID) or CID (CID-keyed).</summary>
    FCharset: TArray<Integer>;
    FNameMap: TDictionary<string, Integer>;
    FCIDMap: TDictionary<Integer, Integer>;
    FEncoding: array[0..255] of Integer;
    FMatrix: TPdfMatrix;
    FOutlineCount: Integer;
    FWidthCache: TArray<Single>;
    FWidthKnown: TArray<Boolean>;
    function ReadIndex(Pos: Integer; out Index: TCFFIndex; out EndPos: Integer): Boolean;
    function ReadDictOperand(var P: Integer; E: Integer; out V: Double; out Truncated: Boolean): Boolean;
    function ParseDict(Start, Len: Integer): TDictEntries;
    function ReadPrivate(const Dict: TDictEntries): TCFFPrivate;
    procedure ReadCharset(Offset: Integer);
    procedure ReadEncoding(Offset: Integer);
    procedure ReadFDSelect(Offset: Integer);
    procedure SetupMatrices(const Top: TDictEntries; const FDHasMatrix: TArray<Boolean>;
      const FDMatrix: TArray<TPdfMatrix>);
    function BytesToStr(Start, Len: Integer): string;
    function GetString(SID: Integer): string;
    function GlyphForStandardCode(Code: Integer): Integer;
    function PrivateIndexOf(GID: Integer): Integer;
    function GetFontName: string;
    function GetCharstringType: Integer;
  public
    /// <summary>True when Data starts with a CFF header (major version 1, hdrSize 4).</summary>
    class function IsCFF(const Data: TBytes): Boolean; static;
    /// <summary>Parses the font program. Raises EPdfFontError when the header or the Name/Top DICT INDEX is
    /// unusable; every other defect degrades gracefully (missing CharStrings give GlyphCount 0).
    /// Data is referenced, not copied: do not modify it while the font is alive.</summary>
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    /// <summary>Top DICT FontMatrix (default [0.001 0 0 0.001 0 0]); CID-keyed fonts combine it with the FontMatrix
    /// of the first Font DICT. Glyphs of a Font DICT with a different matrix are corrected in GetOutline.</summary>
    function FontMatrix: TPdfMatrix; override;
    /// <summary>Number of CharStrings.</summary>
    function GlyphCount: Integer; override;
    /// <summary>Interprets the Type 2 charstring of GID. True for every in-range glyph of a Type 2 font, also when
    /// the charstring is corrupt (the outline then holds what was drawn before the error). False for an
    /// out-of-range GID or a font with Type 1 charstrings (CharstringType 1, not supported).</summary>
    function GetOutline(GID: Integer; out Outline: TPdfGlyphOutline): Boolean; override;
    /// <summary>Charstring width: nominalWidthX + the width operand, or defaultWidthX, from the glyph's Private DICT.</summary>
    function GetAdvance(GID: Integer): Single; override;
    /// <summary>Glyph index by charset name (non-CID fonts only).</summary>
    function GlyphByName(const Name: string): Integer; override;
    /// <summary>Glyph index by the built-in encoding (predefined Standard/Expert or custom; non-CID fonts only).</summary>
    function GlyphByCode(Code: Integer): Integer; override;
    /// <summary>CID-keyed: glyph index whose charset entry is CID. Other fonts: the base behaviour (CID as GID).</summary>
    function GlyphByCID(CID: Integer): Integer; override;
    /// <summary>True when the Top DICT has ROS.</summary>
    function IsCIDKeyed: Boolean; override;
    function HasGlyphNames: Boolean; override;
    function HasCodeMap: Boolean; override;
    /// <summary>Number of charstrings longer than one byte (a lone endchar is not an outline).</summary>
    function OutlineCount: Integer; override;
    /// <summary>Glyph name of a glyph index (non-CID fonts), '' when unknown.</summary>
    function GlyphName(GID: Integer): string;
    /// <summary>CID of a glyph index (CID-keyed fonts), -1 otherwise.</summary>
    function GlyphCID(GID: Integer): Integer;
    /// <summary>First Name INDEX entry.</summary>
    property FontName: string read GetFontName;
    /// <summary>Top DICT CharstringType: 2 (Type 2) or 1 (Type 1 charstrings, outlines unsupported).</summary>
    property CharstringType: Integer read GetCharstringType;
  end;

implementation

const
  // Predefined encodings (code -> SID, 0 = .notdef) and charsets (GID -> SID), generated from pdf.js
  // encodings.js (StandardEncoding, ExpertEncoding) and charsets.js (ExpertCharset, ExpertSubsetCharset).
  CFFStandardEncodingSIDs: array[0..255] of Word = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6,
    7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
    36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91,
    92, 93, 94, 95, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 0, 111, 112, 113, 114, 0, 115, 116, 117,
    118, 119, 120, 121, 122, 0, 123, 0, 124, 125, 126, 127, 128, 129, 130, 131, 0, 132, 133, 0, 134, 135, 136, 137, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 138, 0, 139, 0, 0, 0, 0, 140, 141, 142, 143, 0, 0, 0, 0, 0, 144, 0,
    0, 0, 145, 0, 0, 146, 147, 148, 149, 0, 0, 0, 0);

  CFFExpertEncodingSIDs: array[0..255] of Word = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 229, 230, 0,
    231, 232, 233, 234, 235, 236, 237, 238, 13, 14, 15, 99, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 27, 28,
    249, 250, 251, 252, 0, 253, 254, 255, 256, 257, 0, 0, 0, 258, 0, 0, 259, 260, 261, 262, 0, 0, 263, 264, 265, 0,
    266, 109, 110, 267, 268, 269, 0, 270, 271, 272, 273, 274, 275, 276, 277, 278, 279, 280, 281, 282, 283, 284, 285,
    286, 287, 288, 289, 290, 291, 292, 293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 304, 305, 306, 0, 0, 307, 308, 309,
    310, 311, 0, 312, 0, 0, 313, 0, 0, 314, 315, 0, 0, 316, 317, 318, 0, 0, 0, 158, 155, 163, 319, 320, 321, 322, 323,
    324, 325, 0, 0, 326, 150, 164, 169, 327, 328, 329, 330, 331, 332, 333, 334, 335, 336, 337, 338, 339, 340, 341,
    342, 343, 344, 345, 346, 347, 348, 349, 350, 351, 352, 353, 354, 355, 356, 357, 358, 359, 360, 361, 362, 363, 364,
    365, 366, 367, 368, 369, 370, 371, 372, 373, 374, 375, 376, 377, 378);

  CFFExpertCharsetSIDs: array[0..165] of Word = (
    0, 1, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 13, 14, 15, 99, 239, 240, 241, 242, 243, 244, 245, 246,
    247, 248, 27, 28, 249, 250, 251, 252, 253, 254, 255, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 109,
    110, 267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278, 279, 280, 281, 282, 283, 284, 285, 286, 287, 288,
    289, 290, 291, 292, 293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303, 304, 305, 306, 307, 308, 309, 310, 311,
    312, 313, 314, 315, 316, 317, 318, 158, 155, 163, 319, 320, 321, 322, 323, 324, 325, 326, 150, 164, 169, 327, 328,
    329, 330, 331, 332, 333, 334, 335, 336, 337, 338, 339, 340, 341, 342, 343, 344, 345, 346, 347, 348, 349, 350, 351,
    352, 353, 354, 355, 356, 357, 358, 359, 360, 361, 362, 363, 364, 365, 366, 367, 368, 369, 370, 371, 372, 373, 374,
    375, 376, 377, 378);

  CFFExpertSubsetCharsetSIDs: array[0..86] of Word = (
    0, 1, 231, 232, 235, 236, 237, 238, 13, 14, 15, 99, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 27, 28, 249,
    250, 251, 253, 254, 255, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 109, 110, 267, 268, 269, 270, 272,
    300, 301, 302, 305, 314, 315, 158, 155, 163, 320, 321, 322, 323, 324, 325, 326, 150, 164, 169, 327, 328, 329, 330,
    331, 332, 333, 334, 335, 336, 337, 338, 339, 340, 341, 342, 343, 344, 345, 346);

  /// <summary>Type 2 limits: argument stack, subroutine nesting, operators per glyph.</summary>
  CFFMaxStack = 48;
  CFFMaxSubrDepth = 10;
  CFFMaxOps = 200000;
  CFFMaxFDs = 255;
  CFFNoFD = $FF;
  /// <summary>Magnitude clamp for DICT operands and charstring arithmetic (keeps Double/Single math finite).</summary>
  CFFMaxValue = 1E9;

function ClampValue(V: Double): Double; inline;
begin
  if V > CFFMaxValue then
    Result := CFFMaxValue
  else if V < -CFFMaxValue then
    Result := -CFFMaxValue
  else
    Result := V;
end;

/// <summary>Rounds V to an Integer; Fallback when V is not a sensible integer value.</summary>
function SafeRound(V: Double; Fallback: Integer): Integer;
begin
  if IsNan(V) or (V > 2147483000.0) or (V < -2147483000.0) then
    Result := Fallback
  else
    Result := Round(V);
end;

function SubrBias(Count: Integer): Integer;
begin
  if Count < 1240 then
    Result := 107
  else if Count < 33900 then
    Result := 1131
  else
    Result := 32768;
end;

/// <summary>Operands of the last occurrence of Op.</summary>
function DictFind(const D: TPdfCFFFont.TDictEntries; Op: Integer; out Operands: TArray<Double>): Boolean;
var
  I: Integer;
begin
  for I := High(D) downto 0 do
    if D[I].Op = Op then
    begin
      Operands := D[I].Operands;
      Exit(True);
    end;
  Operands := nil;
  Result := False;
end;

function DictNum(const D: TPdfCFFFont.TDictEntries; Op: Integer; Default: Double): Double;
var
  Ops: TArray<Double>;
begin
  if DictFind(D, Op, Ops) and (Length(Ops) > 0) then
    Result := Ops[0]
  else
    Result := Default;
end;

function DictInt(const D: TPdfCFFFont.TDictEntries; Op: Integer; Default: Integer): Integer;
var
  Ops: TArray<Double>;
begin
  if DictFind(D, Op, Ops) and (Length(Ops) > 0) then
    Result := SafeRound(Ops[0], Default)
  else
    Result := Default;
end;

/// <summary>FontMatrix (12 7) of a DICT; False when absent, incomplete or degenerate.</summary>
function DictMatrix(const D: TPdfCFFFont.TDictEntries; out M: TPdfMatrix): Boolean;
var
  Ops: TArray<Double>;
begin
  M := TPdfMatrix.Identity;
  if not DictFind(D, 1207, Ops) or (Length(Ops) < 6) then
    Exit(False);
  M := TPdfMatrix.Create(Ops[0], Ops[1], Ops[2], Ops[3], Ops[4], Ops[5]);
  Result := Abs(M.A * M.D - M.B * M.C) > 1E-20;
  if not Result then
    M := TPdfMatrix.Identity;
end;

function NearIdentity(const M: TPdfMatrix): Boolean;
const
  Eps = 1E-6;
begin
  Result := (Abs(M.A - 1) < Eps) and (Abs(M.B) < Eps) and (Abs(M.C) < Eps) and (Abs(M.D - 1) < Eps) and
    (Abs(M.E) < Eps) and (Abs(M.F) < Eps);
end;

{ TPdfCFFFont.TCFFIndex }

function TPdfCFFFont.TCFFIndex.ItemStart(I: Integer): Integer;
begin
  Result := Offsets[I];
end;

function TPdfCFFFont.TCFFIndex.ItemLength(I: Integer): Integer;
begin
  Result := Offsets[I + 1] - Offsets[I];
end;

{ Type 2 charstring interpreter }

type
  TCFFRunner = record
    Font: TPdfCFFFont;
    Data: TBytes;
    LocalSubrs: TPdfCFFFont.TCFFIndex;
    LocalBias: Integer;
    DefaultWidthX, NominalWidthX: Double;
    Stack: array[0..CFFMaxStack - 1] of Double;
    SP: Integer;
    Transient: array[0..31] of Double;
    X, Y: Double;
    Stems: Integer;
    WidthChecked, HasWidth: Boolean;
    Width: Double;
    Open: Boolean;
    Ops: Integer;
    Done: Boolean;
    WidthOnly: Boolean;
    SeacDepth: Integer;
    Outline: TPdfGlyphOutline;
    procedure Init(AFont: TPdfCFFFont; Priv: Integer; AWidthOnly: Boolean);
    function Advance: Double;
    procedure Push(V: Double);
    procedure CheckWidth(Extra: Boolean);
    procedure EnsureOpen;
    procedure MoveTo;
    procedure LineTo;
    procedure CurveTo(X1, Y1, X2, Y2, X3, Y3: Double);
    procedure CloseContour;
    procedure Seac(ADX, ADY: Double; BChar, AChar: Integer);
    procedure Escape(Op: Integer);
    procedure Exec(Start, Len, Depth: Integer);
    procedure RunGlyph(GID: Integer);
  end;

procedure TCFFRunner.Init(AFont: TPdfCFFFont; Priv: Integer; AWidthOnly: Boolean);
begin
  Self := Default(TCFFRunner);
  Font := AFont;
  Data := AFont.FData;
  WidthOnly := AWidthOnly;
  LocalBias := 107;
  if (Priv >= 0) and (Priv < Length(AFont.FPrivates)) then
  begin
    LocalSubrs := AFont.FPrivates[Priv].Subrs;
    LocalBias := AFont.FPrivates[Priv].Bias;
    DefaultWidthX := AFont.FPrivates[Priv].DefaultWidthX;
    NominalWidthX := AFont.FPrivates[Priv].NominalWidthX;
  end;
end;

function TCFFRunner.Advance: Double;
begin
  if HasWidth then
    Result := NominalWidthX + Width
  else
    Result := DefaultWidthX;
end;

procedure TCFFRunner.Push(V: Double);
begin
  if SP >= CFFMaxStack then
    SP := 0; // stack overflow: clear and continue
  Stack[SP] := V;
  Inc(SP);
end;

procedure TCFFRunner.CheckWidth(Extra: Boolean);
begin
  if WidthChecked then
    Exit;
  WidthChecked := True;
  if Extra and (SP > 0) then
  begin
    Width := Stack[0];
    HasWidth := True;
    if SP > 1 then
      Move(Stack[1], Stack[0], (SP - 1) * SizeOf(Double));
    Dec(SP);
  end;
  if WidthOnly then
    Done := True;
end;

procedure TCFFRunner.EnsureOpen;
begin
  if not Open then
  begin
    Outline.MoveTo(X, Y);
    Open := True;
  end;
end;

procedure TCFFRunner.MoveTo;
begin
  CloseContour;
  Outline.MoveTo(X, Y);
  Open := True;
end;

procedure TCFFRunner.LineTo;
begin
  EnsureOpen;
  Outline.LineTo(X, Y);
end;

procedure TCFFRunner.CurveTo(X1, Y1, X2, Y2, X3, Y3: Double);
begin
  EnsureOpen;
  Outline.CubicTo(X1, Y1, X2, Y2, X3, Y3);
  X := X3;
  Y := Y3;
end;

procedure TCFFRunner.CloseContour;
begin
  if Open then
    Outline.Close;
  Open := False;
end;

procedure TCFFRunner.Seac(ADX, ADY: Double; BChar, AChar: Integer);
var
  BaseGID, AccentGID: Integer;
  Sub: TCFFRunner;
begin
  if SeacDepth > 0 then
    Exit;
  BaseGID := Font.GlyphForStandardCode(BChar);
  AccentGID := Font.GlyphForStandardCode(AChar);
  CloseContour;
  if BaseGID >= 0 then
  begin
    Sub.Init(Font, Font.PrivateIndexOf(BaseGID), False);
    Sub.SeacDepth := SeacDepth + 1;
    Sub.RunGlyph(BaseGID);
    Outline.Append(Sub.Outline, 0, 0);
  end;
  if AccentGID >= 0 then
  begin
    Sub.Init(Font, Font.PrivateIndexOf(AccentGID), False);
    Sub.SeacDepth := SeacDepth + 1;
    Sub.RunGlyph(AccentGID);
    Outline.Append(Sub.Outline, ADX, ADY);
  end;
end;

procedure TCFFRunner.Escape(Op: Integer);
var
  X1, Y1, X2, Y2, X0, Y0, A: Double;
  I, N, J, K: Integer;
  Tmp: array[0..CFFMaxStack - 1] of Double;
begin
  case Op of
    34: // hflex: dx1 dx2 dy2 dx3 dx4 dx5 dx6
      begin
        if SP >= 7 then
        begin
          Y0 := Y;
          X1 := X + Stack[0];
          X2 := X1 + Stack[1];
          Y2 := Y + Stack[2];
          CurveTo(X1, Y0, X2, Y2, X2 + Stack[3], Y2);
          X1 := X + Stack[4];
          X2 := X1 + Stack[5];
          CurveTo(X1, Y2, X2, Y0, X2 + Stack[6], Y0);
        end;
        SP := 0;
      end;
    35: // flex: dx1 dy1 .. dx6 dy6 fd
      begin
        if SP >= 13 then
        begin
          for K := 0 to 1 do
          begin
            I := K * 6;
            X1 := X + Stack[I];
            Y1 := Y + Stack[I + 1];
            X2 := X1 + Stack[I + 2];
            Y2 := Y1 + Stack[I + 3];
            CurveTo(X1, Y1, X2, Y2, X2 + Stack[I + 4], Y2 + Stack[I + 5]);
          end;
        end;
        SP := 0;
      end;
    36: // hflex1: dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6
      begin
        if SP >= 9 then
        begin
          Y0 := Y;
          X1 := X + Stack[0];
          Y1 := Y + Stack[1];
          X2 := X1 + Stack[2];
          Y2 := Y1 + Stack[3];
          CurveTo(X1, Y1, X2, Y2, X2 + Stack[4], Y2);
          X1 := X + Stack[5];
          Y1 := Y;
          X2 := X1 + Stack[6];
          Y2 := Y1 + Stack[7];
          CurveTo(X1, Y1, X2, Y2, X2 + Stack[8], Y0);
        end;
        SP := 0;
      end;
    37: // flex1: dx1 dy1 .. dx5 dy5 d6
      begin
        if SP >= 11 then
        begin
          X0 := X;
          Y0 := Y;
          X1 := X + Stack[0];
          Y1 := Y + Stack[1];
          X2 := X1 + Stack[2];
          Y2 := Y1 + Stack[3];
          CurveTo(X1, Y1, X2, Y2, X2 + Stack[4], Y2 + Stack[5]);
          X1 := X + Stack[6];
          Y1 := Y + Stack[7];
          X2 := X1 + Stack[8];
          Y2 := Y1 + Stack[9];
          if Abs(X2 - X0) > Abs(Y2 - Y0) then
            CurveTo(X1, Y1, X2, Y2, X2 + Stack[10], Y0)
          else
            CurveTo(X1, Y1, X2, Y2, X0, Y2 + Stack[10]);
        end;
        SP := 0;
      end;
    3, 4, 10, 11, 12, 15, 24: // and or add sub div eq mul
      begin
        if SP < 2 then
        begin
          SP := 0;
          Exit;
        end;
        X1 := Stack[SP - 2];
        X2 := Stack[SP - 1];
        case Op of
          3: A := Ord((X1 <> 0) and (X2 <> 0));
          4: A := Ord((X1 <> 0) or (X2 <> 0));
          10: A := X1 + X2;
          11: A := X1 - X2;
          12:
            if X2 = 0 then
              A := 0
            else
              A := X1 / X2;
          15: A := Ord(X1 = X2);
        else
          A := X1 * X2;
        end;
        Stack[SP - 2] := ClampValue(A);
        Dec(SP);
      end;
    5, 9, 14, 26: // not abs neg sqrt
      begin
        if SP < 1 then
          Exit;
        A := Stack[SP - 1];
        case Op of
          5: A := Ord(A = 0);
          9: A := Abs(A);
          14: A := -A;
        else
          if A > 0 then
            A := Sqrt(A)
          else
            A := 0;
        end;
        Stack[SP - 1] := A;
      end;
    18: // drop
      if SP > 0 then
        Dec(SP);
    20: // put: val i put
      begin
        if SP < 2 then
        begin
          SP := 0;
          Exit;
        end;
        I := SafeRound(Stack[SP - 1], -1);
        if (I >= 0) and (I <= High(Transient)) then
          Transient[I] := Stack[SP - 2];
        Dec(SP, 2);
      end;
    21: // get: i get
      begin
        if SP < 1 then
          Exit;
        I := SafeRound(Stack[SP - 1], -1);
        if (I >= 0) and (I <= High(Transient)) then
          Stack[SP - 1] := Transient[I]
        else
          Stack[SP - 1] := 0;
      end;
    22: // ifelse: s1 s2 v1 v2
      begin
        if SP < 4 then
        begin
          SP := 0;
          Exit;
        end;
        if Stack[SP - 2] <= Stack[SP - 1] then
          A := Stack[SP - 4]
        else
          A := Stack[SP - 3];
        Dec(SP, 3);
        Stack[SP - 1] := A;
      end;
    23: // random: deterministic value in (0, 1]
      Push(0.5);
    27: // dup
      if SP > 0 then
        Push(Stack[SP - 1]);
    28: // exch
      if SP >= 2 then
      begin
        A := Stack[SP - 1];
        Stack[SP - 1] := Stack[SP - 2];
        Stack[SP - 2] := A;
      end
      else
        SP := 0;
    29: // index
      begin
        if SP < 1 then
          Exit;
        I := SafeRound(Stack[SP - 1], 0);
        if I < 0 then
          I := 0;
        if SP - 2 - I >= 0 then
          Stack[SP - 1] := Stack[SP - 2 - I]
        else
          Stack[SP - 1] := 0;
      end;
    30: // roll: n j roll
      begin
        if SP < 2 then
        begin
          SP := 0;
          Exit;
        end;
        N := SafeRound(Stack[SP - 2], 0);
        J := SafeRound(Stack[SP - 1], 0);
        Dec(SP, 2);
        if (N > 0) and (N <= SP) then
        begin
          J := J mod N;
          if J < 0 then
            Inc(J, N);
          for K := 0 to N - 1 do
            Tmp[(K + J) mod N] := Stack[SP - N + K];
          for K := 0 to N - 1 do
            Stack[SP - N + K] := Tmp[K];
        end;
      end;
  else
    SP := 0; // dotsection (12 0) and reserved operators
  end;
end;

procedure TCFFRunner.Exec(Start, Len, Depth: Integer);
var
  P, E, B, I, N, Bias: Integer;
  V, X1, Y1, X2, Y2, X3, Y3: Double;
  Horz, Last: Boolean;
  Subrs: TPdfCFFFont.TCFFIndex;
begin
  if Depth > CFFMaxSubrDepth then
  begin
    Done := True;
    Exit;
  end;
  P := Start;
  E := Start + Len;
  while (P < E) and not Done do
  begin
    Inc(Ops);
    if Ops > CFFMaxOps then
    begin
      Done := True;
      Exit;
    end;
    B := Data[P];
    Inc(P);
    if B >= 32 then
    begin
      if B <= 246 then
        V := B - 139
      else if B <= 254 then
      begin
        if P >= E then
        begin
          Done := True;
          Exit;
        end;
        if B <= 250 then
          V := (B - 247) * 256 + Data[P] + 108
        else
          V := -(B - 251) * 256 - Data[P] - 108;
        Inc(P);
      end
      else
      begin
        if P + 4 > E then
        begin
          Done := True;
          Exit;
        end;
        V := Int32((Cardinal(Data[P]) shl 24) or (Cardinal(Data[P + 1]) shl 16) or
          (Cardinal(Data[P + 2]) shl 8) or Cardinal(Data[P + 3])) / 65536;
        Inc(P, 4);
      end;
      Push(V);
      Continue;
    end;
    case B of
      28: // shortint
        begin
          if P + 2 > E then
          begin
            Done := True;
            Exit;
          end;
          Push(SmallInt((Data[P] shl 8) or Data[P + 1]));
          Inc(P, 2);
        end;
      1, 3, 18, 23: // hstem vstem hstemhm vstemhm
        begin
          CheckWidth(Odd(SP));
          Inc(Stems, SP div 2);
          SP := 0;
        end;
      19, 20: // hintmask cntrmask: pending arguments are an implicit vstem
        begin
          CheckWidth(Odd(SP));
          Inc(Stems, SP div 2);
          SP := 0;
          Inc(P, (Stems + 7) div 8);
        end;
      21: // rmoveto
        begin
          CheckWidth(SP > 2);
          if SP >= 2 then
          begin
            X := X + Stack[SP - 2];
            Y := Y + Stack[SP - 1];
            MoveTo;
          end;
          SP := 0;
        end;
      22: // hmoveto
        begin
          CheckWidth(SP > 1);
          if SP >= 1 then
          begin
            X := X + Stack[SP - 1];
            MoveTo;
          end;
          SP := 0;
        end;
      4: // vmoveto
        begin
          CheckWidth(SP > 1);
          if SP >= 1 then
          begin
            Y := Y + Stack[SP - 1];
            MoveTo;
          end;
          SP := 0;
        end;
      5: // rlineto
        begin
          I := 0;
          while I + 2 <= SP do
          begin
            X := X + Stack[I];
            Y := Y + Stack[I + 1];
            LineTo;
            Inc(I, 2);
          end;
          SP := 0;
        end;
      6, 7: // hlineto vlineto
        begin
          Horz := B = 6;
          for I := 0 to SP - 1 do
          begin
            if Horz then
              X := X + Stack[I]
            else
              Y := Y + Stack[I];
            LineTo;
            Horz := not Horz;
          end;
          SP := 0;
        end;
      8: // rrcurveto
        begin
          I := 0;
          while I + 6 <= SP do
          begin
            X1 := X + Stack[I];
            Y1 := Y + Stack[I + 1];
            X2 := X1 + Stack[I + 2];
            Y2 := Y1 + Stack[I + 3];
            CurveTo(X1, Y1, X2, Y2, X2 + Stack[I + 4], Y2 + Stack[I + 5]);
            Inc(I, 6);
          end;
          SP := 0;
        end;
      24: // rcurveline
        begin
          I := 0;
          while SP - I >= 8 do
          begin
            X1 := X + Stack[I];
            Y1 := Y + Stack[I + 1];
            X2 := X1 + Stack[I + 2];
            Y2 := Y1 + Stack[I + 3];
            CurveTo(X1, Y1, X2, Y2, X2 + Stack[I + 4], Y2 + Stack[I + 5]);
            Inc(I, 6);
          end;
          if SP - I >= 2 then
          begin
            X := X + Stack[I];
            Y := Y + Stack[I + 1];
            LineTo;
          end;
          SP := 0;
        end;
      25: // rlinecurve
        begin
          I := 0;
          while SP - I >= 8 do
          begin
            X := X + Stack[I];
            Y := Y + Stack[I + 1];
            LineTo;
            Inc(I, 2);
          end;
          if SP - I >= 6 then
          begin
            X1 := X + Stack[I];
            Y1 := Y + Stack[I + 1];
            X2 := X1 + Stack[I + 2];
            Y2 := Y1 + Stack[I + 3];
            CurveTo(X1, Y1, X2, Y2, X2 + Stack[I + 4], Y2 + Stack[I + 5]);
          end;
          SP := 0;
        end;
      26: // vvcurveto: dx1? {dya dxb dyb dyc}+
        begin
          I := 0;
          if Odd(SP) then
          begin
            X := X + Stack[0];
            I := 1;
          end;
          while I + 4 <= SP do
          begin
            X1 := X;
            Y1 := Y + Stack[I];
            X2 := X1 + Stack[I + 1];
            Y2 := Y1 + Stack[I + 2];
            CurveTo(X1, Y1, X2, Y2, X2, Y2 + Stack[I + 3]);
            Inc(I, 4);
          end;
          SP := 0;
        end;
      27: // hhcurveto: dy1? {dxa dxb dyb dxc}+
        begin
          I := 0;
          if Odd(SP) then
          begin
            Y := Y + Stack[0];
            I := 1;
          end;
          while I + 4 <= SP do
          begin
            X1 := X + Stack[I];
            Y1 := Y;
            X2 := X1 + Stack[I + 1];
            Y2 := Y1 + Stack[I + 2];
            CurveTo(X1, Y1, X2, Y2, X2 + Stack[I + 3], Y2);
            Inc(I, 4);
          end;
          SP := 0;
        end;
      30, 31: // vhcurveto hvcurveto: alternating, optional final extra coordinate
        begin
          I := 0;
          Horz := B = 31;
          while I + 4 <= SP do
          begin
            Last := SP - I = 5;
            if Horz then
            begin
              X1 := X + Stack[I];
              Y1 := Y;
              X2 := X1 + Stack[I + 1];
              Y2 := Y1 + Stack[I + 2];
              Y3 := Y2 + Stack[I + 3];
              X3 := X2;
              if Last then
                X3 := X3 + Stack[I + 4];
            end
            else
            begin
              X1 := X;
              Y1 := Y + Stack[I];
              X2 := X1 + Stack[I + 1];
              Y2 := Y1 + Stack[I + 2];
              X3 := X2 + Stack[I + 3];
              Y3 := Y2;
              if Last then
                Y3 := Y3 + Stack[I + 4];
            end;
            CurveTo(X1, Y1, X2, Y2, X3, Y3);
            Inc(I, 4);
            if Last then
              Inc(I);
            Horz := not Horz;
          end;
          SP := 0;
        end;
      10, 29: // callsubr callgsubr
        begin
          if SP < 1 then
          begin
            Done := True;
            Exit;
          end;
          Dec(SP);
          if B = 10 then
          begin
            Subrs := LocalSubrs;
            Bias := LocalBias;
          end
          else
          begin
            Subrs := Font.FGSubrs;
            Bias := Font.FGBias;
          end;
          V := Stack[SP] + Bias;
          if IsNan(V) or (V < 0) or (V >= Subrs.Count) then
          begin
            Done := True; // out-of-range subroutine: keep what was drawn
            Exit;
          end;
          N := Trunc(V);
          Exec(Subrs.ItemStart(N), Subrs.ItemLength(N), Depth + 1);
        end;
      11: // return
        Exit;
      14: // endchar, optionally with the seac arguments adx ady bchar achar
        begin
          CheckWidth((SP = 1) or (SP = 5));
          if (SP >= 4) and not WidthOnly then
            Seac(Stack[SP - 4], Stack[SP - 3], SafeRound(Stack[SP - 2], -1), SafeRound(Stack[SP - 1], -1));
          SP := 0;
          CloseContour;
          Done := True;
          Exit;
        end;
      12: // escape
        begin
          if P >= E then
          begin
            Done := True;
            Exit;
          end;
          B := Data[P];
          Inc(P);
          Escape(B);
        end;
    else
      SP := 0; // reserved operators
    end;
  end;
end;

procedure TCFFRunner.RunGlyph(GID: Integer);
begin
  if (GID < 0) or (GID >= Font.FCharStrings.Count) then
    Exit;
  Exec(Font.FCharStrings.ItemStart(GID), Font.FCharStrings.ItemLength(GID), 0);
  CloseContour;
end;

{ TPdfCFFFont }

class function TPdfCFFFont.IsCFF(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= 4) and (Data[0] = 1) and (Data[2] = 4);
end;

constructor TPdfCFFFont.Create(const Data: TBytes);
var
  P, HdrSize, I, N, FDCount: Integer;
  NameIdx, TopIdx, FDIdx: TCFFIndex;
  Top, FD: TDictEntries;
  Ops: TArray<Double>;
  FDHasMatrix: TArray<Boolean>;
  FDMatrix: TArray<TPdfMatrix>;
begin
  inherited Create;
  FData := Data;
  FNameMap := TDictionary<string, Integer>.Create;
  FCIDMap := TDictionary<Integer, Integer>.Create;
  for I := 0 to 255 do
    FEncoding[I] := -1;
  FCharstringType := 2;
  FGBias := 107;
  FMatrix := TPdfMatrix.Create(0.001, 0, 0, 0.001, 0, 0);

  if (Length(FData) < 4) or (FData[0] <> 1) or (FData[2] < 4) then
    raise EPdfFontError.Create('CFF: invalid header');
  HdrSize := FData[2];
  if not ReadIndex(HdrSize, NameIdx, P) then
    raise EPdfFontError.Create('CFF: invalid Name INDEX');
  if not ReadIndex(P, TopIdx, P) or (TopIdx.Count = 0) then
    raise EPdfFontError.Create('CFF: invalid Top DICT INDEX');
  if NameIdx.Count > 0 then
    FFontName := BytesToStr(NameIdx.ItemStart(0), NameIdx.ItemLength(0));
  if not ReadIndex(P, FStrings, P) or not ReadIndex(P, FGSubrs, P) then
  begin
    // A broken String INDEX also hides the Global Subr INDEX behind it.
    FStrings := Default(TCFFIndex);
    FGSubrs := Default(TCFFIndex);
  end;
  FGBias := SubrBias(FGSubrs.Count);

  Top := ParseDict(TopIdx.ItemStart(0), TopIdx.ItemLength(0));
  FCIDKeyed := DictFind(Top, 1230, Ops);
  FCharstringType := DictInt(Top, 1206, 2);

  N := DictInt(Top, 17, 0);
  if (N <= 0) or not ReadIndex(N, FCharStrings, P) then
    FCharStrings := Default(TCFFIndex);

  FDHasMatrix := nil;
  FDMatrix := nil;
  if FCIDKeyed then
  begin
    N := DictInt(Top, 1236, 0);
    if (N > 0) and ReadIndex(N, FDIdx, P) then
    begin
      FDCount := Min(FDIdx.Count, CFFMaxFDs);
      SetLength(FPrivates, FDCount);
      SetLength(FDHasMatrix, FDCount);
      SetLength(FDMatrix, FDCount);
      for I := 0 to FDCount - 1 do
      begin
        FD := ParseDict(FDIdx.ItemStart(I), FDIdx.ItemLength(I));
        FPrivates[I] := ReadPrivate(FD);
        FDHasMatrix[I] := DictMatrix(FD, FDMatrix[I]);
      end;
    end;
    ReadFDSelect(DictInt(Top, 1237, 0));
  end
  else
  begin
    SetLength(FPrivates, 1);
    FPrivates[0] := ReadPrivate(Top);
  end;
  SetupMatrices(Top, FDHasMatrix, FDMatrix);

  ReadCharset(DictInt(Top, 15, 0));
  if not FCIDKeyed then
    ReadEncoding(DictInt(Top, 16, 0));

  FOutlineCount := 0;
  for I := 0 to FCharStrings.Count - 1 do
    if FCharStrings.ItemLength(I) > 1 then
      Inc(FOutlineCount);
  SetLength(FWidthCache, FCharStrings.Count);
  SetLength(FWidthKnown, FCharStrings.Count);
end;

destructor TPdfCFFFont.Destroy;
begin
  FNameMap.Free;
  FCIDMap.Free;
  inherited;
end;

function TPdfCFFFont.ReadIndex(Pos: Integer; out Index: TCFFIndex; out EndPos: Integer): Boolean;
var
  Len, Count, OffSize, DataStart, I, J, P: Integer;
  Off, V, Prev: Int64;
begin
  Index := Default(TCFFIndex);
  EndPos := Pos;
  Len := Length(FData);
  if (Pos < 0) or (Int64(Pos) + 2 > Len) then
    Exit(False);
  Count := (FData[Pos] shl 8) or FData[Pos + 1];
  if Count = 0 then
  begin
    EndPos := Pos + 2;
    Exit(True);
  end;
  if Pos + 3 > Len then
    Exit(False);
  OffSize := FData[Pos + 2];
  if (OffSize < 1) or (OffSize > 4) then
    Exit(False);
  if Int64(Pos) + 3 + Int64(Count + 1) * OffSize > Len then
    Exit(False);
  // Offsets are relative to the byte before the object data.
  DataStart := Pos + 3 + (Count + 1) * OffSize - 1;
  SetLength(Index.Offsets, Count + 1);
  P := Pos + 3;
  Prev := DataStart;
  for I := 0 to Count do
  begin
    Off := 0;
    for J := 1 to OffSize do
    begin
      Off := (Off shl 8) or FData[P];
      Inc(P);
    end;
    V := DataStart + Off;
    if V < Prev then
      V := Prev;
    if V > Len then
      V := Len;
    Index.Offsets[I] := Integer(V);
    Prev := V;
  end;
  Index.Count := Count;
  EndPos := Index.Offsets[Count];
  Result := True;
end;

function TPdfCFFFont.ReadDictOperand(var P: Integer; E: Integer; out V: Double; out Truncated: Boolean): Boolean;
const
  Nibbles: array[0..14] of string = ('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '.', 'E', 'E-', '', '-');
var
  B, Nib, K: Integer;
  S: string;
  Fin: Boolean;
begin
  V := 0;
  Truncated := False;
  Result := True;
  B := FData[P];
  Inc(P);
  case B of
    28:
      begin
        if P + 2 > E then
        begin
          Truncated := True;
          Exit(False);
        end;
        V := SmallInt((FData[P] shl 8) or FData[P + 1]);
        Inc(P, 2);
      end;
    29:
      begin
        if P + 4 > E then
        begin
          Truncated := True;
          Exit(False);
        end;
        V := Int32((Cardinal(FData[P]) shl 24) or (Cardinal(FData[P + 1]) shl 16) or
          (Cardinal(FData[P + 2]) shl 8) or Cardinal(FData[P + 3]));
        Inc(P, 4);
      end;
    30:
      begin
        S := '';
        Fin := False;
        while (P < E) and not Fin do
        begin
          B := FData[P];
          Inc(P);
          for K := 0 to 1 do
          begin
            if K = 0 then
              Nib := B shr 4
            else
              Nib := B and 15;
            if Nib = 15 then
            begin
              Fin := True;
              Break;
            end;
            if Length(S) < 64 then
              S := S + Nibbles[Nib];
          end;
        end;
        V := ClampValue(StrToFloatDef(S, 0, TFormatSettings.Invariant));
      end;
    32..246:
      V := B - 139;
    247..254:
      begin
        if P >= E then
        begin
          Truncated := True;
          Exit(False);
        end;
        if B <= 250 then
          V := (B - 247) * 256 + FData[P] + 108
        else
          V := -(B - 251) * 256 - FData[P] - 108;
        Inc(P);
      end;
  else
    Result := False; // reserved byte: skipped
  end;
end;

function TPdfCFFFont.ParseDict(Start, Len: Integer): TDictEntries;
var
  P, E, B, Count, OpCount: Integer;
  Operands: array[0..CFFMaxStack - 1] of Double;
  V: Double;
  Truncated: Boolean;
begin
  Result := nil;
  if (Start < 0) or (Len <= 0) or (Start >= Length(FData)) then
    Exit;
  P := Start;
  E := Integer(Min(Int64(Start) + Len, Int64(Length(FData))));
  Count := 0;
  OpCount := 0;
  while P < E do
  begin
    B := FData[P];
    if B <= 21 then
    begin
      Inc(P);
      if B = 12 then
      begin
        if P >= E then
          Break;
        B := 1200 + FData[P];
        Inc(P);
      end;
      if Count >= Length(Result) then
        SetLength(Result, Max(8, Count * 2));
      Result[Count].Op := B;
      SetLength(Result[Count].Operands, OpCount);
      if OpCount > 0 then
        Move(Operands[0], Result[Count].Operands[0], OpCount * SizeOf(Double));
      Inc(Count);
      OpCount := 0;
    end
    else if ReadDictOperand(P, E, V, Truncated) then
    begin
      if OpCount < CFFMaxStack then
      begin
        Operands[OpCount] := V;
        Inc(OpCount);
      end;
    end
    else if Truncated then
      Break;
  end;
  SetLength(Result, Count);
end;

function TPdfCFFFont.ReadPrivate(const Dict: TDictEntries): TCFFPrivate;
var
  Ops: TArray<Double>;
  Size, Offset, SubrOff, Dummy: Integer;
  PD: TDictEntries;
begin
  Result := Default(TCFFPrivate);
  Result.Bias := 107;
  if not DictFind(Dict, 18, Ops) or (Length(Ops) < 2) then
    Exit;
  Size := SafeRound(Ops[0], 0);
  Offset := SafeRound(Ops[1], 0);
  if (Size <= 0) or (Offset <= 0) or (Offset >= Length(FData)) then
    Exit;
  Size := Min(Size, Length(FData) - Offset);
  PD := ParseDict(Offset, Size);
  Result.DefaultWidthX := DictNum(PD, 20, 0);
  Result.NominalWidthX := DictNum(PD, 21, 0);
  SubrOff := DictInt(PD, 19, 0);
  if (SubrOff <> 0) and (Int64(Offset) + SubrOff > 0) and (Int64(Offset) + SubrOff < Length(FData)) then
  begin
    if ReadIndex(Offset + SubrOff, Result.Subrs, Dummy) then
      Result.Bias := SubrBias(Result.Subrs.Count)
    else
      Result.Subrs := Default(TCFFIndex);
  end;
end;

procedure TPdfCFFFont.ReadCharset(Offset: Integer);
var
  N, Len, P, G, Fmt, SID, Cnt, I: Integer;
  Name: string;
  Custom: Boolean;
begin
  N := FCharStrings.Count;
  SetLength(FCharset, N);
  if N = 0 then
    Exit;
  Len := Length(FData);
  Custom := (Offset > 2) and (Offset < Len);
  if Custom then
  begin
    Fmt := FData[Offset];
    P := Offset + 1;
    G := 1;
    case Fmt of
      0:
        while (G < N) and (P + 2 <= Len) do
        begin
          FCharset[G] := (FData[P] shl 8) or FData[P + 1];
          Inc(P, 2);
          Inc(G);
        end;
      1, 2:
        while G < N do
        begin
          if P + 2 + Fmt > Len then
            Break;
          SID := (FData[P] shl 8) or FData[P + 1];
          if Fmt = 1 then
          begin
            Cnt := FData[P + 2];
            Inc(P, 3);
          end
          else
          begin
            Cnt := (FData[P + 2] shl 8) or FData[P + 3];
            Inc(P, 4);
          end;
          I := 0;
          while (I <= Cnt) and (G < N) do
          begin
            FCharset[G] := SID + I;
            Inc(G);
            Inc(I);
          end;
        end;
    else
      Custom := False;
    end;
  end;
  if not Custom then
  begin
    if FCIDKeyed then
    begin
      for G := 0 to N - 1 do
        FCharset[G] := G; // identity
    end
    else if Offset = 1 then
    begin
      for G := 0 to Min(N, Length(CFFExpertCharsetSIDs)) - 1 do
        FCharset[G] := CFFExpertCharsetSIDs[G];
    end
    else if Offset = 2 then
    begin
      for G := 0 to Min(N, Length(CFFExpertSubsetCharsetSIDs)) - 1 do
        FCharset[G] := CFFExpertSubsetCharsetSIDs[G];
    end
    else
    begin
      for G := 0 to Min(N, 229) - 1 do
        FCharset[G] := G; // ISOAdobe: SID = GID for SIDs 0..228
    end;
  end;
  FCharset[0] := 0;

  for G := 0 to N - 1 do
    if FCIDKeyed then
    begin
      if not FCIDMap.ContainsKey(FCharset[G]) then
        FCIDMap.Add(FCharset[G], G);
    end
    else
    begin
      Name := GetString(FCharset[G]);
      if (Name <> '') and not FNameMap.ContainsKey(Name) then
        FNameMap.Add(Name, G);
    end;
end;

procedure TPdfCFFFont.ReadEncoding(Offset: Integer);
var
  Len, P, Fmt, I, N, G, First, Left, C, Code, SID: Integer;
begin
  Len := Length(FData);
  if (Offset > 1) and (Offset < Len) then
  begin
    Fmt := FData[Offset];
    P := Offset + 1;
    case Fmt and $7F of
      0:
        if P < Len then
        begin
          N := FData[P];
          Inc(P);
          for I := 1 to N do
          begin
            if P >= Len then
              Break;
            if I < GlyphCount then
              FEncoding[FData[P]] := I;
            Inc(P);
          end;
        end;
      1:
        if P < Len then
        begin
          N := FData[P];
          Inc(P);
          G := 1;
          for I := 1 to N do
          begin
            if P + 2 > Len then
              Break;
            First := FData[P];
            Left := FData[P + 1];
            Inc(P, 2);
            for C := First to First + Left do
            begin
              if (C <= 255) and (G < GlyphCount) then
                FEncoding[C] := G;
              Inc(G);
            end;
          end;
        end;
    else
      Offset := 0; // unknown format: fall back to StandardEncoding
    end;
    if (Offset > 1) and (Fmt and $80 <> 0) and (P < Len) then
    begin
      N := FData[P];
      Inc(P);
      for I := 1 to N do
      begin
        if P + 3 > Len then
          Break;
        Code := FData[P];
        SID := (FData[P + 1] shl 8) or FData[P + 2];
        Inc(P, 3);
        G := GlyphByName(GetString(SID));
        if G >= 0 then
          FEncoding[Code] := G;
      end;
    end;
    if Offset > 1 then
      Exit;
  end;
  // Predefined: 1 = ExpertEncoding, anything else StandardEncoding.
  for Code := 0 to 255 do
  begin
    if Offset = 1 then
      SID := CFFExpertEncodingSIDs[Code]
    else
      SID := CFFStandardEncodingSIDs[Code];
    if SID <> 0 then
      FEncoding[Code] := GlyphByName(PdfCFFStandardStrings[SID]);
  end;
end;

procedure TPdfCFFFont.ReadFDSelect(Offset: Integer);
var
  N, Len, G, P, R, NR, First, Next, FD, FDCount: Integer;
  Fill: Byte;
begin
  N := FCharStrings.Count;
  SetLength(FFDSelect, N);
  FDCount := Length(FPrivates);
  if FDCount > 0 then
    Fill := 0 // lenient: a missing or broken FDSelect selects the first Font DICT
  else
    Fill := CFFNoFD;
  for G := 0 to N - 1 do
    FFDSelect[G] := Fill;
  Len := Length(FData);
  if (FDCount > 0) and (Offset > 0) and (Offset < Len) then
  begin
    case FData[Offset] of
      0:
        for G := 0 to N - 1 do
          if Offset + 1 + G < Len then
            FFDSelect[G] := FData[Offset + 1 + G];
      3:
        if Offset + 3 <= Len then
        begin
          NR := (FData[Offset + 1] shl 8) or FData[Offset + 2];
          P := Offset + 3;
          for R := 0 to NR - 1 do
          begin
            if P + 5 > Len then
              Break;
            First := (FData[P] shl 8) or FData[P + 1];
            FD := FData[P + 2];
            Next := (FData[P + 3] shl 8) or FData[P + 4]; // next range's first GID or the sentinel
            if R = 0 then
              First := 0;
            for G := First to Min(Next, N) - 1 do
              FFDSelect[G] := FD;
            Inc(P, 3);
          end;
        end;
    end;
  end;
  for G := 0 to N - 1 do
    if FFDSelect[G] >= FDCount then
      FFDSelect[G] := CFFNoFD;
end;

procedure TPdfCFFFont.SetupMatrices(const Top: TDictEntries; const FDHasMatrix: TArray<Boolean>;
  const FDMatrix: TArray<TPdfMatrix>);
var
  TopMatrix, Inv, C: TPdfMatrix;
  HasTop: Boolean;
  Glyph: TArray<TPdfMatrix>;
  I, N: Integer;
begin
  HasTop := DictMatrix(Top, TopMatrix);
  if HasTop then
    FMatrix := TopMatrix;
  N := Length(FDHasMatrix);
  SetLength(FFDCorrection, N);
  SetLength(FFDCorrect, N);
  if not FCIDKeyed or (N = 0) then
    Exit;
  // Glyph space of FD i: FD FontMatrix followed by the Top DICT FontMatrix (taken as identity when the Top DICT
  // has none, as producers then move the 0.001 scale into the Font DICTs); without an FD matrix only the Top
  // (or default) matrix applies.
  SetLength(Glyph, N);
  for I := 0 to N - 1 do
    if FDHasMatrix[I] then
    begin
      if HasTop then
        Glyph[I] := FDMatrix[I].Multiply(TopMatrix)
      else
        Glyph[I] := FDMatrix[I];
    end
    else
      Glyph[I] := FMatrix;
  FMatrix := Glyph[0];
  if not FMatrix.Invert(Inv) then
    Exit;
  for I := 1 to N - 1 do
  begin
    C := Glyph[I].Multiply(Inv);
    if not NearIdentity(C) then
    begin
      FFDCorrect[I] := True;
      FFDCorrection[I] := C;
    end;
  end;
end;

function TPdfCFFFont.BytesToStr(Start, Len: Integer): string;
var
  I: Integer;
begin
  if (Start < 0) or (Len <= 0) or (Int64(Start) + Len > Length(FData)) then
    Exit('');
  SetLength(Result, Len);
  for I := 0 to Len - 1 do
    Result[I + 1] := Char(FData[Start + I]);
end;

function TPdfCFFFont.GetString(SID: Integer): string;
begin
  if SID < 0 then
    Result := ''
  else if SID <= High(PdfCFFStandardStrings) then
    Result := PdfCFFStandardStrings[SID]
  else if SID - Length(PdfCFFStandardStrings) < FStrings.Count then
    Result := BytesToStr(FStrings.ItemStart(SID - Length(PdfCFFStandardStrings)),
      FStrings.ItemLength(SID - Length(PdfCFFStandardStrings)))
  else
    Result := '';
end;

function TPdfCFFFont.GlyphForStandardCode(Code: Integer): Integer;
begin
  if (Code < 0) or (Code > 255) or (CFFStandardEncodingSIDs[Code] = 0) then
    Result := -1
  else
    Result := GlyphByName(PdfCFFStandardStrings[CFFStandardEncodingSIDs[Code]]);
end;

function TPdfCFFFont.PrivateIndexOf(GID: Integer): Integer;
begin
  if not FCIDKeyed then
    Result := 0
  else if (GID >= 0) and (GID < Length(FFDSelect)) and (FFDSelect[GID] <> CFFNoFD) then
    Result := FFDSelect[GID]
  else
    Result := -1;
end;

function TPdfCFFFont.GetFontName: string;
begin
  Result := FFontName;
end;

function TPdfCFFFont.GetCharstringType: Integer;
begin
  Result := FCharstringType;
end;

function TPdfCFFFont.FontMatrix: TPdfMatrix;
begin
  Result := FMatrix;
end;

function TPdfCFFFont.GlyphCount: Integer;
begin
  Result := FCharStrings.Count;
end;

function TPdfCFFFont.GetOutline(GID: Integer; out Outline: TPdfGlyphOutline): Boolean;
var
  R: TCFFRunner;
  Priv: Integer;
  Adv: Double;
begin
  Outline.Clear;
  if (GID < 0) or (GID >= GlyphCount) or (FCharstringType <> 2) then
    Exit(False);
  Priv := PrivateIndexOf(GID);
  R.Init(Self, Priv, False);
  R.RunGlyph(GID);
  Outline := R.Outline;
  Adv := R.Advance;
  if (Priv > 0) and (Priv < Length(FFDCorrect)) and FFDCorrect[Priv] then
  begin
    Outline.Transform(FFDCorrection[Priv]);
    Adv := Adv * FFDCorrection[Priv].A;
  end;
  Outline.Advance := Adv;
  Outline.Trim;
  if not FWidthKnown[GID] then
  begin
    FWidthCache[GID] := Adv;
    FWidthKnown[GID] := True;
  end;
  Result := True;
end;

function TPdfCFFFont.GetAdvance(GID: Integer): Single;
var
  R: TCFFRunner;
  Priv: Integer;
  Adv: Double;
begin
  if (GID < 0) or (GID >= GlyphCount) or (FCharstringType <> 2) then
    Exit(-1);
  if FWidthKnown[GID] then
    Exit(FWidthCache[GID]);
  Priv := PrivateIndexOf(GID);
  R.Init(Self, Priv, True);
  R.RunGlyph(GID);
  Adv := R.Advance;
  if (Priv > 0) and (Priv < Length(FFDCorrect)) and FFDCorrect[Priv] then
    Adv := Adv * FFDCorrection[Priv].A;
  FWidthCache[GID] := Adv;
  FWidthKnown[GID] := True;
  Result := Adv;
end;

function TPdfCFFFont.GlyphByName(const Name: string): Integer;
begin
  if FCIDKeyed or not FNameMap.TryGetValue(Name, Result) then
    Result := -1;
end;

function TPdfCFFFont.GlyphByCode(Code: Integer): Integer;
begin
  if FCIDKeyed or (Code < 0) or (Code > 255) then
    Result := -1
  else
    Result := FEncoding[Code];
end;

function TPdfCFFFont.GlyphByCID(CID: Integer): Integer;
begin
  if not FCIDKeyed then
    Result := inherited GlyphByCID(CID)
  else if not FCIDMap.TryGetValue(CID, Result) then
    Result := -1;
end;

function TPdfCFFFont.IsCIDKeyed: Boolean;
begin
  Result := FCIDKeyed;
end;

function TPdfCFFFont.HasGlyphNames: Boolean;
begin
  Result := not FCIDKeyed;
end;

function TPdfCFFFont.HasCodeMap: Boolean;
begin
  Result := not FCIDKeyed;
end;

function TPdfCFFFont.OutlineCount: Integer;
begin
  Result := FOutlineCount;
end;

function TPdfCFFFont.GlyphName(GID: Integer): string;
begin
  if FCIDKeyed or (GID < 0) or (GID >= Length(FCharset)) then
    Result := ''
  else
    Result := GetString(FCharset[GID]);
end;

function TPdfCFFFont.GlyphCID(GID: Integer): Integer;
begin
  if not FCIDKeyed or (GID < 0) or (GID >= Length(FCharset)) then
    Result := -1
  else
    Result := FCharset[GID];
end;

end.
