{*******************************************************************************
  Pdf.Tests.Font.CFF
  DUnitX fixture for Pdf.Font.CFF. A small CFF writer in this unit builds
  synthetic fonts (INDEXes, DICTs with fixed-width offsets, charsets,
  encodings, Private DICTs, FDArray/FDSelect) whose charstrings are written
  with a tiny Type 2 assembler. A corpus sweep runs the parser over the
  FontFile3 programs embedded in the PDFs of PDF_CORPUS_DIRS / Tests\Corpus.
*******************************************************************************}
unit Pdf.Tests.Font.CFF;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Math, System.Diagnostics, System.Generics.Collections,
  DUnitX.TestFramework, Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Document, Pdf.Font.Glyphs, Pdf.Font.CFF;

type
  [TestFixture]
  TPdfCFFTests = class
  public
    [Test] procedure StandardStrings;
    [Test] procedure IsCFFDetection;
    [Test] procedure SimpleFont_Lookups;
    [Test] procedure SimpleFont_Outline;
    [Test] procedure SimpleFont_Advance;
    [Test] procedure StandardEncodingAndCharsetFormat1;
    [Test] procedure Subroutines;
    [Test] procedure HintMask_SkipsMaskBytes;
    [Test] procedure Curves_RRAndHV;
    [Test] procedure Curves_HHVVAndMixed;
    [Test] procedure Flex;
    [Test] procedure Arithmetic_Div;
    [Test] procedure Seac;
    [Test] procedure CIDKeyed;
    [Test] procedure CIDKeyed_FontMatrix;
    [Test] procedure RealOperands_FontMatrix;
    [Test] procedure Robust_TruncatedAfterHeader;
    [Test] procedure Robust_EveryTruncation;
    [Test] procedure Robust_RandomBytes;
    [Test] procedure Robust_SubrOutOfRange;
    [Test] procedure Robust_RecursiveSubr;
    [Test] procedure Robust_CharStringsBeyondData;
    [Test] procedure Robust_Mutations;
    [Test] procedure Corpus_EmbeddedPrograms;
  end;

implementation

{ ---- CFF writer ---------------------------------------------------------- }

type
  TCFFBuild = record
    /// <summary>Charstrings, gid 0 first.</summary>
    Glyphs: TArray<TBytes>;
    /// <summary>SIDs (or CIDs) of gid 1..n-1, written as charset format 0.</summary>
    Charset: TArray<Integer>;
    /// <summary>Raw charset bytes (format byte included); overrides Charset when set.</summary>
    RawCharset: TBytes;
    /// <summary>Custom strings, SID 391 onwards.</summary>
    Strings: TArray<string>;
    GSubrs: TArray<TBytes>;
    /// <summary>Non-CID Private DICT.</summary>
    Subrs: TArray<TBytes>;
    NominalWidthX, DefaultWidthX: Integer;
    /// <summary>Custom encoding format 0: code of gid 1, 2, ..; nil writes Encoding offset 0 (Standard).</summary>
    EncodingCodes: TArray<Byte>;
    /// <summary>Raw DICT operand bytes of a Top DICT FontMatrix (6 operands), nil for none.</summary>
    TopMatrix: TBytes;
    /// <summary>CID-keyed: ROS, FDArray (one Font DICT per FDNominal entry) and raw FDSelect bytes.</summary>
    CID: Boolean;
    FDNominal: TArray<Integer>;
    FDSubrs: TArray<TArray<TBytes>>;
    FDMatrix: TArray<TBytes>;
    FDSelect: TBytes;
    /// <summary>When non-zero, the CharStrings offset written into the Top DICT.</summary>
    CharStringsOffset: Integer;
  end;

procedure Put(var B: TBytes; const Data: array of Byte);
var
  L: Integer;
begin
  L := Length(B);
  SetLength(B, L + Length(Data));
  if Length(Data) > 0 then
    Move(Data[0], B[L], Length(Data));
end;

function Ascii(const S: string): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(S));
  for I := 1 to Length(S) do
    Result[I - 1] := Byte(Ord(S[I]));
end;

/// <summary>Compact integer operand (DICT and charstring share the 1/2-byte and 28 forms).</summary>
function EncInt(V: Integer): TBytes;
begin
  if (V >= -107) and (V <= 107) then
    Result := [Byte(V + 139)]
  else if (V >= 108) and (V <= 1131) then
    Result := [Byte((V - 108) shr 8 + 247), Byte((V - 108) and $FF)]
  else if (V >= -1131) and (V <= -108) then
    Result := [Byte((-V - 108) shr 8 + 251), Byte((-V - 108) and $FF)]
  else
    Result := [28, Byte((V shr 8) and $FF), Byte(V and $FF)];
end;

/// <summary>Fixed-width DICT integer (29 + 4 bytes), used for offsets so sizes are known in advance.</summary>
function EncInt5(V: Integer): TBytes;
begin
  Result := [29, Byte((V shr 24) and $FF), Byte((V shr 16) and $FF), Byte((V shr 8) and $FF), Byte(V and $FF)];
end;

function MakeIndex(const Items: TArray<TBytes>): TBytes;
var
  I, Total, OffSize, Off, K: Integer;
begin
  Result := [Byte(Length(Items) shr 8), Byte(Length(Items) and $FF)];
  if Length(Items) = 0 then
    Exit;
  Total := 1;
  for I := 0 to High(Items) do
    Inc(Total, Length(Items[I]));
  if Total < $100 then
    OffSize := 1
  else if Total < $10000 then
    OffSize := 2
  else
    OffSize := 4;
  Put(Result, [Byte(OffSize)]);
  Off := 1;
  for I := 0 to Length(Items) do
  begin
    for K := OffSize - 1 downto 0 do
      Put(Result, [Byte((Off shr (8 * K)) and $FF)]);
    if I < Length(Items) then
      Inc(Off, Length(Items[I]));
  end;
  for I := 0 to High(Items) do
    Put(Result, Items[I]);
end;

/// <summary>Type 2 assembler: operator names, 'xHH' raw bytes, 'fN.N' (16.16 fixed) and integers.</summary>
function CS(const Src: string): TBytes;
const
  Names: array[0..22] of string = ('hstem', 'vstem', 'vmoveto', 'rlineto', 'hlineto', 'vlineto', 'rrcurveto',
    'callsubr', 'return', 'endchar', 'hstemhm', 'hintmask', 'cntrmask', 'rmoveto', 'hmoveto', 'vstemhm',
    'rcurveline', 'rlinecurve', 'vvcurveto', 'hhcurveto', 'callgsubr', 'vhcurveto', 'hvcurveto');
  Codes: array[0..22] of Byte = (1, 3, 4, 5, 6, 7, 8, 10, 11, 14, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 29, 30, 31);
  EscNames: array[0..6] of string = ('div', 'add', 'mul', 'flex', 'hflex', 'hflex1', 'flex1');
  EscCodes: array[0..6] of Byte = (12, 10, 24, 35, 34, 36, 37);
var
  Tok: string;
  V, I: Integer;
  F: Double;
  Fixed: Int32;
  Found: Boolean;
begin
  Result := nil;
  for Tok in Src.Split([' '], TStringSplitOptions.ExcludeEmpty) do
  begin
    Found := False;
    for I := 0 to High(Names) do
      if Names[I] = Tok then
      begin
        Put(Result, [Codes[I]]);
        Found := True;
        Break;
      end;
    if not Found then
      for I := 0 to High(EscNames) do
        if EscNames[I] = Tok then
        begin
          Put(Result, [12, EscCodes[I]]);
          Found := True;
          Break;
        end;
    if Found then
      Continue;
    if Tok.StartsWith('x') then
    begin
      Put(Result, [Byte(StrToInt('$' + Tok.Substring(1)))]);
      Continue;
    end;
    if Tok.StartsWith('f') then
    begin
      F := StrToFloat(Tok.Substring(1), TFormatSettings.Invariant);
      Fixed := Round(F * 65536);
      Put(Result, [255, Byte((Fixed shr 24) and $FF), Byte((Fixed shr 16) and $FF), Byte((Fixed shr 8) and $FF),
        Byte(Fixed and $FF)]);
      Continue;
    end;
    if TryStrToInt(Tok, V) then
    begin
      Put(Result, EncInt(V));
      Continue;
    end;
    raise Exception.Create('CS: unknown token ' + Tok);
  end;
end;

function PrivateDict(Nominal, DefaultW: Integer; HasSubrs: Boolean): TBytes;
begin
  Result := nil;
  Put(Result, EncInt(DefaultW));
  Put(Result, [20]);
  Put(Result, EncInt(Nominal));
  Put(Result, [21]);
  if HasSubrs then
  begin
    // The Subrs INDEX follows the Private DICT directly: offset = DICT size (5 + 1 bytes for this entry).
    Put(Result, EncInt5(Length(Result) + 6));
    Put(Result, [19]);
  end;
end;

function BuildCFF(const B: TCFFBuild): TBytes;
var
  NameIdx, StrIdx, GSubrIdx, CharsetBytes, EncBytes, CSIdx, TopIdx, FDArrayIdx: TBytes;
  Privs, SubrIdxs, FDDicts: TArray<TBytes>;
  PrivPos: TArray<Integer>;
  StrItems: TArray<TBytes>;
  I, Pos, CharsetPos, EncPos, FDSelPos, CSPos, FDArrayPos, NPriv: Integer;

  function TopDict: TBytes;
  begin
    Result := nil;
    if B.CID then
    begin
      Put(Result, EncInt(391));
      Put(Result, EncInt(392));
      Put(Result, EncInt(0));
      Put(Result, [12, 30]);
    end;
    if B.TopMatrix <> nil then
    begin
      Put(Result, B.TopMatrix);
      Put(Result, [12, 7]);
    end;
    Put(Result, EncInt5(CharsetPos));
    Put(Result, [15]);
    if not B.CID and (B.EncodingCodes <> nil) then
    begin
      Put(Result, EncInt5(EncPos));
      Put(Result, [16]);
    end;
    if B.CharStringsOffset <> 0 then
      Put(Result, EncInt5(B.CharStringsOffset))
    else
      Put(Result, EncInt5(CSPos));
    Put(Result, [17]);
    if B.CID then
    begin
      Put(Result, EncInt5(FDArrayPos));
      Put(Result, [12, 36]);
      Put(Result, EncInt5(FDSelPos));
      Put(Result, [12, 37]);
    end
    else
    begin
      Put(Result, EncInt5(Length(Privs[0])));
      Put(Result, EncInt5(PrivPos[0]));
      Put(Result, [18]);
    end;
  end;

  function FDDict(K: Integer): TBytes;
  begin
    Result := nil;
    if (K < Length(B.FDMatrix)) and (B.FDMatrix[K] <> nil) then
    begin
      Put(Result, B.FDMatrix[K]);
      Put(Result, [12, 7]);
    end;
    Put(Result, EncInt5(Length(Privs[K])));
    Put(Result, EncInt5(PrivPos[K]));
    Put(Result, [18]);
  end;

begin
  NameIdx := MakeIndex([Ascii('Test')]);
  SetLength(StrItems, Length(B.Strings));
  for I := 0 to High(B.Strings) do
    StrItems[I] := Ascii(B.Strings[I]);
  StrIdx := MakeIndex(StrItems);
  GSubrIdx := MakeIndex(B.GSubrs);
  if B.RawCharset <> nil then
    CharsetBytes := B.RawCharset
  else
  begin
    CharsetBytes := [0];
    for I := 0 to High(B.Charset) do
      Put(CharsetBytes, [Byte(B.Charset[I] shr 8), Byte(B.Charset[I] and $FF)]);
  end;
  EncBytes := nil;
  if not B.CID and (B.EncodingCodes <> nil) then
  begin
    EncBytes := [0, Byte(Length(B.EncodingCodes))];
    Put(EncBytes, B.EncodingCodes);
  end;
  CSIdx := MakeIndex(B.Glyphs);

  if B.CID then
    NPriv := Length(B.FDNominal)
  else
    NPriv := 1;
  SetLength(Privs, NPriv);
  SetLength(SubrIdxs, NPriv);
  SetLength(PrivPos, NPriv);
  for I := 0 to NPriv - 1 do
    if B.CID then
    begin
      SubrIdxs[I] := nil;
      if (I < Length(B.FDSubrs)) and (B.FDSubrs[I] <> nil) then
        SubrIdxs[I] := MakeIndex(B.FDSubrs[I]);
      Privs[I] := PrivateDict(B.FDNominal[I], 0, SubrIdxs[I] <> nil);
    end
    else
    begin
      SubrIdxs[I] := nil;
      if B.Subrs <> nil then
        SubrIdxs[I] := MakeIndex(B.Subrs);
      Privs[I] := PrivateDict(B.NominalWidthX, B.DefaultWidthX, SubrIdxs[I] <> nil);
    end;

  // Pass 1 with zero offsets gives the (fixed) Top DICT size, pass 2 writes the real offsets.
  CharsetPos := 0;
  EncPos := 0;
  FDSelPos := 0;
  CSPos := 0;
  FDArrayPos := 0;
  TopIdx := MakeIndex([TopDict]);
  Pos := 4 + Length(NameIdx) + Length(TopIdx) + Length(StrIdx) + Length(GSubrIdx);
  CharsetPos := Pos;
  Inc(Pos, Length(CharsetBytes));
  EncPos := Pos;
  Inc(Pos, Length(EncBytes));
  FDSelPos := Pos;
  if B.CID then
    Inc(Pos, Length(B.FDSelect));
  CSPos := Pos;
  Inc(Pos, Length(CSIdx));
  for I := 0 to NPriv - 1 do
  begin
    PrivPos[I] := Pos;
    Inc(Pos, Length(Privs[I]) + Length(SubrIdxs[I]));
  end;
  FDArrayPos := Pos;
  TopIdx := MakeIndex([TopDict]);

  Result := [1, 0, 4, 4];
  Put(Result, NameIdx);
  Put(Result, TopIdx);
  Put(Result, StrIdx);
  Put(Result, GSubrIdx);
  Assert.AreEqual(CharsetPos, Integer(Length(Result)), 'builder layout');
  Put(Result, CharsetBytes);
  Put(Result, EncBytes);
  if B.CID then
    Put(Result, B.FDSelect);
  Put(Result, CSIdx);
  for I := 0 to NPriv - 1 do
  begin
    Put(Result, Privs[I]);
    Put(Result, SubrIdxs[I]);
  end;
  if B.CID then
  begin
    SetLength(FDDicts, NPriv);
    for I := 0 to NPriv - 1 do
      FDDicts[I] := FDDict(I);
    FDArrayIdx := MakeIndex(FDDicts);
    Put(Result, FDArrayIdx);
  end;
end;

function StdSID(const Name: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(PdfCFFStandardStrings) do
    if PdfCFFStandardStrings[I] = Name then
      Exit(I);
  Result := -1;
end;

const
  SquareCS = '100 100 rmoveto 200 hlineto 200 vlineto -200 hlineto endchar';

function SimpleBuild: TCFFBuild;
begin
  Result := Default(TCFFBuild);
  Result.Glyphs := [CS('endchar'), CS('50 ' + SquareCS)];
  Result.Strings := ['square'];
  Result.Charset := [391];
  Result.EncodingCodes := [65];
  Result.NominalWidthX := 500;
  Result.DefaultWidthX := 300;
end;

function CIDBuild: TCFFBuild;
begin
  Result := Default(TCFFBuild);
  Result.CID := True;
  Result.Strings := ['Adobe', 'Identity'];
  Result.Glyphs := [CS('endchar'), CS('50 0 0 rmoveto 10 hlineto endchar'),
    CS('50 0 0 rmoveto -107 callsubr endchar')];
  Result.Charset := [100, 200];
  Result.FDNominal := [100, 1000];
  SetLength(Result.FDSubrs, 2);
  Result.FDSubrs[1] := [CS('20 vlineto return')];
  // Format 3: 2 ranges (gid 0.. -> FD 0, gid 2.. -> FD 1), sentinel 3.
  Result.FDSelect := [3, 0, 2, 0, 0, 0, 0, 2, 1, 0, 3];
end;

function NewFont(const B: TCFFBuild): TPdfCFFFont;
begin
  Result := TPdfCFFFont.Create(BuildCFF(B));
end;

function Outline(F: TPdfCFFFont; GID: Integer): TPdfGlyphOutline;
begin
  Assert.IsTrue(F.GetOutline(GID, Result), 'GetOutline ' + IntToStr(GID));
end;

procedure CheckPoint(const O: TPdfGlyphOutline; I: Integer; Kind: TPdfOutlineKind; X, Y: Single);
var
  C: TPdfOutlineCmd;
  PX, PY: Single;
begin
  Assert.IsTrue(I < O.Count, Format('command %d missing (count %d)', [I, O.Count]));
  C := O.Cmds[I];
  Assert.AreEqual(Ord(Kind), Ord(C.Kind), Format('kind of command %d', [I]));
  case Kind of
    glMove, glLine:
      begin
        PX := C.X1;
        PY := C.Y1;
      end;
    glQuad:
      begin
        PX := C.X2;
        PY := C.Y2;
      end;
    glCubic:
      begin
        PX := C.X3;
        PY := C.Y3;
      end;
  else
    Exit;
  end;
  Assert.AreEqual(Double(X), Double(PX), 1E-3, Format('x of command %d', [I]));
  Assert.AreEqual(Double(Y), Double(PY), 1E-3, Format('y of command %d', [I]));
end;

procedure CheckSquare(const O: TPdfGlyphOutline);
begin
  Assert.AreEqual(5, O.Count, 'square command count');
  CheckPoint(O, 0, glMove, 100, 100);
  CheckPoint(O, 1, glLine, 300, 100);
  CheckPoint(O, 2, glLine, 300, 300);
  CheckPoint(O, 3, glLine, 100, 300);
  CheckPoint(O, 4, glClose, 0, 0);
end;

/// <summary>Constructs (EPdfFontError allowed) and touches every glyph and lookup; any other exception fails.</summary>
procedure Exercise(const Data: TBytes; const What: string);
var
  F: TPdfCFFFont;
  O: TPdfGlyphOutline;
  G: Integer;
begin
  try
    F := TPdfCFFFont.Create(Data);
  except
    on EPdfFontError do
      Exit;
    on E: Exception do
    begin
      Assert.Fail(What + ': constructor raised ' + E.ClassName + ': ' + E.Message);
      Exit;
    end;
  end;
  try
    try
      for G := -1 to Min(F.GlyphCount, 2000) do
      begin
        F.GetOutline(G, O);
        F.GetAdvance(G);
        F.GlyphName(G);
        F.GlyphCID(G);
      end;
      for G := 0 to 255 do
        F.GlyphByCode(G);
      F.GlyphByName('A');
      F.GlyphByCID(1);
      F.FontMatrix;
      F.OutlineCount;
    except
      on E: Exception do
        Assert.Fail(What + ': ' + E.ClassName + ': ' + E.Message);
    end;
  finally
    F.Free;
  end;
end;

{ ---- Tests --------------------------------------------------------------- }

procedure TPdfCFFTests.StandardStrings;
begin
  Assert.AreEqual('.notdef', PdfCFFStandardStrings[0]);
  Assert.AreEqual('space', PdfCFFStandardStrings[1]);
  Assert.AreEqual('A', PdfCFFStandardStrings[34]);
  Assert.AreEqual('zcaron', PdfCFFStandardStrings[228]);
  Assert.AreEqual('exclamsmall', PdfCFFStandardStrings[229]);
  Assert.AreEqual('Semibold', PdfCFFStandardStrings[390]);
end;

procedure TPdfCFFTests.IsCFFDetection;
begin
  Assert.IsTrue(TPdfCFFFont.IsCFF(BuildCFF(SimpleBuild)));
  Assert.IsFalse(TPdfCFFFont.IsCFF(TBytes.Create(0, 1, 0, 0)));
  Assert.IsFalse(TPdfCFFFont.IsCFF(TBytes.Create(1, 0)));
  Assert.IsFalse(TPdfCFFFont.IsCFF(nil));
end;

procedure TPdfCFFTests.SimpleFont_Lookups;
var
  F: TPdfCFFFont;
begin
  F := NewFont(SimpleBuild);
  try
    Assert.AreEqual('Test', F.FontName);
    Assert.AreEqual(2, F.GlyphCount);
    Assert.AreEqual(2, F.CharstringType);
    Assert.IsFalse(F.IsCIDKeyed);
    Assert.IsTrue(F.HasGlyphNames);
    Assert.IsTrue(F.HasCodeMap);
    Assert.AreEqual(1, F.GlyphByName('square'));
    Assert.AreEqual(0, F.GlyphByName('.notdef'));
    Assert.AreEqual(-1, F.GlyphByName('circle'));
    Assert.AreEqual('square', F.GlyphName(1));
    Assert.AreEqual('.notdef', F.GlyphName(0));
    Assert.AreEqual('', F.GlyphName(7));
    Assert.AreEqual(-1, F.GlyphCID(1));
    Assert.AreEqual(1, F.GlyphByCode(65));
    Assert.AreEqual(-1, F.GlyphByCode(66));
    Assert.AreEqual(-1, F.GlyphByCode(300));
    Assert.AreEqual(1, F.GlyphByCID(1), 'non-CID: base behaviour');
    Assert.AreEqual(-1, F.GlyphByCID(2));
    Assert.AreEqual(1, F.OutlineCount);
    Assert.AreEqual(0.001, F.FontMatrix.A, 1E-12);
    Assert.AreEqual(0.0, F.FontMatrix.B, 1E-12);
    Assert.AreEqual(0.001, F.FontMatrix.D, 1E-12);
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.SimpleFont_Outline;
var
  F: TPdfCFFFont;
  O: TPdfGlyphOutline;
begin
  F := NewFont(SimpleBuild);
  try
    O := Outline(F, 1);
    CheckSquare(O);
    Assert.AreEqual(550.0, Double(O.Advance), 1E-6);
    O := Outline(F, 0);
    Assert.AreEqual(0, O.Count, '.notdef is empty');
    Assert.AreEqual(300.0, Double(O.Advance), 1E-6);
    Assert.IsFalse(F.GetOutline(2, O));
    Assert.IsFalse(F.GetOutline(-1, O));
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.SimpleFont_Advance;
var
  F: TPdfCFFFont;
begin
  F := NewFont(SimpleBuild);
  try
    Assert.AreEqual(550.0, Double(F.GetAdvance(1)), 1E-6, 'nominalWidthX + width');
    Assert.AreEqual(550.0, Double(F.GetAdvance(1)), 1E-6, 'cached');
    Assert.AreEqual(300.0, Double(F.GetAdvance(0)), 1E-6, 'defaultWidthX');
    Assert.AreEqual(-1.0, Double(F.GetAdvance(5)), 1E-6);
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.StandardEncodingAndCharsetFormat1;
var
  B: TCFFBuild;
  F: TPdfCFFFont;
begin
  B := Default(TCFFBuild);
  // gid 1..3 = SIDs 34..36 (A B C) through one format-1 range.
  B.Glyphs := [CS('endchar'), CS(SquareCS), CS(SquareCS), CS(SquareCS)];
  B.RawCharset := [1, 0, 34, 2];
  F := NewFont(B);
  try
    Assert.AreEqual(1, F.GlyphByName('A'));
    Assert.AreEqual(3, F.GlyphByName('C'));
    Assert.AreEqual('B', F.GlyphName(2));
    Assert.AreEqual(1, F.GlyphByCode(65), 'StandardEncoding A');
    Assert.AreEqual(3, F.GlyphByCode(67), 'StandardEncoding C');
    Assert.AreEqual(-1, F.GlyphByCode(68));
    Assert.AreEqual(0.0, Double(F.GetAdvance(1)), 1E-6, 'no width, defaultWidthX 0');
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.Subroutines;
var
  B: TCFFBuild;
  F: TPdfCFFFont;
begin
  B := SimpleBuild;
  B.Glyphs := [CS('endchar'), CS('100 100 rmoveto -107 callsubr -107 callgsubr -200 hlineto endchar')];
  B.Subrs := [CS('200 hlineto return')];
  B.GSubrs := [CS('200 vlineto return')];
  F := NewFont(B);
  try
    CheckSquare(Outline(F, 1));
    Assert.AreEqual(300.0, Double(F.GetAdvance(1)), 1E-6, 'no width operand');
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.HintMask_SkipsMaskBytes;
var
  B: TCFFBuild;
  F: TPdfCFFFont;
begin
  // Width 77 + 4 hstems, then 5 implicit vstems before hintmask: 9 stems -> 2 mask bytes.
  // The second mask byte is $0E (endchar) so a wrong byte count ends the glyph early.
  B := SimpleBuild;
  B.Glyphs := [CS('endchar'),
    CS('77 0 10 20 10 40 10 60 10 hstemhm 0 10 20 10 30 10 40 10 50 10 hintmask xFF x0E ' +
       '100 100 rmoveto 200 hlineto cntrmask xFF x0E 200 vlineto -200 hlineto endchar')];
  F := NewFont(B);
  try
    CheckSquare(Outline(F, 1));
    Assert.AreEqual(577.0, Double(F.GetAdvance(1)), 1E-6);
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.Curves_RRAndHV;
var
  B: TCFFBuild;
  F: TPdfCFFFont;
  O: TPdfGlyphOutline;
begin
  B := SimpleBuild;
  B.Glyphs := [CS('endchar'),
    CS('0 0 rmoveto 10 20 30 40 50 60 rrcurveto 10 20 30 40 hvcurveto 10 20 30 40 5 vhcurveto endchar')];
  F := NewFont(B);
  try
    O := Outline(F, 1);
    Assert.AreEqual(5, O.Count);
    CheckPoint(O, 0, glMove, 0, 0);
    CheckPoint(O, 1, glCubic, 90, 120);
    Assert.AreEqual(10.0, Double(O.Cmds[1].X1), 1E-6);
    Assert.AreEqual(20.0, Double(O.Cmds[1].Y1), 1E-6);
    Assert.AreEqual(40.0, Double(O.Cmds[1].X2), 1E-6);
    Assert.AreEqual(60.0, Double(O.Cmds[1].Y2), 1E-6);
    CheckPoint(O, 2, glCubic, 120, 190);
    Assert.AreEqual(100.0, Double(O.Cmds[2].X1), 1E-6);
    Assert.AreEqual(120.0, Double(O.Cmds[2].Y1), 1E-6);
    CheckPoint(O, 3, glCubic, 180, 235);
    Assert.AreEqual(120.0, Double(O.Cmds[3].X1), 1E-6);
    Assert.AreEqual(200.0, Double(O.Cmds[3].Y1), 1E-6);
    CheckPoint(O, 4, glClose, 0, 0);
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.Curves_HHVVAndMixed;
var
  B: TCFFBuild;
  F: TPdfCFFFont;
  O: TPdfGlyphOutline;
begin
  B := SimpleBuild;
  B.Glyphs := [CS('endchar'),
    CS('0 0 rmoveto 5 10 20 30 40 hhcurveto 6 10 20 30 40 vvcurveto 1 2 3 4 5 6 7 8 rcurveline ' +
       '1 1 1 2 3 4 5 6 rlinecurve 10 20 rlineto 0 0 rmoveto 5 vlineto endchar')];
  F := NewFont(B);
  try
    O := Outline(F, 1);
    CheckPoint(O, 0, glMove, 0, 0);
    CheckPoint(O, 1, glCubic, 70, 35);
    Assert.AreEqual(5.0, Double(O.Cmds[1].Y1), 1E-6, 'hhcurveto dy1');
    CheckPoint(O, 2, glCubic, 96, 115);
    Assert.AreEqual(76.0, Double(O.Cmds[2].X1), 1E-6, 'vvcurveto dx1');
    CheckPoint(O, 3, glCubic, 105, 127);
    CheckPoint(O, 4, glLine, 112, 135);
    CheckPoint(O, 5, glLine, 113, 136);
    CheckPoint(O, 6, glCubic, 122, 148);
    CheckPoint(O, 7, glLine, 132, 168);
    CheckPoint(O, 8, glClose, 0, 0);
    CheckPoint(O, 9, glMove, 132, 168);
    CheckPoint(O, 10, glLine, 132, 173);
    CheckPoint(O, 11, glClose, 0, 0);
    Assert.AreEqual(12, O.Count);
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.Flex;
var
  B: TCFFBuild;
  F: TPdfCFFFont;
  O: TPdfGlyphOutline;
begin
  B := SimpleBuild;
  B.Glyphs := [CS('endchar'),
    CS('0 0 rmoveto 10 0 20 10 30 0 30 0 20 -10 10 0 50 flex 10 20 10 30 40 10 20 hflex endchar')];
  F := NewFont(B);
  try
    O := Outline(F, 1);
    Assert.AreEqual(6, O.Count);
    CheckPoint(O, 1, glCubic, 60, 10);
    Assert.AreEqual(30.0, Double(O.Cmds[1].X2), 1E-6);
    Assert.AreEqual(10.0, Double(O.Cmds[1].Y2), 1E-6);
    CheckPoint(O, 2, glCubic, 120, 0);
    Assert.AreEqual(90.0, Double(O.Cmds[2].X1), 1E-6);
    // hflex from (120, 0): c1 (130, 0) c2 (150, 10) p (180, 10); c3 (220, 10) c4 (230, 0) end (250, 0)
    CheckPoint(O, 3, glCubic, 180, 10);
    Assert.AreEqual(130.0, Double(O.Cmds[3].X1), 1E-6);
    Assert.AreEqual(0.0, Double(O.Cmds[3].Y1), 1E-6);
    CheckPoint(O, 4, glCubic, 250, 0);
    Assert.AreEqual(230.0, Double(O.Cmds[4].X2), 1E-6);
    Assert.AreEqual(0.0, Double(O.Cmds[4].Y2), 1E-6);
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.Arithmetic_Div;
var
  B: TCFFBuild;
  F: TPdfCFFFont;
  O: TPdfGlyphOutline;
begin
  B := SimpleBuild;
  B.Glyphs := [CS('endchar'), CS('0 0 rmoveto 300 2 div hlineto 7 0 div vlineto f2.5 f0.25 add hlineto endchar')];
  F := NewFont(B);
  try
    O := Outline(F, 1);
    CheckPoint(O, 1, glLine, 150, 0);
    CheckPoint(O, 2, glLine, 150, 0);
    CheckPoint(O, 3, glLine, 152.75, 0);
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.Seac;
var
  B: TCFFBuild;
  F: TPdfCFFFont;
  O: TPdfGlyphOutline;
begin
  B := Default(TCFFBuild);
  B.Glyphs := [CS('endchar'),
    CS('0 0 rmoveto 100 0 rlineto 0 100 rlineto endchar'),        // A
    CS('10 10 rmoveto 20 0 rlineto endchar'),                     // acute
    CS('400 150 300 65 194 endchar')];                            // Aacute = seac(A, acute)
  B.Charset := [StdSID('A'), StdSID('acute'), StdSID('Aacute')];
  B.NominalWidthX := 100;
  F := NewFont(B);
  try
    Assert.AreEqual(3, F.GlyphByName('Aacute'));
    Assert.AreEqual(2, F.GlyphByCode(194), 'StandardEncoding acute');
    O := Outline(F, 3);
    Assert.AreEqual(7, O.Count);
    CheckPoint(O, 0, glMove, 0, 0);
    CheckPoint(O, 1, glLine, 100, 0);
    CheckPoint(O, 2, glLine, 100, 100);
    CheckPoint(O, 3, glClose, 0, 0);
    CheckPoint(O, 4, glMove, 160, 310);
    CheckPoint(O, 5, glLine, 180, 310);
    CheckPoint(O, 6, glClose, 0, 0);
    Assert.AreEqual(500.0, Double(O.Advance), 1E-6);
    Assert.AreEqual(500.0, Double(F.GetAdvance(3)), 1E-6);
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.CIDKeyed;
var
  F: TPdfCFFFont;
  O: TPdfGlyphOutline;
begin
  F := NewFont(CIDBuild);
  try
    Assert.IsTrue(F.IsCIDKeyed);
    Assert.IsFalse(F.HasGlyphNames);
    Assert.IsFalse(F.HasCodeMap);
    Assert.AreEqual(3, F.GlyphCount);
    Assert.AreEqual(1, F.GlyphByCID(100));
    Assert.AreEqual(2, F.GlyphByCID(200));
    Assert.AreEqual(0, F.GlyphByCID(0));
    Assert.AreEqual(-1, F.GlyphByCID(1));
    Assert.AreEqual(100, F.GlyphCID(1));
    Assert.AreEqual(200, F.GlyphCID(2));
    Assert.AreEqual(-1, F.GlyphCID(3));
    Assert.AreEqual('', F.GlyphName(1));
    Assert.AreEqual(-1, F.GlyphByName('Adobe'));
    Assert.AreEqual(-1, F.GlyphByCode(65));
    Assert.AreEqual(150.0, Double(F.GetAdvance(1)), 1E-6, 'FD 0 nominalWidthX');
    Assert.AreEqual(1050.0, Double(F.GetAdvance(2)), 1E-6, 'FD 1 nominalWidthX');
    O := Outline(F, 2);
    Assert.AreEqual(3, O.Count, 'local subr of FD 1');
    CheckPoint(O, 1, glLine, 0, 20);
    Assert.AreEqual(1050.0, Double(O.Advance), 1E-6);
    Assert.AreEqual(0.001, F.FontMatrix.A, 1E-12);
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.CIDKeyed_FontMatrix;
var
  B: TCFFBuild;
  F: TPdfCFFFont;
  O: TPdfGlyphOutline;
begin
  B := CIDBuild;
  B.TopMatrix := [140, 139, 139, 140, 139, 139];                        // [1 0 0 1 0 0]
  SetLength(B.FDMatrix, 2);
  B.FDMatrix[0] := [30, $1C, $3F, 139, 139, 30, $1C, $3F, 139, 139];    // [0.001 0 0 0.001 0 0]
  B.FDMatrix[1] := [30, $2C, $3F, 139, 139, 30, $2C, $3F, 139, 139];    // [0.002 0 0 0.002 0 0]
  F := NewFont(B);
  try
    Assert.AreEqual(0.001, F.FontMatrix.A, 1E-12, 'FD 0 matrix x Top matrix');
    Assert.AreEqual(0.001, F.FontMatrix.D, 1E-12);
    O := Outline(F, 2);
    CheckPoint(O, 1, glLine, 0, 40); // FD 1 glyphs are twice as large relative to FontMatrix
    Assert.AreEqual(2100.0, Double(O.Advance), 1E-6);
    Assert.AreEqual(2100.0, Double(F.GetAdvance(2)), 1E-6);
    O := Outline(F, 1);
    CheckPoint(O, 1, glLine, 10, 0);
  finally
    F.Free;
  end;
  // No Top DICT matrix: the FD matrix alone.
  B.TopMatrix := nil;
  F := NewFont(B);
  try
    Assert.AreEqual(0.001, F.FontMatrix.A, 1E-12);
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.RealOperands_FontMatrix;
var
  B: TCFFBuild;
  F: TPdfCFFFont;
begin
  B := SimpleBuild;
  // [0.0005 0 0 -2.25 150 0]: 5E-4, 0, 0, -2.25, 1.5E2, 0
  B.TopMatrix := [30, $5C, $4F, 139, 139, 30, $E2, $A2, $5F, 30, $1A, $5B, $2F, 139];
  F := NewFont(B);
  try
    Assert.AreEqual(0.0005, F.FontMatrix.A, 1E-12);
    Assert.AreEqual(-2.25, F.FontMatrix.D, 1E-12);
    Assert.AreEqual(150.0, F.FontMatrix.E, 1E-9);
    Assert.AreEqual(1, F.GlyphByName('square'), 'DICT after real operands still parsed');
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.Robust_TruncatedAfterHeader;
var
  Data: TBytes;
  F: TPdfCFFFont;
begin
  Data := Copy(BuildCFF(SimpleBuild), 0, 4);
  F := nil;
  try
    try
      F := TPdfCFFFont.Create(Data);
      Assert.AreEqual(0, F.GlyphCount, 'usable font must have no glyphs');
    except
      on E: EPdfFontError do
        Assert.Pass('EPdfFontError: ' + E.Message);
    end;
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.Robust_EveryTruncation;
var
  Full: TBytes;
  N: Integer;
begin
  Full := BuildCFF(CIDBuild);
  for N := 0 to Length(Full) - 1 do
    Exercise(Copy(Full, 0, N), 'CID truncated at ' + IntToStr(N));
  Full := BuildCFF(SimpleBuild);
  for N := 0 to Length(Full) - 1 do
    Exercise(Copy(Full, 0, N), 'simple truncated at ' + IntToStr(N));
  Assert.Pass;
end;

procedure TPdfCFFTests.Robust_RandomBytes;
var
  Data: TBytes;
  I, J, Raised: Integer;
begin
  RandSeed := 20261023;
  Raised := 0;
  for I := 1 to 200 do
  begin
    SetLength(Data, 1 + Random(600));
    for J := 0 to High(Data) do
      Data[J] := Random(256);
    if Data[0] = 1 then
      Data[0] := 2;
    try
      TPdfCFFFont.Create(Data).Free;
      Assert.Fail('random bytes accepted');
    except
      on EPdfFontError do
        Inc(Raised);
    end;
    // With a valid header in front: EPdfFontError or a usable font, nothing else.
    Data[0] := 1;
    if Length(Data) > 2 then
      Data[2] := 4;
    Exercise(Data, 'random ' + IntToStr(I));
  end;
  Assert.AreEqual(200, Raised);
end;

procedure TPdfCFFTests.Robust_SubrOutOfRange;
var
  B: TCFFBuild;
  F: TPdfCFFFont;
  O: TPdfGlyphOutline;
begin
  B := SimpleBuild;
  B.Glyphs := [CS('endchar'), CS('100 100 rmoveto 200 hlineto 5 callsubr 200 vlineto endchar'),
    CS('100 100 rmoveto 200 hlineto 30000 callgsubr endchar')];
  B.Charset := [391, 392];
  B.Strings := ['square', 'other'];
  F := NewFont(B);
  try
    Assert.IsTrue(F.GetOutline(1, O));
    Assert.AreEqual(3, O.Count, 'move + line + close');
    CheckPoint(O, 1, glLine, 300, 100);
    Assert.IsTrue(F.GetOutline(2, O));
    Assert.AreEqual(3, O.Count);
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.Robust_RecursiveSubr;
var
  B: TCFFBuild;
  F: TPdfCFFFont;
  O: TPdfGlyphOutline;
begin
  B := SimpleBuild;
  // Subr 0 draws a line and calls itself: the nesting limit stops it.
  B.Glyphs := [CS('endchar'), CS('0 0 rmoveto -107 callsubr endchar')];
  B.Subrs := [CS('1 hlineto -107 callsubr return')];
  F := NewFont(B);
  try
    Assert.IsTrue(F.GetOutline(1, O));
    Assert.IsTrue((O.Count > 2) and (O.Count < 20), 'bounded by the nesting limit: ' + IntToStr(O.Count));
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.Robust_CharStringsBeyondData;
var
  B: TCFFBuild;
  F: TPdfCFFFont;
  O: TPdfGlyphOutline;
begin
  B := SimpleBuild;
  B.CharStringsOffset := 100000;
  F := NewFont(B);
  try
    Assert.AreEqual(0, F.GlyphCount);
    Assert.IsFalse(F.GetOutline(0, O));
    Assert.AreEqual(-1, F.GlyphByName('square'));
    Assert.AreEqual(-1, F.GlyphByCode(65));
  finally
    F.Free;
  end;
end;

procedure TPdfCFFTests.Robust_Mutations;
var
  Bases: array[0..2] of TBytes;
  Data: TBytes;
  B: TCFFBuild;
  I, K, N: Integer;
begin
  Bases[0] := BuildCFF(SimpleBuild);
  Bases[1] := BuildCFF(CIDBuild);
  B := SimpleBuild;
  B.Glyphs := [CS('endchar'),
    CS('77 0 10 20 10 hstemhm 0 10 hintmask xC0 100 100 rmoveto -107 callsubr -107 callgsubr ' +
       '10 20 30 40 50 60 rrcurveto 10 20 30 40 5 vhcurveto 0 0 rmoveto 10 0 20 10 30 0 30 0 20 -10 10 0 50 flex ' +
       '300 2 div hlineto endchar')];
  B.Subrs := [CS('200 hlineto return')];
  B.GSubrs := [CS('200 vlineto return')];
  Bases[2] := BuildCFF(B);
  RandSeed := 4711;
  for I := 1 to 3000 do
  begin
    Data := Copy(Bases[I mod 3]);
    N := 1 + Random(4);
    for K := 1 to N do
      Data[Random(Length(Data))] := Random(256);
    Exercise(Data, 'mutation ' + IntToStr(I));
  end;
  Assert.Pass;
end;

{ ---- Corpus -------------------------------------------------------------- }

/// <summary>Extracts the 'CFF ' table of an sfnt (OpenType) font program; nil when absent.</summary>
function ExtractCFFTable(const Data: TBytes): TBytes;
var
  NumTables, I, P: Integer;
  Off, Len: Int64;
begin
  Result := nil;
  if Length(Data) < 12 then
    Exit;
  NumTables := (Data[4] shl 8) or Data[5];
  for I := 0 to NumTables - 1 do
  begin
    P := 12 + I * 16;
    if P + 16 > Length(Data) then
      Exit;
    if (Data[P] = Ord('C')) and (Data[P + 1] = Ord('F')) and (Data[P + 2] = Ord('F')) and (Data[P + 3] = Ord(' ')) then
    begin
      Off := (Int64(Data[P + 8]) shl 24) or (Data[P + 9] shl 16) or (Data[P + 10] shl 8) or Data[P + 11];
      Len := (Int64(Data[P + 12]) shl 24) or (Data[P + 13] shl 16) or (Data[P + 14] shl 8) or Data[P + 15];
      if (Off >= 0) and (Off + Len <= Length(Data)) then
        Result := Copy(Data, Integer(Off), Integer(Len));
      Exit;
    end;
  end;
end;

function CorpusFiles: TArray<string>;
var
  Dirs, Files: TList<string>;
  Dir: string;
begin
  Dirs := TList<string>.Create;
  Files := TList<string>.Create;
  try
    Dirs.Add(TPath.GetFullPath(TPath.Combine(ExtractFilePath(ParamStr(0)), '..\..\Tests\Corpus')));
    for Dir in GetEnvironmentVariable('PDF_CORPUS_DIRS').Split([';']) do
      if Trim(Dir) <> '' then
        Dirs.Add(Trim(Dir));
    for Dir in Dirs do
      if TDirectory.Exists(Dir) then
        Files.AddRange(TDirectory.GetFiles(Dir, '*.pdf', TSearchOption.soAllDirectories));
    Files.Sort;
    Result := Files.ToArray;
  finally
    Files.Free;
    Dirs.Free;
  end;
end;

procedure TPdfCFFTests.Corpus_EmbeddedPrograms;
const
  MinPrograms = 60;
  MinCID = 5;
  MaxSeconds = 240;
var
  Files: TArray<string>;
  FileName, Key, Sub, Summary: string;
  Doc: TPdfDocument;
  Fonts, FontDict, Desc: IPdfDictionary;
  Desc0: IPdfArray;
  Stream: IPdfStream;
  Seen: TList<Integer>;
  Data: TBytes;
  F: TPdfCFFFont;
  O: TPdfGlyphOutline;
  PageNo, G, Programs, CIDPrograms, OTPrograms, Rejected, Glyphs, NonEmpty, Empty, FilesWithCFF: Integer;
  Failures: TStringList;
  SW: TStopwatch;
  HadCFF: Boolean;
begin
  Files := CorpusFiles;
  if Length(Files) = 0 then
  begin
    Assert.Pass('No corpus files (set PDF_CORPUS_DIRS)');
    Exit;
  end;
  Programs := 0;
  CIDPrograms := 0;
  OTPrograms := 0;
  Rejected := 0;
  Glyphs := 0;
  NonEmpty := 0;
  Empty := 0;
  FilesWithCFF := 0;
  Failures := TStringList.Create;
  Seen := TList<Integer>.Create;
  SW := TStopwatch.StartNew;
  try
    for FileName in Files do
    begin
      if ((Programs >= MinPrograms) and (CIDPrograms >= MinCID) and (OTPrograms >= 1)) or
        (SW.Elapsed.TotalSeconds > MaxSeconds) then
        Break;
      HadCFF := False;
      Doc := TPdfDocument.Create;
      try
        try
          Doc.LoadFromFile(FileName);
          Seen.Clear;
          for PageNo := 0 to Min(Doc.PageCount, 5) - 1 do
          begin
            Fonts := Doc.Pages[PageNo].Resources.GetDictionary('Font');
            if Fonts = nil then
              Continue;
            for Key in Fonts.Keys do
            begin
              FontDict := Fonts.GetDictionary(Key);
              if FontDict = nil then
                Continue;
              if FontDict.GetName('Subtype') = 'Type0' then
              begin
                Desc0 := FontDict.GetArray('DescendantFonts');
                if (Desc0 = nil) or (Desc0.Count = 0) then
                  Continue;
                FontDict := Desc0.GetDictionary(0);
                if FontDict = nil then
                  Continue;
              end;
              Desc := FontDict.GetDictionary('FontDescriptor');
              if Desc = nil then
                Continue;
              Stream := Desc.GetStream('FontFile3');
              if (Stream = nil) or Seen.Contains(Stream.ObjNum) then
                Continue;
              Seen.Add(Stream.ObjNum);
              Sub := Stream.Dict.GetName('Subtype');
              Data := Stream.GetDecodedData;
              if Sub = 'OpenType' then
              begin
                Data := ExtractCFFTable(Data);
                if Data = nil then
                  Continue;
                Inc(OTPrograms);
              end
              else if (Sub <> 'Type1C') and (Sub <> 'CIDFontType0C') then
                Continue;
              HadCFF := True;
              Inc(Programs);
              try
                F := TPdfCFFFont.Create(Data);
              except
                on EPdfFontError do
                begin
                  Inc(Rejected);
                  Continue;
                end;
                on E: Exception do
                begin
                  Failures.Add(Format('%s %s: constructor %s: %s', [ExtractFileName(FileName), Key, E.ClassName,
                    E.Message]));
                  Continue;
                end;
              end;
              try
                if F.IsCIDKeyed then
                  Inc(CIDPrograms);
                for G := 0 to F.GlyphCount - 1 do
                begin
                  try
                    F.GetOutline(G, O);
                    F.GetAdvance(G);
                  except
                    on E: Exception do
                    begin
                      Failures.Add(Format('%s %s gid %d: %s: %s', [ExtractFileName(FileName), Key, G, E.ClassName,
                        E.Message]));
                      Break;
                    end;
                  end;
                  Inc(Glyphs);
                  if not O.IsEmpty then
                    Inc(NonEmpty)
                  else
                    Inc(Empty); // includes legitimately empty glyphs (space, .notdef)
                end;
              finally
                F.Free;
              end;
            end;
          end;
        except
          on Exception do
            ; // documents the core cannot open are not this fixture's concern
        end;
      finally
        Doc.Free;
      end;
      if HadCFF then
        Inc(FilesWithCFF);
    end;
    Summary := Format('CFF corpus: %d programs (%d CID-keyed, %d OpenType) from %d files, %d rejected with ' +
      'EPdfFontError; %d glyphs, %d non-empty outlines, %d empty; %.1f s',
      [Programs, CIDPrograms, OTPrograms, FilesWithCFF, Rejected, Glyphs, NonEmpty, Empty, SW.Elapsed.TotalSeconds]);
    TDUnitX.CurrentRunner.Log(TLogLevel.Information, Summary);
    if Failures.Count > 0 then
      Assert.Fail(Failures.Count.ToString + ' failures:'#13#10 + Failures.Text);
    if Programs = 0 then
      Assert.Pass('No FontFile3 programs in the corpus');
    Assert.IsTrue(NonEmpty > 0, 'some glyphs must have outlines');
    Assert.Pass(Summary);
  finally
    Seen.Free;
    Failures.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfCFFTests);

end.
