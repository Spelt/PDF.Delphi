unit Pdf.Tests.Phase5;

{ Fase 5: navigation (destinations, outline, annotations), annotation
  appearance rendering, soft masks and text extraction/search. }

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math, System.Skia,
  DUnitX.TestFramework,
  Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Document, Pdf.Core.Navigation,
  Pdf.Core.Parser, System.Generics.Collections, Pdf.Render.Skia, Pdf.Render.Text, Pdf.Tests.Builder;

type
  [TestFixture]
  TPdfNavigationTests = class
  private
    FDoc: TPdfDocument;
    FNav: TPdfNavigation;
    procedure Load(B: TPdfTestBuilder; const ExtraTrailer: string = '');
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure ExplicitDestinations;
    [Test] procedure NamedDestinationsFromDestsAndNameTree;
    [Test] procedure Actions;
    [Test] procedure OutlineTree;
    [Test] procedure OutlineLoopTerminates;
    [Test] procedure AnnotationsWithAppearanceStates;
  end;

  [TestFixture]
  TPdfPhase5RenderTests = class
  private
    FDoc: TPdfDocument;
    FRenderer: TPdfPageRenderer;
    function Render(const Content, Resources, PageExtra: string; const ExtraObjects: array of string): ISkImage;
    function Px(const Img: ISkImage; X, Y: Integer): TAlphaColor;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure AnnotationAppearanceIsDrawnIntoRect;
    [Test] procedure HiddenAnnotationIsSkipped;
    [Test] procedure LuminositySoftMask;
    [Test] procedure AlphaSoftMaskAndNoneResets;
    [Test] procedure TextExtractionAndSearch;
    [Test] procedure TextSelectionByPosition;
    [Test] procedure TextOnlyModeDrawsNothing;
  end;

implementation

function StreamObj(const Dict, Data: string): string;
var
  D: string;
begin
  D := Trim(Dict);
  Delete(D, Length(D) - 1, 2);
  Result := D + ' /Length ' + IntToStr(Length(Data)) + ' >>'#10'stream'#10 + Data + #10'endstream';
end;

{ TPdfNavigationTests }

procedure TPdfNavigationTests.Setup;
begin
  FDoc := TPdfDocument.Create;
end;

procedure TPdfNavigationTests.TearDown;
begin
  FreeAndNil(FNav);
  FreeAndNil(FDoc);
end;

procedure TPdfNavigationTests.Load(B: TPdfTestBuilder; const ExtraTrailer: string);
begin
  FDoc.LoadFromBytes(B.Build(1, ExtraTrailer));
  FreeAndNil(FNav);
  FNav := TPdfNavigation.Create(FDoc);
end;

procedure TPdfNavigationTests.ExplicitDestinations;
var
  B: TPdfTestBuilder;
  D: TPdfDestination;
begin
  B := TPdfTestBuilder.SimpleDocument(3);
  try
    Load(B);
    // SimpleDocument: pages are objects 3, 5, 7
    D := FNav.ResolveDestination(PdfParseObject('[5 0 R /XYZ 10 700 2]', FDoc.Resolver));
    Assert.AreEqual(dkXYZ, D.Kind);
    Assert.AreEqual(1, D.PageIndex);
    Assert.IsTrue(D.HasLeft and D.HasTop and D.HasZoom);
    Assert.AreEqual(700.0, D.Top, 1E-9);
    Assert.AreEqual(2.0, D.Zoom, 1E-9);
    D := FNav.ResolveDestination(PdfParseObject('[7 0 R /XYZ null null null]', FDoc.Resolver));
    Assert.AreEqual(2, D.PageIndex);
    Assert.IsFalse(D.HasTop);
    Assert.IsFalse(D.HasZoom);
    D := FNav.ResolveDestination(PdfParseObject('[3 0 R /FitH 500]', FDoc.Resolver));
    Assert.AreEqual(dkFitH, D.Kind);
    Assert.AreEqual(500.0, D.Top, 1E-9);
    D := FNav.ResolveDestination(PdfParseObject('[3 0 R /FitR 1 2 3 4]', FDoc.Resolver));
    Assert.AreEqual(dkFitR, D.Kind);
    Assert.AreEqual(4.0, D.Top, 1E-9);
    D := FNav.ResolveDestination(PdfParseObject('[1 /Fit]', FDoc.Resolver));
    Assert.AreEqual(1, D.PageIndex, 'page number form');
    D := FNav.ResolveDestination(PdfParseObject('[99 0 R /Fit]', FDoc.Resolver));
    Assert.AreEqual(-1, D.PageIndex);
    Assert.IsFalse(D.IsValid);
    D := FNav.ResolveDestination(PdfParseObject('<< /D [5 0 R /Fit] >>', FDoc.Resolver));
    Assert.AreEqual(1, D.PageIndex, 'dictionary with /D');
    D := FNav.ResolveDestination(nil);
    Assert.IsFalse(D.IsValid);
  finally
    B.Free;
  end;
end;

procedure TPdfNavigationTests.NamedDestinationsFromDestsAndNameTree;
var
  B: TPdfTestBuilder;
  D: TPdfDestination;
begin
  B := TPdfTestBuilder.SimpleDocument(2);
  try
    // 5 = Dests dictionary, 6 = Names dictionary, 7 = name tree root with a kid 8
    B.Replace(1, '<< /Type /Catalog /Pages 2 0 R /Dests 7 0 R /Names << /Dests 8 0 R >> >>');
    B.Add('<< /chapter1 [3 0 R /Fit] /chapter2 << /D [5 0 R /FitH 100] >> >>');
    B.Add('<< /Kids [9 0 R] >>');
    B.Add('<< /Limits [(a) (z)] /Names [(intro) [5 0 R /XYZ 0 0 0] (toc) [3 0 R /Fit]] >>');
    Load(B);
    D := FNav.ResolveDestination(PdfName('chapter1'));
    Assert.AreEqual(0, D.PageIndex);
    D := FNav.ResolveDestination(PdfName('chapter2'));
    Assert.AreEqual(1, D.PageIndex);
    Assert.AreEqual(dkFitH, D.Kind);
    D := FNav.ResolveDestination(PdfString('intro'));
    Assert.AreEqual(1, D.PageIndex, 'name tree string');
    Assert.AreEqual(dkXYZ, D.Kind);
    Assert.IsFalse(D.HasZoom, 'zoom 0 means unchanged');
    D := FNav.ResolveDestination(PdfString('toc'));
    Assert.AreEqual(0, D.PageIndex);
    D := FNav.ResolveDestination(PdfName('nosuch'));
    Assert.IsFalse(D.IsValid);
  finally
    B.Free;
  end;
end;

procedure TPdfNavigationTests.Actions;
var
  B: TPdfTestBuilder;
  A: TPdfAction;
begin
  B := TPdfTestBuilder.SimpleDocument(2);
  try
    Load(B);
    A := FNav.ParseAction(PdfParseObject('<< /S /GoTo /D [5 0 R /Fit] >>', FDoc.Resolver));
    Assert.AreEqual(akGoTo, A.Kind);
    Assert.AreEqual(1, A.Dest.PageIndex);
    A := FNav.ParseAction(PdfParseObject('<< /S /URI /URI (https://example.org/a%20b) >>', FDoc.Resolver));
    Assert.AreEqual(akURI, A.Kind);
    Assert.AreEqual('https://example.org/a%20b', A.Target);
    A := FNav.ParseAction(PdfParseObject('<< /S /GoToR /F (other.pdf) /D [0 /Fit] >>', FDoc.Resolver));
    Assert.AreEqual(akGoToRemote, A.Kind);
    Assert.AreEqual('other.pdf', A.Target);
    A := FNav.ParseAction(PdfParseObject('<< /S /Launch /F << /F (app.exe) /UF (app.exe) >> >>', FDoc.Resolver));
    Assert.AreEqual(akLaunch, A.Kind);
    Assert.AreEqual('app.exe', A.Target);
    A := FNav.ParseAction(PdfParseObject('<< /S /Named /N /NextPage >>', FDoc.Resolver));
    Assert.AreEqual(akNamed, A.Kind);
    Assert.AreEqual('NextPage', A.Target);
    A := FNav.ParseAction(PdfParseObject('<< /S /JavaScript /JS (app.alert(1)) >>', FDoc.Resolver));
    Assert.AreEqual(akJavaScript, A.Kind);
    A := FNav.ParseAction(PdfParseObject('<< /S /Sound >>', FDoc.Resolver));
    Assert.AreEqual(akOther, A.Kind);
    Assert.AreEqual('Sound', A.Target);
    A := FNav.ParseAction(PdfInteger(5));
    Assert.AreEqual(akNone, A.Kind);
  finally
    B.Free;
  end;
end;

procedure TPdfNavigationTests.OutlineTree;
var
  B: TPdfTestBuilder;
  Items: TObjectList<TPdfOutlineItem>;
begin
  B := TPdfTestBuilder.SimpleDocument(3);
  try
    // 9 = outline root, 10/11 top items, 12 child of 10
    B.Replace(1, '<< /Type /Catalog /Pages 2 0 R /Outlines 9 0 R >>');
    B.Add('<< /Type /Outlines /First 10 0 R /Last 11 0 R /Count 3 >>');                           // 9
    B.Add('<< /Title (Chapter 1) /Parent 9 0 R /Next 11 0 R /First 12 0 R /Last 12 0 R /Count 1 /Dest [3 0 R /Fit] >>'); // 10
    B.Add('<< /Title <FEFF00480032> /Parent 9 0 R /Prev 10 0 R /A << /S /GoTo /D [7 0 R /XYZ 0 100 0] >> >>'); // 11
    B.Add('<< /Title (Section 1.1) /Parent 10 0 R /Dest [5 0 R /Fit] >>');                        // 12
    Load(B);
    Assert.AreEqual(2, FNav.OutlineCount);
    Items := FNav.Outline;
    Assert.AreEqual('Chapter 1', Items[0].Title);
    Assert.AreEqual(0, Items[0].Dest.PageIndex);
    Assert.IsTrue(Items[0].IsOpen);
    Assert.AreEqual(1, Integer(Items[0].Children.Count));
    Assert.AreEqual('Section 1.1', Items[0].Children[0].Title);
    Assert.AreEqual(1, Items[0].Children[0].Dest.PageIndex);
    Assert.AreEqual(1, Items[0].Children[0].Level);
    Assert.IsTrue(Items[0].Children[0].Parent = Items[0]);
    Assert.AreEqual('H2', Items[1].Title, 'UTF-16 title');
    Assert.AreEqual(akGoTo, Items[1].Action.Kind);
    Assert.AreEqual(2, Items[1].Dest.PageIndex, 'dest from the GoTo action');
    Assert.AreEqual(100.0, Items[1].Dest.Top, 1E-9);
  finally
    B.Free;
  end;
end;

procedure TPdfNavigationTests.OutlineLoopTerminates;
var
  B: TPdfTestBuilder;
begin
  B := TPdfTestBuilder.SimpleDocument(1);
  try
    B.Replace(1, '<< /Type /Catalog /Pages 2 0 R /Outlines 5 0 R >>');
    B.Add('<< /Type /Outlines /First 6 0 R >>');                                   // 5
    B.Add('<< /Title (A) /Next 7 0 R /First 6 0 R >>');                            // 6: child is itself
    B.Add('<< /Title (B) /Next 6 0 R >>');                                         // 7: cycle back
    Load(B);
    Assert.AreEqual(2, FNav.OutlineCount);
    Assert.AreEqual(0, Integer(FNav.Outline[0].Children.Count));
  finally
    B.Free;
  end;
end;

procedure TPdfNavigationTests.AnnotationsWithAppearanceStates;
var
  B: TPdfTestBuilder;
  List: TObjectList<TPdfAnnotation>;
begin
  B := TPdfTestBuilder.SimpleDocument(2);
  try
    // SimpleDocument(2) uses objects 1..6; page 1 (object 3) gets annotations 7..10 with appearance streams 11/12
    B.Replace(3, '<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [7 0 R 8 0 R 9 0 R 10 0 R 99 0 R] >>');
    B.Add('<< /Type /Annot /Subtype /Link /Rect [10 10 100 30] /Border [0 0 0] /A << /S /URI /URI (http://x.org) >> >>'); // 7
    B.Add('<< /Type /Annot /Subtype /Link /Rect [100 30 10 10] /Dest [5 0 R /Fit] /F 2 >>');                               // 8: hidden, reversed rect
    B.Add('<< /Type /Annot /Subtype /Widget /Rect [0 0 50 50] /AS /On /AP << /N << /On 11 0 R /Off 12 0 R >> >> /F 4 >>'); // 9
    B.Add('<< /Type /Annot /Subtype /Popup /Rect [0 0 1 1] /Contents (hi) >>');                                            // 10
    B.AddStream('<< /Type /XObject /Subtype /Form /BBox [0 0 10 10] >>', '0 g 0 0 10 10 re f');                            // 11
    B.AddStream('<< /Type /XObject /Subtype /Form /BBox [0 0 10 10] >>', '');                                              // 12
    Load(B);
    List := FNav.LoadAnnotations(FDoc.Pages[0]);
    try
      Assert.AreEqual(4, Integer(List.Count), 'the dangling reference is skipped');
      Assert.IsTrue(List[0].IsLink);
      Assert.AreEqual(akURI, List[0].Action.Kind);
      Assert.AreEqual('http://x.org', List[0].Action.Target);
      Assert.IsTrue(List[0].IsVisible);
      Assert.IsNull(List[0].Appearance);
      Assert.AreEqual(akGoTo, List[1].Action.Kind, 'GoTo built from /Dest');
      Assert.AreEqual(1, List[1].Dest.PageIndex);
      Assert.AreEqual(10.0, List[1].Rect.X0, 1E-9, 'rect normalised');
      Assert.AreEqual(100.0, List[1].Rect.X1, 1E-9);
      Assert.IsTrue(afHidden in List[1].Flags);
      Assert.IsFalse(List[1].IsVisible);
      Assert.AreEqual('Widget', List[2].Subtype);
      Assert.IsNotNull(List[2].Appearance, 'state /On selected');
      Assert.AreEqual('On', List[2].AppearanceState);
      Assert.IsTrue(afPrint in List[2].Flags);
      Assert.AreEqual('Popup', List[3].Subtype);
      Assert.IsFalse(List[3].IsVisible);
      Assert.AreEqual('hi', List[3].Contents);
    finally
      List.Free;
    end;
    Assert.AreEqual(0, Integer(FNav.LoadAnnotations(FDoc.Pages[1]).Count));
  finally
    B.Free;
  end;
end;

{ TPdfPhase5RenderTests }

procedure TPdfPhase5RenderTests.Setup;
begin
  FDoc := TPdfDocument.Create;
  FRenderer := TPdfPageRenderer.Create(FDoc);
end;

procedure TPdfPhase5RenderTests.TearDown;
begin
  FRenderer.Free;
  FDoc.Free;
end;

function TPdfPhase5RenderTests.Render(const Content, Resources, PageExtra: string; const ExtraObjects: array of string): ISkImage;
var
  B: TPdfTestBuilder;
  S: string;
begin
  B := TPdfTestBuilder.SimpleDocument(1, '', '/MediaBox [0 0 100 100] /Resources ' + Resources + ' ' + PageExtra);
  try
    B.Replace(4, StreamObj('<< >>', Content));
    for S in ExtraObjects do
      B.Add(S);
    FDoc.LoadFromBytes(B.Build(1));
  finally
    B.Free;
  end;
  Result := FRenderer.RenderToImage(FDoc.Pages[0], 1);
end;

function TPdfPhase5RenderTests.Px(const Img: ISkImage; X, Y: Integer): TAlphaColor;
begin
  Result := Img.PeekPixels.Colors[X, Y];
end;

procedure TPdfPhase5RenderTests.AnnotationAppearanceIsDrawnIntoRect;
var
  Img: ISkImage;
begin
  // Appearance BBox 0..10 with Matrix scaling 2 -> transformed bbox 0..20, mapped onto Rect 50..90 x 10..50 (PDF coords)
  Img := Render('', '<< >>', '/Annots [5 0 R]',
    ['<< /Type /Annot /Subtype /Square /Rect [50 10 90 50] /AP << /N 6 0 R >> >>',
     StreamObj('<< /Type /XObject /Subtype /Form /BBox [0 0 10 10] /Matrix [2 0 0 2 0 0] >>', '1 0 0 rg 0 0 10 10 re f')]);
  Assert.AreEqual(TAlphaColorRec.Red, Px(Img, 70, 70) or $FF000000, 'inside the annotation rect (PDF y=30)');
  Assert.AreEqual(TAlphaColorRec.White, Px(Img, 30, 70), 'outside');
  Assert.AreEqual(TAlphaColorRec.White, Px(Img, 70, 30), 'above the rect');
  Assert.AreEqual(0, FRenderer.ErrorCount);
  FRenderer.RenderAnnotations := False;
  Img := FRenderer.RenderToImage(FDoc.Pages[0], 1);
  Assert.AreEqual(TAlphaColorRec.White, Px(Img, 70, 70), 'annotations switched off');
end;

procedure TPdfPhase5RenderTests.HiddenAnnotationIsSkipped;
var
  Img: ISkImage;
begin
  Img := Render('', '<< >>', '/Annots [5 0 R]',
    ['<< /Type /Annot /Subtype /Square /Rect [0 0 100 100] /F 2 /AP << /N 6 0 R >> >>',
     StreamObj('<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] >>', '1 0 0 rg 0 0 100 100 re f')]);
  Assert.AreEqual(TAlphaColorRec.White, Px(Img, 50, 50));
end;

procedure TPdfPhase5RenderTests.LuminositySoftMask;
var
  Img: ISkImage;
  C: TAlphaColor;
begin
  // Mask: left half white (fully visible), right half black (hidden); fill the page blue under it
  Img := Render('/GS gs 0 0 1 rg 0 0 100 100 re f',
    '<< /ExtGState << /GS << /SMask << /S /Luminosity /G 5 0 R >> >> >> >>', '',
    [StreamObj('<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Group << /S /Transparency /CS /DeviceGray >> >>',
      '1 g 0 0 50 100 re f 0 g 50 0 50 100 re f')]);
  Assert.AreEqual(TAlphaColorRec.Blue, Px(Img, 25, 50), 'visible through the white part of the mask');
  Assert.AreEqual(TAlphaColorRec.White, Px(Img, 75, 50), 'hidden by the black part');
  // Outside the mask form's BBox the backdrop (black) hides everything; with /BC 1 it shows
  Img := Render('/GS gs 0 0 1 rg 0 0 100 100 re f',
    '<< /ExtGState << /GS << /SMask << /S /Luminosity /G 5 0 R /BC [1] >> >> >> >>', '',
    [StreamObj('<< /Type /XObject /Subtype /Form /BBox [0 0 50 100] /Group << /S /Transparency /CS /DeviceGray >> >>',
      '0 g 0 0 50 100 re f')]);
  Assert.AreEqual(TAlphaColorRec.White, Px(Img, 25, 50), 'black mask inside the bbox');
  Assert.AreEqual(TAlphaColorRec.Blue, Px(Img, 75, 50), 'BC 1 outside the bbox');
  C := Px(Img, 75, 50);
  Assert.AreEqual(TAlphaColorRec.Blue, C);
end;

procedure TPdfPhase5RenderTests.AlphaSoftMaskAndNoneResets;
var
  Img: ISkImage;
begin
  // Alpha mask: the form paints only the top half -> only the top half of the red fill shows; then /SMask /None restores
  Img := Render('q /GS gs 1 0 0 rg 0 0 100 100 re f Q /GN gs 0 1 0 rg 0 0 20 20 re f',
    '<< /ExtGState << /GS << /SMask << /S /Alpha /G 5 0 R >> >> /GN << /SMask /None >> >> >>', '',
    [StreamObj('<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Group << /S /Transparency /CS /DeviceRGB >> >>',
      '0 g 0 50 100 50 re f')]);
  Assert.AreEqual(TAlphaColorRec.Red, Px(Img, 50, 25), 'top half visible');
  Assert.AreEqual(TAlphaColorRec.White, Px(Img, 50, 75), 'bottom half masked');
  Assert.AreEqual(TAlphaColorRec.Lime, Px(Img, 10, 90), 'drawn after /SMask /None');
end;

procedure TPdfPhase5RenderTests.TextExtractionAndSearch;
var
  B: TPdfTestBuilder;
  T: TPdfTextPage;
  M: TArray<TPdfTextMatch>;
begin
  B := TPdfTestBuilder.SimpleDocument(1, '', '/MediaBox [0 0 300 100] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>');
  try
    B.Replace(4, StreamObj('<< >>', 'BT /F1 20 Tf 10 60 Td (Hello World) Tj 0 -30 Td [(Sec) -200 (ond line)] TJ ET'));
    FDoc.LoadFromBytes(B.Build(1));
  finally
    B.Free;
  end;
  T := TPdfTextPage.Extract(FDoc.Pages[0], TPdfPageRenderer.PageMatrix(FDoc.Pages[0], 1));
  try
    Assert.AreEqual(0, T.PageIndex);
    Assert.AreEqual('Hello World'#10'Second line', T.Text);
    Assert.AreEqual(2, T.LineCount);
    Assert.AreEqual(22, T.GlyphCount, 'glyphs incl. the space');
    M := T.Find('world');
    Assert.AreEqual(1, Integer(Length(M)));
    Assert.AreEqual(6, M[0].CharIndex);
    Assert.AreEqual(1, Integer(Length(M[0].Rects)));
    // 'World' starts right of 'Hello ' and sits on the first line: y around 100-60-15 .. 100-60+5 (display space, y down)
    Assert.IsTrue(M[0].Rects[0].Left > 60, Format('x %.1f', [M[0].Rects[0].Left]));
    Assert.IsTrue((M[0].Rects[0].Top > 20) and (M[0].Rects[0].Bottom < 50), Format('y %.1f..%.1f', [M[0].Rects[0].Top, M[0].Rects[0].Bottom]));
    Assert.AreEqual(0, Integer(Length(T.Find('world', True))), 'case sensitive');
    Assert.AreEqual(1, Integer(Length(T.Find('World', True, True))));
    Assert.AreEqual(0, Integer(Length(T.Find('orl', False, True))), 'whole word');
    Assert.AreEqual(1, Integer(Length(T.Find('d'#10'S'))), 'the page text contains the line break');
    Assert.AreEqual(0, Integer(Length(T.Find(''))));
  finally
    T.Free;
  end;
end;

procedure TPdfPhase5RenderTests.TextSelectionByPosition;
var
  B: TPdfTestBuilder;
  T: TPdfTextPage;
  G1, G2: Integer;
  R: TArray<TRectF>;
begin
  B := TPdfTestBuilder.SimpleDocument(1, '', '/MediaBox [0 0 300 100] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>');
  try
    B.Replace(4, StreamObj('<< >>', 'BT /F1 20 Tf 10 60 Td (Hello World) Tj 0 -30 Td (Second line) TJ ET BT /F1 20 Tf 10 30 Td (Second line) Tj ET'));
    FDoc.LoadFromBytes(B.Build(1));
  finally
    B.Free;
  end;
  T := TPdfTextPage.Extract(FDoc.Pages[0], TPdfPageRenderer.PageMatrix(FDoc.Pages[0], 1));
  try
    G1 := T.GlyphAt(T.Glyph(0).Bounds.CenterPoint);
    Assert.AreEqual(0, G1, 'exact hit on H');
    Assert.AreEqual(-1, T.GlyphAt(TPointF.Create(290, 5)), 'empty area');
    G2 := T.GlyphAt(TPointF.Create(290, T.Glyph(0).Bounds.CenterPoint.Y), True);
    Assert.AreEqual(10, G2, 'nearest on the first line is the last glyph (d)');
    Assert.AreEqual('Hello World', T.SelectionText(0, 10));
    Assert.AreEqual('Hello World', T.SelectionText(10, 0), 'either order');
    Assert.AreEqual('World'#10'Second', T.SelectionText(6, 16));
    R := T.SelectionRects(6, 16);
    Assert.AreEqual(2, Integer(Length(R)), 'one rect per line');
    Assert.IsTrue(R[0].Top < R[1].Top);
    Assert.AreEqual(0, Integer(Length(T.SelectionRects(-1, 3))));
  finally
    T.Free;
  end;
end;

procedure TPdfPhase5RenderTests.TextOnlyModeDrawsNothing;
var
  Img: ISkImage;
  Sink: TPdfTextPage;
begin
  Img := Render('1 0 0 rg 0 0 100 100 re f BT /F1 20 Tf 10 10 Td (X) Tj ET',
    '<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>', '', []);
  Assert.AreEqual(TAlphaColorRec.Red, Px(Img, 50, 50));
  Sink := TPdfTextPage.Create;
  try
    FRenderer.TextOnly := True;
    FRenderer.TextSink := Sink;
    Img := FRenderer.RenderToImage(FDoc.Pages[0], 1);
    Assert.AreEqual(TAlphaColorRec.White, Px(Img, 50, 50), 'no painting in text-only mode');
    Assert.AreEqual(1, Sink.GlyphCount);
    Assert.AreEqual('X', Sink.Text);
  finally
    FRenderer.TextSink := nil;
    FRenderer.TextOnly := False;
    Sink.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfNavigationTests);
  TDUnitX.RegisterTestFixture(TPdfPhase5RenderTests);

end.
