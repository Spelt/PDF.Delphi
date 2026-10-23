{*******************************************************************************
  Pdf.Tests.Mesh
  DUnitX fixture for the mesh shadings (types 4-7) of Pdf.Render.Shading.

  The mesh streams are built here with a small MSB-first bit packer, decoded by
  TPdfShading and drawn with DrawMesh onto a 100 x 100 raster surface whose
  pixels are checked. The corpus test parses and draws every mesh shading on
  the first pages of the pdf.js test files that contain one.
*******************************************************************************}
unit Pdf.Tests.Mesh;

interface

uses
  System.SysUtils, System.Math, System.Types, System.UITypes, System.Math.Vectors, System.IOUtils,
  System.Generics.Collections, System.Skia, DUnitX.TestFramework,
  Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Parser, Pdf.Core.Document,
  Pdf.Render.Shading;

type
  [TestFixture]
  TPdfMeshShadingTests = class
  public
    /// <summary>Creates the lazily allocated null singleton up front, so the leak monitor does not report it.</summary>
    [SetupFixture] procedure SetupFixture;
    [Test] procedure Type4_TwoTriangles;
    [Test] procedure Type4_FlagTwoFan;
    [Test] procedure Type4_Alpha;
    [Test] procedure Type4_Function;
    [Test] procedure Type4_FunctionNonLinear;
    [Test] procedure Type4_PaddedVertices;
    [Test] procedure Type4_Matrix;
    [Test] procedure Type5_Lattice;
    [Test] procedure Type6_CoonsPatch;
    [Test] procedure Type6_FlagContinuation;
    [Test] procedure Type6_CurvedEdge;
    [Test] procedure Type7_TensorPatch;
    [Test] procedure Truncated_FewerTriangles;
    [Test] procedure Garbage_NeverRaises;
    [Test] procedure EmptyStream_NoOp;
    [Test] procedure SupportFlags;
    [Test] procedure InvalidParameters;
    [Test] procedure AverageColorOfMesh;
    [Test] procedure Corpus_MeshShadings;
  end;

implementation

{ ---------------------------------------------------------------------------- }
{ Helpers                                                                      }
{ ---------------------------------------------------------------------------- }

type
  /// <summary>MSB-first bit packer for mesh data.</summary>
  TBitPacker = class
  private
    FData: TBytes;
    FCount: Integer;
    FAcc: UInt64;
    FAccBits: Integer;
  public
    procedure Put(Value: Cardinal; Bits: Integer);
    /// <summary>Pads to the next byte boundary with zero bits.</summary>
    procedure Align;
    function Bytes: TBytes;
  end;

procedure TBitPacker.Put(Value: Cardinal; Bits: Integer);
begin
  FAcc := (FAcc shl Bits) or (UInt64(Value) and ((UInt64(1) shl Bits) - 1));
  Inc(FAccBits, Bits);
  while FAccBits >= 8 do
  begin
    Dec(FAccBits, 8);
    if FCount >= Integer(Length(FData)) then
      SetLength(FData, Max(64, FCount * 2));
    FData[FCount] := Byte(FAcc shr FAccBits);
    Inc(FCount);
    FAcc := FAcc and ((UInt64(1) shl FAccBits) - 1);
  end;
end;

procedure TBitPacker.Align;
begin
  if FAccBits > 0 then
    Put(0, 8 - FAccBits);
end;

function TBitPacker.Bytes: TBytes;
begin
  Align;
  Result := Copy(FData, 0, FCount);
end;

const
  // Common layout: 32-bit coordinates over [0 100], 16-bit components, 8-bit flags
  StdDict = '<< /ShadingType %d /ColorSpace /DeviceRGB /BitsPerCoordinate 32 /BitsPerComponent 16 ' +
    '/BitsPerFlag 8 /Decode [0 100 0 100 0 1 0 1 0 1] %s >>';

type
  TRGB = record
    R, G, B: Double; // 0..1
  end;

function RGB(R, G, B: Double): TRGB;
begin
  Result.R := R;
  Result.G := G;
  Result.B := B;
end;

const
  Red: TRGB = (R: 1; G: 0; B: 0);
  Green: TRGB = (R: 0; G: 1; B: 0);
  Blue: TRGB = (R: 0; G: 0; B: 1);
  White: TRGB = (R: 1; G: 1; B: 1);
  Black: TRGB = (R: 0; G: 0; B: 0);

function Coord32(V: Double): Cardinal;
begin
  // x = v * 2^-32 * 100
  Result := Cardinal(EnsureRange(Round(V / 100 * 4294967296.0), 0, Int64(High(Cardinal))));
end;

procedure PutPoint(P: TBitPacker; X, Y: Double);
begin
  P.Put(Coord32(X), 32);
  P.Put(Coord32(Y), 32);
end;

procedure PutColor(P: TBitPacker; const C: TRGB);
begin
  P.Put(Round(C.R * 65535), 16);
  P.Put(Round(C.G * 65535), 16);
  P.Put(Round(C.B * 65535), 16);
end;

procedure PutVertex(P: TBitPacker; Flag: Integer; X, Y: Double; const C: TRGB);
begin
  P.Put(Flag, 8);
  PutPoint(P, X, Y);
  PutColor(P, C);
end;

function MakeShading(const DictSource: string; const Data: TBytes): TPdfShading;
var
  S: IPdfStream;
begin
  S := PdfStream(PdfAsDictionary(PdfParseObject(DictSource)), Data);
  Result := TPdfShading.Parse(S, nil, nil);
  Assert.IsNotNull(Result, 'Parse');
end;

function NewSurface(Size: Integer = 100): ISkSurface;
begin
  Result := TSkSurface.MakeRaster(Size, Size);
  Result.Canvas.Clear(TAlphaColorRec.White);
end;

function Draw(Shading: TPdfShading; Alpha: Single = 1): ISkSurface;
begin
  Result := NewSurface;
  Shading.DrawMesh(Result.Canvas, TMatrix.Identity, Alpha, nil);
end;

function Pixel(const Surface: ISkSurface; X, Y: Integer): TAlphaColor;
begin
  Result := Surface.PeekPixels.GetColor(X, Y);
end;

function Mix3(const A, B, C: TRGB; WA, WB, WC: Double): TRGB;
begin
  Result.R := A.R * WA + B.R * WB + C.R * WC;
  Result.G := A.G * WA + B.G * WB + C.G * WC;
  Result.B := A.B * WA + B.B * WB + C.B * WC;
end;

/// <summary>Gouraud colour at the centre of pixel (X, Y) in the triangle (AX, AY) (BX, BY) (CX, CY).</summary>
function TriColor(X, Y: Integer; AX, AY, BX, BY, CX, CY: Double; const CA, CB, CC: TRGB): TRGB;
var
  PX, PY, Det, WA, WB: Double;
begin
  PX := X + 0.5;
  PY := Y + 0.5;
  Det := (BY - CY) * (AX - CX) + (CX - BX) * (AY - CY);
  WA := ((BY - CY) * (PX - CX) + (CX - BX) * (PY - CY)) / Det;
  WB := ((CY - AY) * (PX - CX) + (AX - CX) * (PY - CY)) / Det;
  Result := Mix3(CA, CB, CC, WA, WB, 1 - WA - WB);
end;

function Bilinear(const C00, C01, C10, C11: TRGB; U, V: Double): TRGB;
begin
  // C00 at (u 0, v 0), C01 at (u 1, v 0), C10 at (u 0, v 1), C11 at (u 1, v 1)
  Result.R := (1 - V) * ((1 - U) * C00.R + U * C01.R) + V * ((1 - U) * C10.R + U * C11.R);
  Result.G := (1 - V) * ((1 - U) * C00.G + U * C01.G) + V * ((1 - U) * C10.G + U * C11.G);
  Result.B := (1 - V) * ((1 - U) * C00.B + U * C01.B) + V * ((1 - U) * C10.B + U * C11.B);
end;

procedure CheckPixel(const Surface: ISkSurface; X, Y: Integer; const Expected: TRGB; Tolerance: Integer = 6;
  const Msg: string = '');
var
  C: TAlphaColor;
  R, G, B: Integer;
begin
  C := Pixel(Surface, X, Y);
  R := (C shr 16) and $FF;
  G := (C shr 8) and $FF;
  B := C and $FF;
  if (Abs(R - Round(Expected.R * 255)) > Tolerance) or (Abs(G - Round(Expected.G * 255)) > Tolerance) or
     (Abs(B - Round(Expected.B * 255)) > Tolerance) then
    Assert.Fail(Format('%s pixel (%d,%d) = %d,%d,%d, expected %d,%d,%d', [Msg, X, Y, R, G, B,
      Round(Expected.R * 255), Round(Expected.G * 255), Round(Expected.B * 255)]));
end;

procedure CheckBounds(Shading: TPdfShading; L, T, R, B: Single; Tol: Single = 0.01);
var
  Bounds: TRectF;
begin
  Bounds := Shading.MeshBounds;
  Assert.IsTrue((Abs(Bounds.Left - L) <= Tol) and (Abs(Bounds.Top - T) <= Tol) and (Abs(Bounds.Right - R) <= Tol) and
    (Abs(Bounds.Bottom - B) <= Tol), Format('MeshBounds %.3f %.3f %.3f %.3f', [Bounds.Left, Bounds.Top, Bounds.Right,
    Bounds.Bottom]));
end;

/// <summary>Square 10..90: triangle 1 (flag 0) red (10,10), green (90,10), blue (10,90); triangle 2 (flag 1)
/// continues with white (90,90).</summary>
function SquareType4Data: TBytes;
var
  P: TBitPacker;
begin
  P := TBitPacker.Create;
  try
    PutVertex(P, 0, 10, 10, Red);
    PutVertex(P, 0, 90, 10, Green);
    PutVertex(P, 0, 10, 90, Blue);
    PutVertex(P, 1, 90, 90, White);
    Result := P.Bytes;
  finally
    P.Free;
  end;
end;

/// <summary>Coons/tensor control point (row, col) of a flat patch over [X0, X1] x [Y0, Y1]; columns run along x.</summary>
procedure PutGridPoint(P: TBitPacker; Row, Col: Integer; X0, Y0, X1, Y1: Double);
begin
  PutPoint(P, X0 + (X1 - X0) * Col / 3, Y0 + (Y1 - Y0) * Row / 3);
end;

const
  // Stream order of the 12 border points of a new patch, as (row, col) in pdf.js index terms (index = 4 row + col)
  BorderRC: array[0..11, 0..1] of Integer = ((0, 0), (1, 0), (2, 0), (3, 0), (3, 1), (3, 2), (3, 3), (2, 3), (1, 3),
    (0, 3), (0, 2), (0, 1));
  // Stream order of the 4 interior points of a tensor patch: p11, p12, p22, p21 (indices 5, 9, 10, 6)
  InnerRC: array[0..3, 0..1] of Integer = ((1, 1), (2, 1), (2, 2), (1, 2));

/// <summary>Flat patch over 10..90 with c(row 0, col 0) red, c(0, 3) green, c(3, 0) blue, c(3, 3) white.</summary>
function FlatPatchData(Tensor: Boolean): TBytes;
var
  P: TBitPacker;
  I: Integer;
begin
  P := TBitPacker.Create;
  try
    P.Put(0, 8);
    for I := 0 to 11 do
      PutGridPoint(P, BorderRC[I, 0], BorderRC[I, 1], 10, 10, 90, 90);
    if Tensor then
      for I := 0 to 3 do
        PutGridPoint(P, InnerRC[I, 0], InnerRC[I, 1], 10, 10, 90, 90);
    // Colour order c00, c03, c33, c30 = corners (0,0), (3,0), (3,3), (0,3)
    PutColor(P, Red);
    PutColor(P, Blue);
    PutColor(P, White);
    PutColor(P, Green);
    Result := P.Bytes;
  finally
    P.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ Tests                                                                        }
{ ---------------------------------------------------------------------------- }

procedure TPdfMeshShadingTests.SetupFixture;
begin
  PdfNull;
end;

procedure TPdfMeshShadingTests.Type4_TwoTriangles;
var
  Sh: TPdfShading;
  S: ISkSurface;
  U, V: Double;
begin
  Sh := MakeShading(Format(StdDict, [4, '']), SquareType4Data);
  try
    Assert.IsTrue(Sh.IsMesh, 'IsMesh');
    Assert.AreEqual(2, Sh.TriangleCount);
    CheckBounds(Sh, 10, 10, 90, 90);
    S := Draw(Sh);
    CheckPixel(S, 10, 10, Red, 8, 'red corner');
    CheckPixel(S, 89, 10, Green, 8, 'green corner');
    CheckPixel(S, 10, 89, Blue, 8, 'blue corner');
    CheckPixel(S, 89, 89, White, 8, 'white corner');
    // Inside triangle 1: P = A + U (B - A) + V (C - A) at the pixel centre
    U := (30.5 - 10) / 80;
    V := (30.5 - 10) / 80;
    CheckPixel(S, 30, 30, Mix3(Red, Green, Blue, 1 - U - V, U, V), 4, 'triangle 1');
    CheckPixel(S, 60, 25, TriColor(60, 25, 10, 10, 90, 10, 10, 90, Red, Green, Blue), 4, 'triangle 1b');
    // Inside triangle 2 (green (90,10), blue (10,90), white (90,90))
    CheckPixel(S, 70, 70, TriColor(70, 70, 90, 10, 10, 90, 90, 90, Green, Blue, White), 4, 'triangle 2');
    CheckPixel(S, 85, 40, TriColor(85, 40, 90, 10, 10, 90, 90, 90, Green, Blue, White), 4, 'triangle 2b');
    // Nothing outside the mesh
    CheckPixel(S, 5, 5, White, 0, 'outside');
    CheckPixel(S, 95, 50, White, 0, 'outside');
    CheckPixel(S, 50, 95, White, 0, 'outside');
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.Type4_FlagTwoFan;
var
  Sh: TPdfShading;
  P: TBitPacker;
  S: ISkSurface;
begin
  // Fan around (50,50): triangle (50,50) (10,10) (90,10), then flag 2 adds (90,90) sharing vertices a and c
  P := TBitPacker.Create;
  try
    PutVertex(P, 0, 50, 50, White);
    PutVertex(P, 0, 10, 10, Red);
    PutVertex(P, 0, 90, 10, Green);
    PutVertex(P, 2, 90, 90, Blue);
    PutVertex(P, 2, 10, 90, Black);
    Sh := MakeShading(Format(StdDict, [4, '']), P.Bytes);
  finally
    P.Free;
  end;
  try
    Assert.AreEqual(3, Sh.TriangleCount);
    CheckBounds(Sh, 10, 10, 90, 90);
    S := Draw(Sh);
    CheckPixel(S, 50, 20, TriColor(50, 20, 50, 50, 10, 10, 90, 10, White, Red, Green), 4, 'top triangle');
    CheckPixel(S, 80, 50, TriColor(80, 50, 50, 50, 90, 10, 90, 90, White, Green, Blue), 4, 'right triangle');
    CheckPixel(S, 50, 80, TriColor(50, 80, 50, 50, 90, 90, 10, 90, White, Blue, Black), 4, 'bottom triangle');
    // The left triangle (50,50) (10,10) (10,90) is not part of the fan
    CheckPixel(S, 15, 50, White, 0, 'left gap');
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.Type4_Alpha;
var
  Sh: TPdfShading;
  S: ISkSurface;
begin
  Sh := MakeShading(Format(StdDict, [4, '']), SquareType4Data);
  try
    S := Draw(Sh, 0.5);
    // Red at half coverage over white
    CheckPixel(S, 10, 10, RGB(1, 0.5, 0.5), 8, 'red corner at 0.5');
    CheckPixel(S, 10, 89, RGB(0.5, 0.5, 1), 8, 'blue corner at 0.5');
    CheckPixel(S, 5, 5, White, 0, 'outside');
    // Alpha 0 draws nothing
    S := Draw(Sh, 0);
    CheckPixel(S, 10, 10, White, 0, 'alpha 0');
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.Type4_Function;
var
  Sh: TPdfShading;
  P: TBitPacker;
  S: ISkSurface;
begin
  // One value t per vertex through a 1-in, 3-out type 2 function red -> blue
  P := TBitPacker.Create;
  try
    P.Put(0, 8); PutPoint(P, 10, 10); P.Put(0, 16);
    P.Put(0, 8); PutPoint(P, 90, 10); P.Put(65535, 16);
    P.Put(0, 8); PutPoint(P, 10, 90); P.Put(0, 16);
    Sh := MakeShading('<< /ShadingType 4 /ColorSpace /DeviceRGB /BitsPerCoordinate 32 /BitsPerComponent 16 ' +
      '/BitsPerFlag 8 /Decode [0 100 0 100 0 1] ' +
      '/Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> >>', P.Bytes);
  finally
    P.Free;
  end;
  try
    Assert.IsTrue(Sh.IsMesh);
    Assert.IsTrue(Sh.TriangleCount >= 1);
    CheckBounds(Sh, 10, 10, 90, 90);
    S := Draw(Sh);
    CheckPixel(S, 10, 10, Red, 8, 't=0 corner');
    CheckPixel(S, 87, 11, RGB(1 - 77.5 / 80, 0, 77.5 / 80), 4, 't=1 corner');
    CheckPixel(S, 11, 87, Red, 8, 't=0 corner');
    // t = (x - 10) / 80
    CheckPixel(S, 50, 30, RGB(1 - 40.5 / 80, 0, 40.5 / 80), 4, 'middle');
    CheckPixel(S, 80, 80, White, 0, 'outside');
    // Alpha on the lookup-table path
    S := Draw(Sh, 0.5);
    CheckPixel(S, 10, 10, RGB(1, 0.5, 0.5), 8, 't=0 corner at 0.5');
    CheckPixel(S, 50, 30, RGB(0.5 + 0.5 * (1 - 40.5 / 80), 0.5, 0.5 + 0.5 * 40.5 / 80), 6, 'middle at 0.5');
    CheckPixel(S, 80, 80, White, 0, 'outside at 0.5');
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.Type4_FunctionNonLinear;
var
  Sh: TPdfShading;
  P: TBitPacker;
  S: ISkSurface;
  T: Double;
begin
  // N 2: the colour is quadratic in t, so t (not the colour) must be interpolated across the triangle
  P := TBitPacker.Create;
  try
    P.Put(0, 8); PutPoint(P, 10, 10); P.Put(0, 16);
    P.Put(0, 8); PutPoint(P, 90, 10); P.Put(65535, 16);
    P.Put(0, 8); PutPoint(P, 10, 90); P.Put(0, 16);
    Sh := MakeShading('<< /ShadingType 4 /ColorSpace /DeviceRGB /BitsPerCoordinate 32 /BitsPerComponent 16 ' +
      '/BitsPerFlag 8 /Decode [0 100 0 100 0 1] ' +
      '/Function << /FunctionType 2 /Domain [0 1] /C0 [0 0 0] /C1 [1 1 1] /N 2 >> >>', P.Bytes);
  finally
    P.Free;
  end;
  try
    Assert.AreEqual(1, Sh.TriangleCount, 'no geometric subdivision: t is interpolated as a texture coordinate');
    CheckBounds(Sh, 10, 10, 90, 90);
    S := Draw(Sh);
    T := 40.5 / 80;
    CheckPixel(S, 50, 30, RGB(T * T, T * T, T * T), 4, 't = 0.5');
    T := 60.5 / 80;
    CheckPixel(S, 70, 15, RGB(T * T, T * T, T * T), 4, 't = 0.75');
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.Type4_PaddedVertices;
var
  Sh: TPdfShading;
  P: TBitPacker;
  Data: TBytes;

  procedure V(Flag, X, Y: Integer; R, G, B: Integer);
  begin
    // 2 + 4 + 4 + 3 x 1 = 13 bits, padded to a 2-byte boundary
    P.Put(Flag, 2);
    P.Put(X, 4);
    P.Put(Y, 4);
    P.Put(R, 1);
    P.Put(G, 1);
    P.Put(B, 1);
    P.Align;
  end;

var
  S: ISkSurface;
begin
  P := TBitPacker.Create;
  try
    V(0, 0, 0, 1, 0, 0);
    V(0, 15, 0, 0, 1, 0);
    V(0, 0, 15, 0, 0, 1);
    V(1, 15, 15, 1, 1, 1);
    Data := P.Bytes;
  finally
    P.Free;
  end;
  Assert.AreEqual(8, Integer(Length(Data)), 'packed size');
  Sh := MakeShading('<< /ShadingType 4 /ColorSpace /DeviceRGB /BitsPerCoordinate 4 /BitsPerComponent 1 ' +
    '/BitsPerFlag 2 /Decode [10 90 10 90 0 1 0 1 0 1] >>', Data);
  try
    Assert.AreEqual(2, Sh.TriangleCount);
    CheckBounds(Sh, 10, 10, 90, 90);
    S := Draw(Sh);
    CheckPixel(S, 10, 10, Red, 8, 'red');
    CheckPixel(S, 89, 10, Green, 8, 'green');
    CheckPixel(S, 10, 89, Blue, 8, 'blue');
    CheckPixel(S, 89, 89, White, 8, 'white');
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.Type4_Matrix;
var
  Sh: TPdfShading;
  S: ISkSurface;
begin
  // LocalMatrix maps shading space to the canvas: scale by 0.5 and move by 50
  Sh := MakeShading(Format(StdDict, [4, '']), SquareType4Data);
  try
    S := NewSurface;
    Sh.DrawMesh(S.Canvas, TMatrix.CreateScaling(0.5, 0.5) * TMatrix.CreateTranslation(50, 50), 1, nil);
    CheckPixel(S, 55, 55, Red, 12, 'red corner moved');
    CheckPixel(S, 94, 94, White, 12, 'white corner moved');
    CheckPixel(S, 30, 30, White, 0, 'old position empty');
    // Blender: multiply over a grey background halves the colours
    S := TSkSurface.MakeRaster(100, 100);
    S.Canvas.Clear($FF808080);
    Sh.DrawMesh(S.Canvas, TMatrix.Identity, 1, TSkBlender.MakeMode(TSkBlendMode.Multiply));
    CheckPixel(S, 10, 10, RGB(128 / 255, 0, 0), 8, 'multiply');
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.Type5_Lattice;
var
  Sh: TPdfShading;
  P: TBitPacker;
  S: ISkSurface;
begin
  P := TBitPacker.Create;
  try
    PutPoint(P, 10, 10); PutColor(P, Red);
    PutPoint(P, 90, 10); PutColor(P, Green);
    PutPoint(P, 10, 90); PutColor(P, Blue);
    PutPoint(P, 90, 90); PutColor(P, White);
    Sh := MakeShading('<< /ShadingType 5 /ColorSpace /DeviceRGB /BitsPerCoordinate 32 /BitsPerComponent 16 ' +
      '/VerticesPerRow 2 /Decode [0 100 0 100 0 1 0 1 0 1] >>', P.Bytes);
  finally
    P.Free;
  end;
  try
    Assert.IsTrue(Sh.IsMesh);
    Assert.AreEqual(2, Sh.TriangleCount);
    CheckBounds(Sh, 10, 10, 90, 90);
    S := Draw(Sh);
    CheckPixel(S, 10, 10, Red, 8, 'red');
    CheckPixel(S, 89, 10, Green, 8, 'green');
    CheckPixel(S, 10, 89, Blue, 8, 'blue');
    CheckPixel(S, 89, 89, White, 8, 'white');
    CheckPixel(S, 30, 30, TriColor(30, 30, 10, 10, 90, 10, 10, 90, Red, Green, Blue), 4, 'cell middle');
    CheckPixel(S, 70, 70, TriColor(70, 70, 90, 90, 90, 10, 10, 90, White, Green, Blue), 4, 'second triangle');
    CheckPixel(S, 95, 95, White, 0, 'outside');
    CheckPixel(S, 50, 5, White, 0, 'outside');
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.Type6_CoonsPatch;
var
  Sh: TPdfShading;
  S: ISkSurface;
begin
  Sh := MakeShading(Format(StdDict, [6, '']), FlatPatchData(False));
  try
    Assert.IsTrue(Sh.IsMesh);
    // One patch covering the whole mesh: 20 x 20 cells, 2 triangles each
    Assert.AreEqual(800, Sh.TriangleCount);
    CheckBounds(Sh, 10, 10, 90, 90);
    S := Draw(Sh);
    CheckPixel(S, 10, 10, Red, 8, 'red');
    CheckPixel(S, 89, 10, Green, 8, 'green');
    CheckPixel(S, 10, 89, Blue, 8, 'blue');
    CheckPixel(S, 89, 89, White, 8, 'white');
    CheckPixel(S, 50, 50, Bilinear(Red, Green, Blue, White, 40.5 / 80, 40.5 / 80), 4, 'centre');
    CheckPixel(S, 30, 70, Bilinear(Red, Green, Blue, White, 20.5 / 80, 60.5 / 80), 4, 'lower left');
    CheckPixel(S, 5, 50, White, 0, 'outside');
    CheckPixel(S, 95, 95, White, 0, 'outside');
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.Type6_FlagContinuation;
var
  Sh: TPdfShading;
  P: TBitPacker;
  S: ISkSurface;
  I, R, C: Integer;
const
  // Order of the 8 new border points of a continued patch, as (row, col)
  ContRC: array[0..7, 0..1] of Integer = ((3, 1), (3, 2), (3, 3), (2, 3), (1, 3), (0, 3), (0, 2), (0, 1));
begin
  P := TBitPacker.Create;
  try
    // Patch 1 over x 10..90, y 10..50: point (row, col) = (10 + 80 col / 3, 10 + 40 row / 3)
    P.Put(0, 8);
    for I := 0 to 11 do
      PutGridPoint(P, BorderRC[I, 0], BorderRC[I, 1], 10, 10, 90, 50);
    PutColor(P, Red);   // (0,0) at (10,10)
    PutColor(P, Blue);  // (3,0) at (10,50)
    PutColor(P, White); // (3,3) at (90,50)
    PutColor(P, Green); // (0,3) at (90,10)
    // Patch 2 (flag 1): its column 0 is patch 1's row 3 (y = 50); point (row, col) = (10 + 80 row / 3, 50 + 40 col / 3)
    P.Put(1, 8);
    for I := 0 to 7 do
    begin
      R := ContRC[I, 0];
      C := ContRC[I, 1];
      PutPoint(P, 10 + 80 * R / 3, 50 + 40 * C / 3);
    end;
    PutColor(P, Black); // c33 = (3,3) at (90,90)
    PutColor(P, Red);   // c30 = (0,3) at (10,90)
    Sh := MakeShading(Format(StdDict, [6, '']), P.Bytes);
  finally
    P.Free;
  end;
  try
    Assert.AreEqual(1600, Sh.TriangleCount, 'two patches with the common split of 20 x 20 cells');
    CheckBounds(Sh, 10, 10, 90, 90);
    S := Draw(Sh);
    CheckPixel(S, 10, 10, Red, 8, 'patch 1 red');
    CheckPixel(S, 89, 10, Green, 8, 'patch 1 green');
    CheckPixel(S, 10, 50, Blue, 8, 'shared blue');
    CheckPixel(S, 89, 50, White, 8, 'shared white');
    CheckPixel(S, 10, 89, Red, 8, 'patch 2 red');
    CheckPixel(S, 89, 89, Black, 8, 'patch 2 black');
    // Patch 2 centre (50.5, 70.5): u along x from blue/red side, v along y from the shared edge
    CheckPixel(S, 50, 70, Bilinear(Blue, White, Red, Black, 40.5 / 80, 20.5 / 40), 5, 'patch 2 centre');
    CheckPixel(S, 50, 5, White, 0, 'outside');
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.Type6_CurvedEdge;
var
  Sh: TPdfShading;
  P: TBitPacker;
  S: ISkSurface;
  I, R, C: Integer;
  Y: Double;
begin
  // Patch over y 20..90 whose top edge control points (row 0, col 1 and 2) are pulled up to y = 0: the top edge
  // is a cubic Bezier that bulges up to y = 5 in the middle.
  P := TBitPacker.Create;
  try
    P.Put(0, 8);
    for I := 0 to 11 do
    begin
      R := BorderRC[I, 0];
      C := BorderRC[I, 1];
      Y := 20 + 70 * R / 3;
      if (R = 0) and (C in [1, 2]) then
        Y := 0;
      PutPoint(P, 10 + 80 * C / 3, Y);
    end;
    PutColor(P, Red);
    PutColor(P, Red);
    PutColor(P, Red);
    PutColor(P, Red);
    Sh := MakeShading(Format(StdDict, [6, '']), P.Bytes);
  finally
    P.Free;
  end;
  try
    // Bezier top edge: y(0.5) = 20 * 1/8 + 0 * 3/8 + 0 * 3/8 + 20 * 1/8 = 5
    CheckBounds(Sh, 10, 5, 90, 90, 0.1);
    S := Draw(Sh);
    CheckPixel(S, 50, 7, Red, 8, 'bulge painted');
    CheckPixel(S, 50, 3, White, 0, 'above the bulge');
    CheckPixel(S, 12, 15, White, 0, 'above the corner');
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.Type7_TensorPatch;
var
  Sh: TPdfShading;
  S: ISkSurface;
begin
  Sh := MakeShading(Format(StdDict, [7, '']), FlatPatchData(True));
  try
    Assert.IsTrue(Sh.IsMesh);
    Assert.AreEqual(800, Sh.TriangleCount);
    CheckBounds(Sh, 10, 10, 90, 90);
    S := Draw(Sh);
    CheckPixel(S, 10, 10, Red, 8, 'red');
    CheckPixel(S, 89, 10, Green, 8, 'green');
    CheckPixel(S, 10, 89, Blue, 8, 'blue');
    CheckPixel(S, 89, 89, White, 8, 'white');
    CheckPixel(S, 50, 50, Bilinear(Red, Green, Blue, White, 40.5 / 80, 40.5 / 80), 4, 'centre');
    CheckPixel(S, 70, 30, Bilinear(Red, Green, Blue, White, 60.5 / 80, 20.5 / 80), 4, 'upper right');
    CheckPixel(S, 95, 50, White, 0, 'outside');
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.Truncated_FewerTriangles;
var
  Data, Cut: TBytes;
  Sh: TPdfShading;
  S: ISkSurface;
  Len, Expected: Integer;
begin
  // Type 4: 4 vertices of 1 + 8 + 6 = 15 bytes
  Data := SquareType4Data;
  Assert.AreEqual(60, Integer(Length(Data)));
  for Len := 0 to Length(Data) do
  begin
    Cut := Copy(Data, 0, Len);
    if Len >= 60 then
      Expected := 2
    else if Len >= 45 then
      Expected := 1
    else
      Expected := 0;
    Sh := MakeShading(Format(StdDict, [4, '']), Cut);
    try
      Assert.AreEqual(Expected, Sh.TriangleCount, Format('type 4 cut at %d', [Len]));
      S := Draw(Sh);
    finally
      Sh.Free;
    end;
  end;
  // Type 6: a truncated patch is dropped
  Data := FlatPatchData(False);
  for Len := 0 to Length(Data) - 1 do
  begin
    Sh := MakeShading(Format(StdDict, [6, '']), Copy(Data, 0, Len));
    try
      Assert.AreEqual(0, Sh.TriangleCount, Format('type 6 cut at %d', [Len]));
      S := Draw(Sh);
    finally
      Sh.Free;
    end;
  end;
  // Type 7 with one full patch plus a partial second one
  Data := FlatPatchData(True);
  Data := Data + Copy(Data, 0, 50);
  Sh := MakeShading(Format(StdDict, [7, '']), Data);
  try
    Assert.AreEqual(800, Sh.TriangleCount, 'type 7 with a partial second patch');
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.Garbage_NeverRaises;
var
  T, Iter, I: Integer;
  Data: TBytes;
  Sh: TPdfShading;
  S: ISkSurface;
begin
  RandSeed := 4711;
  S := NewSurface;
  for T := 4 to 7 do
    for Iter := 0 to 49 do
    begin
      SetLength(Data, Random(400));
      for I := 0 to High(Data) do
        Data[I] := Random(256);
      if (Iter mod 2 = 0) and (Length(Data) > 0) then
        Data[0] := Random(4); // plausible first flag
      Sh := MakeShading(Format(StdDict, [T, '/VerticesPerRow 3']), Data);
      try
        Sh.TriangleCount;
        Sh.MeshBounds;
        Sh.DrawMesh(S.Canvas, TMatrix.Identity, 1, nil);
        Sh.AverageColor;
      finally
        Sh.Free;
      end;
      // Odd bit widths and a function on top
      Sh := MakeShading(Format('<< /ShadingType %d /ColorSpace /DeviceCMYK /BitsPerCoordinate 7 /BitsPerComponent 3 ' +
        '/BitsPerFlag 2 /VerticesPerRow 2 /Decode [0 100 0 100 0 1] ' +
        '/Function << /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [1 0 1 0] /N 3 >> >>', [T]), Data);
      try
        Sh.DrawMesh(S.Canvas, TMatrix.Identity, 0.5, nil);
      finally
        Sh.Free;
      end;
    end;
  Assert.Pass;
end;

procedure TPdfMeshShadingTests.EmptyStream_NoOp;
var
  T: Integer;
  Sh: TPdfShading;
  S: ISkSurface;
  B: TRectF;
begin
  for T := 4 to 7 do
  begin
    Sh := MakeShading(Format(StdDict, [T, '/VerticesPerRow 2']), nil);
    try
      Assert.IsTrue(Sh.IsMesh, 'IsMesh');
      Assert.AreEqual(0, Sh.TriangleCount);
      B := Sh.MeshBounds;
      Assert.IsTrue(B.IsEmpty, 'empty bounds');
      S := NewSurface;
      Sh.DrawMesh(S.Canvas, TMatrix.Identity, 1, nil);
      CheckPixel(S, 50, 50, White, 0, 'nothing drawn');
    finally
      Sh.Free;
    end;
  end;
end;

procedure TPdfMeshShadingTests.SupportFlags;
var
  T: Integer;
  Sh: TPdfShading;
begin
  for T := 4 to 7 do
  begin
    Sh := MakeShading(Format(StdDict, [T, '/VerticesPerRow 2']), SquareType4Data);
    try
      Assert.IsTrue(Sh.IsSupported, 'IsSupported');
      Assert.IsNull(Sh.MakeShader(TMatrix.Identity), 'MakeShader');
      Assert.IsTrue(Sh.IsMesh, 'IsMesh');
    finally
      Sh.Free;
    end;
  end;
  Sh := TPdfShading.Parse(PdfParseObject('<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0] ' +
    '/Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> >>'), nil, nil);
  try
    Assert.IsNotNull(Sh);
    Assert.IsTrue(Sh.IsSupported);
    Assert.IsFalse(Sh.IsMesh);
    Assert.AreEqual(0, Sh.TriangleCount);
    Assert.IsNotNull(Sh.MakeShader(TMatrix.Identity));
    Sh.DrawMesh(NewSurface.Canvas, TMatrix.Identity, 1, nil);
  finally
    Sh.Free;
  end;
  Sh := TPdfShading.Parse(PdfParseObject('<< /ShadingType 3 /ColorSpace /DeviceGray /Coords [50 50 0 50 50 50] ' +
    '/Function << /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >> >>'), nil, nil);
  try
    Assert.IsFalse(Sh.IsMesh);
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.InvalidParameters;

  procedure Check(const Source: string; const Data: TBytes; const Msg: string);
  var
    Sh: TPdfShading;
  begin
    Sh := MakeShading(Source, Data);
    try
      Assert.IsFalse(Sh.IsMesh, Msg);
      Assert.AreEqual(0, Sh.TriangleCount, Msg);
      Sh.DrawMesh(NewSurface.Canvas, TMatrix.Identity, 1, nil);
    finally
      Sh.Free;
    end;
  end;

var
  Sh: TPdfShading;
begin
  Check('<< /ShadingType 5 /ColorSpace /DeviceRGB /BitsPerCoordinate 32 /BitsPerComponent 16 ' +
    '/VerticesPerRow 1 /Decode [0 100 0 100 0 1 0 1 0 1] >>', SquareType4Data, 'VerticesPerRow 1');
  Check('<< /ShadingType 4 /ColorSpace /DeviceRGB /BitsPerComponent 16 /BitsPerFlag 8 ' +
    '/Decode [0 100 0 100 0 1 0 1 0 1] >>', SquareType4Data, 'no BitsPerCoordinate');
  Check('<< /ShadingType 4 /ColorSpace /DeviceRGB /BitsPerCoordinate 40 /BitsPerComponent 16 /BitsPerFlag 8 ' +
    '/Decode [0 100 0 100 0 1 0 1 0 1] >>', SquareType4Data, 'BitsPerCoordinate 40');
  Check('<< /ShadingType 4 /ColorSpace /DeviceRGB /BitsPerCoordinate 32 /BitsPerComponent 16 /BitsPerFlag 8 ' +
    '/Decode [0 100] >>', SquareType4Data, 'short Decode');
  // A mesh shading that is a dictionary instead of a stream
  Sh := TPdfShading.Parse(PdfParseObject('<< /ShadingType 4 /ColorSpace /DeviceRGB /BitsPerCoordinate 32 ' +
    '/BitsPerComponent 16 /BitsPerFlag 8 /Decode [0 100 0 100 0 1 0 1 0 1] >>'), nil, nil);
  try
    Assert.IsNotNull(Sh);
    Assert.IsFalse(Sh.IsMesh, 'dictionary');
    Assert.AreEqual(0, Sh.TriangleCount);
  finally
    Sh.Free;
  end;
  // Missing colour ranges in /Decode default to [0 1]
  Sh := MakeShading('<< /ShadingType 4 /ColorSpace /DeviceRGB /BitsPerCoordinate 32 /BitsPerComponent 16 ' +
    '/BitsPerFlag 8 /Decode [0 100 0 100] >>', SquareType4Data);
  try
    Assert.IsTrue(Sh.IsMesh);
    Assert.AreEqual(2, Sh.TriangleCount);
    CheckPixel(Draw(Sh), 10, 10, Red, 8, 'default ranges');
  finally
    Sh.Free;
  end;
end;

procedure TPdfMeshShadingTests.AverageColorOfMesh;
var
  Sh: TPdfShading;
  C: TAlphaColor;
begin
  // Vertices red, green, blue, green, blue, white: average (2, 3, 3) / 6 * 255
  Sh := MakeShading(Format(StdDict, [4, '']), SquareType4Data);
  try
    C := Sh.AverageColor;
    Assert.AreEqual(Integer(2 * 255 div 6), Integer((C shr 16) and $FF), 'R');
    Assert.AreEqual(Integer(3 * 255 div 6), Integer((C shr 8) and $FF), 'G');
    Assert.AreEqual(Integer(3 * 255 div 6), Integer(C and $FF), 'B');
  finally
    Sh.Free;
  end;
end;

{ Corpus }

function CorpusDir: string;
var
  Env, D: string;
begin
  Env := GetEnvironmentVariable('PDF_CORPUS_DIRS');
  for D in Env.Split([';']) do
    if (Trim(D) <> '') and TFile.Exists(TPath.Combine(Trim(D), 'mesh_shading_empty.pdf')) then
      Exit(Trim(D));
  Result := TPath.Combine(TPath.GetTempPath, 'claude\pdfjs-corpus\pdfjs\test\pdfs');
  if not TDirectory.Exists(Result) then
    Result := '';
end;

type
  TFoundShading = record
    Obj: IPdfObject;
    Resources: IPdfDictionary;
    Name: string;
  end;

/// <summary>Mesh shadings (types 4-7) reachable from Resources: /Shading, shading patterns and form XObjects.</summary>
procedure CollectMeshShadings(const Doc: TPdfDocument; const Resources: IPdfDictionary; Depth: Integer;
  const Prefix: string; List: TList<TFoundShading>; Seen: TList<IPdfDictionary>);

  procedure Consider(const Raw: IPdfObject; const Name: string);
  var
    D: IPdfDictionary;
    F: TFoundShading;
    T: Int64;
  begin
    D := PdfAsDictionary(Doc.Resolve(Raw));
    if D = nil then
      Exit;
    T := D.GetInteger('ShadingType', 0);
    if (T >= 4) and (T <= 7) then
    begin
      F.Obj := Raw;
      F.Resources := Resources;
      F.Name := Name;
      List.Add(F);
    end;
  end;

var
  Dict, Pat, XObj: IPdfDictionary;
  K: string;
  S: IPdfStream;
begin
  if (Resources = nil) or (Depth > 4) or Seen.Contains(Resources) then
    Exit;
  Seen.Add(Resources);
  Dict := Resources.GetDictionary('Shading');
  if Dict <> nil then
    for K in Dict.Keys do
      Consider(Dict.GetRaw(K), Prefix + 'sh:' + K);
  Dict := Resources.GetDictionary('Pattern');
  if Dict <> nil then
    for K in Dict.Keys do
    begin
      Pat := PdfAsDictionary(Doc.Resolve(Dict.GetRaw(K)));
      if (Pat <> nil) and (Pat.GetInteger('PatternType', 0) = 2) then
        Consider(Pat.GetRaw('Shading'), Prefix + 'pat:' + K)
      else if Pat <> nil then
      begin
        XObj := Pat.GetDictionary('Resources');
        CollectMeshShadings(Doc, XObj, Depth + 1, Prefix + K + '/', List, Seen);
      end;
    end;
  Dict := Resources.GetDictionary('XObject');
  if Dict <> nil then
    for K in Dict.Keys do
    begin
      S := PdfAsStream(Doc.Resolve(Dict.GetRaw(K)));
      if (S <> nil) and (S.Dict.GetName('Subtype') = 'Form') then
        CollectMeshShadings(Doc, S.Dict.GetDictionary('Resources'), Depth + 1, Prefix + K + '/', List, Seen);
    end;
end;

procedure TPdfMeshShadingTests.Corpus_MeshShadings;
const
  Files: array[0..14] of string = ('mesh_shading_empty', 'issue2948', 'issue17848', 'issue6231_1',
    'coons-allflags-withfunction', 'tensor-allflags-withfunction', 'issue18816', 'personwithdog',
    'bug1703683_page2_reduced', 'issue13520', 'issue13372', 'issue6113', 'issue15367', 'issue6231_2', 'issue5446');
  MaxPages = 3;
var
  Dir, FileName: string;
  Doc: TPdfDocument;
  Found: TList<TFoundShading>;
  Seen: TList<IPdfDictionary>;
  F: TFoundShading;
  Sh: TPdfShading;
  S: ISkSurface;
  B: TRectF;
  M: TMatrix;
  Scale: Single;
  I, PageIndex, Meshes, Total: Integer;
  Name: string;
begin
  Dir := CorpusDir;
  if Dir = '' then
    Assert.Pass('pdf.js corpus not found');
  Meshes := 0;
  Total := 0;
  S := TSkSurface.MakeRaster(200, 200);
  for Name in Files do
  begin
    FileName := TPath.Combine(Dir, Name + '.pdf');
    if not TFile.Exists(FileName) then
      Continue;
    Doc := TPdfDocument.Create;
    Found := TList<TFoundShading>.Create;
    Seen := TList<IPdfDictionary>.Create;
    try
      try
        Doc.LoadFromFile(FileName);
      except
        on E: Exception do
        begin
          TDUnitX.CurrentRunner.Log(TLogLevel.Information, Format('%s: open failed (%s)', [Name, E.Message]));
          Continue;
        end;
      end;
      for PageIndex := 0 to Min(Doc.PageCount, MaxPages) - 1 do
        CollectMeshShadings(Doc, Doc.Pages[PageIndex].Resources, 0, Format('p%d:', [PageIndex + 1]), Found, Seen);
      for I := 0 to Found.Count - 1 do
      begin
        F := Found[I];
        Sh := TPdfShading.Parse(F.Obj, F.Resources, Doc.Resolver);
        if Sh = nil then
        begin
          TDUnitX.CurrentRunner.Log(TLogLevel.Information, Format('%s %s: Parse = nil', [Name, F.Name]));
          Continue;
        end;
        try
          B := Sh.MeshBounds;
          // Fit the mesh into the scratch surface
          if (B.Width > 0) and (B.Height > 0) then
          begin
            Scale := Min(200 / B.Width, 200 / B.Height);
            M := TMatrix.CreateTranslation(-B.Left, -B.Top) * TMatrix.CreateScaling(Scale, Scale);
          end
          else
            M := TMatrix.Identity;
          S.Canvas.Clear(TAlphaColorRec.White);
          Sh.DrawMesh(S.Canvas, M, 1, nil);
          Inc(Meshes);
          Inc(Total, Sh.TriangleCount);
          TDUnitX.CurrentRunner.Log(TLogLevel.Information, Format('%s %s: type %d, IsMesh %s, %d triangles, ' +
            'bounds %.1f %.1f %.1f %.1f', [Name, F.Name, Sh.ShadingType, BoolToStr(Sh.IsMesh, True), Sh.TriangleCount,
            B.Left, B.Top, B.Right, B.Bottom]));
        finally
          Sh.Free;
        end;
      end;
    finally
      Seen.Free;
      Found.Free;
      Doc.Free;
    end;
  end;
  TDUnitX.CurrentRunner.Log(TLogLevel.Information, Format('corpus: %d mesh shadings, %d triangles', [Meshes, Total]));
  Assert.IsTrue(Meshes > 0, 'no mesh shadings found in the corpus');
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfMeshShadingTests);

end.
