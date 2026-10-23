{*******************************************************************************
  Pdf.Core.Objects
  The PDF object model (ISO 32000-1 §7.3): null, boolean, number, string,
  name, array, dictionary, stream and indirect reference, plus an operator
  object used by content streams. Objects are reference counted through
  interfaces. Containers carry an IPdfResolver so that indirect references
  can be followed transparently with Get(...).
*******************************************************************************}
unit Pdf.Core.Objects;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.Math,
  Pdf.Core.Types;

type
  TPdfObjectKind = (okNull, okBoolean, okInteger, okReal, okString, okName,
    okArray, okDictionary, okStream, okReference, okOperator);

  IPdfObject = interface;
  IPdfArray = interface;
  IPdfDictionary = interface;
  IPdfStream = interface;

  /// <summary>Follows indirect references. Implemented by the cross-reference table of a document.</summary>
  IPdfResolver = interface
    ['{6C7E7D3A-5C1A-4F8E-9D2B-0F4E9A1B2C3D}']
    /// <summary>Returns the object itself, or the referenced object for an IPdfReference (never nil: missing objects resolve to null).</summary>
    function Resolve(const Obj: IPdfObject): IPdfObject;
    function FetchObject(Num, Gen: Integer): IPdfObject;
  end;

  IPdfObject = interface
    ['{A1B2C3D4-0001-4000-8000-000000000001}']
    function GetKind: TPdfObjectKind;
    property Kind: TPdfObjectKind read GetKind;
    /// <summary>PDF-like textual representation for debugging and tests.</summary>
    function ToText: string;
  end;

  IPdfBoolean = interface(IPdfObject)
    ['{A1B2C3D4-0002-4000-8000-000000000002}']
    function GetValue: Boolean;
    property Value: Boolean read GetValue;
  end;

  IPdfNumber = interface(IPdfObject)
    ['{A1B2C3D4-0003-4000-8000-000000000003}']
    function GetValue: Double;
    function GetIsInteger: Boolean;
    function GetIntValue: Int64;
    property Value: Double read GetValue;
    property IsInteger: Boolean read GetIsInteger;
    property IntValue: Int64 read GetIntValue;
  end;

  IPdfString = interface(IPdfObject)
    ['{A1B2C3D4-0004-4000-8000-000000000004}']
    function GetBytes: TBytes;
    function GetIsHex: Boolean;
    /// <summary>Decodes the text string: UTF-16 (BOM FE FF), UTF-8 (BOM EF BB BF) or PDFDocEncoding.</summary>
    function AsText: string;
    property Bytes: TBytes read GetBytes;
    property IsHex: Boolean read GetIsHex;
  end;

  IPdfName = interface(IPdfObject)
    ['{A1B2C3D4-0005-4000-8000-000000000005}']
    function GetName: string;
    property Name: string read GetName;
  end;

  IPdfReference = interface(IPdfObject)
    ['{A1B2C3D4-0006-4000-8000-000000000006}']
    function GetNum: Integer;
    function GetGen: Integer;
    property Num: Integer read GetNum;
    property Gen: Integer read GetGen;
  end;

  /// <summary>A content-stream operator (or any keyword the parser does not know).</summary>
  IPdfOperator = interface(IPdfObject)
    ['{A1B2C3D4-0007-4000-8000-000000000007}']
    function GetName: string;
    property Name: string read GetName;
  end;

  IPdfArray = interface(IPdfObject)
    ['{A1B2C3D4-0008-4000-8000-000000000008}']
    function GetCount: Integer;
    function GetItem(Index: Integer): IPdfObject;
    procedure SetItem(Index: Integer; const Obj: IPdfObject);
    function GetResolver: IPdfResolver;
    procedure SetResolver(const Value: IPdfResolver);
    /// <summary>Item with indirect references resolved (null object when out of range).</summary>
    function Get(Index: Integer): IPdfObject;
    procedure Add(const Obj: IPdfObject);
    procedure Insert(Index: Integer; const Obj: IPdfObject);
    procedure Delete(Index: Integer);
    procedure Clear;
    function GetNumber(Index: Integer; Default: Double = 0): Double;
    function GetInteger(Index: Integer; Default: Int64 = 0): Int64;
    function GetName(Index: Integer; const Default: string = ''): string;
    function GetArray(Index: Integer): IPdfArray;
    function GetDictionary(Index: Integer): IPdfDictionary;
    function GetStream(Index: Integer): IPdfStream;
    /// <summary>Copies the first Count numeric items into Values; returns False when any item is not a number.</summary>
    function GetNumbers(out Values: TArray<Double>; Count: Integer = -1): Boolean;
    property Count: Integer read GetCount;
    /// <summary>Raw item (references not resolved).</summary>
    property Items[Index: Integer]: IPdfObject read GetItem write SetItem; default;
    property Resolver: IPdfResolver read GetResolver write SetResolver;
  end;

  IPdfDictionary = interface(IPdfObject)
    ['{A1B2C3D4-0009-4000-8000-000000000009}']
    function GetCount: Integer;
    function GetKey(Index: Integer): string;
    function GetResolver: IPdfResolver;
    procedure SetResolver(const Value: IPdfResolver);
    function Contains(const Key: string): Boolean;
    /// <summary>Raw value (references not resolved); nil when the key is absent.</summary>
    function GetRaw(const Key: string): IPdfObject;
    /// <summary>Value with indirect references resolved; the null object when absent.</summary>
    function Get(const Key: string): IPdfObject; overload;
    /// <summary>Looks up Key1, then Key2 (for abbreviations such as /Filter and /F).</summary>
    function Get(const Key1, Key2: string): IPdfObject; overload;
    procedure SetValue(const Key: string; const Obj: IPdfObject);
    procedure Remove(const Key: string);
    procedure Clear;
    function GetNumber(const Key: string; Default: Double = 0): Double;
    function GetInteger(const Key: string; Default: Int64 = 0): Int64;
    function GetBoolean(const Key: string; Default: Boolean = False): Boolean;
    function GetName(const Key: string; const Default: string = ''): string;
    function GetString(const Key: string): IPdfString;
    function GetArray(const Key: string): IPdfArray;
    /// <summary>Returns the dictionary for Key; for a stream value its stream dictionary. nil when absent or of another type.</summary>
    function GetDictionary(const Key: string): IPdfDictionary;
    function GetStream(const Key: string): IPdfStream;
    /// <summary>Reads a 4-number array as rectangle; returns False when absent or malformed.</summary>
    function GetRectangle(const Key: string; out R: TPdfRectangle): Boolean;
    /// <summary>True when /Type (or /Subtype when CheckSubtype) equals Name.</summary>
    function IsType(const Name: string): Boolean;
    function Keys: TArray<string>;
    property Count: Integer read GetCount;
    property Resolver: IPdfResolver read GetResolver write SetResolver;
  end;

  IPdfStream = interface(IPdfObject)
    ['{A1B2C3D4-000A-4000-8000-00000000000A}']
    function GetDict: IPdfDictionary;
    function GetRawData: TBytes;
    procedure SetRawData(const Value: TBytes);
    function GetObjNum: Integer;
    function GetObjGen: Integer;
    procedure SetObjectNumber(Num, Gen: Integer);
    /// <summary>Data after applying all standard filters; image codecs (DCT, JPX, JBIG2, CCITT) are left in place, see ImageFilter.</summary>
    function GetDecodedData: TBytes;
    /// <summary>Name of the remaining image filter ('' when fully decoded), set after GetDecodedData.</summary>
    function GetImageFilter: string;
    /// <summary>Decode parameters of the remaining image filter (may be nil).</summary>
    function GetImageFilterParms: IPdfDictionary;
    /// <summary>Filter names in order, abbreviations expanded.</summary>
    function GetFilterNames: TArray<string>;
    property Dict: IPdfDictionary read GetDict;
    /// <summary>Encoded bytes exactly as stored in the file (after decryption).</summary>
    property RawData: TBytes read GetRawData write SetRawData;
    property ObjNum: Integer read GetObjNum;
    property ObjGen: Integer read GetObjGen;
    property ImageFilter: string read GetImageFilter;
    property ImageFilterParms: IPdfDictionary read GetImageFilterParms;
  end;

{ Factories }

function PdfNull: IPdfObject;
function PdfBoolean(Value: Boolean): IPdfBoolean;
function PdfInteger(Value: Int64): IPdfNumber;
function PdfReal(Value: Double): IPdfNumber;
function PdfString(const Bytes: TBytes; IsHex: Boolean = False): IPdfString; overload;
function PdfString(const Text: string): IPdfString; overload;
function PdfName(const Name: string): IPdfName;
function PdfReference(Num, Gen: Integer): IPdfReference;
function PdfOperator(const Name: string): IPdfOperator;
function PdfArray(const Resolver: IPdfResolver = nil): IPdfArray;
function PdfDictionary(const Resolver: IPdfResolver = nil): IPdfDictionary;
function PdfStream(const Dict: IPdfDictionary; const RawData: TBytes): IPdfStream;

{ Type helpers (all accept nil) }

function PdfIsNull(const Obj: IPdfObject): Boolean; inline;
function PdfIsNumber(const Obj: IPdfObject): Boolean; inline;
function PdfIsName(const Obj: IPdfObject): Boolean; overload; inline;
function PdfIsName(const Obj: IPdfObject; const Name: string): Boolean; overload;
function PdfIsOperator(const Obj: IPdfObject; const Name: string): Boolean;
function PdfAsNumber(const Obj: IPdfObject; Default: Double = 0): Double;
function PdfAsInteger(const Obj: IPdfObject; Default: Int64 = 0): Int64;
function PdfAsBoolean(const Obj: IPdfObject; Default: Boolean = False): Boolean;
function PdfAsName(const Obj: IPdfObject; const Default: string = ''): string;
function PdfAsString(const Obj: IPdfObject): IPdfString;
function PdfAsArray(const Obj: IPdfObject): IPdfArray;
/// <summary>Dictionary of a dictionary or stream object; nil otherwise.</summary>
function PdfAsDictionary(const Obj: IPdfObject): IPdfDictionary;
function PdfAsStream(const Obj: IPdfObject): IPdfStream;
function PdfAsReference(const Obj: IPdfObject): IPdfReference;
/// <summary>Resolves Obj through Resolver when both are assigned; otherwise returns Obj (or null for nil).</summary>
function PdfResolve(const Resolver: IPdfResolver; const Obj: IPdfObject): IPdfObject;
/// <summary>Decodes a PDF text string (UTF-16BE/UTF-8 BOM or PDFDocEncoding).</summary>
function PdfDecodeTextString(const Bytes: TBytes): string;

implementation

uses
  Pdf.Core.Filters;

type
  TPdfObject = class(TInterfacedObject, IPdfObject)
  protected
    function GetKind: TPdfObjectKind; virtual; abstract;
  public
    function ToText: string; virtual; abstract;
  end;

  TPdfNullObject = class(TPdfObject)
  protected
    function GetKind: TPdfObjectKind; override;
  public
    function ToText: string; override;
  end;

  TPdfBooleanObject = class(TPdfObject, IPdfBoolean)
  private
    FValue: Boolean;
  protected
    function GetKind: TPdfObjectKind; override;
    function GetValue: Boolean;
  public
    constructor Create(AValue: Boolean);
    function ToText: string; override;
  end;

  TPdfNumberObject = class(TPdfObject, IPdfNumber)
  private
    FValue: Double;
    FIntValue: Int64;
    FIsInteger: Boolean;
  protected
    function GetKind: TPdfObjectKind; override;
    function GetValue: Double;
    function GetIsInteger: Boolean;
    function GetIntValue: Int64;
  public
    constructor CreateInteger(AValue: Int64);
    constructor CreateReal(AValue: Double);
    function ToText: string; override;
  end;

  TPdfStringObject = class(TPdfObject, IPdfString)
  private
    FBytes: TBytes;
    FIsHex: Boolean;
  protected
    function GetKind: TPdfObjectKind; override;
    function GetBytes: TBytes;
    function GetIsHex: Boolean;
  public
    constructor Create(const ABytes: TBytes; AIsHex: Boolean);
    function AsText: string;
    function ToText: string; override;
  end;

  TPdfNameObject = class(TPdfObject, IPdfName)
  private
    FName: string;
  protected
    function GetKind: TPdfObjectKind; override;
    function GetName: string;
  public
    constructor Create(const AName: string);
    function ToText: string; override;
  end;

  TPdfReferenceObject = class(TPdfObject, IPdfReference)
  private
    FNum, FGen: Integer;
  protected
    function GetKind: TPdfObjectKind; override;
    function GetNum: Integer;
    function GetGen: Integer;
  public
    constructor Create(ANum, AGen: Integer);
    function ToText: string; override;
  end;

  TPdfOperatorObject = class(TPdfObject, IPdfOperator)
  private
    FName: string;
  protected
    function GetKind: TPdfObjectKind; override;
    function GetName: string;
  public
    constructor Create(const AName: string);
    function ToText: string; override;
  end;

  TPdfArrayObject = class(TPdfObject, IPdfArray)
  private
    FItems: TList<IPdfObject>;
    FResolver: IPdfResolver;
  protected
    function GetKind: TPdfObjectKind; override;
    function GetCount: Integer;
    function GetItem(Index: Integer): IPdfObject;
    procedure SetItem(Index: Integer; const Obj: IPdfObject);
    function GetResolver: IPdfResolver;
    procedure SetResolver(const Value: IPdfResolver);
  public
    constructor Create(const AResolver: IPdfResolver);
    destructor Destroy; override;
    function Get(Index: Integer): IPdfObject;
    procedure Add(const Obj: IPdfObject);
    procedure Insert(Index: Integer; const Obj: IPdfObject);
    procedure Delete(Index: Integer);
    procedure Clear;
    function GetNumber(Index: Integer; Default: Double = 0): Double;
    function GetInteger(Index: Integer; Default: Int64 = 0): Int64;
    function GetName(Index: Integer; const Default: string = ''): string;
    function GetArray(Index: Integer): IPdfArray;
    function GetDictionary(Index: Integer): IPdfDictionary;
    function GetStream(Index: Integer): IPdfStream;
    function GetNumbers(out Values: TArray<Double>; Count: Integer = -1): Boolean;
    function ToText: string; override;
  end;

  TPdfDictionaryObject = class(TPdfObject, IPdfDictionary)
  private
    FKeys: TList<string>;
    FValues: TDictionary<string, IPdfObject>;
    FResolver: IPdfResolver;
  protected
    function GetKind: TPdfObjectKind; override;
    function GetCount: Integer;
    function GetKey(Index: Integer): string;
    function GetResolver: IPdfResolver;
    procedure SetResolver(const Value: IPdfResolver);
  public
    constructor Create(const AResolver: IPdfResolver);
    destructor Destroy; override;
    function Contains(const Key: string): Boolean;
    function GetRaw(const Key: string): IPdfObject;
    function Get(const Key: string): IPdfObject; overload;
    function Get(const Key1, Key2: string): IPdfObject; overload;
    procedure SetValue(const Key: string; const Obj: IPdfObject);
    procedure Remove(const Key: string);
    procedure Clear;
    function GetNumber(const Key: string; Default: Double = 0): Double;
    function GetInteger(const Key: string; Default: Int64 = 0): Int64;
    function GetBoolean(const Key: string; Default: Boolean = False): Boolean;
    function GetName(const Key: string; const Default: string = ''): string;
    function GetString(const Key: string): IPdfString;
    function GetArray(const Key: string): IPdfArray;
    function GetDictionary(const Key: string): IPdfDictionary;
    function GetStream(const Key: string): IPdfStream;
    function GetRectangle(const Key: string; out R: TPdfRectangle): Boolean;
    function IsType(const Name: string): Boolean;
    function Keys: TArray<string>;
    function ToText: string; override;
  end;

  TPdfStreamObject = class(TPdfObject, IPdfStream)
  private
    FDict: IPdfDictionary;
    FRawData: TBytes;
    FDecodedData: TBytes;
    FDecoded: Boolean;
    FImageFilter: string;
    FImageFilterParms: IPdfDictionary;
    FObjNum, FObjGen: Integer;
    procedure Decode;
  protected
    function GetKind: TPdfObjectKind; override;
    function GetDict: IPdfDictionary;
    function GetRawData: TBytes;
    procedure SetRawData(const Value: TBytes);
    function GetObjNum: Integer;
    function GetObjGen: Integer;
    function GetImageFilter: string;
    function GetImageFilterParms: IPdfDictionary;
  public
    constructor Create(const ADict: IPdfDictionary; const ARawData: TBytes);
    procedure SetObjectNumber(Num, Gen: Integer);
    function GetDecodedData: TBytes;
    function GetFilterNames: TArray<string>;
    function ToText: string; override;
  end;

var
  GNull: IPdfObject;

{ Factories }

function PdfNull: IPdfObject;
begin
  if GNull = nil then
    GNull := TPdfNullObject.Create;
  Result := GNull;
end;

function PdfBoolean(Value: Boolean): IPdfBoolean;
begin
  Result := TPdfBooleanObject.Create(Value);
end;

function PdfInteger(Value: Int64): IPdfNumber;
begin
  Result := TPdfNumberObject.CreateInteger(Value);
end;

function PdfReal(Value: Double): IPdfNumber;
begin
  Result := TPdfNumberObject.CreateReal(Value);
end;

function PdfString(const Bytes: TBytes; IsHex: Boolean): IPdfString;
begin
  Result := TPdfStringObject.Create(Bytes, IsHex);
end;

function PdfString(const Text: string): IPdfString;
begin
  Result := TPdfStringObject.Create(PdfLatin1ToBytes(Text), False);
end;

function PdfName(const Name: string): IPdfName;
begin
  Result := TPdfNameObject.Create(Name);
end;

function PdfReference(Num, Gen: Integer): IPdfReference;
begin
  Result := TPdfReferenceObject.Create(Num, Gen);
end;

function PdfOperator(const Name: string): IPdfOperator;
begin
  Result := TPdfOperatorObject.Create(Name);
end;

function PdfArray(const Resolver: IPdfResolver): IPdfArray;
begin
  Result := TPdfArrayObject.Create(Resolver);
end;

function PdfDictionary(const Resolver: IPdfResolver): IPdfDictionary;
begin
  Result := TPdfDictionaryObject.Create(Resolver);
end;

function PdfStream(const Dict: IPdfDictionary; const RawData: TBytes): IPdfStream;
begin
  Result := TPdfStreamObject.Create(Dict, RawData);
end;

{ Type helpers }

function PdfIsNull(const Obj: IPdfObject): Boolean;
begin
  Result := (Obj = nil) or (Obj.Kind = okNull);
end;

function PdfIsNumber(const Obj: IPdfObject): Boolean;
begin
  Result := (Obj <> nil) and (Obj.Kind in [okInteger, okReal]);
end;

function PdfIsName(const Obj: IPdfObject): Boolean;
begin
  Result := (Obj <> nil) and (Obj.Kind = okName);
end;

function PdfIsName(const Obj: IPdfObject; const Name: string): Boolean;
begin
  Result := (Obj <> nil) and (Obj.Kind = okName) and ((Obj as IPdfName).Name = Name);
end;

function PdfIsOperator(const Obj: IPdfObject; const Name: string): Boolean;
begin
  Result := (Obj <> nil) and (Obj.Kind = okOperator) and ((Obj as IPdfOperator).Name = Name);
end;

function PdfAsNumber(const Obj: IPdfObject; Default: Double): Double;
begin
  if PdfIsNumber(Obj) then
    Result := (Obj as IPdfNumber).Value
  else
    Result := Default;
end;

function PdfAsInteger(const Obj: IPdfObject; Default: Int64): Int64;
begin
  if PdfIsNumber(Obj) then
    Result := (Obj as IPdfNumber).IntValue
  else
    Result := Default;
end;

function PdfAsBoolean(const Obj: IPdfObject; Default: Boolean): Boolean;
begin
  if (Obj <> nil) and (Obj.Kind = okBoolean) then
    Result := (Obj as IPdfBoolean).Value
  else
    Result := Default;
end;

function PdfAsName(const Obj: IPdfObject; const Default: string): string;
begin
  if PdfIsName(Obj) then
    Result := (Obj as IPdfName).Name
  else
    Result := Default;
end;

function PdfAsString(const Obj: IPdfObject): IPdfString;
begin
  if (Obj <> nil) and (Obj.Kind = okString) then
    Result := Obj as IPdfString
  else
    Result := nil;
end;

function PdfAsArray(const Obj: IPdfObject): IPdfArray;
begin
  if (Obj <> nil) and (Obj.Kind = okArray) then
    Result := Obj as IPdfArray
  else
    Result := nil;
end;

function PdfAsDictionary(const Obj: IPdfObject): IPdfDictionary;
begin
  if Obj = nil then
    Exit(nil);
  case Obj.Kind of
    okDictionary: Result := Obj as IPdfDictionary;
    okStream: Result := (Obj as IPdfStream).Dict;
  else
    Result := nil;
  end;
end;

function PdfAsStream(const Obj: IPdfObject): IPdfStream;
begin
  if (Obj <> nil) and (Obj.Kind = okStream) then
    Result := Obj as IPdfStream
  else
    Result := nil;
end;

function PdfAsReference(const Obj: IPdfObject): IPdfReference;
begin
  if (Obj <> nil) and (Obj.Kind = okReference) then
    Result := Obj as IPdfReference
  else
    Result := nil;
end;

function PdfResolve(const Resolver: IPdfResolver; const Obj: IPdfObject): IPdfObject;
begin
  if Obj = nil then
    Result := PdfNull
  else if (Resolver <> nil) and (Obj.Kind = okReference) then
    Result := Resolver.Resolve(Obj)
  else
    Result := Obj;
end;

const
  // PDFDocEncoding for the ranges that differ from Latin-1 (0x18-0x1F, 0x7F-0xA0, 0xAD).
  PdfDocEncodingLow: array[$18..$1F] of Word = (
    $02D8, $02C7, $02C6, $02D9, $02DD, $02DB, $02DA, $02DC);
  PdfDocEncodingHigh: array[$7F..$A0] of Word = (
    $FFFD, $2022, $2020, $2021, $2026, $2014, $2013, $0192, $2044, $2039, $203A,
    $2212, $2030, $201E, $201C, $201D, $2018, $2019, $201A, $2122, $FB01, $FB02,
    $0141, $0152, $0160, $0178, $017D, $0131, $0142, $0153, $0161, $017E, $FFFD,
    $20AC);

function PdfDecodeTextString(const Bytes: TBytes): string;
var
  I, N: Integer;
  W: Word;
  SB: TStringBuilder;
begin
  N := Length(Bytes);
  if N = 0 then
    Exit('');
  if (N >= 2) and (Bytes[0] = $FE) and (Bytes[1] = $FF) then
  begin
    SB := TStringBuilder.Create;
    try
      I := 2;
      while I + 1 < N do
      begin
        W := (Bytes[I] shl 8) or Bytes[I + 1];
        SB.Append(Char(W));
        Inc(I, 2);
      end;
      Result := SB.ToString;
    finally
      SB.Free;
    end;
    Exit;
  end;
  if (N >= 2) and (Bytes[0] = $FF) and (Bytes[1] = $FE) then
  begin
    // Little-endian BOM is not allowed by the spec but occurs
    SB := TStringBuilder.Create;
    try
      I := 2;
      while I + 1 < N do
      begin
        W := (Bytes[I + 1] shl 8) or Bytes[I];
        SB.Append(Char(W));
        Inc(I, 2);
      end;
      Result := SB.ToString;
    finally
      SB.Free;
    end;
    Exit;
  end;
  if (N >= 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and (Bytes[2] = $BF) then
    Exit(TEncoding.UTF8.GetString(Bytes, 3, N - 3));
  SetLength(Result, N);
  for I := 0 to N - 1 do
  begin
    case Bytes[I] of
      $18..$1F: W := PdfDocEncodingLow[Bytes[I]];
      $7F..$A0: W := PdfDocEncodingHigh[Bytes[I]];
      $AD: W := $FFFD;
    else
      W := Bytes[I];
    end;
    Result[I + 1] := Char(W);
  end;
end;

{ TPdfNullObject }

function TPdfNullObject.GetKind: TPdfObjectKind;
begin
  Result := okNull;
end;

function TPdfNullObject.ToText: string;
begin
  Result := 'null';
end;

{ TPdfBooleanObject }

constructor TPdfBooleanObject.Create(AValue: Boolean);
begin
  inherited Create;
  FValue := AValue;
end;

function TPdfBooleanObject.GetKind: TPdfObjectKind;
begin
  Result := okBoolean;
end;

function TPdfBooleanObject.GetValue: Boolean;
begin
  Result := FValue;
end;

function TPdfBooleanObject.ToText: string;
begin
  if FValue then
    Result := 'true'
  else
    Result := 'false';
end;

{ TPdfNumberObject }

constructor TPdfNumberObject.CreateInteger(AValue: Int64);
begin
  inherited Create;
  FIntValue := AValue;
  FValue := AValue;
  FIsInteger := True;
end;

constructor TPdfNumberObject.CreateReal(AValue: Double);
begin
  inherited Create;
  FValue := AValue;
  FIsInteger := False;
  if Abs(AValue) < 9.2E18 then
    FIntValue := Trunc(AValue)
  else
    FIntValue := 0;
end;

function TPdfNumberObject.GetKind: TPdfObjectKind;
begin
  if FIsInteger then
    Result := okInteger
  else
    Result := okReal;
end;

function TPdfNumberObject.GetValue: Double;
begin
  Result := FValue;
end;

function TPdfNumberObject.GetIsInteger: Boolean;
begin
  Result := FIsInteger;
end;

function TPdfNumberObject.GetIntValue: Int64;
begin
  Result := FIntValue;
end;

function TPdfNumberObject.ToText: string;
var
  FS: TFormatSettings;
begin
  if FIsInteger then
    Result := IntToStr(FIntValue)
  else
  begin
    FS := TFormatSettings.Invariant;
    Result := FloatToStrF(FValue, ffGeneral, 10, 0, FS);
  end;
end;

{ TPdfStringObject }

constructor TPdfStringObject.Create(const ABytes: TBytes; AIsHex: Boolean);
begin
  inherited Create;
  FBytes := ABytes;
  FIsHex := AIsHex;
end;

function TPdfStringObject.GetKind: TPdfObjectKind;
begin
  Result := okString;
end;

function TPdfStringObject.GetBytes: TBytes;
begin
  Result := FBytes;
end;

function TPdfStringObject.GetIsHex: Boolean;
begin
  Result := FIsHex;
end;

function TPdfStringObject.AsText: string;
begin
  Result := PdfDecodeTextString(FBytes);
end;

function TPdfStringObject.ToText: string;
var
  I: Integer;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    if FIsHex then
    begin
      SB.Append('<');
      for I := 0 to High(FBytes) do
        SB.Append(IntToHex(FBytes[I], 2));
      SB.Append('>');
    end
    else
    begin
      SB.Append('(');
      for I := 0 to High(FBytes) do
        case FBytes[I] of
          Ord('('), Ord(')'), Ord('\'):
            begin
              SB.Append('\');
              SB.Append(Char(FBytes[I]));
            end;
          $0A: SB.Append('\n');
          $0D: SB.Append('\r');
          $20..$27, $2A..$5B, $5D..$7E: SB.Append(Char(FBytes[I]));
        else
          SB.Append('\').Append(IntToStr(FBytes[I] shr 6)).Append(IntToStr((FBytes[I] shr 3) and 7)).Append(IntToStr(FBytes[I] and 7));
        end;
      SB.Append(')');
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ TPdfNameObject }

constructor TPdfNameObject.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

function TPdfNameObject.GetKind: TPdfObjectKind;
begin
  Result := okName;
end;

function TPdfNameObject.GetName: string;
begin
  Result := FName;
end;

function TPdfNameObject.ToText: string;
var
  I: Integer;
  C: Char;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('/');
    for I := 1 to Length(FName) do
    begin
      C := FName[I];
      if (Ord(C) < $21) or (Ord(C) > $7E) or (C = '#') or IsPdfDelimiter(Byte(Ord(C) and $FF)) then
        SB.Append('#').Append(IntToHex(Ord(C) and $FF, 2))
      else
        SB.Append(C);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ TPdfReferenceObject }

constructor TPdfReferenceObject.Create(ANum, AGen: Integer);
begin
  inherited Create;
  FNum := ANum;
  FGen := AGen;
end;

function TPdfReferenceObject.GetKind: TPdfObjectKind;
begin
  Result := okReference;
end;

function TPdfReferenceObject.GetNum: Integer;
begin
  Result := FNum;
end;

function TPdfReferenceObject.GetGen: Integer;
begin
  Result := FGen;
end;

function TPdfReferenceObject.ToText: string;
begin
  Result := Format('%d %d R', [FNum, FGen]);
end;

{ TPdfOperatorObject }

constructor TPdfOperatorObject.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

function TPdfOperatorObject.GetKind: TPdfObjectKind;
begin
  Result := okOperator;
end;

function TPdfOperatorObject.GetName: string;
begin
  Result := FName;
end;

function TPdfOperatorObject.ToText: string;
begin
  Result := FName;
end;

{ TPdfArrayObject }

constructor TPdfArrayObject.Create(const AResolver: IPdfResolver);
begin
  inherited Create;
  FItems := TList<IPdfObject>.Create;
  FResolver := AResolver;
end;

destructor TPdfArrayObject.Destroy;
begin
  FItems.Free;
  inherited;
end;

function TPdfArrayObject.GetKind: TPdfObjectKind;
begin
  Result := okArray;
end;

function TPdfArrayObject.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TPdfArrayObject.GetItem(Index: Integer): IPdfObject;
begin
  if (Index >= 0) and (Index < FItems.Count) then
    Result := FItems[Index]
  else
    Result := nil;
end;

procedure TPdfArrayObject.SetItem(Index: Integer; const Obj: IPdfObject);
begin
  if Obj = nil then
    FItems[Index] := PdfNull
  else
    FItems[Index] := Obj;
end;

function TPdfArrayObject.GetResolver: IPdfResolver;
begin
  Result := FResolver;
end;

procedure TPdfArrayObject.SetResolver(const Value: IPdfResolver);
begin
  FResolver := Value;
end;

function TPdfArrayObject.Get(Index: Integer): IPdfObject;
begin
  Result := PdfResolve(FResolver, GetItem(Index));
end;

procedure TPdfArrayObject.Add(const Obj: IPdfObject);
begin
  if Obj = nil then
    FItems.Add(PdfNull)
  else
    FItems.Add(Obj);
end;

procedure TPdfArrayObject.Insert(Index: Integer; const Obj: IPdfObject);
begin
  FItems.Insert(Index, Obj);
end;

procedure TPdfArrayObject.Delete(Index: Integer);
begin
  FItems.Delete(Index);
end;

procedure TPdfArrayObject.Clear;
begin
  FItems.Clear;
end;

function TPdfArrayObject.GetNumber(Index: Integer; Default: Double): Double;
begin
  Result := PdfAsNumber(Get(Index), Default);
end;

function TPdfArrayObject.GetInteger(Index: Integer; Default: Int64): Int64;
begin
  Result := PdfAsInteger(Get(Index), Default);
end;

function TPdfArrayObject.GetName(Index: Integer; const Default: string): string;
begin
  Result := PdfAsName(Get(Index), Default);
end;

function TPdfArrayObject.GetArray(Index: Integer): IPdfArray;
begin
  Result := PdfAsArray(Get(Index));
end;

function TPdfArrayObject.GetDictionary(Index: Integer): IPdfDictionary;
begin
  Result := PdfAsDictionary(Get(Index));
end;

function TPdfArrayObject.GetStream(Index: Integer): IPdfStream;
begin
  Result := PdfAsStream(Get(Index));
end;

function TPdfArrayObject.GetNumbers(out Values: TArray<Double>; Count: Integer): Boolean;
var
  I: Integer;
  Obj: IPdfObject;
begin
  if Count < 0 then
    Count := FItems.Count;
  SetLength(Values, Count);
  Result := Count <= FItems.Count;
  for I := 0 to Count - 1 do
  begin
    Obj := Get(I);
    if PdfIsNumber(Obj) then
      Values[I] := (Obj as IPdfNumber).Value
    else
    begin
      Values[I] := 0;
      Result := False;
    end;
  end;
end;

function TPdfArrayObject.ToText: string;
var
  I: Integer;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('[');
    for I := 0 to FItems.Count - 1 do
    begin
      if I > 0 then
        SB.Append(' ');
      SB.Append(FItems[I].ToText);
    end;
    SB.Append(']');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ TPdfDictionaryObject }

constructor TPdfDictionaryObject.Create(const AResolver: IPdfResolver);
begin
  inherited Create;
  FKeys := TList<string>.Create;
  FValues := TDictionary<string, IPdfObject>.Create;
  FResolver := AResolver;
end;

destructor TPdfDictionaryObject.Destroy;
begin
  FValues.Free;
  FKeys.Free;
  inherited;
end;

function TPdfDictionaryObject.GetKind: TPdfObjectKind;
begin
  Result := okDictionary;
end;

function TPdfDictionaryObject.GetCount: Integer;
begin
  Result := FKeys.Count;
end;

function TPdfDictionaryObject.GetKey(Index: Integer): string;
begin
  Result := FKeys[Index];
end;

function TPdfDictionaryObject.GetResolver: IPdfResolver;
begin
  Result := FResolver;
end;

procedure TPdfDictionaryObject.SetResolver(const Value: IPdfResolver);
begin
  FResolver := Value;
end;

function TPdfDictionaryObject.Contains(const Key: string): Boolean;
begin
  Result := FValues.ContainsKey(Key);
end;

function TPdfDictionaryObject.GetRaw(const Key: string): IPdfObject;
begin
  if not FValues.TryGetValue(Key, Result) then
    Result := nil;
end;

function TPdfDictionaryObject.Get(const Key: string): IPdfObject;
begin
  Result := PdfResolve(FResolver, GetRaw(Key));
end;

function TPdfDictionaryObject.Get(const Key1, Key2: string): IPdfObject;
var
  Raw: IPdfObject;
begin
  Raw := GetRaw(Key1);
  if Raw = nil then
    Raw := GetRaw(Key2);
  Result := PdfResolve(FResolver, Raw);
end;

procedure TPdfDictionaryObject.SetValue(const Key: string; const Obj: IPdfObject);
begin
  if not FValues.ContainsKey(Key) then
    FKeys.Add(Key);
  if Obj = nil then
    FValues.AddOrSetValue(Key, PdfNull)
  else
    FValues.AddOrSetValue(Key, Obj);
end;

procedure TPdfDictionaryObject.Remove(const Key: string);
begin
  if FValues.ContainsKey(Key) then
  begin
    FValues.Remove(Key);
    FKeys.Remove(Key);
  end;
end;

procedure TPdfDictionaryObject.Clear;
begin
  FValues.Clear;
  FKeys.Clear;
end;

function TPdfDictionaryObject.GetNumber(const Key: string; Default: Double): Double;
begin
  Result := PdfAsNumber(Get(Key), Default);
end;

function TPdfDictionaryObject.GetInteger(const Key: string; Default: Int64): Int64;
begin
  Result := PdfAsInteger(Get(Key), Default);
end;

function TPdfDictionaryObject.GetBoolean(const Key: string; Default: Boolean): Boolean;
begin
  Result := PdfAsBoolean(Get(Key), Default);
end;

function TPdfDictionaryObject.GetName(const Key: string; const Default: string): string;
begin
  Result := PdfAsName(Get(Key), Default);
end;

function TPdfDictionaryObject.GetString(const Key: string): IPdfString;
begin
  Result := PdfAsString(Get(Key));
end;

function TPdfDictionaryObject.GetArray(const Key: string): IPdfArray;
begin
  Result := PdfAsArray(Get(Key));
end;

function TPdfDictionaryObject.GetDictionary(const Key: string): IPdfDictionary;
begin
  Result := PdfAsDictionary(Get(Key));
end;

function TPdfDictionaryObject.GetStream(const Key: string): IPdfStream;
begin
  Result := PdfAsStream(Get(Key));
end;

function TPdfDictionaryObject.GetRectangle(const Key: string; out R: TPdfRectangle): Boolean;
var
  Arr: IPdfArray;
  V: TArray<Double>;
begin
  R := TPdfRectangle.Empty;
  Arr := GetArray(Key);
  Result := (Arr <> nil) and (Arr.Count >= 4) and Arr.GetNumbers(V, 4);
  if Result then
    R := TPdfRectangle.Create(V[0], V[1], V[2], V[3]).Normalized;
end;

function TPdfDictionaryObject.IsType(const Name: string): Boolean;
begin
  Result := GetName('Type') = Name;
end;

function TPdfDictionaryObject.Keys: TArray<string>;
begin
  Result := FKeys.ToArray;
end;

function TPdfDictionaryObject.ToText: string;
var
  I: Integer;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('<<');
    for I := 0 to FKeys.Count - 1 do
    begin
      if I > 0 then
        SB.Append(' ');
      SB.Append(PdfName(FKeys[I]).ToText).Append(' ').Append(FValues[FKeys[I]].ToText);
    end;
    SB.Append('>>');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ TPdfStreamObject }

constructor TPdfStreamObject.Create(const ADict: IPdfDictionary; const ARawData: TBytes);
begin
  inherited Create;
  if ADict = nil then
    FDict := PdfDictionary(nil)
  else
    FDict := ADict;
  FRawData := ARawData;
  FObjNum := -1;
end;

function TPdfStreamObject.GetKind: TPdfObjectKind;
begin
  Result := okStream;
end;

function TPdfStreamObject.GetDict: IPdfDictionary;
begin
  Result := FDict;
end;

function TPdfStreamObject.GetRawData: TBytes;
begin
  Result := FRawData;
end;

procedure TPdfStreamObject.SetRawData(const Value: TBytes);
begin
  FRawData := Value;
  FDecoded := False;
  FDecodedData := nil;
end;

function TPdfStreamObject.GetObjNum: Integer;
begin
  Result := FObjNum;
end;

function TPdfStreamObject.GetObjGen: Integer;
begin
  Result := FObjGen;
end;

procedure TPdfStreamObject.SetObjectNumber(Num, Gen: Integer);
begin
  FObjNum := Num;
  FObjGen := Gen;
end;

function TPdfStreamObject.GetImageFilter: string;
begin
  if not FDecoded then
    Decode;
  Result := FImageFilter;
end;

function TPdfStreamObject.GetImageFilterParms: IPdfDictionary;
begin
  if not FDecoded then
    Decode;
  Result := FImageFilterParms;
end;

function TPdfStreamObject.GetFilterNames: TArray<string>;
var
  Obj: IPdfObject;
  Arr: IPdfArray;
  I, N: Integer;
begin
  Result := nil;
  Obj := FDict.Get('Filter', 'F');
  if PdfIsName(Obj) then
  begin
    SetLength(Result, 1);
    Result[0] := PdfNormalizeFilterName((Obj as IPdfName).Name);
  end
  else
  begin
    Arr := PdfAsArray(Obj);
    if Arr <> nil then
    begin
      N := 0;
      SetLength(Result, Arr.Count);
      for I := 0 to Arr.Count - 1 do
        if PdfIsName(Arr.Get(I)) then
        begin
          Result[N] := PdfNormalizeFilterName(Arr.GetName(I));
          Inc(N);
        end;
      SetLength(Result, N);
    end;
  end;
end;

procedure TPdfStreamObject.Decode;
var
  Names: TArray<string>;
  ParmsObj: IPdfObject;
  ParmsArr: IPdfArray;
  Parms: IPdfDictionary;
  Params: TPdfFilterParams;
  Data: TBytes;
  I: Integer;
begin
  FDecoded := True;
  FImageFilter := '';
  FImageFilterParms := nil;
  Data := FRawData;
  Names := GetFilterNames;
  ParmsObj := FDict.Get('DecodeParms', 'DP');
  ParmsArr := PdfAsArray(ParmsObj);
  for I := 0 to High(Names) do
  begin
    if ParmsArr <> nil then
      Parms := ParmsArr.GetDictionary(I)
    else if I = 0 then
      Parms := PdfAsDictionary(ParmsObj)
    else
      Parms := nil;
    if PdfIsImageFilter(Names[I]) then
    begin
      FImageFilter := Names[I];
      FImageFilterParms := Parms;
      Break;
    end;
    Params := TPdfFilterParams.Default;
    if Parms <> nil then
    begin
      Params.Predictor := Integer(Parms.GetInteger('Predictor', 1));
      Params.Colors := Integer(Parms.GetInteger('Colors', 1));
      Params.BitsPerComponent := Integer(Parms.GetInteger('BitsPerComponent', 8));
      Params.Columns := Integer(Parms.GetInteger('Columns', 1));
      Params.EarlyChange := Integer(Parms.GetInteger('EarlyChange', 1));
    end;
    Data := PdfApplyFilter(Names[I], Data, Params);
  end;
  FDecodedData := Data;
end;

function TPdfStreamObject.GetDecodedData: TBytes;
begin
  if not FDecoded then
    Decode;
  Result := FDecodedData;
end;

function TPdfStreamObject.ToText: string;
begin
  Result := FDict.ToText + Format(' stream[%d bytes]', [Length(FRawData)]);
end;

end.
