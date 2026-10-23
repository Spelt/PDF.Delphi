{*******************************************************************************
  Pdf.Viewer.Layout
  Page layout of a vertical viewer: page rectangles at a zoom level, visible
  pages for a scroll position, current page, fit-width and fit-page zoom.
  Pages are grouped in rows of one or two columns (facing pages, optionally
  with the first page alone as a cover). In continuous mode all rows are
  stacked; otherwise only the row of ActivePage is laid out and the others
  get an empty rectangle. Pure arithmetic, no UI dependencies, so it can be
  unit tested. All sizes are in logical pixels (points x zoom).
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
    FPageSizes: TArray<TSizeF>;   // display size in points (after rotation)
    FZoom: Double;
    FGap: Double;
    FMargin: Double;
    FViewportWidth: Double;
    FViewportHeight: Double;
    FColumns: Integer;
    FCoverPage: Boolean;
    FContinuous: Boolean;
    FActivePage: Integer;
    FRects: TArray<TRectF>;
    FRowOfPage: TArray<Integer>;
    FRowFirst: TArray<Integer>;   // first page of each row; one extra entry = PageCount
    FTotalWidth: Double;
    FTotalHeight: Double;
    FDirty: Boolean;
    procedure SetZoom(const Value: Double);
    procedure SetGap(const Value: Double);
    procedure SetMargin(const Value: Double);
    procedure SetViewportWidth(const Value: Double);
    procedure SetViewportHeight(const Value: Double);
    procedure SetColumns(const Value: Integer);
    procedure SetCoverPage(const Value: Boolean);
    procedure SetContinuous(const Value: Boolean);
    procedure SetActivePage(const Value: Integer);
    procedure BuildRows;
    procedure Update;
    function GetPageRect(Index: Integer): TRectF;
    function GetTotalWidth: Double;
    function GetTotalHeight: Double;
    function GetRowCount: Integer;
    /// <summary>Column slot (0 left, 1 right) of a page; always 0 with one column.</summary>
    function SlotOfPage(Index: Integer): Integer;
    procedure ColumnMaxWidths(out LeftMax, RightMax: Double);
    procedure RowSizePoints(Row: Integer; out Width, Height: Double; out Pages: Integer);
  public
    constructor Create;
    /// <summary>Sets the page sizes in points (width, height after rotation).</summary>
    procedure SetPages(const Sizes: TArray<TSizeF>);
    function PageCount: Integer;
    /// <summary>Row (0-based) of a page, -1 for an invalid index.</summary>
    function RowOfPage(Index: Integer): Integer;
    /// <summary>Page indexes of a row, in order (one or two pages).</summary>
    function RowPages(Row: Integer): TArray<Integer>;
    function FirstPageOfRow(Row: Integer): Integer;
    /// <summary>True when the page has a rectangle in the current mode (always in continuous mode).</summary>
    function IsPageLaidOut(Index: Integer): Boolean;
    /// <summary>Pages that intersect the viewport at ScrollY/ScrollX, in order.</summary>
    function VisiblePages(ScrollX, ScrollY: Double): TArray<TPdfPageRect>;
    /// <summary>Page with the largest visible area; -1 when there are no pages. Ties go to the first page.</summary>
    function CurrentPage(ScrollX, ScrollY: Double): Integer;
    /// <summary>Page containing a document point, -1 when in a gap.</summary>
    function PageAt(X, Y: Double): Integer;
    /// <summary>Scroll position that puts the top of page Index one margin below the top of the viewport (clamped).
    /// In non-continuous mode a page outside the active row gives 0.</summary>
    function ScrollTopOfPage(Index: Integer): Double;
    /// <summary>Largest scroll positions (0 when the document fits).</summary>
    function MaxScrollX: Double;
    function MaxScrollY: Double;
    function ClampScrollX(Value: Double): Double;
    function ClampScrollY(Value: Double): Double;
    /// <summary>Zoom that makes the widest row fit the viewport width (minus margins and the gap between columns).
    /// In non-continuous mode only the active row counts.</summary>
    function FitWidthZoom: Double;
    /// <summary>Zoom that makes the row of page Index (or the largest row when Index &lt; 0) fit the viewport in both directions.</summary>
    function FitPageZoom(Index: Integer = -1): Double;
    /// <summary>Converts a document point to page space in points (y up, relative to the page's display box).</summary>
    function DocumentToPage(Index: Integer; X, Y: Double; out PX, PY: Double): Boolean;
    property Zoom: Double read FZoom write SetZoom;
    /// <summary>Gap between pages (vertical, and horizontal between columns) in logical pixels (not zoomed).</summary>
    property Gap: Double read FGap write SetGap;
    /// <summary>Margin around the pages in logical pixels (not zoomed).</summary>
    property Margin: Double read FMargin write SetMargin;
    property ViewportWidth: Double read FViewportWidth write SetViewportWidth;
    property ViewportHeight: Double read FViewportHeight write SetViewportHeight;
    /// <summary>1 (single pages) or 2 (facing pages).</summary>
    property Columns: Integer read FColumns write SetColumns;
    /// <summary>With two columns: the first page stands alone on the right, so that pages 2-3, 4-5 ... face each other.</summary>
    property CoverPage: Boolean read FCoverPage write SetCoverPage;
    /// <summary>True (default): all rows are stacked. False: only the row of ActivePage is laid out.</summary>
    property Continuous: Boolean read FContinuous write SetContinuous;
    /// <summary>Page whose row is shown in non-continuous mode.</summary>
    property ActivePage: Integer read FActivePage write SetActivePage;
    property RowCount: Integer read GetRowCount;
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
  FColumns := 1;
  FContinuous := True;
  FDirty := True;
end;

procedure TPdfPageLayout.SetPages(const Sizes: TArray<TSizeF>);
begin
  FPageSizes := Copy(Sizes);
  FActivePage := EnsureRange(FActivePage, 0, Max(0, Length(FPageSizes) - 1));
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

procedure TPdfPageLayout.SetColumns(const Value: Integer);
begin
  if (Value in [1, 2]) and (Value <> FColumns) then
  begin
    FColumns := Value;
    FDirty := True;
  end;
end;

procedure TPdfPageLayout.SetCoverPage(const Value: Boolean);
begin
  if Value <> FCoverPage then
  begin
    FCoverPage := Value;
    FDirty := True;
  end;
end;

procedure TPdfPageLayout.SetContinuous(const Value: Boolean);
begin
  if Value <> FContinuous then
  begin
    FContinuous := Value;
    FDirty := True;
  end;
end;

procedure TPdfPageLayout.SetActivePage(const Value: Integer);
var
  V: Integer;
begin
  V := EnsureRange(Value, 0, Max(0, Length(FPageSizes) - 1));
  if V <> FActivePage then
  begin
    FActivePage := V;
    if not FContinuous then
      FDirty := True;
  end;
end;

{ Rows }

procedure TPdfPageLayout.BuildRows;
var
  I, Row, InRow, N: Integer;
begin
  N := Length(FPageSizes);
  SetLength(FRowOfPage, N);
  SetLength(FRowFirst, N + 1);
  Row := 0;
  InRow := 0;
  for I := 0 to N - 1 do
  begin
    if InRow = 0 then
      FRowFirst[Row] := I;
    FRowOfPage[I] := Row;
    Inc(InRow);
    if (InRow >= FColumns) or ((FColumns = 2) and FCoverPage and (I = 0)) then
    begin
      Inc(Row);
      InRow := 0;
    end;
  end;
  if InRow > 0 then
    Inc(Row);
  SetLength(FRowFirst, Row + 1);
  FRowFirst[Row] := N;
end;

function TPdfPageLayout.GetRowCount: Integer;
begin
  Update;
  Result := Max(0, Length(FRowFirst) - 1);
end;

function TPdfPageLayout.RowOfPage(Index: Integer): Integer;
begin
  Update;
  if (Index >= 0) and (Index < Length(FRowOfPage)) then
    Result := FRowOfPage[Index]
  else
    Result := -1;
end;

function TPdfPageLayout.FirstPageOfRow(Row: Integer): Integer;
begin
  Update;
  if (Row >= 0) and (Row < RowCount) then
    Result := FRowFirst[Row]
  else
    Result := -1;
end;

function TPdfPageLayout.RowPages(Row: Integer): TArray<Integer>;
var
  I, N: Integer;
begin
  Result := nil;
  if (Row < 0) or (Row >= RowCount) then
    Exit;
  N := FRowFirst[Row + 1] - FRowFirst[Row];
  SetLength(Result, N);
  for I := 0 to N - 1 do
    Result[I] := FRowFirst[Row] + I;
end;

function TPdfPageLayout.SlotOfPage(Index: Integer): Integer;
begin
  if FColumns = 1 then
    Exit(0);
  if FCoverPage and (Index = 0) then
    Exit(1);
  Result := Index - FRowFirst[FRowOfPage[Index]];
end;

function TPdfPageLayout.IsPageLaidOut(Index: Integer): Boolean;
begin
  Update;
  Result := (Index >= 0) and (Index < Length(FRects)) and not FRects[Index].IsEmpty;
end;

procedure TPdfPageLayout.ColumnMaxWidths(out LeftMax, RightMax: Double);
var
  I, First, Last: Integer;
begin
  // In points. In non-continuous mode only the active row counts so that fit modes follow the shown row.
  LeftMax := 0;
  RightMax := 0;
  if Length(FPageSizes) = 0 then
    Exit;
  if FContinuous then
  begin
    First := 0;
    Last := High(FPageSizes);
  end
  else
  begin
    First := FRowFirst[FRowOfPage[FActivePage]];
    Last := FRowFirst[FRowOfPage[FActivePage] + 1] - 1;
  end;
  for I := First to Last do
    if SlotOfPage(I) = 0 then
      LeftMax := Max(LeftMax, FPageSizes[I].Width)
    else
      RightMax := Max(RightMax, FPageSizes[I].Width);
end;

procedure TPdfPageLayout.RowSizePoints(Row: Integer; out Width, Height: Double; out Pages: Integer);
var
  I: Integer;
begin
  Width := 0;
  Height := 0;
  Pages := 0;
  if (Row < 0) or (Row >= Length(FRowFirst) - 1) then
    Exit;
  for I := FRowFirst[Row] to FRowFirst[Row + 1] - 1 do
  begin
    Width := Width + FPageSizes[I].Width;
    Height := Max(Height, FPageSizes[I].Height);
    Inc(Pages);
  end;
end;

procedure TPdfPageLayout.Update;
var
  I, Row, ActiveRow: Integer;
  W, H, Y, RowH, ContentW, X, CX, LeftMax, RightMax: Double;
  Slot: Integer;
begin
  if not FDirty then
    Exit;
  FDirty := False;
  BuildRows;
  SetLength(FRects, Length(FPageSizes));
  ColumnMaxWidths(LeftMax, RightMax);
  if FColumns = 2 then
    ContentW := LeftMax * FZoom + FGap + RightMax * FZoom
  else
    ContentW := LeftMax * FZoom;
  ContentW := Max(ContentW + 2 * FMargin, FViewportWidth);
  FTotalWidth := ContentW;
  CX := ContentW / 2;
  Y := FMargin;
  if (not FContinuous) and (Length(FPageSizes) > 0) then
    ActiveRow := FRowOfPage[FActivePage]
  else
    ActiveRow := -1;
  for Row := 0 to Length(FRowFirst) - 2 do
  begin
    if (ActiveRow >= 0) and (Row <> ActiveRow) then
    begin
      for I := FRowFirst[Row] to FRowFirst[Row + 1] - 1 do
        FRects[I] := TRectF.Empty;
      Continue;
    end;
    RowH := 0;
    for I := FRowFirst[Row] to FRowFirst[Row + 1] - 1 do
    begin
      W := FPageSizes[I].Width * FZoom;
      H := FPageSizes[I].Height * FZoom;
      if FColumns = 2 then
      begin
        Slot := SlotOfPage(I);
        if Slot = 0 then
          X := CX - FGap / 2 - W
        else
          X := CX + FGap / 2;
      end
      else
        X := CX - W / 2;
      FRects[I] := TRectF.Create(X, Y, X + W, Y + H);
      RowH := Max(RowH, H);
    end;
    Y := Y + RowH + FGap;
  end;
  if Y > FMargin then
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
    if FRects[I].IsEmpty then
      Continue;
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
    if Area > Best + 1 then // a fraction of a pixel must not break the tie between facing pages
    begin
      Best := Area;
      Result := Visible[I].Index;
    end;
  end;
  if (Result < 0) and (Length(FRects) > 0) then
  begin
    if not FContinuous then
      Result := FRowFirst[FRowOfPage[FActivePage]]
    // Viewport beyond the last page or no visible area: nearest page
    else if ScrollY >= FRects[High(FRects)].Bottom then
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
    if FRects[I].IsEmpty then
      Continue;
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
  if (Index < 0) or (Index >= Length(FRects)) or FRects[Index].IsEmpty then
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
  LeftMax, RightMax, Avail: Double;
begin
  Update;
  ColumnMaxWidths(LeftMax, RightMax);
  Avail := FViewportWidth - 2 * FMargin;
  if FColumns = 2 then
    Avail := Avail - FGap;
  if (LeftMax + RightMax <= 0) or (Avail <= 0) then
    Exit(1);
  Result := Avail / (LeftMax + RightMax);
end;

function TPdfPageLayout.FitPageZoom(Index: Integer): Double;
var
  Row, Pages, N: Integer;
  W, H, RW, RH, ZW, ZH, AvailW: Double;
begin
  Update;
  W := 0;
  H := 0;
  Pages := 1;
  if (Index >= 0) and (Index < Length(FPageSizes)) then
    RowSizePoints(FRowOfPage[Index], W, H, Pages)
  else
    for Row := 0 to RowCount - 1 do
    begin
      RowSizePoints(Row, RW, RH, N);
      if RW > W then
      begin
        W := RW;
        Pages := N;
      end;
      H := Max(H, RH);
    end;
  AvailW := FViewportWidth - 2 * FMargin - FGap * (Pages - 1);
  if (W <= 0) or (H <= 0) or (AvailW <= 0) or (FViewportHeight <= 2 * FMargin) then
    Exit(1);
  ZW := AvailW / W;
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
