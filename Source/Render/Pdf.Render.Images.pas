{*******************************************************************************
  Pdf.Render.Images
  Image XObjects and inline images (ISO 32000-1 §8.9): sample unpacking
  (1..16 bits per component), /Decode arrays, colour conversion through
  Pdf.Render.ColorSpaces, stencil masks (/ImageMask), soft masks (/SMask),
  explicit masks (/Mask stream) and colour key masking (/Mask array).
  JPEG (DCTDecode) is decoded by Skia; JPX, JBIG2 and CCITT are not supported
  yet. The result is an RGBA8888 premultiplied ISkImage, top-down: pixel (0,0)
  is the top-left sample of the image.
  Portions derived from pdf.js (Mozilla, Apache License 2.0), src/core/image.js.
*******************************************************************************}
unit Pdf.Render.Images;

interface

uses
  System.SysUtils, System.UITypes, System.Skia, Pdf.Core.Types, Pdf.Core.Objects, Pdf.Render.ColorSpaces;

const
  /// <summary>Images with more pixels than this are not decoded (Decode returns nil).</summary>
  PdfMaxImagePixels = 50000000;

type
  /// <summary>Decodes PDF images to Skia images.</summary>
  TPdfImageDecoder = class
  public
    /// <summary>Decodes an image XObject or an inline image (dictionary with abbreviated keys such as
    /// /W /H /BPC /CS /D /F /IM) to an RGBA8888 premultiplied ISkImage (for an unmasked JPEG Skia's own
    /// decoded image is returned). The image is top-down: pixel (0,0) is the first sample of the data,
    /// which maps to the top-left corner of the unit square (0,1) in image space.
    /// Resources: used to look up named colour spaces (inline images); may be nil.
    /// FillColor: colour painted by stencil masks (/ImageMask true), its alpha is used as well.
    /// IsStencil: True for a stencil mask. Returns nil when nothing can be decoded; Reason then says why
    /// (e.g. 'JPXDecode not supported'). Never raises for bad data.</summary>
    class function Decode(const Stream: IPdfStream; const Resources: IPdfDictionary; const Resolver: IPdfResolver;
      FillColor: TAlphaColor; out IsStencil: Boolean; out Reason: string): ISkImage; static;
    /// <summary>Width/Height from /Width /Height (or /W /H); False when missing or non-positive.</summary>
    class function GetSize(const Dict: IPdfDictionary; out Width, Height: Integer): Boolean; static;
    /// <summary>True when /ImageMask (or /IM) is true.</summary>
    class function IsStencilMask(const Dict: IPdfDictionary): Boolean; static;
  end;

/// <summary>Builds an ISkImage (RGBA8888, premultiplied) from a tightly packed RGBA8888 buffer of
/// Width*Height*4 bytes with straight (non-premultiplied) alpha, R first in memory. The caller's buffer is
/// not modified. Returns nil for invalid sizes or a too short buffer.</summary>
function PdfMakeSkImageRGBA(Width, Height: Integer; const RGBA: TBytes): ISkImage;

implementation

uses
  System.Math, System.StrUtils, System.Generics.Collections;

{$POINTERMATH ON}

type
  /// Raw sample data of an image: rows padded to whole bytes, Data is at least RowBytes*Height long.
  TSampleImage = record
    Width, Height, BPC, NComps, RowBytes: Integer;
    Data: TBytes;
  end;

  TCardinalArray = array of Cardinal;

// Pixels are handled as Cardinals with R in the lowest byte: RGBA8888 in memory on little-endian targets
// (all Delphi platforms).
function PackRGBA(R, G, B, A: Byte): Cardinal; inline;
begin
  Result := Cardinal(R) or (Cardinal(G) shl 8) or (Cardinal(B) shl 16) or (Cardinal(A) shl 24);
end;

function UnitToByte(V: Double): Byte; inline;
begin
  if V <= 0 then
    Result := 0
  else if V >= 1 then
    Result := 255
  else
    Result := Round(V * 255);
end;

function RGBToPixel(const C: TPdfRGB): Cardinal; inline;
begin
  Result := PackRGBA(UnitToByte(C.R), UnitToByte(C.G), UnitToByte(C.B), 255);
end;

function AlphaColorToPixel(C: TAlphaColor): Cardinal;
begin
  Result := PackRGBA((C shr 16) and $FF, (C shr 8) and $FF, C and $FF, (C shr 24) and $FF);
end;

{ Image creation }

procedure PremultiplyInPlace(var RGBA: TBytes; Count: Integer);
var
  P: PByte;
  I: Integer;
  A: Cardinal;
begin
  P := PByte(RGBA);
  for I := 0 to Count - 1 do
  begin
    A := P[3];
    if A = 0 then
      PCardinal(P)^ := 0
    else if A < 255 then
    begin
      P[0] := (P[0] * A + 127) div 255;
      P[1] := (P[1] * A + 127) div 255;
      P[2] := (P[2] * A + 127) div 255;
    end;
    Inc(P, 4);
  end;
end;

function HasTransparency(const RGBA: TBytes; Count: Integer): Boolean;
var
  P: PCardinal;
  I: Integer;
begin
  P := PCardinal(RGBA);
  for I := 0 to Count - 1 do
    if P[I] < $FF000000 then
      Exit(True);
  Result := False;
end;

/// Builds the Skia image from a straight-alpha buffer that may be modified (premultiplied in place).
function MakeImageOwned(Width, Height: Integer; var RGBA: TBytes): ISkImage;
var
  Info: TSkImageInfo;
begin
  Result := nil;
  if (Width <= 0) or (Height <= 0) or (Int64(Width) * Height * 4 > Length(RGBA)) then
    Exit;
  PremultiplyInPlace(RGBA, Width * Height);
  try
    Info := TSkImageInfo.Create(Width, Height, TSkColorType.RGBA8888, TSkAlphaType.Premul);
    Result := TSkImage.MakeRasterCopy(Info, PByte(RGBA), NativeUInt(Width) * 4);
  except
    Result := nil;
  end;
end;

function PdfMakeSkImageRGBA(Width, Height: Integer; const RGBA: TBytes): ISkImage;
var
  Buf: TBytes;
  Info: TSkImageInfo;
begin
  Result := nil;
  if (Width <= 0) or (Height <= 0) or (Int64(Width) * Height * 4 > Length(RGBA)) then
    Exit;
  if HasTransparency(RGBA, Width * Height) then
  begin
    SetLength(Buf, Width * Height * 4);
    Move(RGBA[0], Buf[0], Length(Buf));
    Exit(MakeImageOwned(Width, Height, Buf));
  end;
  try
    Info := TSkImageInfo.Create(Width, Height, TSkColorType.RGBA8888, TSkAlphaType.Premul);
    Result := TSkImage.MakeRasterCopy(Info, PByte(RGBA), NativeUInt(Width) * 4);
  except
    Result := nil;
  end;
end;

{ Helpers on dictionaries }

function GetDecodeArray(const Dict: IPdfDictionary; NComps: Integer; out Values: TArray<Double>): Boolean;
var
  Arr: IPdfArray;
  I: Integer;
begin
  Values := nil;
  Arr := PdfAsArray(Dict.Get('Decode', 'D'));
  if (Arr = nil) or (Arr.Count < 2 * NComps) then
    Exit(False);
  SetLength(Values, 2 * NComps);
  for I := 0 to 2 * NComps - 1 do
  begin
    if not PdfIsNumber(Arr.Get(I)) then
    begin
      Values := nil;
      Exit(False);
    end;
    Values[I] := Arr.GetNumber(I);
  end;
  Result := True;
end;

function IsDefaultDecode(const Values, Defaults: TArray<Double>): Boolean;
var
  I: Integer;
begin
  if Length(Values) <> Length(Defaults) then
    Exit(False);
  for I := 0 to High(Values) do
    if Abs(Values[I] - Defaults[I]) > 1E-9 then
      Exit(False);
  Result := True;
end;

function IsInvertedDecode(const Values: TArray<Double>): Boolean;
var
  I: Integer;
begin
  if Values = nil then
    Exit(False);
  for I := 0 to Length(Values) div 2 - 1 do
    if (Abs(Values[2 * I] - 1) > 1E-9) or (Abs(Values[2 * I + 1]) > 1E-9) then
      Exit(False);
  Result := True;
end;

function GetBitsPerComponent(const Dict: IPdfDictionary; Default: Integer): Integer;
var
  O: IPdfObject;
begin
  O := Dict.Get('BitsPerComponent', 'BPC');
  if PdfIsNumber(O) then
    Result := Integer(PdfAsInteger(O, Default))
  else
    Result := Default;
end;

function ReadStreamData(const Stream: IPdfStream; out Data: TBytes; out Filter, Reason: string): Boolean;
begin
  Data := nil;
  Filter := '';
  try
    Data := Stream.GetDecodedData;
    Filter := Stream.ImageFilter;
    Result := True;
  except
    on E: Exception do
    begin
      Reason := 'Filter error: ' + E.Message;
      Result := False;
    end;
  end;
end;

{ JPEG via Skia }

/// Skips junk before the SOI marker (as pdf.js does).
function StripJpegJunk(const Data: TBytes): TBytes;
var
  I, Limit: Integer;
begin
  Result := Data;
  if (Length(Data) >= 2) and (Data[0] = $FF) and (Data[1] = $D8) then
    Exit;
  Limit := Min(Integer(Length(Data)) - 3, 4096);
  for I := 1 to Limit do
    if (Data[I] = $FF) and (Data[I + 1] = $D8) and (Data[I + 2] = $FF) then
      Exit(Copy(Data, I, MaxInt));
end;

function DecodeJpeg(const Data: TBytes): ISkImage;
var
  Bytes: TBytes;
begin
  Result := nil;
  Bytes := StripJpegJunk(Data);
  if Length(Bytes) < 4 then
    Exit;
  try
    Result := TSkImage.MakeFromEncoded(Bytes);
  except
    Result := nil;
  end;
  if (Result <> nil) and ((Result.Width <= 0) or (Result.Height <= 0)) then
    Result := nil;
end;

function ReadImageRGBA(const Img: ISkImage; out RGBA: TBytes): Boolean;
var
  Info: TSkImageInfo;
begin
  RGBA := nil;
  if Int64(Img.Width) * Img.Height > PdfMaxImagePixels then
    Exit(False);
  SetLength(RGBA, Img.Width * Img.Height * 4);
  try
    Info := TSkImageInfo.Create(Img.Width, Img.Height, TSkColorType.RGBA8888, TSkAlphaType.Unpremul);
    Result := Img.ReadPixels(Info, PByte(RGBA), NativeUInt(Img.Width) * 4);
  except
    Result := False;
  end;
  if not Result then
    RGBA := nil;
end;

/// Turns decoded JPEG pixels into 8-bit samples with NComps (1 or 3) components taken from the R or RGB channels.
procedure JpegToSamples(const Img: ISkImage; const RGBA: TBytes; NComps: Integer; out S: TSampleImage);
var
  I, N: Integer;
  Src, Dst: PByte;
begin
  S.Width := Img.Width;
  S.Height := Img.Height;
  S.BPC := 8;
  S.NComps := NComps;
  S.RowBytes := S.Width * NComps;
  N := S.Width * S.Height;
  SetLength(S.Data, N * NComps);
  Src := PByte(RGBA);
  Dst := PByte(S.Data);
  if NComps = 1 then
    for I := 0 to N - 1 do
    begin
      Dst[I] := Src[0];
      Inc(Src, 4);
    end
  else
    for I := 0 to N - 1 do
    begin
      Dst[0] := Src[0];
      Dst[1] := Src[1];
      Dst[2] := Src[2];
      Inc(Dst, 3);
      Inc(Src, 4);
    end;
end;

{ Raw CMYK from 4-component JPEGs }

// Skia converts CMYK JPEGs to RGB assuming Adobe-inverted data (R = C*K/255 on the stored values), which is
// right only for PDFs that say /Decode [1 0 1 0 1 0 1 0]; pdf.js takes the stored values as plain CMYK.
// Skia cannot output CMYK, so the stored channels are recovered from two extra decodes of a rewritten
// header in which some components use an all-zero quantisation table (their samples become 128):
//   pass A, K zeroed:     R,G,B = C,M,Y * 128/255
//   pass B, C,M,Y zeroed: R = K * 128/255
// This keeps 7 of the 8 bits of each channel. Embedded ICC profiles (APP2) are dropped so that Skia uses its
// plain swizzle.

/// Rewrites a JPEG header: components whose bit is set in ZeroMask (bit i = i-th component of the frame) get a
/// new all-zero quantisation table; APP2 segments are removed. Returns nil when the header is not understood.
/// NComps receives the component count of the frame (0 when unknown); ZeroMask < 0 only parses (returns nil).
function JpegRewrite(const Data: TBytes; ZeroMask: Integer; out NComps: Integer): TBytes;
var
  P, Len, SegLen, Q, SOS, I, OutLen, Free: Integer;
  M: Byte;
  Used: array[0..3] of Boolean;
  Segs: array of record Pos, Len: Integer; Marker: Byte; end;
  SOFIndex: Integer;
  Buf: TBytes;

  procedure Put(const Src; Count: Integer);
  begin
    if Count > 0 then
      Move(Src, Buf[OutLen], Count);
    Inc(OutLen, Count);
  end;

begin
  Result := nil;
  NComps := 0;
  Len := Length(Data);
  if (Len < 4) or (Data[0] <> $FF) or (Data[1] <> $D8) then
    Exit;
  for I := 0 to 3 do
    Used[I] := False;
  SOFIndex := -1;
  SOS := -1;
  P := 2;
  while P + 4 <= Len do
  begin
    if Data[P] <> $FF then
      Exit;
    M := Data[P + 1];
    if M = $FF then
    begin
      Inc(P);
      Continue;
    end;
    if (M = $01) or ((M >= $D0) and (M <= $D7)) then
    begin
      Inc(P, 2);
      Continue;
    end;
    if M = $DA then
    begin
      SOS := P;
      Break;
    end;
    SegLen := (Data[P + 2] shl 8) or Data[P + 3];
    if (SegLen < 2) or (P + 2 + SegLen > Len) then
      Exit;
    case M of
      $DB:
        begin
          Q := P + 4;
          while Q < P + 2 + SegLen do
          begin
            Used[Data[Q] and 3] := True;
            Inc(Q, 1 + 64 * (1 + (Data[Q] shr 4)));
          end;
        end;
      $C0..$C3, $C5..$C7, $C9..$CB, $CD..$CF:
        begin
          if SegLen < 8 then
            Exit;
          NComps := Data[P + 9];
          if 8 + 3 * NComps > SegLen then
            Exit;
          SOFIndex := Length(Segs);
        end;
    end;
    SetLength(Segs, Length(Segs) + 1);
    Segs[High(Segs)].Pos := P;
    Segs[High(Segs)].Len := SegLen + 2;
    Segs[High(Segs)].Marker := M;
    Inc(P, 2 + SegLen);
  end;
  if (SOS < 0) or (SOFIndex < 0) or (ZeroMask < 0) then
    Exit;
  Free := -1;
  if ZeroMask <> 0 then
  begin
    for I := 3 downto 0 do
      if not Used[I] then
      begin
        Free := I;
        Break;
      end;
    if Free < 0 then
      Exit;
  end;
  SetLength(Buf, Len + 69);
  OutLen := 0;
  Put(Data[0], 2);
  for I := 0 to High(Segs) do
  begin
    if Segs[I].Marker = $E2 then
      Continue;
    if (I = SOFIndex) and (ZeroMask <> 0) then
    begin
      // DQT segment with one 8-bit table of zeros, then the frame header with patched table selectors.
      Buf[OutLen] := $FF;
      Buf[OutLen + 1] := $DB;
      Buf[OutLen + 2] := 0;
      Buf[OutLen + 3] := 67;
      Buf[OutLen + 4] := Byte(Free);
      FillChar(Buf[OutLen + 5], 64, 0);
      Inc(OutLen, 69);
      Put(Data[Segs[I].Pos], Segs[I].Len);
      for Q := 0 to NComps - 1 do
        if (Q < 31) and (ZeroMask and (1 shl Q) <> 0) then
          Buf[OutLen - Segs[I].Len + 12 + 3 * Q] := Byte(Free);
    end
    else
      Put(Data[Segs[I].Pos], Segs[I].Len);
  end;
  Put(Data[SOS], Len - SOS);
  SetLength(Buf, OutLen);
  Result := Buf;
end;

/// Recovers the stored CMYK samples of a 4-component JPEG (see above) as 8-bit samples.
function JpegToCmykSamples(const Data: TBytes; out S: TSampleImage): Boolean;
var
  NC, I, N: Integer;
  ImgA, ImgB: ISkImage;
  A, B: TBytes;
  Expand: array[0..255] of Byte;
  PA, PB, D: PByte;
begin
  Result := False;
  ImgA := DecodeJpeg(JpegRewrite(Data, 8, NC));
  if (NC <> 4) or (ImgA = nil) then
    Exit;
  ImgB := DecodeJpeg(JpegRewrite(Data, 7, NC));
  if (ImgB = nil) or (ImgB.Width <> ImgA.Width) or (ImgB.Height <> ImgA.Height) then
    Exit;
  if not ReadImageRGBA(ImgA, A) or not ReadImageRGBA(ImgB, B) then
    Exit;
  S.Width := ImgA.Width;
  S.Height := ImgA.Height;
  S.BPC := 8;
  S.NComps := 4;
  S.RowBytes := S.Width * 4;
  ImgA := nil;
  ImgB := nil;
  for I := 0 to 255 do
    Expand[I] := Min(255, (I * 255 + 64) div 128);
  N := S.Width * S.Height;
  S.Data := nil;
  SetLength(S.Data, N * 4);
  PA := PByte(A);
  PB := PByte(B);
  D := PByte(S.Data);
  for I := 0 to N - 1 do
  begin
    D[0] := Expand[PA[0]];
    D[1] := Expand[PA[1]];
    D[2] := Expand[PA[2]];
    D[3] := Expand[PB[0]];
    Inc(D, 4);
    Inc(PA, 4);
    Inc(PB, 4);
  end;
  Result := True;
end;

{ Sample unpacking }

/// Sets RowBytes and pads Data with zeros to RowBytes*Height (missing samples count as 0).
function PrepareSamples(var S: TSampleImage; const Data: TBytes; out Reason: string): Boolean;
var
  Row, Need: Int64;
begin
  Row := (Int64(S.Width) * S.NComps * S.BPC + 7) div 8;
  Need := Row * S.Height;
  if Need > MaxInt then
  begin
    Reason := 'Image data too large';
    Exit(False);
  end;
  S.RowBytes := Integer(Row);
  if Length(Data) >= Need then
    S.Data := Data
  else
  begin
    S.Data := nil;
    SetLength(S.Data, Integer(Need));
    if Length(Data) > 0 then
      Move(Data[0], S.Data[0], Length(Data));
  end;
  Result := True;
end;

/// Unpacks Count samples of BPC bits (1..16) starting at Src into Raw.
procedure UnpackRow(Src: PByte; Count, BPC: Integer; var Raw: TCardinalArray);
var
  I: Integer;
  Buf: Cardinal;
  Bits: Integer;
  Mask: Cardinal;
begin
  case BPC of
    8:
      for I := 0 to Count - 1 do
        Raw[I] := Src[I];
    16:
      for I := 0 to Count - 1 do
        Raw[I] := (Cardinal(Src[2 * I]) shl 8) or Src[2 * I + 1];
    1:
      for I := 0 to Count - 1 do
        Raw[I] := (Src[I shr 3] shr (7 - (I and 7))) and 1;
    2:
      for I := 0 to Count - 1 do
        Raw[I] := (Src[I shr 2] shr (6 - 2 * (I and 3))) and 3;
    4:
      for I := 0 to Count - 1 do
        Raw[I] := (Src[I shr 1] shr (4 - 4 * (I and 1))) and 15;
  else
    Buf := 0;
    Bits := 0;
    Mask := (Cardinal(1) shl BPC) - 1;
    for I := 0 to Count - 1 do
    begin
      while Bits < BPC do
      begin
        Buf := (Buf shl 8) or Src^;
        Inc(Src);
        Inc(Bits, 8);
      end;
      Dec(Bits, BPC);
      Raw[I] := (Buf shr Bits) and Mask;
      Buf := Buf and ((Cardinal(1) shl Bits) - 1);
    end;
  end;
end;

/// Single-component images: every raw sample value maps through Table (length 2^BPC) to a pixel.
procedure ConvertOneComponent(const S: TSampleImage; const Table: TCardinalArray; Pix: PCardinal);
var
  X, Y, Full, J: Integer;
  Src: PByte;
  D: PCardinal;
  B: Byte;
  T0, T1: Cardinal;
  Raw: TCardinalArray;
begin
  if S.BPC <> 1 then
    SetLength(Raw, S.Width);
  T0 := Table[0];
  if Length(Table) > 1 then
    T1 := Table[1]
  else
    T1 := T0;
  for Y := 0 to S.Height - 1 do
  begin
    Src := PByte(S.Data) + NativeInt(Y) * S.RowBytes;
    D := Pix + NativeInt(Y) * S.Width;
    case S.BPC of
      1:
        begin
          Full := S.Width shr 3;
          for X := 0 to Full - 1 do
          begin
            B := Src[X];
            if B = 0 then
            begin
              D[0] := T0; D[1] := T0; D[2] := T0; D[3] := T0;
              D[4] := T0; D[5] := T0; D[6] := T0; D[7] := T0;
            end
            else if B = $FF then
            begin
              D[0] := T1; D[1] := T1; D[2] := T1; D[3] := T1;
              D[4] := T1; D[5] := T1; D[6] := T1; D[7] := T1;
            end
            else
            begin
              D[0] := Table[B shr 7];
              D[1] := Table[(B shr 6) and 1];
              D[2] := Table[(B shr 5) and 1];
              D[3] := Table[(B shr 4) and 1];
              D[4] := Table[(B shr 3) and 1];
              D[5] := Table[(B shr 2) and 1];
              D[6] := Table[(B shr 1) and 1];
              D[7] := Table[B and 1];
            end;
            Inc(D, 8);
          end;
          if S.Width and 7 <> 0 then
          begin
            B := Src[Full];
            for J := 0 to (S.Width and 7) - 1 do
              D[J] := Table[(B shr (7 - J)) and 1];
          end;
        end;
      8:
        for X := 0 to S.Width - 1 do
          D[X] := Table[Src[X]];
    else
      UnpackRow(Src, S.Width, S.BPC, Raw);
      for X := 0 to S.Width - 1 do
        D[X] := Table[Raw[X]];
    end;
  end;
end;

{ Colour conversion }

type
  TColorKey = record
    Active: Boolean;
    Min, Max: TArray<Cardinal>;
    function Matches(const Raw: TCardinalArray; Offset, NComps: Integer): Boolean; inline;
  end;

function TColorKey.Matches(const Raw: TCardinalArray; Offset, NComps: Integer): Boolean;
var
  C: Integer;
begin
  for C := 0 to NComps - 1 do
    if (Raw[Offset + C] < Min[C]) or (Raw[Offset + C] > Max[C]) then
      Exit(False);
  Result := True;
end;

function DecodeComp(const Decode: TArray<Double>; C: Integer; Raw: Cardinal; MaxVal: Double): Double; inline;
begin
  Result := Decode[2 * C] + Raw * (Decode[2 * C + 1] - Decode[2 * C]) / MaxVal;
end;

/// Builds the 2^BPC pixel table for a single-component colour image (or a stencil mask).
function BuildOneComponentTable(CS: TPdfColorSpace; const Decode: TArray<Double>; BPC: Integer;
  Stencil: Boolean; FillPixel: Cardinal; const Key: TColorKey): TCardinalArray;
var
  I, N, Idx: Integer;
  MaxVal, V: Double;
  Comps: TArray<Double>;
begin
  N := 1 shl BPC;
  MaxVal := N - 1;
  SetLength(Result, N);
  SetLength(Comps, 1);
  for I := 0 to N - 1 do
  begin
    V := DecodeComp(Decode, 0, Cardinal(I), MaxVal);
    if Stencil then
    begin
      if V < 0.5 then
        Result[I] := FillPixel
      else
        Result[I] := 0;
      Continue;
    end;
    if CS.Family = csIndexed then
    begin
      Idx := EnsureRange(Round(V), 0, Max(CS.HiVal, 0));
      Result[I] := RGBToPixel(CS.LookupRGB(Idx));
    end
    else
    begin
      Comps[0] := V;
      Result[I] := RGBToPixel(CS.ToRGB(Comps));
    end;
    if Key.Active and (Cardinal(I) >= Key.Min[0]) and (Cardinal(I) <= Key.Max[0]) then
      Result[I] := 0;
  end;
end;

/// Multi-component images (DeviceRGB, DeviceCMYK and everything else through ToRGB).
procedure ConvertMultiComponent(const S: TSampleImage; CS: TPdfColorSpace; const Decode: TArray<Double>;
  const Key: TColorKey; Pix: PCardinal);
type
  TMode = (mRGB8, mCMYK8, mRGB, mCMYK, mGeneric);
var
  Mode: TMode;
  N, X, Y, C, P, KeyBits: Integer;
  MaxVal: Double;
  Src: PByte;
  D: PCardinal;
  Raw: TCardinalArray;
  CompTab: array of TBytes;
  Comps: TArray<Double>;
  Small: TCardinalArray;
  Cache: TDictionary<UInt64, Cardinal>;
  Key64, LastKey: UInt64;
  HasLast: Boolean;
  LastPix, Px: Cardinal;
  K: Integer;
  UseSmall, UseDict: Boolean;

  function ComputePixel(Offset: Integer): Cardinal;
  var
    I: Integer;
  begin
    for I := 0 to N - 1 do
      Comps[I] := DecodeComp(Decode, I, Raw[Offset + I], MaxVal);
    Result := RGBToPixel(CS.ToRGB(Comps));
  end;

begin
  N := S.NComps;
  MaxVal := (1 shl S.BPC) - 1;
  if (CS.Family = csDeviceRGB) and (N = 3) then
    Mode := mRGB
  else if (CS.Family = csDeviceCMYK) and (N = 4) then
    Mode := mCMYK
  else
    Mode := mGeneric;
  if (Mode <> mGeneric) and (S.BPC = 8) and not Key.Active and IsDefaultDecode(Decode, CS.DefaultDecode(8)) then
  begin
    if Mode = mRGB then
      Mode := mRGB8
    else
      Mode := mCMYK8;
  end;

  // Fast 8-bit paths straight from the sample buffer.
  if Mode in [mRGB8, mCMYK8] then
  begin
    for Y := 0 to S.Height - 1 do
    begin
      Src := PByte(S.Data) + NativeInt(Y) * S.RowBytes;
      D := Pix + NativeInt(Y) * S.Width;
      if Mode = mRGB8 then
        for X := 0 to S.Width - 1 do
        begin
          D[X] := Cardinal(Src[0]) or (Cardinal(Src[1]) shl 8) or (Cardinal(Src[2]) shl 16) or $FF000000;
          Inc(Src, 3);
        end
      else
        for X := 0 to S.Width - 1 do
        begin
          K := 255 - Src[3];
          D[X] := PackRGBA(((255 - Src[0]) * K + 127) div 255, ((255 - Src[1]) * K + 127) div 255,
            ((255 - Src[2]) * K + 127) div 255, 255);
          Inc(Src, 4);
        end;
    end;
    Exit;
  end;

  SetLength(Raw, S.Width * N);
  if Mode in [mRGB, mCMYK] then
  begin
    // Per-component tables: raw sample -> decoded component as a byte.
    SetLength(CompTab, N);
    for C := 0 to N - 1 do
    begin
      SetLength(CompTab[C], 1 shl S.BPC);
      for P := 0 to High(CompTab[C]) do
        CompTab[C][P] := UnitToByte(DecodeComp(Decode, C, Cardinal(P), MaxVal));
    end;
    for Y := 0 to S.Height - 1 do
    begin
      UnpackRow(PByte(S.Data) + NativeInt(Y) * S.RowBytes, S.Width * N, S.BPC, Raw);
      D := Pix + NativeInt(Y) * S.Width;
      P := 0;
      for X := 0 to S.Width - 1 do
      begin
        if Key.Active and Key.Matches(Raw, P, N) then
          D[X] := 0
        else if Mode = mRGB then
          D[X] := PackRGBA(CompTab[0][Raw[P]], CompTab[1][Raw[P + 1]], CompTab[2][Raw[P + 2]], 255)
        else
        begin
          K := 255 - CompTab[3][Raw[P + 3]];
          D[X] := PackRGBA(((255 - CompTab[0][Raw[P]]) * K + 127) div 255,
            ((255 - CompTab[1][Raw[P + 1]]) * K + 127) div 255,
            ((255 - CompTab[2][Raw[P + 2]]) * K + 127) div 255, 255);
        end;
        Inc(P, N);
      end;
    end;
    Exit;
  end;

  // Generic path: ToRGB per pixel, cached by the raw sample tuple.
  SetLength(Comps, N);
  KeyBits := N * S.BPC;
  UseSmall := KeyBits <= 16;
  UseDict := not UseSmall and (KeyBits <= 64);
  if UseSmall then
    SetLength(Small, 1 shl KeyBits); // 0 = not computed yet (computed pixels are always opaque)
  Cache := nil;
  if UseDict then
    Cache := TDictionary<UInt64, Cardinal>.Create;
  try
    HasLast := False;
    LastKey := 0;
    LastPix := 0;
    for Y := 0 to S.Height - 1 do
    begin
      UnpackRow(PByte(S.Data) + NativeInt(Y) * S.RowBytes, S.Width * N, S.BPC, Raw);
      D := Pix + NativeInt(Y) * S.Width;
      P := 0;
      for X := 0 to S.Width - 1 do
      begin
        if Key.Active and Key.Matches(Raw, P, N) then
          D[X] := 0
        else if UseSmall or UseDict then
        begin
          Key64 := 0;
          for C := 0 to N - 1 do
            Key64 := (Key64 shl S.BPC) or Raw[P + C];
          if UseSmall then
          begin
            Px := Small[Integer(Key64)];
            if Px = 0 then
            begin
              Px := ComputePixel(P);
              Small[Integer(Key64)] := Px;
            end;
          end
          else if HasLast and (Key64 = LastKey) then
            Px := LastPix
          else
          begin
            if not Cache.TryGetValue(Key64, Px) then
            begin
              Px := ComputePixel(P);
              if Cache.Count >= 65536 then
                Cache.Clear;
              Cache.Add(Key64, Px);
            end;
            HasLast := True;
            LastKey := Key64;
            LastPix := Px;
          end;
          D[X] := Px;
        end
        else
          D[X] := ComputePixel(P);
        Inc(P, N);
      end;
    end;
  finally
    Cache.Free;
  end;
end;

{ Masks }

/// Decodes a soft mask (/SMask) or an explicit stencil mask (/Mask stream) to one byte per pixel:
/// the decoded gray level (0..255) for a soft mask, the opacity (255 - level) for a stencil mask.
function LoadMaskPlane(const MaskStream: IPdfStream; IsSoft: Boolean; out Plane: TBytes; out MW, MH: Integer): Boolean;
var
  Dict: IPdfDictionary;
  Data, RGBA: TBytes;
  Filter, Reason: string;
  S: TSampleImage;
  Img: ISkImage;
  Decode: TArray<Double>;
  Table: TBytes;
  Raw: TCardinalArray;
  I, X, Y, N: Integer;
  MaxVal: Double;
  Dst: PByte;
begin
  Result := False;
  Plane := nil;
  Dict := MaskStream.Dict;
  if not TPdfImageDecoder.GetSize(Dict, MW, MH) or (Int64(MW) * MH > PdfMaxImagePixels) then
    Exit;
  if not ReadStreamData(MaskStream, Data, Filter, Reason) then
    Exit;
  if Filter = 'DCTDecode' then
  begin
    Img := DecodeJpeg(Data);
    if (Img = nil) or not ReadImageRGBA(Img, RGBA) then
      Exit;
    JpegToSamples(Img, RGBA, 1, S);
    MW := S.Width;
    MH := S.Height;
  end
  else if Filter <> '' then
    Exit
  else
  begin
    if Length(Data) = 0 then
      Exit;
    S.Width := MW;
    S.Height := MH;
    S.NComps := 1;
    if IsSoft then
      S.BPC := GetBitsPerComponent(Dict, 8)
    else
      S.BPC := 1;
    if (S.BPC < 1) or (S.BPC > 16) then
      Exit;
    if not PrepareSamples(S, Data, Reason) then
      Exit;
  end;
  if not GetDecodeArray(Dict, 1, Decode) then
    Decode := [0, 1];
  N := 1 shl S.BPC;
  MaxVal := N - 1;
  SetLength(Table, N);
  for I := 0 to N - 1 do
    if IsSoft then
      Table[I] := UnitToByte(DecodeComp(Decode, 0, Cardinal(I), MaxVal))
    else
      Table[I] := 255 - UnitToByte(DecodeComp(Decode, 0, Cardinal(I), MaxVal));
  SetLength(Plane, MW * MH);
  SetLength(Raw, MW);
  for Y := 0 to MH - 1 do
  begin
    UnpackRow(PByte(S.Data) + NativeInt(Y) * S.RowBytes, MW, S.BPC, Raw);
    Dst := PByte(Plane) + NativeInt(Y) * MW;
    for X := 0 to MW - 1 do
      Dst[X] := Table[Raw[X]];
  end;
  Result := True;
end;

/// Multiplies a mask plane (resampled nearest-neighbour to Width x Height) into the alpha of Pix.
procedure ApplyMaskPlane(Pix: PCardinal; Width, Height: Integer; const Plane: TBytes; MW, MH: Integer);
var
  X, Y, MY: Integer;
  ColMap: TArray<Integer>;
  Row: PByte;
  A, M: Cardinal;
  D: PCardinal;
begin
  SetLength(ColMap, Width);
  for X := 0 to Width - 1 do
    ColMap[X] := Integer(Int64(X) * MW div Width);
  for Y := 0 to Height - 1 do
  begin
    MY := Integer(Int64(Y) * MH div Height);
    Row := PByte(Plane) + NativeInt(MY) * MW;
    D := Pix + NativeInt(Y) * Width;
    for X := 0 to Width - 1 do
    begin
      M := Row[ColMap[X]];
      if M = 255 then
        Continue;
      A := D[X] shr 24;
      A := (A * M + 127) div 255;
      D[X] := (D[X] and $00FFFFFF) or (A shl 24);
    end;
  end;
end;

{ TPdfImageDecoder }

class function TPdfImageDecoder.GetSize(const Dict: IPdfDictionary; out Width, Height: Integer): Boolean;
var
  W, H: Double;
begin
  Width := 0;
  Height := 0;
  if Dict = nil then
    Exit(False);
  W := PdfAsNumber(Dict.Get('Width', 'W'), 0);
  H := PdfAsNumber(Dict.Get('Height', 'H'), 0);
  if (W < 1) or (H < 1) or (W > 1E9) or (H > 1E9) then
    Exit(False);
  Width := Trunc(W);
  Height := Trunc(H);
  Result := True;
end;

class function TPdfImageDecoder.IsStencilMask(const Dict: IPdfDictionary): Boolean;
begin
  Result := (Dict <> nil) and PdfAsBoolean(Dict.Get('ImageMask', 'IM'), False);
end;

function DecodeImage(const Stream: IPdfStream; const Resources: IPdfDictionary; const Resolver: IPdfResolver;
  FillColor: TAlphaColor; out IsStencil: Boolean; out Reason: string): ISkImage;
var
  Dict: IPdfDictionary;
  W, H, BPC, NComps, JComps, I, MW, MH: Integer;
  Data, RGBA, Plane: TBytes;
  Filter: string;
  CS: TPdfColorSpace;
  CSObj, MaskObj: IPdfObject;
  Decode: TArray<Double>;
  HasDecode, IsJpeg, NeedsProcessing, JpegAsRGB: Boolean;
  SMaskStream, MaskStream: IPdfStream;
  MaskArr: IPdfArray;
  Key: TColorKey;
  Jpeg: ISkImage;
  S: TSampleImage;
  Table: TCardinalArray;
begin
  Result := nil;
  IsStencil := False;
  Reason := '';
  if Stream = nil then
  begin
    Reason := 'No image stream';
    Exit;
  end;
  Dict := Stream.Dict;
  if not TPdfImageDecoder.GetSize(Dict, W, H) then
  begin
    Reason := 'Invalid image size';
    Exit;
  end;
  // For JPEGs the real size comes from the JPEG data (checked below when pixels are processed).
  if (Int64(W) * H > PdfMaxImagePixels) and (IndexStr('DCTDecode', Stream.GetFilterNames) < 0) then
  begin
    Reason := Format('Image too large (%d x %d)', [W, H]);
    Exit;
  end;
  IsStencil := TPdfImageDecoder.IsStencilMask(Dict);
  JpegAsRGB := False;
  if not ReadStreamData(Stream, Data, Filter, Reason) then
    Exit;
  if (Filter = 'JPXDecode') or (Filter = 'JBIG2Decode') or (Filter = 'CCITTFaxDecode') then
  begin
    Reason := Filter + ' not supported';
    Exit;
  end;
  if (Filter <> '') and (Filter <> 'DCTDecode') then
  begin
    Reason := Filter + ' not supported';
    Exit;
  end;
  IsJpeg := Filter = 'DCTDecode';
  if Length(Data) = 0 then
  begin
    Reason := 'Image has no data';
    Exit;
  end;

  // Masks (not for stencil masks; an SMask overrides /Mask).
  SMaskStream := nil;
  MaskStream := nil;
  MaskArr := nil;
  if not IsStencil then
  begin
    SMaskStream := PdfAsStream(Dict.Get('SMask'));
    if SMaskStream = nil then
    begin
      MaskObj := Dict.Get('Mask');
      MaskStream := PdfAsStream(MaskObj);
      if MaskStream = nil then
        MaskArr := PdfAsArray(MaskObj);
    end;
  end;

  // Colour space.
  CS := nil;
  try
    if IsStencil then
      NComps := 1
    else
    begin
      CSObj := Dict.Get('ColorSpace', 'CS');
      if not PdfIsNull(CSObj) then
        CS := TPdfColorSpace.Parse(CSObj, Resources, Resolver);
      if (CS <> nil) and CS.IsNone then
      begin
        Reason := 'Separation /None: nothing is painted';
        Exit;
      end;
      if (CS <> nil) and CS.IsPattern then
        FreeAndNil(CS);
      if (CS = nil) and not IsJpeg then
      begin
        // Unknown or missing colour space: guess the component count from the data size.
        BPC := GetBitsPerComponent(Dict, 8);
        if (BPC >= 1) and (BPC <= 16) then
          I := Round(Length(Data) * 8.0 / (Int64(W) * H * BPC))
        else
          I := 1;
        if I >= 4 then
          CS := TPdfColorSpace.DeviceCMYK
        else if I = 3 then
          CS := TPdfColorSpace.DeviceRGB
        else
          CS := TPdfColorSpace.DeviceGray;
      end;
      if CS <> nil then
        NComps := Max(CS.NComponents, 1)
      else
        NComps := 0;
    end;

    // JPEG: Skia decodes; return its image directly unless more work is needed.
    if IsJpeg then
    begin
      Data := StripJpegJunk(Data);
      Jpeg := DecodeJpeg(Data);
      if Jpeg = nil then
      begin
        Reason := 'DCTDecode: cannot decode JPEG data';
        Exit;
      end;
      JpegRewrite(Data, -1, JComps);
      if JComps = 0 then
        JComps := NComps;
      NeedsProcessing := IsStencil or (SMaskStream <> nil) or (MaskStream <> nil) or (MaskArr <> nil);
      if JComps = 4 then
        // Skia's CMYK conversion is only right for Adobe-inverted data, i.e. /Decode [1 0 1 0 1 0 1 0].
        NeedsProcessing := NeedsProcessing or not (GetDecodeArray(Dict, 4, Decode) and IsInvertedDecode(Decode))
      else if CS <> nil then
      begin
        HasDecode := GetDecodeArray(Dict, NComps, Decode) and not IsDefaultDecode(Decode, CS.DefaultDecode(8));
        NeedsProcessing := NeedsProcessing or HasDecode or
          (CS.Family in [csIndexed, csSeparation, csDeviceN, csLab]);
      end;
      if not NeedsProcessing then
        Exit(Jpeg);
      if Int64(Jpeg.Width) * Jpeg.Height > PdfMaxImagePixels then
      begin
        Reason := Format('Image too large (%d x %d)', [Jpeg.Width, Jpeg.Height]);
        Exit;
      end;
      if (JComps = 4) and not IsStencil and JpegToCmykSamples(Data, S) then
      begin
        if (CS = nil) or (CS.NComponents <> 4) then
        begin
          FreeAndNil(CS);
          CS := TPdfColorSpace.DeviceCMYK;
        end;
        NComps := 4;
      end
      else
      begin
        if not ReadImageRGBA(Jpeg, RGBA) then
        begin
          Reason := 'DCTDecode: cannot read JPEG pixels';
          Exit;
        end;
        if not IsStencil and ((CS = nil) or not (NComps in [1, 3])) then
        begin
          // Unknown colour space or CMYK that could not be recovered: use Skia's RGB result as DeviceRGB.
          FreeAndNil(CS);
          CS := TPdfColorSpace.DeviceRGB;
          NComps := 3;
          JpegAsRGB := True;
          MaskArr := nil;
        end;
        JpegToSamples(Jpeg, RGBA, NComps, S);
        RGBA := nil;
      end;
      Jpeg := nil;
      W := S.Width;
      H := S.Height;
      BPC := 8;
    end
    else
    begin
      if IsStencil then
        BPC := 1
      else
        BPC := GetBitsPerComponent(Dict, 8);
      if (BPC < 1) or (BPC > 16) then
      begin
        Reason := Format('Unsupported BitsPerComponent %d', [BPC]);
        Exit;
      end;
      S.Width := W;
      S.Height := H;
      S.BPC := BPC;
      S.NComps := NComps;
      if not PrepareSamples(S, Data, Reason) then
        Exit;
    end;
    Data := nil;

    // Decode array.
    if JpegAsRGB then
      Decode := CS.DefaultDecode(8)
    else if not GetDecodeArray(Dict, NComps, Decode) then
    begin
      if IsStencil then
        Decode := [0, 1]
      else
        Decode := CS.DefaultDecode(BPC);
    end;

    // Colour key mask.
    Key.Active := False;
    if (MaskArr <> nil) and (MaskArr.Count >= 2 * NComps) then
    begin
      Key.Active := True;
      SetLength(Key.Min, NComps);
      SetLength(Key.Max, NComps);
      for I := 0 to NComps - 1 do
      begin
        Key.Min[I] := Cardinal(EnsureRange(MaskArr.GetInteger(2 * I), 0, MaxInt));
        Key.Max[I] := Cardinal(EnsureRange(MaskArr.GetInteger(2 * I + 1), 0, MaxInt));
      end;
    end;

    // Samples -> RGBA.
    SetLength(RGBA, W * H * 4);
    if NComps = 1 then
    begin
      Table := BuildOneComponentTable(CS, Decode, BPC, IsStencil, AlphaColorToPixel(FillColor), Key);
      ConvertOneComponent(S, Table, PCardinal(RGBA));
    end
    else
      ConvertMultiComponent(S, CS, Decode, Key, PCardinal(RGBA));
    S.Data := nil;

    // Soft mask / explicit mask.
    if SMaskStream <> nil then
    begin
      if LoadMaskPlane(SMaskStream, True, Plane, MW, MH) then
        ApplyMaskPlane(PCardinal(RGBA), W, H, Plane, MW, MH);
    end
    else if MaskStream <> nil then
    begin
      if LoadMaskPlane(MaskStream, False, Plane, MW, MH) then
        ApplyMaskPlane(PCardinal(RGBA), W, H, Plane, MW, MH);
    end;
    Plane := nil;

    Result := MakeImageOwned(W, H, RGBA);
    if Result = nil then
      Reason := 'Cannot create Skia image';
  finally
    CS.Free;
  end;
end;

class function TPdfImageDecoder.Decode(const Stream: IPdfStream; const Resources: IPdfDictionary;
  const Resolver: IPdfResolver; FillColor: TAlphaColor; out IsStencil: Boolean; out Reason: string): ISkImage;
begin
  IsStencil := False;
  Reason := '';
  try
    Result := DecodeImage(Stream, Resources, Resolver, FillColor, IsStencil, Reason);
  except
    on E: Exception do
    begin
      Result := nil;
      Reason := 'Image decoding failed: ' + E.ClassName + ': ' + E.Message;
    end;
  end;
end;

end.
