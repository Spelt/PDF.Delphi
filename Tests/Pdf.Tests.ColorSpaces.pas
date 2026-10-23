unit Pdf.Tests.ColorSpaces;

interface

uses
  System.SysUtils, System.UITypes, DUnitX.TestFramework, Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Parser,
  Pdf.Render.Functions, Pdf.Render.ColorSpaces;

type
  [TestFixture]
  TPdfColorSpaceTests = class
  public
    /// <summary>Creates the lazily allocated null singleton up front, so the leak monitor does not report it.</summary>
    [SetupFixture] procedure SetupFixture;
    [Test] procedure DeviceConversions;
    [Test] procedure DeviceDecodeAndInitialColor;
    [Test] procedure Abbreviations;
    [Test] procedure CalGrayAndCalRGB;
    [Test] procedure IndexedWithStringLookup;
    [Test] procedure IndexedWithStreamLookup;
    [Test] procedure IndexedShortLookup;
    [Test] procedure IndexedLabBase;
    [Test] procedure IndexedInvalid;
    [Test] procedure SeparationType2ToCMYK;
    [Test] procedure SeparationNoneAndAll;
    [Test] procedure SeparationInvalid;
    [Test] procedure DeviceNWithType4Tint;
    [Test] procedure DeviceNAllNone;
    [Test] procedure ICCBasedByN;
    [Test] procedure ICCBasedAlternate;
    [Test] procedure LabConversion;
    [Test] procedure PatternWithBase;
    [Test] procedure ResourceLookup;
    [Test] procedure UnknownNameReturnsNil;
    [Test] procedure SelfReferenceDoesNotHang;
    [Test] procedure ParseReturnsNewInstances;
  end;

implementation

type
  TCsTestResolver = class(TInterfacedObject, IPdfResolver)
  private
    FObjects: TArray<IPdfObject>;
  public
    constructor Create(const Objects: array of IPdfObject);
    function Resolve(const Obj: IPdfObject): IPdfObject;
    function FetchObject(Num, Gen: Integer): IPdfObject;
  end;

constructor TCsTestResolver.Create(const Objects: array of IPdfObject);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FObjects, Length(Objects));
  for I := 0 to High(Objects) do
    FObjects[I] := Objects[I];
end;

function TCsTestResolver.FetchObject(Num, Gen: Integer): IPdfObject;
begin
  if (Num >= 0) and (Num < Length(FObjects)) and (FObjects[Num] <> nil) then
    Result := FObjects[Num]
  else
    Result := PdfNull;
end;

function TCsTestResolver.Resolve(const Obj: IPdfObject): IPdfObject;
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

function CS(const Source: string; const Resources: IPdfDictionary = nil; const Resolver: IPdfResolver = nil): TPdfColorSpace;
begin
  Result := TPdfColorSpace.Parse(PdfParseObject(Source, Resolver), Resources, Resolver);
end;

function Dict(const Source: string; const Resolver: IPdfResolver = nil): IPdfDictionary;
begin
  Result := PdfAsDictionary(PdfParseObject(Source, Resolver));
end;

function MakeStream(const DictSource: string; const Data: TBytes): IPdfStream;
begin
  Result := PdfStream(Dict(DictSource), Data);
end;

procedure Near(Expected, Actual: Double; const Msg: string = ''; Tol: Double = 0.005);
begin
  Assert.IsTrue(Abs(Expected - Actual) <= Tol, Format('%s expected %g, got %g', [Msg, Expected, Actual]));
end;

procedure AssertRGB(R, G, B: Double; const Actual: TPdfRGB; const Msg: string = ''; Tol: Double = 0.005);
begin
  Near(R, Actual.R, Msg + ' R', Tol);
  Near(G, Actual.G, Msg + ' G', Tol);
  Near(B, Actual.B, Msg + ' B', Tol);
end;

procedure AssertNumbers(const Expected: array of Double; const Actual: TArray<Double>; const Msg: string = '');
var
  I: Integer;
begin
  Assert.AreEqual(Integer(Length(Expected)), Integer(Length(Actual)), Msg + ' length');
  for I := 0 to High(Expected) do
    Near(Expected[I], Actual[I], Format('%s [%d]', [Msg, I]), 1E-9);
end;

{ TPdfColorSpaceTests }

procedure TPdfColorSpaceTests.SetupFixture;
begin
  PdfNull;
end;

{ Tests }

procedure TPdfColorSpaceTests.DeviceConversions;
var
  C: TPdfColorSpace;
begin
  C := CS('/DeviceGray');
  try
    Assert.IsTrue(C.Family = csDeviceGray);
    Assert.AreEqual(1, C.NComponents);
    AssertRGB(0.5, 0.5, 0.5, C.ToRGB([0.5]));
    AssertRGB(1, 1, 1, C.ToRGB([2]), 'clamped');
    AssertRGB(0, 0, 0, C.ToRGB([]), 'missing');
  finally
    C.Free;
  end;
  C := CS('/DeviceRGB');
  try
    Assert.IsTrue(C.Family = csDeviceRGB);
    Assert.AreEqual(3, C.NComponents);
    AssertRGB(1, 0.5, 0, C.ToRGB([1, 0.5, 0]));
    Assert.AreEqual(Cardinal($FFFF0000), Cardinal(C.ToAlphaColor([1, 0, 0])));
    Assert.AreEqual(Cardinal($8000FF00), Cardinal(C.ToAlphaColor([0, 1, 0], 128 / 255)));
  finally
    C.Free;
  end;
  C := CS('/DeviceCMYK');
  try
    Assert.IsTrue(C.Family = csDeviceCMYK);
    Assert.AreEqual(4, C.NComponents);
    AssertRGB(0, 0, 0, C.ToRGB([0, 0, 0, 1]), 'black');
    AssertRGB(1, 1, 1, C.ToRGB([0, 0, 0, 0]), 'white');
    AssertRGB(0, 1, 1, C.ToRGB([1, 0, 0, 0]), 'cyan');
    AssertRGB(1, 0, 0, C.ToRGB([0, 1, 1, 0]), 'red');
    AssertRGB(0.25, 0.25, 0.25, C.ToRGB([0.5, 0.5, 0.5, 0.5]));
  finally
    C.Free;
  end;
end;

procedure TPdfColorSpaceTests.DeviceDecodeAndInitialColor;
var
  C: TPdfColorSpace;
begin
  C := TPdfColorSpace.DeviceGray;
  try
    AssertNumbers([0], C.InitialColor);
    AssertNumbers([0, 1], C.DefaultDecode(8));
  finally
    C.Free;
  end;
  C := TPdfColorSpace.DeviceRGB;
  try
    AssertNumbers([0, 0, 0], C.InitialColor);
    AssertNumbers([0, 1, 0, 1, 0, 1], C.DefaultDecode(4));
    Assert.IsFalse(C.IsNone);
    Assert.IsFalse(C.IsPattern);
    Assert.AreEqual(-1, C.HiVal);
    Assert.IsNull(C.BaseColorSpace);
  finally
    C.Free;
  end;
  C := TPdfColorSpace.DeviceCMYK;
  try
    AssertNumbers([0, 0, 0, 1], C.InitialColor);
    AssertNumbers([0, 1, 0, 1, 0, 1, 0, 1], C.DefaultDecode(8));
  finally
    C.Free;
  end;
end;

procedure TPdfColorSpaceTests.Abbreviations;
var
  C: TPdfColorSpace;
begin
  C := CS('/G');
  try
    Assert.IsTrue(C.Family = csDeviceGray);
  finally
    C.Free;
  end;
  C := CS('/RGB');
  try
    Assert.IsTrue(C.Family = csDeviceRGB);
  finally
    C.Free;
  end;
  C := CS('/CMYK');
  try
    Assert.IsTrue(C.Family = csDeviceCMYK);
  finally
    C.Free;
  end;
  C := CS('[/DeviceRGB]');
  try
    Assert.IsNotNull(C);
    Assert.IsTrue(C.Family = csDeviceRGB);
  finally
    C.Free;
  end;
  C := CS('[/CMYK]');
  try
    Assert.IsTrue(C.Family = csDeviceCMYK);
  finally
    C.Free;
  end;
  C := CS('[/I /RGB 1 <FF0000 00FF00>]');
  try
    Assert.IsNotNull(C);
    Assert.IsTrue(C.Family = csIndexed);
    AssertRGB(0, 1, 0, C.ToRGB([1]));
  finally
    C.Free;
  end;
  Assert.IsNull(CS('/I'), 'bare /I is not a colour space');
end;

procedure TPdfColorSpaceTests.CalGrayAndCalRGB;
var
  C: TPdfColorSpace;
begin
  C := CS('[/CalRGB << /WhitePoint [0.9505 1 1.089] /Gamma [2.2 2.2 2.2] >>]');
  try
    Assert.IsTrue(C.Family = csCalRGB);
    Assert.AreEqual(3, C.NComponents);
    AssertRGB(0.2, 0.4, 0.6, C.ToRGB([0.2, 0.4, 0.6]));
    AssertNumbers([0, 0, 0], C.InitialColor);
  finally
    C.Free;
  end;
  C := CS('[/CalGray << /WhitePoint [0.9505 1 1.089] >>]');
  try
    Assert.IsTrue(C.Family = csCalGray);
    Assert.AreEqual(1, C.NComponents);
    AssertRGB(0.3, 0.3, 0.3, C.ToRGB([0.3]));
  finally
    C.Free;
  end;
end;

procedure TPdfColorSpaceTests.IndexedWithStringLookup;
var
  C: TPdfColorSpace;
begin
  C := CS('[/Indexed /DeviceRGB 2 <FF0000 00FF00 0000FF>]');
  try
    Assert.IsNotNull(C);
    Assert.IsTrue(C.Family = csIndexed);
    Assert.AreEqual(1, C.NComponents);
    Assert.AreEqual(2, C.HiVal);
    Assert.IsNotNull(C.BaseColorSpace);
    Assert.IsTrue(C.BaseColorSpace.Family = csDeviceRGB);
    AssertRGB(1, 0, 0, C.ToRGB([0]));
    AssertRGB(0, 1, 0, C.ToRGB([1]));
    AssertRGB(0, 0, 1, C.ToRGB([2]));
    AssertRGB(0, 0, 1, C.ToRGB([5]), 'clamped high');
    AssertRGB(1, 0, 0, C.ToRGB([-3]), 'clamped low');
    AssertRGB(0, 1, 0, C.ToRGB([0.6]), 'rounded');
    AssertRGB(1, 0, 0, C.LookupRGB(0));
    AssertRGB(0, 0, 1, C.LookupRGB(99));
    AssertNumbers([0], C.InitialColor);
    AssertNumbers([0, 255], C.DefaultDecode(8));
    AssertNumbers([0, 15], C.DefaultDecode(4));
    AssertNumbers([0, 1], C.DefaultDecode(1));
  finally
    C.Free;
  end;
  // Literal string lookup
  C := CS('[/Indexed /DeviceGray 1 (\000\377)]');
  try
    AssertRGB(0, 0, 0, C.ToRGB([0]));
    AssertRGB(1, 1, 1, C.ToRGB([1]));
  finally
    C.Free;
  end;
end;

procedure TPdfColorSpaceTests.IndexedWithStreamLookup;
var
  Arr: IPdfArray;
  C: TPdfColorSpace;
  R: IPdfResolver;
begin
  Arr := PdfArray;
  Arr.Add(PdfName('Indexed'));
  Arr.Add(PdfName('DeviceCMYK'));
  Arr.Add(PdfInteger(1));
  Arr.Add(MakeStream('<< >>', [0, 0, 0, 255, 0, 255, 255, 0]));
  C := TPdfColorSpace.Parse(Arr, nil, nil);
  try
    Assert.IsNotNull(C);
    AssertRGB(0, 0, 0, C.ToRGB([0]));
    AssertRGB(1, 0, 0, C.ToRGB([1]));
  finally
    C.Free;
  end;
  // Lookup stream by reference, with a filter
  R := TCsTestResolver.Create([nil,
    PdfParseObject('<< /Filter /ASCIIHexDecode /Length 13 >>stream'#10'FFFFFF000000>'#10'endstream')]);
  C := CS('[/Indexed /DeviceRGB 1 1 0 R]', nil, R);
  try
    Assert.IsNotNull(C);
    AssertRGB(1, 1, 1, C.ToRGB([0]));
    AssertRGB(0, 0, 0, C.ToRGB([1]));
  finally
    C.Free;
  end;
end;

procedure TPdfColorSpaceTests.IndexedShortLookup;
var
  C: TPdfColorSpace;
begin
  C := CS('[/Indexed /DeviceRGB 3 <FF00FF 80>]');
  try
    Assert.AreEqual(3, C.HiVal);
    AssertRGB(1, 0, 1, C.ToRGB([0]));
    AssertRGB(128 / 255, 0, 0, C.ToRGB([1]));
    AssertRGB(0, 0, 0, C.ToRGB([3]));
  finally
    C.Free;
  end;
  // hival above 255 is clamped
  C := CS('[/Indexed /DeviceGray 300 <FF>]');
  try
    Assert.AreEqual(255, C.HiVal);
  finally
    C.Free;
  end;
end;

procedure TPdfColorSpaceTests.IndexedLabBase;
var
  C: TPdfColorSpace;
begin
  // Lookup bytes map onto Lab's ranges: FF -> L 100, 80 -> a/b ~0 in [-128 127]
  C := CS('[/Indexed [/Lab << /WhitePoint [0.9642 1 0.8249] /Range [-128 127 -128 127] >>] 0 <FF8080>]');
  try
    Assert.IsNotNull(C);
    AssertRGB(1, 1, 1, C.ToRGB([0]), 'white', 0.02);
  finally
    C.Free;
  end;
end;

procedure TPdfColorSpaceTests.IndexedInvalid;
begin
  Assert.IsNull(CS('[/Indexed /DeviceRGB 1]'), 'too short');
  Assert.IsNull(CS('[/Indexed /DeviceRGB /x <00>]'), 'hival not a number');
  Assert.IsNull(CS('[/Indexed /DeviceRGB 1 42]'), 'lookup not a string');
  Assert.IsNull(CS('[/Indexed /Pattern 1 <00>]'), 'pattern base');
  Assert.IsNull(CS('[/Indexed [/Indexed /DeviceRGB 0 <000000>] 0 <00>]'), 'indexed base');
  Assert.IsNull(CS('[/Indexed /Foo 1 <00>]'), 'unknown base');
end;

const
  SpotTint = '<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [0 1 1 0] /N 1 >>';

procedure TPdfColorSpaceTests.SeparationType2ToCMYK;
var
  C: TPdfColorSpace;
begin
  C := CS('[/Separation /Spot /DeviceCMYK ' + SpotTint + ']');
  try
    Assert.IsNotNull(C);
    Assert.IsTrue(C.Family = csSeparation);
    Assert.AreEqual(1, C.NComponents);
    Assert.IsFalse(C.IsNone);
    AssertRGB(1, 0, 0, C.ToRGB([1]), 'full tint');
    AssertRGB(1, 1, 1, C.ToRGB([0]), 'no tint');
    AssertRGB(1, 0.5, 0.5, C.ToRGB([0.5]), 'half tint', 0.01);
    // Cached value is returned the second time
    AssertRGB(1, 0.5, 0.5, C.ToRGB([0.5]), 'half tint again', 0.01);
    AssertRGB(1, 0, 0, C.ToRGB([7]), 'clamped');
    AssertNumbers([1], C.InitialColor);
    AssertNumbers([0, 1], C.DefaultDecode(8));
  finally
    C.Free;
  end;
  // Alternate space by name through resources, tint by reference
  C := CS('[/Separation (Spot) /RGB << /FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [0 0 1] /N 1 >>]');
  try
    Assert.IsNotNull(C);
    AssertRGB(0, 0, 1, C.ToRGB([1]));
  finally
    C.Free;
  end;
end;

procedure TPdfColorSpaceTests.SeparationNoneAndAll;
var
  C: TPdfColorSpace;
begin
  C := CS('[/Separation /None /DeviceCMYK ' + SpotTint + ']');
  try
    Assert.IsNotNull(C);
    Assert.IsTrue(C.IsNone);
  finally
    C.Free;
  end;
  // /None without a usable tint transform is still accepted (nothing is painted anyway)
  C := CS('[/Separation /None /DeviceGray null]');
  try
    Assert.IsNotNull(C);
    Assert.IsTrue(C.IsNone);
  finally
    C.Free;
  end;
  C := CS('[/Separation /All /DeviceCMYK ' + SpotTint + ']');
  try
    Assert.IsNotNull(C);
    Assert.IsFalse(C.IsNone);
    AssertRGB(0, 0, 0, C.ToRGB([1]));
    AssertRGB(1, 1, 1, C.ToRGB([0]));
    AssertRGB(0.75, 0.75, 0.75, C.ToRGB([0.25]));
  finally
    C.Free;
  end;
end;

procedure TPdfColorSpaceTests.SeparationInvalid;
begin
  Assert.IsNull(CS('[/Separation /Spot /DeviceCMYK]'), 'too short');
  Assert.IsNull(CS('[/Separation /Spot /DeviceCMYK 5]'), 'bad tint');
  Assert.IsNull(CS('[/Separation /Spot /Foo ' + SpotTint + ']'), 'bad alternate');
  Assert.IsNull(CS('[/Separation /Spot /Pattern ' + SpotTint + ']'), 'pattern alternate');
end;

procedure TPdfColorSpaceTests.DeviceNWithType4Tint;
var
  R: IPdfResolver;
  C: TPdfColorSpace;
begin
  R := TCsTestResolver.Create([nil,
    PdfParseObject('<< /FunctionType 4 /Domain [0 1 0 1] /Range [0 1 0 1 0 1 0 1] /Length 7 >>stream'#10'{ 0 0 }'#10'endstream')]);
  C := CS('[/DeviceN [/Cyan /Magenta] /DeviceCMYK 1 0 R << /Subtype /NChannel >>]', nil, R);
  try
    Assert.IsNotNull(C);
    Assert.IsTrue(C.Family = csDeviceN);
    Assert.AreEqual(2, C.NComponents);
    Assert.IsFalse(C.IsNone);
    AssertRGB(0, 1, 1, C.ToRGB([1, 0]), 'cyan');
    AssertRGB(1, 0, 1, C.ToRGB([0, 1]), 'magenta');
    AssertRGB(0, 0, 1, C.ToRGB([1, 1]), 'blue');
    AssertRGB(1, 1, 1, C.ToRGB([]), 'missing components');
    AssertNumbers([1, 1], C.InitialColor);
    AssertNumbers([0, 1, 0, 1], C.DefaultDecode(8));
  finally
    C.Free;
  end;
  // Without attributes dictionary
  C := CS('[/DeviceN [/Spot] /DeviceGray << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>]');
  try
    Assert.IsNotNull(C);
    Assert.AreEqual(1, C.NComponents);
    AssertRGB(0.25, 0.25, 0.25, C.ToRGB([0.75]), '', 0.01);
  finally
    C.Free;
  end;
end;

procedure TPdfColorSpaceTests.DeviceNAllNone;
var
  C: TPdfColorSpace;
begin
  C := CS('[/DeviceN [/None /None] /DeviceCMYK << /FunctionType 2 /Domain [0 1 0 1] /C0 [0 0 0 0] /C1 [0 0 0 1] /N 1 >>]');
  try
    Assert.IsNotNull(C);
    Assert.IsTrue(C.IsNone);
  finally
    C.Free;
  end;
  C := CS('[/DeviceN [/None /Black] /DeviceCMYK << /FunctionType 2 /Domain [0 1 0 1] /C0 [0 0 0 0] /C1 [0 0 0 1] /N 1 >>]');
  try
    Assert.IsFalse(C.IsNone);
  finally
    C.Free;
  end;
  Assert.IsNull(CS('[/DeviceN [] /DeviceCMYK ' + SpotTint + ']'), 'no names');
  Assert.IsNull(CS('[/DeviceN /Spot /DeviceCMYK ' + SpotTint + ']'), 'names not an array');
end;

procedure TPdfColorSpaceTests.ICCBasedByN;
var
  Arr: IPdfArray;
  C: TPdfColorSpace;

  function ICC(const DictSource: string): TPdfColorSpace;
  begin
    Arr := PdfArray;
    Arr.Add(PdfName('ICCBased'));
    Arr.Add(MakeStream(DictSource, [1, 2, 3]));
    Result := TPdfColorSpace.Parse(Arr, nil, nil);
  end;

begin
  C := ICC('<< /N 3 >>');
  try
    Assert.IsNotNull(C);
    Assert.IsTrue(C.Family = csICCBased);
    Assert.AreEqual(3, C.NComponents);
    AssertRGB(0.1, 0.2, 0.3, C.ToRGB([0.1, 0.2, 0.3]));
    AssertNumbers([0, 0, 0], C.InitialColor);
    AssertNumbers([0, 1, 0, 1, 0, 1], C.DefaultDecode(8));
  finally
    C.Free;
  end;
  C := ICC('<< /N 4 >>');
  try
    Assert.AreEqual(4, C.NComponents);
    AssertRGB(0, 0, 0, C.ToRGB([0, 0, 0, 1]));
    AssertRGB(0, 1, 1, C.ToRGB([1, 0, 0, 0]));
  finally
    C.Free;
  end;
  C := ICC('<< /N 1 /Range [0.2 1] >>');
  try
    Assert.AreEqual(1, C.NComponents);
    AssertRGB(0.7, 0.7, 0.7, C.ToRGB([0.7]));
    AssertNumbers([0.2, 1], C.DefaultDecode(8));
    AssertNumbers([0.2], C.InitialColor);
  finally
    C.Free;
  end;
  Assert.IsNull(ICC('<< /N 2 >>'), 'N = 2 without alternate');
  Assert.IsNull(ICC('<< >>'), 'no N');
  Assert.IsNull(CS('[/ICCBased]'), 'no stream');
end;

procedure TPdfColorSpaceTests.ICCBasedAlternate;
var
  R: IPdfResolver;
  C: TPdfColorSpace;
begin
  R := TCsTestResolver.Create([nil,
    PdfParseObject('<< /N 2 /Alternate /DeviceRGB /Length 3 >>stream'#10'abc'#10'endstream'),
    PdfParseObject('<< /N 5 /Alternate [/Lab << /WhitePoint [0.9505 1 1.089] >>] /Length 3 >>stream'#10'abc'#10'endstream'),
    PdfParseObject('<< /N 3 /Alternate /DeviceCMYK /Length 3 >>stream'#10'abc'#10'endstream')]);
  C := CS('[/ICCBased 1 0 R]', nil, R);
  try
    Assert.IsNotNull(C);
    Assert.IsTrue(C.Family = csDeviceRGB);
  finally
    C.Free;
  end;
  C := CS('[/ICCBased 2 0 R]', nil, R);
  try
    Assert.IsNotNull(C);
    Assert.IsTrue(C.Family = csLab);
  finally
    C.Free;
  end;
  // A valid N wins over the alternate
  C := CS('[/ICCBased 3 0 R]', nil, R);
  try
    Assert.IsTrue(C.Family = csICCBased);
    Assert.AreEqual(3, C.NComponents);
  finally
    C.Free;
  end;
end;

procedure TPdfColorSpaceTests.LabConversion;
var
  C: TPdfColorSpace;
begin
  C := CS('[/Lab << /WhitePoint [0.9505 1 1.089] /Range [-128 127 -128 127] >>]');
  try
    Assert.IsNotNull(C);
    Assert.IsTrue(C.Family = csLab);
    Assert.AreEqual(3, C.NComponents);
    AssertRGB(1, 1, 1, C.ToRGB([100, 0, 0]), 'white', 0.01);
    AssertRGB(0, 0, 0, C.ToRGB([0, 0, 0]), 'black', 0.01);
    AssertRGB(1, 0, 0, C.ToRGB([53.24, 80.09, 67.20]), 'red', 0.03);
    AssertRGB(0, 0, 1, C.ToRGB([32.30, 79.19, -107.86]), 'blue', 0.03);
    // sRGB mid grey (L* 53.39 is 50% grey after gamma)
    AssertRGB(0.5, 0.5, 0.5, C.ToRGB([53.39, 0, 0]), 'grey', 0.01);
    AssertNumbers([0, 100, -128, 127, -128, 127], C.DefaultDecode(8));
    AssertNumbers([0, 0, 0], C.InitialColor);
  finally
    C.Free;
  end;
  // D50 white point, default range
  C := CS('[/Lab << /WhitePoint [0.9642 1 0.8249] >>]');
  try
    AssertRGB(1, 1, 1, C.ToRGB([100, 0, 0]), 'D50 white', 0.01);
    AssertNumbers([0, 100, -100, 100, -100, 100], C.DefaultDecode(8));
  finally
    C.Free;
  end;
end;

procedure TPdfColorSpaceTests.PatternWithBase;
var
  C: TPdfColorSpace;
begin
  C := CS('[/Pattern /DeviceRGB]');
  try
    Assert.IsNotNull(C);
    Assert.IsTrue(C.IsPattern);
    Assert.IsTrue(C.Family = csPattern);
    Assert.IsNotNull(C.BaseColorSpace);
    Assert.IsTrue(C.BaseColorSpace.Family = csDeviceRGB);
    AssertRGB(0, 0, 0, C.ToRGB([1, 1, 1]));
  finally
    C.Free;
  end;
  C := CS('/Pattern');
  try
    Assert.IsTrue(C.IsPattern);
    Assert.IsNull(C.BaseColorSpace);
  finally
    C.Free;
  end;
  C := CS('[/Pattern]');
  try
    Assert.IsTrue(C.IsPattern);
    Assert.IsNull(C.BaseColorSpace);
  finally
    C.Free;
  end;
  C := CS('[/Pattern [/Separation /Spot /DeviceCMYK ' + SpotTint + ']]');
  try
    Assert.IsTrue(C.BaseColorSpace.Family = csSeparation);
  finally
    C.Free;
  end;
end;

procedure TPdfColorSpaceTests.ResourceLookup;
var
  Res: IPdfDictionary;
  C: TPdfColorSpace;
begin
  Res := Dict('<< /ColorSpace << /CS0 [/Indexed /DeviceRGB 0 <00FF00>] /CS1 /DeviceCMYK ' +
    '/CS2 [/Pattern /CS1] /CS3 [/Indexed /CS1 0 <00000000>] >> >>');
  C := CS('/CS0', Res);
  try
    Assert.IsNotNull(C);
    Assert.IsTrue(C.Family = csIndexed);
    AssertRGB(0, 1, 0, C.ToRGB([0]));
  finally
    C.Free;
  end;
  C := CS('/CS1', Res);
  try
    Assert.IsTrue(C.Family = csDeviceCMYK);
  finally
    C.Free;
  end;
  C := CS('/CS2', Res);
  try
    Assert.IsTrue(C.IsPattern);
    Assert.IsTrue(C.BaseColorSpace.Family = csDeviceCMYK);
  finally
    C.Free;
  end;
  C := CS('/CS3', Res);
  try
    Assert.IsNotNull(C);
    AssertRGB(1, 1, 1, C.ToRGB([0]));
  finally
    C.Free;
  end;
  // Device names are never looked up in resources
  C := CS('/DeviceGray', Dict('<< /ColorSpace << /DeviceGray /DeviceCMYK >> >>'));
  try
    Assert.IsTrue(C.Family = csDeviceGray);
  finally
    C.Free;
  end;
  Assert.IsNull(CS('/CS9', Res), 'missing resource');
  Assert.IsNull(CS('/CS0'), 'no resources');
end;

procedure TPdfColorSpaceTests.UnknownNameReturnsNil;
begin
  Assert.IsNull(CS('/Foo'));
  Assert.IsNull(CS('[/Foo]'));
  Assert.IsNull(CS('[]'));
  Assert.IsNull(CS('42'));
  Assert.IsNull(CS('null'));
  Assert.IsNull(CS('[42 /DeviceRGB]'));
  Assert.IsNull(TPdfColorSpace.Parse(nil, nil, nil));
  Assert.IsNull(CS('/Indexed'));
end;

procedure TPdfColorSpaceTests.SelfReferenceDoesNotHang;
var
  Res: IPdfDictionary;
  R: IPdfResolver;
  C: TPdfColorSpace;
begin
  Res := Dict('<< /ColorSpace << /CS0 /CS0 /A /B /B /A /DeviceRGB /DeviceRGB ' +
    '/CS2 [/Indexed /CS2 1 <00>] /CS3 [/Pattern /CS3] >> >>');
  Assert.IsNull(CS('/CS0', Res), 'self');
  Assert.IsNull(CS('/A', Res), 'cycle');
  Assert.IsNull(CS('/CS2', Res), 'indexed self base');
  C := CS('/CS3', Res);
  try
    Assert.IsTrue(C.IsPattern);
  finally
    C.Free;
  end;
  C := CS('/DeviceRGB', Res);
  try
    Assert.IsTrue(C.Family = csDeviceRGB);
  finally
    C.Free;
  end;
  // Indirect self-references
  R := TCsTestResolver.Create([nil,
    PdfParseObject('[/Indexed 1 0 R 1 <00>]'),
    PdfParseObject('<< /N 7 /Alternate [/ICCBased 2 0 R] /Length 1 >>stream'#10'a'#10'endstream'),
    PdfParseObject('[/Separation /S 3 0 R << /FunctionType 2 /Domain [0 1] /N 1 >>]')]);
  Assert.IsNull(TPdfColorSpace.Parse(PdfReference(1, 0), nil, R), 'indexed');
  Assert.IsNull(CS('[/ICCBased 2 0 R]', nil, R), 'iccbased alternate');
  Assert.IsNull(TPdfColorSpace.Parse(PdfReference(3, 0), nil, R), 'separation');
end;

procedure TPdfColorSpaceTests.ParseReturnsNewInstances;
var
  Res: IPdfDictionary;
  A, B: TPdfColorSpace;
begin
  Res := Dict('<< /ColorSpace << /CS0 /DeviceRGB >> >>');
  A := CS('/CS0', Res);
  B := CS('/CS0', Res);
  try
    Assert.IsNotNull(A);
    Assert.IsNotNull(B);
    Assert.IsFalse(A = B);
  finally
    A.Free;
    B.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfColorSpaceTests);

end.
