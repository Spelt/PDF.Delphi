unit Pdf.Tests.Functions;

interface

uses
  System.SysUtils, System.Math, DUnitX.TestFramework, Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Parser,
  Pdf.Render.Functions;

type
  [TestFixture]
  TPdfFunctionTests = class
  public
    /// <summary>Creates the lazily allocated null singleton up front, so the leak monitor does not report it.</summary>
    [SetupFixture] procedure SetupFixture;
    [Test] procedure ExponentialLinear;
    [Test] procedure ExponentialQuadratic;
    [Test] procedure ExponentialDefaults;
    [Test] procedure ExponentialDomainClipping;
    [Test] procedure ExponentialRangeClipping;
    [Test] procedure ExponentialNegativeBaseFractionalN;
    [Test] procedure StitchingTwoFunctions;
    [Test] procedure StitchingEncodeReversed;
    [Test] procedure StitchingDomainEnd;
    [Test] procedure StitchingEqualBoundsNoDivisionByZero;
    [Test] procedure StitchingReferencesAndSelfReference;
    [Test] procedure SampledLinear1D;
    [Test] procedure SampledBilinear2D;
    [Test] procedure SampledOneBit;
    [Test] procedure SampledSixteenBitTwoOutputs;
    [Test] procedure SampledEncodeDecode;
    [Test] procedure SampledShortDataAndSizeOne;
    [Test] procedure PostScriptArithmetic;
    [Test] procedure PostScriptBitwise;
    [Test] procedure PostScriptComparisonAndBoolean;
    [Test] procedure PostScriptIfElse;
    [Test] procedure PostScriptStackOperators;
    [Test] procedure PostScriptTintTransforms;
    [Test] procedure PostScriptAtanDegrees;
    [Test] procedure PostScriptUnderflowAndMathErrors;
    [Test] procedure PostScriptTolerantSyntax;
    [Test] procedure PostScriptInvalid;
    [Test] procedure ParseArrayOfThree;
    [Test] procedure EvaluateFunctionsHelper;
    [Test] procedure InvalidInputReturnsNil;
    [Test] procedure NaNInputDoesNotRaise;
  end;

implementation

type
  /// <summary>Resolver over a fixed table of objects (index = object number).</summary>
  TFnTestResolver = class(TInterfacedObject, IPdfResolver)
  private
    FObjects: TArray<IPdfObject>;
  public
    constructor Create(const Objects: array of IPdfObject);
    function Resolve(const Obj: IPdfObject): IPdfObject;
    function FetchObject(Num, Gen: Integer): IPdfObject;
  end;

constructor TFnTestResolver.Create(const Objects: array of IPdfObject);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FObjects, Length(Objects));
  for I := 0 to High(Objects) do
    FObjects[I] := Objects[I];
end;

function TFnTestResolver.FetchObject(Num, Gen: Integer): IPdfObject;
begin
  if (Num >= 0) and (Num < Length(FObjects)) and (FObjects[Num] <> nil) then
    Result := FObjects[Num]
  else
    Result := PdfNull;
end;

function TFnTestResolver.Resolve(const Obj: IPdfObject): IPdfObject;
var
  Ref: IPdfReference;
begin
  Result := Obj;
  if (Result <> nil) and (Result.Kind = okReference) then
  begin
    Ref := Result as IPdfReference;
    Result := FetchObject(Ref.Num, Ref.Gen);
  end;
end;

{ Helpers }

function Fn(const Source: string; const Resolver: IPdfResolver = nil): TPdfFunction;
begin
  Result := TPdfFunction.Parse(PdfParseObject(Source, Resolver), Resolver);
end;

function MakeStream(const DictSource: string; const Data: TBytes): IPdfStream;
begin
  Result := PdfStream(PdfAsDictionary(PdfParseObject(DictSource)), Data);
end;

function StreamFn(const DictSource: string; const Data: TBytes): TPdfFunction;
begin
  Result := TPdfFunction.Parse(MakeStream(DictSource, Data), nil);
end;

/// <summary>Type 4 function with NIn inputs in [-1000 1000] and NOut outputs in [-1000 1000].</summary>
function PsFn(const Code: string; NIn: Integer = 1; NOut: Integer = 1): TPdfFunction;
var
  D, R: string;
  I: Integer;
begin
  D := '';
  for I := 1 to NIn do
    D := D + '-1000 1000 ';
  R := '';
  for I := 1 to NOut do
    R := R + '-1000 1000 ';
  Result := StreamFn('<< /FunctionType 4 /Domain [' + D + '] /Range [' + R + '] >>', PdfLatin1ToBytes(Code));
end;

procedure Near(Expected, Actual: Double; const Msg: string = ''; Tol: Double = 1E-9);
begin
  Assert.IsTrue(Abs(Expected - Actual) <= Tol, Format('%s expected %g, got %g', [Msg, Expected, Actual]));
end;

procedure NearArr(const Expected: array of Double; const Actual: TArray<Double>; const Msg: string = ''; Tol: Double = 1E-9);
var
  I: Integer;
begin
  Assert.AreEqual(Integer(Length(Expected)), Integer(Length(Actual)), Msg + ' length');
  for I := 0 to High(Expected) do
    Near(Expected[I], Actual[I], Format('%s [%d]', [Msg, I]), Tol);
end;

/// <summary>Evaluates a one-output type 4 program on one input.</summary>
function Ps1(const Code: string; Input: Double = 0): Double;
var
  F: TPdfFunction;
begin
  F := PsFn(Code);
  try
    Assert.IsNotNull(F, 'parse ' + Code);
    Result := F.Evaluate(Input)[0];
  finally
    F.Free;
  end;
end;

{ TPdfFunctionTests }

procedure TPdfFunctionTests.SetupFixture;
begin
  PdfNull;
end;

{ Exponential }

procedure TPdfFunctionTests.ExponentialLinear;
var
  F: TPdfFunction;
begin
  F := Fn('<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0] /C1 [1 0.5 0] /N 1 >>');
  try
    Assert.IsNotNull(F);
    Assert.IsTrue(F.FunctionType = ftExponential);
    Assert.AreEqual(1, F.InputCount);
    Assert.AreEqual(3, F.OutputCount);
    NearArr([0.5, 0.25, 0], F.Evaluate(0.5));
    NearArr([1, 0.5, 0], F.Evaluate(1));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.ExponentialQuadratic;
var
  F: TPdfFunction;
begin
  F := Fn('<< /FunctionType 2 /Domain [0 1] /C0 [0.2] /C1 [1.2] /N 2 >>');
  try
    Assert.IsNotNull(F);
    NearArr([0.45], F.Evaluate(0.5));
    NearArr([0.2], F.Evaluate(0));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.ExponentialDefaults;
var
  F: TPdfFunction;
begin
  F := Fn('<< /FunctionType 2 /Domain [0 1] /N 1 >>');
  try
    Assert.IsNotNull(F);
    Assert.AreEqual(1, F.OutputCount);
    NearArr([0.3], F.Evaluate(0.3));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.ExponentialDomainClipping;
var
  F: TPdfFunction;
begin
  F := Fn('<< /FunctionType 2 /Domain [0 1] /C0 [2] /C1 [4] /N 1 >>');
  try
    NearArr([4], F.Evaluate(2));
    NearArr([2], F.Evaluate(-1));
    NearArr([3], F.Evaluate(0.5));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.ExponentialRangeClipping;
var
  F: TPdfFunction;
begin
  F := Fn('<< /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [10] /N 1 /Range [0 5] >>');
  try
    Assert.AreEqual(1, F.OutputCount);
    NearArr([5], F.Evaluate(1));
    NearArr([2], F.Evaluate(0.2));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.ExponentialNegativeBaseFractionalN;
var
  F: TPdfFunction;
begin
  F := Fn('<< /FunctionType 2 /Domain [-1 1] /C0 [0.5] /C1 [1] /N 0.5 >>');
  try
    // (-0.5)^0.5 is undefined: x counts as 0, so the result is C0.
    NearArr([0.5], F.Evaluate(-0.5));
    NearArr([0.75], F.Evaluate(0.25));
  finally
    F.Free;
  end;
  // 0 to a negative power does not raise either
  F := Fn('<< /FunctionType 2 /Domain [0 1] /N -1 >>');
  try
    Assert.AreEqual(1, Integer(Length(F.Evaluate(0))));
    NearArr([2], F.Evaluate(0.5));
  finally
    F.Free;
  end;
end;

{ Stitching }

const
  Ramp = '<< /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >>';
  InvRamp = '<< /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>';

procedure TPdfFunctionTests.StitchingTwoFunctions;
var
  F: TPdfFunction;
begin
  F := Fn('<< /FunctionType 3 /Domain [0 1] /Functions [' + Ramp + InvRamp + '] /Bounds [0.5] /Encode [0 1 0 1] >>');
  try
    Assert.IsNotNull(F);
    Assert.IsTrue(F.FunctionType = ftStitching);
    Assert.AreEqual(1, F.OutputCount);
    NearArr([0.5], F.Evaluate(0.25));
    NearArr([0], F.Evaluate(0));
    // A bound belongs to the next subdomain
    NearArr([1], F.Evaluate(0.5));
    NearArr([0.5], F.Evaluate(0.75));
    NearArr([0], F.Evaluate(1));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.StitchingEncodeReversed;
var
  F: TPdfFunction;
begin
  F := Fn('<< /FunctionType 3 /Domain [0 1] /Functions [' + Ramp + Ramp + '] /Bounds [0.5] /Encode [1 0 1 0] >>');
  try
    NearArr([1], F.Evaluate(0));
    NearArr([0.8], F.Evaluate(0.1));
    NearArr([0.5], F.Evaluate(0.25));
    NearArr([0.5], F.Evaluate(0.75));
    NearArr([0], F.Evaluate(1));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.StitchingDomainEnd;
var
  F: TPdfFunction;
begin
  // One function, empty bounds
  F := Fn('<< /FunctionType 3 /Domain [0 2] /Functions [' + Ramp + '] /Bounds [] /Encode [0 1] >>');
  try
    Assert.IsNotNull(F);
    NearArr([1], F.Evaluate(2));
    NearArr([0.5], F.Evaluate(1));
  finally
    F.Free;
  end;
  // The end of the domain belongs to the last function
  F := Fn('<< /FunctionType 3 /Domain [0 1] /Functions [' + Ramp + InvRamp + Ramp + '] /Bounds [0.3 0.6] /Encode [0 1 0 1 0 1] >>');
  try
    NearArr([1], F.Evaluate(1));
    NearArr([1], F.Evaluate(5));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.StitchingEqualBoundsNoDivisionByZero;
var
  F: TPdfFunction;
begin
  // Bounds equal to the domain end: the last subdomain is empty
  F := Fn('<< /FunctionType 3 /Domain [0 1] /Functions [' + Ramp + InvRamp + '] /Bounds [1] /Encode [0 1 0.25 1] >>');
  try
    NearArr([0.5], F.Evaluate(0.5));
    NearArr([0.75], F.Evaluate(1));
  finally
    F.Free;
  end;
  // Equal and descending bounds
  F := Fn('<< /FunctionType 3 /Domain [0 1] /Functions [' + Ramp + InvRamp + Ramp + '] /Bounds [0.5 0.5] /Encode [0 1 0 1 0 1] >>');
  try
    NearArr([0.5], F.Evaluate(0.25));
    NearArr([0], F.Evaluate(0.5));
    NearArr([0.5], F.Evaluate(0.75));
  finally
    F.Free;
  end;
  F := Fn('<< /FunctionType 3 /Domain [0 1] /Functions [' + Ramp + InvRamp + '] /Bounds [2] /Encode [0 1 0 1] >>');
  try
    Assert.AreEqual(1, Integer(Length(F.Evaluate(1))));
  finally
    F.Free;
  end;
  // Domain start equal to the first bound stays in the first function
  F := Fn('<< /FunctionType 3 /Domain [0 1] /Functions [' + InvRamp + Ramp + '] /Bounds [0] /Encode [0 1 0 1] >>');
  try
    NearArr([1], F.Evaluate(0));
    NearArr([0.5], F.Evaluate(0.5));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.StitchingReferencesAndSelfReference;
var
  R: IPdfResolver;
  F: TPdfFunction;
begin
  R := TFnTestResolver.Create([nil,
    PdfParseObject(Ramp),
    PdfParseObject(InvRamp),
    nil]);
  F := Fn('<< /FunctionType 3 /Domain [0 1] /Functions [1 0 R 2 0 R] /Bounds [0.5] /Encode [0 1 0 1] >>', R);
  try
    Assert.IsNotNull(F);
    NearArr([0.5], F.Evaluate(0.75));
  finally
    F.Free;
  end;
  // A stitching function that contains itself must not recurse forever.
  R := TFnTestResolver.Create([nil,
    PdfParseObject('<< /FunctionType 3 /Domain [0 1] /Functions [1 0 R] /Encode [0 1] >>')]);
  F := TPdfFunction.Parse(PdfReference(1, 0), R);
  Assert.IsNull(F);
end;

{ Sampled }

procedure TPdfFunctionTests.SampledLinear1D;
var
  F: TPdfFunction;
begin
  F := StreamFn('<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [2] /BitsPerSample 8 >>', [0, 255]);
  try
    Assert.IsNotNull(F);
    Assert.IsTrue(F.FunctionType = ftSampled);
    Assert.AreEqual(1, F.OutputCount);
    NearArr([0.5], F.Evaluate(0.5));
    NearArr([0.25], F.Evaluate(0.25));
    NearArr([1], F.Evaluate(1));
    NearArr([0], F.Evaluate(-3));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.SampledBilinear2D;
var
  F: TPdfFunction;
begin
  // s(0,0)=0, s(1,0)=0.2, s(0,1)=0.4, s(1,1)=1 (first input varies fastest)
  F := StreamFn('<< /FunctionType 0 /Domain [0 1 0 1] /Range [0 1] /Size [2 2] /BitsPerSample 8 >>', [0, 51, 102, 255]);
  try
    Assert.IsNotNull(F);
    Assert.AreEqual(2, F.InputCount);
    NearArr([0.4], F.Evaluate([0.5, 0.5]));
    NearArr([0.6], F.Evaluate([1, 0.5]));
    NearArr([0.4], F.Evaluate([0, 1]));
    NearArr([0.2], F.Evaluate([1, 0]));
    NearArr([0.1 * 0.75 + 0.7 * 0.25], F.Evaluate([0.5, 0.25]));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.SampledOneBit;
var
  F: TPdfFunction;
begin
  // $A5 = 1010 0101
  F := StreamFn('<< /FunctionType 0 /Domain [0 7] /Range [0 1] /Size [8] /BitsPerSample 1 >>', [$A5]);
  try
    NearArr([1], F.Evaluate(0));
    NearArr([0], F.Evaluate(1));
    NearArr([1], F.Evaluate(2));
    NearArr([0], F.Evaluate(3));
    NearArr([1], F.Evaluate(5));
    NearArr([1], F.Evaluate(7));
    NearArr([0.5], F.Evaluate(0.5));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.SampledSixteenBitTwoOutputs;
var
  F: TPdfFunction;
begin
  F := StreamFn('<< /FunctionType 0 /Domain [0 1] /Range [0 1 0 1] /Size [2] /BitsPerSample 16 >>',
    [$00, $00, $FF, $FF, $FF, $FF, $00, $00]);
  try
    Assert.AreEqual(2, F.OutputCount);
    NearArr([0.25, 0.75], F.Evaluate(0.25));
    NearArr([1, 0], F.Evaluate(1));
  finally
    F.Free;
  end;
  // 12-bit samples: $FFF $000 packed into 3 bytes
  F := StreamFn('<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [2] /BitsPerSample 12 >>', [$FF, $F0, $00]);
  try
    NearArr([1], F.Evaluate(0));
    NearArr([0], F.Evaluate(1));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.SampledEncodeDecode;
var
  F: TPdfFunction;
begin
  F := StreamFn('<< /FunctionType 0 /Domain [0 1] /Range [0 10] /Size [3] /BitsPerSample 8 /Encode [2 0] /Decode [0 10] >>',
    [0, 128, 255]);
  try
    NearArr([10], F.Evaluate(0));
    NearArr([0], F.Evaluate(1));
    NearArr([128 / 255 * 10], F.Evaluate(0.5));
  finally
    F.Free;
  end;
  // Decode beyond Range is clipped to Range
  F := StreamFn('<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [2] /BitsPerSample 8 /Decode [0.5 2] >>', [0, 255]);
  try
    NearArr([0.5], F.Evaluate(0));
    NearArr([1], F.Evaluate(1));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.SampledShortDataAndSizeOne;
var
  F: TPdfFunction;
begin
  F := StreamFn('<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [4] /BitsPerSample 8 >>', [255]);
  try
    Assert.IsNotNull(F);
    NearArr([1], F.Evaluate(0));
    NearArr([0], F.Evaluate(1));
  finally
    F.Free;
  end;
  F := StreamFn('<< /FunctionType 0 /Domain [0 1 0 1] /Range [0 1] /Size [1 2] /BitsPerSample 8 >>', [0, 255]);
  try
    Assert.IsNotNull(F);
    NearArr([0.5], F.Evaluate([0.3, 0.5]));
  finally
    F.Free;
  end;
end;

{ PostScript }

procedure TPdfFunctionTests.PostScriptArithmetic;
var
  F: TPdfFunction;
begin
  F := PsFn('{ 2 mul 1 add }');
  try
    Assert.IsNotNull(F);
    Assert.IsTrue(F.FunctionType = ftPostScript);
    Assert.AreEqual(1, F.OutputCount);
    NearArr([7], F.Evaluate(3));
  finally
    F.Free;
  end;
  Near(2, Ps1('{ 3 sub 2 div neg abs }', 7));
  Near(4, Ps1('{ dup mul sqrt }', -4));
  Near(7, Ps1('{ pop 7.6 floor }'));
  Near(-8, Ps1('{ pop -7.6 floor }'));
  Near(8, Ps1('{ pop 7.2 ceiling }'));
  Near(3, Ps1('{ pop 7 2 idiv }'));
  Near(-3, Ps1('{ pop -7 2 idiv }'));
  Near(1, Ps1('{ pop 7 3 mod }'));
  Near(-1, Ps1('{ pop -7 3 mod }'));
  Near(3, Ps1('{ pop 2.5 round }'));
  Near(-2, Ps1('{ pop -2.5 round }'));
  Near(-2, Ps1('{ pop -2.7 truncate }'));
  Near(3, Ps1('{ pop 3.7 cvi }'));
  Near(3.5, Ps1('{ pop 3.5 cvr }'));
  Near(8, Ps1('{ pop 2 3 exp }'));
  Near(2, Ps1('{ pop 100 log }'));
  Near(0, Ps1('{ pop 1 ln }'));
  Near(1, Ps1('{ pop 90 sin }'));
  Near(-1, Ps1('{ pop 180 cos }'));
  Near(0.5, Ps1('{ pop 30 sin }'));
  Near(-5, Ps1('{ neg }', 5));
end;

procedure TPdfFunctionTests.PostScriptBitwise;
begin
  Near(16, Ps1('{ pop 1 4 bitshift }'));
  Near(4, Ps1('{ pop 16 -2 bitshift }'));
  Near(-4, Ps1('{ pop -16 -2 bitshift }'));
  Near(1, Ps1('{ pop 5 3 and }'));
  Near(7, Ps1('{ pop 5 3 or }'));
  Near(6, Ps1('{ pop 5 3 xor }'));
  Near(-1, Ps1('{ pop 0 not }'));
  Near(0, Ps1('{ pop 1 40 bitshift }'));
end;

procedure TPdfFunctionTests.PostScriptComparisonAndBoolean;
begin
  Near(1, Ps1('{ 0.5 gt }', 0.7));
  Near(0, Ps1('{ 0.5 gt }', 0.3));
  Near(1, Ps1('{ pop 1 1 eq }'));
  Near(0, Ps1('{ pop 1 2 eq }'));
  Near(1, Ps1('{ pop 1 2 ne }'));
  Near(1, Ps1('{ pop 2 2 ge }'));
  Near(0, Ps1('{ pop 1 2 ge }'));
  Near(1, Ps1('{ pop 2 2 le }'));
  Near(1, Ps1('{ pop 1 2 lt }'));
  Near(0, Ps1('{ pop 2 2 lt }'));
  Near(1, Ps1('{ pop true false or }'));
  Near(0, Ps1('{ pop true false and }'));
  Near(1, Ps1('{ pop true false xor }'));
  Near(0, Ps1('{ pop true not }'));
  Near(1, Ps1('{ pop 1 2 lt 3 4 lt and }'));
end;

procedure TPdfFunctionTests.PostScriptIfElse;
const
  Prog = '{ dup 0.5 lt { 2 mul } { 0.5 sub 2 mul 1 exch sub } ifelse }';
  Nested = '{ dup 0.5 lt { dup 0.25 lt { pop 0 } { pop 0.5 } ifelse } { pop 1 } ifelse }';
begin
  Near(0.5, Ps1(Prog, 0.25));
  Near(0.2, Ps1(Prog, 0.9));
  Near(1, Ps1('{ dup 0.5 gt { pop 1 } if }', 0.7));
  Near(0.3, Ps1('{ dup 0.5 gt { pop 1 } if }', 0.3));
  Near(0, Ps1(Nested, 0.1));
  Near(0.5, Ps1(Nested, 0.3));
  Near(1, Ps1(Nested, 0.8));
  // Number as condition: non-zero is true
  Near(5, Ps1('{ pop 1 { 5 } { 6 } ifelse }'));
  Near(6, Ps1('{ pop 0 { 5 } { 6 } ifelse }'));
  // Empty procedures
  Near(0.4, Ps1('{ dup 0.5 lt { } if }', 0.4));
end;

procedure TPdfFunctionTests.PostScriptStackOperators;

  function Run(const Code: string; NOut: Integer): TArray<Double>;
  var
    F: TPdfFunction;
  begin
    F := PsFn(Code, 1, NOut);
    try
      Assert.IsNotNull(F, Code);
      Result := F.Evaluate(0);
    finally
      F.Free;
    end;
  end;

begin
  NearArr([3, 1, 2], Run('{ pop 1 2 3 3 1 roll }', 3), 'roll 1');
  NearArr([2, 3, 1], Run('{ pop 1 2 3 3 -1 roll }', 3), 'roll -1');
  NearArr([1, 2, 3], Run('{ pop 1 2 3 3 3 roll }', 3), 'roll n');
  NearArr([1, 3, 2], Run('{ pop 1 2 3 2 1 roll }', 3), 'roll 2');
  NearArr([1, 2, 3, 1], Run('{ pop 1 2 3 2 index }', 4), 'index');
  NearArr([1, 2, 3, 3], Run('{ pop 1 2 3 0 index }', 4), 'index 0');
  NearArr([1, 2, 1, 2], Run('{ pop 1 2 2 copy }', 4), 'copy');
  NearArr([2, 1], Run('{ pop 1 2 exch }', 2), 'exch');
  NearArr([5, 5], Run('{ pop 5 dup }', 2), 'dup');
  NearArr([1], Run('{ pop 1 2 pop }', 1), 'pop');
  NearArr([7, 7], Run('{ pop 7 0 copy dup }', 2), 'copy 0');
end;

procedure TPdfFunctionTests.PostScriptTintTransforms;
var
  F: TPdfFunction;
begin
  Near(0.2, Ps1('{ dup 0.5 mul exch 0.3 mul add 1 exch sub }', 1));
  Near(0.6, Ps1('{ dup 0.5 mul exch 0.3 mul add 1 exch sub }', 0.5));
  // Typical spot colour: tint -> C M Y K
  F := StreamFn('<< /FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1 0 1] /Length 60 >>',
    PdfLatin1ToBytes('{ dup 0.2 mul exch dup 0.4 mul exch dup 0 mul exch 0.1 mul }'));
  try
    Assert.AreEqual(4, F.OutputCount);
    NearArr([0.2, 0.4, 0, 0.1], F.Evaluate(1));
    NearArr([0.1, 0.2, 0, 0.05], F.Evaluate(0.5));
  finally
    F.Free;
  end;
  // Two inputs (DeviceN) -> CMYK
  F := StreamFn('<< /FunctionType 4 /Domain [0 1 0 1] /Range [0 1 0 1 0 1 0 1] >>',
    PdfLatin1ToBytes('{ 0 0 }'));
  try
    NearArr([0.3, 0.6, 0, 0], F.Evaluate([0.3, 0.6]));
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.PostScriptAtanDegrees;
begin
  Near(45, Ps1('{ pop 1 1 atan }'), 'atan 1 1', 1E-9);
  Near(90, Ps1('{ pop 1 0 atan }'), 'atan 1 0', 1E-9);
  Near(180, Ps1('{ pop 0 -1 atan }'), 'atan 0 -1', 1E-9);
  Near(270, Ps1('{ pop -1 0 atan }'), 'atan -1 0', 1E-9);
  Near(315, Ps1('{ pop -1 1 atan }'), 'atan -1 1', 1E-9);
  Near(0, Ps1('{ pop 0 0 atan }'));
end;

procedure TPdfFunctionTests.PostScriptUnderflowAndMathErrors;
var
  F: TPdfFunction;
  R: TArray<Double>;
begin
  F := PsFn('{ add add mul pop pop exch roll index copy dup }', 1, 2);
  try
    Assert.IsNotNull(F);
    Assert.WillNotRaiseAny(
      procedure
      begin
        R := F.Evaluate(0.5);
      end);
    Assert.AreEqual(2, Integer(Length(R)));
  finally
    F.Free;
  end;
  Near(0, Ps1('{ pop 1 0 div }'));
  Near(0, Ps1('{ pop 1 0 idiv }'));
  Near(0, Ps1('{ pop 1 0 mod }'));
  Near(0, Ps1('{ pop -1 sqrt }'));
  Near(0, Ps1('{ pop 0 ln }'));
  Near(0, Ps1('{ pop -2 0.5 exp }'));
  // Overflow and huge values are clipped to Range, not raised
  Near(1000, Ps1('{ pop 10 400 exp }'));
  Near(1000, Ps1('{ pop 1e300 cvi }'));
  Near(1000, Ps1('{ pop 1e200 dup mul }'));
  // Fewer results than outputs: missing ones are 0
  F := PsFn('{ }', 1, 3);
  try
    NearArr([0, 0, 0.5], F.Evaluate(0.5));
  finally
    F.Free;
  end;
  // Stack overflow drops values instead of raising
  F := PsFn('{ 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 ' +
    '1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 add }');
  try
    Assert.WillNotRaiseAny(
      procedure
      begin
        R := F.Evaluate(0.5);
      end);
    Near(2, R[0]);
  finally
    F.Free;
  end;
end;

procedure TPdfFunctionTests.PostScriptTolerantSyntax;
begin
  Near(1.5, Ps1('junk 12 { pop 1. .5 add } trailing garbage'));
  Near(-0.5, Ps1('{ pop -.5 }'));
  Near(3, Ps1('{ pop 1 2 add'));
  Near(3, Ps1(#13#10'{'#10'pop'#9'1 2'#13'add % comment'#10'}'#10));
end;

procedure TPdfFunctionTests.PostScriptInvalid;
begin
  Assert.IsNull(PsFn('pop 1 2 add'), 'no braces');
  Assert.IsNull(PsFn('{ 1 2 foo }'), 'unknown operator');
  Assert.IsNull(PsFn('{ 1 if }'), 'if without procedure');
  Assert.IsNull(PsFn('{ 1 { 2 } }'), 'procedure without if');
  Assert.IsNull(PsFn('{ 1 { 2 } { 3 } if }'), 'two procedures with if');
  Assert.IsNull(PsFn('{ 1 { 2 '), 'unterminated nested procedure');
  Assert.IsNull(PsFn('{ (string) }'), 'string operand');
  Assert.IsNull(StreamFn('<< /FunctionType 4 /Domain [0 1] >>', PdfLatin1ToBytes('{ }')), 'missing Range');
  Assert.IsNull(Fn('<< /FunctionType 4 /Domain [0 1] /Range [0 1] >>'), 'not a stream');
end;

{ Arrays and helpers }

procedure TPdfFunctionTests.ParseArrayOfThree;
var
  Funcs: TArray<TPdfFunction>;
begin
  Funcs := TPdfFunction.ParseArray(PdfParseObject('[' +
    '<< /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >>' +
    '<< /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>' +
    '<< /FunctionType 2 /Domain [0 1] /C0 [0.5] /C1 [0.5] /N 1 >>]'), nil);
  try
    Assert.AreEqual(3, Integer(Length(Funcs)));
    NearArr([0.25, 0.75, 0.5], PdfEvaluateFunctions(Funcs, [0.25]));
  finally
    PdfFreeFunctions(Funcs);
  end;
  Assert.AreEqual(0, Integer(Length(Funcs)));
  Funcs := TPdfFunction.ParseArray(PdfParseObject(Ramp), nil);
  try
    Assert.AreEqual(1, Integer(Length(Funcs)));
  finally
    PdfFreeFunctions(Funcs);
  end;
  Funcs := TPdfFunction.ParseArray(PdfParseObject('/Identity'), nil);
  Assert.AreEqual(0, Integer(Length(Funcs)));
end;

procedure TPdfFunctionTests.EvaluateFunctionsHelper;
var
  Funcs: TArray<TPdfFunction>;
begin
  Funcs := TPdfFunction.ParseArray(PdfParseObject(
    '<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0] /C1 [1 1 1] /N 1 >>'), nil);
  try
    NearArr([0.5, 0.5, 0.5], PdfEvaluateFunctions(Funcs, [0.5]));
  finally
    PdfFreeFunctions(Funcs);
  end;
end;

procedure TPdfFunctionTests.InvalidInputReturnsNil;
begin
  Assert.IsNull(TPdfFunction.Parse(nil, nil), 'nil');
  Assert.IsNull(Fn('42'), 'number');
  Assert.IsNull(Fn('<< /Domain [0 1] /N 1 >>'), 'no FunctionType');
  Assert.IsNull(Fn('<< /FunctionType 5 /Domain [0 1] /N 1 >>'), 'unknown type');
  Assert.IsNull(Fn('<< /FunctionType /Two /Domain [0 1] /N 1 >>'), 'type not a number');
  Assert.IsNull(Fn('<< /FunctionType 2 /N 1 >>'), 'no Domain');
  Assert.IsNull(Fn('<< /FunctionType 2 /Domain [0] /N 1 >>'), 'short Domain');
  Assert.IsNull(Fn('<< /FunctionType 2 /Domain [0 /x] /N 1 >>'), 'non-numeric Domain');
  Assert.IsNull(Fn('<< /FunctionType 2 /Domain [0 1] >>'), 'no N');
  Assert.IsNull(Fn('<< /FunctionType 2 /Domain [0 1] /C0 [] /C1 [] /N 1 >>'), 'empty C0');
  Assert.IsNull(Fn('<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [2] /BitsPerSample 8 >>'), 'type 0 not a stream');
  Assert.IsNull(StreamFn('<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [2] /BitsPerSample 7 >>', [0, 1]), 'bad bps');
  Assert.IsNull(StreamFn('<< /FunctionType 0 /Domain [0 1] /Size [2] /BitsPerSample 8 >>', [0, 1]), 'type 0 no Range');
  Assert.IsNull(StreamFn('<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [0] /BitsPerSample 8 >>', [0, 1]), 'size 0');
  Assert.IsNull(StreamFn('<< /FunctionType 0 /Domain [0 1 0 1] /Range [0 1] /Size [2] /BitsPerSample 8 >>', [0, 1]), 'short Size');
  Assert.IsNull(StreamFn('<< /FunctionType 0 /Domain [0 1 0 1] /Range [0 1] /Size [100000 100000] /BitsPerSample 8 >>', [0]), 'huge');
  Assert.IsNull(Fn('<< /FunctionType 3 /Domain [0 1] /Functions [] >>'), 'no sub-functions');
  Assert.IsNull(Fn('<< /FunctionType 3 /Domain [0 1] /Functions [' + Ramp + ' 5] /Bounds [0.5] /Encode [0 1 0 1] >>'), 'bad sub-function');
  Assert.IsNull(Fn('<< /FunctionType 3 /Domain [0 1] >>'), 'no Functions');
end;

procedure TPdfFunctionTests.NaNInputDoesNotRaise;
var
  F: TPdfFunction;
  R: TArray<Double>;
begin
  F := Fn(Ramp);
  try
    Assert.WillNotRaiseAny(
      procedure
      begin
        R := F.Evaluate(NaN);
      end);
    NearArr([0], R);
    NearArr([1], F.Evaluate(Infinity));
    NearArr([0], F.Evaluate([]));
  finally
    F.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfFunctionTests);

end.
