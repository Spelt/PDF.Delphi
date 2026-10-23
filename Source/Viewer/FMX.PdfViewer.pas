{*******************************************************************************
  FMX.PdfViewer
  TPdfViewer: an FMX control that shows a PDF document as a continuous
  vertical scroll of pages. Pages are rendered in a background thread
  (Pdf.Viewer.RenderQueue) into an LRU cache (Pdf.Viewer.Cache); the UI
  thread only draws finished ISkImages. While a sharp image is pending the
  nearest cached rendition is shown scaled. Zoom, FitWidth, FitPage, pinch
  to zoom, mouse wheel, drag panning, scroll bars and keyboard navigation.
  The behaviour lives in TPdfViewerController (Pdf.Viewer.Controller), which
  the VCL TPdfViewer (Vcl.PdfViewer) shares; this unit adds the FMX control,
  its scroll bars, input and clipboard.
*******************************************************************************}
unit FMX.PdfViewer;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math, System.Generics.Collections,
  System.Skia,
  FMX.Types, FMX.Controls, FMX.Graphics, FMX.StdCtrls, FMX.Skia, FMX.Platform,
  Pdf.Core.Document, Pdf.Core.Navigation, Pdf.Render.Text, Pdf.Viewer.Layout, Pdf.Viewer.Cache,
  Pdf.Viewer.Controller;

{$I Pdf.Viewer.Aliases.inc}

type
  [ComponentPlatformsAttribute(pidAllPlatforms)]
  TPdfViewer = class(TSkCustomControl, IPdfControlHost)
  private const
    ScrollBarWidth = 14;
  private
    FController: TPdfViewerController;
    FVScroll, FHScroll: TScrollBar;
    procedure ScrollBarChanged(Sender: TObject);
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
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean); override;
    procedure KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
    procedure DoGesture(const EventInfo: TGestureEventInfo; var Handled: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  published
    property Align;
    property Anchors;
    property CanFocus default True;
    property ClipChildren default True;
    property Cursor default crDefault;
    property DragMode;
    property EnableDragHighlight;
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
    property Touch;
    property Visible default True;
    property Width;
    property OnClick;
    property OnDblClick;
    property OnDragEnter;
    property OnDragLeave;
    property OnDragOver;
    property OnDragDrop;
    property OnDragEnd;
    property OnEnter;
    property OnExit;
    property OnGesture;
    property OnKeyDown;
    property OnKeyUp;
    property OnMouseDown;
    property OnMouseMove;
    property OnMouseUp;
    property OnMouseWheel;
    property OnPainting;
    property OnPaint;
    property OnResize;
    property OnResized;
  end;

implementation

{$I Pdf.Viewer.ApiImpl.inc}

{ TPdfViewer }

constructor TPdfViewer.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FVScroll := TScrollBar.Create(Self);
  FVScroll.Parent := Self;
  FVScroll.Stored := False;
  FVScroll.Orientation := TOrientation.Vertical;
  FVScroll.Align := TAlignLayout.Right;
  FVScroll.Width := ScrollBarWidth;
  FVScroll.Visible := False;
  FVScroll.OnChange := ScrollBarChanged;

  FHScroll := TScrollBar.Create(Self);
  FHScroll.Parent := Self;
  FHScroll.Stored := False;
  FHScroll.Orientation := TOrientation.Horizontal;
  FHScroll.Align := TAlignLayout.Bottom;
  FHScroll.Height := ScrollBarWidth;
  FHScroll.Visible := False;
  FHScroll.OnChange := ScrollBarChanged;

  FController := TPdfViewerController.Create(Self, Self);
  HitTest := True;
  CanFocus := True;
  TabStop := True;
  AutoCapture := True;
  ClipChildren := True;
  DrawCacheKind := TSkDrawCacheKind.Never;
  Touch.InteractiveGestures := Touch.InteractiveGestures + [TInteractiveGesture.Zoom, TInteractiveGesture.DoubleTap];
  SetBounds(0, 0, 400, 300);
end;

destructor TPdfViewer.Destroy;
begin
  FreeAndNil(FController);
  inherited;
end;

{ IPdfControlHost }

procedure TPdfViewer.InvalidateHost;
begin
  if not (csDestroying in ComponentState) then
    Redraw;
end;

function TPdfViewer.HostSize: TSizeF;
begin
  Result := TSizeF.Create(Width, Height);
end;

function TPdfViewer.HostDeviceScale: Single;
begin
  Result := 1;
  if Scene <> nil then
    Result := Scene.GetSceneScale;
end;

function TPdfViewer.HostScrollBarSize: Single;
begin
  Result := ScrollBarWidth;
end;

procedure TPdfViewer.SyncScrollBars(const Vertical, Horizontal: TPdfScrollBarState);

  procedure Apply(Bar: TScrollBar; const State: TPdfScrollBarState);
  begin
    Bar.Visible := State.Visible;
    if State.Visible then
    begin
      Bar.Max := State.Max;
      Bar.ViewportSize := State.ViewportSize;
      Bar.SmallChange := State.SmallChange;
      Bar.Value := State.Value;
    end;
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
var
  Svc: IFMXClipboardService;
begin
  Result := TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService, Svc);
  if Result then
    Svc.SetClipboard(Text);
end;

procedure TPdfViewer.ScrollBarChanged(Sender: TObject);
begin
  FController.ScrollBarMoved(Sender = FVScroll, TScrollBar(Sender).Value);
end;

{ Drawing and input }

procedure TPdfViewer.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
begin
  FController.Draw(ACanvas, ADest);
end;

procedure TPdfViewer.Resize;
begin
  inherited;
  if FController <> nil then
    FController.Resized;
end;

procedure TPdfViewer.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if CanFocus then
    SetFocus;
  FController.MouseDown(Button, Shift, TPointF.Create(X, Y));
end;

procedure TPdfViewer.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  FController.MouseMove(Shift, TPointF.Create(X, Y));
end;

procedure TPdfViewer.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  FController.MouseUp(Button, Shift, TPointF.Create(X, Y));
end;

procedure TPdfViewer.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  inherited;
  if Handled then
    Exit;
  FController.MouseWheel(Shift, WheelDelta);
  Handled := True;
end;

procedure TPdfViewer.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  inherited;
  FController.KeyDown(Key, KeyChar, Shift);
end;

procedure TPdfViewer.DoGesture(const EventInfo: TGestureEventInfo; var Handled: Boolean);
var
  Phase: TPdfPinchPhase;
begin
  if EventInfo.GestureID = igiZoom then
  begin
    if TInteractiveGestureFlag.gfBegin in EventInfo.Flags then
      Phase := ppBegin
    else if TInteractiveGestureFlag.gfEnd in EventInfo.Flags then
      Phase := ppEnd
    else
      Phase := ppUpdate;
    FController.Pinch(Phase, EventInfo.Distance, AbsoluteToLocal(EventInfo.Location));
    Handled := True;
  end
  else if EventInfo.GestureID = igiDoubleTap then
  begin
    FController.DoubleTap(AbsoluteToLocal(EventInfo.Location));
    Handled := True;
  end
  else
    inherited;
end;

end.
