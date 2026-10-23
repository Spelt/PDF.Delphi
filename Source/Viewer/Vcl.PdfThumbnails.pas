{*******************************************************************************
  Vcl.PdfThumbnails
  TPdfThumbnails for the VCL: a vertical strip of page thumbnails for a
  Vcl.PdfViewer.TPdfViewer, the counterpart of FMX.PdfThumbnails. The
  behaviour lives in TPdfThumbnailsController
  (Pdf.Viewer.ThumbnailsController); this unit adds the window, a native
  scroll bar and mouse and keyboard input.
*******************************************************************************}
unit Vcl.PdfThumbnails;

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math, System.Skia,
  Vcl.Controls, Vcl.StdCtrls, Vcl.Forms, Vcl.Skia,
  Pdf.Viewer.Controller, Pdf.Viewer.ThumbnailsController, Vcl.PdfViewer;

type
  TPdfThumbnails = class(TSkCustomWinControl, IPdfControlHost)
  private
    FController: TPdfThumbnailsController;
    FViewer: TPdfViewer;
    FScroll: TScrollBar;
    function LogicalPoint(X, Y: Integer): TPointF;
    procedure UpdateScrollBarMetrics;
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
    procedure WMGetDlgCode(var Message: TWMGetDlgCode); message WM_GETDLGCODE;
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
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    /// <summary>Scrolls so that the thumbnail of a page is visible (centred when it was outside the view).</summary>
    procedure EnsureVisible(Index: Integer);
    property ScrollY: Double read GetScrollY;
  published
    property Hint;
    property TabOrder;
    property TabStop default True;
    property OnEnter;
    property OnExit;
    property OnKeyDown;
    property OnMouseWheel;
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
  ControlStyle := ControlStyle - [csAcceptsControls] + [csOpaque];
  FScroll := TScrollBar.Create(Self);
  FScroll.Kind := sbVertical;
  FScroll.Align := alRight;
  FScroll.TabStop := False;
  FScroll.Visible := False;
  FScroll.OnChange := ScrollChanged;
  FScroll.Parent := Self;
  UpdateScrollBarMetrics;
  FController := TPdfThumbnailsController.Create(Self, Self);
  DrawCacheKind := TSkDrawCacheKind.Never;
  TabStop := True;
  Width := 160;
  Height := 300;
end;

destructor TPdfThumbnails.Destroy;
begin
  FreeAndNil(FController);
  inherited;
end;

function TPdfThumbnails.LogicalPoint(X, Y: Integer): TPointF;
begin
  Result := TPointF.Create(X / HostDeviceScale, Y / HostDeviceScale);
end;

procedure TPdfThumbnails.UpdateScrollBarMetrics;
begin
  if FScroll <> nil then
    FScroll.Width := GetSystemMetrics(SM_CXVSCROLL);
end;

procedure TPdfThumbnails.WMGetDlgCode(var Message: TWMGetDlgCode);
begin
  inherited;
  Message.Result := Message.Result or DLGC_WANTARROWS;
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
    Invalidate;
end;

function TPdfThumbnails.HostSize: TSizeF;
begin
  Result := TSizeF.Create(Width / HostDeviceScale, Height / HostDeviceScale);
end;

function TPdfThumbnails.HostDeviceScale: Single;
begin
  Result := ScaleFactor;
  if Result <= 0 then
    Result := 1;
end;

function TPdfThumbnails.HostScrollBarSize: Single;
begin
  Result := FScroll.Width / HostDeviceScale;
end;

procedure TPdfThumbnails.SyncScrollBars(const Vertical, Horizontal: TPdfScrollBarState);
var
  MaxPos, Page: Integer;
begin
  if FScroll = nil then
    Exit;
  if Vertical.Visible then
  begin
    MaxPos := Max(1, Ceil(Vertical.Max) - 1);
    Page := EnsureRange(Round(Vertical.ViewportSize), 1, MaxPos);
    FScroll.PageSize := 0;
    FScroll.SetParams(EnsureRange(Round(Vertical.Value), 0, MaxPos), 0, MaxPos);
    FScroll.PageSize := Page;
    FScroll.SmallChange := EnsureRange(Round(Vertical.SmallChange), 1, High(TScrollBarInc));
    FScroll.LargeChange := EnsureRange(Round(Vertical.ViewportSize * 0.9), 1, High(TScrollBarInc));
    FScroll.Position := EnsureRange(Round(Vertical.Value), 0, MaxPos);
  end;
  FScroll.Visible := Vertical.Visible;
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
  if FController <> nil then
    FController.ScrollBarMoved(FScroll.Position);
end;

{ Drawing and input }

procedure TPdfThumbnails.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
begin
  if FController <> nil then
    FController.Draw(ACanvas, ADest);
end;

procedure TPdfThumbnails.Resize;
begin
  inherited;
  if FController <> nil then
    FController.Resized;
end;

procedure TPdfThumbnails.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  UpdateScrollBarMetrics;
  if FController <> nil then
    FController.Resized;
end;

procedure TPdfThumbnails.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if CanFocus and not Focused then
    SetFocus;
  FController.MouseDown(Button, Shift, LogicalPoint(X, Y));
end;

procedure TPdfThumbnails.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  FController.MouseUp(Button, Shift, LogicalPoint(X, Y));
end;

function TPdfThumbnails.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := inherited;
  if Result then
    Exit;
  FController.MouseWheel(Shift, WheelDelta);
  Result := True;
end;

procedure TPdfThumbnails.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited;
  if Key <> 0 then
    FController.KeyDown(Key, Shift);
end;

end.
