{*******************************************************************************
  Pdf.Codec.JBIG2
  JBIG2 decoder for the PDF-embedded profile (ITU-T T.88; PDF JBIG2Decode
  filter): a sequence of segments without file header, with optional globals.
  Supports generic regions (templates 0-3, AT pixels, TPGDON), generic
  refinement regions (templates 0-1, TPGRON), symbol dictionaries and text
  regions (arithmetic and Huffman, refinement/aggregate, transposed, all
  reference corners), pattern dictionaries and halftone regions (skip, all
  combination operators), standard and custom Huffman tables, intermediate
  regions and context reuse between symbol dictionaries. MMR coded bitmaps
  (generic regions, collective symbol bitmaps, patterns, halftone planes) go
  through Pdf.Codec.CCITT (T.6, K = -1).
  Ported from pdf.js (src/core/jbig2.js, Apache License 2.0, see NOTICE) and
  extended per T.88 where pdf.js lacks a feature.
*******************************************************************************}
unit Pdf.Codec.JBIG2;

interface

uses
  System.SysUtils, Pdf.Core.Types;

type
  /// <summary>Bi-level bitmap with one byte per pixel (0 = white, 1 = black, JBIG2 convention).</summary>
  TJBig2Bitmap = record
    Width: Integer;
    Height: Integer;
    /// <summary>Width * Height bytes, row by row.</summary>
    Data: TBytes;
    /// <summary>Creates a bitmap filled with Value; raises EJBig2Error for invalid or huge sizes.</summary>
    class function Create(AWidth, AHeight: Integer; Value: Byte = 0): TJBig2Bitmap; static;
    /// <summary>Pixel at (X, Y), 0 outside the bitmap.</summary>
    function Pixel(X, Y: Integer): Integer; inline;
  end;

  /// <summary>Parsed segment header (T.88 7.2).</summary>
  TJBig2SegmentHeader = record
    Number: Cardinal;
    SegmentType: Integer;
    DeferredNonRetain: Boolean;
    PageAssociation: Cardinal;
    ReferredTo: TArray<Cardinal>;
    /// <summary>Offset of the segment data in the stream.</summary>
    DataStart: Integer;
    /// <summary>Length of the segment data (resolved when stored as 0xFFFFFFFF).</summary>
    DataLength: Integer;
    /// <summary>True when the header stored the unknown length 0xFFFFFFFF.</summary>
    UnknownLength: Boolean;
    /// <summary>Row count from the end of an unknown-length generic region, else -1.</summary>
    RowCount: Integer;
  end;

/// <summary>Decodes the PDF-embedded JBIG2 stream (sequence of segments, no file header) with optional globals.
/// Width/Height come from the image dictionary and define the page bitmap (the page info segment may say
/// 0xFFFFFFFF height). Output: packed 1-bit rows, stride (Width+7) div 8, 0 = black and 1 = white, i.e.
/// exactly what the PDF JBIG2Decode filter delivers. A corrupt segment stops decoding and the page decoded
/// so far is returned; EPdfFilterError is raised only when the first segment header is unusable.</summary>
function PdfJBIG2Decode(const Data, Globals: TBytes; Width, Height: Integer): TBytes;
/// <summary>As PdfJBIG2Decode, and returns diagnostics (unsupported features, errors) in Log.</summary>
function PdfJBIG2DecodeWithLog(const Data, Globals: TBytes; Width, Height: Integer; out Log: string): TBytes;
/// <summary>Parses the segment headers of an embedded stream (diagnostics and tests); stops at the
/// first unusable header and raises EPdfFilterError when there is none at all.</summary>
function PdfJBIG2ReadSegmentHeaders(const Data: TBytes): TArray<TJBig2SegmentHeader>;
/// <summary>Combines Source into Target at (X, Y), clipped to Target. Op: 0 OR, 1 AND, 2 XOR,
/// 3 XNOR, 4 REPLACE (T.88 7.4.1.5).</summary>
procedure JBig2Compose(var Target: TJBig2Bitmap; const Source: TJBig2Bitmap; X, Y, Op: Integer);

implementation

uses
  System.Generics.Collections, Pdf.Codec.JBIG2.Arith, Pdf.Codec.JBIG2.Huffman, Pdf.Codec.CCITT;

{$POINTERMATH ON}

const
  MaxPixels = Int64(1) shl 28;

  // Segment types (7.3)
  stSymbolDictionary = 0;
  stIntermediateTextRegion = 4;
  stImmediateTextRegion = 6;
  stImmediateLosslessTextRegion = 7;
  stPatternDictionary = 16;
  stIntermediateHalftoneRegion = 20;
  stImmediateHalftoneRegion = 22;
  stImmediateLosslessHalftoneRegion = 23;
  stIntermediateGenericRegion = 36;
  stImmediateGenericRegion = 38;
  stImmediateLosslessGenericRegion = 39;
  stIntermediateRefinementRegion = 40;
  stImmediateRefinementRegion = 42;
  stImmediateLosslessRefinementRegion = 43;
  stPageInformation = 48;
  stEndOfPage = 49;
  stEndOfStripe = 50;
  stEndOfFile = 51;
  stProfiles = 52;
  stTables = 53;
  stExtension = 62;

function CeilLog2(N: Int64): Integer;
begin
  Result := 0;
  while (Int64(1) shl Result) < N do
    Inc(Result);
end;

function Sar64(V: Int64; Bits: Integer): Int64; inline;
begin
  // arithmetic shift right (floor division by 2^Bits)
  if V >= 0 then
    Result := V shr Bits
  else
    Result := not ((not V) shr Bits);
end;

function FloorDiv2(V: Integer): Integer; inline;
begin
  Result := Integer(Sar64(V, 1));
end;

{ TJBig2Bitmap }

class function TJBig2Bitmap.Create(AWidth, AHeight: Integer; Value: Byte): TJBig2Bitmap;
begin
  if (AWidth < 0) or (AHeight < 0) or (Int64(AWidth) * AHeight > MaxPixels) then
    raise EJBig2Error.CreateFmt('invalid bitmap size %d x %d', [AWidth, AHeight]);
  Result.Width := AWidth;
  Result.Height := AHeight;
  // Result may alias the caller's variable: drop its old pixels, SetLength would keep them
  Result.Data := nil;
  SetLength(Result.Data, AWidth * AHeight);
  if (Value <> 0) and (Result.Data <> nil) then
    FillChar(Result.Data[0], AWidth * AHeight, Value);
end;

function TJBig2Bitmap.Pixel(X, Y: Integer): Integer;
begin
  if (Cardinal(X) < Cardinal(Width)) and (Cardinal(Y) < Cardinal(Height)) then
    Result := Data[Y * Width + X]
  else
    Result := 0;
end;

procedure JBig2Compose(var Target: TJBig2Bitmap; const Source: TJBig2Bitmap; X, Y, Op: Integer);
var
  X0, X1, Y0, Y1, SY, I, Count: Integer;
  S, T: PByte;
begin
  // clip the source rectangle to the target
  X0 := 0;
  if X < 0 then
  begin
    if Int64(X) + Source.Width <= 0 then
      Exit;
    X0 := -X;
  end;
  Y0 := 0;
  if Y < 0 then
  begin
    if Int64(Y) + Source.Height <= 0 then
      Exit;
    Y0 := -Y;
  end;
  if Int64(X) + Source.Width > Target.Width then
    X1 := Integer(Int64(Target.Width) - X)
  else
    X1 := Source.Width;
  if Int64(Y) + Source.Height > Target.Height then
    Y1 := Integer(Int64(Target.Height) - Y)
  else
    Y1 := Source.Height;
  Count := X1 - X0;
  if (Count <= 0) or (Y1 <= Y0) then
    Exit;
  for SY := Y0 to Y1 - 1 do
  begin
    S := @Source.Data[SY * Source.Width + X0];
    T := @Target.Data[(Y + SY) * Target.Width + X + X0];
    case Op of
      1:
        for I := 0 to Count - 1 do
          T[I] := T[I] and S[I];
      2:
        for I := 0 to Count - 1 do
          T[I] := T[I] xor S[I];
      3:
        for I := 0 to Count - 1 do
          T[I] := (T[I] xor S[I]) xor 1;
      4:
        Move(S^, T^, Count);
    else
      for I := 0 to Count - 1 do
        T[I] := T[I] or S[I];
    end;
  end;
end;

{ Bitmap decoding procedures }

const
  // Generic region templates in T.88 context bit order (6.2.5.3): pixels of row y-2 (x-L2..x+R2) at
  // shift S2, row y-1 (x-L1..x+R1) at shift S1, row y (x-L0..x-1) at shift 0, AT pixels at ATShift.
  GenL2: array[0..3] of Integer = (1, 1, 1, 0);
  GenR2: array[0..3] of Integer = (1, 2, 1, -1);
  GenS2: array[0..3] of Integer = (12, 9, 7, 0);
  GenL1: array[0..3] of Integer = (2, 2, 2, 3);
  GenR1: array[0..3] of Integer = (2, 2, 1, 1);
  GenS1: array[0..3] of Integer = (5, 4, 3, 5);
  GenL0: array[0..3] of Integer = (4, 3, 2, 4);
  GenATShift: array[0..3, 0..3] of Integer = ((4, 10, 11, 15), (3, 0, 0, 0), (2, 0, 0, 0), (4, 0, 0, 0));
  GenATCount: array[0..3] of Integer = (4, 1, 1, 1);
  // 6.2.5.7: context of the SLTP pseudo pixel for TPGDON
  GenTPContext: array[0..3] of Integer = ($9B25, $0795, $00E5, $0195);
  // 6.3.5.6: context of the SLTP pseudo pixel for TPGRON (only the reference pixel set)
  RefTPContext: array[0..1] of Integer = ($0020, $0008);

/// 6.2 Generic region decoding procedure (arithmetic, MMR = 0).
function DecodeGenericBitmap(Decoder: TJBig2ArithDecoder; const GB: TJBig2ContextArray;
  Width, Height, Template: Integer; TPGDON: Boolean; const ATX, ATY: array of Integer;
  const Skip: TJBig2Bitmap; UseSkip: Boolean): TJBig2Bitmap;
var
  PadL, PadR, PadT, Stride, I, NAT, X, Y, K, Bit, Ctx: Integer;
  L2, R2, S2, L1, R1, S1, M2, M1, M0, Reg2, Reg1, Reg0: Integer;
  ATOff, ATBit: array[0..3] of Integer;
  Buf: TBytes;
  P0, P1, P2: PByte;
  LTP: Boolean;
  SkipRow: PByte;
begin
  Result := TJBig2Bitmap.Create(Width, Height);
  if (Width = 0) or (Height = 0) then
    Exit;
  if (Template < 0) or (Template > 3) then
    raise EJBig2Error.Create('invalid generic template');
  NAT := GenATCount[Template];
  if (Length(ATX) < NAT) or (Length(ATY) < NAT) then
    raise EJBig2Error.Create('missing AT pixels');
  PadL := 4;
  PadR := 3;
  PadT := 2;
  for I := 0 to NAT - 1 do
  begin
    if (ATY[I] > 0) or ((ATY[I] = 0) and (ATX[I] >= 0)) then
      raise EJBig2Error.Create('invalid AT pixel');
    if -ATX[I] > PadL then
      PadL := -ATX[I];
    if ATX[I] > PadR then
      PadR := ATX[I];
    if -ATY[I] > PadT then
      PadT := -ATY[I];
  end;
  Stride := PadL + Width + PadR;
  if Int64(Stride) * (PadT + Height) > MaxPixels * 2 then
    raise EJBig2Error.Create('generic region too large');
  SetLength(Buf, Stride * (PadT + Height));
  for I := 0 to NAT - 1 do
  begin
    ATOff[I] := ATY[I] * Stride + ATX[I];
    ATBit[I] := 1 shl GenATShift[Template, I];
  end;
  L2 := GenL2[Template];
  R2 := GenR2[Template];
  S2 := GenS2[Template];
  L1 := GenL1[Template];
  R1 := GenR1[Template];
  S1 := GenS1[Template];
  M2 := (1 shl (L2 + R2 + 1)) - 1;
  M1 := (1 shl (L1 + R1 + 1)) - 1;
  M0 := (1 shl GenL0[Template]) - 1;
  if UseSkip and ((Skip.Width <> Width) or (Skip.Height <> Height)) then
    UseSkip := False;
  LTP := False;
  SkipRow := nil;
  for Y := 0 to Height - 1 do
  begin
    P0 := @Buf[(PadT + Y) * Stride + PadL];
    P1 := P0 - Stride;
    P2 := P1 - Stride;
    if TPGDON then
    begin
      if Decoder.ReadBit(GB, GenTPContext[Template]) <> 0 then
        LTP := not LTP;
      if LTP then
      begin
        Move(P1^, P0^, Width);
        Continue;
      end;
    end;
    if UseSkip then
      SkipRow := @Skip.Data[Y * Width];
    Reg2 := 0;
    for K := -L2 to R2 do
      Reg2 := (Reg2 shl 1) or P2[K];
    Reg1 := 0;
    for K := -L1 to R1 do
      Reg1 := (Reg1 shl 1) or P1[K];
    Reg0 := 0;
    for X := 0 to Width - 1 do
    begin
      if UseSkip and (SkipRow[X] <> 0) then
        Bit := 0
      else
      begin
        Ctx := (Reg2 shl S2) or (Reg1 shl S1) or Reg0;
        for I := 0 to NAT - 1 do
          if P0[X + ATOff[I]] <> 0 then
            Ctx := Ctx or ATBit[I];
        Bit := Decoder.ReadBit(GB, Ctx);
        P0[X] := Bit;
      end;
      Reg2 := ((Reg2 shl 1) or P2[X + 1 + R2]) and M2;
      Reg1 := ((Reg1 shl 1) or P1[X + 1 + R1]) and M1;
      Reg0 := ((Reg0 shl 1) or Bit) and M0;
    end;
  end;
  for Y := 0 to Height - 1 do
    Move(Buf[(PadT + Y) * Stride + PadL], Result.Data[Y * Width], Width);
end;

/// 6.3 Generic refinement region decoding procedure.
function DecodeRefinementBitmap(Decoder: TJBig2ArithDecoder; const GR: TJBig2ContextArray;
  Width, Height, Template: Integer; const Ref: TJBig2Bitmap; DX, DY: Integer; TPGRON: Boolean;
  const ATX, ATY: array of Integer): TJBig2Bitmap;
var
  X, Y, RX, RY, Ctx, V, I, J: Integer;
  LTP, Typical: Boolean;
  Row: PByte;
begin
  Result := TJBig2Bitmap.Create(Width, Height);
  if (Width = 0) or (Height = 0) then
    Exit;
  if (Template = 0) and ((Length(ATX) < 2) or (Length(ATY) < 2)) then
    raise EJBig2Error.Create('missing refinement AT pixels');
  LTP := False;
  for Y := 0 to Height - 1 do
  begin
    if TPGRON then
      if Decoder.ReadBit(GR, RefTPContext[Template and 1]) <> 0 then
        LTP := not LTP;
    Row := @Result.Data[Y * Width];
    RY := Y - DY;
    for X := 0 to Width - 1 do
    begin
      RX := X - DX;
      if LTP then
      begin
        // TPGRPIX: a pixel whose 3x3 reference neighbourhood is uniform takes that value
        V := Ref.Pixel(RX - 1, RY - 1);
        Typical := True;
        for J := -1 to 1 do
        begin
          for I := -1 to 1 do
            if Ref.Pixel(RX + I, RY + J) <> V then
            begin
              Typical := False;
              Break;
            end;
          if not Typical then
            Break;
        end;
        if Typical then
        begin
          Row[X] := V;
          Continue;
        end;
      end;
      if Template = 0 then
        Ctx := (Result.Pixel(X, Y - 1) shl 12) or (Result.Pixel(X + 1, Y - 1) shl 11) or
          (Result.Pixel(X - 1, Y) shl 10) or (Result.Pixel(X + ATX[0], Y + ATY[0]) shl 9) or
          (Ref.Pixel(RX, RY - 1) shl 8) or (Ref.Pixel(RX + 1, RY - 1) shl 7) or
          (Ref.Pixel(RX - 1, RY) shl 6) or (Ref.Pixel(RX, RY) shl 5) or (Ref.Pixel(RX + 1, RY) shl 4) or
          (Ref.Pixel(RX - 1, RY + 1) shl 3) or (Ref.Pixel(RX, RY + 1) shl 2) or
          (Ref.Pixel(RX + 1, RY + 1) shl 1) or Ref.Pixel(RX + ATX[1], RY + ATY[1])
      else
        Ctx := (Result.Pixel(X - 1, Y - 1) shl 9) or (Result.Pixel(X, Y - 1) shl 8) or
          (Result.Pixel(X + 1, Y - 1) shl 7) or (Result.Pixel(X - 1, Y) shl 6) or
          (Ref.Pixel(RX, RY - 1) shl 5) or (Ref.Pixel(RX - 1, RY) shl 4) or (Ref.Pixel(RX, RY) shl 3) or
          (Ref.Pixel(RX + 1, RY) shl 2) or (Ref.Pixel(RX, RY + 1) shl 1) or Ref.Pixel(RX + 1, RY + 1);
      Row[X] := Decoder.ReadBit(GR, Ctx);
    end;
  end;
end;

/// 6.5.9: uncompressed collective bitmap, rows padded to a byte boundary.
function ReadUncompressedBitmap(Reader: TJBig2BitReader; Width, Height: Integer): TJBig2Bitmap;
var
  X, Y: Integer;
begin
  Result := TJBig2Bitmap.Create(Width, Height);
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
      Result.Data[Y * Width + X] := Reader.ReadBit;
    Reader.ByteAlign;
  end;
end;

function SubBitmap(const Source: TJBig2Bitmap; X, Width: Integer): TJBig2Bitmap;
var
  Y: Integer;
begin
  Result := TJBig2Bitmap.Create(Width, Source.Height);
  if Width > 0 then
    for Y := 0 to Source.Height - 1 do
      Move(Source.Data[Y * Source.Width + X], Result.Data[Y * Width], Width);
end;

type
  TJBig2Cursor = record
    Data: TBytes;
    Pos: Integer;
    Finish: Integer;
    procedure Init(const AData: TBytes; AStart, AFinish: Integer);
    procedure Need(Count: Integer); inline;
    function U8: Integer;
    function I8: Integer;
    function U16: Integer;
    function U32: Cardinal;
    function I32: Integer;
  end;

  TJBig2RegionInfo = record
    Width: Integer;
    Height: Integer;
    RawHeight: Cardinal;
    X: Integer;
    Y: Integer;
    Op: Integer;
  end;

  TJBig2StoredRegion = record
    Bitmap: TJBig2Bitmap;
    Info: TJBig2RegionInfo;
  end;

  TJBig2RetainedContexts = record
    GB: TBytes;
    GR: TBytes;
  end;

  TJBig2DecodingContext = class
  private
    FData: TBytes;
    FStart: Integer;
    FEnd: Integer;
    FDecoder: TJBig2ArithDecoder;
    FContexts: TJBig2Contexts;
    function GetDecoder: TJBig2ArithDecoder;
  public
    constructor Create(const Data: TBytes; Start, Finish: Integer);
    destructor Destroy; override;
    property Decoder: TJBig2ArithDecoder read GetDecoder;
    property Contexts: TJBig2Contexts read FContexts;
  end;

  TJBig2TextParams = record
    Huffman: Boolean;
    Refine: Boolean;
    Width: Integer;
    Height: Integer;
    DefaultPixel: Byte;
    NumInstances: Int64;
    LogStrips: Integer;
    Transposed: Boolean;
    DSOffset: Integer;
    RefCorner: Integer;
    CombOp: Integer;
    RTemplate: Integer;
    RATX: array[0..1] of Integer;
    RATY: array[0..1] of Integer;
    SymCodeLen: Integer;
    TableFS: TJBig2HuffmanTable;
    TableDS: TJBig2HuffmanTable;
    TableDT: TJBig2HuffmanTable;
    TableRDW: TJBig2HuffmanTable;
    TableRDH: TJBig2HuffmanTable;
    TableRDX: TJBig2HuffmanTable;
    TableRDY: TJBig2HuffmanTable;
    TableRSize: TJBig2HuffmanTable;
    /// nil: symbol IDs are SymCodeLen-bit fixed length codes
    TableSymID: TJBig2HuffmanTable;
  end;

  TJBig2SymbolDictParams = record
    Huffman: Boolean;
    Refine: Boolean;
    Template: Integer;
    RTemplate: Integer;
    ATX: array[0..3] of Integer;
    ATY: array[0..3] of Integer;
    RATX: array[0..1] of Integer;
    RATY: array[0..1] of Integer;
    NumExported: Int64;
    NumNew: Int64;
    TableDH: TJBig2HuffmanTable;
    TableDW: TJBig2HuffmanTable;
    TableBMSize: TJBig2HuffmanTable;
    TableAggInst: TJBig2HuffmanTable;
  end;

  TJBig2Decoder = class
  private
    FPage: TJBig2Bitmap;
    FPageInfoSeen: Boolean;
    FPageDefaultOp: Integer;
    FPageOverride: Boolean;
    FSymbols: TDictionary<Cardinal, TArray<TJBig2Bitmap>>;
    FPatterns: TDictionary<Cardinal, TArray<TJBig2Bitmap>>;
    FTables: TObjectDictionary<Cardinal, TJBig2HuffmanTable>;
    FRegions: TDictionary<Cardinal, TJBig2StoredRegion>;
    FRetained: TDictionary<Cardinal, TJBig2RetainedContexts>;
    FStd: array[1..15] of TJBig2HuffmanTable;
    FLog: TStringBuilder;
    procedure Log(const Msg: string);
    function Std(Number: Integer): TJBig2HuffmanTable;
    function ReferredSymbols(const Seg: TJBig2SegmentHeader): TArray<TJBig2Bitmap>;
    function ReferredTables(const Seg: TJBig2SegmentHeader): TArray<TJBig2HuffmanTable>;
    function DecodeMMR(const Data: TBytes; Start, Finish, Width, Height: Integer;
      EndOfBlock: Boolean = False): TJBig2Bitmap;
    function DecodeValue(Ctx: TJBig2DecodingContext; Proc: TJBig2IntProc; Huffman: Boolean;
      Table: TJBig2HuffmanTable; Reader: TJBig2BitReader; out Value: Integer): Boolean;
    function DecodeTextRegion(const P: TJBig2TextParams; const Symbols: TArray<TJBig2Bitmap>;
      Ctx: TJBig2DecodingContext; Reader: TJBig2BitReader): TJBig2Bitmap;
    function DecodeSymbolDictionary(const P: TJBig2SymbolDictParams; const InputSymbols: TArray<TJBig2Bitmap>;
      Ctx: TJBig2DecodingContext; Reader: TJBig2BitReader): TArray<TJBig2Bitmap>;
    procedure CheckRegionSize(const Info: TJBig2RegionInfo);
    procedure ComposeRegion(const Seg: TJBig2SegmentHeader; const Bitmap: TJBig2Bitmap;
      const Info: TJBig2RegionInfo; Intermediate: Boolean);
    procedure PageInformation(var C: TJBig2Cursor);
    procedure GenericRegion(const Seg: TJBig2SegmentHeader; var C: TJBig2Cursor);
    procedure RefinementRegion(const Seg: TJBig2SegmentHeader; var C: TJBig2Cursor);
    procedure SymbolDictionary(const Seg: TJBig2SegmentHeader; var C: TJBig2Cursor);
    procedure TextRegion(const Seg: TJBig2SegmentHeader; var C: TJBig2Cursor);
    procedure PatternDictionary(const Seg: TJBig2SegmentHeader; var C: TJBig2Cursor);
    procedure HalftoneRegion(const Seg: TJBig2SegmentHeader; var C: TJBig2Cursor);
    procedure ProcessSegment(const Data: TBytes; const Seg: TJBig2SegmentHeader);
  public
    constructor Create(Width, Height: Integer);
    destructor Destroy; override;
    procedure Run(const Data: TBytes; IsGlobals: Boolean);
    function PackPage: TBytes;
    function LogText: string;
  end;

{ TJBig2Cursor }

procedure TJBig2Cursor.Init(const AData: TBytes; AStart, AFinish: Integer);
begin
  Data := AData;
  Pos := AStart;
  if AFinish > Integer(Length(AData)) then
    AFinish := Integer(Length(AData));
  Finish := AFinish;
end;

procedure TJBig2Cursor.Need(Count: Integer);
begin
  if (Pos < 0) or (Pos + Count > Finish) then
    raise EJBig2Error.Create('segment data too short');
end;

function TJBig2Cursor.U8: Integer;
begin
  Need(1);
  Result := Data[Pos];
  Inc(Pos);
end;

function TJBig2Cursor.I8: Integer;
begin
  Result := ShortInt(U8);
end;

function TJBig2Cursor.U16: Integer;
begin
  Need(2);
  Result := (Data[Pos] shl 8) or Data[Pos + 1];
  Inc(Pos, 2);
end;

function TJBig2Cursor.U32: Cardinal;
begin
  Need(4);
  Result := (Cardinal(Data[Pos]) shl 24) or (Cardinal(Data[Pos + 1]) shl 16) or
    (Cardinal(Data[Pos + 2]) shl 8) or Cardinal(Data[Pos + 3]);
  Inc(Pos, 4);
end;

function TJBig2Cursor.I32: Integer;
begin
  Result := Integer(U32);
end;

function ClampCoord(V: Cardinal): Integer;
begin
  if V > Cardinal(MaxInt div 2) then
    Result := MaxInt div 2
  else
    Result := Integer(V);
end;

function ReadRegionInfo(var C: TJBig2Cursor): TJBig2RegionInfo;
var
  W: Cardinal;
begin
  // 7.4.1 Region segment information field
  W := C.U32;
  Result.RawHeight := C.U32;
  if W > Cardinal(MaxInt) then
    raise EJBig2Error.Create('invalid region width');
  Result.Width := Integer(W);
  if Result.RawHeight > Cardinal(MaxInt) then
    Result.Height := -1
  else
    Result.Height := Integer(Result.RawHeight);
  Result.X := ClampCoord(C.U32);
  Result.Y := ClampCoord(C.U32);
  Result.Op := C.U8 and 7;
end;

{ TJBig2DecodingContext }

constructor TJBig2DecodingContext.Create(const Data: TBytes; Start, Finish: Integer);
begin
  inherited Create;
  FData := Data;
  FStart := Start;
  FEnd := Finish;
  FContexts := TJBig2Contexts.Create;
end;

destructor TJBig2DecodingContext.Destroy;
begin
  FDecoder.Free;
  FContexts.Free;
  inherited;
end;

function TJBig2DecodingContext.GetDecoder: TJBig2ArithDecoder;
begin
  if FDecoder = nil then
    FDecoder := TJBig2ArithDecoder.Create(FData, FStart, FEnd);
  Result := FDecoder;
end;

{ TJBig2Decoder }

constructor TJBig2Decoder.Create(Width, Height: Integer);
begin
  inherited Create;
  FPage := TJBig2Bitmap.Create(Width, Height);
  FSymbols := TDictionary<Cardinal, TArray<TJBig2Bitmap>>.Create;
  FPatterns := TDictionary<Cardinal, TArray<TJBig2Bitmap>>.Create;
  FTables := TObjectDictionary<Cardinal, TJBig2HuffmanTable>.Create([doOwnsValues]);
  FRegions := TDictionary<Cardinal, TJBig2StoredRegion>.Create;
  FRetained := TDictionary<Cardinal, TJBig2RetainedContexts>.Create;
  FLog := TStringBuilder.Create;
end;

destructor TJBig2Decoder.Destroy;
var
  I: Integer;
begin
  for I := Low(FStd) to High(FStd) do
    FStd[I].Free;
  FSymbols.Free;
  FPatterns.Free;
  FTables.Free;
  FRegions.Free;
  FRetained.Free;
  FLog.Free;
  inherited;
end;

procedure TJBig2Decoder.Log(const Msg: string);
begin
  if FLog.Length > 0 then
    FLog.Append(sLineBreak);
  FLog.Append(Msg);
end;

function TJBig2Decoder.LogText: string;
begin
  Result := FLog.ToString;
end;

function TJBig2Decoder.Std(Number: Integer): TJBig2HuffmanTable;
begin
  if FStd[Number] = nil then
    FStd[Number] := JBig2StandardTable(Number);
  Result := FStd[Number];
end;

function TJBig2Decoder.ReferredSymbols(const Seg: TJBig2SegmentHeader): TArray<TJBig2Bitmap>;
var
  N: Cardinal;
  Symbols: TArray<TJBig2Bitmap>;
begin
  Result := nil;
  for N in Seg.ReferredTo do
    if FSymbols.TryGetValue(N, Symbols) then
      Result := Result + Symbols;
end;

function TJBig2Decoder.ReferredTables(const Seg: TJBig2SegmentHeader): TArray<TJBig2HuffmanTable>;
var
  N: Cardinal;
  Table: TJBig2HuffmanTable;
begin
  Result := nil;
  for N in Seg.ReferredTo do
    if FTables.TryGetValue(N, Table) then
      Result := Result + [Table];
end;

/// Returns the byte offset after the first EOFB (two EOL codes, 000000000001 000000000001) at or after
/// Start, or Finish when there is none.
function FindEndOfBlock(const Data: TBytes; Start, Finish: Integer): Integer;
var
  I, Bit: Integer;
  Window: Cardinal;
  Bits: Int64;
begin
  if Finish > Integer(Length(Data)) then
    Finish := Integer(Length(Data));
  Window := 0;
  Bits := 0;
  for I := Start to Finish - 1 do
    for Bit := 7 downto 0 do
    begin
      Window := ((Window shl 1) or Cardinal((Data[I] shr Bit) and 1)) and $FFFFFF;
      Inc(Bits);
      if (Bits >= 24) and (Window = $001001) then
        Exit(I + 1);
    end;
  Result := Finish;
end;

function TJBig2Decoder.DecodeMMR(const Data: TBytes; Start, Finish, Width, Height: Integer;
  EndOfBlock: Boolean): TJBig2Bitmap;
var
  Params: TPdfCCITTParams;
  Bits: TBytes;
  Rows, Stride, X, Y: Integer;
begin
  // 6.2.6: MMR is CCITT T.6 (Group 4) with BlackIs1, no byte alignment
  Result := TJBig2Bitmap.Create(Width, Height);
  if (Width = 0) or (Height = 0) then
    Exit;
  if Finish > Integer(Length(Data)) then
    Finish := Integer(Length(Data));
  if Start >= Finish then
  begin
    Log(Format('MMR bitmap %d x %d without data', [Width, Height]));
    Exit;
  end;
  Params := TPdfCCITTParams.Make(-1, Width, Height, True, False, False, EndOfBlock);
  try
    Bits := PdfCCITTDecode(Copy(Data, Start, Finish - Start), Params, Rows);
  except
    on E: EPdfFilterError do
    begin
      Log(Format('MMR bitmap %d x %d: %s', [Width, Height, E.Message]));
      Exit;
    end;
  end;
  Stride := (Width + 7) div 8;
  if Rows > Height then
    Rows := Height;
  if Rows > Integer(Length(Bits)) div Stride then
    Rows := Integer(Length(Bits)) div Stride;
  if Rows < Height then
    Log(Format('MMR bitmap %d x %d: only %d rows decoded', [Width, Height, Rows]));
  for Y := 0 to Rows - 1 do
    for X := 0 to Width - 1 do
      Result.Data[Y * Width + X] := (Bits[Y * Stride + X shr 3] shr (7 - X and 7)) and 1;
end;

function TJBig2Decoder.DecodeValue(Ctx: TJBig2DecodingContext; Proc: TJBig2IntProc; Huffman: Boolean;
  Table: TJBig2HuffmanTable; Reader: TJBig2BitReader; out Value: Integer): Boolean;
begin
  if Huffman then
  begin
    if Table = nil then
      raise EJBig2Error.Create('missing Huffman table');
    Result := Table.Decode(Reader, Value);
  end
  else
    Result := JBig2DecodeInteger(Ctx.Decoder, Ctx.Contexts.IntCtx[Proc], Value);
end;

function TJBig2Decoder.DecodeTextRegion(const P: TJBig2TextParams; const Symbols: TArray<TJBig2Bitmap>;
  Ctx: TJBig2DecodingContext; Reader: TJBig2BitReader): TJBig2Bitmap;

  function Need(Proc: TJBig2IntProc; Table: TJBig2HuffmanTable): Integer;
  begin
    if not DecodeValue(Ctx, Proc, P.Huffman, Table, Reader, Result) then
      raise EJBig2Error.Create('unexpected OOB in text region');
  end;

var
  StripT, FirstS, CurS, CurT, T, S, ID, RDW, RDH, RDX, RDY, BMSize, IDS, X, Y, Strips: Integer;
  Count: Int64;
  Sym: TJBig2Bitmap;
  ApplyRefine: Boolean;
  RefDecoder: TJBig2ArithDecoder;
  RefStart: Integer;
begin
  // 6.4 Text region decoding procedure
  Result := TJBig2Bitmap.Create(P.Width, P.Height, P.DefaultPixel);
  Strips := 1 shl P.LogStrips;
  StripT := -Need(ipIADT, P.TableDT);
  FirstS := 0;
  Count := 0;
  while Count < P.NumInstances do
  begin
    StripT := StripT + Need(ipIADT, P.TableDT);
    FirstS := FirstS + Need(ipIAFS, P.TableFS);
    CurS := FirstS;
    while True do
    begin
      CurT := 0;
      if Strips > 1 then
      begin
        if P.Huffman then
          CurT := Integer(Reader.ReadBits(P.LogStrips))
        else
          CurT := Need(ipIAIT, nil);
      end;
      T := Strips * StripT + CurT;
      if P.Huffman then
      begin
        if P.TableSymID <> nil then
          ID := P.TableSymID.DecodeValue(Reader)
        else
          ID := Integer(Reader.ReadBits(P.SymCodeLen));
      end
      else
        ID := JBig2DecodeIAID(Ctx.Decoder, Ctx.Contexts, P.SymCodeLen);
      if (ID < 0) or (ID >= Integer(Length(Symbols))) then
        raise EJBig2Error.CreateFmt('symbol ID %d out of range', [ID]);
      ApplyRefine := False;
      if P.Refine then
      begin
        if P.Huffman then
          ApplyRefine := Reader.ReadBit <> 0
        else
          ApplyRefine := Need(ipIARI, nil) <> 0;
      end;
      Sym := Symbols[ID];
      if ApplyRefine then
      begin
        // 6.4.11 refinement of the symbol bitmap
        RDW := Need(ipIARDW, P.TableRDW);
        RDH := Need(ipIARDH, P.TableRDH);
        RDX := Need(ipIARDX, P.TableRDX);
        RDY := Need(ipIARDY, P.TableRDY);
        if P.Huffman then
        begin
          BMSize := P.TableRSize.DecodeValue(Reader);
          if BMSize < 0 then
            raise EJBig2Error.Create('invalid refinement bitmap size');
          Reader.ByteAlign;
          RefStart := Reader.Position;
          RefDecoder := TJBig2ArithDecoder.Create(Reader.Data, RefStart, RefStart + BMSize);
          try
            Sym := DecodeRefinementBitmap(RefDecoder, Ctx.Contexts.GR, Sym.Width + RDW, Sym.Height + RDH,
              P.RTemplate, Sym, FloorDiv2(RDW) + RDX, FloorDiv2(RDH) + RDY, False, P.RATX, P.RATY);
          finally
            RefDecoder.Free;
          end;
          Reader.Position := RefStart + BMSize;
        end
        else
          Sym := DecodeRefinementBitmap(Ctx.Decoder, Ctx.Contexts.GR, Sym.Width + RDW, Sym.Height + RDH,
            P.RTemplate, Sym, FloorDiv2(RDW) + RDX, FloorDiv2(RDH) + RDY, False, P.RATX, P.RATY);
      end;
      // 6.4.5 (3c vi - xi): place the symbol
      if not P.Transposed and (P.RefCorner > 1) then
        Inc(CurS, Sym.Width - 1)
      else if P.Transposed and ((P.RefCorner and 1) = 0) then
        Inc(CurS, Sym.Height - 1);
      S := CurS;
      if not P.Transposed then
      begin
        X := S;
        Y := T;
      end
      else
      begin
        X := T;
        Y := S;
      end;
      case P.RefCorner of
        0: // bottom left
          Y := Y - Sym.Height + 1;
        2: // bottom right
          begin
            X := X - Sym.Width + 1;
            Y := Y - Sym.Height + 1;
          end;
        3: // top right
          X := X - Sym.Width + 1;
      end;
      JBig2Compose(Result, Sym, X, Y, P.CombOp);
      if not P.Transposed and (P.RefCorner < 2) then
        Inc(CurS, Sym.Width - 1)
      else if P.Transposed and ((P.RefCorner and 1) <> 0) then
        Inc(CurS, Sym.Height - 1);
      Inc(Count);
      if not DecodeValue(Ctx, ipIADS, P.Huffman, P.TableDS, Reader, IDS) then
        Break; // OOB: end of strip
      if Count >= P.NumInstances then
        Break;
      CurS := CurS + IDS + P.DSOffset;
    end;
  end;
end;

function TJBig2Decoder.DecodeSymbolDictionary(const P: TJBig2SymbolDictParams;
  const InputSymbols: TArray<TJBig2Bitmap>; Ctx: TJBig2DecodingContext; Reader: TJBig2BitReader): TArray<TJBig2Bitmap>;
var
  NewSymbols: TArray<TJBig2Bitmap>;
  NewCount: Integer;

  procedure AddSymbol(const B: TJBig2Bitmap);
  begin
    if NewCount >= P.NumNew then
      raise EJBig2Error.Create('too many symbols in height class');
    NewSymbols[NewCount] := B;
    Inc(NewCount);
  end;

  function AllSymbols: TArray<TJBig2Bitmap>;
  begin
    Result := InputSymbols + Copy(NewSymbols, 0, NewCount);
  end;

var
  SymCodeLen, CurrentHeight, CurrentWidth, DH, DW, NumInst, ID, RDX, RDY, BMSize, I, Run, XMin: Integer;
  TotalWidth: Int64;
  Widths: TArray<Integer>;
  WidthCount: Integer;
  Bitmap, Collective, Ref: TJBig2Bitmap;
  TP: TJBig2TextParams;
  RefDecoder: TJBig2ArithDecoder;
  RefStart, Total, FlagCount, Guard, Exported: Integer;
  Flags: TArray<Boolean>;
  CurrentFlag: Boolean;
begin
  // 6.5 Symbol dictionary decoding procedure
  if P.NumNew > 1 shl 20 then
    raise EJBig2Error.Create('too many new symbols');
  SetLength(NewSymbols, P.NumNew);
  NewCount := 0;
  SymCodeLen := CeilLog2(Int64(Length(InputSymbols)) + P.NumNew);
  if P.Huffman and (SymCodeLen < 1) then
    SymCodeLen := 1;
  CurrentHeight := 0;
  Widths := nil;
  while NewCount < P.NumNew do
  begin
    if not DecodeValue(Ctx, ipIADH, P.Huffman, P.TableDH, Reader, DH) then
      raise EJBig2Error.Create('unexpected OOB for delta height');
    CurrentHeight := CurrentHeight + DH;
    if CurrentHeight < 0 then
      raise EJBig2Error.Create('negative symbol height');
    CurrentWidth := 0;
    TotalWidth := 0;
    WidthCount := 0;
    while True do
    begin
      if not DecodeValue(Ctx, ipIADW, P.Huffman, P.TableDW, Reader, DW) then
        Break; // OOB: end of height class
      if NewCount + WidthCount >= P.NumNew then
        raise EJBig2Error.Create('too many symbols');
      CurrentWidth := CurrentWidth + DW;
      if CurrentWidth < 0 then
        raise EJBig2Error.Create('negative symbol width');
      TotalWidth := TotalWidth + CurrentWidth;
      if P.Refine then
      begin
        // 6.5.8.2 refinement/aggregate coded symbol bitmap
        if not DecodeValue(Ctx, ipIAAI, P.Huffman, P.TableAggInst, Reader, NumInst) then
          raise EJBig2Error.Create('unexpected OOB for aggregate instances');
        if NumInst > 1 then
        begin
          TP := Default(TJBig2TextParams);
          TP.Huffman := P.Huffman;
          TP.Refine := True;
          TP.Width := CurrentWidth;
          TP.Height := CurrentHeight;
          TP.NumInstances := NumInst;
          TP.LogStrips := 0;
          TP.RefCorner := 1; // top left
          TP.CombOp := 0;
          TP.RTemplate := P.RTemplate;
          TP.RATX[0] := P.RATX[0];
          TP.RATY[0] := P.RATY[0];
          TP.RATX[1] := P.RATX[1];
          TP.RATY[1] := P.RATY[1];
          TP.SymCodeLen := SymCodeLen;
          if P.Huffman then
          begin
            // Table 17
            TP.TableFS := Std(6);
            TP.TableDS := Std(8);
            TP.TableDT := Std(11);
            TP.TableRDW := Std(15);
            TP.TableRDH := Std(15);
            TP.TableRDX := Std(15);
            TP.TableRDY := Std(15);
            TP.TableRSize := Std(1);
          end;
          Bitmap := DecodeTextRegion(TP, AllSymbols, Ctx, Reader);
        end
        else
        begin
          // 6.5.8.2.2 a single refined symbol
          if P.Huffman then
          begin
            ID := Integer(Reader.ReadBits(SymCodeLen));
            RDX := Std(15).DecodeValue(Reader);
            RDY := Std(15).DecodeValue(Reader);
            BMSize := Std(1).DecodeValue(Reader);
            Reader.ByteAlign;
          end
          else
          begin
            ID := JBig2DecodeIAID(Ctx.Decoder, Ctx.Contexts, SymCodeLen);
            if not JBig2DecodeInteger(Ctx.Decoder, Ctx.Contexts.IntCtx[ipIARDX], RDX) or
              not JBig2DecodeInteger(Ctx.Decoder, Ctx.Contexts.IntCtx[ipIARDY], RDY) then
              raise EJBig2Error.Create('unexpected OOB in symbol refinement');
            BMSize := 0;
          end;
          if (ID < 0) or (ID >= Integer(Length(InputSymbols)) + NewCount) then
            raise EJBig2Error.CreateFmt('refinement symbol ID %d out of range', [ID]);
          if ID < Integer(Length(InputSymbols)) then
            Ref := InputSymbols[ID]
          else
            Ref := NewSymbols[ID - Integer(Length(InputSymbols))];
          if P.Huffman then
          begin
            if BMSize < 0 then
              raise EJBig2Error.Create('invalid refinement bitmap size');
            RefStart := Reader.Position;
            RefDecoder := TJBig2ArithDecoder.Create(Reader.Data, RefStart, RefStart + BMSize);
            try
              Bitmap := DecodeRefinementBitmap(RefDecoder, Ctx.Contexts.GR, CurrentWidth, CurrentHeight,
                P.RTemplate, Ref, RDX, RDY, False, P.RATX, P.RATY);
            finally
              RefDecoder.Free;
            end;
            Reader.Position := RefStart + BMSize;
          end
          else
            Bitmap := DecodeRefinementBitmap(Ctx.Decoder, Ctx.Contexts.GR, CurrentWidth, CurrentHeight,
              P.RTemplate, Ref, RDX, RDY, False, P.RATX, P.RATY);
        end;
        AddSymbol(Bitmap);
      end
      else if P.Huffman then
      begin
        // widths only; the height class collective bitmap follows
        if WidthCount >= Integer(Length(Widths)) then
          SetLength(Widths, WidthCount * 2 + 8);
        Widths[WidthCount] := CurrentWidth;
        Inc(WidthCount);
      end
      else
        // 6.5.8.1 direct coded symbol bitmap
        AddSymbol(DecodeGenericBitmap(Ctx.Decoder, Ctx.Contexts.GB, CurrentWidth, CurrentHeight, P.Template,
          False, P.ATX, P.ATY, Default(TJBig2Bitmap), False));
    end;
    if P.Huffman and not P.Refine then
    begin
      // 6.5.9 height class collective bitmap
      BMSize := P.TableBMSize.DecodeValue(Reader);
      Reader.ByteAlign;
      if TotalWidth > MaxInt then
        raise EJBig2Error.Create('collective bitmap too wide');
      if BMSize = 0 then
        Collective := ReadUncompressedBitmap(Reader, Integer(TotalWidth), CurrentHeight)
      else
      begin
        if BMSize < 0 then
          raise EJBig2Error.Create('invalid collective bitmap size');
        RefStart := Reader.Position;
        Collective := DecodeMMR(Reader.Data, RefStart, RefStart + BMSize, Integer(TotalWidth), CurrentHeight);
        Reader.Position := RefStart + BMSize;
      end;
      XMin := 0;
      for I := 0 to WidthCount - 1 do
      begin
        AddSymbol(SubBitmap(Collective, XMin, Widths[I]));
        Inc(XMin, Widths[I]);
      end;
    end;
  end;

  // 6.5.10 exported symbols
  Total := Integer(Length(InputSymbols)) + NewCount;
  SetLength(Flags, Total);
  FlagCount := 0;
  CurrentFlag := False;
  Guard := 0;
  while FlagCount < Total do
  begin
    if P.Huffman then
      Run := Std(1).DecodeValue(Reader)
    else if not JBig2DecodeInteger(Ctx.Decoder, Ctx.Contexts.IntCtx[ipIAEX], Run) then
      raise EJBig2Error.Create('unexpected OOB in export flags');
    if (Run < 0) or (Run > Total - FlagCount) then
      raise EJBig2Error.Create('invalid export run length');
    for I := 0 to Run - 1 do
      Flags[FlagCount + I] := CurrentFlag;
    Inc(FlagCount, Run);
    CurrentFlag := not CurrentFlag;
    Inc(Guard);
    if Guard > 2 * Total + 2 then
      raise EJBig2Error.Create('export flags do not progress');
  end;
  SetLength(Result, Total);
  Exported := 0;
  for I := 0 to Total - 1 do
    if Flags[I] then
    begin
      if I < Integer(Length(InputSymbols)) then
        Result[Exported] := InputSymbols[I]
      else
        Result[Exported] := NewSymbols[I - Integer(Length(InputSymbols))];
      Inc(Exported);
    end;
  SetLength(Result, Exported);
  if Exported <> P.NumExported then
    Log(Format('symbol dictionary exports %d symbols, header says %d', [Exported, P.NumExported]));
end;

procedure TJBig2Decoder.CheckRegionSize(const Info: TJBig2RegionInfo);
begin
  // regions end up on the page: a region far larger than the page means corrupt data
  if Int64(Info.Width) * Info.Height > 4 * (Int64(FPage.Width) * FPage.Height) + (1 shl 20) then
    raise EJBig2Error.CreateFmt('region %d x %d too large for the page', [Info.Width, Info.Height]);
end;

procedure TJBig2Decoder.ComposeRegion(const Seg: TJBig2SegmentHeader; const Bitmap: TJBig2Bitmap;
  const Info: TJBig2RegionInfo; Intermediate: Boolean);
var
  Stored: TJBig2StoredRegion;
  Op: Integer;
begin
  if Intermediate then
  begin
    Stored.Bitmap := Bitmap;
    Stored.Info := Info;
    FRegions.AddOrSetValue(Seg.Number, Stored);
    Exit;
  end;
  // 7.4.8.5: regions use the page default operator unless the page allows overriding it
  if FPageInfoSeen and not FPageOverride then
    Op := FPageDefaultOp
  else
    Op := Info.Op;
  if Op > 4 then
    Op := 0;
  JBig2Compose(FPage, Bitmap, Info.X, Info.Y, Op);
end;

procedure TJBig2Decoder.PageInformation(var C: TJBig2Cursor);
var
  Flags: Integer;
begin
  // 7.4.8 Page information segment
  C.U32; // width
  C.U32; // height (may be 0xFFFFFFFF)
  C.U32; // x resolution
  C.U32; // y resolution
  Flags := C.U8;
  if FPageInfoSeen then
    Exit;
  FPageInfoSeen := True;
  FPageDefaultOp := (Flags shr 3) and 3;
  FPageOverride := (Flags and $40) <> 0;
  if ((Flags shr 2) and 1) <> 0 then
    FPage := TJBig2Bitmap.Create(FPage.Width, FPage.Height, 1);
end;

procedure TJBig2Decoder.GenericRegion(const Seg: TJBig2SegmentHeader; var C: TJBig2Cursor);
var
  Info: TJBig2RegionInfo;
  Flags, Template, I: Integer;
  MMR, TPGDON: Boolean;
  ATX, ATY: array[0..3] of Integer;
  Ctx: TJBig2DecodingContext;
  Bitmap: TJBig2Bitmap;
begin
  // 7.4.6 Generic region segment
  Info := ReadRegionInfo(C);
  Flags := C.U8;
  MMR := (Flags and 1) <> 0;
  Template := (Flags shr 1) and 3;
  TPGDON := (Flags and 8) <> 0;
  if (Flags and $10) <> 0 then
    raise EJBig2Error.Create('extended template not supported');
  FillChar(ATX, SizeOf(ATX), 0);
  FillChar(ATY, SizeOf(ATY), 0);
  if not MMR then
    for I := 0 to GenATCount[Template] - 1 do
    begin
      ATX[I] := C.I8;
      ATY[I] := C.I8;
    end;
  if Seg.UnknownLength and (Seg.RowCount >= 0) and ((Info.Height < 0) or (Seg.RowCount < Info.Height)) then
    Info.Height := Seg.RowCount;
  if Info.Height < 0 then
    raise EJBig2Error.Create('invalid region height');
  CheckRegionSize(Info);
  if MMR then
    Bitmap := DecodeMMR(C.Data, C.Pos, C.Finish, Info.Width, Info.Height)
  else
  begin
    Ctx := TJBig2DecodingContext.Create(C.Data, C.Pos, C.Finish);
    try
      Bitmap := DecodeGenericBitmap(Ctx.Decoder, Ctx.Contexts.GB, Info.Width, Info.Height, Template, TPGDON,
        ATX, ATY, Default(TJBig2Bitmap), False);
    finally
      Ctx.Free;
    end;
  end;
  ComposeRegion(Seg, Bitmap, Info, Seg.SegmentType = stIntermediateGenericRegion);
end;

procedure TJBig2Decoder.RefinementRegion(const Seg: TJBig2SegmentHeader; var C: TJBig2Cursor);
var
  Info: TJBig2RegionInfo;
  Flags, Template, I: Integer;
  TPGRON, Found: Boolean;
  ATX, ATY: array[0..1] of Integer;
  Ctx: TJBig2DecodingContext;
  Ref, Bitmap: TJBig2Bitmap;
  Stored: TJBig2StoredRegion;
  N: Cardinal;
begin
  // 7.4.7 Generic refinement region segment
  Info := ReadRegionInfo(C);
  if Info.Height < 0 then
    raise EJBig2Error.Create('invalid region height');
  CheckRegionSize(Info);
  Flags := C.U8;
  Template := Flags and 1;
  TPGRON := (Flags and 2) <> 0;
  FillChar(ATX, SizeOf(ATX), 0);
  FillChar(ATY, SizeOf(ATY), 0);
  if Template = 0 then
    for I := 0 to 1 do
    begin
      ATX[I] := C.I8;
      ATY[I] := C.I8;
    end;
  // 7.4.7.4: the reference is the referred intermediate region, else the page area under the region
  Found := False;
  for N in Seg.ReferredTo do
    if FRegions.TryGetValue(N, Stored) then
    begin
      Ref := Stored.Bitmap;
      FRegions.Remove(N);
      Found := True;
      Break;
    end;
  if not Found then
  begin
    Ref := TJBig2Bitmap.Create(Info.Width, Info.Height);
    JBig2Compose(Ref, FPage, -Info.X, -Info.Y, 4);
  end;
  Ctx := TJBig2DecodingContext.Create(C.Data, C.Pos, C.Finish);
  try
    Bitmap := DecodeRefinementBitmap(Ctx.Decoder, Ctx.Contexts.GR, Info.Width, Info.Height, Template, Ref,
      0, 0, TPGRON, ATX, ATY);
  finally
    Ctx.Free;
  end;
  ComposeRegion(Seg, Bitmap, Info, Seg.SegmentType = stIntermediateRefinementRegion);
end;

procedure TJBig2Decoder.SymbolDictionary(const Seg: TJBig2SegmentHeader; var C: TJBig2Cursor);
var
  Flags, I, CustomIndex: Integer;
  P: TJBig2SymbolDictParams;
  CtxUsed, CtxRetained: Boolean;
  Custom: TArray<TJBig2HuffmanTable>;
  Ctx: TJBig2DecodingContext;
  Reader: TJBig2BitReader;
  Retained: TJBig2RetainedContexts;
  N: Cardinal;

  function NextCustom: TJBig2HuffmanTable;
  begin
    if CustomIndex >= Integer(Length(Custom)) then
      raise EJBig2Error.Create('custom Huffman table not found');
    Result := Custom[CustomIndex];
    Inc(CustomIndex);
  end;

begin
  // 7.4.2 Symbol dictionary segment
  P := Default(TJBig2SymbolDictParams);
  Flags := C.U16;
  P.Huffman := (Flags and 1) <> 0;
  P.Refine := (Flags and 2) <> 0;
  CtxUsed := (Flags and $100) <> 0;
  CtxRetained := (Flags and $200) <> 0;
  P.Template := (Flags shr 10) and 3;
  P.RTemplate := (Flags shr 12) and 1;
  if not P.Huffman then
    for I := 0 to GenATCount[P.Template] - 1 do
    begin
      P.ATX[I] := C.I8;
      P.ATY[I] := C.I8;
    end;
  if P.Refine and (P.RTemplate = 0) then
    for I := 0 to 1 do
    begin
      P.RATX[I] := C.I8;
      P.RATY[I] := C.I8;
    end;
  P.NumExported := C.U32;
  P.NumNew := C.U32;
  if P.Huffman then
  begin
    // 7.4.2.1.6 Huffman table selection
    Custom := ReferredTables(Seg);
    CustomIndex := 0;
    case (Flags shr 2) and 3 of
      0: P.TableDH := Std(4);
      1: P.TableDH := Std(5);
      3: P.TableDH := NextCustom;
    else
      raise EJBig2Error.Create('invalid Huffman DH selector');
    end;
    case (Flags shr 4) and 3 of
      0: P.TableDW := Std(2);
      1: P.TableDW := Std(3);
      3: P.TableDW := NextCustom;
    else
      raise EJBig2Error.Create('invalid Huffman DW selector');
    end;
    if ((Flags shr 6) and 1) <> 0 then
      P.TableBMSize := NextCustom
    else
      P.TableBMSize := Std(1);
    if ((Flags shr 7) and 1) <> 0 then
      P.TableAggInst := NextCustom
    else
      P.TableAggInst := Std(1);
  end;
  Ctx := TJBig2DecodingContext.Create(C.Data, C.Pos, C.Finish);
  Reader := TJBig2BitReader.Create(C.Data, C.Pos, C.Finish);
  try
    if CtxUsed then
    begin
      // 7.4.2.2 (3): reuse the generic and refinement contexts of the last referred dictionary
      for N in Seg.ReferredTo do
        if FRetained.TryGetValue(N, Retained) then
        begin
          Ctx.Contexts.GB := Copy(Retained.GB);
          Ctx.Contexts.GR := Copy(Retained.GR);
        end;
    end;
    FSymbols.AddOrSetValue(Seg.Number, DecodeSymbolDictionary(P, ReferredSymbols(Seg), Ctx, Reader));
    if CtxRetained then
    begin
      Retained.GB := Copy(Ctx.Contexts.GB);
      Retained.GR := Copy(Ctx.Contexts.GR);
      FRetained.AddOrSetValue(Seg.Number, Retained);
    end;
  finally
    Reader.Free;
    Ctx.Free;
  end;
end;

procedure TJBig2Decoder.TextRegion(const Seg: TJBig2SegmentHeader; var C: TJBig2Cursor);
var
  Info: TJBig2RegionInfo;
  Flags, HFlags, I, CustomIndex, CodeLength, Repeats, RepeatedLength: Integer;
  P: TJBig2TextParams;
  Symbols: TArray<TJBig2Bitmap>;
  Custom: TArray<TJBig2HuffmanTable>;
  Ctx: TJBig2DecodingContext;
  Reader: TJBig2BitReader;
  Lines: TArray<TJBig2HuffmanLine>;
  RunCodes, SymIDTable: TJBig2HuffmanTable;
  Bitmap: TJBig2Bitmap;

  function NextCustom: TJBig2HuffmanTable;
  begin
    if CustomIndex >= Integer(Length(Custom)) then
      raise EJBig2Error.Create('custom Huffman table not found');
    Result := Custom[CustomIndex];
    Inc(CustomIndex);
  end;

  function Select(Selector, Std0, Std1: Integer): TJBig2HuffmanTable;
  begin
    case Selector of
      0: Result := Std(Std0);
      1: Result := Std(Std1);
      3: Result := NextCustom;
    else
      raise EJBig2Error.Create('invalid Huffman table selector');
    end;
  end;

begin
  // 7.4.3 Text region segment
  Info := ReadRegionInfo(C);
  if Info.Height < 0 then
    raise EJBig2Error.Create('invalid region height');
  CheckRegionSize(Info);
  P := Default(TJBig2TextParams);
  Flags := C.U16;
  P.Huffman := (Flags and 1) <> 0;
  P.Refine := (Flags and 2) <> 0;
  P.LogStrips := (Flags shr 2) and 3;
  P.RefCorner := (Flags shr 4) and 3;
  P.Transposed := (Flags and $40) <> 0;
  P.CombOp := (Flags shr 7) and 3;
  P.DefaultPixel := (Flags shr 9) and 1;
  P.DSOffset := (Flags shr 10) and $1F;
  if P.DSOffset >= 16 then
    Dec(P.DSOffset, 32);
  P.RTemplate := (Flags shr 15) and 1;
  P.Width := Info.Width;
  P.Height := Info.Height;
  HFlags := 0;
  if P.Huffman then
    HFlags := C.U16;
  if P.Refine and (P.RTemplate = 0) then
    for I := 0 to 1 do
    begin
      P.RATX[I] := C.I8;
      P.RATY[I] := C.I8;
    end;
  P.NumInstances := C.U32;
  Symbols := ReferredSymbols(Seg);
  P.SymCodeLen := CeilLog2(Length(Symbols));
  SymIDTable := nil;
  Ctx := TJBig2DecodingContext.Create(C.Data, C.Pos, C.Finish);
  Reader := TJBig2BitReader.Create(C.Data, C.Pos, C.Finish);
  try
    if P.Huffman then
    begin
      // 7.4.3.1.6 table selection
      Custom := ReferredTables(Seg);
      CustomIndex := 0;
      case HFlags and 3 of
        0: P.TableFS := Std(6);
        1: P.TableFS := Std(7);
        3: P.TableFS := NextCustom;
      else
        raise EJBig2Error.Create('invalid Huffman FS selector');
      end;
      case (HFlags shr 2) and 3 of
        0: P.TableDS := Std(8);
        1: P.TableDS := Std(9);
        2: P.TableDS := Std(10);
      else
        P.TableDS := NextCustom;
      end;
      case (HFlags shr 4) and 3 of
        0: P.TableDT := Std(11);
        1: P.TableDT := Std(12);
        2: P.TableDT := Std(13);
      else
        P.TableDT := NextCustom;
      end;
      if P.Refine then
      begin
        P.TableRDW := Select((HFlags shr 6) and 3, 14, 15);
        P.TableRDH := Select((HFlags shr 8) and 3, 14, 15);
        P.TableRDX := Select((HFlags shr 10) and 3, 14, 15);
        P.TableRDY := Select((HFlags shr 12) and 3, 14, 15);
        if (HFlags and $4000) <> 0 then
          P.TableRSize := NextCustom
        else
          P.TableRSize := Std(1);
      end;
      // 7.4.3.1.7 symbol ID Huffman table
      Lines := nil;
      for I := 0 to 34 do
        Lines := Lines + [JBig2HuffmanLine(I, Integer(Reader.ReadBits(4)), 0)];
      RunCodes := TJBig2HuffmanTable.Create(Lines, False);
      try
        SetLength(Lines, Length(Symbols));
        I := 0;
        while I < Integer(Length(Symbols)) do
        begin
          CodeLength := RunCodes.DecodeValue(Reader);
          if CodeLength >= 32 then
          begin
            case CodeLength of
              32:
                begin
                  if I = 0 then
                    raise EJBig2Error.Create('no previous value in symbol ID table');
                  Repeats := Integer(Reader.ReadBits(2)) + 3;
                  RepeatedLength := Lines[I - 1].PrefixLength;
                end;
              33:
                begin
                  Repeats := Integer(Reader.ReadBits(3)) + 3;
                  RepeatedLength := 0;
                end;
              34:
                begin
                  Repeats := Integer(Reader.ReadBits(7)) + 11;
                  RepeatedLength := 0;
                end;
            else
              raise EJBig2Error.Create('invalid code length in symbol ID table');
            end;
            while (Repeats > 0) and (I < Integer(Length(Symbols))) do
            begin
              Lines[I] := JBig2HuffmanLine(I, RepeatedLength, 0);
              Inc(I);
              Dec(Repeats);
            end;
          end
          else
          begin
            Lines[I] := JBig2HuffmanLine(I, CodeLength, 0);
            Inc(I);
          end;
        end;
      finally
        RunCodes.Free;
      end;
      Reader.ByteAlign;
      SymIDTable := TJBig2HuffmanTable.Create(Lines, False);
      P.TableSymID := SymIDTable;
    end;
    Bitmap := DecodeTextRegion(P, Symbols, Ctx, Reader);
  finally
    SymIDTable.Free;
    Reader.Free;
    Ctx.Free;
  end;
  ComposeRegion(Seg, Bitmap, Info, Seg.SegmentType = stIntermediateTextRegion);
end;

procedure TJBig2Decoder.PatternDictionary(const Seg: TJBig2SegmentHeader; var C: TJBig2Cursor);
var
  Flags, Template, PatternWidth, PatternHeight, I: Integer;
  MMR: Boolean;
  GrayMax: Cardinal;
  CollectiveWidth: Int64;
  ATX, ATY: array[0..3] of Integer;
  Ctx: TJBig2DecodingContext;
  Collective: TJBig2Bitmap;
  Patterns: TArray<TJBig2Bitmap>;
begin
  // 7.4.4 Pattern dictionary segment, 6.7 decoding procedure
  Flags := C.U8;
  MMR := (Flags and 1) <> 0;
  Template := (Flags shr 1) and 3;
  PatternWidth := C.U8;
  PatternHeight := C.U8;
  GrayMax := C.U32;
  CollectiveWidth := (Int64(GrayMax) + 1) * PatternWidth;
  if (PatternWidth = 0) or (PatternHeight = 0) or (GrayMax > 1 shl 20) or
    (CollectiveWidth * PatternHeight > MaxPixels) then
    raise EJBig2Error.Create('invalid pattern dictionary');
  ATX[0] := -PatternWidth;
  ATY[0] := 0;
  ATX[1] := -3;
  ATY[1] := -1;
  ATX[2] := 2;
  ATY[2] := -2;
  ATX[3] := -2;
  ATY[3] := -2;
  if MMR then
    Collective := DecodeMMR(C.Data, C.Pos, C.Finish, Integer(CollectiveWidth), PatternHeight)
  else
  begin
    Ctx := TJBig2DecodingContext.Create(C.Data, C.Pos, C.Finish);
    try
      Collective := DecodeGenericBitmap(Ctx.Decoder, Ctx.Contexts.GB, Integer(CollectiveWidth), PatternHeight,
        Template, False, ATX, ATY, Default(TJBig2Bitmap), False);
    finally
      Ctx.Free;
    end;
  end;
  SetLength(Patterns, GrayMax + 1);
  for I := 0 to Integer(GrayMax) do
    Patterns[I] := SubBitmap(Collective, I * PatternWidth, PatternWidth);
  FPatterns.AddOrSetValue(Seg.Number, Patterns);
end;

procedure TJBig2Decoder.HalftoneRegion(const Seg: TJBig2SegmentHeader; var C: TJBig2Cursor);
var
  Info: TJBig2RegionInfo;
  Flags, Template, Op, BPP, I, J, MG, NG, Bit, Index, X, Y, HPW, HPH, Pos: Integer;
  MMR, EnableSkip: Boolean;
  DefPixel: Byte;
  GridWidth, GridHeight: Cardinal;
  GridX, GridY: Integer;
  VectorX, VectorY: Integer;
  ATX, ATY: array[0..3] of Integer;
  Patterns, Found: TArray<TJBig2Bitmap>;
  N: Cardinal;
  Region, Skip: TJBig2Bitmap;
  Planes: TArray<TJBig2Bitmap>;
  Ctx: TJBig2DecodingContext;
begin
  // 7.4.5 Halftone region segment, 6.6 decoding procedure
  Info := ReadRegionInfo(C);
  if Info.Height < 0 then
    raise EJBig2Error.Create('invalid region height');
  CheckRegionSize(Info);
  Flags := C.U8;
  MMR := (Flags and 1) <> 0;
  Template := (Flags shr 1) and 3;
  EnableSkip := (Flags and 8) <> 0;
  Op := (Flags shr 4) and 7;
  DefPixel := (Flags shr 7) and 1;
  GridWidth := C.U32;
  GridHeight := C.U32;
  GridX := C.I32;
  GridY := C.I32;
  VectorX := C.U16;
  VectorY := C.U16;
  Patterns := nil;
  for N in Seg.ReferredTo do
    if FPatterns.TryGetValue(N, Found) then
    begin
      Patterns := Found;
      Break;
    end;
  if Length(Patterns) = 0 then
    raise EJBig2Error.Create('halftone region without pattern dictionary');
  if Int64(GridWidth) * GridHeight > 4 * (Int64(Info.Width) * Info.Height) + 65536 then
    raise EJBig2Error.Create('halftone grid too large');
  HPW := Patterns[0].Width;
  HPH := Patterns[0].Height;
  Region := TJBig2Bitmap.Create(Info.Width, Info.Height, DefPixel);
  BPP := CeilLog2(Length(Patterns));
  // 6.6.5.1 skip bitmap: grid cells whose pattern lies completely outside the region
  Skip := Default(TJBig2Bitmap);
  if EnableSkip then
  begin
    Skip := TJBig2Bitmap.Create(Integer(GridWidth), Integer(GridHeight));
    for MG := 0 to Integer(GridHeight) - 1 do
      for NG := 0 to Integer(GridWidth) - 1 do
      begin
        X := Integer(Sar64(Int64(GridX) + Int64(MG) * VectorY + Int64(NG) * VectorX, 8));
        Y := Integer(Sar64(Int64(GridY) + Int64(MG) * VectorX - Int64(NG) * VectorY, 8));
        if (Int64(X) + HPW <= 0) or (X >= Info.Width) or (Int64(Y) + HPH <= 0) or (Y >= Info.Height) then
          Skip.Data[MG * Integer(GridWidth) + NG] := 1;
      end;
  end;
  // Annex C gray-scale image decoding
  ATX[0] := 3;
  if Template > 1 then
    ATX[0] := 2;
  ATY[0] := -1;
  ATX[1] := -3;
  ATY[1] := -1;
  ATX[2] := 2;
  ATY[2] := -2;
  ATX[3] := -2;
  ATY[3] := -2;
  SetLength(Planes, BPP);
  if MMR then
  begin
    // the planes form one MMR stream, each plane ends with EOFB and the next starts on a byte boundary
    Pos := C.Pos;
    for J := BPP - 1 downto 0 do
    begin
      Planes[J] := DecodeMMR(C.Data, Pos, C.Finish, Integer(GridWidth), Integer(GridHeight), True);
      Pos := FindEndOfBlock(C.Data, Pos, C.Finish);
    end;
  end
  else
  begin
    Ctx := TJBig2DecodingContext.Create(C.Data, C.Pos, C.Finish);
    try
      for J := BPP - 1 downto 0 do
        Planes[J] := DecodeGenericBitmap(Ctx.Decoder, Ctx.Contexts.GB, Integer(GridWidth), Integer(GridHeight),
          Template, False, ATX, ATY, Skip, EnableSkip);
    finally
      Ctx.Free;
    end;
  end;
  // 6.6.5.2 rendering the patterns
  for MG := 0 to Integer(GridHeight) - 1 do
    for NG := 0 to Integer(GridWidth) - 1 do
    begin
      Bit := 0;
      Index := 0;
      I := MG * Integer(GridWidth) + NG;
      for J := BPP - 1 downto 0 do
      begin
        Bit := Bit xor Planes[J].Data[I];
        Index := Index or (Bit shl J);
      end;
      if Index >= Integer(Length(Patterns)) then
        Index := High(Patterns);
      X := Integer(Sar64(Int64(GridX) + Int64(MG) * VectorY + Int64(NG) * VectorX, 8));
      Y := Integer(Sar64(Int64(GridY) + Int64(MG) * VectorX - Int64(NG) * VectorY, 8));
      JBig2Compose(Region, Patterns[Index], X, Y, Op);
    end;
  ComposeRegion(Seg, Region, Info, Seg.SegmentType = stIntermediateHalftoneRegion);
end;

procedure TJBig2Decoder.ProcessSegment(const Data: TBytes; const Seg: TJBig2SegmentHeader);
var
  C: TJBig2Cursor;
begin
  C.Init(Data, Seg.DataStart, Seg.DataStart + Seg.DataLength);
  case Seg.SegmentType of
    stSymbolDictionary:
      SymbolDictionary(Seg, C);
    stIntermediateTextRegion, stImmediateTextRegion, stImmediateLosslessTextRegion:
      TextRegion(Seg, C);
    stPatternDictionary:
      PatternDictionary(Seg, C);
    stIntermediateHalftoneRegion, stImmediateHalftoneRegion, stImmediateLosslessHalftoneRegion:
      HalftoneRegion(Seg, C);
    stIntermediateGenericRegion, stImmediateGenericRegion, stImmediateLosslessGenericRegion:
      GenericRegion(Seg, C);
    stIntermediateRefinementRegion, stImmediateRefinementRegion, stImmediateLosslessRefinementRegion:
      RefinementRegion(Seg, C);
    stPageInformation:
      PageInformation(C);
    stTables:
      FTables.AddOrSetValue(Seg.Number, JBig2DecodeTableSegment(Data, C.Pos, C.Finish));
    stEndOfPage, stEndOfStripe, stEndOfFile, stProfiles, stExtension:
      ;
  else
    Log(Format('segment %d: unknown type %d skipped', [Seg.Number, Seg.SegmentType]));
  end;
end;

{ Segment headers }

const
  FileHeaderId: array[0..7] of Byte = ($97, $4A, $42, $32, $0D, $0A, $1A, $0A);

/// 7.2 Segment header syntax; returns the offset of the segment data.
procedure ReadSegmentHeader(const Data: TBytes; Pos, Finish: Integer; out Header: TJBig2SegmentHeader);
var
  C: TJBig2Cursor;
  Flags, RefFlags, Count, RefSize, I, MMRFlag, J: Integer;
  Len, RegionHeight: Cardinal;
  Pattern: array[0..5] of Byte;
  PatternLength: Integer;
begin
  C.Init(Data, Pos, Finish);
  Header := Default(TJBig2SegmentHeader);
  Header.RowCount := -1;
  Header.Number := C.U32;
  Flags := C.U8;
  Header.SegmentType := Flags and $3F;
  Header.DeferredNonRetain := (Flags and $80) <> 0;
  RefFlags := C.U8;
  Count := RefFlags shr 5;
  if Count = 7 then
  begin
    // long form: 29 bit count followed by the retain bits
    Dec(C.Pos);
    Count := Integer(C.U32 and $1FFFFFFF);
    if Count > Finish - C.Pos then
      raise EJBig2Error.Create('invalid referred-to segment count');
    C.Need((Count + 8) div 8);
    Inc(C.Pos, (Count + 8) div 8);
  end
  else if Count > 4 then
    raise EJBig2Error.Create('invalid referred-to flags');
  if Header.Number <= 256 then
    RefSize := 1
  else if Header.Number <= 65536 then
    RefSize := 2
  else
    RefSize := 4;
  C.Need(Count * RefSize);
  SetLength(Header.ReferredTo, Count);
  for I := 0 to Count - 1 do
    case RefSize of
      1: Header.ReferredTo[I] := Cardinal(C.U8);
      2: Header.ReferredTo[I] := Cardinal(C.U16);
    else
      Header.ReferredTo[I] := C.U32;
    end;
  if (Flags and $40) <> 0 then
    Header.PageAssociation := C.U32
  else
    Header.PageAssociation := Cardinal(C.U8);
  Len := C.U32;
  Header.DataStart := C.Pos;
  if Len = $FFFFFFFF then
  begin
    // 7.2.7: unknown length, only for immediate generic regions; the data ends with
    // 0xFF 0xAC (arithmetic) or 0x00 0x00 (MMR) followed by the 4 byte row count
    if Header.SegmentType <> stImmediateGenericRegion then
      raise EJBig2Error.Create('invalid unknown segment length');
    C.Need(18);
    RegionHeight := (Cardinal(Data[C.Pos + 4]) shl 24) or (Cardinal(Data[C.Pos + 5]) shl 16) or
      (Cardinal(Data[C.Pos + 6]) shl 8) or Cardinal(Data[C.Pos + 7]);
    MMRFlag := Data[C.Pos + 17] and 1;
    if MMRFlag = 0 then
    begin
      Pattern[0] := $FF;
      Pattern[1] := $AC;
    end
    else
    begin
      Pattern[0] := 0;
      Pattern[1] := 0;
    end;
    Pattern[2] := Byte(RegionHeight shr 24);
    Pattern[3] := Byte(RegionHeight shr 16);
    Pattern[4] := Byte(RegionHeight shr 8);
    Pattern[5] := Byte(RegionHeight);
    // first look for the marker with the announced row count, then for the marker alone
    PatternLength := 6;
    while Header.DataLength = 0 do
    begin
      for I := C.Pos + 18 to Finish - 6 do
      begin
        J := 0;
        while (J < PatternLength) and (Data[I + J] = Pattern[J]) do
          Inc(J);
        if J = PatternLength then
        begin
          Header.DataLength := I + 6 - C.Pos;
          Header.RowCount := Integer(((Cardinal(Data[I + 2]) shl 24) or (Cardinal(Data[I + 3]) shl 16) or
            (Cardinal(Data[I + 4]) shl 8) or Cardinal(Data[I + 5])) and $7FFFFFFF);
          Break;
        end;
      end;
      if Header.DataLength > 0 then
        Break;
      if PatternLength = 2 then
        raise EJBig2Error.Create('end of segment with unknown length not found');
      PatternLength := 2;
    end;
    Header.UnknownLength := True;
  end
  else
  begin
    if Len > Cardinal(MaxInt) then
      raise EJBig2Error.Create('invalid segment length');
    Header.DataLength := Integer(Len);
  end;
end;

/// Parses all segment headers. Returns False with Error set when parsing stopped at an unusable header.
function ReadSegments(const Data: TBytes; out Headers: TArray<TJBig2SegmentHeader>; out Error: string): Boolean;
var
  Pos, Finish, Count, I: Integer;
  Header: TJBig2SegmentHeader;
  RandomAccess: Boolean;
  FileFlags: Integer;
begin
  Headers := nil;
  Error := '';
  Count := 0;
  Pos := 0;
  Finish := Integer(Length(Data));
  RandomAccess := False;
  // tolerate a full JBIG2 file (D.4 file header) instead of the embedded stream
  if (Finish >= 13) and CompareMem(@Data[0], @FileHeaderId[0], 8) then
  begin
    FileFlags := Data[8];
    Pos := 9;
    if (FileFlags and 2) = 0 then
      Inc(Pos, 4);
    RandomAccess := (FileFlags and 1) = 0;
  end;
  try
    while Pos < Finish do
    begin
      ReadSegmentHeader(Data, Pos, Finish, Header);
      if Count >= Integer(Length(Headers)) then
        SetLength(Headers, Count * 2 + 8);
      Headers[Count] := Header;
      Inc(Count);
      if RandomAccess then
        Pos := Header.DataStart
      else
        Pos := Header.DataStart + Header.DataLength;
      if Header.SegmentType = stEndOfFile then
        Break;
    end;
  except
    on E: EJBig2Error do
      Error := E.Message;
  end;
  SetLength(Headers, Count);
  if RandomAccess then
  begin
    // D.2: the data parts follow all headers in the same order
    for I := 0 to Count - 1 do
    begin
      Headers[I].DataStart := Pos;
      Inc(Pos, Headers[I].DataLength);
    end;
  end;
  Result := Error = '';
end;

procedure TJBig2Decoder.Run(const Data: TBytes; IsGlobals: Boolean);
var
  Headers: TArray<TJBig2SegmentHeader>;
  Error: string;
  I: Integer;
  Seg: TJBig2SegmentHeader;
begin
  ReadSegments(Data, Headers, Error);
  if (Length(Headers) = 0) and not IsGlobals then
  begin
    if Error = '' then
      Error := 'no segments';
    raise EPdfFilterError.Create('JBIG2Decode: ' + Error);
  end;
  if Error <> '' then
    Log('segment headers: ' + Error);
  for I := 0 to High(Headers) do
  begin
    Seg := Headers[I];
    if Seg.DataStart + Seg.DataLength > Integer(Length(Data)) then
    begin
      Log(Format('segment %d truncated', [Seg.Number]));
      Seg.DataLength := Integer(Length(Data)) - Seg.DataStart;
      if Seg.DataLength < 0 then
        Exit;
    end;
    try
      ProcessSegment(Data, Seg);
    except
      on E: Exception do
      begin
        Log(Format('segment %d (type %d): %s', [Seg.Number, Seg.SegmentType, E.Message]));
        Exit;
      end;
    end;
    if (Seg.SegmentType = stEndOfPage) or (Seg.SegmentType = stEndOfFile) then
      Exit;
  end;
end;

function TJBig2Decoder.PackPage: TBytes;
var
  Stride, X, Y, B, Bit: Integer;
  Src: PByte;
  Dst: PByte;
begin
  Stride := (FPage.Width + 7) div 8;
  SetLength(Result, Stride * FPage.Height);
  for Y := 0 to FPage.Height - 1 do
  begin
    Src := @FPage.Data[Y * FPage.Width];
    Dst := @Result[Y * Stride];
    X := 0;
    while X < FPage.Width do
    begin
      B := 0;
      for Bit := 7 downto 0 do
      begin
        if (X < FPage.Width) and (Src[X] <> 0) then
          B := B or (1 shl Bit);
        Inc(X);
      end;
      Dst^ := Byte(not B); // PDF: 0 = black
      Inc(Dst);
    end;
  end;
end;

{ Public API }

function DecodeInternal(const Data, Globals: TBytes; Width, Height: Integer; out Log: string): TBytes;
var
  Decoder: TJBig2Decoder;
begin
  if (Width <= 0) or (Height <= 0) or (Int64(Width) * Height > MaxPixels) then
    raise EPdfFilterError.CreateFmt('JBIG2Decode: invalid image size %d x %d', [Width, Height]);
  Decoder := TJBig2Decoder.Create(Width, Height);
  try
    if Length(Globals) > 0 then
      Decoder.Run(Globals, True);
    Decoder.Run(Data, False);
    Result := Decoder.PackPage;
    Log := Decoder.LogText;
  finally
    Decoder.Free;
  end;
end;

function PdfJBIG2Decode(const Data, Globals: TBytes; Width, Height: Integer): TBytes;
var
  Log: string;
begin
  Result := DecodeInternal(Data, Globals, Width, Height, Log);
end;

function PdfJBIG2DecodeWithLog(const Data, Globals: TBytes; Width, Height: Integer; out Log: string): TBytes;
begin
  Result := DecodeInternal(Data, Globals, Width, Height, Log);
end;

function PdfJBIG2ReadSegmentHeaders(const Data: TBytes): TArray<TJBig2SegmentHeader>;
var
  Error: string;
begin
  ReadSegments(Data, Result, Error);
  if (Length(Result) = 0) and (Error <> '') then
    raise EPdfFilterError.Create('JBIG2Decode: ' + Error);
end;

end.
