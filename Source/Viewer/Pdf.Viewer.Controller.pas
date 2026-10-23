{*******************************************************************************
  Pdf.Viewer.Controller
  TPdfViewerController: everything TPdfViewer does that does not depend on a
  UI framework. It owns the document, the layout, the page cache and the
  background render queue, keeps scroll position, zoom, rotation, display
  mode, text selection and search, draws onto an ISkCanvas and interprets
  mouse, wheel, keyboard and pinch input. Coordinates are logical pixels of
  the hosting control. The FMX and VCL controls (FMX.PdfViewer,
  Vcl.PdfViewer) are thin hosts: they forward input and paint requests here
  and implement IPdfControlHost for size, scale, scroll bars, cursor and
  clipboard.
*******************************************************************************}
unit Pdf.Viewer.Controller;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math, System.SyncObjs,
  System.Generics.Collections, System.Skia,
  Pdf.Core.Types, Pdf.Core.Document, Pdf.Core.Navigation, Pdf.Render.Skia, Pdf.Render.Text,
  Pdf.Viewer.Layout, Pdf.Viewer.Cache, Pdf.Viewer.RenderQueue;

type
  TPdfZoomMode = (zmCustom, zmFitWidth, zmFitPage);

  TPdfPageChangeEvent = procedure(Sender: TObject; PageIndex: Integer) of object;
  TPdfLoadErrorEvent = procedure(Sender: TObject; const FileName: string; E: Exception; var Handled: Boolean) of object;
  /// <summary>A link was clicked. Set Handled to stop the default handling (GoTo destinations are followed, URIs go to OnOpenURI).</summary>
  TPdfLinkClickEvent = procedure(Sender: TObject; const Action: TPdfAction; var Handled: Boolean) of object;
  TPdfOpenURIEvent = procedure(Sender: TObject; const URI: string) of object;

  TPdfSearchMatch = record
    PageIndex: Integer;
    Match: TPdfTextMatch;
  end;
  TPdfRenderErrorNotify = procedure(Sender: TObject; PageIndex: Integer; const Message: string) of object;
  /// <summary>How pages are arranged: single pages or facing pairs; continuous (all rows stacked) or one row at a time.</summary>
  TPdfDisplayMode = (dmContinuous, dmSinglePage, dmFacingContinuous, dmFacing);
  /// <summary>The document is encrypted and the password given so far was wrong (Attempt starts at 1).
  /// Return a password to try again, or set Cancel to give up silently.</summary>
  TPdfPasswordEvent = procedure(Sender: TObject; const FileName: string; Attempt: Integer; var Password: string;
    var Cancel: Boolean) of object;
  /// <summary>What changed, for companion controls registered with TPdfViewer.AddChangeListener.</summary>
  TPdfViewerChange = (vcDocument, vcPage, vcZoom, vcScroll, vcRotation, vcDisplayMode, vcPageImage, vcSelection,
    vcSearch);
  TPdfViewerChangeEvent = procedure(Sender: TObject; Change: TPdfViewerChange) of object;
  /// <summary>A background rendition finished (UI thread); Scale is the render scale it was requested at.</summary>
  TPdfPageRenderedEvent = procedure(Sender: TObject; PageIndex: Integer; Scale: Double) of object;

  /// <summary>State of one scroll bar in logical pixels: range 0..Max, ViewportSize of it visible, at Value.</summary>
  TPdfScrollBarState = record
    Visible: Boolean;
    Max: Double;
    ViewportSize: Double;
    Value: Double;
    SmallChange: Double;
  end;

  TPdfPinchPhase = (ppBegin, ppUpdate, ppEnd);

  /// <summary>What a framework control provides to the controller it hosts.</summary>
  IPdfControlHost = interface
    ['{4E0B6C51-8A3D-4F27-9C1E-2D7A5B90E3F4}']
    /// <summary>Schedules a repaint of the control.</summary>
    procedure InvalidateHost;
    /// <summary>Size of the whole control in logical pixels.</summary>
    function HostSize: TSizeF;
    /// <summary>Device pixels per logical pixel.</summary>
    function HostDeviceScale: Single;
    /// <summary>Thickness of the control's scroll bars in logical pixels.</summary>
    function HostScrollBarSize: Single;
    /// <summary>Shows, hides and positions the scroll bars. Changes the host reports back while this runs are ignored.</summary>
    procedure SyncScrollBars(const Vertical, Horizontal: TPdfScrollBarState);
    procedure SetHostCursor(Cursor: TCursor);
    /// <summary>Puts text on the clipboard; False when there is no clipboard.</summary>
    function CopyTextToClipboard(const Text: string): Boolean;
  end;

  TPdfViewerController = class
  public const
    DefaultMinZoom = 0.1;
    DefaultMaxZoom = 16;
    DefaultBackgroundColor = $FF505050;
    DefaultSelectionColor = $603399FF;
    DefaultHighlightColor = $60FFE000;
    DefaultActiveHighlightColor = $90FF8000;
    {$IF defined(ANDROID) or defined(IOS)}
    DefaultCacheLimitMB = 96;
    {$ELSE}
    DefaultCacheLimitMB = 256;
    {$ENDIF}
  private const
    ZoomStep = 1.25;
    WheelLines = 3;
    LineHeight = 40;
  private
    FSender: TObject;
    FHost: IPdfControlHost;
    FDestroying: Boolean;
    FDocument: TPdfDocument;
    FLayout: TPdfPageLayout;
    FCache: TPdfImageCache;
    FQueue: TPdfRenderQueue;
    FScrollX, FScrollY: Double;
    FZoom: Double;
    FZoomMode: TPdfZoomMode;
    FMinZoom, FMaxZoom: Double;
    FVBarVisible, FHBarVisible: Boolean;
    FUpdatingScrollBars: Boolean;
    FCurrentPage: Integer;
    FPageGap: Single;
    FPageMargin: Single;
    FBackgroundColor: TAlphaColor;
    FPageShadow: Boolean;
    FCacheLimitMB: Integer;
    FFileName: string;
    FDragging, FDragMoved: Boolean;
    FNavigation: TPdfNavigation;
    FAnnots: TObjectDictionary<Integer, TObjectList<TPdfAnnotation>>;
    FTextPages: TObjectDictionary<Integer, TPdfTextPage>;
    FPressedLink: TPdfAnnotation;
    FHoverLink: TPdfAnnotation;
    FSelecting: Boolean;
    FSelPage, FSelStart, FSelEnd: Integer;
    FSearchQuery: string;
    FSearchMatches: TList<TPdfSearchMatch>;
    FActiveMatch: Integer;
    FTextSelectionEnabled: Boolean;
    FLinksEnabled: Boolean;
    FSelectionColor, FHighlightColor, FActiveHighlightColor: TAlphaColor;
    FOnLinkClick: TPdfLinkClickEvent;
    FOnOpenURI: TPdfOpenURIEvent;
    FOnSelectionChange: TNotifyEvent;
    FDragStart: TPointF;
    FDragScroll: TPointF;
    FLastMouse: TPointF;
    FCursor: TCursor;
    FPinchStartZoom: Double;
    FPinchStartDistance: Integer;
    FRedrawQueued: Integer;
    FPrefetchPages: Integer;
    FOnPageChange: TPdfPageChangeEvent;
    FOnLoadError: TPdfLoadErrorEvent;
    FOnRenderError: TPdfRenderErrorNotify;
    FOnZoomChange: TNotifyEvent;
    FOnScroll: TNotifyEvent;
    FRenderErrors: Integer;
    FRotation: Integer;
    FDisplayMode: TPdfDisplayMode;
    FFacingCoverPage: Boolean;
    FUnrotatedSizes: TArray<TSizeF>;   // display size per page in points before Rotation
    FListeners: TList<TPdfViewerChangeEvent>;
    FOnPasswordRequest: TPdfPasswordEvent;
    FOnPageRendered: TPdfPageRenderedEvent;
    procedure DoLoad(const FileName: string; const Password: string; const LoadProc: TProc<string>);
    procedure ApplyPageSizes;
    /// <summary>Maps a point in the page's unrotated display space (points, y down; the space of TextPage and
    /// PageMatrix(Page, 1)) to the display space shown, which includes Rotation.</summary>
    function UnrotatedToView(PageIndex: Integer; const P: TPointF): TPointF;
    function ViewToUnrotated(PageIndex: Integer; const P: TPointF): TPointF;
    function UnrotatedRectToView(PageIndex: Integer; const R: TRectF): TRectF;
    procedure SetRotation(const Value: Integer);
    procedure SetDisplayMode(const Value: TPdfDisplayMode);
    procedure SetFacingCoverPage(const Value: Boolean);
    procedure ApplyDisplayMode;
    procedure Notify(Change: TPdfViewerChange);
    procedure SelectionChanged;
    /// <summary>Scrolls vertically; in non-continuous modes scrolling past the end of the row shows the next row.</summary>
    procedure ScrollOrFlip(DY: Double);
    function PageAnnotations(Index: Integer): TObjectList<TPdfAnnotation>;
    function LinkAt(const P: TPointF): TPdfAnnotation;
    function ControlToPagePoint(const P: TPointF; out PageIndex: Integer): TPointF;
    procedure WithDocumentLock(const Proc: TProc);
    procedure DrawOverlays(const ACanvas: ISkCanvas; PageIndex: Integer; const PageRectOnCanvas: TRectF);
    procedure UpdateCursor(const P: TPointF);
    procedure ScrollToPageRect(PageIndex: Integer; const Unrotated: TRectF);
    procedure PageReady(Sender: TObject; Page: Integer; Scale: Double; const Image: ISkImage);
    procedure RenderError(Sender: TObject; Page: Integer; const Message: string);
    procedure Redraw;
    procedure QueueRedraw;
    function DeviceScale: Single;
    function RenderScale: Double;
    procedure UpdateLayoutViewport;
    procedure ApplyZoomMode;
    procedure UpdateScrollBars;
    procedure SyncHostScrollBars;
    procedure SetScroll(X, Y: Double);
    procedure UpdateCurrentPage;
    procedure DoPageChange;
    procedure RequestVisiblePages;
    procedure SetZoomInternal(NewZoom: Double; const Anchor: TPointF; FromMode: Boolean);
    procedure SetZoom(const Value: Double);
    procedure SetZoomMode(const Value: TPdfZoomMode);
    procedure SetMinZoom(const Value: Double);
    procedure SetMaxZoom(const Value: Double);
    procedure SetPageGap(const Value: Single);
    procedure SetPageMargin(const Value: Single);
    procedure SetBackgroundColor(const Value: TAlphaColor);
    procedure SetPageShadow(const Value: Boolean);
    procedure SetCacheLimitMB(const Value: Integer);
    function GetPageCount: Integer;
    function GetIsLoaded: Boolean;
    procedure StartQueue;
    procedure StopQueue;
    procedure AfterLoad;
  public
    /// <summary>Sender is passed to every event (the hosting control); Host provides size, scale and scroll bars.</summary>
    constructor Create(ASender: TObject; const AHost: IPdfControlHost);
    destructor Destroy; override;
    { Host side }
    /// <summary>Paints background, pages and overlays; ADest is the control's rectangle in logical pixels.</summary>
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF);
    /// <summary>The control changed size or device scale.</summary>
    procedure Resized;
    /// <summary>The user moved a host scroll bar to Value (logical pixels).</summary>
    procedure ScrollBarMoved(Vertical: Boolean; Value: Double);
    /// <summary>Visible part of the control, without the scroll bars, in logical pixels.</summary>
    function ViewportRect: TRectF;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; const P: TPointF);
    procedure MouseMove(Shift: TShiftState; const P: TPointF);
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; const P: TPointF);
    /// <summary>Wheel input (120 per notch) at the last mouse position. Always handled.</summary>
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer);
    /// <summary>Keyboard input. Key is a vk code (System.UITypes), KeyChar the typed character (either may be 0).
    /// Returns True and clears both when the key was handled.</summary>
    function KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState): Boolean;
    /// <summary>Two-finger zoom; Distance is the finger distance in any unit, Center in logical pixels.</summary>
    procedure Pinch(Phase: TPdfPinchPhase; Distance: Integer; const Center: TPointF);
    /// <summary>Double tap: zooms in at P from fit-width, otherwise back to fit-width.</summary>
    procedure DoubleTap(const P: TPointF);
    { TPdfViewer API }
    procedure LoadFromFile(const FileName: string; const Password: string = '');
    procedure LoadFromStream(Stream: TStream; const Password: string = '');
    procedure Close;
    procedure GoToPage(Index: Integer);
    procedure NextPage;
    procedure PreviousPage;
    procedure ZoomIn;
    procedure ZoomOut;
    procedure ZoomAt(NewZoom: Double; const Anchor: TPointF);
    procedure FitWidth;
    procedure FitPage;
    procedure ScrollTo(X, Y: Double);
    procedure ScrollBy(DX, DY: Double);
    procedure RotateClockwise;
    procedure RotateCounterClockwise;
    function RowPages(Index: Integer): TArray<Integer>;
    function PageSize(Index: Integer): TSizeF;
    function RenderPageToImage(Index: Integer; Scale: Double; Background: TAlphaColor = TAlphaColorRec.White;
      ARotation: Integer = -1): ISkImage;
    procedure RequestPageImage(Index: Integer; Scale: Double; Priority: Integer = 2000);
    function TryGetPageImage(Index: Integer; Scale: Double; out Image: ISkImage): Boolean;
    function TryGetNearestPageImage(Index: Integer; Scale: Double; out Image: ISkImage; out ImageScale: Double): Boolean;
    procedure AddChangeListener(const Listener: TPdfViewerChangeEvent);
    procedure RemoveChangeListener(const Listener: TPdfViewerChangeEvent);
    function PageAtPoint(const P: TPointF): Integer;
    function Outline: TObjectList<TPdfOutlineItem>;
    function GoToDestination(const Dest: TPdfDestination): Boolean;
    procedure GoToOutlineItem(Item: TPdfOutlineItem);
    function PerformAction(const Action: TPdfAction): Boolean;
    function TextPage(Index: Integer): TPdfTextPage;
    function Find(const Query: string; CaseSensitive: Boolean = False; WholeWord: Boolean = False): Integer;
    function FindNext: Boolean;
    function FindPrevious: Boolean;
    procedure ClearSearch;
    function SearchMatchCount: Integer;
    function SearchMatch(Index: Integer): TPdfSearchMatch;
    procedure GoToMatch(Index: Integer);
    function SelectedText: string;
    function HasSelection: Boolean;
    procedure ClearSelection;
    procedure SelectPage(PageIndex: Integer);
    function CopySelection: Boolean;
    function PointToPage(const P: TPointF; out PageIndex: Integer; out PX, PY: Double): Boolean;
    property Navigation: TPdfNavigation read FNavigation;
    property ActiveMatch: Integer read FActiveMatch;
    property SearchQuery: string read FSearchQuery;
    property Document: TPdfDocument read FDocument;
    property Layout: TPdfPageLayout read FLayout;
    property Cache: TPdfImageCache read FCache;
    property PageCount: Integer read GetPageCount;
    property CurrentPage: Integer read FCurrentPage;
    property IsLoaded: Boolean read GetIsLoaded;
    property FileName: string read FFileName;
    property ScrollX: Double read FScrollX;
    property ScrollY: Double read FScrollY;
    property RenderErrors: Integer read FRenderErrors;
    property Zoom: Double read FZoom write SetZoom;
    property ZoomMode: TPdfZoomMode read FZoomMode write SetZoomMode;
    property Rotation: Integer read FRotation write SetRotation;
    property DisplayMode: TPdfDisplayMode read FDisplayMode write SetDisplayMode;
    property FacingCoverPage: Boolean read FFacingCoverPage write SetFacingCoverPage;
    property MinZoom: Double read FMinZoom write SetMinZoom;
    property MaxZoom: Double read FMaxZoom write SetMaxZoom;
    property PageGap: Single read FPageGap write SetPageGap;
    property PageMargin: Single read FPageMargin write SetPageMargin;
    property BackgroundColor: TAlphaColor read FBackgroundColor write SetBackgroundColor;
    property PageShadow: Boolean read FPageShadow write SetPageShadow;
    property CacheLimitMB: Integer read FCacheLimitMB write SetCacheLimitMB;
    property PrefetchPages: Integer read FPrefetchPages write FPrefetchPages;
    property TextSelectionEnabled: Boolean read FTextSelectionEnabled write FTextSelectionEnabled;
    property LinksEnabled: Boolean read FLinksEnabled write FLinksEnabled;
    property SelectionColor: TAlphaColor read FSelectionColor write FSelectionColor;
    property HighlightColor: TAlphaColor read FHighlightColor write FHighlightColor;
    property ActiveHighlightColor: TAlphaColor read FActiveHighlightColor write FActiveHighlightColor;
    property OnPageChange: TPdfPageChangeEvent read FOnPageChange write FOnPageChange;
    property OnLoadError: TPdfLoadErrorEvent read FOnLoadError write FOnLoadError;
    property OnPasswordRequest: TPdfPasswordEvent read FOnPasswordRequest write FOnPasswordRequest;
    property OnRenderError: TPdfRenderErrorNotify read FOnRenderError write FOnRenderError;
    property OnPageRendered: TPdfPageRenderedEvent read FOnPageRendered write FOnPageRendered;
    property OnZoomChange: TNotifyEvent read FOnZoomChange write FOnZoomChange;
    property OnScroll: TNotifyEvent read FOnScroll write FOnScroll;
    property OnLinkClick: TPdfLinkClickEvent read FOnLinkClick write FOnLinkClick;
    property OnOpenURI: TPdfOpenURIEvent read FOnOpenURI write FOnOpenURI;
    property OnSelectionChange: TNotifyEvent read FOnSelectionChange write FOnSelectionChange;
  end;

implementation

{ TPdfViewerController }

constructor TPdfViewerController.Create(ASender: TObject; const AHost: IPdfControlHost);
begin
  inherited Create;
  FSender := ASender;
  FHost := AHost;
  FDocument := TPdfDocument.Create;
  FLayout := TPdfPageLayout.Create;
  FCacheLimitMB := DefaultCacheLimitMB;
  FCache := TPdfImageCache.Create(Int64(FCacheLimitMB) * 1024 * 1024);
  FZoom := 1;
  FZoomMode := zmFitWidth;
  FMinZoom := DefaultMinZoom;
  FMaxZoom := DefaultMaxZoom;
  FPageGap := 8;
  FPageMargin := 8;
  FBackgroundColor := DefaultBackgroundColor;
  FPageShadow := True;
  FPrefetchPages := 1;
  FCurrentPage := -1;
  FLayout.Gap := FPageGap;
  FLayout.Margin := FPageMargin;
  FAnnots := TObjectDictionary<Integer, TObjectList<TPdfAnnotation>>.Create([doOwnsValues]);
  FTextPages := TObjectDictionary<Integer, TPdfTextPage>.Create([doOwnsValues]);
  FSearchMatches := TList<TPdfSearchMatch>.Create;
  FListeners := TList<TPdfViewerChangeEvent>.Create;
  FDisplayMode := dmContinuous;
  FActiveMatch := -1;
  FSelPage := -1;
  FSelStart := -1;
  FSelEnd := -1;
  FTextSelectionEnabled := True;
  FLinksEnabled := True;
  FSelectionColor := DefaultSelectionColor;
  FHighlightColor := DefaultHighlightColor;
  FActiveHighlightColor := DefaultActiveHighlightColor;
  FCursor := crDefault;
end;

destructor TPdfViewerController.Destroy;
begin
  FDestroying := True;
  StopQueue;
  // Redraw/notification closures queued by the worker still reference Self: run them now (they see FDestroying)
  if TThread.CurrentThread.ThreadID = MainThreadID then
    CheckSynchronize;
  FreeAndNil(FListeners);
  FSearchMatches.Free;
  FTextPages.Free;
  FAnnots.Free;
  FNavigation.Free;
  FDocument.Free;
  FCache.Free;
  FLayout.Free;
  FHost := nil;
  inherited;
end;

{ Loading }

procedure TPdfViewerController.StartQueue;
begin
  if FQueue <> nil then
    Exit;
  FQueue := TPdfRenderQueue.Create(FDocument, FCache);
  FQueue.Rotation := FRotation;
  FQueue.OnPageReady := PageReady;
  FQueue.OnError := RenderError;
  FQueue.Start;
end;

procedure TPdfViewerController.StopQueue;
begin
  if FQueue = nil then
    Exit;
  FQueue.Stop;
  FreeAndNil(FQueue);
end;

procedure TPdfViewerController.Close;
begin
  StopQueue;
  FCache.Clear;
  FSearchMatches.Clear;
  FSearchQuery := '';
  FActiveMatch := -1;
  FSelPage := -1;
  FSelStart := -1;
  FSelEnd := -1;
  FPressedLink := nil;
  FHoverLink := nil;
  FTextPages.Clear;
  FAnnots.Clear;
  FreeAndNil(FNavigation);
  FDocument.Close;
  FLayout.SetPages(nil);
  FScrollX := 0;
  FScrollY := 0;
  FCurrentPage := -1;
  FFileName := '';
  FRenderErrors := 0;
  FUnrotatedSizes := nil;
  UpdateScrollBars;
  Notify(vcDocument);
  Redraw;
end;

procedure TPdfViewerController.DoLoad(const FileName: string; const Password: string; const LoadProc: TProc<string>);
var
  Handled, Cancel: Boolean;
  Pwd: string;
  Attempt: Integer;
begin
  Close;
  Pwd := Password;
  Attempt := 0;
  repeat
    try
      LoadProc(Pwd);
      FFileName := FileName;
      AfterLoad;
      Exit;
    except
      on E: Exception do
      begin
        FDocument.Close;
        if (E is EPdfPasswordError) and Assigned(FOnPasswordRequest) then
        begin
          Inc(Attempt);
          Cancel := False;
          Pwd := '';
          FOnPasswordRequest(FSender, FileName, Attempt, Pwd, Cancel);
          if Cancel then
            Exit;
          Continue;
        end;
        Handled := False;
        if Assigned(FOnLoadError) then
          FOnLoadError(FSender, FileName, E, Handled);
        if not Handled then
          raise;
        Exit;
      end;
    end;
  until False;
end;

procedure TPdfViewerController.LoadFromFile(const FileName: string; const Password: string);
begin
  DoLoad(FileName, Password,
    procedure(Pwd: string)
    begin
      FDocument.LoadFromFile(FileName, Pwd);
    end);
end;

procedure TPdfViewerController.LoadFromStream(Stream: TStream; const Password: string);
var
  Start: Int64;
begin
  Start := Stream.Position;
  DoLoad('', Password,
    procedure(Pwd: string)
    begin
      Stream.Position := Start;
      FDocument.LoadFromStream(Stream, Pwd);
    end);
end;

procedure TPdfViewerController.ApplyPageSizes;
var
  Sizes: TArray<TSizeF>;
  I: Integer;
  P: TPdfPage;
begin
  // Page metrics are collected on the UI thread while the render thread is not running:
  // otherwise only the worker touches the document. Cached, so a rotation needs no document access.
  if Length(FUnrotatedSizes) <> FDocument.PageCount then
  begin
    SetLength(FUnrotatedSizes, FDocument.PageCount);
    for I := 0 to High(FUnrotatedSizes) do
    begin
      P := FDocument.Pages[I];
      FUnrotatedSizes[I] := TSizeF.Create(Max(1, P.GetDisplayWidth), Max(1, P.GetDisplayHeight));
    end;
  end;
  SetLength(Sizes, Length(FUnrotatedSizes));
  for I := 0 to High(Sizes) do
    if (FRotation = 90) or (FRotation = 270) then
      Sizes[I] := TSizeF.Create(FUnrotatedSizes[I].Height, FUnrotatedSizes[I].Width)
    else
      Sizes[I] := FUnrotatedSizes[I];
  FLayout.SetPages(Sizes);
end;

procedure TPdfViewerController.AfterLoad;
var
  I: Integer;
begin
  ApplyPageSizes;
  FLayout.ActivePage := 0;
  // Navigation data and annotations are read now, before the render thread owns the document
  FNavigation := TPdfNavigation.Create(FDocument);
  try
    FNavigation.OutlineCount;
    for I := 0 to FDocument.PageCount - 1 do
      FAnnots.Add(I, FNavigation.LoadAnnotations(FDocument.Pages[I]));
  except
    // a broken outline or annotation list must not stop the document from showing
  end;
  UpdateLayoutViewport;
  ApplyZoomMode;
  FScrollX := 0;
  FScrollY := 0;
  FCurrentPage := -1;
  StartQueue;
  UpdateScrollBars;
  Notify(vcDocument);
  UpdateCurrentPage;
  Redraw;
end;

function TPdfViewerController.GetPageCount: Integer;
begin
  Result := FLayout.PageCount;
end;

function TPdfViewerController.GetIsLoaded: Boolean;
begin
  Result := FDocument.IsLoaded;
end;

{ Background rendering }

procedure TPdfViewerController.PageReady(Sender: TObject; Page: Integer; Scale: Double; const Image: ISkImage);
begin
  QueueRedraw;
  if Assigned(FOnPageRendered) or (FListeners.Count > 0) then
    TThread.Queue(nil,
      procedure
      begin
        if FDestroying then
          Exit;
        if Assigned(FOnPageRendered) then
          FOnPageRendered(FSender, Page, Scale);
        Notify(vcPageImage);
      end);
end;

procedure TPdfViewerController.RenderError(Sender: TObject; Page: Integer; const Message: string);
begin
  TInterlocked.Increment(FRenderErrors);
  if Assigned(FOnRenderError) then
    TThread.Queue(nil,
      procedure
      begin
        if not FDestroying and Assigned(FOnRenderError) then
          FOnRenderError(FSender, Page, Message);
      end);
end;

procedure TPdfViewerController.Redraw;
begin
  if (FHost <> nil) and not FDestroying then
    FHost.InvalidateHost;
end;

procedure TPdfViewerController.QueueRedraw;
begin
  // Coalesce: one queued redraw at a time
  if TInterlocked.CompareExchange(FRedrawQueued, 1, 0) <> 0 then
    Exit;
  TThread.Queue(nil,
    procedure
    begin
      TInterlocked.Exchange(FRedrawQueued, 0);
      Redraw;
    end);
end;

function TPdfViewerController.DeviceScale: Single;
begin
  Result := FHost.HostDeviceScale;
  if Result <= 0 then
    Result := 1;
end;

function TPdfViewerController.RenderScale: Double;
begin
  Result := FZoom * DeviceScale;
end;

function TPdfViewerController.ViewportRect: TRectF;
var
  S: TSizeF;
begin
  S := FHost.HostSize;
  Result := TRectF.Create(0, 0, S.Width, S.Height);
  if FVBarVisible then
    Result.Right := Result.Right - FHost.HostScrollBarSize;
  if FHBarVisible then
    Result.Bottom := Result.Bottom - FHost.HostScrollBarSize;
end;

procedure TPdfViewerController.UpdateLayoutViewport;
var
  R: TRectF;
begin
  R := ViewportRect;
  FLayout.ViewportWidth := Max(0, R.Width);
  FLayout.ViewportHeight := Max(0, R.Height);
end;

procedure TPdfViewerController.ApplyZoomMode;
var
  Z: Double;
begin
  case FZoomMode of
    zmFitWidth: Z := FLayout.FitWidthZoom;
    zmFitPage: Z := FLayout.FitPageZoom(Max(0, FCurrentPage));
  else
    Exit;
  end;
  Z := EnsureRange(Z, FMinZoom, FMaxZoom);
  if not SameValue(Z, FZoom, 1E-6) then
  begin
    FZoom := Z;
    FLayout.Zoom := Z;
    if FQueue <> nil then
      FQueue.CancelPending;
    if Assigned(FOnZoomChange) then
      FOnZoomChange(FSender);
    Notify(vcZoom);
  end;
end;

procedure TPdfViewerController.UpdateScrollBars;
var
  NeedV, NeedH: Boolean;
begin
  if FUpdatingScrollBars then
    Exit;
  FUpdatingScrollBars := True;
  try
    // Two passes: showing one bar can make the other necessary
    FVBarVisible := False;
    FHBarVisible := False;
    UpdateLayoutViewport;
    NeedV := FLayout.TotalHeight > FLayout.ViewportHeight + 0.5;
    NeedH := FLayout.TotalWidth > FLayout.ViewportWidth + 0.5;
    FVBarVisible := NeedV and (FLayout.PageCount > 0);
    FHBarVisible := NeedH and (FLayout.PageCount > 0);
    UpdateLayoutViewport;
    NeedV := FLayout.TotalHeight > FLayout.ViewportHeight + 0.5;
    NeedH := FLayout.TotalWidth > FLayout.ViewportWidth + 0.5;
    FVBarVisible := NeedV and (FLayout.PageCount > 0);
    FHBarVisible := NeedH and (FLayout.PageCount > 0);
    UpdateLayoutViewport;
    FScrollX := FLayout.ClampScrollX(FScrollX);
    FScrollY := FLayout.ClampScrollY(FScrollY);
    SyncHostScrollBars;
  finally
    FUpdatingScrollBars := False;
  end;
end;

procedure TPdfViewerController.SyncHostScrollBars;
var
  V, H: TPdfScrollBarState;
  R: TRectF;
begin
  R := ViewportRect;
  V.Visible := FVBarVisible;
  V.Max := FLayout.TotalHeight;
  V.ViewportSize := R.Height;
  V.Value := FScrollY;
  V.SmallChange := LineHeight;
  H.Visible := FHBarVisible;
  H.Max := FLayout.TotalWidth;
  H.ViewportSize := R.Width;
  H.Value := FScrollX;
  H.SmallChange := LineHeight;
  FHost.SyncScrollBars(V, H);
end;

procedure TPdfViewerController.ScrollBarMoved(Vertical: Boolean; Value: Double);
begin
  if FUpdatingScrollBars then
    Exit;
  if Vertical then
    SetScroll(FScrollX, Value)
  else
    SetScroll(Value, FScrollY);
end;

procedure TPdfViewerController.SetScroll(X, Y: Double);
var
  NX, NY: Double;
begin
  NX := FLayout.ClampScrollX(X);
  NY := FLayout.ClampScrollY(Y);
  if SameValue(NX, FScrollX, 0.01) and SameValue(NY, FScrollY, 0.01) then
    Exit;
  FScrollX := NX;
  FScrollY := NY;
  if not FUpdatingScrollBars then
  begin
    FUpdatingScrollBars := True;
    try
      SyncHostScrollBars;
    finally
      FUpdatingScrollBars := False;
    end;
  end;
  UpdateCurrentPage;
  if Assigned(FOnScroll) then
    FOnScroll(FSender);
  Notify(vcScroll);
  Redraw;
end;

procedure TPdfViewerController.UpdateCurrentPage;
var
  P: Integer;
begin
  P := FLayout.CurrentPage(FScrollX, FScrollY);
  if P <> FCurrentPage then
  begin
    FCurrentPage := P;
    DoPageChange;
  end;
end;

procedure TPdfViewerController.DoPageChange;
begin
  if Assigned(FOnPageChange) then
    FOnPageChange(FSender, FCurrentPage);
  Notify(vcPage);
end;

procedure TPdfViewerController.Notify(Change: TPdfViewerChange);
var
  I: Integer;
begin
  if FListeners = nil then
    Exit;
  for I := FListeners.Count - 1 downto 0 do
    if I < FListeners.Count then
      FListeners[I](FSender, Change);
end;

procedure TPdfViewerController.AddChangeListener(const Listener: TPdfViewerChangeEvent);
begin
  if Assigned(Listener) and not FListeners.Contains(Listener) then
    FListeners.Add(Listener);
end;

procedure TPdfViewerController.RemoveChangeListener(const Listener: TPdfViewerChangeEvent);
begin
  if FListeners <> nil then
    FListeners.Remove(Listener);
end;

procedure TPdfViewerController.SelectionChanged;
begin
  if Assigned(FOnSelectionChange) then
    FOnSelectionChange(FSender);
  Notify(vcSelection);
end;

procedure TPdfViewerController.RequestVisiblePages;
var
  Visible: TArray<TPdfPageRect>;
  I, First, Last, P: Integer;
  Scale, Center: Double;
begin
  if FQueue = nil then
    Exit;
  Scale := RenderScale;
  Visible := FLayout.VisiblePages(FScrollX, FScrollY);
  if Length(Visible) = 0 then
    Exit;
  Center := FScrollY + FLayout.ViewportHeight / 2;
  for I := 0 to High(Visible) do
    FQueue.Request(Visible[I].Index, Scale, Round(Abs(Visible[I].Rect.CenterPoint.Y - Center) / 100));
  First := Visible[0].Index;
  Last := Visible[High(Visible)].Index;
  for I := 1 to FPrefetchPages do
  begin
    P := Last + I;
    if P < FLayout.PageCount then
      FQueue.Request(P, Scale, 1000 + I);
    P := First - I;
    if P >= 0 then
      FQueue.Request(P, Scale, 1000 + I);
  end;
end;

{ Drawing }

procedure TPdfViewerController.Draw(const ACanvas: ISkCanvas; const ADest: TRectF);
var
  Visible: TArray<TPdfPageRect>;
  I: Integer;
  R, Shadow: TRectF;
  Paint: ISkPaint;
  Img: ISkImage;
  Scale, ImgScale: Double;
  View: TRectF;
  Sampling: TSkSamplingOptions;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.Color := FBackgroundColor;
  ACanvas.DrawRect(ADest, Paint);
  if FLayout.PageCount = 0 then
    Exit;
  View := ViewportRect;
  View.Offset(ADest.Left, ADest.Top);
  ACanvas.Save;
  try
    ACanvas.ClipRect(View);
    Scale := RenderScale;
    Visible := FLayout.VisiblePages(FScrollX, FScrollY);
    Paint.AntiAlias := True;
    for I := 0 to High(Visible) do
    begin
      R := Visible[I].Rect;
      R.Offset(-FScrollX + View.Left, -FScrollY + View.Top);
      if FPageShadow then
      begin
        Shadow := R;
        Shadow.Offset(2, 2);
        Paint.Color := $60000000;
        ACanvas.DrawRect(Shadow, Paint);
      end;
      Paint.Color := TAlphaColorRec.White;
      ACanvas.DrawRect(R, Paint);
      if FCache.Get(Visible[I].Index, Scale, Img) then
        Sampling := TSkSamplingOptions.Create(TSkFilterMode.Nearest, TSkMipmapMode.None)
      else if FCache.GetNearest(Visible[I].Index, Scale, Img, ImgScale) then
        Sampling := TSkSamplingOptions.Create(TSkFilterMode.Linear, TSkMipmapMode.Linear)
      else
        Img := nil;
      if Img <> nil then
        ACanvas.DrawImageRect(Img, R, Sampling);
      DrawOverlays(ACanvas, Visible[I].Index, R);
    end;
  finally
    ACanvas.Restore;
  end;
  RequestVisiblePages;
end;

procedure TPdfViewerController.Resized;
begin
  UpdateLayoutViewport;
  ApplyZoomMode;
  UpdateScrollBars;
  UpdateCurrentPage;
  Redraw;
end;

{ Zoom }

procedure TPdfViewerController.SetZoomInternal(NewZoom: Double; const Anchor: TPointF; FromMode: Boolean);
const
  MaxPagePixels = 12000; // keeps a single page bitmap below Skia's raster limits
var
  DocX, DocY, Factor, Largest: Double;
  I: Integer;
begin
  NewZoom := EnsureRange(NewZoom, FMinZoom, FMaxZoom);
  Largest := 0;
  for I := 0 to FLayout.PageCount - 1 do
    Largest := Max(Largest, Max(FLayout.PageSizes[I].Width, FLayout.PageSizes[I].Height));
  if Largest > 0 then
    NewZoom := Min(NewZoom, MaxPagePixels / (Largest * DeviceScale));
  if SameValue(NewZoom, FZoom, 1E-6) then
    Exit;
  if not FromMode then
    FZoomMode := zmCustom;
  // Keep the document point under the anchor fixed
  DocX := FScrollX + Anchor.X;
  DocY := FScrollY + Anchor.Y;
  Factor := NewZoom / FZoom;
  FZoom := NewZoom;
  FLayout.Zoom := NewZoom;
  if FQueue <> nil then
    FQueue.CancelPending;
  UpdateScrollBars;
  FScrollX := FLayout.ClampScrollX(DocX * Factor - Anchor.X);
  FScrollY := FLayout.ClampScrollY(DocY * Factor - Anchor.Y);
  UpdateScrollBars;
  UpdateCurrentPage;
  if Assigned(FOnZoomChange) then
    FOnZoomChange(FSender);
  Redraw;
end;

procedure TPdfViewerController.SetZoom(const Value: Double);
begin
  SetZoomInternal(Value, ViewportRect.CenterPoint, False);
end;

procedure TPdfViewerController.ZoomAt(NewZoom: Double; const Anchor: TPointF);
begin
  SetZoomInternal(NewZoom, Anchor, False);
end;

procedure TPdfViewerController.ZoomIn;
begin
  Zoom := FZoom * ZoomStep;
end;

procedure TPdfViewerController.ZoomOut;
begin
  Zoom := FZoom / ZoomStep;
end;

procedure TPdfViewerController.FitWidth;
begin
  ZoomMode := zmFitWidth;
end;

procedure TPdfViewerController.FitPage;
begin
  ZoomMode := zmFitPage;
end;

procedure TPdfViewerController.SetZoomMode(const Value: TPdfZoomMode);
var
  Page: Integer;
begin
  FZoomMode := Value;
  if Value = zmCustom then
    Exit;
  Page := Max(0, FCurrentPage);
  UpdateLayoutViewport;
  ApplyZoomMode;
  UpdateScrollBars;
  if FLayout.PageCount > 0 then
  begin
    FScrollX := FLayout.ClampScrollX((FLayout.TotalWidth - FLayout.ViewportWidth) / 2);
    FScrollY := FLayout.ScrollTopOfPage(Page);
  end;
  UpdateScrollBars;
  UpdateCurrentPage;
  Redraw;
end;

procedure TPdfViewerController.SetMinZoom(const Value: Double);
begin
  FMinZoom := Max(0.01, Value);
  if FZoom < FMinZoom then
    Zoom := FMinZoom;
end;

procedure TPdfViewerController.SetMaxZoom(const Value: Double);
begin
  FMaxZoom := Max(FMinZoom, Value);
  if FZoom > FMaxZoom then
    Zoom := FMaxZoom;
end;

procedure TPdfViewerController.SetPageGap(const Value: Single);
begin
  FPageGap := Max(0, Value);
  FLayout.Gap := FPageGap;
  UpdateScrollBars;
  Redraw;
end;

procedure TPdfViewerController.SetPageMargin(const Value: Single);
begin
  FPageMargin := Max(0, Value);
  FLayout.Margin := FPageMargin;
  UpdateScrollBars;
  Redraw;
end;

procedure TPdfViewerController.SetBackgroundColor(const Value: TAlphaColor);
begin
  FBackgroundColor := Value;
  Redraw;
end;

procedure TPdfViewerController.SetPageShadow(const Value: Boolean);
begin
  FPageShadow := Value;
  Redraw;
end;

procedure TPdfViewerController.SetCacheLimitMB(const Value: Integer);
begin
  FCacheLimitMB := Max(4, Value);
  FCache.MaxBytes := Int64(FCacheLimitMB) * 1024 * 1024;
end;

{ Navigation }

procedure TPdfViewerController.GoToPage(Index: Integer);
var
  Prev: Integer;
begin
  if (Index < 0) or (Index >= FLayout.PageCount) then
    Exit;
  Prev := FCurrentPage;
  if not FLayout.IsPageLaidOut(Index) then
  begin
    // Non-continuous mode: switch to the row of the page; fit modes follow the new row
    FLayout.ActivePage := Index;
    FCurrentPage := Index;
    UpdateLayoutViewport;
    ApplyZoomMode;
    UpdateScrollBars;
    FScrollX := FLayout.ClampScrollX((FLayout.TotalWidth - FLayout.ViewportWidth) / 2);
    FScrollY := -1; // force SetScroll to apply and redraw
  end;
  SetScroll(FScrollX, FLayout.ScrollTopOfPage(Index));
  // A short last page cannot be scrolled to the top: still report it as current. Prev catches a row
  // switch in non-continuous mode, where FCurrentPage was set before scrolling.
  if (FCurrentPage <> Index) or (Prev <> Index) then
  begin
    FCurrentPage := Index;
    DoPageChange;
  end;
end;

procedure TPdfViewerController.NextPage;
begin
  GoToPage(FLayout.FirstPageOfRow(FLayout.RowOfPage(Max(0, FCurrentPage)) + 1));
end;

procedure TPdfViewerController.PreviousPage;
begin
  GoToPage(FLayout.FirstPageOfRow(FLayout.RowOfPage(Max(0, FCurrentPage)) - 1));
end;

procedure TPdfViewerController.ScrollOrFlip(DY: Double);
var
  Row: Integer;
begin
  if not FLayout.Continuous and (FLayout.PageCount > 0) then
  begin
    Row := FLayout.RowOfPage(Max(0, FCurrentPage));
    if (DY > 0) and (FScrollY >= FLayout.MaxScrollY - 0.5) and (Row + 1 < FLayout.RowCount) then
    begin
      GoToPage(FLayout.FirstPageOfRow(Row + 1));
      Exit;
    end;
    if (DY < 0) and (FScrollY <= 0.5) and (Row > 0) then
    begin
      GoToPage(FLayout.FirstPageOfRow(Row - 1));
      SetScroll(FScrollX, FLayout.MaxScrollY);
      Exit;
    end;
  end;
  ScrollBy(0, DY);
end;

function TPdfViewerController.RowPages(Index: Integer): TArray<Integer>;
begin
  Result := FLayout.RowPages(FLayout.RowOfPage(Index));
end;

function TPdfViewerController.PageSize(Index: Integer): TSizeF;
begin
  if (Index >= 0) and (Index < FLayout.PageCount) then
    Result := FLayout.PageSizes[Index]
  else
    Result := TSizeF.Create(0, 0);
end;

{ Rotation and display mode }

function TPdfViewerController.UnrotatedToView(PageIndex: Integer; const P: TPointF): TPointF;
var
  W0, H0: Single;
begin
  if (FRotation = 0) or (PageIndex < 0) or (PageIndex >= Length(FUnrotatedSizes)) then
    Exit(P);
  W0 := FUnrotatedSizes[PageIndex].Width;
  H0 := FUnrotatedSizes[PageIndex].Height;
  case FRotation of
    90:  Result := TPointF.Create(H0 - P.Y, P.X);
    180: Result := TPointF.Create(W0 - P.X, H0 - P.Y);
  else
    Result := TPointF.Create(P.Y, W0 - P.X); // 270
  end;
end;

function TPdfViewerController.ViewToUnrotated(PageIndex: Integer; const P: TPointF): TPointF;
var
  W0, H0: Single;
begin
  if (FRotation = 0) or (PageIndex < 0) or (PageIndex >= Length(FUnrotatedSizes)) then
    Exit(P);
  W0 := FUnrotatedSizes[PageIndex].Width;
  H0 := FUnrotatedSizes[PageIndex].Height;
  case FRotation of
    90:  Result := TPointF.Create(P.Y, H0 - P.X);
    180: Result := TPointF.Create(W0 - P.X, H0 - P.Y);
  else
    Result := TPointF.Create(W0 - P.Y, P.X); // 270
  end;
end;

function TPdfViewerController.UnrotatedRectToView(PageIndex: Integer; const R: TRectF): TRectF;
var
  A, B: TPointF;
begin
  if FRotation = 0 then
    Exit(R);
  A := UnrotatedToView(PageIndex, R.TopLeft);
  B := UnrotatedToView(PageIndex, R.BottomRight);
  Result := TRectF.Create(Min(A.X, B.X), Min(A.Y, B.Y), Max(A.X, B.X), Max(A.Y, B.Y));
end;

procedure TPdfViewerController.SetRotation(const Value: Integer);
var
  V, Page: Integer;
begin
  V := Value mod 360;
  if V < 0 then
    Inc(V, 360);
  V := (V div 90) * 90;
  if V = FRotation then
    Exit;
  FRotation := V;
  if not FDocument.IsLoaded then
  begin
    Notify(vcRotation);
    Exit;
  end;
  Page := Max(0, FCurrentPage);
  StopQueue;
  FCache.Clear;
  ApplyPageSizes;
  UpdateLayoutViewport;
  ApplyZoomMode;
  StartQueue;
  UpdateScrollBars;
  FScrollX := FLayout.ClampScrollX((FLayout.TotalWidth - FLayout.ViewportWidth) / 2);
  FScrollY := FLayout.ScrollTopOfPage(Page);
  UpdateScrollBars;
  UpdateCurrentPage;
  Notify(vcRotation);
  Redraw;
end;

procedure TPdfViewerController.RotateClockwise;
begin
  Rotation := FRotation + 90;
end;

procedure TPdfViewerController.RotateCounterClockwise;
begin
  Rotation := FRotation - 90;
end;

procedure TPdfViewerController.SetDisplayMode(const Value: TPdfDisplayMode);
begin
  if Value = FDisplayMode then
    Exit;
  FDisplayMode := Value;
  ApplyDisplayMode;
end;

procedure TPdfViewerController.SetFacingCoverPage(const Value: Boolean);
begin
  if Value = FFacingCoverPage then
    Exit;
  FFacingCoverPage := Value;
  ApplyDisplayMode;
end;

procedure TPdfViewerController.ApplyDisplayMode;
var
  Page: Integer;
begin
  Page := Max(0, FCurrentPage);
  if FDisplayMode in [dmFacingContinuous, dmFacing] then
    FLayout.Columns := 2
  else
    FLayout.Columns := 1;
  FLayout.CoverPage := FFacingCoverPage;
  FLayout.Continuous := FDisplayMode in [dmContinuous, dmFacingContinuous];
  FLayout.ActivePage := Page;
  Notify(vcDisplayMode);
  if FLayout.PageCount = 0 then
  begin
    Redraw;
    Exit;
  end;
  UpdateLayoutViewport;
  ApplyZoomMode;
  UpdateScrollBars;
  FScrollX := FLayout.ClampScrollX((FLayout.TotalWidth - FLayout.ViewportWidth) / 2);
  FScrollY := FLayout.ScrollTopOfPage(Page);
  UpdateScrollBars;
  UpdateCurrentPage;
  Redraw;
end;

{ Page images for companion controls }

procedure TPdfViewerController.RequestPageImage(Index: Integer; Scale: Double; Priority: Integer);
begin
  if (FQueue <> nil) and (Index >= 0) and (Index < FLayout.PageCount) and (Scale > 0) then
    FQueue.Request(Index, Scale, Priority);
end;

function TPdfViewerController.TryGetPageImage(Index: Integer; Scale: Double; out Image: ISkImage): Boolean;
begin
  Result := FCache.Get(Index, Scale, Image);
end;

function TPdfViewerController.TryGetNearestPageImage(Index: Integer; Scale: Double; out Image: ISkImage;
  out ImageScale: Double): Boolean;
begin
  Result := FCache.GetNearest(Index, Scale, Image, ImageScale);
end;

procedure TPdfViewerController.ScrollTo(X, Y: Double);
begin
  SetScroll(X, Y);
end;

procedure TPdfViewerController.ScrollBy(DX, DY: Double);
begin
  SetScroll(FScrollX + DX, FScrollY + DY);
end;

function TPdfViewerController.PageAtPoint(const P: TPointF): Integer;
begin
  Result := FLayout.PageAt(P.X + FScrollX, P.Y + FScrollY);
end;

function TPdfViewerController.PointToPage(const P: TPointF; out PageIndex: Integer; out PX, PY: Double): Boolean;
var
  PP: TPointF;
  M: TPdfMatrix;
begin
  PX := 0;
  PY := 0;
  PP := ControlToPagePoint(P, PageIndex);
  Result := PageIndex >= 0;
  if not Result then
    Exit;
  // PP is in the page's display space (points, y down); back to user space through the page matrix
  M := TPdfPageRenderer.PageMatrix(FDocument.Pages[PageIndex], 1);
  if not M.Invert(M) then
    Exit(False);
  PX := PP.X;
  PY := PP.Y;
  M.Apply(PX, PY);
end;

function TPdfViewerController.RenderPageToImage(Index: Integer; Scale: Double; Background: TAlphaColor;
  ARotation: Integer): ISkImage;
var
  R: TPdfPageRenderer;
  WasRunning: Boolean;
begin
  Result := nil;
  if (Index < 0) or (Index >= FDocument.PageCount) then
    Exit;
  if ARotation < 0 then
    ARotation := FRotation;
  WasRunning := FQueue <> nil;
  StopQueue;
  try
    R := TPdfPageRenderer.Create(FDocument);
    try
      Result := R.RenderToImage(FDocument.Pages[Index], Scale, Background, ARotation);
    finally
      R.Free;
    end;
  finally
    if WasRunning then
      StartQueue;
  end;
end;

{ Input }

procedure TPdfViewerController.MouseDown(Button: TMouseButton; Shift: TShiftState; const P: TPointF);
var
  PageIdx, G: Integer;
  PP: TPointF;
  TP: TPdfTextPage;
begin
  FLastMouse := P;
  if Button <> TMouseButton.mbLeft then
    Exit;
  FDragging := True;
  FDragMoved := False;
  FSelecting := False;
  FDragStart := P;
  FDragScroll := TPointF.Create(FScrollX, FScrollY);
  FPressedLink := nil;
  if FLinksEnabled then
    FPressedLink := LinkAt(P);
  if (FPressedLink = nil) and FTextSelectionEnabled then
  begin
    PP := ControlToPagePoint(P, PageIdx);
    if PageIdx >= 0 then
    begin
      TP := TextPage(PageIdx);
      if TP <> nil then
      begin
        G := TP.GlyphAt(PP, False);
        if G >= 0 then
        begin
          FSelecting := True;
          FSelPage := PageIdx;
          FSelStart := G;
          FSelEnd := G;
          if ssDouble in Shift then
          begin
            // Double click: select the word
            while (FSelStart > 0) and (TP.Glyph(FSelStart - 1).Line = TP.Glyph(G).Line) and
                  not TP.Glyph(FSelStart - 1).IsSpace do
              Dec(FSelStart);
            while (FSelEnd < TP.GlyphCount - 1) and (TP.Glyph(FSelEnd + 1).Line = TP.Glyph(G).Line) and
                  not TP.Glyph(FSelEnd + 1).IsSpace do
              Inc(FSelEnd);
            FSelecting := False;
          end;
          SelectionChanged;
          Redraw;
          Exit;
        end;
      end;
    end;
  end;
  if HasSelection then
    ClearSelection;
end;

procedure TPdfViewerController.MouseMove(Shift: TShiftState; const P: TPointF);
var
  PP: TPointF;
  PageIdx, G: Integer;
  TP: TPdfTextPage;
begin
  FLastMouse := P;
  if FDragging and (ssLeft in Shift) then
  begin
    if (Abs(P.X - FDragStart.X) > 2) or (Abs(P.Y - FDragStart.Y) > 2) then
      FDragMoved := True;
    if not FDragMoved then
      Exit;
    if FSelecting then
    begin
      TP := TextPage(FSelPage);
      if TP <> nil then
      begin
        PP := ControlToPagePoint(P, PageIdx);
        if PageIdx <> FSelPage then
        begin
          // Outside the page: extend to the start or end of the page's text
          if P.Y + FScrollY < FLayout.PageRect[FSelPage].Top then
            G := 0
          else
            G := TP.GlyphCount - 1;
        end
        else
          G := TP.GlyphAt(PP, True);
        if (G >= 0) and (G <> FSelEnd) then
        begin
          FSelEnd := G;
          SelectionChanged;
          Redraw;
        end;
      end;
    end
    else if FPressedLink = nil then
      SetScroll(FDragScroll.X - (P.X - FDragStart.X), FDragScroll.Y - (P.Y - FDragStart.Y));
  end
  else
    UpdateCursor(P);
end;

procedure TPdfViewerController.MouseUp(Button: TMouseButton; Shift: TShiftState; const P: TPointF);
var
  Link: TPdfAnnotation;
  Handled: Boolean;
begin
  FDragging := False;
  FSelecting := False;
  Link := FPressedLink;
  FPressedLink := nil;
  if (Button = TMouseButton.mbLeft) and (Link <> nil) and not FDragMoved and (LinkAt(P) = Link) then
  begin
    Handled := False;
    if Assigned(FOnLinkClick) then
      FOnLinkClick(FSender, Link.Action, Handled);
    if not Handled then
      PerformAction(Link.Action);
  end;
end;

procedure TPdfViewerController.MouseWheel(Shift: TShiftState; WheelDelta: Integer);
var
  Steps: Double;
begin
  Steps := WheelDelta / 120;
  if ssCtrl in Shift then
    ZoomAt(FZoom * Power(1.1, Steps), FLastMouse)
  else if ssShift in Shift then
    ScrollBy(-Steps * WheelLines * LineHeight, 0)
  else
    ScrollOrFlip(-Steps * WheelLines * LineHeight);
end;

function TPdfViewerController.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState): Boolean;
var
  PageStep: Double;
begin
  Result := True;
  PageStep := Max(LineHeight, FLayout.ViewportHeight - LineHeight);
  case Key of
    vkDown: ScrollBy(0, LineHeight);
    vkUp: ScrollBy(0, -LineHeight);
    vkLeft: ScrollBy(-LineHeight, 0);
    vkRight: ScrollBy(LineHeight, 0);
    vkNext: if ssCtrl in Shift then NextPage else ScrollOrFlip(PageStep);
    vkPrior: if ssCtrl in Shift then PreviousPage else ScrollOrFlip(-PageStep);
    vkHome: if ssCtrl in Shift then GoToPage(0) else ScrollTo(FScrollX, 0);
    vkEnd: if ssCtrl in Shift then GoToPage(PageCount - 1) else ScrollTo(FScrollX, FLayout.MaxScrollY);
    vkAdd: ZoomIn;
    vkSubtract: ZoomOut;
    vkF3: if ssShift in Shift then FindPrevious else FindNext;
    vkEscape:
      begin
        ClearSelection;
        ClearSearch;
      end;
  else
    if (ssCtrl in Shift) and ((KeyChar = 'c') or (KeyChar = 'C') or (Key = vkC)) then
      CopySelection
    else if (ssCtrl in Shift) and ((KeyChar = 'a') or (KeyChar = 'A') or (Key = vkA)) then
      SelectPage(Max(0, FCurrentPage))
    else
      case KeyChar of
        '+', '=': ZoomIn;
        '-': ZoomOut;
        '0': FitWidth;
      else
        Exit(False);
      end;
  end;
  Key := 0;
  KeyChar := #0;
end;

procedure TPdfViewerController.Pinch(Phase: TPdfPinchPhase; Distance: Integer; const Center: TPointF);
begin
  case Phase of
    ppBegin:
      begin
        FPinchStartZoom := FZoom;
        FPinchStartDistance := Max(1, Distance);
      end;
    ppUpdate:
      if FPinchStartDistance > 0 then
        ZoomAt(FPinchStartZoom * Distance / FPinchStartDistance, Center);
  end;
end;

procedure TPdfViewerController.DoubleTap(const P: TPointF);
begin
  if FZoomMode = zmFitWidth then
    ZoomAt(FZoom * 2, P)
  else
    FitWidth;
end;

{ Links, outline, text }

function TPdfViewerController.PageAnnotations(Index: Integer): TObjectList<TPdfAnnotation>;
begin
  if not FAnnots.TryGetValue(Index, Result) then
    Result := nil;
end;

function TPdfViewerController.LinkAt(const P: TPointF): TPdfAnnotation;
var
  PageIdx: Integer;
  PP: TPointF;
  List: TObjectList<TPdfAnnotation>;
  A: TPdfAnnotation;
  M: TPdfMatrix;
  X, Y: Double;
begin
  Result := nil;
  PP := ControlToPagePoint(P, PageIdx);
  if PageIdx < 0 then
    Exit;
  List := PageAnnotations(PageIdx);
  if List = nil then
    Exit;
  // PP is in display space (points, y down); annotation rects are in user space
  M := TPdfPageRenderer.PageMatrix(FDocument.Pages[PageIdx], 1);
  if not M.Invert(M) then
    Exit;
  X := PP.X;
  Y := PP.Y;
  M.Apply(X, Y);
  for A in List do
    if A.IsLink and A.IsVisible and (A.Action.Kind <> akNone) and
       (X >= A.Rect.X0) and (X <= A.Rect.X1) and (Y >= A.Rect.Y0) and (Y <= A.Rect.Y1) then
      Exit(A);
end;

function TPdfViewerController.ControlToPagePoint(const P: TPointF; out PageIndex: Integer): TPointF;
var
  R: TRectF;
begin
  Result := TPointF.Zero;
  PageIndex := PageAtPoint(P);
  if PageIndex < 0 then
    Exit;
  R := FLayout.PageRect[PageIndex];
  Result := ViewToUnrotated(PageIndex,
    TPointF.Create((P.X + FScrollX - R.Left) / FZoom, (P.Y + FScrollY - R.Top) / FZoom));
end;

procedure TPdfViewerController.WithDocumentLock(const Proc: TProc);
var
  WasRunning: Boolean;
begin
  WasRunning := FQueue <> nil;
  StopQueue;
  try
    Proc;
  finally
    if WasRunning then
      StartQueue;
  end;
end;

function TPdfViewerController.TextPage(Index: Integer): TPdfTextPage;
var
  TP: TPdfTextPage;
begin
  if (Index < 0) or (Index >= FDocument.PageCount) then
    Exit(nil);
  if FTextPages.TryGetValue(Index, Result) then
    Exit;
  TP := nil;
  WithDocumentLock(
    procedure
    begin
      TP := TPdfTextPage.Extract(FDocument.Pages[Index], TPdfPageRenderer.PageMatrix(FDocument.Pages[Index], 1));
    end);
  FTextPages.Add(Index, TP);
  Result := TP;
end;

procedure TPdfViewerController.DrawOverlays(const ACanvas: ISkCanvas; PageIndex: Integer;
  const PageRectOnCanvas: TRectF);
var
  Paint: ISkPaint;
  I: Integer;
  R: TRectF;
  TP: TPdfTextPage;
  Rects: TArray<TRectF>;

  function Map(const Unrotated: TRectF): TRectF;
  var
    PR: TRectF;
  begin
    PR := UnrotatedRectToView(PageIndex, Unrotated);
    Result := TRectF.Create(PageRectOnCanvas.Left + PR.Left * FZoom, PageRectOnCanvas.Top + PR.Top * FZoom,
      PageRectOnCanvas.Left + PR.Right * FZoom, PageRectOnCanvas.Top + PR.Bottom * FZoom);
  end;

begin
  if (FSearchMatches.Count = 0) and (FSelPage <> PageIndex) then
    Exit;
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;
  for I := 0 to FSearchMatches.Count - 1 do
    if FSearchMatches[I].PageIndex = PageIndex then
    begin
      if I = FActiveMatch then
        Paint.Color := FActiveHighlightColor
      else
        Paint.Color := FHighlightColor;
      for R in FSearchMatches[I].Match.Rects do
        ACanvas.DrawRect(Map(R), Paint);
    end;
  if (FSelPage = PageIndex) and (FSelStart >= 0) and (FSelEnd >= 0) and FTextPages.TryGetValue(PageIndex, TP) then
  begin
    Paint.Color := FSelectionColor;
    Rects := TP.SelectionRects(FSelStart, FSelEnd);
    for R in Rects do
      ACanvas.DrawRect(Map(R), Paint);
  end;
end;

procedure TPdfViewerController.UpdateCursor(const P: TPointF);
var
  NewCursor: TCursor;
  PageIdx: Integer;
  PP: TPointF;
  TP: TPdfTextPage;
  Link: TPdfAnnotation;
begin
  NewCursor := crDefault;
  Link := nil;
  if FLinksEnabled then
    Link := LinkAt(P);
  if Link <> nil then
    NewCursor := crHandPoint
  else if FTextSelectionEnabled then
  begin
    PP := ControlToPagePoint(P, PageIdx);
    // Only consult already extracted pages here: extraction pauses the renderer
    if (PageIdx >= 0) and FTextPages.TryGetValue(PageIdx, TP) and (TP.GlyphAt(PP, False) >= 0) then
      NewCursor := crIBeam;
  end;
  FHoverLink := Link;
  if FCursor <> NewCursor then
  begin
    FCursor := NewCursor;
    FHost.SetHostCursor(NewCursor);
  end;
end;

function TPdfViewerController.Outline: TObjectList<TPdfOutlineItem>;
begin
  if FNavigation = nil then
    Exit(nil);
  FNavigation.OutlineCount;
  Result := FNavigation.Outline;
end;

procedure TPdfViewerController.ScrollToPageRect(PageIndex: Integer; const Unrotated: TRectF);
var
  PR, R: TRectF;
  Y, X: Double;
begin
  if not FLayout.IsPageLaidOut(PageIndex) then
    GoToPage(PageIndex);
  R := UnrotatedRectToView(PageIndex, Unrotated);
  PR := FLayout.PageRect[PageIndex];
  Y := PR.Top + R.Top * FZoom - FLayout.ViewportHeight / 3;
  X := FScrollX;
  if (PR.Left + R.Right * FZoom < FScrollX) or (PR.Left + R.Left * FZoom > FScrollX + FLayout.ViewportWidth) then
    X := PR.Left + R.Left * FZoom - FLayout.ViewportWidth / 3;
  SetScroll(X, Y);
end;

function TPdfViewerController.GoToDestination(const Dest: TPdfDestination): Boolean;
var
  Page: TPdfPage;
  M: TPdfMatrix;
  X, Y: Double;
  PR: TRectF;
  Pt: TPointF;
begin
  Result := Dest.IsValid and (Dest.PageIndex < FLayout.PageCount);
  if not Result then
    Exit;
  Page := FDocument.Pages[Dest.PageIndex];
  case Dest.Kind of
    dkFit, dkFitB:
      begin
        FZoomMode := zmFitPage;
        FCurrentPage := Dest.PageIndex;
        ZoomMode := zmFitPage;
        GoToPage(Dest.PageIndex);
      end;
    dkFitH, dkFitBH, dkFitV, dkFitBV, dkXYZ, dkFitR:
      begin
        if (Dest.Kind in [dkFitH, dkFitBH]) and (FZoomMode <> zmFitWidth) then
          FitWidth
        else if (Dest.Kind = dkXYZ) and Dest.HasZoom then
          Zoom := Dest.Zoom;
        if not FLayout.IsPageLaidOut(Dest.PageIndex) then
          GoToPage(Dest.PageIndex);
        M := TPdfPageRenderer.PageMatrix(Page, 1);
        PR := FLayout.PageRect[Dest.PageIndex];
        if Dest.HasLeft then
          X := Dest.Left
        else
          X := Page.CropBox.X0;
        if Dest.HasTop then
          Y := Dest.Top
        else
          Y := Page.CropBox.Y1;
        M.Apply(X, Y);
        Pt := UnrotatedToView(Dest.PageIndex, TPointF.Create(X, Y));
        SetScroll(PR.Left + Pt.X * FZoom - FPageMargin, PR.Top + Pt.Y * FZoom - FPageMargin);
        if FCurrentPage <> Dest.PageIndex then
        begin
          FCurrentPage := Dest.PageIndex;
          DoPageChange;
        end;
      end;
  else
    GoToPage(Dest.PageIndex);
  end;
end;

procedure TPdfViewerController.GoToOutlineItem(Item: TPdfOutlineItem);
begin
  if Item = nil then
    Exit;
  if Item.Dest.IsValid then
    GoToDestination(Item.Dest)
  else
    PerformAction(Item.Action);
end;

function TPdfViewerController.PerformAction(const Action: TPdfAction): Boolean;
begin
  Result := False;
  case Action.Kind of
    akGoTo:
      Result := GoToDestination(Action.Dest);
    akURI:
      if Assigned(FOnOpenURI) and (Action.Target <> '') then
      begin
        FOnOpenURI(FSender, Action.Target);
        Result := True;
      end;
    akNamed:
      begin
        Result := True;
        if Action.Target = 'NextPage' then
          NextPage
        else if Action.Target = 'PrevPage' then
          PreviousPage
        else if Action.Target = 'FirstPage' then
          GoToPage(0)
        else if Action.Target = 'LastPage' then
          GoToPage(PageCount - 1)
        else
          Result := False;
      end;
  end;
end;

function TPdfViewerController.Find(const Query: string; CaseSensitive, WholeWord: Boolean): Integer;
var
  I: Integer;
  TP: TPdfTextPage;
  Matches: TArray<TPdfTextMatch>;
  M: TPdfTextMatch;
  SM: TPdfSearchMatch;
  First: Integer;
begin
  FSearchMatches.Clear;
  FActiveMatch := -1;
  FSearchQuery := Query;
  if (Query = '') or not FDocument.IsLoaded then
  begin
    Redraw;
    Exit(0);
  end;
  First := -1;
  for I := 0 to FDocument.PageCount - 1 do
  begin
    TP := TextPage(I);
    if TP = nil then
      Continue;
    Matches := TP.Find(Query, CaseSensitive, WholeWord);
    for M in Matches do
    begin
      SM.PageIndex := I;
      SM.Match := M;
      FSearchMatches.Add(SM);
      if (First < 0) and (I >= Max(0, FCurrentPage)) then
        First := FSearchMatches.Count - 1;
    end;
  end;
  Result := FSearchMatches.Count;
  if Result > 0 then
  begin
    if First < 0 then
      First := 0;
    GoToMatch(First);
  end
  else
  begin
    Notify(vcSearch);
    Redraw;
  end;
end;

procedure TPdfViewerController.GoToMatch(Index: Integer);
var
  SM: TPdfSearchMatch;
begin
  if (Index < 0) or (Index >= FSearchMatches.Count) then
    Exit;
  FActiveMatch := Index;
  SM := FSearchMatches[FActiveMatch];
  if Length(SM.Match.Rects) > 0 then
    ScrollToPageRect(SM.PageIndex, SM.Match.Rects[0]);
  Notify(vcSearch);
  Redraw;
end;

function TPdfViewerController.FindNext: Boolean;
begin
  Result := FSearchMatches.Count > 0;
  if Result then
    GoToMatch((FActiveMatch + 1) mod FSearchMatches.Count);
end;

function TPdfViewerController.FindPrevious: Boolean;
begin
  Result := FSearchMatches.Count > 0;
  if Result then
    GoToMatch((FActiveMatch - 1 + FSearchMatches.Count) mod FSearchMatches.Count);
end;

procedure TPdfViewerController.ClearSearch;
begin
  FSearchMatches.Clear;
  FSearchQuery := '';
  FActiveMatch := -1;
  Notify(vcSearch);
  Redraw;
end;

function TPdfViewerController.SearchMatchCount: Integer;
begin
  Result := FSearchMatches.Count;
end;

function TPdfViewerController.SearchMatch(Index: Integer): TPdfSearchMatch;
begin
  if (Index >= 0) and (Index < FSearchMatches.Count) then
    Result := FSearchMatches[Index]
  else
  begin
    Result := Default(TPdfSearchMatch);
    Result.PageIndex := -1;
  end;
end;

function TPdfViewerController.HasSelection: Boolean;
begin
  Result := (FSelPage >= 0) and (FSelStart >= 0) and (FSelEnd >= 0);
end;

function TPdfViewerController.SelectedText: string;
var
  TP: TPdfTextPage;
begin
  Result := '';
  if HasSelection and FTextPages.TryGetValue(FSelPage, TP) then
    Result := TP.SelectionText(FSelStart, FSelEnd);
end;

procedure TPdfViewerController.ClearSelection;
begin
  if not HasSelection then
    Exit;
  FSelPage := -1;
  FSelStart := -1;
  FSelEnd := -1;
  SelectionChanged;
  Redraw;
end;

procedure TPdfViewerController.SelectPage(PageIndex: Integer);
var
  TP: TPdfTextPage;
begin
  TP := TextPage(PageIndex);
  if (TP = nil) or (TP.GlyphCount = 0) then
    Exit;
  FSelPage := PageIndex;
  FSelStart := 0;
  FSelEnd := TP.GlyphCount - 1;
  SelectionChanged;
  Redraw;
end;

function TPdfViewerController.CopySelection: Boolean;
var
  S: string;
begin
  S := SelectedText;
  Result := (S <> '') and FHost.CopyTextToClipboard(S);
end;

end.
