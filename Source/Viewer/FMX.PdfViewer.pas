{*******************************************************************************
  FMX.PdfViewer
  TPdfViewer: an FMX control that shows a PDF document as a continuous
  vertical scroll of pages. Pages are rendered in a background thread
  (Pdf.Viewer.RenderQueue) into an LRU cache (Pdf.Viewer.Cache); the UI
  thread only draws finished ISkImages. While a sharp image is pending the
  nearest cached rendition is shown scaled. Zoom, FitWidth, FitPage, pinch
  to zoom, mouse wheel, drag panning, scroll bars and keyboard navigation.
*******************************************************************************}
unit FMX.PdfViewer;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math, System.SyncObjs,
  System.Generics.Collections, System.Skia,
  FMX.Types, FMX.Controls, FMX.Graphics, FMX.StdCtrls, FMX.Skia, FMX.Platform,
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

  [ComponentPlatformsAttribute(pidAllPlatforms)]
  TPdfViewer = class(TSkCustomControl)
  private const
    DefaultMinZoom = 0.1;
    DefaultMaxZoom = 16;
    ZoomStep = 1.25;
    WheelLines = 3;
    LineHeight = 40;
  private
    FDocument: TPdfDocument;
    FLayout: TPdfPageLayout;
    FCache: TPdfImageCache;
    FQueue: TPdfRenderQueue;
    FScrollX, FScrollY: Double;
    FZoom: Double;
    FZoomMode: TPdfZoomMode;
    FMinZoom, FMaxZoom: Double;
    FVScroll, FHScroll: TScrollBar;
    FUpdatingScrollBars: Boolean;
    FCurrentPage: Integer;
    FPageGap: Single;
    FPageMargin: Single;
    FBackgroundColor: TAlphaColor;
    FPageShadow: Boolean;
    FCacheLimitMB: Integer;
    FFileName: string;
    FDragging, FDragMoved: Boolean;
    // fase 5
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
    function PageAnnotations(Index: Integer): TObjectList<TPdfAnnotation>;
    function LinkAt(const P: TPointF): TPdfAnnotation;
    function ControlToPagePoint(const P: TPointF; out PageIndex: Integer): TPointF;
    procedure WithDocumentLock(const Proc: TProc);
    procedure DrawOverlays(const ACanvas: ISkCanvas; PageIndex: Integer; const PageRectOnCanvas: TRectF);
    procedure UpdateCursor(const P: TPointF);
    procedure ScrollToPageRect(PageIndex: Integer; const R: TRectF);
    procedure PageReady(Sender: TObject; Page: Integer; Scale: Double; const Image: ISkImage);
    procedure RenderError(Sender: TObject; Page: Integer; const Message: string);
    procedure QueueRedraw;
    function SceneScale: Single;
    function RenderScale: Double;
    function ViewportRect: TRectF;
    procedure UpdateLayoutViewport;
    procedure ApplyZoomMode;
    procedure UpdateScrollBars;
    procedure ScrollBarChanged(Sender: TObject);
    procedure SetScroll(X, Y: Double);
    procedure UpdateCurrentPage;
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
    function IsZoomStored: Boolean;
  protected
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single); override;
    procedure Resize; override;
    procedure DoPageChange; virtual;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean); override;
    procedure KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
    procedure DoGesture(const EventInfo: TGestureEventInfo; var Handled: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    /// <summary>Opens a file. Errors go to OnLoadError; without a handler the exception propagates.</summary>
    procedure LoadFromFile(const FileName: string; const Password: string = '');
    procedure LoadFromStream(Stream: TStream; const Password: string = '');
    procedure Close;
    procedure GoToPage(Index: Integer);
    procedure NextPage;
    procedure PreviousPage;
    procedure ZoomIn;
    procedure ZoomOut;
    /// <summary>Sets the zoom keeping the document point under Anchor (control coordinates) in place.</summary>
    procedure ZoomAt(NewZoom: Double; const Anchor: TPointF);
    procedure FitWidth;
    procedure FitPage;
    /// <summary>Scrolls so that the given document position (logical pixels at the current zoom) is at the top-left.</summary>
    procedure ScrollTo(X, Y: Double);
    procedure ScrollBy(DX, DY: Double);
    /// <summary>Renders a page synchronously (thumbnails, export). Pauses the background renderer meanwhile.</summary>
    function RenderPageToImage(Index: Integer; Scale: Double; Background: TAlphaColor = TAlphaColorRec.White): ISkImage;
    /// <summary>Page under a control point, -1 when none.</summary>
    function PageAtPoint(const P: TPointF): Integer;
    /// <summary>Navigation data of the document (outline, destinations). Valid while a document is loaded.</summary>
    property Navigation: TPdfNavigation read FNavigation;
    /// <summary>Top-level bookmarks; empty when the document has none.</summary>
    function Outline: TObjectList<TPdfOutlineItem>;
    /// <summary>Scrolls (and zooms, for XYZ with a zoom) to a destination; False when it has no page.</summary>
    function GoToDestination(const Dest: TPdfDestination): Boolean;
    procedure GoToOutlineItem(Item: TPdfOutlineItem);
    /// <summary>Performs an action: GoTo scrolls, URI raises OnOpenURI, Named handles Next/Prev/First/LastPage. False when nothing was done.</summary>
    function PerformAction(const Action: TPdfAction): Boolean;
    /// <summary>Extracted text of a page (cached; pauses the background renderer on first use).</summary>
    function TextPage(Index: Integer): TPdfTextPage;
    /// <summary>Searches the whole document; returns the number of matches and highlights them. Empty query clears.</summary>
    function Find(const Query: string; CaseSensitive: Boolean = False; WholeWord: Boolean = False): Integer;
    /// <summary>Moves to the next/previous match (wrapping) and scrolls it into view. False when there are no matches.</summary>
    function FindNext: Boolean;
    function FindPrevious: Boolean;
    procedure ClearSearch;
    function SearchMatchCount: Integer;
    /// <summary>Index of the active match (0-based), -1 when none.</summary>
    property ActiveMatch: Integer read FActiveMatch;
    property SearchQuery: string read FSearchQuery;
    /// <summary>Text of the current selection ('' when none).</summary>
    function SelectedText: string;
    function HasSelection: Boolean;
    procedure ClearSelection;
    /// <summary>Selects all text of a page.</summary>
    procedure SelectPage(PageIndex: Integer);
    /// <summary>Copies the selection to the clipboard; False when nothing is selected or no clipboard service exists.</summary>
    function CopySelection: Boolean;
    /// <summary>Converts a control point to PDF user-space coordinates of the page under it; False when not on a page.</summary>
    function PointToPage(const P: TPointF; out PageIndex: Integer; out PX, PY: Double): Boolean;
    property Document: TPdfDocument read FDocument;
    property Layout: TPdfPageLayout read FLayout;
    property Cache: TPdfImageCache read FCache;
    property PageCount: Integer read GetPageCount;
    /// <summary>Zero-based index of the page that occupies most of the viewport.</summary>
    property CurrentPage: Integer read FCurrentPage;
    property IsLoaded: Boolean read GetIsLoaded;
    property FileName: string read FFileName;
    property ScrollX: Double read FScrollX;
    property ScrollY: Double read FScrollY;
    /// <summary>Number of background render failures since the document was loaded.</summary>
    property RenderErrors: Integer read FRenderErrors;
  published
    property Align;
    property Anchors;
    property CanFocus default True;
    property ClipChildren default True;
    property Cursor default crDefault;
    property Enabled default True;
    property Height;
    property HitTest default True;
    property Margins;
    property Opacity;
    property Padding;
    property Position;
    property Size;
    property TabOrder;
    property TabStop default True;
    property Touch;
    property Visible default True;
    property Width;
    property OnClick;
    property OnDblClick;
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
    /// <summary>1.0 = 72 dpi (one point per logical pixel).</summary>
    property Zoom: Double read FZoom write SetZoom stored IsZoomStored;
    property ZoomMode: TPdfZoomMode read FZoomMode write SetZoomMode default zmFitWidth;
    property MinZoom: Double read FMinZoom write SetMinZoom;
    property MaxZoom: Double read FMaxZoom write SetMaxZoom;
    /// <summary>Space between pages in logical pixels.</summary>
    property PageGap: Single read FPageGap write SetPageGap;
    property PageMargin: Single read FPageMargin write SetPageMargin;
    property BackgroundColor: TAlphaColor read FBackgroundColor write SetBackgroundColor default $FF505050;
    property PageShadow: Boolean read FPageShadow write SetPageShadow default True;
    /// <summary>Memory budget of the rendered-page cache in MB.</summary>
    property CacheLimitMB: Integer read FCacheLimitMB write SetCacheLimitMB default 256;
    /// <summary>Pages before and after the visible ones that are rendered in advance.</summary>
    property PrefetchPages: Integer read FPrefetchPages write FPrefetchPages default 1;
    property OnPageChange: TPdfPageChangeEvent read FOnPageChange write FOnPageChange;
    property OnLoadError: TPdfLoadErrorEvent read FOnLoadError write FOnLoadError;
    property OnRenderError: TPdfRenderErrorNotify read FOnRenderError write FOnRenderError;
    property OnZoomChange: TNotifyEvent read FOnZoomChange write FOnZoomChange;
    property OnScroll: TNotifyEvent read FOnScroll write FOnScroll;
    /// <summary>Dragging over text selects it (True); otherwise dragging always pans.</summary>
    property TextSelectionEnabled: Boolean read FTextSelectionEnabled write FTextSelectionEnabled default True;
    /// <summary>Link annotations react to clicks (True).</summary>
    property LinksEnabled: Boolean read FLinksEnabled write FLinksEnabled default True;
    property SelectionColor: TAlphaColor read FSelectionColor write FSelectionColor default $603399FF;
    property HighlightColor: TAlphaColor read FHighlightColor write FHighlightColor default $60FFE000;
    property ActiveHighlightColor: TAlphaColor read FActiveHighlightColor write FActiveHighlightColor default $90FF8000;
    property OnLinkClick: TPdfLinkClickEvent read FOnLinkClick write FOnLinkClick;
    /// <summary>A URI link was followed; the application opens it (the control does not launch browsers).</summary>
    property OnOpenURI: TPdfOpenURIEvent read FOnOpenURI write FOnOpenURI;
    property OnSelectionChange: TNotifyEvent read FOnSelectionChange write FOnSelectionChange;
  end;

implementation

{ TPdfViewer }

constructor TPdfViewer.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FDocument := TPdfDocument.Create;
  FLayout := TPdfPageLayout.Create;
  {$IF defined(ANDROID) or defined(IOS)}
  FCacheLimitMB := 96;
  {$ELSE}
  FCacheLimitMB := 256;
  {$ENDIF}
  FCache := TPdfImageCache.Create(Int64(FCacheLimitMB) * 1024 * 1024);
  FZoom := 1;
  FZoomMode := zmFitWidth;
  FMinZoom := DefaultMinZoom;
  FMaxZoom := DefaultMaxZoom;
  FPageGap := 8;
  FPageMargin := 8;
  FBackgroundColor := $FF505050;
  FPageShadow := True;
  FPrefetchPages := 1;
  FCurrentPage := -1;
  FLayout.Gap := FPageGap;
  FLayout.Margin := FPageMargin;
  FAnnots := TObjectDictionary<Integer, TObjectList<TPdfAnnotation>>.Create([doOwnsValues]);
  FTextPages := TObjectDictionary<Integer, TPdfTextPage>.Create([doOwnsValues]);
  FSearchMatches := TList<TPdfSearchMatch>.Create;
  FActiveMatch := -1;
  FSelPage := -1;
  FSelStart := -1;
  FSelEnd := -1;
  FTextSelectionEnabled := True;
  FLinksEnabled := True;
  FSelectionColor := $603399FF;
  FHighlightColor := $60FFE000;
  FActiveHighlightColor := $90FF8000;
  HitTest := True;
  CanFocus := True;
  TabStop := True;
  AutoCapture := True;
  ClipChildren := True;
  DrawCacheKind := TSkDrawCacheKind.Never;
  Touch.InteractiveGestures := Touch.InteractiveGestures + [TInteractiveGesture.Zoom, TInteractiveGesture.DoubleTap];
  SetBounds(0, 0, 400, 300);

  FVScroll := TScrollBar.Create(Self);
  FVScroll.Parent := Self;
  FVScroll.Stored := False;
  FVScroll.Orientation := TOrientation.Vertical;
  FVScroll.Align := TAlignLayout.Right;
  FVScroll.Width := 14;
  FVScroll.Visible := False;
  FVScroll.OnChange := ScrollBarChanged;

  FHScroll := TScrollBar.Create(Self);
  FHScroll.Parent := Self;
  FHScroll.Stored := False;
  FHScroll.Orientation := TOrientation.Horizontal;
  FHScroll.Align := TAlignLayout.Bottom;
  FHScroll.Height := 14;
  FHScroll.Visible := False;
  FHScroll.OnChange := ScrollBarChanged;
end;

destructor TPdfViewer.Destroy;
begin
  StopQueue;
  FSearchMatches.Free;
  FTextPages.Free;
  FAnnots.Free;
  FNavigation.Free;
  FDocument.Free;
  FCache.Free;
  FLayout.Free;
  inherited;
end;

{ Loading }

procedure TPdfViewer.StartQueue;
begin
  if FQueue <> nil then
    Exit;
  FQueue := TPdfRenderQueue.Create(FDocument, FCache);
  FQueue.OnPageReady := PageReady;
  FQueue.OnError := RenderError;
  FQueue.Start;
end;

procedure TPdfViewer.StopQueue;
begin
  if FQueue = nil then
    Exit;
  FQueue.Stop;
  FreeAndNil(FQueue);
end;

procedure TPdfViewer.Close;
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
  UpdateScrollBars;
  Redraw;
end;

procedure TPdfViewer.LoadFromFile(const FileName: string; const Password: string);
var
  Handled: Boolean;
begin
  Close;
  try
    FDocument.LoadFromFile(FileName, Password);
    FFileName := FileName;
    AfterLoad;
  except
    on E: Exception do
    begin
      FDocument.Close;
      Handled := False;
      if Assigned(FOnLoadError) then
        FOnLoadError(Self, FileName, E, Handled);
      if not Handled then
        raise;
    end;
  end;
end;

procedure TPdfViewer.LoadFromStream(Stream: TStream; const Password: string);
var
  Handled: Boolean;
begin
  Close;
  try
    FDocument.LoadFromStream(Stream, Password);
    FFileName := '';
    AfterLoad;
  except
    on E: Exception do
    begin
      FDocument.Close;
      Handled := False;
      if Assigned(FOnLoadError) then
        FOnLoadError(Self, '', E, Handled);
      if not Handled then
        raise;
    end;
  end;
end;

procedure TPdfViewer.AfterLoad;
var
  Sizes: TArray<TSizeF>;
  I: Integer;
  P: TPdfPage;
begin
  // Page metrics are collected on the UI thread before the render thread starts:
  // afterwards only the worker touches the document.
  SetLength(Sizes, FDocument.PageCount);
  for I := 0 to FDocument.PageCount - 1 do
  begin
    P := FDocument.Pages[I];
    Sizes[I] := TSizeF.Create(Max(1, P.GetDisplayWidth), Max(1, P.GetDisplayHeight));
  end;
  FLayout.SetPages(Sizes);
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
  UpdateCurrentPage;
  Redraw;
end;

function TPdfViewer.GetPageCount: Integer;
begin
  Result := FLayout.PageCount;
end;

function TPdfViewer.GetIsLoaded: Boolean;
begin
  Result := FDocument.IsLoaded;
end;

{ Background rendering }

procedure TPdfViewer.PageReady(Sender: TObject; Page: Integer; Scale: Double; const Image: ISkImage);
begin
  QueueRedraw;
end;

procedure TPdfViewer.RenderError(Sender: TObject; Page: Integer; const Message: string);
begin
  TInterlocked.Increment(FRenderErrors);
  if Assigned(FOnRenderError) then
    TThread.Queue(nil,
      procedure
      begin
        if Assigned(FOnRenderError) then
          FOnRenderError(Self, Page, Message);
      end);
end;

procedure TPdfViewer.QueueRedraw;
begin
  // Coalesce: one queued redraw at a time
  if TInterlocked.CompareExchange(FRedrawQueued, 1, 0) <> 0 then
    Exit;
  TThread.Queue(nil,
    procedure
    begin
      TInterlocked.Exchange(FRedrawQueued, 0);
      if not (csDestroying in ComponentState) then
        Redraw;
    end);
end;

function TPdfViewer.SceneScale: Single;
begin
  Result := 1;
  if Scene <> nil then
    Result := Scene.GetSceneScale;
  if Result <= 0 then
    Result := 1;
end;

function TPdfViewer.RenderScale: Double;
begin
  Result := FZoom * SceneScale;
end;

function TPdfViewer.ViewportRect: TRectF;
begin
  Result := LocalRect;
  if (FVScroll <> nil) and FVScroll.Visible then
    Result.Right := Result.Right - FVScroll.Width;
  if (FHScroll <> nil) and FHScroll.Visible then
    Result.Bottom := Result.Bottom - FHScroll.Height;
end;

procedure TPdfViewer.UpdateLayoutViewport;
var
  R: TRectF;
begin
  R := ViewportRect;
  FLayout.ViewportWidth := Max(0, R.Width);
  FLayout.ViewportHeight := Max(0, R.Height);
end;

procedure TPdfViewer.ApplyZoomMode;
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
      FOnZoomChange(Self);
  end;
end;

procedure TPdfViewer.UpdateScrollBars;
var
  NeedV, NeedH: Boolean;
  R: TRectF;
begin
  if FUpdatingScrollBars or (FVScroll = nil) or (FHScroll = nil) then
    Exit;
  FUpdatingScrollBars := True;
  try
    // Two passes: showing one bar can make the other necessary
    FVScroll.Visible := False;
    FHScroll.Visible := False;
    UpdateLayoutViewport;
    NeedV := FLayout.TotalHeight > FLayout.ViewportHeight + 0.5;
    NeedH := FLayout.TotalWidth > FLayout.ViewportWidth + 0.5;
    FVScroll.Visible := NeedV and (FLayout.PageCount > 0);
    FHScroll.Visible := NeedH and (FLayout.PageCount > 0);
    UpdateLayoutViewport;
    NeedV := FLayout.TotalHeight > FLayout.ViewportHeight + 0.5;
    NeedH := FLayout.TotalWidth > FLayout.ViewportWidth + 0.5;
    FVScroll.Visible := NeedV and (FLayout.PageCount > 0);
    FHScroll.Visible := NeedH and (FLayout.PageCount > 0);
    UpdateLayoutViewport;
    R := ViewportRect;
    FScrollX := FLayout.ClampScrollX(FScrollX);
    FScrollY := FLayout.ClampScrollY(FScrollY);
    if FVScroll.Visible then
    begin
      FVScroll.Max := FLayout.TotalHeight;
      FVScroll.ViewportSize := R.Height;
      FVScroll.SmallChange := LineHeight;
      FVScroll.Value := FScrollY;
    end;
    if FHScroll.Visible then
    begin
      FHScroll.Max := FLayout.TotalWidth;
      FHScroll.ViewportSize := R.Width;
      FHScroll.SmallChange := LineHeight;
      FHScroll.Value := FScrollX;
    end;
  finally
    FUpdatingScrollBars := False;
  end;
end;

procedure TPdfViewer.ScrollBarChanged(Sender: TObject);
begin
  if FUpdatingScrollBars then
    Exit;
  if Sender = FVScroll then
    SetScroll(FScrollX, FVScroll.Value)
  else
    SetScroll(FHScroll.Value, FScrollY);
end;

procedure TPdfViewer.SetScroll(X, Y: Double);
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
      if FVScroll.Visible then
        FVScroll.Value := FScrollY;
      if FHScroll.Visible then
        FHScroll.Value := FScrollX;
    finally
      FUpdatingScrollBars := False;
    end;
  end;
  UpdateCurrentPage;
  if Assigned(FOnScroll) then
    FOnScroll(Self);
  Redraw;
end;

procedure TPdfViewer.UpdateCurrentPage;
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

procedure TPdfViewer.DoPageChange;
begin
  if Assigned(FOnPageChange) then
    FOnPageChange(Self, FCurrentPage);
end;

procedure TPdfViewer.RequestVisiblePages;
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

procedure TPdfViewer.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
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

procedure TPdfViewer.Resize;
begin
  inherited;
  if (FLayout = nil) or (FVScroll = nil) or (FHScroll = nil) then
    Exit;
  UpdateLayoutViewport;
  ApplyZoomMode;
  UpdateScrollBars;
  UpdateCurrentPage;
  Redraw;
end;

{ Zoom }

function TPdfViewer.IsZoomStored: Boolean;
begin
  Result := FZoomMode = zmCustom;
end;

procedure TPdfViewer.SetZoomInternal(NewZoom: Double; const Anchor: TPointF; FromMode: Boolean);
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
    NewZoom := Min(NewZoom, MaxPagePixels / (Largest * SceneScale));
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
    FOnZoomChange(Self);
  Redraw;
end;

procedure TPdfViewer.SetZoom(const Value: Double);
begin
  SetZoomInternal(Value, ViewportRect.CenterPoint, False);
end;

procedure TPdfViewer.ZoomAt(NewZoom: Double; const Anchor: TPointF);
begin
  SetZoomInternal(NewZoom, Anchor, False);
end;

procedure TPdfViewer.ZoomIn;
begin
  Zoom := FZoom * ZoomStep;
end;

procedure TPdfViewer.ZoomOut;
begin
  Zoom := FZoom / ZoomStep;
end;

procedure TPdfViewer.FitWidth;
begin
  ZoomMode := zmFitWidth;
end;

procedure TPdfViewer.FitPage;
begin
  ZoomMode := zmFitPage;
end;

procedure TPdfViewer.SetZoomMode(const Value: TPdfZoomMode);
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

procedure TPdfViewer.SetMinZoom(const Value: Double);
begin
  FMinZoom := Max(0.01, Value);
  if FZoom < FMinZoom then
    Zoom := FMinZoom;
end;

procedure TPdfViewer.SetMaxZoom(const Value: Double);
begin
  FMaxZoom := Max(FMinZoom, Value);
  if FZoom > FMaxZoom then
    Zoom := FMaxZoom;
end;

procedure TPdfViewer.SetPageGap(const Value: Single);
begin
  FPageGap := Max(0, Value);
  FLayout.Gap := FPageGap;
  UpdateScrollBars;
  Redraw;
end;

procedure TPdfViewer.SetPageMargin(const Value: Single);
begin
  FPageMargin := Max(0, Value);
  FLayout.Margin := FPageMargin;
  UpdateScrollBars;
  Redraw;
end;

procedure TPdfViewer.SetBackgroundColor(const Value: TAlphaColor);
begin
  FBackgroundColor := Value;
  Redraw;
end;

procedure TPdfViewer.SetPageShadow(const Value: Boolean);
begin
  FPageShadow := Value;
  Redraw;
end;

procedure TPdfViewer.SetCacheLimitMB(const Value: Integer);
begin
  FCacheLimitMB := Max(4, Value);
  FCache.MaxBytes := Int64(FCacheLimitMB) * 1024 * 1024;
end;

{ Navigation }

procedure TPdfViewer.GoToPage(Index: Integer);
begin
  if (Index < 0) or (Index >= FLayout.PageCount) then
    Exit;
  SetScroll(FScrollX, FLayout.ScrollTopOfPage(Index));
  // A short last page cannot be scrolled to the top: still report it as current
  if FCurrentPage <> Index then
  begin
    FCurrentPage := Index;
    DoPageChange;
  end;
end;

procedure TPdfViewer.NextPage;
begin
  GoToPage(FCurrentPage + 1);
end;

procedure TPdfViewer.PreviousPage;
begin
  GoToPage(FCurrentPage - 1);
end;

procedure TPdfViewer.ScrollTo(X, Y: Double);
begin
  SetScroll(X, Y);
end;

procedure TPdfViewer.ScrollBy(DX, DY: Double);
begin
  SetScroll(FScrollX + DX, FScrollY + DY);
end;

function TPdfViewer.PageAtPoint(const P: TPointF): Integer;
begin
  Result := FLayout.PageAt(P.X + FScrollX, P.Y + FScrollY);
end;

function TPdfViewer.PointToPage(const P: TPointF; out PageIndex: Integer; out PX, PY: Double): Boolean;
begin
  PageIndex := PageAtPoint(P);
  Result := (PageIndex >= 0) and FLayout.DocumentToPage(PageIndex, P.X + FScrollX, P.Y + FScrollY, PX, PY);
end;

function TPdfViewer.RenderPageToImage(Index: Integer; Scale: Double; Background: TAlphaColor): ISkImage;
var
  R: TPdfPageRenderer;
  WasRunning: Boolean;
begin
  Result := nil;
  if (Index < 0) or (Index >= FDocument.PageCount) then
    Exit;
  WasRunning := FQueue <> nil;
  StopQueue;
  try
    R := TPdfPageRenderer.Create(FDocument);
    try
      Result := R.RenderToImage(FDocument.Pages[Index], Scale, Background);
    finally
      R.Free;
    end;
  finally
    if WasRunning then
      StartQueue;
  end;
end;

{ Input }

procedure TPdfViewer.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  P: TPointF;
  PageIdx, G: Integer;
  PP: TPointF;
  TP: TPdfTextPage;
begin
  inherited;
  if CanFocus then
    SetFocus;
  if Button = TMouseButton.mbLeft then
  begin
    P := TPointF.Create(X, Y);
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
            if Assigned(FOnSelectionChange) then
              FOnSelectionChange(Self);
            Redraw;
            Exit;
          end;
        end;
      end;
    end;
    if HasSelection then
      ClearSelection;
  end;
end;

procedure TPdfViewer.MouseMove(Shift: TShiftState; X, Y: Single);
var
  P, PP: TPointF;
  PageIdx, G: Integer;
  TP: TPdfTextPage;
begin
  inherited;
  P := TPointF.Create(X, Y);
  FLastMouse := P;
  if FDragging and (ssLeft in Shift) then
  begin
    if (Abs(X - FDragStart.X) > 2) or (Abs(Y - FDragStart.Y) > 2) then
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
          if Assigned(FOnSelectionChange) then
            FOnSelectionChange(Self);
          Redraw;
        end;
      end;
    end
    else if FPressedLink = nil then
      SetScroll(FDragScroll.X - (X - FDragStart.X), FDragScroll.Y - (Y - FDragStart.Y));
  end
  else
    UpdateCursor(P);
end;

procedure TPdfViewer.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  Link: TPdfAnnotation;
  Handled: Boolean;
begin
  inherited;
  FDragging := False;
  FSelecting := False;
  Link := FPressedLink;
  FPressedLink := nil;
  if (Button = TMouseButton.mbLeft) and (Link <> nil) and not FDragMoved and (LinkAt(TPointF.Create(X, Y)) = Link) then
  begin
    Handled := False;
    if Assigned(FOnLinkClick) then
      FOnLinkClick(Self, Link.Action, Handled);
    if not Handled then
      PerformAction(Link.Action);
  end;
end;

{ Fase 5: links, outline, text }

function TPdfViewer.PageAnnotations(Index: Integer): TObjectList<TPdfAnnotation>;
begin
  if not FAnnots.TryGetValue(Index, Result) then
    Result := nil;
end;

function TPdfViewer.LinkAt(const P: TPointF): TPdfAnnotation;
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

function TPdfViewer.ControlToPagePoint(const P: TPointF; out PageIndex: Integer): TPointF;
var
  R: TRectF;
begin
  Result := TPointF.Zero;
  PageIndex := PageAtPoint(P);
  if PageIndex < 0 then
    Exit;
  R := FLayout.PageRect[PageIndex];
  Result := TPointF.Create((P.X + FScrollX - R.Left) / FZoom, (P.Y + FScrollY - R.Top) / FZoom);
end;

procedure TPdfViewer.WithDocumentLock(const Proc: TProc);
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

function TPdfViewer.TextPage(Index: Integer): TPdfTextPage;
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

procedure TPdfViewer.DrawOverlays(const ACanvas: ISkCanvas; PageIndex: Integer; const PageRectOnCanvas: TRectF);
var
  Paint: ISkPaint;
  I: Integer;
  R: TRectF;
  TP: TPdfTextPage;
  Rects: TArray<TRectF>;

  function Map(const PR: TRectF): TRectF;
  begin
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

procedure TPdfViewer.UpdateCursor(const P: TPointF);
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
  if Cursor <> NewCursor then
    Cursor := NewCursor;
end;

function TPdfViewer.Outline: TObjectList<TPdfOutlineItem>;
begin
  if FNavigation = nil then
    Exit(nil);
  FNavigation.OutlineCount;
  Result := FNavigation.Outline;
end;

procedure TPdfViewer.ScrollToPageRect(PageIndex: Integer; const R: TRectF);
var
  PR: TRectF;
  Y, X: Double;
begin
  PR := FLayout.PageRect[PageIndex];
  Y := PR.Top + R.Top * FZoom - FLayout.ViewportHeight / 3;
  X := FScrollX;
  if (PR.Left + R.Right * FZoom < FScrollX) or (PR.Left + R.Left * FZoom > FScrollX + FLayout.ViewportWidth) then
    X := PR.Left + R.Left * FZoom - FLayout.ViewportWidth / 3;
  SetScroll(X, Y);
end;

function TPdfViewer.GoToDestination(const Dest: TPdfDestination): Boolean;
var
  Page: TPdfPage;
  M: TPdfMatrix;
  X, Y: Double;
  PR: TRectF;
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
        SetScroll(PR.Left + X * FZoom - FPageMargin, PR.Top + Y * FZoom - FPageMargin);
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

procedure TPdfViewer.GoToOutlineItem(Item: TPdfOutlineItem);
begin
  if Item = nil then
    Exit;
  if Item.Dest.IsValid then
    GoToDestination(Item.Dest)
  else
    PerformAction(Item.Action);
end;

function TPdfViewer.PerformAction(const Action: TPdfAction): Boolean;
begin
  Result := False;
  case Action.Kind of
    akGoTo:
      Result := GoToDestination(Action.Dest);
    akURI:
      if Assigned(FOnOpenURI) and (Action.Target <> '') then
      begin
        FOnOpenURI(Self, Action.Target);
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

function TPdfViewer.Find(const Query: string; CaseSensitive, WholeWord: Boolean): Integer;
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
    FActiveMatch := First - 1;
    FindNext;
  end
  else
    Redraw;
end;

function TPdfViewer.FindNext: Boolean;
var
  SM: TPdfSearchMatch;
begin
  Result := FSearchMatches.Count > 0;
  if not Result then
    Exit;
  FActiveMatch := (FActiveMatch + 1) mod FSearchMatches.Count;
  SM := FSearchMatches[FActiveMatch];
  if Length(SM.Match.Rects) > 0 then
    ScrollToPageRect(SM.PageIndex, SM.Match.Rects[0]);
  Redraw;
end;

function TPdfViewer.FindPrevious: Boolean;
var
  SM: TPdfSearchMatch;
begin
  Result := FSearchMatches.Count > 0;
  if not Result then
    Exit;
  FActiveMatch := (FActiveMatch - 1 + FSearchMatches.Count) mod FSearchMatches.Count;
  SM := FSearchMatches[FActiveMatch];
  if Length(SM.Match.Rects) > 0 then
    ScrollToPageRect(SM.PageIndex, SM.Match.Rects[0]);
  Redraw;
end;

procedure TPdfViewer.ClearSearch;
begin
  FSearchMatches.Clear;
  FSearchQuery := '';
  FActiveMatch := -1;
  Redraw;
end;

function TPdfViewer.SearchMatchCount: Integer;
begin
  Result := FSearchMatches.Count;
end;

function TPdfViewer.HasSelection: Boolean;
begin
  Result := (FSelPage >= 0) and (FSelStart >= 0) and (FSelEnd >= 0);
end;

function TPdfViewer.SelectedText: string;
var
  TP: TPdfTextPage;
begin
  Result := '';
  if HasSelection and FTextPages.TryGetValue(FSelPage, TP) then
    Result := TP.SelectionText(FSelStart, FSelEnd);
end;

procedure TPdfViewer.ClearSelection;
begin
  if not HasSelection then
    Exit;
  FSelPage := -1;
  FSelStart := -1;
  FSelEnd := -1;
  if Assigned(FOnSelectionChange) then
    FOnSelectionChange(Self);
  Redraw;
end;

procedure TPdfViewer.SelectPage(PageIndex: Integer);
var
  TP: TPdfTextPage;
begin
  TP := TextPage(PageIndex);
  if (TP = nil) or (TP.GlyphCount = 0) then
    Exit;
  FSelPage := PageIndex;
  FSelStart := 0;
  FSelEnd := TP.GlyphCount - 1;
  if Assigned(FOnSelectionChange) then
    FOnSelectionChange(Self);
  Redraw;
end;

function TPdfViewer.CopySelection: Boolean;
var
  Svc: IFMXClipboardService;
  S: string;
begin
  Result := False;
  S := SelectedText;
  if S = '' then
    Exit;
  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService, Svc) then
  begin
    Svc.SetClipboard(S);
    Result := True;
  end;
end;

procedure TPdfViewer.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
var
  Steps: Double;
begin
  inherited;
  if Handled then
    Exit;
  Steps := WheelDelta / 120;
  if ssCtrl in Shift then
    ZoomAt(FZoom * Power(1.1, Steps), FLastMouse)
  else if ssShift in Shift then
    ScrollBy(-Steps * WheelLines * LineHeight, 0)
  else
    ScrollBy(0, -Steps * WheelLines * LineHeight);
  Handled := True;
end;

procedure TPdfViewer.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
var
  PageStep: Double;
begin
  inherited;
  PageStep := Max(LineHeight, FLayout.ViewportHeight - LineHeight);
  case Key of
    vkDown: ScrollBy(0, LineHeight);
    vkUp: ScrollBy(0, -LineHeight);
    vkLeft: ScrollBy(-LineHeight, 0);
    vkRight: ScrollBy(LineHeight, 0);
    vkNext: if ssCtrl in Shift then NextPage else ScrollBy(0, PageStep);
    vkPrior: if ssCtrl in Shift then PreviousPage else ScrollBy(0, -PageStep);
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
    begin
      CopySelection;
      Key := 0;
      KeyChar := #0;
      Exit;
    end;
    if (ssCtrl in Shift) and ((KeyChar = 'a') or (KeyChar = 'A') or (Key = vkA)) then
    begin
      SelectPage(Max(0, FCurrentPage));
      Key := 0;
      KeyChar := #0;
      Exit;
    end;
    case KeyChar of
      '+', '=': ZoomIn;
      '-': ZoomOut;
      '0': FitWidth;
    else
      Exit;
    end;
  end;
  Key := 0;
  KeyChar := #0;
end;

procedure TPdfViewer.DoGesture(const EventInfo: TGestureEventInfo; var Handled: Boolean);
var
  Local: TPointF;
begin
  if EventInfo.GestureID = igiZoom then
  begin
    Local := AbsoluteToLocal(EventInfo.Location);
    if TInteractiveGestureFlag.gfBegin in EventInfo.Flags then
    begin
      FPinchStartZoom := FZoom;
      FPinchStartDistance := Max(1, EventInfo.Distance);
    end
    else if not (TInteractiveGestureFlag.gfEnd in EventInfo.Flags) and (FPinchStartDistance > 0) then
      ZoomAt(FPinchStartZoom * EventInfo.Distance / FPinchStartDistance, Local);
    Handled := True;
  end
  else if EventInfo.GestureID = igiDoubleTap then
  begin
    if FZoomMode = zmFitWidth then
      ZoomAt(FZoom * 2, AbsoluteToLocal(EventInfo.Location))
    else
      FitWidth;
    Handled := True;
  end
  else
    inherited;
end;

end.
