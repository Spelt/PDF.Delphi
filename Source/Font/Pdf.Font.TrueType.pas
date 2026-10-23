{*******************************************************************************
  Pdf.Font.TrueType
  TrueType / OpenType (sfnt) font program parser: table directory (including
  the first font of a TrueType collection), head, maxp, loca, glyf (simple and
  composite glyphs to quadratic outlines), hhea/hmtx metrics, cmap subtables
  (formats 0, 4, 6, 12, 13) and post glyph names.

  Fonts embedded in PDF files are often damaged or heavily subsetted, so the
  parser follows pdf.js (fonts.js, sanitizeGlyphLocations / readCmapTable /
  readPostScriptTable) in tolerating broken tables: every offset and length
  read from the file is validated, a corrupt table only makes that feature
  unavailable (empty glyph, lookup -1) and only a missing table directory
  raises EPdfFontError.

  OpenType fonts with CFF outlines ('OTTO') expose the raw 'CFF ' table through
  CFFData; their outlines are produced by Pdf.Font.CFF, not by this unit.

  All lookups and GetOutline are thread-safe after construction.
*******************************************************************************}
unit Pdf.Font.TrueType;

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections, Pdf.Core.Types, Pdf.Font.Glyphs;

type
  /// <summary>A TrueType (glyf) or OpenType font program. Outlines are in font units (y up); FontMatrix scales
  /// them to a 1-unit em.</summary>
  TPdfTrueTypeFont = class(TPdfGlyphSource)
  private type
    TTableEntry = record
      Offset: Integer;
      Length: Integer;
    end;

    TCmapSegment = record
      StartCode, EndCode, IdDelta, IdRangeOffset, RangeOffsetPos: Integer;
    end;

    TCmapGroup = record
      StartCode, EndCode, StartGlyph: Int64;
    end;

    TCmapSubtable = record
      PlatformID, EncodingID, Format: Integer;
      /// <summary>Absolute offset of the subtable in the font data.</summary>
      Offset: Integer;
      /// <summary>Formats 0 and 6: first code and number of glyph entries present.</summary>
      FirstCode, EntryCount: Integer;
      Segments: TArray<TCmapSegment>;
      Groups: TArray<TCmapGroup>;
      /// <summary>Segments or groups are sorted by end code (binary search possible).</summary>
      Sorted: Boolean;
    end;

    TGidChain = array[0..7] of Integer;
  private const
    MaxCompositeDepth = 8;
  private
    FData: TBytes;
    FTables: TDictionary<string, TTableEntry>;
    FSfntVersion: Cardinal;
    FUnitsPerEm: Integer;
    FIndexToLocFormat: Integer;
    FNumGlyphs: Integer;
    FHasGlyf: Boolean;
    FHasCFF: Boolean;
    FCFFData: TBytes;
    FGlyphStart: TArray<Integer>;
    FGlyphEnd: TArray<Integer>;
    FOutlineCount: Integer;
    FHmtxOffset: Integer;
    FNumHMetrics: Integer;
    FSubtables: TArray<TCmapSubtable>;
    FHasSymbolCmap: Boolean;
    FHasMacRomanCmap: Boolean;
    FHasUnicodeCmap: Boolean;
    FPostFormat: Integer;
    FPostOffset: Integer;
    FPostLength: Integer;
    FPostNumGlyphs: Integer;
    FNameLock: TObject;
    FNamesBuilt: Boolean;
    FNames: TArray<string>;
    FNameMap: TDictionary<string, Integer>;
    function Avail(Pos, Count: Int64): Boolean; inline;
    function U16(Pos: Integer): Integer; inline;
    function S16(Pos: Integer): Integer; inline;
    function U32(Pos: Integer): Int64; inline;
    function TagAt(Pos: Integer): string;
    function FindTable(const Tag: string; out Entry: TTableEntry): Boolean;
    procedure ReadDirectory;
    procedure ReadCFF;
    procedure ReadHead;
    procedure ReadMaxp;
    procedure ReadLoca;
    procedure ReadMetrics;
    procedure ReadCmap;
    procedure ReadPost;
    function ParseCmapSubtable(var T: TCmapSubtable): Boolean;
    function LookupSubtable(const T: TCmapSubtable; Code: Int64): Integer;
    function LookupPlatform(PlatformID, EncodingID: Integer; Code: Int64): Integer;
    function ValidGlyph(GID: Integer): Integer;
    procedure BuildNames;
    function BuildGlyph(GID, Depth: Integer; var Chain: TGidChain; var Outline: TPdfGlyphOutline): Boolean;
    function ParseSimpleGlyph(P, E, NumContours: Integer; var Outline: TPdfGlyphOutline): Boolean;
    function ParseCompositeGlyph(P, E, Depth: Integer; var Chain: TGidChain; var Outline: TPdfGlyphOutline): Boolean;
    function GetHasCmap: Boolean;
    function GetHasPostNames: Boolean;
  public
    /// <summary>True for sfnt data: version 0x00010000, 'true', 'ttcf' (first font is used) or 'OTTO'.</summary>
    class function IsTrueType(const Data: TBytes): Boolean; static;
    /// <summary>Parses the font program. Raises EPdfFontError only when there is no usable table directory;
    /// damaged tables make the corresponding feature unavailable instead.</summary>
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    /// <summary>Scaling by 1/unitsPerEm (1/1000 when head is missing or unitsPerEm is 0).</summary>
    function FontMatrix: TPdfMatrix; override;
    /// <summary>maxp numGlyphs, or the number of loca entries when maxp is missing.</summary>
    function GlyphCount: Integer; override;
    /// <summary>Quadratic outline of GID from the glyf table in font units (y up). False when the font has no
    /// usable glyf table, GID is out of range or the glyph data is corrupt; an empty glyph returns True.</summary>
    function GetOutline(GID: Integer; out Outline: TPdfGlyphOutline): Boolean; override;
    /// <summary>hmtx advance width in font units (the last entry repeats); -1 when the font has no metrics.</summary>
    function GetAdvance(GID: Integer): Single; override;
    /// <summary>Glyph index for a glyph name from the post table (format 2.0 names, format 1.0 standard
    /// Macintosh order); -1 otherwise.</summary>
    function GlyphByName(const Name: string): Integer; override;
    /// <summary>Glyph index through the (3,1) cmap, then any (0,x), then (3,10); -1 when unmapped.</summary>
    function GlyphByUnicode(CodePoint: Integer): Integer; override;
    /// <summary>GlyphBySymbolCode, then GlyphByMacCode. The font loader applies further heuristics itself.</summary>
    function GlyphByCode(Code: Integer): Integer; override;
    function HasGlyphNames: Boolean; override;
    function HasUnicodeMap: Boolean; override;
    function HasCodeMap: Boolean; override;
    /// <summary>Number of glyphs with a non-empty glyf entry; -1 when the font has no usable glyf table.</summary>
    function OutlineCount: Integer; override;
    /// <summary>(3,0) symbol cmap lookup trying Code, $F000+Code, $F100+Code, $F200+Code; -1 when there is no
    /// (3,0) table or no hit.</summary>
    function GlyphBySymbolCode(Code: Integer): Integer;
    /// <summary>(1,0) Macintosh Roman cmap lookup; -1 when absent.</summary>
    function GlyphByMacCode(Code: Integer): Integer;
    /// <summary>post table name of GID ('' when unknown).</summary>
    function GlyphName(GID: Integer): string;
    /// <summary>True when the table directory has an entry for Tag (padded with spaces to 4 characters).</summary>
    function HasTable(const Tag: string): Boolean;
    /// <summary>glyf and loca are present and usable.</summary>
    property HasGlyf: Boolean read FHasGlyf;
    /// <summary>A 'CFF ' table is present (OpenType CFF); outlines come from Pdf.Font.CFF, parsed by the loader.</summary>
    property HasCFF: Boolean read FHasCFF;
    /// <summary>Raw 'CFF ' table bytes (nil when absent).</summary>
    property CFFData: TBytes read FCFFData;
    /// <summary>head unitsPerEm (1000 when head is missing or the value is 0).</summary>
    property UnitsPerEm: Integer read FUnitsPerEm;
    /// <summary>At least one usable cmap subtable.</summary>
    property HasCmap: Boolean read GetHasCmap;
    /// <summary>A usable (3,0) symbol subtable.</summary>
    property HasSymbolCmap: Boolean read FHasSymbolCmap;
    /// <summary>A usable (1,0) Macintosh Roman subtable.</summary>
    property HasMacRomanCmap: Boolean read FHasMacRomanCmap;
    /// <summary>A usable (3,1), (0,x) or (3,10) subtable.</summary>
    property HasUnicodeCmap: Boolean read FHasUnicodeCmap;
    /// <summary>post table format 1.0 or a valid format 2.0.</summary>
    property HasPostNames: Boolean read GetHasPostNames;
    /// <summary>maxp numGlyphs (0 when maxp is missing).</summary>
    property NumGlyphs: Integer read FNumGlyphs;
  end;

implementation

const
  TagTTCF = $74746366; // 'ttcf'
  TagTRUE = $74727565; // 'true'
  TagOTTO = $4F54544F; // 'OTTO'
  TagV1 = $00010000;

  /// <summary>The 258 standard Macintosh glyph names (post format 1.0 order).</summary>
  MacGlyphNames: array[0..257] of string = (
    '.notdef', '.null', 'nonmarkingreturn', 'space', 'exclam', 'quotedbl',
    'numbersign', 'dollar', 'percent', 'ampersand', 'quotesingle', 'parenleft',
    'parenright', 'asterisk', 'plus', 'comma', 'hyphen', 'period', 'slash',
    'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
    'nine', 'colon', 'semicolon', 'less', 'equal', 'greater', 'question', 'at',
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',
    'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'bracketleft',
    'backslash', 'bracketright', 'asciicircum', 'underscore', 'grave', 'a', 'b',
    'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q',
    'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'braceleft', 'bar', 'braceright',
    'asciitilde', 'Adieresis', 'Aring', 'Ccedilla', 'Eacute', 'Ntilde',
    'Odieresis', 'Udieresis', 'aacute', 'agrave', 'acircumflex', 'adieresis',
    'atilde', 'aring', 'ccedilla', 'eacute', 'egrave', 'ecircumflex', 'edieresis',
    'iacute', 'igrave', 'icircumflex', 'idieresis', 'ntilde', 'oacute', 'ograve',
    'ocircumflex', 'odieresis', 'otilde', 'uacute', 'ugrave', 'ucircumflex',
    'udieresis', 'dagger', 'degree', 'cent', 'sterling', 'section', 'bullet',
    'paragraph', 'germandbls', 'registered', 'copyright', 'trademark', 'acute',
    'dieresis', 'notequal', 'AE', 'Oslash', 'infinity', 'plusminus', 'lessequal',
    'greaterequal', 'yen', 'mu', 'partialdiff', 'summation', 'product', 'pi',
    'integral', 'ordfeminine', 'ordmasculine', 'Omega', 'ae', 'oslash',
    'questiondown', 'exclamdown', 'logicalnot', 'radical', 'florin',
    'approxequal', 'Delta', 'guillemotleft', 'guillemotright', 'ellipsis',
    'nonbreakingspace', 'Agrave', 'Atilde', 'Otilde', 'OE', 'oe', 'endash',
    'emdash', 'quotedblleft', 'quotedblright', 'quoteleft', 'quoteright',
    'divide', 'lozenge', 'ydieresis', 'Ydieresis', 'fraction', 'currency',
    'guilsinglleft', 'guilsinglright', 'fi', 'fl', 'daggerdbl', 'periodcentered',
    'quotesinglbase', 'quotedblbase', 'perthousand', 'Acircumflex',
    'Ecircumflex', 'Aacute', 'Edieresis', 'Egrave', 'Iacute', 'Icircumflex',
    'Idieresis', 'Igrave', 'Oacute', 'Ocircumflex', 'apple', 'Ograve', 'Uacute',
    'Ucircumflex', 'Ugrave', 'dotlessi', 'circumflex', 'tilde', 'macron',
    'breve', 'dotaccent', 'ring', 'cedilla', 'hungarumlaut', 'ogonek', 'caron',
    'Lslash', 'lslash', 'Scaron', 'scaron', 'Zcaron', 'zcaron', 'brokenbar',
    'Eth', 'eth', 'Yacute', 'yacute', 'Thorn', 'thorn', 'minus', 'multiply',
    'onesuperior', 'twosuperior', 'threesuperior', 'onehalf', 'onequarter',
    'threequarters', 'franc', 'Gbreve', 'gbreve', 'Idotaccent', 'Scedilla',
    'scedilla', 'Cacute', 'cacute', 'Ccaron', 'ccaron', 'dcroat');

function ReadTag(const Data: TBytes; Pos: Integer): Cardinal;
begin
  Result := (Cardinal(Data[Pos]) shl 24) or (Cardinal(Data[Pos + 1]) shl 16) or
    (Cardinal(Data[Pos + 2]) shl 8) or Cardinal(Data[Pos + 3]);
end;

{ TPdfTrueTypeFont }

class function TPdfTrueTypeFont.IsTrueType(const Data: TBytes): Boolean;
var
  Tag: Cardinal;
begin
  if Length(Data) < 12 then
    Exit(False);
  Tag := ReadTag(Data, 0);
  Result := (Tag = TagV1) or (Tag = TagTRUE) or (Tag = TagTTCF) or (Tag = TagOTTO);
end;

constructor TPdfTrueTypeFont.Create(const Data: TBytes);
begin
  inherited Create;
  FData := Data;
  FTables := TDictionary<string, TTableEntry>.Create;
  FNameLock := TObject.Create;
  FUnitsPerEm := 1000;
  FIndexToLocFormat := -1;
  FOutlineCount := -1;
  ReadDirectory;
  ReadCFF;
  ReadHead;
  ReadMaxp;
  ReadLoca;
  ReadMetrics;
  ReadCmap;
  ReadPost;
end;

destructor TPdfTrueTypeFont.Destroy;
begin
  FNameMap.Free;
  FNameLock.Free;
  FTables.Free;
  inherited;
end;

function TPdfTrueTypeFont.Avail(Pos, Count: Int64): Boolean;
begin
  Result := (Pos >= 0) and (Count >= 0) and (Pos + Count <= Length(FData));
end;

function TPdfTrueTypeFont.U16(Pos: Integer): Integer;
begin
  Result := (FData[Pos] shl 8) or FData[Pos + 1];
end;

function TPdfTrueTypeFont.S16(Pos: Integer): Integer;
begin
  Result := SmallInt((FData[Pos] shl 8) or FData[Pos + 1]);
end;

function TPdfTrueTypeFont.U32(Pos: Integer): Int64;
begin
  Result := (Int64(FData[Pos]) shl 24) or (FData[Pos + 1] shl 16) or (FData[Pos + 2] shl 8) or FData[Pos + 3];
end;

function TPdfTrueTypeFont.TagAt(Pos: Integer): string;
var
  I: Integer;
begin
  SetLength(Result, 4);
  for I := 0 to 3 do
    Result[I + Low(string)] := Char(FData[Pos + I]);
end;

function TPdfTrueTypeFont.FindTable(const Tag: string; out Entry: TTableEntry): Boolean;
begin
  Result := FTables.TryGetValue(Tag, Entry) and (Entry.Length > 0);
end;

procedure TPdfTrueTypeFont.ReadDirectory;
const
  KnownTags: array[0..8] of string = ('head', 'maxp', 'loca', 'glyf', 'cmap', 'hmtx', 'hhea', 'post', 'CFF ');
var
  Dir, NumTables, I, Pos: Integer;
  Offset, Len: Int64;
  Entry: TTableEntry;
  Tag: string;
  Known: Boolean;
begin
  if Length(FData) < 12 then
    raise EPdfFontError.Create('TrueType: font data too short for a table directory');
  Dir := 0;
  FSfntVersion := ReadTag(FData, 0);
  if FSfntVersion = TagTTCF then
  begin
    // TrueType collection: header, version, numFonts, offsets; the first font is used.
    if not Avail(0, 16) or (U32(8) = 0) then
      raise EPdfFontError.Create('TrueType: empty font collection');
    Offset := U32(12);
    if not Avail(Offset, 12) then
      raise EPdfFontError.Create('TrueType: collection font offset out of range');
    Dir := Integer(Offset);
    FSfntVersion := ReadTag(FData, Dir);
  end;
  NumTables := U16(Dir + 4);
  NumTables := Min(NumTables, (Integer(Length(FData)) - Dir - 12) div 16);
  for I := 0 to NumTables - 1 do
  begin
    Pos := Dir + 12 + I * 16;
    Tag := TagAt(Pos);
    Offset := U32(Pos + 8);
    Len := U32(Pos + 12);
    // Entries pointing outside the data are ignored; lengths that run past the end are clamped.
    if Offset >= Length(FData) then
      Continue;
    if Offset + Len > Length(FData) then
      Len := Length(FData) - Offset;
    if FTables.ContainsKey(Tag) then
      Continue;
    Entry.Offset := Integer(Offset);
    Entry.Length := Integer(Len);
    FTables.Add(Tag, Entry);
  end;
  Known := False;
  for Tag in KnownTags do
    if FTables.ContainsKey(Tag) then
    begin
      Known := True;
      Break;
    end;
  if not Known then
    raise EPdfFontError.Create('TrueType: no usable table directory');
end;

procedure TPdfTrueTypeFont.ReadCFF;
var
  T: TTableEntry;
begin
  if FindTable('CFF ', T) then
  begin
    FHasCFF := True;
    FCFFData := Copy(FData, T.Offset, T.Length);
  end;
end;

procedure TPdfTrueTypeFont.ReadHead;
var
  T: TTableEntry;
begin
  if not FindTable('head', T) then
    Exit;
  if T.Length >= 20 then
  begin
    FUnitsPerEm := U16(T.Offset + 18);
    if FUnitsPerEm = 0 then
      FUnitsPerEm := 1000;
  end;
  if T.Length >= 52 then
    FIndexToLocFormat := S16(T.Offset + 50);
end;

procedure TPdfTrueTypeFont.ReadMaxp;
var
  T: TTableEntry;
begin
  if FindTable('maxp', T) and (T.Length >= 6) then
    FNumGlyphs := U16(T.Offset + 4);
end;

procedure TPdfTrueTypeFont.ReadLoca;
var
  Loca, Glyf, Other: TTableEntry;
  N, Fmt, I, BadDecl, BadOther, GlyfLen, OtherFmt, Count: Integer;
  NextOffset: Int64;
  Offs, OffsOther: TArray<Int64>;
  S, E: Int64;

  function LocaBytes(ItemSize: Integer): Integer;
  var
    Need: Int64;
  begin
    // A loca table declared too short (pdf.js #13425) is extended when the space up to the next table allows it.
    Result := Loca.Length;
    Need := Int64(N + 1) * ItemSize;
    if (Result < Need) and (Loca.Offset + Need <= NextOffset) then
      Result := Integer(Need);
  end;

  function Decode(Long: Boolean; out Values: TArray<Int64>): Integer;
  var
    ItemSize, Avl, J: Integer;
    Prev: Int64;
  begin
    // Returns the number of bad entries: beyond glyf, decreasing, or missing.
    if Long then
      ItemSize := 4
    else
      ItemSize := 2;
    Avl := Min(N + 1, LocaBytes(ItemSize) div ItemSize);
    SetLength(Values, Avl);
    Result := N + 1 - Avl;
    Prev := 0;
    for J := 0 to Avl - 1 do
    begin
      if Long then
        Values[J] := U32(Loca.Offset + J * 4)
      else
        Values[J] := Int64(U16(Loca.Offset + J * 2)) * 2;
      if (Values[J] > GlyfLen) or (Values[J] < Prev) then
        Inc(Result);
      Prev := Values[J];
    end;
  end;

begin
  if (FSfntVersion = TagOTTO) or not FindTable('loca', Loca) or not FTables.TryGetValue('glyf', Glyf) then
    Exit;
  GlyfLen := Glyf.Length;
  Fmt := FIndexToLocFormat;
  N := FNumGlyphs;
  if N <= 0 then
  begin
    if Fmt = 1 then
      N := Loca.Length div 4 - 1
    else
      N := Loca.Length div 2 - 1;
  end;
  if N <= 0 then
    Exit;
  NextOffset := Length(FData);
  for Other in FTables.Values do
    if (Other.Offset > Loca.Offset) and (Other.Offset < NextOffset) then
      NextOffset := Other.Offset;
  if (Fmt <> 0) and (Fmt <> 1) then
  begin
    // Invalid indexToLocFormat: deduce it from the loca length (pdf.js sanitizeHead).
    if Loca.Length = (N + 1) * 4 then
      Fmt := 1
    else
      Fmt := 0;
  end;
  BadDecl := Decode(Fmt = 1, Offs);
  if BadDecl * 2 > N + 1 then
  begin
    // Most entries are unusable: the format flag is probably wrong (short data declared long or vice versa).
    OtherFmt := 1 - Fmt;
    BadOther := Decode(OtherFmt = 1, OffsOther);
    if BadOther * 4 < BadDecl then
      Offs := OffsOther;
  end
  else if (Fmt = 0) and (Loca.Length >= (N + 1) * 4) then
  begin
    // Declared short but the table is sized for long offsets: long data read as shorts mostly gives
    // high words (zeros), which look valid but cover less of glyf than the long reading.
    BadOther := Decode(True, OffsOther);
    if (BadOther = 0) and (Length(Offs) = N + 1) and (Length(OffsOther) = N + 1) and (OffsOther[N] > Offs[N]) then
      Offs := OffsOther;
  end;
  Count := Length(Offs);
  if Count = 0 then
    Exit;
  SetLength(FGlyphStart, N);
  SetLength(FGlyphEnd, N);
  FOutlineCount := 0;
  for I := 0 to N - 1 do
  begin
    if I + 1 >= Count then
      Break; // missing entries: empty glyphs
    S := Offs[I];
    E := Offs[I + 1];
    // A last offset of 0 cannot give the end of the last glyph: use the end of glyf (pdf.js #17671).
    if (I = N - 1) and (E = 0) and (S > 0) then
      E := GlyfLen;
    if (S <= E) and (E <= GlyfLen) and (E > S) then
    begin
      FGlyphStart[I] := Glyf.Offset + Integer(S);
      FGlyphEnd[I] := Glyf.Offset + Integer(E);
      Inc(FOutlineCount);
    end;
  end;
  FHasGlyf := True;
end;

procedure TPdfTrueTypeFont.ReadMetrics;
var
  Hhea, Hmtx: TTableEntry;
begin
  if not FindTable('hmtx', Hmtx) then
    Exit;
  if FindTable('hhea', Hhea) and (Hhea.Length >= 36) then
    FNumHMetrics := U16(Hhea.Offset + 34)
  else
    FNumHMetrics := Max(FNumGlyphs, 1);
  FNumHMetrics := Min(FNumHMetrics, Hmtx.Length div 4);
  FHmtxOffset := Hmtx.Offset;
end;

function TPdfTrueTypeFont.ParseCmapSubtable(var T: TCmapSubtable): Boolean;
var
  P, SegCount, I, Avl: Integer;
  NGroups: Int64;
  Prev: Int64;
begin
  Result := False;
  P := T.Offset;
  T.Sorted := True;
  case T.Format of
    0:
      begin
        // format, length, language, 256 glyph bytes (a short table keeps what is present)
        T.FirstCode := 0;
        T.EntryCount := Min(256, Integer(Length(FData)) - (P + 6));
        Result := T.EntryCount > 0;
      end;
    4:
      begin
        // The length field is often wrong: the arrays are addressed through segCount and validated
        // against the data instead.
        if not Avail(P, 14) then
          Exit;
        SegCount := U16(P + 6) div 2;
        if (SegCount = 0) or not Avail(P + 16, Int64(SegCount) * 8) then
          Exit;
        SetLength(T.Segments, SegCount);
        Prev := -1;
        for I := 0 to SegCount - 1 do
        begin
          T.Segments[I].EndCode := U16(P + 14 + I * 2);
          T.Segments[I].StartCode := U16(P + 16 + SegCount * 2 + I * 2);
          T.Segments[I].IdDelta := U16(P + 16 + SegCount * 4 + I * 2);
          T.Segments[I].RangeOffsetPos := P + 16 + SegCount * 6 + I * 2;
          T.Segments[I].IdRangeOffset := U16(T.Segments[I].RangeOffsetPos);
          if T.Segments[I].EndCode < Prev then
            T.Sorted := False;
          Prev := T.Segments[I].EndCode;
        end;
        Result := True;
      end;
    6:
      begin
        if not Avail(P, 10) then
          Exit;
        T.FirstCode := U16(P + 6);
        T.EntryCount := Min(U16(P + 8), (Integer(Length(FData)) - (P + 10)) div 2);
        Result := T.EntryCount > 0;
      end;
    12, 13:
      begin
        if not Avail(P, 16) then
          Exit;
        NGroups := U32(P + 12);
        Avl := (Integer(Length(FData)) - (P + 16)) div 12;
        if NGroups > Avl then
          NGroups := Avl;
        if NGroups <= 0 then
          Exit;
        SetLength(T.Groups, Integer(NGroups));
        Prev := -1;
        for I := 0 to Integer(NGroups) - 1 do
        begin
          T.Groups[I].StartCode := U32(P + 16 + I * 12);
          T.Groups[I].EndCode := U32(P + 20 + I * 12);
          T.Groups[I].StartGlyph := U32(P + 24 + I * 12);
          if T.Groups[I].EndCode < Prev then
            T.Sorted := False;
          Prev := T.Groups[I].EndCode;
        end;
        Result := True;
      end;
  end;
end;

procedure TPdfTrueTypeFont.ReadCmap;
var
  Cmap: TTableEntry;
  NumSub, I, Pos: Integer;
  SubOffset: Int64;
  T: TCmapSubtable;
  List: TList<TCmapSubtable>;
begin
  if not FindTable('cmap', Cmap) or (Cmap.Length < 4) then
    Exit;
  NumSub := U16(Cmap.Offset + 2);
  NumSub := Min(NumSub, (Cmap.Length - 4) div 8);
  List := TList<TCmapSubtable>.Create;
  try
    for I := 0 to NumSub - 1 do
    begin
      Pos := Cmap.Offset + 4 + I * 8;
      T := Default(TCmapSubtable);
      T.PlatformID := U16(Pos);
      T.EncodingID := U16(Pos + 2);
      SubOffset := U32(Pos + 4);
      if (SubOffset >= Cmap.Length) or not Avail(Cmap.Offset + SubOffset, 2) then
        Continue;
      T.Offset := Cmap.Offset + Integer(SubOffset);
      T.Format := U16(T.Offset);
      if not ParseCmapSubtable(T) then
        Continue;
      List.Add(T);
      if (T.PlatformID = 3) and (T.EncodingID = 0) then
        FHasSymbolCmap := True
      else if (T.PlatformID = 1) and (T.EncodingID = 0) then
        FHasMacRomanCmap := True;
      if (T.PlatformID = 0) or ((T.PlatformID = 3) and ((T.EncodingID = 1) or (T.EncodingID = 10))) then
        FHasUnicodeCmap := True;
    end;
    FSubtables := List.ToArray;
  finally
    List.Free;
  end;
end;

procedure TPdfTrueTypeFont.ReadPost;
var
  Post: TTableEntry;
  Version: Int64;
  I: Integer;
begin
  FPostFormat := 0;
  if not FindTable('post', Post) or (Post.Length < 32) then
    Exit;
  Version := U32(Post.Offset);
  if Version = $00010000 then
    FPostFormat := 1
  else if (Version = $00020000) and (Post.Length >= 34) then
  begin
    FPostNumGlyphs := U16(Post.Offset + 32);
    if 34 + FPostNumGlyphs * 2 > Post.Length then
      Exit;
    // Name indices >= 32768 are reserved: the table is garbage (pdf.js readPostScriptTable).
    for I := 0 to FPostNumGlyphs - 1 do
      if U16(Post.Offset + 34 + I * 2) >= 32768 then
        Exit;
    FPostFormat := 2;
    FPostOffset := Post.Offset;
    FPostLength := Post.Length;
  end;
end;

procedure TPdfTrueTypeFont.BuildNames;
var
  Custom: TList<string>;
  P, Limit, Len, I, Idx, N: Integer;
  S: string;
begin
  if FNamesBuilt then
    Exit;
  TMonitor.Enter(FNameLock);
  try
    if FNamesBuilt then
      Exit;
    FNameMap := TDictionary<string, Integer>.Create;
    if FPostFormat = 1 then
    begin
      N := Length(MacGlyphNames);
      if GlyphCount > 0 then
        N := Min(N, GlyphCount);
      SetLength(FNames, N);
      for I := 0 to N - 1 do
        FNames[I] := MacGlyphNames[I];
    end
    else if FPostFormat = 2 then
    begin
      Custom := TList<string>.Create;
      try
        P := FPostOffset + 34 + FPostNumGlyphs * 2;
        Limit := FPostOffset + FPostLength;
        while P < Limit do
        begin
          Len := FData[P];
          Inc(P);
          if P + Len > Limit then
            Break;
          SetLength(S, Len);
          for I := 0 to Len - 1 do
            S[I + Low(string)] := Char(FData[P + I]);
          Custom.Add(S);
          Inc(P, Len);
        end;
        SetLength(FNames, FPostNumGlyphs);
        for I := 0 to FPostNumGlyphs - 1 do
        begin
          Idx := U16(FPostOffset + 34 + I * 2);
          if Idx < 258 then
            FNames[I] := MacGlyphNames[Idx]
          else if Idx - 258 < Custom.Count then
            FNames[I] := Custom[Idx - 258];
        end;
      finally
        Custom.Free;
      end;
    end;
    for I := 0 to Integer(Length(FNames)) - 1 do
      if (FNames[I] <> '') and not FNameMap.ContainsKey(FNames[I]) then
        FNameMap.Add(FNames[I], I);
    FNamesBuilt := True;
  finally
    TMonitor.Exit(FNameLock);
  end;
end;

function TPdfTrueTypeFont.FontMatrix: TPdfMatrix;
begin
  Result := TPdfMatrix.Scaling(1 / FUnitsPerEm, 1 / FUnitsPerEm);
end;

function TPdfTrueTypeFont.GlyphCount: Integer;
begin
  if FNumGlyphs > 0 then
    Result := FNumGlyphs
  else
    Result := Length(FGlyphStart);
end;

function TPdfTrueTypeFont.ValidGlyph(GID: Integer): Integer;
begin
  if (GID <= 0) or ((GlyphCount > 0) and (GID >= GlyphCount)) then
    Result := -1
  else
    Result := GID;
end;

function TPdfTrueTypeFont.GetOutline(GID: Integer; out Outline: TPdfGlyphOutline): Boolean;
var
  Chain: TGidChain;
  Adv: Single;
begin
  Outline.Clear;
  if not FHasGlyf or (GID < 0) or (GID >= GlyphCount) then
    Exit(False);
  Result := BuildGlyph(GID, 0, Chain, Outline);
  if not Result then
  begin
    Outline.Clear;
    Exit;
  end;
  Outline.Trim;
  Adv := GetAdvance(GID);
  if Adv > 0 then
    Outline.Advance := Adv;
end;

function TPdfTrueTypeFont.BuildGlyph(GID, Depth: Integer; var Chain: TGidChain; var Outline: TPdfGlyphOutline): Boolean;
var
  P, E, NumContours: Integer;
begin
  Outline.Clear;
  if (GID < 0) or (GID >= GlyphCount) then
    Exit(False);
  if GID >= Length(FGlyphStart) then
    Exit(True); // no loca entry: empty glyph
  P := FGlyphStart[GID];
  E := FGlyphEnd[GID];
  if E <= P then
    Exit(True);
  if E - P < 10 then
    Exit(False);
  NumContours := S16(P);
  if NumContours >= 0 then
    Result := ParseSimpleGlyph(P, E, NumContours, Outline)
  else if (NumContours = -1) and (Depth < MaxCompositeDepth) then
  begin
    Chain[Depth] := GID;
    Result := ParseCompositeGlyph(P, E, Depth, Chain, Outline);
  end
  else
    Result := False; // < -1 means garbage (pdf.js sanitizeGlyph), or nesting too deep
end;

function TPdfTrueTypeFont.ParseSimpleGlyph(P, E, NumContours: Integer; var Outline: TPdfGlyphOutline): Boolean;
var
  EndPts: TArray<Integer>;
  Flags: TArray<Byte>;
  Xs, Ys: TArray<Integer>;
  I, C, NumPoints, Prev, Rep, V, S, L, First, Cnt, J: Integer;
  F: Byte;
  SX, SY, CX, CY, X, Y: Single;
  HaveCtrl: Boolean;
begin
  Result := False;
  P := P + 10;
  if NumContours = 0 then
    Exit(True);
  if Int64(P) + NumContours * 2 + 2 > E then
    Exit;
  SetLength(EndPts, NumContours);
  Prev := -1;
  for I := 0 to NumContours - 1 do
  begin
    EndPts[I] := U16(P);
    if EndPts[I] < Prev then
      Exit;
    Prev := EndPts[I];
    Inc(P, 2);
  end;
  NumPoints := Prev + 1;
  // Skip the instructions.
  P := P + 2 + U16(P);
  if P > E then
    Exit;
  SetLength(Flags, NumPoints);
  I := 0;
  while I < NumPoints do
  begin
    if P >= E then
      Exit;
    F := FData[P];
    Inc(P);
    Flags[I] := F;
    Inc(I);
    if F and 8 <> 0 then
    begin
      if P >= E then
        Exit;
      Rep := FData[P];
      Inc(P);
      while (Rep > 0) and (I < NumPoints) do
      begin
        Flags[I] := F;
        Inc(I);
        Dec(Rep);
      end;
    end;
  end;
  SetLength(Xs, NumPoints);
  SetLength(Ys, NumPoints);
  V := 0;
  for I := 0 to NumPoints - 1 do
  begin
    F := Flags[I];
    if F and 2 <> 0 then
    begin
      if P >= E then
        Exit;
      if F and 16 <> 0 then
        Inc(V, FData[P])
      else
        Dec(V, FData[P]);
      Inc(P);
    end
    else if F and 16 = 0 then
    begin
      if P + 2 > E then
        Exit;
      Inc(V, S16(P));
      Inc(P, 2);
    end;
    Xs[I] := V;
  end;
  V := 0;
  for I := 0 to NumPoints - 1 do
  begin
    F := Flags[I];
    if F and 4 <> 0 then
    begin
      if P >= E then
        Exit;
      if F and 32 <> 0 then
        Inc(V, FData[P])
      else
        Dec(V, FData[P]);
      Inc(P);
    end
    else if F and 32 = 0 then
    begin
      if P + 2 > E then
        Exit;
      Inc(V, S16(P));
      Inc(P, 2);
    end;
    Ys[I] := V;
  end;

  // Contours: quadratic splines with implied on-curve midpoints between consecutive off-curve points.
  S := 0;
  for C := 0 to NumContours - 1 do
  begin
    L := EndPts[C];
    if L - S + 1 >= 2 then
    begin
      if Flags[S] and 1 <> 0 then
      begin
        SX := Xs[S];
        SY := Ys[S];
        First := S + 1;
        Cnt := L - S;
      end
      else if Flags[L] and 1 <> 0 then
      begin
        // Starts off-curve: begin at the last point, which is on-curve.
        SX := Xs[L];
        SY := Ys[L];
        First := S;
        Cnt := L - S;
      end
      else
      begin
        // Both ends off-curve: begin at their implied midpoint.
        SX := (Xs[S] + Xs[L]) / 2;
        SY := (Ys[S] + Ys[L]) / 2;
        First := S;
        Cnt := L - S + 1;
      end;
      Outline.MoveTo(SX, SY);
      HaveCtrl := False;
      CX := 0;
      CY := 0;
      for J := First to First + Cnt - 1 do
      begin
        X := Xs[J];
        Y := Ys[J];
        if Flags[J] and 1 <> 0 then
        begin
          if HaveCtrl then
            Outline.QuadTo(CX, CY, X, Y)
          else
            Outline.LineTo(X, Y);
          HaveCtrl := False;
        end
        else
        begin
          if HaveCtrl then
            Outline.QuadTo(CX, CY, (CX + X) / 2, (CY + Y) / 2);
          CX := X;
          CY := Y;
          HaveCtrl := True;
        end;
      end;
      if HaveCtrl then
        Outline.QuadTo(CX, CY, SX, SY);
      Outline.Close;
    end;
    S := L + 1;
  end;
  Result := True;
end;

function TPdfTrueTypeFont.ParseCompositeGlyph(P, E, Depth: Integer; var Chain: TGidChain;
  var Outline: TPdfGlyphOutline): Boolean;
const
  ARG_1_AND_2_ARE_WORDS = $0001;
  ARGS_ARE_XY_VALUES = $0002;
  WE_HAVE_A_SCALE = $0008;
  MORE_COMPONENTS = $0020;
  WE_HAVE_AN_X_AND_Y_SCALE = $0040;
  WE_HAVE_A_TWO_BY_TWO = $0080;
  SCALED_COMPONENT_OFFSET = $0800;
  UNSCALED_COMPONENT_OFFSET = $1000;
var
  Flags, Comp, Arg1, Arg2, I: Integer;
  MA, MB, MC, MD, DX, DY, T: Double;
  Component: TPdfGlyphOutline;
  InChain: Boolean;

  function F2Dot14(Pos: Integer): Double;
  begin
    Result := S16(Pos) / 16384;
  end;

begin
  P := P + 10;
  repeat
    if P + 4 > E then
      Break;
    Flags := U16(P);
    Comp := U16(P + 2);
    Inc(P, 4);
    if Flags and ARG_1_AND_2_ARE_WORDS <> 0 then
    begin
      if P + 4 > E then
        Break;
      if Flags and ARGS_ARE_XY_VALUES <> 0 then
      begin
        Arg1 := S16(P);
        Arg2 := S16(P + 2);
      end
      else
      begin
        Arg1 := U16(P);
        Arg2 := U16(P + 2);
      end;
      Inc(P, 4);
    end
    else
    begin
      if P + 2 > E then
        Break;
      if Flags and ARGS_ARE_XY_VALUES <> 0 then
      begin
        Arg1 := ShortInt(FData[P]);
        Arg2 := ShortInt(FData[P + 1]);
      end
      else
      begin
        Arg1 := FData[P];
        Arg2 := FData[P + 1];
      end;
      Inc(P, 2);
    end;
    MA := 1;
    MB := 0;
    MC := 0;
    MD := 1;
    if Flags and WE_HAVE_A_SCALE <> 0 then
    begin
      if P + 2 > E then
        Break;
      MA := F2Dot14(P);
      MD := MA;
      Inc(P, 2);
    end
    else if Flags and WE_HAVE_AN_X_AND_Y_SCALE <> 0 then
    begin
      if P + 4 > E then
        Break;
      MA := F2Dot14(P);
      MD := F2Dot14(P + 2);
      Inc(P, 4);
    end
    else if Flags and WE_HAVE_A_TWO_BY_TWO <> 0 then
    begin
      if P + 8 > E then
        Break;
      MA := F2Dot14(P);
      MB := F2Dot14(P + 2);
      MC := F2Dot14(P + 4);
      MD := F2Dot14(P + 6);
      Inc(P, 8);
    end;
    if Flags and ARGS_ARE_XY_VALUES <> 0 then
    begin
      DX := Arg1;
      DY := Arg2;
      if (Flags and SCALED_COMPONENT_OFFSET <> 0) and (Flags and UNSCALED_COMPONENT_OFFSET = 0) then
      begin
        T := MA * DX + MC * DY;
        DY := MB * DX + MD * DY;
        DX := T;
      end;
    end
    else
    begin
      // Point matching is not supported: the component is placed without offset.
      DX := 0;
      DY := 0;
    end;
    InChain := False;
    for I := 0 to Depth do
      if Chain[I] = Comp then
        InChain := True;
    if not InChain and BuildGlyph(Comp, Depth + 1, Chain, Component) and (Component.Count > 0) then
      Outline.AppendTransformed(Component, TPdfMatrix.Create(MA, MB, MC, MD, DX, DY));
  until Flags and MORE_COMPONENTS = 0;
  Result := True;
end;

function TPdfTrueTypeFont.GetAdvance(GID: Integer): Single;
var
  Idx: Integer;
begin
  if (FNumHMetrics <= 0) or (GID < 0) or ((GlyphCount > 0) and (GID >= GlyphCount)) then
    Exit(-1);
  Idx := Min(GID, FNumHMetrics - 1);
  Result := U16(FHmtxOffset + Idx * 4);
end;

function TPdfTrueTypeFont.LookupSubtable(const T: TCmapSubtable; Code: Int64): Integer;
var
  Lo, Hi, Mid, Found, Addr: Integer;
  G: Int64;
  Seg: TCmapSegment;
begin
  Result := 0;
  if Code < 0 then
    Exit;
  case T.Format of
    0, 6:
      if (Code >= T.FirstCode) and (Code < T.FirstCode + T.EntryCount) then
      begin
        if T.Format = 0 then
          Result := FData[T.Offset + 6 + Integer(Code)]
        else
          Result := U16(T.Offset + 10 + 2 * (Integer(Code) - T.FirstCode));
      end;
    4:
      begin
        if Code > $FFFF then
          Exit;
        Found := -1;
        if T.Sorted then
        begin
          Lo := 0;
          Hi := High(T.Segments);
          while Lo <= Hi do
          begin
            Mid := (Lo + Hi) div 2;
            if T.Segments[Mid].EndCode < Code then
              Lo := Mid + 1
            else
            begin
              Found := Mid;
              Hi := Mid - 1;
            end;
          end;
          if (Found >= 0) and (T.Segments[Found].StartCode > Code) then
            Found := -1;
        end
        else
          for Mid := 0 to High(T.Segments) do
            if (T.Segments[Mid].StartCode <= Code) and (T.Segments[Mid].EndCode >= Code) then
            begin
              Found := Mid;
              Break;
            end;
        if Found < 0 then
          Exit;
        Seg := T.Segments[Found];
        if Seg.IdRangeOffset = 0 then
          Result := (Integer(Code) + Seg.IdDelta) and $FFFF
        else
        begin
          // idRangeOffset is relative to its own position in the idRangeOffset array.
          Addr := Seg.RangeOffsetPos + Seg.IdRangeOffset + 2 * (Integer(Code) - Seg.StartCode);
          if Avail(Addr, 2) then
          begin
            Result := U16(Addr);
            if Result <> 0 then
              Result := (Result + Seg.IdDelta) and $FFFF;
          end;
        end;
      end;
    12, 13:
      begin
        Found := -1;
        if T.Sorted then
        begin
          Lo := 0;
          Hi := High(T.Groups);
          while Lo <= Hi do
          begin
            Mid := (Lo + Hi) div 2;
            if T.Groups[Mid].EndCode < Code then
              Lo := Mid + 1
            else
            begin
              Found := Mid;
              Hi := Mid - 1;
            end;
          end;
          if (Found >= 0) and (T.Groups[Found].StartCode > Code) then
            Found := -1;
        end
        else
          for Mid := 0 to High(T.Groups) do
            if (T.Groups[Mid].StartCode <= Code) and (T.Groups[Mid].EndCode >= Code) then
            begin
              Found := Mid;
              Break;
            end;
        if Found < 0 then
          Exit;
        if T.Format = 12 then
          G := T.Groups[Found].StartGlyph + (Code - T.Groups[Found].StartCode)
        else
          G := T.Groups[Found].StartGlyph;
        if (G > 0) and (G <= $FFFF) then
          Result := Integer(G);
      end;
  end;
end;

function TPdfTrueTypeFont.LookupPlatform(PlatformID, EncodingID: Integer; Code: Int64): Integer;
var
  I: Integer;
begin
  // EncodingID -1 matches any encoding.
  for I := 0 to High(FSubtables) do
    if (FSubtables[I].PlatformID = PlatformID) and
      ((EncodingID < 0) or (FSubtables[I].EncodingID = EncodingID)) then
    begin
      Result := ValidGlyph(LookupSubtable(FSubtables[I], Code));
      if Result > 0 then
        Exit;
    end;
  Result := -1;
end;

function TPdfTrueTypeFont.GlyphByUnicode(CodePoint: Integer): Integer;
begin
  if (CodePoint < 0) or (CodePoint > $10FFFF) then
    Exit(-1);
  Result := LookupPlatform(3, 1, CodePoint);
  if Result < 0 then
    Result := LookupPlatform(0, -1, CodePoint);
  if Result < 0 then
    Result := LookupPlatform(3, 10, CodePoint);
end;

function TPdfTrueTypeFont.GlyphBySymbolCode(Code: Integer): Integer;
begin
  Result := -1;
  if not FHasSymbolCmap or (Code < 0) then
    Exit;
  Result := LookupPlatform(3, 0, Code);
  if Result < 0 then
    Result := LookupPlatform(3, 0, $F000 + Code);
  if Result < 0 then
    Result := LookupPlatform(3, 0, $F100 + Code);
  if Result < 0 then
    Result := LookupPlatform(3, 0, $F200 + Code);
end;

function TPdfTrueTypeFont.GlyphByMacCode(Code: Integer): Integer;
begin
  if not FHasMacRomanCmap or (Code < 0) then
    Exit(-1);
  Result := LookupPlatform(1, 0, Code);
end;

function TPdfTrueTypeFont.GlyphByCode(Code: Integer): Integer;
begin
  Result := GlyphBySymbolCode(Code);
  if Result < 0 then
    Result := GlyphByMacCode(Code);
end;

function TPdfTrueTypeFont.GlyphByName(const Name: string): Integer;
begin
  if (FPostFormat = 0) or (Name = '') then
    Exit(-1);
  BuildNames;
  if not FNameMap.TryGetValue(Name, Result) then
    Exit(-1);
  if (GlyphCount > 0) and (Result >= GlyphCount) then
    Result := -1;
end;

function TPdfTrueTypeFont.GlyphName(GID: Integer): string;
begin
  Result := '';
  if FPostFormat = 0 then
    Exit;
  BuildNames;
  if (GID >= 0) and (GID < Length(FNames)) then
    Result := FNames[GID];
end;

function TPdfTrueTypeFont.HasGlyphNames: Boolean;
begin
  Result := FPostFormat <> 0;
end;

function TPdfTrueTypeFont.HasUnicodeMap: Boolean;
begin
  Result := FHasUnicodeCmap;
end;

function TPdfTrueTypeFont.HasCodeMap: Boolean;
begin
  Result := FHasSymbolCmap or FHasMacRomanCmap;
end;

function TPdfTrueTypeFont.OutlineCount: Integer;
begin
  if FHasGlyf then
    Result := FOutlineCount
  else
    Result := -1;
end;

function TPdfTrueTypeFont.HasTable(const Tag: string): Boolean;
var
  Key: string;
begin
  Key := Tag;
  while Length(Key) < 4 do
    Key := Key + ' ';
  Result := FTables.ContainsKey(Key);
end;

function TPdfTrueTypeFont.GetHasCmap: Boolean;
begin
  Result := Length(FSubtables) > 0;
end;

function TPdfTrueTypeFont.GetHasPostNames: Boolean;
begin
  Result := FPostFormat <> 0;
end;

end.
