{*******************************************************************************
  Pdf.Render.Content
  Content stream interpreter front-end (ISO 32000-1 §7.8.2): splits a content
  stream into operations (operator + operands) and extracts inline images
  (BI ... ID ... EI) as stream objects.
  Portions derived from pdf.js (Mozilla, Apache License 2.0).
*******************************************************************************}
unit Pdf.Render.Content;

interface

uses
  System.SysUtils, System.Math, Pdf.Core.Types, Pdf.Core.Lexer, Pdf.Core.Objects, Pdf.Core.Parser;

type
  TPdfOperation = record
    /// <summary>Operator name, e.g. 're', 'Tj'. Inline images arrive as 'EI' with one IPdfStream operand.</summary>
    &Operator: string;
    Operands: TArray<IPdfObject>;
    /// <summary>Offset of the operator in the content data (for error messages).</summary>
    Position: Integer;
    function Count: Integer; inline;
    function Num(Index: Integer; Default: Double = 0): Double;
    function Int(Index: Integer; Default: Int64 = 0): Int64;
    function Name(Index: Integer; const Default: string = ''): string;
    function Obj(Index: Integer): IPdfObject;
    /// <summary>All operands as numbers (non-numbers become 0); False when fewer than MinCount operands.</summary>
    function Numbers(MinCount: Integer; out Values: TArray<Double>): Boolean;
    function IsOp(const AName: string): Boolean; inline;
  end;

  TPdfContentParser = class
  private
    FData: TBytes;
    FParser: TPdfParser;
    FResolver: IPdfResolver;
    FResources: IPdfDictionary;
    FOperands: TArray<IPdfObject>;
    FOperandCount: Integer;
    function ReadInlineImage(out Op: TPdfOperation): Boolean;
    function InlineImageComponents(const Dict: IPdfDictionary): Integer;
    function FindInlineImageEnd(Start: Integer): Integer;
  public
    /// <summary>Resources are used to find the component count of named colour spaces in unfiltered inline images.</summary>
    constructor Create(const Data: TBytes; const Resolver: IPdfResolver = nil; const Resources: IPdfDictionary = nil);
    destructor Destroy; override;
    /// <summary>Returns the next operation; False at the end of the data.</summary>
    function Next(out Op: TPdfOperation): Boolean;
    function Position: Integer;
  end;

implementation

const
  MaxOperands = 32;

{ TPdfOperation }

function TPdfOperation.Count: Integer;
begin
  Result := Length(Operands);
end;

function TPdfOperation.Obj(Index: Integer): IPdfObject;
begin
  if (Index >= 0) and (Index < Length(Operands)) then
    Result := Operands[Index]
  else
    Result := nil;
end;

function TPdfOperation.Num(Index: Integer; Default: Double): Double;
begin
  Result := PdfAsNumber(Obj(Index), Default);
end;

function TPdfOperation.Int(Index: Integer; Default: Int64): Int64;
begin
  Result := PdfAsInteger(Obj(Index), Default);
end;

function TPdfOperation.Name(Index: Integer; const Default: string): string;
begin
  Result := PdfAsName(Obj(Index), Default);
end;

function TPdfOperation.Numbers(MinCount: Integer; out Values: TArray<Double>): Boolean;
var
  I: Integer;
begin
  SetLength(Values, Length(Operands));
  for I := 0 to High(Operands) do
    Values[I] := PdfAsNumber(Operands[I], 0);
  Result := Length(Operands) >= MinCount;
end;

function TPdfOperation.IsOp(const AName: string): Boolean;
begin
  Result := &Operator = AName;
end;

{ TPdfContentParser }

constructor TPdfContentParser.Create(const Data: TBytes; const Resolver: IPdfResolver; const Resources: IPdfDictionary);
begin
  inherited Create;
  FData := Data;
  FResolver := Resolver;
  FResources := Resources;
  FParser := TPdfParser.Create(Data, 0, nil, False);
  SetLength(FOperands, MaxOperands);
end;

destructor TPdfContentParser.Destroy;
begin
  FParser.Free;
  inherited;
end;

function TPdfContentParser.Position: Integer;
begin
  Result := FParser.Position;
end;

function TPdfContentParser.Next(out Op: TPdfOperation): Boolean;
var
  O: IPdfObject;
  Pos, I: Integer;
begin
  Op := Default(TPdfOperation);
  FOperandCount := 0;
  while True do
  begin
    Pos := FParser.Position;
    O := FParser.ParseObject;
    if O = nil then
      Exit(False);
    if O.Kind = okOperator then
    begin
      Op.&Operator := (O as IPdfOperator).Name;
      Op.Position := Pos;
      SetLength(Op.Operands, FOperandCount);
      for I := 0 to FOperandCount - 1 do
        Op.Operands[I] := FOperands[I];
      FOperandCount := 0;
      if Op.&Operator = 'BI' then
      begin
        if ReadInlineImage(Op) then
          Exit(True);
        Continue; // unreadable inline image: skip it
      end;
      Exit(True);
    end;
    if FOperandCount >= MaxOperands then
    begin
      // Runaway operand list (garbage data): keep the most recent ones
      for I := 1 to MaxOperands - 1 do
        FOperands[I - 1] := FOperands[I];
      Dec(FOperandCount);
    end;
    FOperands[FOperandCount] := O;
    Inc(FOperandCount);
  end;
end;

function TPdfContentParser.InlineImageComponents(const Dict: IPdfDictionary): Integer;
var
  CS: IPdfObject;
  Name: string;
  Arr: IPdfArray;
  Res: IPdfDictionary;
  Names: IPdfArray;
  Stream: IPdfStream;
begin
  if Dict.GetBoolean('ImageMask', Dict.GetBoolean('IM', False)) then
    Exit(1);
  CS := Dict.Get('ColorSpace', 'CS');
  if PdfIsName(CS) and (FResources <> nil) then
  begin
    Name := (CS as IPdfName).Name;
    Res := FResources.GetDictionary('ColorSpace');
    if (Res <> nil) and Res.Contains(Name) then
      CS := Res.Get(Name);
  end;
  if PdfIsName(CS) then
  begin
    Name := (CS as IPdfName).Name;
    if (Name = 'DeviceRGB') or (Name = 'RGB') or (Name = 'CalRGB') then
      Exit(3);
    if (Name = 'DeviceCMYK') or (Name = 'CMYK') then
      Exit(4);
    if (Name = 'DeviceGray') or (Name = 'G') or (Name = 'CalGray') or (Name = 'I') or (Name = 'Indexed') then
      Exit(1);
    Exit(-1);
  end;
  Arr := PdfAsArray(CS);
  if (Arr <> nil) and (Arr.Count >= 1) then
  begin
    Name := Arr.GetName(0);
    if (Name = 'Indexed') or (Name = 'I') or (Name = 'Separation') or (Name = 'CalGray') then
      Exit(1);
    if Name = 'CalRGB' then
      Exit(3);
    if Name = 'Lab' then
      Exit(3);
    if Name = 'DeviceN' then
    begin
      Names := Arr.GetArray(1);
      if Names <> nil then
        Exit(Names.Count);
      Exit(-1);
    end;
    if Name = 'ICCBased' then
    begin
      Stream := Arr.GetStream(1);
      if Stream <> nil then
        Exit(Integer(Stream.Dict.GetInteger('N', -1)));
      Exit(-1);
    end;
    if Name = 'DeviceRGB' then
      Exit(3);
    if Name = 'DeviceCMYK' then
      Exit(4);
    if Name = 'DeviceGray' then
      Exit(1);
  end;
  if CS = nil then
    Exit(1); // no colour space: only valid for masks, assume 1
  Result := -1;
end;

function TPdfContentParser.FindInlineImageEnd(Start: Integer): Integer;
var
  P, Q, N: Integer;
  B: Byte;
begin
  // 'EI' preceded by whitespace and followed by whitespace/EOF, where the bytes after it look like text.
  P := Start;
  N := Length(FData);
  while P + 1 < N do
  begin
    if (FData[P] = Ord('E')) and (FData[P + 1] = Ord('I')) and (P > 0) and IsPdfWhitespace(FData[P - 1]) and
       ((P + 2 >= N) or IsPdfWhitespace(FData[P + 2]) or IsPdfDelimiter(FData[P + 2])) then
    begin
      Q := P + 2;
      while (Q < N) and (Q < P + 2 + 24) do
      begin
        B := FData[Q];
        if not (IsPdfWhitespace(B) or ((B >= $20) and (B <= $7E))) then
          Break;
        Inc(Q);
      end;
      if (Q >= N) or (Q >= P + 2 + 24) then
        Exit(P);
    end;
    Inc(P);
  end;
  Result := -1;
end;

function TPdfContentParser.ReadInlineImage(out Op: TPdfOperation): Boolean;
var
  Sub: TPdfParser;
  Dict: IPdfDictionary;
  Key, Value: IPdfObject;
  DataStart, DataEnd, P, W, H, BPC, Comps, Len: Integer;
  Filters: IPdfObject;
  Stream: IPdfStream;
begin
  Result := False;
  Dict := PdfDictionary(FResolver);
  Sub := TPdfParser.Create(FData, FParser.Position, nil, False);
  try
    // Key/value pairs up to the ID operator
    while True do
    begin
      Key := Sub.ParseObject;
      if Key = nil then
        Exit;
      if PdfIsOperator(Key, 'ID') then
        Break;
      if Key.Kind <> okName then
        Continue;
      Value := Sub.ParseObject;
      if Value = nil then
        Exit;
      if PdfIsOperator(Value, 'ID') then
        Break;
      Dict.SetValue((Key as IPdfName).Name, Value);
    end;
    // Exactly one whitespace byte follows ID
    DataStart := Sub.Position;
    if (DataStart < Length(FData)) and IsPdfWhitespace(FData[DataStart]) then
      Inc(DataStart);
  finally
    Sub.Free;
  end;
  DataEnd := -1;
  Filters := Dict.Get('Filter', 'F');
  if PdfIsNull(Filters) or ((Filters.Kind = okArray) and ((Filters as IPdfArray).Count = 0)) then
  begin
    // Unfiltered: the length follows from the image parameters
    W := Integer(Dict.GetInteger('Width', Dict.GetInteger('W', 0)));
    H := Integer(Dict.GetInteger('Height', Dict.GetInteger('H', 0)));
    BPC := Integer(Dict.GetInteger('BitsPerComponent', Dict.GetInteger('BPC', 8)));
    if Dict.GetBoolean('ImageMask', Dict.GetBoolean('IM', False)) then
      BPC := 1;
    Comps := InlineImageComponents(Dict);
    if (W > 0) and (H > 0) and (Comps > 0) and (BPC > 0) then
    begin
      Len := ((W * Comps * BPC + 7) div 8) * H;
      if DataStart + Len <= Length(FData) then
      begin
        P := DataStart + Len;
        PdfSkipWhitespace(FData, P);
        if PdfMatchBytes(FData, P, 'EI') and ((P + 2 >= Length(FData)) or not IsPdfRegular(FData[P + 2])) then
          DataEnd := DataStart + Len;
      end;
    end;
  end;
  if DataEnd < 0 then
  begin
    P := FindInlineImageEnd(DataStart);
    if P < 0 then
    begin
      // No terminator: consume the rest of the stream
      FParser.Position := Length(FData);
      Exit;
    end;
    DataEnd := P;
    // Strip the whitespace byte before EI
    if (DataEnd > DataStart) and IsPdfWhitespace(FData[DataEnd - 1]) then
      Dec(DataEnd);
  end;
  Stream := PdfStream(Dict, PdfCopyBytes(FData, DataStart, DataEnd - DataStart));
  // Continue after EI
  P := DataEnd;
  PdfSkipWhitespace(FData, P);
  if PdfMatchBytes(FData, P, 'EI') then
    Inc(P, 2);
  FParser.Position := P;
  Op.&Operator := 'EI';
  Op.Operands := [Stream];
  Result := True;
end;

end.
