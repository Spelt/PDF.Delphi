{*******************************************************************************
  FMX.PdfThumbnails
  TPdfThumbnails: a vertical strip of page thumbnails for a TPdfViewer.
  Thumbnails are rendered by the viewer's own background queue (so they
  never block the UI and never compete with it for the document) and come
  out of the viewer's page cache; while a thumbnail is pending the nearest
  cached rendition is shown scaled. Clicking a thumbnail navigates the
  viewer; the strip follows the viewer's current page, document, and rotation.
*******************************************************************************}
unit FMX.PdfThumbnails;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math, System.Skia,
  FMX.Types, FMX.Controls, FMX.Graphics, FMX.StdCtrls, FMX.Skia, FMX.PdfViewer;

type
  [ComponentPlatformsAttribute(pidAllPlatforms)]
  TPdfThumbnails = class(TSkCustomControl)
  private const
    DefaultThumbnailWidth = 120;
    DefaultSpacing = 14;
    DefaultInset = 12;
    NumberHeight = 18;
    WheelStep = 60;
  private
    FViewer: TPdfViewer;
    FScroll: TScrollBar;
    FScrollY: Double;
    FThumbnailWidth: Single;
    FSpacing: Single;
    FInset: Single;
    FBackgroundColor: TAlphaColor;
    FSelectedColor: TAlphaColor;
    FTextColor: TAlphaColor;
    FShowPageNumbers: Boolean;
    FUpdatingScroll: Boolean;
    FPressedPage: Integer;
    FFont: ISkFont;
    FOnPageClick: TPdfPageChangeEvent;
    procedure SetViewer(const Value: TPdfViewer);
    procedure SetThumbnailWidth(const Value: Single);
    procedure SetSpacing(const Value: Single);
    procedure SetInset(const Value: Single);
    procedure SetBackgroundColor(const Value: TAlphaColor);
    procedure SetSelectedColor(const Value: TAlphaColor);
    procedure SetTextColor(const Value: TAlphaColor);
    procedure SetShowPageNumbers(const Value: Boolean);
    procedure ViewerChanged(Sender: TObject; Change: TPdfViewerChange);
    procedure ScrollChanged(Sender: TObject);
    function PageCount: Integer;
    function SceneScale: Single;
    /// <summary>Thumbnail image height in logical pixels for a page (width is ThumbnailWidth).</summary>
    function ThumbHeight(Index: Integer): Single;
    function ItemHeight(Index: Integer): Single;
    function ItemTop(Index: Integer): Single;
    function ContentHeight: Single;
    function ViewportWidth: Single;
    /// <summary>Device pixels per point that make the page ThumbnailWidth logical pixels wide.</summary>
    function RenderScale(Index: Integer): Double;
    function PageAtY(Y: Single): Integer;
    procedure UpdateScrollBar;
    procedure SetScrollY(Value: Double);
    procedure Layout;
  protected
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single); override;
    procedure Resize; override;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean); override;
    procedure KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    /// <summary>Scrolls so that the thumbnail of a page is visible (centred when it was outside the view).</summary>
    procedure EnsureVisible(Index: Integer);
    property ScrollY: Double read FScrollY;
  published
    property Align;
    property Anchors;
    property CanFocus default True;
    property ClipChildren default True;
    property DragMode;
    property Enabled default True;
    property Height;
    property Hint;
    property HitTest default True;
    property Margins;
    property Opacity;
    property Padding;
    property PopupMenu;
    property Position;
    property ShowHint;
    property Size;
    property TabOrder;
    property TabStop default True;
    property Visible default True;
    property Width;
    property OnClick;
    property OnDragEnter;
    property OnDragLeave;
    property OnDragOver;
    property OnDragDrop;
    property OnMouseDown;
    property OnMouseMove;
    property OnMouseUp;
    property OnMouseWheel;
    property OnResize;
    property OnResized;
    /// <summary>The viewer whose pages are shown and navigated.</summary>
    property Viewer: TPdfViewer read FViewer write SetViewer;
    /// <summary>Width of a thumbnail in logical pixels.</summary>
    property ThumbnailWidth: Single read FThumbnailWidth write SetThumbnailWidth;
    /// <summary>Vertical space between thumbnails.</summary>
    property Spacing: Single read FSpacing write SetSpacing;
    /// <summary>Space around the strip.</summary>
    property Inset: Single read FInset write SetInset;
    property BackgroundColor: TAlphaColor read FBackgroundColor write SetBackgroundColor default $FF3C3C3C;
    property SelectedColor: TAlphaColor read FSelectedColor write SetSelectedColor default $FF3D8BFF;
    property TextColor: TAlphaColor read FTextColor write SetTextColor default $FFE0E0E0;
    property ShowPageNumbers: Boolean read FShowPageNumbers write SetShowPageNumbers default True;
    /// <summary>A thumbnail was clicked (after the viewer has navigated to it).</summary>
    property OnPageClick: TPdfPageChangeEvent read FOnPageClick write FOnPageClick;
  end;

implementation

{ TPdfThumbnails }

constructor TPdfThumbnails.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FThumbnailWidth := DefaultThumbnailWidth;
  FSpacing := DefaultSpacing;
  FInset := DefaultInset;
  FBackgroundColor := $FF3C3C3C;
  FSelectedColor := $FF3D8BFF;
  FTextColor := $FFE0E0E0;
  FShowPageNumbers := True;
  FPressedPage := -1;
  HitTest := True;
  CanFocus := True;
  TabStop := True;
  AutoCapture := True;
  ClipChildren := True;
  DrawCacheKind := TSkDrawCacheKind.Never;
  SetBounds(0, 0, 160, 300);
  FScroll := TScrollBar.Create(Self);
  FScroll.Parent := Self;
  FScroll.Stored := False;
  FScroll.Orientation := TOrientation.Vertical;
  FScroll.Align := TAlignLayout.Right;
  FScroll.Width := 14;
  FScroll.Visible := False;
  FScroll.OnChange := ScrollChanged;
end;

destructor TPdfThumbnails.Destroy;
begin
  if FViewer <> nil then
    FViewer.RemoveChangeListener(ViewerChanged);
  inherited;
end;

procedure TPdfThumbnails.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if (Operation = opRemove) and (AComponent = FViewer) then
  begin
    FViewer := nil;
    Layout;
  end;
end;

procedure TPdfThumbnails.SetViewer(const Value: TPdfViewer);
begin
  if Value = FViewer then
    Exit;
  if FViewer <> nil then
  begin
    FViewer.RemoveChangeListener(ViewerChanged);
    FViewer.RemoveFreeNotification(Self);
  end;
  FViewer := Value;
  if FViewer <> nil then
  begin
    FViewer.FreeNotification(Self);
    FViewer.AddChangeListener(ViewerChanged);
  end;
  FScrollY := 0;
  Layout;
end;

procedure TPdfThumbnails.SetThumbnailWidth(const Value: Single);
begin
  FThumbnailWidth := Max(24, Value);
  Layout;
end;

procedure TPdfThumbnails.SetSpacing(const Value: Single);
begin
  FSpacing := Max(0, Value);
  Layout;
end;

procedure TPdfThumbnails.SetInset(const Value: Single);
begin
  FInset := Max(0, Value);
  Layout;
end;

procedure TPdfThumbnails.SetBackgroundColor(const Value: TAlphaColor);
begin
  FBackgroundColor := Value;
  Redraw;
end;

procedure TPdfThumbnails.SetSelectedColor(const Value: TAlphaColor);
begin
  FSelectedColor := Value;
  Redraw;
end;

procedure TPdfThumbnails.SetTextColor(const Value: TAlphaColor);
begin
  FTextColor := Value;
  Redraw;
end;

procedure TPdfThumbnails.SetShowPageNumbers(const Value: Boolean);
begin
  FShowPageNumbers := Value;
  Layout;
end;

{ Geometry }

function TPdfThumbnails.PageCount: Integer;
begin
  if FViewer <> nil then
    Result := FViewer.PageCount
  else
    Result := 0;
end;

function TPdfThumbnails.SceneScale: Single;
begin
  Result := 1;
  if Scene <> nil then
    Result := Scene.GetSceneScale;
  if Result <= 0 then
    Result := 1;
end;

function TPdfThumbnails.ThumbHeight(Index: Integer): Single;
var
  S: TSizeF;
begin
  S := FViewer.PageSize(Index);
  if S.Width <= 0 then
    Exit(FThumbnailWidth * 1.4142);
  Result := FThumbnailWidth * S.Height / S.Width;
end;

function TPdfThumbnails.ItemHeight(Index: Integer): Single;
begin
  Result := ThumbHeight(Index);
  if FShowPageNumbers then
    Result := Result + NumberHeight;
end;

function TPdfThumbnails.ItemTop(Index: Integer): Single;
var
  I: Integer;
begin
  // Pages mostly share one size; the running sum is cheap for the counts a strip shows
  Result := FInset;
  for I := 0 to Index - 1 do
    Result := Result + ItemHeight(I) + FSpacing;
end;

function TPdfThumbnails.ContentHeight: Single;
var
  N: Integer;
begin
  N := PageCount;
  if N = 0 then
    Exit(0);
  Result := ItemTop(N - 1) + ItemHeight(N - 1) + FInset;
end;

function TPdfThumbnails.ViewportWidth: Single;
begin
  Result := Width;
  if (FScroll <> nil) and FScroll.Visible then
    Result := Result - FScroll.Width;
end;

function TPdfThumbnails.RenderScale(Index: Integer): Double;
var
  S: TSizeF;
begin
  S := FViewer.PageSize(Index);
  if S.Width <= 0 then
    Exit(0.2 * SceneScale);
  Result := FThumbnailWidth * SceneScale / S.Width;
end;

function TPdfThumbnails.PageAtY(Y: Single): Integer;
var
  I: Integer;
  Top: Single;
begin
  Top := FInset;
  Y := Y + FScrollY;
  for I := 0 to PageCount - 1 do
  begin
    if (Y >= Top) and (Y < Top + ItemHeight(I)) then
      Exit(I);
    Top := Top + ItemHeight(I) + FSpacing;
    if Top > Y then
      Break;
  end;
  Result := -1;
end;

procedure TPdfThumbnails.UpdateScrollBar;
var
  CH: Single;
begin
  if (FScroll = nil) or FUpdatingScroll then
    Exit;
  FUpdatingScroll := True;
  try
    CH := ContentHeight;
    FScroll.Visible := CH > Height + 0.5;
    FScrollY := EnsureRange(FScrollY, 0, Max(0, CH - Height));
    if FScroll.Visible then
    begin
      FScroll.Max := CH;
      FScroll.ViewportSize := Height;
      FScroll.SmallChange := WheelStep;
      FScroll.Value := FScrollY;
    end;
  finally
    FUpdatingScroll := False;
  end;
end;

procedure TPdfThumbnails.SetScrollY(Value: Double);
begin
  Value := EnsureRange(Value, 0, Max(0, ContentHeight - Height));
  if SameValue(Value, FScrollY, 0.01) then
    Exit;
  FScrollY := Value;
  if (FScroll <> nil) and FScroll.Visible and not FUpdatingScroll then
  begin
    FUpdatingScroll := True;
    try
      FScroll.Value := FScrollY;
    finally
      FUpdatingScroll := False;
    end;
  end;
  Redraw;
end;

procedure TPdfThumbnails.ScrollChanged(Sender: TObject);
begin
  if not FUpdatingScroll then
    SetScrollY(FScroll.Value);
end;

procedure TPdfThumbnails.Layout;
begin
  UpdateScrollBar;
  Redraw;
end;

procedure TPdfThumbnails.Resize;
begin
  inherited;
  if FScroll <> nil then
    Layout;
end;

procedure TPdfThumbnails.EnsureVisible(Index: Integer);
var
  Top, H: Single;
begin
  if (Index < 0) or (Index >= PageCount) then
    Exit;
  Top := ItemTop(Index);
  H := ItemHeight(Index);
  if Top < FScrollY then
    SetScrollY(Top - FInset)
  else if Top + H > FScrollY + Height then
    SetScrollY(Top + H + FInset - Height);
end;

procedure TPdfThumbnails.ViewerChanged(Sender: TObject; Change: TPdfViewerChange);
begin
  case Change of
    vcDocument:
      begin
        FScrollY := 0;
        Layout;
      end;
    vcRotation:
      Layout;
    vcPage:
      begin
        if FViewer <> nil then
          EnsureVisible(FViewer.CurrentPage);
        Redraw;
      end;
    vcPageImage:
      Redraw;
  end;
end;

{ Drawing }

procedure TPdfThumbnails.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
var
  Paint: ISkPaint;
  I, N, Current: Integer;
  Top, H, X, W, VW: Single;
  R, Frame: TRectF;
  Img: ISkImage;
  Scale, ImgScale: Double;
  Sampling: TSkSamplingOptions;
  S: string;
  Pending: Integer;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;
  Paint.Color := FBackgroundColor;
  ACanvas.DrawRect(ADest, Paint);
  N := PageCount;
  if (N = 0) or (FViewer = nil) then
    Exit;
  if FFont = nil then
    FFont := TSkFont.Create(TSkTypeface.MakeDefault, 11);
  VW := ViewportWidth;
  W := FThumbnailWidth;
  X := ADest.Left + Max(FInset, (VW - W) / 2);
  Current := FViewer.CurrentPage;
  Top := FInset;
  Pending := 0;
  ACanvas.Save;
  try
    ACanvas.ClipRect(TRectF.Create(ADest.Left, ADest.Top, ADest.Left + VW, ADest.Bottom));
    for I := 0 to N - 1 do
    begin
      H := ThumbHeight(I);
      if Top - FScrollY > Height then
        Break;
      if Top + ItemHeight(I) - FScrollY >= 0 then
      begin
        R := TRectF.Create(X, ADest.Top + Top - FScrollY, X + W, ADest.Top + Top - FScrollY + H);
        if I = Current then
        begin
          Frame := R;
          Frame.Inflate(4, 4);
          Paint.Color := FSelectedColor;
          ACanvas.DrawRoundRect(Frame, 3, 3, Paint);
        end
        else
        begin
          Frame := R;
          Frame.Offset(1.5, 1.5);
          Paint.Color := $50000000;
          ACanvas.DrawRect(Frame, Paint);
        end;
        Paint.Color := TAlphaColorRec.White;
        ACanvas.DrawRect(R, Paint);
        Scale := RenderScale(I);
        if FViewer.TryGetPageImage(I, Scale, Img) then
          Sampling := TSkSamplingOptions.Create(TSkFilterMode.Linear, TSkMipmapMode.None)
        else
        begin
          // Ask for the thumbnail (nearest to the viewport first) and show whatever is cached meanwhile
          if Pending < 12 then
          begin
            FViewer.RequestPageImage(I, Scale, 3000 + Pending);
            Inc(Pending);
          end;
          if FViewer.TryGetNearestPageImage(I, Scale, Img, ImgScale) then
            Sampling := TSkSamplingOptions.Create(TSkFilterMode.Linear, TSkMipmapMode.Linear)
          else
            Img := nil;
        end;
        if Img <> nil then
          ACanvas.DrawImageRect(Img, R, Sampling);
        if FShowPageNumbers then
        begin
          S := IntToStr(I + 1);
          Paint.Color := FTextColor;
          ACanvas.DrawSimpleText(S, R.Left + (W - FFont.MeasureText(S)) / 2, R.Bottom + NumberHeight - 5, FFont, Paint);
        end;
      end;
      Top := Top + ItemHeight(I) + FSpacing;
    end;
  finally
    ACanvas.Restore;
  end;
end;

{ Input }

procedure TPdfThumbnails.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if CanFocus then
    SetFocus;
  if Button = TMouseButton.mbLeft then
    FPressedPage := PageAtY(Y);
end;

procedure TPdfThumbnails.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  P: Integer;
begin
  inherited;
  P := FPressedPage;
  FPressedPage := -1;
  if (Button = TMouseButton.mbLeft) and (P >= 0) and (PageAtY(Y) = P) and (FViewer <> nil) then
  begin
    FViewer.GoToPage(P);
    if Assigned(FOnPageClick) then
      FOnPageClick(Self, P);
    Redraw;
  end;
end;

procedure TPdfThumbnails.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  inherited;
  if Handled then
    Exit;
  SetScrollY(FScrollY - WheelDelta / 120 * WheelStep);
  Handled := True;
end;

procedure TPdfThumbnails.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  inherited;
  if FViewer = nil then
    Exit;
  case Key of
    vkDown, vkRight: FViewer.NextPage;
    vkUp, vkLeft: FViewer.PreviousPage;
    vkHome: FViewer.GoToPage(0);
    vkEnd: FViewer.GoToPage(FViewer.PageCount - 1);
    vkNext: SetScrollY(FScrollY + Height);
    vkPrior: SetScrollY(FScrollY - Height);
  else
    Exit;
  end;
  Key := 0;
end;

end.
