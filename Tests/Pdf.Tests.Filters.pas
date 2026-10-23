{*******************************************************************************
  Pdf.Tests.Filters
  DUnitX tests for Pdf.Core.Filters.
*******************************************************************************}
unit Pdf.Tests.Filters;

interface

uses
  System.SysUtils, System.Classes, System.ZLib, System.Generics.Collections,
  DUnitX.TestFramework, Pdf.Core.Types, Pdf.Core.Filters;

type
  [TestFixture]
  TFlateDecodeTests = class
  public
    [Test] procedure RoundTrip;
    [Test] procedure LargeRoundTrip;
    [Test] procedure LeadingGarbageSkipped;
    [Test] procedure TruncatedReturnsPrefix;
    [Test] procedure CorruptTailKeepsPrefix;
    [Test] procedure RawDeflate;
    [Test] procedure EmptyInput;
    [Test] procedure GarbageRaises;
  end;

  [TestFixture]
  TLZWDecodeTests = class
  public
    [Test] procedure SpecExample;
    [Test] procedure EncoderRoundTripText;
    [Test] procedure EncoderRoundTripRandomEarlyChange1;
    [Test] procedure EncoderRoundTripRandomEarlyChange0;
    [Test] procedure KwKwKRuns;
    [Test] procedure TruncatedWithoutEod;
    [Test] procedure EmptyInput;
  end;

  [TestFixture]
  TASCIIFilterTests = class
  public
    [Test] procedure A85KnownVector;
    [Test] procedure A85Prefix;
    [Test] procedure A85ZeroGroup;
    [Test] procedure A85Whitespace;
    [Test] procedure A85PartialGroup;
    [Test] procedure A85NoEod;
    [Test] procedure A85EmptyAndEodOnly;
    [Test] procedure A85Garbage;
    [Test] procedure AHxHello;
    [Test] procedure AHxOddDigit;
    [Test] procedure AHxWhitespaceAndCase;
    [Test] procedure AHxEmpty;
  end;

  [TestFixture]
  TRunLengthTests = class
  public
    [Test] procedure LiteralRun;
    [Test] procedure RepeatRun;
    [Test] procedure StopsAtEod;
    [Test] procedure Truncated;
    [Test] procedure EmptyInput;
  end;

  [TestFixture]
  TPredictorTests = class
  public
    [Test] procedure NoPredictor;
    [Test] procedure PngNoneSubUp;
    [Test] procedure PngAveragePaeth;
    [Test] procedure PngMultiByteSub;
    [Test] procedure PngTruncatedLastRow;
    [Test] procedure ZeroParamsDefaulted;
    [Test] procedure Tiff8Bit;
    [Test] procedure Tiff16Bit;
    [Test] procedure Tiff1Bit;
    [Test] procedure Tiff4Bit;
    [Test] procedure FlateWithPngPredictor;
  end;

  [TestFixture]
  TFilterNameTests = class
  public
    [Test] procedure Normalize;
    [Test] procedure ImageFilters;
    [Test] procedure ApplyFilterDispatch;
    [Test] procedure ApplyFilterUnknownRaises;
    [Test] procedure ApplyFilterImageRaises;
  end;

implementation

{ Helpers }

function Hex(const Data: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Integer(Length(Data)) - 1 do
  begin
    if I > 0 then
      Result := Result + ' ';
    Result := Result + IntToHex(Data[I], 2);
  end;
end;

function FromHex(const S: string): TBytes;
var
  Digits: string;
  I: Integer;
begin
  Digits := StringReplace(S, ' ', '', [rfReplaceAll]);
  SetLength(Result, Length(Digits) div 2);
  for I := 0 to Integer(Length(Result)) - 1 do
    Result[I] := Byte(StrToInt('$' + Copy(Digits, I * 2 + 1, 2)));
end;

function Bytes(const S: string): TBytes;
begin
  Result := PdfLatin1ToBytes(S);
end;

function AsText(const Data: TBytes): string;
begin
  Result := PdfBytesToLatin1(Data);
end;

function SampleText: string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to 200 do
    Result := Result + Format('Line %d: The quick brown fox jumps over the lazy dog. ', [I]);
end;

/// Deterministic pseudo-random bytes (LCG), no global RandSeed.
function PseudoRandomBytes(Count: Integer; Seed: Cardinal): TBytes;
var
  I: Integer;
  X: Cardinal;
begin
  SetLength(Result, Count);
  X := Seed;
  for I := 0 to Count - 1 do
  begin
    X := Cardinal((UInt64(X) * 1103515245 + 12345) and $FFFFFFFF);
    Result[I] := Byte(X shr 16);
  end;
end;

function Compress(const Data: TBytes): TBytes;
begin
  ZCompress(Data, Result);
end;

function CompressRaw(const Data: TBytes): TBytes;
var
  Dest: TBytesStream;
  Z: TZCompressionStream;
begin
  Dest := TBytesStream.Create;
  try
    Z := TZCompressionStream.Create(Dest, zcDefault, -15);
    try
      if Length(Data) > 0 then
        Z.WriteBuffer(Data[0], Length(Data));
    finally
      Z.Free;
    end;
    Result := Copy(Dest.Bytes, 0, Dest.Size);
  finally
    Dest.Free;
  end;
end;

/// Code width the decoder uses after it has defined entries up to NextCode.
function LzwWidth(N: Integer): Integer;
begin
  if N >= 2048 then
    Result := 12
  else if N >= 1024 then
    Result := 11
  else if N >= 512 then
    Result := 10
  else
    Result := 9;
end;

/// Minimal LZW encoder (PDF 32000-1 7.4.4) used to produce test input. It
/// emits a clear code first, a clear code when the table is nearly full, and
/// an EOD code at the end. The decoder lags the encoder by one table entry,
/// hence the "- 1" in the code width for regular codes.
function LzwEncode(const Data: TBytes; EarlyChange: Integer): TBytes;
var
  Dict: TDictionary<Integer, Integer>;
  BitBuf: UInt64;
  BitCount: Integer;
  Output: TList<Byte>;
  NextCode, W, Code, I: Integer;
  C: Byte;

  procedure Emit(Value, Width: Integer);
  begin
    BitBuf := (BitBuf shl Width) or UInt64(Value);
    Inc(BitCount, Width);
    while BitCount >= 8 do
    begin
      Output.Add(Byte(BitBuf shr (BitCount - 8)));
      Dec(BitCount, 8);
      BitBuf := BitBuf and ((UInt64(1) shl BitCount) - 1);
    end;
  end;

begin
  Dict := TDictionary<Integer, Integer>.Create;
  Output := TList<Byte>.Create;
  try
    BitBuf := 0;
    BitCount := 0;
    NextCode := 258;
    Emit(256, 9);
    W := -1;
    for I := 0 to Integer(Length(Data)) - 1 do
    begin
      C := Data[I];
      if W < 0 then
        W := C
      else if Dict.TryGetValue(W * 256 + C, Code) then
        W := Code
      else
      begin
        Emit(W, LzwWidth(NextCode - 1 + EarlyChange));
        Dict.Add(W * 256 + C, NextCode);
        Inc(NextCode);
        if NextCode >= 4000 then
        begin
          Emit(256, LzwWidth(NextCode - 1 + EarlyChange));
          Dict.Clear;
          NextCode := 258;
        end;
        W := C;
      end;
    end;
    if W >= 0 then
      Emit(W, LzwWidth(NextCode - 1 + EarlyChange));
    Emit(257, LzwWidth(NextCode + EarlyChange));
    if BitCount > 0 then
      Output.Add(Byte(BitBuf shl (8 - BitCount)));
    Result := Output.ToArray;
  finally
    Output.Free;
    Dict.Free;
  end;
end;

function PngParams(Colors, Bits, Columns: Integer): TPdfFilterParams;
begin
  Result := TPdfFilterParams.Default;
  Result.Predictor := 15;
  Result.Colors := Colors;
  Result.BitsPerComponent := Bits;
  Result.Columns := Columns;
end;

function TiffParams(Colors, Bits, Columns: Integer): TPdfFilterParams;
begin
  Result := PngParams(Colors, Bits, Columns);
  Result.Predictor := 2;
end;

{ TFlateDecodeTests }

procedure TFlateDecodeTests.RoundTrip;
var
  Text: string;
begin
  Text := 'Hello, PDF world! Hello, PDF world! Hello, PDF world!';
  Assert.AreEqual(Text, AsText(PdfFlateDecode(Compress(Bytes(Text)))));
end;

procedure TFlateDecodeTests.LargeRoundTrip;
var
  Input, Output: TBytes;
  I: Integer;
begin
  // Highly compressible: output is far larger than the initial buffer guess.
  SetLength(Input, 3 * 1024 * 1024);
  for I := 0 to Integer(Length(Input)) - 1 do
    Input[I] := Byte(I mod 7);
  Output := PdfFlateDecode(Compress(Input));
  Assert.AreEqual(Integer(Length(Input)), Integer(Length(Output)));
  Assert.IsTrue(CompareMem(@Input[0], @Output[0], Length(Input)));
end;

procedure TFlateDecodeTests.LeadingGarbageSkipped;
var
  Text: string;
begin
  Text := SampleText;
  Assert.AreEqual(Text, AsText(PdfFlateDecode(PdfConcatBytes(FromHex('0D 0A 20 00 FF 41'),
    Compress(Bytes(Text))))));
end;

procedure TFlateDecodeTests.TruncatedReturnsPrefix;
var
  Text, Decoded: string;
  Zipped: TBytes;
begin
  Text := AsText(PseudoRandomBytes(20000, 7)); // incompressible: output tracks input
  Zipped := Compress(Bytes(Text));
  Decoded := AsText(PdfFlateDecode(PdfCopyBytes(Zipped, 0, Integer(Length(Zipped)) div 2)));
  Assert.IsTrue(Length(Decoded) > 5000, 'expected a substantial prefix, got ' + IntToStr(Length(Decoded)));
  Assert.IsTrue(Length(Decoded) < Length(Text));
  Assert.AreEqual(Copy(Text, 1, Length(Decoded)), Decoded);
end;

procedure TFlateDecodeTests.CorruptTailKeepsPrefix;
var
  Text, Decoded: string;
  Zipped: TBytes;
begin
  Text := SampleText;
  Zipped := Compress(Bytes(Text));
  // Break the Adler-32 checksum: all data is still delivered.
  Zipped[High(Zipped)] := Zipped[High(Zipped)] xor $FF;
  Decoded := AsText(PdfFlateDecode(Zipped));
  Assert.AreEqual(Text, Decoded);
end;

procedure TFlateDecodeTests.RawDeflate;
var
  Text: string;
begin
  Text := SampleText;
  Assert.AreEqual(Text, AsText(PdfFlateDecode(CompressRaw(Bytes(Text)))));
end;

procedure TFlateDecodeTests.EmptyInput;
begin
  Assert.AreEqual(0, Integer(Length(PdfFlateDecode(nil))));
  Assert.AreEqual(0, Integer(Length(PdfFlateDecode(Bytes(#13#10)))));
  Assert.AreEqual(0, Integer(Length(PdfFlateDecode(Compress(nil)))));
end;

procedure TFlateDecodeTests.GarbageRaises;
begin
  Assert.WillRaise(
    procedure
    begin
      PdfFlateDecode(FromHex('FF FF FF FF FF FF FF FF'));
    end, EPdfFilterError);
end;

{ TLZWDecodeTests }

procedure TLZWDecodeTests.SpecExample;
begin
  // PDF 32000-1:2008 section 7.4.4.2, Example 2: the input sequence (decimal)
  // 45 45 45 45 45 65 45 45 45 66, i.e. '-----A---B', encodes to the codes
  // 256 45 258 258 65 259 66 257 = bytes 80 0B 60 50 22 0C 0C 85 01.
  Assert.AreEqual('-----A---B', AsText(PdfLZWDecode(FromHex('80 0B 60 50 22 0C 0C 85 01'))));
  Assert.AreEqual(Hex(FromHex('80 0B 60 50 22 0C 0C 85 01')), Hex(LzwEncode(Bytes('-----A---B'), 1)));
end;

procedure TLZWDecodeTests.EncoderRoundTripText;
var
  Text: string;
begin
  Text := SampleText;
  Assert.AreEqual(Text, AsText(PdfLZWDecode(LzwEncode(Bytes(Text), 1))));
  Assert.AreEqual(Text, AsText(PdfLZWDecode(LzwEncode(Bytes(Text), 0), 0)));
end;

procedure TLZWDecodeTests.EncoderRoundTripRandomEarlyChange1;
var
  Input: TBytes;
begin
  // Enough codes to pass all width changes and a table reset.
  Input := PseudoRandomBytes(12000, 42);
  Assert.AreEqual(Hex(Input), Hex(PdfLZWDecode(LzwEncode(Input, 1), 1)));
end;

procedure TLZWDecodeTests.EncoderRoundTripRandomEarlyChange0;
var
  Input: TBytes;
begin
  Input := PseudoRandomBytes(12000, 99);
  Assert.AreEqual(Hex(Input), Hex(PdfLZWDecode(LzwEncode(Input, 0), 0)));
end;

procedure TLZWDecodeTests.KwKwKRuns;
var
  Input: TBytes;
begin
  SetLength(Input, 5000);
  FillChar(Input[0], Length(Input), Ord('a'));
  Assert.AreEqual(Hex(Input), Hex(PdfLZWDecode(LzwEncode(Input, 1))));
end;

procedure TLZWDecodeTests.TruncatedWithoutEod;
var
  Encoded: TBytes;
begin
  Encoded := LzwEncode(Bytes('-----A---B'), 1);
  // Drop the last two bytes (EOD and part of the last code).
  Assert.AreEqual('-----A---', AsText(PdfLZWDecode(PdfCopyBytes(Encoded, 0, Integer(Length(Encoded)) - 2))));
end;

procedure TLZWDecodeTests.EmptyInput;
begin
  Assert.AreEqual(0, Integer(Length(PdfLZWDecode(nil))));
  // Clear + EOD only: a valid empty stream (256, 257 in 9 bits).
  Assert.AreEqual(0, Integer(Length(PdfLZWDecode(FromHex('80 40 40')))));
end;

{ TASCIIFilterTests }

procedure TASCIIFilterTests.A85KnownVector;
// The classic vector '87cURD]i,"Ebo80' decodes to 'Hello World!' (12 bytes).
begin
  Assert.AreEqual('Hello World!', AsText(PdfASCII85Decode(Bytes('87cURD]i,"Ebo80~>'))));
end;

procedure TASCIIFilterTests.A85Prefix;
begin
  Assert.AreEqual('Hello World!', AsText(PdfASCII85Decode(Bytes('  <~87cURD]i,"Ebo80~>'))));
end;

procedure TASCIIFilterTests.A85ZeroGroup;
begin
  Assert.AreEqual('00 00 00 00 48 65 6C 6C 00 00 00 00 00 00 00 00',
    Hex(PdfASCII85Decode(Bytes('z87cURzz~>'))));
  Assert.AreEqual('00 00 00 00 00 00 00 00', Hex(PdfASCII85Decode(Bytes('zz~>'))));
end;

procedure TASCIIFilterTests.A85Whitespace;
begin
  Assert.AreEqual('Hello World!', AsText(PdfASCII85Decode(Bytes('87cU'#13#10'RD]i ,"E'#9'bo80'#10'~>'))));
end;

procedure TASCIIFilterTests.A85PartialGroup;
begin
  // 'Hello' = 87cUR (Hell) + DZ (o).
  Assert.AreEqual('Hello', AsText(PdfASCII85Decode(Bytes('87cURDZ~>'))));
  Assert.AreEqual('Hel', AsText(PdfASCII85Decode(Bytes('87cU~>'))));
  Assert.AreEqual('He', AsText(PdfASCII85Decode(Bytes('87c~>'))));
end;

procedure TASCIIFilterTests.A85NoEod;
begin
  Assert.AreEqual('Hello World!', AsText(PdfASCII85Decode(Bytes('87cURD]i,"Ebo80'))));
end;

procedure TASCIIFilterTests.A85EmptyAndEodOnly;
begin
  Assert.AreEqual(0, Integer(Length(PdfASCII85Decode(nil))));
  Assert.AreEqual(0, Integer(Length(PdfASCII85Decode(Bytes('~>')))));
  Assert.AreEqual(0, Integer(Length(PdfASCII85Decode(Bytes('<~~>')))));
end;

procedure TASCIIFilterTests.A85Garbage;
begin
  Assert.WillRaise(
    procedure
    begin
      PdfASCII85Decode(Bytes('{|}'));
    end, EPdfFilterError);
end;

procedure TASCIIFilterTests.AHxHello;
begin
  Assert.AreEqual('Hello', AsText(PdfASCIIHexDecode(Bytes('48656C6C6F>'))));
  Assert.AreEqual('Hello', AsText(PdfASCIIHexDecode(Bytes('48656C6C6F>4142'))));
end;

procedure TASCIIFilterTests.AHxOddDigit;
begin
  Assert.AreEqual('41 50', Hex(PdfASCIIHexDecode(Bytes('415>'))));
  Assert.AreEqual('41 50', Hex(PdfASCIIHexDecode(Bytes('415'))));
end;

procedure TASCIIFilterTests.AHxWhitespaceAndCase;
begin
  Assert.AreEqual('Hello', AsText(PdfASCIIHexDecode(Bytes(' 48 65'#13#10'6c 6C'#9'6f >'))));
end;

procedure TASCIIFilterTests.AHxEmpty;
begin
  Assert.AreEqual(0, Integer(Length(PdfASCIIHexDecode(nil))));
  Assert.AreEqual(0, Integer(Length(PdfASCIIHexDecode(Bytes('>')))));
  Assert.WillRaise(
    procedure
    begin
      PdfASCIIHexDecode(Bytes('xyz'));
    end, EPdfFilterError);
end;

{ TRunLengthTests }

procedure TRunLengthTests.LiteralRun;
begin
  Assert.AreEqual('ABC', AsText(PdfRunLengthDecode(FromHex('02 41 42 43 80'))));
end;

procedure TRunLengthTests.RepeatRun;
begin
  // 257 - 253 = 4 copies; 257 - 129 = 128 copies.
  Assert.AreEqual('XXXX', AsText(PdfRunLengthDecode(FromHex('FD 58 80'))));
  Assert.AreEqual(128, Integer(Length(PdfRunLengthDecode(FromHex('81 00 80')))));
  Assert.AreEqual('AB' + 'ZZZ' + 'C', AsText(PdfRunLengthDecode(FromHex('01 41 42 FE 5A 00 43 80'))));
end;

procedure TRunLengthTests.StopsAtEod;
begin
  Assert.AreEqual('A', AsText(PdfRunLengthDecode(FromHex('00 41 80 02 42 43 44'))));
  Assert.AreEqual(0, Integer(Length(PdfRunLengthDecode(FromHex('80 00 41')))));
end;

procedure TRunLengthTests.Truncated;
begin
  Assert.AreEqual('AB', AsText(PdfRunLengthDecode(FromHex('05 41 42'))));
  Assert.AreEqual('A', AsText(PdfRunLengthDecode(FromHex('00 41 FD'))));
  Assert.WillRaise(
    procedure
    begin
      PdfRunLengthDecode(FromHex('FD'));
    end, EPdfFilterError);
end;

procedure TRunLengthTests.EmptyInput;
begin
  Assert.AreEqual(0, Integer(Length(PdfRunLengthDecode(nil))));
end;

{ TPredictorTests }

procedure TPredictorTests.NoPredictor;
var
  Data: TBytes;
begin
  Data := FromHex('01 02 03');
  Assert.AreEqual('01 02 03', Hex(PdfApplyPredictor(Data, TPdfFilterParams.Default)));
end;

procedure TPredictorTests.PngNoneSubUp;
begin
  // Rows of 3 bytes, 1 byte per pixel:
  //   None [7 8 9]; Sub [10 5 5] -> 10 15 20; Up [1 1 1] over 10 15 20 -> 11 16 21.
  Assert.AreEqual('07 08 09 0A 0F 14 0B 10 15',
    Hex(PdfApplyPredictor(FromHex('00 07 08 09 01 0A 05 05 02 01 01 01'), PngParams(1, 8, 3))));
end;

procedure TPredictorTests.PngAveragePaeth;
begin
  // Up [11 16 21]; Paeth [2 3 250] -> 13 19 15; Average [4 6 8] -> 10 20 25.
  Assert.AreEqual('0B 10 15 0D 13 0F 0A 14 19',
    Hex(PdfApplyPredictor(FromHex('02 0B 10 15 04 02 03 FA 03 04 06 08'), PngParams(1, 8, 3))));
end;

procedure TPredictorTests.PngMultiByteSub;
begin
  // RGB, 2 columns: bpp = 3, Sub adds the pixel to the left.
  Assert.AreEqual('01 02 03 05 07 09',
    Hex(PdfApplyPredictor(FromHex('01 01 02 03 04 05 06'), PngParams(3, 8, 2))));
end;

procedure TPredictorTests.PngTruncatedLastRow;
begin
  Assert.AreEqual('01 02 03 04',
    Hex(PdfApplyPredictor(FromHex('00 01 02 03 02 03'), PngParams(1, 8, 3))));
end;

procedure TPredictorTests.ZeroParamsDefaulted;
var
  P: TPdfFilterParams;
begin
  P := Default(TPdfFilterParams);
  Assert.AreEqual('01 02 03', Hex(PdfApplyPredictor(FromHex('01 02 03'), P)));
  // Predictor 12, Colors/BPC/Columns 0 -> 1/8/1: each row is one byte.
  P.Predictor := 12;
  Assert.AreEqual('05 07', Hex(PdfApplyPredictor(FromHex('00 05 02 02'), P)));
end;

procedure TPredictorTests.Tiff8Bit;
begin
  // 2 components, 3 columns, 2 rows; each row restarts.
  Assert.AreEqual('01 02 02 03 04 05 05 05 06 06 07 07',
    Hex(PdfApplyPredictor(FromHex('01 02 01 01 02 02 05 05 01 01 01 01'), TiffParams(2, 8, 3))));
end;

procedure TPredictorTests.Tiff16Bit;
begin
  // 01FF + 0002 = 0201.
  Assert.AreEqual('01 FF 02 01',
    Hex(PdfApplyPredictor(FromHex('01 FF 00 02'), TiffParams(1, 16, 2))));
end;

procedure TPredictorTests.Tiff1Bit;
begin
  // 1 0 0 0 0 0 0 0 | 0 1 0 0 0 0 0 0 -> running XOR: FF | 7F.
  Assert.AreEqual('FF 7F', Hex(PdfApplyPredictor(FromHex('80 40'), TiffParams(1, 1, 8))));
end;

procedure TPredictorTests.Tiff4Bit;
begin
  // Samples 1 2 1 1 -> 1 3 4 5.
  Assert.AreEqual('13 45', Hex(PdfApplyPredictor(FromHex('12 11'), TiffParams(1, 4, 4))));
end;

procedure TPredictorTests.FlateWithPngPredictor;
var
  Image, Predicted, Decoded: TBytes;
  Params: TPdfFilterParams;
  Row, Col, Columns, Rows: Integer;
begin
  Columns := 4;
  Rows := 50;
  SetLength(Image, Columns * Rows);
  for Row := 0 to Rows - 1 do
    for Col := 0 to Columns - 1 do
      Image[Row * Columns + Col] := Byte(Row * 3 + Col * 17);
  // Encode every row with the Up filter (type 2), as xref streams typically do.
  SetLength(Predicted, (Columns + 1) * Rows);
  for Row := 0 to Rows - 1 do
  begin
    Predicted[Row * (Columns + 1)] := 2;
    for Col := 0 to Columns - 1 do
      if Row = 0 then
        Predicted[Row * (Columns + 1) + 1 + Col] := Image[Col]
      else
        Predicted[Row * (Columns + 1) + 1 + Col] :=
          Byte(Image[Row * Columns + Col] - Image[(Row - 1) * Columns + Col]);
  end;
  Params := TPdfFilterParams.Default;
  Params.Predictor := 12;
  Params.Columns := Columns;
  Decoded := PdfApplyFilter('FlateDecode', Compress(Predicted), Params);
  Assert.AreEqual(Hex(Image), Hex(Decoded));
  Decoded := PdfApplyFilter('Fl', Compress(Predicted), Params);
  Assert.AreEqual(Hex(Image), Hex(Decoded));
end;

{ TFilterNameTests }

procedure TFilterNameTests.Normalize;
begin
  Assert.AreEqual('FlateDecode', PdfNormalizeFilterName('Fl'));
  Assert.AreEqual('LZWDecode', PdfNormalizeFilterName('LZW'));
  Assert.AreEqual('ASCII85Decode', PdfNormalizeFilterName('A85'));
  Assert.AreEqual('ASCIIHexDecode', PdfNormalizeFilterName('AHx'));
  Assert.AreEqual('RunLengthDecode', PdfNormalizeFilterName('RL'));
  Assert.AreEqual('CCITTFaxDecode', PdfNormalizeFilterName('CCF'));
  Assert.AreEqual('DCTDecode', PdfNormalizeFilterName('DCT'));
  Assert.AreEqual('FlateDecode', PdfNormalizeFilterName('FlateDecode'));
  Assert.AreEqual('FlateDecode', PdfNormalizeFilterName('/Fl'));
  Assert.AreEqual('JPXDecode', PdfNormalizeFilterName('JPXDecode'));
end;

procedure TFilterNameTests.ImageFilters;
begin
  Assert.IsTrue(PdfIsImageFilter('DCTDecode'));
  Assert.IsTrue(PdfIsImageFilter('DCT'));
  Assert.IsTrue(PdfIsImageFilter('JPXDecode'));
  Assert.IsTrue(PdfIsImageFilter('JBIG2Decode'));
  Assert.IsTrue(PdfIsImageFilter('CCITTFaxDecode'));
  Assert.IsTrue(PdfIsImageFilter('CCF'));
  Assert.IsFalse(PdfIsImageFilter('FlateDecode'));
  Assert.IsFalse(PdfIsImageFilter('Fl'));
  Assert.IsFalse(PdfIsImageFilter('Crypt'));
end;

procedure TFilterNameTests.ApplyFilterDispatch;
var
  P: TPdfFilterParams;
begin
  P := TPdfFilterParams.Default;
  Assert.AreEqual('Hello', AsText(PdfApplyFilter('AHx', Bytes('48656C6C6F>'), P)));
  Assert.AreEqual('Hello', AsText(PdfApplyFilter('ASCIIHexDecode', Bytes('48656C6C6F>'), P)));
  Assert.AreEqual('Hello World!', AsText(PdfApplyFilter('A85', Bytes('87cURD]i,"Ebo80~>'), P)));
  Assert.AreEqual('XXXX', AsText(PdfApplyFilter('RL', FromHex('FD 58 80'), P)));
  Assert.AreEqual('-----A---B', AsText(PdfApplyFilter('LZW', FromHex('80 0B 60 50 22 0C 0C 85 01'), P)));
  Assert.AreEqual('raw', AsText(PdfApplyFilter('Crypt', Bytes('raw'), P)));
end;

procedure TFilterNameTests.ApplyFilterUnknownRaises;
begin
  Assert.WillRaise(
    procedure
    begin
      PdfApplyFilter('BogusDecode', Bytes('x'), TPdfFilterParams.Default);
    end, EPdfFilterError);
end;

procedure TFilterNameTests.ApplyFilterImageRaises;
begin
  Assert.WillRaise(
    procedure
    begin
      PdfApplyFilter('DCTDecode', Bytes('x'), TPdfFilterParams.Default);
    end, EPdfFilterError);
end;

initialization
  TDUnitX.RegisterTestFixture(TFlateDecodeTests);
  TDUnitX.RegisterTestFixture(TLZWDecodeTests);
  TDUnitX.RegisterTestFixture(TASCIIFilterTests);
  TDUnitX.RegisterTestFixture(TRunLengthTests);
  TDUnitX.RegisterTestFixture(TPredictorTests);
  TDUnitX.RegisterTestFixture(TFilterNameTests);

end.
