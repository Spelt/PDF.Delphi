unit Pdf.Tests.Text;

{ Text rendering tests (fase 3): fonts are loaded from dictionaries built in
  the test and glyphs are rendered to a raster image, then pixels are checked. }

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.UITypes, System.Math, System.Skia,
  DUnitX.TestFramework,
  Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Parser, Pdf.Core.Document,
  Pdf.Font.Glyphs, Pdf.Font.Loader, Pdf.Render.Skia, Pdf.Tests.Builder;

type
  [TestFixture]
  TPdfFontLoaderTests = class
  public
    [Test] procedure StandardHelveticaWithoutDescriptor;
    [Test] procedure StandardFontWidthsFromProgram;
    [Test] procedure WidthsArrayAndMissingWidth;
    [Test] procedure DifferencesEncoding;
    [Test] procedure SymbolFontBuiltInEncoding;
    [Test] procedure EmbeddedTrueTypeWithWinAnsi;
    [Test] procedure Type0IdentityWithCIDToGIDMap;
    [Test] procedure Type0WidthsArrayForms;
    [Test] procedure Type3Font;
    [Test] procedure BrokenFontFallsBack;
    [Test] procedure OutlineCacheAndTextSpace;
  end;

  [TestFixture]
  TPdfTextRenderTests = class
  private
    FDoc: TPdfDocument;
    FRenderer: TPdfPageRenderer;
    function Render(const Content, Resources: string; const ExtraObjects: array of string; Scale: Double = 1): ISkImage;
    function CountInk(const Img: ISkImage; X0, Y0, X1, Y1: Integer): Integer;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure HelveticaDrawsGlyphs;
    [Test] procedure TextPositioningOperators;
    [Test] procedure RenderModes;
    [Test] procedure TextClipMode;
    [Test] procedure EmbeddedTrueTypeGlyphs;
    [Test] procedure Type3GlyphProcedures;
    [Test] procedure WordAndCharSpacingAdvance;
    [Test] procedure CorpusTextPagesRender;
  end;

implementation

function FontObj(const Body: string): IPdfDictionary;
begin
  Result := PdfAsDictionary(PdfParseObject(Body));
end;

function StreamObj(const Dict, Data: string): string;
var
  D: string;
begin
  D := Trim(Dict);
  Delete(D, Length(D) - 1, 2);
  Result := D + ' /Length ' + IntToStr(Length(Data)) + ' >>'#10'stream'#10 + Data + #10'endstream';
end;

function LiberationPath: string;
begin
  Result := TPath.GetFullPath(TPath.Combine(TestDataPath, '..\..\Resources\Fonts\LiberationSans-Regular.ttf'));
end;

{ TPdfFontLoaderTests }

procedure TPdfFontLoaderTests.StandardHelveticaWithoutDescriptor;
var
  F: TPdfFont;
  G: TArray<TPdfGlyphInfo>;
  O: TPdfGlyphOutline;
begin
  F := TPdfFont.Create(FontObj('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'), nil);
  try
    Assert.AreEqual(fkType1, F.Kind);
    Assert.IsTrue(F.IsSubstitute);
    Assert.IsTrue(F.HasProgram);
    Assert.IsFalse(F.IsSymbolic);
    G := F.Decode(PdfLatin1ToBytes('A '));
    Assert.AreEqual(2, Integer(Length(G)));
    Assert.IsTrue(G[0].GID > 0, 'A has a glyph');
    Assert.AreEqual(0.667, G[0].Width, 0.01, 'Helvetica A width 667');
    Assert.IsTrue(G[1].IsSpace);
    Assert.AreEqual(0.278, G[1].Width, 0.01, 'space width 278');
    Assert.IsTrue(F.GetOutline(G[0].GID, O));
    Assert.IsFalse(O.IsEmpty);
  finally
    F.Free;
  end;
end;

procedure TPdfFontLoaderTests.StandardFontWidthsFromProgram;
var
  F: TPdfFont;
  G: TArray<TPdfGlyphInfo>;
begin
  F := TPdfFont.Create(FontObj('<< /Type /Font /Subtype /Type1 /BaseFont /Times-Bold >>'), nil);
  try
    Assert.IsTrue(F.IsSubstitute);
    G := F.Decode(PdfLatin1ToBytes('M'));
    Assert.IsTrue(G[0].GID > 0);
    Assert.AreEqual(0.944, G[0].Width, 0.03, 'Times-Bold M width 944');
  finally
    F.Free;
  end;
  F := TPdfFont.Create(FontObj('<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>'), nil);
  try
    G := F.Decode(PdfLatin1ToBytes('iW'));
    Assert.AreEqual(0.6, G[0].Width, 0.01, 'Courier is monospaced');
    Assert.AreEqual(0.6, G[1].Width, 0.01);
  finally
    F.Free;
  end;
end;

procedure TPdfFontLoaderTests.WidthsArrayAndMissingWidth;
var
  F: TPdfFont;
  G: TArray<TPdfGlyphInfo>;
begin
  F := TPdfFont.Create(FontObj('<< /Type /Font /Subtype /TrueType /BaseFont /Arial /FirstChar 65 /LastChar 66 /Widths [700 800] ' +
    '/FontDescriptor << /Type /FontDescriptor /FontName /Arial /Flags 32 /MissingWidth 250 >> >>'), nil);
  try
    G := F.Decode(TBytes.Create(65, 66, 67));
    Assert.AreEqual(0.7, G[0].Width, 1E-6);
    Assert.AreEqual(0.8, G[1].Width, 1E-6);
    Assert.AreEqual(0.25, G[2].Width, 1E-6, 'outside Widths: MissingWidth');
  finally
    F.Free;
  end;
end;

procedure TPdfFontLoaderTests.DifferencesEncoding;
var
  F: TPdfFont;
  G: TArray<TPdfGlyphInfo>;
  OA, OB: TPdfGlyphOutline;
begin
  F := TPdfFont.Create(FontObj('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ' +
    '/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [65 /B 128 /Euro] >> >>'), nil);
  try
    G := F.Decode(TBytes.Create(65, 66, 128));
    Assert.IsTrue(G[0].GID > 0);
    Assert.AreEqual(G[0].GID, G[1].GID, 'code 65 remapped to B');
    Assert.IsTrue(G[2].GID > 0, 'Euro found through the glyph list');
    Assert.IsTrue(F.GetOutline(G[0].GID, OA));
    Assert.IsTrue(F.GetOutline(G[2].GID, OB));
    Assert.IsFalse(OB.IsEmpty);
  finally
    F.Free;
  end;
end;

procedure TPdfFontLoaderTests.SymbolFontBuiltInEncoding;
var
  F: TPdfFont;
  G: TArray<TPdfGlyphInfo>;
begin
  F := TPdfFont.Create(FontObj('<< /Type /Font /Subtype /Type1 /BaseFont /Symbol >>'), nil);
  try
    Assert.IsTrue(F.IsSymbolic);
    G := F.Decode(TBytes.Create(97)); // alpha
    Assert.IsTrue(G[0].GID > 0, 'alpha via the built-in encoding');
  finally
    F.Free;
  end;
  F := TPdfFont.Create(FontObj('<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats >>'), nil);
  try
    G := F.Decode(TBytes.Create(33)); // a1
    Assert.IsTrue(G[0].GID > 0, 'a1 via the built-in encoding');
  finally
    F.Free;
  end;
end;

procedure TPdfFontLoaderTests.EmbeddedTrueTypeWithWinAnsi;
var
  Data: TBytes;
  Stream: IPdfStream;
  Dict, Desc: IPdfDictionary;
  F: TPdfFont;
  G: TArray<TPdfGlyphInfo>;
begin
  Data := TFile.ReadAllBytes(LiberationPath);
  Stream := PdfStream(FontObj('<< /Length1 ' + IntToStr(Length(Data)) + ' >>'), Data);
  Desc := FontObj('<< /Type /FontDescriptor /FontName /LiberationSans /Flags 32 >>');
  Desc.SetValue('FontFile2', Stream);
  Dict := FontObj('<< /Type /Font /Subtype /TrueType /BaseFont /LiberationSans /Encoding /WinAnsiEncoding >>');
  Dict.SetValue('FontDescriptor', Desc);
  F := TPdfFont.Create(Dict, nil);
  try
    Assert.IsFalse(F.IsSubstitute);
    G := F.Decode(TBytes.Create(Ord('A'), $E9, $80));
    Assert.IsTrue(G[0].GID > 0, 'A');
    Assert.IsTrue(G[1].GID > 0, 'eacute through WinAnsi + cmap');
    Assert.IsTrue(G[2].GID > 0, 'Euro');
    Assert.AreEqual(1366 / 2048, G[0].Width, 0.001, 'width from hmtx when /Widths is absent');
  finally
    F.Free;
  end;
end;

procedure TPdfFontLoaderTests.Type0IdentityWithCIDToGIDMap;
var
  Data, Map: TBytes;
  Stream, MapStream: IPdfStream;
  Dict, Desc, CIDFont: IPdfDictionary;
  F: TPdfFont;
  G: TArray<TPdfGlyphInfo>;
  I: Integer;
begin
  Data := TFile.ReadAllBytes(LiberationPath);
  Stream := PdfStream(FontObj('<< >>'), Data);
  Desc := FontObj('<< /Type /FontDescriptor /FontName /LiberationSans /Flags 4 >>');
  Desc.SetValue('FontFile2', Stream);
  // CIDToGIDMap: CID 1 -> GID 36 ('A' in Liberation Sans is glyph 36), CID 2 -> GID 37
  SetLength(Map, 6);
  for I := 0 to 5 do
    Map[I] := 0;
  Map[2] := 0;
  Map[3] := 36;
  Map[4] := 0;
  Map[5] := 37;
  MapStream := PdfStream(FontObj('<< >>'), Map);
  CIDFont := FontObj('<< /Type /Font /Subtype /CIDFontType2 /BaseFont /LiberationSans /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /DW 500 /W [1 [700 800]] >>');
  CIDFont.SetValue('FontDescriptor', Desc);
  CIDFont.SetValue('CIDToGIDMap', MapStream);
  Dict := FontObj('<< /Type /Font /Subtype /Type0 /BaseFont /LiberationSans /Encoding /Identity-H >>');
  Dict.SetValue('DescendantFonts', PdfParseObject('[]'));
  (Dict.Get('DescendantFonts') as IPdfArray).Add(CIDFont);
  F := TPdfFont.Create(Dict, nil);
  try
    Assert.AreEqual(fkType0, F.Kind);
    Assert.IsFalse(F.Vertical);
    G := F.Decode(TBytes.Create(0, 1, 0, 2, 0, 9));
    Assert.AreEqual(3, Integer(Length(G)));
    Assert.AreEqual(1, G[0].CID);
    Assert.AreEqual(36, G[0].GID);
    Assert.AreEqual(0.7, G[0].Width, 1E-6);
    Assert.AreEqual(37, G[1].GID);
    Assert.AreEqual(0.8, G[1].Width, 1E-6);
    Assert.AreEqual(0.5, G[2].Width, 1E-6, 'DW');
    Assert.AreEqual(2, G[0].NumBytes);
    Assert.IsFalse(G[0].IsSpace);
  finally
    F.Free;
  end;
end;

procedure TPdfFontLoaderTests.Type0WidthsArrayForms;
var
  Dict, CIDFont: IPdfDictionary;
  F: TPdfFont;
  G: TArray<TPdfGlyphInfo>;
begin
  CIDFont := FontObj('<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Arial /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> ' +
    '/DW 1000 /W [10 [100 200] 20 25 300] /FontDescriptor << /Type /FontDescriptor /FontName /Arial /Flags 32 >> >>');
  Dict := FontObj('<< /Type /Font /Subtype /Type0 /BaseFont /Arial /Encoding /Identity-H >>');
  Dict.SetValue('DescendantFonts', PdfParseObject('[]'));
  (Dict.Get('DescendantFonts') as IPdfArray).Add(CIDFont);
  F := TPdfFont.Create(Dict, nil);
  try
    Assert.IsTrue(F.IsSubstitute, 'no program: substitute');
    G := F.Decode(TBytes.Create(0, 10, 0, 11, 0, 22, 0, 30));
    Assert.AreEqual(0.1, G[0].Width, 1E-6);
    Assert.AreEqual(0.2, G[1].Width, 1E-6);
    Assert.AreEqual(0.3, G[2].Width, 1E-6, 'range form');
    Assert.AreEqual(1.0, G[3].Width, 1E-6, 'DW');
  finally
    F.Free;
  end;
end;

procedure TPdfFontLoaderTests.Type3Font;
var
  Dict: IPdfDictionary;
  F: TPdfFont;
  G: TArray<TPdfGlyphInfo>;
begin
  Dict := FontObj('<< /Type /Font /Subtype /Type3 /FontBBox [0 0 750 750] /FontMatrix [0.01 0 0 0.01 0 0] ' +
    '/CharProcs << /square 5 0 R >> /Encoding << /Type /Encoding /Differences [97 /square] >> /FirstChar 97 /LastChar 97 /Widths [50] >>');
  F := TPdfFont.Create(Dict, nil);
  try
    Assert.IsTrue(F.IsType3);
    Assert.AreEqual(0.01, F.FontMatrix.A, 1E-9);
    G := F.Decode(TBytes.Create(97, 98));
    Assert.AreEqual(0.5, G[0].Width, 1E-6, 'width through the font matrix');
    Assert.AreEqual(0.0, G[1].Width, 1E-6);
    Assert.IsNull(F.Type3GlyphProc(98));
  finally
    F.Free;
  end;
end;

procedure TPdfFontLoaderTests.BrokenFontFallsBack;
var
  Dict, Desc: IPdfDictionary;
  F: TPdfFont;
  G: TArray<TPdfGlyphInfo>;
begin
  Desc := FontObj('<< /Type /FontDescriptor /FontName /Broken /Flags 32 >>');
  Desc.SetValue('FontFile2', PdfStream(FontObj('<< >>'), PdfLatin1ToBytes('this is not a font program at all, just garbage bytes')));
  Dict := FontObj('<< /Type /Font /Subtype /TrueType /BaseFont /Broken-Bold >>');
  Dict.SetValue('FontDescriptor', Desc);
  F := TPdfFont.Create(Dict, nil);
  try
    Assert.IsTrue(F.IsSubstitute);
    G := F.Decode(PdfLatin1ToBytes('x'));
    Assert.IsTrue(G[0].GID > 0);
    Assert.IsTrue(G[0].Width > 0);
  finally
    F.Free;
  end;
  F := TPdfFont.Create(nil, nil);
  try
    Assert.IsTrue(F.HasProgram, 'nil dictionary gives a default font');
  finally
    F.Free;
  end;
end;

procedure TPdfFontLoaderTests.OutlineCacheAndTextSpace;
var
  F: TPdfFont;
  G: TArray<TPdfGlyphInfo>;
  O1, O2: TPdfGlyphOutline;
  I: Integer;
  MaxY: Single;
begin
  F := TPdfFont.Create(FontObj('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'), nil);
  try
    G := F.Decode(PdfLatin1ToBytes('H'));
    Assert.IsTrue(F.GetOutline(G[0].GID, O1));
    Assert.IsTrue(F.GetOutline(G[0].GID, O2));
    Assert.AreEqual(O1.Count, O2.Count);
    MaxY := 0;
    for I := 0 to O1.Count - 1 do
      MaxY := Max(MaxY, O1.Cmds[I].Y1);
    Assert.IsTrue((MaxY > 0.6) and (MaxY < 0.8), Format('cap height in em units: %.3f', [MaxY]));
    Assert.IsFalse(F.GetOutline(-1, O1));
  finally
    F.Free;
  end;
end;

{ TPdfTextRenderTests }

procedure TPdfTextRenderTests.Setup;
begin
  FDoc := TPdfDocument.Create;
  FRenderer := TPdfPageRenderer.Create(FDoc);
end;

procedure TPdfTextRenderTests.TearDown;
begin
  FRenderer.Free;
  FDoc.Free;
end;

function TPdfTextRenderTests.Render(const Content, Resources: string; const ExtraObjects: array of string; Scale: Double): ISkImage;
var
  B: TPdfTestBuilder;
  S: string;
begin
  B := TPdfTestBuilder.SimpleDocument(1, '', '/MediaBox [0 0 200 100] /Resources ' + Resources);
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

function TPdfTextRenderTests.CountInk(const Img: ISkImage; X0, Y0, X1, Y1: Integer): Integer;
var
  X, Y: Integer;
  P: ISkPixmap;
begin
  Result := 0;
  P := Img.PeekPixels;
  for Y := Max(0, Y0) to Min(Img.Height - 1, Y1) do
    for X := Max(0, X0) to Min(Img.Width - 1, X1) do
      if (P.Colors[X, Y] and $FFFFFF) <> $FFFFFF then
        Inc(Result);
end;

const
  HelvRes = '<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>';

procedure TPdfTextRenderTests.HelveticaDrawsGlyphs;
var
  Img: ISkImage;
begin
  Img := Render('BT /F1 40 Tf 10 30 Td (HI) Tj ET', HelvRes, []);
  // 'H' at x 10..~37, cap height ~29 -> rows 100-30-29=41..70
  Assert.IsTrue(CountInk(Img, 10, 40, 40, 70) > 100, 'H has ink');
  Assert.AreEqual(0, CountInk(Img, 10, 75, 190, 99), 'nothing below the baseline');
  Assert.AreEqual(0, CountInk(Img, 100, 0, 199, 99), 'nothing right of the text');
  Assert.AreEqual(0, FRenderer.ErrorCount);
  Assert.AreEqual(1, FRenderer.FontCount);
end;

procedure TPdfTextRenderTests.TextPositioningOperators;
var
  Img1, Img2: ISkImage;
begin
  // Td then T* with leading: second line lower; Tm absolute
  Img1 := Render('BT /F1 20 Tf 24 TL 10 70 Td (A) Tj T* (A) Tj ET', HelvRes, []);
  Assert.IsTrue(CountInk(Img1, 10, 15, 30, 30) > 20, 'first A');
  Assert.IsTrue(CountInk(Img1, 10, 39, 30, 54) > 20, 'second A one leading lower');
  Img2 := Render('BT /F1 20 Tf 1 0 0 1 150 10 Tm (A) Tj ET', HelvRes, []);
  Assert.IsTrue(CountInk(Img2, 150, 75, 170, 90) > 20, 'Tm positions at 150,10');
  Assert.AreEqual(0, CountInk(Img2, 0, 0, 140, 99));
end;

procedure TPdfTextRenderTests.RenderModes;
var
  Fill, Stroke, Invisible: Integer;
begin
  Fill := CountInk(Render('BT /F1 40 Tf 0 Tr 10 30 Td (H) Tj ET', HelvRes, []), 0, 0, 199, 99);
  Stroke := CountInk(Render('BT /F1 40 Tf 1 Tr 0.5 w 10 30 Td (H) Tj ET', HelvRes, []), 0, 0, 199, 99);
  Invisible := CountInk(Render('BT /F1 40 Tf 3 Tr 10 30 Td (H) Tj ET', HelvRes, []), 0, 0, 199, 99);
  Assert.IsTrue(Fill > 150, 'fill');
  Assert.IsTrue((Stroke > 50) and (Stroke < Fill), 'stroke is an outline');
  Assert.AreEqual(0, Invisible, 'mode 3 draws nothing');
end;

procedure TPdfTextRenderTests.TextClipMode;
var
  Img: ISkImage;
begin
  // Mode 7: glyph shapes become the clip; a full-page red fill then only shows inside the letter
  Img := Render('BT /F1 60 Tf 7 Tr 10 20 Td (H) Tj ET 1 0 0 rg 0 0 200 100 re f', HelvRes, []);
  Assert.IsTrue(CountInk(Img, 10, 30, 60, 80) > 200, 'red inside the H');
  Assert.AreEqual(0, CountInk(Img, 100, 0, 199, 99), 'clipped outside the glyph');
  // Mode 7 without any shown glyph leaves the clip alone (pdf.js behaviour)
  Img := Render('BT /F1 60 Tf 7 Tr ET 1 0 0 rg 0 0 200 100 re f', HelvRes, []);
  Assert.AreEqual(20000, CountInk(Img, 0, 0, 199, 99));
  // Clip is restored by Q
  Img := Render('q BT /F1 60 Tf 7 Tr 10 20 Td (H) Tj ET Q 1 0 0 rg 0 0 200 100 re f', HelvRes, []);
  Assert.AreEqual(20000, CountInk(Img, 0, 0, 199, 99));
end;

procedure TPdfTextRenderTests.EmbeddedTrueTypeGlyphs;
var
  Data: TBytes;
  Img: ISkImage;
begin
  Data := TFile.ReadAllBytes(LiberationPath);
  Img := Render('BT /F1 40 Tf 10 30 Td (I) Tj ET',
    '<< /Font << /F1 5 0 R >> >>',
    ['<< /Type /Font /Subtype /TrueType /BaseFont /LiberationSans /Encoding /WinAnsiEncoding /FontDescriptor 6 0 R >>',
     '<< /Type /FontDescriptor /FontName /LiberationSans /Flags 32 /FontFile2 7 0 R >>',
     StreamObj('<< >>', PdfBytesToLatin1(Data))]);
  Assert.IsTrue(CountInk(Img, 10, 40, 25, 70) > 50, 'I drawn from the embedded TrueType');
  Assert.AreEqual(0, CountInk(Img, 40, 0, 199, 99));
  Assert.AreEqual(0, FRenderer.ErrorCount);
end;

procedure TPdfTextRenderTests.Type3GlyphProcedures;
var
  Img: ISkImage;
begin
  // Glyph 'a' = a filled square 0..750 in glyph space (FontMatrix 0.001): at 40pt it is 30x30 points
  Img := Render('BT /T3 40 Tf 10 10 Td (a) Tj ET',
    '<< /Font << /T3 5 0 R >> >>',
    ['<< /Type /Font /Subtype /Type3 /FontBBox [0 0 750 750] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /square 6 0 R >> ' +
     '/Encoding << /Type /Encoding /Differences [97 /square] >> /FirstChar 97 /LastChar 97 /Widths [1000] /Resources << >> >>',
     StreamObj('<< >>', '1000 0 0 0 750 750 d1 0 0 750 750 re f')]);
  Assert.IsTrue(CountInk(Img, 12, 62, 38, 88) > 600, 'square filled');
  Assert.AreEqual(0, CountInk(Img, 45, 0, 199, 99));
  Assert.AreEqual(0, FRenderer.ErrorCount);
end;

procedure TPdfTextRenderTests.WordAndCharSpacingAdvance;
var
  Plain, Spaced: ISkImage;
  FirstInkPlain, FirstInkSpaced, X: Integer;
begin
  Plain := Render('BT /F1 20 Tf 10 40 Td (A A) Tj ET', HelvRes, []);
  Spaced := Render('BT /F1 20 Tf 10 Tw 5 Tc 10 40 Td (A A) Tj ET', HelvRes, []);
  // The second A starts further right when word and char spacing are set
  FirstInkPlain := -1;
  FirstInkSpaced := -1;
  for X := 26 to 199 do
  begin
    if (FirstInkPlain < 0) and (CountInk(Plain, X, 40, X, 60) > 0) then
      FirstInkPlain := X;
    if (FirstInkSpaced < 0) and (CountInk(Spaced, X, 40, X, 60) > 0) then
      FirstInkSpaced := X;
  end;
  Assert.IsTrue(FirstInkPlain > 26, 'second A found');
  Assert.IsTrue(FirstInkSpaced > FirstInkPlain + 15, Format('spacing moved the second A: %d vs %d', [FirstInkPlain, FirstInkSpaced]));
end;

procedure TPdfTextRenderTests.CorpusTextPagesRender;
const
  Files: array[0..4] of string = ('tracemonkey.pdf', 'TAMReview.pdf', 'issue2829.pdf', 'text_clip_cff_cid.pdf', 'mixedfonts.pdf');
var
  Dir, F: string;
  Doc: TPdfDocument;
  R: TPdfPageRenderer;
  Img: ISkImage;
  Found: Integer;
begin
  Dir := GetEnvironmentVariable('PDF_CORPUS_DIRS');
  if Dir.Contains(';') then
    Dir := Dir.Split([';'])[0];
  Dir := Trim(Dir);
  if (Dir = '') or not TDirectory.Exists(Dir) then
  begin
    Assert.Pass('No corpus');
    Exit;
  end;
  Doc := TPdfDocument.Create;
  R := TPdfPageRenderer.Create(Doc);
  try
    Found := 0;
    for F in Files do
      if TFile.Exists(TPath.Combine(Dir, F)) then
      begin
        Doc.LoadFromFile(TPath.Combine(Dir, F));
        Img := R.RenderToImage(Doc.Pages[0], 1);
        Assert.IsTrue(CountInk(Img, 0, 0, Img.Width - 1, Img.Height - 1) > 500, F + ' shows text');
        Inc(Found);
      end;
    Assert.IsTrue(Found > 0);
  finally
    R.Free;
    Doc.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfFontLoaderTests);
  TDUnitX.RegisterTestFixture(TPdfTextRenderTests);

end.
