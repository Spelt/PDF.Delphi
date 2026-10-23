{*******************************************************************************
  Pdf.Core.Lexer
  Tokenizer for PDF syntax (ISO 32000-1 §7.2): numbers, literal and hex
  strings, names, array/dictionary delimiters, braces and keywords.
  Works on an in-memory byte buffer and is deliberately tolerant of the
  malformed input found in real-world files.
  Portions derived from pdf.js (Mozilla, Apache License 2.0).
*******************************************************************************}
unit Pdf.Core.Lexer;

interface

uses
  System.SysUtils, System.Math, Pdf.Core.Types;

type
  TPdfTokenKind = (
    tkEOF,
    tkNumber,       // integer or real
    tkString,       // literal (...) or hex <...>; Bytes holds the decoded bytes
    tkName,         // /Name; Bytes holds the decoded name without the slash
    tkArrayOpen,    // [
    tkArrayClose,   // ]
    tkDictOpen,     // <<
    tkDictClose,    // >>
    tkBraceOpen,    // {
    tkBraceClose,   // }
    tkKeyword       // obj, endobj, stream, R, true, false, null, operators ...
  );

  TPdfToken = record
    Kind: TPdfTokenKind;
    /// <summary>Offset of the first byte of the token in the buffer.</summary>
    Position: Integer;
    /// <summary>Numeric value for tkNumber.</summary>
    NumberValue: Double;
    /// <summary>True when the number was written without fraction or exponent.</summary>
    IsInteger: Boolean;
    IntValue: Int64;
    /// <summary>Decoded bytes of a string, name or keyword.</summary>
    Bytes: TBytes;
    /// <summary>True when a tkString was written as &lt;hex&gt;.</summary>
    IsHexString: Boolean;
    /// <summary>Latin-1 text of Bytes (names, keywords, debugging).</summary>
    function Text: string;
    function IsKeyword(const Keyword: string): Boolean;
    function IsEOF: Boolean; inline;
  end;

  TPdfLexer = class
  private
    FData: TBytes;
    FPos: Integer;
    FEnd: Integer;
    function ReadNumber: TPdfToken;
    function ReadLiteralString: TPdfToken;
    function ReadHexString: TPdfToken;
    function ReadName: TPdfToken;
    function ReadKeyword: TPdfToken;
  public
    /// <summary>Tokenizes Data[Start .. Start+Len-1]; Len &lt; 0 means up to the end.</summary>
    constructor Create(const Data: TBytes; Start: Integer = 0; Len: Integer = -1);
    /// <summary>Returns the next token; tkEOF at the end of the buffer.</summary>
    function NextToken: TPdfToken;
    /// <summary>Skips whitespace and %-comments.</summary>
    procedure SkipWhitespaceAndComments;
    /// <summary>Skips an end-of-line marker (CR, LF or CRLF) if present; returns True when one was skipped.</summary>
    function SkipEOL: Boolean;
    /// <summary>Returns the byte at the current position or -1 at the end.</summary>
    function PeekByte: Integer; inline;
    function PeekByteAt(Offset: Integer): Integer; inline;
    function AtEnd: Boolean; inline;
    property Data: TBytes read FData;
    property Position: Integer read FPos write FPos;
    property EndPosition: Integer read FEnd;
  end;

/// <summary>Finds Pattern in Data between Start and Stop (exclusive; Stop &lt; 0 means end); returns -1 if absent.</summary>
function PdfFindBytes(const Data: TBytes; const Pattern: string; Start: Integer; Stop: Integer = -1): Integer;
/// <summary>Finds the last occurrence of Pattern that starts before Stop (exclusive; Stop &lt; 0 means end) and not before Start.</summary>
function PdfFindBytesBackward(const Data: TBytes; const Pattern: string; Stop: Integer = -1; Start: Integer = 0): Integer;
/// <summary>True when Data at Pos equals Pattern.</summary>
function PdfMatchBytes(const Data: TBytes; Pos: Integer; const Pattern: string): Boolean;
/// <summary>Parses an unsigned decimal integer at Pos (skipping leading whitespace); returns False if none.</summary>
function PdfReadUnsignedInt(const Data: TBytes; var Pos: Integer; out Value: Int64): Boolean;
/// <summary>Skips PDF whitespace starting at Pos.</summary>
procedure PdfSkipWhitespace(const Data: TBytes; var Pos: Integer; Stop: Integer = -1);

implementation

{ TPdfToken }

function TPdfToken.Text: string;
begin
  Result := PdfBytesToLatin1(Bytes);
end;

function TPdfToken.IsKeyword(const Keyword: string): Boolean;
var
  I: Integer;
begin
  if (Kind <> tkKeyword) or (Length(Bytes) <> Length(Keyword)) then
    Exit(False);
  for I := 0 to High(Bytes) do
    if Bytes[I] <> Ord(Keyword[I + 1]) then
      Exit(False);
  Result := True;
end;

function TPdfToken.IsEOF: Boolean;
begin
  Result := Kind = tkEOF;
end;

{ Byte helpers }

function PdfMatchBytes(const Data: TBytes; Pos: Integer; const Pattern: string): Boolean;
var
  I, L: Integer;
begin
  L := Length(Pattern);
  if (Pos < 0) or (Pos + L > Length(Data)) then
    Exit(False);
  for I := 0 to L - 1 do
    if Data[Pos + I] <> Ord(Pattern[I + 1]) then
      Exit(False);
  Result := True;
end;

function PdfFindBytes(const Data: TBytes; const Pattern: string; Start: Integer; Stop: Integer = -1): Integer;
var
  I, L, Last: Integer;
  First: Byte;
begin
  L := Length(Pattern);
  if (Stop < 0) or (Stop > Length(Data)) then
    Stop := Length(Data);
  if (L = 0) or (Start < 0) then
    Exit(-1);
  Last := Stop - L;
  First := Ord(Pattern[1]);
  I := Start;
  while I <= Last do
  begin
    if (Data[I] = First) and PdfMatchBytes(Data, I, Pattern) then
      Exit(I);
    Inc(I);
  end;
  Result := -1;
end;

function PdfFindBytesBackward(const Data: TBytes; const Pattern: string; Stop: Integer = -1; Start: Integer = 0): Integer;
var
  I, L: Integer;
begin
  L := Length(Pattern);
  if (Stop < 0) or (Stop > Length(Data)) then
    Stop := Length(Data);
  if Start < 0 then
    Start := 0;
  I := Stop - L;
  while I >= Start do
  begin
    if PdfMatchBytes(Data, I, Pattern) then
      Exit(I);
    Dec(I);
  end;
  Result := -1;
end;

procedure PdfSkipWhitespace(const Data: TBytes; var Pos: Integer; Stop: Integer = -1);
begin
  if (Stop < 0) or (Stop > Length(Data)) then
    Stop := Length(Data);
  while (Pos < Stop) and IsPdfWhitespace(Data[Pos]) do
    Inc(Pos);
end;

function PdfReadUnsignedInt(const Data: TBytes; var Pos: Integer; out Value: Int64): Boolean;
var
  P: Integer;
begin
  Value := 0;
  P := Pos;
  PdfSkipWhitespace(Data, P);
  if (P >= Length(Data)) or not IsPdfDigit(Data[P]) then
    Exit(False);
  while (P < Length(Data)) and IsPdfDigit(Data[P]) do
  begin
    if Value < High(Int64) div 10 then
      Value := Value * 10 + (Data[P] - Ord('0'));
    Inc(P);
  end;
  Pos := P;
  Result := True;
end;

{ TPdfLexer }

constructor TPdfLexer.Create(const Data: TBytes; Start: Integer; Len: Integer);
begin
  inherited Create;
  FData := Data;
  FPos := Max(0, Start);
  if Len < 0 then
    FEnd := Length(Data)
  else
    FEnd := Min(Length(Data), Start + Len);
  if FPos > FEnd then
    FPos := FEnd;
end;

function TPdfLexer.PeekByte: Integer;
begin
  if FPos < FEnd then
    Result := FData[FPos]
  else
    Result := -1;
end;

function TPdfLexer.PeekByteAt(Offset: Integer): Integer;
begin
  if FPos + Offset < FEnd then
    Result := FData[FPos + Offset]
  else
    Result := -1;
end;

function TPdfLexer.AtEnd: Boolean;
begin
  Result := FPos >= FEnd;
end;

procedure TPdfLexer.SkipWhitespaceAndComments;
begin
  while FPos < FEnd do
  begin
    if IsPdfWhitespace(FData[FPos]) then
      Inc(FPos)
    else if FData[FPos] = Ord('%') then
    begin
      while (FPos < FEnd) and (FData[FPos] <> $0A) and (FData[FPos] <> $0D) do
        Inc(FPos);
    end
    else
      Break;
  end;
end;

function TPdfLexer.SkipEOL: Boolean;
begin
  Result := False;
  if (FPos < FEnd) and (FData[FPos] = $0D) then
  begin
    Inc(FPos);
    Result := True;
  end;
  if (FPos < FEnd) and (FData[FPos] = $0A) then
  begin
    Inc(FPos);
    Result := True;
  end;
end;

function TPdfLexer.NextToken: TPdfToken;
var
  B: Byte;
begin
  SkipWhitespaceAndComments;
  Result := Default(TPdfToken);
  Result.Position := FPos;
  if FPos >= FEnd then
  begin
    Result.Kind := tkEOF;
    Exit;
  end;
  B := FData[FPos];
  case B of
    Ord('0')..Ord('9'), Ord('+'), Ord('-'), Ord('.'):
      Result := ReadNumber;
    Ord('('):
      Result := ReadLiteralString;
    Ord('/'):
      Result := ReadName;
    Ord('['):
      begin
        Inc(FPos);
        Result.Kind := tkArrayOpen;
      end;
    Ord(']'):
      begin
        Inc(FPos);
        Result.Kind := tkArrayClose;
      end;
    Ord('<'):
      begin
        if PeekByteAt(1) = Ord('<') then
        begin
          Inc(FPos, 2);
          Result.Kind := tkDictOpen;
        end
        else
          Result := ReadHexString;
      end;
    Ord('>'):
      begin
        if PeekByteAt(1) = Ord('>') then
        begin
          Inc(FPos, 2);
          Result.Kind := tkDictClose;
        end
        else
        begin
          // Stray '>' (pdf.js: ignore and continue)
          Inc(FPos);
          Result := NextToken;
        end;
      end;
    Ord('{'):
      begin
        Inc(FPos);
        Result.Kind := tkBraceOpen;
      end;
    Ord('}'):
      begin
        Inc(FPos);
        Result.Kind := tkBraceClose;
      end;
    Ord(')'):
      begin
        // Unbalanced ')': skip it
        Inc(FPos);
        Result := NextToken;
      end;
  else
    Result := ReadKeyword;
  end;
end;

function TPdfLexer.ReadNumber: TPdfToken;
var
  Start: Integer;
  B: Byte;
  Sign: Integer;
  IntPart: Int64;
  Frac: Double;
  FracScale: Double;
  SeenDigit, SeenDot, SeenExp: Boolean;
  ExpSign, ExpValue: Integer;
  Value: Double;
begin
  Result := Default(TPdfToken);
  Result.Kind := tkNumber;
  Result.Position := FPos;
  Start := FPos;
  Sign := 1;
  // Tolerate repeated signs such as "--5" or "-+5" (pdf.js behaviour)
  while FPos < FEnd do
  begin
    B := FData[FPos];
    if B = Ord('-') then
      Sign := -1
    else if B = Ord('+') then
      Sign := 1
    else
      Break;
    Inc(FPos);
  end;
  IntPart := 0;
  Frac := 0;
  FracScale := 1;
  SeenDigit := False;
  SeenDot := False;
  SeenExp := False;
  ExpSign := 1;
  ExpValue := 0;
  while FPos < FEnd do
  begin
    B := FData[FPos];
    if IsPdfDigit(B) then
    begin
      SeenDigit := True;
      if SeenExp then
        ExpValue := Min(ExpValue * 10 + (B - Ord('0')), 400)
      else if SeenDot then
      begin
        FracScale := FracScale / 10;
        Frac := Frac + (B - Ord('0')) * FracScale;
      end
      else if IntPart < High(Int64) div 10 then
        IntPart := IntPart * 10 + (B - Ord('0'));
    end
    else if (B = Ord('.')) and not SeenExp then
    begin
      // A second '.' is ignored ("1.2.3" -> 1.23 in pdf.js terms; good enough)
      SeenDot := True;
    end
    else if (B = Ord('-')) and not SeenExp and SeenDigit then
    begin
      // "34.5-2" style garbage: ignore the trailing minus and the digits after it
      Inc(FPos);
      while (FPos < FEnd) and IsPdfDigit(FData[FPos]) do
        Inc(FPos);
      Break;
    end
    else if ((B = Ord('e')) or (B = Ord('E'))) and SeenDigit and not SeenExp then
    begin
      // Exponent is not valid PDF syntax but appears in the wild
      if (PeekByteAt(1) = Ord('-')) or (PeekByteAt(1) = Ord('+')) then
      begin
        if PeekByteAt(1) = Ord('-') then
          ExpSign := -1;
        Inc(FPos);
      end
      else if not ((PeekByteAt(1) >= Ord('0')) and (PeekByteAt(1) <= Ord('9'))) then
        Break;
      SeenExp := True;
    end
    else
      Break;
    Inc(FPos);
  end;
  if not SeenDigit then
  begin
    // Lone sign or dot: treat as the number 0 but make sure we advance.
    if FPos = Start then
      Inc(FPos);
    Result.NumberValue := 0;
    Result.IsInteger := True;
    Result.IntValue := 0;
    Exit;
  end;
  if SeenDot or SeenExp then
  begin
    Value := (IntPart + Frac) * Sign;
    if SeenExp then
      Value := Value * Power(10, ExpSign * ExpValue);
    Result.NumberValue := Value;
    Result.IsInteger := False;
    if Abs(Value) < 9.2E18 then
      Result.IntValue := Trunc(Value)
    else
      Result.IntValue := 0;
  end
  else
  begin
    Result.IntValue := IntPart * Sign;
    Result.NumberValue := Result.IntValue;
    Result.IsInteger := True;
  end;
end;

function TPdfLexer.ReadLiteralString: TPdfToken;
var
  Buf: TBytes;
  N, Depth, Octal, Digits: Integer;
  B: Byte;

  procedure Put(Value: Byte);
  begin
    if N >= Length(Buf) then
      SetLength(Buf, Max(32, Length(Buf) * 2));
    Buf[N] := Value;
    Inc(N);
  end;

begin
  Result := Default(TPdfToken);
  Result.Kind := tkString;
  Result.Position := FPos;
  Inc(FPos); // '('
  N := 0;
  Depth := 1;
  while FPos < FEnd do
  begin
    B := FData[FPos];
    Inc(FPos);
    case B of
      Ord('('):
        begin
          Inc(Depth);
          Put(B);
        end;
      Ord(')'):
        begin
          Dec(Depth);
          if Depth = 0 then
            Break;
          Put(B);
        end;
      Ord('\'):
        begin
          if FPos >= FEnd then
            Break;
          B := FData[FPos];
          Inc(FPos);
          case B of
            Ord('n'): Put($0A);
            Ord('r'): Put($0D);
            Ord('t'): Put($09);
            Ord('b'): Put($08);
            Ord('f'): Put($0C);
            Ord('0')..Ord('7'):
              begin
                Octal := B - Ord('0');
                Digits := 1;
                while (Digits < 3) and (FPos < FEnd) and
                      (FData[FPos] >= Ord('0')) and (FData[FPos] <= Ord('7')) do
                begin
                  Octal := Octal * 8 + (FData[FPos] - Ord('0'));
                  Inc(FPos);
                  Inc(Digits);
                end;
                Put(Byte(Octal and $FF));
              end;
            $0D:
              begin
                // Line continuation: backslash + CR [LF]
                if (FPos < FEnd) and (FData[FPos] = $0A) then
                  Inc(FPos);
              end;
            $0A:
              ; // continuation
          else
            Put(B); // \( \) \\ and unknown escapes: the character itself
          end;
        end;
      $0D:
        begin
          // CR or CRLF inside a literal string is normalised to LF
          if (FPos < FEnd) and (FData[FPos] = $0A) then
            Inc(FPos);
          Put($0A);
        end;
    else
      Put(B);
    end;
  end;
  SetLength(Buf, N);
  Result.Bytes := Buf;
end;

function TPdfLexer.ReadHexString: TPdfToken;
var
  Buf: TBytes;
  N, Digit, Pending: Integer;
  B: Byte;
  HavePending: Boolean;
begin
  Result := Default(TPdfToken);
  Result.Kind := tkString;
  Result.IsHexString := True;
  Result.Position := FPos;
  Inc(FPos); // '<'
  N := 0;
  Pending := 0;
  HavePending := False;
  SetLength(Buf, 32);
  while FPos < FEnd do
  begin
    B := FData[FPos];
    Inc(FPos);
    if B = Ord('>') then
      Break;
    Digit := PdfHexValue(B);
    if Digit < 0 then
      Continue; // whitespace and garbage are ignored
    if HavePending then
    begin
      if N >= Length(Buf) then
        SetLength(Buf, Length(Buf) * 2);
      Buf[N] := Byte(Pending * 16 + Digit);
      Inc(N);
      HavePending := False;
    end
    else
    begin
      Pending := Digit;
      HavePending := True;
    end;
  end;
  if HavePending then
  begin
    if N >= Length(Buf) then
      SetLength(Buf, Length(Buf) * 2);
    Buf[N] := Byte(Pending * 16);
    Inc(N);
  end;
  SetLength(Buf, N);
  Result.Bytes := Buf;
end;

function TPdfLexer.ReadName: TPdfToken;
var
  Buf: TBytes;
  N, H1, H2: Integer;
  B: Byte;
begin
  Result := Default(TPdfToken);
  Result.Kind := tkName;
  Result.Position := FPos;
  Inc(FPos); // '/'
  N := 0;
  SetLength(Buf, 32);
  while FPos < FEnd do
  begin
    B := FData[FPos];
    if not IsPdfRegular(B) then
      Break;
    Inc(FPos);
    if (B = Ord('#')) and (FPos + 1 < FEnd) then
    begin
      H1 := PdfHexValue(FData[FPos]);
      H2 := PdfHexValue(FData[FPos + 1]);
      if (H1 >= 0) and (H2 >= 0) then
      begin
        B := Byte(H1 * 16 + H2);
        Inc(FPos, 2);
      end;
    end;
    if N >= Length(Buf) then
      SetLength(Buf, Length(Buf) * 2);
    Buf[N] := B;
    Inc(N);
  end;
  SetLength(Buf, N);
  Result.Bytes := Buf;
end;

function TPdfLexer.ReadKeyword: TPdfToken;
var
  Start: Integer;
begin
  Result := Default(TPdfToken);
  Result.Kind := tkKeyword;
  Result.Position := FPos;
  Start := FPos;
  while (FPos < FEnd) and IsPdfRegular(FData[FPos]) do
    Inc(FPos);
  if FPos = Start then
    Inc(FPos); // should not happen (delimiters are handled by the caller) but never loop forever
  Result.Bytes := PdfCopyBytes(FData, Start, FPos - Start);
end;

end.
