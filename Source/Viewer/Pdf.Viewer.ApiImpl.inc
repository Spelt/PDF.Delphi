{ Included in the implementation of FMX.PdfViewer and Vcl.PdfViewer: the shared TPdfViewer API
  declared in Pdf.Viewer.ApiDecl.inc, delegated to FController. }

{ TPdfViewer: properties }

function TPdfViewer.IsZoomStored: Boolean;
begin
  Result := FController.ZoomMode = zmCustom;
end;

function TPdfViewer.GetZoom: Double;
begin
  Result := FController.Zoom;
end;

procedure TPdfViewer.SetZoom(const Value: Double);
begin
  FController.Zoom := Value;
end;

function TPdfViewer.GetZoomMode: TPdfZoomMode;
begin
  Result := FController.ZoomMode;
end;

procedure TPdfViewer.SetZoomMode(const Value: TPdfZoomMode);
begin
  FController.ZoomMode := Value;
end;

function TPdfViewer.GetRotation: Integer;
begin
  Result := FController.Rotation;
end;

procedure TPdfViewer.SetRotation(const Value: Integer);
begin
  FController.Rotation := Value;
end;

function TPdfViewer.GetDisplayMode: TPdfDisplayMode;
begin
  Result := FController.DisplayMode;
end;

procedure TPdfViewer.SetDisplayMode(const Value: TPdfDisplayMode);
begin
  FController.DisplayMode := Value;
end;

function TPdfViewer.GetFacingCoverPage: Boolean;
begin
  Result := FController.FacingCoverPage;
end;

procedure TPdfViewer.SetFacingCoverPage(const Value: Boolean);
begin
  FController.FacingCoverPage := Value;
end;

function TPdfViewer.GetMinZoom: Double;
begin
  Result := FController.MinZoom;
end;

procedure TPdfViewer.SetMinZoom(const Value: Double);
begin
  FController.MinZoom := Value;
end;

function TPdfViewer.GetMaxZoom: Double;
begin
  Result := FController.MaxZoom;
end;

procedure TPdfViewer.SetMaxZoom(const Value: Double);
begin
  FController.MaxZoom := Value;
end;

function TPdfViewer.GetPageGap: Single;
begin
  Result := FController.PageGap;
end;

procedure TPdfViewer.SetPageGap(const Value: Single);
begin
  FController.PageGap := Value;
end;

function TPdfViewer.GetPageMargin: Single;
begin
  Result := FController.PageMargin;
end;

procedure TPdfViewer.SetPageMargin(const Value: Single);
begin
  FController.PageMargin := Value;
end;

function TPdfViewer.GetBackgroundColor: TAlphaColor;
begin
  Result := FController.BackgroundColor;
end;

procedure TPdfViewer.SetBackgroundColor(const Value: TAlphaColor);
begin
  FController.BackgroundColor := Value;
end;

function TPdfViewer.GetPageShadow: Boolean;
begin
  Result := FController.PageShadow;
end;

procedure TPdfViewer.SetPageShadow(const Value: Boolean);
begin
  FController.PageShadow := Value;
end;

function TPdfViewer.GetCacheLimitMB: Integer;
begin
  Result := FController.CacheLimitMB;
end;

procedure TPdfViewer.SetCacheLimitMB(const Value: Integer);
begin
  FController.CacheLimitMB := Value;
end;

function TPdfViewer.GetPrefetchPages: Integer;
begin
  Result := FController.PrefetchPages;
end;

procedure TPdfViewer.SetPrefetchPages(const Value: Integer);
begin
  FController.PrefetchPages := Value;
end;

function TPdfViewer.GetTextSelectionEnabled: Boolean;
begin
  Result := FController.TextSelectionEnabled;
end;

procedure TPdfViewer.SetTextSelectionEnabled(const Value: Boolean);
begin
  FController.TextSelectionEnabled := Value;
end;

function TPdfViewer.GetLinksEnabled: Boolean;
begin
  Result := FController.LinksEnabled;
end;

procedure TPdfViewer.SetLinksEnabled(const Value: Boolean);
begin
  FController.LinksEnabled := Value;
end;

function TPdfViewer.GetSelectionColor: TAlphaColor;
begin
  Result := FController.SelectionColor;
end;

procedure TPdfViewer.SetSelectionColor(const Value: TAlphaColor);
begin
  FController.SelectionColor := Value;
end;

function TPdfViewer.GetHighlightColor: TAlphaColor;
begin
  Result := FController.HighlightColor;
end;

procedure TPdfViewer.SetHighlightColor(const Value: TAlphaColor);
begin
  FController.HighlightColor := Value;
end;

function TPdfViewer.GetActiveHighlightColor: TAlphaColor;
begin
  Result := FController.ActiveHighlightColor;
end;

procedure TPdfViewer.SetActiveHighlightColor(const Value: TAlphaColor);
begin
  FController.ActiveHighlightColor := Value;
end;

function TPdfViewer.GetOnPageChange: TPdfPageChangeEvent;
begin
  Result := FController.OnPageChange;
end;

procedure TPdfViewer.SetOnPageChange(const Value: TPdfPageChangeEvent);
begin
  FController.OnPageChange := Value;
end;

function TPdfViewer.GetOnLoadError: TPdfLoadErrorEvent;
begin
  Result := FController.OnLoadError;
end;

procedure TPdfViewer.SetOnLoadError(const Value: TPdfLoadErrorEvent);
begin
  FController.OnLoadError := Value;
end;

function TPdfViewer.GetOnPasswordRequest: TPdfPasswordEvent;
begin
  Result := FController.OnPasswordRequest;
end;

procedure TPdfViewer.SetOnPasswordRequest(const Value: TPdfPasswordEvent);
begin
  FController.OnPasswordRequest := Value;
end;

function TPdfViewer.GetOnRenderError: TPdfRenderErrorNotify;
begin
  Result := FController.OnRenderError;
end;

procedure TPdfViewer.SetOnRenderError(const Value: TPdfRenderErrorNotify);
begin
  FController.OnRenderError := Value;
end;

function TPdfViewer.GetOnPageRendered: TPdfPageRenderedEvent;
begin
  Result := FController.OnPageRendered;
end;

procedure TPdfViewer.SetOnPageRendered(const Value: TPdfPageRenderedEvent);
begin
  FController.OnPageRendered := Value;
end;

function TPdfViewer.GetOnZoomChange: TNotifyEvent;
begin
  Result := FController.OnZoomChange;
end;

procedure TPdfViewer.SetOnZoomChange(const Value: TNotifyEvent);
begin
  FController.OnZoomChange := Value;
end;

function TPdfViewer.GetOnScroll: TNotifyEvent;
begin
  Result := FController.OnScroll;
end;

procedure TPdfViewer.SetOnScroll(const Value: TNotifyEvent);
begin
  FController.OnScroll := Value;
end;

function TPdfViewer.GetOnLinkClick: TPdfLinkClickEvent;
begin
  Result := FController.OnLinkClick;
end;

procedure TPdfViewer.SetOnLinkClick(const Value: TPdfLinkClickEvent);
begin
  FController.OnLinkClick := Value;
end;

function TPdfViewer.GetOnOpenURI: TPdfOpenURIEvent;
begin
  Result := FController.OnOpenURI;
end;

procedure TPdfViewer.SetOnOpenURI(const Value: TPdfOpenURIEvent);
begin
  FController.OnOpenURI := Value;
end;

function TPdfViewer.GetOnSelectionChange: TNotifyEvent;
begin
  Result := FController.OnSelectionChange;
end;

procedure TPdfViewer.SetOnSelectionChange(const Value: TNotifyEvent);
begin
  FController.OnSelectionChange := Value;
end;

function TPdfViewer.GetNavigation: TPdfNavigation;
begin
  Result := FController.Navigation;
end;

function TPdfViewer.GetActiveMatch: Integer;
begin
  Result := FController.ActiveMatch;
end;

function TPdfViewer.GetSearchQuery: string;
begin
  Result := FController.SearchQuery;
end;

function TPdfViewer.GetDocument: TPdfDocument;
begin
  Result := FController.Document;
end;

function TPdfViewer.GetLayout: TPdfPageLayout;
begin
  Result := FController.Layout;
end;

function TPdfViewer.GetCache: TPdfImageCache;
begin
  Result := FController.Cache;
end;

function TPdfViewer.GetPageCount: Integer;
begin
  Result := FController.PageCount;
end;

function TPdfViewer.GetCurrentPage: Integer;
begin
  Result := FController.CurrentPage;
end;

function TPdfViewer.GetIsLoaded: Boolean;
begin
  Result := FController.IsLoaded;
end;

function TPdfViewer.GetFileName: string;
begin
  Result := FController.FileName;
end;

function TPdfViewer.GetScrollX: Double;
begin
  Result := FController.ScrollX;
end;

function TPdfViewer.GetScrollY: Double;
begin
  Result := FController.ScrollY;
end;

function TPdfViewer.GetRenderErrors: Integer;
begin
  Result := FController.RenderErrors;
end;

{ TPdfViewer: methods }

procedure TPdfViewer.LoadFromFile(const FileName: string; const Password: string);
begin
  FController.LoadFromFile(FileName, Password);
end;

procedure TPdfViewer.LoadFromStream(Stream: TStream; const Password: string);
begin
  FController.LoadFromStream(Stream, Password);
end;

procedure TPdfViewer.Close;
begin
  FController.Close;
end;

procedure TPdfViewer.GoToPage(Index: Integer);
begin
  FController.GoToPage(Index);
end;

procedure TPdfViewer.NextPage;
begin
  FController.NextPage;
end;

procedure TPdfViewer.PreviousPage;
begin
  FController.PreviousPage;
end;

procedure TPdfViewer.ZoomIn;
begin
  FController.ZoomIn;
end;

procedure TPdfViewer.ZoomOut;
begin
  FController.ZoomOut;
end;

procedure TPdfViewer.ZoomAt(NewZoom: Double; const Anchor: TPointF);
begin
  FController.ZoomAt(NewZoom, Anchor);
end;

procedure TPdfViewer.FitWidth;
begin
  FController.FitWidth;
end;

procedure TPdfViewer.FitPage;
begin
  FController.FitPage;
end;

procedure TPdfViewer.ScrollTo(X, Y: Double);
begin
  FController.ScrollTo(X, Y);
end;

procedure TPdfViewer.ScrollBy(DX, DY: Double);
begin
  FController.ScrollBy(DX, DY);
end;

procedure TPdfViewer.RotateClockwise;
begin
  FController.RotateClockwise;
end;

procedure TPdfViewer.RotateCounterClockwise;
begin
  FController.RotateCounterClockwise;
end;

function TPdfViewer.RowPages(Index: Integer): TArray<Integer>;
begin
  Result := FController.RowPages(Index);
end;

function TPdfViewer.PageSize(Index: Integer): TSizeF;
begin
  Result := FController.PageSize(Index);
end;

function TPdfViewer.RenderPageToImage(Index: Integer; Scale: Double; Background: TAlphaColor;
  ARotation: Integer): ISkImage;
begin
  Result := FController.RenderPageToImage(Index, Scale, Background, ARotation);
end;

procedure TPdfViewer.RequestPageImage(Index: Integer; Scale: Double; Priority: Integer);
begin
  FController.RequestPageImage(Index, Scale, Priority);
end;

function TPdfViewer.TryGetPageImage(Index: Integer; Scale: Double; out Image: ISkImage): Boolean;
begin
  Result := FController.TryGetPageImage(Index, Scale, Image);
end;

function TPdfViewer.TryGetNearestPageImage(Index: Integer; Scale: Double; out Image: ISkImage;
  out ImageScale: Double): Boolean;
begin
  Result := FController.TryGetNearestPageImage(Index, Scale, Image, ImageScale);
end;

procedure TPdfViewer.AddChangeListener(const Listener: TPdfViewerChangeEvent);
begin
  FController.AddChangeListener(Listener);
end;

procedure TPdfViewer.RemoveChangeListener(const Listener: TPdfViewerChangeEvent);
begin
  if FController <> nil then
    FController.RemoveChangeListener(Listener);
end;

function TPdfViewer.PageAtPoint(const P: TPointF): Integer;
begin
  Result := FController.PageAtPoint(P);
end;

function TPdfViewer.Outline: TObjectList<TPdfOutlineItem>;
begin
  Result := FController.Outline;
end;

function TPdfViewer.GoToDestination(const Dest: TPdfDestination): Boolean;
begin
  Result := FController.GoToDestination(Dest);
end;

procedure TPdfViewer.GoToOutlineItem(Item: TPdfOutlineItem);
begin
  FController.GoToOutlineItem(Item);
end;

function TPdfViewer.PerformAction(const Action: TPdfAction): Boolean;
begin
  Result := FController.PerformAction(Action);
end;

function TPdfViewer.TextPage(Index: Integer): TPdfTextPage;
begin
  Result := FController.TextPage(Index);
end;

function TPdfViewer.Find(const Query: string; CaseSensitive, WholeWord: Boolean): Integer;
begin
  Result := FController.Find(Query, CaseSensitive, WholeWord);
end;

function TPdfViewer.FindNext: Boolean;
begin
  Result := FController.FindNext;
end;

function TPdfViewer.FindPrevious: Boolean;
begin
  Result := FController.FindPrevious;
end;

procedure TPdfViewer.ClearSearch;
begin
  FController.ClearSearch;
end;

function TPdfViewer.SearchMatchCount: Integer;
begin
  Result := FController.SearchMatchCount;
end;

function TPdfViewer.SearchMatch(Index: Integer): TPdfSearchMatch;
begin
  Result := FController.SearchMatch(Index);
end;

procedure TPdfViewer.GoToMatch(Index: Integer);
begin
  FController.GoToMatch(Index);
end;

function TPdfViewer.SelectedText: string;
begin
  Result := FController.SelectedText;
end;

function TPdfViewer.HasSelection: Boolean;
begin
  Result := FController.HasSelection;
end;

procedure TPdfViewer.ClearSelection;
begin
  FController.ClearSelection;
end;

procedure TPdfViewer.SelectPage(PageIndex: Integer);
begin
  FController.SelectPage(PageIndex);
end;

function TPdfViewer.CopySelection: Boolean;
begin
  Result := FController.CopySelection;
end;

function TPdfViewer.PointToPage(const P: TPointF; out PageIndex: Integer; out PX, PY: Double): Boolean;
begin
  Result := FController.PointToPage(P, PageIndex, PX, PY);
end;
