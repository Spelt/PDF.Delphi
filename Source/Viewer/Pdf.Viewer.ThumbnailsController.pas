{*******************************************************************************
  Pdf.Viewer.ThumbnailsController
  TPdfThumbnailsController: the framework-independent part of TPdfThumbnails,
  a vertical strip of page thumbnails for a viewer. Thumbnails are rendered by
  the viewer's own background queue (so they never block the UI and never
  compete with it for the document) and come out of the viewer's page cache;
  while a thumbnail is pending the nearest cached rendition is shown scaled.
  Clicking a thumbnail navigates the viewer; the strip follows the viewer's
  current page, document, and rotation. The FMX and VCL controls
  (FMX.PdfThumbnails, Vcl.PdfThumbnails) host it through IPdfControlHost.
*******************************************************************************}
unit Pdf.Viewer.ThumbnailsController;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math, System.Skia,
  Pdf.Viewer.Controller;

type
  TPdfThumbnailsController = class
  public const
    DefaultThumbnailWidth = 120;
    DefaultSpacing = 14;
    DefaultInset = 12;
    DefaultBackgroundColor = $FF3C3C3C;
    DefaultSelectedColor = $FF3D8BFF;
    DefaultTextColor = $FFE0E0E0;
  private const
    NumberHeight = 18;
    WheelStep = 60;
  private
    FSender: TObject;
    FHost: IPdfControlHost;
    FViewer: TPdfViewerController;
    FScrollY: Double;
    FScrollBarVisible: Boolean;
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
    procedure SetViewer(const Value: TPdfViewerController);
    procedure SetThumbnailWidth(const Value: Single);
    procedure SetSpacing(const Value: Single);
    procedure SetInset(const Value: Single);
    procedure SetBackgroundColor(const Value: TAlphaColor);
    procedure SetSelectedColor(const Value: TAlphaColor);
    procedure SetTextColor(const Value: TAlphaColor);
    procedure SetShowPageNumbers(const Value: Boolean);
    procedure ViewerChanged(Sender: TObject; Change: TPdfViewerChange);
    procedure Redraw;
    function PageCount: Integer;
    function DeviceScale: Single;
    function ViewHeight: Single;
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
    procedure SyncHostScrollBar;
    procedure SetScrollY(Value: Double);
    procedure Layout;
  public
    /// <summary>Sender is passed to OnPageClick (the hosting control).</summary>
    constructor Create(ASender: TObject; const AHost: IPdfControlHost);
    destructor Destroy; override;
    { Host side }
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF);
    procedure Resized;
    procedure ScrollBarMoved(Value: Double);
    /// <summary>The viewer's control is being destroyed: forget it without unregistering.</summary>
    procedure ViewerFreed;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; const P: TPointF);
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; const P: TPointF);
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer);
    /// <summary>Returns True and clears Key when the key was handled.</summary>
    function KeyDown(var Key: Word; Shift: TShiftState): Boolean;
    { TPdfThumbnails API }
    procedure EnsureVisible(Index: Integer);
    property Viewer: TPdfViewerController read FViewer write SetViewer;
    property ScrollY: Double read FScrollY;
    property ThumbnailWidth: Single read FThumbnailWidth write SetThumbnailWidth;
    property Spacing: Single read FSpacing write SetSpacing;
    property Inset: Single read FInset write SetInset;
    property BackgroundColor: TAlphaColor read FBackgroundColor write SetBackgroundColor;
    property SelectedColor: TAlphaColor read FSelectedColor write SetSelectedColor;
    property TextColor: TAlphaColor read FTextColor write SetTextColor;
    property ShowPageNumbers: Boolean read FShowPageNumbers write SetShowPageNumbers;
    property OnPageClick: TPdfPageChangeEvent read FOnPageClick write FOnPageClick;
  end;

implementation

{ TPdfThumbnailsController }

constructor TPdfThumbnailsController.Create(ASender: TObject; const AHost: IPdfControlHost);
begin
  inherited Create;
  FSender := ASender;
  FHost := AHost;
  FThumbnailWidth := DefaultThumbnailWidth;
  FSpacing := DefaultSpacing;
  FInset := DefaultInset;
  FBackgroundColor := DefaultBackgroundColor;
  FSelectedColor := DefaultSelectedColor;
  FTextColor := DefaultTextColor;
  FShowPageNumbers := True;
  FPressedPage := -1;
end;

destructor TPdfThumbnailsController.Destroy;
begin
  if FViewer <> nil then
    FViewer.RemoveChangeListener(ViewerChanged);
  FHost := nil;
  inherited;
end;

procedure TPdfThumbnailsController.SetViewer(const Value: TPdfViewerController);
begin
  if Value = FViewer then
    Exit;
  if FViewer <> nil then
    FViewer.RemoveChangeListener(ViewerChanged);
  FViewer := Value;
  if FViewer <> nil then
    FViewer.AddChangeListener(ViewerChanged);
  FScrollY := 0;
  Layout;
end;

procedure TPdfThumbnailsController.ViewerFreed;
begin
  FViewer := nil;
  Layout;
end;

procedure TPdfThumbnailsController.SetThumbnailWidth(const Value: Single);
begin
  FThumbnailWidth := Max(24, Value);
  Layout;
end;

procedure TPdfThumbnailsController.SetSpacing(const Value: Single);
begin
  FSpacing := Max(0, Value);
  Layout;
end;

procedure TPdfThumbnailsController.SetInset(const Value: Single);
begin
  FInset := Max(0, Value);
  Layout;
end;

procedure TPdfThumbnailsController.SetBackgroundColor(const Value: TAlphaColor);
begin
  FBackgroundColor := Value;
  Redraw;
end;

procedure TPdfThumbnailsController.SetSelectedColor(const Value: TAlphaColor);
begin
  FSelectedColor := Value;
  Redraw;
end;

procedure TPdfThumbnailsController.SetTextColor(const Value: TAlphaColor);
begin
  FTextColor := Value;
  Redraw;
end;

procedure TPdfThumbnailsController.SetShowPageNumbers(const Value: Boolean);
begin
  FShowPageNumbers := Value;
  Layout;
end;

procedure TPdfThumbnailsController.Redraw;
begin
  if FHost <> nil then
    FHost.InvalidateHost;
end;

{ Geometry }

function TPdfThumbnailsController.PageCount: Integer;
begin
  if FViewer <> nil then
    Result := FViewer.PageCount
  else
    Result := 0;
end;

function TPdfThumbnailsController.DeviceScale: Single;
begin
  Result := FHost.HostDeviceScale;
  if Result <= 0 then
    Result := 1;
end;

function TPdfThumbnailsController.ViewHeight: Single;
begin
  Result := FHost.HostSize.Height;
end;

function TPdfThumbnailsController.ThumbHeight(Index: Integer): Single;
var
  S: TSizeF;
begin
  S := FViewer.PageSize(Index);
  if S.Width <= 0 then
    Exit(FThumbnailWidth * 1.4142);
  Result := FThumbnailWidth * S.Height / S.Width;
end;

function TPdfThumbnailsController.ItemHeight(Index: Integer): Single;
begin
  Result := ThumbHeight(Index);
  if FShowPageNumbers then
    Result := Result + NumberHeight;
end;

function TPdfThumbnailsController.ItemTop(Index: Integer): Single;
var
  I: Integer;
begin
  // Pages mostly share one size; the running sum is cheap for the counts a strip shows
  Result := FInset;
  for I := 0 to Index - 1 do
    Result := Result + ItemHeight(I) + FSpacing;
end;

function TPdfThumbnailsController.ContentHeight: Single;
var
  N: Integer;
begin
  N := PageCount;
  if N = 0 then
    Exit(0);
  Result := ItemTop(N - 1) + ItemHeight(N - 1) + FInset;
end;

function TPdfThumbnailsController.ViewportWidth: Single;
begin
  Result := FHost.HostSize.Width;
  if FScrollBarVisible then
    Result := Result - FHost.HostScrollBarSize;
end;

function TPdfThumbnailsController.RenderScale(Index: Integer): Double;
var
  S: TSizeF;
begin
  S := FViewer.PageSize(Index);
  if S.Width <= 0 then
    Exit(0.2 * DeviceScale);
  Result := FThumbnailWidth * DeviceScale / S.Width;
end;

function TPdfThumbnailsController.PageAtY(Y: Single): Integer;
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

procedure TPdfThumbnailsController.UpdateScrollBar;
var
  CH, H: Single;
begin
  if FUpdatingScroll then
    Exit;
  FUpdatingScroll := True;
  try
    CH := ContentHeight;
    H := ViewHeight;
    FScrollBarVisible := CH > H + 0.5;
    FScrollY := EnsureRange(FScrollY, 0, Max(0, CH - H));
    SyncHostScrollBar;
  finally
    FUpdatingScroll := False;
  end;
end;

procedure TPdfThumbnailsController.SyncHostScrollBar;
var
  V, H: TPdfScrollBarState;
begin
  V.Visible := FScrollBarVisible;
  V.Max := ContentHeight;
  V.ViewportSize := ViewHeight;
  V.Value := FScrollY;
  V.SmallChange := WheelStep;
  H := Default(TPdfScrollBarState);
  FHost.SyncScrollBars(V, H);
end;

procedure TPdfThumbnailsController.SetScrollY(Value: Double);
begin
  Value := EnsureRange(Value, 0, Max(0, ContentHeight - ViewHeight));
  if SameValue(Value, FScrollY, 0.01) then
    Exit;
  FScrollY := Value;
  if FScrollBarVisible and not FUpdatingScroll then
  begin
    FUpdatingScroll := True;
    try
      SyncHostScrollBar;
    finally
      FUpdatingScroll := False;
    end;
  end;
  Redraw;
end;

procedure TPdfThumbnailsController.ScrollBarMoved(Value: Double);
begin
  if not FUpdatingScroll then
    SetScrollY(Value);
end;

procedure TPdfThumbnailsController.Layout;
begin
  UpdateScrollBar;
  Redraw;
end;

procedure TPdfThumbnailsController.Resized;
begin
  Layout;
end;

procedure TPdfThumbnailsController.EnsureVisible(Index: Integer);
var
  Top, H: Single;
begin
  if (Index < 0) or (Index >= PageCount) then
    Exit;
  Top := ItemTop(Index);
  H := ItemHeight(Index);
  if Top < FScrollY then
    SetScrollY(Top - FInset)
  else if Top + H > FScrollY + ViewHeight then
    SetScrollY(Top + H + FInset - ViewHeight);
end;

procedure TPdfThumbnailsController.ViewerChanged(Sender: TObject; Change: TPdfViewerChange);
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

procedure TPdfThumbnailsController.Draw(const ACanvas: ISkCanvas; const ADest: TRectF);
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
      if Top - FScrollY > ADest.Height then
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

procedure TPdfThumbnailsController.MouseDown(Button: TMouseButton; Shift: TShiftState; const P: TPointF);
begin
  if Button = TMouseButton.mbLeft then
    FPressedPage := PageAtY(P.Y);
end;

procedure TPdfThumbnailsController.MouseUp(Button: TMouseButton; Shift: TShiftState; const P: TPointF);
var
  Page: Integer;
begin
  Page := FPressedPage;
  FPressedPage := -1;
  if (Button = TMouseButton.mbLeft) and (Page >= 0) and (PageAtY(P.Y) = Page) and (FViewer <> nil) then
  begin
    FViewer.GoToPage(Page);
    if Assigned(FOnPageClick) then
      FOnPageClick(FSender, Page);
    Redraw;
  end;
end;

procedure TPdfThumbnailsController.MouseWheel(Shift: TShiftState; WheelDelta: Integer);
begin
  SetScrollY(FScrollY - WheelDelta / 120 * WheelStep);
end;

function TPdfThumbnailsController.KeyDown(var Key: Word; Shift: TShiftState): Boolean;
begin
  Result := FViewer <> nil;
  if not Result then
    Exit;
  case Key of
    vkDown, vkRight: FViewer.NextPage;
    vkUp, vkLeft: FViewer.PreviousPage;
    vkHome: FViewer.GoToPage(0);
    vkEnd: FViewer.GoToPage(FViewer.PageCount - 1);
    vkNext: SetScrollY(FScrollY + ViewHeight);
    vkPrior: SetScrollY(FScrollY - ViewHeight);
  else
    Exit(False);
  end;
  Key := 0;
end;

end.
