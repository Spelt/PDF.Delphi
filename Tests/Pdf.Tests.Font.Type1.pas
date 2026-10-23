{*******************************************************************************
  Pdf.Tests.Font.Type1
  DUnitX fixture for Pdf.Font.Type1.

  The synthetic fonts are produced here by a tiny Type 1 *writer*: a charstring
  encoder (numbers + operator names), charstring encryption (r = 4330, lenIV
  bytes prefixed), a private part with Subrs (incl. the standard flex and hint
  replacement Subrs 0-3) and CharStrings, eexec encryption (r = 55665) and the
  three containers (binary as in a PDF /FontFile, PFA hex, PFB segments).

  Note: Resources/Fonts/Foxit*.pfb are, despite their extension, bare CFF
  programs (header 01 00 04 02, no eexec); they belong to Pdf.Font.CFF and are
  only checked here to be rejected cleanly.
*******************************************************************************}
unit Pdf.Tests.Font.Type1;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections, DUnitX.TestFramework,
  Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Document, Pdf.Font.Glyphs, Pdf.Font.Type1, Pdf.Tests.Builder;

type
  [TestFixture]
  TPdfType1Tests = class
  public
    [Test] procedure Detection;
    [Test] procedure Synthetic_HeaderAndCustomEncoding;
    [Test] procedure Synthetic_SquareOutline;
    [Test] procedure Synthetic_CallSubr;
    [Test] procedure Synthetic_CurveOperators;
    [Test] procedure Synthetic_Seac;
    [Test] procedure Synthetic_FlexAndHintReplacement;
    [Test] procedure Synthetic_StandardEncoding;
    [Test] procedure Synthetic_PfaHexForm;
    [Test] procedure Synthetic_PfbSegmentForm;
    [Test] procedure Synthetic_UnencryptedCharStrings;
    [Test] procedure CorruptCharStrings;
    [Test] procedure TruncatedPrograms;
    [Test] procedure NoCharStringsRaises;
    [Test] procedure FoxitFontsAreCFF;
    [Test] procedure CorpusSweep;
  end;

implementation

type
  TFontForm = (ffBinary, ffPfa, ffPfb);

const
  SquareCS = '50 500 hsbw 100 100 rmoveto 200 hlineto 200 vlineto closepath endchar';

  // Standard Subrs 0-3 (flex and hint replacement), Subrs 4 used by callsubr, 5 a hint subr.
  StdSubrs: array[0..5] of string = (
    '3 0 callothersubr pop pop setcurrentpoint return',
    '0 1 callothersubr return',
    '0 2 callothersubr return',
    'return',
    '100 0 rlineto 0 100 rlineto return',
    '0 50 hstem return');

  MainGlyphs: array[0..7] of string = (
    '.notdef=0 250 hsbw endchar',
    'square=' + SquareCS,
    'A=' + SquareCS,
    'acute=20 300 hsbw 10 0 rmoveto 40 hlineto 40 vlineto closepath endchar',
    'subrglyph=0 400 hsbw 50 50 rmoveto 4 callsubr closepath endchar',
    'seacglyph=50 600 hsbw 20 100 300 65 194 seac',
    'flexglyph=0 500 hsbw 100 100 rmoveto 5 1 3 callothersubr pop callsubr 1 callsubr ' +
      '100 0 rmoveto 2 callsubr -50 30 rmoveto 2 callsubr 30 hmoveto 2 callsubr 20 0 rmoveto 2 callsubr ' +
      '20 0 rmoveto 2 callsubr 30 0 rmoveto 2 callsubr 50 -30 rmoveto 2 callsubr 50 300 100 0 callsubr ' +
      'closepath endchar',
    'curves=10 20 600 0 sbw 0 10 hstem 100 vmoveto 30 40 50 60 hvcurveto dotsection 10 20 30 40 vhcurveto ' +
      '1 2 3 4 5 6 rrcurveto 600 3 div 0 rlineto closepath endchar');

{ ---------------------------------------------------------------------------- }
{ Type 1 writer                                                                }
{ ---------------------------------------------------------------------------- }

function Cat(const A, B: TBytes): TBytes;
begin
  Result := PdfConcatBytes(A, B);
end;

/// Encodes 'num num op ...' into a Type 1 charstring; '#n' emits the raw byte n.
function EncodeCharString(const Src: string): TBytes;
const
  Ops: array[0..24] of string = ('hstem=1', 'vstem=3', 'vmoveto=4', 'rlineto=5', 'hlineto=6', 'vlineto=7',
    'rrcurveto=8', 'closepath=9', 'callsubr=10', 'return=11', 'hsbw=13', 'endchar=14', 'rmoveto=21',
    'hmoveto=22', 'vhcurveto=30', 'hvcurveto=31', 'dotsection=12.0', 'vstem3=12.1', 'hstem3=12.2',
    'seac=12.6', 'sbw=12.7', 'div=12.12', 'callothersubr=12.16', 'pop=12.17', 'setcurrentpoint=12.33');
var
  Tok, Op, Code: string;
  V, W, I: Integer;
  Found: Boolean;
  Parts: TArray<string>;
begin
  Result := nil;
  for Tok in Src.Split([' '], TStringSplitOptions.ExcludeEmpty) do
  begin
    if Tok.StartsWith('#') then
      Result := Cat(Result, TBytes.Create(Byte(StrToInt(Tok.Substring(1)))))
    else if TryStrToInt(Tok, V) then
    begin
      if (V >= -107) and (V <= 107) then
        Result := Cat(Result, TBytes.Create(Byte(V + 139)))
      else if (V >= 108) and (V <= 1131) then
      begin
        W := V - 108;
        Result := Cat(Result, TBytes.Create(Byte(W div 256 + 247), Byte(W mod 256)));
      end
      else if (V >= -1131) and (V <= -108) then
      begin
        W := -V - 108;
        Result := Cat(Result, TBytes.Create(Byte(W div 256 + 251), Byte(W mod 256)));
      end
      else
        Result := Cat(Result, TBytes.Create(255, Byte(V shr 24), Byte(V shr 16), Byte(V shr 8), Byte(V)));
    end
    else
    begin
      Found := False;
      for Op in Ops do
        if Op.StartsWith(Tok + '=') then
        begin
          Code := Op.Substring(Length(Tok) + 1);
          Parts := Code.Split(['.']);
          for I := 0 to High(Parts) do
            Result := Cat(Result, TBytes.Create(Byte(StrToInt(Parts[I]))));
          Found := True;
          Break;
        end;
      if not Found then
        raise Exception.Create('Unknown charstring operator ' + Tok);
    end;
  end;
end;

function T1Encrypt(const Plain: TBytes; Key: Word; const Prefix: TBytes): TBytes;
var
  Src: TBytes;
  R: Cardinal;
  I: Integer;
  C: Byte;
begin
  Src := Cat(Prefix, Plain);
  SetLength(Result, Length(Src));
  R := Key;
  for I := 0 to High(Src) do
  begin
    C := Src[I] xor Byte(R shr 8);
    Result[I] := C;
    R := ((Cardinal(C) + R) * Cardinal(52845) + Cardinal(22719)) and $FFFF;
  end;
end;

function IsHexByte(B: Byte): Boolean;
begin
  Result := B in [Ord('0')..Ord('9'), Ord('A')..Ord('F'), Ord('a')..Ord('f')];
end;

/// eexec-encrypts Plain with a prefix whose first cipher byte is neither white space nor a hex digit.
function EexecEncrypt(const Plain: TBytes): TBytes;
var
  I: Integer;
begin
  for I := 0 to 255 do
  begin
    Result := T1Encrypt(Plain, 55665, TBytes.Create(Byte(I), $5A, $A5, $3C));
    if not IsHexByte(Result[0]) and not (Result[0] in [0, 9, 10, 12, 13, 32]) then
      Exit;
  end;
end;

function EncryptCS(const Src: string; LenIV: Integer): TBytes;
begin
  if LenIV < 0 then
    Result := EncodeCharString(Src)
  else
    Result := T1Encrypt(EncodeCharString(Src), 4330, TBytes.Create(0, 0, 0, 0));
end;

function HexLines(const Data: TBytes): string;
var
  SB: TStringBuilder;
  I: Integer;
begin
  SB := TStringBuilder.Create;
  try
    for I := 0 to High(Data) do
    begin
      SB.Append(LowerCase(IntToHex(Data[I], 2)));
      if I mod 32 = 31 then
        SB.Append(#13#10);
    end;
    SB.Append(#13#10);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function Le32(V: Integer): TBytes;
begin
  Result := TBytes.Create(Byte(V), Byte(V shr 8), Byte(V shr 16), Byte(V shr 24));
end;

/// Builds a Type 1 program. Glyphs are 'name=charstring', Subrs are charstring sources (index = position).
function BuildType1(const Glyphs, Subrs: array of string; Form: TFontForm; StandardEnc: Boolean;
  LenIV: Integer = 4): TBytes;
var
  Clear, Priv, Cipher, Trailer: TBytes;
  I, P: Integer;
  Bin: TBytes;
  Name, Src, Zeros, RD, ND, NP: string;
begin
  Clear := BytesOf('%!PS-AdobeFont-1.0: TestT1 001.000'#10'%%Comment: eexe is not eexec'#10 +
    '11 dict begin'#10'/FontInfo 2 dict dup begin'#10'/Notice (Test (c) /Encoding font) readonly def'#10 +
    '/FullName (Test T1) readonly def'#10'end readonly def'#10'/FontName /TestT1 def'#10);
  if StandardEnc then
    Clear := Cat(Clear, BytesOf('/Encoding StandardEncoding def'#10 +
      '/FontMatrix [0.002 0 0 0.002 0 0] readonly def'#10))
  else
    Clear := Cat(Clear, BytesOf('/Encoding 256 array'#10'0 1 255 {1 index exch /.notdef put} for'#10 +
      'dup 67 /flexglyph put'#10'dup 65 /square put'#10'dup 66/seacglyph put'#10'dup 68 /A put'#10 +
      'dup 68 /subrglyph put'#10'dup 300 /A put'#10'dup 69 /curves put'#10'readonly def'#10));
  Clear := Cat(Clear, BytesOf('/PaintType 0 def'#10'/FontType 1 def'#10 +
    '/FontMatrix [0.001 0 0 0.001 0 0] readonly def'#10'/FontBBox {-10 -20 1000 900} readonly def'#10 +
    'currentdict end'#10'currentfile eexec'#13));

  Priv := BytesOf('dup /Private 8 dict dup begin'#10'/RD{string currentfile exch readstring pop}executeonly def'#10 +
    '/ND{noaccess def}executeonly def'#10'/NP{noaccess put}executeonly def'#10 +
    '/lenIV ' + IntToStr(LenIV) + ' def'#10'/MinFeature{16 16} def'#10'/password 5839 def'#10 +
    '/OtherSubrs [ {} {} {} { systemdict /internaldict known not { pop 3 } if } ] noaccess def'#10 +
    '/Subrs ' + IntToStr(Length(Subrs)) + ' array'#10);
  // Subrs in reverse order with the three NP spellings.
  for I := High(Subrs) downto 0 do
  begin
    Bin := EncryptCS(Subrs[I], LenIV);
    case I mod 3 of
      0: begin RD := 'RD'; NP := 'NP'; end;
      1: begin RD := '-|'; NP := '|'; end;
    else
      RD := 'RD';
      NP := 'noaccess put';
    end;
    Priv := Cat(Cat(Cat(Priv, BytesOf(Format('dup %d %d %s ', [I, Length(Bin), RD]))), Bin), BytesOf(' ' + NP + #10));
  end;
  Priv := Cat(Priv, BytesOf('ND'#10'2 index /CharStrings ' + IntToStr(Length(Glyphs)) + ' dict dup begin'#10));
  for I := 0 to High(Glyphs) do
  begin
    P := Pos('=', Glyphs[I], 2);
    Name := Copy(Glyphs[I], 1, P - 1);
    Src := Copy(Glyphs[I], P + 1, MaxInt);
    Bin := EncryptCS(Src, LenIV);
    case I mod 3 of
      0: begin RD := 'RD'; ND := 'ND'; end;
      1: begin RD := '-|'; ND := '|-'; end;
    else
      RD := 'RD';
      ND := 'noaccess def';
    end;
    Priv := Cat(Cat(Cat(Priv, BytesOf(Format('/%s %d %s ', [Name, Length(Bin), RD]))), Bin), BytesOf(' ' + ND + #10));
  end;
  Priv := Cat(Priv, BytesOf('end'#10'end'#10'readonly put'#10'noaccess put'#10 +
    'dup/FontName get exch definefont pop'#10'mark currentfile closefile'#10));
  Cipher := EexecEncrypt(Priv);

  Zeros := '';
  for I := 1 to 8 do
    Zeros := Zeros + StringOfChar('0', 64) + #10;
  Trailer := BytesOf(#10 + Zeros + 'cleartomark'#10);
  case Form of
    ffBinary:
      Result := Cat(Cat(Clear, Cipher), Trailer);
    ffPfa:
      Result := Cat(Cat(Clear, BytesOf(#10 + HexLines(Cipher))), Trailer);
    ffPfb:
      begin
        Result := Cat(Cat(TBytes.Create($80, 1), Le32(Length(Clear))), Clear);
        Result := Cat(Cat(Cat(Result, TBytes.Create($80, 2)), Le32(Length(Cipher))), Cipher);
        Result := Cat(Cat(Cat(Result, TBytes.Create($80, 1)), Le32(Length(Trailer))), Trailer);
        Result := Cat(Result, TBytes.Create($80, 3));
      end;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ Assertion helpers                                                            }
{ ---------------------------------------------------------------------------- }

procedure CheckPoint(const O: TPdfGlyphOutline; Index: Integer; Kind: TPdfOutlineKind; X, Y: Single);
var
  C: TPdfOutlineCmd;
  PX, PY: Single;
begin
  Assert.IsTrue(Index < O.Count, Format('command %d missing (count %d)', [Index, O.Count]));
  C := O.Cmds[Index];
  Assert.AreEqual(Ord(Kind), Ord(C.Kind), Format('kind of command %d', [Index]));
  case Kind of
    glCubic:
      begin
        PX := C.X3;
        PY := C.Y3;
      end;
    glQuad:
      begin
        PX := C.X2;
        PY := C.Y2;
      end;
  else
    PX := C.X1;
    PY := C.Y1;
  end;
  if Kind <> glClose then
  begin
    Assert.AreEqual(Double(X), Double(PX), 0.001, Format('x of command %d', [Index]));
    Assert.AreEqual(Double(Y), Double(PY), 0.001, Format('y of command %d', [Index]));
  end;
end;

procedure CheckCubic(const O: TPdfGlyphOutline; Index: Integer; X1, Y1, X2, Y2, X3, Y3: Single);
var
  C: TPdfOutlineCmd;
begin
  CheckPoint(O, Index, glCubic, X3, Y3);
  C := O.Cmds[Index];
  Assert.AreEqual(Double(X1), Double(C.X1), 0.001, 'c1x');
  Assert.AreEqual(Double(Y1), Double(C.Y1), 0.001, 'c1y');
  Assert.AreEqual(Double(X2), Double(C.X2), 0.001, 'c2x');
  Assert.AreEqual(Double(Y2), Double(C.Y2), 0.001, 'c2y');
end;

function MainFont(Form: TFontForm = ffBinary): TPdfType1Font;
begin
  Result := TPdfType1Font.Create(BuildType1(MainGlyphs, StdSubrs, Form, False));
end;

procedure CheckMainOutlines(F: TPdfType1Font);
var
  O: TPdfGlyphOutline;
begin
  Assert.IsTrue(F.GetOutline(F.GlyphByName('square'), O));
  Assert.AreEqual(5, O.Count);
  CheckPoint(O, 0, glMove, 150, 100);
  CheckPoint(O, 1, glLine, 350, 100);
  CheckPoint(O, 2, glLine, 350, 300);
  CheckPoint(O, 3, glLine, 150, 100);
  CheckPoint(O, 4, glClose, 0, 0);
  Assert.AreEqual(Double(500), Double(F.GetAdvance(F.GlyphByName('square'))), 0.001);
  Assert.IsTrue(F.GetOutline(F.GlyphByName('flexglyph'), O));
  Assert.AreEqual(5, O.Count);
end;

function FontsDir: string;
begin
  Result := TPath.GetFullPath(TPath.Combine(TestDataPath, '..\..\Resources\Fonts'));
end;

{ ---------------------------------------------------------------------------- }
{ Tests                                                                        }
{ ---------------------------------------------------------------------------- }

procedure TPdfType1Tests.Detection;
begin
  Assert.IsTrue(TPdfType1Font.IsType1(BuildType1(MainGlyphs, StdSubrs, ffBinary, False)));
  Assert.IsTrue(TPdfType1Font.IsType1(BuildType1(MainGlyphs, StdSubrs, ffPfa, False)));
  Assert.IsTrue(TPdfType1Font.IsType1(BuildType1(MainGlyphs, StdSubrs, ffPfb, False)));
  Assert.IsTrue(TPdfType1Font.IsType1(BytesOf('%!FontType1-1.0: X')));
  Assert.IsTrue(TPdfType1Font.IsType1(BytesOf('%!PS-AdobeFont-1.0: X')));
  Assert.IsTrue(TPdfType1Font.IsType1(BytesOf('/FontName /X def currentfile eexec ')));
  Assert.IsFalse(TPdfType1Font.IsType1(TBytes.Create(0, 1, 0, 0, 0, 12)));
  Assert.IsFalse(TPdfType1Font.IsType1(TBytes.Create(1, 0, 4, 2)));
  Assert.IsFalse(TPdfType1Font.IsType1(nil));
end;

procedure TPdfType1Tests.Synthetic_HeaderAndCustomEncoding;
var
  F: TPdfType1Font;
  M: TPdfMatrix;
  I: Integer;
begin
  F := MainFont;
  try
    Assert.AreEqual('TestT1', F.FontName);
    Assert.IsFalse(F.HasStandardEncoding);
    Assert.IsTrue(F.HasCodeMap);
    Assert.IsTrue(F.HasGlyphNames);
    M := F.FontMatrix;
    Assert.AreEqual(0.001, M.A, 1E-9);
    Assert.AreEqual(0.001, M.D, 1E-9);
    Assert.AreEqual(0.0, M.B, 1E-9);
    Assert.AreEqual(-10.0, F.FontBBox.X0, 1E-9);
    Assert.AreEqual(-20.0, F.FontBBox.Y0, 1E-9);
    Assert.AreEqual(1000.0, F.FontBBox.X1, 1E-9);
    Assert.AreEqual(900.0, F.FontBBox.Y1, 1E-9);
    Assert.AreEqual(Length(MainGlyphs), F.GlyphCount);
    for I := 0 to High(MainGlyphs) do
      Assert.AreEqual(Copy(MainGlyphs[I], 1, Pos('=', MainGlyphs[I], 2) - 1), F.GlyphName(I));
    Assert.AreEqual('', F.GlyphName(-1));
    Assert.AreEqual('', F.GlyphName(F.GlyphCount));
    Assert.AreEqual(1, F.GlyphByName('square'));
    Assert.AreEqual(-1, F.GlyphByName('nonexistent'));
    Assert.AreEqual(F.GlyphByName('square'), F.GlyphByCode(65));
    Assert.AreEqual(F.GlyphByName('seacglyph'), F.GlyphByCode(66));
    Assert.AreEqual(F.GlyphByName('flexglyph'), F.GlyphByCode(67));
    Assert.AreEqual('subrglyph', F.EncodingName(68), 'same code twice: last wins');
    Assert.AreEqual('square', F.EncodingName(65));
    Assert.AreEqual('', F.EncodingName(32), '.notdef counts as unmapped');
    Assert.AreEqual('', F.EncodingName(300));
    Assert.AreEqual(-1, F.GlyphByCode(32));
    Assert.AreEqual(-1, F.GlyphByCode(-1));
    // .notdef draws nothing; the other 7 glyphs draw.
    Assert.AreEqual(7, F.OutlineCount);
  finally
    F.Free;
  end;
end;

procedure TPdfType1Tests.Synthetic_SquareOutline;
var
  F: TPdfType1Font;
  O: TPdfGlyphOutline;
begin
  F := MainFont;
  try
    CheckMainOutlines(F);
    Assert.IsTrue(F.GetOutline(F.GlyphByCode(65), O));
    Assert.AreEqual(Double(500), Double(O.Advance), 0.001);
    Assert.IsTrue(F.GetOutline(F.GlyphByName('.notdef'), O));
    Assert.IsTrue(O.IsEmpty);
    Assert.AreEqual(Double(250), Double(F.GetAdvance(0)), 0.001);
    Assert.IsFalse(F.GetOutline(-1, O));
    Assert.IsFalse(F.GetOutline(F.GlyphCount, O));
    Assert.AreEqual(Double(-1), Double(F.GetAdvance(F.GlyphCount)), 0.001);
  finally
    F.Free;
  end;
end;

procedure TPdfType1Tests.Synthetic_CallSubr;
var
  F: TPdfType1Font;
  O: TPdfGlyphOutline;
begin
  F := MainFont;
  try
    Assert.IsTrue(F.GetOutline(F.GlyphByName('subrglyph'), O));
    Assert.AreEqual(5, O.Count);
    CheckPoint(O, 0, glMove, 50, 50);
    CheckPoint(O, 1, glLine, 150, 50);
    CheckPoint(O, 2, glLine, 150, 150);
    CheckPoint(O, 3, glLine, 50, 50);
    CheckPoint(O, 4, glClose, 0, 0);
    Assert.AreEqual(Double(400), Double(F.GetAdvance(F.GlyphByName('subrglyph'))), 0.001);
  finally
    F.Free;
  end;
end;

procedure TPdfType1Tests.Synthetic_CurveOperators;
var
  F: TPdfType1Font;
  O: TPdfGlyphOutline;
begin
  F := MainFont;
  try
    // 10 20 600 0 sbw ... 100 vmoveto: start at (10, 120)
    Assert.IsTrue(F.GetOutline(F.GlyphByName('curves'), O));
    Assert.AreEqual(7, O.Count);
    CheckPoint(O, 0, glMove, 10, 120);
    CheckCubic(O, 1, 40, 120, 80, 170, 80, 230);       // hvcurveto
    CheckCubic(O, 2, 80, 240, 100, 270, 140, 270);     // vhcurveto
    CheckCubic(O, 3, 141, 272, 144, 276, 149, 282);    // rrcurveto
    CheckPoint(O, 4, glLine, 349, 282);                // 600 3 div 0 rlineto
    CheckPoint(O, 5, glLine, 10, 120);
    CheckPoint(O, 6, glClose, 0, 0);
    Assert.AreEqual(Double(600), Double(F.GetAdvance(F.GlyphByName('curves'))), 0.001);
  finally
    F.Free;
  end;
end;

procedure TPdfType1Tests.Synthetic_Seac;
var
  F: TPdfType1Font;
  O, Base, Accent: TPdfGlyphOutline;
  I: Integer;
begin
  F := MainFont;
  try
    Assert.IsTrue(F.GetOutline(F.GlyphByName('A'), Base));
    Assert.IsTrue(F.GetOutline(F.GlyphByName('acute'), Accent));
    Assert.IsTrue(F.GetOutline(F.GlyphByName('seacglyph'), O));
    Assert.AreEqual(Base.Count + Accent.Count, O.Count);
    // Base ('A', drawn like 'square') at its own position.
    for I := 0 to Base.Count - 1 do
      CheckPoint(O, I, Base.Cmds[I].Kind, Base.Cmds[I].X1, Base.Cmds[I].Y1);
    CheckPoint(O, 0, glMove, 150, 100);
    // Accent displaced by adx - asb + sbx = 100 - 20 + 50 = 130 and ady = 300; acute starts at (30, 0).
    for I := 0 to Accent.Count - 1 do
      if Accent.Cmds[I].Kind <> glClose then
        CheckPoint(O, Base.Count + I, Accent.Cmds[I].Kind, Accent.Cmds[I].X1 + 130, Accent.Cmds[I].Y1 + 300);
    CheckPoint(O, Base.Count, glMove, 160, 300);
    Assert.AreEqual(Double(600), Double(F.GetAdvance(F.GlyphByName('seacglyph'))), 0.001);
    Assert.AreEqual(Double(600), Double(O.Advance), 0.001);
  finally
    F.Free;
  end;
end;

procedure TPdfType1Tests.Synthetic_FlexAndHintReplacement;
var
  F: TPdfType1Font;
  O: TPdfGlyphOutline;
  I, Cubics: Integer;
begin
  F := MainFont;
  try
    Assert.IsTrue(F.GetOutline(F.GlyphByCode(67), O));
    Cubics := 0;
    for I := 0 to O.Count - 1 do
      if O.Cmds[I].Kind = glCubic then
        Inc(Cubics);
    Assert.AreEqual(2, Cubics);
    Assert.AreEqual(5, O.Count);
    CheckPoint(O, 0, glMove, 100, 100);
    CheckCubic(O, 1, 150, 130, 180, 130, 200, 130);
    CheckCubic(O, 2, 220, 130, 250, 130, 300, 100);
    CheckPoint(O, 3, glLine, 100, 100);
    CheckPoint(O, 4, glClose, 0, 0);
  finally
    F.Free;
  end;
end;

procedure TPdfType1Tests.Synthetic_StandardEncoding;
var
  F: TPdfType1Font;
  O: TPdfGlyphOutline;
begin
  F := TPdfType1Font.Create(BuildType1(MainGlyphs, StdSubrs, ffBinary, True));
  try
    Assert.IsTrue(F.HasStandardEncoding);
    Assert.AreEqual(F.GlyphByName('A'), F.GlyphByCode(65));
    Assert.AreEqual(F.GlyphByName('acute'), F.GlyphByCode(194));
    Assert.AreEqual('A', F.EncodingName(65));
    Assert.AreEqual('quoteright', F.EncodingName(39));
    Assert.AreEqual(-1, F.GlyphByCode(66), 'B is not in the font');
    Assert.AreEqual('', F.EncodingName(0));
    // The first /FontMatrix wins.
    Assert.AreEqual(0.002, F.FontMatrix.A, 1E-9);
    Assert.IsTrue(F.GetOutline(F.GlyphByCode(65), O));
    Assert.AreEqual(5, O.Count);
  finally
    F.Free;
  end;
end;

procedure TPdfType1Tests.Synthetic_PfaHexForm;
var
  F: TPdfType1Font;
begin
  F := MainFont(ffPfa);
  try
    Assert.AreEqual(Length(MainGlyphs), F.GlyphCount);
    Assert.AreEqual(F.GlyphByName('square'), F.GlyphByCode(65));
    CheckMainOutlines(F);
  finally
    F.Free;
  end;
end;

procedure TPdfType1Tests.Synthetic_PfbSegmentForm;
var
  F: TPdfType1Font;
begin
  F := MainFont(ffPfb);
  try
    Assert.AreEqual('TestT1', F.FontName);
    Assert.AreEqual(Length(MainGlyphs), F.GlyphCount);
    Assert.AreEqual(F.GlyphByName('square'), F.GlyphByCode(65));
    CheckMainOutlines(F);
    Assert.AreEqual(7, F.OutlineCount);
  finally
    F.Free;
  end;
end;

procedure TPdfType1Tests.Synthetic_UnencryptedCharStrings;
var
  F: TPdfType1Font;
begin
  F := TPdfType1Font.Create(BuildType1(MainGlyphs, StdSubrs, ffBinary, False, -1));
  try
    CheckMainOutlines(F);
    Assert.AreEqual(7, F.OutlineCount);
  finally
    F.Free;
  end;
  // lenIV 0: encrypted without random prefix bytes is not used by the writer; lenIV 2 is.
  F := TPdfType1Font.Create(BuildType1(MainGlyphs, StdSubrs, ffBinary, False, 2));
  try
    Assert.AreEqual(Length(MainGlyphs), F.GlyphCount);
  finally
    F.Free;
  end;
end;

procedure TPdfType1Tests.CorruptCharStrings;
const
  Glyphs: array[0..7] of string = (
    '.notdef=0 250 hsbw endchar',
    'underflow=0 500 hsbw rlineto endchar',
    'unknownop=0 500 hsbw 10 10 rmoveto 100 hlineto #2 100 vlineto endchar',
    'badsubr=0 500 hsbw 10 10 rmoveto 99 callsubr endchar',
    'recurse=0 500 hsbw 10 10 rmoveto 6 callsubr endchar',
    'truncated=0 500 hsbw 10 10 rmoveto 100 hlineto #255 #1',
    'noend=0 500 hsbw 10 10 rmoveto 100 hlineto 100 vlineto',
    'nestedseac=0 500 hsbw 0 0 0 66 65 seac');
  Subrs: array[0..6] of string = ('return', 'return', 'return', 'return', 'return', 'return',
    '6 callsubr return');
var
  F: TPdfType1Font;
  O: TPdfGlyphOutline;
begin
  F := TPdfType1Font.Create(BuildType1(Glyphs, Subrs, ffBinary, True));
  try
    Assert.IsFalse(F.GetOutline(F.GlyphByName('underflow'), O));
    Assert.IsTrue(O.IsEmpty);
    Assert.AreEqual(Double(500), Double(F.GetAdvance(F.GlyphByName('underflow'))), 0.001);

    Assert.IsTrue(F.GetOutline(F.GlyphByName('unknownop'), O), 'unknown operator ends the glyph');
    Assert.AreEqual(4, O.Count);
    CheckPoint(O, 1, glLine, 110, 10);
    CheckPoint(O, 2, glLine, 10, 10);
    CheckPoint(O, 3, glClose, 0, 0);

    Assert.IsFalse(F.GetOutline(F.GlyphByName('badsubr'), O));
    Assert.IsTrue(O.IsEmpty);
    Assert.IsFalse(F.GetOutline(F.GlyphByName('recurse'), O));
    Assert.IsTrue(O.IsEmpty);
    Assert.IsFalse(F.GetOutline(F.GlyphByName('truncated'), O));
    Assert.IsTrue(O.IsEmpty);

    Assert.IsTrue(F.GetOutline(F.GlyphByName('noend'), O), 'missing endchar closes the contour');
    Assert.AreEqual(5, O.Count);
    CheckPoint(O, 4, glClose, 0, 0);

    // seac referring to B/A that are absent: an empty glyph, not an error.
    Assert.IsTrue(F.GetOutline(F.GlyphByName('nestedseac'), O));
    Assert.IsTrue(O.IsEmpty);
    Assert.AreEqual(2, F.OutlineCount);
  finally
    F.Free;
  end;
end;

procedure TPdfType1Tests.TruncatedPrograms;
var
  Full, Part: TBytes;
  Cut, Glyph, Accepted: Integer;
  F: TPdfType1Font;
  O: TPdfGlyphOutline;
  Form: TFontForm;
begin
  for Form := Low(TFontForm) to High(TFontForm) do
  begin
    Full := BuildType1(MainGlyphs, StdSubrs, Form, False);
    Accepted := 0;
    Cut := 1;
    while Cut < Length(Full) do
    begin
      Part := Copy(Full, 0, Cut);
      try
        F := TPdfType1Font.Create(Part);
        try
          Inc(Accepted);
          for Glyph := -1 to F.GlyphCount do
          begin
            F.GetOutline(Glyph, O);
            F.GetAdvance(Glyph);
          end;
          for Glyph := 0 to 255 do
            F.GlyphByCode(Glyph);
        finally
          F.Free;
        end;
      except
        on E: EPdfFontError do
          ;
      end;
      Inc(Cut, 7);
    end;
    Assert.IsTrue(Accepted > 0, 'some truncated programs still have CharStrings');
  end;
end;

procedure TPdfType1Tests.NoCharStringsRaises;
begin
  Assert.WillRaise(
    procedure
    begin
      TPdfType1Font.Create(BytesOf('%!PS-AdobeFont-1.0: X'#10'/FontName /X def currentfile eexec'#13'garbage')).Free;
    end, EPdfFontError);
  Assert.WillRaise(
    procedure
    begin
      TPdfType1Font.Create(nil).Free;
    end, EPdfFontError);
  Assert.WillRaise(
    procedure
    begin
      TPdfType1Font.Create(TBytes.Create($80, $01, $FF, $FF, $FF, $7F, 1, 2)).Free;
    end, EPdfFontError);
end;

procedure TPdfType1Tests.FoxitFontsAreCFF;
var
  Files: TArray<string>;
  FileName: string;
  Data: TBytes;
begin
  if not TDirectory.Exists(FontsDir) then
  begin
    Assert.Pass('Resources\Fonts not found');
    Exit;
  end;
  Files := TDirectory.GetFiles(FontsDir, 'Foxit*.pfb');
  Assert.AreEqual(10, Integer(Length(Files)));
  for FileName in Files do
  begin
    Data := TFile.ReadAllBytes(FileName);
    // Bare CFF (major 1, minor 0, header size 4): not a Type 1 program.
    Assert.AreEqual(1, Integer(Data[0]), ExtractFileName(FileName));
    Assert.AreEqual(0, Integer(Data[1]), ExtractFileName(FileName));
    Assert.IsFalse(TPdfType1Font.IsType1(Data), ExtractFileName(FileName));
    Assert.WillRaise(
      procedure
      begin
        TPdfType1Font.Create(Data).Free;
      end, EPdfFontError, ExtractFileName(FileName));
  end;
end;

procedure TPdfType1Tests.CorpusSweep;
var
  Dirs, Failures, Notes: TStringList;
  Files: TList<string>;
  Seen: TList<Integer>;
  Dir, Env, FileName, Key: string;
  Doc: TPdfDocument;
  Limit, Fonts, Rejected, WithOutlines, Glyphs, GlyphsDrawn, Custom, NoOutline, P, G, C: Integer;
  FontDict, FD, Desc: IPdfDictionary;
  Stm: IPdfStream;
  Data: TBytes;
  F: TPdfType1Font;
  O: TPdfGlyphOutline;
  Label1: string;
begin
  Limit := StrToIntDef(GetEnvironmentVariable('PDF_TYPE1_CORPUS_LIMIT'), 60);
  Dirs := TStringList.Create;
  Files := TList<string>.Create;
  Failures := TStringList.Create;
  Notes := TStringList.Create;
  Seen := TList<Integer>.Create;
  Doc := TPdfDocument.Create;
  try
    Dirs.Add(TPath.GetFullPath(TPath.Combine(TestDataPath, '..\Corpus')));
    Env := GetEnvironmentVariable('PDF_CORPUS_DIRS');
    for Dir in Env.Split([';']) do
      if Trim(Dir) <> '' then
        Dirs.Add(Trim(Dir));
    for Dir in Dirs do
      if TDirectory.Exists(Dir) then
        Files.AddRange(TDirectory.GetFiles(Dir, '*.pdf', TSearchOption.soAllDirectories));
    if Files.Count = 0 then
    begin
      Assert.Pass('No corpus files (set PDF_CORPUS_DIRS)');
      Exit;
    end;
    Files.Sort;
    Fonts := 0;
    Rejected := 0;
    WithOutlines := 0;
    Glyphs := 0;
    GlyphsDrawn := 0;
    Custom := 0;
    NoOutline := 0;
    for FileName in Files do
    begin
      if Fonts >= Limit then
        Break;
      try
        Doc.LoadFromFile(FileName);
      except
        Continue;
      end;
      Seen.Clear;
      try
        for P := 0 to Doc.PageCount - 1 do
        begin
          try
            if Doc.Pages[P].Resources = nil then
              Continue;
            FontDict := Doc.Pages[P].Resources.GetDictionary('Font');
          except
            Continue;
          end;
          if FontDict = nil then
            Continue;
          for Key in FontDict.Keys do
          begin
            try
              FD := FontDict.GetDictionary(Key);
              if FD = nil then
                Continue;
              Desc := FD.GetDictionary('FontDescriptor');
              if Desc = nil then
                Continue;
              Stm := Desc.GetStream('FontFile');
              if (Stm = nil) or Seen.Contains(Stm.GetObjNum) then
                Continue;
              Seen.Add(Stm.GetObjNum);
              Data := Stm.GetDecodedData;
            except
              Continue;
            end;
            Inc(Fonts);
            Label1 := ExtractFileName(FileName) + ' ' + FD.GetName('BaseFont');
            try
              F := TPdfType1Font.Create(Data);
            except
              on E: EPdfFontError do
              begin
                Inc(Rejected);
                Notes.Add('rejected: ' + Label1 + ' (' + IntToStr(Length(Data)) + ' bytes)');
                Continue;
              end;
              on E: Exception do
              begin
                Failures.Add(Label1 + ': ' + E.ClassName + ': ' + E.Message);
                Continue;
              end;
            end;
            try
              try
                Inc(Glyphs, F.GlyphCount);
                for G := 0 to F.GlyphCount - 1 do
                begin
                  F.GetOutline(G, O);
                  if not O.IsEmpty then
                    Inc(GlyphsDrawn);
                  F.GetAdvance(G);
                end;
                for C := 0 to 255 do
                  F.GlyphByCode(C);
                if F.OutlineCount > 0 then
                  Inc(WithOutlines)
                else
                begin
                  Inc(NoOutline);
                  Notes.Add('no outlines: ' + Label1);
                end;
                if not F.HasStandardEncoding then
                  Inc(Custom);
              except
                on E: Exception do
                  Failures.Add(Label1 + ': glyphs: ' + E.ClassName + ': ' + E.Message);
              end;
            finally
              F.Free;
            end;
          end;
        end;
      except
        on E: Exception do
          ; // broken page tree etc.: not a font problem
      end;
      Doc.Close;
    end;
    TDUnitX.CurrentRunner.Log(TLogLevel.Information, Format(
      'Type1 corpus: %d FontFile programs, %d rejected (EPdfFontError), %d with outlines, %d without, ' +
      '%d glyphs of which %d drawn, %d custom encodings', [Fonts, Rejected, WithOutlines, NoOutline, Glyphs,
      GlyphsDrawn, Custom]));
    if Notes.Count > 0 then
      TDUnitX.CurrentRunner.Log(TLogLevel.Information, Notes.Text);
    if Fonts = 0 then
    begin
      Assert.Pass('No Type1 FontFile programs in the corpus');
      Exit;
    end;
    Assert.AreEqual(0, Failures.Count, #10 + Failures.Text);
    Assert.IsTrue(WithOutlines >= (Fonts * 9) div 10, 'at least 90% of the programs produce outlines');
  finally
    Doc.Free;
    Seen.Free;
    Notes.Free;
    Failures.Free;
    Files.Free;
    Dirs.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfType1Tests);

end.
