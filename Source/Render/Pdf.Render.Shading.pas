{*******************************************************************************
  Pdf.Render.Shading
  Shadings (ISO 32000-1 §8.7.4.5): type 1 (function-based), 2 (axial) and
  3 (radial) as Skia shaders. Mesh shadings (types 4-7) are recognised but
  not rendered yet (planned for fase 5).
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
    function ColorAt(T: Double): TAlphaColor;
    procedure BuildStops(out Colors: TArray<TAlphaColor>; out Positions: TArray<Single>);
    function MakeFunctionShader(const LocalMatrix: TMatrix): ISkShader;
  public
    /// <summary>Parses a shading dictionary or stream; nil when invalid. The caller owns the result.</summary>
    class function Parse(const Obj: IPdfObject; const Resources: IPdfDictionary; const Resolver: IPdfResolver): TPdfShading; static;
    destructor Destroy; override;
    /// <summary>Builds the Skia shader in shading space; LocalMatrix maps shading space to the canvas.
    /// Returns nil for unsupported types (4-7).</summary>
    function MakeShader(const LocalMatrix: TMatrix): ISkShader;
    /// <summary>True for types 1-3.</summary>
    function IsSupported: Boolean;
    /// <summary>Average colour over the domain (used as a fallback for unsupported mesh shadings when they carry a function).</summary>
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

{ TPdfShading }

class function TPdfShading.Parse(const Obj: IPdfObject; const Resources: IPdfDictionary; const Resolver: IPdfResolver): TPdfShading;
var
  O: IPdfObject;
  Dict: IPdfDictionary;
  Arr: IPdfArray;
  V: TArray<Double>;
  Comps: TArray<Double>;
  I: Integer;
begin
  Result := nil;
  O := PdfResolve(Resolver, Obj);
  Dict := PdfAsDictionary(O);
  if Dict = nil then
    Exit;
  Result := TPdfShading.Create;
  Result.FShadingType := Integer(Dict.GetInteger('ShadingType', 0));
  Result.FColorSpace := TPdfColorSpace.Parse(Dict.GetRaw('ColorSpace'), Resources, Resolver);
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
end;

destructor TPdfShading.Destroy;
begin
  PdfFreeFunctions(FFunctions);
  FColorSpace.Free;
  inherited;
end;

function TPdfShading.IsSupported: Boolean;
begin
  Result := FShadingType in [1, 2, 3];
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
  R, G, B: Integer;
  C: TAlphaColor;
begin
  if Length(FFunctions) = 0 then
    Exit(TAlphaColorRec.Gray);
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
