{ Included in the class declaration of TPdfViewer in FMX.PdfViewer and Vcl.PdfViewer: the part of the
  viewer API that both frameworks share. Every member delegates to FController (Pdf.Viewer.ApiImpl.inc). }

  private
    function GetZoom: Double;
    procedure SetZoom(const Value: Double);
    function IsZoomStored: Boolean;
    function GetZoomMode: TPdfZoomMode;
    procedure SetZoomMode(const Value: TPdfZoomMode);
    function GetRotation: Integer;
    procedure SetRotation(const Value: Integer);
    function GetDisplayMode: TPdfDisplayMode;
    procedure SetDisplayMode(const Value: TPdfDisplayMode);
    function GetFacingCoverPage: Boolean;
    procedure SetFacingCoverPage(const Value: Boolean);
    function GetMinZoom: Double;
    procedure SetMinZoom(const Value: Double);
    function GetMaxZoom: Double;
    procedure SetMaxZoom(const Value: Double);
    function GetPageGap: Single;
    procedure SetPageGap(const Value: Single);
    function GetPageMargin: Single;
    procedure SetPageMargin(const Value: Single);
    function GetBackgroundColor: TAlphaColor;
    procedure SetBackgroundColor(const Value: TAlphaColor);
    function GetPageShadow: Boolean;
    procedure SetPageShadow(const Value: Boolean);
    function GetCacheLimitMB: Integer;
    procedure SetCacheLimitMB(const Value: Integer);
    function GetPrefetchPages: Integer;
    procedure SetPrefetchPages(const Value: Integer);
    function GetTextSelectionEnabled: Boolean;
    procedure SetTextSelectionEnabled(const Value: Boolean);
    function GetLinksEnabled: Boolean;
    procedure SetLinksEnabled(const Value: Boolean);
    function GetSelectionColor: TAlphaColor;
    procedure SetSelectionColor(const Value: TAlphaColor);
    function GetHighlightColor: TAlphaColor;
    procedure SetHighlightColor(const Value: TAlphaColor);
    function GetActiveHighlightColor: TAlphaColor;
    procedure SetActiveHighlightColor(const Value: TAlphaColor);
    function GetOnPageChange: TPdfPageChangeEvent;
    procedure SetOnPageChange(const Value: TPdfPageChangeEvent);
    function GetOnLoadError: TPdfLoadErrorEvent;
    procedure SetOnLoadError(const Value: TPdfLoadErrorEvent);
    function GetOnPasswordRequest: TPdfPasswordEvent;
    procedure SetOnPasswordRequest(const Value: TPdfPasswordEvent);
    function GetOnRenderError: TPdfRenderErrorNotify;
    procedure SetOnRenderError(const Value: TPdfRenderErrorNotify);
    function GetOnPageRendered: TPdfPageRenderedEvent;
    procedure SetOnPageRendered(const Value: TPdfPageRenderedEvent);
    function GetOnZoomChange: TNotifyEvent;
    procedure SetOnZoomChange(const Value: TNotifyEvent);
    function GetOnScroll: TNotifyEvent;
    procedure SetOnScroll(const Value: TNotifyEvent);
    function GetOnLinkClick: TPdfLinkClickEvent;
    procedure SetOnLinkClick(const Value: TPdfLinkClickEvent);
    function GetOnOpenURI: TPdfOpenURIEvent;
    procedure SetOnOpenURI(const Value: TPdfOpenURIEvent);
    function GetOnSelectionChange: TNotifyEvent;
    procedure SetOnSelectionChange(const Value: TNotifyEvent);
    function GetNavigation: TPdfNavigation;
    function GetActiveMatch: Integer;
    function GetSearchQuery: string;
    function GetDocument: TPdfDocument;
    function GetLayout: TPdfPageLayout;
    function GetCache: TPdfImageCache;
    function GetPageCount: Integer;
    function GetCurrentPage: Integer;
    function GetIsLoaded: Boolean;
    function GetFileName: string;
    function GetScrollX: Double;
    function GetScrollY: Double;
    function GetRenderErrors: Integer;
  public
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
    /// <summary>Rotates the view 90 degrees clockwise or counter-clockwise (all pages).</summary>
    procedure RotateClockwise;
    procedure RotateCounterClockwise;
    /// <summary>Pages of the row that contains Index: one page, or two in facing modes.</summary>
    function RowPages(Index: Integer): TArray<Integer>;
    /// <summary>Size of a page in points as shown (after /Rotate and Rotation); zero for an invalid index.</summary>
    function PageSize(Index: Integer): TSizeF;
    /// <summary>Renders a page synchronously (export, printing). Pauses the background renderer meanwhile.
    /// ARotation -1 uses the viewer's Rotation; 0, 90, 180 or 270 rotate explicitly.</summary>
    function RenderPageToImage(Index: Integer; Scale: Double; Background: TAlphaColor = TAlphaColorRec.White;
      ARotation: Integer = -1): ISkImage;
    /// <summary>Queues a page for background rendering at Scale (device pixels per point) into the page cache, e.g.
    /// for thumbnails. OnPageRendered and the vcPageImage change report completion; nothing happens without a document.</summary>
    procedure RequestPageImage(Index: Integer; Scale: Double; Priority: Integer = 2000);
    /// <summary>Cached rendition of a page at exactly Scale, False when none.</summary>
    function TryGetPageImage(Index: Integer; Scale: Double; out Image: ISkImage): Boolean;
    /// <summary>Nearest cached rendition of a page at any scale, False when none.</summary>
    function TryGetNearestPageImage(Index: Integer; Scale: Double; out Image: ISkImage; out ImageScale: Double): Boolean;
    /// <summary>Companion controls (thumbnails, outline panes) register here to follow the viewer.</summary>
    procedure AddChangeListener(const Listener: TPdfViewerChangeEvent);
    procedure RemoveChangeListener(const Listener: TPdfViewerChangeEvent);
    /// <summary>Page under a control point (logical pixels), -1 when none.</summary>
    function PageAtPoint(const P: TPointF): Integer;
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
    /// <summary>Match by index (0 .. SearchMatchCount - 1).</summary>
    function SearchMatch(Index: Integer): TPdfSearchMatch;
    /// <summary>Makes match Index the active one and scrolls it into view.</summary>
    procedure GoToMatch(Index: Integer);
    /// <summary>Text of the current selection ('' when none).</summary>
    function SelectedText: string;
    function HasSelection: Boolean;
    procedure ClearSelection;
    /// <summary>Selects all text of a page.</summary>
    procedure SelectPage(PageIndex: Integer);
    /// <summary>Copies the selection to the clipboard; False when nothing is selected or no clipboard exists.</summary>
    function CopySelection: Boolean;
    /// <summary>Converts a control point (logical pixels) to PDF user-space coordinates of the page under it; False when not on a page.</summary>
    function PointToPage(const P: TPointF; out PageIndex: Integer; out PX, PY: Double): Boolean;
    /// <summary>The framework-independent viewer behind this control.</summary>
    property Controller: TPdfViewerController read FController;
    /// <summary>Navigation data of the document (outline, destinations). Valid while a document is loaded.</summary>
    property Navigation: TPdfNavigation read GetNavigation;
    /// <summary>Index of the active match (0-based), -1 when none.</summary>
    property ActiveMatch: Integer read GetActiveMatch;
    property SearchQuery: string read GetSearchQuery;
    property Document: TPdfDocument read GetDocument;
    property Layout: TPdfPageLayout read GetLayout;
    property Cache: TPdfImageCache read GetCache;
    property PageCount: Integer read GetPageCount;
    /// <summary>Zero-based index of the page that occupies most of the viewport.</summary>
    property CurrentPage: Integer read GetCurrentPage;
    property IsLoaded: Boolean read GetIsLoaded;
    property FileName: string read GetFileName;
    property ScrollX: Double read GetScrollX;
    property ScrollY: Double read GetScrollY;
    /// <summary>Number of background render failures since the document was loaded.</summary>
    property RenderErrors: Integer read GetRenderErrors;
  published
    /// <summary>1.0 = 72 dpi (one point per logical pixel).</summary>
    property Zoom: Double read GetZoom write SetZoom stored IsZoomStored;
    property ZoomMode: TPdfZoomMode read GetZoomMode write SetZoomMode default zmFitWidth;
    /// <summary>Clockwise rotation of the view in degrees (0, 90, 180, 270), on top of each page's own /Rotate.</summary>
    property Rotation: Integer read GetRotation write SetRotation default 0;
    property DisplayMode: TPdfDisplayMode read GetDisplayMode write SetDisplayMode default dmContinuous;
    /// <summary>In facing modes the first page stands alone, so that pages 2-3, 4-5 ... face each other.</summary>
    property FacingCoverPage: Boolean read GetFacingCoverPage write SetFacingCoverPage default False;
    property MinZoom: Double read GetMinZoom write SetMinZoom;
    property MaxZoom: Double read GetMaxZoom write SetMaxZoom;
    /// <summary>Space between pages in logical pixels.</summary>
    property PageGap: Single read GetPageGap write SetPageGap;
    property PageMargin: Single read GetPageMargin write SetPageMargin;
    property BackgroundColor: TAlphaColor read GetBackgroundColor write SetBackgroundColor default $FF505050;
    property PageShadow: Boolean read GetPageShadow write SetPageShadow default True;
    /// <summary>Memory budget of the rendered-page cache in MB.</summary>
    property CacheLimitMB: Integer read GetCacheLimitMB write SetCacheLimitMB default 256;
    /// <summary>Pages before and after the visible ones that are rendered in advance.</summary>
    property PrefetchPages: Integer read GetPrefetchPages write SetPrefetchPages default 1;
    property OnPageChange: TPdfPageChangeEvent read GetOnPageChange write SetOnPageChange;
    property OnLoadError: TPdfLoadErrorEvent read GetOnLoadError write SetOnLoadError;
    /// <summary>Asked for a password when the document is encrypted; without a handler the load fails with EPdfPasswordError.</summary>
    property OnPasswordRequest: TPdfPasswordEvent read GetOnPasswordRequest write SetOnPasswordRequest;
    property OnRenderError: TPdfRenderErrorNotify read GetOnRenderError write SetOnRenderError;
    property OnPageRendered: TPdfPageRenderedEvent read GetOnPageRendered write SetOnPageRendered;
    property OnZoomChange: TNotifyEvent read GetOnZoomChange write SetOnZoomChange;
    property OnScroll: TNotifyEvent read GetOnScroll write SetOnScroll;
    /// <summary>Dragging over text selects it (True); otherwise dragging always pans.</summary>
    property TextSelectionEnabled: Boolean read GetTextSelectionEnabled write SetTextSelectionEnabled default True;
    /// <summary>Link annotations react to clicks (True).</summary>
    property LinksEnabled: Boolean read GetLinksEnabled write SetLinksEnabled default True;
    property SelectionColor: TAlphaColor read GetSelectionColor write SetSelectionColor default $603399FF;
    property HighlightColor: TAlphaColor read GetHighlightColor write SetHighlightColor default $60FFE000;
    property ActiveHighlightColor: TAlphaColor read GetActiveHighlightColor write SetActiveHighlightColor default $90FF8000;
    property OnLinkClick: TPdfLinkClickEvent read GetOnLinkClick write SetOnLinkClick;
    /// <summary>A URI link was followed; the application opens it (the control does not launch browsers).</summary>
    property OnOpenURI: TPdfOpenURIEvent read GetOnOpenURI write SetOnOpenURI;
    property OnSelectionChange: TNotifyEvent read GetOnSelectionChange write SetOnSelectionChange;
