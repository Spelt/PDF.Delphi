{*******************************************************************************
  Pdf.Tests.Font.TrueType
  DUnitX fixture for Pdf.Font.TrueType: Liberation Sans (Resources/Fonts),
  small synthetic sfnt files built here (symbol cmap, broken loca, loca format
  mismatch, composite glyphs with a self-reference), damaged data, and a sweep
  over the FontFile2 programs embedded in the pdf.js test corpus.
*******************************************************************************}
unit Pdf.Tests.Font.TrueType;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections, System.Generics.Defaults,
  System.Diagnostics, DUnitX.TestFramework,
  Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Document, Pdf.Font.Glyphs, Pdf.Font.TrueType;

type
  [TestFixture]
  TPdfTrueTypeTests = class
  public
    [Test] procedure LiberationRegular_Basics;
    [Test] procedure LiberationRegular_GlyphA;
    [Test] procedure LiberationRegular_Composite;
    [Test] procedure LiberationRegular_Lookups;
    [Test] procedure LiberationStyles_Load;
    [Test] procedure Synthetic_SymbolSquare;
    [Test] procedure Synthetic_BrokenLoca;
    [Test] procedure Synthetic_LocaFormatMismatch;
    [Test] procedure Synthetic_CompositeAndSelfReference;
    [Test] procedure Synthetic_OffCurveContour;
    [Test] procedure Synthetic_CollectionAndDirectory;
    [Test] procedure Damaged_Truncated;
    [Test] procedure Damaged_Mutated;
    [Test] procedure Damaged_Empty;
    [Test] procedure Corpus_FontFile2Sweep;
    [Test] procedure Corpus_OpenTypeCFF;
  end;

implementation

uses
  Pdf.Tests.Builder;

{ ---------------------------------------------------------------------------- }
{ Helpers                                                                      }
{ ---------------------------------------------------------------------------- }

type
  /// <summary>Big-endian byte writer for the synthetic fonts.</summary>
  TBeWriter = class
  private
    FData: TBytes;
    FLen: Integer;
    procedure Grow(N: Integer);
  public
    procedure U8(V: Integer);
    procedure U16(V: Integer);
    procedure U32(V: Cardinal);
    procedure Bytes(const B: TBytes);
    procedure Pad4;
    function ToBytes: TBytes;
    property Len: Integer read FLen;
  end;

procedure TBeWriter.Grow(N: Integer);
begin
  if FLen + N > Length(FData) then
    SetLength(FData, (FLen + N) * 2 + 16);
end;

procedure TBeWriter.U8(V: Integer);
begin
  Grow(1);
  FData[FLen] := Byte(V);
  Inc(FLen);
end;

procedure TBeWriter.U16(V: Integer);
begin
  U8((V shr 8) and $FF);
  U8(V and $FF);
end;

procedure TBeWriter.U32(V: Cardinal);
begin
  U16(Integer(V shr 16));
  U16(Integer(V and $FFFF));
end;

procedure TBeWriter.Bytes(const B: TBytes);
begin
  if Length(B) = 0 then
    Exit;
  Grow(Length(B));
  Move(B[0], FData[FLen], Length(B));
  Inc(FLen, Length(B));
end;

procedure TBeWriter.Pad4;
begin
  while FLen mod 4 <> 0 do
    U8(0);
end;

function TBeWriter.ToBytes: TBytes;
begin
  Result := Copy(FData, 0, FLen);
end;

/// <summary>Assembles an sfnt file (version 1.0) from tables in the given order.</summary>
function BuildSfnt(const Tags: array of string; const Tables: array of TBytes; BaseOffset: Integer = 0): TBytes;
var
  W: TBeWriter;
  I, J, Offset: Integer;
begin
  W := TBeWriter.Create;
  try
    W.U32($00010000);
    W.U16(Length(Tags));
    W.U16(0);
    W.U16(0);
    W.U16(0);
    Offset := BaseOffset + 12 + 16 * Length(Tags);
    for I := 0 to High(Tags) do
    begin
      for J := 1 to 4 do
        W.U8(Ord(Tags[I][J]));
      W.U32(0);
      W.U32(Cardinal(Offset));
      W.U32(Cardinal(Length(Tables[I])));
      Offset := Offset + ((Length(Tables[I]) + 3) and not 3);
    end;
    for I := 0 to High(Tables) do
    begin
      W.Bytes(Tables[I]);
      W.Pad4;
    end;
    Result := W.ToBytes;
  finally
    W.Free;
  end;
end;

function MakeHead(UnitsPerEm, LocFormat: Integer): TBytes;
var
  W: TBeWriter;
  I: Integer;
begin
  W := TBeWriter.Create;
  try
    W.U32($00010000);
    for I := 1 to 14 do
      W.U8(0);
    W.U16(UnitsPerEm);                   // offset 18
    while W.Len < 50 do
      W.U8(0);
    W.U16(LocFormat);                    // offset 50
    W.U16(0);
    Result := W.ToBytes;
  finally
    W.Free;
  end;
end;

function MakeMaxp(NumGlyphs: Integer): TBytes;
var
  W: TBeWriter;
begin
  W := TBeWriter.Create;
  try
    W.U32($00005000);
    W.U16(NumGlyphs);
    Result := W.ToBytes;
  finally
    W.Free;
  end;
end;

function MakeHhea(NumHMetrics: Integer): TBytes;
var
  W: TBeWriter;
begin
  W := TBeWriter.Create;
  try
    W.U32($00010000);
    while W.Len < 34 do
      W.U8(0);
    W.U16(NumHMetrics);
    Result := W.ToBytes;
  finally
    W.Free;
  end;
end;

function MakeHmtx(const Advances: array of Integer): TBytes;
var
  W: TBeWriter;
  A: Integer;
begin
  W := TBeWriter.Create;
  try
    for A in Advances do
    begin
      W.U16(A);
      W.U16(0);
    end;
    Result := W.ToBytes;
  finally
    W.Free;
  end;
end;

function MakeLoca(const Offsets: array of Integer; Long: Boolean): TBytes;
var
  W: TBeWriter;
  O: Integer;
begin
  W := TBeWriter.Create;
  try
    for O in Offsets do
      if Long then
        W.U32(Cardinal(O))
      else
        W.U16(O div 2);
    Result := W.ToBytes;
  finally
    W.Free;
  end;
end;

/// <summary>cmap with one (3,0) format 4 subtable mapping $F041 to glyph 1.</summary>
function MakeSymbolCmap: TBytes;
var
  W: TBeWriter;
begin
  W := TBeWriter.Create;
  try
    W.U16(0);
    W.U16(1);
    W.U16(3);
    W.U16(0);
    W.U32(12);
    // format 4, two segments ($F041 and the $FFFF terminator)
    W.U16(4);
    W.U16(16 + 2 * 8);
    W.U16(0);
    W.U16(4);              // segCountX2
    W.U16(4);
    W.U16(1);
    W.U16(0);
    W.U16($F041);          // endCode
    W.U16($FFFF);
    W.U16(0);              // reservedPad
    W.U16($F041);          // startCode
    W.U16($FFFF);
    W.U16((1 - $F041) and $FFFF); // idDelta
    W.U16(1);
    W.U16(0);              // idRangeOffset
    W.U16(0);
    Result := W.ToBytes;
  finally
    W.Free;
  end;
end;

/// <summary>Simple glyph from on/off-curve points (one contour per EndPts entry), int16 coordinates.</summary>
function MakeSimpleGlyph(const EndPts: array of Integer; const Xs, Ys: array of Integer;
  const OnCurve: array of Boolean): TBytes;
var
  W: TBeWriter;
  I, Prev: Integer;
begin
  W := TBeWriter.Create;
  try
    W.U16(Length(EndPts));
    W.U16(0);
    W.U16(0);
    W.U16(1000);
    W.U16(1000);
    for I in EndPts do
      W.U16(I);
    W.U16(0); // no instructions
    for I := 0 to High(Xs) do
      if OnCurve[I] then
        W.U8(1)
      else
        W.U8(0);
    Prev := 0;
    for I := 0 to High(Xs) do
    begin
      W.U16((Xs[I] - Prev) and $FFFF);
      Prev := Xs[I];
    end;
    Prev := 0;
    for I := 0 to High(Ys) do
    begin
      W.U16((Ys[I] - Prev) and $FFFF);
      Prev := Ys[I];
    end;
    if W.Len mod 2 <> 0 then
      W.U8(0);
    Result := W.ToBytes;
  finally
    W.Free;
  end;
end;

function SquareGlyph: TBytes;
begin
  Result := MakeSimpleGlyph([3], [0, 500, 500, 0], [0, 0, 500, 500], [True, True, True, True]);
end;

/// <summary>Minimal symbolic font: glyph 0 empty, glyph 1 a square, cmap (3,0) $F041 -> 1.</summary>
function MakeSymbolFont(DeclaredLong, LocaLong: Boolean): TBytes;
var
  Glyf: TBytes;
begin
  Glyf := SquareGlyph;
  Result := BuildSfnt(['head', 'maxp', 'hhea', 'hmtx', 'loca', 'glyf', 'cmap'],
    [MakeHead(1000, Ord(DeclaredLong)), MakeMaxp(2), MakeHhea(2), MakeHmtx([500, 600]),
     MakeLoca([0, 0, Length(Glyf)], LocaLong), Glyf, MakeSymbolCmap]);
end;

function FontFile(const Name: string): string;
begin
  Result := TPath.GetFullPath(TPath.Combine(TestDataPath, '..\..\Resources\Fonts\' + Name));
end;

function LoadFont(const Name: string): TPdfTrueTypeFont;
begin
  Result := TPdfTrueTypeFont.Create(TFile.ReadAllBytes(FontFile(Name)));
end;

function CountMoves(const O: TPdfGlyphOutline): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to O.Count - 1 do
    if O.Cmds[I].Kind = glMove then
      Inc(Result);
end;

procedure OutlineBounds(const O: TPdfGlyphOutline; out MinX, MinY, MaxX, MaxY: Single);
var
  I: Integer;

  procedure Add(X, Y: Single);
  begin
    if X < MinX then MinX := X;
    if X > MaxX then MaxX := X;
    if Y < MinY then MinY := Y;
    if Y > MaxY then MaxY := Y;
  end;

begin
  MinX := 1E9;
  MinY := 1E9;
  MaxX := -1E9;
  MaxY := -1E9;
  for I := 0 to O.Count - 1 do
    case O.Cmds[I].Kind of
      glMove, glLine: Add(O.Cmds[I].X1, O.Cmds[I].Y1);
      glQuad:
        begin
          Add(O.Cmds[I].X1, O.Cmds[I].Y1);
          Add(O.Cmds[I].X2, O.Cmds[I].Y2);
        end;
      glCubic:
        begin
          Add(O.Cmds[I].X1, O.Cmds[I].Y1);
          Add(O.Cmds[I].X2, O.Cmds[I].Y2);
          Add(O.Cmds[I].X3, O.Cmds[I].Y3);
        end;
    end;
end;

/// <summary>Calls every lookup and GetOutline on every glyph; exceptions propagate to the caller.</summary>
procedure ExerciseFont(Font: TPdfTrueTypeFont; out Outlines: Integer);
var
  G, C: Integer;
  O: TPdfGlyphOutline;
begin
  Outlines := 0;
  for G := 0 to Font.GlyphCount - 1 do
  begin
    if Font.GetOutline(G, O) and (O.Count > 0) then
      Inc(Outlines);
    Font.GetAdvance(G);
  end;
  Font.GetOutline(-1, O);
  Font.GetOutline(Font.GlyphCount, O);
  for C := 0 to 255 do
  begin
    Font.GlyphByCode(C);
    Font.GlyphByUnicode(C);
  end;
  Font.GlyphByUnicode($4E00);
  Font.GlyphByUnicode($1F600);
  Font.GlyphByName('A');
  Font.GlyphByName('.notdef');
  Font.GlyphName(1);
  Font.FontMatrix;
  Font.OutlineCount;
end;

function CorpusDir: string;
var
  Env, D: string;
begin
  Env := GetEnvironmentVariable('PDF_CORPUS_DIRS');
  for D in Env.Split([';']) do
    if (Trim(D) <> '') and TDirectory.Exists(Trim(D)) then
      Exit(Trim(D));
  Result := TPath.Combine(TPath.GetTempPath, 'claude\pdfjs-corpus\pdfjs\test\pdfs');
  if not TDirectory.Exists(Result) then
    Result := '';
end;

/// <summary>Decoded font program streams (Kind = 'FontFile2' / 'FontFile3') of the fonts on the first pages of a
/// PDF. Problems on the PDF side are ignored.</summary>
function CollectFontPrograms(const FileName, Kind: string; MaxPages: Integer): TList<TBytes>;
var
  Doc: TPdfDocument;
  Seen: TList<Integer>;
  P, K: Integer;
  Fonts, FD, Desc: IPdfDictionary;
  Descendants: IPdfArray;
  S: IPdfStream;
begin
  Result := TList<TBytes>.Create;
  Seen := TList<Integer>.Create;
  Doc := TPdfDocument.Create;
  try
    try
      Doc.LoadFromFile(FileName);
      for P := 0 to Doc.PageCount - 1 do
      begin
        if P >= MaxPages then
          Break;
        try
          if Doc.Pages[P].Resources = nil then
            Continue;
          Fonts := Doc.Pages[P].Resources.GetDictionary('Font');
          if Fonts = nil then
            Continue;
          for K := 0 to Fonts.GetCount - 1 do
          try
            FD := Fonts.GetDictionary(Fonts.GetKey(K));
            if FD = nil then
              Continue;
            Descendants := FD.GetArray('DescendantFonts');
            if (Descendants <> nil) and (Descendants.GetCount > 0) then
              FD := Descendants.GetDictionary(0);
            if FD = nil then
              Continue;
            Desc := FD.GetDictionary('FontDescriptor');
            if Desc = nil then
              Continue;
            S := Desc.GetStream(Kind);
            if S = nil then
              Continue;
            if S.GetObjNum > 0 then
            begin
              if Seen.Contains(S.GetObjNum) then
                Continue;
              Seen.Add(S.GetObjNum);
            end;
            Result.Add(S.GetDecodedData);
          except
            // broken font dictionary or stream: not this unit's concern
          end;
        except
          // broken page
        end;
      end;
    except
      // unreadable or encrypted document
    end;
  finally
    Doc.Free;
    Seen.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ Liberation Sans                                                              }
{ ---------------------------------------------------------------------------- }

procedure TPdfTrueTypeTests.LiberationRegular_Basics;
var
  Data: TBytes;
  Font: TPdfTrueTypeFont;
  M: TPdfMatrix;
begin
  Data := TFile.ReadAllBytes(FontFile('LiberationSans-Regular.ttf'));
  Assert.IsTrue(TPdfTrueTypeFont.IsTrueType(Data));
  Font := TPdfTrueTypeFont.Create(Data);
  try
    Assert.AreEqual(2048, Font.UnitsPerEm);
    // The bundled Liberation Sans is a 1.x build: maxp numGlyphs = 681, of which 678 have outlines.
    Assert.AreEqual(681, Font.GlyphCount, 'GlyphCount');
    Assert.AreEqual(Font.NumGlyphs, Font.GlyphCount);
    Assert.AreEqual(678, Font.OutlineCount, 'OutlineCount');
    Assert.IsTrue(Font.HasGlyf);
    Assert.IsFalse(Font.HasCFF);
    Assert.IsTrue(Font.CFFData = nil);
    Assert.IsTrue(Font.HasTable('glyf'));
    Assert.IsTrue(Font.HasTable('cmap'));
    Assert.IsFalse(Font.HasTable('CFF'));
    Assert.IsTrue(Font.HasCmap);
    Assert.IsTrue(Font.HasUnicodeCmap);
    Assert.IsTrue(Font.HasUnicodeMap);
    Assert.IsTrue(Font.HasPostNames);
    Assert.IsTrue(Font.HasGlyphNames);
    Assert.IsFalse(Font.HasSymbolCmap);
    M := Font.FontMatrix;
    Assert.AreEqual(1 / 2048, M.A, 1E-12);
    Assert.AreEqual(1 / 2048, M.D, 1E-12);
    Assert.AreEqual(0.0, M.B, 1E-12);
  finally
    Font.Free;
  end;
end;

procedure TPdfTrueTypeTests.LiberationRegular_GlyphA;
var
  Font: TPdfTrueTypeFont;
  G: Integer;
  O: TPdfGlyphOutline;
  MinX, MinY, MaxX, MaxY: Single;
begin
  Font := LoadFont('LiberationSans-Regular.ttf');
  try
    G := Font.GlyphByUnicode(Ord('A'));
    Assert.IsTrue(G > 0, 'cmap A');
    Assert.IsTrue(Font.GetOutline(G, O));
    Assert.AreEqual(2, CountMoves(O), 'A: outer contour + hole');
    Assert.AreEqual(glClose, O.Cmds[O.Count - 1].Kind);
    OutlineBounds(O, MinX, MinY, MaxX, MaxY);
    Assert.IsTrue((MinX >= -10) and (MinX < 50), Format('MinX %g', [MinX]));
    Assert.IsTrue((MaxX > 1250) and (MaxX <= 1380), Format('MaxX %g', [MaxX]));
    Assert.IsTrue((MinY >= -10) and (MinY <= 10), Format('MinY %g', [MinY]));
    Assert.IsTrue((MaxY > 1300) and (MaxY < 1500), Format('MaxY %g', [MaxY]));
    Assert.AreEqual(1366.0, Double(Font.GetAdvance(G)), 0.001);
    Assert.AreEqual(1366.0, Double(O.Advance), 0.001);
    Assert.AreEqual(G, Font.GlyphByName('A'), 'post name');
    Assert.AreEqual('A', Font.GlyphName(G));
    // space: an empty glyph is not an error
    G := Font.GlyphByUnicode(32);
    Assert.IsTrue(G > 0);
    Assert.IsTrue(Font.GetOutline(G, O));
    Assert.IsTrue(O.IsEmpty);
    Assert.IsTrue(O.Advance > 0);
  finally
    Font.Free;
  end;
end;

procedure TPdfTrueTypeTests.LiberationRegular_Composite;
var
  Font: TPdfTrueTypeFont;
  G, GE: Integer;
  O, OE: TPdfGlyphOutline;
  MinX, MinY, MaxX, MaxY: Single;
begin
  Font := LoadFont('LiberationSans-Regular.ttf');
  try
    G := Font.GlyphByUnicode($E9);
    Assert.IsTrue(G > 0);
    Assert.AreEqual(G, Font.GlyphByName('eacute'));
    Assert.IsTrue(Font.GetOutline(G, O));
    Assert.AreEqual(3, CountMoves(O), 'eacute = e (2) + acute (1)');
    GE := Font.GlyphByUnicode(Ord('e'));
    Assert.IsTrue(Font.GetOutline(GE, OE));
    Assert.AreEqual(2, CountMoves(OE));
    OutlineBounds(O, MinX, MinY, MaxX, MaxY);
    Assert.IsTrue(MaxY > 1300, 'accent above the x-height');
  finally
    Font.Free;
  end;
end;

procedure TPdfTrueTypeTests.LiberationRegular_Lookups;
var
  Font: TPdfTrueTypeFont;
  O: TPdfGlyphOutline;
begin
  Font := LoadFont('LiberationSans-Regular.ttf');
  try
    Assert.AreEqual(-1, Font.GlyphByUnicode($10000));
    Assert.AreEqual(-1, Font.GlyphByUnicode($110000));
    Assert.AreEqual(-1, Font.GlyphByUnicode(-5));
    Assert.IsTrue(Font.HasMacRomanCmap, 'Liberation has a (1,0) table');
    Assert.IsTrue(Font.GlyphByMacCode(65) > 0);
    Assert.AreEqual(Font.GlyphByUnicode(65), Font.GlyphByMacCode(65));
    // Mac Roman $8E = eacute
    Assert.AreEqual(Font.GlyphByUnicode($E9), Font.GlyphByMacCode($8E));
    Assert.AreEqual(-1, Font.GlyphBySymbolCode(65));
    Assert.AreEqual(Font.GlyphByMacCode(65), Font.GlyphByCode(65));
    Assert.IsTrue(Font.HasCodeMap);
    Assert.AreEqual(-1, Font.GlyphByName('no-such-glyph'));
    Assert.AreEqual(-1, Font.GlyphByName(''));
    Assert.AreEqual(0, Font.GlyphByName('.notdef'));
    Assert.IsTrue(Font.GlyphByUnicode($20AC) > 0, 'Euro');
    Assert.AreEqual(Font.GlyphByUnicode($20AC), Font.GlyphByName('Euro'));
    Assert.IsFalse(Font.GetOutline(-1, O));
    Assert.IsFalse(Font.GetOutline(Font.GlyphCount, O));
    Assert.AreEqual(-1.0, Double(Font.GetAdvance(Font.GlyphCount)), 0.001);
  finally
    Font.Free;
  end;
end;

procedure TPdfTrueTypeTests.LiberationStyles_Load;
const
  Names: array[0..2] of string = ('LiberationSans-Bold.ttf', 'LiberationSans-Italic.ttf',
    'LiberationSans-BoldItalic.ttf');
var
  Name: string;
  Font: TPdfTrueTypeFont;
  G: Integer;
  O: TPdfGlyphOutline;
begin
  for Name in Names do
  begin
    Font := LoadFont(Name);
    try
      Assert.AreEqual(2048, Font.UnitsPerEm, Name);
      G := Font.GlyphByUnicode(Ord('A'));
      Assert.IsTrue(G > 0, Name);
      Assert.IsTrue(Font.GetOutline(G, O), Name);
      Assert.AreEqual(2, CountMoves(O), Name);
      Assert.AreEqual(G, Font.GlyphByName('A'), Name);
    finally
      Font.Free;
    end;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ Synthetic fonts                                                              }
{ ---------------------------------------------------------------------------- }

procedure TPdfTrueTypeTests.Synthetic_SymbolSquare;
var
  Font: TPdfTrueTypeFont;
  O: TPdfGlyphOutline;
begin
  Font := TPdfTrueTypeFont.Create(MakeSymbolFont(False, False));
  try
    Assert.AreEqual(1000, Font.UnitsPerEm);
    Assert.AreEqual(2, Font.GlyphCount);
    Assert.AreEqual(1, Font.OutlineCount);
    Assert.IsTrue(Font.HasSymbolCmap);
    Assert.IsFalse(Font.HasUnicodeCmap);
    Assert.IsFalse(Font.HasMacRomanCmap);
    Assert.IsFalse(Font.HasPostNames);
    Assert.AreEqual(1, Font.GlyphBySymbolCode($41));
    Assert.AreEqual(1, Font.GlyphBySymbolCode($F041));
    Assert.AreEqual(1, Font.GlyphByCode($41));
    Assert.AreEqual(-1, Font.GlyphBySymbolCode($42));
    Assert.AreEqual(-1, Font.GlyphByMacCode($41));
    Assert.AreEqual(-1, Font.GlyphByUnicode($41));
    Assert.AreEqual(-1, Font.GlyphByName('A'));
    Assert.IsTrue(Font.GetOutline(1, O));
    Assert.AreEqual(5, O.Count, 'move, 3 lines, close');
    Assert.AreEqual(glMove, O.Cmds[0].Kind);
    Assert.AreEqual(0.0, Double(O.Cmds[0].X1), 0.001);
    Assert.AreEqual(glLine, O.Cmds[1].Kind);
    Assert.AreEqual(500.0, Double(O.Cmds[1].X1), 0.001);
    Assert.AreEqual(glLine, O.Cmds[2].Kind);
    Assert.AreEqual(500.0, Double(O.Cmds[2].Y1), 0.001);
    Assert.AreEqual(glLine, O.Cmds[3].Kind);
    Assert.AreEqual(0.0, Double(O.Cmds[3].X1), 0.001);
    Assert.AreEqual(glClose, O.Cmds[4].Kind);
    Assert.AreEqual(600.0, Double(O.Advance), 0.001);
    Assert.IsTrue(Font.GetOutline(0, O));
    Assert.IsTrue(O.IsEmpty);
    Assert.AreEqual(500.0, Double(Font.GetAdvance(0)), 0.001);
  finally
    Font.Free;
  end;
end;

procedure TPdfTrueTypeTests.Synthetic_BrokenLoca;
var
  Glyf, Data: TBytes;
  Font: TPdfTrueTypeFont;
  O: TPdfGlyphOutline;
  G, N: Integer;
begin
  Glyf := SquareGlyph;
  // glyph 0 square; glyph 1 ends before it starts; glyph 2 starts inside glyph 0; glyph 3 points past glyf;
  // glyph 4 has no loca entry at all
  Data := BuildSfnt(['head', 'maxp', 'hhea', 'hmtx', 'loca', 'glyf', 'cmap'],
    [MakeHead(1000, 0), MakeMaxp(5), MakeHhea(1), MakeHmtx([700]),
     MakeLoca([0, Length(Glyf), 4, Length(Glyf), 4000], False), Glyf, MakeSymbolCmap]);
  Font := TPdfTrueTypeFont.Create(Data);
  try
    Assert.AreEqual(5, Font.GlyphCount);
    Assert.IsTrue(Font.GetOutline(0, O));
    Assert.AreEqual(1, CountMoves(O));
    Assert.IsTrue(Font.GetOutline(1, O), 'end < start: empty glyph');
    Assert.IsTrue(O.IsEmpty);
    for G := 2 to 4 do
      Font.GetOutline(G, O); // must not raise
    Assert.IsTrue(Font.GetOutline(4, O));
    Assert.IsTrue(O.IsEmpty, 'missing loca entry: empty glyph');
    Assert.AreEqual(700.0, Double(Font.GetAdvance(4)), 0.001, 'last hmtx entry repeats');
    ExerciseFont(Font, N);
  finally
    Font.Free;
  end;
end;

procedure TPdfTrueTypeTests.Synthetic_LocaFormatMismatch;
var
  Font: TPdfTrueTypeFont;
  O: TPdfGlyphOutline;
begin
  // head says long offsets, loca holds short ones
  Font := TPdfTrueTypeFont.Create(MakeSymbolFont(True, False));
  try
    Assert.IsTrue(Font.GetOutline(1, O));
    Assert.AreEqual(5, O.Count);
  finally
    Font.Free;
  end;
  // head says short offsets, loca holds long ones
  Font := TPdfTrueTypeFont.Create(MakeSymbolFont(False, True));
  try
    Assert.IsTrue(Font.GetOutline(1, O));
    Assert.AreEqual(5, O.Count);
  finally
    Font.Free;
  end;
  // consistent long format
  Font := TPdfTrueTypeFont.Create(MakeSymbolFont(True, True));
  try
    Assert.IsTrue(Font.GetOutline(1, O));
    Assert.AreEqual(5, O.Count);
  finally
    Font.Free;
  end;
end;

procedure TPdfTrueTypeTests.Synthetic_CompositeAndSelfReference;
var
  Sq, Comp, SelfRef, Glyf, Data: TBytes;
  W: TBeWriter;
  Font: TPdfTrueTypeFont;
  O: TPdfGlyphOutline;
  MinX, MinY, MaxX, MaxY: Single;
begin
  Sq := SquareGlyph;
  W := TBeWriter.Create;
  try
    W.U16($FFFF);
    W.U16(0); W.U16(0); W.U16(1100); W.U16(500);
    W.U16($0023);          // words | xy | more
    W.U16(1);
    W.U16(600);
    W.U16(0);
    W.U16($000A);          // xy | scale, byte args
    W.U16(1);
    W.U8(0);
    W.U8(0);
    W.U16($2000);          // 0.5
    Comp := W.ToBytes;
  finally
    W.Free;
  end;
  W := TBeWriter.Create;
  try
    W.U16($FFFF);
    W.U16(0); W.U16(0); W.U16(500); W.U16(500);
    W.U16($0023);
    W.U16(3);              // itself
    W.U16(0);
    W.U16(0);
    W.U16($0003);
    W.U16(1);
    W.U16(10);
    W.U16(20);
    SelfRef := W.ToBytes;
  finally
    W.Free;
  end;
  Glyf := Sq + Comp + SelfRef;
  Data := BuildSfnt(['head', 'maxp', 'loca', 'glyf'],
    [MakeHead(2048, 1), MakeMaxp(4),
     MakeLoca([0, 0, Length(Sq), Length(Sq) + Length(Comp), Length(Glyf)], True), Glyf]);
  Font := TPdfTrueTypeFont.Create(Data);
  try
    Assert.AreEqual(2048, Font.UnitsPerEm);
    Assert.IsFalse(Font.HasCmap);
    Assert.AreEqual(-1.0, Double(Font.GetAdvance(1)), 0.001, 'no hmtx');
    Assert.IsTrue(Font.GetOutline(2, O));
    Assert.AreEqual(2, CountMoves(O));
    // first component moved by 600, second scaled by 0.5
    Assert.AreEqual(600.0, Double(O.Cmds[0].X1), 0.001);
    Assert.AreEqual(1100.0, Double(O.Cmds[1].X1), 0.001);
    Assert.AreEqual(glMove, O.Cmds[5].Kind);
    Assert.AreEqual(250.0, Double(O.Cmds[6].X1), 0.001);
    OutlineBounds(O, MinX, MinY, MaxX, MaxY);
    Assert.AreEqual(0.0, Double(MinX), 0.001);
    Assert.AreEqual(1100.0, Double(MaxX), 0.001);
    Assert.IsTrue(Font.GetOutline(3, O), 'self reference is skipped');
    Assert.AreEqual(1, CountMoves(O));
    Assert.AreEqual(10.0, Double(O.Cmds[0].X1), 0.001);
    Assert.AreEqual(20.0, Double(O.Cmds[0].Y1), 0.001);
  finally
    Font.Free;
  end;
end;

procedure TPdfTrueTypeTests.Synthetic_OffCurveContour;
var
  Glyf, Data: TBytes;
  Font: TPdfTrueTypeFont;
  O: TPdfGlyphOutline;
  I, Quads: Integer;
begin
  // A diamond of four off-curve points: every on-curve point is implied, the contour starts at a midpoint.
  Glyf := MakeSimpleGlyph([3], [0, 100, 100, 0], [0, 0, 100, 100], [False, False, False, False]);
  Data := BuildSfnt(['head', 'maxp', 'loca', 'glyf'],
    [MakeHead(1000, 0), MakeMaxp(1), MakeLoca([0, Length(Glyf)], False), Glyf]);
  Font := TPdfTrueTypeFont.Create(Data);
  try
    Assert.IsTrue(Font.GetOutline(0, O));
    Assert.AreEqual(glMove, O.Cmds[0].Kind);
    Assert.AreEqual(0.0, Double(O.Cmds[0].X1), 0.001);
    Assert.AreEqual(50.0, Double(O.Cmds[0].Y1), 0.001);
    Quads := 0;
    for I := 0 to O.Count - 1 do
      if O.Cmds[I].Kind = glQuad then
        Inc(Quads);
    Assert.AreEqual(4, Quads);
    Assert.AreEqual(6, O.Count);
    // last curve returns to the start point
    Assert.AreEqual(0.0, Double(O.Cmds[4].X2), 0.001);
    Assert.AreEqual(50.0, Double(O.Cmds[4].Y2), 0.001);
  finally
    Font.Free;
  end;
  // Starts off-curve, ends on-curve: the contour begins at the last point.
  Glyf := MakeSimpleGlyph([2], [50, 100, 0], [100, 0, 0], [False, True, True]);
  Data := BuildSfnt(['head', 'maxp', 'loca', 'glyf'],
    [MakeHead(1000, 0), MakeMaxp(1), MakeLoca([0, Length(Glyf)], False), Glyf]);
  Font := TPdfTrueTypeFont.Create(Data);
  try
    Assert.IsTrue(Font.GetOutline(0, O));
    Assert.AreEqual(glMove, O.Cmds[0].Kind);
    Assert.AreEqual(0.0, Double(O.Cmds[0].X1), 0.001);
    Assert.AreEqual(glQuad, O.Cmds[1].Kind);
    Assert.AreEqual(50.0, Double(O.Cmds[1].X1), 0.001);
    Assert.AreEqual(100.0, Double(O.Cmds[1].X2), 0.001);
  finally
    Font.Free;
  end;
end;

procedure TPdfTrueTypeTests.Synthetic_CollectionAndDirectory;
var
  Glyf, Sfnt, Data: TBytes;
  W: TBeWriter;
  Font: TPdfTrueTypeFont;
  O: TPdfGlyphOutline;
begin
  // 'ttcf' header with one font whose table offsets are relative to the start of the collection
  Glyf := SquareGlyph;
  Sfnt := BuildSfnt(['head', 'maxp', 'loca', 'glyf', 'cmap'],
    [MakeHead(1000, 0), MakeMaxp(2), MakeLoca([0, 0, Length(Glyf)], False), Glyf, MakeSymbolCmap], 16);
  W := TBeWriter.Create;
  try
    W.U32($74746366);
    W.U32($00010000);
    W.U32(1);
    W.U32(16);
    W.Bytes(Sfnt);
    Data := W.ToBytes;
  finally
    W.Free;
  end;
  Assert.IsTrue(TPdfTrueTypeFont.IsTrueType(Data));
  Font := TPdfTrueTypeFont.Create(Data);
  try
    Assert.AreEqual(1, Font.GlyphBySymbolCode($41));
    Assert.IsTrue(Font.GetOutline(1, O));
    Assert.AreEqual(5, O.Count);
  finally
    Font.Free;
  end;

  // Duplicate tags (first wins), an entry pointing past the end (ignored) and a length running past the end
  // (clamped). The 'head' record is patched to point outside the data; a second 'maxp' says 99 glyphs.
  Data := BuildSfnt(['maxp', 'maxp', 'head', 'loca', 'glyf'],
    [MakeMaxp(2), MakeMaxp(99), MakeHead(2048, 0), MakeLoca([0, 0, Length(Glyf)], False), Glyf]);
  // head record: index 2 -> offset field at 12 + 2*16 + 8
  Data[12 + 32 + 8] := $7F;
  // glyf record: index 4 -> length field at 12 + 4*16 + 12
  Data[12 + 64 + 12] := $00;
  Data[12 + 64 + 13] := $10;
  Font := TPdfTrueTypeFont.Create(Data);
  try
    Assert.IsFalse(Font.HasTable('head'), 'out-of-range entry ignored');
    Assert.AreEqual(1000, Font.UnitsPerEm, 'no head: 1000');
    Assert.AreEqual(2, Font.GlyphCount, 'first maxp wins');
    Assert.IsTrue(Font.GetOutline(1, O));
    Assert.AreEqual(5, O.Count);
  finally
    Font.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ Damaged data                                                                 }
{ ---------------------------------------------------------------------------- }

procedure TPdfTrueTypeTests.Damaged_Truncated;
var
  Full, Data: TBytes;
  Font: TPdfTrueTypeFont;
  Cut, N, Loaded: Integer;
begin
  Full := TFile.ReadAllBytes(FontFile('LiberationSans-Regular.ttf'));
  Loaded := 0;
  for Cut in [Length(Full) div 2, Length(Full) div 3, Length(Full) - 1000, 5000, 400, 100, 20, 12, 11] do
  begin
    Data := Copy(Full, 0, Cut);
    try
      Font := TPdfTrueTypeFont.Create(Data);
    except
      on E: EPdfFontError do
        Continue;
    end;
    try
      Inc(Loaded);
      ExerciseFont(Font, N);
    finally
      Font.Free;
    end;
  end;
  Assert.IsTrue(Loaded >= 3, 'truncated fonts with an intact directory load');
end;

procedure TPdfTrueTypeTests.Damaged_Mutated;
var
  Full, Data: TBytes;
  Font: TPdfTrueTypeFont;
  Round, I, N: Integer;
begin
  Full := TFile.ReadAllBytes(FontFile('LiberationSans-Regular.ttf'));
  RandSeed := 12345;
  for Round := 1 to 25 do
  begin
    Data := Copy(Full);
    for I := 1 to 200 do
      Data[Random(Length(Data))] := Byte(Random(256));
    // also hit the directory and table headers harder
    for I := 1 to 4 do
      Data[Random(400)] := Byte(Random(256));
    try
      Font := TPdfTrueTypeFont.Create(Data);
    except
      on E: EPdfFontError do
        Continue;
    end;
    try
      ExerciseFont(Font, N);
    finally
      Font.Free;
    end;
  end;
  Assert.Pass;
end;

procedure TPdfTrueTypeTests.Damaged_Empty;
begin
  Assert.WillRaise(
    procedure
    begin
      TPdfTrueTypeFont.Create(nil).Free;
    end, EPdfFontError);
  Assert.WillRaise(
    procedure
    begin
      TPdfTrueTypeFont.Create(TEncoding.ANSI.GetBytes('this is not a font at all, just text')).Free;
    end, EPdfFontError);
  Assert.IsFalse(TPdfTrueTypeFont.IsTrueType(nil));
  Assert.IsFalse(TPdfTrueTypeFont.IsTrueType(TEncoding.ANSI.GetBytes('%!PS-AdobeFont-1.0')));
end;

{ ---------------------------------------------------------------------------- }
{ Corpus                                                                       }
{ ---------------------------------------------------------------------------- }

procedure TPdfTrueTypeTests.Corpus_FontFile2Sweep;
const
  MaxDocs = 150;
var
  Dir, F: string;
  Files: TArray<string>;
  Programs: TList<TBytes>;
  Data: TBytes;
  Font: TPdfTrueTypeFont;
  Failures: TStringList;
  Docs, Fonts, Loaded, Rejected, WithCmap, WithPost, Glyphs, Outlines, N: Integer;
  SW: TStopwatch;
begin
  Dir := CorpusDir;
  if Dir = '' then
  begin
    Assert.Pass('No corpus folder');
    Exit;
  end;
  Files := TDirectory.GetFiles(Dir, '*.pdf');
  TArray.Sort<string>(Files, TComparer<string>.Construct(
    function(const L, R: string): Integer
    begin
      Result := CompareText(L, R);
    end));
  Failures := TStringList.Create;
  SW := TStopwatch.StartNew;
  Docs := 0;
  Fonts := 0;
  Loaded := 0;
  Rejected := 0;
  WithCmap := 0;
  WithPost := 0;
  Glyphs := 0;
  Outlines := 0;
  try
    for F in Files do
    begin
      if Docs >= MaxDocs then
        Break;
      Programs := CollectFontPrograms(F, 'FontFile2', 10);
      try
        if Programs.Count = 0 then
          Continue;
        Inc(Docs);
        for Data in Programs do
        begin
          Inc(Fonts);
          Font := nil;
          try
            try
              Font := TPdfTrueTypeFont.Create(Data);
            except
              on E: EPdfFontError do
              begin
                Inc(Rejected);
                Continue;
              end;
            end;
            Inc(Loaded);
            if Font.HasCmap then
              Inc(WithCmap);
            if Font.HasPostNames then
              Inc(WithPost);
            Inc(Glyphs, Font.GlyphCount);
            ExerciseFont(Font, N);
            Inc(Outlines, N);
          except
            on E: Exception do
              Failures.Add(Format('%s: %s: %s', [TPath.GetFileName(F), E.ClassName, E.Message]));
          end;
          Font.Free;
        end;
      finally
        Programs.Free;
      end;
    end;
    TDUnitX.CurrentRunner.Log(TLogLevel.Information, Format(
      'TrueType sweep: %d PDFs, %d FontFile2 programs, %d loaded, %d rejected (EPdfFontError), ' +
      '%d with cmap, %d with post names, %d glyphs, %d with outlines, %d ms',
      [Docs, Fonts, Loaded, Rejected, WithCmap, WithPost, Glyphs, Outlines, SW.ElapsedMilliseconds]));
    if Failures.Count > 0 then
      Assert.Fail(Failures.Text);
    Assert.IsTrue(Loaded > 0, 'no FontFile2 program loaded');
  finally
    Failures.Free;
  end;
end;

procedure TPdfTrueTypeTests.Corpus_OpenTypeCFF;
var
  Dir, F: string;
  Programs: TList<TBytes>;
  Data: TBytes;
  Font: TPdfTrueTypeFont;
  O: TPdfGlyphOutline;
  Found: Boolean;
begin
  Dir := CorpusDir;
  F := TPath.Combine(Dir, 'issue9915_reduced.pdf');
  if (Dir = '') or not TFile.Exists(F) then
  begin
    Assert.Pass('No corpus file issue9915_reduced.pdf');
    Exit;
  end;
  Found := False;
  Programs := CollectFontPrograms(F, 'FontFile3', 10);
  try
    for Data in Programs do
    begin
      if (Length(Data) < 4) or (TEncoding.ANSI.GetString(Data, 0, 4) <> 'OTTO') then
        Continue;
      Found := True;
      Assert.IsTrue(TPdfTrueTypeFont.IsTrueType(Data));
      Font := TPdfTrueTypeFont.Create(Data);
      try
        Assert.IsTrue(Font.HasCFF);
        Assert.IsTrue(Length(Font.CFFData) > 0);
        Assert.IsTrue(Font.HasTable('CFF '));
        Assert.IsFalse(Font.HasGlyf);
        Assert.AreEqual(-1, Font.OutlineCount);
        Assert.IsFalse(Font.GetOutline(1, O));
        Assert.IsTrue(Font.GlyphCount > 0);
      finally
        Font.Free;
      end;
    end;
  finally
    Programs.Free;
  end;
  Assert.IsTrue(Found, 'no OTTO program in issue9915_reduced.pdf');
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfTrueTypeTests);

end.
