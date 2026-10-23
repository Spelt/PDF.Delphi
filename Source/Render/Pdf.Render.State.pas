{*******************************************************************************
  Pdf.Render.State
  The graphics state (ISO 32000-1 §8.4) and text state (§9.3) as tracked by
  the renderer. Colour spaces are owned by the renderer, not by the state.
*******************************************************************************}
unit Pdf.Render.State;

interface

uses
  System.SysUtils, System.UITypes, System.Math, Pdf.Core.Types, Pdf.Core.Objects,
  Pdf.Render.ColorSpaces;

type
  TPdfGraphicsState = class
  public
    CTM: TPdfMatrix;
    // Colour
    FillColorSpace: TPdfColorSpace;    // not owned
    StrokeColorSpace: TPdfColorSpace;  // not owned
    FillColor: TArray<Double>;
    StrokeColor: TArray<Double>;
    FillRGB: TAlphaColor;              // opaque sRGB of FillColor
    StrokeRGB: TAlphaColor;
    FillPattern: IPdfObject;           // pattern dictionary/stream when FillColorSpace is Pattern
    StrokePattern: IPdfObject;
    // Line parameters
    LineWidth: Double;
    LineCap: Integer;                  // 0 butt, 1 round, 2 square
    LineJoin: Integer;                 // 0 miter, 1 round, 2 bevel
    MiterLimit: Double;
    DashArray: TArray<Double>;
    DashPhase: Double;
    // Transparency
    FillAlpha: Double;
    StrokeAlpha: Double;
    BlendMode: string;                 // 'Normal', 'Multiply', ...
    SoftMask: IPdfObject;              // /SMask from ExtGState (dictionary) or nil
    // Text state
    CharSpacing: Double;
    WordSpacing: Double;
    HorizontalScale: Double;           // 1 = 100%
    Leading: Double;
    FontSize: Double;
    Rise: Double;
    RenderMode: Integer;
    Font: IPdfDictionary;
    FontName: string;
    constructor Create;
    procedure Assign(Source: TPdfGraphicsState);
    function Clone: TPdfGraphicsState;
    procedure SetFillColorSpace(CS: TPdfColorSpace);
    procedure SetStrokeColorSpace(CS: TPdfColorSpace);
    procedure SetFillColor(const Comps: TArray<Double>);
    procedure SetStrokeColor(const Comps: TArray<Double>);
    /// <summary>Fill colour with FillAlpha applied.</summary>
    function FillColorWithAlpha: TAlphaColor;
    function StrokeColorWithAlpha: TAlphaColor;
    /// <summary>True when the dash array has at least one positive entry (otherwise the line is solid).</summary>
    function HasDash: Boolean;
  end;

function PdfApplyAlpha(Color: TAlphaColor; Alpha: Double): TAlphaColor;

implementation

function PdfApplyAlpha(Color: TAlphaColor; Alpha: Double): TAlphaColor;
var
  A: Integer;
begin
  A := Round(EnsureRange(Alpha, 0, 1) * 255);
  Result := (Color and $00FFFFFF) or (TAlphaColor(A) shl 24);
end;

{ TPdfGraphicsState }

constructor TPdfGraphicsState.Create;
begin
  inherited Create;
  CTM := TPdfMatrix.Identity;
  FillColor := [0];
  StrokeColor := [0];
  FillRGB := TAlphaColorRec.Black;
  StrokeRGB := TAlphaColorRec.Black;
  LineWidth := 1;
  MiterLimit := 10;
  FillAlpha := 1;
  StrokeAlpha := 1;
  BlendMode := 'Normal';
  HorizontalScale := 1;
end;

procedure TPdfGraphicsState.Assign(Source: TPdfGraphicsState);
begin
  CTM := Source.CTM;
  FillColorSpace := Source.FillColorSpace;
  StrokeColorSpace := Source.StrokeColorSpace;
  FillColor := Copy(Source.FillColor);
  StrokeColor := Copy(Source.StrokeColor);
  FillRGB := Source.FillRGB;
  StrokeRGB := Source.StrokeRGB;
  FillPattern := Source.FillPattern;
  StrokePattern := Source.StrokePattern;
  LineWidth := Source.LineWidth;
  LineCap := Source.LineCap;
  LineJoin := Source.LineJoin;
  MiterLimit := Source.MiterLimit;
  DashArray := Copy(Source.DashArray);
  DashPhase := Source.DashPhase;
  FillAlpha := Source.FillAlpha;
  StrokeAlpha := Source.StrokeAlpha;
  BlendMode := Source.BlendMode;
  SoftMask := Source.SoftMask;
  CharSpacing := Source.CharSpacing;
  WordSpacing := Source.WordSpacing;
  HorizontalScale := Source.HorizontalScale;
  Leading := Source.Leading;
  FontSize := Source.FontSize;
  Rise := Source.Rise;
  RenderMode := Source.RenderMode;
  Font := Source.Font;
  FontName := Source.FontName;
end;

function TPdfGraphicsState.Clone: TPdfGraphicsState;
begin
  Result := TPdfGraphicsState.Create;
  Result.Assign(Self);
end;

procedure TPdfGraphicsState.SetFillColorSpace(CS: TPdfColorSpace);
begin
  FillColorSpace := CS;
  FillPattern := nil;
  if CS <> nil then
    SetFillColor(CS.InitialColor)
  else
    SetFillColor([0]);
end;

procedure TPdfGraphicsState.SetStrokeColorSpace(CS: TPdfColorSpace);
begin
  StrokeColorSpace := CS;
  StrokePattern := nil;
  if CS <> nil then
    SetStrokeColor(CS.InitialColor)
  else
    SetStrokeColor([0]);
end;

procedure TPdfGraphicsState.SetFillColor(const Comps: TArray<Double>);
begin
  FillColor := Copy(Comps);
  if FillColorSpace <> nil then
    FillRGB := FillColorSpace.ToAlphaColor(FillColor, 1)
  else if Length(Comps) >= 3 then
    FillRGB := TPdfRGB.Create(Comps[0], Comps[1], Comps[2]).ToAlphaColor
  else if Length(Comps) >= 1 then
    FillRGB := TPdfRGB.Create(Comps[0], Comps[0], Comps[0]).ToAlphaColor
  else
    FillRGB := TAlphaColorRec.Black;
end;

procedure TPdfGraphicsState.SetStrokeColor(const Comps: TArray<Double>);
begin
  StrokeColor := Copy(Comps);
  if StrokeColorSpace <> nil then
    StrokeRGB := StrokeColorSpace.ToAlphaColor(StrokeColor, 1)
  else if Length(Comps) >= 3 then
    StrokeRGB := TPdfRGB.Create(Comps[0], Comps[1], Comps[2]).ToAlphaColor
  else if Length(Comps) >= 1 then
    StrokeRGB := TPdfRGB.Create(Comps[0], Comps[0], Comps[0]).ToAlphaColor
  else
    StrokeRGB := TAlphaColorRec.Black;
end;

function TPdfGraphicsState.FillColorWithAlpha: TAlphaColor;
begin
  Result := PdfApplyAlpha(FillRGB, FillAlpha);
end;

function TPdfGraphicsState.StrokeColorWithAlpha: TAlphaColor;
begin
  Result := PdfApplyAlpha(StrokeRGB, StrokeAlpha);
end;

function TPdfGraphicsState.HasDash: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(DashArray) do
    if DashArray[I] > 0 then
      Exit(True);
end;

end.
