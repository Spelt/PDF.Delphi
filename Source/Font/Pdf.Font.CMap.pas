{*******************************************************************************
  Pdf.Font.CMap
  CMaps (ISO 32000-1 §9.7.5) for composite (Type0) fonts and ToUnicode CMaps
  (§9.10.3): embedded CMap streams, the built-in Identity-H / Identity-V, and
  the predefined Adobe CMaps, which are linked in as RCDATA resources in
  pdf.js's compact binary .bcmap format (Resources/PdfCMaps.rc).
  Portions derived from pdf.js (Mozilla, Apache License 2.0): src/core/cmap.js
  and src/core/binary_cmap.js.
*******************************************************************************}
unit Pdf.Font.CMap;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Pdf.Core.Types, Pdf.Core.Lexer;

type
  /// <summary>Maps character codes (1 to 4 bytes) to CIDs and/or Unicode text.</summary>
  /// <remarks>
  /// Codes are looked up by value and byte length; a code that is not mapped for its own byte length falls back
  /// to the same value at another byte length (pdf.js keys its maps by value only), and then to the Parent
  /// (usecmap) chain. Lookups are read-only and therefore thread-safe once the map is built.
  /// </remarks>
  TPdfCMap = class
  private type
    TCodespaceRange = record
      NumBytes: Integer;
      Low, High: Cardinal;
    end;

    /// <summary>A range that was not expanded into the lookup tables (huge 3/4-byte ranges).</summary>
    TBigRange = record
      NumBytes: Integer;
      Low, High: Cardinal;
      CID: Integer;
      Unicode: string;
      IsUnicode: Boolean;
    end;

    TBinaryNumber = array[0..15] of Byte;

    /// <summary>Reader for pdf.js's .bcmap streams (port of BinaryCMapStream).</summary>
    TBinaryReader = record
      Data: TBytes;
      Pos: Integer;
      function GetByte: Integer;
      function ReadNumber: Cardinal;
      function ReadSigned: Integer;
      procedure ReadHex(var Num: TBinaryNumber; Size: Integer);
      procedure ReadHexNumber(var Num: TBinaryNumber; Size: Integer);
      procedure ReadHexSigned(var Num: TBinaryNumber; Size: Integer);
      function ReadString: string;
    end;
  private
    FName: string;
    FVertical: Boolean;
    FWModeSet: Boolean;
    FIdentity: Boolean;
    FParent: TPdfCMap;
    FOwnsParent: Boolean;
    FCodespace: TArray<TCodespaceRange>;
    FCodespaceCount: Integer;
    FCid1: TArray<Integer>;                    // 256 entries, -1 = unmapped
    FCid2: TArray<Integer>;                    // 65536 entries, -1 = unmapped
    FCidN: TDictionary<Int64, Integer>;        // 3- and 4-byte codes, key = NumBytes shl 32 or Code
    FUnicode: TDictionary<Int64, string>;      // all lengths, same key
    FBig: TList<TBigRange>;
    FExpanded: Int64;                          // entries written by range expansion (budget)
    FUsedLengths: set of 1..4;
    function GetVertical: Boolean;
    function CodespaceSource: TPdfCMap;
    procedure SetParent(AParent: TPdfCMap; Owns: Boolean);
    procedure AddCodespace(NumBytes: Integer; Low, High: Cardinal);
    procedure AddBigRange(NumBytes: Integer; Low, High: Cardinal; CID: Integer; const Unicode: string;
      IsUnicode: Boolean);
    procedure MapCID(NumBytes: Integer; Code: Cardinal; CID: Integer);
    procedure MapCidRange(NumBytes: Integer; Low, High: Cardinal; CID: Integer);
    procedure MapUnicode(NumBytes: Integer; Code: Cardinal; const Text: string);
    procedure MapBfRange(NumBytes: Integer; Low, High: Cardinal; const Text: string);
    function FindCID(Code: Cardinal; NumBytes: Integer): Integer;
    function FindUnicode(Code: Cardinal; NumBytes: Integer; out Text: string): Boolean;
    procedure InferCodespace;
    procedure DetectIdentity;
    procedure ParseText(const Data: TBytes; out UseName: string);
    procedure ParseBinaryData(const Data: TBytes; out UseName: string);
    class function LoadResource(const Name: string): TBytes; static;
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary>Parses an embedded CMap (or ToUnicode CMap) stream. Never raises: malformed parts are
    /// skipped.</summary>
    /// <remarks>
    /// <c>usecmap</c> of a predefined name is resolved through Predefined. An embedded /UseCMap stream is the
    /// caller's business: parse it first and pass it as Parent (it then takes precedence over a usecmap
    /// operator in the data). The result does not own Parent unless OwnsParent is True. When the data defines
    /// no codespace ranges and there is no parent, they are inferred from the byte lengths of the mapped codes
    /// (one full range per length). The result is owned by the caller.
    /// </remarks>
    class function Parse(const Data: TBytes; Parent: TPdfCMap = nil; OwnsParent: Boolean = False): TPdfCMap;
      static;
    /// <summary>Parses a CMap in pdf.js's binary .bcmap format. Never raises; a truncated or corrupt stream
    /// keeps what was read. Its usecmap is resolved through Predefined. The result is owned by the caller.</summary>
    class function ParseBinary(const Data: TBytes; const Name: string = ''): TPdfCMap; static;
    /// <summary>Built-in Identity-H / Identity-V (2-byte codes, CID = code). Owned by the caller.</summary>
    class function Identity(Vertical: Boolean): TPdfCMap; static;
    /// <summary>Predefined CMap by name, or nil when unknown.</summary>
    /// <remarks>
    /// Identity-H / Identity-V are built in; the names in PredefinedNames are loaded from the PdfCMaps resources
    /// including their usecmap chain. Results are cached and owned by the unit: do not free them. Thread-safe.
    /// </remarks>
    class function Predefined(const Name: string): TPdfCMap; static;
    /// <summary>Loads a resource-backed predefined CMap without caching it (owned by the caller; its usecmap
    /// parent comes from the cache). nil when unknown.</summary>
    class function LoadPredefined(const Name: string): TPdfCMap; static;
    /// <summary>The names of the resource-backed predefined CMaps (Identity-H / Identity-V not included).</summary>
    class function PredefinedNames: TArray<string>; static;
    /// <summary>The resource name of a predefined CMap: PDFCMAP_ + upper-cased name with '-' replaced by '_'.</summary>
    class function ResourceName(const Name: string): string; static;
    /// <summary>Decodes the next code at Pos and advances Pos past it.</summary>
    /// <remarks>
    /// Tries 1..4 byte lengths; a code matches a codespace range of its own length. When no range matches, the
    /// length is taken from the first codespace range whose first-byte range contains the byte, else 1; a code
    /// cut short by the end of the data consumes the remaining bytes and gets CID 0. CID is 0 when unmapped.
    /// At or beyond the end of the data NumBytes is 0 and Pos is unchanged.
    /// </remarks>
    procedure NextCode(const Bytes: TBytes; var Pos: Integer; out Code, CID, NumBytes: Integer);
    /// <summary>CID for a code of NumBytes bytes; 0 when unmapped.</summary>
    function LookupCID(Code, NumBytes: Integer): Integer;
    /// <summary>ToUnicode text for a code ('' when unmapped). Numeric (CID) mappings are not Unicode.</summary>
    function ToUnicode(Code, NumBytes: Integer): string;
    /// <summary>True when the map (or its parent chain) contains bfchar/bfrange (Unicode) mappings.</summary>
    function HasUnicodeMappings: Boolean;
    /// <summary>True when the effective codespace contains a one-byte range (word spacing then applies to
    /// single-byte code 32).</summary>
    function HasOneByteCodes: Boolean;
    /// <summary>True for Identity-H / Identity-V (built in, or an embedded CMap of that name mapping every
    /// 2-byte code to itself).</summary>
    function IsIdentity: Boolean;
    /// <summary>/WMode 1 (inherited from the parent when not given), or a name ending in -V.</summary>
    property Vertical: Boolean read GetVertical;
    /// <summary>/CMapName, or the predefined name.</summary>
    property Name: string read FName;
    /// <summary>The usecmap target (not owned when predefined).</summary>
    property Parent: TPdfCMap read FParent;
  end;

implementation

uses
  System.Types;

const
  /// <summary>Total number of entries range expansion may write into one map (pdf.js MAX_MAP_RANGE); larger
  /// ranges are kept as unexpanded range records.</summary>
  MaxExpanded = 1 shl 24 - 1;
  /// <summary>3- and 4-byte ranges larger than this are not expanded into the dictionaries.</summary>
  MaxDictRange = 65536;

  PredefinedCMapNames: array[0..167] of string = (
    '78-EUC-H', '78-EUC-V', '78-H', '78-RKSJ-H', '78-RKSJ-V', '78-V', '78ms-RKSJ-H', '78ms-RKSJ-V',
    '83pv-RKSJ-H', '90ms-RKSJ-H', '90ms-RKSJ-V', '90msp-RKSJ-H', '90msp-RKSJ-V', '90pv-RKSJ-H', '90pv-RKSJ-V',
    'Add-H', 'Add-RKSJ-H', 'Add-RKSJ-V', 'Add-V', 'Adobe-CNS1-0', 'Adobe-CNS1-1', 'Adobe-CNS1-2', 'Adobe-CNS1-3',
    'Adobe-CNS1-4', 'Adobe-CNS1-5', 'Adobe-CNS1-6', 'Adobe-CNS1-UCS2', 'Adobe-GB1-0', 'Adobe-GB1-1',
    'Adobe-GB1-2', 'Adobe-GB1-3', 'Adobe-GB1-4', 'Adobe-GB1-5', 'Adobe-GB1-UCS2', 'Adobe-Japan1-0',
    'Adobe-Japan1-1', 'Adobe-Japan1-2', 'Adobe-Japan1-3', 'Adobe-Japan1-4', 'Adobe-Japan1-5', 'Adobe-Japan1-6',
    'Adobe-Japan1-UCS2', 'Adobe-Korea1-0', 'Adobe-Korea1-1', 'Adobe-Korea1-2', 'Adobe-Korea1-UCS2', 'B5-H',
    'B5-V', 'B5pc-H', 'B5pc-V', 'CNS-EUC-H', 'CNS-EUC-V', 'CNS1-H', 'CNS1-V', 'CNS2-H', 'CNS2-V', 'ETHK-B5-H',
    'ETHK-B5-V', 'ETen-B5-H', 'ETen-B5-V', 'ETenms-B5-H', 'ETenms-B5-V', 'EUC-H', 'EUC-V', 'Ext-H', 'Ext-RKSJ-H',
    'Ext-RKSJ-V', 'Ext-V', 'GB-EUC-H', 'GB-EUC-V', 'GB-H', 'GB-V', 'GBK-EUC-H', 'GBK-EUC-V', 'GBK2K-H',
    'GBK2K-V', 'GBKp-EUC-H', 'GBKp-EUC-V', 'GBT-EUC-H', 'GBT-EUC-V', 'GBT-H', 'GBT-V', 'GBTpc-EUC-H',
    'GBTpc-EUC-V', 'GBpc-EUC-H', 'GBpc-EUC-V', 'H', 'HKdla-B5-H', 'HKdla-B5-V', 'HKdlb-B5-H', 'HKdlb-B5-V',
    'HKgccs-B5-H', 'HKgccs-B5-V', 'HKm314-B5-H', 'HKm314-B5-V', 'HKm471-B5-H', 'HKm471-B5-V', 'HKscs-B5-H',
    'HKscs-B5-V', 'Hankaku', 'Hiragana', 'KSC-EUC-H', 'KSC-EUC-V', 'KSC-H', 'KSC-Johab-H', 'KSC-Johab-V',
    'KSC-V', 'KSCms-UHC-H', 'KSCms-UHC-HW-H', 'KSCms-UHC-HW-V', 'KSCms-UHC-V', 'KSCpc-EUC-H', 'KSCpc-EUC-V',
    'Katakana', 'NWP-H', 'NWP-V', 'RKSJ-H', 'RKSJ-V', 'Roman', 'UniCNS-UCS2-H', 'UniCNS-UCS2-V',
    'UniCNS-UTF16-H', 'UniCNS-UTF16-V', 'UniCNS-UTF32-H', 'UniCNS-UTF32-V', 'UniCNS-UTF8-H', 'UniCNS-UTF8-V',
    'UniGB-UCS2-H', 'UniGB-UCS2-V', 'UniGB-UTF16-H', 'UniGB-UTF16-V', 'UniGB-UTF32-H', 'UniGB-UTF32-V',
    'UniGB-UTF8-H', 'UniGB-UTF8-V', 'UniJIS-UCS2-H', 'UniJIS-UCS2-HW-H', 'UniJIS-UCS2-HW-V', 'UniJIS-UCS2-V',
    'UniJIS-UTF16-H', 'UniJIS-UTF16-V', 'UniJIS-UTF32-H', 'UniJIS-UTF32-V', 'UniJIS-UTF8-H', 'UniJIS-UTF8-V',
    'UniJIS2004-UTF16-H', 'UniJIS2004-UTF16-V', 'UniJIS2004-UTF32-H', 'UniJIS2004-UTF32-V', 'UniJIS2004-UTF8-H',
    'UniJIS2004-UTF8-V', 'UniJISPro-UCS2-HW-V', 'UniJISPro-UCS2-V', 'UniJISPro-UTF8-V', 'UniJISX0213-UTF32-H',
    'UniJISX0213-UTF32-V', 'UniJISX02132004-UTF32-H', 'UniJISX02132004-UTF32-V', 'UniKS-UCS2-H', 'UniKS-UCS2-V',
    'UniKS-UTF16-H', 'UniKS-UTF16-V', 'UniKS-UTF32-H', 'UniKS-UTF32-V', 'UniKS-UTF8-H', 'UniKS-UTF8-V', 'V',
    'WP-Symbol');

type
  EPdfCMapFormat = class(Exception);

var
  GLock: TObject;
  GCache: TObjectDictionary<string, TPdfCMap>;
  GLoading: TList<string>;

{ Helpers }

function MaxCode(NumBytes: Integer): Cardinal;
begin
  case NumBytes of
    1: Result := $FF;
    2: Result := $FFFF;
    3: Result := $FFFFFF;
  else
    Result := $FFFFFFFF;
  end;
end;

function MapKey(NumBytes: Integer; Code: Cardinal): Int64; inline;
begin
  Result := (Int64(NumBytes) shl 32) or Int64(Code);
end;

/// <summary>Decodes UTF-16BE bytes; an odd byte count gets a leading zero byte (pdf.js).</summary>
function Utf16BEToString(const Bytes: TBytes; Start, Len: Integer): string;
var
  I, Odd, N: Integer;
  Hi: Integer;
begin
  if Len <= 0 then
    Exit('');
  Odd := Len and 1;
  N := (Len + 1) div 2;
  SetLength(Result, N);
  for I := 0 to N - 1 do
  begin
    if (I = 0) and (Odd = 1) then
      Hi := 0
    else
      Hi := Bytes[Start + 2 * I - Odd];
    Result[I + 1] := Char((Hi shl 8) or Bytes[Start + 2 * I + 1 - Odd]);
  end;
end;

/// <summary>Text with its last UTF-16 code unit increased by Delta (bfrange destinations).</summary>
function IncrementLast(const Text: string; Delta: Cardinal): string;
var
  L: Integer;
begin
  Result := Text;
  L := Length(Result);
  if (L = 0) or (Delta = 0) then
    Exit;
  Result[L] := Char((Cardinal(Ord(Result[L])) + Delta) and $FFFF);
end;

/// <summary>A code point as a UTF-16 string ('' when invalid).</summary>
function CodePointToString(CP: Int64): string;
begin
  if (CP < 0) or (CP > $10FFFF) then
    Result := ''
  else if CP < $10000 then
    Result := Char(Word(CP))
  else
    Result := Char($D800 + ((CP - $10000) shr 10)) + Char($DC00 + ((CP - $10000) and $3FF));
end;

/// <summary>Code value and byte length of a string token; False unless it has 1..4 bytes.</summary>
function TokenCode(const T: TPdfToken; out Code: Cardinal; out NumBytes: Integer): Boolean;
var
  I: Integer;
begin
  Code := 0;
  NumBytes := Length(T.Bytes);
  Result := (T.Kind = tkString) and (NumBytes >= 1) and (NumBytes <= 4);
  if Result then
    for I := 0 to NumBytes - 1 do
      Code := (Code shl 8) or T.Bytes[I];
end;

{ Binary .bcmap helpers (pdf.js binary_cmap.js) }

function HexToInt(const A: TPdfCMap.TBinaryNumber; Size: Integer): Cardinal;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Size do
    Result := (Result shl 8) or A[I];
end;

function HexToStr(const A: TPdfCMap.TBinaryNumber; Size: Integer): string;
var
  B: TBytes;
begin
  SetLength(B, Size + 1);
  Move(A[0], B[0], Size + 1);
  Result := Utf16BEToString(B, 0, Size + 1);
end;

procedure AddHex(var A: TPdfCMap.TBinaryNumber; const B: TPdfCMap.TBinaryNumber; Size: Integer);
var
  I, C: Integer;
begin
  C := 0;
  for I := Size downto 0 do
  begin
    C := C + A[I] + B[I];
    A[I] := Byte(C and 255);
    C := C shr 8;
  end;
end;

procedure IncHex(var A: TPdfCMap.TBinaryNumber; Size: Integer);
var
  I, C: Integer;
begin
  C := 1;
  I := Size;
  while (I >= 0) and (C > 0) do
  begin
    C := C + A[I];
    A[I] := Byte(C and 255);
    C := C shr 8;
    Dec(I);
  end;
end;

{ TPdfCMap.TBinaryReader }

function TPdfCMap.TBinaryReader.GetByte: Integer;
begin
  if Pos < Length(Data) then
  begin
    Result := Data[Pos];
    Inc(Pos);
  end
  else
    Result := -1;
end;

function TPdfCMap.TBinaryReader.ReadNumber: Cardinal;
var
  B: Integer;
begin
  Result := 0;
  repeat
    B := GetByte;
    if B < 0 then
      raise EPdfCMapFormat.Create('unexpected EOF in bcmap');
    Result := (Result shl 7) or Cardinal(B and $7F);
  until B and $80 = 0;
end;

function TPdfCMap.TBinaryReader.ReadSigned: Integer;
var
  N: Cardinal;
begin
  N := ReadNumber;
  if N and 1 <> 0 then
    Result := -Integer(N shr 1) - 1
  else
    Result := Integer(N shr 1);
end;

procedure TPdfCMap.TBinaryReader.ReadHex(var Num: TBinaryNumber; Size: Integer);
begin
  if Pos + Size + 1 > Length(Data) then
    raise EPdfCMapFormat.Create('unexpected EOF in bcmap');
  Move(Data[Pos], Num[0], Size + 1);
  Inc(Pos, Size + 1);
end;

procedure TPdfCMap.TBinaryReader.ReadHexNumber(var Num: TBinaryNumber; Size: Integer);
var
  Stack: array[0..18] of Byte;
  SP, B, I, Buffer, BufferSize: Integer;
begin
  SP := 0;
  repeat
    B := GetByte;
    if B < 0 then
      raise EPdfCMapFormat.Create('unexpected EOF in bcmap');
    if SP > High(Stack) then
      raise EPdfCMapFormat.Create('number too long in bcmap');
    Stack[SP] := B and $7F;
    Inc(SP);
  until B and $80 = 0;
  I := Size;
  Buffer := 0;
  BufferSize := 0;
  while I >= 0 do
  begin
    while BufferSize < 8 do
    begin
      // pdf.js reads past the pushed digits as undefined, i.e. zero
      Dec(SP);
      if SP >= 0 then
        Buffer := Buffer or (Stack[SP] shl BufferSize);
      Inc(BufferSize, 7);
    end;
    Num[I] := Byte(Buffer and 255);
    Dec(I);
    Buffer := Buffer shr 8;
    Dec(BufferSize, 8);
  end;
end;

procedure TPdfCMap.TBinaryReader.ReadHexSigned(var Num: TBinaryNumber; Size: Integer);
var
  Sign, C, I: Integer;
begin
  ReadHexNumber(Num, Size);
  if Num[Size] and 1 <> 0 then
    Sign := 255
  else
    Sign := 0;
  C := 0;
  for I := 0 to Size do
  begin
    C := ((C and 1) shl 8) or Num[I];
    Num[I] := Byte(((C shr 1) xor Sign) and 255);
  end;
end;

function TPdfCMap.TBinaryReader.ReadString: string;
var
  Len, I: Cardinal;
  SB: TStringBuilder;
begin
  Len := ReadNumber;
  if Len > Cardinal(Length(Data)) then
    raise EPdfCMapFormat.Create('string too long in bcmap');
  SB := TStringBuilder.Create;
  try
    I := 0;
    while I < Len do
    begin
      SB.Append(Char(ReadNumber and $FFFF));
      Inc(I);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ TPdfCMap }

constructor TPdfCMap.Create;
begin
  inherited Create;
end;

destructor TPdfCMap.Destroy;
begin
  if FOwnsParent then
    FParent.Free;
  FCidN.Free;
  FUnicode.Free;
  FBig.Free;
  inherited;
end;

function TPdfCMap.GetVertical: Boolean;
begin
  Result := FVertical or FName.EndsWith('-V');
end;

procedure TPdfCMap.SetParent(AParent: TPdfCMap; Owns: Boolean);
begin
  if AParent = Self then
    Exit;
  if FOwnsParent then
    FParent.Free;
  FParent := AParent;
  FOwnsParent := Owns and (AParent <> nil);
end;

function TPdfCMap.CodespaceSource: TPdfCMap;
var
  Depth: Integer;
begin
  Result := Self;
  Depth := 0;
  while (Result.FCodespaceCount = 0) and (Result.FParent <> nil) and (Depth < 16) do
  begin
    Result := Result.FParent;
    Inc(Depth);
  end;
end;

procedure TPdfCMap.AddCodespace(NumBytes: Integer; Low, High: Cardinal);
var
  R: TCodespaceRange;
begin
  if (NumBytes < 1) or (NumBytes > 4) then
    Exit;
  R.NumBytes := NumBytes;
  R.Low := Low;
  R.High := High;
  if FCodespaceCount >= Length(FCodespace) then
    SetLength(FCodespace, FCodespaceCount * 2 + 4);
  FCodespace[FCodespaceCount] := R;
  Inc(FCodespaceCount);
end;

procedure TPdfCMap.AddBigRange(NumBytes: Integer; Low, High: Cardinal; CID: Integer; const Unicode: string;
  IsUnicode: Boolean);
var
  R: TBigRange;
begin
  if FBig = nil then
    FBig := TList<TBigRange>.Create;
  R.NumBytes := NumBytes;
  R.Low := Low;
  R.High := High;
  R.CID := CID;
  R.Unicode := Unicode;
  R.IsUnicode := IsUnicode;
  FBig.Add(R);
  Include(FUsedLengths, NumBytes);
end;

procedure TPdfCMap.MapCID(NumBytes: Integer; Code: Cardinal; CID: Integer);
begin
  if FIdentity or (CID < 0) or (NumBytes < 1) or (NumBytes > 4) or (Code > MaxCode(NumBytes)) then
    Exit;
  case NumBytes of
    1:
      begin
        if FCid1 = nil then
        begin
          SetLength(FCid1, 256);
          FillChar(FCid1[0], 256 * SizeOf(Integer), $FF);
        end;
        FCid1[Code] := CID;
      end;
    2:
      begin
        if FCid2 = nil then
        begin
          SetLength(FCid2, 65536);
          FillChar(FCid2[0], 65536 * SizeOf(Integer), $FF);
        end;
        FCid2[Code] := CID;
      end;
  else
    if FCidN = nil then
      FCidN := TDictionary<Int64, Integer>.Create;
    FCidN.AddOrSetValue(MapKey(NumBytes, Code), CID);
  end;
  Include(FUsedLengths, NumBytes);
end;

procedure TPdfCMap.MapCidRange(NumBytes: Integer; Low, High: Cardinal; CID: Integer);
var
  Count, I: Int64;
begin
  if FIdentity or (CID < 0) or (NumBytes < 1) or (NumBytes > 4) or (Low > MaxCode(NumBytes)) then
    Exit;
  if High > MaxCode(NumBytes) then
    High := MaxCode(NumBytes);
  if High < Low then
    Exit;
  Count := Int64(High) - Low + 1;
  if ((NumBytes >= 3) and (Count > MaxDictRange)) or (FExpanded + Count > MaxExpanded) then
  begin
    AddBigRange(NumBytes, Low, High, CID, '', False);
    Exit;
  end;
  Inc(FExpanded, Count);
  I := 0;
  while I < Count do
  begin
    if Int64(CID) + I > MaxInt then
      Break;
    MapCID(NumBytes, Cardinal(Low + I), Integer(CID + I));
    Inc(I);
  end;
end;

procedure TPdfCMap.MapUnicode(NumBytes: Integer; Code: Cardinal; const Text: string);
begin
  if FIdentity or (Text = '') or (NumBytes < 1) or (NumBytes > 4) or (Code > MaxCode(NumBytes)) then
    Exit;
  if FUnicode = nil then
    FUnicode := TDictionary<Int64, string>.Create;
  FUnicode.AddOrSetValue(MapKey(NumBytes, Code), Text);
  Include(FUsedLengths, NumBytes);
end;

procedure TPdfCMap.MapBfRange(NumBytes: Integer; Low, High: Cardinal; const Text: string);
var
  Count, I: Int64;
begin
  if FIdentity or (Text = '') or (NumBytes < 1) or (NumBytes > 4) or (Low > MaxCode(NumBytes)) then
    Exit;
  if High > MaxCode(NumBytes) then
    High := MaxCode(NumBytes);
  if High < Low then
    Exit;
  Count := Int64(High) - Low + 1;
  if (Count > MaxDictRange) or (FExpanded + Count > MaxExpanded) then
  begin
    AddBigRange(NumBytes, Low, High, 0, Text, True);
    Exit;
  end;
  Inc(FExpanded, Count);
  I := 0;
  while I < Count do
  begin
    MapUnicode(NumBytes, Cardinal(Low + I), IncrementLast(Text, Cardinal(I)));
    Inc(I);
  end;
end;

function TPdfCMap.FindCID(Code: Cardinal; NumBytes: Integer): Integer;
var
  I: Integer;
  R: TBigRange;
  V: Int64;
begin
  if FIdentity then
  begin
    if Code <= $FFFF then
      Exit(Integer(Code));
    Exit(-1);
  end;
  Result := -1;
  case NumBytes of
    1:
      if (FCid1 <> nil) and (Code <= $FF) then
        Result := FCid1[Code];
    2:
      if (FCid2 <> nil) and (Code <= $FFFF) then
        Result := FCid2[Code];
    3, 4:
      if (FCidN = nil) or not FCidN.TryGetValue(MapKey(NumBytes, Code), Result) then
        Result := -1;
  end;
  if (Result < 0) and (FBig <> nil) then
    for I := FBig.Count - 1 downto 0 do
    begin
      R := FBig.List[I];
      if not R.IsUnicode and (R.NumBytes = NumBytes) and (Code >= R.Low) and (Code <= R.High) then
      begin
        V := Int64(R.CID) + (Int64(Code) - R.Low);
        if V <= MaxInt then
          Result := Integer(V);
        Break;
      end;
    end;
  if (Result < 0) and (FParent <> nil) then
    Result := FParent.FindCID(Code, NumBytes);
end;

function TPdfCMap.FindUnicode(Code: Cardinal; NumBytes: Integer; out Text: string): Boolean;
var
  I: Integer;
  R: TBigRange;
begin
  Text := '';
  Result := (FUnicode <> nil) and FUnicode.TryGetValue(MapKey(NumBytes, Code), Text);
  if not Result and (FBig <> nil) then
    for I := FBig.Count - 1 downto 0 do
    begin
      R := FBig.List[I];
      if R.IsUnicode and (R.NumBytes = NumBytes) and (Code >= R.Low) and (Code <= R.High) then
      begin
        Text := IncrementLast(R.Unicode, Code - R.Low);
        Exit(True);
      end;
    end;
  if not Result and (FParent <> nil) then
    Result := FParent.FindUnicode(Code, NumBytes, Text);
end;

procedure TPdfCMap.InferCodespace;
var
  N: Integer;
begin
  for N := 1 to 4 do
    if N in FUsedLengths then
      AddCodespace(N, 0, MaxCode(N));
end;

procedure TPdfCMap.DetectIdentity;
var
  I: Integer;
begin
  // pdf.js CMapFactory: an embedded CMap named Identity-H/V that maps every 2-byte code to itself
  if not ((FName = 'Identity-H') or (FName = 'Identity-V')) or (FParent <> nil) or (FCid2 = nil) or
    (FCid1 <> nil) or (FCidN <> nil) or (FBig <> nil) or (FUnicode <> nil) then
    Exit;
  for I := 0 to $FFFF do
    if FCid2[I] <> I then
      Exit;
  FIdentity := True;
  FCid2 := nil;
  FCodespaceCount := 0;
  AddCodespace(2, 0, $FFFF);
end;

procedure TPdfCMap.ParseText(const Data: TBytes; out UseName: string);
var
  Lexer: TPdfLexer;
  Pending: TPdfToken;
  HasPending: Boolean;
  PrevName, S: string;
  T, V: TPdfToken;

  function Next: TPdfToken;
  begin
    if HasPending then
    begin
      Result := Pending;
      HasPending := False;
    end
    else
      Result := Lexer.NextToken;
  end;

  procedure PushBack(const Tok: TPdfToken);
  begin
    Pending := Tok;
    HasPending := True;
  end;

  // A token in source-code position. True for a string; Done when the block ends: its end keyword, EOF, or a
  // keyword or name that belongs to the main loop (missing end keyword; pushed back). Other junk is skipped.
  function SourceToken(const Tok: TPdfToken; const EndKeyword: string; out Done: Boolean): Boolean;
  begin
    Result := False;
    Done := False;
    case Tok.Kind of
      tkEOF:
        Done := True;
      tkString:
        Result := True;
      tkKeyword:
        begin
          Done := True;
          if not Tok.IsKeyword(EndKeyword) then
            PushBack(Tok);
        end;
      tkName:
        begin
          Done := True;
          PushBack(Tok);
        end;
    end;
  end;

  procedure ParseCodespaceRange;
  var
    Lo, Hi: TPdfToken;
    Done: Boolean;
    LoCode, HiCode: Cardinal;
    LoLen, HiLen: Integer;
  begin
    repeat
      Lo := Next;
      if not SourceToken(Lo, 'endcodespacerange', Done) then
      begin
        if Done then
          Exit;
        Continue;
      end;
      Hi := Next;
      if Hi.Kind <> tkString then
      begin
        PushBack(Hi);
        Continue;
      end;
      // pdf.js takes the code length from the high end
      if TokenCode(Lo, LoCode, LoLen) and TokenCode(Hi, HiCode, HiLen) then
        AddCodespace(HiLen, LoCode, HiCode);
    until False;
  end;

  procedure ParseCidRange;
  var
    Lo, Hi, D: TPdfToken;
    Done: Boolean;
    LoCode, HiCode: Cardinal;
    LoLen, HiLen: Integer;
  begin
    repeat
      Lo := Next;
      if not SourceToken(Lo, 'endcidrange', Done) then
      begin
        if Done then
          Exit;
        Continue;
      end;
      Hi := Next;
      if Hi.Kind <> tkString then
      begin
        PushBack(Hi);
        Continue;
      end;
      D := Next;
      if D.Kind <> tkNumber then
      begin
        PushBack(D);
        Continue;
      end;
      if TokenCode(Lo, LoCode, LoLen) and TokenCode(Hi, HiCode, HiLen) and (D.IntValue >= 0) and
        (D.IntValue <= MaxInt) then
        MapCidRange(LoLen, LoCode, HiCode, Integer(D.IntValue));
    until False;
  end;

  procedure ParseCidChar;
  var
    Src, D: TPdfToken;
    Done: Boolean;
    Code: Cardinal;
    Len: Integer;
  begin
    repeat
      Src := Next;
      if not SourceToken(Src, 'endcidchar', Done) then
      begin
        if Done then
          Exit;
        Continue;
      end;
      D := Next;
      if D.Kind <> tkNumber then
      begin
        PushBack(D);
        Continue;
      end;
      if TokenCode(Src, Code, Len) and (D.IntValue >= 0) and (D.IntValue <= MaxInt) then
        MapCID(Len, Code, Integer(D.IntValue));
    until False;
  end;

  procedure ParseBfChar;
  var
    Src, D: TPdfToken;
    Done: Boolean;
    Code: Cardinal;
    Len: Integer;
  begin
    repeat
      Src := Next;
      if not SourceToken(Src, 'endbfchar', Done) then
      begin
        if Done then
          Exit;
        Continue;
      end;
      D := Next;
      case D.Kind of
        tkString:
          if TokenCode(Src, Code, Len) then
            MapUnicode(Len, Code, Utf16BEToString(D.Bytes, 0, Length(D.Bytes)));
        tkName, tkNumber:
          ; // glyph-name / numeric destinations are not Unicode: ignored
      else
        PushBack(D);
      end;
    until False;
  end;

  procedure ParseBfRange;
  var
    Lo, Hi, D: TPdfToken;
    Done: Boolean;
    LoCode, HiCode: Cardinal;
    LoLen, HiLen: Integer;
    Index: Int64;
    Valid: Boolean;
  begin
    repeat
      Lo := Next;
      if not SourceToken(Lo, 'endbfrange', Done) then
      begin
        if Done then
          Exit;
        Continue;
      end;
      Hi := Next;
      if Hi.Kind <> tkString then
      begin
        PushBack(Hi);
        Continue;
      end;
      Valid := TokenCode(Lo, LoCode, LoLen) and TokenCode(Hi, HiCode, HiLen);
      D := Next;
      case D.Kind of
        tkString:
          if Valid then
            MapBfRange(LoLen, LoCode, HiCode, Utf16BEToString(D.Bytes, 0, Length(D.Bytes)));
        tkNumber:
          // pdf.js: String.fromCharCode(n), i.e. the code point n
          if Valid then
            MapBfRange(LoLen, LoCode, HiCode, CodePointToString(D.IntValue));
        tkArrayOpen:
          begin
            Index := 0;
            repeat
              D := Next;
              case D.Kind of
                tkArrayClose, tkEOF:
                  Break;
                tkKeyword:
                  begin
                    PushBack(D);
                    Break;
                  end;
                tkString:
                  if Valid and (Int64(LoCode) + Index <= HiCode) then
                    MapUnicode(LoLen, Cardinal(LoCode + Index), Utf16BEToString(D.Bytes, 0, Length(D.Bytes)));
              end;
              Inc(Index);
            until False;
          end;
      else
        PushBack(D);
      end;
    until False;
  end;

begin
  UseName := '';
  PrevName := '';
  HasPending := False;
  Lexer := TPdfLexer.Create(Data);
  try
    repeat
      T := Next;
      case T.Kind of
        tkEOF:
          Break;
        tkName:
          begin
            S := T.Text;
            if S = 'WMode' then
            begin
              V := Next;
              if V.Kind = tkNumber then
              begin
                FVertical := V.IntValue <> 0;
                FWModeSet := True;
              end
              else
                PushBack(V);
            end
            else if S = 'CMapName' then
            begin
              V := Next;
              if V.Kind = tkName then
                FName := V.Text
              else
                PushBack(V);
            end;
            PrevName := S;
          end;
        tkKeyword:
          if T.IsKeyword('endcmap') then
            Break
          else if T.IsKeyword('usecmap') then
          begin
            if PrevName <> '' then
              UseName := PrevName;
          end
          else if T.IsKeyword('begincodespacerange') then
            ParseCodespaceRange
          else if T.IsKeyword('begincidrange') then
            ParseCidRange
          else if T.IsKeyword('begincidchar') then
            ParseCidChar
          else if T.IsKeyword('beginbfchar') then
            ParseBfChar
          else if T.IsKeyword('beginbfrange') then
            ParseBfRange;
      end;
    until False;
  finally
    Lexer.Free;
  end;
end;

procedure TPdfCMap.ParseBinaryData(const Data: TBytes; out UseName: string);
const
  Ucs2DataSize = 1;
var
  S: TBinaryReader;
  Header, B, Typ, DataSize: Integer;
  Sequence: Boolean;
  Count, I: Cardinal;
  Start, Stop, Chr, CharCode, Tmp: TBinaryNumber;
  Code: Integer;
begin
  // Port of pdf.js BinaryCMapReader.process
  UseName := '';
  S.Data := Data;
  S.Pos := 0;
  Header := S.GetByte;
  if Header < 0 then
    Exit;
  FVertical := Header and 1 <> 0;
  FWModeSet := True;
  FillChar(Start, SizeOf(Start), 0);
  FillChar(Stop, SizeOf(Stop), 0);
  FillChar(Chr, SizeOf(Chr), 0);
  FillChar(CharCode, SizeOf(CharCode), 0);
  FillChar(Tmp, SizeOf(Tmp), 0);
  repeat
    B := S.GetByte;
    if B < 0 then
      Break;
    Typ := B shr 5;
    if Typ = 7 then
    begin
      // metadata: comment or usecmap
      case B and $1F of
        0: S.ReadString;
        1: UseName := S.ReadString;
      end;
      Continue;
    end;
    Sequence := B and $10 <> 0;
    DataSize := B and 15;
    Count := S.ReadNumber;
    case Typ of
      0: // codespacerange
        begin
          S.ReadHex(Start, DataSize);
          S.ReadHexNumber(Stop, DataSize);
          AddHex(Stop, Start, DataSize);
          AddCodespace(DataSize + 1, HexToInt(Start, DataSize), HexToInt(Stop, DataSize));
          I := 1;
          while I < Count do
          begin
            IncHex(Stop, DataSize);
            S.ReadHexNumber(Start, DataSize);
            AddHex(Start, Stop, DataSize);
            S.ReadHexNumber(Stop, DataSize);
            AddHex(Stop, Start, DataSize);
            AddCodespace(DataSize + 1, HexToInt(Start, DataSize), HexToInt(Stop, DataSize));
            Inc(I);
          end;
        end;
      1: // notdefrange: skipped
        begin
          S.ReadHex(Start, DataSize);
          S.ReadHexNumber(Stop, DataSize);
          AddHex(Stop, Start, DataSize);
          S.ReadNumber;
          I := 1;
          while I < Count do
          begin
            IncHex(Stop, DataSize);
            S.ReadHexNumber(Start, DataSize);
            AddHex(Start, Stop, DataSize);
            S.ReadHexNumber(Stop, DataSize);
            AddHex(Stop, Start, DataSize);
            S.ReadNumber;
            Inc(I);
          end;
        end;
      2: // cidchar
        begin
          S.ReadHex(Chr, DataSize);
          Code := Integer(S.ReadNumber);
          MapCID(DataSize + 1, HexToInt(Chr, DataSize), Code);
          I := 1;
          while I < Count do
          begin
            IncHex(Chr, DataSize);
            if not Sequence then
            begin
              S.ReadHexNumber(Tmp, DataSize);
              AddHex(Chr, Tmp, DataSize);
            end;
            Code := S.ReadSigned + (Code + 1);
            MapCID(DataSize + 1, HexToInt(Chr, DataSize), Code);
            Inc(I);
          end;
        end;
      3: // cidrange
        begin
          S.ReadHex(Start, DataSize);
          S.ReadHexNumber(Stop, DataSize);
          AddHex(Stop, Start, DataSize);
          Code := Integer(S.ReadNumber);
          MapCidRange(DataSize + 1, HexToInt(Start, DataSize), HexToInt(Stop, DataSize), Code);
          I := 1;
          while I < Count do
          begin
            IncHex(Stop, DataSize);
            if not Sequence then
            begin
              S.ReadHexNumber(Start, DataSize);
              AddHex(Start, Stop, DataSize);
            end
            else
              Start := Stop;
            S.ReadHexNumber(Stop, DataSize);
            AddHex(Stop, Start, DataSize);
            Code := Integer(S.ReadNumber);
            MapCidRange(DataSize + 1, HexToInt(Start, DataSize), HexToInt(Stop, DataSize), Code);
            Inc(I);
          end;
        end;
      4: // bfchar (UCS2 maps: 2-byte CID -> UTF-16BE)
        begin
          S.ReadHex(Chr, Ucs2DataSize);
          S.ReadHex(CharCode, DataSize);
          MapUnicode(Ucs2DataSize + 1, HexToInt(Chr, Ucs2DataSize), HexToStr(CharCode, DataSize));
          I := 1;
          while I < Count do
          begin
            IncHex(Chr, Ucs2DataSize);
            if not Sequence then
            begin
              S.ReadHexNumber(Tmp, Ucs2DataSize);
              AddHex(Chr, Tmp, Ucs2DataSize);
            end;
            IncHex(CharCode, DataSize);
            S.ReadHexSigned(Tmp, DataSize);
            AddHex(CharCode, Tmp, DataSize);
            MapUnicode(Ucs2DataSize + 1, HexToInt(Chr, Ucs2DataSize), HexToStr(CharCode, DataSize));
            Inc(I);
          end;
        end;
      5: // bfrange
        begin
          S.ReadHex(Start, Ucs2DataSize);
          S.ReadHexNumber(Stop, Ucs2DataSize);
          AddHex(Stop, Start, Ucs2DataSize);
          S.ReadHex(CharCode, DataSize);
          MapBfRange(Ucs2DataSize + 1, HexToInt(Start, Ucs2DataSize), HexToInt(Stop, Ucs2DataSize),
            HexToStr(CharCode, DataSize));
          I := 1;
          while I < Count do
          begin
            IncHex(Stop, Ucs2DataSize);
            if not Sequence then
            begin
              S.ReadHexNumber(Start, Ucs2DataSize);
              AddHex(Start, Stop, Ucs2DataSize);
            end
            else
              Start := Stop;
            S.ReadHexNumber(Stop, Ucs2DataSize);
            AddHex(Stop, Start, Ucs2DataSize);
            S.ReadHex(CharCode, DataSize);
            MapBfRange(Ucs2DataSize + 1, HexToInt(Start, Ucs2DataSize), HexToInt(Stop, Ucs2DataSize),
              HexToStr(CharCode, DataSize));
            Inc(I);
          end;
        end;
    else
      raise EPdfCMapFormat.CreateFmt('unknown bcmap record type %d', [Typ]);
    end;
  until False;
end;

class function TPdfCMap.Parse(const Data: TBytes; Parent: TPdfCMap; OwnsParent: Boolean): TPdfCMap;
var
  UseName: string;
begin
  Result := TPdfCMap.Create;
  try
    Result.ParseText(Data, UseName);
  except
    on Exception do
      ; // never raise: keep what was parsed
  end;
  if Parent <> nil then
    Result.SetParent(Parent, OwnsParent)
  else if UseName <> '' then
    Result.SetParent(Predefined(UseName), False);
  if not Result.FWModeSet and (Result.FParent <> nil) then
    Result.FVertical := Result.FParent.Vertical;
  if (Result.FCodespaceCount = 0) and (Result.FParent = nil) then
    Result.InferCodespace;
  Result.DetectIdentity;
end;

class function TPdfCMap.ParseBinary(const Data: TBytes; const Name: string): TPdfCMap;
var
  UseName: string;
begin
  Result := TPdfCMap.Create;
  Result.FName := Name;
  try
    Result.ParseBinaryData(Data, UseName);
  except
    on Exception do
      ; // never raise: keep what was read
  end;
  if (UseName <> '') and (UseName <> Name) then
    Result.SetParent(Predefined(UseName), False);
end;

class function TPdfCMap.Identity(Vertical: Boolean): TPdfCMap;
begin
  Result := TPdfCMap.Create;
  if Vertical then
    Result.FName := 'Identity-V'
  else
    Result.FName := 'Identity-H';
  Result.FVertical := Vertical;
  Result.FWModeSet := True;
  Result.AddCodespace(2, 0, $FFFF);
  Result.FIdentity := True;
end;

class function TPdfCMap.ResourceName(const Name: string): string;
begin
  Result := 'PDFCMAP_' + UpperCase(Name).Replace('-', '_');
end;

class function TPdfCMap.PredefinedNames: TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, Length(PredefinedCMapNames));
  for I := 0 to High(PredefinedCMapNames) do
    Result[I] := PredefinedCMapNames[I];
end;

class function TPdfCMap.LoadResource(const Name: string): TBytes;
var
  RS: TResourceStream;
begin
  Result := nil;
  try
    RS := TResourceStream.Create(HInstance, ResourceName(Name), System.Types.RT_RCDATA);
    try
      SetLength(Result, RS.Size);
      if RS.Size > 0 then
        RS.ReadBuffer(Result[0], RS.Size);
    finally
      RS.Free;
    end;
  except
    on Exception do
      Result := nil;
  end;
end;

class function TPdfCMap.LoadPredefined(const Name: string): TPdfCMap;
var
  I: Integer;
  Known: Boolean;
  Data: TBytes;
begin
  Result := nil;
  Known := False;
  for I := 0 to High(PredefinedCMapNames) do
    if PredefinedCMapNames[I] = Name then
    begin
      Known := True;
      Break;
    end;
  if not Known then
    Exit;
  Data := LoadResource(Name);
  if Data <> nil then
    Result := ParseBinary(Data, Name);
end;

class function TPdfCMap.Predefined(const Name: string): TPdfCMap;
begin
  Result := nil;
  if Name = '' then
    Exit;
  TMonitor.Enter(GLock);
  try
    if GCache.TryGetValue(Name, Result) then
      Exit;
    if (Name = 'Identity-H') or (Name = 'Identity-V') then
      Result := Identity(Name = 'Identity-V')
    else
    begin
      if GLoading.Contains(Name) then
        Exit(nil); // usecmap cycle
      GLoading.Add(Name);
      try
        Result := LoadPredefined(Name);
      finally
        GLoading.Remove(Name);
      end;
    end;
    GCache.AddOrSetValue(Name, Result); // nil results are cached too
  finally
    TMonitor.Exit(GLock);
  end;
end;

procedure TPdfCMap.NextCode(const Bytes: TBytes; var Pos: Integer; out Code, CID, NumBytes: Integer);
var
  Src: TPdfCMap;
  Len, N, K, Avail: Integer;
  C: Cardinal;
  R: TCodespaceRange;
  B: Byte;
begin
  Code := 0;
  CID := 0;
  NumBytes := 0;
  Len := Length(Bytes);
  if (Pos < 0) or (Pos >= Len) then
    Exit;
  Src := CodespaceSource;
  C := 0;
  for N := 1 to 4 do
  begin
    if Pos + N > Len then
      Break;
    C := (C shl 8) or Bytes[Pos + N - 1];
    for K := 0 to Src.FCodespaceCount - 1 do
    begin
      R := Src.FCodespace[K];
      if (R.NumBytes = N) and (C >= R.Low) and (C <= R.High) then
      begin
        Code := Integer(C);
        NumBytes := N;
        Inc(Pos, N);
        CID := LookupCID(Code, N);
        Exit;
      end;
    end;
  end;
  // No range matched: the length of the first range whose first-byte range contains the byte, else 1
  B := Bytes[Pos];
  NumBytes := 1;
  for K := 0 to Src.FCodespaceCount - 1 do
  begin
    R := Src.FCodespace[K];
    if (B >= R.Low shr (8 * (R.NumBytes - 1))) and (B <= R.High shr (8 * (R.NumBytes - 1))) then
    begin
      NumBytes := R.NumBytes;
      Break;
    end;
  end;
  Avail := NumBytes;
  if Pos + Avail > Len then
    Avail := Len - Pos;
  C := 0;
  for K := 0 to Avail - 1 do
    C := (C shl 8) or Bytes[Pos + K];
  Code := Integer(C);
  Inc(Pos, Avail);
  if Avail = NumBytes then
    CID := LookupCID(Code, NumBytes)
  else
  begin
    NumBytes := Avail; // partial code at the end of the data
    CID := 0;
  end;
end;

function TPdfCMap.LookupCID(Code, NumBytes: Integer): Integer;
var
  N: Integer;
  C: Cardinal;
begin
  C := Cardinal(Code);
  Result := FindCID(C, NumBytes);
  if Result < 0 then
    for N := 1 to 4 do
      if (N <> NumBytes) and (C <= MaxCode(N)) then
      begin
        Result := FindCID(C, N);
        if Result >= 0 then
          Break;
      end;
  if Result < 0 then
    Result := 0;
end;

function TPdfCMap.ToUnicode(Code, NumBytes: Integer): string;
var
  N: Integer;
  C: Cardinal;
begin
  C := Cardinal(Code);
  if FindUnicode(C, NumBytes, Result) then
    Exit;
  for N := 1 to 4 do
    if (N <> NumBytes) and (C <= MaxCode(N)) and FindUnicode(C, N, Result) then
      Exit;
  Result := '';
end;

function TPdfCMap.HasUnicodeMappings: Boolean;
var
  I: Integer;
begin
  Result := (FUnicode <> nil) and (FUnicode.Count > 0);
  if not Result and (FBig <> nil) then
    for I := 0 to FBig.Count - 1 do
      if FBig.List[I].IsUnicode then
        Exit(True);
  if not Result and (FParent <> nil) then
    Result := FParent.HasUnicodeMappings;
end;

function TPdfCMap.HasOneByteCodes: Boolean;
var
  Src: TPdfCMap;
  K: Integer;
begin
  Src := CodespaceSource;
  for K := 0 to Src.FCodespaceCount - 1 do
    if Src.FCodespace[K].NumBytes = 1 then
      Exit(True);
  Result := False;
end;

function TPdfCMap.IsIdentity: Boolean;
begin
  Result := FIdentity;
end;

{$R PdfCMaps.res}

initialization
  GLock := TObject.Create;
  GCache := TObjectDictionary<string, TPdfCMap>.Create([doOwnsValues]);
  GLoading := TList<string>.Create;

finalization
  GLoading.Free;
  GCache.Free;
  GLock.Free;

end.
