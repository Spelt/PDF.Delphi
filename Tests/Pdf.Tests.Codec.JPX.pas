{*******************************************************************************
  Pdf.Tests.Codec.JPX
  DUnitX tests for the JPEG 2000 decoder (Pdf.Codec.JPX, Pdf.Codec.JPX.Primitives):
  building blocks (MQ decoder against a T.800/T.88 encoder written here, tag trees,
  packet header bits, inverse wavelet transforms against forward transforms written
  here), small hand-built codestreams and JP2 files, robustness against damaged
  data, and every JPXDecode image of the pdf.js corpus (first 10 pages per file).
*******************************************************************************}
unit Pdf.Tests.Codec.JPX;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Math, System.Diagnostics, System.Generics.Collections,
  System.Generics.Defaults, System.StrUtils, System.Skia, DUnitX.TestFramework, Pdf.Core.Types, Pdf.Core.Objects,
  Pdf.Core.Document, Pdf.Codec.JPX.Primitives, Pdf.Codec.JPX;

type
  [TestFixture]
  TPdfJPXTests = class
  public
    [Test] procedure IsJPXDetectsSignatures;
    [Test] procedure MQDecoderRoundTrip;
    [Test] procedure MQDecoderPaddingPastEnd;
    [Test] procedure PacketBitReaderSkipsStuffedBit;
    [Test] procedure TagTreeHandBuiltBits;
    [Test] procedure TagTreeInclusionThresholds;
    [Test] procedure Inverse53ConstantFromSingleLL;
    [Test] procedure Inverse97ConstantFromSingleLL;
    [Test] procedure Inverse53RoundTrip;
    [Test] procedure Inverse97RoundTrip;
    [Test] procedure SyntheticCodestreamDecodes;
    [Test] procedure SyntheticJP2BoxesAndColorSpace;
    [Test] procedure SyntheticPaletteAndIndexed;
    [Test] procedure SyntheticChannelDefinitionAlpha;
    [Test] procedure SyntheticSMaskInData;
    [Test] procedure SyntheticReadInfo;
    [Test] procedure UnsupportedFeaturesRaise;
    [Test] procedure GarbageRaisesFilterError;
    [Test] procedure TruncatedSyntheticNeverCrashes;
    [Test] procedure CorpusDamagedStreams;
    [Test] procedure CorpusReduceLevelsHalvesSize;
    [Test] procedure CorpusAllJPXImages;
  end;

implementation

const
  CorpusDirConst = 'C:\Users\EDWARD~1\AppData\Local\Temp\claude\pdfjs-corpus\pdfjs\test\pdfs\';

function CorpusDir: string;
var
  Env, D: string;
begin
  Env := GetEnvironmentVariable('PDF_CORPUS_DIRS');
  for D in Env.Split([';']) do
    if (Trim(D) <> '') and TDirectory.Exists(Trim(D)) then
      Exit(IncludeTrailingPathDelimiter(Trim(D)));
  Result := CorpusDirConst;
  if not TDirectory.Exists(Result) then
    Result := '';
end;

function ScratchDir: string;
begin
  Result := TPath.GetFullPath(TPath.Combine(ExtractFilePath(ParamStr(0)), '..\scratch'));
end;

{ ---------------------------------------------------------------------------- }
{ Byte helpers                                                                 }
{ ---------------------------------------------------------------------------- }

type
  TByteWriter = record
    Bytes: TBytes;
    procedure Put8(V: Integer);
    procedure Put16(V: Integer);
    procedure Put32(V: Cardinal);
    procedure PutBytes(const B: TBytes);
    procedure PutText(const S: AnsiString);
  end;

procedure TByteWriter.Put8(V: Integer);
begin
  Bytes := Bytes + [Byte(V)];
end;

procedure TByteWriter.Put16(V: Integer);
begin
  Put8(V shr 8);
  Put8(V);
end;

procedure TByteWriter.Put32(V: Cardinal);
begin
  Put16(V shr 16);
  Put16(V and $FFFF);
end;

procedure TByteWriter.PutBytes(const B: TBytes);
begin
  Bytes := Bytes + B;
end;

procedure TByteWriter.PutText(const S: AnsiString);
var
  I: Integer;
begin
  for I := 1 to Length(S) do
    Put8(Ord(S[I]));
end;

/// A valid 8x8 J2K codestream: one tile, no wavelet levels, empty packets (all samples at the DC level).
function SynthCodestream(const Precisions: array of Integer; Style: Byte = 0; const Extra: TBytes = nil): TBytes;
var
  W: TByteWriter;
  C, I: Integer;
begin
  C := Length(Precisions);
  W.Put16($FF4F);                      // SOC
  W.Put16($FF51);                      // SIZ
  W.Put16(38 + 3 * C);
  W.Put16(0);                          // Rsiz
  W.Put32(8); W.Put32(8);              // Xsiz, Ysiz
  W.Put32(0); W.Put32(0);              // XOsiz, YOsiz
  W.Put32(8); W.Put32(8);              // XTsiz, YTsiz
  W.Put32(0); W.Put32(0);              // XTOsiz, YTOsiz
  W.Put16(C);
  for I := 0 to C - 1 do
  begin
    W.Put8(Precisions[I] - 1);
    W.Put8(1);
    W.Put8(1);
  end;
  W.Put16($FF52);                      // COD
  W.Put16(12);
  W.Put8(0);                           // Scod
  W.Put8(0);                           // LRCP
  W.Put16(1);                          // layers
  W.Put8(0);                           // MCT
  W.Put8(0);                           // decomposition levels
  W.Put8(2); W.Put8(2);                // 16x16 code-blocks
  W.Put8(Style);
  W.Put8(1);                           // 5/3
  W.Put16($FF5C);                      // QCD: no quantization, 2 guard bits
  W.Put16(4);
  W.Put8($40);
  W.Put8(8 shl 3);
  W.PutBytes(Extra);
  W.Put16($FF90);                      // SOT
  W.Put16(10);
  W.Put16(0);
  W.Put32(14 + C);
  W.Put8(0);
  W.Put8(1);
  W.Put16($FF93);                      // SOD
  for I := 1 to C do
    W.Put8(0);                         // one empty packet per component
  W.Put16($FFD9);                      // EOC
  Result := W.Bytes;
end;

function Box(const Typ: AnsiString; const Content: TBytes): TBytes;
var
  W: TByteWriter;
begin
  W.Put32(8 + Length(Content));
  W.PutText(Typ);
  W.PutBytes(Content);
  Result := W.Bytes;
end;

function WrapJP2(const Codestream: TBytes; Components, EnumCS: Integer; const ExtraHeaderBoxes: TBytes = nil): TBytes;
var
  W, H: TByteWriter;
begin
  W.PutBytes(Box('jP  ', [$0D, $0A, $87, $0A]));
  H.PutText('jp2 ');
  H.Put32(0);
  H.PutText('jp2 ');
  W.PutBytes(Box('ftyp', H.Bytes));
  H := Default(TByteWriter);
  H.Put32(8); H.Put32(8); H.Put16(Components); H.Put8(7); H.Put8(7); H.Put8(0); H.Put8(0);
  H.Bytes := Box('ihdr', H.Bytes);
  if EnumCS >= 0 then
    H.PutBytes(Box('colr', [1, 0, 0, Byte(EnumCS shr 24), Byte(EnumCS shr 16), Byte(EnumCS shr 8), Byte(EnumCS)]));
  H.PutBytes(ExtraHeaderBoxes);
  W.PutBytes(Box('jp2h', H.Bytes));
  W.PutBytes(Box('jp2c', Codestream));
  Result := W.Bytes;
end;

{ ---------------------------------------------------------------------------- }
{ MQ encoder (T.800 C.2 / T.88 E.2) for the round trip                         }
{ ---------------------------------------------------------------------------- }

const
  EncQe: array[0..46] of Integer = ($5601, $3401, $1801, $0AC1, $0521, $0221, $5601, $5401, $4801, $3801, $3001,
    $2401, $1C01, $1601, $5601, $5401, $5101, $4801, $3801, $3401, $3001, $2801, $2401, $2201, $1C01, $1801,
    $1601, $1401, $1201, $1101, $0AC1, $09C1, $08A1, $0521, $0441, $02A1, $0221, $0141, $0111, $0085, $0049,
    $0025, $0015, $0009, $0005, $0001, $5601);
  EncNMPS: array[0..46] of Integer = (1, 2, 3, 4, 5, 38, 7, 8, 9, 10, 11, 12, 13, 29, 15, 16, 17, 18, 19, 20, 21,
    22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 45, 46);
  EncNLPS: array[0..46] of Integer = (1, 6, 9, 12, 29, 33, 6, 14, 14, 14, 17, 18, 20, 21, 14, 14, 15, 16, 17, 18,
    19, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 46);
  EncSwitch: array[0..46] of Integer = (1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

type
  TMQEncoder = record
    A, C: Cardinal;
    CT: Integer;
    Output: TList<Byte>;
    Index, Mps: array[0..31] of Integer;
    procedure Init;
    procedure ByteOut;
    procedure RenormE;
    procedure Encode(Cx, D: Integer);
    function Flush: TBytes;
  end;

procedure TMQEncoder.Init;
begin
  A := $8000;
  C := 0;
  CT := 12;
  Output := TList<Byte>.Create;
  Output.Add(0); // the byte before the first one (BP = BPST - 1)
  FillChar(Index, SizeOf(Index), 0);
  FillChar(Mps, SizeOf(Mps), 0);
end;

procedure TMQEncoder.ByteOut;
var
  B: Integer;
begin
  B := Output.Last;
  if B = $FF then
  begin
    Output.Add(Byte(C shr 20));
    C := C and $FFFFF;
    CT := 7;
  end
  else if C < $8000000 then
  begin
    Output.Add(Byte(C shr 19));
    C := C and $7FFFF;
    CT := 8;
  end
  else
  begin
    Inc(B);
    Output[Output.Count - 1] := Byte(B);
    if B = $FF then
    begin
      C := C and $7FFFFFF;
      Output.Add(Byte(C shr 20));
      C := C and $FFFFF;
      CT := 7;
    end
    else
    begin
      Output.Add(Byte(C shr 19));
      C := C and $7FFFF;
      CT := 8;
    end;
  end;
end;

procedure TMQEncoder.RenormE;
begin
  repeat
    A := A shl 1;
    C := C shl 1;
    Dec(CT);
    if CT = 0 then
      ByteOut;
  until (A and $8000) <> 0;
end;

procedure TMQEncoder.Encode(Cx, D: Integer);
var
  Qe: Cardinal;
  I: Integer;
begin
  I := Index[Cx];
  Qe := EncQe[I];
  if D = Mps[Cx] then
  begin
    // CODEMPS
    A := A - Qe;
    if (A and $8000) = 0 then
    begin
      if A < Qe then
        A := Qe
      else
        C := C + Qe;
      Index[Cx] := EncNMPS[I];
      RenormE;
    end
    else
      C := C + Qe;
  end
  else
  begin
    // CODELPS
    A := A - Qe;
    if A < Qe then
      C := C + Qe
    else
      A := Qe;
    if EncSwitch[I] = 1 then
      Mps[Cx] := 1 - Mps[Cx];
    Index[Cx] := EncNLPS[I];
    RenormE;
  end;
end;

function TMQEncoder.Flush: TBytes;
var
  Temp: Cardinal;
begin
  // SETBITS
  Temp := C + A;
  C := C or $FFFF;
  if C >= Temp then
    C := C - $8000;
  C := C shl CT;
  ByteOut;
  C := C shl CT;
  ByteOut;
  if Output.Last = $FF then
    Output.Delete(Output.Count - 1);
  Output.Delete(0);
  Result := Output.ToArray;
  Output.Free;
end;

{ ---------------------------------------------------------------------------- }
{ Forward wavelet transforms (T.800 F.4) for the round trips                   }
{ ---------------------------------------------------------------------------- }

function Mirror(K, N: Integer): Integer;
begin
  Result := K;
  while (Result < 0) or (Result >= N) do
    if Result < 0 then
      Result := -Result
    else
      Result := 2 * (N - 1) - Result;
end;

procedure Forward1D(var X: TArray<Double>; N: Integer; Reversible: Boolean);
const
  Alpha = -1.586134342059924;
  Beta = -0.052980118572961;
  Gamma = 0.882911075530934;
  Delta = 0.443506852043971;
  K = 1.230174104914001;

  procedure Lift(Parity: Integer; Coef: Double);
  var
    I: Integer;
  begin
    I := Parity;
    while I < N do
    begin
      X[I] := X[I] + Coef * (X[Mirror(I - 1, N)] + X[Mirror(I + 1, N)]);
      Inc(I, 2);
    end;
  end;

var
  I: Integer;
begin
  if N < 2 then
    Exit;
  if Reversible then
  begin
    I := 1;
    while I < N do
    begin
      X[I] := X[I] - Floor((X[Mirror(I - 1, N)] + X[Mirror(I + 1, N)]) / 2);
      Inc(I, 2);
    end;
    I := 0;
    while I < N do
    begin
      X[I] := X[I] + Floor((X[Mirror(I - 1, N)] + X[Mirror(I + 1, N)] + 2) / 4);
      Inc(I, 2);
    end;
  end
  else
  begin
    Lift(1, Alpha);
    Lift(0, Beta);
    Lift(1, Gamma);
    Lift(0, Delta);
    for I := 0 to N - 1 do
      if Odd(I) then
        X[I] := X[I] * K
      else
        X[I] := X[I] / K;
  end;
end;

/// Forward DWT with NL levels; returns the bands in the layout JpxInverseTransform expects.
function ForwardTransform(const Image: TArray<Double>; W, H, NL: Integer; Reversible: Boolean): TArray<TJpxBand>;
var
  Cur, Line: TArray<Double>;
  CW, CH, Lev, X, Y: Integer;
  NW, NH: Integer;
  Next: TArray<Double>;
begin
  SetLength(Result, NL + 1);
  Cur := Copy(Image);
  CW := W;
  CH := H;
  for Lev := 1 to NL do
  begin
    // VER_SD then HOR_SD
    SetLength(Line, CH);
    for X := 0 to CW - 1 do
    begin
      for Y := 0 to CH - 1 do
        Line[Y] := Cur[Y * CW + X];
      Forward1D(Line, CH, Reversible);
      for Y := 0 to CH - 1 do
        Cur[Y * CW + X] := Line[Y];
    end;
    SetLength(Line, CW);
    for Y := 0 to CH - 1 do
    begin
      for X := 0 to CW - 1 do
        Line[X] := Cur[Y * CW + X];
      Forward1D(Line, CW, Reversible);
      for X := 0 to CW - 1 do
        Cur[Y * CW + X] := Line[X];
    end;
    Result[NL - Lev + 1].Width := CW;
    Result[NL - Lev + 1].Height := CH;
    SetLength(Result[NL - Lev + 1].Items, CW * CH);
    for X := 0 to CW * CH - 1 do
      Result[NL - Lev + 1].Items[X] := Cur[X];
    NW := (CW + 1) div 2;
    NH := (CH + 1) div 2;
    SetLength(Next, NW * NH);
    for Y := 0 to NH - 1 do
      for X := 0 to NW - 1 do
        Next[Y * NW + X] := Cur[(2 * Y) * CW + 2 * X];
    Cur := Next;
    Next := nil;
    CW := NW;
    CH := NH;
  end;
  Result[0].Width := CW;
  Result[0].Height := CH;
  SetLength(Result[0].Items, CW * CH);
  for X := 0 to CW * CH - 1 do
    Result[0].Items[X] := Cur[X];
end;

procedure RoundTrip(Reversible: Boolean; W, H, NL: Integer; Tolerance: Double);
var
  Image: TArray<Double>;
  Bands: TArray<TJpxBand>;
  Res: TJpxBand;
  I: Integer;
begin
  SetLength(Image, W * H);
  for I := 0 to W * H - 1 do
    Image[I] := Random(256) - 128;
  Bands := ForwardTransform(Image, W, H, NL, Reversible);
  Res := JpxInverseTransform(Bands, Reversible, 0, 0);
  Assert.AreEqual(W, Res.Width);
  Assert.AreEqual(H, Res.Height);
  for I := 0 to W * H - 1 do
    Assert.AreEqual(Image[I], Double(Res.Items[I]), Tolerance,
      Format('%dx%d/%d sample %d', [W, H, NL, I]));
end;

{ ---------------------------------------------------------------------------- }
{ Corpus helpers                                                               }
{ ---------------------------------------------------------------------------- }

type
  TJpxSample = record
    FileName, Key: string;
    Data: TBytes;
    Width, Height: Integer;
    Options: TPdfJPXOptions;
  end;

function ColorComponentsOf(const CS: IPdfObject): Integer;
var
  Arr: IPdfArray;
  Name: string;
  S: IPdfStream;
begin
  Result := 0;
  Name := PdfAsName(CS);
  Arr := PdfAsArray(CS);
  if (Name = '') and (Arr <> nil) and (Arr.Count > 0) then
    Name := Arr.GetName(0);
  if (Name = 'DeviceGray') or (Name = 'CalGray') or (Name = 'G') then
    Result := 1
  else if (Name = 'DeviceRGB') or (Name = 'CalRGB') or (Name = 'Lab') or (Name = 'RGB') then
    Result := 3
  else if (Name = 'DeviceCMYK') or (Name = 'CMYK') then
    Result := 4
  else if (Name = 'ICCBased') and (Arr <> nil) then
  begin
    S := Arr.GetStream(1);
    if S <> nil then
      Result := S.Dict.GetInteger('N');
  end
  else if (Name = 'Indexed') or (Name = 'Separation') then
    Result := 1
  else if (Name = 'DeviceN') and (Arr <> nil) and (Arr.GetArray(1) <> nil) then
    Result := Arr.GetArray(1).Count;
end;

procedure CollectFromResources(const FileName: string; const Res: IPdfDictionary; Depth: Integer;
  Seen: TDictionary<Integer, Boolean>; List: TList<TJpxSample>);

  procedure AddStream(const Key: string; const S: IPdfStream);
  var
    Sample: TJpxSample;
    CS: IPdfObject;
    Arr: IPdfArray;
  begin
    if (S.ObjNum > 0) and Seen.ContainsKey(S.ObjNum) then
      Exit;
    if S.ObjNum > 0 then
      Seen.Add(S.ObjNum, True);
    try
      Sample.Data := S.GetDecodedData;
    except
      Exit;
    end;
    if S.ImageFilter <> 'JPXDecode' then
      Exit;
    Sample.FileName := FileName;
    Sample.Key := Key;
    Sample.Width := S.Dict.GetInteger('Width');
    Sample.Height := S.Dict.GetInteger('Height');
    Sample.Options := TPdfJPXOptions.Default;
    Sample.Options.SMaskInData := S.Dict.GetInteger('SMaskInData') <> 0;
    CS := S.Dict.Get('ColorSpace');
    Arr := PdfAsArray(CS);
    Sample.Options.IsIndexed := (Arr <> nil) and (Arr.Count > 0) and (Arr.GetName(0) = 'Indexed');
    Sample.Options.ColorComponents := ColorComponentsOf(CS);
    List.Add(Sample);
  end;

var
  XObjects: IPdfDictionary;
  Key: string;
  S, SM: IPdfStream;
begin
  if (Res = nil) or (Depth > 4) then
    Exit;
  XObjects := Res.GetDictionary('XObject');
  if XObjects = nil then
    Exit;
  for Key in XObjects.Keys do
  begin
    S := XObjects.GetStream(Key);
    if S = nil then
      Continue;
    if S.Dict.GetName('Subtype') = 'Image' then
    begin
      AddStream(Key, S);
      SM := S.Dict.GetStream('SMask');
      if SM <> nil then
        AddStream(Key + '.SMask', SM);
    end
    else if S.Dict.GetName('Subtype') = 'Form' then
    begin
      if (S.ObjNum > 0) and Seen.ContainsKey(-S.ObjNum) then
        Continue;
      if S.ObjNum > 0 then
        Seen.Add(-S.ObjNum, True);
      CollectFromResources(FileName, S.Dict.GetDictionary('Resources'), Depth + 1, Seen, List);
    end;
  end;
end;

/// JPXDecode image streams on the first MaxPages pages of a PDF (problems on the PDF side are ignored).
procedure CollectJpx(const FileName: string; MaxPages: Integer; List: TList<TJpxSample>);
var
  Doc: TPdfDocument;
  Seen: TDictionary<Integer, Boolean>;
  P: Integer;
begin
  Doc := TPdfDocument.Create;
  Seen := TDictionary<Integer, Boolean>.Create;
  try
    try
      Doc.LoadFromFile(FileName);
      for P := 0 to Min(Doc.PageCount, MaxPages) - 1 do
        CollectFromResources(TPath.GetFileName(FileName), Doc.Pages[P].Resources, 0, Seen, List);
    except
      on E: Exception do
        ;
    end;
  finally
    Seen.Free;
    Doc.Free;
  end;
end;

function FirstJpx(const Name: string; out Sample: TJpxSample): Boolean;
var
  List: TList<TJpxSample>;
begin
  Result := False;
  if (CorpusDir = '') or not TFile.Exists(CorpusDir + Name) then
    Exit;
  List := TList<TJpxSample>.Create;
  try
    CollectJpx(CorpusDir + Name, 10, List);
    if List.Count > 0 then
    begin
      Sample := List[0];
      Result := True;
    end;
  finally
    List.Free;
  end;
end;

function RaisesFilterError(const Data: TBytes): Boolean;
begin
  Result := False;
  try
    PdfJPXDecode(Data);
  except
    on E: EPdfFilterError do
      Result := True;
  end;
end;

procedure WritePng(const Img: TPdfJPXImage; const FileName: string);
var
  RGBA: TBytes;
  I, N, S: Integer;
  Sk: ISkImage;
begin
  if (Img.Width = 0) or (Img.Height = 0) or not TDirectory.Exists(ScratchDir) then
    Exit;
  N := Img.Components + Ord(Img.HasAlpha);
  SetLength(RGBA, Img.Width * Img.Height * 4);
  for I := 0 to Img.Width * Img.Height - 1 do
  begin
    S := I * 4;
    if Img.Components >= 3 then
    begin
      if (Img.ColorSpace = jcCMYK) and (Img.Components >= 4) then
      begin
        RGBA[S] := (255 - Img.Data[I * N]) * (255 - Img.Data[I * N + 3]) div 255;
        RGBA[S + 1] := (255 - Img.Data[I * N + 1]) * (255 - Img.Data[I * N + 3]) div 255;
        RGBA[S + 2] := (255 - Img.Data[I * N + 2]) * (255 - Img.Data[I * N + 3]) div 255;
      end
      else
      begin
        RGBA[S] := Img.Data[I * N];
        RGBA[S + 1] := Img.Data[I * N + 1];
        RGBA[S + 2] := Img.Data[I * N + 2];
      end;
    end
    else
    begin
      RGBA[S] := Img.Data[I * N];
      RGBA[S + 1] := Img.Data[I * N];
      RGBA[S + 2] := Img.Data[I * N];
    end;
    if Img.HasAlpha then
      RGBA[S + 3] := Img.Data[I * N + N - 1]
    else
      RGBA[S + 3] := 255;
  end;
  Sk := TSkImage.MakeRasterCopy(TSkImageInfo.Create(Img.Width, Img.Height, TSkColorType.RGBA8888,
    TSkAlphaType.Unpremul), @RGBA[0], NativeUInt(Img.Width) * 4);
  if Sk <> nil then
    Sk.EncodeToFile(TPath.Combine(ScratchDir, FileName));
end;

{ ---------------------------------------------------------------------------- }
{ Building blocks                                                              }
{ ---------------------------------------------------------------------------- }

procedure TPdfJPXTests.IsJPXDetectsSignatures;
begin
  Assert.IsTrue(PdfIsJPX(SynthCodestream([8])), 'J2K');
  Assert.IsTrue(PdfIsJPX(WrapJP2(SynthCodestream([8]), 1, 17)), 'JP2');
  Assert.IsFalse(PdfIsJPX(nil), 'empty');
  Assert.IsFalse(PdfIsJPX([$FF, $4F]), 'short');
  Assert.IsFalse(PdfIsJPX([$FF, $D8, $FF, $E0, 0, 16, $4A, $46, $49, $46, 0, 1]), 'JPEG');
  Assert.IsFalse(PdfIsJPX(TEncoding.ANSI.GetBytes('%PDF-1.7 garbage garbage')), 'garbage');
end;

procedure TPdfJPXTests.MQDecoderRoundTrip;
const
  Count = 20000;
var
  Enc: TMQEncoder;
  Bits, Ctxs: TArray<Integer>;
  Data: TBytes;
  Dec: TJpxMQDecoder;
  Contexts: array[0..3] of Byte;
  I: Integer;
begin
  RandSeed := 12345;
  SetLength(Bits, Count);
  SetLength(Ctxs, Count);
  for I := 0 to Count - 1 do
  begin
    Ctxs[I] := Random(4);
    // context 0: mostly 0, 1: mostly 1, 2: balanced, 3: runs
    case Ctxs[I] of
      0: Bits[I] := Ord(Random(100) < 5);
      1: Bits[I] := Ord(Random(100) < 90);
      2: Bits[I] := Random(2);
    else
      Bits[I] := (I div 37) and 1;
    end;
  end;
  Enc.Init;
  for I := 0 to Count - 1 do
    Enc.Encode(Ctxs[I], Bits[I]);
  Data := Enc.Flush;
  Assert.IsTrue(Length(Data) < Count div 8, 'compressed');
  FillChar(Contexts, SizeOf(Contexts), 0);
  Dec.Init(Data, 0, Length(Data));
  for I := 0 to Count - 1 do
    Assert.AreEqual(Bits[I], Dec.ReadBit(@Contexts[Ctxs[I]]), Format('decision %d', [I]));
end;

procedure TPdfJPXTests.MQDecoderPaddingPastEnd;
var
  Dec: TJpxMQDecoder;
  Cx: Byte;
  I: Integer;
begin
  // No data at all: the decoder reads padding and must stay in bounds
  Cx := 0;
  Dec.Init(nil, 0, 0);
  for I := 1 to 1000 do
    Dec.ReadBit(@Cx);
  Dec.Init([$FF, $FF, $FF], 0, 3);
  for I := 1 to 1000 do
    Dec.ReadBit(@Cx);
  Assert.Pass;
end;

procedure TPdfJPXTests.PacketBitReaderSkipsStuffedBit;
var
  R: TJpxPacketBitReader;
begin
  R.Init([$A5, $FF, $7F, $80, $C3], 0);
  Assert.AreEqual(Cardinal($A), R.ReadBits(4));
  Assert.AreEqual(Cardinal($5), R.ReadBits(4));
  Assert.AreEqual(Cardinal($FF), R.ReadBits(8));
  // after 0xFF only 7 bits of the next byte count
  Assert.AreEqual(Cardinal($7F), R.ReadBits(7));
  Assert.AreEqual(3, R.Position);
  Assert.AreEqual(Cardinal($80), R.ReadBits(8));
  R.AlignToByte;
  Assert.AreEqual(Cardinal($C3), R.ReadBits(8));
  // reading past the end gives zero bits
  Assert.AreEqual(Cardinal(0), R.ReadBits(32));
end;

procedure TPdfJPXTests.TagTreeHandBuiltBits;
var
  Tree: TJpxTagTree;
  R: TJpxPacketBitReader;
  Z: Integer;
begin
  // Two leaves with values 1 and 3 (root = 1). Zero bit-plane decoding of leaf 0 then leaf 1:
  // leaf 0: threshold 1 -> root 0 ("> 0"); threshold 2 -> root 1, leaf 1      => bits 0 1 1
  // leaf 1: threshold 2 -> leaf 0 ("> 1"); 3 -> 0 ("> 2"); 4 -> 1 (= 3)        => bits 0 0 1
  Tree := TJpxTagTree.Create(2, 1);
  try
    R.Init([$64], 0); // 0110 0100
    Z := 1;
    while not Tree.Decode(R, 0, 0, Z) do
      Inc(Z);
    Assert.AreEqual(1, Tree.LeafValue(0, 0));
    Assert.AreEqual(2, Z);
    Z := 1;
    while not Tree.Decode(R, 1, 0, Z) do
      Inc(Z);
    Assert.AreEqual(3, Tree.LeafValue(1, 0));
    Assert.AreEqual(4, Z);
    Assert.AreEqual(1, R.Position, 'exactly one byte consumed');
  finally
    Tree.Free;
  end;
end;

procedure TPdfJPXTests.TagTreeInclusionThresholds;
var
  Tree: TJpxTagTree;
  R: TJpxPacketBitReader;
begin
  // 3x3 leaves (two levels above). Layer 0: leaf (2,2) not included: root "> 0" = bit 0.
  // Layer 1: root continues at 1 -> bit 1 (= 1), then the middle node 1 -> bit 1, the leaf 1 -> bit 1: included.
  // Layer 1, leaf (0,0): root known (no bit), its node (0,0) of level 1 starts at 1 -> bit 0 ("> 1"): not included.
  Tree := TJpxTagTree.Create(3, 3);
  try
    R.Init([$70], 0); // 0 111 0 000
    Assert.IsFalse(Tree.Decode(R, 2, 2, 1), 'layer 0');
    Assert.IsTrue(Tree.Decode(R, 2, 2, 2), 'layer 1');
    Assert.AreEqual(1, Tree.LeafValue(2, 2));
    Assert.IsFalse(Tree.Decode(R, 0, 0, 2), 'other leaf, layer 1');
    Assert.AreEqual(1, R.Position, 'five bits of the first byte used');
    Assert.WillRaise(
      procedure
      begin
        Tree.Decode(R, 3, 0, 1);
      end, EPdfFilterError);
  finally
    Tree.Free;
  end;
end;

procedure TPdfJPXTests.Inverse53ConstantFromSingleLL;
var
  Levels: TArray<TJpxBand>;
  Res: TJpxBand;
  I: Integer;
begin
  SetLength(Levels, 3);
  Levels[0].Width := 1;
  Levels[0].Height := 1;
  Levels[0].Items := [100];
  Levels[1].Width := 2;
  Levels[1].Height := 2;
  SetLength(Levels[1].Items, 4);
  Levels[2].Width := 4;
  Levels[2].Height := 3;
  SetLength(Levels[2].Items, 12);
  Res := JpxInverseTransform(Levels, True, 0, 0);
  Assert.AreEqual(4, Res.Width);
  Assert.AreEqual(3, Res.Height);
  for I := 0 to 11 do
    Assert.AreEqual(Single(100), Res.Items[I]);
end;

procedure TPdfJPXTests.Inverse97ConstantFromSingleLL;
var
  Levels: TArray<TJpxBand>;
  Res: TJpxBand;
  I: Integer;
begin
  SetLength(Levels, 3);
  Levels[0].Width := 1;
  Levels[0].Height := 1;
  Levels[0].Items := [-37.5];
  Levels[1].Width := 2;
  Levels[1].Height := 2;
  SetLength(Levels[1].Items, 4);
  Levels[2].Width := 3;
  Levels[2].Height := 4;
  SetLength(Levels[2].Items, 12);
  Res := JpxInverseTransform(Levels, False, 0, 0);
  Assert.AreEqual(3, Res.Width);
  Assert.AreEqual(4, Res.Height);
  for I := 0 to 11 do
    Assert.AreEqual(-37.5, Double(Res.Items[I]), 0.001);
end;

procedure TPdfJPXTests.Inverse53RoundTrip;
begin
  RandSeed := 1;
  RoundTrip(True, 8, 8, 3, 0);
  RoundTrip(True, 7, 5, 2, 0);
  RoundTrip(True, 13, 6, 2, 0);
  RoundTrip(True, 1, 9, 2, 0);
  RoundTrip(True, 33, 17, 4, 0);
end;

procedure TPdfJPXTests.Inverse97RoundTrip;
begin
  RandSeed := 2;
  RoundTrip(False, 8, 8, 3, 0.01);
  RoundTrip(False, 7, 5, 2, 0.01);
  RoundTrip(False, 13, 6, 2, 0.01);
  RoundTrip(False, 33, 17, 4, 0.01);
end;

{ ---------------------------------------------------------------------------- }
{ Hand-built codestreams                                                       }
{ ---------------------------------------------------------------------------- }

procedure TPdfJPXTests.SyntheticCodestreamDecodes;
var
  Img: TPdfJPXImage;
  I: Integer;
begin
  Img := PdfJPXDecode(SynthCodestream([8]));
  Assert.AreEqual(8, Img.Width);
  Assert.AreEqual(8, Img.Height);
  Assert.AreEqual(1, Img.Components);
  Assert.IsFalse(Img.HasAlpha);
  Assert.AreEqual(Ord(jcGray), Ord(Img.ColorSpace));
  Assert.AreEqual(8, Img.BitDepth);
  Assert.AreEqual(64, Integer(Length(Img.Data)));
  for I := 0 to 63 do
    Assert.AreEqual(128, Integer(Img.Data[I]), 'DC level');

  Img := PdfJPXDecode(SynthCodestream([8, 8, 8]));
  Assert.AreEqual(3, Img.Components);
  Assert.AreEqual(Ord(jcRGB), Ord(Img.ColorSpace));
  Assert.AreEqual(192, Integer(Length(Img.Data)));

  Img := PdfJPXDecode(SynthCodestream([12, 12, 12, 12]));
  Assert.AreEqual(4, Img.Components);
  Assert.AreEqual(Ord(jcCMYK), Ord(Img.ColorSpace));
  Assert.AreEqual(12, Img.BitDepth);
  Assert.AreEqual(128, Integer(Img.Data[0]), '12-bit mid level scaled to 8 bits');

  // a 4-bit component is scaled up: mid level 8 of 15 -> 136
  Img := PdfJPXDecode(SynthCodestream([4]));
  Assert.AreEqual(136, Integer(Img.Data[0]));
end;

procedure TPdfJPXTests.SyntheticJP2BoxesAndColorSpace;
var
  Img: TPdfJPXImage;
begin
  Img := PdfJPXDecode(WrapJP2(SynthCodestream([8]), 1, 17));
  Assert.AreEqual(8, Img.Width);
  Assert.AreEqual(Ord(jcGray), Ord(Img.ColorSpace));

  Img := PdfJPXDecode(WrapJP2(SynthCodestream([8, 8, 8]), 3, 16));
  Assert.AreEqual(Ord(jcRGB), Ord(Img.ColorSpace));

  // sYCC is converted to RGB: Y = 128, Cb = Cr = 128 -> grey 128
  Img := PdfJPXDecode(WrapJP2(SynthCodestream([8, 8, 8]), 3, 18));
  Assert.AreEqual(Ord(jcRGB), Ord(Img.ColorSpace));
  Assert.AreEqual(128, Integer(Img.Data[0]));
  Assert.AreEqual(128, Integer(Img.Data[1]));
  Assert.AreEqual(128, Integer(Img.Data[2]));

  Img := PdfJPXDecode(WrapJP2(SynthCodestream([8, 8, 8, 8]), 4, 12));
  Assert.AreEqual(Ord(jcCMYK), Ord(Img.ColorSpace));

  // without colr the component count decides
  Img := PdfJPXDecode(WrapJP2(SynthCodestream([8, 8, 8]), 3, -1));
  Assert.AreEqual(Ord(jcRGB), Ord(Img.ColorSpace));
end;

procedure TPdfJPXTests.SyntheticPaletteAndIndexed;
var
  Pclr, Cmap: TByteWriter;
  Img: TPdfJPXImage;
  Opt: TPdfJPXOptions;
  Data: TBytes;
  K: Integer;
begin
  // two RGB entries; index 128 is clamped to the last entry
  Pclr.Put16(2);
  Pclr.Put8(3);
  Pclr.Put8(7); Pclr.Put8(7); Pclr.Put8(7);
  Pclr.Put8(10); Pclr.Put8(20); Pclr.Put8(30);
  Pclr.Put8(200); Pclr.Put8(100); Pclr.Put8(50);
  for K := 0 to 2 do
  begin
    Cmap.Put16(0);
    Cmap.Put8(1);
    Cmap.Put8(K);
  end;
  Data := WrapJP2(SynthCodestream([8]), 1, 16, Box('pclr', Pclr.Bytes) + Box('cmap', Cmap.Bytes));
  Img := PdfJPXDecode(Data);
  Assert.AreEqual(3, Img.Components);
  Assert.AreEqual(Ord(jcRGB), Ord(Img.ColorSpace));
  Assert.AreEqual(200, Integer(Img.Data[0]));
  Assert.AreEqual(100, Integer(Img.Data[1]));
  Assert.AreEqual(50, Integer(Img.Data[2]));
  Assert.AreEqual(8 * 8 * 3, Integer(Length(Img.Data)));

  // the PDF colour space is /Indexed: raw indices
  Opt := TPdfJPXOptions.Default;
  Opt.IsIndexed := True;
  Img := PdfJPXDecode(Data, Opt);
  Assert.AreEqual(1, Img.Components);
  Assert.AreEqual(128, Integer(Img.Data[0]));
  Assert.AreEqual(64, Integer(Length(Img.Data)));
end;

procedure TPdfJPXTests.SyntheticChannelDefinitionAlpha;
var
  Cdef: TByteWriter;
  Img: TPdfJPXImage;
begin
  // channel 0 (8-bit, 128) is the opacity, channel 1 (4-bit, 136 after scaling) the grey colour
  Cdef.Put16(2);
  Cdef.Put16(0); Cdef.Put16(1); Cdef.Put16(0);
  Cdef.Put16(1); Cdef.Put16(0); Cdef.Put16(1);
  Img := PdfJPXDecode(WrapJP2(SynthCodestream([8, 4]), 2, 17, Box('cdef', Cdef.Bytes)));
  Assert.AreEqual(1, Img.Components);
  Assert.IsTrue(Img.HasAlpha);
  Assert.AreEqual(Ord(jcGray), Ord(Img.ColorSpace));
  Assert.AreEqual(8 * 8 * 2, Integer(Length(Img.Data)));
  Assert.AreEqual(136, Integer(Img.Data[0]), 'colour first');
  Assert.AreEqual(128, Integer(Img.Data[1]), 'alpha last');
end;

procedure TPdfJPXTests.SyntheticSMaskInData;
var
  Img: TPdfJPXImage;
  Opt: TPdfJPXOptions;
begin
  Img := PdfJPXDecode(SynthCodestream([8, 8]));
  Assert.AreEqual(2, Img.Components);
  Assert.IsFalse(Img.HasAlpha);
  Assert.AreEqual(Ord(jcUnknown), Ord(Img.ColorSpace));

  Opt := TPdfJPXOptions.Default;
  Opt.SMaskInData := True;
  Img := PdfJPXDecode(SynthCodestream([8, 8]), Opt);
  Assert.AreEqual(1, Img.Components);
  Assert.IsTrue(Img.HasAlpha);
  Assert.AreEqual(Ord(jcGray), Ord(Img.ColorSpace));

  Img := PdfJPXDecode(SynthCodestream([8, 8, 8, 8]), Opt);
  Assert.AreEqual(3, Img.Components);
  Assert.IsTrue(Img.HasAlpha);
  Assert.AreEqual(Ord(jcRGB), Ord(Img.ColorSpace));

  // SMaskInData with a 3-component RGB colour space and 3 components: no alpha in the data
  Opt.ColorComponents := 3;
  Img := PdfJPXDecode(SynthCodestream([8, 8, 8]), Opt);
  Assert.AreEqual(3, Img.Components);
  Assert.IsFalse(Img.HasAlpha);
end;

procedure TPdfJPXTests.SyntheticReadInfo;
var
  Info: TPdfJPXInfo;
begin
  Assert.IsTrue(PdfJPXReadInfo(WrapJP2(SynthCodestream([8, 8, 8]), 3, 16), Info));
  Assert.AreEqual(8, Info.Width);
  Assert.AreEqual(8, Info.Height);
  Assert.AreEqual(3, Info.Components);
  Assert.AreEqual(8, Info.BitDepth);
  Assert.AreEqual(0, Info.DecompositionLevels);
  Assert.AreEqual(Ord(jcRGB), Ord(Info.ColorSpace));
  Assert.IsFalse(PdfJPXReadInfo(TEncoding.ANSI.GetBytes('not a jpeg 2000 file'), Info));
end;

procedure TPdfJPXTests.UnsupportedFeaturesRaise;
var
  PPM: TBytes;
begin
  Assert.IsTrue(RaisesFilterError(SynthCodestream([8], $01)), 'selective arithmetic coding bypass');
  Assert.IsTrue(RaisesFilterError(SynthCodestream([8], $04)), 'termination on each coding pass');
  PPM := [$FF, $60, 0, 3, 0];
  Assert.IsTrue(RaisesFilterError(SynthCodestream([8], 0, PPM)), 'PPM');
  // vertically causal, predictable termination, reset and segmentation symbols are accepted
  Assert.AreEqual(8, PdfJPXDecode(SynthCodestream([8], $08 or $10 or $02 or $20)).Width);
end;

procedure TPdfJPXTests.GarbageRaisesFilterError;
begin
  Assert.IsTrue(RaisesFilterError(nil));
  Assert.IsTrue(RaisesFilterError(TEncoding.ANSI.GetBytes('this is not JPEG 2000 at all')));
  Assert.IsTrue(RaisesFilterError([$FF, $4F, $FF, $51, 0, 2]));
  Assert.IsTrue(RaisesFilterError(Box('jP  ', [$0D, $0A, $87, $0A]) + Box('jp2c', [1, 2, 3, 4])));
end;

procedure TPdfJPXTests.TruncatedSyntheticNeverCrashes;
var
  Full, Part: TBytes;
  N, Decoded: Integer;
begin
  Full := WrapJP2(SynthCodestream([8, 8, 8]), 3, 16);
  Decoded := 0;
  for N := 0 to Length(Full) - 1 do
  begin
    Part := Copy(Full, 0, N);
    try
      PdfJPXDecode(Part);
      Inc(Decoded);
    except
      on E: EPdfFilterError do
        ;
    end;
  end;
  // once the main header is complete, a missing tile still gives an image
  Assert.IsTrue(Decoded > 0);
end;

{ ---------------------------------------------------------------------------- }
{ Corpus                                                                       }
{ ---------------------------------------------------------------------------- }

procedure TPdfJPXTests.CorpusDamagedStreams;
const
  Files: array[0..2] of string = ('S2.pdf', 'jp2k-resetprob.pdf', 'issue19326.pdf');
var
  FileName: string;
  Sample: TJpxSample;
  Data: TBytes;
  I, K, Pos, Ok, Rejected: Integer;
begin
  if CorpusDir = '' then
  begin
    Assert.Pass('pdf.js corpus not present');
    Exit;
  end;
  RandSeed := 77;
  Ok := 0;
  Rejected := 0;
  for FileName in Files do
  begin
    if not FirstJpx(FileName, Sample) then
      Continue;
    for I := 1 to 60 do
    begin
      Data := Copy(Sample.Data);
      if I mod 3 = 0 then
        SetLength(Data, Random(Length(Data)))
      else
        for K := 1 to 1 + Random(8) do
        begin
          Pos := Random(Length(Data));
          Data[Pos] := Byte(Random(256));
        end;
      try
        PdfJPXDecode(Data);
        Inc(Ok);
      except
        on E: EPdfFilterError do
          Inc(Rejected);
      end;
    end;
  end;
  TDUnitX.CurrentRunner.Log(TLogLevel.Information,
    Format('JPX damaged streams: %d decoded (partially), %d rejected with EPdfFilterError', [Ok, Rejected]));
  Assert.Pass;
end;

procedure TPdfJPXTests.CorpusReduceLevelsHalvesSize;
var
  Sample: TJpxSample;
  Full, Half: TPdfJPXImage;
  X, Y, C, Sum, N, Diff: Int64;
  Avg: Integer;
begin
  if not FirstJpx('issue5567.pdf', Sample) then
  begin
    Assert.Pass('issue5567.pdf not present');
    Exit;
  end;
  Full := PdfJPXDecode(Sample.Data);
  Half := PdfJPXDecode(Sample.Data, 1);
  Assert.AreEqual(1500, Full.Width);
  Assert.AreEqual(1125, Full.Height);
  Assert.AreEqual(750, Half.Width);
  Assert.AreEqual(563, Half.Height);
  Assert.AreEqual(1, Half.ReducedLevels);
  Assert.AreEqual(Full.Components, Half.Components);
  // the half-size image matches the 2x2 averages of the full one
  Diff := 0;
  N := 0;
  for Y := 0 to Half.Height - 2 do
    for X := 0 to Half.Width - 1 do
      for C := 0 to Full.Components - 1 do
      begin
        Sum := Full.Data[((2 * Y) * Full.Width + 2 * X) * 3 + C] + Full.Data[((2 * Y) * Full.Width + 2 * X + 1) * 3 + C] +
          Full.Data[((2 * Y + 1) * Full.Width + 2 * X) * 3 + C] + Full.Data[((2 * Y + 1) * Full.Width + 2 * X + 1) * 3 + C];
        Avg := (Sum + 2) div 4;
        Inc(Diff, Abs(Avg - Half.Data[(Y * Half.Width + X) * 3 + C]));
        Inc(N);
      end;
  TDUnitX.CurrentRunner.Log(TLogLevel.Information, Format('ReduceLevels=1: mean abs difference to 2x2 average %.2f',
    [Diff / N]));
  Assert.IsTrue(Diff / N < 8, 'reduced image resembles the full one');
  WritePng(Half, 'jpx_issue5567_half.png');
end;

procedure TPdfJPXTests.CorpusAllJPXImages;
const
  PngFiles: array[0..2] of string = ('issue5567.pdf', 'issue5481.pdf', 'S2.pdf');
var
  Dir, F: string;
  Files: TArray<string>;
  Samples: TList<TJpxSample>;
  Sample: TJpxSample;
  Img: TPdfJPXImage;
  Info: TPdfJPXInfo;
  Log, Failures, Errors: TStringList;
  SW, Total: TStopwatch;
  Decoded, Rejected, Mismatch, S, ExpW, ExpH: Integer;
  PngDone: TDictionary<string, Boolean>;
begin
  Dir := CorpusDir;
  if Dir = '' then
  begin
    Assert.Pass('pdf.js corpus not present');
    Exit;
  end;
  Files := TDirectory.GetFiles(Dir, '*.pdf');
  TArray.Sort<string>(Files, TComparer<string>.Construct(
    function(const L, R: string): Integer
    begin
      Result := CompareText(L, R);
    end));
  Samples := TList<TJpxSample>.Create;
  Log := TStringList.Create;
  Failures := TStringList.Create;
  Errors := TStringList.Create;
  PngDone := TDictionary<string, Boolean>.Create;
  try
    Total := TStopwatch.StartNew;
    for F in Files do
      CollectJpx(F, 10, Samples);
    Log.Add(Format('JPX corpus: %d JPXDecode streams in %d PDFs scanned (%d ms)',
      [Samples.Count, Length(Files), Total.ElapsedMilliseconds]));
    Decoded := 0;
    Rejected := 0;
    Mismatch := 0;
    for Sample in Samples do
    begin
      SW := TStopwatch.StartNew;
      try
        Img := PdfJPXDecode(Sample.Data, Sample.Options);
      except
        on E: EPdfFilterError do
        begin
          Inc(Rejected);
          Failures.Add(Format('%s %s: %s', [Sample.FileName, Sample.Key, E.Message]));
          Continue;
        end;
        on E: Exception do
        begin
          Errors.Add(Format('%s %s: %s: %s', [Sample.FileName, Sample.Key, E.ClassName, E.Message]));
          Continue;
        end;
      end;
      Inc(Decoded);
      Log.Add(Format('  %-22s %-8s dict %5dx%-5d -> %5dx%-5d comps %d%s cs %d bits %2d reduced %d  %5d ms',
        [Sample.FileName, Sample.Key, Sample.Width, Sample.Height, Img.Width, Img.Height, Img.Components,
         IfThen(Img.HasAlpha, '+A', '  '), Ord(Img.ColorSpace), Img.BitDepth, Img.ReducedLevels,
         SW.ElapsedMilliseconds]));
      Assert.AreEqual(Int64(Img.Width) * Img.Height * (Img.Components + Ord(Img.HasAlpha)), Int64(Length(Img.Data)),
        Sample.FileName + ' data size');
      if PdfJPXReadInfo(Sample.Data, Info) and (Info.Width = Sample.Width) and (Info.Height = Sample.Height) then
      begin
        // the dictionary matches the codestream: the decoded size must match too
        S := 1 shl Img.ReducedLevels;
        ExpW := (Sample.Width + S - 1) div S;
        ExpH := (Sample.Height + S - 1) div S;
        Assert.AreEqual(ExpW, Img.Width, Sample.FileName + ' width');
        Assert.AreEqual(ExpH, Img.Height, Sample.FileName + ' height');
      end
      else
      begin
        Inc(Mismatch);
        Log.Add(Format('    dictionary size %dx%d differs from the codestream %dx%d',
          [Sample.Width, Sample.Height, Info.Width, Info.Height]));
      end;
      if MatchText(Sample.FileName, PngFiles) and not PngDone.ContainsKey(Sample.FileName) then
      begin
        PngDone.Add(Sample.FileName, True);
        WritePng(Img, 'jpx_' + ChangeFileExt(Sample.FileName, '') + '.png');
      end;
    end;
    Log.Add(Format('JPX corpus: %d decoded, %d rejected (EPdfFilterError), %d other exceptions, ' +
      '%d with a dictionary size that differs from the codestream, %d ms in total',
      [Decoded, Rejected, Errors.Count, Mismatch, Total.ElapsedMilliseconds]));
    if Failures.Count > 0 then
      Log.Add('Rejected: ' + Failures.Text);
    TDUnitX.CurrentRunner.Log(TLogLevel.Information, Log.Text);
    if Errors.Count > 0 then
      Assert.Fail(Errors.Text);
    if Samples.Count > 0 then
      Assert.IsTrue(Decoded > 0, 'no JPX image decoded');
  finally
    PngDone.Free;
    Errors.Free;
    Failures.Free;
    Log.Free;
    Samples.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfJPXTests);

end.
