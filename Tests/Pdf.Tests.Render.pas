unit Pdf.Tests.Render;

{ Visual tests for Pdf.Render.Skia: small hand-made pages are rendered to a
  raster image and individual pixels are checked. Pixels are sampled away
  from edges so anti-aliasing does not matter. }

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Diagnostics, System.UITypes, System.Math,
  System.Generics.Collections, System.Skia, DUnitX.TestFramework,
  Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Document, Pdf.Render.Skia, Pdf.Tests.Builder;

type
  [TestFixture]
  TPdfRenderTests = class
  private
    FDoc: TPdfDocument;
    FRenderer: TPdfPageRenderer;
    function Render(const Content, Resources: string; const ExtraObjects: array of string;
      Scale: Double = 1; const PageExtra: string = '/MediaBox [0 0 100 100]'): ISkImage;
    procedure CheckPixel(const Img: ISkImage; X, Y: Integer; Expected: TAlphaColor; const Msg: string; Tolerance: Integer = 8);
    function IsWhite(const Img: ISkImage; X, Y: Integer): Boolean;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure PageMatrixAndSize;
    [Test] procedure FilledRectangleWithYFlip;
    [Test] procedure NonzeroVersusEvenOdd;
    [Test] procedure StrokedLineAndMinimumWidth;
    [Test] procedure DashedLine;
    [Test] procedure ClipRestrictsPainting;
    [Test] procedure CTMConcatenation;
    [Test] procedure ColorOperatorsAndSpaces;
    [Test] procedure ExtGStateAlpha;
    [Test] procedure AxialShadingOperator;
    [Test] procedure RadialShadingWithoutExtend;
    [Test] procedure ShadingPatternFill;
    [Test] procedure TilingPattern;
    [Test] procedure UncolouredTilingPattern;
    [Test] procedure InlineImageMask;
    [Test] procedure ImageXObjectRGB;
    [Test] procedure FormXObjectWithMatrixAndBBox;
    [Test] procedure RotatedPage;
    [Test] procedure CropBoxOffset;
    [Test] procedure GarbageDoesNotAbortRendering;
    [Test] procedure RecursiveFormTerminates;
    [Test] procedure TextPlaceholders;
    [Test] procedure TransparencyGroupAlpha;
  end;

  [TestFixture]
  TPdfRenderCorpusTests = class
  public
    [Test] procedure AllCorpusPagesRender;
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

function Px(const Img: ISkImage; X, Y: Integer): TAlphaColor;
begin
  Result := Img.PeekPixels.Colors[X, Y];
end;

{ TPdfRenderTests }

procedure TPdfRenderTests.Setup;
begin
  FDoc := TPdfDocument.Create;
  FRenderer := TPdfPageRenderer.Create(FDoc);
end;

procedure TPdfRenderTests.TearDown;
begin
  FRenderer.Free;
  FDoc.Free;
end;

function TPdfRenderTests.Render(const Content, Resources: string; const ExtraObjects: array of string;
  Scale: Double; const PageExtra: string): ISkImage;
var
  B: TPdfTestBuilder;
  S: string;
begin
  B := TPdfTestBuilder.SimpleDocument(1, '', PageExtra + ' /Resources ' + Resources);
  try
    B.Replace(4, StreamObj('<< >>', Content));
    for S in ExtraObjects do
      B.Add(S);
    FDoc.LoadFromBytes(B.Build(1));
  finally
    B.Free;
  end;
  Result := FRenderer.RenderToImage(FDoc.Pages[0], Scale);
end;

procedure TPdfRenderTests.CheckPixel(const Img: ISkImage; X, Y: Integer; Expected: TAlphaColor; const Msg: string; Tolerance: Integer);
var
  Actual: TAlphaColor;
  DR, DG, DB: Integer;
begin
  Actual := Px(Img, X, Y);
  DR := Abs(Integer((Actual shr 16) and $FF) - Integer((Expected shr 16) and $FF));
  DG := Abs(Integer((Actual shr 8) and $FF) - Integer((Expected shr 8) and $FF));
  DB := Abs(Integer(Actual and $FF) - Integer(Expected and $FF));
  Assert.IsTrue((DR <= Tolerance) and (DG <= Tolerance) and (DB <= Tolerance),
    Format('%s: pixel (%d,%d) is %.8x, expected %.8x', [Msg, X, Y, Actual, Expected]));
end;

function TPdfRenderTests.IsWhite(const Img: ISkImage; X, Y: Integer): Boolean;
begin
  Result := (Px(Img, X, Y) and $FFFFFF) = $FFFFFF;
end;

procedure TPdfRenderTests.PageMatrixAndSize;
var
  B: TPdfTestBuilder;
  M: TPdfMatrix;
  W, H: Integer;
  X, Y: Double;
begin
  B := TPdfTestBuilder.SimpleDocument(1, '', '/MediaBox [0 0 200 100]');
  try
    FDoc.LoadFromBytes(B.Build(1));
  finally
    B.Free;
  end;
  TPdfPageRenderer.PageSizePixels(FDoc.Pages[0], 2, W, H);
  Assert.AreEqual(400, W);
  Assert.AreEqual(200, H);
  M := TPdfPageRenderer.PageMatrix(FDoc.Pages[0], 2);
  X := 0;
  Y := 0;
  M.Apply(X, Y);
  Assert.AreEqual(0.0, X, 1E-6);
  Assert.AreEqual(200.0, Y, 1E-6); // bottom-left maps to the bottom row
  X := 200;
  Y := 100;
  M.Apply(X, Y);
  Assert.AreEqual(400.0, X, 1E-6);
  Assert.AreEqual(0.0, Y, 1E-6);
end;

procedure TPdfRenderTests.FilledRectangleWithYFlip;
var
  Img: ISkImage;
begin
  Img := Render('1 0 0 rg 10 10 50 30 re f', '<< >>', []);
  Assert.AreEqual(100, Img.Width);
  Assert.AreEqual(100, Img.Height);
  CheckPixel(Img, 30, 75, TAlphaColorRec.Red, 'inside (PDF y=25)');
  CheckPixel(Img, 30, 50, TAlphaColorRec.White, 'above the rectangle (PDF y=50)');
  CheckPixel(Img, 80, 75, TAlphaColorRec.White, 'right of the rectangle');
  Assert.AreEqual(0, FRenderer.ErrorCount);
end;

procedure TPdfRenderTests.NonzeroVersusEvenOdd;
const
  Squares = '10 10 80 80 re 30 30 40 40 re ';
var
  Img: ISkImage;
begin
  Img := Render('0 0 1 rg ' + Squares + 'f', '<< >>', []);
  CheckPixel(Img, 50, 50, TAlphaColorRec.Blue, 'nonzero fills the inner square');
  Img := Render('0 0 1 rg ' + Squares + 'f*', '<< >>', []);
  CheckPixel(Img, 50, 50, TAlphaColorRec.White, 'even-odd leaves a hole');
  CheckPixel(Img, 15, 50, TAlphaColorRec.Blue, 'even-odd ring');
end;

procedure TPdfRenderTests.StrokedLineAndMinimumWidth;
var
  Img: ISkImage;
begin
  Img := Render('0 0 1 RG 4 w 10 50 m 90 50 l S', '<< >>', []);
  CheckPixel(Img, 50, 50, TAlphaColorRec.Blue, 'on the line');
  CheckPixel(Img, 50, 40, TAlphaColorRec.White, 'beside the line');
  CheckPixel(Img, 5, 50, TAlphaColorRec.White, 'before the line (butt cap)');
  // Zero-width line is still visible (one device pixel)
  Img := Render('0 w 0 0 1 RG 10 50.5 m 90 50.5 l S', '<< >>', []);
  Assert.IsFalse(IsWhite(Img, 50, 49) and IsWhite(Img, 50, 50), 'hairline drawn');
end;

procedure TPdfRenderTests.DashedLine;
var
  Img: ISkImage;
  X, Painted, Blank: Integer;
begin
  Img := Render('[10 10] 0 d 4 w 0 0 1 RG 0 50 m 100 50 l S', '<< >>', []);
  Painted := 0;
  Blank := 0;
  for X := 0 to 99 do
    if IsWhite(Img, X, 50) then
      Inc(Blank)
    else
      Inc(Painted);
  Assert.IsTrue((Painted > 35) and (Painted < 65), Format('dash coverage %d/100', [Painted]));
  Assert.IsTrue(Blank > 35);
  CheckPixel(Img, 5, 50, TAlphaColorRec.Blue, 'first dash on');
  CheckPixel(Img, 15, 50, TAlphaColorRec.White, 'first gap');
end;

procedure TPdfRenderTests.ClipRestrictsPainting;
var
  Img: ISkImage;
begin
  Img := Render('q 0 0 50 100 re W n 0 1 0 rg 0 0 100 100 re f Q 0 0 1 rg 60 0 10 10 re f', '<< >>', []);
  CheckPixel(Img, 25, 50, TAlphaColorRec.Lime, 'inside clip');
  CheckPixel(Img, 75, 50, TAlphaColorRec.White, 'outside clip');
  CheckPixel(Img, 65, 95, TAlphaColorRec.Blue, 'clip restored after Q');
  // Empty clip path blocks everything
  Img := Render('W n 1 0 0 rg 0 0 100 100 re f', '<< >>', []);
  CheckPixel(Img, 50, 50, TAlphaColorRec.White, 'empty clip');
end;

procedure TPdfRenderTests.CTMConcatenation;
var
  Img: ISkImage;
begin
  Img := Render('q 2 0 0 2 10 10 cm 0 0 10 10 re f Q 1 0 0 rg q 1 0 0 1 50 50 cm 0.5 0 0 0.5 0 0 cm 0 0 40 40 re f Q', '<< >>', []);
  CheckPixel(Img, 20, 80, TAlphaColorRec.Black, 'scaled rect 10..30');
  CheckPixel(Img, 35, 80, TAlphaColorRec.White, 'outside scaled rect');
  CheckPixel(Img, 60, 40, TAlphaColorRec.Red, 'nested cm: 50..70');
  CheckPixel(Img, 75, 40, TAlphaColorRec.White, 'nested cm outside');
end;

procedure TPdfRenderTests.ColorOperatorsAndSpaces;
var
  Img: ISkImage;
begin
  Img := Render('0.5 g 0 0 50 50 re f 0 0 0 1 k 50 0 50 50 re f /DeviceRGB cs 0 1 0 sc 0 50 50 50 re f /CS0 cs 1 sc 50 50 50 50 re f',
    '<< /ColorSpace << /CS0 [/Indexed /DeviceRGB 1 <FF00FF00FFFF>] >> >>', []);
  CheckPixel(Img, 25, 75, $FF808080, 'gray 0.5');
  CheckPixel(Img, 75, 75, TAlphaColorRec.Black, 'CMYK black');
  CheckPixel(Img, 25, 25, TAlphaColorRec.Lime, 'sc in DeviceRGB');
  CheckPixel(Img, 75, 25, $FF00FFFF, 'Indexed colour 1 = cyan');
end;

procedure TPdfRenderTests.ExtGStateAlpha;
var
  Img: ISkImage;
begin
  Img := Render('/G1 gs 0 0 1 rg 0 0 100 100 re f', '<< /ExtGState << /G1 << /ca 0.5 /CA 1 >> >> >>', []);
  CheckPixel(Img, 50, 50, $FF8080FF, '50% blue over white');
end;

procedure TPdfRenderTests.AxialShadingOperator;
var
  Img: ISkImage;
begin
  Img := Render('/S1 sh',
    '<< /Shading << /S1 << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0] ' +
    '/Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> /Extend [true true] >> >> >>', []);
  CheckPixel(Img, 2, 50, TAlphaColorRec.Red, 'start colour', 16);
  CheckPixel(Img, 97, 50, TAlphaColorRec.Blue, 'end colour', 16);
  CheckPixel(Img, 50, 50, $FF800080, 'middle', 24);
end;

procedure TPdfRenderTests.RadialShadingWithoutExtend;
var
  Img: ISkImage;
begin
  Img := Render('0 0 1 rg 0 0 100 100 re f /S1 sh',
    '<< /Shading << /S1 << /ShadingType 3 /ColorSpace /DeviceGray /Coords [50 50 0 50 50 30] ' +
    '/Function << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >> >> >> >>', []);
  CheckPixel(Img, 50, 50, TAlphaColorRec.White, 'centre', 24);
  CheckPixel(Img, 50, 22, TAlphaColorRec.Black, 'near the edge of the circle (t=0.93)', 40);
  CheckPixel(Img, 5, 5, TAlphaColorRec.Blue, 'outside the circle stays untouched without Extend');
end;

procedure TPdfRenderTests.ShadingPatternFill;
var
  Img: ISkImage;
begin
  Img := Render('/Pattern cs /P1 scn 0 0 100 50 re f',
    '<< /Pattern << /P1 << /PatternType 2 /Shading << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0] ' +
    '/Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> /Extend [true true] >> >> >> >>', []);
  CheckPixel(Img, 2, 75, TAlphaColorRec.Red, 'left', 16);
  CheckPixel(Img, 97, 75, TAlphaColorRec.Blue, 'right', 16);
  CheckPixel(Img, 50, 25, TAlphaColorRec.White, 'outside the filled rectangle');
end;

procedure TPdfRenderTests.TilingPattern;
var
  Img: ISkImage;
begin
  // Object 5: a 20x20 tile with a red 10x10 square in its lower-left quarter
  Img := Render('/Pattern cs /P1 scn 0 0 100 100 re f',
    '<< /Pattern << /P1 5 0 R >> >>',
    [StreamObj('<< /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 20 20] /XStep 20 /YStep 20 /Resources << >> >>',
      '1 0 0 rg 0 0 10 10 re f')]);
  CheckPixel(Img, 5, 95, TAlphaColorRec.Red, 'first tile, red quarter');
  CheckPixel(Img, 15, 95, TAlphaColorRec.White, 'first tile, empty quarter');
  CheckPixel(Img, 45, 55, TAlphaColorRec.Red, 'tile (2,2) red quarter');
  CheckPixel(Img, 55, 45, TAlphaColorRec.White, 'tile (2,2) empty quarter');
end;

procedure TPdfRenderTests.UncolouredTilingPattern;
var
  Img: ISkImage;
begin
  Img := Render('/Pattern cs /P1 scn 0 0 100 100 re f',
    '<< /Pattern << /P1 5 0 R >> /ColorSpace << /CSp [/Pattern /DeviceRGB] >> >>',
    [StreamObj('<< /PatternType 1 /PaintType 2 /TilingType 1 /BBox [0 0 20 20] /XStep 20 /YStep 20 /Resources << >> >>',
      '0 0 1 rg 0 0 20 20 re f')]);
  // Without a base colour space the pattern paints black (no components given)
  CheckPixel(Img, 10, 90, TAlphaColorRec.Black, 'uncoloured without components');
  Img := Render('/CSp cs 0 1 0 /P1 scn 0 0 100 100 re f',
    '<< /Pattern << /P1 5 0 R >> /ColorSpace << /CSp [/Pattern /DeviceRGB] >> >>',
    [StreamObj('<< /PatternType 1 /PaintType 2 /TilingType 1 /BBox [0 0 20 20] /XStep 20 /YStep 20 /Resources << >> >>',
      '0 0 1 rg 0 0 20 20 re f')]);
  CheckPixel(Img, 10, 90, TAlphaColorRec.Lime, 'uncoloured pattern takes the scn colour, ignores rg inside');
end;

procedure TPdfRenderTests.InlineImageMask;
var
  Img: ISkImage;
begin
  // 2x2 stencil: row 0 = 01 (paint, skip), row 1 = 10 (skip, paint); bit 0 paints
  Img := Render('0 1 0 rg q 100 0 0 100 0 0 cm BI /W 2 /H 2 /IM true /BPC 1 ID ' + #$40 + #$80 + ' EI Q', '<< >>', []);
  CheckPixel(Img, 25, 25, TAlphaColorRec.Lime, 'top-left painted');
  CheckPixel(Img, 75, 25, TAlphaColorRec.White, 'top-right skipped');
  CheckPixel(Img, 25, 75, TAlphaColorRec.White, 'bottom-left skipped');
  CheckPixel(Img, 75, 75, TAlphaColorRec.Lime, 'bottom-right painted');
end;

procedure TPdfRenderTests.ImageXObjectRGB;
var
  Img: ISkImage;
begin
  Img := Render('q 100 0 0 100 0 0 cm /Im1 Do Q', '<< /XObject << /Im1 5 0 R >> >>',
    [StreamObj('<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 >>',
      #$FF#$00#$00 + #$00#$FF#$00 + #$00#$00#$FF + #$FF#$FF#$00)]);
  CheckPixel(Img, 25, 25, TAlphaColorRec.Red, 'top-left', 16);
  CheckPixel(Img, 75, 25, TAlphaColorRec.Lime, 'top-right', 16);
  CheckPixel(Img, 25, 75, TAlphaColorRec.Blue, 'bottom-left', 16);
  CheckPixel(Img, 75, 75, TAlphaColorRec.Yellow, 'bottom-right', 16);
end;

procedure TPdfRenderTests.FormXObjectWithMatrixAndBBox;
var
  Img: ISkImage;
begin
  // Form draws a 100x100 red square; Matrix moves it by (50,50); BBox clips it to 25x25
  Img := Render('/Fx Do', '<< /XObject << /Fx 5 0 R >> >>',
    [StreamObj('<< /Type /XObject /Subtype /Form /BBox [0 0 25 25] /Matrix [1 0 0 1 50 50] >>', '1 0 0 rg -10 -10 100 100 re f')]);
  CheckPixel(Img, 60, 40, TAlphaColorRec.Red, 'inside bbox');
  CheckPixel(Img, 85, 40, TAlphaColorRec.White, 'clipped by bbox');
  CheckPixel(Img, 40, 60, TAlphaColorRec.White, 'before the matrix offset');
end;

procedure TPdfRenderTests.RotatedPage;
var
  Img: ISkImage;
begin
  Img := Render('1 0 0 rg 0 0 10 10 re f', '<< >>', [], 1, '/MediaBox [0 0 100 50] /Rotate 90');
  Assert.AreEqual(50, Img.Width);
  Assert.AreEqual(100, Img.Height);
  CheckPixel(Img, 5, 5, TAlphaColorRec.Red, 'bottom-left of the page ends up top-left after 90 degrees');
  CheckPixel(Img, 45, 95, TAlphaColorRec.White, 'opposite corner');
  Img := Render('1 0 0 rg 0 0 10 10 re f', '<< >>', [], 1, '/MediaBox [0 0 100 50] /Rotate 180');
  CheckPixel(Img, 95, 5, TAlphaColorRec.Red, '180: top-right');
  Img := Render('1 0 0 rg 0 0 10 10 re f', '<< >>', [], 1, '/MediaBox [0 0 100 50] /Rotate 270');
  CheckPixel(Img, 45, 95, TAlphaColorRec.Red, '270: bottom-right');
end;

procedure TPdfRenderTests.CropBoxOffset;
var
  Img: ISkImage;
begin
  Img := Render('1 0 0 rg 50 50 10 10 re f', '<< >>', [], 2, '/MediaBox [0 0 100 100] /CropBox [50 50 100 100]');
  Assert.AreEqual(100, Img.Width);
  CheckPixel(Img, 10, 90, TAlphaColorRec.Red, 'rect at crop origin, scale 2');
  CheckPixel(Img, 50, 50, TAlphaColorRec.White, 'elsewhere');
end;

procedure TPdfRenderTests.GarbageDoesNotAbortRendering;
var
  Img: ISkImage;
begin
  Img := Render('0 0 1 rg foo 1 2 bar (x) baz /NoSuch Do /NoSuch sh /NoSuch gs ] >> 10 10 80 80 re f', '<< >>', []);
  CheckPixel(Img, 50, 50, TAlphaColorRec.Blue, 'rectangle after garbage');
  Assert.IsTrue(FRenderer.UnknownOperators >= 3);
  Assert.AreEqual(0, FRenderer.ErrorCount);
end;

procedure TPdfRenderTests.RecursiveFormTerminates;
var
  Img: ISkImage;
begin
  Img := Render('/Fx Do 1 0 0 rg 0 0 10 10 re f', '<< /XObject << /Fx 5 0 R >> >>',
    [StreamObj('<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources << /XObject << /Fx 5 0 R >> >> >>', '0 0 1 rg 40 40 20 20 re f /Fx Do')]);
  CheckPixel(Img, 50, 50, TAlphaColorRec.Blue, 'form content drawn once');
  CheckPixel(Img, 5, 95, TAlphaColorRec.Red, 'rendering continued after the recursive form');
end;

procedure TPdfRenderTests.TextPlaceholders;
const
  Content = 'BT /F1 24 Tf 10 40 Td (Hello) Tj ET';
  Res = '<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>';
var
  Img: ISkImage;
  X, Y, NonWhite: Integer;
begin
  Img := Render(Content, Res, []);
  NonWhite := 0;
  for Y := 0 to 99 do
    for X := 0 to 99 do
      if not IsWhite(Img, X, Y) then
        Inc(NonWhite);
  Assert.IsTrue(NonWhite > 50, 'glyphs are drawn by default');
  FRenderer.ShowTextPlaceholders := True;
  Img := Render(Content, Res, []);
  NonWhite := 0;
  for Y := 0 to 99 do
    for X := 0 to 99 do
      if not IsWhite(Img, X, Y) then
        Inc(NonWhite);
  Assert.IsTrue(NonWhite > 20, 'placeholder frame drawn');
  Assert.AreEqual(0, FRenderer.ErrorCount);
end;

procedure TPdfRenderTests.TransparencyGroupAlpha;
var
  Img: ISkImage;
begin
  // Two overlapping opaque squares inside a group drawn at 50%: the overlap must not be darker than the rest
  Img := Render('/G1 gs /Fx Do', '<< /ExtGState << /G1 << /ca 0.5 >> >> /XObject << /Fx 5 0 R >> >>',
    [StreamObj('<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Group << /S /Transparency /CS /DeviceRGB >> >>',
      '0 0 1 rg 10 10 50 50 re f 30 30 50 50 re f')]);
  CheckPixel(Img, 20, 80, $FF8080FF, 'single square at 50%');
  CheckPixel(Img, 45, 55, $FF8080FF, 'overlap also 50% (group alpha)');
end;

{ TPdfRenderCorpusTests }

procedure TPdfRenderCorpusTests.AllCorpusPagesRender;
var
  Files: TList<string>;
  Dir, Env, F: string;
  Doc: TPdfDocument;
  Renderer: TPdfPageRenderer;
  Failures: TStringList;
  I, Pages, OkCount, PageCount: Integer;
  SW: TStopwatch;
  Page: TPdfPage;
  Scale: Double;
  Img: ISkImage;
begin
  Files := TList<string>.Create;
  Failures := TStringList.Create;
  Doc := TPdfDocument.Create;
  Renderer := TPdfPageRenderer.Create(Doc);
  try
    Dir := TPath.GetFullPath(TPath.Combine(TestDataPath, '..\Corpus'));
    if TDirectory.Exists(Dir) then
      Files.AddRange(TDirectory.GetFiles(Dir, '*.pdf', TSearchOption.soAllDirectories));
    Env := GetEnvironmentVariable('PDF_CORPUS_DIRS');
    for Dir in Env.Split([';']) do
      if (Trim(Dir) <> '') and TDirectory.Exists(Trim(Dir)) then
        Files.AddRange(TDirectory.GetFiles(Trim(Dir), '*.pdf', TSearchOption.soAllDirectories));
    if Files.Count = 0 then
    begin
      Assert.Pass('No corpus files');
      Exit;
    end;
    Files.Sort;
    OkCount := 0;
    PageCount := 0;
    for F in Files do
    begin
      SW := TStopwatch.StartNew;
      try
        Doc.LoadFromFile(F);
        Pages := Min(Doc.PageCount, 3);
        for I := 0 to Pages - 1 do
        begin
          Page := Doc.Pages[I];
          Scale := 200 / Max(1, Max(Page.CropBox.Width, Page.CropBox.Height));
          Img := Renderer.RenderToImage(Page, Scale);
          Assert.IsNotNull(Img);
          Inc(PageCount);
        end;
        Doc.Close;
        if SW.ElapsedMilliseconds > 60000 then
          Failures.Add(Format('%s: took %d ms', [ExtractFileName(F), SW.ElapsedMilliseconds]))
        else
          Inc(OkCount);
      except
        on E: EPdfPasswordError do
          Inc(OkCount);
        on E: Exception do
          Failures.Add(Format('%s: %s: %s', [ExtractFileName(F), E.ClassName, E.Message]));
      end;
    end;
    TDUnitX.CurrentRunner.Log(TLogLevel.Information,
      Format('Render corpus: %d files, %d pages, %d ok, %d failed', [Files.Count, PageCount, OkCount, Failures.Count]));
    Assert.AreEqual(0, Failures.Count, #10 + Failures.Text);
  finally
    Renderer.Free;
    Doc.Free;
    Failures.Free;
    Files.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfRenderTests);
  TDUnitX.RegisterTestFixture(TPdfRenderCorpusTests);

end.
