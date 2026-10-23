{*******************************************************************************
  Pdf.Render.Functions
  PDF functions (ISO 32000-1 §7.10): type 0 (sampled), 2 (exponential),
  3 (stitching) and 4 (PostScript calculator). Shared by colour spaces
  (Separation/DeviceN tint transforms) and shadings.
  Portions derived from pdf.js (Mozilla, Apache License 2.0).
*******************************************************************************}
unit Pdf.Render.Functions;

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections,
  Pdf.Core.Types, Pdf.Core.Objects;

type
  TPdfFunctionType = (ftSampled, ftExponential, ftStitching, ftPostScript);

  /// <summary>A parsed PDF function. Evaluate clips inputs to Domain and outputs to Range (when present).</summary>
  TPdfFunction = class abstract
  private
    FDomain: TArray<Double>;
    FRange: TArray<Double>;
    /// <summary>Parse with a nesting depth (stitching functions may contain stitching functions, or loop through references).</summary>
    class function ParseLevel(const Obj: IPdfObject; const Resolver: IPdfResolver; Depth: Integer): TPdfFunction; static;
  protected
    /// <summary>Inputs are already clipped to Domain; the result is clipped to Range by Evaluate.</summary>
    function DoEvaluate(const Inputs: TArray<Double>): TArray<Double>; virtual; abstract;
    function GetFunctionType: TPdfFunctionType; virtual; abstract;
    function GetOutputCount: Integer; virtual; abstract;
  public
    /// <summary>Parses a function dictionary or stream (references are resolved). Returns nil when Obj is not a valid function.</summary>
    class function Parse(const Obj: IPdfObject; const Resolver: IPdfResolver): TPdfFunction; static;
    /// <summary>Parses either one function or an array of functions (one per output component, as used by shadings).
    /// Returns an empty array when nothing valid is found. The caller owns the functions.</summary>
    class function ParseArray(const Obj: IPdfObject; const Resolver: IPdfResolver): TArray<TPdfFunction>; static;
    function Evaluate(const Inputs: TArray<Double>): TArray<Double>; overload;
    function Evaluate(Input: Double): TArray<Double>; overload;
    property FunctionType: TPdfFunctionType read GetFunctionType;
    /// <summary>Number of inputs (Length(Domain) div 2).</summary>
    function InputCount: Integer;
    /// <summary>Number of outputs; -1 when unknown (type 4 without /Range is invalid, so normally known).</summary>
    property OutputCount: Integer read GetOutputCount;
    property Domain: TArray<Double> read FDomain;
    property Range: TArray<Double> read FRange;
  end;

/// <summary>Evaluates one function with n outputs, or n functions with one output each, and concatenates the results.</summary>
function PdfEvaluateFunctions(const Funcs: TArray<TPdfFunction>; const Inputs: TArray<Double>): TArray<Double>;
/// <summary>Frees all functions in the array and sets it to nil.</summary>
procedure PdfFreeFunctions(var Funcs: TArray<TPdfFunction>);

implementation

uses
  Pdf.Core.Lexer;

const
  /// <summary>Maximum nesting of stitching functions (also stops reference loops).</summary>
  MaxFunctionDepth = 16;
  /// <summary>Maximum number of samples (all outputs) of a type 0 function.</summary>
  MaxSampleCount = 1 shl 23;
  /// <summary>Type 0 functions with more inputs use nearest-sample lookup instead of multilinear interpolation.</summary>
  MaxInterpolatedInputs = 8;
  /// <summary>Operand stack limit of type 4 functions (ISO 32000-1 Annex C).</summary>
  PsMaxStack = 100;
  /// <summary>Maximum nesting of { } procedures in a type 4 function.</summary>
  PsMaxNesting = 64;

type
  TPdfSampledFunction = class(TPdfFunction)
  private
    FSize: TArray<Integer>;
    FEncode: TArray<Double>;
    FDecode: TArray<Double>;
    FSamples: TArray<Double>;
    FOutputs: Integer;
    function Load(const Stream: IPdfStream; const Resolver: IPdfResolver): Boolean;
  protected
    function DoEvaluate(const Inputs: TArray<Double>): TArray<Double>; override;
    function GetFunctionType: TPdfFunctionType; override;
    function GetOutputCount: Integer; override;
  end;

  TPdfExponentialFunction = class(TPdfFunction)
  private
    FC0: TArray<Double>;
    FDiff: TArray<Double>;
    FN: Double;
    function Load(const Dict: IPdfDictionary; const Resolver: IPdfResolver): Boolean;
  protected
    function DoEvaluate(const Inputs: TArray<Double>): TArray<Double>; override;
    function GetFunctionType: TPdfFunctionType; override;
    function GetOutputCount: Integer; override;
  end;

  TPdfStitchingFunction = class(TPdfFunction)
  private
    FFunctions: TArray<TPdfFunction>;
    FBounds: TArray<Double>;
    FEncode: TArray<Double>;
    function Load(const Dict: IPdfDictionary; const Resolver: IPdfResolver; Depth: Integer): Boolean;
  protected
    function DoEvaluate(const Inputs: TArray<Double>): TArray<Double>; override;
    function GetFunctionType: TPdfFunctionType; override;
    function GetOutputCount: Integer; override;
  public
    destructor Destroy; override;
  end;

  TPsOpCode = (
    psPush, psTrue, psFalse, psJumpIfFalse, psJump,
    // arithmetic
    psAbs, psAdd, psAtan, psCeiling, psCos, psCvi, psCvr, psDiv, psExp, psFloor, psIdiv,
    psLn, psLog, psMod, psMul, psNeg, psRound, psSin, psSqrt, psSub, psTruncate,
    // relational, boolean and bitwise
    psAnd, psBitshift, psEq, psGe, psGt, psLe, psLt, psNe, psNot, psOr, psXor,
    // stack
    psCopy, psDup, psExch, psIndex, psPop, psRoll);

  TPsInstruction = record
    Op: TPsOpCode;
    /// <summary>Operand of psPush.</summary>
    Value: Double;
    /// <summary>Jump target (instruction index) of psJumpIfFalse / psJump.</summary>
    Target: Integer;
  end;

  TPsStack = record
    Values: array[0..PsMaxStack - 1] of Double;
    IsBool: array[0..PsMaxStack - 1] of Boolean;
    Count: Integer;
    procedure Push(V: Double); inline;
    procedure PushBool(V: Boolean); inline;
    function Pop: Double; inline;
    function TopIsBool(Depth: Integer): Boolean; inline;
  end;

  TPdfPostScriptFunction = class(TPdfFunction)
  private
    FCode: TArray<TPsInstruction>;
    FCodeLen: Integer;
    function Emit(Op: TPsOpCode; Value: Double = 0): Integer;
    function ParseBlock(Lexer: TPdfLexer; Nesting: Integer): Boolean;
    function Compile(const Data: TBytes): Boolean;
  protected
    function DoEvaluate(const Inputs: TArray<Double>): TArray<Double>; override;
    function GetFunctionType: TPdfFunctionType; override;
    function GetOutputCount: Integer; override;
  end;

{ Helpers }

/// <summary>Resolved value of Key (null when absent), also following references the dictionary's own resolver left alone.</summary>
function DictGet(const Dict: IPdfDictionary; const Key: string; const Resolver: IPdfResolver): IPdfObject;
begin
  Result := PdfResolve(Resolver, Dict.Get(Key));
end;

/// <summary>Reads a numeric array. False when the key is absent or the value is not an array of numbers.</summary>
function GetNumbers(const Dict: IPdfDictionary; const Key: string; const Resolver: IPdfResolver;
  out Values: TArray<Double>): Boolean;
var
  Arr: IPdfArray;
  Item: IPdfObject;
  I: Integer;
  V: Double;
begin
  Values := nil;
  Arr := PdfAsArray(DictGet(Dict, Key, Resolver));
  if Arr = nil then
    Exit(False);
  SetLength(Values, Arr.Count);
  for I := 0 to Arr.Count - 1 do
  begin
    Item := PdfResolve(Resolver, Arr.Get(I));
    if not PdfIsNumber(Item) then
    begin
      Values := nil;
      Exit(False);
    end;
    V := PdfAsNumber(Item);
    if IsNaN(V) or IsInfinite(V) then
      V := 0;
    Values[I] := V;
  end;
  Result := True;
end;

function Interpolate(X, XMin, XMax, YMin, YMax: Double): Double; inline;
begin
  if XMax = XMin then
    Result := YMin
  else
    Result := YMin + (X - XMin) * (YMax - YMin) / (XMax - XMin);
end;

function DFloor(X: Double): Double; inline;
begin
  Result := Int(X);
  if Result > X then
    Result := Result - 1;
end;

function DCeil(X: Double): Double; inline;
begin
  Result := Int(X);
  if Result < X then
    Result := Result + 1;
end;

/// <summary>Truncates to a 32-bit integer, saturating (PostScript integers are 32-bit).</summary>
function PsInt(X: Double): Integer; inline;
begin
  if IsNaN(X) then
    Result := 0
  else if X >= MaxInt then
    Result := MaxInt
  else if X <= -MaxInt - 1.0 then
    Result := -MaxInt - 1
  else
    Result := Trunc(X);
end;

/// <summary>X^N without floating-point exceptions: a negative base with a fractional exponent counts as 0,
/// 0 to a negative power gives 0 and overflow saturates at ±1e300.</summary>
function SafePower(X, N: Double): Double;
var
  L: Double;
  Negative: Boolean;
begin
  if N = 1 then
    Exit(X);
  if N = 0 then
    Exit(1);
  if X = 0 then
    Exit(0);
  Negative := False;
  if X < 0 then
  begin
    if Frac(N) <> 0 then
      Exit(0);
    Negative := Frac(N / 2) <> 0;
    X := -X;
  end;
  L := N * Ln(X);
  if L > 690 then
    Result := 1E300
  else if L < -690 then
    Result := 0
  else if N = 2 then
    Result := X * X
  else
    Result := Exp(L);
  if Negative then
    Result := -Result;
end;

{ TPdfFunction }

class function TPdfFunction.Parse(const Obj: IPdfObject; const Resolver: IPdfResolver): TPdfFunction;
begin
  Result := ParseLevel(Obj, Resolver, 0);
end;

class function TPdfFunction.ParseLevel(const Obj: IPdfObject; const Resolver: IPdfResolver; Depth: Integer): TPdfFunction;
var
  O, TypeObj: IPdfObject;
  Dict: IPdfDictionary;
  Stream: IPdfStream;
  Domain, Range: TArray<Double>;
  F: TPdfFunction;
  Ok: Boolean;
begin
  Result := nil;
  if Depth > MaxFunctionDepth then
    Exit;
  F := nil;
  try
    O := PdfResolve(Resolver, Obj);
    Dict := PdfAsDictionary(O);
    if Dict = nil then
      Exit;
    Stream := PdfAsStream(O);
    TypeObj := DictGet(Dict, 'FunctionType', Resolver);
    if not PdfIsNumber(TypeObj) then
      Exit;
    if not GetNumbers(Dict, 'Domain', Resolver, Domain) or (Length(Domain) < 2) then
      Exit;
    SetLength(Domain, Length(Domain) and not 1);
    if not GetNumbers(Dict, 'Range', Resolver, Range) or (Length(Range) < 2) then
      Range := nil
    else
      SetLength(Range, Length(Range) and not 1);
    Ok := False;
    case PdfAsInteger(TypeObj, -1) of
      0:
        if (Stream <> nil) and (Range <> nil) then
        begin
          F := TPdfSampledFunction.Create;
          F.FDomain := Domain;
          F.FRange := Range;
          Ok := TPdfSampledFunction(F).Load(Stream, Resolver);
        end;
      2:
        begin
          F := TPdfExponentialFunction.Create;
          F.FDomain := Domain;
          F.FRange := Range;
          Ok := TPdfExponentialFunction(F).Load(Dict, Resolver);
        end;
      3:
        begin
          F := TPdfStitchingFunction.Create;
          F.FDomain := Domain;
          F.FRange := Range;
          Ok := TPdfStitchingFunction(F).Load(Dict, Resolver, Depth);
        end;
      4:
        if (Stream <> nil) and (Range <> nil) then
        begin
          F := TPdfPostScriptFunction.Create;
          F.FDomain := Domain;
          F.FRange := Range;
          Ok := TPdfPostScriptFunction(F).Compile(Stream.GetDecodedData);
        end;
    end;
    if Ok then
    begin
      Result := F;
      F := nil;
    end;
  except
    // Parse never raises: malformed functions are simply not usable.
    Result := nil;
  end;
  F.Free;
end;

class function TPdfFunction.ParseArray(const Obj: IPdfObject; const Resolver: IPdfResolver): TArray<TPdfFunction>;
var
  O: IPdfObject;
  Arr: IPdfArray;
  I: Integer;
  F: TPdfFunction;
begin
  Result := nil;
  O := PdfResolve(Resolver, Obj);
  Arr := PdfAsArray(O);
  if Arr <> nil then
  begin
    for I := 0 to Arr.Count - 1 do
    begin
      F := Parse(Arr.Get(I), Resolver);
      if F <> nil then
        Result := Result + [F];
    end;
  end
  else
  begin
    F := Parse(O, Resolver);
    if F <> nil then
      Result := [F];
  end;
end;

function TPdfFunction.InputCount: Integer;
begin
  Result := Length(FDomain) div 2;
end;

function TPdfFunction.Evaluate(Input: Double): TArray<Double>;
begin
  Result := Evaluate(TArray<Double>.Create(Input));
end;

function TPdfFunction.Evaluate(const Inputs: TArray<Double>): TArray<Double>;
var
  Clipped: TArray<Double>;
  I, N, NOut, Old: Integer;
  V, Lo, Hi: Double;
  OldMask: TArithmeticExceptionMask;
begin
  N := InputCount;
  SetLength(Clipped, N);
  for I := 0 to N - 1 do
  begin
    Lo := Min(FDomain[2 * I], FDomain[2 * I + 1]);
    Hi := Max(FDomain[2 * I], FDomain[2 * I + 1]);
    if I < Length(Inputs) then
      V := Inputs[I]
    else
      V := 0;
    if IsNaN(V) then
      V := Lo;
    Clipped[I] := EnsureRange(V, Lo, Hi);
  end;
  // Evaluate never raises: floating-point exceptions (unmasked by default on Windows) are masked
  // while evaluating, so overflow and invalid operations give Inf/NaN, which are clipped below.
  OldMask := SetExceptionMask(exAllArithmeticExceptions);
  try
    try
      Result := DoEvaluate(Clipped);
    except
      Result := nil;
    end;
  finally
    ClearExceptions(False);
    SetExceptionMask(OldMask);
  end;
  NOut := OutputCount;
  if (NOut >= 0) and (Length(Result) <> NOut) then
  begin
    Old := Length(Result);
    SetLength(Result, NOut);
    for I := Old to NOut - 1 do
      Result[I] := 0;
  end;
  for I := 0 to High(Result) do
  begin
    V := Result[I];
    if I < Length(FRange) div 2 then
    begin
      Lo := Min(FRange[2 * I], FRange[2 * I + 1]);
      Hi := Max(FRange[2 * I], FRange[2 * I + 1]);
      if IsNaN(V) then
        V := Lo
      else
        V := EnsureRange(V, Lo, Hi);
    end
    else if IsNaN(V) or IsInfinite(V) then
      V := 0;
    Result[I] := V;
  end;
end;

{ TPdfSampledFunction }

function TPdfSampledFunction.Load(const Stream: IPdfStream; const Resolver: IPdfResolver): Boolean;
var
  Dict: IPdfDictionary;
  M, I, Bps, DataLen, BytePos, Bits: Integer;
  SizeVals, Enc, DecodeVals: TArray<Double>;
  Total: Int64;
  Data: TBytes;
  Buf, Mask: UInt64;
  Scale: Double;
begin
  Result := False;
  Dict := Stream.Dict;
  M := InputCount;
  FOutputs := Length(FRange) div 2;
  if (M = 0) or (FOutputs = 0) then
    Exit;
  if not GetNumbers(Dict, 'Size', Resolver, SizeVals) or (Length(SizeVals) < M) then
    Exit;
  SetLength(FSize, M);
  Total := FOutputs;
  for I := 0 to M - 1 do
  begin
    if (SizeVals[I] < 1) or (SizeVals[I] > MaxSampleCount) then
      Exit;
    FSize[I] := Trunc(SizeVals[I]);
    Total := Total * FSize[I];
    if Total > MaxSampleCount then
      Exit;
  end;
  Bps := PdfAsInteger(DictGet(Dict, 'BitsPerSample', Resolver), 0);
  if not (Bps in [1, 2, 4, 8, 12, 16, 24, 32]) then
    Exit;
  // /Encode defaults to [0 (Size_0 - 1) 0 (Size_1 - 1) ...], /Decode to /Range.
  SetLength(FEncode, 2 * M);
  if not GetNumbers(Dict, 'Encode', Resolver, Enc) or (Length(Enc) < 2 * M) then
    Enc := nil;
  for I := 0 to M - 1 do
    if Enc <> nil then
    begin
      FEncode[2 * I] := Enc[2 * I];
      FEncode[2 * I + 1] := Enc[2 * I + 1];
    end
    else
    begin
      FEncode[2 * I] := 0;
      FEncode[2 * I + 1] := FSize[I] - 1;
    end;
  if GetNumbers(Dict, 'Decode', Resolver, DecodeVals) and (Length(DecodeVals) >= 2 * FOutputs) then
    FDecode := Copy(DecodeVals, 0, 2 * FOutputs)
  else
    FDecode := Copy(FRange, 0, 2 * FOutputs);
  // Samples are packed MSB first without padding; missing data counts as 0.
  Data := Stream.GetDecodedData;
  DataLen := Length(Data);
  SetLength(FSamples, Total);
  Mask := (UInt64(1) shl Bps) - 1;
  Scale := 1 / Mask;
  Buf := 0;
  Bits := 0;
  BytePos := 0;
  for I := 0 to Integer(Total) - 1 do
  begin
    while Bits < Bps do
    begin
      Buf := Buf shl 8;
      if BytePos < DataLen then
        Buf := Buf or Data[BytePos];
      Inc(BytePos);
      Inc(Bits, 8);
    end;
    Dec(Bits, Bps);
    FSamples[I] := ((Buf shr Bits) and Mask) * Scale;
    Buf := Buf and ((UInt64(1) shl Bits) - 1);
  end;
  Result := True;
end;

function TPdfSampledFunction.DoEvaluate(const Inputs: TArray<Double>): TArray<Double>;
var
  CubeN: array[0..(1 shl MaxInterpolatedInputs) - 1] of Double;
  CubeVertex: array[0..(1 shl MaxInterpolatedInputs) - 1] of Integer;
  M, N, I, J, Vertices, Pos, K, SizeI, E0, Offset0, Offset1, Index: Integer;
  E, N0, N1, R: Double;
begin
  M := InputCount;
  N := FOutputs;
  SetLength(Result, N);
  if M > MaxInterpolatedInputs then
  begin
    // Nearest sample
    Index := 0;
    K := N;
    for I := 0 to M - 1 do
    begin
      E := Interpolate(Inputs[I], FDomain[2 * I], FDomain[2 * I + 1], FEncode[2 * I], FEncode[2 * I + 1]);
      E := EnsureRange(E, 0, FSize[I] - 1);
      Inc(Index, Round(E) * K);
      K := K * FSize[I];
    end;
    for J := 0 to N - 1 do
      Result[J] := Interpolate(FSamples[Index + J], 0, 1, FDecode[2 * J], FDecode[2 * J + 1]);
    Exit;
  end;
  // Multilinear interpolation over the 2^m corners of the enclosing cell (pdf.js).
  Vertices := 1 shl M;
  for J := 0 to Vertices - 1 do
  begin
    CubeN[J] := 1;
    CubeVertex[J] := 0;
  end;
  K := N;
  Pos := 1;
  for I := 0 to M - 1 do
  begin
    SizeI := FSize[I];
    E := Interpolate(Inputs[I], FDomain[2 * I], FDomain[2 * I + 1], FEncode[2 * I], FEncode[2 * I + 1]);
    if IsNaN(E) then
      E := 0;
    E := EnsureRange(E, 0, SizeI - 1);
    if SizeI = 1 then
    begin
      N0 := 1;
      N1 := 0;
      Offset0 := 0;
      Offset1 := 0;
    end
    else
    begin
      E0 := Trunc(E);
      if E0 > SizeI - 2 then
        E0 := SizeI - 2;
      N1 := E - E0;
      N0 := 1 - N1;
      Offset0 := E0 * K;
      Offset1 := Offset0 + K;
    end;
    for J := 0 to Vertices - 1 do
      if (J and Pos) <> 0 then
      begin
        CubeN[J] := CubeN[J] * N1;
        Inc(CubeVertex[J], Offset1);
      end
      else
      begin
        CubeN[J] := CubeN[J] * N0;
        Inc(CubeVertex[J], Offset0);
      end;
    K := K * SizeI;
    Pos := Pos shl 1;
  end;
  for J := 0 to N - 1 do
  begin
    R := 0;
    for I := 0 to Vertices - 1 do
      if CubeN[I] <> 0 then
        R := R + FSamples[CubeVertex[I] + J] * CubeN[I];
    Result[J] := Interpolate(R, 0, 1, FDecode[2 * J], FDecode[2 * J + 1]);
  end;
end;

function TPdfSampledFunction.GetFunctionType: TPdfFunctionType;
begin
  Result := ftSampled;
end;

function TPdfSampledFunction.GetOutputCount: Integer;
begin
  Result := FOutputs;
end;

{ TPdfExponentialFunction }

function TPdfExponentialFunction.Load(const Dict: IPdfDictionary; const Resolver: IPdfResolver): Boolean;
var
  C1: TArray<Double>;
  NObj: IPdfObject;
  I, Count: Integer;
begin
  Result := False;
  if Dict.Contains('C0') then
  begin
    if not GetNumbers(Dict, 'C0', Resolver, FC0) then
      Exit;
  end
  else
    FC0 := [0];
  if Dict.Contains('C1') then
  begin
    if not GetNumbers(Dict, 'C1', Resolver, C1) then
      Exit;
  end
  else
    C1 := [1];
  Count := Min(Length(FC0), Length(C1));
  if Count = 0 then
    Exit;
  SetLength(FC0, Count);
  SetLength(FDiff, Count);
  for I := 0 to Count - 1 do
    FDiff[I] := C1[I] - FC0[I];
  NObj := DictGet(Dict, 'N', Resolver);
  if not PdfIsNumber(NObj) then
    Exit;
  FN := PdfAsNumber(NObj);
  Result := not (IsNaN(FN) or IsInfinite(FN));
end;

function TPdfExponentialFunction.DoEvaluate(const Inputs: TArray<Double>): TArray<Double>;
var
  X: Double;
  I: Integer;
begin
  X := Inputs[0];
  if FN <> 1 then
    X := SafePower(X, FN);
  SetLength(Result, Length(FC0));
  for I := 0 to High(FC0) do
    Result[I] := FC0[I] + X * FDiff[I];
end;

function TPdfExponentialFunction.GetFunctionType: TPdfFunctionType;
begin
  Result := ftExponential;
end;

function TPdfExponentialFunction.GetOutputCount: Integer;
begin
  if Length(FRange) >= 2 then
    Result := Length(FRange) div 2
  else
    Result := Length(FC0);
end;

{ TPdfStitchingFunction }

destructor TPdfStitchingFunction.Destroy;
begin
  PdfFreeFunctions(FFunctions);
  inherited;
end;

function TPdfStitchingFunction.Load(const Dict: IPdfDictionary; const Resolver: IPdfResolver; Depth: Integer): Boolean;
var
  Arr: IPdfArray;
  I, K, Old: Integer;
  F: TPdfFunction;
begin
  Result := False;
  Arr := PdfAsArray(DictGet(Dict, 'Functions', Resolver));
  if (Arr = nil) or (Arr.Count = 0) then
    Exit;
  K := Arr.Count;
  SetLength(FFunctions, K);
  for I := 0 to K - 1 do
    FFunctions[I] := nil;
  for I := 0 to K - 1 do
  begin
    F := ParseLevel(Arr.Get(I), Resolver, Depth + 1);
    if F = nil then
      Exit;
    FFunctions[I] := F;
  end;
  // /Bounds: k-1 values (missing ones collapse onto the end of the domain).
  if not GetNumbers(Dict, 'Bounds', Resolver, FBounds) then
    FBounds := nil;
  Old := Length(FBounds);
  SetLength(FBounds, K - 1);
  for I := Old to K - 2 do
    FBounds[I] := FDomain[1];
  // /Encode: 2k values (missing pairs default to [0 1]).
  if not GetNumbers(Dict, 'Encode', Resolver, FEncode) then
    FEncode := nil;
  Old := Length(FEncode) and not 1;
  SetLength(FEncode, 2 * K);
  for I := Old to 2 * K - 1 do
    FEncode[I] := I and 1;
  Result := True;
end;

function TPdfStitchingFunction.DoEvaluate(const Inputs: TArray<Double>): TArray<Double>;
var
  V, DMin, DMax, RMin, RMax, T: Double;
  I, NB: Integer;
begin
  V := Inputs[0];
  NB := Length(FBounds);
  I := 0;
  // Subdomains are half-open [Bounds(i-1), Bounds(i)); the last one includes the end of the domain.
  // When Domain0 = Bounds0 the first subdomain is closed, so the domain start stays in function 0.
  if V > Min(FDomain[0], FDomain[1]) then
    while (I < NB) and (V >= FBounds[I]) do
      Inc(I);
  if I > 0 then
    DMin := FBounds[I - 1]
  else
    DMin := FDomain[0];
  if I < NB then
    DMax := FBounds[I]
  else
    DMax := FDomain[1];
  RMin := FEncode[2 * I];
  RMax := FEncode[2 * I + 1];
  if DMax = DMin then
    T := RMin
  else
    T := RMin + (V - DMin) * (RMax - RMin) / (DMax - DMin);
  Result := FFunctions[I].Evaluate(T);
end;

function TPdfStitchingFunction.GetFunctionType: TPdfFunctionType;
begin
  Result := ftStitching;
end;

function TPdfStitchingFunction.GetOutputCount: Integer;
begin
  if Length(FRange) >= 2 then
    Result := Length(FRange) div 2
  else
    Result := FFunctions[0].OutputCount;
end;

{ TPsStack }

procedure TPsStack.Push(V: Double);
begin
  // Overflow beyond the PostScript limit drops the value instead of raising.
  if Count < PsMaxStack then
  begin
    Values[Count] := V;
    IsBool[Count] := False;
    Inc(Count);
  end;
end;

procedure TPsStack.PushBool(V: Boolean);
begin
  if Count < PsMaxStack then
  begin
    if V then
      Values[Count] := 1
    else
      Values[Count] := 0;
    IsBool[Count] := True;
    Inc(Count);
  end;
end;

function TPsStack.Pop: Double;
begin
  // Underflow yields 0 instead of raising.
  if Count > 0 then
  begin
    Dec(Count);
    Result := Values[Count];
  end
  else
    Result := 0;
end;

function TPsStack.TopIsBool(Depth: Integer): Boolean;
begin
  Result := (Count > Depth) and IsBool[Count - 1 - Depth];
end;

{ TPdfPostScriptFunction }

const
  PsOperatorNames: array[psAbs..psRoll] of string = (
    'abs', 'add', 'atan', 'ceiling', 'cos', 'cvi', 'cvr', 'div', 'exp', 'floor', 'idiv',
    'ln', 'log', 'mod', 'mul', 'neg', 'round', 'sin', 'sqrt', 'sub', 'truncate',
    'and', 'bitshift', 'eq', 'ge', 'gt', 'le', 'lt', 'ne', 'not', 'or', 'xor',
    'copy', 'dup', 'exch', 'index', 'pop', 'roll');

function LookupPsOperator(const Name: string; out Op: TPsOpCode): Boolean;
var
  O: TPsOpCode;
begin
  if Name = 'true' then
  begin
    Op := psTrue;
    Exit(True);
  end;
  if Name = 'false' then
  begin
    Op := psFalse;
    Exit(True);
  end;
  for O := Low(PsOperatorNames) to High(PsOperatorNames) do
    if PsOperatorNames[O] = Name then
    begin
      Op := O;
      Exit(True);
    end;
  Result := False;
end;

function TPdfPostScriptFunction.Emit(Op: TPsOpCode; Value: Double): Integer;
begin
  if FCodeLen = Length(FCode) then
    SetLength(FCode, Max(16, 2 * FCodeLen));
  Result := FCodeLen;
  FCode[Result].Op := Op;
  FCode[Result].Value := Value;
  FCode[Result].Target := 0;
  Inc(FCodeLen);
end;

function TPdfPostScriptFunction.ParseBlock(Lexer: TPdfLexer; Nesting: Integer): Boolean;
var
  Tok: TPdfToken;
  Op: TPsOpCode;
  CondPos, JumpPos: Integer;
begin
  Result := False;
  if Nesting > PsMaxNesting then
    Exit;
  while True do
  begin
    Tok := Lexer.NextToken;
    case Tok.Kind of
      tkNumber:
        Emit(psPush, Tok.NumberValue);
      tkKeyword:
        begin
          if not LookupPsOperator(Tok.Text, Op) then
            Exit; // unknown operator, or if/ifelse without procedures
          Emit(Op);
        end;
      tkBraceOpen:
        begin
          // { proc } if   or   { proc1 } { proc2 } ifelse, compiled to conditional jumps (pdf.js).
          CondPos := Emit(psJumpIfFalse);
          if not ParseBlock(Lexer, Nesting + 1) then
            Exit;
          Tok := Lexer.NextToken;
          if Tok.IsKeyword('if') then
            FCode[CondPos].Target := FCodeLen
          else if Tok.Kind = tkBraceOpen then
          begin
            JumpPos := Emit(psJump);
            FCode[CondPos].Target := FCodeLen;
            if not ParseBlock(Lexer, Nesting + 1) then
              Exit;
            if not Lexer.NextToken.IsKeyword('ifelse') then
              Exit;
            FCode[JumpPos].Target := FCodeLen;
          end
          else
            Exit;
        end;
      tkBraceClose:
        Exit(True);
      tkEOF:
        // Tolerate a missing final brace of the outermost procedure.
        Exit(Nesting = 0);
    else
      Exit;
    end;
  end;
end;

function TPdfPostScriptFunction.Compile(const Data: TBytes): Boolean;
var
  Lexer: TPdfLexer;
  Tok: TPdfToken;
begin
  Result := False;
  FCodeLen := 0;
  Lexer := TPdfLexer.Create(Data);
  try
    // Skip leading junk up to the opening brace; anything after the closing brace is ignored.
    repeat
      Tok := Lexer.NextToken;
    until Tok.Kind in [tkBraceOpen, tkEOF];
    if Tok.Kind = tkEOF then
      Exit;
    Result := ParseBlock(Lexer, 0);
  finally
    Lexer.Free;
  end;
  SetLength(FCode, FCodeLen);
end;

function TPdfPostScriptFunction.DoEvaluate(const Inputs: TArray<Double>): TArray<Double>;
var
  S: TPsStack;
  PC, I, N, Idx, J, IA, IB: Integer;
  A, B: Double;
  BA, BB: Boolean;
  Tmp: array[0..PsMaxStack - 1] of Double;
  TmpBool: array[0..PsMaxStack - 1] of Boolean;
begin
  S.Count := 0;
  for I := 0 to High(Inputs) do
    S.Push(Inputs[I]);
  PC := 0;
  while PC < FCodeLen do
  begin
    case FCode[PC].Op of
      psPush:
        S.Push(FCode[PC].Value);
      psTrue:
        S.PushBool(True);
      psFalse:
        S.PushBool(False);
      psJumpIfFalse:
        if S.Pop = 0 then
        begin
          PC := FCode[PC].Target;
          Continue;
        end;
      psJump:
        begin
          PC := FCode[PC].Target;
          Continue;
        end;
      psAbs:
        S.Push(Abs(S.Pop));
      psAdd:
        begin
          B := S.Pop;
          A := S.Pop;
          S.Push(A + B);
        end;
      psAtan:
        begin
          // num den atan: angle in degrees, 0 <= angle < 360
          B := S.Pop;
          A := S.Pop;
          if (A = 0) and (B = 0) then
            A := 0
          else
          begin
            A := RadToDeg(ArcTan2(A, B));
            if A < 0 then
              A := A + 360;
          end;
          S.Push(A);
        end;
      psCeiling:
        S.Push(DCeil(S.Pop));
      psCos:
        S.Push(Cos(DegToRad(S.Pop)));
      psCvi:
        S.Push(PsInt(S.Pop));
      psCvr:
        ; // numbers are already real
      psDiv:
        begin
          B := S.Pop;
          A := S.Pop;
          if B = 0 then
            S.Push(0)
          else
            S.Push(A / B);
        end;
      psExp:
        begin
          B := S.Pop;
          A := S.Pop;
          S.Push(SafePower(A, B));
        end;
      psFloor:
        S.Push(DFloor(S.Pop));
      psIdiv:
        begin
          IB := PsInt(S.Pop);
          IA := PsInt(S.Pop);
          if IB = 0 then
            S.Push(0)
          else
            S.Push(Trunc(Int64(IA) / IB));
        end;
      psLn:
        begin
          A := S.Pop;
          if A > 0 then
            S.Push(Ln(A))
          else
            S.Push(0);
        end;
      psLog:
        begin
          A := S.Pop;
          if A > 0 then
            S.Push(Log10(A))
          else
            S.Push(0);
        end;
      psMod:
        begin
          IB := PsInt(S.Pop);
          IA := PsInt(S.Pop);
          if IB = 0 then
            S.Push(0)
          else
            S.Push(Int64(IA) mod IB);
        end;
      psMul:
        begin
          B := S.Pop;
          A := S.Pop;
          S.Push(A * B);
        end;
      psNeg:
        S.Push(-S.Pop);
      psRound:
        S.Push(DFloor(S.Pop + 0.5));
      psSin:
        S.Push(Sin(DegToRad(S.Pop)));
      psSqrt:
        begin
          A := S.Pop;
          if A > 0 then
            S.Push(Sqrt(A))
          else
            S.Push(0);
        end;
      psSub:
        begin
          B := S.Pop;
          A := S.Pop;
          S.Push(A - B);
        end;
      psTruncate:
        S.Push(Int(S.Pop));
      psAnd, psOr, psXor:
        begin
          BB := S.TopIsBool(0);
          BA := S.TopIsBool(1);
          B := S.Pop;
          A := S.Pop;
          if BA and BB then
            case FCode[PC].Op of
              psAnd: S.PushBool((A <> 0) and (B <> 0));
              psOr: S.PushBool((A <> 0) or (B <> 0));
            else
              S.PushBool((A <> 0) xor (B <> 0));
            end
          else
            case FCode[PC].Op of
              psAnd: S.Push(PsInt(A) and PsInt(B));
              psOr: S.Push(PsInt(A) or PsInt(B));
            else
              S.Push(PsInt(A) xor PsInt(B));
            end;
        end;
      psNot:
        if S.TopIsBool(0) then
          S.PushBool(S.Pop = 0)
        else
          S.Push(not PsInt(S.Pop));
      psBitshift:
        begin
          IB := PsInt(S.Pop);
          IA := PsInt(S.Pop);
          if (IB >= 32) or (IB <= -32) then
          begin
            if (IB <= -32) and (IA < 0) then
              S.Push(-1)
            else
              S.Push(0);
          end
          else if IB >= 0 then
            S.Push(Integer(Cardinal(IA) shl IB))
          else if IA >= 0 then
            S.Push(IA shr -IB)
          else
            S.Push(not ((not IA) shr -IB)); // arithmetic shift right
        end;
      psEq, psNe, psGe, psGt, psLe, psLt:
        begin
          B := S.Pop;
          A := S.Pop;
          case FCode[PC].Op of
            psEq: S.PushBool(A = B);
            psNe: S.PushBool(A <> B);
            psGe: S.PushBool(A >= B);
            psGt: S.PushBool(A > B);
            psLe: S.PushBool(A <= B);
          else
            S.PushBool(A < B);
          end;
        end;
      psCopy:
        begin
          N := PsInt(S.Pop);
          if (N > 0) and (N <= S.Count) then
          begin
            Idx := S.Count - N;
            for I := 0 to N - 1 do
              if S.Count < PsMaxStack then
              begin
                S.Values[S.Count] := S.Values[Idx + I];
                S.IsBool[S.Count] := S.IsBool[Idx + I];
                Inc(S.Count);
              end;
          end;
        end;
      psDup:
        if S.Count > 0 then
        begin
          if S.Count < PsMaxStack then
          begin
            S.Values[S.Count] := S.Values[S.Count - 1];
            S.IsBool[S.Count] := S.IsBool[S.Count - 1];
            Inc(S.Count);
          end;
        end
        else
          S.Push(0);
      psExch:
        begin
          while S.Count < 2 do
          begin
            // Underflow: pad the bottom of the stack with zeros.
            for I := S.Count downto 1 do
            begin
              S.Values[I] := S.Values[I - 1];
              S.IsBool[I] := S.IsBool[I - 1];
            end;
            S.Values[0] := 0;
            S.IsBool[0] := False;
            Inc(S.Count);
          end;
          A := S.Values[S.Count - 1];
          BA := S.IsBool[S.Count - 1];
          S.Values[S.Count - 1] := S.Values[S.Count - 2];
          S.IsBool[S.Count - 1] := S.IsBool[S.Count - 2];
          S.Values[S.Count - 2] := A;
          S.IsBool[S.Count - 2] := BA;
        end;
      psIndex:
        begin
          N := PsInt(S.Pop);
          if (N >= 0) and (N < S.Count) then
          begin
            Idx := S.Count - 1 - N;
            if S.IsBool[Idx] then
              S.PushBool(S.Values[Idx] <> 0)
            else
              S.Push(S.Values[Idx]);
          end
          else
            S.Push(0);
        end;
      psPop:
        S.Pop;
      psRoll:
        begin
          J := PsInt(S.Pop);
          N := PsInt(S.Pop);
          if (N > 0) and (N <= S.Count) then
          begin
            J := J mod N;
            if J < 0 then
              Inc(J, N);
            if J <> 0 then
            begin
              Idx := S.Count - N;
              for I := 0 to N - 1 do
              begin
                Tmp[(I + J) mod N] := S.Values[Idx + I];
                TmpBool[(I + J) mod N] := S.IsBool[Idx + I];
              end;
              for I := 0 to N - 1 do
              begin
                S.Values[Idx + I] := Tmp[I];
                S.IsBool[Idx + I] := TmpBool[I];
              end;
            end;
          end;
        end;
    end;
    Inc(PC);
  end;
  // The result is the top OutputCount values; missing ones (stack underflow) are 0.
  N := Length(FRange) div 2;
  SetLength(Result, N);
  Idx := S.Count - N;
  for I := 0 to N - 1 do
    if Idx + I >= 0 then
      Result[I] := S.Values[Idx + I]
    else
      Result[I] := 0;
end;

function TPdfPostScriptFunction.GetFunctionType: TPdfFunctionType;
begin
  Result := ftPostScript;
end;

function TPdfPostScriptFunction.GetOutputCount: Integer;
begin
  Result := Length(FRange) div 2;
end;

{ Functions }

function PdfEvaluateFunctions(const Funcs: TArray<TPdfFunction>; const Inputs: TArray<Double>): TArray<Double>;
var
  I: Integer;
begin
  Result := nil;
  if Length(Funcs) = 1 then
    Exit(Funcs[0].Evaluate(Inputs));
  for I := 0 to High(Funcs) do
    Result := Result + Funcs[I].Evaluate(Inputs);
end;

procedure PdfFreeFunctions(var Funcs: TArray<TPdfFunction>);
var
  I: Integer;
begin
  for I := 0 to High(Funcs) do
    Funcs[I].Free;
  Funcs := nil;
end;

end.
