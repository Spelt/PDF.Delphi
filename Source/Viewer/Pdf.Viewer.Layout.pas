{*******************************************************************************
  Pdf.Viewer.Layout
  Page layout of a continuous vertical viewer: page rectangles at a zoom
  level, visible pages for a scroll position, current page, fit-width and
  fit-page zoom. Pure arithmetic, no UI dependencies, so it can be unit tested.
  All sizes are in logical pixels (points x zoom).
*******************************************************************************}
unit Pdf.Viewer.Layout;

interface

uses
  System.SysUtils, System.Types, System.Math, System.Generics.Collections;

type
  TPdfPageRect = record
    Index: Integer;
    /// <summary>Page rectangle in document coordinates (unscrolled, zoomed).</summary>
    Rect: TRectF;
  end;

  TPdfPageLayout = class
  private
    FPageSizes: TArray<TSizeF>;   // display size in points (after /Rotate)
    FZoom: Double;
    FGap: Double;
    FMargin: Double;
    FViewportWidth: Double;
    FViewportHeight: Double;
    FRects: TArray<TRectF>;
    FTotalWidth: Double;
    FTotalHeight: Double;
    FDirty: Boolean;
    procedure SetZoom(const Value: Double);
    procedure SetGap(const Value: Double);
    procedure SetMargin(const Value: Double);
    procedure SetViewportWidth(const Value: Double);
    procedure SetViewportHeight(const Value: Double);
    procedure Update;
    function GetPageRect(Index: Integer): TRectF;
    function GetTotalWidth: Double;
    function GetTotalHeight: Double;
  public
    constructor Create;
    /// <summary>Sets the page sizes in points (width, height after rotation).</summary>
    procedure SetPages(const Sizes: TArray<TSizeF>);
    function PageCount: Integer;
    /// <summary>Pages that intersect the viewport at ScrollY/ScrollX, in order.</summary>
    function VisiblePages(ScrollX, ScrollY: Double): TArray<TPdfPageRect>;
    /// <summary>Page with the largest visible area; -1 when there are no pages. Ties go to the upper page.</summary>
    function CurrentPage(ScrollX, ScrollY: Double): Integer;
    /// <summary>Page containing a document point, -1 when in a gap.</summary>
    function PageAt(X, Y: Double): Integer;
    /// <summary>Scroll position that puts the top of page Index one margin below the top of the viewport (clamped).</summary>
    function ScrollTopOfPage(Index: Integer): Double;
    /// <summary>Largest scroll positions (0 when the document fits).</summary>
    function MaxScrollX: Double;
    function MaxScrollY: Double;
    function ClampScrollX(Value: Double): Double;
    function ClampScrollY(Value: Double): Double;
    /// <summary>Zoom that makes the widest page fit the viewport width (minus margins).</summary>
    function FitWidthZoom: Double;
    /// <summary>Zoom that makes page Index (or the largest page when Index &lt; 0) fit the viewport in both directions.</summary>
    function FitPageZoom(Index: Integer = -1): Double;
    /// <summary>Converts a document point to page space in points (y up, PDF user space of the display box).</summary>
    function DocumentToPage(Index: Integer; X, Y: Double; out PX, PY: Double): Boolean;
    property Zoom: Double read FZoom write SetZoom;
    /// <summary>Vertical gap between pages in logical pixels (not zoomed).</summary>
    property Gap: Double read FGap write SetGap;
    /// <summary>Margin around the pages in logical pixels (not zoomed).</summary>
    property Margin: Double read FMargin write SetMargin;
    property ViewportWidth: Double read FViewportWidth write SetViewportWidth;
    property ViewportHeight: Double read FViewportHeight write SetViewportHeight;
    property PageRect[Index: Integer]: TRectF read GetPageRect;
    property TotalWidth: Double read GetTotalWidth;
    property TotalHeight: Double read GetTotalHeight;
    property PageSizes: TArray<TSizeF> read FPageSizes;
  end;

implementation

{ TPdfPageLayout }

constructor TPdfPageLayout.Create;
begin
  inherited Create;
  FZoom := 1;
  FGap := 8;
  FMargin := 8;
  FDirty := True;
end;

procedure TPdfPageLayout.SetPages(const Sizes: TArray<TSizeF>);
begin
  FPageSizes := Copy(Sizes);
  FDirty := True;
end;

function TPdfPageLayout.PageCount: Integer;
begin
  Result := Length(FPageSizes);
end;

procedure TPdfPageLayout.SetZoom(const Value: Double);
begin
  if Value <= 0 then
    Exit;
  if not SameValue(FZoom, Value) then
  begin
    FZoom := Value;
    FDirty := True;
  end;
end;

procedure TPdfPageLayout.SetGap(const Value: Double);
begin
  FGap := Max(0, Value);
  FDirty := True;
end;

procedure TPdfPageLayout.SetMargin(const Value: Double);
begin
  FMargin := Max(0, Value);
  FDirty := True;
end;

procedure TPdfPageLayout.SetViewportWidth(const Value: Double);
begin
  if not SameValue(FViewportWidth, Value) then
  begin
    FViewportWidth := Max(0, Value);
    FDirty := True;
  end;
end;

procedure TPdfPageLayout.SetViewportHeight(const Value: Double);
begin
  FViewportHeight := Max(0, Value);
end;

procedure TPdfPageLayout.Update;
var
  I: Integer;
  W, H, Y, MaxW, ContentW, X: Double;
begin
  if not FDirty then
    Exit;
  FDirty := False;
  SetLength(FRects, Length(FPageSizes));
  MaxW := 0;
  for I := 0 to High(FPageSizes) do
    MaxW := Max(MaxW, FPageSizes[I].Width * FZoom);
  ContentW := Max(MaxW + 2 * FMargin, FViewportWidth);
  FTotalWidth := ContentW;
  Y := FMargin;
  for I := 0 to High(FPageSizes) do
  begin
    W := FPageSizes[I].Width * FZoom;
    H := FPageSizes[I].Height * FZoom;
    X := (ContentW - W) / 2;
    FRects[I] := TRectF.Create(X, Y, X + W, Y + H);
    Y := Y + H + FGap;
  end;
  if Length(FPageSizes) > 0 then
    Y := Y - FGap;
  FTotalHeight := Y + FMargin;
end;

function TPdfPageLayout.GetPageRect(Index: Integer): TRectF;
begin
  Update;
  if (Index >= 0) and (Index < Length(FRects)) then
    Result := FRects[Index]
  else
    Result := TRectF.Empty;
end;

function TPdfPageLayout.GetTotalWidth: Double;
begin
  Update;
  Result := FTotalWidth;
end;

function TPdfPageLayout.GetTotalHeight: Double;
begin
  Update;
  Result := FTotalHeight;
end;

function TPdfPageLayout.VisiblePages(ScrollX, ScrollY: Double): TArray<TPdfPageRect>;
var
  I, N: Integer;
  Top, Bottom: Double;
begin
  Update;
  Result := nil;
  Top := ScrollY;
  Bottom := ScrollY + FViewportHeight;
  N := 0;
  SetLength(Result, Length(FRects));
  for I := 0 to High(FRects) do
  begin
    if FRects[I].Top >= Bottom then
      Break;
    if (FRects[I].Bottom > Top) and (FRects[I].Right > ScrollX) and (FRects[I].Left < ScrollX + FViewportWidth) then
    begin
      Result[N].Index := I;
      Result[N].Rect := FRects[I];
      Inc(N);
    end;
  end;
  SetLength(Result, N);
end;

function TPdfPageLayout.CurrentPage(ScrollX, ScrollY: Double): Integer;
var
  Visible: TArray<TPdfPageRect>;
  I: Integer;
  Area, Best: Double;
  R: TRectF;
begin
  Visible := VisiblePages(ScrollX, ScrollY);
  Result := -1;
  Best := -1;
  for I := 0 to High(Visible) do
  begin
    R := Visible[I].Rect;
    R.Top := Max(R.Top, ScrollY);
    R.Bottom := Min(R.Bottom, ScrollY + FViewportHeight);
    R.Left := Max(R.Left, ScrollX);
    R.Right := Min(R.Right, ScrollX + FViewportWidth);
    Area := Max(0, R.Bottom - R.Top) * Max(0, R.Right - R.Left);
    if Area > Best then
    begin
      Best := Area;
      Result := Visible[I].Index;
    end;
  end;
  if (Result < 0) and (Length(FRects) > 0) then
  begin
    // Viewport beyond the last page or no visible area: nearest page
    if ScrollY >= FRects[High(FRects)].Bottom then
      Result := High(FRects)
    else
      Result := 0;
  end;
end;

function TPdfPageLayout.PageAt(X, Y: Double): Integer;
var
  I: Integer;
begin
  Update;
  for I := 0 to High(FRects) do
  begin
    if FRects[I].Top > Y then
      Break;
    if FRects[I].Contains(TPointF.Create(X, Y)) then
      Exit(I);
  end;
  Result := -1;
end;

function TPdfPageLayout.ScrollTopOfPage(Index: Integer): Double;
begin
  Update;
  if (Index < 0) or (Index >= Length(FRects)) then
    Exit(0);
  Result := ClampScrollY(FRects[Index].Top - FMargin);
end;

function TPdfPageLayout.MaxScrollX: Double;
begin
  Result := Max(0, TotalWidth - FViewportWidth);
end;

function TPdfPageLayout.MaxScrollY: Double;
begin
  Result := Max(0, TotalHeight - FViewportHeight);
end;

function TPdfPageLayout.ClampScrollX(Value: Double): Double;
begin
  Result := EnsureRange(Value, 0, MaxScrollX);
end;

function TPdfPageLayout.ClampScrollY(Value: Double): Double;
begin
  Result := EnsureRange(Value, 0, MaxScrollY);
end;

function TPdfPageLayout.FitWidthZoom: Double;
var
  I: Integer;
  MaxW: Double;
begin
  MaxW := 0;
  for I := 0 to High(FPageSizes) do
    MaxW := Max(MaxW, FPageSizes[I].Width);
  if (MaxW <= 0) or (FViewportWidth <= 2 * FMargin) then
    Exit(1);
  Result := (FViewportWidth - 2 * FMargin) / MaxW;
end;

function TPdfPageLayout.FitPageZoom(Index: Integer): Double;
var
  I: Integer;
  W, H, ZW, ZH: Double;
begin
  W := 0;
  H := 0;
  if (Index >= 0) and (Index < Length(FPageSizes)) then
  begin
    W := FPageSizes[Index].Width;
    H := FPageSizes[Index].Height;
  end
  else
    for I := 0 to High(FPageSizes) do
    begin
      W := Max(W, FPageSizes[I].Width);
      H := Max(H, FPageSizes[I].Height);
    end;
  if (W <= 0) or (H <= 0) or (FViewportWidth <= 2 * FMargin) or (FViewportHeight <= 2 * FMargin) then
    Exit(1);
  ZW := (FViewportWidth - 2 * FMargin) / W;
  ZH := (FViewportHeight - 2 * FMargin) / H;
  Result := Min(ZW, ZH);
end;

function TPdfPageLayout.DocumentToPage(Index: Integer; X, Y: Double; out PX, PY: Double): Boolean;
var
  R: TRectF;
begin
  PX := 0;
  PY := 0;
  R := GetPageRect(Index);
  if R.IsEmpty or (FZoom <= 0) then
    Exit(False);
  PX := (X - R.Left) / FZoom;
  PY := (R.Bottom - Y) / FZoom;
  Result := True;
end;

end.
