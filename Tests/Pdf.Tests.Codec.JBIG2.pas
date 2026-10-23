{*******************************************************************************
  Pdf.Tests.Codec.JBIG2
  DUnitX tests for the JBIG2 decoder (Pdf.Codec.JBIG2, .Arith, .Huffman): the MQ
  decoder against the T.88 H.2 test sequence and a test-side MQ encoder, integer
  and IAID procedures, Huffman tables, segment header parsing, composition,
  synthetic generic regions (encoded here) and the pdf.js corpus.
*******************************************************************************}
unit Pdf.Tests.Codec.JBIG2;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Diagnostics, System.Generics.Collections, System.Skia,
  DUnitX.TestFramework, Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Document,
  Pdf.Codec.JBIG2.Arith, Pdf.Codec.JBIG2.Huffman, Pdf.Codec.JBIG2;

type
  [TestFixture]
  TPdfJBIG2Tests = class
  public
    [Test] procedure ArithDecoderSpecVector;
    [Test] procedure ArithEncoderSpecVector;
    [Test] procedure ArithRoundTripSingleContext;
    [Test] procedure ArithRoundTripManyContexts;
    [Test] procedure ArithReadsPastEndAsFF;
    [Test] procedure IntegerRoundTrip;
    [Test] procedure IAIDRoundTrip;
    [Test] procedure StandardHuffmanTables;
    [Test] procedure CustomHuffmanTable;
    [Test] procedure SegmentHeaderShortForm;
    [Test] procedure SegmentHeaderLongFormAndWideNumbers;
    [Test] procedure SegmentHeaderUnknownLength;
    [Test] procedure UnusableFirstHeaderRaises;
    [Test] procedure TruncatedLaterSegmentKeepsPage;
    [Test] procedure ComposeOperators;
    [Test] procedure ComposeClipping;
    [Test] procedure GenericRegionPattern;
    [Test] procedure GenericRegionTPGDONAllWhite;
    [Test] procedure GenericRegionUnknownLength;
    [Test] procedure RegionCombinationOperators;
    [Test] procedure PageDefaultPixelAndPacking;
    [Test] procedure LargeGenericRegionIsFast;
    [Test] procedure CorpusBitmapFamily;
    [Test] procedure CorpusAllJBIG2Images;
    [Test] procedure CorruptDataDoesNotRaise;
  end;

implementation

{ MQ encoder (T.88 Annex E.2), test side only }

type
  TQe = record
    Qe: Cardinal;
    NMps, NLps, Switch: Byte;
  end;

const
  QeTable: array[0..46] of TQe = (
    (Qe: $5601; NMps: 1; NLps: 1; Switch: 1), (Qe: $3401; NMps: 2; NLps: 6; Switch: 0),
    (Qe: $1801; NMps: 3; NLps: 9; Switch: 0), (Qe: $0AC1; NMps: 4; NLps: 12; Switch: 0),
    (Qe: $0521; NMps: 5; NLps: 29; Switch: 0), (Qe: $0221; NMps: 38; NLps: 33; Switch: 0),
    (Qe: $5601; NMps: 7; NLps: 6; Switch: 1), (Qe: $5401; NMps: 8; NLps: 14; Switch: 0),
    (Qe: $4801; NMps: 9; NLps: 14; Switch: 0), (Qe: $3801; NMps: 10; NLps: 14; Switch: 0),
    (Qe: $3001; NMps: 11; NLps: 17; Switch: 0), (Qe: $2401; NMps: 12; NLps: 18; Switch: 0),
    (Qe: $1C01; NMps: 13; NLps: 20; Switch: 0), (Qe: $1601; NMps: 29; NLps: 21; Switch: 0),
    (Qe: $5601; NMps: 15; NLps: 14; Switch: 1), (Qe: $5401; NMps: 16; NLps: 14; Switch: 0),
    (Qe: $5101; NMps: 17; NLps: 15; Switch: 0), (Qe: $4801; NMps: 18; NLps: 16; Switch: 0),
    (Qe: $3801; NMps: 19; NLps: 17; Switch: 0), (Qe: $3401; NMps: 20; NLps: 18; Switch: 0),
    (Qe: $3001; NMps: 21; NLps: 19; Switch: 0), (Qe: $2801; NMps: 22; NLps: 19; Switch: 0),
    (Qe: $2401; NMps: 23; NLps: 20; Switch: 0), (Qe: $2201; NMps: 24; NLps: 21; Switch: 0),
    (Qe: $1C01; NMps: 25; NLps: 22; Switch: 0), (Qe: $1801; NMps: 26; NLps: 23; Switch: 0),
    (Qe: $1601; NMps: 27; NLps: 24; Switch: 0), (Qe: $1401; NMps: 28; NLps: 25; Switch: 0),
    (Qe: $1201; NMps: 29; NLps: 26; Switch: 0), (Qe: $1101; NMps: 30; NLps: 27; Switch: 0),
    (Qe: $0AC1; NMps: 31; NLps: 28; Switch: 0), (Qe: $09C1; NMps: 32; NLps: 29; Switch: 0),
    (Qe: $08A1; NMps: 33; NLps: 30; Switch: 0), (Qe: $0521; NMps: 34; NLps: 31; Switch: 0),
    (Qe: $0441; NMps: 35; NLps: 32; Switch: 0), (Qe: $02A1; NMps: 36; NLps: 33; Switch: 0),
    (Qe: $0221; NMps: 37; NLps: 34; Switch: 0), (Qe: $0141; NMps: 38; NLps: 35; Switch: 0),
    (Qe: $0111; NMps: 39; NLps: 36; Switch: 0), (Qe: $0085; NMps: 40; NLps: 37; Switch: 0),
    (Qe: $0049; NMps: 41; NLps: 38; Switch: 0), (Qe: $0025; NMps: 42; NLps: 39; Switch: 0),
    (Qe: $0015; NMps: 43; NLps: 40; Switch: 0), (Qe: $0009; NMps: 44; NLps: 41; Switch: 0),
    (Qe: $0005; NMps: 45; NLps: 42; Switch: 0), (Qe: $0001; NMps: 45; NLps: 43; Switch: 0),
    (Qe: $5601; NMps: 46; NLps: 46; Switch: 0));

  // T.88 H.2 test sequence: 256 decisions with one context and the expected code string
  SpecPlain: array[0..31] of Byte = (
    $00, $02, $00, $51, $00, $00, $00, $C0, $03, $52, $87, $2A, $AA, $AA, $AA, $AA,
    $82, $C0, $20, $00, $FC, $D7, $9E, $F6, $BF, $7F, $ED, $90, $4F, $46, $A3, $BF);
  SpecCoded: array[0..29] of Byte = (
    $84, $C7, $3B, $FC, $E1, $A1, $43, $04, $02, $20, $00, $00, $41, $0D, $BB, $86,
    $F4, $31, $7F, $FF, $88, $FF, $37, $47, $1A, $DB, $6A, $DF, $FF, $AC);

type
  TMQEncoder = class
  private
    FA: Cardinal;
    FC: Cardinal;
    FCT: Integer;
    FOut: TList<Byte>; // FOut[0] is the byte before the code string
    procedure ByteOut;
    procedure RenormE;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Encode(const Contexts: TBytes; Pos, Bit: Integer);
    function Flush: TBytes;
  end;

constructor TMQEncoder.Create;
begin
  inherited Create;
  FOut := TList<Byte>.Create;
  FOut.Add(0);
  FA := $8000;
  FC := 0;
  FCT := 12;
end;

destructor TMQEncoder.Destroy;
begin
  FOut.Free;
  inherited;
end;

procedure TMQEncoder.ByteOut;
var
  B: Byte;
begin
  B := FOut.Last;
  if B = $FF then
  begin
    FOut.Add(Byte(FC shr 20));
    FC := FC and $FFFFF;
    FCT := 7;
  end
  else if FC < $8000000 then
  begin
    FOut.Add(Byte(FC shr 19));
    FC := FC and $7FFFF;
    FCT := 8;
  end
  else
  begin
    Inc(B);
    FOut[FOut.Count - 1] := B;
    if B = $FF then
    begin
      FC := FC and $7FFFFFF;
      FOut.Add(Byte(FC shr 20));
      FC := FC and $FFFFF;
      FCT := 7;
    end
    else
    begin
      FOut.Add(Byte(FC shr 19));
      FC := FC and $7FFFF;
      FCT := 8;
    end;
  end;
end;

procedure TMQEncoder.RenormE;
begin
  repeat
    FA := FA shl 1;
    FC := FC shl 1;
    Dec(FCT);
    if FCT = 0 then
      ByteOut;
  until (FA and $8000) <> 0;
end;

procedure TMQEncoder.Encode(const Contexts: TBytes; Pos, Bit: Integer);
var
  I, Mps: Integer;
  Qe: Cardinal;
begin
  I := Contexts[Pos] shr 1;
  Mps := Contexts[Pos] and 1;
  Qe := QeTable[I].Qe;
  FA := FA - Qe;
  if Bit = Mps then
  begin
    // CODEMPS
    if (FA and $8000) = 0 then
    begin
      if FA < Qe then
        FA := Qe
      else
        FC := FC + Qe;
      I := QeTable[I].NMps;
      RenormE;
    end
    else
      FC := FC + Qe;
  end
  else
  begin
    // CODELPS
    if FA < Qe then
      FC := FC + Qe
    else
      FA := Qe;
    if QeTable[I].Switch = 1 then
      Mps := 1 - Mps;
    I := QeTable[I].NLps;
    RenormE;
  end;
  Contexts[Pos] := Byte((I shl 1) or Mps);
end;

function TMQEncoder.Flush: TBytes;
var
  TempC: Cardinal;
  I: Integer;
begin
  // SETBITS
  TempC := FC + FA;
  FC := FC or $FFFF;
  if FC >= TempC then
    FC := FC - $8000;
  FC := FC shl FCT;
  ByteOut;
  FC := FC shl FCT;
  ByteOut;
  if FOut.Last <> $FF then
    FOut.Add($FF);
  FOut.Add($AC);
  SetLength(Result, FOut.Count - 1);
  for I := 1 to FOut.Count - 1 do
    Result[I - 1] := FOut[I];
end;

{ Small helpers }

type
  TRng = record
    State: UInt64;
    function Next(Range: Integer): Integer;
  end;

function TRng.Next(Range: Integer): Integer;
begin
  State := State * UInt64(6364136223846793005) + UInt64(1442695040888963407);
  Result := Integer((State shr 33) mod UInt64(Cardinal(Range)));
end;

function BytesOf(const A: array of Byte): TBytes;
begin
  SetLength(Result, Length(A));
  if Length(A) > 0 then
    Move(A[0], Result[0], Length(A));
end;

procedure PutU32(var B: TBytes; V: Cardinal);
begin
  B := B + [Byte(V shr 24), Byte(V shr 16), Byte(V shr 8), Byte(V)];
end;

procedure PutU16(var B: TBytes; V: Cardinal);
begin
  B := B + [Byte(V shr 8), Byte(V)];
end;

type
  TBitWriter = record
    Data: TBytes;
    Count: Integer;
    procedure Put(Value: UInt64; Bits: Integer);
  end;

procedure TBitWriter.Put(Value: UInt64; Bits: Integer);
var
  I: Integer;
begin
  for I := Bits - 1 downto 0 do
  begin
    if Count mod 8 = 0 then
      Data := Data + [0];
    if (Value shr I) and 1 <> 0 then
      Data[Count div 8] := Data[Count div 8] or (1 shl (7 - Count mod 8));
    Inc(Count);
  end;
end;

/// Builds a segment (7.2): header with short or long referred-to form and the given data part.
function Segment(Number: Cardinal; SegType: Byte; const Refs: array of Cardinal; const Body: TBytes;
  Page: Cardinal = 1; LongPage: Boolean = False; UnknownLength: Boolean = False): TBytes;
var
  Flags: Byte;
  I, RefSize: Integer;
begin
  Result := nil;
  PutU32(Result, Number);
  Flags := SegType;
  if LongPage then
    Flags := Flags or $40;
  Result := Result + [Flags];
  if Length(Refs) <= 4 then
    Result := Result + [Byte(Length(Refs) shl 5)]
  else
  begin
    PutU32(Result, $E0000000 or Cardinal(Length(Refs)));
    for I := 1 to (Length(Refs) + 8) div 8 do
      Result := Result + [0];
  end;
  if Number <= 256 then
    RefSize := 1
  else if Number <= 65536 then
    RefSize := 2
  else
    RefSize := 4;
  for I := 0 to High(Refs) do
    case RefSize of
      1: Result := Result + [Byte(Refs[I])];
      2: PutU16(Result, Refs[I]);
    else
      PutU32(Result, Refs[I]);
    end;
  if LongPage then
    PutU32(Result, Page)
  else
    Result := Result + [Byte(Page)];
  if UnknownLength then
    PutU32(Result, $FFFFFFFF)
  else
    PutU32(Result, Length(Body));
  Result := Result + Body;
end;

function PageInfo(W, H: Cardinal; Flags: Byte): TBytes;
begin
  Result := nil;
  PutU32(Result, W);
  PutU32(Result, H);
  PutU32(Result, 0);
  PutU32(Result, 0);
  Result := Result + [Flags];
  PutU16(Result, 0);
end;

type
  TImage = record
    W, H: Integer;
    P: TBytes; // one byte per pixel, 1 = black
    function Get(X, Y: Integer): Integer;
  end;

function TImage.Get(X, Y: Integer): Integer;
begin
  if (X < 0) or (X >= W) or (Y < 0) or (Y >= H) then
    Result := 0
  else
    Result := P[Y * W + X];
end;

function MakeImage(W, H: Integer; Value: Byte): TImage;
begin
  Result.W := W;
  Result.H := H;
  SetLength(Result.P, W * H);
  if W * H > 0 then
    FillChar(Result.P[0], W * H, Value);
end;

/// Arithmetic coding of an image with generic template 0 and the default AT pixels (T.88 6.2.5.3),
/// context bits computed independently of the decoder.
function EncodeTemplate0(const Img: TImage; TPGDON: Boolean): TBytes;
const
  // (dx, dy, bit) for the 16 template pixels, default AT positions included
  T: array[0..15, 0..2] of Integer = (
    (-1, 0, 0), (-2, 0, 1), (-3, 0, 2), (-4, 0, 3), (3, -1, 4), (2, -1, 5), (1, -1, 6), (0, -1, 7),
    (-1, -1, 8), (-2, -1, 9), (-3, -1, 10), (2, -2, 11), (1, -2, 12), (0, -2, 13), (-1, -2, 14), (-2, -2, 15));
var
  Enc: TMQEncoder;
  Ctx: TBytes;
  X, Y, K, Cx: Integer;
  LTP, Same: Boolean;
begin
  SetLength(Ctx, 65536);
  Enc := TMQEncoder.Create;
  try
    LTP := False;
    for Y := 0 to Img.H - 1 do
    begin
      if TPGDON then
      begin
        Same := True;
        for X := 0 to Img.W - 1 do
          if Img.Get(X, Y) <> Img.Get(X, Y - 1) then
          begin
            Same := False;
            Break;
          end;
        Enc.Encode(Ctx, $9B25, Ord(Same <> LTP));
        LTP := Same;
        if LTP then
          Continue;
      end;
      for X := 0 to Img.W - 1 do
      begin
        Cx := 0;
        for K := 0 to 15 do
          if Img.Get(X + T[K, 0], Y + T[K, 1]) <> 0 then
            Cx := Cx or (1 shl T[K, 2]);
        Enc.Encode(Ctx, Cx, Img.Get(X, Y));
      end;
    end;
    Result := Enc.Flush;
  finally
    Enc.Free;
  end;
end;

function GenericRegionBody(const Img: TImage; X, Y: Cardinal; Op: Byte; TPGDON: Boolean;
  UnknownHeight: Boolean = False): TBytes;
begin
  Result := nil;
  PutU32(Result, Img.W);
  if UnknownHeight then
    PutU32(Result, $FFFFFFFF)
  else
    PutU32(Result, Img.H);
  PutU32(Result, X);
  PutU32(Result, Y);
  Result := Result + [Op];
  if TPGDON then
    Result := Result + [$08]
  else
    Result := Result + [$00];
  Result := Result + [$03, $FF, $FD, $FF, $02, $FE, $FE, $FE]; // default AT pixels
  Result := Result + EncodeTemplate0(Img, TPGDON);
end;

/// Packs a model page like the PDF filter output: 1 = white.
function PackModel(const Img: TImage): TBytes;
var
  Stride, X, Y: Integer;
begin
  Stride := (Img.W + 7) div 8;
  SetLength(Result, Stride * Img.H);
  FillChar(Result[0], Length(Result), $FF);
  for Y := 0 to Img.H - 1 do
    for X := 0 to Img.W - 1 do
      if Img.P[Y * Img.W + X] <> 0 then
        Result[Y * Stride + X shr 3] := Result[Y * Stride + X shr 3] and not (1 shl (7 - X and 7));
end;

procedure ModelCompose(var Page: TImage; const Src: TImage; X0, Y0, Op: Integer);
var
  X, Y, D, S: Integer;
begin
  for Y := 0 to Src.H - 1 do
    for X := 0 to Src.W - 1 do
      if (X0 + X >= 0) and (X0 + X < Page.W) and (Y0 + Y >= 0) and (Y0 + Y < Page.H) then
      begin
        D := Page.P[(Y0 + Y) * Page.W + X0 + X];
        S := Src.P[Y * Src.W + X];
        case Op of
          0: D := D or S;
          1: D := D and S;
          2: D := D xor S;
          3: D := 1 - (D xor S);
          4: D := S;
        end;
        Page.P[(Y0 + Y) * Page.W + X0 + X] := D;
      end;
end;

function CountDiffs(const A, B: TBytes): Integer;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(MaxInt);
  Result := 0;
  for I := 0 to High(A) do
    if A[I] <> B[I] then
      Inc(Result);
end;

function TestPattern(W, H: Integer; Seed: UInt64): TImage;
var
  X, Y: Integer;
  Rng: TRng;
begin
  Result := MakeImage(W, H, 0);
  Rng.State := Seed;
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
      // blocks, a diagonal band and some noise
      if (((X div 8) + (Y div 8)) mod 3 = 0) or (Abs(X - Y) < 3) or (Rng.Next(50) = 0) then
        Result.P[Y * W + X] := 1;
end;

function CorpusDir: string;
var
  Env, Dir: string;
begin
  Env := GetEnvironmentVariable('PDF_CORPUS_DIRS');
  for Dir in Env.Split([';']) do
    if (Dir <> '') and TFile.Exists(TPath.Combine(Dir, 'bitmap-symbol.pdf')) then
      Exit(Dir);
  Result := TPath.Combine(TPath.GetTempPath, 'claude\pdfjs-corpus\pdfjs\test\pdfs');
end;

function ScratchDir: string;
begin
  Result := TPath.GetFullPath(TPath.Combine(ExtractFilePath(ParamStr(0)), '..\scratch'));
  if not TDirectory.Exists(Result) then
    Result := '';
end;

procedure SavePng(const FileName: string; const Bits: TBytes; W, H: Integer);
var
  Gray: TBytes;
  X, Y, Stride: Integer;
  Img: ISkImage;
begin
  Stride := (W + 7) div 8;
  SetLength(Gray, W * H);
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
      if (Bits[Y * Stride + X shr 3] shr (7 - X and 7)) and 1 <> 0 then
        Gray[Y * W + X] := 255
      else
        Gray[Y * W + X] := 0;
  Img := TSkImage.MakeRasterCopy(TSkImageInfo.Create(W, H, TSkColorType.Gray8), @Gray[0], W);
  TFile.WriteAllBytes(FileName, Img.Encode(TSkEncodedImageFormat.PNG));
end;

type
  TJBig2Image = record
    Key: string;
    Data: TBytes;
    Globals: TBytes;
    Width: Integer;
    Height: Integer;
  end;

procedure CollectImages(const Resources: IPdfDictionary; Depth: Integer; Visited: TList<Integer>;
  var List: TArray<TJBig2Image>);
var
  XObjects, Parms: IPdfDictionary;
  Key: string;
  S, G: IPdfStream;
  Img: TJBig2Image;
begin
  if (Resources = nil) or (Depth > 4) then
    Exit;
  XObjects := Resources.GetDictionary('XObject');
  if XObjects = nil then
    Exit;
  for Key in XObjects.Keys do
  begin
    S := XObjects.GetStream(Key);
    if S = nil then
      Continue;
    if S.ObjNum > 0 then
    begin
      if Visited.Contains(S.ObjNum) then
        Continue;
      Visited.Add(S.ObjNum);
    end;
    if S.Dict.GetName('Subtype') = 'Form' then
      CollectImages(S.Dict.GetDictionary('Resources'), Depth + 1, Visited, List)
    else if S.ImageFilter = 'JBIG2Decode' then
    begin
      Img.Key := Key;
      Img.Data := S.GetDecodedData;
      Img.Globals := nil;
      Parms := S.ImageFilterParms;
      if Parms <> nil then
      begin
        G := Parms.GetStream('JBIG2Globals');
        if G <> nil then
          Img.Globals := G.GetDecodedData;
      end;
      Img.Width := Integer(S.Dict.GetInteger('Width'));
      Img.Height := Integer(S.Dict.GetInteger('Height'));
      List := List + [Img];
    end;
  end;
end;

/// JBIG2 image XObjects of the first MaxPages pages (forms included).
function LoadImages(const FileName: string; MaxPages: Integer): TArray<TJBig2Image>;
var
  Doc: TPdfDocument;
  Visited: TList<Integer>;
  I: Integer;
begin
  Result := nil;
  Doc := TPdfDocument.Create;
  Visited := TList<Integer>.Create;
  try
    Doc.LoadFromFile(FileName);
    for I := 0 to Doc.PageCount - 1 do
    begin
      if I >= MaxPages then
        Break;
      CollectImages(Doc.Pages[I].Resources, 0, Visited, Result);
    end;
  finally
    Visited.Free;
    Doc.Free;
  end;
end;

procedure LogInfo(const Msg: string);
begin
  TDUnitX.CurrentRunner.Log(TLogLevel.Information, Msg);
end;

{ TPdfJBIG2Tests }

procedure TPdfJBIG2Tests.ArithDecoderSpecVector;
var
  Dec: TJBig2ArithDecoder;
  Ctx: TBytes;
  I, Bit: Integer;
  Expected: Integer;
begin
  SetLength(Ctx, 1);
  Dec := TJBig2ArithDecoder.Create(BytesOf(SpecCoded), 0, Length(SpecCoded));
  try
    for I := 0 to 255 do
    begin
      Bit := Dec.ReadBit(Ctx, 0);
      Expected := (SpecPlain[I div 8] shr (7 - I mod 8)) and 1;
      if Bit <> Expected then
        Assert.Fail(Format('decision %d: got %d, expected %d', [I, Bit, Expected]));
    end;
  finally
    Dec.Free;
  end;
  Assert.Pass;
end;

procedure TPdfJBIG2Tests.ArithEncoderSpecVector;
var
  Enc: TMQEncoder;
  Ctx, Coded: TBytes;
  I: Integer;
begin
  // validates the test-side encoder used by the round trip and region tests
  SetLength(Ctx, 1);
  Enc := TMQEncoder.Create;
  try
    for I := 0 to 255 do
      Enc.Encode(Ctx, 0, (SpecPlain[I div 8] shr (7 - I mod 8)) and 1);
    Coded := Enc.Flush;
  finally
    Enc.Free;
  end;
  Assert.AreEqual(Integer(Length(SpecCoded)), Integer(Length(Coded)), 'code string length');
  for I := 0 to High(SpecCoded) do
    Assert.AreEqual(Integer(SpecCoded[I]), Integer(Coded[I]), Format('code byte %d', [I]));
end;

procedure RoundTrip(ContextCount, Count: Integer; Seed: UInt64);
var
  Enc: TMQEncoder;
  Dec: TJBig2ArithDecoder;
  EncCtx, DecCtx, Coded: TBytes;
  Bits, Ctxs, Bias: TArray<Integer>;
  Rng: TRng;
  I: Integer;
begin
  Rng.State := Seed;
  SetLength(Bits, Count);
  SetLength(Ctxs, Count);
  SetLength(Bias, ContextCount);
  for I := 0 to ContextCount - 1 do
    Bias[I] := Rng.Next(100); // per context probability of a 1
  for I := 0 to Count - 1 do
  begin
    Ctxs[I] := Rng.Next(ContextCount);
    Bits[I] := Ord(Rng.Next(100) < Bias[Ctxs[I]]);
  end;
  SetLength(EncCtx, ContextCount);
  SetLength(DecCtx, ContextCount);
  Enc := TMQEncoder.Create;
  try
    for I := 0 to Count - 1 do
      Enc.Encode(EncCtx, Ctxs[I], Bits[I]);
    Coded := Enc.Flush;
  finally
    Enc.Free;
  end;
  Dec := TJBig2ArithDecoder.Create(Coded, 0, Length(Coded));
  try
    for I := 0 to Count - 1 do
      if Dec.ReadBit(DecCtx, Ctxs[I]) <> Bits[I] then
        Assert.Fail(Format('%d contexts: decision %d differs', [ContextCount, I]));
  finally
    Dec.Free;
  end;
end;

procedure TPdfJBIG2Tests.ArithRoundTripSingleContext;
var
  Seed: UInt64;
begin
  for Seed := 1 to 20 do
    RoundTrip(1, 5000, Seed);
  Assert.Pass;
end;

procedure TPdfJBIG2Tests.ArithRoundTripManyContexts;
var
  Seed: UInt64;
begin
  for Seed := 1 to 10 do
  begin
    RoundTrip(7, 20000, Seed * 31);
    RoundTrip(512, 50000, Seed * 77);
  end;
  Assert.Pass;
end;

procedure TPdfJBIG2Tests.ArithReadsPastEndAsFF;
var
  Dec: TJBig2ArithDecoder;
  Ctx, Data: TBytes;
  I: Integer;
begin
  // decoding beyond Finish must neither read the bytes after it nor fail early
  Data := BytesOf([$84, $C7, $3B, $FC, $FF, $00, $12, $34]);
  SetLength(Ctx, 1);
  Dec := TJBig2ArithDecoder.Create(Data, 0, 4);
  try
    for I := 1 to 2000 do
      Dec.ReadBit(Ctx, 0);
    Assert.IsTrue(Dec.Position <= 4, 'decoder must not move past the end of its data');
  finally
    Dec.Free;
  end;
end;

procedure EncodeInteger(Enc: TMQEncoder; const Ctx: TBytes; Value: Int64; OOB: Boolean);
var
  Prev: Integer;

  procedure Bits(V: Int64; N: Integer);
  var
    I, Bit: Integer;
  begin
    for I := N - 1 downto 0 do
    begin
      Bit := (V shr I) and 1;
      Enc.Encode(Ctx, Prev, Bit);
      if Prev < 256 then
        Prev := (Prev shl 1) or Bit
      else
        Prev := (((Prev shl 1) or Bit) and 511) or 256;
    end;
  end;

var
  V: Int64;
begin
  Prev := 1;
  if OOB then
  begin
    Bits(1, 1);
    Bits(0, 1);
    Bits(0, 2);
    Exit;
  end;
  Bits(Ord(Value < 0), 1);
  V := Abs(Value);
  if V < 4 then
  begin
    Bits(0, 1);
    Bits(V, 2);
  end
  else if V < 20 then
  begin
    Bits(2, 2);
    Bits(V - 4, 4);
  end
  else if V < 84 then
  begin
    Bits(6, 3);
    Bits(V - 20, 6);
  end
  else if V < 340 then
  begin
    Bits(14, 4);
    Bits(V - 84, 8);
  end
  else if V < 4436 then
  begin
    Bits(30, 5);
    Bits(V - 340, 12);
  end
  else
  begin
    Bits(31, 5);
    Bits(V - 4436, 32);
  end;
end;

procedure TPdfJBIG2Tests.IntegerRoundTrip;
const
  Values: array[0..19] of Integer = (0, 1, -1, 3, -3, 4, 19, -19, 20, 83, 84, -84, 339, 340, 4435, 4436,
    100000, -100000, 2147483647, -2147483647);
var
  Enc: TMQEncoder;
  Dec: TJBig2ArithDecoder;
  EncCtx, DecCtx, Coded: TBytes;
  I, V: Integer;
begin
  SetLength(EncCtx, 512);
  SetLength(DecCtx, 512);
  Enc := TMQEncoder.Create;
  try
    for I := 0 to High(Values) do
    begin
      EncodeInteger(Enc, EncCtx, Values[I], False);
      if I mod 5 = 4 then
        EncodeInteger(Enc, EncCtx, 0, True);
    end;
    Coded := Enc.Flush;
  finally
    Enc.Free;
  end;
  Dec := TJBig2ArithDecoder.Create(Coded, 0, Length(Coded));
  try
    for I := 0 to High(Values) do
    begin
      Assert.IsTrue(JBig2DecodeInteger(Dec, DecCtx, V), Format('value %d decoded as OOB', [Values[I]]));
      Assert.AreEqual(Values[I], V);
      if I mod 5 = 4 then
        Assert.IsFalse(JBig2DecodeInteger(Dec, DecCtx, V), 'OOB expected');
    end;
  finally
    Dec.Free;
  end;
end;

procedure TPdfJBIG2Tests.IAIDRoundTrip;
var
  Enc: TMQEncoder;
  Dec: TJBig2ArithDecoder;
  EncCtx, Coded: TBytes;
  Ctxs: TJBig2Contexts;
  Rng: TRng;
  IDs: TArray<Integer>;
  I, K, Prev, Bit: Integer;
const
  CodeLength = 9;
begin
  Rng.State := 99;
  SetLength(IDs, 300);
  SetLength(EncCtx, 1 shl (CodeLength + 1));
  Enc := TMQEncoder.Create;
  try
    for I := 0 to High(IDs) do
    begin
      IDs[I] := Rng.Next(1 shl CodeLength);
      Prev := 1;
      for K := CodeLength - 1 downto 0 do
      begin
        Bit := (IDs[I] shr K) and 1;
        Enc.Encode(EncCtx, Prev, Bit);
        Prev := (Prev shl 1) or Bit;
      end;
    end;
    Coded := Enc.Flush;
  finally
    Enc.Free;
  end;
  Ctxs := TJBig2Contexts.Create;
  Dec := TJBig2ArithDecoder.Create(Coded, 0, Length(Coded));
  try
    for I := 0 to High(IDs) do
      Assert.AreEqual(IDs[I], JBig2DecodeIAID(Dec, Ctxs, CodeLength), Format('ID %d', [I]));
  finally
    Dec.Free;
    Ctxs.Free;
  end;
end;

procedure TPdfJBIG2Tests.StandardHuffmanTables;
var
  W: TBitWriter;
  Reader: TJBig2BitReader;
  B1, B2, B3: TJBig2HuffmanTable;
  V: Integer;
begin
  W := Default(TBitWriter);
  W.Put(0, 1); W.Put(5, 4);         // B.1: 5
  W.Put(2, 2); W.Put(4, 8);         // B.1: 16 + 4
  W.Put(6, 3); W.Put(28, 16);       // B.1: 272 + 28
  W.Put($3F, 6);                    // B.2: OOB
  W.Put($E, 4); W.Put(5, 3);        // B.2: 3 + 5
  W.Put($FF, 8); W.Put(43, 32);     // B.3 lower range: -257 - 43
  W.Put($FE, 8); W.Put(10, 8);      // B.3: -256 + 10
  B1 := JBig2StandardTable(1);
  B2 := JBig2StandardTable(2);
  B3 := JBig2StandardTable(3);
  Reader := TJBig2BitReader.Create(W.Data, 0, Length(W.Data));
  try
    Assert.AreEqual(5, B1.DecodeValue(Reader));
    Assert.AreEqual(20, B1.DecodeValue(Reader));
    Assert.AreEqual(300, B1.DecodeValue(Reader));
    Assert.IsFalse(B2.Decode(Reader, V), 'B.2 OOB');
    Assert.AreEqual(8, B2.DecodeValue(Reader));
    Assert.AreEqual(-300, B3.DecodeValue(Reader));
    Assert.AreEqual(-246, B3.DecodeValue(Reader));
  finally
    Reader.Free;
    B1.Free;
    B2.Free;
    B3.Free;
  end;
end;

procedure TPdfJBIG2Tests.CustomHuffmanTable;
var
  Seg: TBytes;
  W, Values: TBitWriter;
  Table: TJBig2HuffmanTable;
  Reader: TJBig2BitReader;
  V: Integer;
begin
  // B.2 code table: OOB, prefix lengths in 3 bits, range lengths in 2 bits, range 0..10
  Seg := [$01 or (2 shl 1) or (1 shl 4)];
  PutU32(Seg, 0);
  PutU32(Seg, 10);
  W := Default(TBitWriter);
  W.Put(1, 3); W.Put(2, 2); // 0..3
  W.Put(2, 3); W.Put(2, 2); // 4..7
  W.Put(3, 3); W.Put(1, 2); // 8..9
  W.Put(4, 3);              // lower range
  W.Put(5, 3);              // upper range
  W.Put(5, 3);              // OOB
  Seg := Seg + W.Data;
  Table := JBig2DecodeTableSegment(Seg, 0, Length(Seg));
  try
    // B.3 codes: 0, 10, 110, 1110 (lower), 11110 (upper), 11111 (OOB)
    Values := Default(TBitWriter);
    Values.Put(0, 1); Values.Put(2, 2);
    Values.Put(2, 2); Values.Put(2, 2);
    Values.Put(6, 3); Values.Put(1, 1);
    Values.Put($E, 4); Values.Put(4, 32);
    Values.Put($1E, 5); Values.Put(990, 32);
    Values.Put($1F, 5);
    Reader := TJBig2BitReader.Create(Values.Data, 0, Length(Values.Data));
    try
      Assert.AreEqual(2, Table.DecodeValue(Reader));
      Assert.AreEqual(6, Table.DecodeValue(Reader));
      Assert.AreEqual(9, Table.DecodeValue(Reader));
      Assert.AreEqual(-5, Table.DecodeValue(Reader));
      Assert.AreEqual(1000, Table.DecodeValue(Reader));
      Assert.IsFalse(Table.Decode(Reader, V), 'OOB');
      Reader.Position := Integer(Length(Values.Data));
      try
        Reader.ReadBit;
        Assert.Fail('EJBig2Error expected at the end of the data');
      except
        on E: EJBig2Error do
          ;
      end;
    finally
      Reader.Free;
    end;
  finally
    Table.Free;
  end;
end;

procedure TPdfJBIG2Tests.SegmentHeaderShortForm;
var
  Data: TBytes;
  H: TArray<TJBig2SegmentHeader>;
begin
  Data := Segment(0, 48, [], PageInfo(10, 10, 0)) + Segment(1, 53, [0], [1, 2, 3]) +
    Segment(2, 6, [0, 1, 255], [9]) + Segment(3, 50, [], [0, 0, 0, 9]) + Segment(4, 51, [], []);
  H := PdfJBIG2ReadSegmentHeaders(Data);
  Assert.AreEqual(5, Integer(Length(H)));
  Assert.AreEqual(48, H[0].SegmentType);
  Assert.AreEqual(19, H[0].DataLength);
  Assert.AreEqual(Cardinal(1), H[0].PageAssociation);
  Assert.AreEqual(1, Integer(Length(H[1].ReferredTo)));
  Assert.AreEqual(3, H[1].DataLength);
  Assert.AreEqual(3, Integer(Length(H[2].ReferredTo)));
  Assert.AreEqual(Cardinal(255), H[2].ReferredTo[2]);
  Assert.AreEqual(Integer(9), Integer(Data[H[2].DataStart]));
  Assert.AreEqual(50, H[3].SegmentType);
  Assert.AreEqual(51, H[4].SegmentType);
  Assert.AreEqual(-1, H[0].RowCount);
end;

procedure TPdfJBIG2Tests.SegmentHeaderLongFormAndWideNumbers;
var
  Data: TBytes;
  H: TArray<TJBig2SegmentHeader>;
  Refs: TArray<Cardinal>;
  I: Integer;
begin
  SetLength(Refs, 9);
  for I := 0 to 8 do
    Refs[I] := 300 + Cardinal(I) * 1000;
  // long referred-to form with 2 byte numbers (segment number > 256) and a 4 byte page association
  Data := Segment(1000, 0, Refs, [7, 7], 70000, True);
  // 4 byte referred-to numbers (segment number > 65536)
  Data := Data + Segment(70000, 6, [100000, 65537], [5]);
  H := PdfJBIG2ReadSegmentHeaders(Data);
  Assert.AreEqual(2, Integer(Length(H)));
  Assert.AreEqual(Cardinal(1000), H[0].Number);
  Assert.AreEqual(9, Integer(Length(H[0].ReferredTo)));
  for I := 0 to 8 do
    Assert.AreEqual(Refs[I], H[0].ReferredTo[I]);
  Assert.AreEqual(Cardinal(70000), H[0].PageAssociation);
  Assert.AreEqual(2, H[0].DataLength);
  Assert.AreEqual(Integer(7), Integer(Data[H[0].DataStart]));
  Assert.AreEqual(Cardinal(100000), H[1].ReferredTo[0]);
  Assert.AreEqual(Cardinal(65537), H[1].ReferredTo[1]);
  Assert.AreEqual(Integer(5), Integer(Data[H[1].DataStart]));
end;

procedure TPdfJBIG2Tests.SegmentHeaderUnknownLength;
var
  Img: TImage;
  Body, Data: TBytes;
  H: TArray<TJBig2SegmentHeader>;
begin
  Img := TestPattern(20, 12, 5);
  Body := GenericRegionBody(Img, 0, 0, 0, False);
  PutU32(Body, 12); // row count after the 0xFF 0xAC end marker
  Data := Segment(0, 48, [], PageInfo(20, 12, 0)) + Segment(1, 38, [], Body, 1, False, True) +
    Segment(2, 49, [], []);
  H := PdfJBIG2ReadSegmentHeaders(Data);
  Assert.AreEqual(3, Integer(Length(H)));
  Assert.IsTrue(H[1].UnknownLength);
  Assert.AreEqual(Integer(Length(Body)), H[1].DataLength);
  Assert.AreEqual(12, H[1].RowCount);
  Assert.AreEqual(49, H[2].SegmentType);
end;

procedure ExpectFilterError(const Data: TBytes; Width, Height: Integer; const What: string);
begin
  try
    PdfJBIG2Decode(Data, nil, Width, Height);
  except
    on E: EPdfFilterError do
      Exit;
  end;
  Assert.Fail('EPdfFilterError expected: ' + What);
end;

procedure TPdfJBIG2Tests.UnusableFirstHeaderRaises;
begin
  ExpectFilterError(nil, 10, 10, 'empty');
  ExpectFilterError(BytesOf([1, 2, 3]), 10, 10, 'short header');
  // referred-to count 5 is reserved
  ExpectFilterError(BytesOf([0, 0, 0, 1, 48, $A0, 1, 2, 3, 4, 5, 1, 0, 0, 0, 0]), 10, 10, 'invalid referred-to count');
  ExpectFilterError(Segment(0, 48, [], PageInfo(1, 1, 0)), 0, 10, 'invalid size');
  // unknown length on a segment type that does not allow it
  ExpectFilterError(Segment(0, 0, [], [1, 2], 1, False, True), 10, 10, 'unknown length');
  Assert.Pass;
end;

procedure TPdfJBIG2Tests.TruncatedLaterSegmentKeepsPage;
var
  Img, Page: TImage;
  Data, Res: TBytes;
  Log: string;
begin
  Img := TestPattern(16, 8, 3);
  Data := Segment(0, 48, [], PageInfo(24, 12, $40)) + Segment(1, 38, [], GenericRegionBody(Img, 4, 2, 0, False));
  // a broken header, then a segment whose data runs past the end of the stream
  Res := PdfJBIG2DecodeWithLog(Data + BytesOf([0, 0, 0, 2, 38]), nil, 24, 12, Log);
  Page := MakeImage(24, 12, 0);
  ModelCompose(Page, Img, 4, 2, 0);
  Assert.AreEqual(0, CountDiffs(PackModel(Page), Res), 'page after broken header');
  Assert.IsTrue(Log <> '', 'the broken header is logged');
  Res := PdfJBIG2Decode(Data + Copy(Segment(2, 38, [], GenericRegionBody(Img, 0, 0, 2, False)), 0, 40),
    nil, 24, 12);
  Assert.AreEqual(Integer(Length(PackModel(Page))), Integer(Length(Res)), 'truncated segment');
end;

procedure TPdfJBIG2Tests.ComposeOperators;
const
  Dst: array[0..3] of Byte = (0, 0, 1, 1);
  Src: array[0..3] of Byte = (0, 1, 0, 1);
  Expected: array[0..4, 0..3] of Byte = ((0, 1, 1, 1), (0, 0, 0, 1), (0, 1, 1, 0), (1, 0, 0, 1), (0, 1, 0, 1));
var
  Op, I: Integer;
  T, S: TJBig2Bitmap;
begin
  for Op := 0 to 4 do
  begin
    T := TJBig2Bitmap.Create(4, 1);
    S := TJBig2Bitmap.Create(4, 1);
    for I := 0 to 3 do
    begin
      T.Data[I] := Dst[I];
      S.Data[I] := Src[I];
    end;
    JBig2Compose(T, S, 0, 0, Op);
    for I := 0 to 3 do
      Assert.AreEqual(Integer(Expected[Op, I]), Integer(T.Data[I]), Format('op %d pixel %d', [Op, I]));
  end;
end;

procedure TPdfJBIG2Tests.ComposeClipping;
var
  T, S: TJBig2Bitmap;
  X, Y, Count: Integer;
begin
  S := TJBig2Bitmap.Create(4, 4, 1);
  T := TJBig2Bitmap.Create(6, 5);
  JBig2Compose(T, S, -2, -1, 0);   // 2 x 3 visible
  JBig2Compose(T, S, 4, 3, 0);     // 2 x 2 visible
  JBig2Compose(T, S, 100, 0, 0);   // outside
  JBig2Compose(T, S, -MaxInt, -MaxInt, 0);
  JBig2Compose(T, S, MaxInt, MaxInt, 0);
  Count := 0;
  for Y := 0 to T.Height - 1 do
    for X := 0 to T.Width - 1 do
      Inc(Count, T.Data[Y * T.Width + X]);
  Assert.AreEqual(10, Count);
  Assert.AreEqual(1, T.Pixel(1, 2));
  Assert.AreEqual(0, T.Pixel(2, 0));
  Assert.AreEqual(1, T.Pixel(5, 4));
  Assert.AreEqual(0, T.Pixel(6, 4), 'outside reads 0');
end;

procedure TPdfJBIG2Tests.GenericRegionPattern;
var
  Img, Page: TImage;
  Data, Res: TBytes;
begin
  Img := TestPattern(37, 23, 11);
  Data := Segment(0, 48, [], PageInfo(37, 23, 0)) + Segment(1, 38, [], GenericRegionBody(Img, 0, 0, 0, False)) +
    Segment(2, 49, [], []);
  Res := PdfJBIG2Decode(Data, nil, 37, 23);
  Page := Img;
  Assert.AreEqual(0, CountDiffs(PackModel(Page), Res), 'template 0 pattern');
  // same image with typical prediction (several identical rows)
  Img := MakeImage(30, 20, 0);
  Img.P[5 * 30 + 3] := 1;
  Move(Img.P[5 * 30], Img.P[6 * 30], 30);
  Move(Img.P[5 * 30], Img.P[7 * 30], 30);
  Data := Segment(0, 48, [], PageInfo(30, 20, 0)) + Segment(1, 38, [], GenericRegionBody(Img, 0, 0, 0, True));
  Res := PdfJBIG2Decode(Data, nil, 30, 20);
  Assert.AreEqual(0, CountDiffs(PackModel(Img), Res), 'TPGDON');
end;

procedure TPdfJBIG2Tests.GenericRegionTPGDONAllWhite;
var
  Img, Page: TImage;
  Data, Res: TBytes;
begin
  // a white region (all rows predicted) replacing part of a black page
  Img := MakeImage(10, 6, 0);
  Data := Segment(0, 48, [], PageInfo(16, 10, $04 or $40)) +
    Segment(1, 38, [], GenericRegionBody(Img, 3, 2, 4, True));
  Res := PdfJBIG2Decode(Data, nil, 16, 10);
  Page := MakeImage(16, 10, 1);
  ModelCompose(Page, Img, 3, 2, 4);
  Assert.AreEqual(0, CountDiffs(PackModel(Page), Res));
end;

procedure TPdfJBIG2Tests.GenericRegionUnknownLength;
var
  Img, Page: TImage;
  Body, Data, Res: TBytes;
begin
  // the region height is unknown (0xFFFFFFFF) and comes from the row count after the end marker
  Img := TestPattern(18, 9, 21);
  Body := GenericRegionBody(Img, 1, 1, 0, False, True);
  PutU32(Body, 9);
  Data := Segment(0, 48, [], PageInfo(20, $FFFFFFFF, $40)) + Segment(1, 38, [], Body, 1, False, True) +
    Segment(2, 50, [], [0, 0, 0, 10]) + Segment(3, 49, [], []);
  Res := PdfJBIG2Decode(Data, nil, 20, 12);
  Page := MakeImage(20, 12, 0);
  ModelCompose(Page, Img, 1, 1, 0);
  Assert.AreEqual(0, CountDiffs(PackModel(Page), Res));
end;

procedure TPdfJBIG2Tests.RegionCombinationOperators;
var
  Page, A, B, Wh: TImage;
  Data, Res: TBytes;
  N: Cardinal;

  procedure Add(const Img: TImage; X, Y, Op: Integer);
  begin
    Data := Data + Segment(N, 38, [], GenericRegionBody(Img, Cardinal(X), Cardinal(Y), Byte(Op), False));
    Inc(N);
    ModelCompose(Page, Img, X, Y, Op);
  end;

begin
  A := TestPattern(12, 10, 1);
  B := TestPattern(9, 14, 2);
  Wh := MakeImage(5, 5, 0);
  Page := MakeImage(28, 20, 0);
  Data := Segment(0, 48, [], PageInfo(28, 20, $40)); // regions may override the operator
  N := 1;
  Add(A, 0, 0, 0);    // OR
  Add(B, 6, 3, 2);    // XOR
  Add(A, 10, 8, 1);   // AND
  Add(B, 20, 9, 3);   // XNOR, partly outside the page
  Add(Wh, 2, 2, 4);   // REPLACE
  Add(Wh, 25, 17, 3); // XNOR with white, clipped
  Res := PdfJBIG2Decode(Data, nil, 28, 20);
  Assert.AreEqual(0, CountDiffs(PackModel(Page), Res));
end;

procedure TPdfJBIG2Tests.PageDefaultPixelAndPacking;
var
  Res: TBytes;
begin
  // no regions: white page, black page with default pixel 1; stride 2 for width 10, padding bits white
  Res := PdfJBIG2Decode(Segment(0, 48, [], PageInfo(10, 2, 0)), nil, 10, 2);
  Assert.AreEqual(4, Integer(Length(Res)));
  Assert.AreEqual($FF, Integer(Res[0]));
  Assert.AreEqual($FF, Integer(Res[3]));
  Res := PdfJBIG2Decode(Segment(0, 48, [], PageInfo(10, 2, $04)), nil, 10, 2);
  Assert.AreEqual($00, Integer(Res[0]));
  Assert.AreEqual($3F, Integer(Res[1]), 'black pixels 8 and 9, padding white');
  Assert.AreEqual($3F, Integer(Res[3]));
end;

procedure TPdfJBIG2Tests.LargeGenericRegionIsFast;
var
  Img: TImage;
  Data, Res: TBytes;
  SW: TStopwatch;
begin
  Img := TestPattern(2500, 3300, 7);
  Data := Segment(0, 48, [], PageInfo(2500, 3300, 0)) + Segment(1, 38, [], GenericRegionBody(Img, 0, 0, 0, False));
  SW := TStopwatch.StartNew;
  Res := PdfJBIG2Decode(Data, nil, 2500, 3300);
  SW.Stop;
  LogInfo(Format('2500 x 3300 generic region (%d bytes): %d ms', [Length(Data), SW.ElapsedMilliseconds]));
  Assert.AreEqual(0, CountDiffs(PackModel(Img), Res));
  Assert.IsTrue(SW.ElapsedMilliseconds < 1000, Format('took %d ms', [SW.ElapsedMilliseconds]));
end;

procedure TPdfJBIG2Tests.CorpusBitmapFamily;
const
  RefName = 'bitmap-symbol-big-segmentid.pdf';
var
  Dir, F, Name, Log, Scratch: string;
  Files: TArray<string>;
  Images: TArray<TJBig2Image>;
  Ref, Res: TBytes;
  RefW, RefH, Same, Diff: Integer;
  Different: TStringList;
  SW: TStopwatch;
  Total, MaxMs: Int64;
begin
  Dir := CorpusDir;
  if not TFile.Exists(TPath.Combine(Dir, RefName)) then
    Assert.Pass('pdf.js corpus not found');
  Images := LoadImages(TPath.Combine(Dir, RefName), 1);
  Assert.AreEqual(1, Integer(Length(Images)), 'reference image');
  Ref := PdfJBIG2Decode(Images[0].Data, Images[0].Globals, Images[0].Width, Images[0].Height);
  RefW := Images[0].Width;
  RefH := Images[0].Height;
  Scratch := ScratchDir;
  Different := TStringList.Create;
  try
    Same := 0;
    Diff := 0;
    Total := 0;
    MaxMs := 0;
    Files := TDirectory.GetFiles(Dir, 'bitmap-*.pdf');
    for F in Files do
    begin
      Name := TPath.GetFileName(F);
      Images := LoadImages(F, 1);
      if Length(Images) = 0 then
      begin
        Different.Add(Name + ': no JBIG2 image');
        Inc(Diff);
        Continue;
      end;
      SW := TStopwatch.StartNew;
      Res := PdfJBIG2DecodeWithLog(Images[0].Data, Images[0].Globals, Images[0].Width, Images[0].Height, Log);
      SW.Stop;
      Inc(Total, SW.ElapsedMilliseconds);
      if SW.ElapsedMilliseconds > MaxMs then
        MaxMs := SW.ElapsedMilliseconds;
      if (Images[0].Width = RefW) and (Images[0].Height = RefH) and (CountDiffs(Ref, Res) = 0) then
        Inc(Same)
      else
      begin
        Inc(Diff);
        Different.Add(Format('%s: %d pixels bytes differ; %s', [Name, CountDiffs(Ref, Res), Log]));
      end;
      if Scratch <> '' then
      begin
        if Name = 'bitmap-template3-customat-tpgdon.pdf' then
          SavePng(TPath.Combine(Scratch, 'jbig2_test_generic.png'), Res, Images[0].Width, Images[0].Height)
        else if Name = 'bitmap-symbol-symbolrefine-textrefine.pdf' then
          SavePng(TPath.Combine(Scratch, 'jbig2_test_text.png'), Res, Images[0].Width, Images[0].Height)
        else if Name = 'bitmap-halftone-10bpp-mmr.pdf' then
          SavePng(TPath.Combine(Scratch, 'jbig2_test_halftone.png'), Res, Images[0].Width, Images[0].Height);
      end;
    end;
    LogInfo(Format('bitmap-* family: %d files, %d identical to %s, %d different; decode total %d ms, max %d ms',
      [Length(Files), Same, RefName, Diff, Total, MaxMs]));
    if Different.Count > 0 then
      LogInfo('differing: ' + Different.Text);
    Assert.IsTrue(Length(Files) >= 40, 'bitmap-* files expected');
    Assert.AreEqual(0, Diff, 'variants differing from the reference: ' + Different.Text);
  finally
    Different.Free;
  end;
end;

function ContainsAnsi(const Bytes: TBytes; const S: AnsiString): Boolean;
var
  I, J, N: Integer;
begin
  N := Length(S);
  for I := 0 to Integer(Length(Bytes)) - N do
    if Bytes[I] = Ord(S[1]) then
    begin
      J := 2;
      while (J <= N) and (Bytes[I + J - 1] = Ord(S[J])) do
        Inc(J);
      if J > N then
        Exit(True);
    end;
  Result := False;
end;

procedure TPdfJBIG2Tests.CorpusAllJBIG2Images;
var
  Dir, F, Name, Log, Scratch: string;
  Images: TArray<TJBig2Image>;
  Img: TJBig2Image;
  Res: TBytes;
  Files, Decoded, Logged: Integer;
  SW: TStopwatch;
  Ms: Int64;
begin
  Dir := CorpusDir;
  if not TDirectory.Exists(Dir) then
    Assert.Pass('pdf.js corpus not found');
  Scratch := ScratchDir;
  Files := 0;
  Decoded := 0;
  Logged := 0;
  for F in TDirectory.GetFiles(Dir, '*.pdf') do
  begin
    Name := TPath.GetFileName(F);
    if Name.StartsWith('bitmap-') or not ContainsAnsi(TFile.ReadAllBytes(F), 'JBIG2Decode') then
      Continue;
    try
      Images := LoadImages(F, 10);
    except
      on E: Exception do
      begin
        LogInfo(Format('%s: not loadable (%s)', [Name, E.Message]));
        Continue;
      end;
    end;
    Inc(Files);
    for Img in Images do
    begin
      if (Img.Width <= 0) or (Img.Height <= 0) then
        Continue;
      SW := TStopwatch.StartNew;
      Res := PdfJBIG2DecodeWithLog(Img.Data, Img.Globals, Img.Width, Img.Height, Log);
      Ms := SW.ElapsedMilliseconds;
      Inc(Decoded);
      Assert.AreEqual(((Img.Width + 7) div 8) * Img.Height, Integer(Length(Res)), Name + ' output size');
      LogInfo(Format('%s %s %d x %d: %d ms %s', [Name, Img.Key, Img.Width, Img.Height, Ms, Log]));
      if Log <> '' then
        Inc(Logged);
      if (Scratch <> '') and (Name = 'issue12963.pdf') then
        SavePng(TPath.Combine(Scratch, 'jbig2_test_issue12963.png'), Res, Img.Width, Img.Height);
    end;
  end;
  LogInfo(Format('other corpus files with JBIG2: %d, images decoded: %d, with diagnostics: %d',
    [Files, Decoded, Logged]));
  Assert.IsTrue(Decoded > 0, 'JBIG2 images expected in the corpus');
end;

procedure TPdfJBIG2Tests.CorruptDataDoesNotRaise;
const
  Names: array[0..7] of string = ('bitmap-symbol-symbolrefine-textrefine.pdf', 'bitmap-symbol-texthuffrefinecustom.pdf',
    'bitmap-halftone-10bpp.pdf', 'bitmap-halftone-10bpp-mmr.pdf', 'bitmap-refine-page.pdf', 'bitmap-mmr.pdf',
    'bitmap-symbol-context-reuse.pdf', 'bitmap-initially-unknown-size.pdf');
var
  Dir, N: string;
  Images: TArray<TJBig2Image>;
  Img: TJBig2Image;
  Data: TBytes;
  Rng: TRng;
  I, K, Runs, Raised: Integer;
  SW: TStopwatch;
begin
  Dir := CorpusDir;
  if not TDirectory.Exists(Dir) then
    Assert.Pass('pdf.js corpus not found');
  Rng.State := 2024;
  Runs := 0;
  Raised := 0;
  SW := TStopwatch.StartNew;
  for N in Names do
  begin
    if not TFile.Exists(TPath.Combine(Dir, N)) then
      Continue;
    Images := LoadImages(TPath.Combine(Dir, N), 1);
    if Length(Images) = 0 then
      Continue;
    Img := Images[0];
    for I := 0 to 59 do
    begin
      if I < 30 then
        Data := Copy(Img.Data, 0, Rng.Next(Integer(Length(Img.Data)))) // truncated
      else
      begin
        Data := Copy(Img.Data); // corrupted bytes
        for K := 0 to Rng.Next(6) do
          Data[Rng.Next(Integer(Length(Data)))] := Byte(Rng.Next(256));
      end;
      Inc(Runs);
      try
        PdfJBIG2Decode(Data, Img.Globals, Img.Width, Img.Height);
      except
        on E: EPdfFilterError do
          Inc(Raised); // allowed: unusable first header
      end;
    end;
  end;
  LogInfo(Format('corrupt inputs: %d runs, %d EPdfFilterError, %d ms', [Runs, Raised, SW.ElapsedMilliseconds]));
  Assert.IsTrue(SW.ElapsedMilliseconds < 60000, 'corrupt data must not take long');
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfJBIG2Tests);

end.
