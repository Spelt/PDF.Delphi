{*******************************************************************************
  Pdf.Font.Type1
  Adobe Type 1 font programs (Adobe Type 1 Font Format, version 1.1): the
  container (PFB segments, PFA with a hex eexec section, or the binary form
  embedded as a PDF /FontFile), the clear-text header (/FontName,
  /FontMatrix, /FontBBox, /Encoding), eexec and charstring decryption, the
  private part (/lenIV, /Subrs, /CharStrings) and a Type 1 charstring
  interpreter (hints ignored, flex and seac supported) that produces glyph
  outlines in glyph units.

  The structure follows pdf.js (src/core/type1_parser.js and type1_font.js,
  Apache 2.0, see NOTICE): the clear text is scanned for the few keys that
  matter instead of being executed as PostScript, and the private part is
  scanned for /Subrs and /CharStrings.
*******************************************************************************}
unit Pdf.Font.Type1;

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections, Pdf.Core.Types, Pdf.Font.Glyphs;

type
  /// <summary>A parsed Type 1 font program. Glyph indices are the CharStrings entries in file order
  /// ('.notdef' may be anywhere). Outlines are produced on demand by the charstring interpreter; the
  /// object is read-only after construction.</summary>
  TPdfType1Font = class(TPdfGlyphSource)
  private
    FFontName: string;
    FFontMatrix: TPdfMatrix;
    FFontBBox: TPdfRectangle;
    FStandardEncoding: Boolean;
    FEncoding: TArray<string>;
    FNames: TArray<string>;
    FCharStrings: TArray<TBytes>;
    FSubrs: TArray<TBytes>;
    FNameMap: TDictionary<string, Integer>;
    FAdvances: TArray<Single>;
    FOutlineCount: Integer;
    procedure ParseHeader(const Clear: TBytes);
    function ParsePrivate(const Priv: TBytes): Boolean;
    procedure ComputeMetrics;
    function Interpret(GID: Integer; AllowSeac: Boolean; out Outline: TPdfGlyphOutline; out Width: Double): Boolean;
    function StandardCodeGlyph(Code: Integer): Integer;
  public
    /// <summary>True for '%!PS-AdobeFont', '%!FontType1', a PFB segment header ($80 $01) or any data containing
    /// 'eexec' in the first 4 KB.</summary>
    class function IsType1(const Data: TBytes): Boolean; static;
    /// <summary>Parses a Type 1 program in PFB, PFA or PDF-embedded (clear text + binary eexec) form.
    /// Raises EPdfFontError only when no CharStrings can be found at all.</summary>
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    /// <summary>/FontMatrix, default [0.001 0 0 0.001 0 0].</summary>
    function FontMatrix: TPdfMatrix; override;
    /// <summary>Number of CharStrings entries.</summary>
    function GlyphCount: Integer; override;
    /// <summary>Outline of GID in glyph units (y up). False (empty outline) when GID is out of range or the
    /// charstring is corrupt; an unknown operator ends the glyph with what was drawn so far.</summary>
    function GetOutline(GID: Integer; out Outline: TPdfGlyphOutline): Boolean; override;
    /// <summary>Width from hsbw/sbw; -1 when GID is out of range or the charstring sets no width.</summary>
    function GetAdvance(GID: Integer): Single; override;
    /// <summary>Glyph index of a CharStrings key; -1 when absent (duplicate keys: the last one wins).</summary>
    function GlyphByName(const Name: string): Integer; override;
    /// <summary>Glyph index through the built-in /Encoding (code, then name, then glyph); -1 when unmapped.</summary>
    function GlyphByCode(Code: Integer): Integer; override;
    function HasGlyphNames: Boolean; override;
    function HasCodeMap: Boolean; override;
    /// <summary>Number of charstrings that draw at least one line or curve.</summary>
    function OutlineCount: Integer; override;
    /// <summary>Glyph name of a glyph index, '' when out of range.</summary>
    function GlyphName(GID: Integer): string;
    /// <summary>Name of the glyph the built-in encoding maps Code to ('' when unmapped or '.notdef').</summary>
    function EncodingName(Code: Integer): string;
    /// <summary>True when the font declares a named encoding (/Encoding StandardEncoding; other names are treated
    /// as StandardEncoding too) as opposed to a custom array.</summary>
    property HasStandardEncoding: Boolean read FStandardEncoding;
    /// <summary>/FontName from the clear text ('' when absent).</summary>
    property FontName: string read FFontName;
    /// <summary>/FontBBox in glyph units (empty when absent).</summary>
    property FontBBox: TPdfRectangle read FFontBBox;
  end;

implementation

const
  EexecKey = 55665;
  CharStringKey = 4330;
  CryptC1 = 52845;
  CryptC2 = 22719;
  MaxStack = 64;
  MaxSubrDepth = 10;
  MaxFlexPoints = 16;
  MaxOpsPerGlyph = 1000000;
  MaxGlyphs = 65535;
  MaxSubrs = 65536;
  MaxStackValue = 2147483648.0;

  StdEncNames: array[0..255] of string = (
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',
    '', '', '', '', '', '', 'space', 'exclam', 'quotedbl', 'numbersign', 'dollar', 'percent', 'ampersand',
    'quoteright', 'parenleft', 'parenright', 'asterisk', 'plus', 'comma', 'hyphen', 'period', 'slash',
    'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'colon', 'semicolon',
    'less', 'equal', 'greater', 'question', 'at', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L',
    'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'bracketleft', 'backslash',
    'bracketright', 'asciicircum', 'underscore', 'quoteleft', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i',
    'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'braceleft', 'bar',
    'braceright', 'asciitilde', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', 'exclamdown', 'cent', 'sterling', 'fraction',
    'yen', 'florin', 'section', 'currency', 'quotesingle', 'quotedblleft', 'guillemotleft', 'guilsinglleft',
    'guilsinglright', 'fi', 'fl', '', 'endash', 'dagger', 'daggerdbl', 'periodcentered', '', 'paragraph',
    'bullet', 'quotesinglbase', 'quotedblbase', 'quotedblright', 'guillemotright', 'ellipsis', 'perthousand',
    '', 'questiondown', '', 'grave', 'acute', 'circumflex', 'tilde', 'macron', 'breve', 'dotaccent',
    'dieresis', '', 'ring', 'cedilla', '', 'hungarumlaut', 'ogonek', 'caron', 'emdash', '', '', '', '', '',
    '', '', '', '', '', '', '', '', '', '', '', 'AE', '', 'ordfeminine', '', '', '', '', 'Lslash', 'Oslash',
    'OE', 'ordmasculine', '', '', '', '', '', 'ae', '', '', '', 'dotlessi', '', '', 'lslash', 'oslash', 'oe',
    'germandbls', '', '', '', '');

{ ---------------------------------------------------------------------------- }
{ Byte helpers                                                                 }
{ ---------------------------------------------------------------------------- }

function IsPsSpace(B: Byte): Boolean; inline;
begin
  Result := B in [0, 9, 10, 12, 13, 32];
end;

function IsPsDelim(B: Byte): Boolean; inline;
begin
  Result := B in [Ord('('), Ord(')'), Ord('<'), Ord('>'), Ord('['), Ord(']'), Ord('{'), Ord('}'), Ord('/'), Ord('%')];
end;

function HexValue(B: Byte): Integer; inline;
begin
  case B of
    Ord('0')..Ord('9'): Result := B - Ord('0');
    Ord('A')..Ord('F'): Result := B - Ord('A') + 10;
    Ord('a')..Ord('f'): Result := B - Ord('a') + 10;
  else
    Result := -1;
  end;
end;

/// <summary>Index of Pattern in Data[Start..Limit-1] (the match must fit before Limit), or -1.</summary>
function FindBytes(const Data: TBytes; const Pattern: RawByteString; Start, Limit: Integer): Integer;
var
  I, J, PLen: Integer;
begin
  PLen := Length(Pattern);
  Limit := Min(Limit, Integer(Length(Data)));
  for I := Max(Start, 0) to Limit - PLen do
  begin
    J := 0;
    while (J < PLen) and (Data[I + J] = Byte(Pattern[J + 1])) do
      Inc(J);
    if J = PLen then
      Exit(I);
  end;
  Result := -1;
end;

function StartsWithBytes(const Data: TBytes; const Prefix: RawByteString): Boolean;
begin
  Result := (Length(Data) >= Length(Prefix)) and (FindBytes(Data, Prefix, 0, Length(Prefix)) = 0);
end;

/// <summary>Type 1 decryption (eexec or charstring key) of Data[Start..Start+Count-1], dropping the first Skip
/// plaintext bytes.</summary>
function Type1Decrypt(const Data: TBytes; Start, Count: Integer; Key: Cardinal; Skip: Integer): TBytes;
var
  I: Integer;
  R: Cardinal;
  C: Byte;
begin
  Result := nil;
  if (Start < 0) or (Count <= 0) or (Start + Count > Length(Data)) then
    Exit;
  if Skip < 0 then
    Skip := 0;
  if Count <= Skip then
    Exit;
  SetLength(Result, Count - Skip);
  R := Key;
  for I := 0 to Count - 1 do
  begin
    C := Data[Start + I];
    if I >= Skip then
      Result[I - Skip] := C xor Byte(R shr 8);
    R := ((Cardinal(C) + R) * Cardinal(CryptC1) + Cardinal(CryptC2)) and $FFFF;
  end;
end;

/// <summary>Hex digits from Data[Start..] up to the first byte that is neither a hex digit nor white space.</summary>
function DecodeHexSection(const Data: TBytes; Start: Integer): TBytes;
var
  I, N, Digit, High4: Integer;
begin
  SetLength(Result, Max(0, (Integer(Length(Data)) - Start) div 2));
  N := 0;
  High4 := -1;
  I := Start;
  while I < Length(Data) do
  begin
    Digit := HexValue(Data[I]);
    if Digit < 0 then
    begin
      if not IsPsSpace(Data[I]) then
        Break;
    end
    else if High4 < 0 then
      High4 := Digit
    else
    begin
      if N < Length(Result) then
      begin
        Result[N] := Byte((High4 shl 4) or Digit);
        Inc(N);
      end;
      High4 := -1;
    end;
    Inc(I);
  end;
  SetLength(Result, N);
end;

/// <summary>Position of the 'eexec' keyword: preceded by white space and not inside a % comment line; falls back to
/// the first occurrence of the bytes. -1 when absent.</summary>
function FindEexec(const Data: TBytes): Integer;
var
  P, Q: Integer;
  InComment: Boolean;
begin
  P := FindBytes(Data, 'eexec', 0, Length(Data));
  Result := P;
  while P >= 0 do
  begin
    if (P = 0) or IsPsSpace(Data[P - 1]) then
    begin
      InComment := False;
      Q := P - 1;
      while (Q >= 0) and not (Data[Q] in [10, 13]) do
      begin
        if Data[Q] = Ord('%') then
          InComment := True;
        Dec(Q);
      end;
      if not InComment then
        Exit(P);
    end;
    P := FindBytes(Data, 'eexec', P + 1, Length(Data));
  end;
end;

/// <summary>Concatenates the ASCII (1) and binary (2) segments of a PFB file.</summary>
function UnwrapPfb(const Data: TBytes): TBytes;
var
  P, Len: Integer;
  SegLen: Int64;
  SegType: Byte;
begin
  Result := nil;
  P := 0;
  Len := Length(Data);
  while (P + 6 <= Len) and (Data[P] = $80) do
  begin
    SegType := Data[P + 1];
    if not (SegType in [1, 2]) then
      Break;
    SegLen := Int64(Data[P + 2]) or (Int64(Data[P + 3]) shl 8) or (Int64(Data[P + 4]) shl 16) or
      (Int64(Data[P + 5]) shl 24);
    if SegLen > Len - P - 6 then
      SegLen := Len - P - 6;
    Result := PdfConcatBytes(Result, PdfCopyBytes(Data, P + 6, Integer(SegLen)));
    Inc(P, 6 + Integer(SegLen));
  end;
end;

{ ---------------------------------------------------------------------------- }
{ PostScript scanner                                                           }
{ ---------------------------------------------------------------------------- }

type
  TPsTokenKind = (tkEOF, tkName, tkWord, tkOpen, tkClose, tkString, tkOther);

  TPsToken = record
    Kind: TPsTokenKind;
    Text: string;
    function IsWord(const S: string): Boolean;
  end;

  /// <summary>Minimal PostScript tokenizer over a byte buffer; binary data after RD is read with ReadBinary.</summary>
  TPsScanner = record
    Data: TBytes;
    Pos: Integer;
    procedure Init(const AData: TBytes);
    function Next: TPsToken;
    /// <summary>Skips the single space after the RD keyword and returns the next Count bytes (clipped).</summary>
    function ReadBinary(Count: Integer): TBytes;
  end;

function TPsToken.IsWord(const S: string): Boolean;
begin
  Result := (Kind = tkWord) and (Text = S);
end;

procedure TPsScanner.Init(const AData: TBytes);
begin
  Data := AData;
  Pos := 0;
end;

function TPsScanner.Next: TPsToken;
var
  Len, Start, Depth: Integer;
  B: Byte;
begin
  Len := Length(Data);
  Result.Text := '';
  while Pos < Len do
  begin
    B := Data[Pos];
    if IsPsSpace(B) then
      Inc(Pos)
    else if B = Ord('%') then
    begin
      while (Pos < Len) and not (Data[Pos] in [10, 13]) do
        Inc(Pos);
    end
    else
      Break;
  end;
  if Pos >= Len then
  begin
    Result.Kind := tkEOF;
    Exit;
  end;
  B := Data[Pos];
  case B of
    Ord('/'):
      begin
        Inc(Pos);
        if (Pos < Len) and (Data[Pos] = Ord('/')) then
          Inc(Pos);
        Start := Pos;
        while (Pos < Len) and not IsPsSpace(Data[Pos]) and not IsPsDelim(Data[Pos]) do
          Inc(Pos);
        Result.Kind := tkName;
        Result.Text := PdfBytesToLatin1(Data, Start, Pos - Start);
      end;
    Ord('['), Ord('{'):
      begin
        Result.Kind := tkOpen;
        Result.Text := Char(B);
        Inc(Pos);
      end;
    Ord(']'), Ord('}'):
      begin
        Result.Kind := tkClose;
        Result.Text := Char(B);
        Inc(Pos);
      end;
    Ord('('):
      begin
        Depth := 1;
        Inc(Pos);
        while (Pos < Len) and (Depth > 0) do
        begin
          case Data[Pos] of
            Ord('\'): Inc(Pos);
            Ord('('): Inc(Depth);
            Ord(')'): Dec(Depth);
          end;
          Inc(Pos);
        end;
        Result.Kind := tkString;
      end;
    Ord('<'):
      begin
        Inc(Pos);
        if (Pos < Len) and (Data[Pos] = Ord('<')) then
        begin
          Inc(Pos);
          Result.Kind := tkOther;
          Result.Text := '<<';
        end
        else
        begin
          while (Pos < Len) and (Data[Pos] <> Ord('>')) do
            Inc(Pos);
          if Pos < Len then
            Inc(Pos);
          Result.Kind := tkString;
        end;
      end;
    Ord('>'), Ord(')'):
      begin
        Inc(Pos);
        if (B = Ord('>')) and (Pos < Len) and (Data[Pos] = Ord('>')) then
          Inc(Pos);
        Result.Kind := tkOther;
        Result.Text := Char(B);
      end;
  else
    Start := Pos;
    while (Pos < Len) and not IsPsSpace(Data[Pos]) and not IsPsDelim(Data[Pos]) do
      Inc(Pos);
    Result.Kind := tkWord;
    Result.Text := PdfBytesToLatin1(Data, Start, Pos - Start);
  end;
end;

function TPsScanner.ReadBinary(Count: Integer): TBytes;
var
  N: Integer;
begin
  if Pos < Length(Data) then
    Inc(Pos);
  N := Max(0, Min(Count, Integer(Length(Data)) - Pos));
  Result := PdfCopyBytes(Data, Pos, N);
  Inc(Pos, N);
end;

/// <summary>Parses a PostScript number (integer, real or radix 'base#digits').</summary>
function PsTryNumber(const S: string; out V: Double): Boolean;
var
  P, Radix, I, Digit: Integer;
  Acc: Int64;
  C: Char;
begin
  Result := False;
  V := 0;
  if (S = '') or not CharInSet(S[1], ['0'..'9', '+', '-', '.']) then
    Exit;
  P := Pos('#', S);
  if P > 1 then
  begin
    if not TryStrToInt(Copy(S, 1, P - 1), Radix) or (Radix < 2) or (Radix > 36) or (P = Length(S)) then
      Exit;
    Acc := 0;
    for I := P + 1 to Length(S) do
    begin
      C := UpCase(S[I]);
      case C of
        '0'..'9': Digit := Ord(C) - Ord('0');
        'A'..'Z': Digit := Ord(C) - Ord('A') + 10;
      else
        Exit;
      end;
      if (Digit >= Radix) or (Acc > High(Integer)) then
        Exit;
      Acc := Acc * Radix + Digit;
    end;
    V := Acc;
    Exit(True);
  end;
  Result := TryStrToFloat(S, V, TFormatSettings.Invariant) and not IsNan(V) and not IsInfinite(V);
end;

function PsTryInt(const S: string; out I: Integer): Boolean;
var
  V: Double;
begin
  I := 0;
  Result := PsTryNumber(S, V) and (Abs(V) < MaxInt) and (Frac(V) = 0);
  if Result then
    I := Trunc(V);
end;

/// <summary>Reads '[' or '{', then numbers up to the matching ']' or '}'.</summary>
function ReadNumberArray(var S: TPsScanner; out Values: TArray<Double>): Boolean;
var
  T: TPsToken;
  V: Double;
  N: Integer;
begin
  Values := nil;
  T := S.Next;
  if T.Kind <> tkOpen then
    Exit(False);
  N := 0;
  repeat
    T := S.Next;
    if T.Kind in [tkEOF, tkClose] then
      Break;
    if (T.Kind = tkWord) and PsTryNumber(T.Text, V) then
    begin
      SetLength(Values, N + 1);
      Values[N] := V;
      Inc(N);
    end;
  until N >= 64;
  Result := True;
end;

{ ---------------------------------------------------------------------------- }
{ Charstring interpreter                                                       }
{ ---------------------------------------------------------------------------- }

type
  TT1Result = (trContinue, trReturn, trEnd, trError);

  /// <summary>Type 1 charstring interpreter state for one glyph (hints are ignored).</summary>
  TT1Interpreter = record
  private
    Font: TPdfType1Font;
    Stack: array[0..MaxStack - 1] of Double;
    SP: Integer;
    PS: array[0..MaxStack - 1] of Double;
    PSP: Integer;
    X, Y, StartX, StartY: Double;
    Open: Boolean;
    Flexing: Boolean;
    FlexX, FlexY: array[0..MaxFlexPoints - 1] of Double;
    FlexCount: Integer;
    Sbx: Double;
    Ops: Integer;
    AllowSeac: Boolean;
    procedure EnsureOpen;
    procedure MoveBy(DX, DY: Double);
    procedure LineBy(DX, DY: Double);
    procedure CurveBy(DX1, DY1, DX2, DY2, DX3, DY3: Double);
    procedure AddFlex(DX, DY: Double);
    procedure EndFlex;
    function PushPS(V: Double): Boolean;
    function Seac: TT1Result;
    function CallOtherSubr: TT1Result;
  public
    Outline: TPdfGlyphOutline;
    Width: Double;
    HaveWidth: Boolean;
    procedure Init(AFont: TPdfType1Font; AAllowSeac: Boolean);
    procedure ClosePath;
    function Run(const Code: TBytes; Depth: Integer): TT1Result;
  end;

function TryIndex(V: Double; out I: Integer): Boolean;
begin
  Result := (Abs(V) < MaxStackValue) and (Frac(V) = 0);
  if Result then
    I := Trunc(V)
  else
    I := -1;
end;

procedure TT1Interpreter.Init(AFont: TPdfType1Font; AAllowSeac: Boolean);
begin
  Self := Default(TT1Interpreter);
  Font := AFont;
  AllowSeac := AAllowSeac;
end;

procedure TT1Interpreter.EnsureOpen;
begin
  if not Open then
  begin
    Outline.MoveTo(X, Y);
    StartX := X;
    StartY := Y;
    Open := True;
  end;
end;

procedure TT1Interpreter.ClosePath;
begin
  if Open then
  begin
    if (Single(X) <> Single(StartX)) or (Single(Y) <> Single(StartY)) then
      Outline.LineTo(StartX, StartY);
    Outline.Close;
    Open := False;
  end;
end;

procedure TT1Interpreter.MoveBy(DX, DY: Double);
begin
  ClosePath;
  X := X + DX;
  Y := Y + DY;
end;

procedure TT1Interpreter.LineBy(DX, DY: Double);
begin
  EnsureOpen;
  X := X + DX;
  Y := Y + DY;
  Outline.LineTo(X, Y);
end;

procedure TT1Interpreter.CurveBy(DX1, DY1, DX2, DY2, DX3, DY3: Double);
var
  X1, Y1, X2, Y2: Double;
begin
  EnsureOpen;
  X1 := X + DX1;
  Y1 := Y + DY1;
  X2 := X1 + DX2;
  Y2 := Y1 + DY2;
  X := X2 + DX3;
  Y := Y2 + DY3;
  Outline.CubicTo(X1, Y1, X2, Y2, X, Y);
end;

procedure TT1Interpreter.AddFlex(DX, DY: Double);
begin
  if FlexCount < MaxFlexPoints then
  begin
    FlexX[FlexCount] := DX;
    FlexY[FlexCount] := DY;
    Inc(FlexCount);
  end;
end;

procedure TT1Interpreter.EndFlex;
var
  RX, RY, X1, Y1, X2, Y2, X3, Y3, X4, Y4, PX, PY: Double;
  K: Integer;
begin
  if FlexCount >= 7 then
  begin
    // Point 0 is the reference point (relative to the current point), points 1..6 are the two curves,
    // each relative to the previous point. As in pdf.js, the first control point is rp + bcp1.
    RX := X + FlexX[0];
    RY := Y + FlexY[0];
    X1 := RX + FlexX[1];
    Y1 := RY + FlexY[1];
    X2 := X1 + FlexX[2];
    Y2 := Y1 + FlexY[2];
    PX := X2 + FlexX[3];
    PY := Y2 + FlexY[3];
    X3 := PX + FlexX[4];
    Y3 := PY + FlexY[4];
    X4 := X3 + FlexX[5];
    Y4 := Y3 + FlexY[5];
    EnsureOpen;
    Outline.CubicTo(X1, Y1, X2, Y2, PX, PY);
    X := X4 + FlexX[6];
    Y := Y4 + FlexY[6];
    Outline.CubicTo(X3, Y3, X4, Y4, X, Y);
  end
  else if FlexCount > 0 then
  begin
    // Malformed flex: connect the collected points with straight lines.
    PX := FlexX[0];
    PY := FlexY[0];
    for K := 1 to FlexCount - 1 do
    begin
      PX := PX + FlexX[K];
      PY := PY + FlexY[K];
    end;
    LineBy(PX, PY);
  end;
  FlexCount := 0;
  Flexing := False;
end;

function TT1Interpreter.PushPS(V: Double): Boolean;
begin
  Result := PSP < MaxStack;
  if Result then
  begin
    PS[PSP] := V;
    Inc(PSP);
  end;
end;

function TT1Interpreter.CallOtherSubr: TT1Result;
var
  OtherSubr, N, K: Integer;
begin
  Result := trContinue;
  if (SP < 2) or not TryIndex(Stack[SP - 1], OtherSubr) or not TryIndex(Stack[SP - 2], N) then
    Exit(trError);
  Dec(SP, 2);
  if (N < 0) or (N > SP) then
    Exit(trError);
  case OtherSubr of
    0:
      begin
        // Flex end: flexdepth endx endy 3 0 callothersubr; the end point is left for the two pops.
        EndFlex;
        if N >= 2 then
        begin
          if not PushPS(Stack[SP - 1]) or not PushPS(Stack[SP - 2]) then
            Exit(trError);
        end;
        Dec(SP, N);
      end;
    1:
      begin
        Flexing := True;
        FlexCount := 0;
        Dec(SP, N);
      end;
    2:
      Dec(SP, N);
    3:
      begin
        // Hint replacement: subr# 1 3 callothersubr pop callsubr; returning 3 calls the empty Subrs 3.
        Dec(SP, N);
        if not PushPS(3) then
          Exit(trError);
      end;
  else
    // Unknown othersubr: the arguments become its results, the first pop yields the first argument.
    for K := SP - 1 downto SP - N do
      if not PushPS(Stack[K]) then
        Exit(trError);
    Dec(SP, N);
  end;
end;

function TT1Interpreter.Seac: TT1Result;
var
  Asb, Adx, Ady: Double;
  BChar, AChar, BaseGID, AccentGID: Integer;
  Part: TPdfGlyphOutline;
  W: Double;
begin
  Asb := Stack[SP - 5];
  Adx := Stack[SP - 4];
  Ady := Stack[SP - 3];
  if not TryIndex(Stack[SP - 2], BChar) or not TryIndex(Stack[SP - 1], AChar) or not AllowSeac then
    Exit(trError);
  SP := 0;
  ClosePath;
  BaseGID := Font.StandardCodeGlyph(BChar);
  AccentGID := Font.StandardCodeGlyph(AChar);
  if (BaseGID >= 0) and Font.Interpret(BaseGID, False, Part, W) then
    Outline.Append(Part, 0, 0);
  // As pdf.js / FreeType: the accent is displaced by adx - asb plus the composite's own side bearing.
  if (AccentGID >= 0) and Font.Interpret(AccentGID, False, Part, W) then
    Outline.Append(Part, Adx - Asb + Sbx, Ady);
  Result := trEnd;
end;

function TT1Interpreter.Run(const Code: TBytes; Depth: Integer): TT1Result;
var
  I, Len, Op, Idx: Integer;
  B: Byte;
  V: Double;
  R: TT1Result;
begin
  if Depth > MaxSubrDepth then
    Exit(trError);
  Len := Length(Code);
  I := 0;
  while I < Len do
  begin
    Inc(Ops);
    if Ops > MaxOpsPerGlyph then
      Exit(trError);
    B := Code[I];
    Inc(I);
    if B >= 32 then
    begin
      if B <= 246 then
        V := Integer(B) - 139
      else if B <= 250 then
      begin
        if I >= Len then
          Exit(trError);
        V := (Integer(B) - 247) * 256 + Integer(Code[I]) + 108;
        Inc(I);
      end
      else if B <= 254 then
      begin
        if I >= Len then
          Exit(trError);
        V := -(Integer(B) - 251) * 256 - Integer(Code[I]) - 108;
        Inc(I);
      end
      else
      begin
        if I + 4 > Len then
          Exit(trError);
        V := Int32((Cardinal(Code[I]) shl 24) or (Cardinal(Code[I + 1]) shl 16) or (Cardinal(Code[I + 2]) shl 8) or
          Cardinal(Code[I + 3]));
        Inc(I, 4);
      end;
      if SP >= MaxStack then
        Exit(trError);
      Stack[SP] := V;
      Inc(SP);
      Continue;
    end;
    Op := B;
    if Op = 12 then
    begin
      if I >= Len then
      begin
        ClosePath;
        Exit(trEnd);
      end;
      Op := (12 shl 8) or Code[I];
      Inc(I);
    end;
    case Op of
      1, 3, (12 shl 8) or 0, (12 shl 8) or 1, (12 shl 8) or 2:
        SP := 0; // hstem, vstem, dotsection, vstem3, hstem3
      4: // vmoveto
        begin
          if SP < 1 then
            Exit(trError);
          if Flexing then
            AddFlex(0, Stack[SP - 1])
          else
            MoveBy(0, Stack[SP - 1]);
          SP := 0;
        end;
      5: // rlineto
        begin
          if SP < 2 then
            Exit(trError);
          LineBy(Stack[SP - 2], Stack[SP - 1]);
          SP := 0;
        end;
      6: // hlineto
        begin
          if SP < 1 then
            Exit(trError);
          LineBy(Stack[SP - 1], 0);
          SP := 0;
        end;
      7: // vlineto
        begin
          if SP < 1 then
            Exit(trError);
          LineBy(0, Stack[SP - 1]);
          SP := 0;
        end;
      8: // rrcurveto
        begin
          if SP < 6 then
            Exit(trError);
          CurveBy(Stack[SP - 6], Stack[SP - 5], Stack[SP - 4], Stack[SP - 3], Stack[SP - 2], Stack[SP - 1]);
          SP := 0;
        end;
      9: // closepath
        begin
          ClosePath;
          SP := 0;
        end;
      10: // callsubr
        begin
          if (SP < 1) or not TryIndex(Stack[SP - 1], Idx) or (Idx < 0) or (Idx >= Length(Font.FSubrs)) then
            Exit(trError);
          Dec(SP);
          R := Run(Font.FSubrs[Idx], Depth + 1);
          if R in [trEnd, trError] then
            Exit(R);
        end;
      11: // return
        Exit(trReturn);
      13: // hsbw
        begin
          if SP < 2 then
            Exit(trError);
          Sbx := Stack[SP - 2];
          Width := Stack[SP - 1];
          HaveWidth := True;
          X := Sbx;
          Y := 0;
          SP := 0;
        end;
      14: // endchar
        begin
          ClosePath;
          Exit(trEnd);
        end;
      21: // rmoveto
        begin
          if SP < 2 then
            Exit(trError);
          if Flexing then
            AddFlex(Stack[SP - 2], Stack[SP - 1])
          else
            MoveBy(Stack[SP - 2], Stack[SP - 1]);
          SP := 0;
        end;
      22: // hmoveto
        begin
          if SP < 1 then
            Exit(trError);
          if Flexing then
            AddFlex(Stack[SP - 1], 0)
          else
            MoveBy(Stack[SP - 1], 0);
          SP := 0;
        end;
      30: // vhcurveto
        begin
          if SP < 4 then
            Exit(trError);
          CurveBy(0, Stack[SP - 4], Stack[SP - 3], Stack[SP - 2], Stack[SP - 1], 0);
          SP := 0;
        end;
      31: // hvcurveto
        begin
          if SP < 4 then
            Exit(trError);
          CurveBy(Stack[SP - 4], 0, Stack[SP - 3], Stack[SP - 2], 0, Stack[SP - 1]);
          SP := 0;
        end;
      (12 shl 8) or 6: // seac
        begin
          if SP < 5 then
            Exit(trError);
          Exit(Seac);
        end;
      (12 shl 8) or 7: // sbw
        begin
          if SP < 4 then
            Exit(trError);
          Sbx := Stack[SP - 4];
          X := Sbx;
          Y := Stack[SP - 3];
          Width := Stack[SP - 2];
          HaveWidth := True;
          SP := 0;
        end;
      (12 shl 8) or 12: // div
        begin
          if SP < 2 then
            Exit(trError);
          if Abs(Stack[SP - 1]) < 1E-9 then
            V := 0
          else
            V := EnsureRange(Stack[SP - 2] / Stack[SP - 1], -MaxStackValue, MaxStackValue);
          Dec(SP);
          Stack[SP - 1] := V;
        end;
      (12 shl 8) or 16: // callothersubr
        begin
          R := CallOtherSubr;
          if R <> trContinue then
            Exit(R);
        end;
      (12 shl 8) or 17: // pop
        if PSP > 0 then
        begin
          if SP >= MaxStack then
            Exit(trError);
          Dec(PSP);
          Stack[SP] := PS[PSP];
          Inc(SP);
        end;
      (12 shl 8) or 33: // setcurrentpoint: only follows flex, whose end point is already current
        SP := 0;
    else
      // Unknown operator: end the glyph with what has been drawn.
      ClosePath;
      Exit(trEnd);
    end;
  end;
  Result := trContinue;
end;

{ ---------------------------------------------------------------------------- }
{ TPdfType1Font                                                                }
{ ---------------------------------------------------------------------------- }

class function TPdfType1Font.IsType1(const Data: TBytes): Boolean;
begin
  Result := ((Length(Data) >= 2) and (Data[0] = $80) and (Data[1] = $01)) or
    StartsWithBytes(Data, '%!PS-AdobeFont') or StartsWithBytes(Data, '%!FontType1') or
    (FindBytes(Data, 'eexec', 0, 4096) >= 0);
end;

constructor TPdfType1Font.Create(const Data: TBytes);
var
  Raw, Body: TBytes;
  EexecPos, P: Integer;
  IsHex, Found: Boolean;

  function Decode(Hex: Boolean): TBytes;
  var
    Bin: TBytes;
  begin
    if Hex then
    begin
      Bin := DecodeHexSection(Body, 0);
      Result := Type1Decrypt(Bin, 0, Length(Bin), EexecKey, 4);
    end
    else
      Result := Type1Decrypt(Body, 0, Length(Body), EexecKey, 4);
  end;

begin
  inherited Create;
  FFontMatrix := TPdfMatrix.Create(0.001, 0, 0, 0.001, 0, 0);
  FFontBBox := TPdfRectangle.Empty;
  FStandardEncoding := True;
  FNameMap := TDictionary<string, Integer>.Create;
  if (Length(Data) >= 2) and (Data[0] = $80) and (Data[1] = $01) then
    Raw := UnwrapPfb(Data)
  else
    Raw := Data;
  EexecPos := FindEexec(Raw);
  if EexecPos >= 0 then
    ParseHeader(PdfCopyBytes(Raw, 0, EexecPos))
  else
    ParseHeader(Raw);
  Found := False;
  if EexecPos >= 0 then
  begin
    P := EexecPos + 5;
    while (P < Length(Raw)) and (Raw[P] in [9, 10, 13, 32]) do
      Inc(P);
    Body := PdfCopyBytes(Raw, P, Integer(Length(Raw)) - P);
    IsHex := (Length(Body) >= 4) and (HexValue(Body[0]) >= 0) and (HexValue(Body[1]) >= 0) and
      (HexValue(Body[2]) >= 0) and (HexValue(Body[3]) >= 0);
    Found := ParsePrivate(Decode(IsHex)) or ParsePrivate(Decode(not IsHex));
  end;
  // Tolerance: an unencrypted private part, or a bare eexec section without clear text.
  if not Found then
    Found := ParsePrivate(Raw);
  if not Found and (EexecPos < 0) then
  begin
    Body := Raw;
    Found := ParsePrivate(Decode(False)) or ParsePrivate(Decode(True));
  end;
  if not Found then
    raise EPdfFontError.Create('Type1 font: no CharStrings found');
  ComputeMetrics;
end;

destructor TPdfType1Font.Destroy;
begin
  FNameMap.Free;
  inherited;
end;

procedure TPdfType1Font.ParseHeader(const Clear: TBytes);
var
  S: TPsScanner;
  T: TPsToken;
  Values: TArray<Double>;
  HaveMatrix, HaveBBox, HaveEncoding: Boolean;

  procedure ParseEncoding;
  var
    Save, Code, Depth, Count: Integer;
    Tok: TPsToken;
  begin
    Tok := S.Next;
    if (Tok.Kind = tkWord) and PsTryInt(Tok.Text, Code) then
    begin
      // /Encoding 256 array ... dup <code> /<name> put ... readonly def
      FStandardEncoding := False;
      SetLength(FEncoding, 256);
      Depth := 0;
      Count := 0;
      while Count < 100000 do
      begin
        Inc(Count);
        Save := S.Pos;
        Tok := S.Next;
        case Tok.Kind of
          tkEOF:
            Break;
          tkOpen:
            Inc(Depth);
          tkClose:
            if Depth > 0 then
              Dec(Depth);
          tkName:
            if Depth = 0 then
            begin
              // A key at the top level: the 'def' is missing, leave the key for the header loop.
              S.Pos := Save;
              Break;
            end;
          tkWord:
            if Depth = 0 then
            begin
              if Tok.Text = 'def' then
                Break;
              if Tok.Text = 'dup' then
              begin
                Tok := S.Next;
                if (Tok.Kind = tkWord) and PsTryInt(Tok.Text, Code) then
                begin
                  Save := S.Pos;
                  Tok := S.Next;
                  if Tok.Kind = tkName then
                  begin
                    if (Code >= 0) and (Code <= 255) then
                      FEncoding[Code] := Tok.Text;
                  end
                  else
                    S.Pos := Save;
                end;
              end;
            end;
        end;
      end;
    end
    else if Tok.Kind = tkOpen then
    begin
      // /Encoding [ /name ... ] def
      FStandardEncoding := False;
      SetLength(FEncoding, 256);
      Code := 0;
      repeat
        Tok := S.Next;
        if Tok.Kind in [tkEOF, tkClose] then
          Break;
        if Tok.Kind = tkName then
        begin
          if Code <= 255 then
            FEncoding[Code] := Tok.Text;
          Inc(Code);
        end;
      until False;
    end
    else
      FStandardEncoding := True; // StandardEncoding (other named encodings are approximated by it)
  end;

begin
  S.Init(Clear);
  HaveMatrix := False;
  HaveBBox := False;
  HaveEncoding := False;
  repeat
    T := S.Next;
    if T.Kind = tkEOF then
      Break;
    if T.Kind <> tkName then
      Continue;
    if T.Text = 'FontName' then
    begin
      T := S.Next;
      if (T.Kind = tkName) and (FFontName = '') then
        FFontName := T.Text;
    end
    else if (T.Text = 'FontMatrix') and not HaveMatrix then
    begin
      if ReadNumberArray(S, Values) and (Length(Values) >= 6) and
        ((Values[0] <> 0) or (Values[1] <> 0) or (Values[2] <> 0) or (Values[3] <> 0)) then
      begin
        FFontMatrix := TPdfMatrix.Create(Values[0], Values[1], Values[2], Values[3], Values[4], Values[5]);
        HaveMatrix := True;
      end;
    end
    else if (T.Text = 'FontBBox') and not HaveBBox then
    begin
      if ReadNumberArray(S, Values) and (Length(Values) >= 4) then
      begin
        FFontBBox := TPdfRectangle.Create(Values[0], Values[1], Values[2], Values[3]);
        HaveBBox := True;
      end;
    end
    else if (T.Text = 'Encoding') and not HaveEncoding then
    begin
      HaveEncoding := True;
      ParseEncoding;
    end;
  until False;
end;

function TPdfType1Font.ParsePrivate(const Priv: TBytes): Boolean;
var
  S: TPsScanner;
  T: TPsToken;
  LenIV, Count, Index, Len, Save, I: Integer;
  Subrs: TArray<TBytes>;
  Names: TList<string>;
  Strings: TList<TBytes>;
  SubrsDone, CharsDone, Found: Boolean;

  function DecryptCharString(const Bin: TBytes): TBytes;
  begin
    if LenIV < 0 then
      Result := Bin
    else
      Result := Type1Decrypt(Bin, 0, Length(Bin), CharStringKey, LenIV);
  end;

begin
  Result := False;
  if Length(Priv) = 0 then
    Exit;
  S.Init(Priv);
  LenIV := 4;
  Subrs := nil;
  SubrsDone := False;
  CharsDone := False;
  Names := TList<string>.Create;
  Strings := TList<TBytes>.Create;
  try
    repeat
      T := S.Next;
      if T.Kind = tkEOF then
        Break;
      if T.Kind <> tkName then
        Continue;
      if T.Text = 'lenIV' then
      begin
        T := S.Next;
        if (T.Kind = tkWord) and PsTryInt(T.Text, I) then
          LenIV := I;
      end
      else if (T.Text = 'Subrs') and not SubrsDone then
      begin
        // /Subrs <n> array  dup <i> <len> RD <binary> NP ...
        T := S.Next;
        if (T.Kind <> tkWord) or not PsTryInt(T.Text, Count) then
          Continue;
        if not S.Next.IsWord('array') then
          Continue;
        SubrsDone := True;
        SetLength(Subrs, EnsureRange(Count, 0, MaxSubrs));
        repeat
          Save := S.Pos;
          if not S.Next.IsWord('dup') then
          begin
            S.Pos := Save;
            Break;
          end;
          T := S.Next;
          if (T.Kind <> tkWord) or not PsTryInt(T.Text, Index) then
            Break;
          T := S.Next;
          if (T.Kind <> tkWord) or not PsTryInt(T.Text, Len) or (Len < 0) then
            Break;
          if S.Next.Kind = tkEOF then // RD or -|
            Break;
          if (Index >= 0) and (Index < MaxSubrs) then
          begin
            if Index >= Length(Subrs) then
              SetLength(Subrs, Index + 1);
            Subrs[Index] := DecryptCharString(S.ReadBinary(Len));
          end
          else
            S.ReadBinary(Len);
          Save := S.Pos;
          T := S.Next; // NP, | or noaccess put
          if T.IsWord('noaccess') then
            S.Next
          else if T.IsWord('dup') or (T.Kind = tkName) then
            S.Pos := Save;
        until False;
      end
      else if (T.Text = 'CharStrings') and not CharsDone then
      begin
        // /CharStrings <n> dict dup begin  /<name> <len> RD <binary> ND ... end
        Found := False;
        for I := 1 to 6 do
        begin
          T := S.Next;
          if T.Kind = tkEOF then
            Break;
          if T.IsWord('begin') then
          begin
            Found := True;
            Break;
          end;
        end;
        if not Found then
          Continue;
        CharsDone := True;
        while Names.Count < MaxGlyphs do
        begin
          T := S.Next;
          if (T.Kind = tkEOF) or T.IsWord('end') then
            Break;
          if T.Kind <> tkName then
            Continue;
          Names.Add(T.Text);
          Save := S.Pos;
          T := S.Next;
          if (T.Kind <> tkWord) or not PsTryInt(T.Text, Len) or (Len < 0) then
          begin
            Names.Delete(Names.Count - 1);
            if T.Kind = tkName then
              S.Pos := Save;
            Continue;
          end;
          if S.Next.Kind = tkEOF then // RD or -|
          begin
            Names.Delete(Names.Count - 1);
            Break;
          end;
          Strings.Add(DecryptCharString(S.ReadBinary(Len)));
          Save := S.Pos;
          T := S.Next; // ND, |- or noaccess def
          if T.IsWord('noaccess') then
            S.Next
          else if (T.Kind = tkName) or T.IsWord('end') then
            S.Pos := Save;
        end;
      end;
    until False;
    if Strings.Count = 0 then
      Exit;
    FNames := Names.ToArray;
    FCharStrings := Strings.ToArray;
    FSubrs := Subrs;
    FNameMap.Clear;
    for I := 0 to High(FNames) do
      FNameMap.AddOrSetValue(FNames[I], I);
    Result := True;
  finally
    Strings.Free;
    Names.Free;
  end;
end;

procedure TPdfType1Font.ComputeMetrics;
var
  GID, K: Integer;
  Outline: TPdfGlyphOutline;
  W: Double;
begin
  SetLength(FAdvances, Length(FCharStrings));
  FOutlineCount := 0;
  for GID := 0 to High(FCharStrings) do
  begin
    Interpret(GID, True, Outline, W);
    FAdvances[GID] := W;
    for K := 0 to Outline.Count - 1 do
      if Outline.Cmds[K].Kind in [glLine, glQuad, glCubic] then
      begin
        Inc(FOutlineCount);
        Break;
      end;
  end;
end;

function TPdfType1Font.Interpret(GID: Integer; AllowSeac: Boolean; out Outline: TPdfGlyphOutline;
  out Width: Double): Boolean;
var
  Interp: TT1Interpreter;
begin
  Interp.Init(Self, AllowSeac);
  Result := Interp.Run(FCharStrings[GID], 0) <> trError;
  if Interp.HaveWidth then
    Width := Interp.Width
  else
    Width := -1;
  if Result then
  begin
    Interp.ClosePath;
    Outline := Interp.Outline;
    Outline.Trim;
  end
  else
    Outline.Clear;
  Outline.Advance := Max(Width, 0);
end;

function TPdfType1Font.StandardCodeGlyph(Code: Integer): Integer;
begin
  if (Code >= 0) and (Code <= 255) and (StdEncNames[Code] <> '') then
    Result := GlyphByName(StdEncNames[Code])
  else
    Result := -1;
end;

function TPdfType1Font.FontMatrix: TPdfMatrix;
begin
  Result := FFontMatrix;
end;

function TPdfType1Font.GlyphCount: Integer;
begin
  Result := Length(FCharStrings);
end;

function TPdfType1Font.GetOutline(GID: Integer; out Outline: TPdfGlyphOutline): Boolean;
var
  W: Double;
begin
  if (GID < 0) or (GID >= Length(FCharStrings)) then
  begin
    Outline.Clear;
    Exit(False);
  end;
  Result := Interpret(GID, True, Outline, W);
end;

function TPdfType1Font.GetAdvance(GID: Integer): Single;
begin
  if (GID >= 0) and (GID < Length(FAdvances)) then
    Result := FAdvances[GID]
  else
    Result := -1;
end;

function TPdfType1Font.GlyphByName(const Name: string): Integer;
begin
  if not FNameMap.TryGetValue(Name, Result) then
    Result := -1;
end;

function TPdfType1Font.GlyphByCode(Code: Integer): Integer;
var
  Name: string;
begin
  Name := EncodingName(Code);
  if Name = '' then
    Result := -1
  else
    Result := GlyphByName(Name);
end;

function TPdfType1Font.HasGlyphNames: Boolean;
begin
  Result := True;
end;

function TPdfType1Font.HasCodeMap: Boolean;
begin
  Result := True;
end;

function TPdfType1Font.OutlineCount: Integer;
begin
  Result := FOutlineCount;
end;

function TPdfType1Font.GlyphName(GID: Integer): string;
begin
  if (GID >= 0) and (GID < Length(FNames)) then
    Result := FNames[GID]
  else
    Result := '';
end;

function TPdfType1Font.EncodingName(Code: Integer): string;
begin
  Result := '';
  if (Code < 0) or (Code > 255) then
    Exit;
  if FStandardEncoding then
    Result := StdEncNames[Code]
  else if Length(FEncoding) = 256 then
    Result := FEncoding[Code];
  if Result = '.notdef' then
    Result := '';
end;

end.
