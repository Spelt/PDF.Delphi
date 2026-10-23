unit Pdf.Tests.Font.CMap;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.Diagnostics, DUnitX.TestFramework, Pdf.Core.Types,
  Pdf.Font.CMap;

type
  [TestFixture]
  TPdfCMapTests = class
  private
    function ParseText(const Source: string; Parent: TPdfCMap = nil): TPdfCMap;
    procedure CheckNext(Map: TPdfCMap; const Bytes: TBytes; var Pos: Integer; ExpCode, ExpCID, ExpLen: Integer);
  public
    [Test] procedure EmbeddedMixedWidths;
    [Test] procedure EmbeddedUnmappedCode;
    [Test] procedure EmbeddedTwoByteOnlyPartialCode;
    [Test] procedure EmbeddedNameAndWMode;
    [Test] procedure EmbeddedUseCMapPredefined;
    [Test] procedure EmbeddedParentArgument;
    [Test] procedure EmbeddedIdentityDetected;
    [Test] procedure EmbeddedHugeRanges;
    [Test] procedure ToUnicodeOneByte;
    [Test] procedure ToUnicodeTwoByte;
    [Test] procedure ToUnicodeInferredCodespace;
    [Test] procedure IdentityBuiltIn;
    [Test] procedure PredefinedIdentity;
    [Test] procedure Predefined90msRKSJ;
    [Test] procedure PredefinedUniJIS;
    [Test] procedure PredefinedUseCMapChain;
    [Test] procedure PredefinedUnknown;
    [Test] procedure PredefinedUCS2;
    [Test] procedure PredefinedLoadTime;
    [Test] procedure PredefinedAllLoad;
    [Test] procedure ResourceNames;
    [Test] procedure MalformedText;
    [Test] procedure MalformedRandom;
    [Test] procedure MalformedBinary;
  end;

implementation

function Bytes(const Values: array of Byte): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(Values));
  for I := 0 to High(Values) do
    Result[I] := Values[I];
end;

function TPdfCMapTests.ParseText(const Source: string; Parent: TPdfCMap): TPdfCMap;
begin
  Result := TPdfCMap.Parse(PdfLatin1ToBytes(Source), Parent);
  Assert.IsNotNull(Result);
end;

procedure TPdfCMapTests.CheckNext(Map: TPdfCMap; const Bytes: TBytes; var Pos: Integer;
  ExpCode, ExpCID, ExpLen: Integer);
var
  Code, CID, Len, Start: Integer;
begin
  Start := Pos;
  Map.NextCode(Bytes, Pos, Code, CID, Len);
  Assert.AreEqual(ExpCode, Code, Format('code at %d', [Start]));
  Assert.AreEqual(ExpCID, CID, Format('CID at %d', [Start]));
  Assert.AreEqual(ExpLen, Len, Format('length at %d', [Start]));
  Assert.AreEqual(Start + ExpLen, Pos, Format('position after %d', [Start]));
end;

const
  MixedCMap =
    '%!PS-Adobe-3.0 Resource-CMap'#10 +
    '/CIDInit /ProcSet findresource begin'#10 +
    '12 dict begin'#10 +
    'begincmap'#10 +
    '/CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 2 >> def'#10 +
    '/CMapName /Test-RKSJ-H def'#10 +
    '/CMapType 1 def'#10 +
    '2 begincodespacerange'#10 +
    '<00> <80>'#10 +
    '<8140> <9ffc>'#10 +
    'endcodespacerange'#10 +
    '1 begincidrange'#10 +
    '<20> <7e> 1'#10 +
    'endcidrange'#10 +
    '1 begincidchar'#10 +
    '<8140> 633'#10 +
    'endcidchar'#10 +
    'endcmap'#10 +
    'CMapName currentdict /CMap defineresource pop'#10 +
    'end'#10 +
    'end'#10;

procedure TPdfCMapTests.EmbeddedMixedWidths;
var
  Map: TPdfCMap;
  D: TBytes;
  P: Integer;
begin
  Map := ParseText(MixedCMap);
  try
    Assert.AreEqual('Test-RKSJ-H', Map.Name);
    Assert.IsFalse(Map.Vertical);
    Assert.IsTrue(Map.HasOneByteCodes);
    Assert.IsFalse(Map.IsIdentity);
    Assert.IsFalse(Map.HasUnicodeMappings);
    D := Bytes([$41, $81, $40, $20]);
    P := 0;
    CheckNext(Map, D, P, $41, 34, 1);
    CheckNext(Map, D, P, $8140, 633, 2);
    CheckNext(Map, D, P, $20, 1, 1);
    Assert.AreEqual(34, Map.LookupCID($41, 1));
    Assert.AreEqual(633, Map.LookupCID($8140, 2));
    Assert.AreEqual(95, Map.LookupCID($7E, 1));
  finally
    Map.Free;
  end;
end;

procedure TPdfCMapTests.EmbeddedUnmappedCode;
var
  Map: TPdfCMap;
  D: TBytes;
  P, Code, CID, Len: Integer;
begin
  Map := ParseText(MixedCMap);
  try
    D := Bytes([$10, $81, $41, $FF, $A0, $41]);
    P := 0;
    CheckNext(Map, D, P, $10, 0, 1);       // in the 1-byte codespace, not mapped
    CheckNext(Map, D, P, $8141, 0, 2);     // in the 2-byte codespace, not mapped
    CheckNext(Map, D, P, $FF, 0, 1);       // in no codespace: 1 byte
    CheckNext(Map, D, P, $A0, 0, 1);
    CheckNext(Map, D, P, $41, 34, 1);
    Map.NextCode(D, P, Code, CID, Len);     // at the end
    Assert.AreEqual(0, Len);
    Assert.AreEqual(Integer(Length(D)), P);
    Assert.AreEqual(0, Map.LookupCID($7F, 1));
    Assert.AreEqual(0, Map.LookupCID($9000, 2));
  finally
    Map.Free;
  end;
end;

procedure TPdfCMapTests.EmbeddedTwoByteOnlyPartialCode;
var
  Map: TPdfCMap;
  D: TBytes;
  P: Integer;
begin
  Map := ParseText(
    '1 begincodespacerange <0000> <ffff> endcodespacerange'#10 +
    '1 begincidrange <0000> <ffff> 0 endcidrange');
  try
    Assert.IsFalse(Map.HasOneByteCodes);
    D := Bytes([$00, $41, $12, $34, $56]);
    P := 0;
    CheckNext(Map, D, P, $0041, $41, 2);
    CheckNext(Map, D, P, $1234, $1234, 2);
    CheckNext(Map, D, P, $56, 0, 1);       // partial code at the end
  finally
    Map.Free;
  end;
end;

procedure TPdfCMapTests.EmbeddedNameAndWMode;
var
  Map: TPdfCMap;
begin
  Map := ParseText('/CMapName /Custom def /WMode 1 def 1 begincodespacerange <00> <ff> endcodespacerange');
  try
    Assert.AreEqual('Custom', Map.Name);
    Assert.IsTrue(Map.Vertical);
  finally
    Map.Free;
  end;
  Map := ParseText('/CMapName /Custom-V def');
  try
    Assert.IsTrue(Map.Vertical, 'name ending in -V');
  finally
    Map.Free;
  end;
  Map := ParseText('/CMapName /Custom-H def /WMode 0 def');
  try
    Assert.IsFalse(Map.Vertical);
  finally
    Map.Free;
  end;
end;

procedure TPdfCMapTests.EmbeddedUseCMapPredefined;
var
  Map: TPdfCMap;
  D: TBytes;
  P: Integer;
begin
  Map := ParseText(
    '/CMapName /Child def /90ms-RKSJ-H usecmap'#10 +
    '1 begincidchar <41> 999 endcidchar');
  try
    Assert.IsNotNull(Map.Parent);
    Assert.AreEqual('90ms-RKSJ-H', Map.Parent.Name);
    Assert.IsTrue(Map.Parent = TPdfCMap.Predefined('90ms-RKSJ-H'), 'cached instance');
    Assert.IsTrue(Map.HasOneByteCodes, 'codespace inherited');
    Assert.AreEqual(999, Map.LookupCID($41, 1), 'own mapping wins');
    Assert.AreEqual(265, Map.LookupCID($42, 1), 'parent mapping');
    D := Bytes([$41, $88, $9F]);
    P := 0;
    CheckNext(Map, D, P, $41, 999, 1);
    CheckNext(Map, D, P, $889F, TPdfCMap.Predefined('90ms-RKSJ-H').LookupCID($889F, 2), 2);
  finally
    Map.Free;
  end;
  // Identity-H as parent
  Map := ParseText('/Identity-V usecmap 1 begincidchar <0041> 7 endcidchar');
  try
    Assert.IsTrue(Map.Vertical, 'WMode inherited from the parent');
    Assert.AreEqual(7, Map.LookupCID($41, 2));
    Assert.AreEqual($42, Map.LookupCID($42, 2));
  finally
    Map.Free;
  end;
end;

procedure TPdfCMapTests.EmbeddedParentArgument;
var
  Parent, Map: TPdfCMap;
begin
  Parent := ParseText(
    '1 begincodespacerange <0000> <ffff> endcodespacerange'#10 +
    '1 begincidrange <0100> <01ff> 10 endcidrange'#10 +
    '1 beginbfchar <0100> <0058> endbfchar');
  Map := ParseText('/90ms-RKSJ-H usecmap 1 begincidchar <0101> 5 endcidchar', Parent);
  try
    Assert.IsTrue(Map.Parent = Parent, 'Parent argument wins over usecmap');
    Assert.IsFalse(Map.HasOneByteCodes);
    Assert.AreEqual(10, Map.LookupCID($0100, 2));
    Assert.AreEqual(5, Map.LookupCID($0101, 2));
    Assert.AreEqual(12, Map.LookupCID($0102, 2));
    Assert.IsTrue(Map.HasUnicodeMappings);
    Assert.AreEqual('X', Map.ToUnicode($0100, 2));
  finally
    Map.Free;
    Parent.Free;
  end;
  // Owned parent
  Parent := ParseText('1 begincidchar <0001> 3 endcidchar');
  Map := TPdfCMap.Parse(PdfLatin1ToBytes('1 begincidchar <0002> 4 endcidchar'), Parent, True);
  try
    Assert.AreEqual(3, Map.LookupCID(1, 2));
    Assert.AreEqual(4, Map.LookupCID(2, 2));
  finally
    Map.Free; // frees Parent
  end;
end;

procedure TPdfCMapTests.EmbeddedIdentityDetected;
var
  Map: TPdfCMap;
begin
  Map := ParseText(
    '/CMapName /Identity-H def 1 begincodespacerange <0000> <FFFF> endcodespacerange'#10 +
    '1 begincidrange <0000> <FFFF> 0 endcidrange');
  try
    Assert.IsTrue(Map.IsIdentity);
    Assert.AreEqual($1234, Map.LookupCID($1234, 2));
  finally
    Map.Free;
  end;
  Map := ParseText(
    '/CMapName /Identity-H def 1 begincodespacerange <0000> <FFFF> endcodespacerange'#10 +
    '1 begincidrange <0000> <FFFF> 1 endcidrange');
  try
    Assert.IsFalse(Map.IsIdentity);
    Assert.AreEqual($1235, Map.LookupCID($1234, 2));
  finally
    Map.Free;
  end;
end;

procedure TPdfCMapTests.EmbeddedHugeRanges;
var
  Map: TPdfCMap;
  SW: TStopwatch;
begin
  // pdf.js issue11922: ranges spanning the whole 4-byte space must not hang
  SW := TStopwatch.StartNew;
  Map := ParseText(
    '1 begincodespacerange <00000000> <FFFFFFFF> endcodespacerange'#10 +
    '1 begincidrange <00000000> <FFFFFFFF> 0 endcidrange'#10 +
    '1 begincidchar <00000005> 77 endcidchar'#10 +
    '1 beginbfrange <00000000> <FFFFFFFF> <0041> endbfrange');
  try
    Assert.IsTrue(SW.ElapsedMilliseconds < 1000, 'parse time');
    Assert.AreEqual($123456, Map.LookupCID($123456, 4));
    Assert.AreEqual(77, Map.LookupCID(5, 4));
    Assert.AreEqual('C', Map.ToUnicode(2, 4));
    Assert.IsTrue(Map.HasUnicodeMappings);
  finally
    Map.Free;
  end;
end;

procedure TPdfCMapTests.ToUnicodeOneByte;
var
  Map: TPdfCMap;
begin
  Map := ParseText(
    '/CIDInit /ProcSet findresource begin 12 dict begin begincmap'#10 +
    '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def'#10 +
    '/CMapName /Adobe-Identity-UCS def /CMapType 2 def'#10 +
    '1 begincodespacerange <00> <FF> endcodespacerange'#10 +
    '2 beginbfchar <01> <0041> <07> /space endbfchar'#10 +
    '2 beginbfrange <02> <04> <0061>'#10 +
    '<05> <06> [<00660066> <0066006C>] endbfrange'#10 +
    'endcmap CMapName currentdict /CMap defineresource pop end end');
  try
    Assert.IsTrue(Map.HasUnicodeMappings);
    Assert.IsTrue(Map.HasOneByteCodes);
    Assert.AreEqual('A', Map.ToUnicode(1, 1));
    Assert.AreEqual('a', Map.ToUnicode(2, 1));
    Assert.AreEqual('b', Map.ToUnicode(3, 1));
    Assert.AreEqual('c', Map.ToUnicode(4, 1));
    Assert.AreEqual('ff', Map.ToUnicode(5, 1));
    Assert.AreEqual('fl', Map.ToUnicode(6, 1));
    Assert.AreEqual('', Map.ToUnicode(7, 1), 'name destination ignored');
    Assert.AreEqual('', Map.ToUnicode(8, 1));
    Assert.AreEqual(0, Map.LookupCID(1, 1), 'bf mappings are not CIDs');
  finally
    Map.Free;
  end;
end;

procedure TPdfCMapTests.ToUnicodeTwoByte;
var
  Map: TPdfCMap;
  D: TBytes;
  P: Integer;
begin
  Map := ParseText(
    '1 begincodespacerange <0000> <FFFF> endcodespacerange'#10 +
    '3 beginbfchar <0003> <0020> <0004> <D83DDE00> <0005> <FB01> endbfchar'#10 +
    '1 beginbfrange <0010> <0012> <0041> endbfrange'#10 +
    '1 beginbfrange <00FE> <0101> <00FE> endbfrange');
  try
    Assert.IsTrue(Map.HasUnicodeMappings);
    Assert.IsFalse(Map.HasOneByteCodes);
    D := Bytes([$00, $03, $00, $11]);
    P := 0;
    CheckNext(Map, D, P, 3, 0, 2);
    CheckNext(Map, D, P, $11, 0, 2);
    Assert.AreEqual(' ', Map.ToUnicode(3, 2));
    Assert.AreEqual(#$D83D#$DE00, Map.ToUnicode(4, 2));
    Assert.AreEqual(#$FB01, Map.ToUnicode(5, 2));
    Assert.AreEqual('A', Map.ToUnicode($10, 2));
    Assert.AreEqual('C', Map.ToUnicode($12, 2));
    Assert.AreEqual('', Map.ToUnicode($13, 2));
    Assert.AreEqual(#$0100, Map.ToUnicode($0100, 2), 'carry into the high byte');
    Assert.AreEqual('A', Map.ToUnicode($10, 1), 'pdf.js: lookup by value when the length differs');
  finally
    Map.Free;
  end;
end;

procedure TPdfCMapTests.ToUnicodeInferredCodespace;
var
  Map: TPdfCMap;
  D: TBytes;
  P: Integer;
begin
  Map := ParseText('2 beginbfchar <0001> <0041> <0002> <0042> endbfchar');
  try
    Assert.IsFalse(Map.HasOneByteCodes);
    D := Bytes([$00, $02]);
    P := 0;
    CheckNext(Map, D, P, 2, 0, 2);
    Assert.AreEqual('B', Map.ToUnicode(2, 2));
  finally
    Map.Free;
  end;
  Map := ParseText('1 beginbfchar <41> <0058> endbfchar');
  try
    Assert.IsTrue(Map.HasOneByteCodes);
    Assert.AreEqual('X', Map.ToUnicode($41, 1));
  finally
    Map.Free;
  end;
end;

procedure TPdfCMapTests.IdentityBuiltIn;
var
  Map: TPdfCMap;
  D: TBytes;
  P: Integer;
begin
  Map := TPdfCMap.Identity(False);
  try
    Assert.IsTrue(Map.IsIdentity);
    Assert.IsFalse(Map.Vertical);
    Assert.AreEqual('Identity-H', Map.Name);
    Assert.IsFalse(Map.HasOneByteCodes);
    Assert.IsFalse(Map.HasUnicodeMappings);
    Assert.IsNull(Map.Parent);
    D := Bytes([$00, $41, $FF, $FF, $12]);
    P := 0;
    CheckNext(Map, D, P, $41, $41, 2);
    CheckNext(Map, D, P, $FFFF, $FFFF, 2);
    CheckNext(Map, D, P, $12, 0, 1);
    Assert.AreEqual($4E9C, Map.LookupCID($4E9C, 2));
    Assert.AreEqual('', Map.ToUnicode($41, 2));
  finally
    Map.Free;
  end;
  Map := TPdfCMap.Identity(True);
  try
    Assert.IsTrue(Map.Vertical);
    Assert.IsTrue(Map.IsIdentity);
    Assert.AreEqual('Identity-V', Map.Name);
  finally
    Map.Free;
  end;
end;

procedure TPdfCMapTests.PredefinedIdentity;
var
  H, V: TPdfCMap;
begin
  H := TPdfCMap.Predefined('Identity-H');
  V := TPdfCMap.Predefined('Identity-V');
  Assert.IsNotNull(H);
  Assert.IsNotNull(V);
  Assert.IsTrue(H.IsIdentity);
  Assert.IsFalse(H.Vertical);
  Assert.IsTrue(V.Vertical);
  Assert.IsTrue(H = TPdfCMap.Predefined('Identity-H'), 'cached');
end;

procedure TPdfCMapTests.Predefined90msRKSJ;
var
  Map: TPdfCMap;
  D: TBytes;
  P, CID: Integer;
begin
  Map := TPdfCMap.Predefined('90ms-RKSJ-H');
  Assert.IsNotNull(Map);
  Assert.AreEqual('90ms-RKSJ-H', Map.Name);
  Assert.IsFalse(Map.Vertical);
  Assert.IsTrue(Map.HasOneByteCodes);
  Assert.IsFalse(Map.IsIdentity);
  // 90ms-RKSJ-H maps single bytes to the half-width Roman CIDs (<20> <7d> 231); 90msp-RKSJ-H to the
  // proportional ones (<20> <7e> 1)
  Assert.AreEqual(231, Map.LookupCID($20, 1));
  Assert.AreEqual(264, Map.LookupCID($41, 1));
  Assert.AreEqual(34, TPdfCMap.Predefined('90msp-RKSJ-H').LookupCID($41, 1));
  Assert.AreEqual(1, TPdfCMap.Predefined('90msp-RKSJ-H').LookupCID($20, 1));
  Assert.AreEqual(1125, TPdfCMap.Predefined('90msp-RKSJ-H').LookupCID($889F, 2));
  // 0x889F (SJIS) = U+4E9C, Adobe-Japan1 CID 1125
  CID := Map.LookupCID($889F, 2);
  Assert.AreEqual(1125, CID);
  Assert.AreEqual(TPdfCMap.Predefined('UniJIS-UCS2-H').LookupCID($4E9C, 2), CID, 'same CID through Unicode');
  // 0x82A0 (SJIS) = U+3042 HIRAGANA LETTER A = CID 843
  Assert.AreEqual(843, Map.LookupCID($82A0, 2));
  D := Bytes([$41, $88, $9F, $82, $A0, $20]);
  P := 0;
  CheckNext(Map, D, P, $41, 264, 1);
  CheckNext(Map, D, P, $889F, 1125, 2);
  CheckNext(Map, D, P, $82A0, 843, 2);
  CheckNext(Map, D, P, $20, 231, 1);
  Assert.IsTrue(TPdfCMap.Predefined('90ms-RKSJ-V').Vertical);
end;

procedure TPdfCMapTests.PredefinedUniJIS;
var
  Map: TPdfCMap;
  D: TBytes;
  P: Integer;
begin
  Map := TPdfCMap.Predefined('UniJIS-UCS2-H');
  Assert.IsNotNull(Map);
  Assert.IsFalse(Map.Vertical);
  Assert.IsFalse(Map.HasOneByteCodes);
  Assert.AreEqual(843, Map.LookupCID($3042, 2));    // HIRAGANA LETTER A
  Assert.AreEqual(34, Map.LookupCID($0041, 2));     // A
  D := Bytes([$30, $42, $00, $41]);
  P := 0;
  CheckNext(Map, D, P, $3042, 843, 2);
  CheckNext(Map, D, P, $41, 34, 2);
  // UTF-8 variant: 3-byte codes
  Map := TPdfCMap.Predefined('UniJIS-UTF8-H');
  Assert.IsNotNull(Map);
  D := Bytes([$E3, $81, $82, $41]);
  P := 0;
  CheckNext(Map, D, P, $E38182, 843, 3);
  CheckNext(Map, D, P, $41, 34, 1);
  // UTF-32 variant: 4-byte codes
  Map := TPdfCMap.Predefined('UniJIS-UTF32-H');
  Assert.IsNotNull(Map);
  Assert.AreEqual(843, Map.LookupCID($3042, 4));
end;

procedure TPdfCMapTests.PredefinedUseCMapChain;
var
  Map: TPdfCMap;
begin
  Map := TPdfCMap.Predefined('UniJIS-UCS2-HW-V');
  Assert.IsNotNull(Map);
  Assert.IsTrue(Map.Vertical);
  Assert.IsNotNull(Map.Parent, 'usecmap');
  Assert.AreEqual(843, Map.LookupCID($3042, 2), 'through the parent');
  Assert.IsFalse(Map.HasOneByteCodes);
  Map := TPdfCMap.Predefined('90ms-RKSJ-V');
  Assert.IsNotNull(Map.Parent);
  Assert.AreEqual(264, Map.LookupCID($41, 1));
end;

procedure TPdfCMapTests.PredefinedUnknown;
begin
  Assert.IsNull(TPdfCMap.Predefined('NoSuchCMap'));
  Assert.IsNull(TPdfCMap.Predefined(''));
  Assert.IsNull(TPdfCMap.Predefined('unijis-ucs2-h'), 'names are case-sensitive');
  Assert.IsNull(TPdfCMap.LoadPredefined('NoSuchCMap'));
end;

procedure TPdfCMapTests.PredefinedUCS2;
var
  Map: TPdfCMap;
begin
  Map := TPdfCMap.Predefined('Adobe-Japan1-UCS2');
  Assert.IsNotNull(Map);
  Assert.IsTrue(Map.HasUnicodeMappings);
  Assert.AreEqual('A', Map.ToUnicode(34, 2));
  Assert.AreEqual(#$3042, Map.ToUnicode(843, 2));
  Assert.AreEqual(#$4E9C, Map.ToUnicode(1125, 2));
  Assert.IsNotNull(TPdfCMap.Predefined('Adobe-GB1-UCS2'));
  Assert.IsNotNull(TPdfCMap.Predefined('Adobe-CNS1-UCS2'));
  Assert.IsNotNull(TPdfCMap.Predefined('Adobe-Korea1-UCS2'));
end;

procedure TPdfCMapTests.PredefinedLoadTime;
var
  Map: TPdfCMap;
  SW: TStopwatch;
begin
  SW := TStopwatch.StartNew;
  Map := TPdfCMap.LoadPredefined('UniGB-UCS2-H');
  try
    SW.Stop;
    Assert.IsNotNull(Map);
    Assert.IsTrue(SW.ElapsedMilliseconds < 200, Format('UniGB-UCS2-H took %d ms', [SW.ElapsedMilliseconds]));
    Assert.IsTrue(Map.LookupCID($4E00, 2) > 0); // CJK ideograph one
  finally
    Map.Free;
  end;
  SW := TStopwatch.StartNew;
  Map := TPdfCMap.LoadPredefined('UniJIS-UCS2-H');
  try
    SW.Stop;
    Assert.IsTrue(SW.ElapsedMilliseconds < 100, Format('UniJIS-UCS2-H took %d ms', [SW.ElapsedMilliseconds]));
  finally
    Map.Free;
  end;
end;

procedure TPdfCMapTests.PredefinedAllLoad;
var
  Names: TArray<string>;
  Name: string;
  Map: TPdfCMap;
begin
  Names := TPdfCMap.PredefinedNames;
  Assert.AreEqual(168, Integer(Length(Names)));
  for Name in Names do
  begin
    Map := TPdfCMap.Predefined(Name);
    Assert.IsNotNull(Map, Name);
    Assert.AreEqual(Name, Map.Name);
    Assert.IsTrue(Map.HasUnicodeMappings or (Map.LookupCID(0, 1) >= 0), Name);
    if Name.EndsWith('-V') then
      Assert.IsTrue(Map.Vertical, Name);
  end;
end;

procedure TPdfCMapTests.ResourceNames;
begin
  Assert.AreEqual('PDFCMAP_90MS_RKSJ_H', TPdfCMap.ResourceName('90ms-RKSJ-H'));
  Assert.AreEqual('PDFCMAP_UNIJIS_UCS2_HW_V', TPdfCMap.ResourceName('UniJIS-UCS2-HW-V'));
  Assert.AreEqual('PDFCMAP_H', TPdfCMap.ResourceName('H'));
end;

procedure TPdfCMapTests.MalformedText;
const
  Cases: array[0..11] of string = (
    '1 begincodespacerange <00',
    '1 begincodespacerange <00> <ff> 1 begincidrange <41> <42> 50 endcidrange',
    'begincidrange <41> <42>',
    'begincidrange <41> <42> /foo <43> <44> 7 endcidrange',
    'beginbfrange <01> <05> [<0041> <0042>',
    'beginbfrange <01> <05> [<0041> begincidchar <20> 3 endcidchar',
    'beginbfchar <01> endbfchar beginbfchar <> <0041> <0102030405> <0041> endbfchar',
    'begincidchar <01> -5 <02> 1e30 <03> 2.5 endcidchar',
    '/WMode /CMapName 3 usecmap /CMapName usecmap /Identity-H',
    '<< /a [ ( ) { } >> ] ) ( begincodespacerange ] [ << >>',
    'beginbfrange <0005> <0001> <0041> <00> <ff> <> endbfrange',
    '');
var
  S: string;
  Map: TPdfCMap;
  Code, CID, Len, P: Integer;
  D: TBytes;
begin
  for S in Cases do
  begin
    Map := TPdfCMap.Parse(PdfLatin1ToBytes(S));
    try
      Assert.IsNotNull(Map, S);
      D := Bytes([0, 1, 2, $41, $42, $43, $FF]);
      P := 0;
      while P < Length(D) do
      begin
        Map.NextCode(D, P, Code, CID, Len);
        Assert.IsTrue(Len > 0, S);
      end;
      Map.ToUnicode(1, 1);
      Map.LookupCID($41, 1);
    finally
      Map.Free;
    end;
  end;
  // Missing end keywords: the next block still counts
  Map := TPdfCMap.Parse(PdfLatin1ToBytes(Cases[1]));
  try
    Assert.AreEqual(50, Map.LookupCID($41, 1));
    Assert.AreEqual(51, Map.LookupCID($42, 1));
  finally
    Map.Free;
  end;
  Map := TPdfCMap.Parse(PdfLatin1ToBytes(Cases[5]));
  try
    Assert.AreEqual('A', Map.ToUnicode(1, 1));
    Assert.AreEqual(3, Map.LookupCID($20, 1));
  finally
    Map.Free;
  end;
  // Junk inside a block is skipped
  Map := TPdfCMap.Parse(PdfLatin1ToBytes('begincidrange <41> <42> 10 [ 5 ] <43> <44> 7 endcidrange'));
  try
    Assert.AreEqual(11, Map.LookupCID($42, 1));
    Assert.AreEqual(8, Map.LookupCID($44, 1));
  finally
    Map.Free;
  end;
end;

procedure TPdfCMapTests.MalformedRandom;
const
  Tokens: array[0..17] of string = ('begincodespacerange', 'endcodespacerange', 'begincidrange', 'endcidrange',
    'beginbfrange', 'endbfrange', 'beginbfchar', 'endbfchar', 'begincidchar', 'endcidchar', '<00>', '<ffff>',
    '<12345678>', '[', ']', '/WMode', '12', '/Identity-H usecmap');
var
  Round, I, P, Code, CID, Len: Integer;
  D: TBytes;
  S: string;
  Map: TPdfCMap;
begin
  RandSeed := 12345;
  for Round := 1 to 300 do
  begin
    if Round mod 2 = 0 then
    begin
      SetLength(D, Random(400));
      for I := 0 to High(D) do
        D[I] := Byte(Random(256));
    end
    else
    begin
      S := '';
      for I := 1 to Random(60) do
        S := S + Tokens[Random(Length(Tokens))] + ' ';
      D := PdfLatin1ToBytes(S);
    end;
    Map := TPdfCMap.Parse(D);
    try
      Assert.IsNotNull(Map);
      P := 0;
      while P < Length(D) do
      begin
        Map.NextCode(D, P, Code, CID, Len);
        if Len <= 0 then
          Assert.Fail('NextCode did not advance');
      end;
      Map.HasUnicodeMappings;
      Map.ToUnicode(0, 2);
    finally
      Map.Free;
    end;
  end;
end;

procedure TPdfCMapTests.MalformedBinary;
var
  RS: TResourceStream;
  Full, D: TBytes;
  Len, I: Integer;
  Map: TPdfCMap;
begin
  RS := TResourceStream.Create(HInstance, TPdfCMap.ResourceName('90ms-RKSJ-H'), RT_RCDATA);
  try
    SetLength(Full, RS.Size);
    RS.ReadBuffer(Full[0], RS.Size);
  finally
    RS.Free;
  end;
  Map := TPdfCMap.ParseBinary(Full, 'Copy');
  try
    Assert.AreEqual(1125, Map.LookupCID($889F, 2));
  finally
    Map.Free;
  end;
  Len := 0;
  while Len < Length(Full) do
  begin
    D := Copy(Full, 0, Len);
    Map := TPdfCMap.ParseBinary(D);
    Map.Free;
    Inc(Len, 7);
  end;
  RandSeed := 777;
  for I := 1 to 100 do
  begin
    D := Copy(Full);
    D[Random(Length(D))] := Byte(Random(256));
    D[Random(Length(D))] := Byte(Random(256));
    Map := TPdfCMap.ParseBinary(D);
    Map.Free;
  end;
  Assert.Pass;
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfCMapTests);

end.
