{*******************************************************************************
  Vcl.PdfViewer
  TPdfViewer for the VCL: the same PDF viewer as FMX.PdfViewer (continuous or
  page-by-page display, background rendering, zoom, rotation, text
  selection, search, links) as a windowed VCL control drawn with Skia
  (Vcl.Skia). The behaviour lives in TPdfViewerController
  (Pdf.Viewer.Controller); this unit adds the window, native scroll bars,
  mouse, keyboard and pinch input and the clipboard. Coordinates in the API
  (ZoomAt, PageAtPoint, PointToPage) are logical pixels: client pixels
  divided by ScaleFactor.
*******************************************************************************}
unit Vcl.PdfViewer;

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math, System.Generics.Collections,
  System.Skia,
  Vcl.Controls, Vcl.StdCtrls, Vcl.Forms, Vcl.Clipbrd, Vcl.Skia,
  Pdf.Core.Document, Pdf.Core.Navigation, Pdf.Render.Text, Pdf.Viewer.Layout, Pdf.Viewer.Cache,
  Pdf.Viewer.Controller;

{$I Pdf.Viewer.Aliases.inc}

type
  TPdfViewer = class(TSkCustomWinControl, IPdfControlHost)
  private
    FController: TPdfViewerController;
    FVScroll, FHScroll: TScrollBar;
    FKeyHandled: Boolean;
    function LogicalPoint(X, Y: Integer): TPointF;
    procedure UpdateScrollBarMetrics;
    procedure ScrollBarChanged(Sender: TObject);
    procedure WMGetDlgCode(var Message: TWMGetDlgCode); message WM_GETDLGCODE;
    { IPdfControlHost }
    procedure InvalidateHost;
    function HostSize: TSizeF;
    function HostDeviceScale: Single;
    function HostScrollBarSize: Single;
    procedure SyncScrollBars(const Vertical, Horizontal: TPdfScrollBarState);
    procedure SetHostCursor(Cursor: TCursor);
    function CopyTextToClipboard(const Text: string): Boolean;
  {$I Pdf.Viewer.ApiDecl.inc}
  protected
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single); override;
    procedure Resize; override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyPress(var Key: Char); override;
    procedure DoGesture(const EventInfo: TGestureEventInfo; var Handled: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  published
    property Hint;
    property TabOrder;
    property TabStop default True;
    property OnEnter;
    property OnExit;
    property OnKeyDown;
    property OnKeyPress;
    property OnKeyUp;
    property OnMouseWheel;
  end;

implementation

{$I Pdf.Viewer.ApiImpl.inc}

{ TPdfViewer }

constructor TPdfViewer.Create(AOwner: TComponent);

  function MakeScrollBar(AKind: TScrollBarKind; AAlign: TAlign): TScrollBar;
  begin
    Result := TScrollBar.Create(Self);
    Result.Kind := AKind;
    Result.Align := AAlign;
    Result.TabStop := False;
    Result.Visible := False;
    Result.OnChange := ScrollBarChanged;
    Result.Parent := Self;
  end;

begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle - [csAcceptsControls] + [csOpaque];
  FVScroll := MakeScrollBar(sbVertical, alRight);
  FHScroll := MakeScrollBar(sbHorizontal, alBottom);
  UpdateScrollBarMetrics;
  FController := TPdfViewerController.Create(Self, Self);
  DrawCacheKind := TSkDrawCacheKind.Never;
  TabStop := True;
  Touch.InteractiveGestures := [igZoom];
  Width := 400;
  Height := 300;
end;

destructor TPdfViewer.Destroy;
begin
  FreeAndNil(FController);
  inherited;
end;

function TPdfViewer.LogicalPoint(X, Y: Integer): TPointF;
begin
  Result := TPointF.Create(X / HostDeviceScale, Y / HostDeviceScale);
end;

procedure TPdfViewer.UpdateScrollBarMetrics;
begin
  if FVScroll <> nil then
    FVScroll.Width := GetSystemMetrics(SM_CXVSCROLL);
  if FHScroll <> nil then
    FHScroll.Height := GetSystemMetrics(SM_CYHSCROLL);
end;

procedure TPdfViewer.WMGetDlgCode(var Message: TWMGetDlgCode);
begin
  inherited;
  Message.Result := Message.Result or DLGC_WANTARROWS or DLGC_WANTCHARS;
end;

{ IPdfControlHost }

procedure TPdfViewer.InvalidateHost;
begin
  if not (csDestroying in ComponentState) then
    Invalidate;
end;

function TPdfViewer.HostSize: TSizeF;
begin
  Result := TSizeF.Create(Width / HostDeviceScale, Height / HostDeviceScale);
end;

function TPdfViewer.HostDeviceScale: Single;
begin
  Result := ScaleFactor;
  if Result <= 0 then
    Result := 1;
end;

function TPdfViewer.HostScrollBarSize: Single;
begin
  Result := FVScroll.Width / HostDeviceScale;
end;

procedure TPdfViewer.SyncScrollBars(const Vertical, Horizontal: TPdfScrollBarState);

  procedure Apply(Bar: TScrollBar; const State: TPdfScrollBarState);
  var
    MaxPos, Page: Integer;
  begin
    if State.Visible then
    begin
      // Range 0..Max - 1 with a page of ViewportSize: the thumb can move to Max - ViewportSize
      MaxPos := Max(1, Ceil(State.Max) - 1);
      Page := EnsureRange(Round(State.ViewportSize), 1, MaxPos);
      Bar.PageSize := 0;
      Bar.SetParams(EnsureRange(Round(State.Value), 0, MaxPos), 0, MaxPos);
      Bar.PageSize := Page;
      Bar.SmallChange := EnsureRange(Round(State.SmallChange), 1, High(TScrollBarInc));
      Bar.LargeChange := EnsureRange(Round(State.ViewportSize * 0.9), 1, High(TScrollBarInc));
      Bar.Position := EnsureRange(Round(State.Value), 0, MaxPos);
    end;
    Bar.Visible := State.Visible;
  end;

begin
  if (FVScroll = nil) or (FHScroll = nil) then
    Exit;
  Apply(FVScroll, Vertical);
  Apply(FHScroll, Horizontal);
end;

procedure TPdfViewer.SetHostCursor(Cursor: TCursor);
begin
  Self.Cursor := Cursor;
end;

function TPdfViewer.CopyTextToClipboard(const Text: string): Boolean;
begin
  Clipboard.AsText := Text;
  Result := True;
end;

procedure TPdfViewer.ScrollBarChanged(Sender: TObject);
begin
  if FController <> nil then
    FController.ScrollBarMoved(Sender = FVScroll, TScrollBar(Sender).Position);
end;

{ Drawing and input }

procedure TPdfViewer.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
begin
  if FController <> nil then
    FController.Draw(ACanvas, ADest);
end;

procedure TPdfViewer.Resize;
begin
  inherited;
  if FController <> nil then
    FController.Resized;
end;

procedure TPdfViewer.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  UpdateScrollBarMetrics;
  if FController <> nil then
    FController.Resized;
end;

procedure TPdfViewer.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if CanFocus and not Focused then
    SetFocus;
  FController.MouseDown(Button, Shift, LogicalPoint(X, Y));
end;

procedure TPdfViewer.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  FController.MouseMove(Shift, LogicalPoint(X, Y));
end;

procedure TPdfViewer.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  FController.MouseUp(Button, Shift, LogicalPoint(X, Y));
end;

function TPdfViewer.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := inherited;
  if Result then
    Exit;
  FController.MouseWheel(Shift, WheelDelta);
  Result := True;
end;

procedure TPdfViewer.KeyDown(var Key: Word; Shift: TShiftState);
var
  KeyChar: WideChar;
begin
  inherited;
  // A key handled here must not act again through the character it generates (KeyPress)
  FKeyHandled := False;
  if Key = 0 then
    Exit;
  KeyChar := #0;
  FKeyHandled := FController.KeyDown(Key, KeyChar, Shift);
end;

procedure TPdfViewer.KeyPress(var Key: Char);
var
  VirtualKey: Word;
begin
  inherited;
  if FKeyHandled then
  begin
    FKeyHandled := False;
    Key := #0;
    Exit;
  end;
  if Key = #0 then
    Exit;
  VirtualKey := 0;
  FController.KeyDown(VirtualKey, Key, []);
end;

procedure TPdfViewer.DoGesture(const EventInfo: TGestureEventInfo; var Handled: Boolean);
var
  Phase: TPdfPinchPhase;
begin
  if EventInfo.GestureID = igiZoom then
  begin
    if gfBegin in EventInfo.Flags then
      Phase := ppBegin
    else if gfEnd in EventInfo.Flags then
      Phase := ppEnd
    else
      Phase := ppUpdate;
    FController.Pinch(Phase, EventInfo.Distance, LogicalPoint(EventInfo.Location.X, EventInfo.Location.Y));
    Handled := True;
  end
  else
    inherited;
end;

end.
