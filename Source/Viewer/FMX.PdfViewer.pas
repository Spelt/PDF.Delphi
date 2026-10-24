{*******************************************************************************
  FMX.PdfViewer
  TPdfViewer: an FMX control that shows a PDF document as a continuous
  vertical scroll of pages. Pages are rendered in a background thread
  (Pdf.Viewer.RenderQueue) into an LRU cache (Pdf.Viewer.Cache); the UI
  thread only draws finished ISkImages. While a sharp image is pending the
  nearest cached rendition is shown scaled. Zoom, FitWidth, FitPage, pinch
  to zoom, mouse wheel, drag panning (touch drags with the platform's
  momentum through TAniCalculations), scroll bars and keyboard navigation.
  The behaviour lives in TPdfViewerController (Pdf.Viewer.Controller), which
  the VCL TPdfViewer (Vcl.PdfViewer) shares; this unit adds the FMX control,
  its scroll bars, input and clipboard.
*******************************************************************************}
unit FMX.PdfViewer;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math, System.Generics.Collections,
  System.Skia,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.StdCtrls, FMX.Skia, FMX.Platform, FMX.InertialMovement,
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
    // Touch drags scroll through FMX's own inertial engine, with the platform's momentum
    FAni: TAniCalculations;
    FAniAnimation: Boolean;
    FApplyingAni: Boolean;
    FKineticScrolling: Boolean;
    // FMX reports the number of fingers only to the form (OnTouch); the viewer chains into it to notice a second
    // finger, because the mouse events then carry the position of either finger
    FTouchForm: TCommonCustomForm;
    FPrevFormTouch: TTouchEvent;
    procedure HookFormTouch;
    procedure UnhookFormTouch;
    procedure FormTouch(Sender: TObject; const Touches: TTouches; const Action: TTouchAction);
    procedure ScrollBarChanged(Sender: TObject);
    procedure SetKineticScrolling(const Value: Boolean);
    procedure AniChanged(Sender: TObject);
    procedure ControllerChanged(Sender: TObject; Change: TPdfViewerChange);
    procedure UpdateAniTargets;
    /// <summary>Ends a running momentum animation where it is.</summary>
    procedure StopAni;
    /// <summary>Ends a touch drag without momentum (a pinch took over).</summary>
    procedure CancelAniTouch;
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
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
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
    /// <summary>Touch drags scroll with the platform's momentum (FMX's TAniCalculations, as in TScrollBox):
    /// released while moving, the document keeps scrolling and slows down. Mouse drags are not affected.</summary>
    property KineticScrolling: Boolean read FKineticScrolling write SetKineticScrolling default True;
  end;

implementation

{$I Pdf.Viewer.ApiImpl.inc}

function PlatformScrollAnimation: Boolean;
var
  Svc: IFMXSystemInformationService;
begin
  Result := TPlatformServices.Current.SupportsPlatformService(IFMXSystemInformationService, Svc) and
    (TScrollingBehaviour.Animation in Svc.GetScrollingBehaviour);
end;

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
  FController.AddChangeListener(ControllerChanged);

  FAniAnimation := PlatformScrollAnimation;
  FAni := TAniCalculations.Create(Self);
  FAni.TouchTracking := [ttVertical, ttHorizontal];
  FAni.BoundsAnimation := False; // the viewer clamps its scroll position: an elastic overscroll would not show
  FAni.Animation := FAniAnimation;
  FAni.OnChanged := AniChanged;
  FKineticScrolling := True;
  FController.HostPansTouch := True;

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
  UnhookFormTouch;
  StopAni;
  FreeAndNil(FAni);
  FreeAndNil(FController);
  inherited;
end;

{ Kinetic scrolling }

procedure TPdfViewer.SetKineticScrolling(const Value: Boolean);
begin
  if Value = FKineticScrolling then
    Exit;
  FKineticScrolling := Value;
  if not Value then
  begin
    CancelAniTouch;
    StopAni;
  end;
  FController.HostPansTouch := Value;
end;

procedure TPdfViewer.UpdateAniTargets;
var
  Targets: array[0..1] of TAniCalculations.TTarget;
begin
  Targets[0].TargetType := TAniCalculations.TTargetType.Min;
  Targets[0].Point := TPointD.Create(0, 0);
  Targets[1].TargetType := TAniCalculations.TTargetType.Max;
  Targets[1].Point := TPointD.Create(FController.Layout.MaxScrollX, FController.Layout.MaxScrollY);
  FAni.SetTargets(Targets);
end;

procedure TPdfViewer.AniChanged(Sender: TObject);
begin
  if FApplyingAni or (FController = nil) then
    Exit;
  FApplyingAni := True;
  try
    FController.ScrollTo(FAni.ViewportPosition.X, FAni.ViewportPosition.Y);
  finally
    FApplyingAni := False;
  end;
end;

procedure TPdfViewer.ControllerChanged(Sender: TObject; Change: TPdfViewerChange);
begin
  // Scrolling from anywhere else (buttons, wheel, keys, navigation) or a new layout ends the momentum
  if not FApplyingAni and (Change in [vcDocument, vcZoom, vcScroll, vcRotation, vcDisplayMode]) then
    StopAni;
end;

procedure TPdfViewer.StopAni;
begin
  if (FAni = nil) or not FAniAnimation or FAni.Down then
    Exit;
  FApplyingAni := True;
  try
    // Switching the animation off clears the velocity and stops the timer
    FAni.Animation := False;
    FAni.Animation := True;
  finally
    FApplyingAni := False;
  end;
end;

procedure TPdfViewer.CancelAniTouch;
begin
  if (FAni = nil) or not FAni.Down then
    Exit;
  FApplyingAni := True;
  try
    FAni.Animation := False;
    FAni.Down := False;
    FAni.Animation := FAniAnimation;
  finally
    FApplyingAni := False;
  end;
end;

function SameMethod(const A, B: TTouchEvent): Boolean;
begin
  Result := (TMethod(A).Code = TMethod(B).Code) and (TMethod(A).Data = TMethod(B).Data);
end;

procedure TPdfViewer.HookFormTouch;
var
  Form: TCommonCustomForm;
begin
  if (Root = nil) or not (Root.GetObject is TCommonCustomForm) then
    Exit;
  Form := TCommonCustomForm(Root.GetObject);
  if (Form = FTouchForm) and SameMethod(Form.OnTouch, FormTouch) then
    Exit;
  UnhookFormTouch;
  FTouchForm := Form;
  FTouchForm.FreeNotification(Self);
  // Keep the application's own handler: FormTouch calls it first
  FPrevFormTouch := FTouchForm.OnTouch;
  FTouchForm.OnTouch := FormTouch;
end;

procedure TPdfViewer.UnhookFormTouch;
begin
  if FTouchForm = nil then
    Exit;
  if SameMethod(FTouchForm.OnTouch, FormTouch) then
    FTouchForm.OnTouch := FPrevFormTouch;
  FTouchForm.RemoveFreeNotification(Self);
  FTouchForm := nil;
  FPrevFormTouch := nil;
end;

procedure TPdfViewer.FormTouch(Sender: TObject; const Touches: TTouches; const Action: TTouchAction);
begin
  if Assigned(FPrevFormTouch) then
    FPrevFormTouch(Sender, Touches, Action);
  // A second finger: from now on the mouse events of this touch carry the position of either finger, which
  // would pan the page by the distance between them. The pinch takes over; the drag ends without a fling.
  if (Length(Touches) > 1) and (FAni <> nil) and FAni.Down then
    CancelAniTouch;
end;

procedure TPdfViewer.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if (Operation = opRemove) and (AComponent = FTouchForm) then
  begin
    FTouchForm := nil;
    FPrevFormTouch := nil;
  end;
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
  if (Button = TMouseButton.mbLeft) and (ssTouch in Shift) and FKineticScrolling then
  begin
    // A touch catches a running fling and starts tracking from the current scroll position
    StopAni;
    UpdateAniTargets;
    FApplyingAni := True;
    try
      FAni.ViewportPosition := TPointD.Create(FController.ScrollX, FController.ScrollY);
    finally
      FApplyingAni := False;
    end;
    FAni.Averaging := True;
    FAni.MouseDown(X, Y);
    HookFormTouch;
  end;
  FController.MouseDown(Button, Shift, TPointF.Create(X, Y));
end;

procedure TPdfViewer.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if FAni.Down then
    FAni.MouseMove(X, Y);
  FController.MouseMove(Shift, TPointF.Create(X, Y));
end;

procedure TPdfViewer.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if FAni.Down then
    FAni.MouseUp(X, Y);
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
    begin
      // The first finger was being tracked as a drag: the pinch takes over without a fling
      CancelAniTouch;
      Phase := ppBegin;
    end
    else if TInteractiveGestureFlag.gfEnd in EventInfo.Flags then
      Phase := ppEnd
    else
      Phase := ppUpdate;
    FController.Pinch(Phase, EventInfo.Distance, AbsoluteToLocal(EventInfo.Location));
    Handled := True;
  end
  else if EventInfo.GestureID = igiDoubleTap then
  begin
    StopAni;
    FController.DoubleTap(AbsoluteToLocal(EventInfo.Location));
    Handled := True;
  end
  else
    inherited;
end;

end.
