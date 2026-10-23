{*******************************************************************************
  Pdf.Core.Types
  Basic types, exceptions and character classes shared by the Pdf.Core units.
  Pdf.Core has no dependency on Skia or FMX.
*******************************************************************************}
unit Pdf.Core.Types;

interface

uses
  System.SysUtils, System.Math;

type
  EPdfException = class(Exception);
  /// <summary>Malformed syntax in the file (lexer/parser level).</summary>
  EPdfSyntaxError = class(EPdfException);
  /// <summary>Stream filter failed or is unsupported.</summary>
  EPdfFilterError = class(EPdfException);
  /// <summary>Encryption dictionary invalid or unsupported.</summary>
  EPdfEncryptionError = class(EPdfException);
  /// <summary>Neither the user nor the owner password matched.</summary>
  EPdfPasswordError = class(EPdfEncryptionError);
  /// <summary>The document cannot be opened at all (no objects found).</summary>
  EPdfInvalidDocument = class(EPdfException);

  TPdfRectangle = record
    X0, Y0, X1, Y1: Double;
    class function Create(AX0, AY0, AX1, AY1: Double): TPdfRectangle; static;
    class function Empty: TPdfRectangle; static;
    /// <summary>Swaps coordinates so that X0 &lt;= X1 and Y0 &lt;= Y1.</summary>
    function Normalized: TPdfRectangle;
    function Width: Double;
    function Height: Double;
    function IsEmpty: Boolean;
    function Intersect(const R: TPdfRectangle): TPdfRectangle;
  end;

  /// <summary>PDF transformation matrix [a b c d e f].</summary>
  TPdfMatrix = record
    A, B, C, D, E, F: Double;
    class function Identity: TPdfMatrix; static;
    class function Create(AA, AB, AC, AD, AE, AF: Double): TPdfMatrix; static;
    class function Translation(DX, DY: Double): TPdfMatrix; static;
    class function Scaling(SX, SY: Double): TPdfMatrix; static;
    /// <summary>Returns Self x M (apply Self first, then M), as the PDF 'cm' operator does.</summary>
    function Multiply(const M: TPdfMatrix): TPdfMatrix;
    function Invert(out Inverse: TPdfMatrix): Boolean;
    procedure Apply(var X, Y: Double);
  end;

/// <summary>PDF whitespace: NUL, TAB, LF, FF, CR, SPACE.</summary>
function IsPdfWhitespace(B: Byte): Boolean; inline;
/// <summary>PDF delimiters: ( ) &lt; &gt; [ ] { } / %</summary>
function IsPdfDelimiter(B: Byte): Boolean; inline;
/// <summary>Any byte that is neither whitespace nor a delimiter.</summary>
function IsPdfRegular(B: Byte): Boolean; inline;
function IsPdfDigit(B: Byte): Boolean; inline;
function IsPdfHexDigit(B: Byte): Boolean; inline;
function PdfHexValue(B: Byte): Integer; inline;

/// <summary>Interprets bytes as Latin-1 (one char per byte); used for names, keywords and debugging.</summary>
function PdfBytesToLatin1(const Data: TBytes; Start, Len: Integer): string; overload;
function PdfBytesToLatin1(const Data: TBytes): string; overload;
function PdfLatin1ToBytes(const S: string): TBytes;
/// <summary>Concatenates two byte arrays.</summary>
function PdfConcatBytes(const A, B: TBytes): TBytes;
function PdfCopyBytes(const Data: TBytes; Start, Len: Integer): TBytes;

implementation

function IsPdfWhitespace(B: Byte): Boolean;
begin
  Result := (B = $20) or (B = $0A) or (B = $0D) or (B = $09) or (B = $0C) or (B = $00);
end;

function IsPdfDelimiter(B: Byte): Boolean;
begin
  case B of
    Ord('('), Ord(')'), Ord('<'), Ord('>'), Ord('['), Ord(']'),
    Ord('{'), Ord('}'), Ord('/'), Ord('%'):
      Result := True;
  else
    Result := False;
  end;
end;

function IsPdfRegular(B: Byte): Boolean;
begin
  Result := not IsPdfWhitespace(B) and not IsPdfDelimiter(B);
end;

function IsPdfDigit(B: Byte): Boolean;
begin
  Result := (B >= Ord('0')) and (B <= Ord('9'));
end;

function IsPdfHexDigit(B: Byte): Boolean;
begin
  Result := ((B >= Ord('0')) and (B <= Ord('9'))) or
            ((B >= Ord('a')) and (B <= Ord('f'))) or
            ((B >= Ord('A')) and (B <= Ord('F')));
end;

function PdfHexValue(B: Byte): Integer;
begin
  if (B >= Ord('0')) and (B <= Ord('9')) then
    Result := B - Ord('0')
  else if (B >= Ord('a')) and (B <= Ord('f')) then
    Result := B - Ord('a') + 10
  else if (B >= Ord('A')) and (B <= Ord('F')) then
    Result := B - Ord('A') + 10
  else
    Result := -1;
end;

function PdfBytesToLatin1(const Data: TBytes; Start, Len: Integer): string;
var
  I: Integer;
begin
  if Len <= 0 then
    Exit('');
  SetLength(Result, Len);
  for I := 0 to Len - 1 do
    Result[I + 1] := Char(Data[Start + I]);
end;

function PdfBytesToLatin1(const Data: TBytes): string;
begin
  Result := PdfBytesToLatin1(Data, 0, Integer(Length(Data)));
end;

function PdfLatin1ToBytes(const S: string): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(S));
  for I := 1 to Length(S) do
    Result[I - 1] := Byte(Ord(S[I]) and $FF);
end;

function PdfConcatBytes(const A, B: TBytes): TBytes;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then
    Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then
    Move(B[0], Result[Length(A)], Length(B));
end;

function PdfCopyBytes(const Data: TBytes; Start, Len: Integer): TBytes;
begin
  if Start < 0 then
    Start := 0;
  if Start + Len > Length(Data) then
    Len := Integer(Length(Data)) - Start;
  if Len <= 0 then
    Exit(nil);
  SetLength(Result, Len);
  Move(Data[Start], Result[0], Len);
end;

{ TPdfRectangle }

class function TPdfRectangle.Create(AX0, AY0, AX1, AY1: Double): TPdfRectangle;
begin
  Result.X0 := AX0;
  Result.Y0 := AY0;
  Result.X1 := AX1;
  Result.Y1 := AY1;
end;

class function TPdfRectangle.Empty: TPdfRectangle;
begin
  Result := Create(0, 0, 0, 0);
end;

function TPdfRectangle.Normalized: TPdfRectangle;
begin
  Result := Self;
  if Result.X0 > Result.X1 then
  begin
    Result.X0 := X1;
    Result.X1 := X0;
  end;
  if Result.Y0 > Result.Y1 then
  begin
    Result.Y0 := Y1;
    Result.Y1 := Y0;
  end;
end;

function TPdfRectangle.Width: Double;
begin
  Result := Abs(X1 - X0);
end;

function TPdfRectangle.Height: Double;
begin
  Result := Abs(Y1 - Y0);
end;

function TPdfRectangle.IsEmpty: Boolean;
begin
  Result := (Width <= 0) or (Height <= 0);
end;

function TPdfRectangle.Intersect(const R: TPdfRectangle): TPdfRectangle;
var
  A, B: TPdfRectangle;
begin
  A := Normalized;
  B := R.Normalized;
  Result.X0 := Max(A.X0, B.X0);
  Result.Y0 := Max(A.Y0, B.Y0);
  Result.X1 := Min(A.X1, B.X1);
  Result.Y1 := Min(A.Y1, B.Y1);
  if (Result.X1 < Result.X0) or (Result.Y1 < Result.Y0) then
    Result := Empty;
end;

{ TPdfMatrix }

class function TPdfMatrix.Identity: TPdfMatrix;
begin
  Result := Create(1, 0, 0, 1, 0, 0);
end;

class function TPdfMatrix.Create(AA, AB, AC, AD, AE, AF: Double): TPdfMatrix;
begin
  Result.A := AA;
  Result.B := AB;
  Result.C := AC;
  Result.D := AD;
  Result.E := AE;
  Result.F := AF;
end;

class function TPdfMatrix.Translation(DX, DY: Double): TPdfMatrix;
begin
  Result := Create(1, 0, 0, 1, DX, DY);
end;

class function TPdfMatrix.Scaling(SX, SY: Double): TPdfMatrix;
begin
  Result := Create(SX, 0, 0, SY, 0, 0);
end;

function TPdfMatrix.Multiply(const M: TPdfMatrix): TPdfMatrix;
begin
  Result.A := A * M.A + B * M.C;
  Result.B := A * M.B + B * M.D;
  Result.C := C * M.A + D * M.C;
  Result.D := C * M.B + D * M.D;
  Result.E := E * M.A + F * M.C + M.E;
  Result.F := E * M.B + F * M.D + M.F;
end;

function TPdfMatrix.Invert(out Inverse: TPdfMatrix): Boolean;
var
  Det: Double;
begin
  Det := A * D - B * C;
  if Abs(Det) < 1E-12 then
    Exit(False);
  Inverse.A := D / Det;
  Inverse.B := -B / Det;
  Inverse.C := -C / Det;
  Inverse.D := A / Det;
  Inverse.E := (C * F - D * E) / Det;
  Inverse.F := (B * E - A * F) / Det;
  Result := True;
end;

procedure TPdfMatrix.Apply(var X, Y: Double);
var
  NX: Double;
begin
  NX := A * X + C * Y + E;
  Y := B * X + D * Y + F;
  X := NX;
end;

end.
