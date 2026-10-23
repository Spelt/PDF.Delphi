{*******************************************************************************
  Pdf.Codec.JBIG2.Arith
  MQ arithmetic decoder (ITU-T T.88 Annex E, T.800 Annex C.3) and the JBIG2
  arithmetic integer decoding procedures (T.88 Annex A).
  Ported from pdf.js (src/core/arithmetic_decoder.js and jbig2.js,
  Apache License 2.0, see NOTICE).
*******************************************************************************}
unit Pdf.Codec.JBIG2.Arith;

interface

uses
  System.SysUtils;

type
  /// <summary>Raised internally for corrupt or unsupported JBIG2 data; the
  /// public decoder catches it and returns what was decoded so far.</summary>
  EJBig2Error = class(Exception);

  /// <summary>Context states of one decoding procedure: one byte per context,
  /// holding (Qe table index shl 1) or MPS. A zeroed array is the initial state.</summary>
  TJBig2ContextArray = TBytes;

  /// <summary>MQ arithmetic decoder over Data[Start..Finish). Reading past the
  /// end behaves as if the data were followed by 0xFF bytes (spec behaviour).</summary>
  TJBig2ArithDecoder = class
  private
    FData: TBytes;
    FPos: Integer;
    FEnd: Integer;
    FCHigh: Integer;
    FCLow: Integer;
    FCT: Integer;
    FA: Integer;
    FOverrun: Integer;
    function ByteAt(Index: Integer): Integer; inline;
    procedure ByteIn;
  public
    /// <summary>INITDEC: starts decoding at Data[Start]; Finish is exclusive.</summary>
    constructor Create(const Data: TBytes; Start, Finish: Integer);
    /// <summary>DECODE: decodes one decision with context Contexts[Pos] and updates the context.</summary>
    function ReadBit(const Contexts: TJBig2ContextArray; Pos: Integer): Integer;
    /// <summary>Current byte position of the decoder in the data.</summary>
    property Position: Integer read FPos;
  end;

  /// <summary>Arithmetic integer decoding procedures of Annex A.2 (IADH ... IARDY).</summary>
  TJBig2IntProc = (ipIADH, ipIADW, ipIAEX, ipIAAI, ipIADT, ipIAFS, ipIADS, ipIAIT, ipIARI,
    ipIARDW, ipIARDH, ipIARDX, ipIARDY);

  /// <summary>All arithmetic coding contexts used while decoding one segment.</summary>
  TJBig2Contexts = class
  public
    /// <summary>Contexts of the integer procedures (512 entries each).</summary>
    IntCtx: array[TJBig2IntProc] of TJBig2ContextArray;
    /// <summary>Contexts of the IAID procedure, sized by EnsureIAID.</summary>
    IAID: TJBig2ContextArray;
    /// <summary>Generic region contexts (16 bit context labels).</summary>
    GB: TJBig2ContextArray;
    /// <summary>Generic refinement region contexts (13 bit context labels).</summary>
    GR: TJBig2ContextArray;
    constructor Create;
    /// <summary>Makes IAID large enough for symbol codes of CodeLength bits.</summary>
    procedure EnsureIAID(CodeLength: Integer);
  end;

/// <summary>A.2: decodes a signed integer. Returns False for OOB (or a value out of the Int32 range).</summary>
function JBig2DecodeInteger(Decoder: TJBig2ArithDecoder; const Contexts: TJBig2ContextArray;
  out Value: Integer): Boolean;
/// <summary>A.3: decodes a symbol ID of CodeLength bits (the IAID procedure).</summary>
function JBig2DecodeIAID(Decoder: TJBig2ArithDecoder; Contexts: TJBig2Contexts; CodeLength: Integer): Integer;

implementation

type
  TQe = record
    Qe: Integer;
    NMps: Byte;
    NLps: Byte;
    Switch: Byte;
  end;

const
  // Table E.1 (T.88) / C.2 (T.800)
  QeTable: array[0..46] of TQe = (
    (Qe: $5601; NMps: 1; NLps: 1; Switch: 1),
    (Qe: $3401; NMps: 2; NLps: 6; Switch: 0),
    (Qe: $1801; NMps: 3; NLps: 9; Switch: 0),
    (Qe: $0AC1; NMps: 4; NLps: 12; Switch: 0),
    (Qe: $0521; NMps: 5; NLps: 29; Switch: 0),
    (Qe: $0221; NMps: 38; NLps: 33; Switch: 0),
    (Qe: $5601; NMps: 7; NLps: 6; Switch: 1),
    (Qe: $5401; NMps: 8; NLps: 14; Switch: 0),
    (Qe: $4801; NMps: 9; NLps: 14; Switch: 0),
    (Qe: $3801; NMps: 10; NLps: 14; Switch: 0),
    (Qe: $3001; NMps: 11; NLps: 17; Switch: 0),
    (Qe: $2401; NMps: 12; NLps: 18; Switch: 0),
    (Qe: $1C01; NMps: 13; NLps: 20; Switch: 0),
    (Qe: $1601; NMps: 29; NLps: 21; Switch: 0),
    (Qe: $5601; NMps: 15; NLps: 14; Switch: 1),
    (Qe: $5401; NMps: 16; NLps: 14; Switch: 0),
    (Qe: $5101; NMps: 17; NLps: 15; Switch: 0),
    (Qe: $4801; NMps: 18; NLps: 16; Switch: 0),
    (Qe: $3801; NMps: 19; NLps: 17; Switch: 0),
    (Qe: $3401; NMps: 20; NLps: 18; Switch: 0),
    (Qe: $3001; NMps: 21; NLps: 19; Switch: 0),
    (Qe: $2801; NMps: 22; NLps: 19; Switch: 0),
    (Qe: $2401; NMps: 23; NLps: 20; Switch: 0),
    (Qe: $2201; NMps: 24; NLps: 21; Switch: 0),
    (Qe: $1C01; NMps: 25; NLps: 22; Switch: 0),
    (Qe: $1801; NMps: 26; NLps: 23; Switch: 0),
    (Qe: $1601; NMps: 27; NLps: 24; Switch: 0),
    (Qe: $1401; NMps: 28; NLps: 25; Switch: 0),
    (Qe: $1201; NMps: 29; NLps: 26; Switch: 0),
    (Qe: $1101; NMps: 30; NLps: 27; Switch: 0),
    (Qe: $0AC1; NMps: 31; NLps: 28; Switch: 0),
    (Qe: $09C1; NMps: 32; NLps: 29; Switch: 0),
    (Qe: $08A1; NMps: 33; NLps: 30; Switch: 0),
    (Qe: $0521; NMps: 34; NLps: 31; Switch: 0),
    (Qe: $0441; NMps: 35; NLps: 32; Switch: 0),
    (Qe: $02A1; NMps: 36; NLps: 33; Switch: 0),
    (Qe: $0221; NMps: 37; NLps: 34; Switch: 0),
    (Qe: $0141; NMps: 38; NLps: 35; Switch: 0),
    (Qe: $0111; NMps: 39; NLps: 36; Switch: 0),
    (Qe: $0085; NMps: 40; NLps: 37; Switch: 0),
    (Qe: $0049; NMps: 41; NLps: 38; Switch: 0),
    (Qe: $0025; NMps: 42; NLps: 39; Switch: 0),
    (Qe: $0015; NMps: 43; NLps: 40; Switch: 0),
    (Qe: $0009; NMps: 44; NLps: 41; Switch: 0),
    (Qe: $0005; NMps: 45; NLps: 42; Switch: 0),
    (Qe: $0001; NMps: 45; NLps: 43; Switch: 0),
    (Qe: $5601; NMps: 46; NLps: 46; Switch: 0));

const
  MaxOverrun = 100000;

{ TJBig2ArithDecoder }

constructor TJBig2ArithDecoder.Create(const Data: TBytes; Start, Finish: Integer);
begin
  inherited Create;
  FData := Data;
  if Finish > Integer(Length(Data)) then
    Finish := Integer(Length(Data));
  FEnd := Finish;
  FPos := Start;
  FCHigh := ByteAt(Start);
  FCLow := 0;
  ByteIn;
  FCHigh := ((FCHigh shl 7) and $FFFF) or ((FCLow shr 9) and $7F);
  FCLow := (FCLow shl 7) and $FFFF;
  Dec(FCT, 7);
  FA := $8000;
end;

function TJBig2ArithDecoder.ByteAt(Index: Integer): Integer;
begin
  if (Index >= 0) and (Index < FEnd) then
    Result := FData[Index]
  else
    Result := $FF;
end;

procedure TJBig2ArithDecoder.ByteIn;
begin
  if FPos >= FEnd - 1 then
  begin
    // past the end the decoder reads 0xFF forever: stop corrupt data from looping for long
    Inc(FOverrun);
    if FOverrun > MaxOverrun then
      raise EJBig2Error.Create('arithmetic data exhausted');
  end;
  if ByteAt(FPos) = $FF then
  begin
    if ByteAt(FPos + 1) > $8F then
    begin
      Inc(FCLow, $FF00);
      FCT := 8;
    end
    else
    begin
      Inc(FPos);
      Inc(FCLow, ByteAt(FPos) shl 9);
      FCT := 7;
    end;
  end
  else
  begin
    Inc(FPos);
    Inc(FCLow, ByteAt(FPos) shl 8);
    FCT := 8;
  end;
  if FCLow > $FFFF then
  begin
    Inc(FCHigh, FCLow shr 16);
    FCLow := FCLow and $FFFF;
  end;
end;

function TJBig2ArithDecoder.ReadBit(const Contexts: TJBig2ContextArray; Pos: Integer): Integer;
var
  CxIndex, CxMps, Qe, A, D: Integer;
begin
  CxIndex := Contexts[Pos] shr 1;
  CxMps := Contexts[Pos] and 1;
  Qe := QeTable[CxIndex].Qe;
  A := FA - Qe;
  if FCHigh < Qe then
  begin
    // exchange LPS
    if A < Qe then
    begin
      A := Qe;
      D := CxMps;
      CxIndex := QeTable[CxIndex].NMps;
    end
    else
    begin
      A := Qe;
      D := 1 xor CxMps;
      if QeTable[CxIndex].Switch = 1 then
        CxMps := D;
      CxIndex := QeTable[CxIndex].NLps;
    end;
  end
  else
  begin
    Dec(FCHigh, Qe);
    if (A and $8000) <> 0 then
    begin
      FA := A;
      Exit(CxMps);
    end;
    // exchange MPS
    if A < Qe then
    begin
      D := 1 xor CxMps;
      if QeTable[CxIndex].Switch = 1 then
        CxMps := D;
      CxIndex := QeTable[CxIndex].NLps;
    end
    else
    begin
      D := CxMps;
      CxIndex := QeTable[CxIndex].NMps;
    end;
  end;
  // RENORMD
  repeat
    if FCT = 0 then
      ByteIn;
    A := A shl 1;
    FCHigh := ((FCHigh shl 1) and $FFFF) or ((FCLow shr 15) and 1);
    FCLow := (FCLow shl 1) and $FFFF;
    Dec(FCT);
  until (A and $8000) <> 0;
  FA := A;
  Contexts[Pos] := Byte((CxIndex shl 1) or CxMps);
  Result := D;
end;

{ TJBig2Contexts }

constructor TJBig2Contexts.Create;
var
  P: TJBig2IntProc;
begin
  inherited Create;
  for P := Low(TJBig2IntProc) to High(TJBig2IntProc) do
    SetLength(IntCtx[P], 512);
  SetLength(GB, 1 shl 16);
  SetLength(GR, 1 shl 13);
end;

procedure TJBig2Contexts.EnsureIAID(CodeLength: Integer);
var
  Needed: Integer;
begin
  if (CodeLength < 0) or (CodeLength > 24) then
    raise EJBig2Error.CreateFmt('symbol code length %d out of range', [CodeLength]);
  Needed := 1 shl (CodeLength + 1);
  if Integer(Length(IAID)) < Needed then
    SetLength(IAID, Needed);
end;

{ Integer procedures }

function JBig2DecodeInteger(Decoder: TJBig2ArithDecoder; const Contexts: TJBig2ContextArray;
  out Value: Integer): Boolean;
var
  Prev: Integer;

  function ReadBits(Count: Integer): Int64;
  var
    I, Bit: Integer;
  begin
    Result := 0;
    for I := 0 to Count - 1 do
    begin
      Bit := Decoder.ReadBit(Contexts, Prev);
      if Prev < 256 then
        Prev := (Prev shl 1) or Bit
      else
        Prev := (((Prev shl 1) or Bit) and 511) or 256;
      Result := (Result shl 1) or Bit;
    end;
  end;

var
  Sign: Int64;
  V: Int64;
begin
  Prev := 1;
  Sign := ReadBits(1);
  if ReadBits(1) = 0 then
    V := ReadBits(2)
  else if ReadBits(1) = 0 then
    V := ReadBits(4) + 4
  else if ReadBits(1) = 0 then
    V := ReadBits(6) + 20
  else if ReadBits(1) = 0 then
    V := ReadBits(8) + 84
  else if ReadBits(1) = 0 then
    V := ReadBits(12) + 340
  else
    V := ReadBits(32) + 4436;
  Value := 0;
  if Sign <> 0 then
  begin
    if V = 0 then
      Exit(False); // OOB
    V := -V;
  end;
  if (V < -2147483647 - 1) or (V > 2147483647) then
    Exit(False);
  Value := Integer(V);
  Result := True;
end;

function JBig2DecodeIAID(Decoder: TJBig2ArithDecoder; Contexts: TJBig2Contexts; CodeLength: Integer): Integer;
var
  Prev, I: Integer;
begin
  Contexts.EnsureIAID(CodeLength);
  Prev := 1;
  for I := 0 to CodeLength - 1 do
    Prev := (Prev shl 1) or Decoder.ReadBit(Contexts.IAID, Prev);
  Result := Prev and ((1 shl CodeLength) - 1);
end;

end.
