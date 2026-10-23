{*******************************************************************************
  Pdf.Render.Skia
  Renders a page's content streams to an ISkCanvas: graphics state, paths,
  clipping, colour, images (XObject and inline), form XObjects, shading and
  tiling patterns, shadings and ExtGState transparency. Text operators are
  tracked but glyphs are not drawn yet (fase 3); optionally a placeholder
  frame is drawn where text would appear.
  Portions derived from pdf.js (Mozilla, Apache License 2.0).
*******************************************************************************}
unit Pdf.Render.Skia;

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Types, System.UITypes, System.Math.Vectors,
  System.Generics.Collections, System.Skia,
  Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Document,
  Pdf.Render.Functions, Pdf.Render.ColorSpaces, Pdf.Render.Content, Pdf.Render.State,
  Pdf.Render.Images, Pdf.Render.Shading;

type
  TPdfRenderError = record
    &Operator: string;
    Position: Integer;
    Message: string;
  end;

  TPdfPageRenderer = class
  private type
    TPathCmdKind = (pcMove, pcLine, pcCubic, pcClose);
    TPathCmd = record
      Kind: TPathCmdKind;
      X1, Y1, X2, Y2, X3, Y3: Double;
    end;
  private
    FDocument: TPdfDocument;
    FResolver: IPdfResolver;
    FCanvas: ISkCanvas;
    FState: TPdfGraphicsState;
    FStack: TObjectList<TPdfGraphicsState>;
    FColorSpaces: TObjectList<TPdfColorSpace>;
    FNamedColorSpaces: TDictionary<string, TPdfColorSpace>;
    FDeviceGray, FDeviceRGB, FDeviceCMYK: TPdfColorSpace;
    FImageCache: TDictionary<string, ISkImage>;
    FErrors: TList<TPdfRenderError>;
    FUnknownOperators: Integer;
    FPath: TList<TPathCmd>;
    FHasCurrentPoint: Boolean;
    FCurrentX, FCurrentY, FStartX, FStartY: Double;
    FPendingClip: Integer; // 0 none, 1 nonzero, 2 even-odd
    FBaseCTM: TPdfMatrix;
    FTextMatrix, FTextLineMatrix: TPdfMatrix;
    FFormDepth: Integer;
    FActiveForms: TList<Integer>;
    FOperationCount: Int64;
    FMaxOperations: Int64;
    FAntiAlias: Boolean;
    FShowTextPlaceholders: Boolean;
    FForcedColor: Boolean;      // uncoloured tiling pattern: colour operators are ignored
    FAborted: Boolean;
    procedure ResetForPage(const Matrix: TPdfMatrix);
    procedure Execute(const Data: TBytes; const Resources: IPdfDictionary);
    procedure ExecuteOperation(const Op: TPdfOperation; const Resources: IPdfDictionary);
    procedure AddError(const Op: TPdfOperation; const Msg: string);
    // state
    procedure PushState;
    procedure PopState;
    function ColorSpaceByName(const Name: string; const Resources: IPdfDictionary): TPdfColorSpace;
    function ColorSpaceFromObject(const Obj: IPdfObject; const Resources: IPdfDictionary): TPdfColorSpace;
    procedure ApplyExtGState(const GS: IPdfDictionary);
    procedure SetColor(const Op: TPdfOperation; const Resources: IPdfDictionary; Stroke: Boolean);
    // paths
    procedure PathMoveTo(X, Y: Double);
    procedure PathLineTo(X, Y: Double);
    procedure PathCurveTo(X1, Y1, X2, Y2, X3, Y3: Double);
    procedure PathClose;
    procedure PathRect(X, Y, W, H: Double);
    function BuildPath(EvenOdd: Boolean): ISkPath;
    procedure EndPath;
    procedure PaintPath(Fill, Stroke, EvenOdd: Boolean);
    procedure FillWithPaint(const Path: ISkPath; Stroke: Boolean);
    procedure PaintWithPattern(const Path: ISkPath; const Pattern: IPdfObject; Stroke: Boolean; const Resources: IPdfDictionary);
    procedure PaintShadingPattern(const Shading: TPdfShading; const Matrix: TPdfMatrix; Alpha: Double);
    procedure PaintTilingPattern(const Pattern: IPdfStream; const Matrix: TPdfMatrix; Stroke: Boolean);
    function MakeStrokePaint: ISkPaint;
    function MakeFillPaint: ISkPaint;
    function CurrentBlendMode: TSkBlendMode;
    function CTMScale: Double;
    // xobjects
    procedure DoXObject(const Name: string; const Resources: IPdfDictionary);
    procedure DrawForm(const Form: IPdfStream; const ParentResources: IPdfDictionary);
    procedure DrawImage(const Image: IPdfStream; const Resources: IPdfDictionary; const CacheKey: string);
    procedure DoShading(const Name: string; const Resources: IPdfDictionary);
    // text
    procedure ShowText(const Op: TPdfOperation);
    procedure TextNewLine(TX, TY: Double);
    function GetErrorCount: Integer;
  public
    constructor Create(ADocument: TPdfDocument);
    destructor Destroy; override;
    /// <summary>Matrix that maps PDF user space of Page to device pixels at Scale (1 = 72 dpi), honouring CropBox and Rotate.</summary>
    class function PageMatrix(Page: TPdfPage; Scale: Double): TPdfMatrix; static;
    /// <summary>Pixel size of the page at Scale after rotation.</summary>
    class procedure PageSizePixels(Page: TPdfPage; Scale: Double; out Width, Height: Integer); static;
    /// <summary>Renders Page onto Canvas; Matrix maps user space to the canvas (see PageMatrix). The background is not cleared.</summary>
    procedure RenderPage(Page: TPdfPage; const Canvas: ISkCanvas; const Matrix: TPdfMatrix);
    /// <summary>Renders Page to a new raster image at Scale with the given background colour.</summary>
    function RenderToImage(Page: TPdfPage; Scale: Double; Background: TAlphaColor = TAlphaColorRec.White): ISkImage;
    /// <summary>Operators that raised an exception during the last RenderPage (rendering continues after each).</summary>
    property Errors: TList<TPdfRenderError> read FErrors;
    property ErrorCount: Integer read GetErrorCount;
    property UnknownOperators: Integer read FUnknownOperators;
    property AntiAlias: Boolean read FAntiAlias write FAntiAlias;
    /// <summary>Draw a light frame where text would be shown (until fase 3 draws glyphs). Default False.</summary>
    property ShowTextPlaceholders: Boolean read FShowTextPlaceholders write FShowTextPlaceholders;
    /// <summary>Safety limit on the number of content operations per page (default 5 million).</summary>
    property MaxOperations: Int64 read FMaxOperations write FMaxOperations;
    property Document: TPdfDocument read FDocument;
  end;

implementation

const
  MaxFormDepth = 14;
  MaxErrors = 500;

function RectFOf(const R: TPdfRectangle): TRectF;
begin
  Result := TRectF.Create(R.X0, R.Y0, R.X1, R.Y1);
  Result.NormalizeRect;
end;

function BlendModeFromName(const Name: string): TSkBlendMode;
begin
  if (Name = 'Multiply') then Result := TSkBlendMode.Multiply
  else if Name = 'Screen' then Result := TSkBlendMode.Screen
  else if Name = 'Overlay' then Result := TSkBlendMode.Overlay
  else if Name = 'Darken' then Result := TSkBlendMode.Darken
  else if Name = 'Lighten' then Result := TSkBlendMode.Lighten
  else if Name = 'ColorDodge' then Result := TSkBlendMode.ColorDodge
  else if Name = 'ColorBurn' then Result := TSkBlendMode.ColorBurn
  else if Name = 'HardLight' then Result := TSkBlendMode.HardLight
  else if Name = 'SoftLight' then Result := TSkBlendMode.SoftLight
  else if Name = 'Difference' then Result := TSkBlendMode.Difference
  else if Name = 'Exclusion' then Result := TSkBlendMode.Exclusion
  else if Name = 'Hue' then Result := TSkBlendMode.Hue
  else if Name = 'Saturation' then Result := TSkBlendMode.Saturation
  else if Name = 'Color' then Result := TSkBlendMode.Color
  else if Name = 'Luminosity' then Result := TSkBlendMode.Luminosity
  else Result := TSkBlendMode.SrcOver;
end;

{ TPdfPageRenderer }

constructor TPdfPageRenderer.Create(ADocument: TPdfDocument);
begin
  inherited Create;
  FDocument := ADocument;
  if ADocument <> nil then
    FResolver := ADocument.Resolver;
  FStack := TObjectList<TPdfGraphicsState>.Create(True);
  FColorSpaces := TObjectList<TPdfColorSpace>.Create(True);
  FNamedColorSpaces := TDictionary<string, TPdfColorSpace>.Create;
  FImageCache := TDictionary<string, ISkImage>.Create;
  FErrors := TList<TPdfRenderError>.Create;
  FPath := TList<TPathCmd>.Create;
  FActiveForms := TList<Integer>.Create;
  FDeviceGray := TPdfColorSpace.DeviceGray;
  FDeviceRGB := TPdfColorSpace.DeviceRGB;
  FDeviceCMYK := TPdfColorSpace.DeviceCMYK;
  FColorSpaces.Add(FDeviceGray);
  FColorSpaces.Add(FDeviceRGB);
  FColorSpaces.Add(FDeviceCMYK);
  FMaxOperations := 5000000;
  FAntiAlias := True;
  FState := TPdfGraphicsState.Create;
end;

destructor TPdfPageRenderer.Destroy;
begin
  FState.Free;
  FActiveForms.Free;
  FPath.Free;
  FErrors.Free;
  FImageCache.Free;
  FNamedColorSpaces.Free;
  FColorSpaces.Free;
  FStack.Free;
  inherited;
end;

function TPdfPageRenderer.GetErrorCount: Integer;
begin
  Result := FErrors.Count;
end;

class function TPdfPageRenderer.PageMatrix(Page: TPdfPage; Scale: Double): TPdfMatrix;
var
  Box: TPdfRectangle;
begin
  Box := Page.CropBox.Normalized;
  case Page.Rotate of
    90:  Result := TPdfMatrix.Create(0, Scale, Scale, 0, -Scale * Box.Y0, -Scale * Box.X0);
    180: Result := TPdfMatrix.Create(-Scale, 0, 0, Scale, Scale * Box.X1, -Scale * Box.Y0);
    270: Result := TPdfMatrix.Create(0, -Scale, -Scale, 0, Scale * Box.Y1, Scale * Box.X1);
  else
    Result := TPdfMatrix.Create(Scale, 0, 0, -Scale, -Scale * Box.X0, Scale * Box.Y1);
  end;
end;

class procedure TPdfPageRenderer.PageSizePixels(Page: TPdfPage; Scale: Double; out Width, Height: Integer);
var
  W, H: Double;
begin
  W := Page.CropBox.Width * Scale;
  H := Page.CropBox.Height * Scale;
  if (Page.Rotate = 90) or (Page.Rotate = 270) then
  begin
    Width := Max(1, Round(H));
    Height := Max(1, Round(W));
  end
  else
  begin
    Width := Max(1, Round(W));
    Height := Max(1, Round(H));
  end;
end;

function TPdfPageRenderer.RenderToImage(Page: TPdfPage; Scale: Double; Background: TAlphaColor): ISkImage;
var
  W, H: Integer;
  Surface: ISkSurface;
begin
  PageSizePixels(Page, Scale, W, H);
  Surface := TSkSurface.MakeRaster(W, H);
  Surface.Canvas.Clear(Background);
  RenderPage(Page, Surface.Canvas, PageMatrix(Page, Scale));
  Result := Surface.MakeImageSnapshot;
end;

procedure TPdfPageRenderer.ResetForPage(const Matrix: TPdfMatrix);
begin
  FStack.Clear;
  FErrors.Clear;
  FUnknownOperators := 0;
  FPath.Clear;
  FHasCurrentPoint := False;
  FPendingClip := 0;
  FOperationCount := 0;
  FFormDepth := 0;
  FActiveForms.Clear;
  FAborted := False;
  FState.Free;
  FState := TPdfGraphicsState.Create;
  FState.CTM := Matrix;
  FState.FillColorSpace := FDeviceGray;
  FState.StrokeColorSpace := FDeviceGray;
  FBaseCTM := Matrix;
  FTextMatrix := TPdfMatrix.Identity;
  FTextLineMatrix := TPdfMatrix.Identity;
end;

procedure TPdfPageRenderer.RenderPage(Page: TPdfPage; const Canvas: ISkCanvas; const Matrix: TPdfMatrix);
var
  SaveCount: Integer;
begin
  // The document may have been (re)loaded after this renderer was created
  FDocument := Page.Document;
  FResolver := FDocument.Resolver;
  FCanvas := Canvas;
  ResetForPage(Matrix);
  SaveCount := Canvas.Save;
  try
    Execute(Page.GetContentData, Page.Resources);
  finally
    Canvas.RestoreToCount(SaveCount);
    FCanvas := nil;
  end;
end;

procedure TPdfPageRenderer.AddError(const Op: TPdfOperation; const Msg: string);
var
  E: TPdfRenderError;
begin
  if FErrors.Count >= MaxErrors then
  begin
    FAborted := True;
    Exit;
  end;
  E.&Operator := Op.&Operator;
  E.Position := Op.Position;
  E.Message := Msg;
  FErrors.Add(E);
end;

procedure TPdfPageRenderer.Execute(const Data: TBytes; const Resources: IPdfDictionary);
var
  Parser: TPdfContentParser;
  Op: TPdfOperation;
  Res: IPdfDictionary;
  StackDepth: Integer;
begin
  Res := Resources;
  if Res = nil then
    Res := PdfDictionary(FResolver);
  StackDepth := FStack.Count;
  Parser := TPdfContentParser.Create(Data, FResolver, Res);
  try
    while not FAborted and Parser.Next(Op) do
    begin
      Inc(FOperationCount);
      if FOperationCount > FMaxOperations then
      begin
        AddError(Op, 'Operation limit reached');
        FAborted := True;
        Break;
      end;
      try
        ExecuteOperation(Op, Res);
      except
        on E: Exception do
          AddError(Op, E.ClassName + ': ' + E.Message);
      end;
    end;
  finally
    Parser.Free;
  end;
  // Unbalanced q without Q inside this stream: restore to the depth at entry
  while FStack.Count > StackDepth do
    PopState;
end;

procedure TPdfPageRenderer.PushState;
begin
  FStack.Add(FState.Clone);
  FCanvas.Save;
end;

procedure TPdfPageRenderer.PopState;
var
  S: TPdfGraphicsState;
begin
  if FStack.Count = 0 then
    Exit;
  S := FStack.Last;
  FStack.Extract(S);
  FState.Free;
  FState := S;
  FCanvas.Restore;
end;

function TPdfPageRenderer.CTMScale: Double;
begin
  Result := Sqrt(Abs(FState.CTM.A * FState.CTM.D - FState.CTM.B * FState.CTM.C));
end;

function TPdfPageRenderer.CurrentBlendMode: TSkBlendMode;
begin
  Result := BlendModeFromName(FState.BlendMode);
end;

{ Colour }

function TPdfPageRenderer.ColorSpaceFromObject(const Obj: IPdfObject; const Resources: IPdfDictionary): TPdfColorSpace;
begin
  Result := TPdfColorSpace.Parse(Obj, Resources, FResolver);
  if Result = nil then
    Exit(FDeviceGray);
  FColorSpaces.Add(Result);
end;

function TPdfPageRenderer.ColorSpaceByName(const Name: string; const Resources: IPdfDictionary): TPdfColorSpace;
var
  Key: string;
  CSDict: IPdfDictionary;
begin
  if (Name = 'DeviceGray') or (Name = 'G') then
    Exit(FDeviceGray);
  if (Name = 'DeviceRGB') or (Name = 'RGB') then
    Exit(FDeviceRGB);
  if (Name = 'DeviceCMYK') or (Name = 'CMYK') then
    Exit(FDeviceCMYK);
  CSDict := Resources.GetDictionary('ColorSpace');
  if (CSDict <> nil) and CSDict.Contains(Name) then
  begin
    Key := Format('%p:%s', [Pointer(CSDict), Name]);
    if FNamedColorSpaces.TryGetValue(Key, Result) then
      Exit;
    Result := ColorSpaceFromObject(CSDict.GetRaw(Name), nil);
    FNamedColorSpaces.Add(Key, Result);
    Exit;
  end;
  Result := ColorSpaceFromObject(PdfName(Name), Resources);
end;

procedure TPdfPageRenderer.SetColor(const Op: TPdfOperation; const Resources: IPdfDictionary; Stroke: Boolean);
var
  CS, Base: TPdfColorSpace;
  Values: TArray<Double>;
  PatName: string;
  Patterns: IPdfDictionary;
  Pat: IPdfObject;
  I, N: Integer;
begin
  if FForcedColor then
    Exit;
  if Stroke then
    CS := FState.StrokeColorSpace
  else
    CS := FState.FillColorSpace;
  if (CS <> nil) and CS.IsPattern and (Op.Count >= 1) and PdfIsName(Op.Obj(Op.Count - 1)) then
  begin
    PatName := Op.Name(Op.Count - 1);
    Patterns := Resources.GetDictionary('Pattern');
    Pat := nil;
    if Patterns <> nil then
      Pat := Patterns.Get(PatName);
    if PdfIsNull(Pat) then
      Pat := nil;
    // Components for an uncoloured pattern in the base space
    Base := CS.BaseColorSpace;
    N := Op.Count - 1;
    SetLength(Values, N);
    for I := 0 to N - 1 do
      Values[I] := Op.Num(I);
    if Stroke then
    begin
      FState.StrokePattern := Pat;
      if (Base <> nil) and (N > 0) then
        FState.StrokeRGB := Base.ToAlphaColor(Values)
      else
        FState.StrokeRGB := TAlphaColorRec.Black;
      FState.StrokeColor := Values;
    end
    else
    begin
      FState.FillPattern := Pat;
      if (Base <> nil) and (N > 0) then
        FState.FillRGB := Base.ToAlphaColor(Values)
      else
        FState.FillRGB := TAlphaColorRec.Black;
      FState.FillColor := Values;
    end;
    Exit;
  end;
  if not Op.Numbers(1, Values) then
    Exit;
  if Stroke then
    FState.SetStrokeColor(Values)
  else
    FState.SetFillColor(Values);
end;

procedure TPdfPageRenderer.ApplyExtGState(const GS: IPdfDictionary);
var
  Obj: IPdfObject;
  Arr: IPdfArray;
  V: TArray<Double>;
  FontArr: IPdfArray;
begin
  if GS = nil then
    Exit;
  if GS.Contains('LW') then
    FState.LineWidth := GS.GetNumber('LW', FState.LineWidth);
  if GS.Contains('LC') then
    FState.LineCap := Integer(GS.GetInteger('LC', FState.LineCap));
  if GS.Contains('LJ') then
    FState.LineJoin := Integer(GS.GetInteger('LJ', FState.LineJoin));
  if GS.Contains('ML') then
    FState.MiterLimit := GS.GetNumber('ML', FState.MiterLimit);
  Arr := GS.GetArray('D');
  if (Arr <> nil) and (Arr.Count >= 1) then
  begin
    if (Arr.GetArray(0) <> nil) and Arr.GetArray(0).GetNumbers(V) then
      FState.DashArray := V
    else
      FState.DashArray := nil;
    FState.DashPhase := Arr.GetNumber(1, 0);
  end;
  if GS.Contains('CA') then
    FState.StrokeAlpha := EnsureRange(GS.GetNumber('CA', 1), 0, 1);
  if GS.Contains('ca') then
    FState.FillAlpha := EnsureRange(GS.GetNumber('ca', 1), 0, 1);
  Obj := GS.Get('BM');
  if PdfIsName(Obj) then
    FState.BlendMode := (Obj as IPdfName).Name
  else if (Obj <> nil) and (Obj.Kind = okArray) and ((Obj as IPdfArray).Count > 0) then
    FState.BlendMode := (Obj as IPdfArray).GetName(0, 'Normal');
  if GS.Contains('SMask') then
  begin
    Obj := GS.Get('SMask');
    if (Obj <> nil) and (Obj.Kind = okDictionary) then
      FState.SoftMask := Obj
    else
      FState.SoftMask := nil; // /None
  end;
  FontArr := GS.GetArray('Font');
  if (FontArr <> nil) and (FontArr.Count >= 2) then
  begin
    FState.Font := FontArr.GetDictionary(0);
    FState.FontSize := FontArr.GetNumber(1, FState.FontSize);
  end;
end;

{ Paths }

procedure TPdfPageRenderer.PathMoveTo(X, Y: Double);
var
  C: TPathCmd;
begin
  C := Default(TPathCmd);
  C.Kind := pcMove;
  C.X1 := X;
  C.Y1 := Y;
  FPath.Add(C);
  FCurrentX := X;
  FCurrentY := Y;
  FStartX := X;
  FStartY := Y;
  FHasCurrentPoint := True;
end;

procedure TPdfPageRenderer.PathLineTo(X, Y: Double);
var
  C: TPathCmd;
begin
  if not FHasCurrentPoint then
  begin
    PathMoveTo(X, Y);
    Exit;
  end;
  C := Default(TPathCmd);
  C.Kind := pcLine;
  C.X1 := X;
  C.Y1 := Y;
  FPath.Add(C);
  FCurrentX := X;
  FCurrentY := Y;
end;

procedure TPdfPageRenderer.PathCurveTo(X1, Y1, X2, Y2, X3, Y3: Double);
var
  C: TPathCmd;
begin
  if not FHasCurrentPoint then
    PathMoveTo(X1, Y1);
  C.Kind := pcCubic;
  C.X1 := X1;
  C.Y1 := Y1;
  C.X2 := X2;
  C.Y2 := Y2;
  C.X3 := X3;
  C.Y3 := Y3;
  FPath.Add(C);
  FCurrentX := X3;
  FCurrentY := Y3;
end;

procedure TPdfPageRenderer.PathClose;
var
  C: TPathCmd;
begin
  if not FHasCurrentPoint then
    Exit;
  C := Default(TPathCmd);
  C.Kind := pcClose;
  FPath.Add(C);
  FCurrentX := FStartX;
  FCurrentY := FStartY;
end;

procedure TPdfPageRenderer.PathRect(X, Y, W, H: Double);
begin
  PathMoveTo(X, Y);
  PathLineTo(X + W, Y);
  PathLineTo(X + W, Y + H);
  PathLineTo(X, Y + H);
  PathClose;
end;

function TPdfPageRenderer.BuildPath(EvenOdd: Boolean): ISkPath;
var
  B: ISkPathBuilder;
  C: TPathCmd;
begin
  B := TSkPathBuilder.Create;
  if EvenOdd then
    B.FillType := TSkPathFillType.EvenOdd
  else
    B.FillType := TSkPathFillType.Winding;
  for C in FPath do
    case C.Kind of
      pcMove: B.MoveTo(C.X1, C.Y1);
      pcLine: B.LineTo(C.X1, C.Y1);
      pcCubic: B.CubicTo(C.X1, C.Y1, C.X2, C.Y2, C.X3, C.Y3);
      pcClose: B.Close;
    end;
  Result := B.Detach;
end;

procedure TPdfPageRenderer.EndPath;
var
  Path, DevPath: ISkPath;
begin
  if FPendingClip <> 0 then
  begin
    if FPath.Count = 0 then
      FCanvas.ClipRect(TRectF.Create(0, 0, 0, 0), TSkClipOp.Intersect, False)
    else
    begin
      Path := BuildPath(FPendingClip = 2);
      DevPath := Path.Transform(PdfMatrixToSk(FState.CTM));
      FCanvas.ClipPath(DevPath, TSkClipOp.Intersect, FAntiAlias);
    end;
    FPendingClip := 0;
  end;
  FPath.Clear;
  FHasCurrentPoint := False;
end;

function TPdfPageRenderer.MakeFillPaint: ISkPaint;
begin
  Result := TSkPaint.Create(TSkPaintStyle.Fill);
  Result.AntiAlias := FAntiAlias;
  Result.Color := FState.FillColorWithAlpha;
  Result.Blender := TSkBlender.MakeMode(CurrentBlendMode);
end;

function TPdfPageRenderer.MakeStrokePaint: ISkPaint;
var
  Scale, Width: Double;
  Intervals: TArray<Single>;
  I, N: Integer;
  AllZero: Boolean;
begin
  Result := TSkPaint.Create(TSkPaintStyle.Stroke);
  Result.AntiAlias := FAntiAlias;
  Result.Color := FState.StrokeColorWithAlpha;
  Result.Blender := TSkBlender.MakeMode(CurrentBlendMode);
  Scale := CTMScale;
  Width := FState.LineWidth;
  // Lines thinner than one device pixel are drawn one pixel wide (as pdf.js does)
  if (Scale > 0) and (Width * Scale < 1) then
    Width := 1 / Scale;
  Result.StrokeWidth := Width;
  case FState.LineCap of
    1: Result.StrokeCap := TSkStrokeCap.Round;
    2: Result.StrokeCap := TSkStrokeCap.Square;
  else
    Result.StrokeCap := TSkStrokeCap.Butt;
  end;
  case FState.LineJoin of
    1: Result.StrokeJoin := TSkStrokeJoin.Round;
    2: Result.StrokeJoin := TSkStrokeJoin.Bevel;
  else
    Result.StrokeJoin := TSkStrokeJoin.Miter;
  end;
  Result.StrokeMiter := Max(1, FState.MiterLimit);
  if FState.HasDash then
  begin
    N := Length(FState.DashArray);
    AllZero := True;
    for I := 0 to N - 1 do
      if FState.DashArray[I] > 0 then
        AllZero := False;
    if not AllZero and (N <= 64) then
    begin
      if Odd(N) then
        SetLength(Intervals, 2 * N)
      else
        SetLength(Intervals, N);
      for I := 0 to High(Intervals) do
        Intervals[I] := Max(0, FState.DashArray[I mod N]);
      Result.PathEffect := TSkPathEffect.MakeDash(Intervals, FState.DashPhase);
    end;
  end;
end;

procedure TPdfPageRenderer.FillWithPaint(const Path: ISkPath; Stroke: Boolean);
var
  Paint: ISkPaint;
begin
  if Stroke then
    Paint := MakeStrokePaint
  else
    Paint := MakeFillPaint;
  FCanvas.Save;
  try
    FCanvas.Concat(PdfMatrixToSk(FState.CTM));
    FCanvas.DrawPath(Path, Paint);
  finally
    FCanvas.Restore;
  end;
end;

procedure TPdfPageRenderer.PaintPath(Fill, Stroke, EvenOdd: Boolean);
var
  Path: ISkPath;
  Pattern: IPdfObject;
begin
  if (FPath.Count > 0) and (CTMScale > 0) then
  begin
    if Fill then
    begin
      Path := BuildPath(EvenOdd);
      if (FState.FillColorSpace <> nil) and FState.FillColorSpace.IsPattern and not FForcedColor then
      begin
        Pattern := FState.FillPattern;
        if Pattern <> nil then
          PaintWithPattern(Path, Pattern, False, nil);
      end
      else if not ((FState.FillColorSpace <> nil) and FState.FillColorSpace.IsNone) then
        FillWithPaint(Path, False);
    end;
    if Stroke then
    begin
      if Path = nil then
        Path := BuildPath(False);
      if (FState.StrokeColorSpace <> nil) and FState.StrokeColorSpace.IsPattern and not FForcedColor then
      begin
        Pattern := FState.StrokePattern;
        if Pattern <> nil then
          PaintWithPattern(Path, Pattern, True, nil);
      end
      else if not ((FState.StrokeColorSpace <> nil) and FState.StrokeColorSpace.IsNone) then
        FillWithPaint(Path, True);
    end;
  end;
  EndPath;
end;

{ Patterns and shadings }

procedure TPdfPageRenderer.PaintShadingPattern(const Shading: TPdfShading; const Matrix: TPdfMatrix; Alpha: Double);
var
  Shader: ISkShader;
  Paint: ISkPaint;
  BBoxPath: ISkPath;
  B: ISkPathBuilder;
begin
  Shader := Shading.MakeShader(PdfMatrixToSk(Matrix));
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := FAntiAlias;
  Paint.Blender := TSkBlender.MakeMode(CurrentBlendMode);
  Paint.AlphaF := Alpha;
  if Shader = nil then
  begin
    if not Shading.IsSupported and (Shading.ShadingType >= 4) then
      Paint.Color := PdfApplyAlpha(Shading.AverageColor, Alpha)
    else
      Exit;
  end
  else
    Paint.Shader := Shader;
  FCanvas.Save;
  try
    if Shading.HasBBox then
    begin
      B := TSkPathBuilder.Create;
      B.AddRect(RectFOf(Shading.BBox));
      BBoxPath := B.Detach.Transform(PdfMatrixToSk(Matrix));
      FCanvas.ClipPath(BBoxPath, TSkClipOp.Intersect, FAntiAlias);
    end;
    FCanvas.DrawPaint(Paint);
  finally
    FCanvas.Restore;
  end;
end;

procedure TPdfPageRenderer.PaintTilingPattern(const Pattern: IPdfStream; const Matrix: TPdfMatrix; Stroke: Boolean);
var
  Dict: IPdfDictionary;
  BBox: TPdfRectangle;
  XStep, YStep: Double;
  Recorder: ISkPictureRecorder;
  Picture: ISkPicture;
  Sub: TPdfPageRenderer;
  TileCanvas: ISkCanvas;
  Shader: ISkShader;
  Paint: ISkPaint;
  TileRect: TRectF;
  PaintType: Integer;
  Color: TAlphaColor;
  DevScale: Double;
  I: Integer;
begin
  Dict := Pattern.Dict;
  if not Dict.GetRectangle('BBox', BBox) then
    Exit;
  XStep := Dict.GetNumber('XStep', BBox.Width);
  YStep := Dict.GetNumber('YStep', BBox.Height);
  if (Abs(XStep) < 1E-9) or IsInfinite(XStep) or IsNan(XStep) then
    XStep := BBox.Width;
  if (Abs(YStep) < 1E-9) or IsInfinite(YStep) or IsNan(YStep) then
    YStep := BBox.Height;
  XStep := Abs(XStep);
  YStep := Abs(YStep);
  if (XStep < 1E-9) or (YStep < 1E-9) then
    Exit;
  PaintType := Integer(Dict.GetInteger('PaintType', 1));
  if Stroke then
    Color := FState.StrokeRGB
  else
    Color := FState.FillRGB;
  // The picture is recorded in pattern space; the shader applies Matrix to it.
  TileRect := TRectF.Create(BBox.X0, BBox.Y0, BBox.X0 + XStep, BBox.Y0 + YStep);
  Recorder := TSkPictureRecorder.Create;
  TileCanvas := Recorder.BeginRecording(RectFOf(BBox));
  Sub := TPdfPageRenderer.Create(FDocument);
  try
    Sub.FAntiAlias := FAntiAlias;
    Sub.FShowTextPlaceholders := FShowTextPlaceholders;
    Sub.FMaxOperations := Max(1000, (FMaxOperations - FOperationCount) div 4);
    Sub.FFormDepth := FFormDepth + 1;
    for I in FActiveForms do
      Sub.FActiveForms.Add(I);
    Sub.FCanvas := TileCanvas;
    Sub.ResetForPage(TPdfMatrix.Identity);
    Sub.FFormDepth := FFormDepth + 1;
    Sub.FBaseCTM := TPdfMatrix.Identity;
    if PaintType = 2 then
    begin
      Sub.FState.FillRGB := Color;
      Sub.FState.StrokeRGB := Color;
      Sub.FForcedColor := True;
    end;
    TileCanvas.ClipRect(RectFOf(BBox));
    Sub.Execute(Pattern.GetDecodedData, Dict.GetDictionary('Resources'));
    for I := 0 to Sub.FErrors.Count - 1 do
      FErrors.Add(Sub.FErrors[I]);
    Inc(FOperationCount, Sub.FOperationCount);
  finally
    Sub.Free;
  end;
  Picture := Recorder.FinishRecording;
  if Picture = nil then
    Exit;
  // Avoid shaders with absurd tile counts (tiny steps at high zoom are still fine: Skia rasterises lazily)
  DevScale := Sqrt(Abs(Matrix.A * Matrix.D - Matrix.B * Matrix.C));
  if DevScale <= 0 then
    Exit;
  Shader := Picture.MakeShader(TileRect, PdfMatrixToSk(Matrix), TSkTileMode.&Repeat, TSkTileMode.&Repeat, TSkFilterMode.Linear);
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := FAntiAlias;
  Paint.Shader := Shader;
  Paint.Blender := TSkBlender.MakeMode(CurrentBlendMode);
  if Stroke then
    Paint.AlphaF := FState.StrokeAlpha
  else
    Paint.AlphaF := FState.FillAlpha;
  FCanvas.DrawPaint(Paint);
end;

procedure TPdfPageRenderer.PaintWithPattern(const Path: ISkPath; const Pattern: IPdfObject; Stroke: Boolean; const Resources: IPdfDictionary);
var
  PatDict: IPdfDictionary;
  PatternType: Integer;
  Matrix: TPdfMatrix;
  Arr: IPdfArray;
  V: TArray<Double>;
  Shading: TPdfShading;
  ClipPath: ISkPath;
  StrokePaint: ISkPaint;
  Alpha: Double;
begin
  PatDict := PdfAsDictionary(Pattern);
  if PatDict = nil then
    Exit;
  PatternType := Integer(PatDict.GetInteger('PatternType', 0));
  Matrix := TPdfMatrix.Identity;
  Arr := PatDict.GetArray('Matrix');
  if (Arr <> nil) and Arr.GetNumbers(V, 6) then
    Matrix := TPdfMatrix.Create(V[0], V[1], V[2], V[3], V[4], V[5]);
  Matrix := Matrix.Multiply(FBaseCTM);
  // Clip to the path (or to the stroke outline)
  if Stroke then
  begin
    StrokePaint := MakeStrokePaint;
    ClipPath := StrokePaint.GetFillPath(Path).Transform(PdfMatrixToSk(FState.CTM));
    Alpha := FState.StrokeAlpha;
  end
  else
  begin
    ClipPath := Path.Transform(PdfMatrixToSk(FState.CTM));
    Alpha := FState.FillAlpha;
  end;
  FCanvas.Save;
  try
    FCanvas.ClipPath(ClipPath, TSkClipOp.Intersect, FAntiAlias);
    if PatternType = 2 then
    begin
      Shading := TPdfShading.Parse(PatDict.GetRaw('Shading'), Resources, FResolver);
      if Shading <> nil then
      try
        PaintShadingPattern(Shading, Matrix, Alpha);
      finally
        Shading.Free;
      end;
    end
    else if (PatternType = 1) and (Pattern.Kind = okStream) then
    begin
      if FFormDepth < MaxFormDepth then
        PaintTilingPattern(Pattern as IPdfStream, Matrix, Stroke);
    end;
  finally
    FCanvas.Restore;
  end;
end;

procedure TPdfPageRenderer.DoShading(const Name: string; const Resources: IPdfDictionary);
var
  Shadings: IPdfDictionary;
  Shading: TPdfShading;
begin
  Shadings := Resources.GetDictionary('Shading');
  if Shadings = nil then
    Exit;
  Shading := TPdfShading.Parse(Shadings.GetRaw(Name), Resources, FResolver);
  if Shading = nil then
    Exit;
  try
    PaintShadingPattern(Shading, FState.CTM, FState.FillAlpha);
  finally
    Shading.Free;
  end;
end;

{ XObjects }

procedure TPdfPageRenderer.DoXObject(const Name: string; const Resources: IPdfDictionary);
var
  XObjects: IPdfDictionary;
  Obj: IPdfObject;
  Stream: IPdfStream;
  Subtype: string;
begin
  XObjects := Resources.GetDictionary('XObject');
  if XObjects = nil then
    Exit;
  Obj := XObjects.Get(Name);
  Stream := PdfAsStream(Obj);
  if Stream = nil then
    Exit;
  Subtype := Stream.Dict.GetName('Subtype');
  if Subtype = 'Image' then
    DrawImage(Stream, Resources, Format('obj%d', [Stream.ObjNum]))
  else if Subtype = 'Form' then
    DrawForm(Stream, Resources)
  else if Subtype = 'PS' then
    Exit
  else if Stream.Dict.Contains('BBox') then
    DrawForm(Stream, Resources)
  else if Stream.Dict.Contains('Width') then
    DrawImage(Stream, Resources, Format('obj%d', [Stream.ObjNum]));
end;

procedure TPdfPageRenderer.DrawForm(const Form: IPdfStream; const ParentResources: IPdfDictionary);
var
  Dict, Resources: IPdfDictionary;
  Arr: IPdfArray;
  V: TArray<Double>;
  M: TPdfMatrix;
  BBox: TPdfRectangle;
  B: ISkPathBuilder;
  SavedBase: TPdfMatrix;
  SavedTM, SavedTLM: TPdfMatrix;
  NeedsLayer: Boolean;
  LayerPaint: ISkPaint;
  ObjNum: Integer;
begin
  if FFormDepth >= MaxFormDepth then
    Exit;
  ObjNum := Form.ObjNum;
  if (ObjNum >= 0) and FActiveForms.Contains(ObjNum) then
    Exit; // recursive form
  Dict := Form.Dict;
  Resources := Dict.GetDictionary('Resources');
  if Resources = nil then
    Resources := ParentResources;
  M := TPdfMatrix.Identity;
  Arr := Dict.GetArray('Matrix');
  if (Arr <> nil) and Arr.GetNumbers(V, 6) then
    M := TPdfMatrix.Create(V[0], V[1], V[2], V[3], V[4], V[5]);
  NeedsLayer := Dict.Contains('Group') and ((FState.FillAlpha < 1) or (FState.BlendMode <> 'Normal') and (FState.BlendMode <> 'Compatible'));
  PushState;
  Inc(FFormDepth);
  if ObjNum >= 0 then
    FActiveForms.Add(ObjNum);
  SavedBase := FBaseCTM;
  SavedTM := FTextMatrix;
  SavedTLM := FTextLineMatrix;
  try
    FState.CTM := M.Multiply(FState.CTM);
    if Dict.GetRectangle('BBox', BBox) then
    begin
      B := TSkPathBuilder.Create;
      B.AddRect(RectFOf(BBox));
      FCanvas.ClipPath(B.Detach.Transform(PdfMatrixToSk(FState.CTM)), TSkClipOp.Intersect, FAntiAlias);
    end;
    if NeedsLayer then
    begin
      LayerPaint := TSkPaint.Create;
      LayerPaint.AlphaF := FState.FillAlpha;
      LayerPaint.Blender := TSkBlender.MakeMode(CurrentBlendMode);
      FCanvas.SaveLayer(LayerPaint);
      // Inside the group the content is drawn opaque with normal blending
      FState.FillAlpha := 1;
      FState.StrokeAlpha := 1;
      FState.BlendMode := 'Normal';
    end;
    FBaseCTM := FState.CTM;
    EndPath;
    Execute(Form.GetDecodedData, Resources);
    if NeedsLayer then
      FCanvas.Restore;
  finally
    FBaseCTM := SavedBase;
    FTextMatrix := SavedTM;
    FTextLineMatrix := SavedTLM;
    if ObjNum >= 0 then
      FActiveForms.Remove(ObjNum);
    Dec(FFormDepth);
    PopState;
  end;
end;

procedure TPdfPageRenderer.DrawImage(const Image: IPdfStream; const Resources: IPdfDictionary; const CacheKey: string);
var
  Img: ISkImage;
  IsStencil: Boolean;
  Reason, Key: string;
  Paint: ISkPaint;
  W, H: Integer;
  Sampling: TSkSamplingOptions;
  Scale: Double;
begin
  IsStencil := TPdfImageDecoder.IsStencilMask(Image.Dict);
  Key := '';
  if (CacheKey <> '') and (Image.ObjNum >= 0) then
  begin
    Key := CacheKey;
    if IsStencil then
      Key := Key + ':' + IntToHex(FState.FillRGB, 8);
  end;
  if (Key = '') or not FImageCache.TryGetValue(Key, Img) then
  begin
    Img := TPdfImageDecoder.Decode(Image, Resources, FResolver, FState.FillRGB, IsStencil, Reason);
    if Img = nil then
      Exit;
    if Key <> '' then
    begin
      if FImageCache.Count > 64 then
        FImageCache.Clear;
      FImageCache.Add(Key, Img);
    end;
  end;
  W := Img.Width;
  H := Img.Height;
  if (W <= 0) or (H <= 0) then
    Exit;
  Paint := TSkPaint.Create;
  Paint.AntiAlias := FAntiAlias;
  Paint.AlphaF := FState.FillAlpha;
  Paint.Blender := TSkBlender.MakeMode(CurrentBlendMode);
  // Device size of the unit square decides the sampling quality
  Scale := CTMScale;
  if Scale <= 0 then
    Exit;
  if (Scale < W) or (Scale < H) then
    Sampling := TSkSamplingOptions.Create(TSkFilterMode.Linear, TSkMipmapMode.Linear)
  else if (W <= 2) and (H <= 2) then
    Sampling := TSkSamplingOptions.Create(TSkFilterMode.Nearest, TSkMipmapMode.None)
  else
    Sampling := TSkSamplingOptions.Create(TSkFilterMode.Linear, TSkMipmapMode.None);
  FCanvas.Save;
  try
    FCanvas.Concat(PdfMatrixToSk(FState.CTM));
    // Image space (W x H, y down) -> unit square (y up)
    FCanvas.Concat(PdfMatrixToSk(TPdfMatrix.Create(1 / W, 0, 0, -1 / H, 0, 1)));
    FCanvas.DrawImageRect(Img, TRectF.Create(0, 0, W, H), Sampling, Paint);
  finally
    FCanvas.Restore;
  end;
end;

{ Text (tracking only; glyph rendering is fase 3) }

procedure TPdfPageRenderer.TextNewLine(TX, TY: Double);
begin
  FTextLineMatrix := TPdfMatrix.Translation(TX, TY).Multiply(FTextLineMatrix);
  FTextMatrix := FTextLineMatrix;
end;

procedure TPdfPageRenderer.ShowText(const Op: TPdfOperation);
var
  Obj: IPdfObject;
  Arr: IPdfArray;
  I, NChars, NSpaces: Integer;
  Width, Adjust: Double;
  Paint: ISkPaint;
  M: TPdfMatrix;
  B: ISkPathBuilder;

  procedure ShowString(const S: TBytes);
  var
    J: Integer;
  begin
    NChars := Length(S);
    NSpaces := 0;
    for J := 0 to High(S) do
      if S[J] = 32 then
        Inc(NSpaces);
    if NChars = 0 then
      Exit;
    // Approximate advance: 0.5 em per glyph until real font metrics exist
    Width := (NChars * 0.5 * FState.FontSize + NChars * FState.CharSpacing + NSpaces * FState.WordSpacing) * FState.HorizontalScale;
    if FShowTextPlaceholders and (FState.FontSize > 0) and (FState.RenderMode <> 3) and (FState.RenderMode <> 7) then
    begin
      M := TPdfMatrix.Create(FState.FontSize * FState.HorizontalScale, 0, 0, FState.FontSize, 0, FState.Rise)
        .Multiply(FTextMatrix).Multiply(FState.CTM);
      B := TSkPathBuilder.Create;
      B.AddRect(TRectF.Create(0, -0.22, Width / Max(FState.FontSize, 1E-6) / Max(FState.HorizontalScale, 1E-6), 0.78));
      Paint := TSkPaint.Create(TSkPaintStyle.Stroke);
      Paint.AntiAlias := FAntiAlias;
      Paint.Color := PdfApplyAlpha(FState.FillRGB, 0.35 * FState.FillAlpha);
      Paint.StrokeWidth := 0;
      FCanvas.DrawPath(B.Detach.Transform(PdfMatrixToSk(M)), Paint);
    end;
    FTextMatrix := TPdfMatrix.Translation(Width, 0).Multiply(FTextMatrix);
  end;

begin
  if Op.Count = 0 then
    Exit;
  Obj := Op.Obj(Op.Count - 1);
  if Obj = nil then
    Exit;
  if Obj.Kind = okString then
    ShowString((Obj as IPdfString).Bytes)
  else if Obj.Kind = okArray then
  begin
    Arr := Obj as IPdfArray;
    for I := 0 to Arr.Count - 1 do
    begin
      Obj := Arr.Get(I);
      if Obj.Kind = okString then
        ShowString((Obj as IPdfString).Bytes)
      else if PdfIsNumber(Obj) then
      begin
        Adjust := -PdfAsNumber(Obj) / 1000 * FState.FontSize * FState.HorizontalScale;
        FTextMatrix := TPdfMatrix.Translation(Adjust, 0).Multiply(FTextMatrix);
      end;
    end;
  end;
end;

{ Operator dispatch }

procedure TPdfPageRenderer.ExecuteOperation(const Op: TPdfOperation; const Resources: IPdfDictionary);
var
  V: TArray<Double>;
  Name: string;
  GS: IPdfDictionary;
  Fonts: IPdfDictionary;
  Stream: IPdfStream;
begin
  Name := Op.&Operator;
  if Name = '' then
    Exit;
  case Name[1] of
    'q':
      if Name = 'q' then
      begin
        PushState;
        Exit;
      end;
    'Q':
      if Name = 'Q' then
      begin
        PopState;
        Exit;
      end;
    'c':
      begin
        if Name = 'cm' then
        begin
          if Op.Numbers(6, V) then
            FState.CTM := TPdfMatrix.Create(V[0], V[1], V[2], V[3], V[4], V[5]).Multiply(FState.CTM);
          Exit;
        end;
        if Name = 'c' then
        begin
          if Op.Numbers(6, V) then
            PathCurveTo(V[0], V[1], V[2], V[3], V[4], V[5]);
          Exit;
        end;
        if Name = 'cs' then
        begin
          if not FForcedColor then
            FState.SetFillColorSpace(ColorSpaceByName(Op.Name(0), Resources));
          Exit;
        end;
      end;
    'C':
      if Name = 'CS' then
      begin
        if not FForcedColor then
          FState.SetStrokeColorSpace(ColorSpaceByName(Op.Name(0), Resources));
        Exit;
      end;
    'w':
      if Name = 'w' then
      begin
        FState.LineWidth := Abs(Op.Num(0, 1));
        Exit;
      end;
    'J':
      if Name = 'J' then
      begin
        FState.LineCap := Integer(Op.Int(0));
        Exit;
      end;
    'j':
      if Name = 'j' then
      begin
        FState.LineJoin := Integer(Op.Int(0));
        Exit;
      end;
    'M':
      begin
        if Name = 'M' then
        begin
          FState.MiterLimit := Op.Num(0, 10);
          Exit;
        end;
        if Name = 'MP' then
          Exit;
      end;
    'd':
      begin
        if Name = 'd' then
        begin
          if (Op.Count >= 1) and (Op.Obj(0).Kind = okArray) and (Op.Obj(0) as IPdfArray).GetNumbers(V) then
            FState.DashArray := V
          else
            FState.DashArray := nil;
          FState.DashPhase := Op.Num(1, 0);
          Exit;
        end;
        if (Name = 'd0') or (Name = 'd1') then
          Exit;
      end;
    'r':
      begin
        if Name = 're' then
        begin
          if Op.Numbers(4, V) then
            PathRect(V[0], V[1], V[2], V[3]);
          Exit;
        end;
        if Name = 'rg' then
        begin
          if not FForcedColor then
          begin
            FState.SetFillColorSpace(FDeviceRGB);
            SetColor(Op, Resources, False);
          end;
          Exit;
        end;
        if Name = 'ri' then
          Exit;
      end;
    'R':
      if Name = 'RG' then
      begin
        if not FForcedColor then
        begin
          FState.SetStrokeColorSpace(FDeviceRGB);
          SetColor(Op, Resources, True);
        end;
        Exit;
      end;
    'g':
      begin
        if Name = 'g' then
        begin
          if not FForcedColor then
          begin
            FState.SetFillColorSpace(FDeviceGray);
            SetColor(Op, Resources, False);
          end;
          Exit;
        end;
        if Name = 'gs' then
        begin
          GS := Resources.GetDictionary('ExtGState');
          if GS <> nil then
            ApplyExtGState(GS.GetDictionary(Op.Name(0)));
          Exit;
        end;
      end;
    'G':
      if Name = 'G' then
      begin
        if not FForcedColor then
        begin
          FState.SetStrokeColorSpace(FDeviceGray);
          SetColor(Op, Resources, True);
        end;
        Exit;
      end;
    'k':
      if Name = 'k' then
      begin
        if not FForcedColor then
        begin
          FState.SetFillColorSpace(FDeviceCMYK);
          SetColor(Op, Resources, False);
        end;
        Exit;
      end;
    'K':
      if Name = 'K' then
      begin
        if not FForcedColor then
        begin
          FState.SetStrokeColorSpace(FDeviceCMYK);
          SetColor(Op, Resources, True);
        end;
        Exit;
      end;
    's':
      begin
        if (Name = 'sc') or (Name = 'scn') then
        begin
          SetColor(Op, Resources, False);
          Exit;
        end;
        if Name = 's' then
        begin
          PathClose;
          PaintPath(False, True, False);
          Exit;
        end;
        if Name = 'sh' then
        begin
          DoShading(Op.Name(0), Resources);
          Exit;
        end;
      end;
    'S':
      begin
        if (Name = 'SC') or (Name = 'SCN') then
        begin
          SetColor(Op, Resources, True);
          Exit;
        end;
        if Name = 'S' then
        begin
          PaintPath(False, True, False);
          Exit;
        end;
      end;
    'm':
      if Name = 'm' then
      begin
        if Op.Numbers(2, V) then
          PathMoveTo(V[0], V[1]);
        Exit;
      end;
    'l':
      if Name = 'l' then
      begin
        if Op.Numbers(2, V) then
          PathLineTo(V[0], V[1]);
        Exit;
      end;
    'v':
      if Name = 'v' then
      begin
        if Op.Numbers(4, V) then
          PathCurveTo(FCurrentX, FCurrentY, V[0], V[1], V[2], V[3]);
        Exit;
      end;
    'y':
      if Name = 'y' then
      begin
        if Op.Numbers(4, V) then
          PathCurveTo(V[0], V[1], V[2], V[3], V[2], V[3]);
        Exit;
      end;
    'h':
      if Name = 'h' then
      begin
        PathClose;
        Exit;
      end;
    'n':
      if Name = 'n' then
      begin
        EndPath;
        Exit;
      end;
    'f':
      begin
        if Name = 'f' then
        begin
          PaintPath(True, False, False);
          Exit;
        end;
        if Name = 'f*' then
        begin
          PaintPath(True, False, True);
          Exit;
        end;
      end;
    'F':
      if Name = 'F' then
      begin
        PaintPath(True, False, False);
        Exit;
      end;
    'B':
      begin
        if Name = 'B' then
        begin
          PaintPath(True, True, False);
          Exit;
        end;
        if Name = 'B*' then
        begin
          PaintPath(True, True, True);
          Exit;
        end;
        if Name = 'BT' then
        begin
          FTextMatrix := TPdfMatrix.Identity;
          FTextLineMatrix := TPdfMatrix.Identity;
          Exit;
        end;
        if (Name = 'BMC') or (Name = 'BDC') or (Name = 'BX') or (Name = 'BI') then
          Exit;
      end;
    'b':
      begin
        if Name = 'b' then
        begin
          PathClose;
          PaintPath(True, True, False);
          Exit;
        end;
        if Name = 'b*' then
        begin
          PathClose;
          PaintPath(True, True, True);
          Exit;
        end;
      end;
    'W':
      begin
        if Name = 'W' then
        begin
          FPendingClip := 1;
          Exit;
        end;
        if Name = 'W*' then
        begin
          FPendingClip := 2;
          Exit;
        end;
      end;
    'D':
      begin
        if Name = 'Do' then
        begin
          EndPath;
          DoXObject(Op.Name(0), Resources);
          Exit;
        end;
        if Name = 'DP' then
          Exit;
      end;
    'E':
      begin
        if Name = 'EI' then
        begin
          Stream := PdfAsStream(Op.Obj(0));
          if Stream <> nil then
            DrawImage(Stream, Resources, '');
          Exit;
        end;
        if (Name = 'ET') or (Name = 'EMC') or (Name = 'EX') then
          Exit;
      end;
    'T':
      begin
        if Name = 'Tj' then
        begin
          ShowText(Op);
          Exit;
        end;
        if Name = 'TJ' then
        begin
          ShowText(Op);
          Exit;
        end;
        if Name = 'Td' then
        begin
          TextNewLine(Op.Num(0), Op.Num(1));
          Exit;
        end;
        if Name = 'TD' then
        begin
          FState.Leading := -Op.Num(1);
          TextNewLine(Op.Num(0), Op.Num(1));
          Exit;
        end;
        if Name = 'Tm' then
        begin
          if Op.Numbers(6, V) then
          begin
            FTextLineMatrix := TPdfMatrix.Create(V[0], V[1], V[2], V[3], V[4], V[5]);
            FTextMatrix := FTextLineMatrix;
          end;
          Exit;
        end;
        if Name = 'T*' then
        begin
          TextNewLine(0, -FState.Leading);
          Exit;
        end;
        if Name = 'TL' then
        begin
          FState.Leading := Op.Num(0);
          Exit;
        end;
        if Name = 'Tc' then
        begin
          FState.CharSpacing := Op.Num(0);
          Exit;
        end;
        if Name = 'Tw' then
        begin
          FState.WordSpacing := Op.Num(0);
          Exit;
        end;
        if Name = 'Tz' then
        begin
          FState.HorizontalScale := Op.Num(0, 100) / 100;
          Exit;
        end;
        if Name = 'Ts' then
        begin
          FState.Rise := Op.Num(0);
          Exit;
        end;
        if Name = 'Tr' then
        begin
          FState.RenderMode := Integer(Op.Int(0));
          Exit;
        end;
        if Name = 'Tf' then
        begin
          FState.FontSize := Op.Num(1, FState.FontSize);
          FState.FontName := Op.Name(0);
          Fonts := Resources.GetDictionary('Font');
          if Fonts <> nil then
            FState.Font := Fonts.GetDictionary(FState.FontName)
          else
            FState.Font := nil;
          Exit;
        end;
      end;
    '''':
      if Name = '''' then
      begin
        TextNewLine(0, -FState.Leading);
        ShowText(Op);
        Exit;
      end;
    '"':
      if Name = '"' then
      begin
        FState.WordSpacing := Op.Num(0);
        FState.CharSpacing := Op.Num(1);
        TextNewLine(0, -FState.Leading);
        ShowText(Op);
        Exit;
      end;
    'i':
      if Name = 'i' then
        Exit;
    'P':
      if Name = 'PS' then
        Exit;
  end;
  // Not an operator we know: pdf.js warns and continues
  Inc(FUnknownOperators);
end;

end.
