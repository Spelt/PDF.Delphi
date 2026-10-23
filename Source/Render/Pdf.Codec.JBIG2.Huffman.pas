{*******************************************************************************
  Pdf.Codec.JBIG2.Huffman
  Bit reader and Huffman tables of JBIG2 (ITU-T T.88 Annex B): the standard
  tables B.1-B.15, custom tables from table segments (type 53) and the prefix
  code assignment of B.3.
  Ported from pdf.js (src/core/jbig2.js, Apache License 2.0, see NOTICE).
*******************************************************************************}
unit Pdf.Codec.JBIG2.Huffman;

interface

uses
  System.SysUtils, Pdf.Codec.JBIG2.Arith;

type
  /// <summary>MSB-first bit reader over Data[Start..Finish); raises EJBig2Error at the end.</summary>
  TJBig2BitReader = class
  private
    FData: TBytes;
    FPosition: Integer;
    FEnd: Integer;
    FShift: Integer;
    FCurrent: Integer;
    procedure SetPosition(Value: Integer);
  public
    constructor Create(const Data: TBytes; Start, Finish: Integer);
    /// <summary>Reads one bit.</summary>
    function ReadBit: Integer;
    /// <summary>Reads Count (0..32) bits, most significant first.</summary>
    function ReadBits(Count: Integer): Cardinal;
    /// <summary>Skips the remaining bits of the current byte.</summary>
    procedure ByteAlign;
    /// <summary>The underlying buffer.</summary>
    property Data: TBytes read FData;
    /// <summary>Position of the next unread byte; setting it also byte-aligns.</summary>
    property Position: Integer read FPosition write SetPosition;
    /// <summary>Exclusive end of the readable data.</summary>
    property EndPos: Integer read FEnd;
  end;

  /// <summary>One table line (B.2): a range of values, an OOB line or a lower range line.</summary>
  TJBig2HuffmanLine = record
    RangeLow: Int64;
    PrefixLength: Integer;
    RangeLength: Integer;
    PrefixCode: Cardinal;
    IsLowerRange: Boolean;
    IsOOB: Boolean;
  end;

  /// <summary>A Huffman table as a binary decoding tree.</summary>
  TJBig2HuffmanTable = class
  private type
    TNode = record
      Child: array[0..1] of Integer;
      Line: Integer;
    end;
  private
    FLines: TArray<TJBig2HuffmanLine>;
    FNodes: TArray<TNode>;
    FNodeCount: Integer;
    function NewNode: Integer;
    procedure AssignPrefixCodes;
    procedure BuildTree;
  public
    /// <summary>Builds the table; with PrefixCodesDone False the codes are assigned per B.3.</summary>
    constructor Create(const Lines: TArray<TJBig2HuffmanLine>; PrefixCodesDone: Boolean);
    /// <summary>Decodes a value; returns False for the OOB code.</summary>
    function Decode(Reader: TJBig2BitReader; out Value: Integer): Boolean;
    /// <summary>Decodes a value; raises EJBig2Error for OOB.</summary>
    function DecodeValue(Reader: TJBig2BitReader): Integer;
  end;

/// <summary>Creates a normal (or lower range) table line.</summary>
function JBig2HuffmanLine(RangeLow: Int64; PrefixLength, RangeLength: Integer; PrefixCode: Cardinal = 0;
  IsLower: Boolean = False): TJBig2HuffmanLine;
/// <summary>Creates an OOB table line.</summary>
function JBig2OOBLine(PrefixLength: Integer; PrefixCode: Cardinal = 0): TJBig2HuffmanLine;
/// <summary>Creates standard table B.Number (1..15); the caller owns the result.</summary>
function JBig2StandardTable(Number: Integer): TJBig2HuffmanTable;
/// <summary>Decodes the code table of a tables segment (B.2); the caller owns the result.</summary>
function JBig2DecodeTableSegment(const Data: TBytes; Start, Finish: Integer): TJBig2HuffmanTable;

implementation

{ TJBig2BitReader }

constructor TJBig2BitReader.Create(const Data: TBytes; Start, Finish: Integer);
begin
  inherited Create;
  FData := Data;
  if Finish > Integer(Length(Data)) then
    Finish := Integer(Length(Data));
  FEnd := Finish;
  FPosition := Start;
  FShift := -1;
end;

procedure TJBig2BitReader.SetPosition(Value: Integer);
begin
  FPosition := Value;
  FShift := -1;
end;

function TJBig2BitReader.ReadBit: Integer;
begin
  if FShift < 0 then
  begin
    if (FPosition < 0) or (FPosition >= FEnd) then
      raise EJBig2Error.Create('end of data while reading bit');
    FCurrent := FData[FPosition];
    Inc(FPosition);
    FShift := 7;
  end;
  Result := (FCurrent shr FShift) and 1;
  Dec(FShift);
end;

function TJBig2BitReader.ReadBits(Count: Integer): Cardinal;
var
  I: Integer;
begin
  if (Count < 0) or (Count > 32) then
    raise EJBig2Error.CreateFmt('cannot read %d bits', [Count]);
  Result := 0;
  for I := 1 to Count do
    Result := (Result shl 1) or Cardinal(ReadBit);
end;

procedure TJBig2BitReader.ByteAlign;
begin
  FShift := -1;
end;

{ Lines }

function JBig2HuffmanLine(RangeLow: Int64; PrefixLength, RangeLength: Integer; PrefixCode: Cardinal;
  IsLower: Boolean): TJBig2HuffmanLine;
begin
  Result.RangeLow := RangeLow;
  Result.PrefixLength := PrefixLength;
  Result.RangeLength := RangeLength;
  Result.PrefixCode := PrefixCode;
  Result.IsLowerRange := IsLower;
  Result.IsOOB := False;
end;

function JBig2OOBLine(PrefixLength: Integer; PrefixCode: Cardinal): TJBig2HuffmanLine;
begin
  Result.RangeLow := 0;
  Result.PrefixLength := PrefixLength;
  Result.RangeLength := 0;
  Result.PrefixCode := PrefixCode;
  Result.IsLowerRange := False;
  Result.IsOOB := True;
end;

{ TJBig2HuffmanTable }

constructor TJBig2HuffmanTable.Create(const Lines: TArray<TJBig2HuffmanLine>; PrefixCodesDone: Boolean);
begin
  inherited Create;
  FLines := Copy(Lines);
  if not PrefixCodesDone then
    AssignPrefixCodes;
  BuildTree;
end;

procedure TJBig2HuffmanTable.AssignPrefixCodes;
var
  I, MaxLength, CurrentLength: Integer;
  Histogram: TArray<Integer>;
  FirstCode, CurrentCode: Cardinal;
begin
  // B.3 Assigning the prefix codes
  MaxLength := 0;
  for I := 0 to High(FLines) do
  begin
    if (FLines[I].PrefixLength < 0) or (FLines[I].PrefixLength > 32) then
      raise EJBig2Error.Create('invalid Huffman prefix length');
    if FLines[I].PrefixLength > MaxLength then
      MaxLength := FLines[I].PrefixLength;
  end;
  SetLength(Histogram, MaxLength + 1);
  for I := 0 to High(FLines) do
    Inc(Histogram[FLines[I].PrefixLength]);
  Histogram[0] := 0;
  FirstCode := 0;
  for CurrentLength := 1 to MaxLength do
  begin
    FirstCode := (FirstCode + Cardinal(Histogram[CurrentLength - 1])) shl 1;
    CurrentCode := FirstCode;
    for I := 0 to High(FLines) do
      if FLines[I].PrefixLength = CurrentLength then
      begin
        FLines[I].PrefixCode := CurrentCode;
        Inc(CurrentCode);
      end;
  end;
end;

function TJBig2HuffmanTable.NewNode: Integer;
begin
  if FNodeCount >= Integer(Length(FNodes)) then
    SetLength(FNodes, FNodeCount * 2 + 16);
  Result := FNodeCount;
  FNodes[Result].Child[0] := -1;
  FNodes[Result].Child[1] := -1;
  FNodes[Result].Line := -1;
  Inc(FNodeCount);
end;

procedure TJBig2HuffmanTable.BuildTree;
var
  I, Shift, Node, Bit, Next: Integer;
begin
  FNodeCount := 0;
  NewNode; // root
  for I := 0 to High(FLines) do
  begin
    if (FLines[I].PrefixLength <= 0) or (FLines[I].PrefixLength > 32) then
      Continue;
    Node := 0;
    for Shift := FLines[I].PrefixLength - 1 downto 0 do
    begin
      Bit := (FLines[I].PrefixCode shr Shift) and 1;
      Next := FNodes[Node].Child[Bit];
      if Next < 0 then
      begin
        Next := NewNode;
        FNodes[Node].Child[Bit] := Next;
      end
      else if FNodes[Next].Line >= 0 then
        Break; // prefix conflict in a corrupt table: keep the first line
      Node := Next;
      if Shift = 0 then
        FNodes[Node].Line := I;
    end;
  end;
end;

function TJBig2HuffmanTable.Decode(Reader: TJBig2BitReader; out Value: Integer): Boolean;
var
  Node, Next, Line: Integer;
  V, Offset: Int64;
begin
  Value := 0;
  Node := 0;
  repeat
    Next := FNodes[Node].Child[Reader.ReadBit];
    if Next < 0 then
      raise EJBig2Error.Create('invalid Huffman code');
    Node := Next;
  until FNodes[Node].Line >= 0;
  Line := FNodes[Node].Line;
  if FLines[Line].IsOOB then
    Exit(False);
  Offset := Reader.ReadBits(FLines[Line].RangeLength);
  if FLines[Line].IsLowerRange then
    V := FLines[Line].RangeLow - Offset
  else
    V := FLines[Line].RangeLow + Offset;
  if (V < -2147483647 - 1) or (V > 2147483647) then
    raise EJBig2Error.Create('Huffman value out of range');
  Value := Integer(V);
  Result := True;
end;

function TJBig2HuffmanTable.DecodeValue(Reader: TJBig2BitReader): Integer;
begin
  if not Decode(Reader, Result) then
    raise EJBig2Error.Create('unexpected OOB in Huffman data');
end;

{ Standard tables }

function JBig2StandardTable(Number: Integer): TJBig2HuffmanTable;
var
  Lines: TArray<TJBig2HuffmanLine>;

  procedure N(Low: Int64; PrefixLength, RangeLength: Integer; Code: Cardinal);
  begin
    Lines := Lines + [JBig2HuffmanLine(Low, PrefixLength, RangeLength, Code)];
  end;

  procedure L(Low: Int64; PrefixLength, RangeLength: Integer; Code: Cardinal);
  begin
    Lines := Lines + [JBig2HuffmanLine(Low, PrefixLength, RangeLength, Code, True)];
  end;

  procedure O(PrefixLength: Integer; Code: Cardinal);
  begin
    Lines := Lines + [JBig2OOBLine(PrefixLength, Code)];
  end;

begin
  Lines := nil;
  case Number of
    1:
      begin
        N(0, 1, 4, $0); N(16, 2, 8, $2); N(272, 3, 16, $6); N(65808, 3, 32, $7);
      end;
    2:
      begin
        N(0, 1, 0, $0); N(1, 2, 0, $2); N(2, 3, 0, $6); N(3, 4, 3, $E); N(11, 5, 6, $1E);
        N(75, 6, 32, $3E); O(6, $3F);
      end;
    3:
      begin
        N(-256, 8, 8, $FE); N(0, 1, 0, $0); N(1, 2, 0, $2); N(2, 3, 0, $6); N(3, 4, 3, $E);
        N(11, 5, 6, $1E); L(-257, 8, 32, $FF); N(75, 7, 32, $7E); O(6, $3E);
      end;
    4:
      begin
        N(1, 1, 0, $0); N(2, 2, 0, $2); N(3, 3, 0, $6); N(4, 4, 3, $E); N(12, 5, 6, $1E);
        N(76, 5, 32, $1F);
      end;
    5:
      begin
        N(-255, 7, 8, $7E); N(1, 1, 0, $0); N(2, 2, 0, $2); N(3, 3, 0, $6); N(4, 4, 3, $E);
        N(12, 5, 6, $1E); L(-256, 7, 32, $7F); N(76, 6, 32, $3E);
      end;
    6:
      begin
        N(-2048, 5, 10, $1C); N(-1024, 4, 9, $8); N(-512, 4, 8, $9); N(-256, 4, 7, $A);
        N(-128, 5, 6, $1D); N(-64, 5, 5, $1E); N(-32, 4, 5, $B); N(0, 2, 7, $0);
        N(128, 3, 7, $2); N(256, 3, 8, $3); N(512, 4, 9, $C); N(1024, 4, 10, $D);
        L(-2049, 6, 32, $3E); N(2048, 6, 32, $3F);
      end;
    7:
      begin
        N(-1024, 4, 9, $8); N(-512, 3, 8, $0); N(-256, 4, 7, $9); N(-128, 5, 6, $1A);
        N(-64, 5, 5, $1B); N(-32, 4, 5, $A); N(0, 4, 5, $B); N(32, 5, 5, $1C);
        N(64, 5, 6, $1D); N(128, 4, 7, $C); N(256, 3, 8, $1); N(512, 3, 9, $2);
        N(1024, 3, 10, $3); L(-1025, 5, 32, $1E); N(2048, 5, 32, $1F);
      end;
    8:
      begin
        N(-15, 8, 3, $FC); N(-7, 9, 1, $1FC); N(-5, 8, 1, $FD); N(-3, 9, 0, $1FD);
        N(-2, 7, 0, $7C); N(-1, 4, 0, $A); N(0, 2, 1, $0); N(2, 5, 0, $1A);
        N(3, 6, 0, $3A); N(4, 3, 4, $4); N(20, 6, 1, $3B); N(22, 4, 4, $B);
        N(38, 4, 5, $C); N(70, 5, 6, $1B); N(134, 5, 7, $1C); N(262, 6, 7, $3C);
        N(390, 7, 8, $7D); N(646, 6, 10, $3D); L(-16, 9, 32, $1FE); N(1670, 9, 32, $1FF);
        O(2, $1);
      end;
    9:
      begin
        N(-31, 8, 4, $FC); N(-15, 9, 2, $1FC); N(-11, 8, 2, $FD); N(-7, 9, 1, $1FD);
        N(-5, 7, 1, $7C); N(-3, 4, 1, $A); N(-1, 3, 1, $2); N(1, 3, 1, $3);
        N(3, 5, 1, $1A); N(5, 6, 1, $3A); N(7, 3, 5, $4); N(39, 6, 2, $3B);
        N(43, 4, 5, $B); N(75, 4, 6, $C); N(139, 5, 7, $1B); N(267, 5, 8, $1C);
        N(523, 6, 8, $3C); N(779, 7, 9, $7D); N(1291, 6, 11, $3D); L(-32, 9, 32, $1FE);
        N(3339, 9, 32, $1FF); O(2, $0);
      end;
    10:
      begin
        N(-21, 7, 4, $7A); N(-5, 8, 0, $FC); N(-4, 7, 0, $7B); N(-3, 5, 0, $18);
        N(-2, 2, 2, $0); N(2, 5, 0, $19); N(3, 6, 0, $36); N(4, 7, 0, $7C);
        N(5, 8, 0, $FD); N(6, 2, 6, $1); N(70, 5, 5, $1A); N(102, 6, 5, $37);
        N(134, 6, 6, $38); N(198, 6, 7, $39); N(326, 6, 8, $3A); N(582, 6, 9, $3B);
        N(1094, 6, 10, $3C); N(2118, 7, 11, $7D); L(-22, 8, 32, $FE); N(4166, 8, 32, $FF);
        O(2, $2);
      end;
    11:
      begin
        N(1, 1, 0, $0); N(2, 2, 1, $2); N(4, 4, 0, $C); N(5, 4, 1, $D); N(7, 5, 1, $1C);
        N(9, 5, 2, $1D); N(13, 6, 2, $3C); N(17, 7, 2, $7A); N(21, 7, 3, $7B);
        N(29, 7, 4, $7C); N(45, 7, 5, $7D); N(77, 7, 6, $7E); N(141, 7, 32, $7F);
      end;
    12:
      begin
        N(1, 1, 0, $0); N(2, 2, 0, $2); N(3, 3, 1, $6); N(5, 5, 0, $1C); N(6, 5, 1, $1D);
        N(8, 6, 1, $3C); N(10, 7, 0, $7A); N(11, 7, 1, $7B); N(13, 7, 2, $7C);
        N(17, 7, 3, $7D); N(25, 7, 4, $7E); N(41, 8, 5, $FE); N(73, 8, 32, $FF);
      end;
    13:
      begin
        N(1, 1, 0, $0); N(2, 3, 0, $4); N(3, 4, 0, $C); N(4, 5, 0, $1C); N(5, 4, 1, $D);
        N(7, 3, 3, $5); N(15, 6, 1, $3A); N(17, 6, 2, $3B); N(21, 6, 3, $3C);
        N(29, 6, 4, $3D); N(45, 6, 5, $3E); N(77, 7, 6, $7E); N(141, 7, 32, $7F);
      end;
    14:
      begin
        N(-2, 3, 0, $4); N(-1, 3, 0, $5); N(0, 1, 0, $0); N(1, 3, 0, $6); N(2, 3, 0, $7);
      end;
    15:
      begin
        N(-24, 7, 4, $7C); N(-8, 6, 2, $3C); N(-4, 5, 1, $1C); N(-2, 4, 0, $C);
        N(-1, 3, 0, $4); N(0, 1, 0, $0); N(1, 3, 0, $5); N(2, 4, 0, $D);
        N(3, 5, 1, $1D); N(5, 6, 2, $3D); N(9, 7, 4, $7D); L(-25, 7, 32, $7E);
        N(25, 7, 32, $7F);
      end;
  else
    raise EJBig2Error.CreateFmt('standard table B.%d does not exist', [Number]);
  end;
  Result := TJBig2HuffmanTable.Create(Lines, True);
end;

function JBig2DecodeTableSegment(const Data: TBytes; Start, Finish: Integer): TJBig2HuffmanTable;

  function ReadInt32(Pos: Integer): Int64;
  begin
    Result := Int32((Cardinal(Data[Pos]) shl 24) or (Cardinal(Data[Pos + 1]) shl 16) or
      (Cardinal(Data[Pos + 2]) shl 8) or Cardinal(Data[Pos + 3]));
  end;

var
  Flags, PrefixSizeBits, RangeSizeBits, PrefixLength, RangeLength: Integer;
  LowestValue, HighestValue, CurrentRangeLow: Int64;
  Reader: TJBig2BitReader;
  Lines: TArray<TJBig2HuffmanLine>;
begin
  // B.2 Code table structure
  if Finish > Integer(Length(Data)) then
    Finish := Integer(Length(Data));
  if Start + 9 > Finish then
    raise EJBig2Error.Create('tables segment too short');
  Flags := Data[Start];
  LowestValue := ReadInt32(Start + 1);
  HighestValue := ReadInt32(Start + 5);
  if HighestValue < LowestValue then
    raise EJBig2Error.Create('invalid code table range');
  PrefixSizeBits := ((Flags shr 1) and 7) + 1;
  RangeSizeBits := ((Flags shr 4) and 7) + 1;
  Lines := nil;
  Reader := TJBig2BitReader.Create(Data, Start + 9, Finish);
  try
    CurrentRangeLow := LowestValue;
    repeat
      PrefixLength := Integer(Reader.ReadBits(PrefixSizeBits));
      RangeLength := Integer(Reader.ReadBits(RangeSizeBits));
      if RangeLength > 32 then
        raise EJBig2Error.Create('invalid code table range length');
      Lines := Lines + [JBig2HuffmanLine(CurrentRangeLow, PrefixLength, RangeLength)];
      Inc(CurrentRangeLow, Int64(1) shl RangeLength);
      if Length(Lines) > 65536 then
        raise EJBig2Error.Create('code table too large');
    until CurrentRangeLow >= HighestValue;
    // lower range line
    PrefixLength := Integer(Reader.ReadBits(PrefixSizeBits));
    Lines := Lines + [JBig2HuffmanLine(LowestValue - 1, PrefixLength, 32, 0, True)];
    // upper range line
    PrefixLength := Integer(Reader.ReadBits(PrefixSizeBits));
    Lines := Lines + [JBig2HuffmanLine(HighestValue, PrefixLength, 32)];
    if (Flags and 1) <> 0 then
    begin
      PrefixLength := Integer(Reader.ReadBits(PrefixSizeBits));
      Lines := Lines + [JBig2OOBLine(PrefixLength)];
    end;
  finally
    Reader.Free;
  end;
  Result := TJBig2HuffmanTable.Create(Lines, False);
end;

end.
