{*******************************************************************************
  Pdf.Tests.Controller
  DUnitX fixture for TPdfViewerController (Pdf.Viewer.Controller) without a
  UI framework: a stub host stands in for the FMX or VCL control. Covers
  drag input: mouse drags over text select it, touch drags always scroll,
  and with HostPansTouch the controller leaves touch scrolling to the host
  (the FMX viewer, which adds the platform's momentum).
*******************************************************************************}
unit Pdf.Tests.Controller;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.UITypes, System.Skia, DUnitX.TestFramework,
  Pdf.Viewer.Controller;

type
  TStubHost = class(TInterfacedObject, IPdfControlHost)
  public
    procedure InvalidateHost;
    function HostSize: TSizeF;
    function HostDeviceScale: Single;
    function HostScrollBarSize: Single;
    procedure SyncScrollBars(const Vertical, Horizontal: TPdfScrollBarState);
    procedure SetHostCursor(Cursor: TCursor);
    function CopyTextToClipboard(const Text: string): Boolean;
  end;

  [TestFixture]
  TPdfViewerControllerTests = class
  private
    FHost: IPdfControlHost;
    FController: TPdfViewerController;
    /// <summary>Control point on the middle of the first glyph of page 1.</summary>
    function TextPoint: TPointF;
    /// <summary>Drags from Start upwards by 6 steps of 20 pixels; Touch adds ssTouch.</summary>
    procedure Drag(Touch: Boolean; const Start: TPointF);
    /// <summary>Paints into an offscreen surface, which requests the visible pages from the render queue.</summary>
    procedure Paint;
    /// <summary>Lets the render thread work and runs its queued notifications until Done or the timeout.</summary>
    function WaitFor(const Done: TFunc<Boolean>; TimeoutMs: Integer): Boolean;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure MouseDrag_OnBackground_Scrolls;
    [Test] procedure MouseDrag_OnText_Selects;
    [Test] procedure TouchDrag_OnText_ScrollsWithoutSelecting;
    [Test] procedure HostPansTouch_TouchDragLeavesScrollToHost;
    [Test] procedure HostPansTouch_MouseDragStillScrolls;
    [Test] procedure Pinch_RendersOnlyTheFinalZoom;
    [Test] procedure DeepZoom_RenditionFitsTheCache;
  end;

implementation

uses
  Pdf.Render.Text, Pdf.Tests.Builder;

{ TStubHost }

procedure TStubHost.InvalidateHost;
begin
end;

function TStubHost.HostSize: TSizeF;
begin
  Result := TSizeF.Create(400, 600);
end;

function TStubHost.HostDeviceScale: Single;
begin
  Result := 1;
end;

function TStubHost.HostScrollBarSize: Single;
begin
  Result := 14;
end;

procedure TStubHost.SyncScrollBars(const Vertical, Horizontal: TPdfScrollBarState);
begin
end;

procedure TStubHost.SetHostCursor(Cursor: TCursor);
begin
end;

function TStubHost.CopyTextToClipboard(const Text: string): Boolean;
begin
  Result := False;
end;

{ TPdfViewerControllerTests }

procedure TPdfViewerControllerTests.Setup;
var
  B: TPdfTestBuilder;
  Stream: TBytesStream;
begin
  FHost := TStubHost.Create;
  FController := TPdfViewerController.Create(nil, FHost);
  B := TPdfTestBuilder.SimpleDocument(5, '', '/MediaBox [0 0 612 792] ' +
    '/Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>');
  try
    Stream := TBytesStream.Create(B.Build(1));
    try
      FController.LoadFromStream(Stream);
    finally
      Stream.Free;
    end;
  finally
    B.Free;
  end;
end;

procedure TPdfViewerControllerTests.TearDown;
begin
  FreeAndNil(FController);
  FHost := nil;
end;

function TPdfViewerControllerTests.TextPoint: TPointF;
var
  TP: TPdfTextPage;
  C: TPointF;
  R: TRectF;
begin
  TP := FController.TextPage(0);
  Assert.IsTrue((TP <> nil) and (TP.GlyphCount > 0), 'page 1 has text');
  C := TP.Glyph(0).Bounds.CenterPoint;
  R := FController.Layout.PageRect[0];
  Result := TPointF.Create(R.Left + C.X * FController.Zoom - FController.ScrollX,
    R.Top + C.Y * FController.Zoom - FController.ScrollY);
  Assert.IsTrue((Result.Y > 120) and (Result.Y < 600), 'the text is in view and leaves room to drag up');
end;

procedure TPdfViewerControllerTests.Drag(Touch: Boolean; const Start: TPointF);
var
  Shift: TShiftState;
  I: Integer;
  P: TPointF;
begin
  Shift := [ssLeft];
  if Touch then
    Include(Shift, ssTouch);
  P := Start;
  FController.MouseDown(TMouseButton.mbLeft, Shift, P);
  for I := 1 to 6 do
  begin
    P.Y := P.Y - 20;
    FController.MouseMove(Shift, P);
  end;
  FController.MouseUp(TMouseButton.mbLeft, Shift, P);
end;

procedure TPdfViewerControllerTests.Paint;
var
  Surface: ISkSurface;
begin
  Surface := TSkSurface.MakeRaster(400, 600);
  FController.Draw(Surface.Canvas, TRectF.Create(0, 0, 400, 600));
end;

function TPdfViewerControllerTests.WaitFor(const Done: TFunc<Boolean>; TimeoutMs: Integer): Boolean;
var
  Elapsed: Integer;
begin
  Elapsed := 0;
  repeat
    CheckSynchronize(10);
    Result := Done();
    if Result then
      Exit;
    Sleep(10);
    Inc(Elapsed, 20);
  until Elapsed >= TimeoutMs;
end;

procedure TPdfViewerControllerTests.Pinch_RendersOnlyTheFinalZoom;
var
  Center: TPointF;
  Passing: array[0..1] of Double;
  FinalZoom: Double;
begin
  Paint;
  Assert.IsTrue(WaitFor(
    function: Boolean
    begin
      Result := FController.Cache.Contains(0, FController.Zoom);
    end, 5000), 'page 1 rendered at the starting zoom');
  Center := TPointF.Create(200, 300);
  FController.Pinch(ppBegin, 100, Center);
  FController.Pinch(ppUpdate, 150, Center);
  Passing[0] := FController.Zoom;
  Paint;
  FController.Pinch(ppUpdate, 200, Center);
  Passing[1] := FController.Zoom;
  Paint;
  FController.Pinch(ppUpdate, 230, Center);
  FinalZoom := FController.Zoom;
  Paint;
  WaitFor(function: Boolean begin Result := False end, 400);
  Assert.IsFalse(FController.Cache.Contains(0, Passing[0]), 'nothing rendered while pinching');
  Assert.IsFalse(FController.Cache.Contains(0, Passing[1]), 'nothing rendered while pinching');
  Assert.IsFalse(FController.Cache.Contains(0, FinalZoom), 'nothing rendered before the pinch ends');
  FController.Pinch(ppEnd, 230, Center);
  Paint;
  Assert.IsTrue(WaitFor(
    function: Boolean
    begin
      Result := FController.Cache.Contains(0, FinalZoom);
    end, 5000), 'the final zoom is rendered once the pinch ends');
end;

procedure TPdfViewerControllerTests.DeepZoom_RenditionFitsTheCache;
var
  Img: ISkImage;
  ImgScale: Double;
begin
  FController.CacheLimitMB := 4;
  FController.ZoomAt(8, TPointF.Create(0, 0));
  Paint;
  Assert.IsTrue(WaitFor(
    function: Boolean
    begin
      Result := FController.TryGetNearestPageImage(0, FController.Zoom, Img, ImgScale);
    end, 5000), 'a rendition of page 1 is cached despite the deep zoom');
  Assert.IsTrue(ImgScale < FController.Zoom, 'rendered below the zoom');
  Assert.IsTrue(Int64(Img.Width) * Img.Height * 4 <= FController.Cache.MaxBytes div 4,
    Format('the rendition takes at most a quarter of the cache (%d x %d)', [Img.Width, Img.Height]));
end;

procedure TPdfViewerControllerTests.MouseDrag_OnBackground_Scrolls;
begin
  Drag(False, TPointF.Create(3, 300)); // the margin left of the page
  Assert.AreEqual(120.0, FController.ScrollY, 0.5);
  Assert.IsFalse(FController.HasSelection);
end;

procedure TPdfViewerControllerTests.MouseDrag_OnText_Selects;
begin
  Drag(False, TextPoint);
  Assert.IsTrue(FController.HasSelection, 'a mouse drag over text selects it');
  Assert.AreEqual(0.0, FController.ScrollY, 0.01, 'and does not scroll');
end;

procedure TPdfViewerControllerTests.TouchDrag_OnText_ScrollsWithoutSelecting;
begin
  Drag(True, TextPoint);
  Assert.IsFalse(FController.HasSelection, 'a finger over text does not select');
  Assert.AreEqual(120.0, FController.ScrollY, 0.5, 'it scrolls');
end;

procedure TPdfViewerControllerTests.HostPansTouch_TouchDragLeavesScrollToHost;
begin
  FController.HostPansTouch := True;
  Drag(True, TPointF.Create(200, 300));
  Assert.AreEqual(0.0, FController.ScrollY, 0.01, 'the host scrolls touch drags itself');
end;

procedure TPdfViewerControllerTests.HostPansTouch_MouseDragStillScrolls;
begin
  FController.HostPansTouch := True;
  Drag(False, TPointF.Create(3, 300));
  Assert.AreEqual(120.0, FController.ScrollY, 0.5);
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfViewerControllerTests);

end.
