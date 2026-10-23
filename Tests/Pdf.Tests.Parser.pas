unit Pdf.Tests.Parser;

interface

uses
  System.SysUtils, DUnitX.TestFramework, Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Parser;

type
  [TestFixture]
  TPdfObjectTests = class
  public
    [Test] procedure Factories;
    [Test] procedure DictionaryTypedGetters;
    [Test] procedure ArrayTypedGetters;
    [Test] procedure TextStringDecoding;
    [Test] procedure ToTextRoundTrip;
  end;

  [TestFixture]
  TPdfParserTests = class
  public
    [Test] procedure Scalars;
    [Test] procedure References;
    [Test] procedure NestedContainers;
    [Test] procedure DictionaryWithMissingValueAndGarbageKey;
    [Test] procedure UnterminatedContainersStopAtEndobj;
    [Test] procedure StreamWithCorrectLength;
    [Test] procedure StreamWithWrongLength;
    [Test] procedure StreamWithoutEndstream;
    [Test] procedure StreamWithIndirectLength;
    [Test] procedure IndirectObject;
    [Test] procedure EmptyIndirectObject;
    [Test] procedure ContentStreamOperators;
    [Test] procedure DeepNestingDoesNotOverflow;
    [Test] procedure FilterChainDecodesStream;
  end;

  /// <summary>Minimal resolver for tests: a fixed set of objects by number.</summary>
  TTestResolver = class(TInterfacedObject, IPdfResolver)
  private
    FObjects: TArray<IPdfObject>;
  public
    constructor Create(const Objects: array of IPdfObject);
    function Resolve(const Obj: IPdfObject): IPdfObject;
    function FetchObject(Num, Gen: Integer): IPdfObject;
  end;

implementation

uses
  System.ZLib, System.Classes;

{ TTestResolver }

constructor TTestResolver.Create(const Objects: array of IPdfObject);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FObjects, Length(Objects));
  for I := 0 to High(Objects) do
    FObjects[I] := Objects[I];
end;

function TTestResolver.FetchObject(Num, Gen: Integer): IPdfObject;
begin
  if (Num >= 0) and (Num < Length(FObjects)) and (FObjects[Num] <> nil) then
    Result := FObjects[Num]
  else
    Result := PdfNull;
end;

function TTestResolver.Resolve(const Obj: IPdfObject): IPdfObject;
var
  Ref: IPdfReference;
begin
  Result := Obj;
  while (Result <> nil) and (Result.Kind = okReference) do
  begin
    Ref := Result as IPdfReference;
    Result := FetchObject(Ref.Num, Ref.Gen);
  end;
  if Result = nil then
    Result := PdfNull;
end;

{ TPdfObjectTests }

procedure TPdfObjectTests.Factories;
begin
  Assert.AreEqual(okNull, PdfNull.Kind);
  Assert.AreEqual(okBoolean, PdfBoolean(True).Kind);
  Assert.IsTrue(PdfBoolean(True).Value);
  Assert.AreEqual(okInteger, PdfInteger(5).Kind);
  Assert.AreEqual(okReal, PdfReal(5.5).Kind);
  Assert.AreEqual<Int64>(5, PdfReal(5.9).IntValue);
  Assert.AreEqual('Abc', PdfName('Abc').Name);
  Assert.AreEqual(3, PdfReference(3, 1).Num);
  Assert.AreEqual(1, PdfReference(3, 1).Gen);
  Assert.AreEqual('Tj', PdfOperator('Tj').Name);
  Assert.IsTrue(PdfIsNull(nil));
  Assert.IsTrue(PdfIsName(PdfName('X'), 'X'));
  Assert.IsFalse(PdfIsName(PdfName('X'), 'Y'));
end;

procedure TPdfObjectTests.DictionaryTypedGetters;
var
  D: IPdfDictionary;
  R: TPdfRectangle;
begin
  D := PdfAsDictionary(PdfParseObject('<< /Type /Page /Count 3 /W 1.5 /Flag true /Name /N /Box [1 2 3 4] /Sub << /A 1 >> /S (txt) /Bad [1 2] >>'));
  Assert.IsNotNull(D);
  Assert.AreEqual(9, D.Count);
  Assert.IsTrue(D.IsType('Page'));
  Assert.AreEqual<Int64>(3, D.GetInteger('Count'));
  Assert.AreEqual<Int64>(7, D.GetInteger('Missing', 7));
  Assert.AreEqual(1.5, D.GetNumber('W'), 1E-9);
  Assert.AreEqual(3.0, D.GetNumber('Count'), 1E-9);
  Assert.IsTrue(D.GetBoolean('Flag'));
  Assert.AreEqual('N', D.GetName('Name'));
  Assert.AreEqual('', D.GetName('Count'));
  Assert.IsTrue(D.GetRectangle('Box', R));
  Assert.AreEqual(1.0, R.X0, 1E-9);
  Assert.AreEqual(4.0, R.Y1, 1E-9);
  Assert.IsFalse(D.GetRectangle('Bad', R));
  Assert.IsNotNull(D.GetDictionary('Sub'));
  Assert.AreEqual<Int64>(1, D.GetDictionary('Sub').GetInteger('A'));
  Assert.IsNull(D.GetDictionary('Count'));
  Assert.AreEqual('txt', D.GetString('S').AsText);
  Assert.IsTrue(PdfIsNull(D.Get('Missing')));
  Assert.IsNull(D.GetRaw('Missing'));
  Assert.AreEqual('Type', D.Keys[0]);
  D.Remove('Type');
  Assert.IsFalse(D.Contains('Type'));
  Assert.AreEqual(8, D.Count);
end;

procedure TPdfObjectTests.ArrayTypedGetters;
var
  A: IPdfArray;
  V: TArray<Double>;
begin
  A := PdfAsArray(PdfParseObject('[1 2.5 /N [3] << /K 1 >> (s)]'));
  Assert.AreEqual(6, A.Count);
  Assert.AreEqual<Int64>(1, A.GetInteger(0));
  Assert.AreEqual(2.5, A.GetNumber(1), 1E-9);
  Assert.AreEqual('N', A.GetName(2));
  Assert.AreEqual(1, A.GetArray(3).Count);
  Assert.AreEqual<Int64>(1, A.GetDictionary(4).GetInteger('K'));
  Assert.IsTrue(A.GetNumbers(V, 2));
  Assert.AreEqual(2, Integer(Length(V)));
  Assert.IsFalse(A.GetNumbers(V));
  Assert.IsTrue(PdfIsNull(A.Get(99)));
  A[0] := PdfInteger(42);
  Assert.AreEqual<Int64>(42, A.GetInteger(0));
end;

procedure TPdfObjectTests.TextStringDecoding;
begin
  Assert.AreEqual('Hello', PdfDecodeTextString(PdfLatin1ToBytes('Hello')));
  Assert.AreEqual('H'#$00E9, PdfDecodeTextString(TBytes.Create($FE, $FF, 0, Ord('H'), 0, $E9)));
  Assert.AreEqual('H'#$00E9, PdfDecodeTextString(TBytes.Create($EF, $BB, $BF, Ord('H'), $C3, $A9)));
  // PDFDocEncoding specials: 0x80 bullet, 0x92 trademark, 0xA0 euro
  Assert.AreEqual(#$2022#$2122#$20AC, PdfDecodeTextString(TBytes.Create($80, $92, $A0)));
  Assert.AreEqual('', PdfDecodeTextString(nil));
end;

procedure TPdfObjectTests.ToTextRoundTrip;
const
  Src = '<</Type /Page /Kids [1 0 R 2 0 R] /Name /A#20B /S (a\)b) /H <4140> /N -0.5 /T true /Z null>>';
var
  O: IPdfObject;
begin
  O := PdfParseObject(Src);
  Assert.AreEqual(Src, O.ToText);
  Assert.AreEqual(Src, PdfParseObject(O.ToText).ToText);
end;

{ TPdfParserTests }

procedure TPdfParserTests.Scalars;
begin
  Assert.AreEqual(okInteger, PdfParseObject('12').Kind);
  Assert.AreEqual(okReal, PdfParseObject('-1.5').Kind);
  Assert.AreEqual(okBoolean, PdfParseObject('false').Kind);
  Assert.AreEqual(okNull, PdfParseObject('null').Kind);
  Assert.AreEqual(okNull, PdfParseObject('').Kind);
  Assert.AreEqual(okString, PdfParseObject('(x)').Kind);
  Assert.AreEqual(okName, PdfParseObject('/x').Kind);
  Assert.AreEqual(okOperator, PdfParseObject('foo').Kind);
end;

procedure TPdfParserTests.References;
var
  O: IPdfObject;
  A: IPdfArray;
begin
  O := PdfParseObject('12 0 R');
  Assert.AreEqual(okReference, O.Kind);
  Assert.AreEqual(12, (O as IPdfReference).Num);
  A := PdfAsArray(PdfParseObject('[1 0 R 2 3 4 0 R 5]'));
  Assert.AreEqual(5, A.Count);
  Assert.AreEqual(okReference, A[0].Kind);
  Assert.AreEqual(okInteger, A[1].Kind);
  Assert.AreEqual(okInteger, A[2].Kind);
  Assert.AreEqual(okReference, A[3].Kind);
  Assert.AreEqual(4, (A[3] as IPdfReference).Num);
  Assert.AreEqual<Int64>(5, A.GetInteger(4));
  // Negative numbers are never part of a reference
  A := PdfAsArray(PdfParseObject('[-1 0 R]'));
  Assert.AreEqual(3, A.Count);
end;

procedure TPdfParserTests.NestedContainers;
var
  D: IPdfDictionary;
begin
  D := PdfAsDictionary(PdfParseObject('<< /A [ [1 2] << /B [3] >> ] /C << /D << /E 5 >> >> >>'));
  Assert.AreEqual(2, D.GetArray('A').Count);
  Assert.AreEqual<Int64>(2, D.GetArray('A').GetArray(0).GetInteger(1));
  Assert.AreEqual<Int64>(3, D.GetArray('A').GetDictionary(1).GetArray('B').GetInteger(0));
  Assert.AreEqual<Int64>(5, D.GetDictionary('C').GetDictionary('D').GetInteger('E'));
end;

procedure TPdfParserTests.DictionaryWithMissingValueAndGarbageKey;
var
  D: IPdfDictionary;
begin
  D := PdfAsDictionary(PdfParseObject('<< /A 1 /B /C 3 42 /D 4 /E >>'));
  Assert.AreEqual<Int64>(1, D.GetInteger('A'));
  Assert.AreEqual('C', D.GetName('B'));
  Assert.AreEqual<Int64>(4, D.GetInteger('D'));
  Assert.IsFalse(D.Contains('E'));
  Assert.IsFalse(D.Contains('42'));
end;

procedure TPdfParserTests.UnterminatedContainersStopAtEndobj;
var
  P: TPdfParser;
  O: IPdfObject;
  Num, Gen: Integer;
begin
  P := TPdfParser.Create(PdfLatin1ToBytes('1 0 obj << /A [1 2 endobj 2 0 obj 7 endobj'));
  try
    O := P.ParseIndirectObject(Num, Gen);
    Assert.AreEqual(1, Num);
    Assert.AreEqual(okDictionary, O.Kind);
    Assert.AreEqual(2, PdfAsDictionary(O).GetArray('A').Count);
    O := P.ParseIndirectObject(Num, Gen);
    Assert.AreEqual(2, Num);
    Assert.AreEqual<Int64>(7, PdfAsInteger(O));
  finally
    P.Free;
  end;
end;

procedure TPdfParserTests.StreamWithCorrectLength;
var
  S: IPdfStream;
begin
  S := PdfAsStream(PdfParseObject('<< /Length 5 >>stream'#13#10'ABCDE'#13#10'endstream'));
  Assert.IsNotNull(S);
  Assert.AreEqual('ABCDE', PdfBytesToLatin1(S.RawData));
  Assert.AreEqual('ABCDE', PdfBytesToLatin1(S.GetDecodedData));
  // LF only, and data containing 'endstream' text
  S := PdfAsStream(PdfParseObject('<< /Length 12 >>stream'#10'xxendstream!'#10'endstream'));
  Assert.AreEqual('xxendstream!', PdfBytesToLatin1(S.RawData));
end;

procedure TPdfParserTests.StreamWithWrongLength;
var
  S: IPdfStream;
begin
  S := PdfAsStream(PdfParseObject('<< /Length 99 >>stream'#13#10'ABCDE'#13#10'endstream'#10'endobj'));
  Assert.AreEqual('ABCDE', PdfBytesToLatin1(S.RawData));
  S := PdfAsStream(PdfParseObject('<< /Length 2 >>stream'#10'ABCDE'#10'endstream'));
  Assert.AreEqual('ABCDE', PdfBytesToLatin1(S.RawData));
  S := PdfAsStream(PdfParseObject('<< >>stream'#10'ABCDE'#13'endstream'));
  Assert.AreEqual('ABCDE', PdfBytesToLatin1(S.RawData));
end;

procedure TPdfParserTests.StreamWithoutEndstream;
var
  P: TPdfParser;
  O: IPdfObject;
  Num, Gen: Integer;
begin
  P := TPdfParser.Create(PdfLatin1ToBytes('3 0 obj << /Length 100 >> stream'#10'DATA'#10'endobj 4 0 obj 1 endobj'));
  try
    O := P.ParseIndirectObject(Num, Gen);
    Assert.AreEqual(okStream, O.Kind);
    Assert.AreEqual('DATA', PdfBytesToLatin1(PdfAsStream(O).RawData));
    O := P.ParseIndirectObject(Num, Gen);
    Assert.AreEqual(4, Num);
  finally
    P.Free;
  end;
end;

procedure TPdfParserTests.StreamWithIndirectLength;
var
  R: IPdfResolver;
  S: IPdfStream;
begin
  R := TTestResolver.Create([nil, PdfInteger(5)]);
  S := PdfAsStream(PdfParseObject('<< /Length 1 0 R >>stream'#10'ABCDEendstream', R));
  Assert.AreEqual('ABCDE', PdfBytesToLatin1(S.RawData));
end;

procedure TPdfParserTests.IndirectObject;
var
  P: TPdfParser;
  O: IPdfObject;
  Num, Gen: Integer;
begin
  P := TPdfParser.Create(PdfLatin1ToBytes('% comment'#10'12 3 obj'#13#10'<< /K (v) >>'#10'endobj'#10'trailer'));
  try
    Assert.IsTrue(P.AtObjectHeader(Num, Gen));
    Assert.AreEqual(12, Num);
    O := P.ParseIndirectObject(Num, Gen);
    Assert.AreEqual(12, Num);
    Assert.AreEqual(3, Gen);
    Assert.AreEqual(okDictionary, O.Kind);
    Assert.IsTrue(P.ParseObject.Kind = okOperator);
  finally
    P.Free;
  end;
  P := TPdfParser.Create(PdfLatin1ToBytes('<< >>'));
  try
    Assert.IsFalse(P.AtObjectHeader(Num, Gen));
    Assert.WillRaise(procedure begin P.ParseIndirectObject(Num, Gen); end, EPdfSyntaxError);
  finally
    P.Free;
  end;
end;

procedure TPdfParserTests.EmptyIndirectObject;
var
  P: TPdfParser;
  O: IPdfObject;
  Num, Gen: Integer;
begin
  P := TPdfParser.Create(PdfLatin1ToBytes('5 0 obj endobj 6 0 obj'));
  try
    O := P.ParseIndirectObject(Num, Gen);
    Assert.AreEqual(okNull, O.Kind);
    O := P.ParseIndirectObject(Num, Gen);
    Assert.AreEqual(6, Num);
    Assert.AreEqual(okNull, O.Kind);
  finally
    P.Free;
  end;
end;

procedure TPdfParserTests.ContentStreamOperators;
var
  P: TPdfParser;
  Objs: TArray<IPdfObject>;
  O: IPdfObject;
begin
  P := TPdfParser.Create(PdfLatin1ToBytes('q 1 0 0 1 10 20 cm BT /F1 12 Tf (Hi) Tj T* ET Q BI /W 1 ID x EI'), 0, nil, False);
  try
    repeat
      O := P.ParseObject;
      if O <> nil then
        Objs := Objs + [O];
    until O = nil;
  finally
    P.Free;
  end;
  Assert.AreEqual(23, Integer(Length(Objs)));
  Assert.IsTrue(PdfIsOperator(Objs[0], 'q'));
  Assert.IsTrue(PdfIsOperator(Objs[7], 'cm'));
  Assert.AreEqual<Int64>(10, PdfAsInteger(Objs[5]));
  Assert.IsTrue(PdfIsOperator(Objs[8], 'BT'));
  Assert.IsTrue(PdfIsOperator(Objs[14], 'T*'));
  Assert.IsTrue(PdfIsOperator(Objs[16], 'Q'));
  Assert.IsTrue(PdfIsOperator(Objs[17], 'BI'));
end;

procedure TPdfParserTests.DeepNestingDoesNotOverflow;
var
  S: string;
  O: IPdfObject;
begin
  S := StringOfChar('[', 5000) + '1' + StringOfChar(']', 5000);
  O := PdfParseObject(S);
  Assert.AreEqual(okArray, O.Kind);
end;

procedure TPdfParserTests.FilterChainDecodesStream;
var
  Plain, Deflated: TBytes;
  Hex: string;
  I: Integer;
  S: IPdfStream;
begin
  Plain := PdfLatin1ToBytes('Hello filter chain, hello filter chain, hello filter chain.');
  ZCompress(Plain, Deflated);
  Hex := '';
  for I := 0 to High(Deflated) do
    Hex := Hex + IntToHex(Deflated[I], 2);
  S := PdfAsStream(PdfParseObject('<< /Filter [/AHx /Fl] /Length ' + IntToStr(Length(Hex) + 1) + ' >>stream'#10 + Hex + '>'#10'endstream'));
  Assert.IsNotNull(S);
  Assert.AreEqual(2, Integer(Length(S.GetFilterNames)));
  Assert.AreEqual('ASCIIHexDecode', S.GetFilterNames[0]);
  Assert.AreEqual('FlateDecode', S.GetFilterNames[1]);
  Assert.AreEqual(PdfBytesToLatin1(Plain), PdfBytesToLatin1(S.GetDecodedData));
  Assert.AreEqual('', S.ImageFilter);
  // Image filter stays in place
  S := PdfAsStream(PdfParseObject('<< /Filter [/AHx /DCTDecode] /DecodeParms [null << /K -1 >>] >>stream'#10'4142>'#10'endstream'));
  Assert.AreEqual('AB', PdfBytesToLatin1(S.GetDecodedData));
  Assert.AreEqual('DCTDecode', S.ImageFilter);
  Assert.IsNotNull(S.ImageFilterParms);
  Assert.AreEqual<Int64>(-1, S.ImageFilterParms.GetInteger('K'));
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfObjectTests);
  TDUnitX.RegisterTestFixture(TPdfParserTests);

end.
