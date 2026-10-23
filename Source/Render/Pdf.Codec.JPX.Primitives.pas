{*******************************************************************************
  Pdf.Codec.JPX.Primitives
  Building blocks of the JPEG 2000 decoder in Pdf.Codec.JPX, exposed so the unit
  tests can exercise them directly:
  - TJpxMQDecoder: the MQ arithmetic decoder (ITU-T T.800 Annex C.3);
  - TJpxPacketBitReader: the bit reader of packet headers (bit stuffing after 0xFF);
  - TJpxTagTree: tag trees (T.800 B.10.2) for code-block inclusion and zero bit-planes;
  - JpxInverseTransform: the inverse 5/3 and 9/7 discrete wavelet transforms (Annex F).

  Ported from pdf.js src/core/arithmetic_decoder.js and src/core/jpx.js
  (Copyright 2012 Mozilla Foundation, Apache License 2.0; see NOTICE). The tag
  tree follows the standard algorithm (as in OpenJPEG) instead of the pdf.js
  InclusionTree/TagTree pair, which mis-reads inclusion after empty packets.
  This copy of the MQ decoder is private to the JPX decoder on purpose.
*******************************************************************************}
unit Pdf.Codec.JPX.Primitives;

interface

uses
  System.SysUtils, Pdf.Core.Types;

type
  /// <summary>MQ arithmetic decoder (T.800 C.3). Contexts are single bytes holding (index shl 1) or mps.</summary>
  TJpxMQDecoder = record
  private
    FData: TBytes;
    FBp, FEnd: Integer;
    FCHigh, FCLow, FCT, FA: Integer;
    function ByteAt(Index: Integer): Integer; inline;
    procedure ByteIn;
  public
    /// <summary>INITDEC over Data[Start..Finish). Bytes past Finish read as 0xFF00 padding (as pdf.js).</summary>
    procedure Init(const Data: TBytes; Start, Finish: Integer);
    /// <summary>DECODE: one binary decision with the context byte Cx (updated in place).</summary>
    function ReadBit(Cx: PByte): Integer;
  end;

  /// <summary>Bit reader for packet headers (T.800 B.10.1): after a 0xFF byte only 7 bits of the next byte are
  /// used. Reads past the end of the buffer return zero bits.</summary>
  TJpxPacketBitReader = record
  private
    FData: TBytes;
    FBuffer: UInt64;
    FBufferSize: Integer;
    FSkipNextBit: Boolean;
  public
    /// <summary>Absolute start offset of the data in Data.</summary>
    Offset: Integer;
    /// <summary>Read position relative to Offset.</summary>
    Position: Integer;
    procedure Init(const Data: TBytes; AOffset: Integer);
    function ByteAt(Index: Integer): Integer; inline;
    /// <summary>Reads Count (0..32) bits, most significant first.</summary>
    function ReadBits(Count: Integer): Cardinal;
    function ReadBit: Integer; inline;
    /// <summary>Drops the remaining bits of the current byte (and the stuffed byte after 0xFF).</summary>
    procedure AlignToByte;
    /// <summary>Skips a 0xFF,Value marker at (or just before) the read position; True when found.</summary>
    function SkipMarkerIfEqual(Value: Byte): Boolean;
    procedure SkipBytes(Count: Integer); inline;
  end;

  /// <summary>Tag tree (T.800 B.10.2) of Width x Height leaves with the decoding procedure of B.10.2
  /// (node values start at "infinity", the lower bounds at 0).</summary>
  TJpxTagTree = class
  private
    type
      TNode = record
        Value, Low, Parent: Integer;
      end;
  private
    FWidth, FHeight: Integer;
    FNodes: TArray<TNode>;
  public
    constructor Create(Width, Height: Integer);
    /// <summary>Decodes leaf (I, J) up to Threshold. Returns True when the leaf value is below Threshold.</summary>
    function Decode(var Reader: TJpxPacketBitReader; I, J, Threshold: Integer): Boolean;
    /// <summary>Value of leaf (I, J) once decoded (a large number while unknown).</summary>
    function LeafValue(I, J: Integer): Integer;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
  end;

  /// <summary>A rectangular band of wavelet coefficients (row-major).</summary>
  TJpxBand = record
    Width, Height: Integer;
    Items: TArray<Single>;
  end;

/// <summary>Inverse DWT (T.800 F.3) as in pdf.js Transform.calculate. Levels[0] is the LL band of the lowest
/// resolution; every following entry has the size of the next resolution level and holds its HL, LH and HH
/// coefficients already interleaved (HL at odd columns/even rows, LH at even columns/odd rows, HH at odd/odd); the
/// even/even positions are filled with the previous result here. The Items arrays are modified in place.
/// U0/V0: origin of the tile-component (only its parity matters for 1-sample-wide levels).</summary>
function JpxInverseTransform(const Levels: TArray<TJpxBand>; Reversible: Boolean; U0, V0: Integer): TJpxBand;

/// <summary>Floor of log2(X) for X >= 1 (0 for X <= 1).</summary>
function JpxFloorLog2(X: Cardinal): Integer;
/// <summary>Ceil of log2(X) for X >= 1 (0 for X <= 1), like pdf.js core_utils log2.</summary>
function JpxCeilLog2(X: Cardinal): Integer;

implementation

{$R-}{$Q-}

type
  TQe = record
    Qe: Integer;
    NMPS, NLPS, Switch: Byte;
  end;

const
  // Table C.2
  QeTable: array[0..46] of TQe = (
    (Qe: $5601; NMPS: 1; NLPS: 1; Switch: 1), (Qe: $3401; NMPS: 2; NLPS: 6; Switch: 0),
    (Qe: $1801; NMPS: 3; NLPS: 9; Switch: 0), (Qe: $0AC1; NMPS: 4; NLPS: 12; Switch: 0),
    (Qe: $0521; NMPS: 5; NLPS: 29; Switch: 0), (Qe: $0221; NMPS: 38; NLPS: 33; Switch: 0),
    (Qe: $5601; NMPS: 7; NLPS: 6; Switch: 1), (Qe: $5401; NMPS: 8; NLPS: 14; Switch: 0),
    (Qe: $4801; NMPS: 9; NLPS: 14; Switch: 0), (Qe: $3801; NMPS: 10; NLPS: 14; Switch: 0),
    (Qe: $3001; NMPS: 11; NLPS: 17; Switch: 0), (Qe: $2401; NMPS: 12; NLPS: 18; Switch: 0),
    (Qe: $1C01; NMPS: 13; NLPS: 20; Switch: 0), (Qe: $1601; NMPS: 29; NLPS: 21; Switch: 0),
    (Qe: $5601; NMPS: 15; NLPS: 14; Switch: 1), (Qe: $5401; NMPS: 16; NLPS: 14; Switch: 0),
    (Qe: $5101; NMPS: 17; NLPS: 15; Switch: 0), (Qe: $4801; NMPS: 18; NLPS: 16; Switch: 0),
    (Qe: $3801; NMPS: 19; NLPS: 17; Switch: 0), (Qe: $3401; NMPS: 20; NLPS: 18; Switch: 0),
    (Qe: $3001; NMPS: 21; NLPS: 19; Switch: 0), (Qe: $2801; NMPS: 22; NLPS: 19; Switch: 0),
    (Qe: $2401; NMPS: 23; NLPS: 20; Switch: 0), (Qe: $2201; NMPS: 24; NLPS: 21; Switch: 0),
    (Qe: $1C01; NMPS: 25; NLPS: 22; Switch: 0), (Qe: $1801; NMPS: 26; NLPS: 23; Switch: 0),
    (Qe: $1601; NMPS: 27; NLPS: 24; Switch: 0), (Qe: $1401; NMPS: 28; NLPS: 25; Switch: 0),
    (Qe: $1201; NMPS: 29; NLPS: 26; Switch: 0), (Qe: $1101; NMPS: 30; NLPS: 27; Switch: 0),
    (Qe: $0AC1; NMPS: 31; NLPS: 28; Switch: 0), (Qe: $09C1; NMPS: 32; NLPS: 29; Switch: 0),
    (Qe: $08A1; NMPS: 33; NLPS: 30; Switch: 0), (Qe: $0521; NMPS: 34; NLPS: 31; Switch: 0),
    (Qe: $0441; NMPS: 35; NLPS: 32; Switch: 0), (Qe: $02A1; NMPS: 36; NLPS: 33; Switch: 0),
    (Qe: $0221; NMPS: 37; NLPS: 34; Switch: 0), (Qe: $0141; NMPS: 38; NLPS: 35; Switch: 0),
    (Qe: $0111; NMPS: 39; NLPS: 36; Switch: 0), (Qe: $0085; NMPS: 40; NLPS: 37; Switch: 0),
    (Qe: $0049; NMPS: 41; NLPS: 38; Switch: 0), (Qe: $0025; NMPS: 42; NLPS: 39; Switch: 0),
    (Qe: $0015; NMPS: 43; NLPS: 40; Switch: 0), (Qe: $0009; NMPS: 44; NLPS: 41; Switch: 0),
    (Qe: $0005; NMPS: 45; NLPS: 42; Switch: 0), (Qe: $0001; NMPS: 45; NLPS: 43; Switch: 0),
    (Qe: $5601; NMPS: 46; NLPS: 46; Switch: 0));

function JpxFloorLog2(X: Cardinal): Integer;
begin
  Result := 0;
  while X > 1 do
  begin
    X := X shr 1;
    Inc(Result);
  end;
end;

function JpxCeilLog2(X: Cardinal): Integer;
begin
  if X <= 1 then
    Exit(0);
  Result := JpxFloorLog2(X - 1) + 1;
end;

{ TJpxMQDecoder }

function TJpxMQDecoder.ByteAt(Index: Integer): Integer;
begin
  // pdf.js reads `undefined` (0 in the bit operations) outside its typed array
  if (Index >= 0) and (Index < Length(FData)) then
    Result := FData[Index]
  else
    Result := 0;
end;

procedure TJpxMQDecoder.Init(const Data: TBytes; Start, Finish: Integer);
begin
  FData := Data;
  FBp := Start;
  if Finish > Length(Data) then
    Finish := Length(Data);
  FEnd := Finish;
  FCHigh := ByteAt(Start);
  FCLow := 0;
  ByteIn;
  FCHigh := ((FCHigh shl 7) and $FFFF) or ((FCLow shr 9) and $7F);
  FCLow := (FCLow shl 7) and $FFFF;
  Dec(FCT, 7);
  FA := $8000;
end;

procedure TJpxMQDecoder.ByteIn;
var
  Bp: Integer;
begin
  // C.3.4 BYTEIN
  Bp := FBp;
  if ByteAt(Bp) = $FF then
  begin
    if ByteAt(Bp + 1) > $8F then
    begin
      Inc(FCLow, $FF00);
      FCT := 8;
    end
    else
    begin
      Inc(Bp);
      Inc(FCLow, ByteAt(Bp) shl 9);
      FCT := 7;
      FBp := Bp;
    end;
  end
  else
  begin
    Inc(Bp);
    if Bp < FEnd then
      Inc(FCLow, ByteAt(Bp) shl 8)
    else
      Inc(FCLow, $FF00);
    FCT := 8;
    FBp := Bp;
  end;
  if FCLow > $FFFF then
  begin
    Inc(FCHigh, FCLow shr 16);
    FCLow := FCLow and $FFFF;
  end;
end;

function TJpxMQDecoder.ReadBit(Cx: PByte): Integer;
var
  Index, Mps, Qe, A: Integer;
  Q: ^TQe;
begin
  // C.3.2 DECODE
  Index := Cx^ shr 1;
  Mps := Cx^ and 1;
  if Index > 46 then
    Index := 46;
  Q := @QeTable[Index];
  Qe := Q.Qe;
  A := FA - Qe;
  if FCHigh < Qe then
  begin
    // exchangeLps
    if A < Qe then
    begin
      A := Qe;
      Result := Mps;
      Index := Q.NMPS;
    end
    else
    begin
      A := Qe;
      Result := 1 xor Mps;
      if Q.Switch = 1 then
        Mps := Result;
      Index := Q.NLPS;
    end;
  end
  else
  begin
    Dec(FCHigh, Qe);
    if (A and $8000) <> 0 then
    begin
      FA := A;
      Exit(Mps);
    end;
    // exchangeMps
    if A < Qe then
    begin
      Result := 1 xor Mps;
      if Q.Switch = 1 then
        Mps := Result;
      Index := Q.NLPS;
    end
    else
    begin
      Result := Mps;
      Index := Q.NMPS;
    end;
  end;
  // C.3.3 RENORMD
  repeat
    if FCT = 0 then
      ByteIn;
    A := A shl 1;
    FCHigh := ((FCHigh shl 1) and $FFFF) or ((FCLow shr 15) and 1);
    FCLow := (FCLow shl 1) and $FFFF;
    Dec(FCT);
  until (A and $8000) <> 0;
  FA := A;
  Cx^ := Byte((Index shl 1) or Mps);
end;

{ TJpxPacketBitReader }

procedure TJpxPacketBitReader.Init(const Data: TBytes; AOffset: Integer);
begin
  FData := Data;
  Offset := AOffset;
  Position := 0;
  FBuffer := 0;
  FBufferSize := 0;
  FSkipNextBit := False;
end;

function TJpxPacketBitReader.ByteAt(Index: Integer): Integer;
begin
  if (Index >= 0) and (Index < Length(FData)) then
    Result := FData[Index]
  else
    Result := 0;
end;

function TJpxPacketBitReader.ReadBits(Count: Integer): Cardinal;
var
  B: Integer;
begin
  if (Count < 0) or (Count > 32) then
    raise EPdfFilterError.Create('JPX: invalid packet header bit count');
  while FBufferSize < Count do
  begin
    B := ByteAt(Offset + Position);
    Inc(Position);
    if FSkipNextBit then
    begin
      FBuffer := (FBuffer shl 7) or UInt64(B and $7F);
      Inc(FBufferSize, 7);
      FSkipNextBit := False;
    end
    else
    begin
      FBuffer := (FBuffer shl 8) or UInt64(B);
      Inc(FBufferSize, 8);
    end;
    if B = $FF then
      FSkipNextBit := True;
  end;
  Dec(FBufferSize, Count);
  Result := Cardinal((FBuffer shr FBufferSize) and ((UInt64(1) shl Count) - 1));
end;

function TJpxPacketBitReader.ReadBit: Integer;
begin
  Result := Integer(ReadBits(1));
end;

procedure TJpxPacketBitReader.AlignToByte;
begin
  FBufferSize := 0;
  if FSkipNextBit then
  begin
    Inc(Position);
    FSkipNextBit := False;
  end;
end;

function TJpxPacketBitReader.SkipMarkerIfEqual(Value: Byte): Boolean;
begin
  if (ByteAt(Offset + Position - 1) = $FF) and (ByteAt(Offset + Position) = Value) then
  begin
    SkipBytes(1);
    Result := True;
  end
  else if (ByteAt(Offset + Position) = $FF) and (ByteAt(Offset + Position + 1) = Value) then
  begin
    SkipBytes(2);
    Result := True;
  end
  else
    Result := False;
end;

procedure TJpxPacketBitReader.SkipBytes(Count: Integer);
begin
  Inc(Position, Count);
end;

{ TJpxTagTree }

constructor TJpxTagTree.Create(Width, Height: Integer);
var
  W, H, Total, Base, NextBase, I, J: Integer;
  LevelW, LevelH: TArray<Integer>;
  Bases: TArray<Integer>;
  Levels, L: Integer;
begin
  inherited Create;
  if Width < 1 then
    Width := 1;
  if Height < 1 then
    Height := 1;
  FWidth := Width;
  FHeight := Height;
  // Same level count as pdf.js: log2(max(w, h)) + 1
  if Width > Height then
    Levels := JpxCeilLog2(Cardinal(Width)) + 1
  else
    Levels := JpxCeilLog2(Cardinal(Height)) + 1;
  SetLength(LevelW, Levels);
  SetLength(LevelH, Levels);
  SetLength(Bases, Levels);
  W := Width;
  H := Height;
  Total := 0;
  for L := 0 to Levels - 1 do
  begin
    LevelW[L] := W;
    LevelH[L] := H;
    Bases[L] := Total;
    Inc(Total, W * H);
    W := (W + 1) div 2;
    H := (H + 1) div 2;
  end;
  SetLength(FNodes, Total);
  for L := 0 to Levels - 1 do
  begin
    Base := Bases[L];
    if L + 1 < Levels then
      NextBase := Bases[L + 1]
    else
      NextBase := -1;
    for J := 0 to LevelH[L] - 1 do
      for I := 0 to LevelW[L] - 1 do
      begin
        FNodes[Base + J * LevelW[L] + I].Value := MaxInt;
        FNodes[Base + J * LevelW[L] + I].Low := 0;
        if NextBase >= 0 then
          FNodes[Base + J * LevelW[L] + I].Parent := NextBase + (J shr 1) * LevelW[L + 1] + (I shr 1)
        else
          FNodes[Base + J * LevelW[L] + I].Parent := -1;
      end;
  end;
end;

function TJpxTagTree.Decode(var Reader: TJpxPacketBitReader; I, J, Threshold: Integer): Boolean;
var
  Stack: array[0..63] of Integer;
  Depth, Node, Low: Integer;
begin
  if (I < 0) or (J < 0) or (I >= FWidth) or (J >= FHeight) then
    raise EPdfFilterError.Create('JPX: tag tree index out of range');
  Depth := 0;
  Node := J * FWidth + I;
  while FNodes[Node].Parent >= 0 do
  begin
    Stack[Depth] := Node;
    Inc(Depth);
    Node := FNodes[Node].Parent;
  end;
  Low := 0;
  while True do
  begin
    if Low > FNodes[Node].Low then
      FNodes[Node].Low := Low
    else
      Low := FNodes[Node].Low;
    while (Low < Threshold) and (Low < FNodes[Node].Value) do
    begin
      if Reader.ReadBit <> 0 then
        FNodes[Node].Value := Low
      else
        Inc(Low);
    end;
    FNodes[Node].Low := Low;
    if Depth = 0 then
      Break;
    Dec(Depth);
    Node := Stack[Depth];
  end;
  Result := FNodes[Node].Value < Threshold;
end;

function TJpxTagTree.LeafValue(I, J: Integer): Integer;
begin
  if (I < 0) or (J < 0) or (I >= FWidth) or (J >= FHeight) then
    Exit(MaxInt);
  Result := FNodes[J * FWidth + I].Value;
end;

{ Wavelet transforms }

const
  BufferPadding = 4;

/// Section F.3.7: symmetric extension by up to 4 samples on each side.
procedure Extend(Buffer: PSingle; Offset, Size: Integer);
type
  TSingles = array[0..MaxInt div SizeOf(Single) - 1] of Single;
var
  B: ^TSingles;
  I1, J1, I2, J2: Integer;
begin
  B := Pointer(Buffer);
  I1 := Offset - 1;
  J1 := Offset + 1;
  I2 := Offset + Size - 2;
  J2 := Offset + Size;
  B[I1] := B[J1]; Dec(I1); Inc(J1);
  B[J2] := B[I2]; Inc(J2); Dec(I2);
  B[I1] := B[J1]; Dec(I1); Inc(J1);
  B[J2] := B[I2]; Inc(J2); Dec(I2);
  B[I1] := B[J1]; Dec(I1); Inc(J1);
  B[J2] := B[I2]; Inc(J2); Dec(I2);
  B[I1] := B[J1];
  B[J2] := B[I2];
end;

function Sar(X, N: Integer): Integer; inline;
begin
  if X >= 0 then
    Result := X shr N
  else
    Result := not ((not X) shr N);
end;

/// Section F.3.8.1: reversible 5-3 synthesis (in place, even positions are low-pass).
procedure Filter53(Buffer: PSingle; Offset, Length: Integer);
type
  TSingles = array[0..MaxInt div SizeOf(Single) - 1] of Single;
var
  X: ^TSingles;
  Len, J, N: Integer;
begin
  X := Pointer(Buffer);
  Len := Length shr 1;
  J := Offset;
  for N := 0 to Len do
  begin
    X[J] := X[J] - Sar(Trunc(X[J - 1] + X[J + 1] + 2), 2);
    Inc(J, 2);
  end;
  J := Offset + 1;
  for N := 1 to Len do
  begin
    X[J] := X[J] + Sar(Trunc(X[J - 1] + X[J + 1]), 1);
    Inc(J, 2);
  end;
end;

/// Section F.3.8.2: irreversible 9-7 synthesis (in place).
procedure Filter97(Buffer: PSingle; Offset, Length: Integer);
type
  TSingles = array[0..MaxInt div SizeOf(Single) - 1] of Single;
const
  Alpha = -1.586134342059924;
  Beta = -0.052980118572961;
  Gamma = 0.882911075530934;
  Delta = 0.443506852043971;
  K = 1.230174104914001;
  K_ = 1 / K;
var
  X: ^TSingles;
  Len, J, N: Integer;
begin
  X := Pointer(Buffer);
  Len := Length shr 1;
  // step 2 (step 1 is combined with step 3)
  J := Offset - 3;
  for N := 1 to Len + 4 do
  begin
    X[J] := X[J] * K_;
    Inc(J, 2);
  end;
  // step 1 & 3
  J := Offset - 2;
  for N := 1 to Len + 3 do
  begin
    X[J] := K * X[J] - Delta * X[J - 1] - Delta * X[J + 1];
    Inc(J, 2);
  end;
  // step 4
  J := Offset - 1;
  for N := 1 to Len + 2 do
  begin
    X[J] := X[J] - (Gamma * X[J - 1] + Gamma * X[J + 1]);
    Inc(J, 2);
  end;
  // step 5
  J := Offset;
  for N := 1 to Len + 1 do
  begin
    X[J] := X[J] - (Beta * X[J - 1] + Beta * X[J + 1]);
    Inc(J, 2);
  end;
  // step 6
  J := Offset + 1;
  for N := 1 to Len do
  begin
    X[J] := X[J] - (Alpha * X[J - 1] + Alpha * X[J + 1]);
    Inc(J, 2);
  end;
end;

procedure Filter(Reversible: Boolean; Buffer: PSingle; Offset, Length: Integer); inline;
begin
  if Reversible then
    Filter53(Buffer, Offset, Length)
  else
    Filter97(Buffer, Offset, Length);
end;

function Iterate(const LL: TJpxBand; const Band: TJpxBand; Reversible: Boolean; U0, V0: Integer): TJpxBand;
const
  MaxBuffers = 16;
var
  Width, Height, LLWidth, LLHeight, Count: Integer;
  Items: TArray<Single>;
  I, J, K, L, U, V, B, NumBuffers, CurrentBuffer, LLEnd: Integer;
  RowBuffer: TArray<Single>;
  ColBuffers: array[0..MaxBuffers - 1] of TArray<Single>;
begin
  Width := Band.Width;
  Height := Band.Height;
  Items := Band.Items;
  Count := Width * Height;
  if Length(Items) < Count then
    SetLength(Items, Count);
  LLWidth := LL.Width;
  LLHeight := LL.Height;
  // Interleave LL according to Section F.3.3
  K := 0;
  for I := 0 to LLHeight - 1 do
  begin
    L := I * 2 * Width;
    for J := 0 to LLWidth - 1 do
    begin
      if (L < Count) and (K < Length(LL.Items)) then
        Items[L] := LL.Items[K];
      Inc(K);
      Inc(L, 2);
    end;
  end;
  Result.Width := Width;
  Result.Height := Height;
  Result.Items := Items;
  if Count = 0 then
    Exit;

  // Section F.3.4 HOR_SR
  if Width = 1 then
  begin
    // if width = 1, when u0 even keep items as is, when odd divide by 2
    if (U0 and 1) <> 0 then
    begin
      K := 0;
      for V := 0 to Height - 1 do
      begin
        Items[K] := Items[K] * 0.5;
        Inc(K, Width);
      end;
    end;
  end
  else
  begin
    SetLength(RowBuffer, Width + 2 * BufferPadding);
    K := 0;
    for V := 0 to Height - 1 do
    begin
      Move(Items[K], RowBuffer[BufferPadding], Width * SizeOf(Single));
      Extend(@RowBuffer[0], BufferPadding, Width);
      Filter(Reversible, @RowBuffer[0], BufferPadding, Width);
      Move(RowBuffer[BufferPadding], Items[K], Width * SizeOf(Single));
      Inc(K, Width);
    end;
  end;

  // Section F.3.5 VER_SR, several columns at once to reduce cache misses
  if Height = 1 then
  begin
    if (V0 and 1) <> 0 then
      for U := 0 to Width - 1 do
        Items[U] := Items[U] * 0.5;
  end
  else
  begin
    NumBuffers := MaxBuffers;
    for I := 0 to MaxBuffers - 1 do
      SetLength(ColBuffers[I], Height + 2 * BufferPadding);
    CurrentBuffer := 0;
    LLEnd := BufferPadding + Height;
    for U := 0 to Width - 1 do
    begin
      // if we ran out of buffers, copy several image columns at once
      if CurrentBuffer = 0 then
      begin
        if Width - U < NumBuffers then
          NumBuffers := Width - U;
        K := U;
        for L := BufferPadding to LLEnd - 1 do
        begin
          for B := 0 to NumBuffers - 1 do
            ColBuffers[B][L] := Items[K + B];
          Inc(K, Width);
        end;
        CurrentBuffer := NumBuffers;
      end;
      Dec(CurrentBuffer);
      Extend(@ColBuffers[CurrentBuffer][0], BufferPadding, Height);
      Filter(Reversible, @ColBuffers[CurrentBuffer][0], BufferPadding, Height);
      // If this is last buffer in this group of buffers, flush all buffers.
      if CurrentBuffer = 0 then
      begin
        K := U - NumBuffers + 1;
        for L := BufferPadding to LLEnd - 1 do
        begin
          for B := 0 to NumBuffers - 1 do
            Items[K + B] := ColBuffers[B][L];
          Inc(K, Width);
        end;
      end;
    end;
  end;
end;

function JpxInverseTransform(const Levels: TArray<TJpxBand>; Reversible: Boolean; U0, V0: Integer): TJpxBand;
var
  I: Integer;
begin
  if Length(Levels) = 0 then
  begin
    Result.Width := 0;
    Result.Height := 0;
    Result.Items := nil;
    Exit;
  end;
  Result := Levels[0];
  for I := 1 to High(Levels) do
    Result := Iterate(Result, Levels[I], Reversible, U0, V0);
end;

end.
