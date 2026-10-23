{*******************************************************************************
  Pdf.Core.Filters
  Stream filters (PDF 32000-1 section 7.4): FlateDecode, LZWDecode,
  ASCII85Decode, ASCIIHexDecode, RunLengthDecode and the PNG/TIFF predictors.
  Image codecs (DCT, JPX, JBIG2, CCITT) are left to the renderer.

  All decoders are tolerant: truncated or slightly corrupt input yields the
  data decoded so far. EPdfFilterError is raised only when the input is
  non-empty and nothing at all could be decoded.

  Portions derived from pdf.js (Mozilla, Apache License 2.0): the LZW decoding
  loop (LZWStream), the PNG/TIFF predictor logic (PredictorStream) and the
  ASCII85/ASCIIHex tolerance rules.
*******************************************************************************}
unit Pdf.Core.Filters;

interface

uses
  System.SysUtils, Pdf.Core.Types;

type
  /// <summary>Decode parameters of a filter (/DecodeParms). Plain record so
  /// this unit has no dependency on the object model. Obtain an initialised
  /// value with <c>TPdfFilterParams.Default</c>.</summary>
  TPdfFilterParams = record
    /// <summary>1 (or 0) = none, 2 = TIFF predictor 2, &gt;= 10 = PNG predictors.</summary>
    Predictor: Integer;
    /// <summary>Colour components per sample (default 1; 0 is treated as 1).</summary>
    Colors: Integer;
    /// <summary>Bits per colour component (default 8; 0 is treated as 8).</summary>
    BitsPerComponent: Integer;
    /// <summary>Samples per row (default 1; 0 is treated as 1).</summary>
    Columns: Integer;
    /// <summary>LZW only: 1 (default) = code width grows one code early, 0 = not.</summary>
    EarlyChange: Integer;
    /// <summary>Returns the default parameters defined by the PDF specification.</summary>
    class function Default: TPdfFilterParams; static;
  end;

/// <summary>Decodes zlib/deflate data (FlateDecode). Leading whitespace or
/// garbage before the zlib header is skipped; raw deflate data (without zlib
/// header) is accepted as a fallback. The predictor is not applied.</summary>
function PdfFlateDecode(const Data: TBytes): TBytes;
/// <summary>Decodes LZW data (LZWDecode, 9-12 bit codes, MSB first). The
/// predictor is not applied.</summary>
function PdfLZWDecode(const Data: TBytes; EarlyChange: Integer = 1): TBytes;
/// <summary>Decodes ASCII base-85 data (ASCII85Decode).</summary>
function PdfASCII85Decode(const Data: TBytes): TBytes;
/// <summary>Decodes hexadecimal data (ASCIIHexDecode).</summary>
function PdfASCIIHexDecode(const Data: TBytes): TBytes;
/// <summary>Decodes run-length data (RunLengthDecode).</summary>
function PdfRunLengthDecode(const Data: TBytes): TBytes;
/// <summary>Applies the PNG/TIFF predictor described by Params (no-op when
/// Predictor &lt;= 1; unsupported predictor values or bit depths return the
/// data unchanged).</summary>
function PdfApplyPredictor(const Data: TBytes; const Params: TPdfFilterParams): TBytes;
/// <summary>True for DCTDecode/DCT, JPXDecode, JBIG2Decode, CCITTFaxDecode/CCF:
/// these are image codecs left to the renderer.</summary>
function PdfIsImageFilter(const Name: string): Boolean;
/// <summary>Normalises abbreviations (Fl, LZW, A85, AHx, RL, CCF, DCT) to the
/// full filter name. A leading '/' is removed; other names are returned
/// unchanged.</summary>
function PdfNormalizeFilterName(const Name: string): string;
/// <summary>Applies one named filter (FlateDecode, LZWDecode, ASCII85Decode,
/// ASCIIHexDecode, RunLengthDecode and their abbreviations) including the
/// predictor from Params (Flate and LZW only). 'Crypt' is identity (decryption
/// is done elsewhere). Raises EPdfFilterError for unknown filters and for image
/// filters (callers check PdfIsImageFilter first).</summary>
function PdfApplyFilter(const Name: string; const Data: TBytes; const Params: TPdfFilterParams): TBytes;

implementation

uses
  System.Classes, System.Math, System.ZLib;

type
  /// <summary>Growable output buffer with geometric growth.</summary>
  TPdfByteBuffer = record
  private
    FData: TBytes;
    FCount: Integer;
    procedure Grow(Extra: Integer);
  public
    procedure Init(InitialCapacity: Integer);
    procedure Add(B: Byte); inline;
    procedure AddBytes(const Src: TBytes; Start, Len: Integer);
    function ToBytes: TBytes;
    property Count: Integer read FCount;
  end;

{ TPdfByteBuffer }

procedure TPdfByteBuffer.Init(InitialCapacity: Integer);
begin
  FCount := 0;
  SetLength(FData, Max(InitialCapacity, 16));
end;

procedure TPdfByteBuffer.Grow(Extra: Integer);
var
  NewCap: Int64;
begin
  NewCap := Int64(Length(FData)) * 2;
  if NewCap < Int64(FCount) + Extra then
    NewCap := Int64(FCount) + Extra;
  if NewCap > MaxInt then
    NewCap := MaxInt;
  if NewCap < Int64(FCount) + Extra then
    raise EPdfFilterError.Create('Decoded stream too large');
  SetLength(FData, NewCap);
end;

procedure TPdfByteBuffer.Add(B: Byte);
begin
  if FCount >= Length(FData) then
    Grow(1);
  FData[FCount] := B;
  Inc(FCount);
end;

procedure TPdfByteBuffer.AddBytes(const Src: TBytes; Start, Len: Integer);
begin
  if Len <= 0 then
    Exit;
  if Int64(FCount) + Len > Length(FData) then
    Grow(Len);
  Move(Src[Start], FData[FCount], Len);
  Inc(FCount, Len);
end;

function TPdfByteBuffer.ToBytes: TBytes;
begin
  SetLength(FData, FCount);
  Result := FData;
  FData := nil;
  FCount := 0;
end;

{ TPdfFilterParams }

class function TPdfFilterParams.Default: TPdfFilterParams;
begin
  Result.Predictor := 1;
  Result.Colors := 1;
  Result.BitsPerComponent := 8;
  Result.Columns := 1;
  Result.EarlyChange := 1;
end;

{ Helpers }

/// True when the input contains at least one non-whitespace byte.
function HasContent(const Data: TBytes): Boolean;
var
  I: Integer;
begin
  for I := 0 to Integer(Length(Data)) - 1 do
    if not IsPdfWhitespace(Data[I]) then
      Exit(True);
  Result := False;
end;

{ FlateDecode }

/// Inflates Data starting at Offset. Clean is True when decoding ran to the
/// end (stream end or end of input) without a zlib error.
function InflateFrom(const Data: TBytes; Offset, WindowBits: Integer; out Clean: Boolean): TBytes;
const
  MaxCapacity = MaxInt - 16;
var
  Source: TBytesStream;
  Z: TZDecompressionStream;
  Buf: TBytes;
  Total, N: Integer;
  NewCap, Produced: Int64;
begin
  Clean := False;
  Total := 0;
  NewCap := Max(Int64(4096), (Int64(Length(Data)) - Offset) * 4);
  if NewCap > MaxCapacity then
    NewCap := MaxCapacity;
  SetLength(Buf, NewCap);
  Source := TBytesStream.Create(Data);
  try
    Source.Position := Offset;
    Z := nil;
    try
      try
        Z := TZDecompressionStream.Create(Source, WindowBits);
        repeat
          if Total >= Length(Buf) then
          begin
            if Length(Buf) >= MaxCapacity then
              Break;
            NewCap := Min(Int64(Length(Buf)) * 2, Int64(MaxCapacity));
            SetLength(Buf, NewCap);
          end;
          N := Z.Read(Buf[Total], Integer(Length(Buf)) - Total);
          Inc(Total, N);
        until N <= 0;
        Clean := True;
      except
        on EZLibError do
        begin
          // Keep whatever the failing Read call produced before the error:
          // Position reports the decompressor's total output.
          if Z <> nil then
          begin
            try
              Produced := Z.Position;
              if (Produced > Total) and (Produced <= Length(Buf)) then
                Total := Integer(Produced);
            except
              on EZLibError do
                ;
            end;
          end;
        end;
      end;
    finally
      Z.Free;
    end;
  finally
    Source.Free;
  end;
  SetLength(Buf, Total);
  Result := Buf;
end;

/// Plausible zlib header: deflate method, window <= 32K, valid check bits and
/// no preset dictionary.
function IsZlibHeader(CMF, FLG: Byte): Boolean;
begin
  Result := ((CMF and $0F) = 8) and ((CMF shr 4) <= 7) and
    ((((Integer(CMF) shl 8) or FLG) mod 31) = 0) and ((FLG and $20) = 0);
end;

function PdfFlateDecode(const Data: TBytes): TBytes;
const
  ScanLimit = 1024;
  MaxCandidates = 8;
var
  Len, Start, P, Candidates: Integer;
  Clean, AnyClean: Boolean;
begin
  Result := nil;
  Len := Integer(Length(Data));
  Start := 0;
  while (Start < Len) and IsPdfWhitespace(Data[Start]) do
    Inc(Start);
  if Start >= Len then
    Exit;
  AnyClean := False;
  // zlib-wrapped data, possibly preceded by garbage (as pdf.js tolerates).
  Candidates := 0;
  P := Start;
  while (P + 1 < Len) and (P - Start <= ScanLimit) and (Candidates < MaxCandidates) do
  begin
    if IsZlibHeader(Data[P], Data[P + 1]) then
    begin
      Inc(Candidates);
      Result := InflateFrom(Data, P, 15, Clean);
      if Length(Result) > 0 then
        Exit;
      AnyClean := AnyClean or Clean;
    end;
    Inc(P);
  end;
  // Fallback: raw deflate without zlib header.
  Result := InflateFrom(Data, Start, -15, Clean);
  if Length(Result) > 0 then
    Exit;
  AnyClean := AnyClean or Clean;
  if not AnyClean then
    raise EPdfFilterError.Create('FlateDecode: no decodable zlib/deflate data');
end;

{ LZWDecode }

function PdfLZWDecode(const Data: TBytes; EarlyChange: Integer): TBytes;
const
  ClearCode = 256;
  EodCode = 257;
  FirstCode = 258;
  TableSize = 4096;
var
  Values: TBytes;
  PrevCodes, Lengths: array of Integer;
  Sequence: TBytes;
  SeqLen, NextCode, CodeLength, PrevCode, Code, Early, I, J, Q, N: Integer;
  Pos, Len, BitCount: Integer;
  BitBuf: Cardinal;
  HasPrev, SawEod: Boolean;
  Output: TPdfByteBuffer;
begin
  Result := nil;
  Len := Integer(Length(Data));
  if Len = 0 then
    Exit;
  if EarlyChange <> 0 then
    Early := 1
  else
    Early := 0;
  SetLength(Values, TableSize);
  SetLength(PrevCodes, TableSize);
  SetLength(Lengths, TableSize);
  SetLength(Sequence, TableSize + 1);
  for I := 0 to 255 do
  begin
    Values[I] := Byte(I);
    PrevCodes[I] := -1;
    Lengths[I] := 1;
  end;
  Output.Init(Len * 3);
  NextCode := FirstCode;
  CodeLength := 9;
  PrevCode := 0;
  SeqLen := 0;
  Pos := 0;
  BitBuf := 0;
  BitCount := 0;
  SawEod := False;
  while True do
  begin
    // Read CodeLength bits, MSB first.
    while (BitCount < CodeLength) and (Pos < Len) do
    begin
      BitBuf := (BitBuf shl 8) or Data[Pos];
      Inc(Pos);
      Inc(BitCount, 8);
    end;
    if BitCount < CodeLength then
      Break; // end of data
    Code := Integer((BitBuf shr (BitCount - CodeLength)) and ((Cardinal(1) shl CodeLength) - 1));
    Dec(BitCount, CodeLength);
    BitBuf := BitBuf and ((Cardinal(1) shl BitCount) - 1);

    HasPrev := SeqLen > 0;
    if Code < 256 then
    begin
      Sequence[0] := Byte(Code);
      SeqLen := 1;
    end
    else if Code >= FirstCode then
    begin
      if Code < NextCode then
      begin
        SeqLen := Lengths[Code];
        Q := Code;
        for J := SeqLen - 1 downto 0 do
        begin
          Sequence[J] := Values[Q];
          Q := PrevCodes[Q];
        end;
      end
      else if HasPrev and (Code = NextCode) then
      begin
        // KwKwK: previous sequence followed by its own first byte.
        Sequence[SeqLen] := Sequence[0];
        Inc(SeqLen);
      end
      else
        Break; // invalid code: stop cleanly
    end
    else if Code = ClearCode then
    begin
      CodeLength := 9;
      NextCode := FirstCode;
      SeqLen := 0;
      Continue;
    end
    else
    begin
      SawEod := True; // EodCode
      Break;
    end;

    if HasPrev and (NextCode < TableSize) then
    begin
      PrevCodes[NextCode] := PrevCode;
      Lengths[NextCode] := Lengths[PrevCode] + 1;
      Values[NextCode] := Sequence[0];
      Inc(NextCode);
      N := NextCode + Early;
      if N >= 2048 then
        CodeLength := 12
      else if N >= 1024 then
        CodeLength := 11
      else if N >= 512 then
        CodeLength := 10
      else
        CodeLength := 9;
    end;
    // When the table is full the entries are frozen until a clear code
    // arrives (same effective behaviour as pdf.js).
    PrevCode := Code;
    Output.AddBytes(Sequence, 0, SeqLen);
  end;
  if (Output.Count = 0) and not SawEod then
    raise EPdfFilterError.Create('LZWDecode: no decodable data');
  Result := Output.ToBytes;
end;

{ ASCII85Decode }

function PdfASCII85Decode(const Data: TBytes): TBytes;
var
  Len, Pos, GroupLen, I: Integer;
  Group: array[0..4] of Byte;
  Value: UInt64;
  C: Byte;
  SawEod: Boolean;
  Output: TPdfByteBuffer;

  procedure FlushGroup(Count: Integer);
  var
    K: Integer;
    V: Cardinal;
  begin
    // Count characters (2..5); missing ones are padded with 'u'.
    for K := Count to 4 do
      Group[K] := 84;
    Value := 0;
    for K := 0 to 4 do
      Value := Value * 85 + Group[K];
    V := Cardinal(Value and $FFFFFFFF);
    for K := 0 to Count - 2 do
      Output.Add(Byte(V shr (24 - 8 * K)));
  end;

begin
  Result := nil;
  Len := Integer(Length(Data));
  if Len = 0 then
    Exit;
  Output.Init(Len);
  Pos := 0;
  while (Pos < Len) and IsPdfWhitespace(Data[Pos]) do
    Inc(Pos);
  if (Pos + 1 < Len) and (Data[Pos] = Ord('<')) and (Data[Pos + 1] = Ord('~')) then
    Inc(Pos, 2);
  GroupLen := 0;
  SawEod := False;
  while Pos < Len do
  begin
    C := Data[Pos];
    Inc(Pos);
    if C = Ord('~') then
    begin
      SawEod := True;
      Break;
    end
    else if (C = Ord('z')) and (GroupLen = 0) then
    begin
      for I := 1 to 4 do
        Output.Add(0);
    end
    else if (C >= Ord('!')) and (C <= Ord('u')) then
    begin
      Group[GroupLen] := Byte(C - Ord('!'));
      Inc(GroupLen);
      if GroupLen = 5 then
      begin
        FlushGroup(5);
        GroupLen := 0;
      end;
    end;
    // Whitespace and invalid characters are ignored.
  end;
  if GroupLen >= 2 then
    FlushGroup(GroupLen);
  if (Output.Count = 0) and not SawEod and HasContent(Data) then
    raise EPdfFilterError.Create('ASCII85Decode: no decodable data');
  Result := Output.ToBytes;
end;

{ ASCIIHexDecode }

function PdfASCIIHexDecode(const Data: TBytes): TBytes;
var
  Len, Pos, Digit, HighNibble: Integer;
  C: Byte;
  SawEod: Boolean;
  Output: TPdfByteBuffer;
begin
  Result := nil;
  Len := Integer(Length(Data));
  if Len = 0 then
    Exit;
  Output.Init(Len div 2 + 1);
  HighNibble := -1;
  SawEod := False;
  for Pos := 0 to Len - 1 do
  begin
    C := Data[Pos];
    if C = Ord('>') then
    begin
      SawEod := True;
      Break;
    end;
    Digit := PdfHexValue(C);
    if Digit < 0 then
      Continue; // whitespace and invalid characters are ignored
    if HighNibble < 0 then
      HighNibble := Digit
    else
    begin
      Output.Add(Byte((HighNibble shl 4) or Digit));
      HighNibble := -1;
    end;
  end;
  if HighNibble >= 0 then
    Output.Add(Byte(HighNibble shl 4)); // odd final digit is followed by an implied 0
  if (Output.Count = 0) and not SawEod and HasContent(Data) then
    raise EPdfFilterError.Create('ASCIIHexDecode: no decodable data');
  Result := Output.ToBytes;
end;

{ RunLengthDecode }

function PdfRunLengthDecode(const Data: TBytes): TBytes;
var
  Len, Pos, L, N, I: Integer;
  B: Byte;
  SawEod: Boolean;
  Output: TPdfByteBuffer;
begin
  Result := nil;
  Len := Integer(Length(Data));
  if Len = 0 then
    Exit;
  Output.Init(Len * 2);
  Pos := 0;
  SawEod := False;
  while Pos < Len do
  begin
    L := Data[Pos];
    Inc(Pos);
    if L = 128 then
    begin
      SawEod := True;
      Break;
    end
    else if L < 128 then
    begin
      N := Min(L + 1, Len - Pos); // truncated literal: copy what is there
      Output.AddBytes(Data, Pos, N);
      Inc(Pos, N);
    end
    else
    begin
      if Pos >= Len then
        Break;
      B := Data[Pos];
      Inc(Pos);
      for I := 1 to 257 - L do
        Output.Add(B);
    end;
  end;
  if (Output.Count = 0) and not SawEod then
    raise EPdfFilterError.Create('RunLengthDecode: no decodable data');
  Result := Output.ToBytes;
end;

{ Predictors }

function PngPredictor(const Data: TBytes; RowBytes, PixBytes: Integer): TBytes;
var
  Len, Pos, RowLen, I, A, B, C, P, PA, PB, PC: Integer;
  FilterType: Byte;
  PrevRow, Row: TBytes;
  Output: TPdfByteBuffer;
begin
  Len := Integer(Length(Data));
  Output.Init(Len);
  SetLength(PrevRow, RowBytes);
  SetLength(Row, RowBytes);
  FillChar(PrevRow[0], RowBytes, 0);
  Pos := 0;
  while Pos < Len do
  begin
    FilterType := Data[Pos];
    Inc(Pos);
    RowLen := Min(RowBytes, Len - Pos); // the last row may be truncated
    if RowLen <= 0 then
      Break;
    case FilterType of
      0: // None
        Move(Data[Pos], Row[0], RowLen);
      1: // Sub
        for I := 0 to RowLen - 1 do
          if I < PixBytes then
            Row[I] := Data[Pos + I]
          else
            Row[I] := Byte(Row[I - PixBytes] + Data[Pos + I]);
      2: // Up
        for I := 0 to RowLen - 1 do
          Row[I] := Byte(PrevRow[I] + Data[Pos + I]);
      3: // Average
        for I := 0 to RowLen - 1 do
          if I < PixBytes then
            Row[I] := Byte((PrevRow[I] shr 1) + Data[Pos + I])
          else
            Row[I] := Byte(((PrevRow[I] + Row[I - PixBytes]) shr 1) + Data[Pos + I]);
      4: // Paeth
        for I := 0 to RowLen - 1 do
        begin
          B := PrevRow[I];
          if I < PixBytes then
          begin
            A := 0;
            C := 0;
          end
          else
          begin
            A := Row[I - PixBytes];
            C := PrevRow[I - PixBytes];
          end;
          P := A + B - C;
          PA := Abs(P - A);
          PB := Abs(P - B);
          PC := Abs(P - C);
          if (PA <= PB) and (PA <= PC) then
            Row[I] := Byte(A + Data[Pos + I])
          else if PB <= PC then
            Row[I] := Byte(B + Data[Pos + I])
          else
            Row[I] := Byte(C + Data[Pos + I]);
        end;
    else
      Break; // unknown row filter type: stop with what was decoded so far
    end;
    Output.AddBytes(Row, 0, RowLen);
    Inc(Pos, RowLen);
    if RowLen < RowBytes then
      Break;
    Move(Row[0], PrevRow[0], RowBytes);
  end;
  if Output.Count = 0 then
    raise EPdfFilterError.Create('Predictor: invalid PNG row filter type');
  Result := Output.ToBytes;
end;

function TiffPredictor(const Data: TBytes; RowBytes, Colors, Bits, Columns: Integer): TBytes;
var
  Len, Pos, RowLen, Start, I, J, K, KK, Sum, BytesPerPixel: Integer;
  InBuf, OutBuf, InBits, OutBits, BitMask: Cardinal;
  CompArray: TArray<Cardinal>;
  C: Cardinal;
  Truncated: Boolean;
  Output: TBytes;
begin
  Len := Integer(Length(Data));
  SetLength(Output, Len);
  Pos := 0;
  while Pos < Len do
  begin
    RowLen := Min(RowBytes, Len - Pos);
    Start := Pos;
    if (Bits = 1) and (Colors = 1) then
    begin
      InBuf := 0;
      for I := 0 to RowLen - 1 do
      begin
        C := Data[Start + I] xor InBuf;
        C := C xor (C shr 1);
        C := C xor (C shr 2);
        C := C xor (C shr 4);
        InBuf := (C and 1) shl 7;
        Output[Start + I] := Byte(C);
      end;
    end
    else if Bits = 8 then
    begin
      for I := 0 to RowLen - 1 do
        if I < Colors then
          Output[Start + I] := Data[Start + I]
        else
          Output[Start + I] := Byte(Output[Start + I - Colors] + Data[Start + I]);
    end
    else if Bits = 16 then
    begin
      BytesPerPixel := Colors * 2;
      I := 0;
      while I < RowLen do
      begin
        if (I < BytesPerPixel) or (I + 1 >= RowLen) then
        begin
          Output[Start + I] := Data[Start + I];
          Inc(I);
        end
        else
        begin
          Sum := (Integer(Data[Start + I]) shl 8) + Data[Start + I + 1] +
            (Integer(Output[Start + I - BytesPerPixel]) shl 8) +
            Output[Start + I - BytesPerPixel + 1];
          Output[Start + I] := Byte(Sum shr 8);
          Output[Start + I + 1] := Byte(Sum);
          Inc(I, 2);
        end;
      end;
    end
    else
    begin
      // 1 (multi-component), 2 or 4 bits per component.
      SetLength(CompArray, Colors);
      for KK := 0 to Colors - 1 do
        CompArray[KK] := 0;
      BitMask := (Cardinal(1) shl Bits) - 1;
      InBuf := 0;
      OutBuf := 0;
      InBits := 0;
      OutBits := 0;
      J := 0;
      K := 0;
      Truncated := False;
      for I := 0 to Columns - 1 do
      begin
        for KK := 0 to Colors - 1 do
        begin
          if InBits < Cardinal(Bits) then
          begin
            if J >= RowLen then
            begin
              Truncated := True;
              Break;
            end;
            InBuf := ((InBuf shl 8) or Data[Start + J]) and $FFFF;
            Inc(J);
            Inc(InBits, 8);
          end;
          CompArray[KK] := (CompArray[KK] + (InBuf shr (InBits - Cardinal(Bits)))) and BitMask;
          Dec(InBits, Bits);
          OutBuf := ((OutBuf shl Bits) or CompArray[KK]) and $FFFF;
          Inc(OutBits, Bits);
          if OutBits >= 8 then
          begin
            if K < RowLen then
              Output[Start + K] := Byte(OutBuf shr (OutBits - 8));
            Inc(K);
            Dec(OutBits, 8);
          end;
        end;
        if Truncated then
          Break;
      end;
      if (OutBits > 0) and not Truncated and (K < RowLen) then
      begin
        Output[Start + K] := Byte((OutBuf shl (8 - OutBits)) +
          (InBuf and ((Cardinal(1) shl (8 - OutBits)) - 1)));
        Inc(K);
      end;
      // Bytes not produced (truncated row) are copied unchanged.
      for I := K to RowLen - 1 do
        Output[Start + I] := Data[Start + I];
    end;
    Inc(Pos, RowLen);
  end;
  Result := Output;
end;

function PdfApplyPredictor(const Data: TBytes; const Params: TPdfFilterParams): TBytes;
var
  Predictor, Colors, Bits, Columns: Integer;
  RowBytes, PixBytes: Int64;
begin
  Predictor := Params.Predictor;
  if (Predictor <= 1) or (Length(Data) = 0) then
    Exit(Data);
  Colors := Params.Colors;
  if Colors <= 0 then
    Colors := 1;
  Bits := Params.BitsPerComponent;
  if Bits <= 0 then
    Bits := 8;
  Columns := Params.Columns;
  if Columns <= 0 then
    Columns := 1;
  PixBytes := (Int64(Colors) * Bits + 7) div 8;
  RowBytes := (Int64(Colors) * Bits * Columns + 7) div 8;
  if (RowBytes <= 0) or (RowBytes > MaxInt div 2) or (PixBytes > RowBytes) then
    Exit(Data);
  if Predictor = 2 then
  begin
    if not (Bits in [1, 2, 4, 8, 16]) then
      Exit(Data);
    Result := TiffPredictor(Data, Integer(RowBytes), Colors, Bits, Columns);
  end
  else if Predictor >= 10 then
    Result := PngPredictor(Data, Integer(RowBytes), Integer(PixBytes))
  else
    Result := Data; // unsupported predictor value: pass through
end;

{ Filter names }

function StripSlash(const Name: string): string;
begin
  if (Name <> '') and (Name[1] = '/') then
    Result := Copy(Name, 2, MaxInt)
  else
    Result := Name;
end;

function PdfNormalizeFilterName(const Name: string): string;
begin
  Result := StripSlash(Name);
  if Result = 'Fl' then
    Result := 'FlateDecode'
  else if Result = 'LZW' then
    Result := 'LZWDecode'
  else if Result = 'A85' then
    Result := 'ASCII85Decode'
  else if Result = 'AHx' then
    Result := 'ASCIIHexDecode'
  else if Result = 'RL' then
    Result := 'RunLengthDecode'
  else if Result = 'CCF' then
    Result := 'CCITTFaxDecode'
  else if Result = 'DCT' then
    Result := 'DCTDecode';
end;

function PdfIsImageFilter(const Name: string): Boolean;
var
  N: string;
begin
  N := PdfNormalizeFilterName(Name);
  Result := (N = 'DCTDecode') or (N = 'JPXDecode') or (N = 'JBIG2Decode') or
    (N = 'CCITTFaxDecode');
end;

function PdfApplyFilter(const Name: string; const Data: TBytes; const Params: TPdfFilterParams): TBytes;
var
  N: string;
begin
  N := PdfNormalizeFilterName(Name);
  if N = 'FlateDecode' then
    Result := PdfApplyPredictor(PdfFlateDecode(Data), Params)
  else if N = 'LZWDecode' then
    Result := PdfApplyPredictor(PdfLZWDecode(Data, Params.EarlyChange), Params)
  else if N = 'ASCII85Decode' then
    Result := PdfASCII85Decode(Data)
  else if N = 'ASCIIHexDecode' then
    Result := PdfASCIIHexDecode(Data)
  else if N = 'RunLengthDecode' then
    Result := PdfRunLengthDecode(Data)
  else if N = 'Crypt' then
    Result := Data
  else if PdfIsImageFilter(N) then
    raise EPdfFilterError.CreateFmt('%s is an image filter and must be decoded by the renderer', [N])
  else
    raise EPdfFilterError.CreateFmt('Unsupported filter: %s', [Name]);
end;

end.
