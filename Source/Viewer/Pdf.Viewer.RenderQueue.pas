{*******************************************************************************
  Pdf.Viewer.RenderQueue
  Background rendering of pages: one worker thread with a priority queue
  renders pages to ISkImage (through TPdfPageRenderer) and stores them in
  a TPdfImageCache. Requests carry a generation number so that a zoom change
  cancels pending work. Results are reported through OnPageReady, which is
  called on the worker thread; the UI marshals it as needed.
  Only the worker thread touches the document while the queue is running.
*******************************************************************************}
unit Pdf.Viewer.RenderQueue;

interface

uses
  System.SysUtils, System.Classes, System.Math, System.SyncObjs, System.Generics.Collections,
  System.UITypes, System.Skia,
  Pdf.Core.Types, Pdf.Core.Document, Pdf.Render.Skia, Pdf.Viewer.Cache;

type
  TPdfRenderRequest = record
    Page: Integer;
    Scale: Double;
    /// <summary>Lower runs first; the viewer uses the distance to the viewport.</summary>
    Priority: Integer;
    Generation: Integer;
  end;

  TPdfPageReadyEvent = procedure(Sender: TObject; Page: Integer; Scale: Double; const Image: ISkImage) of object;
  TPdfRenderErrorEvent = procedure(Sender: TObject; Page: Integer; const Message: string) of object;

  TPdfRenderQueue = class
  private type
    TWorker = class(TThread)
    private
      FOwner: TPdfRenderQueue;
    protected
      procedure Execute; override;
    public
      constructor Create(AOwner: TPdfRenderQueue);
    end;
  private
    FDocument: TPdfDocument;
    FCache: TPdfImageCache;
    FRenderer: TPdfPageRenderer;
    FLock: TObject;
    FSignal: TEvent;
    FIdle: TEvent;
    FQueue: TList<TPdfRenderRequest>;
    FWorker: TWorker;
    FGeneration: Integer;
    FBackground: TAlphaColor;
    FOnPageReady: TPdfPageReadyEvent;
    FOnError: TPdfRenderErrorEvent;
    FRendered: Int64;
    FBusyPage: Integer;
    FBusyScaleKey: Integer;
    FBusyGeneration: Integer;
    FPageCount: Integer;
    FTerminating: Boolean;
    function TakeNext(out Req: TPdfRenderRequest): Boolean;
    procedure WorkerLoop;
  public
    /// <summary>The queue renders pages of Document into Cache (both owned by the caller and must outlive the queue).</summary>
    constructor Create(ADocument: TPdfDocument; ACache: TPdfImageCache);
    destructor Destroy; override;
    /// <summary>Starts the worker thread (idempotent).</summary>
    procedure Start;
    /// <summary>Stops the worker and waits for it; pending requests are dropped. Safe to call twice.</summary>
    procedure Stop;
    /// <summary>Queues a page at a render scale (device pixels per point). Duplicates (queued or being rendered),
    /// already cached pages and page indexes outside the document are ignored.</summary>
    procedure Request(Page: Integer; Scale: Double; Priority: Integer);
    /// <summary>Drops all pending requests and invalidates the ones in progress (results are discarded).</summary>
    procedure CancelPending;
    /// <summary>Waits until the queue is empty and the worker is idle (tests); False on timeout.</summary>
    function WaitIdle(TimeoutMs: Cardinal): Boolean;
    function PendingCount: Integer;
    property Cache: TPdfImageCache read FCache;
    property Document: TPdfDocument read FDocument;
    property Background: TAlphaColor read FBackground write FBackground;
    /// <summary>Called on the worker thread after an image has been stored in the cache.</summary>
    property OnPageReady: TPdfPageReadyEvent read FOnPageReady write FOnPageReady;
    property OnError: TPdfRenderErrorEvent read FOnError write FOnError;
    property RenderedCount: Int64 read FRendered;
    /// <summary>Page currently being rendered, -1 when idle.</summary>
    property BusyPage: Integer read FBusyPage;
    property Renderer: TPdfPageRenderer read FRenderer;
  end;

implementation

{ TPdfRenderQueue.TWorker }

constructor TPdfRenderQueue.TWorker.Create(AOwner: TPdfRenderQueue);
begin
  inherited Create(False);
  FOwner := AOwner;
  FreeOnTerminate := False;
end;

procedure TPdfRenderQueue.TWorker.Execute;
begin
  NameThreadForDebugging('PdfRenderQueue');
  FOwner.WorkerLoop;
end;

{ TPdfRenderQueue }

constructor TPdfRenderQueue.Create(ADocument: TPdfDocument; ACache: TPdfImageCache);
begin
  inherited Create;
  FDocument := ADocument;
  FCache := ACache;
  FRenderer := TPdfPageRenderer.Create(ADocument);
  FLock := TObject.Create;
  FSignal := TEvent.Create(nil, False, False, '');
  FIdle := TEvent.Create(nil, True, True, '');
  FQueue := TList<TPdfRenderRequest>.Create;
  FBackground := TAlphaColorRec.White;
  FBusyPage := -1;
  if (ADocument <> nil) and ADocument.IsLoaded then
    FPageCount := ADocument.PageCount;
end;

destructor TPdfRenderQueue.Destroy;
begin
  Stop;
  FQueue.Free;
  FIdle.Free;
  FSignal.Free;
  FLock.Free;
  FRenderer.Free;
  inherited;
end;

procedure TPdfRenderQueue.Start;
begin
  if FWorker <> nil then
    Exit;
  FTerminating := False;
  FWorker := TWorker.Create(Self);
end;

procedure TPdfRenderQueue.Stop;
var
  W: TWorker;
begin
  W := FWorker;
  if W = nil then
    Exit;
  TMonitor.Enter(FLock);
  try
    FTerminating := True;
    FQueue.Clear;
    Inc(FGeneration);
  finally
    TMonitor.Exit(FLock);
  end;
  W.Terminate;
  FSignal.SetEvent;
  W.WaitFor;
  W.Free;
  FWorker := nil;
  FIdle.SetEvent;
end;

procedure TPdfRenderQueue.Request(Page: Integer; Scale: Double; Priority: Integer);
var
  I: Integer;
  R: TPdfRenderRequest;
begin
  if (FDocument = nil) or (Page < 0) or (Page >= FPageCount) or (Scale <= 0) then
    Exit;
  if FCache.Contains(Page, Scale) then
    Exit;
  TMonitor.Enter(FLock);
  try
    // Already being rendered for the current generation
    if (FBusyPage = Page) and (FBusyScaleKey = TPdfCacheKey.ScaleToKey(Scale)) and (FBusyGeneration = FGeneration) then
      Exit;
    for I := 0 to FQueue.Count - 1 do
      if (FQueue[I].Page = Page) and (TPdfCacheKey.ScaleToKey(FQueue[I].Scale) = TPdfCacheKey.ScaleToKey(Scale)) then
      begin
        if Priority < FQueue[I].Priority then
        begin
          R := FQueue[I];
          R.Priority := Priority;
          FQueue[I] := R;
        end;
        Exit;
      end;
    R.Page := Page;
    R.Scale := Scale;
    R.Priority := Priority;
    R.Generation := FGeneration;
    FQueue.Add(R);
    FIdle.ResetEvent;
  finally
    TMonitor.Exit(FLock);
  end;
  FSignal.SetEvent;
end;

procedure TPdfRenderQueue.CancelPending;
begin
  TMonitor.Enter(FLock);
  try
    FQueue.Clear;
    Inc(FGeneration);
    if FBusyPage < 0 then
      FIdle.SetEvent;
  finally
    TMonitor.Exit(FLock);
  end;
end;

function TPdfRenderQueue.PendingCount: Integer;
begin
  TMonitor.Enter(FLock);
  try
    Result := FQueue.Count;
  finally
    TMonitor.Exit(FLock);
  end;
end;

function TPdfRenderQueue.WaitIdle(TimeoutMs: Cardinal): Boolean;
begin
  if FWorker = nil then
    Exit(True);
  Result := FIdle.WaitFor(TimeoutMs) = wrSignaled;
end;

function TPdfRenderQueue.TakeNext(out Req: TPdfRenderRequest): Boolean;
var
  I, Best: Integer;
begin
  TMonitor.Enter(FLock);
  try
    Result := FQueue.Count > 0;
    if not Result then
    begin
      FBusyPage := -1;
      FIdle.SetEvent;
      Exit;
    end;
    Best := 0;
    for I := 1 to FQueue.Count - 1 do
      if FQueue[I].Priority < FQueue[Best].Priority then
        Best := I;
    Req := FQueue[Best];
    FQueue.Delete(Best);
    FBusyPage := Req.Page;
    FBusyScaleKey := TPdfCacheKey.ScaleToKey(Req.Scale);
    FBusyGeneration := Req.Generation;
  finally
    TMonitor.Exit(FLock);
  end;
end;

procedure TPdfRenderQueue.WorkerLoop;
var
  Req: TPdfRenderRequest;
  Image: ISkImage;
  Stale: Boolean;
begin
  while not FTerminating do
  begin
    if not TakeNext(Req) then
    begin
      FSignal.WaitFor(INFINITE);
      Continue;
    end;
    Image := nil;
    try
      try
        if (Req.Page >= 0) and (Req.Page < FDocument.PageCount) then
          Image := FRenderer.RenderToImage(FDocument.Pages[Req.Page], Req.Scale, FBackground);
      except
        on E: Exception do
        begin
          if Assigned(FOnError) and not FTerminating then
            FOnError(Self, Req.Page, E.Message);
          Image := nil;
        end;
      end;
      TMonitor.Enter(FLock);
      try
        Stale := (Req.Generation <> FGeneration) or FTerminating;
        if (Image <> nil) and not Stale then
          FCache.Put(Req.Page, Req.Scale, Image); // stored before the busy marker is cleared
        FBusyPage := -1;
      finally
        TMonitor.Exit(FLock);
      end;
      if (Image <> nil) and not Stale then
      begin
        TInterlocked.Increment(FRendered);
        if Assigned(FOnPageReady) then
          FOnPageReady(Self, Req.Page, Req.Scale, Image);
      end;
    finally
      Image := nil;
    end;
  end;
end;

end.
