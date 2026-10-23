{*******************************************************************************
  Pdf.Core.Parser
  Builds PDF objects from the token stream: direct objects, indirect
  references (n g R), indirect object bodies (n g obj ... endobj) and streams.
  Also used for content streams, where unknown keywords become operators.
  Tolerant of missing delimiters, wrong /Length values and stray tokens.
  Portions derived from pdf.js (Mozilla, Apache License 2.0).
*******************************************************************************}
unit Pdf.Core.Parser;

interface

uses
  System.SysUtils, System.Math, Pdf.Core.Types, Pdf.Core.Lexer, Pdf.Core.Objects;

type
  TPdfParser = class
  private
    FLexer: TPdfLexer;
    FResolver: IPdfResolver;
    FAllowStreams: Boolean;
    FBuf: array[0..1] of TPdfToken;
    FBufCount: Integer;
    FDepth: Integer;
    function NextToken: TPdfToken;
    function PeekToken(Index: Integer): TPdfToken;
    procedure FlushTokens;
    function GetPosition: Integer;
    procedure SetPosition(Value: Integer);
    function ParseFromToken(const Tok: TPdfToken): IPdfObject;
    function ParseArray: IPdfObject;
    function ParseDictionaryOrStream: IPdfObject;
    function ReadStream(const Dict: IPdfDictionary; DataStart: Integer): IPdfStream;
  public
    /// <summary>Parses Data[Start..]; Resolver is handed to created containers and used to resolve /Length.
    /// With AllowStreams = False (content streams) the 'stream' keyword is returned as an operator.</summary>
    constructor Create(const Data: TBytes; Start: Integer = 0; const Resolver: IPdfResolver = nil;
      AllowStreams: Boolean = True; Len: Integer = -1);
    destructor Destroy; override;
    /// <summary>Parses the next object. Keywords other than true/false/null/R are returned as IPdfOperator;
    /// returns nil at the end of the data.</summary>
    function ParseObject: IPdfObject;
    /// <summary>Parses "num gen obj &lt;object&gt; [endobj]" at the current position.
    /// Raises EPdfSyntaxError when no object header is found.</summary>
    function ParseIndirectObject(out Num, Gen: Integer): IPdfObject;
    /// <summary>True when "num gen obj" is at the current position (does not consume).</summary>
    function AtObjectHeader(out Num, Gen: Integer): Boolean;
    property Position: Integer read GetPosition write SetPosition;
    property Lexer: TPdfLexer read FLexer;
    property Resolver: IPdfResolver read FResolver write FResolver;
  end;

/// <summary>Parses one object from a byte buffer.</summary>
function PdfParseObject(const Data: TBytes; const Resolver: IPdfResolver = nil): IPdfObject; overload;
/// <summary>Parses one object from a Latin-1 string (tests and tooling).</summary>
function PdfParseObject(const Source: string; const Resolver: IPdfResolver = nil): IPdfObject; overload;

implementation

const
  MaxNestingDepth = 300;

function PdfParseObject(const Data: TBytes; const Resolver: IPdfResolver): IPdfObject;
var
  P: TPdfParser;
begin
  P := TPdfParser.Create(Data, 0, Resolver);
  try
    Result := P.ParseObject;
    if Result = nil then
      Result := PdfNull;
  finally
    P.Free;
  end;
end;

function PdfParseObject(const Source: string; const Resolver: IPdfResolver): IPdfObject;
begin
  Result := PdfParseObject(PdfLatin1ToBytes(Source), Resolver);
end;

{ TPdfParser }

constructor TPdfParser.Create(const Data: TBytes; Start: Integer; const Resolver: IPdfResolver;
  AllowStreams: Boolean; Len: Integer);
begin
  inherited Create;
  FLexer := TPdfLexer.Create(Data, Start, Len);
  FResolver := Resolver;
  FAllowStreams := AllowStreams;
end;

destructor TPdfParser.Destroy;
begin
  FLexer.Free;
  inherited;
end;

function TPdfParser.NextToken: TPdfToken;
begin
  if FBufCount > 0 then
  begin
    Result := FBuf[0];
    FBuf[0] := FBuf[1];
    Dec(FBufCount);
  end
  else
    Result := FLexer.NextToken;
end;

function TPdfParser.PeekToken(Index: Integer): TPdfToken;
begin
  while FBufCount <= Index do
  begin
    FBuf[FBufCount] := FLexer.NextToken;
    Inc(FBufCount);
  end;
  Result := FBuf[Index];
end;

procedure TPdfParser.FlushTokens;
begin
  FBufCount := 0;
end;

function TPdfParser.GetPosition: Integer;
begin
  if FBufCount > 0 then
    Result := FBuf[0].Position
  else
    Result := FLexer.Position;
end;

procedure TPdfParser.SetPosition(Value: Integer);
begin
  FlushTokens;
  FLexer.Position := Value;
end;

function TPdfParser.ParseObject: IPdfObject;
var
  Tok: TPdfToken;
begin
  Tok := NextToken;
  if Tok.Kind = tkEOF then
    Exit(nil);
  Result := ParseFromToken(Tok);
end;

function TPdfParser.ParseFromToken(const Tok: TPdfToken): IPdfObject;
var
  T1, T2: TPdfToken;
begin
  case Tok.Kind of
    tkNumber:
      begin
        if Tok.IsInteger and (Tok.IntValue >= 0) then
        begin
          T1 := PeekToken(0);
          if (T1.Kind = tkNumber) and T1.IsInteger and (T1.IntValue >= 0) then
          begin
            T2 := PeekToken(1);
            if T2.IsKeyword('R') then
            begin
              NextToken;
              NextToken;
              Exit(PdfReference(Integer(Tok.IntValue), Integer(T1.IntValue)));
            end;
          end;
          Result := PdfInteger(Tok.IntValue);
        end
        else if Tok.IsInteger then
          Result := PdfInteger(Tok.IntValue)
        else
          Result := PdfReal(Tok.NumberValue);
      end;
    tkString:
      Result := PdfString(Tok.Bytes, Tok.IsHexString);
    tkName:
      Result := PdfName(Tok.Text);
    tkArrayOpen:
      Result := ParseArray;
    tkDictOpen:
      Result := ParseDictionaryOrStream;
    tkArrayClose:
      Result := PdfOperator(']');
    tkDictClose:
      Result := PdfOperator('>>');
    tkBraceOpen:
      Result := PdfOperator('{');
    tkBraceClose:
      Result := PdfOperator('}');
    tkKeyword:
      begin
        if Tok.IsKeyword('true') then
          Result := PdfBoolean(True)
        else if Tok.IsKeyword('false') then
          Result := PdfBoolean(False)
        else if Tok.IsKeyword('null') then
          Result := PdfNull
        else
          Result := PdfOperator(Tok.Text);
      end;
  else
    Result := PdfNull;
  end;
end;

function TPdfParser.ParseArray: IPdfObject;
var
  Arr: IPdfArray;
  Tok: TPdfToken;
  Obj: IPdfObject;
begin
  Arr := PdfArray(FResolver);
  Result := Arr;
  if FDepth >= MaxNestingDepth then
    Exit;
  Inc(FDepth);
  try
    while True do
    begin
      Tok := PeekToken(0);
      case Tok.Kind of
        tkEOF:
          Break;
        tkArrayClose:
          begin
            NextToken;
            Break;
          end;
        tkDictClose:
          begin
            NextToken; // stray '>>' inside an array: ignore
            Continue;
          end;
        tkKeyword:
          if Tok.IsKeyword('endobj') or Tok.IsKeyword('endstream') or Tok.IsKeyword('stream') then
            Break; // unterminated array: stop before the keyword without consuming it
      end;
      Obj := ParseObject;
      if Obj = nil then
        Break;
      Arr.Add(Obj);
    end;
  finally
    Dec(FDepth);
  end;
end;

function TPdfParser.ParseDictionaryOrStream: IPdfObject;
var
  Dict: IPdfDictionary;
  Tok, ValueTok: TPdfToken;
  Key: string;
  Value: IPdfObject;
  Text: string;
  DataStart: Integer;
begin
  Dict := PdfDictionary(FResolver);
  Result := Dict;
  if FDepth >= MaxNestingDepth then
    Exit;
  Inc(FDepth);
  try
    while True do
    begin
      Tok := PeekToken(0);
      case Tok.Kind of
        tkEOF:
          Break;
        tkDictClose:
          begin
            NextToken;
            Break;
          end;
        tkKeyword:
          if Tok.IsKeyword('endobj') or Tok.IsKeyword('endstream') or Tok.IsKeyword('stream') then
            Break;
      end;
      if Tok.Kind <> tkName then
      begin
        // Not a name: skip the token (or the whole container) and continue
        ParseObject;
        Continue;
      end;
      NextToken;
      Key := Tok.Text;
      ValueTok := PeekToken(0);
      if (ValueTok.Kind = tkDictClose) or (ValueTok.Kind = tkEOF) then
        Continue; // key without value
      if (ValueTok.Kind = tkKeyword) and (ValueTok.IsKeyword('endobj') or ValueTok.IsKeyword('stream')) then
        Continue;
      Value := ParseObject;
      if Value = nil then
        Break;
      if Value.Kind = okOperator then
        Continue; // garbage value: drop the key
      Dict.SetValue(Key, Value);
    end;
  finally
    Dec(FDepth);
  end;
  if not FAllowStreams then
    Exit;
  Tok := PeekToken(0);
  if Tok.Kind <> tkKeyword then
    Exit;
  Text := Tok.Text;
  if (Length(Text) >= 6) and (Copy(Text, 1, 6) = 'stream') and
     ((Length(Text) = 6) or not CharInSet(Text[7], ['a'..'z', 'A'..'Z'])) then
  begin
    // Exactly one token is buffered, so the lexer stands right after the keyword
    // (or after 'stream' plus garbage when the data follows without EOL).
    DataStart := Tok.Position + 6;
    FlushTokens;
    Result := ReadStream(Dict, DataStart);
  end;
end;

function TPdfParser.ReadStream(const Dict: IPdfDictionary; DataStart: Integer): IPdfStream;
var
  Data: TBytes;
  P, DataEnd, EndPos, Found, Len: Integer;
  LengthObj: IPdfObject;
  Valid: Boolean;
begin
  Data := FLexer.Data;
  EndPos := FLexer.EndPosition;
  P := DataStart;
  // Skip trailing spaces/tabs and one EOL after the 'stream' keyword
  while (P < EndPos) and ((Data[P] = $20) or (Data[P] = $09)) do
    Inc(P);
  if (P < EndPos) and (Data[P] = $0D) then
    Inc(P);
  if (P < EndPos) and (Data[P] = $0A) then
    Inc(P);
  DataStart := P;

  Valid := False;
  DataEnd := -1;
  LengthObj := Dict.Get('Length');
  if PdfIsNumber(LengthObj) then
  begin
    Len := Integer(Min(PdfAsInteger(LengthObj), High(Integer)));
    if (Len >= 0) and (DataStart + Len <= EndPos) then
    begin
      P := DataStart + Len;
      PdfSkipWhitespace(Data, P, EndPos);
      if PdfMatchBytes(Data, P, 'endstream') then
      begin
        Valid := True;
        DataEnd := DataStart + Len;
        EndPos := P + 9;
      end;
    end;
  end;
  if not Valid then
  begin
    // Wrong or missing /Length: search for the keyword instead
    Found := PdfFindBytes(Data, 'endstream', DataStart, FLexer.EndPosition);
    if Found < 0 then
    begin
      Found := PdfFindBytes(Data, 'endobj', DataStart, FLexer.EndPosition);
      if Found < 0 then
      begin
        DataEnd := FLexer.EndPosition;
        EndPos := FLexer.EndPosition;
      end
      else
      begin
        DataEnd := Found;
        EndPos := Found; // leave 'endobj' for the caller
      end;
    end
    else
    begin
      DataEnd := Found;
      EndPos := Found + 9;
    end;
    // Strip the EOL that precedes 'endstream'
    if (DataEnd > DataStart) and (Data[DataEnd - 1] = $0A) then
      Dec(DataEnd);
    if (DataEnd > DataStart) and (Data[DataEnd - 1] = $0D) then
      Dec(DataEnd);
  end;
  Result := PdfStream(Dict, PdfCopyBytes(Data, DataStart, DataEnd - DataStart));
  FLexer.Position := EndPos;
end;

function TPdfParser.AtObjectHeader(out Num, Gen: Integer): Boolean;
var
  T0, T1, T2: TPdfToken;
begin
  Num := -1;
  Gen := -1;
  Result := False;
  T0 := PeekToken(0);
  if (T0.Kind <> tkNumber) or not T0.IsInteger or (T0.IntValue < 0) then
    Exit;
  T1 := PeekToken(1);
  if (T1.Kind <> tkNumber) or not T1.IsInteger or (T1.IntValue < 0) then
    Exit;
  // Third token: look at the raw bytes to avoid growing the buffer
  T2 := FLexer.NextToken;
  FLexer.Position := T2.Position;
  if not T2.IsKeyword('obj') then
    Exit;
  Num := Integer(T0.IntValue);
  Gen := Integer(T1.IntValue);
  Result := True;
end;

function TPdfParser.ParseIndirectObject(out Num, Gen: Integer): IPdfObject;
var
  Tok: TPdfToken;
begin
  if not AtObjectHeader(Num, Gen) then
    raise EPdfSyntaxError.CreateFmt('Object header expected at offset %d', [Position]);
  NextToken;
  NextToken;
  NextToken; // obj
  Tok := PeekToken(0);
  if (Tok.Kind = tkEOF) or Tok.IsKeyword('endobj') then
  begin
    if Tok.Kind <> tkEOF then
      NextToken;
    Exit(PdfNull);
  end;
  Result := ParseObject;
  if Result = nil then
    Result := PdfNull
  else if Result.Kind = okOperator then
    Result := PdfNull; // e.g. "1 0 obj endobj" or garbage
  Tok := PeekToken(0);
  if Tok.IsKeyword('endobj') then
    NextToken;
end;

end.
