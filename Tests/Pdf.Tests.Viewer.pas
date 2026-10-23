{*******************************************************************************
  Pdf.Tests.Viewer
  DUnitX fixtures for the non-visual parts of the viewer layer:
  Pdf.Viewer.Layout (TPdfPageLayout), Pdf.Viewer.Cache (TPdfImageCache) and
  Pdf.Viewer.RenderQueue (TPdfRenderQueue).
*******************************************************************************}
unit Pdf.Tests.Viewer;

interface

uses
  System.SysUtils, System.Types, System.Math, System.Classes, System.SyncObjs, System.Diagnostics,
  System.Generics.Collections, System.UITypes, System.Skia, DUnitX.TestFramework,
  Pdf.Core.Types, Pdf.Core.Document, Pdf.Render.Skia, Pdf.Viewer.Layout, Pdf.Viewer.Cache, Pdf.Viewer.RenderQueue;

type
  [TestFixture]
  TPdfPageLayoutTests = class
  private
    FLayout: TPdfPageLayout;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure TwoLetterPages_Geometry;
    [Test] procedure Zoom2_DoublesPageSizes;
    [Test] procedure VisiblePages_ScrollPositions;
    [Test] procedure CurrentPage_LargestVisibleArea;
    [Test] procedure CurrentPage_TieGoesToUpperPage;
    [Test] procedure CurrentPage_NoPages;
    [Test] procedure CurrentPage_PastEnd_LastPage;
    [Test] procedure PageAt_Points;
    [Test] procedure ScrollTopOfPage_NearTopAndClamped;
    [Test] procedure MaxScroll_AndClamp;
    [Test] procedure FitWidthZoom_Letter;
    [Test] procedure FitPageZoom_Letter;
    [Test] procedure FitZoom_MixedPageSizes;
    [Test] procedure DocumentToPage_Corners;
    [Test] procedure DocumentToPage_InvalidIndex;
    [Test] procedure Invalidation_GapMarginZoomViewport;
    [Test] procedure EmptyPages;
    [Test] procedure PageSizesFromDocument_Rotated;
    [Test] procedure Facing_TwoColumns_Geometry;
    [Test] procedure Facing_CoverPage_FirstAloneOnTheRight;
    [Test] procedure Facing_Rows_And_FitZoom;
    [Test] procedure NonContinuous_OnlyActiveRowLaidOut;
    [Test] procedure NonContinuous_CurrentPage_And_ScrollTop;
    [Test] procedure Renderer_PageMatrix_ExtraRotation;
  end;

  [TestFixture]
  TPdfImageCacheTests = class
  public
    [Test] procedure PutGet_ExactMatch;
    [Test] procedure Get_DifferentScale_Misses;
    [Test] procedure HitsAndMisses_Counters;
    [Test] procedure Contains_Count_Bytes;
    [Test] procedure PdfImageBytes_Values;
    [Test] procedure Put_SameKey_Replaces;
    [Test] procedure LRU_EvictsOldest;
    [Test] procedure LRU_GetMarksRecentlyUsed;
    [Test] procedure Put_LargerThanBudget_NotStored;
    [Test] procedure MaxBytes_Lowered_EvictsToFit;
    [Test] procedure GetNearest_ClosestLogRatio;
    [Test] procedure GetNearest_UnknownPage;
    [Test] procedure RemovePage_AllScales;
    [Test] procedure Clear_EmptiesAndResetsBytes;
    [Test] procedure ScaleKey_Quantisation;
    [Test] procedure ThreadSafety_Smoke;
  end;

  [TestFixture]
  TPdfRenderQueueTests = class
  private
    FDoc: TPdfDocument;
    FCache: TPdfImageCache;
    FQueue: TPdfRenderQueue;
    FReadyCount: Integer;
    FErrorCount: Integer;
    FOrderLock: TObject;
    FOrder: TList<Integer>;
    FReadyScales: TList<Double>;
    FLastError: string;
    procedure PageReady(Sender: TObject; Page: Integer; Scale: Double; const Image: ISkImage);
    procedure RenderError(Sender: TObject; Page: Integer; const Message: string);
    function Order: TArray<Integer>;
    function WaitFor(const Condition: TFunc<Boolean>; TimeoutMs: Integer): Boolean;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure RenderOnePage;
    [Test] procedure WaitIdle_NotStarted;
    [Test] procedure Priority_LowerRunsFirst_WorkerBusy;
    [Test] procedure Priority_QueuedBeforeStart;
    [Test] procedure Request_AlreadyCached_NotQueued;
    [Test] procedure Request_Duplicates_Merged;
    [Test] procedure Request_Duplicate_KeepsLowerPriority;
    [Test] procedure Request_WhileRendering_NotDuplicated;
    [Test] procedure CancelPending_DropsQueued;
    [Test] procedure CancelPending_InFlightResultDiscarded;
    [Test] procedure Stop_Prompt_ThenStartAgain;
    [Test] procedure Request_InvalidArguments_Ignored;
    [Test] procedure Request_PageOutOfRange_NoImage;
    [Test] procedure OnError_SurfaceTooLarge;
    [Test] procedure Free_WhileRendering;
  end;

implementation

uses
  Pdf.Tests.Builder;

const
  LetterW = 612;
  LetterH = 792;
  A4W = 595.28;
  A4H = 841.89;
  Eps = 1E-6;

function MakeImage(W, H: Integer): ISkImage;
var
  Surface: ISkSurface;
begin
  Surface := TSkSurface.MakeRaster(W, H);
  Surface.Canvas.Clear(TAlphaColorRec.White);
  Result := Surface.MakeImageSnapshot;
end;

function StreamObj(const Data: string): string;
begin
  Result := '<< /Length ' + IntToStr(Length(Data)) + ' >>'#10'stream'#10 + Data + #10'endstream';
end;

{ ---------------------------------------------------------------------------- }
{ TPdfPageLayoutTests                                                          }
{ ---------------------------------------------------------------------------- }

procedure TPdfPageLayoutTests.Setup;
begin
  FLayout := TPdfPageLayout.Create;
  FLayout.SetPages([TSizeF.Create(LetterW, LetterH), TSizeF.Create(LetterW, LetterH)]);
  FLayout.Zoom := 1;
  FLayout.Gap := 8;
  FLayout.Margin := 8;
  FLayout.ViewportWidth := 800;
  FLayout.ViewportHeight := 600;
end;

procedure TPdfPageLayoutTests.TearDown;
begin
  FLayout.Free;
end;

procedure TPdfPageLayoutTests.TwoLetterPages_Geometry;
var
  R0, R1: TRectF;
begin
  Assert.AreEqual(2, FLayout.PageCount);
  Assert.AreEqual(800.0, FLayout.TotalWidth, Eps, 'viewport wider than the page');
  Assert.AreEqual(8.0 + 792 + 8 + 792 + 8, FLayout.TotalHeight, Eps);
  R0 := FLayout.PageRect[0];
  R1 := FLayout.PageRect[1];
  Assert.AreEqual((800.0 - 612) / 2, Double(R0.Left), Eps, 'page 0 centred');
  Assert.AreEqual(8.0, Double(R0.Top), Eps);
  Assert.AreEqual(612.0, Double(R0.Width), Eps);
  Assert.AreEqual(792.0, Double(R0.Height), Eps);
  Assert.AreEqual(8.0 + 792 + 8, Double(R1.Top), Eps);
  Assert.AreEqual(Double(R0.Left), Double(R1.Left), Eps);
  Assert.IsTrue(FLayout.PageRect[2].IsEmpty, 'out of range index gives an empty rect');
  Assert.IsTrue(FLayout.PageRect[-1].IsEmpty);
end;

procedure TPdfPageLayoutTests.Zoom2_DoublesPageSizes;
var
  R0, R1: TRectF;
begin
  FLayout.Zoom := 2;
  R0 := FLayout.PageRect[0];
  R1 := FLayout.PageRect[1];
  Assert.AreEqual(1224.0, Double(R0.Width), Eps);
  Assert.AreEqual(1584.0, Double(R0.Height), Eps);
  Assert.AreEqual(612.0 * 2 + 16, FLayout.TotalWidth, Eps);
  Assert.AreEqual(8.0 + 1584 + 8 + 1584 + 8, FLayout.TotalHeight, Eps);
  Assert.AreEqual(8.0, Double(R0.Left), Eps, 'content wider than viewport: page at the margin');
  Assert.AreEqual(8.0 + 1584 + 8, Double(R1.Top), Eps);
  // Zoom <= 0 is ignored
  FLayout.Zoom := 0;
  Assert.AreEqual(2.0, FLayout.Zoom, Eps);
  FLayout.Zoom := -1;
  Assert.AreEqual(2.0, FLayout.Zoom, Eps);
end;

procedure TPdfPageLayoutTests.VisiblePages_ScrollPositions;
var
  V: TArray<TPdfPageRect>;
begin
  V := FLayout.VisiblePages(0, 0);
  Assert.AreEqual(1, Integer(Length(V)), 'ScrollY 0');
  Assert.AreEqual(0, V[0].Index);
  Assert.AreEqual(8.0, Double(V[0].Rect.Top), Eps);

  V := FLayout.VisiblePages(0, 700);
  Assert.AreEqual(2, Integer(Length(V)), 'ScrollY 700');
  Assert.AreEqual(0, V[0].Index);
  Assert.AreEqual(1, V[1].Index);
  Assert.AreEqual(808.0, Double(V[1].Rect.Top), Eps);

  V := FLayout.VisiblePages(0, 900);
  Assert.AreEqual(1, Integer(Length(V)), 'ScrollY 900');
  Assert.AreEqual(1, V[0].Index);

  V := FLayout.VisiblePages(0, 2000);
  Assert.AreEqual(0, Integer(Length(V)), 'beyond the end');
end;

procedure TPdfPageLayoutTests.CurrentPage_LargestVisibleArea;
begin
  Assert.AreEqual(0, FLayout.CurrentPage(0, 0));
  // page 0 shows 700..800 (100 px), page 1 shows 808..1300 (492 px)
  Assert.AreEqual(1, FLayout.CurrentPage(0, 700));
  // page 0 shows 500 px, page 1 shows 92 px
  Assert.AreEqual(0, FLayout.CurrentPage(0, 300));
  Assert.AreEqual(1, FLayout.CurrentPage(0, 900));
end;

procedure TPdfPageLayoutTests.CurrentPage_TieGoesToUpperPage;
begin
  // ScrollY 504: page 0 shows 504..800 = 296 px, page 1 shows 808..1104 = 296 px
  Assert.AreEqual(0, FLayout.CurrentPage(0, 504));
  Assert.AreEqual(1, FLayout.CurrentPage(0, 505));
  Assert.AreEqual(0, FLayout.CurrentPage(0, 503));
end;

procedure TPdfPageLayoutTests.CurrentPage_NoPages;
begin
  FLayout.SetPages(nil);
  Assert.AreEqual(-1, FLayout.CurrentPage(0, 0));
  Assert.AreEqual(-1, FLayout.CurrentPage(0, 500));
end;

procedure TPdfPageLayoutTests.CurrentPage_PastEnd_LastPage;
begin
  Assert.AreEqual(1, FLayout.CurrentPage(0, 5000));
  Assert.AreEqual(1, FLayout.CurrentPage(0, FLayout.TotalHeight));
end;

procedure TPdfPageLayoutTests.PageAt_Points;
var
  Left: Double;
begin
  Left := FLayout.PageRect[0].Left;
  Assert.AreEqual(0, FLayout.PageAt(400, 100), 'inside page 0');
  Assert.AreEqual(1, FLayout.PageAt(400, 1000), 'inside page 1');
  Assert.AreEqual(-1, FLayout.PageAt(400, 804), 'in the gap');
  Assert.AreEqual(-1, FLayout.PageAt(400, 4), 'in the top margin');
  Assert.AreEqual(-1, FLayout.PageAt(Left - 10, 1000), 'left of the page');
  Assert.AreEqual(-1, FLayout.PageAt(Left + 612 + 10, 1000), 'right of the page');
  Assert.AreEqual(-1, FLayout.PageAt(400, 5000), 'below the last page');
end;

procedure TPdfPageLayoutTests.ScrollTopOfPage_NearTopAndClamped;
var
  S, Top1: Double;
begin
  Top1 := FLayout.PageRect[1].Top;
  S := FLayout.ScrollTopOfPage(1);
  Assert.IsTrue(S <= Top1, Format('scroll %.2f must not be below the page top %.2f', [S, Top1]));
  Assert.IsTrue(Top1 - S <= FLayout.Margin + Eps, Format('page top %.2f within the margin of scroll %.2f', [Top1, S]));
  Assert.AreEqual(0.0, FLayout.ScrollTopOfPage(0), Eps, 'first page: clamped to 0');
  Assert.AreEqual(0.0, FLayout.ScrollTopOfPage(-1), Eps);
  Assert.AreEqual(0.0, FLayout.ScrollTopOfPage(5), Eps);
  // Taller viewport: MaxScrollY = 1608 - 1000 = 608 < page 1 top - margin
  FLayout.ViewportHeight := 1000;
  Assert.AreEqual(608.0, FLayout.MaxScrollY, Eps);
  Assert.AreEqual(FLayout.MaxScrollY, FLayout.ScrollTopOfPage(1), Eps, 'clamped to MaxScrollY');
end;

procedure TPdfPageLayoutTests.MaxScroll_AndClamp;
begin
  Assert.AreEqual(0.0, FLayout.MaxScrollX, Eps, 'content narrower than viewport');
  Assert.AreEqual(1608.0 - 600, FLayout.MaxScrollY, Eps);
  Assert.AreEqual(0.0, FLayout.ClampScrollY(-50), Eps);
  Assert.AreEqual(300.0, FLayout.ClampScrollY(300), Eps);
  Assert.AreEqual(1008.0, FLayout.ClampScrollY(5000), Eps);
  Assert.AreEqual(0.0, FLayout.ClampScrollX(100), Eps);
  FLayout.Zoom := 2;
  Assert.AreEqual(1240.0 - 800, FLayout.MaxScrollX, Eps, 'zoom 2');
  Assert.AreEqual(3192.0 - 600, FLayout.MaxScrollY, Eps);
  Assert.AreEqual(440.0, FLayout.ClampScrollX(1000), Eps);
  Assert.AreEqual(0.0, FLayout.ClampScrollX(-1), Eps);
  Assert.AreEqual(200.0, FLayout.ClampScrollX(200), Eps);
  // Viewport larger than the document
  FLayout.Zoom := 0.1;
  FLayout.ViewportHeight := 5000;
  Assert.AreEqual(0.0, FLayout.MaxScrollY, Eps);
  Assert.AreEqual(0.0, FLayout.ClampScrollY(100), Eps);
end;

procedure TPdfPageLayoutTests.FitWidthZoom_Letter;
begin
  Assert.AreEqual((800.0 - 16) / 612, FLayout.FitWidthZoom, Eps);
  FLayout.Zoom := FLayout.FitWidthZoom;
  Assert.AreEqual(800.0, FLayout.TotalWidth, 1E-4, 'fit width fills the viewport');
  Assert.AreEqual(8.0, Double(FLayout.PageRect[0].Left), 1E-4);
end;

procedure TPdfPageLayoutTests.FitPageZoom_Letter;
begin
  Assert.AreEqual(Min((800.0 - 16) / 612, (600.0 - 16) / 792), FLayout.FitPageZoom, Eps);
  Assert.AreEqual((600.0 - 16) / 792, FLayout.FitPageZoom(1), Eps);
  FLayout.Zoom := FLayout.FitPageZoom;
  Assert.AreEqual(584.0, Double(FLayout.PageRect[0].Height), 1E-3, 'fit page fills the viewport height');
end;

procedure TPdfPageLayoutTests.FitZoom_MixedPageSizes;
begin
  // Letter portrait + A4 landscape
  FLayout.SetPages([TSizeF.Create(LetterW, LetterH), TSizeF.Create(A4H, A4W)]);
  Assert.AreEqual((800.0 - 16) / A4H, FLayout.FitWidthZoom, 1E-5, 'widest page');
  Assert.AreEqual(Min((800.0 - 16) / A4H, (600.0 - 16) / LetterH), FLayout.FitPageZoom, 1E-5, 'largest page');
  Assert.AreEqual(Min((800.0 - 16) / A4H, (600.0 - 16) / A4W), FLayout.FitPageZoom(1), 1E-5, 'page 1 (landscape)');
  Assert.AreEqual(Min((800.0 - 16) / LetterW, (600.0 - 16) / LetterH), FLayout.FitPageZoom(0), 1E-5, 'page 0 (portrait)');
  // Narrow page is centred in the content width of the wide one
  Assert.AreEqual(Double(FLayout.PageRect[1].Left) + (A4H - LetterW) / 2, Double(FLayout.PageRect[0].Left), 1E-3);
end;

procedure TPdfPageLayoutTests.DocumentToPage_Corners;
var
  R: TRectF;
  PX, PY: Double;
begin
  FLayout.Zoom := 2;
  R := FLayout.PageRect[1];
  Assert.IsTrue(FLayout.DocumentToPage(1, R.Left, R.Bottom, PX, PY));
  Assert.AreEqual(0.0, PX, 1E-4, 'bottom-left x');
  Assert.AreEqual(0.0, PY, 1E-4, 'bottom-left y');
  Assert.IsTrue(FLayout.DocumentToPage(1, R.Right, R.Top, PX, PY));
  Assert.AreEqual(612.0, PX, 1E-4, 'top-right x');
  Assert.AreEqual(792.0, PY, 1E-4, 'top-right y');
  Assert.IsTrue(FLayout.DocumentToPage(1, R.Left + 200, R.Bottom - 100, PX, PY));
  Assert.AreEqual(100.0, PX, 1E-4);
  Assert.AreEqual(50.0, PY, 1E-4);
end;

procedure TPdfPageLayoutTests.DocumentToPage_InvalidIndex;
var
  PX, PY: Double;
begin
  Assert.IsFalse(FLayout.DocumentToPage(2, 100, 100, PX, PY));
  Assert.IsFalse(FLayout.DocumentToPage(-1, 100, 100, PX, PY));
  Assert.AreEqual(0.0, PX, Eps);
  Assert.AreEqual(0.0, PY, Eps);
end;

procedure TPdfPageLayoutTests.Invalidation_GapMarginZoomViewport;
begin
  Assert.AreEqual(1608.0, FLayout.TotalHeight, Eps);
  FLayout.Gap := 20;
  Assert.AreEqual(8.0 + 792 + 20 + 792 + 8, FLayout.TotalHeight, Eps, 'gap');
  Assert.AreEqual(8.0 + 792 + 20, Double(FLayout.PageRect[1].Top), Eps);
  FLayout.Margin := 30;
  Assert.AreEqual(30.0 + 792 + 20 + 792 + 30, FLayout.TotalHeight, Eps, 'margin');
  Assert.AreEqual(30.0, Double(FLayout.PageRect[0].Top), Eps);
  FLayout.Zoom := 0.5;
  Assert.AreEqual(30.0 + 396 + 20 + 396 + 30, FLayout.TotalHeight, Eps, 'zoom');
  FLayout.ViewportWidth := 1000;
  Assert.AreEqual(1000.0, FLayout.TotalWidth, Eps, 'viewport width');
  Assert.AreEqual((1000.0 - 306) / 2, Double(FLayout.PageRect[0].Left), Eps);
  FLayout.ViewportWidth := 100;
  Assert.AreEqual(306.0 + 60, FLayout.TotalWidth, Eps, 'viewport narrower than content');
  FLayout.Gap := -5;
  Assert.AreEqual(0.0, FLayout.Gap, Eps, 'negative gap clamped');
  Assert.AreEqual(30.0 + 396 + 396 + 30, FLayout.TotalHeight, Eps);
  FLayout.SetPages([TSizeF.Create(100, 200)]);
  Assert.AreEqual(30.0 + 100 + 30, FLayout.TotalHeight, Eps, 'SetPages');
end;

procedure TPdfPageLayoutTests.EmptyPages;
begin
  FLayout.SetPages([]);
  Assert.AreEqual(0, FLayout.PageCount);
  Assert.AreEqual(2 * 8.0, FLayout.TotalHeight, Eps);
  Assert.AreEqual(0, Integer(Length(FLayout.VisiblePages(0, 0))));
  Assert.AreEqual(-1, FLayout.PageAt(10, 10));
  Assert.AreEqual(0.0, FLayout.ScrollTopOfPage(0), Eps);
  Assert.AreEqual(0.0, FLayout.MaxScrollY, Eps);
  Assert.AreEqual(1.0, FLayout.FitWidthZoom, Eps, 'fallback without pages');
  Assert.AreEqual(1.0, FLayout.FitPageZoom, Eps);
end;

procedure TPdfPageLayoutTests.PageSizesFromDocument_Rotated;
var
  B: TPdfTestBuilder;
  Doc: TPdfDocument;
  Sizes: TArray<TSizeF>;
  I: Integer;
begin
  B := TPdfTestBuilder.SimpleDocument(2, '', '/MediaBox [0 0 200 100] /Rotate 90');
  Doc := TPdfDocument.Create;
  try
    Doc.LoadFromBytes(B.Build(1));
    SetLength(Sizes, Doc.PageCount);
    for I := 0 to Doc.PageCount - 1 do
      Sizes[I] := TSizeF.Create(Doc.Pages[I].GetDisplayWidth, Doc.Pages[I].GetDisplayHeight);
  finally
    Doc.Free;
    B.Free;
  end;
  FLayout.SetPages(Sizes);
  Assert.AreEqual(2, FLayout.PageCount);
  Assert.AreEqual(100.0, Double(FLayout.PageRect[0].Width), Eps, 'rotated: width is the MediaBox height');
  Assert.AreEqual(200.0, Double(FLayout.PageRect[0].Height), Eps);
  Assert.AreEqual(8.0 + 200 + 8 + 200 + 8, FLayout.TotalHeight, Eps);
end;

procedure TPdfPageLayoutTests.Facing_TwoColumns_Geometry;
var
  R0, R1, R2: TRectF;
begin
  FLayout.SetPages([TSizeF.Create(100, 150), TSizeF.Create(100, 150), TSizeF.Create(100, 150)]);
  FLayout.ViewportWidth := 400;
  FLayout.Columns := 2;
  R0 := FLayout.PageRect[0];
  R1 := FLayout.PageRect[1];
  R2 := FLayout.PageRect[2];
  Assert.AreEqual(2, FLayout.RowCount, 'three pages make two rows');
  Assert.AreEqual(400.0, FLayout.TotalWidth, Eps);
  Assert.AreEqual(200.0 - 4 - 100, Double(R0.Left), Eps, 'left page ends half a gap left of the centre');
  Assert.AreEqual(200.0 + 4, Double(R1.Left), Eps, 'right page starts half a gap right of the centre');
  Assert.AreEqual(Double(R0.Top), Double(R1.Top), Eps, 'pages of a row share the top');
  Assert.AreEqual(8.0 + 150 + 8, Double(R2.Top), Eps, 'second row below the first');
  Assert.AreEqual(Double(R0.Left), Double(R2.Left), Eps, 'odd last page sits in the left column');
  Assert.AreEqual(8.0 + 150 + 8 + 150 + 8, FLayout.TotalHeight, Eps);
  Assert.AreEqual(0, FLayout.RowOfPage(1));
  Assert.AreEqual(1, FLayout.RowOfPage(2));
  Assert.AreEqual(2, Integer(Length(FLayout.RowPages(0))));
  Assert.AreEqual(1, Integer(Length(FLayout.RowPages(1))));
  Assert.AreEqual(2, FLayout.FirstPageOfRow(1));
  Assert.AreEqual(-1, FLayout.FirstPageOfRow(2));
  Assert.AreEqual(0, FLayout.PageAt(100, 50), 'left column hit');
  Assert.AreEqual(1, FLayout.PageAt(250, 50), 'right column hit');
  Assert.AreEqual(-1, FLayout.PageAt(200, 50), 'the gap between the columns');
end;

procedure TPdfPageLayoutTests.Facing_CoverPage_FirstAloneOnTheRight;
begin
  FLayout.SetPages([TSizeF.Create(100, 150), TSizeF.Create(100, 150), TSizeF.Create(100, 150)]);
  FLayout.ViewportWidth := 400;
  FLayout.Columns := 2;
  FLayout.CoverPage := True;
  Assert.AreEqual(2, FLayout.RowCount, 'cover + one pair');
  Assert.AreEqual(204.0, Double(FLayout.PageRect[0].Left), Eps, 'cover page in the right column');
  Assert.AreEqual(96.0, Double(FLayout.PageRect[1].Left), Eps);
  Assert.AreEqual(204.0, Double(FLayout.PageRect[2].Left), Eps);
  Assert.AreEqual(Double(FLayout.PageRect[1].Top), Double(FLayout.PageRect[2].Top), Eps, 'pages 2-3 face each other');
  Assert.AreEqual(1, FLayout.RowOfPage(2));
end;

procedure TPdfPageLayoutTests.Facing_Rows_And_FitZoom;
begin
  FLayout.SetPages([TSizeF.Create(100, 150), TSizeF.Create(100, 150)]);
  FLayout.ViewportWidth := 424; // 2 x 100 points at zoom 2 + gap 8 + margins 16
  FLayout.ViewportHeight := 316; // 150 points + margins 16 at zoom 2
  FLayout.Columns := 2;
  Assert.AreEqual(2.0, FLayout.FitWidthZoom, Eps, 'fit width spans both columns');
  Assert.AreEqual(2.0, FLayout.FitPageZoom(0), Eps, 'fit page fits the row in both directions');
  FLayout.ViewportHeight := 166;
  Assert.AreEqual(1.0, FLayout.FitPageZoom(1), Eps, 'height limits the row');
end;

procedure TPdfPageLayoutTests.NonContinuous_OnlyActiveRowLaidOut;
var
  Visible: TArray<TPdfPageRect>;
begin
  FLayout.SetPages([TSizeF.Create(100, 150), TSizeF.Create(100, 150), TSizeF.Create(100, 150)]);
  FLayout.Continuous := False;
  FLayout.ActivePage := 1;
  Assert.IsFalse(FLayout.IsPageLaidOut(0));
  Assert.IsTrue(FLayout.IsPageLaidOut(1));
  Assert.IsFalse(FLayout.IsPageLaidOut(2));
  Assert.AreEqual(8.0 + 150 + 8, FLayout.TotalHeight, Eps, 'only one page high');
  Assert.AreEqual(8.0, Double(FLayout.PageRect[1].Top), Eps, 'the active page is at the top');
  Visible := FLayout.VisiblePages(0, 0);
  Assert.AreEqual(1, Integer(Length(Visible)));
  Assert.AreEqual(1, Visible[0].Index);
  Assert.AreEqual(0.0, FLayout.ScrollTopOfPage(2), Eps, 'pages outside the active row give 0');
  FLayout.Columns := 2;
  Assert.IsTrue(FLayout.IsPageLaidOut(0), 'page 0 and 1 share the active row now');
  Assert.IsTrue(FLayout.IsPageLaidOut(1));
  Assert.IsFalse(FLayout.IsPageLaidOut(2));
  FLayout.Continuous := True;
  Assert.IsTrue(FLayout.IsPageLaidOut(2), 'continuous again: everything laid out');
end;

procedure TPdfPageLayoutTests.NonContinuous_CurrentPage_And_ScrollTop;
begin
  FLayout.SetPages([TSizeF.Create(100, 150), TSizeF.Create(100, 150), TSizeF.Create(100, 150)]);
  FLayout.Continuous := False;
  FLayout.ActivePage := 2;
  Assert.AreEqual(2, FLayout.CurrentPage(0, 0));
  Assert.AreEqual(2, FLayout.CurrentPage(0, 5000), 'scrolled past the end: still the active row');
  Assert.AreEqual(0.0, FLayout.MaxScrollY, Eps, 'one page fits the 600 px viewport');
  FLayout.ActivePage := 5;
  Assert.AreEqual(2, FLayout.ActivePage, 'clamped to the last page');
end;

procedure TPdfPageLayoutTests.Renderer_PageMatrix_ExtraRotation;
var
  B: TPdfTestBuilder;
  Doc: TPdfDocument;
  W, H: Integer;
  M: TPdfMatrix;
  X, Y: Double;
begin
  B := TPdfTestBuilder.SimpleDocument(1, '', '/MediaBox [0 0 200 100] /Rotate 90');
  Doc := TPdfDocument.Create;
  try
    Doc.LoadFromBytes(B.Build(1));
    Assert.AreEqual(90, TPdfPageRenderer.TotalRotation(Doc.Pages[0], 0));
    Assert.AreEqual(180, TPdfPageRenderer.TotalRotation(Doc.Pages[0], 90));
    Assert.AreEqual(0, TPdfPageRenderer.TotalRotation(Doc.Pages[0], 270));
    Assert.AreEqual(0, TPdfPageRenderer.TotalRotation(Doc.Pages[0], -90));
    TPdfPageRenderer.PageSizePixels(Doc.Pages[0], 1, W, H);
    Assert.AreEqual(100, W, '/Rotate 90 alone: portrait');
    Assert.AreEqual(200, H);
    TPdfPageRenderer.PageSizePixels(Doc.Pages[0], 1, W, H, 90);
    Assert.AreEqual(200, W, 'plus 90: landscape again');
    Assert.AreEqual(100, H);
    // With a total rotation of 180 the user-space origin lands bottom-right
    M := TPdfPageRenderer.PageMatrix(Doc.Pages[0], 1, 90);
    X := 0;
    Y := 0;
    M.Apply(X, Y);
    Assert.AreEqual(200.0, X, Eps);
    Assert.AreEqual(0.0, Y, Eps);
  finally
    Doc.Free;
    B.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TPdfImageCacheTests                                                          }
{ ---------------------------------------------------------------------------- }

procedure TPdfImageCacheTests.PutGet_ExactMatch;
var
  C: TPdfImageCache;
  Img, Got: ISkImage;
begin
  C := TPdfImageCache.Create;
  try
    Img := MakeImage(30, 20);
    C.Put(3, 1.5, Img);
    Assert.IsTrue(C.Get(3, 1.5, Got));
    Assert.IsTrue(Got = Img, 'same image instance');
    Assert.AreEqual(30, Got.Width);
    Assert.AreEqual(20, Got.Height);
    Assert.IsFalse(C.Get(2, 1.5, Got), 'other page');
    Assert.IsTrue(Got = nil, 'Image is nil on a miss');
    C.Put(4, 1.0, nil);
    Assert.IsFalse(C.Contains(4, 1.0), 'nil image is not stored');
  finally
    C.Free;
  end;
end;

procedure TPdfImageCacheTests.Get_DifferentScale_Misses;
var
  C: TPdfImageCache;
  Got: ISkImage;
begin
  C := TPdfImageCache.Create;
  try
    C.Put(0, 1.0, MakeImage(10, 10));
    Assert.IsFalse(C.Get(0, 2.0, Got));
    Assert.IsFalse(C.Get(0, 1.01, Got));
    Assert.IsTrue(C.Get(0, 1.0, Got));
  finally
    C.Free;
  end;
end;

procedure TPdfImageCacheTests.HitsAndMisses_Counters;
var
  C: TPdfImageCache;
  Got: ISkImage;
begin
  C := TPdfImageCache.Create;
  try
    Assert.AreEqual(Int64(0), C.Hits);
    Assert.AreEqual(Int64(0), C.Misses);
    C.Put(0, 1.0, MakeImage(10, 10));
    C.Get(0, 1.0, Got);
    C.Get(0, 1.0, Got);
    C.Get(1, 1.0, Got);
    C.Contains(0, 1.0); // not counted
    Assert.AreEqual(Int64(2), C.Hits);
    Assert.AreEqual(Int64(1), C.Misses);
  finally
    C.Free;
  end;
end;

procedure TPdfImageCacheTests.Contains_Count_Bytes;
var
  C: TPdfImageCache;
begin
  C := TPdfImageCache.Create;
  try
    Assert.AreEqual(0, C.Count);
    Assert.AreEqual(Int64(0), C.Bytes);
    C.Put(0, 1.0, MakeImage(100, 50));
    C.Put(0, 2.0, MakeImage(200, 100));
    C.Put(1, 1.0, MakeImage(10, 10));
    Assert.AreEqual(3, C.Count);
    Assert.AreEqual(Int64(100 * 50 * 4 + 200 * 100 * 4 + 10 * 10 * 4), C.Bytes);
    Assert.IsTrue(C.Contains(0, 1.0));
    Assert.IsTrue(C.Contains(0, 2.0));
    Assert.IsTrue(C.Contains(1, 1.0));
    Assert.IsFalse(C.Contains(1, 2.0));
    Assert.IsFalse(C.Contains(2, 1.0));
  finally
    C.Free;
  end;
end;

procedure TPdfImageCacheTests.PdfImageBytes_Values;
begin
  Assert.AreEqual(Int64(0), PdfImageBytes(nil));
  Assert.AreEqual(Int64(123 * 45 * 4), PdfImageBytes(MakeImage(123, 45)));
end;

procedure TPdfImageCacheTests.Put_SameKey_Replaces;
var
  C: TPdfImageCache;
  Img2, Got: ISkImage;
begin
  C := TPdfImageCache.Create;
  try
    C.Put(0, 1.0, MakeImage(100, 100));
    Img2 := MakeImage(50, 50);
    C.Put(0, 1.0, Img2);
    Assert.AreEqual(1, C.Count);
    Assert.AreEqual(Int64(50 * 50 * 4), C.Bytes);
    Assert.IsTrue(C.Get(0, 1.0, Got));
    Assert.IsTrue(Got = Img2);
  finally
    C.Free;
  end;
end;

procedure TPdfImageCacheTests.LRU_EvictsOldest;
var
  C: TPdfImageCache;
  I: Integer;
begin
  C := TPdfImageCache.Create(3 * 100 * 100 * 4);
  try
    for I := 0 to 3 do
      C.Put(I, 1.0, MakeImage(100, 100));
    Assert.AreEqual(3, C.Count);
    Assert.IsFalse(C.Contains(0, 1.0), 'first one evicted');
    Assert.IsTrue(C.Contains(1, 1.0));
    Assert.IsTrue(C.Contains(2, 1.0));
    Assert.IsTrue(C.Contains(3, 1.0));
    Assert.AreEqual(Int64(3 * 100 * 100 * 4), C.Bytes);
    Assert.IsTrue(C.Bytes <= C.MaxBytes);
  finally
    C.Free;
  end;
end;

procedure TPdfImageCacheTests.LRU_GetMarksRecentlyUsed;
var
  C: TPdfImageCache;
  Got: ISkImage;
begin
  C := TPdfImageCache.Create(3 * 100 * 100 * 4);
  try
    C.Put(0, 1.0, MakeImage(100, 100));
    C.Put(1, 1.0, MakeImage(100, 100));
    C.Put(2, 1.0, MakeImage(100, 100));
    Assert.IsTrue(C.Get(0, 1.0, Got));
    C.Put(3, 1.0, MakeImage(100, 100));
    Assert.IsTrue(C.Contains(0, 1.0), 'touched entry survives');
    Assert.IsFalse(C.Contains(1, 1.0), 'second one evicted instead');
    Assert.IsTrue(C.Contains(2, 1.0));
    Assert.IsTrue(C.Contains(3, 1.0));
  finally
    C.Free;
  end;
end;

procedure TPdfImageCacheTests.Put_LargerThanBudget_NotStored;
var
  C: TPdfImageCache;
begin
  C := TPdfImageCache.Create(100 * 100 * 4);
  try
    C.Put(0, 1.0, MakeImage(100, 100));
    C.Put(1, 1.0, MakeImage(101, 100));
    Assert.IsFalse(C.Contains(1, 1.0), 'too large');
    Assert.IsTrue(C.Contains(0, 1.0), 'existing entries are kept');
    Assert.AreEqual(Int64(100 * 100 * 4), C.Bytes);
    // Replacing an entry by a too large image removes the old one
    C.Put(0, 1.0, MakeImage(200, 200));
    Assert.IsFalse(C.Contains(0, 1.0));
    Assert.AreEqual(Int64(0), C.Bytes);
  finally
    C.Free;
  end;
end;

procedure TPdfImageCacheTests.MaxBytes_Lowered_EvictsToFit;
var
  C: TPdfImageCache;
begin
  C := TPdfImageCache.Create;
  try
    C.Put(0, 1.0, MakeImage(100, 100));
    C.Put(1, 1.0, MakeImage(100, 100));
    C.Put(2, 1.0, MakeImage(100, 100));
    C.MaxBytes := 2 * 100 * 100 * 4;
    Assert.AreEqual(Int64(2 * 100 * 100 * 4), C.MaxBytes);
    Assert.AreEqual(2, C.Count);
    Assert.IsFalse(C.Contains(0, 1.0));
    Assert.IsTrue(C.Contains(2, 1.0));
    Assert.IsTrue(C.Bytes <= C.MaxBytes);
    C.MaxBytes := 0;
    Assert.AreEqual(0, C.Count);
    Assert.AreEqual(Int64(0), C.Bytes);
    C.MaxBytes := -10;
    Assert.AreEqual(Int64(0), C.MaxBytes, 'negative budget clamped');
  finally
    C.Free;
  end;
end;

procedure TPdfImageCacheTests.GetNearest_ClosestLogRatio;
var
  C: TPdfImageCache;
  Img05, Img1, Img4, Got: ISkImage;
  S: Double;
begin
  C := TPdfImageCache.Create;
  try
    Img05 := MakeImage(5, 5);
    Img1 := MakeImage(10, 10);
    Img4 := MakeImage(40, 40);
    C.Put(0, 0.5, Img05);
    C.Put(0, 1.0, Img1);
    C.Put(0, 4.0, Img4);
    C.Put(1, 2.2, MakeImage(22, 22)); // other page, exact match must not be picked
    // 2.2: ln(2.2/1) = 0.79, ln(4/2.2) = 0.60 -> 4 (a linear distance would pick 1)
    Assert.IsTrue(C.GetNearest(0, 2.2, Got, S));
    Assert.IsTrue(Got = Img4, 'log ratio picks 4.0 for 2.2');
    Assert.AreEqual(4.0, S, Eps);
    // 1.9: ln 1.9 = 0.64, ln(4/1.9) = 0.74 -> 1
    Assert.IsTrue(C.GetNearest(0, 1.9, Got, S));
    Assert.IsTrue(Got = Img1, '1.0 for 1.9');
    Assert.AreEqual(1.0, S, Eps);
    // 0.6: ln(0.6/0.5) = 0.18, ln(1/0.6) = 0.51 -> 0.5
    Assert.IsTrue(C.GetNearest(0, 0.6, Got, S));
    Assert.IsTrue(Got = Img05);
    Assert.AreEqual(0.5, S, Eps);
    // Exact match
    Assert.IsTrue(C.GetNearest(0, 4.0, Got, S));
    Assert.IsTrue(Got = Img4);
    Assert.AreEqual(4.0, S, Eps);
    Assert.IsTrue(C.GetNearest(0, 100, Got, S));
    Assert.AreEqual(4.0, S, Eps, 'far above: largest');
  finally
    C.Free;
  end;
end;

procedure TPdfImageCacheTests.GetNearest_UnknownPage;
var
  C: TPdfImageCache;
  Got: ISkImage;
  S: Double;
begin
  C := TPdfImageCache.Create;
  try
    Assert.IsFalse(C.GetNearest(0, 1.0, Got, S), 'empty cache');
    C.Put(1, 1.0, MakeImage(10, 10));
    Assert.IsFalse(C.GetNearest(0, 1.0, Got, S));
    Assert.IsTrue(Got = nil);
    Assert.AreEqual(0.0, S, Eps);
  finally
    C.Free;
  end;
end;

procedure TPdfImageCacheTests.RemovePage_AllScales;
var
  C: TPdfImageCache;
begin
  C := TPdfImageCache.Create;
  try
    C.Put(0, 1.0, MakeImage(10, 10));
    C.Put(0, 2.0, MakeImage(20, 20));
    C.Put(0, 3.0, MakeImage(30, 30));
    C.Put(1, 1.0, MakeImage(10, 10));
    C.RemovePage(0);
    Assert.AreEqual(1, C.Count);
    Assert.IsFalse(C.Contains(0, 1.0));
    Assert.IsFalse(C.Contains(0, 2.0));
    Assert.IsFalse(C.Contains(0, 3.0));
    Assert.IsTrue(C.Contains(1, 1.0));
    Assert.AreEqual(Int64(10 * 10 * 4), C.Bytes);
    C.RemovePage(7); // no-op
    Assert.AreEqual(1, C.Count);
  finally
    C.Free;
  end;
end;

procedure TPdfImageCacheTests.Clear_EmptiesAndResetsBytes;
var
  C: TPdfImageCache;
  Got: ISkImage;
begin
  C := TPdfImageCache.Create;
  try
    C.Put(0, 1.0, MakeImage(10, 10));
    C.Put(1, 1.0, MakeImage(10, 10));
    C.Clear;
    Assert.AreEqual(0, C.Count);
    Assert.AreEqual(Int64(0), C.Bytes);
    Assert.IsFalse(C.Get(0, 1.0, Got));
    C.Put(2, 1.0, MakeImage(10, 10));
    Assert.AreEqual(1, C.Count, 'usable after Clear');
  finally
    C.Free;
  end;
end;

procedure TPdfImageCacheTests.ScaleKey_Quantisation;
var
  C: TPdfImageCache;
begin
  Assert.AreEqual(TPdfCacheKey.ScaleToKey(1.0), TPdfCacheKey.ScaleToKey(1.0004));
  Assert.AreNotEqual(TPdfCacheKey.ScaleToKey(1.0), TPdfCacheKey.ScaleToKey(1.001));
  Assert.AreEqual(1000, TPdfCacheKey.ScaleToKey(1.0));
  Assert.AreEqual(1500, TPdfCacheKey.Create(5, 1.5).ScaleKey);
  Assert.AreEqual(5, TPdfCacheKey.Create(5, 1.5).Page);
  C := TPdfImageCache.Create;
  try
    C.Put(0, 1.0, MakeImage(10, 10));
    Assert.IsTrue(C.Contains(0, 1.0004), '1.0004 shares the key of 1.0');
    Assert.IsFalse(C.Contains(0, 1.001), '1.001 does not');
    C.Put(0, 1.0004, MakeImage(20, 20));
    Assert.AreEqual(1, C.Count, 'replaced, not added');
  finally
    C.Free;
  end;
end;

type
  /// Hammers a shared cache with Put/Get/GetNearest/RemovePage/Contains.
  TCacheStressThread = class(TThread)
  private
    FCache: TPdfImageCache;
    FIndex, FIterations: Integer;
    FImages: TArray<ISkImage>;
  protected
    procedure Execute; override;
  public
    OverBudget: Integer;
    Error: string;
    constructor Create(ACache: TPdfImageCache; AIndex, AIterations: Integer; const AImages: TArray<ISkImage>);
  end;

constructor TCacheStressThread.Create(ACache: TPdfImageCache; AIndex, AIterations: Integer; const AImages: TArray<ISkImage>);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCache := ACache;
  FIndex := AIndex;
  FIterations := AIterations;
  FImages := AImages;
end;

procedure TCacheStressThread.Execute;
var
  N, Page: Integer;
  Scale, NearScale: Double;
  Got: ISkImage;
begin
  try
    for N := 1 to FIterations do
    begin
      Page := (N * 7 + FIndex * 13) mod 25;
      Scale := 0.5 + (N mod 4) * 0.5;
      FCache.Put(Page, Scale, FImages[(N + FIndex) mod Length(FImages)]);
      FCache.Get((Page + 3) mod 25, Scale, Got);
      if N mod 10 = 0 then
        FCache.GetNearest(Page, 1.25, Got, NearScale);
      if N mod 50 = 0 then
        FCache.RemovePage((Page + 1) mod 25);
      if N mod 97 = 0 then
        FCache.Contains(Page, Scale);
      if FCache.Bytes > FCache.MaxBytes then
        Inc(OverBudget);
    end;
  except
    on E: Exception do
      Error := E.ClassName + ': ' + E.Message;
  end;
end;

procedure TPdfImageCacheTests.ThreadSafety_Smoke;
const
  ThreadCount = 4;
  Iterations = 2000;
var
  C: TPdfImageCache;
  Images: TArray<ISkImage>;
  Threads: array[0..ThreadCount - 1] of TCacheStressThread;
  I: Integer;
begin
  Images := [MakeImage(32, 32), MakeImage(48, 32), MakeImage(16, 64), MakeImage(64, 64)];
  C := TPdfImageCache.Create(10 * 32 * 32 * 4);
  try
    for I := 0 to ThreadCount - 1 do
      Threads[I] := TCacheStressThread.Create(C, I, Iterations, Images);
    for I := 0 to ThreadCount - 1 do
      Threads[I].Start;
    try
      for I := 0 to ThreadCount - 1 do
        Threads[I].WaitFor;
      for I := 0 to ThreadCount - 1 do
      begin
        Assert.AreEqual('', Threads[I].Error, Format('thread %d raised', [I]));
        Assert.AreEqual(0, Threads[I].OverBudget, Format('thread %d saw Bytes > MaxBytes', [I]));
      end;
    finally
      for I := 0 to ThreadCount - 1 do
        Threads[I].Free;
    end;
    Assert.IsTrue(C.Bytes <= C.MaxBytes);
    Assert.IsTrue(C.Count > 0);
    Assert.AreEqual(Int64(ThreadCount * Iterations), C.Hits + C.Misses, 'every Get counted once');
  finally
    C.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TPdfRenderQueueTests                                                         }
{ ---------------------------------------------------------------------------- }

procedure TPdfRenderQueueTests.Setup;
var
  B: TPdfTestBuilder;
  I: Integer;
begin
  FReadyCount := 0;
  FErrorCount := 0;
  FLastError := '';
  FOrderLock := TObject.Create;
  FOrder := TList<Integer>.Create;
  FReadyScales := TList<Double>.Create;
  B := TPdfTestBuilder.SimpleDocument(3, '', '/MediaBox [0 0 200 100]');
  try
    // Content objects are 4, 6 and 8: a blue rectangle so that the image is not blank
    for I := 0 to 2 do
      B.Replace(4 + 2 * I, StreamObj('0 0 1 rg 20 20 160 60 re f'));
    FDoc := TPdfDocument.Create;
    FDoc.LoadFromBytes(B.Build(1));
  finally
    B.Free;
  end;
  FCache := TPdfImageCache.Create;
  FQueue := TPdfRenderQueue.Create(FDoc, FCache);
  FQueue.OnPageReady := PageReady;
  FQueue.OnError := RenderError;
end;

procedure TPdfRenderQueueTests.TearDown;
begin
  FQueue.Free;
  FCache.Free;
  FDoc.Free;
  FReadyScales.Free;
  FOrder.Free;
  FOrderLock.Free;
end;

procedure TPdfRenderQueueTests.PageReady(Sender: TObject; Page: Integer; Scale: Double; const Image: ISkImage);
begin
  TMonitor.Enter(FOrderLock);
  try
    FOrder.Add(Page);
    FReadyScales.Add(Scale);
  finally
    TMonitor.Exit(FOrderLock);
  end;
  TInterlocked.Increment(FReadyCount);
end;

procedure TPdfRenderQueueTests.RenderError(Sender: TObject; Page: Integer; const Message: string);
begin
  TMonitor.Enter(FOrderLock);
  try
    FLastError := Message;
  finally
    TMonitor.Exit(FOrderLock);
  end;
  TInterlocked.Increment(FErrorCount);
end;

function TPdfRenderQueueTests.Order: TArray<Integer>;
begin
  TMonitor.Enter(FOrderLock);
  try
    Result := FOrder.ToArray;
  finally
    TMonitor.Exit(FOrderLock);
  end;
end;

function TPdfRenderQueueTests.WaitFor(const Condition: TFunc<Boolean>; TimeoutMs: Integer): Boolean;
var
  SW: TStopwatch;
begin
  SW := TStopwatch.StartNew;
  repeat
    if Condition() then
      Exit(True);
    TThread.Yield;
  until SW.ElapsedMilliseconds > TimeoutMs;
  Result := Condition();
end;

procedure TPdfRenderQueueTests.RenderOnePage;
var
  Img: ISkImage;
  C: TAlphaColor;
begin
  FQueue.Start;
  FQueue.Start; // idempotent
  FQueue.Request(0, 1.0, 0);
  Assert.IsTrue(FQueue.WaitIdle(5000), 'WaitIdle');
  Assert.IsTrue(FCache.Contains(0, 1.0), 'cached');
  Assert.IsTrue(FCache.Get(0, 1.0, Img));
  Assert.AreEqual(200, Img.Width);
  Assert.AreEqual(100, Img.Height);
  Assert.AreEqual(Int64(1), FQueue.RenderedCount);
  Assert.AreEqual(1, TInterlocked.CompareExchange(FReadyCount, 0, 0), 'one OnPageReady');
  Assert.AreEqual(0, FErrorCount);
  Assert.AreEqual(0, FQueue.PendingCount);
  Assert.AreEqual(-1, FQueue.BusyPage, 'idle');
  // (100, 50) is inside the rectangle, (5, 5) outside
  C := Img.PeekPixels.Colors[100, 50];
  Assert.IsTrue((C and $FFFFFF) = $0000FF, Format('filled pixel %.8x', [C]));
  C := Img.PeekPixels.Colors[5, 5];
  Assert.IsTrue((C and $FFFFFF) = $FFFFFF, Format('background pixel %.8x', [C]));
end;

procedure TPdfRenderQueueTests.WaitIdle_NotStarted;
begin
  Assert.IsTrue(FQueue.WaitIdle(0), 'no worker');
  FQueue.Start;
  Assert.IsTrue(FQueue.WaitIdle(1000), 'started, nothing queued');
end;

procedure TPdfRenderQueueTests.Priority_LowerRunsFirst_WorkerBusy;
var
  O: TArray<Integer>;
begin
  FQueue.Start;
  FQueue.Request(0, 8.0, 0);   // keeps the worker busy (1600 x 800)
  FQueue.Request(1, 1.0, 5);
  FQueue.Request(2, 1.0, 1);
  Assert.IsTrue(FQueue.WaitIdle(10000), 'WaitIdle');
  O := Order;
  Assert.AreEqual(3, Integer(Length(O)));
  Assert.AreEqual(0, O[0]);
  Assert.AreEqual(2, O[1], 'priority 1 before priority 5');
  Assert.AreEqual(1, O[2]);
end;

procedure TPdfRenderQueueTests.Priority_QueuedBeforeStart;
var
  O: TArray<Integer>;
begin
  FQueue.Request(0, 1.0, 9);
  FQueue.Request(1, 1.0, 5);
  FQueue.Request(2, 1.0, -3);
  Assert.AreEqual(3, FQueue.PendingCount);
  FQueue.Start;
  Assert.IsTrue(FQueue.WaitIdle(5000));
  O := Order;
  Assert.AreEqual(3, Integer(Length(O)));
  Assert.AreEqual(2, O[0]);
  Assert.AreEqual(1, O[1]);
  Assert.AreEqual(0, O[2]);
end;

procedure TPdfRenderQueueTests.Request_AlreadyCached_NotQueued;
begin
  FQueue.Start;
  FQueue.Request(0, 1.0, 0);
  Assert.IsTrue(FQueue.WaitIdle(5000));
  FQueue.Request(0, 1.0, 0);
  Assert.AreEqual(0, FQueue.PendingCount, 'cached: not queued');
  FQueue.Request(0, 1.0004, 0); // same quantised key
  Assert.AreEqual(0, FQueue.PendingCount);
  Assert.IsTrue(FQueue.WaitIdle(5000));
  Assert.AreEqual(Int64(1), FQueue.RenderedCount);
  Assert.AreEqual(1, FReadyCount);
end;

procedure TPdfRenderQueueTests.Request_Duplicates_Merged;
begin
  FQueue.Request(1, 2.0, 3);
  FQueue.Request(1, 2.0, 3);
  FQueue.Request(1, 2.0004, 7);
  Assert.AreEqual(1, FQueue.PendingCount, 'merged');
  FQueue.Request(1, 3.0, 3);
  Assert.AreEqual(2, FQueue.PendingCount, 'other scale is another request');
  FQueue.Start;
  Assert.IsTrue(FQueue.WaitIdle(5000));
  Assert.AreEqual(Int64(2), FQueue.RenderedCount);
  Assert.AreEqual(2, FReadyCount);
  Assert.IsTrue(FCache.Contains(1, 2.0));
  Assert.IsTrue(FCache.Contains(1, 3.0));
end;

procedure TPdfRenderQueueTests.Request_Duplicate_KeepsLowerPriority;
var
  O: TArray<Integer>;
begin
  FQueue.Request(1, 1.0, 5);
  FQueue.Request(2, 1.0, 3);
  FQueue.Request(1, 1.0, 1);   // raises the priority of the queued request
  FQueue.Request(2, 1.0, 10);  // a higher number does not lower it
  Assert.AreEqual(2, FQueue.PendingCount);
  FQueue.Start;
  Assert.IsTrue(FQueue.WaitIdle(5000));
  O := Order;
  Assert.AreEqual(2, Integer(Length(O)));
  Assert.AreEqual(1, O[0]);
  Assert.AreEqual(2, O[1]);
end;

procedure TPdfRenderQueueTests.Request_WhileRendering_NotDuplicated;
var
  Queue: TPdfRenderQueue;
begin
  // A viewer requests the visible pages on every paint. A request for the
  // page/scale that is being rendered right now is a duplicate as well.
  Queue := FQueue;
  Queue.Start;
  Queue.Request(0, 12.0, 0);   // 2400 x 1200
  Assert.IsTrue(WaitFor(
    function: Boolean
    begin
      Result := (Queue.BusyPage = 0) or (Queue.RenderedCount > 0);
    end, 5000), 'worker picked up the request');
  if FCache.Contains(0, 12.0) then
  begin
    Assert.Pass('render finished before the second request; nothing to check');
    Exit;
  end;
  Queue.Request(0, 12.0, 0);
  Assert.AreEqual(0, Queue.PendingCount, 'in-flight page/scale must not be queued again');
  Assert.IsTrue(Queue.WaitIdle(10000));
  Assert.AreEqual(Int64(1), Queue.RenderedCount, 'rendered once');
end;

procedure TPdfRenderQueueTests.CancelPending_DropsQueued;
begin
  FQueue.Request(0, 1.0, 0);
  FQueue.Request(1, 1.0, 1);
  FQueue.Request(2, 1.0, 2);
  FQueue.CancelPending;
  Assert.AreEqual(0, FQueue.PendingCount);
  FQueue.Start;
  Assert.IsTrue(FQueue.WaitIdle(5000));
  Assert.AreEqual(0, FReadyCount, 'no OnPageReady for dropped pages');
  Assert.AreEqual(Int64(0), FQueue.RenderedCount);
  Assert.AreEqual(0, FCache.Count);
  // New requests after a cancel are rendered (new generation)
  FQueue.Request(1, 1.0, 0);
  Assert.IsTrue(FQueue.WaitIdle(5000));
  Assert.AreEqual(1, FReadyCount);
  Assert.IsTrue(FCache.Contains(1, 1.0));
end;

procedure TPdfRenderQueueTests.CancelPending_InFlightResultDiscarded;
var
  O: TArray<Integer>;
  I: Integer;
begin
  FQueue.Start;
  FQueue.Request(0, 10.0, 0);  // 2000 x 1000, probably in progress when cancelled
  FQueue.Request(1, 1.0, 1);
  FQueue.Request(2, 1.0, 2);
  FQueue.CancelPending;
  Assert.AreEqual(0, FQueue.PendingCount);
  Assert.IsTrue(FQueue.WaitIdle(10000), 'WaitIdle after CancelPending');
  O := Order;
  for I := 0 to High(O) do
    Assert.AreEqual(0, O[I], 'dropped pages 1 and 2 must not be reported');
  Assert.IsFalse(FCache.Contains(1, 1.0));
  Assert.IsFalse(FCache.Contains(2, 1.0));
  // The in-flight result is discarded; if the worker had already finished it
  // before the cancel, it is consistently cached, counted and reported.
  if FCache.Contains(0, 10.0) then
  begin
    Assert.AreEqual(Int64(1), FQueue.RenderedCount);
    Assert.AreEqual(1, FReadyCount);
  end
  else
  begin
    Assert.AreEqual(Int64(0), FQueue.RenderedCount);
    Assert.AreEqual(0, FReadyCount);
  end;
  Assert.AreEqual(0, FErrorCount);
end;

procedure TPdfRenderQueueTests.Stop_Prompt_ThenStartAgain;
var
  SW: TStopwatch;
begin
  FQueue.Start;
  FQueue.Request(0, 6.0, 0);
  FQueue.Request(1, 6.0, 1);
  FQueue.Request(2, 6.0, 2);
  FQueue.Request(0, 7.0, 3);
  FQueue.Request(1, 7.0, 4);
  SW := TStopwatch.StartNew;
  FQueue.Stop;
  Assert.IsTrue(SW.ElapsedMilliseconds < 3000, Format('Stop took %d ms', [SW.ElapsedMilliseconds]));
  Assert.AreEqual(0, FQueue.PendingCount, 'pending requests dropped');
  Assert.IsTrue(FReadyCount <= 1, 'at most the request in progress completed');
  FQueue.Stop; // safe twice
  Assert.IsTrue(FQueue.WaitIdle(0), 'stopped queue is idle');
  FQueue.Start;
  FQueue.Request(1, 1.0, 0);
  Assert.IsTrue(FQueue.WaitIdle(5000));
  Assert.IsTrue(FCache.Contains(1, 1.0), 'restarted worker renders');
end;

procedure TPdfRenderQueueTests.Request_InvalidArguments_Ignored;
begin
  FQueue.Request(0, 0, 0);
  FQueue.Request(0, -1, 0);
  FQueue.Request(-1, 1.0, 0);
  Assert.AreEqual(0, FQueue.PendingCount);
  FQueue.Start;
  Assert.IsTrue(FQueue.WaitIdle(1000));
  Assert.AreEqual(0, FReadyCount);
  Assert.AreEqual(0, FErrorCount);
end;

procedure TPdfRenderQueueTests.Request_PageOutOfRange_NoImage;
begin
  FQueue.Start;
  FQueue.Request(99, 1.0, 0);
  Assert.IsTrue(FQueue.WaitIdle(5000));
  Assert.AreEqual(0, FReadyCount, 'no OnPageReady');
  Assert.AreEqual(0, FErrorCount, 'no OnError');
  Assert.AreEqual(Int64(0), FQueue.RenderedCount);
  Assert.IsFalse(FCache.Contains(99, 1.0));
  // The worker is still alive
  FQueue.Request(0, 1.0, 0);
  Assert.IsTrue(FQueue.WaitIdle(5000));
  Assert.AreEqual(1, FReadyCount);
end;

procedure TPdfRenderQueueTests.OnError_SurfaceTooLarge;
begin
  // 200000 x 100000 pixels exceeds Skia's raster limit: MakeRaster returns nil
  // and RenderToImage raises, which the worker reports through OnError.
  FQueue.Start;
  FQueue.Request(0, 1000.0, 0);
  Assert.IsTrue(FQueue.WaitIdle(10000));
  Assert.AreEqual(1, FErrorCount, 'OnError called once');
  Assert.IsTrue(FLastError <> '', 'error message');
  Assert.AreEqual(0, FReadyCount);
  Assert.IsFalse(FCache.Contains(0, 1000.0));
  FQueue.Request(1, 1.0, 0);
  Assert.IsTrue(FQueue.WaitIdle(5000));
  Assert.AreEqual(1, FReadyCount, 'worker survives the error');
end;

procedure TPdfRenderQueueTests.Free_WhileRendering;
var
  SW: TStopwatch;
begin
  FQueue.Start;
  FQueue.Request(0, 12.0, 0);
  FQueue.Request(1, 12.0, 1);
  WaitFor(
    function: Boolean
    begin
      Result := FQueue.BusyPage >= 0;
    end, 2000);
  SW := TStopwatch.StartNew;
  FQueue.Free;
  FQueue := nil;
  Assert.IsTrue(SW.ElapsedMilliseconds < 5000, Format('Free took %d ms', [SW.ElapsedMilliseconds]));
  Assert.IsTrue(FReadyCount <= 1);
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfPageLayoutTests);
  TDUnitX.RegisterTestFixture(TPdfImageCacheTests);
  TDUnitX.RegisterTestFixture(TPdfRenderQueueTests);

end.
