{*******************************************************************************
  Pdf.Render.Shading
  Shadings (ISO 32000-1 §8.7.4.5): type 1 (function-based), 2 (axial) and
  3 (radial) as Skia shaders; mesh shadings type 4 (free-form triangles),
  5 (lattice), 6 (Coons patches) and 7 (tensor-product patches) as Gouraud-
  shaded triangles drawn with ISkCanvas.DrawVertices. Patches are subdivided
  into a grid of triangles like pdf.js does.
  Portions derived from pdf.js (Mozilla, Apache License 2.0).
*******************************************************************************}
unit Pdf.Render.Shading;

interface

uses
  System.SysUtils, System.Math, System.Types, System.UITypes, System.Math.Vectors,
  System.Generics.Collections, System.Skia,
  Pdf.Core.Types, Pdf.Core.Objects, Pdf.Render.Functions, Pdf.Render.ColorSpaces;

type
  TPdfShading = class
  private type
    TMeshState = (msNone, msPending, msReady, msInvalid);
  private
    FShadingType: Integer;
    FColorSpace: TPdfColorSpace;
    FFunctions: TArray<TPdfFunction>;
    FCoords: TArray<Double>;
    FDomain: TArray<Double>;
    FExtendStart, FExtendEnd: Boolean;
    FHasBBox: Boolean;
    FBBox: TPdfRectangle;
    FHasBackground: Boolean;
    FBackground: TAlphaColor;
    FMatrix: TPdfMatrix; // type 1
    // Mesh shadings (types 4-7): parameters read by Parse, data decoded lazily by EnsureMesh
    FMeshState: TMeshState;
    FMeshStream: IPdfStream;
    FBitsPerCoordinate: Integer;
    FBitsPerComponent: Integer;
    FBitsPerFlag: Integer;
    FVerticesPerRow: Integer;
    FMeshDecode: TArray<Double>;
    FTriPositions: TArray<TPointF>;
    FTriColors: TArray<TAlphaColor>;
    FTriTexCoords: TArray<TPointF>; // with /Function: t as x in the lookup table
    FLutColors: TArray<TAlphaColor>;
    FLutShader: ISkShader;
    FTriCount: Integer;
    FMeshBounds: TRectF;
    function ColorAt(T: Double): TAlphaColor;
    procedure BuildStops(out Colors: TArray<TAlphaColor>; out Positions: TArray<Single>);
    function MakeFunctionShader(const LocalMatrix: TMatrix): ISkShader;
    procedure ParseMeshParameters(const Dict: IPdfDictionary; const Obj: IPdfObject);
    /// <summary>Decodes the mesh data on first use; never raises.</summary>
    procedure EnsureMesh;
  public
    /// <summary>Parses a shading dictionary or stream; nil when invalid. The caller owns the result.
    /// For mesh shadings only the parameters are read here; the stream data is decoded on first use.</summary>
    class function Parse(const Obj: IPdfObject; const Resources: IPdfDictionary; const Resolver: IPdfResolver): TPdfShading; static;
    destructor Destroy; override;
    /// <summary>Builds the Skia shader in shading space; LocalMatrix maps shading space to the canvas.
    /// Returns nil for mesh types (4-7): draw those with DrawMesh.</summary>
    function MakeShader(const LocalMatrix: TMatrix): ISkShader;
    /// <summary>True for types 1-7 (types 4-7 are drawn with DrawMesh instead of MakeShader).</summary>
    function IsSupported: Boolean;
    /// <summary>True for types 4-7 after a successful parse of the mesh data (vertices available, possibly zero
    /// triangles). False for types 1-3 and for mesh shadings with invalid parameters (no stream, bad bit counts,
    /// no /Decode, /VerticesPerRow &lt; 2).</summary>
    function IsMesh: Boolean;
    /// <summary>Draws the mesh triangles on Canvas: LocalMatrix maps shading space to the canvas (same meaning as in
    /// MakeShader). Alpha is applied to every vertex colour; Blender is the PDF blend mode already converted by the
    /// caller (nil = source-over). /BBox and /Background are left to the caller. No-op when there are no triangles.</summary>
    procedure DrawMesh(const Canvas: ISkCanvas; const LocalMatrix: TMatrix; Alpha: Single; const Blender: ISkBlender);
    /// <summary>Number of triangles after decoding and subdivision (0 for types 1-3).</summary>
    function TriangleCount: Integer;
    /// <summary>Bounding box of the mesh triangles in shading space (empty when there are none).</summary>
    function MeshBounds: TRectF;
    /// <summary>Average colour: over the function domain when the shading has a function, otherwise over the mesh
    /// vertices (used as a fallback for mesh shadings).</summary>
    function AverageColor: TAlphaColor;
    property ShadingType: Integer read FShadingType;
    property ColorSpace: TPdfColorSpace read FColorSpace;
    property HasBBox: Boolean read FHasBBox;
    property BBox: TPdfRectangle read FBBox;
    property HasBackground: Boolean read FHasBackground;
    property Background: TAlphaColor read FBackground;
    property Coords: TArray<Double> read FCoords;
  end;

function PdfMatrixToSk(const M: TPdfMatrix): TMatrix;

implementation

const
  GradientSamples = 64;
  /// <summary>Patch subdivision per direction (pdf.js MIN/MAX_SPLIT_PATCH_CHUNKS_AMOUNT, TRIANGLE_DENSITY). Unlike
  /// pdf.js one split count is used for all patches of a mesh, so that shared patch edges get identical vertices
  /// (no T-junctions, hence no pinholes between patches).</summary>
  MeshMinSplit = 3;
  MeshMaxSplit = 20;
  MeshTriangleDensity = 20;
  /// <summary>Triangle budget for the patch grids; the common split count is lowered to stay below it.</summary>
  MeshPatchTriangleBudget = 500000;
  /// <summary>Upper bound on the number of triangles per shading (memory guard against hostile data).</summary>
  MeshMaxTriangles = 1000000;
  /// <summary>Entries of the colour lookup table of a shading with /Function: the function input t is passed as a
  /// texture coordinate, so it (not the colour) is interpolated linearly across each triangle.</summary>
  MeshLutSize = 1024;
  /// <summary>Vertices per DrawVertices call (multiple of 3).</summary>
  MeshDrawBatch = 30000;

function PdfMatrixToSk(const M: TPdfMatrix): TMatrix;
begin
  Result := TMatrix.Identity;
  Result.m11 := M.A;
  Result.m12 := M.B;
  Result.m21 := M.C;
  Result.m22 := M.D;
  Result.m31 := M.E;
  Result.m32 := M.F;
end;

{ ---------------------------------------------------------------------------- }
{ Mesh decoding                                                                }
{ ---------------------------------------------------------------------------- }

type
  TMeshPoint = record
    X, Y: Double;
  end;

  TBernstein = array[0..3] of Double;

  /// <summary>MSB-first bit reader over the decoded mesh data (pdf.js MeshStreamReader).</summary>
  TMeshBitReader = record
  private
    FData: TBytes;
    FPos: Integer;
    FBuffer: UInt64;
    FBufferLen: Integer;
    FFailed: Boolean;
  public
    procedure Init(const AData: TBytes);
    /// <summary>True while unread bytes (or buffered bits) remain.</summary>
    function HasData: Boolean;
    /// <summary>Reads N (1..32) bits; sets Failed and returns 0 when the data runs out.</summary>
    function ReadBits(N: Integer): Cardinal;
    /// <summary>Drops the buffered bits so that the next read starts at a byte boundary.</summary>
    procedure Align;
    property Failed: Boolean read FFailed;
  end;

  /// <summary>Indices of one patch: P = control points p00, p10, ..., p30, p01, ..., p33 (pdf.js order, index
  /// 4 * row + column), C = corner colours c00, c30, c03, c33.</summary>
  TMeshPatch = record
    P: array[0..15] of Integer;
    C: array[0..3] of Integer;
  end;

  /// <summary>Decodes the mesh data of one shading into Gouraud triangles (stored back into the shading).</summary>
  TMeshBuilder = class
  private
    FShading: TPdfShading;
    FReader: TMeshBitReader;
    FNV: Integer;               // values per vertex: 1 (t) with a function, else colour space components
    FCoordScale, FCompScale: Double;
    // Output vertices (types 4/5 directly, 6/7 from the patch grids) and triangles (3 indices each)
    FPts: TList<TMeshPoint>;
    FVals: TList<Double>;
    FTris: TList<Integer>;
    // Patch control points and corner colours (types 6/7)
    FCtl: TList<TMeshPoint>;
    FCVals: TList<Double>;
    FPatches: TList<TMeshPatch>;
    function ReadCoord(out P: TMeshPoint): Boolean;
    function ReadValues(var Vals: TArray<Double>; Offset: Integer): Boolean;
    function AddVertex(const P: TMeshPoint; const Vals: TArray<Double>; Offset: Integer): Integer;
    function TriangleRoom: Boolean;
    procedure AddLattice(const Indices: TArray<Integer>; Count, VerticesPerRow: Integer);
    procedure DecodeFreeForm;
    procedure DecodeLattice;
    procedure DecodePatches(Tensor: Boolean);
    /// <summary>pdf.js split count of one patch (the larger of both directions), relative to the mesh bounds.</summary>
    function PatchSplit(const Patch: TMeshPatch; const AllBounds: TRectF): Integer;
    procedure BuildPatch(const Patch: TMeshPatch; Split: Integer);
    function VertexColor(const Vals: TArray<Double>): TAlphaColor;
    procedure Emit;
  public
    constructor Create(AShading: TPdfShading);
    destructor Destroy; override;
    procedure Run(const Data: TBytes);
  end;

{ TMeshBitReader }

procedure TMeshBitReader.Init(const AData: TBytes);
begin
  FData := AData;
  FPos := 0;
  FBuffer := 0;
  FBufferLen := 0;
  FFailed := False;
end;

function TMeshBitReader.HasData: Boolean;
begin
  Result := not FFailed and ((FPos < Integer(Length(FData))) or (FBufferLen > 0));
end;

function TMeshBitReader.ReadBits(N: Integer): Cardinal;
begin
  Result := 0;
  if FFailed then
    Exit;
  while FBufferLen < N do
  begin
    if FPos >= Integer(Length(FData)) then
    begin
      FFailed := True;
      Exit;
    end;
    FBuffer := (FBuffer shl 8) or FData[FPos];
    Inc(FPos);
    Inc(FBufferLen, 8);
  end;
  Dec(FBufferLen, N);
  Result := Cardinal((FBuffer shr FBufferLen) and ((UInt64(1) shl N) - 1));
  FBuffer := FBuffer and ((UInt64(1) shl FBufferLen) - 1);
end;

procedure TMeshBitReader.Align;
begin
  FBuffer := 0;
  FBufferLen := 0;
end;

{ TMeshBuilder }

function BitScale(Bits: Integer): Double;
begin
  if Bits < 32 then
    Result := 1 / ((Int64(1) shl Bits) - 1)
  else
    Result := 2.3283064365386963e-10; // 2^-32, as pdf.js
end;

/// <summary>Cubic Bernstein weights at t = K / S. Symmetric in rounding: the weights for S - K are exactly the reversed
/// weights for K, so an edge shared by two patches in opposite directions gets bit-identical vertices.</summary>
function MakeBernstein(K, S: Integer): TBernstein;
var
  T, T1, P: Double;
begin
  T := K / S;
  T1 := (S - K) / S;
  P := T * T1;
  Result[0] := T1 * T1 * T1;
  Result[1] := 3 * P * T1;
  Result[2] := 3 * P * T;
  Result[3] := T * T * T;
end;

constructor TMeshBuilder.Create(AShading: TPdfShading);
begin
  inherited Create;
  FShading := AShading;
  if Length(FShading.FFunctions) > 0 then
    FNV := 1
  else
    FNV := Max(FShading.FColorSpace.NComponents, 1);
  FCoordScale := BitScale(FShading.FBitsPerCoordinate);
  FCompScale := BitScale(FShading.FBitsPerComponent);
  FPts := TList<TMeshPoint>.Create;
  FVals := TList<Double>.Create;
  FTris := TList<Integer>.Create;
  FCtl := TList<TMeshPoint>.Create;
  FCVals := TList<Double>.Create;
  FPatches := TList<TMeshPatch>.Create;
end;

destructor TMeshBuilder.Destroy;
begin
  FPts.Free;
  FVals.Free;
  FTris.Free;
  FCtl.Free;
  FCVals.Free;
  FPatches.Free;
  inherited;
end;

function TMeshBuilder.ReadCoord(out P: TMeshPoint): Boolean;
var
  XI, YI: Cardinal;
  D: TArray<Double>;
begin
  D := FShading.FMeshDecode;
  XI := FReader.ReadBits(FShading.FBitsPerCoordinate);
  YI := FReader.ReadBits(FShading.FBitsPerCoordinate);
  P.X := XI * FCoordScale * (D[1] - D[0]) + D[0];
  P.Y := YI * FCoordScale * (D[3] - D[2]) + D[2];
  Result := not FReader.Failed;
end;

function TMeshBuilder.ReadValues(var Vals: TArray<Double>; Offset: Integer): Boolean;
var
  I, J: Integer;
  CI: Cardinal;
  D: TArray<Double>;
begin
  D := FShading.FMeshDecode;
  J := 4;
  for I := 0 to FNV - 1 do
  begin
    CI := FReader.ReadBits(FShading.FBitsPerComponent);
    Vals[Offset + I] := CI * FCompScale * (D[J + 1] - D[J]) + D[J];
    Inc(J, 2);
  end;
  Result := not FReader.Failed;
end;

function TMeshBuilder.AddVertex(const P: TMeshPoint; const Vals: TArray<Double>; Offset: Integer): Integer;
var
  I: Integer;
begin
  Result := FPts.Count;
  FPts.Add(P);
  for I := 0 to FNV - 1 do
    FVals.Add(Vals[Offset + I]);
end;

function TMeshBuilder.TriangleRoom: Boolean;
begin
  Result := FTris.Count div 3 < MeshMaxTriangles;
end;

procedure TMeshBuilder.AddLattice(const Indices: TArray<Integer>; Count, VerticesPerRow: Integer);
var
  Rows, Row, Col, Q: Integer;
begin
  // Two triangles per cell, as pdf.js buildMeshVertexData
  Rows := Count div VerticesPerRow - 1;
  for Row := 0 to Rows - 1 do
  begin
    Q := Row * VerticesPerRow;
    for Col := 0 to VerticesPerRow - 2 do
    begin
      if not TriangleRoom then
        Exit;
      FTris.Add(Indices[Q]);
      FTris.Add(Indices[Q + 1]);
      FTris.Add(Indices[Q + VerticesPerRow]);
      FTris.Add(Indices[Q + VerticesPerRow + 1]);
      FTris.Add(Indices[Q + 1]);
      FTris.Add(Indices[Q + VerticesPerRow]);
      Inc(Q);
    end;
  end;
end;

procedure TMeshBuilder.DecodeFreeForm;
var
  Flag: Cardinal;
  P: TMeshPoint;
  Vals: TArray<Double>;
  VerticesLeft, N: Integer;
  OK: Boolean;
begin
  SetLength(Vals, FNV);
  VerticesLeft := 0;
  while FReader.HasData and TriangleRoom do
  begin
    Flag := FReader.ReadBits(FShading.FBitsPerFlag);
    OK := ReadCoord(P);
    OK := ReadValues(Vals, 0) and OK;
    if not OK then
      Break; // truncated vertex: keep what was read
    if VerticesLeft = 0 then
    begin
      // The flag of a vertex that continues a started triangle is ignored
      N := FTris.Count;
      case Flag of
        0:
          VerticesLeft := 3;
        1:
          begin
            if N < 3 then
              Break;
            FTris.Add(FTris[N - 2]);
            FTris.Add(FTris[N - 1]);
            VerticesLeft := 1;
          end;
        2:
          begin
            if N < 3 then
              Break;
            FTris.Add(FTris[N - 3]);
            FTris.Add(FTris[N - 1]);
            VerticesLeft := 1;
          end;
      else
        Break; // unknown flag: stop and draw what was read
      end;
    end;
    FTris.Add(AddVertex(P, Vals, 0));
    Dec(VerticesLeft);
    // Each vertex starts at a byte boundary
    FReader.Align;
  end;
  // Drop an incomplete last triangle
  FTris.Count := FTris.Count - FTris.Count mod 3;
end;

procedure TMeshBuilder.DecodeLattice;
var
  P: TMeshPoint;
  Vals: TArray<Double>;
  Indices: TArray<Integer>;
  Count, VPR: Integer;
  OK: Boolean;
begin
  SetLength(Vals, FNV);
  VPR := FShading.FVerticesPerRow;
  Count := 0;
  while FReader.HasData do
  begin
    OK := ReadCoord(P);
    OK := ReadValues(Vals, 0) and OK;
    if not OK then
      Break;
    if Count >= Integer(Length(Indices)) then
      SetLength(Indices, Max(64, Count * 2));
    Indices[Count] := AddVertex(P, Vals, 0);
    Inc(Count);
    // Guard: vertices beyond the triangle budget are not read
    if Int64(Count div VPR) * (VPR - 1) * 2 > MeshMaxTriangles then
      Break;
  end;
  AddLattice(Indices, Count, VPR);
end;

procedure TMeshBuilder.DecodePatches(Tensor: Boolean);
const
  // New patch (flag 0): the 12 border points in stream order go to these indices
  BorderOrder: array[0..11] of Integer = (0, 4, 8, 12, 13, 14, 15, 11, 7, 3, 2, 1);
  // Continuation (flags 1-3): the 8 new border points go to these indices
  ContinueOrder: array[0..7] of Integer = (13, 14, 15, 11, 7, 3, 2, 1);
  // Shared edge per flag: previous indices that become the new p00 (0), p01 (4), p02 (8), p03 (12)
  SharedEdge: array[1..3, 0..3] of Integer = ((12, 13, 14, 15), (15, 11, 7, 3), (3, 2, 1, 0));
  // Shared colours per flag: previous colour slots that become the new c00 (slot 0) and c03 (slot 2)
  SharedColors: array[1..3, 0..1] of Integer = ((2, 3), (3, 1), (1, 0));
var
  Flag: Cardinal;
  F, I, NP, NC, PI0, CI0, Inner: Integer;
  Pts: array[0..15] of TMeshPoint;
  Vals: TArray<Double>;
  Patch, Prev: TMeshPatch;
  HavePrev, OK: Boolean;

  function Pt(K: Integer): TMeshPoint;
  begin
    Result := FCtl[Patch.P[K]];
  end;

  procedure AddInner(Target, A, B, C, D, E, F1, G, H: Integer);
  var
    Q: TMeshPoint;
  begin
    // Coons interior point (-4 A - B + 6 (C + D) - 2 (E + F1) + 3 (G + H)) / 9, pdf.js _decodeType6Shading
    Q.X := (-4 * Pt(A).X - Pt(B).X + 6 * (Pt(C).X + Pt(D).X) - 2 * (Pt(E).X + Pt(F1).X) + 3 * (Pt(G).X + Pt(H).X)) / 9;
    Q.Y := (-4 * Pt(A).Y - Pt(B).Y + 6 * (Pt(C).Y + Pt(D).Y) - 2 * (Pt(E).Y + Pt(F1).Y) + 3 * (Pt(G).Y + Pt(H).Y)) / 9;
    Patch.P[Target] := FCtl.Count;
    FCtl.Add(Q);
  end;

begin
  SetLength(Vals, 4 * FNV);
  HavePrev := False;
  Prev := Default(TMeshPatch);
  Patch := Default(TMeshPatch);
  while FReader.HasData do
  begin
    Flag := FReader.ReadBits(FShading.FBitsPerFlag);
    if FReader.Failed or (Flag > 3) then
      Break; // truncated data or unknown flag: stop and draw what was read
    F := Integer(Flag);
    if (F <> 0) and not HavePrev then
      Break; // continuation without a previous patch
    if Tensor then
      NP := 16
    else
      NP := 12;
    if F <> 0 then
    begin
      Dec(NP, 4);
      NC := 2;
    end
    else
      NC := 4;
    OK := True;
    for I := 0 to NP - 1 do
      OK := ReadCoord(Pts[I]) and OK;
    for I := 0 to NC - 1 do
      OK := ReadValues(Vals, I * FNV) and OK;
    if not OK then
      Break; // truncated patch
    PI0 := FCtl.Count;
    for I := 0 to NP - 1 do
      FCtl.Add(Pts[I]);
    CI0 := FCVals.Count div FNV;
    for I := 0 to NC * FNV - 1 do
      FCVals.Add(Vals[I]);
    if F = 0 then
    begin
      for I := 0 to 11 do
        Patch.P[BorderOrder[I]] := PI0 + I;
      Patch.C[0] := CI0;
      Patch.C[2] := CI0 + 1;
      Patch.C[3] := CI0 + 2;
      Patch.C[1] := CI0 + 3;
      Inner := PI0 + 12;
    end
    else
    begin
      Patch.P[0] := Prev.P[SharedEdge[F, 0]];
      Patch.P[4] := Prev.P[SharedEdge[F, 1]];
      Patch.P[8] := Prev.P[SharedEdge[F, 2]];
      Patch.P[12] := Prev.P[SharedEdge[F, 3]];
      for I := 0 to 7 do
        Patch.P[ContinueOrder[I]] := PI0 + I;
      Patch.C[0] := Prev.C[SharedColors[F, 0]];
      Patch.C[2] := Prev.C[SharedColors[F, 1]];
      Patch.C[3] := CI0;
      Patch.C[1] := CI0 + 1;
      Inner := PI0 + 8;
    end;
    if Tensor then
    begin
      // Interior points p11, p12, p22, p21 follow the border in the stream
      Patch.P[5] := Inner;
      Patch.P[9] := Inner + 1;
      Patch.P[10] := Inner + 2;
      Patch.P[6] := Inner + 3;
    end
    else
    begin
      AddInner(5, 0, 15, 4, 1, 12, 3, 13, 7);
      AddInner(6, 3, 12, 2, 7, 0, 15, 4, 14);
      AddInner(9, 12, 3, 8, 13, 0, 15, 11, 1);
      AddInner(10, 15, 0, 11, 14, 12, 3, 2, 8);
    end;
    FPatches.Add(Patch);
    Prev := Patch;
    HavePrev := True;
    if Int64(FPatches.Count) * 2 * MeshMinSplit * MeshMinSplit > MeshMaxTriangles then
      Break;
  end;
end;

function TMeshBuilder.PatchSplit(const Patch: TMeshPatch; const AllBounds: TRectF): Integer;
var
  MinX, MinY, MaxX, MaxY: Double;

  function Split(Extent, Total: Double): Integer;
  begin
    if not (Total > 0) or IsNan(Extent) then
      Exit(MeshMinSplit);
    Result := EnsureRange(Ceil(Min(Extent * MeshTriangleDensity / Total, MeshMaxSplit)), MeshMinSplit, MeshMaxSplit);
  end;

  function Corner(Index: Integer): TMeshPoint;
  begin
    Result := FCtl[Patch.P[Index]];
  end;

begin
  MinX := Min(Min(Corner(0).X, Corner(3).X), Min(Corner(12).X, Corner(15).X));
  MaxX := Max(Max(Corner(0).X, Corner(3).X), Max(Corner(12).X, Corner(15).X));
  MinY := Min(Min(Corner(0).Y, Corner(3).Y), Min(Corner(12).Y, Corner(15).Y));
  MaxY := Max(Max(Corner(0).Y, Corner(3).Y), Max(Corner(12).Y, Corner(15).Y));
  Result := Max(Split(MaxX - MinX, AllBounds.Width), Split(MaxY - MinY, AllBounds.Height));
end;

procedure TMeshBuilder.BuildPatch(const Patch: TMeshPatch; Split: Integer);
var
  SX, SY, Row, Col, I, J, K, VPR: Integer;
  BRow, BCol: TArray<TBernstein>;
  Grid: TArray<Integer>;
  Q, CP: TMeshPoint;
  M, U, V: Double;
  Vals: TArray<Double>;
  C0, C1, C2, C3: Integer;

  function Corner(Index: Integer): TMeshPoint;
  begin
    Result := FCtl[Patch.P[Index]];
  end;

  function EdgePoint(I0, I1, I2, I3: Integer; const W: TBernstein): TMeshPoint;
  var
    P0, P1, P2, P3: TMeshPoint;
  begin
    // (w0 p0 + w3 p3) + (w1 p1 + w2 p2): reversing the edge swaps the operands of each addition only, which is
    // exact in IEEE arithmetic (MakeBernstein gives exactly reversed weights)
    P0 := Corner(I0);
    P1 := Corner(I1);
    P2 := Corner(I2);
    P3 := Corner(I3);
    Result.X := (W[0] * P0.X + W[3] * P3.X) + (W[1] * P1.X + W[2] * P2.X);
    Result.Y := (W[0] * P0.Y + W[3] * P3.Y) + (W[1] * P1.Y + W[2] * P2.Y);
  end;

begin
  SX := Split;
  SY := Split;
  SetLength(BRow, SY + 1);
  for I := 0 to SY do
    BRow[I] := MakeBernstein(I, SY);
  SetLength(BCol, SX + 1);
  for I := 0 to SX do
    BCol[I] := MakeBernstein(I, SX);
  VPR := SX + 1;
  SetLength(Grid, (SY + 1) * VPR);
  SetLength(Vals, FNV);
  C0 := Patch.C[0] * FNV;
  C1 := Patch.C[1] * FNV;
  C2 := Patch.C[2] * FNV;
  C3 := Patch.C[3] * FNV;
  for Row := 0 to SY do
  begin
    V := Row / SY;
    for Col := 0 to SX do
    begin
      U := Col / SX;
      // Corners are the control points themselves; edge points depend only on the 4 control points of their edge
      // and are evaluated symmetrically, so a neighbouring patch sharing the edge (in either direction) gets
      // bit-identical vertices and the triangles meet without cracks.
      if (Row = 0) and (Col = 0) then
        Q := Corner(0)
      else if (Row = 0) and (Col = SX) then
        Q := Corner(3)
      else if (Row = SY) and (Col = 0) then
        Q := Corner(12)
      else if (Row = SY) and (Col = SX) then
        Q := Corner(15)
      else if Row = 0 then
        Q := EdgePoint(0, 1, 2, 3, BCol[Col])
      else if Row = SY then
        Q := EdgePoint(12, 13, 14, 15, BCol[Col])
      else if Col = 0 then
        Q := EdgePoint(0, 4, 8, 12, BRow[Row])
      else if Col = SX then
        Q := EdgePoint(3, 7, 11, 15, BRow[Row])
      else
      begin
        Q.X := 0;
        Q.Y := 0;
        K := 0;
        for I := 0 to 3 do
          for J := 0 to 3 do
          begin
            M := BRow[Row][I] * BCol[Col][J];
            CP := FCtl[Patch.P[K]];
            Q.X := Q.X + CP.X * M;
            Q.Y := Q.Y + CP.Y * M;
            Inc(K);
          end;
      end;
      // Bilinear interpolation of the corner values (colour components or t): c00 at (0, 0), c30 at (0, SX),
      // c03 at (SY, 0), c33 at (SY, SX). Interpolating t rather than the colour keeps non-linear functions exact
      // at every grid vertex.
      for I := 0 to FNV - 1 do
        Vals[I] := (1 - U) * ((1 - V) * FCVals[C0 + I] + V * FCVals[C2 + I]) +
                   U * ((1 - V) * FCVals[C1 + I] + V * FCVals[C3 + I]);
      Grid[Row * VPR + Col] := AddVertex(Q, Vals, 0);
    end;
  end;
  AddLattice(Grid, Integer(Length(Grid)), VPR);
end;

function TMeshBuilder.VertexColor(const Vals: TArray<Double>): TAlphaColor;
begin
  if Length(FShading.FFunctions) > 0 then
    Result := FShading.FColorSpace.ToAlphaColor(PdfEvaluateFunctions(FShading.FFunctions, [Vals[0]]))
  else
    Result := FShading.FColorSpace.ToAlphaColor(Vals);
  Result := Result or $FF000000;
end;

procedure TMeshBuilder.Emit;
var
  NTri, I, T, K, V, Count: Integer;
  Colors: TArray<TAlphaColor>;
  Positions, TexCoords: TArray<TPointF>;
  OutColors, Lut: TArray<TAlphaColor>;
  Vals: TArray<Double>;
  HasFunction: Boolean;
  T0, Span: Double;
  MinX, MinY, MaxX, MaxY: Single;
  P: TMeshPoint;
begin
  SetLength(Colors, FPts.Count);
  SetLength(Vals, FNV);
  for I := 0 to FPts.Count - 1 do
  begin
    for T := 0 to FNV - 1 do
      Vals[T] := FVals[I * FNV + T];
    Colors[I] := VertexColor(Vals);
  end;
  HasFunction := Length(FShading.FFunctions) > 0;
  T0 := FShading.FMeshDecode[4];
  Span := FShading.FMeshDecode[5] - T0;
  if HasFunction then
  begin
    // Lookup table over the /Decode range of t; texture coordinate x = pixel position of t in the table
    SetLength(Lut, MeshLutSize);
    for I := 0 to MeshLutSize - 1 do
    begin
      Vals[0] := T0 + Span * I / (MeshLutSize - 1);
      Lut[I] := VertexColor(Vals);
    end;
  end;
  NTri := FTris.Count div 3;
  Count := NTri * 3;
  SetLength(Positions, Count);
  SetLength(OutColors, Count);
  if HasFunction then
    SetLength(TexCoords, Count);
  for K := 0 to Count - 1 do
  begin
    V := FTris[K];
    P := FPts[V];
    Positions[K] := TPointF.Create(P.X, P.Y);
    OutColors[K] := Colors[V];
    if HasFunction then
    begin
      if Span <> 0 then
        TexCoords[K] := TPointF.Create(EnsureRange((FVals[V] - T0) / Span, 0, 1) * (MeshLutSize - 1) + 0.5, 0.5)
      else
        TexCoords[K] := TPointF.Create(0.5, 0.5);
    end;
  end;
  FShading.FTriPositions := Positions;
  FShading.FTriColors := OutColors;
  FShading.FTriTexCoords := TexCoords;
  FShading.FLutColors := Lut;
  FShading.FTriCount := NTri;
  if Count > 0 then
  begin
    MinX := Positions[0].X;
    MaxX := MinX;
    MinY := Positions[0].Y;
    MaxY := MinY;
    for I := 1 to Count - 1 do
    begin
      MinX := Min(MinX, Positions[I].X);
      MaxX := Max(MaxX, Positions[I].X);
      MinY := Min(MinY, Positions[I].Y);
      MaxY := Max(MaxY, Positions[I].Y);
    end;
    FShading.FMeshBounds := TRectF.Create(MinX, MinY, MaxX, MaxY);
  end
  else
    FShading.FMeshBounds := TRectF.Empty;
end;

procedure TMeshBuilder.Run(const Data: TBytes);
var
  Bounds: TRectF;
  I, Split: Integer;
  P: TMeshPoint;
begin
  FReader.Init(Data);
  try
    case FShading.FShadingType of
      4: DecodeFreeForm;
      5: DecodeLattice;
      6: DecodePatches(False);
      7: DecodePatches(True);
    end;
    if FPatches.Count > 0 then
    begin
      // The bounds of all control points decide how finely each patch is split (pdf.js _updateBounds)
      P := FCtl[0];
      Bounds := TRectF.Create(P.X, P.Y, P.X, P.Y);
      for I := 1 to FCtl.Count - 1 do
      begin
        P := FCtl[I];
        Bounds.Left := Min(Bounds.Left, P.X);
        Bounds.Top := Min(Bounds.Top, P.Y);
        Bounds.Right := Max(Bounds.Right, P.X);
        Bounds.Bottom := Max(Bounds.Bottom, P.Y);
      end;
      // One split count for the whole mesh (the finest any patch asks for), within the triangle budget
      Split := MeshMinSplit;
      for I := 0 to FPatches.Count - 1 do
        Split := Max(Split, PatchSplit(FPatches[I], Bounds));
      while (Split > MeshMinSplit) and (Int64(FPatches.Count) * 2 * Split * Split > MeshPatchTriangleBudget) do
        Dec(Split);
      for I := 0 to FPatches.Count - 1 do
      begin
        if not TriangleRoom then
          Break;
        BuildPatch(FPatches[I], Split);
      end;
    end;
  except
    // Malformed data: draw what was decoded so far
    FTris.Count := FTris.Count - FTris.Count mod 3;
  end;
  Emit;
end;

{ TPdfShading }

class function TPdfShading.Parse(const Obj: IPdfObject; const Resources: IPdfDictionary; const Resolver: IPdfResolver): TPdfShading;
var
  O: IPdfObject;
  Dict: IPdfDictionary;
  Arr: IPdfArray;
  V: TArray<Double>;
  Comps: TArray<Double>;
  I: Integer;
  CSObj: IPdfObject;
begin
  Result := nil;
  O := PdfResolve(Resolver, Obj);
  Dict := PdfAsDictionary(O);
  if Dict = nil then
    Exit;
  Result := TPdfShading.Create;
  Result.FShadingType := Integer(Dict.GetInteger('ShadingType', 0));
  CSObj := Dict.GetRaw('ColorSpace');
  if (CSObj = nil) and (Result.FShadingType in [4..7]) then
    CSObj := Dict.GetRaw('CS'); // abbreviation accepted by pdf.js for mesh shadings
  Result.FColorSpace := TPdfColorSpace.Parse(CSObj, Resources, Resolver);
  if Result.FColorSpace = nil then
    Result.FColorSpace := TPdfColorSpace.DeviceRGB;
  Result.FFunctions := TPdfFunction.ParseArray(Dict.GetRaw('Function'), Resolver);
  Arr := Dict.GetArray('Coords');
  if Arr <> nil then
    Arr.GetNumbers(Result.FCoords);
  Arr := Dict.GetArray('Domain');
  if (Arr <> nil) and Arr.GetNumbers(V) then
    Result.FDomain := V;
  if Result.FShadingType = 1 then
  begin
    if Length(Result.FDomain) < 4 then
      Result.FDomain := [0, 1, 0, 1];
    Result.FMatrix := TPdfMatrix.Identity;
    Arr := Dict.GetArray('Matrix');
    if (Arr <> nil) and Arr.GetNumbers(V, 6) then
      Result.FMatrix := TPdfMatrix.Create(V[0], V[1], V[2], V[3], V[4], V[5]);
  end
  else if Length(Result.FDomain) < 2 then
    Result.FDomain := [0, 1];
  Arr := Dict.GetArray('Extend');
  if (Arr <> nil) and (Arr.Count >= 2) then
  begin
    Result.FExtendStart := PdfAsBoolean(Arr.Get(0));
    Result.FExtendEnd := PdfAsBoolean(Arr.Get(1));
  end;
  Result.FHasBBox := Dict.GetRectangle('BBox', Result.FBBox);
  Arr := Dict.GetArray('Background');
  if (Arr <> nil) and Arr.GetNumbers(Comps) then
  begin
    Result.FHasBackground := True;
    Result.FBackground := Result.FColorSpace.ToAlphaColor(Comps);
  end;
  // Validate the geometry of the supported types
  case Result.FShadingType of
    2: if Length(Result.FCoords) < 4 then
         FreeAndNil(Result);
    3: if Length(Result.FCoords) < 6 then
         FreeAndNil(Result);
    1, 4, 5, 6, 7: ;
  else
    FreeAndNil(Result);
  end;
  if (Result <> nil) and (Result.FShadingType in [1, 2, 3]) and (Length(Result.FFunctions) = 0) then
    FreeAndNil(Result);
  if Result <> nil then
    for I := 0 to High(Result.FFunctions) do
      if Result.FFunctions[I] = nil then
      begin
        FreeAndNil(Result);
        Break;
      end;
  if (Result <> nil) and (Result.FShadingType in [4..7]) then
    Result.ParseMeshParameters(Dict, O);
end;

procedure TPdfShading.ParseMeshParameters(const Dict: IPdfDictionary; const Obj: IPdfObject);
var
  Arr: IPdfArray;
  V: TArray<Double>;
  NV, I: Integer;

  function ValidBits(Bits: Integer): Boolean;
  begin
    Result := (Bits >= 1) and (Bits <= 32);
  end;

begin
  FMeshState := msInvalid;
  FMeshStream := PdfAsStream(Obj);
  if FMeshStream = nil then
    Exit;
  FBitsPerCoordinate := Integer(Dict.GetInteger('BitsPerCoordinate', 0));
  FBitsPerComponent := Integer(Dict.GetInteger('BitsPerComponent', 0));
  FBitsPerFlag := Integer(Dict.GetInteger('BitsPerFlag', 8));
  FVerticesPerRow := Integer(Dict.GetInteger('VerticesPerRow', 0));
  if not ValidBits(FBitsPerCoordinate) or not ValidBits(FBitsPerComponent) then
    Exit;
  if (FShadingType <> 5) and not ValidBits(FBitsPerFlag) then
    Exit;
  if (FShadingType = 5) and (FVerticesPerRow < 2) then
    Exit;
  Arr := Dict.GetArray('Decode');
  if (Arr = nil) or not Arr.GetNumbers(V) or (Length(V) < 4) then
    Exit;
  if Length(FFunctions) > 0 then
    NV := 1
  else
    NV := Max(FColorSpace.NComponents, 1);
  // Missing component ranges default to [0 1]
  I := Length(V);
  if I < 4 + 2 * NV then
  begin
    SetLength(V, 4 + 2 * NV);
    while I < Integer(Length(V)) do
    begin
      V[I] := I and 1;
      Inc(I);
    end;
  end;
  FMeshDecode := V;
  FMeshState := msPending;
end;

procedure TPdfShading.EnsureMesh;
var
  Data: TBytes;
  Builder: TMeshBuilder;
begin
  if FMeshState <> msPending then
    Exit;
  FMeshState := msReady;
  try
    Data := FMeshStream.GetDecodedData;
  except
    Data := nil;
  end;
  FMeshStream := nil;
  try
    Builder := TMeshBuilder.Create(Self);
    try
      Builder.Run(Data);
    finally
      Builder.Free;
    end;
  except
    FTriPositions := nil;
    FTriColors := nil;
    FTriTexCoords := nil;
    FLutColors := nil;
    FTriCount := 0;
    FMeshBounds := TRectF.Empty;
  end;
end;

destructor TPdfShading.Destroy;
begin
  PdfFreeFunctions(FFunctions);
  FColorSpace.Free;
  inherited;
end;

function TPdfShading.IsSupported: Boolean;
begin
  Result := FShadingType in [1..7];
end;

function TPdfShading.IsMesh: Boolean;
begin
  EnsureMesh;
  Result := (FShadingType in [4..7]) and (FMeshState = msReady);
end;

function TPdfShading.TriangleCount: Integer;
begin
  EnsureMesh;
  Result := FTriCount;
end;

function TPdfShading.MeshBounds: TRectF;
begin
  EnsureMesh;
  if FTriCount = 0 then
    Result := TRectF.Empty
  else
    Result := FMeshBounds;
end;

procedure TPdfShading.DrawMesh(const Canvas: ISkCanvas; const LocalMatrix: TMatrix; Alpha: Single; const Blender: ISkBlender);
var
  Paint: ISkPaint;
  Colors: TArray<TAlphaColor>;
  A: Cardinal;
  I, Start, N, Total: Integer;
  Vertices: ISkVertices;
  UseLut: Boolean;
  Image: ISkImage;
begin
  EnsureMesh;
  if (FTriCount = 0) or (Canvas = nil) or not (Alpha > 0) then
    Exit;
  Total := FTriCount * 3;
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := False;
  UseLut := (Length(FTriTexCoords) = Total) and (Length(FLutColors) > 0);
  if UseLut and (FLutShader = nil) then
  begin
    // 1-pixel-high lookup table of the function colours, sampled linearly at the interpolated t
    Image := TSkImage.MakeRasterCopy(TSkImageInfo.Create(Length(FLutColors), 1, TSkColorType.BGRA8888,
      TSkAlphaType.Unpremul), @FLutColors[0], NativeUInt(Length(FLutColors)) * 4);
    if Image <> nil then
      FLutShader := Image.MakeShader(TSkSamplingOptions.Create(TSkFilterMode.Linear, TSkMipmapMode.None),
        TSkTileMode.Clamp, TSkTileMode.Clamp);
    UseLut := FLutShader <> nil;
  end;
  if UseLut then
  begin
    // Without vertex colours the shader is sampled at the texture coordinates; the paint alpha applies on top
    Paint.Shader := FLutShader;
    Paint.AlphaF := Min(Alpha, 1);
    Colors := nil;
  end
  else
  begin
    // Without a shader Skia combines the vertex colours with the paint colour through the blend mode passed to
    // DrawVertices; Modulate with opaque white leaves the vertex colours unchanged
    Paint.Color := TAlphaColorRec.White;
    if Alpha < 1 then
    begin
      A := Cardinal(EnsureRange(Round(Alpha * 255), 0, 255)) shl 24;
      SetLength(Colors, Total);
      for I := 0 to Total - 1 do
        Colors[I] := (FTriColors[I] and $00FFFFFF) or A;
    end
    else
      Colors := FTriColors;
  end;
  if Blender <> nil then
    Paint.Blender := Blender;
  // Vertices are not anti-aliased, so triangles sharing an edge leave neither gaps nor double-painted seams
  Canvas.Save;
  try
    Canvas.Concat(LocalMatrix);
    Start := 0;
    while Start < Total do
    begin
      N := Min(MeshDrawBatch, Total - Start);
      if UseLut then
        Vertices := TSkVertices.MakeCopy(TSkVertexMode.Triangles, Copy(FTriPositions, Start, N),
          Copy(FTriTexCoords, Start, N), nil)
      else
        Vertices := TSkVertices.MakeCopy(TSkVertexMode.Triangles, Copy(FTriPositions, Start, N), nil,
          Copy(Colors, Start, N));
      if Vertices <> nil then
        Canvas.DrawVertices(Vertices, TSkBlendMode.Modulate, Paint);
      Inc(Start, N);
    end;
  finally
    Canvas.Restore;
  end;
end;

function TPdfShading.ColorAt(T: Double): TAlphaColor;
var
  Comps: TArray<Double>;
begin
  Comps := PdfEvaluateFunctions(FFunctions, [T]);
  Result := FColorSpace.ToAlphaColor(Comps);
end;

procedure TPdfShading.BuildStops(out Colors: TArray<TAlphaColor>; out Positions: TArray<Single>);
var
  I, N, Offset: Integer;
  T0, T1: Double;
begin
  T0 := FDomain[0];
  T1 := FDomain[1];
  N := GradientSamples;
  Offset := 0;
  SetLength(Colors, N + 2);
  SetLength(Positions, N + 2);
  if not FExtendStart then
  begin
    // Hard transparent stop at 0 so that nothing is painted before the start
    Colors[0] := 0;
    Positions[0] := 0;
    Offset := 1;
  end;
  for I := 0 to N - 1 do
  begin
    Colors[Offset + I] := ColorAt(T0 + (T1 - T0) * I / (N - 1));
    Positions[Offset + I] := I / (N - 1);
  end;
  Offset := Offset + N;
  if not FExtendEnd then
  begin
    Colors[Offset] := 0;
    Positions[Offset] := 1;
    Inc(Offset);
  end;
  SetLength(Colors, Offset);
  SetLength(Positions, Offset);
end;

function TPdfShading.MakeFunctionShader(const LocalMatrix: TMatrix): ISkShader;
const
  Size = 64;
var
  Pixels: TBytes;
  X, Y: Integer;
  Color: TAlphaColor;
  Comps: TArray<Double>;
  Image: ISkImage;
  Info: TSkImageInfo;
  M: TMatrix;
  X0, X1, Y0, Y1: Double;
begin
  X0 := FDomain[0];
  X1 := FDomain[1];
  Y0 := FDomain[2];
  Y1 := FDomain[3];
  SetLength(Pixels, Size * Size * 4);
  for Y := 0 to Size - 1 do
    for X := 0 to Size - 1 do
    begin
      Comps := PdfEvaluateFunctions(FFunctions, [X0 + (X1 - X0) * (X + 0.5) / Size, Y0 + (Y1 - Y0) * (Y + 0.5) / Size]);
      Color := FColorSpace.ToAlphaColor(Comps);
      Pixels[(Y * Size + X) * 4] := (Color shr 16) and $FF;
      Pixels[(Y * Size + X) * 4 + 1] := (Color shr 8) and $FF;
      Pixels[(Y * Size + X) * 4 + 2] := Color and $FF;
      Pixels[(Y * Size + X) * 4 + 3] := $FF;
    end;
  Info := TSkImageInfo.Create(Size, Size, TSkColorType.RGBA8888, TSkAlphaType.Premul);
  Image := TSkImage.MakeRasterCopy(Info, @Pixels[0], Size * 4);
  if Image = nil then
    Exit(nil);
  // image pixel space -> domain -> shading space (Matrix) -> canvas (LocalMatrix)
  M := TMatrix.CreateScaling((X1 - X0) / Size, (Y1 - Y0) / Size) * TMatrix.CreateTranslation(X0, Y0) *
       PdfMatrixToSk(FMatrix) * LocalMatrix;
  Result := Image.MakeShader(M, TSkSamplingOptions.Create(TSkFilterMode.Linear, TSkMipmapMode.None),
    TSkTileMode.Decal, TSkTileMode.Decal);
end;

function TPdfShading.MakeShader(const LocalMatrix: TMatrix): ISkShader;
var
  Colors: TArray<TAlphaColor>;
  Positions: TArray<Single>;
begin
  Result := nil;
  case FShadingType of
    1:
      Result := MakeFunctionShader(LocalMatrix);
    2:
      begin
        BuildStops(Colors, Positions);
        Result := TSkShader.MakeGradientLinear(TPointF.Create(FCoords[0], FCoords[1]), TPointF.Create(FCoords[2], FCoords[3]),
          Colors, LocalMatrix, Positions, TSkTileMode.Clamp);
      end;
    3:
      begin
        BuildStops(Colors, Positions);
        Result := TSkShader.MakeGradientTwoPointConical(TPointF.Create(FCoords[0], FCoords[1]), FCoords[2],
          TPointF.Create(FCoords[3], FCoords[4]), FCoords[5], Colors, LocalMatrix, Positions, TSkTileMode.Clamp);
      end;
  end;
end;

function TPdfShading.AverageColor: TAlphaColor;
var
  I, N: Integer;
  R, G, B: Int64;
  C: TAlphaColor;
begin
  if Length(FFunctions) = 0 then
  begin
    // Mesh shading without a function: average of the vertex colours
    EnsureMesh;
    if FTriCount = 0 then
      Exit(TAlphaColorRec.Gray);
    N := FTriCount * 3;
    R := 0;
    G := 0;
    B := 0;
    for I := 0 to N - 1 do
    begin
      C := FTriColors[I];
      Inc(R, (C shr 16) and $FF);
      Inc(G, (C shr 8) and $FF);
      Inc(B, C and $FF);
    end;
    Exit($FF000000 or (TAlphaColor(R div N) shl 16) or (TAlphaColor(G div N) shl 8) or TAlphaColor(B div N));
  end;
  N := 8;
  R := 0;
  G := 0;
  B := 0;
  for I := 0 to N - 1 do
  begin
    C := ColorAt(FDomain[0] + (FDomain[1] - FDomain[0]) * I / (N - 1));
    Inc(R, (C shr 16) and $FF);
    Inc(G, (C shr 8) and $FF);
    Inc(B, C and $FF);
  end;
  Result := $FF000000 or (TAlphaColor(R div N) shl 16) or (TAlphaColor(G div N) shl 8) or TAlphaColor(B div N);
end;

end.
