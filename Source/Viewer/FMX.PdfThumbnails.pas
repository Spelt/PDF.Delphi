{*******************************************************************************
  FMX.PdfThumbnails
  TPdfThumbnails: a vertical strip of page thumbnails for a TPdfViewer.
  Thumbnails are rendered by the viewer's own background queue (so they
  never block the UI and never compete with it for the document) and come
  out of the viewer's page cache; while a thumbnail is pending the nearest
  cached rendition is shown scaled. Clicking a thumbnail navigates the
  viewer; the strip follows the viewer's current page, document, and rotation.
  The behaviour lives in TPdfThumbnailsController, shared with the VCL
  TPdfThumbnails (Vcl.PdfThumbnails).
*******************************************************************************}
unit FMX.PdfThumbnails;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math, System.Skia,
  FMX.Types, FMX.Controls, FMX.Graphics, FMX.StdCtrls, FMX.Skia,
  Pdf.Viewer.Controller, Pdf.Viewer.ThumbnailsController, FMX.PdfViewer;

type
  [ComponentPlatformsAttribute(pidAllPlatforms)]
  TPdfThumbnails = class(TSkCustomControl, IPdfControlHost)
  private const
    ScrollBarWidth = 14;
  private
    FController: TPdfThumbnailsController;
    FViewer: TPdfViewer;
    FScroll: TScrollBar;
    procedure SetViewer(const Value: TPdfViewer);
    function GetScrollY: Double;
    function GetThumbnailWidth: Single;
    procedure SetThumbnailWidth(const Value: Single);
    function GetSpacing: Single;
    procedure SetSpacing(const Value: Single);
    function GetInset: Single;
    procedure SetInset(const Value: Single);
    function GetBackgroundColor: TAlphaColor;
    procedure SetBackgroundColor(const Value: TAlphaColor);
    function GetSelectedColor: TAlphaColor;
    procedure SetSelectedColor(const Value: TAlphaColor);
    function GetTextColor: TAlphaColor;
    procedure SetTextColor(const Value: TAlphaColor);
    function GetShowPageNumbers: Boolean;
    procedure SetShowPageNumbers(const Value: Boolean);
    function GetOnPageClick: TPdfPageChangeEvent;
    procedure SetOnPageClick(const Value: TPdfPageChangeEvent);
    procedure ScrollChanged(Sender: TObject);
    { IPdfControlHost }
    procedure InvalidateHost;
    function HostSize: TSizeF;
    function HostDeviceScale: Single;
    function HostScrollBarSize: Single;
    procedure SyncScrollBars(const Vertical, Horizontal: TPdfScrollBarState);
    procedure SetHostCursor(Cursor: TCursor);
    function CopyTextToClipboard(const Text: string): Boolean;
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
    property ScrollY: Double read GetScrollY;
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
    property ThumbnailWidth: Single read GetThumbnailWidth write SetThumbnailWidth;
    /// <summary>Vertical space between thumbnails.</summary>
    property Spacing: Single read GetSpacing write SetSpacing;
    /// <summary>Space around the strip.</summary>
    property Inset: Single read GetInset write SetInset;
    property BackgroundColor: TAlphaColor read GetBackgroundColor write SetBackgroundColor default $FF3C3C3C;
    property SelectedColor: TAlphaColor read GetSelectedColor write SetSelectedColor default $FF3D8BFF;
    property TextColor: TAlphaColor read GetTextColor write SetTextColor default $FFE0E0E0;
    property ShowPageNumbers: Boolean read GetShowPageNumbers write SetShowPageNumbers default True;
    /// <summary>A thumbnail was clicked (after the viewer has navigated to it).</summary>
    property OnPageClick: TPdfPageChangeEvent read GetOnPageClick write SetOnPageClick;
  end;

implementation

{ TPdfThumbnails }

constructor TPdfThumbnails.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FScroll := TScrollBar.Create(Self);
  FScroll.Parent := Self;
  FScroll.Stored := False;
  FScroll.Orientation := TOrientation.Vertical;
  FScroll.Align := TAlignLayout.Right;
  FScroll.Width := ScrollBarWidth;
  FScroll.Visible := False;
  FScroll.OnChange := ScrollChanged;
  FController := TPdfThumbnailsController.Create(Self, Self);
  HitTest := True;
  CanFocus := True;
  TabStop := True;
  AutoCapture := True;
  ClipChildren := True;
  DrawCacheKind := TSkDrawCacheKind.Never;
  SetBounds(0, 0, 160, 300);
end;

destructor TPdfThumbnails.Destroy;
begin
  FreeAndNil(FController);
  inherited;
end;

procedure TPdfThumbnails.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if (Operation = opRemove) and (AComponent = FViewer) then
  begin
    FViewer := nil;
    if FController <> nil then
      FController.ViewerFreed;
  end;
end;

procedure TPdfThumbnails.SetViewer(const Value: TPdfViewer);
begin
  if Value = FViewer then
    Exit;
  if FViewer <> nil then
    FViewer.RemoveFreeNotification(Self);
  FViewer := Value;
  if FViewer <> nil then
  begin
    FViewer.FreeNotification(Self);
    FController.Viewer := FViewer.Controller;
  end
  else
    FController.Viewer := nil;
end;

function TPdfThumbnails.GetScrollY: Double;
begin
  Result := FController.ScrollY;
end;

function TPdfThumbnails.GetThumbnailWidth: Single;
begin
  Result := FController.ThumbnailWidth;
end;

procedure TPdfThumbnails.SetThumbnailWidth(const Value: Single);
begin
  FController.ThumbnailWidth := Value;
end;

function TPdfThumbnails.GetSpacing: Single;
begin
  Result := FController.Spacing;
end;

procedure TPdfThumbnails.SetSpacing(const Value: Single);
begin
  FController.Spacing := Value;
end;

function TPdfThumbnails.GetInset: Single;
begin
  Result := FController.Inset;
end;

procedure TPdfThumbnails.SetInset(const Value: Single);
begin
  FController.Inset := Value;
end;

function TPdfThumbnails.GetBackgroundColor: TAlphaColor;
begin
  Result := FController.BackgroundColor;
end;

procedure TPdfThumbnails.SetBackgroundColor(const Value: TAlphaColor);
begin
  FController.BackgroundColor := Value;
end;

function TPdfThumbnails.GetSelectedColor: TAlphaColor;
begin
  Result := FController.SelectedColor;
end;

procedure TPdfThumbnails.SetSelectedColor(const Value: TAlphaColor);
begin
  FController.SelectedColor := Value;
end;

function TPdfThumbnails.GetTextColor: TAlphaColor;
begin
  Result := FController.TextColor;
end;

procedure TPdfThumbnails.SetTextColor(const Value: TAlphaColor);
begin
  FController.TextColor := Value;
end;

function TPdfThumbnails.GetShowPageNumbers: Boolean;
begin
  Result := FController.ShowPageNumbers;
end;

procedure TPdfThumbnails.SetShowPageNumbers(const Value: Boolean);
begin
  FController.ShowPageNumbers := Value;
end;

function TPdfThumbnails.GetOnPageClick: TPdfPageChangeEvent;
begin
  Result := FController.OnPageClick;
end;

procedure TPdfThumbnails.SetOnPageClick(const Value: TPdfPageChangeEvent);
begin
  FController.OnPageClick := Value;
end;

procedure TPdfThumbnails.EnsureVisible(Index: Integer);
begin
  FController.EnsureVisible(Index);
end;

{ IPdfControlHost }

procedure TPdfThumbnails.InvalidateHost;
begin
  if not (csDestroying in ComponentState) then
    Redraw;
end;

function TPdfThumbnails.HostSize: TSizeF;
begin
  Result := TSizeF.Create(Width, Height);
end;

function TPdfThumbnails.HostDeviceScale: Single;
begin
  Result := 1;
  if Scene <> nil then
    Result := Scene.GetSceneScale;
end;

function TPdfThumbnails.HostScrollBarSize: Single;
begin
  Result := ScrollBarWidth;
end;

procedure TPdfThumbnails.SyncScrollBars(const Vertical, Horizontal: TPdfScrollBarState);
begin
  if FScroll = nil then
    Exit;
  FScroll.Visible := Vertical.Visible;
  if Vertical.Visible then
  begin
    FScroll.Max := Vertical.Max;
    FScroll.ViewportSize := Vertical.ViewportSize;
    FScroll.SmallChange := Vertical.SmallChange;
    FScroll.Value := Vertical.Value;
  end;
end;

procedure TPdfThumbnails.SetHostCursor(Cursor: TCursor);
begin
  Self.Cursor := Cursor;
end;

function TPdfThumbnails.CopyTextToClipboard(const Text: string): Boolean;
begin
  Result := False;
end;

procedure TPdfThumbnails.ScrollChanged(Sender: TObject);
begin
  FController.ScrollBarMoved(FScroll.Value);
end;

{ Drawing and input }

procedure TPdfThumbnails.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
begin
  FController.Draw(ACanvas, ADest);
end;

procedure TPdfThumbnails.Resize;
begin
  inherited;
  if FController <> nil then
    FController.Resized;
end;

procedure TPdfThumbnails.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if CanFocus then
    SetFocus;
  FController.MouseDown(Button, Shift, TPointF.Create(X, Y));
end;

procedure TPdfThumbnails.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  FController.MouseUp(Button, Shift, TPointF.Create(X, Y));
end;

procedure TPdfThumbnails.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  inherited;
  if Handled then
    Exit;
  FController.MouseWheel(Shift, WheelDelta);
  Handled := True;
end;

procedure TPdfThumbnails.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  inherited;
  FController.KeyDown(Key, Shift);
end;

end.
