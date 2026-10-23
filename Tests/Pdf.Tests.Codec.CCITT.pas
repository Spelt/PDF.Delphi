{*******************************************************************************
  Pdf.Tests.Codec.CCITT
  DUnitX tests for Pdf.Codec.CCITT: round trips through small test encoders
  (Group 3 1D/MH, Group 3 2D mixed, Group 4), error tolerance, fuzzing, speed
  and the CCITT images of the pdf.js corpus.
*******************************************************************************}
unit Pdf.Tests.Codec.CCITT;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Math, System.Diagnostics, System.Generics.Collections,
  System.Skia, DUnitX.TestFramework, DUnitX.Exceptions, Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Document, Pdf.Codec.CCITT;

type
  [TestFixture]
  TPdfCCITTTests = class
  public
    [Test] procedure DefaultParams;
    [Test] procedure RoundTrip1D;
    [Test] procedure RoundTrip1DWithEOL;
    [Test] procedure RoundTrip1DByteAlign;
    [Test] procedure RoundTrip1DEndOfBlockFalse;
    [Test] procedure RoundTrip1DMakeupCodes;
    [Test] procedure RoundTripG4;
    [Test] procedure RoundTripG4ByteAlign;
    [Test] procedure RoundTripG4EndOfBlockFalse;
    [Test] procedure RoundTripG4MakeupCodes;
    [Test] procedure RoundTripMixed2D;
    [Test] procedure RoundTripMixed2DByteAlign;
    [Test] procedure RtcAndEofbStopDecoding;
    [Test] procedure ColumnsDefaultTo1728;
    [Test] procedure RowsLimitsOutput;
    [Test] procedure TruncatedReturnsPartialRows;
    [Test] procedure EmptyInputReturnsNil;
    [Test] procedure NothingDecodableRaises;
    [Test] procedure RandomBytesOnlyRaiseFilterError;
    [Test] procedure BitFlipsOnlyRaiseFilterError;
    [Test] procedure LargeG4ScanIsFast;
    [Test] procedure CorpusImages;
  end;

implementation

const
  CorpusDir = 'C:\Users\EDWARD~1\AppData\Local\Temp\claude\pdfjs-corpus\pdfjs\test\pdfs\';
  EOLCode = '000000000001';

  // ITU-T T.4 code tables (bit strings, MSB first).
  WhiteTermCodes: array[0..63] of string = (
    '00110101', '000111', '0111', '1000', '1011', '1100', '1110', '1111',
    '10011', '10100', '00111', '01000', '001000', '000011', '110100', '110101',
    '101010', '101011', '0100111', '0001100', '0001000', '0010111', '0000011', '0000100',
    '0101000', '0101011', '0010011', '0100100', '0011000', '00000010', '00000011', '00011010',
    '00011011', '00010010', '00010011', '00010100', '00010101', '00010110', '00010111', '00101000',
    '00101001', '00101010', '00101011', '00101100', '00101101', '00000100', '00000101', '00001010',
    '00001011', '01010010', '01010011', '01010100', '01010101', '00100100', '00100101', '01011000',
    '01011001', '01011010', '01011011', '01001010', '01001011', '00110010', '00110011', '00110100'
  );
  BlackTermCodes: array[0..63] of string = (
    '0000110111', '010', '11', '10', '011', '0011', '0010', '00011',
    '000101', '000100', '0000100', '0000101', '0000111', '00000100', '00000111', '000011000',
    '0000010111', '0000011000', '0000001000', '00001100111', '00001101000', '00001101100', '00000110111', '00000101000',
    '00000010111', '00000011000', '000011001010', '000011001011', '000011001100', '000011001101', '000001101000', '000001101001',
    '000001101010', '000001101011', '000011010010', '000011010011', '000011010100', '000011010101', '000011010110', '000011010111',
    '000001101100', '000001101101', '000011011010', '000011011011', '000001010100', '000001010101', '000001010110', '000001010111',
    '000001100100', '000001100101', '000001010010', '000001010011', '000000100100', '000000110111', '000000111000', '000000100111',
    '000000101000', '000001011000', '000001011001', '000000101011', '000000101100', '000001011010', '000001100110', '000001100111'
  );
  WhiteMakeupCodes: array[1..27] of string = (
    '11011', '10010', '010111', '0110111', '00110110', '00110111', '01100100', '01100101',
    '01101000', '01100111', '011001100', '011001101', '011010010', '011010011', '011010100', '011010101',
    '011010110', '011010111', '011011000', '011011001', '011011010', '011011011', '010011000', '010011001',
    '010011010', '011000', '010011011'
  );
  BlackMakeupCodes: array[1..27] of string = (
    '0000001111', '000011001000', '000011001001', '000001011011', '000000110011', '000000110100', '000000110101', '0000001101100',
    '0000001101101', '0000001001010', '0000001001011', '0000001001100', '0000001001101', '0000001110010', '0000001110011', '0000001110100',
    '0000001110101', '0000001110110', '0000001110111', '0000001010010', '0000001010011', '0000001010100', '0000001010101', '0000001011010',
    '0000001011011', '0000001100100', '0000001100101'
  );
  ExtMakeupCodes: array[0..12] of string = (
    '00000001000', '00000001100', '00000001101', '000000010010', '000000010011', '000000010100', '000000010101', '000000010110',
    '000000010111', '000000011100', '000000011101', '000000011110', '000000011111'
  );

type
  /// <summary>Test image, one byte per pixel (1 = black).</summary>
  TBilevel = record
    W, H: Integer;
    Pix: TBytes;
    procedure Init(AW, AH: Integer);
    /// <summary>Pixel value; positions left of the row or above the image are white (0).</summary>
    function Get(X, Y: Integer): Integer; inline;
    procedure SetPixel(X, Y: Integer);
  end;

  /// <summary>MSB-first bit writer for the test encoders.</summary>
  TBitWriter = record
    Data: TBytes;
    BitCount: Integer;
    procedure PutBit(Bit: Integer);
    procedure PutCode(const Code: string);
    /// <summary>Zero bits up to the next byte boundary.</summary>
    procedure AlignByte;
    /// <summary>Zero fill bits so that a following code of Len bits ends on a byte boundary.</summary>
    procedure FillBefore(Len: Integer);
    function Bytes: TBytes;
  end;

  /// <summary>Xorshift generator, deterministic across runs.</summary>
  TRng = record
    State: Cardinal;
    function Next(Range: Integer): Integer;
  end;

{ TBilevel }

procedure TBilevel.Init(AW, AH: Integer);
begin
  W := AW;
  H := AH;
  Pix := nil;
  SetLength(Pix, W * H);
  if Length(Pix) > 0 then
    FillChar(Pix[0], Length(Pix), 0);
end;

function TBilevel.Get(X, Y: Integer): Integer;
begin
  if (X < 0) or (Y < 0) then
    Result := 0
  else
    Result := Pix[Y * W + X];
end;

procedure TBilevel.SetPixel(X, Y: Integer);
begin
  Pix[Y * W + X] := 1;
end;

{ TBitWriter }

procedure TBitWriter.PutBit(Bit: Integer);
var
  OldLen: Integer;
begin
  if BitCount div 8 >= Length(Data) then
  begin
    OldLen := Length(Data);
    SetLength(Data, Max(64, OldLen * 2));
    FillChar(Data[OldLen], Length(Data) - OldLen, 0);
  end;
  if Bit <> 0 then
    Data[BitCount div 8] := Data[BitCount div 8] or ($80 shr (BitCount mod 8));
  Inc(BitCount);
end;

procedure TBitWriter.PutCode(const Code: string);
var
  C: Char;
begin
  for C in Code do
    PutBit(Ord(C = '1'));
end;

procedure TBitWriter.AlignByte;
begin
  while BitCount mod 8 <> 0 do
    PutBit(0);
end;

procedure TBitWriter.FillBefore(Len: Integer);
begin
  while (BitCount + Len) mod 8 <> 0 do
    PutBit(0);
end;

function TBitWriter.Bytes: TBytes;
begin
  Result := Copy(Data, 0, (BitCount + 7) div 8);
end;

{ TRng }

function TRng.Next(Range: Integer): Integer;
begin
  State := State xor (State shl 13);
  State := State xor (State shr 17);
  State := State xor (State shl 5);
  Result := Integer(State mod Cardinal(Range));
end;

{ Test encoders }

procedure PutRun(var BW: TBitWriter; Run: Integer; Black: Boolean);
begin
  while Run >= 2560 do
  begin
    BW.PutCode(ExtMakeupCodes[12]);
    Dec(Run, 2560);
  end;
  if Run >= 1792 then
  begin
    BW.PutCode(ExtMakeupCodes[Run div 64 - 28]);
    Run := Run mod 64;
  end
  else if Run >= 64 then
  begin
    if Black then
      BW.PutCode(BlackMakeupCodes[Run div 64])
    else
      BW.PutCode(WhiteMakeupCodes[Run div 64]);
    Run := Run mod 64;
  end;
  if Black then
    BW.PutCode(BlackTermCodes[Run])
  else
    BW.PutCode(WhiteTermCodes[Run]);
end;

/// <summary>Modified Huffman (1D) coding of one row: alternating runs starting with white.</summary>
procedure Encode1DRow(var BW: TBitWriter; const Img: TBilevel; Y: Integer);
var
  X, Run, Color: Integer;
begin
  X := 0;
  Color := 0;
  while X < Img.W do
  begin
    Run := 0;
    while (X + Run < Img.W) and (Img.Get(X + Run, Y) = Color) do
      Inc(Run);
    PutRun(BW, Run, Color = 1);
    Inc(X, Run);
    Color := 1 - Color;
  end;
end;

/// <summary>Next changing element right of X on row Y (W when there is none); row -1 is all white.</summary>
function NextChange(const Img: TBilevel; Y, X: Integer): Integer;
begin
  Result := X + 1;
  while (Result < Img.W) and (Img.Get(Result, Y) = Img.Get(Result - 1, Y)) do
    Inc(Result);
end;

/// <summary>Two-dimensional (READ) coding of row Y against row Y - 1: pass, horizontal and vertical modes.</summary>
procedure Encode2DRow(var BW: TBitWriter; const Img: TBilevel; Y: Integer);
const
  VCodes: array[-3..3] of string = ('0000010', '000010', '010', '1', '011', '000011', '0000011');
var
  A0, A1, A2, B1, B2, Color: Integer;
begin
  A0 := -1;
  Color := 0;
  repeat
    A1 := NextChange(Img, Y, A0);
    B1 := NextChange(Img, Y - 1, A0);
    while (B1 < Img.W) and (Img.Get(B1, Y - 1) = Color) do
      B1 := NextChange(Img, Y - 1, B1);
    if B1 < Img.W then
      B2 := NextChange(Img, Y - 1, B1)
    else
      B2 := Img.W;
    if B2 < A1 then
    begin
      BW.PutCode('0001');
      A0 := B2;
    end
    else if Abs(A1 - B1) <= 3 then
    begin
      BW.PutCode(VCodes[A1 - B1]);
      A0 := A1;
      Color := 1 - Color;
    end
    else
    begin
      if A1 < Img.W then
        A2 := NextChange(Img, Y, A1)
      else
        A2 := Img.W;
      BW.PutCode('001');
      PutRun(BW, A1 - Max(A0, 0), Color = 1);
      PutRun(BW, A2 - A1, Color = 0);
      A0 := A2;
    end;
  until A0 >= Img.W;
end;

/// <summary>Group 3: K = 0 pure 1D, K &gt; 0 mixed (an EOL plus tag bit before every row, every K-th row 1D).</summary>
function EncodeG3(const Img: TBilevel; K: Integer; EOLs, ByteAlign, RTC: Boolean): TBytes;
var
  BW: TBitWriter;
  Y, I: Integer;
begin
  BW := Default(TBitWriter);
  for Y := 0 to Img.H - 1 do
  begin
    if EOLs or (K > 0) then
    begin
      if ByteAlign then
        BW.FillBefore(12);
      BW.PutCode(EOLCode);
      if K > 0 then
        BW.PutBit(Ord(Y mod K = 0));
    end
    else if ByteAlign then
      BW.AlignByte;
    if (K > 0) and (Y mod K <> 0) then
      Encode2DRow(BW, Img, Y)
    else
      Encode1DRow(BW, Img, Y);
  end;
  if RTC then
    for I := 1 to 6 do
    begin
      if ByteAlign and (I = 1) then
        BW.FillBefore(12);
      BW.PutCode(EOLCode);
      if K > 0 then
        BW.PutBit(1);
    end;
  Result := BW.Bytes;
end;

/// <summary>Group 4: every row 2D against the previous one (an all-white row above the first).</summary>
function EncodeG4(const Img: TBilevel; ByteAlign, EOFB: Boolean): TBytes;
var
  BW: TBitWriter;
  Y: Integer;
begin
  BW := Default(TBitWriter);
  for Y := 0 to Img.H - 1 do
  begin
    if ByteAlign then
      BW.AlignByte;
    Encode2DRow(BW, Img, Y);
  end;
  if EOFB then
  begin
    if ByteAlign then
      BW.AlignByte;
    BW.PutCode(EOLCode);
    BW.PutCode(EOLCode);
  end;
  Result := BW.Bytes;
end;

{ Test images }

function StripesImage: TBilevel;
var
  X, Y: Integer;
begin
  Result.Init(40, 12);
  for Y := 0 to Result.H - 1 do
    for X := 0 to Result.W - 1 do
      if Odd(X div 3) then
        Result.SetPixel(X, Y);
end;

function DiagonalImage: TBilevel;
var
  I: Integer;
begin
  Result.Init(33, 33);
  for I := 0 to 32 do
    Result.SetPixel(I, I);
end;

function WhiteImage: TBilevel;
begin
  Result.Init(17, 5);
end;

function BlackImage: TBilevel;
var
  X, Y: Integer;
begin
  Result.Init(63, 4);
  for Y := 0 to Result.H - 1 do
    for X := 0 to Result.W - 1 do
      Result.SetPixel(X, Y);
end;

/// <summary>Blobby random image: rows derived from the previous one with small edge shifts and new runs.</summary>
function RandomImage(W, H: Integer; Seed: Cardinal): TBilevel;
var
  Rng: TRng;
  X, Y: Integer;
begin
  Result.Init(W, H);
  Rng.State := Seed;
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
      if Y = 0 then
      begin
        if Rng.Next(4) = 0 then
          Result.Pix[X] := 1 - Result.Get(X - 1, 0)
        else
          Result.Pix[X] := Result.Get(X - 1, 0);
      end
      else if Rng.Next(10) = 0 then
        Result.Pix[Y * W + X] := 1 - Result.Get(EnsureRange(X + Rng.Next(3) - 1, 0, W - 1), Y - 1)
      else
        Result.Pix[Y * W + X] := Result.Get(X, Y - 1);
end;

/// <summary>Wide image with runs that need makeup codes (64..2560 and longer).</summary>
function WideImage: TBilevel;
var
  X, Y: Integer;
begin
  Result.Init(3000, 6);
  for X := 100 to 2899 do
    Result.SetPixel(X, 0);
  for X := 0 to 1999 do
    Result.SetPixel(X, 1);
  for X := 64 to 127 do
    Result.SetPixel(X, 2);
  for X := 1000 to 2799 do
    Result.SetPixel(X, 2);
  for X := 2999 to 2999 do
    Result.SetPixel(X, 3);
  for X := 0 to 2999 do
    if (X div 700) mod 2 = 1 then
      Result.SetPixel(X, 4);
  for Y := 5 to 5 do
    for X := 0 to 2999 do
      if (X * 7) mod 131 < 60 then
        Result.SetPixel(X, Y);
end;

function SmallImages: TArray<TBilevel>;
begin
  Result := [StripesImage, DiagonalImage, WhiteImage, BlackImage, RandomImage(61, 30, 12345),
    RandomImage(8, 9, 777), RandomImage(1, 7, 99)];
end;

{ Checks }

function Params(const Img: TBilevel; K: Integer; BlackIs1: Boolean = False; ByteAlign: Boolean = False;
  EndOfLine: Boolean = False; EndOfBlock: Boolean = True; Rows: Integer = 0): TPdfCCITTParams;
begin
  Result := TPdfCCITTParams.Make(K, Img.W, Rows, BlackIs1, ByteAlign, EndOfLine, EndOfBlock);
end;

/// <summary>Checks the output size for Rows rows, and every pixel and padding bit of the first CheckCount rows.</summary>
procedure CheckRows(const Img: TBilevel; const Output: TBytes; Rows: Integer; BlackIs1: Boolean;
  CheckCount: Integer; const Context: string);
var
  Stride, X, Y, Bit, Expected: Integer;
begin
  Stride := (Img.W + 7) div 8;
  Assert.AreEqual(Rows * Stride, Integer(Length(Output)), Context + ': output size');
  for Y := 0 to CheckCount - 1 do
    for X := 0 to Stride * 8 - 1 do
    begin
      Bit := (Output[Y * Stride + X shr 3] shr (7 - X and 7)) and 1;
      if X < Img.W then
        Expected := Img.Get(X, Y) xor Ord(not BlackIs1)
      else
        Expected := Ord(BlackIs1);
      if Bit <> Expected then
        Assert.Fail(Format('%s: pixel (%d, %d) is %d, expected %d', [Context, X, Y, Bit, Expected]));
    end;
end;

procedure CheckDecode(const Img: TBilevel; const Data: TBytes; const P: TPdfCCITTParams; const Context: string);
var
  Output: TBytes;
  Rows: Integer;
begin
  Output := PdfCCITTDecode(Data, P, Rows);
  Assert.AreEqual(Img.H, Rows, Context + ': rows');
  CheckRows(Img, Output, Rows, P.BlackIs1, Rows, Context);
end;

function ImageName(Index: Integer; const Img: TBilevel): string;
begin
  Result := Format('image %d (%dx%d)', [Index, Img.W, Img.H]);
end;

{ TPdfCCITTTests }

procedure TPdfCCITTTests.DefaultParams;
var
  P: TPdfCCITTParams;
begin
  P := TPdfCCITTParams.Default;
  Assert.AreEqual(0, P.K);
  Assert.AreEqual(1728, P.Columns);
  Assert.AreEqual(0, P.Rows);
  Assert.IsFalse(P.BlackIs1);
  Assert.IsFalse(P.ByteAlign);
  Assert.IsFalse(P.EndOfLine);
  Assert.IsTrue(P.EndOfBlock);
  Assert.AreEqual(0, P.DamagedRowsBeforeError);
end;

procedure TPdfCCITTTests.RoundTrip1D;
var
  Images: TArray<TBilevel>;
  I: Integer;
  Black: Boolean;
begin
  Images := SmallImages;
  for I := 0 to High(Images) do
    for Black in [False, True] do
      CheckDecode(Images[I], EncodeG3(Images[I], 0, False, False, False), Params(Images[I], 0, Black),
        ImageName(I, Images[I]) + ' MH BlackIs1=' + BoolToStr(Black, True));
end;

procedure TPdfCCITTTests.RoundTrip1DWithEOL;
var
  Images: TArray<TBilevel>;
  I: Integer;
  Black, Eol, Rtc: Boolean;
begin
  Images := SmallImages;
  for I := 0 to High(Images) do
    for Black in [False, True] do
      for Eol in [False, True] do
        for Rtc in [False, True] do
          CheckDecode(Images[I], EncodeG3(Images[I], 0, True, False, Rtc), Params(Images[I], 0, Black, False, Eol),
            Format('%s MH+EOL BlackIs1=%s EndOfLine=%s RTC=%s', [ImageName(I, Images[I]), BoolToStr(Black, True),
            BoolToStr(Eol, True), BoolToStr(Rtc, True)]));
end;

procedure TPdfCCITTTests.RoundTrip1DByteAlign;
var
  Images: TArray<TBilevel>;
  I: Integer;
  Black, Eol: Boolean;
begin
  Images := SmallImages;
  for I := 0 to High(Images) do
    for Black in [False, True] do
    begin
      CheckDecode(Images[I], EncodeG3(Images[I], 0, False, True, False), Params(Images[I], 0, Black, True),
        ImageName(I, Images[I]) + ' MH aligned rows');
      for Eol in [False, True] do
        CheckDecode(Images[I], EncodeG3(Images[I], 0, True, True, True), Params(Images[I], 0, Black, True, Eol),
          ImageName(I, Images[I]) + ' MH aligned EOLs + RTC, EndOfLine=' + BoolToStr(Eol, True));
    end;
end;

procedure TPdfCCITTTests.RoundTrip1DEndOfBlockFalse;
var
  Images: TArray<TBilevel>;
  I: Integer;
  Eol: Boolean;
begin
  // EndOfBlock false uses the bit-by-bit table search and stops after Rows rows.
  Images := SmallImages;
  for I := 0 to High(Images) do
    for Eol in [False, True] do
      CheckDecode(Images[I], EncodeG3(Images[I], 0, Eol, False, False),
        Params(Images[I], 0, False, False, Eol, False, Images[I].H),
        ImageName(I, Images[I]) + ' MH EndOfBlock=false EOL=' + BoolToStr(Eol, True));
end;

procedure TPdfCCITTTests.RoundTrip1DMakeupCodes;
var
  Img: TBilevel;
begin
  Img := WideImage;
  CheckDecode(Img, EncodeG3(Img, 0, False, False, False), Params(Img, 0), 'wide MH');
  CheckDecode(Img, EncodeG3(Img, 0, True, False, True), Params(Img, 0, True), 'wide MH+EOL');
  CheckDecode(Img, EncodeG3(Img, 0, True, True, True), Params(Img, 0, False, True, True), 'wide MH aligned EOL');
  CheckDecode(Img, EncodeG3(Img, 0, False, False, False), Params(Img, 0, False, False, False, False, Img.H),
    'wide MH EndOfBlock=false');
end;

procedure TPdfCCITTTests.RoundTripG4;
var
  Images: TArray<TBilevel>;
  I: Integer;
  Black, Eofb: Boolean;
begin
  Images := SmallImages;
  for I := 0 to High(Images) do
    for Black in [False, True] do
      for Eofb in [False, True] do
        CheckDecode(Images[I], EncodeG4(Images[I], False, Eofb), Params(Images[I], -1, Black),
          Format('%s G4 BlackIs1=%s EOFB=%s', [ImageName(I, Images[I]), BoolToStr(Black, True),
          BoolToStr(Eofb, True)]));
end;

procedure TPdfCCITTTests.RoundTripG4ByteAlign;
var
  Images: TArray<TBilevel>;
  I: Integer;
  Eofb: Boolean;
begin
  Images := SmallImages;
  for I := 0 to High(Images) do
    for Eofb in [False, True] do
      CheckDecode(Images[I], EncodeG4(Images[I], True, Eofb), Params(Images[I], -1, False, True),
        ImageName(I, Images[I]) + ' G4 aligned EOFB=' + BoolToStr(Eofb, True));
end;

procedure TPdfCCITTTests.RoundTripG4EndOfBlockFalse;
var
  Images: TArray<TBilevel>;
  I: Integer;
begin
  Images := SmallImages;
  for I := 0 to High(Images) do
    CheckDecode(Images[I], EncodeG4(Images[I], False, False), Params(Images[I], -1, False, False, False, False,
      Images[I].H), ImageName(I, Images[I]) + ' G4 EndOfBlock=false');
end;

procedure TPdfCCITTTests.RoundTripG4MakeupCodes;
var
  Img: TBilevel;
begin
  Img := WideImage;
  CheckDecode(Img, EncodeG4(Img, False, True), Params(Img, -1), 'wide G4');
  CheckDecode(Img, EncodeG4(Img, True, False), Params(Img, -1, True, True), 'wide G4 aligned');
  Img := RandomImage(2600, 40, 4242);
  CheckDecode(Img, EncodeG4(Img, False, True), Params(Img, -1), 'random 2600 G4');
  CheckDecode(Img, EncodeG4(Img, False, False), Params(Img, -1, False, False, False, False, Img.H),
    'random 2600 G4 EndOfBlock=false');
end;

procedure TPdfCCITTTests.RoundTripMixed2D;
var
  Images: TArray<TBilevel>;
  I, K: Integer;
  Eob: Boolean;
begin
  Images := SmallImages;
  for I := 0 to High(Images) do
    for K in [1, 2, 4] do
      for Eob in [False, True] do
        CheckDecode(Images[I], EncodeG3(Images[I], K, True, False, Eob),
          Params(Images[I], K, False, False, False, Eob, IfThen(Eob, 0, Images[I].H)),
          Format('%s G3 2D K=%d EndOfBlock=%s', [ImageName(I, Images[I]), K, BoolToStr(Eob, True)]));
  CheckDecode(WideImage, EncodeG3(WideImage, 3, True, False, True), Params(WideImage, 3), 'wide G3 2D');
end;

procedure TPdfCCITTTests.RoundTripMixed2DByteAlign;
var
  Images: TArray<TBilevel>;
  I: Integer;
begin
  Images := SmallImages;
  for I := 0 to High(Images) do
    CheckDecode(Images[I], EncodeG3(Images[I], 2, True, True, True), Params(Images[I], 2, False, True, True),
      ImageName(I, Images[I]) + ' G3 2D aligned');
end;

procedure TPdfCCITTTests.RtcAndEofbStopDecoding;
var
  Img: TBilevel;
  Data: TBytes;
begin
  // Garbage after the end-of-block marker must not produce extra rows.
  Img := RandomImage(50, 20, 31337);
  Data := EncodeG4(Img, False, True) + TBytes.Create($A5, $5A, $FF, $00, $13, $37);
  CheckDecode(Img, Data, Params(Img, -1), 'G4 EOFB + garbage');
  Data := EncodeG3(Img, 0, True, False, True) + TBytes.Create($A5, $5A, $FF, $00, $13, $37);
  CheckDecode(Img, Data, Params(Img, 0), 'MH RTC + garbage');
  Data := EncodeG3(Img, 2, True, False, True) + TBytes.Create($A5, $5A, $FF, $00, $13, $37);
  CheckDecode(Img, Data, Params(Img, 2), 'G3 2D RTC + garbage');
end;

procedure TPdfCCITTTests.ColumnsDefaultTo1728;
var
  P: TPdfCCITTParams;
  Output: TBytes;
  Rows, I: Integer;
  Img: TBilevel;
begin
  // In G4 every 1 bit is a V0 code, which completes an all-white row against an all-white reference.
  P := TPdfCCITTParams.Default;
  P.K := -1;
  P.Columns := 0;
  Output := PdfCCITTDecode(TBytes.Create($FF, $FF), P, Rows);
  Assert.AreEqual(16, Rows);
  Assert.AreEqual(16 * 216, Integer(Length(Output)));
  for I := 0 to High(Output) do
    Assert.AreEqual(Byte($FF), Output[I]);
  // A 1728 wide MH image decodes with the default Columns.
  Img := RandomImage(1728, 10, 2024);
  P := TPdfCCITTParams.Default;
  P.Columns := 0;
  Output := PdfCCITTDecode(EncodeG3(Img, 0, True, False, True), P, Rows);
  Assert.AreEqual(Img.H, Rows);
  CheckRows(Img, Output, Rows, False, Rows, '1728 default');
end;

procedure TPdfCCITTTests.RowsLimitsOutput;
var
  P: TPdfCCITTParams;
  Output: TBytes;
  Rows: Integer;
  Img: TBilevel;
begin
  P := TPdfCCITTParams.Default;
  P.K := -1;
  P.Rows := 5;
  Output := PdfCCITTDecode(TBytes.Create($FF, $FF), P, Rows);
  Assert.AreEqual(5, Rows);
  Assert.AreEqual(5 * 216, Integer(Length(Output)));
  Img := RandomImage(45, 20, 555);
  Output := PdfCCITTDecode(EncodeG3(Img, 0, False, False, False), Params(Img, 0, False, False, False, True, 7), Rows);
  Assert.AreEqual(7, Rows);
  CheckRows(Img, Output, Rows, False, Rows, 'MH Rows=7');
  Output := PdfCCITTDecode(EncodeG4(Img, False, True), Params(Img, -1, True, False, False, True, 3), Rows);
  Assert.AreEqual(3, Rows);
  CheckRows(Img, Output, Rows, True, Rows, 'G4 Rows=3');
  // More Rows than the data holds: the decoded rows only.
  Output := PdfCCITTDecode(EncodeG4(Img, False, True), Params(Img, -1, False, False, False, True, 1000), Rows);
  Assert.AreEqual(Img.H, Rows);
end;

procedure TPdfCCITTTests.TruncatedReturnsPartialRows;
var
  Img: TBilevel;
  Data, Output: TBytes;
  Rows, Cut: Integer;
  K: Integer;
begin
  Img := RandomImage(61, 40, 8080);
  for K in TArray<Integer>.Create(-1, 0, 2) do
  begin
    if K < 0 then
      Data := EncodeG4(Img, False, False)
    else
      Data := EncodeG3(Img, K, K > 0, False, False);
    for Cut in TArray<Integer>.Create(3, Length(Data) div 4, Length(Data) div 2, Length(Data) - 1) do
    begin
      Output := PdfCCITTDecode(Copy(Data, 0, Cut), Params(Img, K), Rows);
      Assert.IsTrue((Rows >= 1) and (Rows <= Img.H), Format('K=%d cut %d: %d rows', [K, Cut, Rows]));
      // All rows but the last (which may be completed with white) are exact.
      CheckRows(Img, Output, Rows, False, Rows - 1, Format('K=%d cut %d', [K, Cut]));
    end;
  end;
end;

procedure TPdfCCITTTests.EmptyInputReturnsNil;
var
  Output: TBytes;
  Rows: Integer;
begin
  Output := PdfCCITTDecode(nil, TPdfCCITTParams.Default, Rows);
  Assert.AreEqual(0, Rows);
  Assert.AreEqual(0, Integer(Length(Output)));
end;

procedure TPdfCCITTTests.NothingDecodableRaises;
var
  P: TPdfCCITTParams;
  Proc: TProc;
begin
  P := TPdfCCITTParams.Default;
  P.K := -1;
  Proc :=
    procedure
    var
      Rows: Integer;
    begin
      PdfCCITTDecode(TBytes.Create(0, 0, 0), P, Rows);
    end;
  Assert.WillRaise(Proc, EPdfFilterError);
  // EOFB only.
  Proc :=
    procedure
    var
      Rows: Integer;
    begin
      PdfCCITTDecode(TBytes.Create($00, $10, $01), P, Rows);
    end;
  Assert.WillRaise(Proc, EPdfFilterError);
end;

procedure DecodeExpectingFilterErrorOnly(const Data: TBytes; const P: TPdfCCITTParams; const Context: string);
var
  Output: TBytes;
  Rows, Columns: Integer;
begin
  try
    Output := PdfCCITTDecode(Data, P, Rows);
    Columns := P.Columns;
    if Columns <= 0 then
      Columns := 1728;
    Assert.AreEqual(Rows * ((Columns + 7) div 8), Integer(Length(Output)), Context + ': size');
    if P.Rows > 0 then
      Assert.IsTrue(Rows <= P.Rows, Context + ': too many rows');
  except
    on E: EPdfFilterError do
      ;
    on E: ETestFailure do
      raise;
    on E: Exception do
      Assert.Fail(Format('%s: %s: %s', [Context, E.ClassName, E.Message]));
  end;
end;

function RandomParams(var Rng: TRng): TPdfCCITTParams;
const
  Ks: array[0..4] of Integer = (-1, 0, 1, 2, 4);
  Cols: array[0..6] of Integer = (1, 7, 8, 63, 100, 1728, 0);
begin
  Result := TPdfCCITTParams.Make(Ks[Rng.Next(5)], Cols[Rng.Next(7)], Rng.Next(3) * 5, Rng.Next(2) = 0,
    Rng.Next(2) = 0, Rng.Next(2) = 0, Rng.Next(3) <> 0);
end;

procedure TPdfCCITTTests.RandomBytesOnlyRaiseFilterError;
var
  Rng: TRng;
  Iter, I: Integer;
  Data: TBytes;
  P: TPdfCCITTParams;
begin
  Rng.State := 20261023;
  for Iter := 1 to 3000 do
  begin
    SetLength(Data, 1 + Rng.Next(300));
    for I := 0 to High(Data) do
      case Iter mod 4 of
        0: Data[I] := Rng.Next(256);
        1: Data[I] := Byte(Rng.Next(256) and Rng.Next(256) and Rng.Next(256));   // mostly zero bits
        2: Data[I] := Byte(Rng.Next(256) or Rng.Next(256));                      // mostly one bits
      else
        Data[I] := Byte(IfThen(Rng.Next(4) = 0, Rng.Next(256), 0));
      end;
    P := RandomParams(Rng);
    DecodeExpectingFilterErrorOnly(Data, P, Format('iteration %d', [Iter]));
  end;
end;

procedure TPdfCCITTTests.BitFlipsOnlyRaiseFilterError;
var
  Rng: TRng;
  Img: TBilevel;
  Valid, Data: TBytes;
  Iter, Flips, I, Bit, K: Integer;
  P: TPdfCCITTParams;
begin
  Rng.State := 4711;
  Img := RandomImage(100, 30, 1);
  for Iter := 1 to 2000 do
  begin
    case Iter mod 3 of
      0:
        begin
          K := -1;
          Valid := EncodeG4(Img, Iter mod 5 = 0, True);
        end;
      1:
        begin
          K := 0;
          Valid := EncodeG3(Img, 0, Iter mod 2 = 0, Iter mod 5 = 0, True);
        end;
    else
      K := 2;
      Valid := EncodeG3(Img, 2, True, Iter mod 5 = 0, True);
    end;
    Data := Copy(Valid);
    Flips := 1 + Rng.Next(4);
    for I := 1 to Flips do
    begin
      Bit := Rng.Next(Length(Data) * 8);
      Data[Bit shr 3] := Data[Bit shr 3] xor ($80 shr (Bit and 7));
    end;
    P := Params(Img, K, Rng.Next(2) = 0, Iter mod 5 = 0, Rng.Next(2) = 0, Rng.Next(4) <> 0, Rng.Next(2) * Img.H);
    DecodeExpectingFilterErrorOnly(Data, P, Format('flip iteration %d', [Iter]));
  end;
end;

procedure TPdfCCITTTests.LargeG4ScanIsFast;
var
  Img: TBilevel;
  Rng: TRng;
  Line, X, Y, GlyphW, GlyphH, Top, Left, I, J, Rows: Integer;
  Data, Output: TBytes;
  Watch: TStopwatch;
begin
  // A synthetic 5000 x 7000 "text page": lines of glyph-like boxes and strokes.
  Img.Init(5000, 7000);
  Rng.State := 77;
  for Line := 0 to 110 do
  begin
    Top := 200 + Line * 60;
    Left := 300 + Rng.Next(200);
    while Left < 4600 do
    begin
      GlyphW := 8 + Rng.Next(30);
      GlyphH := 20 + Rng.Next(25);
      for I := 0 to GlyphH - 1 do
        for J := 0 to GlyphW - 1 do
          if (I < 4) or (J < 4) or (I mod 11 = 0) or (J = GlyphW - 1 - I mod GlyphW) then
          begin
            X := Left + J;
            Y := Top + 45 - GlyphH + I;
            if (X < Img.W) and (Y < Img.H) then
              Img.SetPixel(X, Y);
          end;
      Inc(Left, GlyphW + 4 + Rng.Next(10) + IfThen(Rng.Next(6) = 0, 30, 0));
    end;
  end;
  Data := EncodeG4(Img, False, True);
  Watch := TStopwatch.StartNew;
  Output := PdfCCITTDecode(Data, Params(Img, -1, False, False, False, True, Img.H), Rows);
  Watch.Stop;
  TDUnitX.CurrentRunner.Log(TLogLevel.Information, Format('5000x7000 G4 (%d bytes) decoded in %d ms',
    [Length(Data), Watch.ElapsedMilliseconds]));
  Assert.AreEqual(Img.H, Rows);
  CheckRows(Img, Output, Rows, False, Rows, '5000x7000');
  Assert.IsTrue(Watch.ElapsedMilliseconds < 1000, Format('decoding took %d ms', [Watch.ElapsedMilliseconds]));
end;

{ Corpus }

function ScratchDir: string;
begin
  Result := TPath.GetFullPath(TPath.Combine(ExtractFilePath(ParamStr(0)), '..\scratch'));
end;

/// <summary>Decode parameters from a /DecodeParms dictionary (nil = defaults); Rows falls back to the image height.</summary>
function ParamsFromDict(const D: IPdfDictionary; Height: Integer): TPdfCCITTParams;
begin
  Result := TPdfCCITTParams.Default;
  if D <> nil then
  begin
    Result.K := Integer(EnsureRange(D.GetInteger('K', 0), -1, 1000));
    Result.Columns := Integer(EnsureRange(D.GetInteger('Columns', 1728), 0, 1 shl 20));
    Result.Rows := Integer(EnsureRange(D.GetInteger('Rows', 0), 0, MaxInt));
    Result.BlackIs1 := D.GetBoolean('BlackIs1', False);
    Result.ByteAlign := D.GetBoolean('EncodedByteAlign', False);
    Result.EndOfLine := D.GetBoolean('EndOfLine', False);
    Result.EndOfBlock := D.GetBoolean('EndOfBlock', True);
    Result.DamagedRowsBeforeError := Integer(EnsureRange(D.GetInteger('DamagedRowsBeforeError', 0), 0, MaxInt));
  end;
  if Result.Rows <= 0 then
    Result.Rows := Height;
end;

/// <summary>Writes decoded rows as a Gray8 PNG (1 bits white, 0 bits black, inverted for Decode [1 0]).</summary>
procedure WritePng(const FileName: string; const Output: TBytes; Columns, Width, Height, Rows: Integer;
  Invert: Boolean);
var
  Pixels: TBytes;
  Stride, X, Y, Bit: Integer;
  Img: ISkImage;
begin
  Stride := (Columns + 7) div 8;
  Width := Min(Width, Columns);
  SetLength(Pixels, Width * Height);
  FillChar(Pixels[0], Length(Pixels), 255);
  for Y := 0 to Min(Rows, Height) - 1 do
    for X := 0 to Width - 1 do
    begin
      Bit := (Output[Y * Stride + X shr 3] shr (7 - X and 7)) and 1;
      if Invert then
        Bit := Bit xor 1;
      Pixels[Y * Width + X] := Byte(Bit * 255);
    end;
  Img := TSkImage.MakeRasterCopy(TSkImageInfo.Create(Width, Height, TSkColorType.Gray8, TSkAlphaType.Opaque),
    PByte(Pixels), NativeUInt(Width));
  TFile.WriteAllBytes(FileName, Img.Encode(TSkEncodedImageFormat.PNG));
end;

procedure TPdfCCITTTests.CorpusImages;
var
  FileName, Key, Name, Info: string;
  Doc: TPdfDocument;
  PageIndex, Rows, Width, Height, Files, FilesWithCCITT, Ok, Partial, Failed, BestArea: Integer;
  XObjects, Parms: IPdfDictionary;
  Stream: IPdfStream;
  DecodeArr: IPdfArray;
  Data, Output, BestOutput: TBytes;
  P, BestParams: TPdfCCITTParams;
  Seen: TDictionary<string, Boolean>;
  KCounts: array[0..2] of Integer;
  Log: TStringBuilder;
  Watch, Total: TStopwatch;
  Found, Invert, BestInvert: Boolean;
  BestW, BestH, BestRows, BestG4Area: Integer;
  BestName: string;
begin
  if not TDirectory.Exists(CorpusDir) then
    Assert.Pass('pdf.js corpus not present');
  Files := 0;
  FilesWithCCITT := 0;
  Ok := 0;
  Partial := 0;
  Failed := 0;
  BestArea := 0;
  BestW := 0;
  BestH := 0;
  BestRows := 0;
  BestInvert := False;
  BestParams := TPdfCCITTParams.Default;
  BestG4Area := 0;
  FillChar(KCounts, SizeOf(KCounts), 0);
  Total := TStopwatch.StartNew;
  Seen := TDictionary<string, Boolean>.Create;
  Log := TStringBuilder.Create;
  try
    for FileName in TDirectory.GetFiles(CorpusDir, '*.pdf') do
    begin
      Inc(Files);
      Found := False;
      Doc := TPdfDocument.Create;
      try
        try
          Doc.LoadFromFile(FileName);
        except
          Continue;
        end;
        for PageIndex := 0 to Min(Doc.PageCount, 10) - 1 do
        begin
          try
            XObjects := Doc.Pages[PageIndex].Resources.GetDictionary('XObject');
          except
            XObjects := nil;
          end;
          if XObjects = nil then
            Continue;
          for Key in XObjects.Keys do
          begin
            try
              Stream := XObjects.GetStream(Key);
              if (Stream = nil) or (Stream.Dict.GetName('Subtype') <> 'Image') then
                Continue;
              Data := Stream.GetDecodedData;
            except
              Continue;
            end;
            if Stream.ImageFilter <> 'CCITTFaxDecode' then
              Continue;
            Width := Integer(Stream.Dict.GetInteger('Width', Stream.Dict.GetInteger('W', 0)));
            Height := Integer(Stream.Dict.GetInteger('Height', Stream.Dict.GetInteger('H', 0)));
            Name := Format('%s %s', [ExtractFileName(FileName), Key]);
            if Seen.ContainsKey(Name + IntToStr(Length(Data))) then
              Continue;
            Seen.Add(Name + IntToStr(Length(Data)), True);
            Found := True;
            Parms := Stream.ImageFilterParms;
            P := ParamsFromDict(Parms, Height);
            Inc(KCounts[Sign(P.K) + 1]);
            Watch := TStopwatch.StartNew;
            try
              Output := PdfCCITTDecode(Data, P, Rows);
            except
              on E: Exception do
              begin
                Inc(Failed);
                Log.AppendFormat('%s: %s %s; ', [Name, E.ClassName, E.Message]);
                Continue;
              end;
            end;
            Watch.Stop;
            if Rows <= 0 then
            begin
              Inc(Failed);
              Log.AppendFormat('%s: no rows; ', [Name]);
              Continue;
            end;
            Inc(Ok);
            Info := '';
            if Rows < Height then
            begin
              Inc(Partial);
              Info := ' PARTIAL';
            end;
            Log.AppendFormat('%s: %dx%d K=%d Columns=%d EOB=%s Align=%s -> %d rows in %d ms%s; ', [Name, Width, Height,
              P.K, P.Columns, BoolToStr(P.EndOfBlock, True), BoolToStr(P.ByteAlign, True), Rows,
              Watch.ElapsedMilliseconds, Info]);
            DecodeArr := Stream.Dict.GetArray('Decode');
            Invert := (DecodeArr <> nil) and (DecodeArr.Count > 0) and (DecodeArr.GetNumber(0) > 0.5);
            if TDirectory.Exists(ScratchDir) and SameText(ExtractFileName(FileName), 'ccitt_EndOfBlock_false.pdf') then
              WritePng(TPath.Combine(ScratchDir, 'ccitt_EndOfBlock_false_' + Key + '.png'), Output, P.Columns, Width,
                Height, Rows, Invert);
            if (P.K < 0) and (Rows = Height) and (Int64(Width) * Height > BestG4Area) and
              (Int64(Width) * Height < 100000000) and TDirectory.Exists(ScratchDir) then
            begin
              BestG4Area := Width * Height;
              WritePng(TPath.Combine(ScratchDir, 'ccitt_largest_g4.png'), Output, P.Columns, Width, Height, Rows, Invert);
              Log.AppendFormat('largest G4 so far: %s; ', [Name]);
            end;
            if (Rows = Height) and (Int64(Width) * Height > BestArea) and (Int64(Width) * Height < 100000000) then
            begin
              BestArea := Width * Height;
              BestOutput := Output;
              BestParams := P;
              BestW := Width;
              BestH := Height;
              BestRows := Rows;
              BestInvert := Invert;
              BestName := ChangeFileExt(ExtractFileName(FileName), '') + '_' + Key;
            end;
          end;
        end;
      finally
        Doc.Free;
      end;
      if Found then
        Inc(FilesWithCCITT);
    end;
    if (BestArea > 0) and TDirectory.Exists(ScratchDir) then
    begin
      WritePng(TPath.Combine(ScratchDir, 'ccitt_largest_' + BestName + '.png'), BestOutput, BestParams.Columns, BestW,
        BestH, BestRows, BestInvert);
      Log.AppendFormat('largest: %s %dx%d; ', [BestName, BestW, BestH]);
    end;
    TDUnitX.CurrentRunner.Log(TLogLevel.Information, Format('CCITT corpus: %d PDFs scanned in %d s, %d with CCITT ' +
      'images; %d images decoded (%d partial), %d failed; K<0: %d, K=0: %d, K>0: %d. %s', [Files,
      Total.ElapsedMilliseconds div 1000, FilesWithCCITT, Ok, Partial, Failed, KCounts[0], KCounts[1], KCounts[2],
      Log.ToString]));
  finally
    Log.Free;
    Seen.Free;
  end;
  Assert.AreEqual(0, Failed, 'CCITT images that failed to decode');
  Assert.IsTrue(Ok > 0, 'no CCITT image found in the corpus');
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfCCITTTests);

end.
