unit Pdf.Tests.Font.Tables;

interface

uses
  System.SysUtils, DUnitX.TestFramework, Pdf.Font.Encodings, Pdf.Font.GlyphList, Pdf.Font.StandardFonts;

type
  [TestFixture]
  TPdfEncodingTableTests = class
  public
    [Test] procedure WinAnsi;
    [Test] procedure MacRoman;
    [Test] procedure Standard;
    [Test] procedure SymbolAndDingbats;
    [Test] procedure ExpertTables;
    [Test] procedure ByName;
    [Test] procedure StandardEncodingCode;
  end;

  [TestFixture]
  TPdfGlyphListTests = class
  public
    [Test] procedure AdobeGlyphList;
    [Test] procedure UniNames;
    [Test] procedure UNames;
    [Test] procedure GlyphIndexNamesAreUnknown;
    [Test] procedure Suffixes;
    [Test] procedure Ligatures;
    [Test] procedure DecimalCNames;
    [Test] procedure Unknown;
    [Test] procedure Reverse;
    [Test] procedure Dingbats;
  end;

  [TestFixture]
  TPdfStandardFontTests = class
  public
    [Test] procedure StandardNames;
    [Test] procedure ArialFamily;
    [Test] procedure TimesFamily;
    [Test] procedure CourierFamily;
    [Test] procedure SymbolicFonts;
    [Test] procedure FamilyWithStyleWords;
    [Test] procedure NonStandardMap;
    [Test] procedure UnknownNamesGuess;
    [Test] procedure CanonicalNames;
    [Test] procedure Kinds;
    [Test] procedure ResourceData;
    [Test] procedure ResourceDataIsCached;
  end;

implementation

{ TPdfEncodingTableTests }

procedure TPdfEncodingTableTests.WinAnsi;
var
  T: PPdfEncodingTable;
begin
  T := PdfWinAnsiEncoding;
  Assert.AreEqual('A', T^[65]);
  Assert.AreEqual('Euro', T^[128]);
  Assert.AreEqual('space', T^[160]);
  Assert.AreEqual('hyphen', T^[173]);
  Assert.AreEqual('quotesingle', T^[39]);
  Assert.AreEqual('ydieresis', T^[255]);
  Assert.AreEqual('', T^[0]);
end;

procedure TPdfEncodingTableTests.MacRoman;
var
  T: PPdfEncodingTable;
begin
  T := PdfMacRomanEncoding;
  Assert.AreEqual('space', T^[202]);
  Assert.AreEqual('bullet', T^[165]);
  Assert.AreEqual('Adieresis', T^[128]);
  Assert.AreEqual('caron', T^[255]);
end;

procedure TPdfEncodingTableTests.Standard;
var
  T: PPdfEncodingTable;
begin
  T := PdfStandardEncoding;
  Assert.AreEqual('quoteright', T^[39]);
  Assert.AreEqual('quoteleft', T^[96]);
  Assert.AreEqual('space', T^[32]);
  Assert.AreEqual('fi', T^[174]);
  Assert.AreEqual('', T^[128]);
  Assert.AreEqual('germandbls', T^[251]);
end;

procedure TPdfEncodingTableTests.SymbolAndDingbats;
begin
  Assert.AreEqual('alpha', PdfSymbolEncoding^[97]);
  Assert.AreEqual('Alpha', PdfSymbolEncoding^[65]);
  Assert.AreEqual('a1', PdfZapfDingbatsEncoding^[33]);
  Assert.AreEqual('space', PdfZapfDingbatsEncoding^[32]);
end;

procedure TPdfEncodingTableTests.ExpertTables;
begin
  Assert.AreEqual('space', PdfExpertEncoding^[32]);
  Assert.AreEqual('exclamsmall', PdfExpertEncoding^[33]);
  Assert.AreEqual('space', PdfMacExpertEncoding^[32]);
end;

procedure TPdfEncodingTableTests.ByName;
begin
  Assert.IsTrue(PdfEncodingByName('WinAnsiEncoding') = PdfWinAnsiEncoding);
  Assert.IsTrue(PdfEncodingByName('StandardEncoding') = PdfStandardEncoding);
  Assert.IsTrue(PdfEncodingByName('MacRomanEncoding') = PdfMacRomanEncoding);
  Assert.IsTrue(PdfEncodingByName('MacExpertEncoding') = PdfMacExpertEncoding);
  Assert.IsTrue(PdfEncodingByName('Foo') = nil);
  Assert.IsTrue(PdfEncodingByName('SymbolSetEncoding') = nil);
  Assert.IsTrue(PdfEncodingByName('') = nil);
end;

procedure TPdfEncodingTableTests.StandardEncodingCode;
begin
  Assert.AreEqual(65, PdfStandardEncodingCode('A'));
  Assert.AreEqual(-1, PdfStandardEncodingCode('eacute'));
  Assert.AreEqual(39, PdfStandardEncodingCode('quoteright'));
  Assert.AreEqual(194, PdfStandardEncodingCode('acute'));
  Assert.AreEqual(251, PdfStandardEncodingCode('germandbls'));
  Assert.AreEqual(32, PdfStandardEncodingCode('space'));
  Assert.AreEqual(-1, PdfStandardEncodingCode(''));
end;

{ TPdfGlyphListTests }

procedure TPdfGlyphListTests.AdobeGlyphList;
begin
  Assert.AreEqual(65, PdfGlyphNameToUnicode('A'));
  Assert.AreEqual($E9, PdfGlyphNameToUnicode('eacute'));
  Assert.AreEqual($20AC, PdfGlyphNameToUnicode('Euro'));
  Assert.AreEqual($20, PdfGlyphNameToUnicode('space'));
  Assert.AreEqual($3B1, PdfGlyphNameToUnicode('alpha'));
  Assert.AreEqual(0, PdfGlyphNameToUnicode('controlNULL'));
end;

procedure TPdfGlyphListTests.UniNames;
begin
  Assert.AreEqual($E9, PdfGlyphNameToUnicode('uni00E9'));
  Assert.AreEqual($41, PdfGlyphNameToUnicode('uni00410042'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('uni0041004'));  // hex part not a multiple of 4: invalid, as in pdf.js
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('uni00e9'));     // lower-case hex is rejected, as in pdf.js
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('uniD800'));     // surrogate
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('uni004G'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('uni'));
end;

procedure TPdfGlyphListTests.UNames;
begin
  Assert.AreEqual($1F600, PdfGlyphNameToUnicode('u1F600'));
  Assert.AreEqual($E9, PdfGlyphNameToUnicode('u00E9'));
  Assert.AreEqual($10FFFF, PdfGlyphNameToUnicode('u10FFFF'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('u110000'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('u1f600'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('u12'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('u12345678'));
end;

procedure TPdfGlyphListTests.GlyphIndexNamesAreUnknown;
begin
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('g12'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('g0041'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('G41'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('cid5'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('cid12345'));
end;

procedure TPdfGlyphListTests.Suffixes;
begin
  Assert.AreEqual(65, PdfGlyphNameToUnicode('A.sc'));
  Assert.AreEqual($E9, PdfGlyphNameToUnicode('eacute.alt.2'));
  Assert.AreEqual($E9, PdfGlyphNameToUnicode('uni00E9.case'));
  Assert.AreEqual(0, PdfGlyphNameToUnicode('.notdef'));   // pdf.js lists '.notdef' as U+0000
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('.sc'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('nosuch.sc'));
end;

procedure TPdfGlyphListTests.Ligatures;
begin
  // 'f_f_i' is in pdf.js's glyph list (U+FB03); other underscore ligatures give -1 (not split into components).
  Assert.AreEqual($FB03, PdfGlyphNameToUnicode('f_f_i'));
  Assert.AreEqual($FB01, PdfGlyphNameToUnicode('f_i'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('T_h'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('s_t'));
end;

procedure TPdfGlyphListTests.DecimalCNames;
begin
  Assert.AreEqual(65, PdfGlyphNameToUnicode('C65'));
  Assert.AreEqual(65, PdfGlyphNameToUnicode('c65'));
  Assert.AreEqual(233, PdfGlyphNameToUnicode('c233'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('C0'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('C1A'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('C12345'));
end;

procedure TPdfGlyphListTests.Unknown;
begin
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('nosuchglyph'));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode(''));
  Assert.AreEqual(-1, PdfGlyphNameToUnicode('EACUTE')); // names are case-sensitive
  Assert.AreEqual($61, PdfGlyphNameToUnicode('a'));
end;

procedure TPdfGlyphListTests.Reverse;
begin
  Assert.AreEqual('eacute', PdfUnicodeToGlyphName($E9));
  Assert.AreEqual('A', PdfUnicodeToGlyphName(65));
  Assert.AreEqual('space', PdfUnicodeToGlyphName($20));
  Assert.AreEqual('Euro', PdfUnicodeToGlyphName($20AC));
  Assert.AreEqual('', PdfUnicodeToGlyphName($10FFFF));
  Assert.AreEqual('', PdfUnicodeToGlyphName(-1));
end;

procedure TPdfGlyphListTests.Dingbats;
begin
  Assert.AreEqual($2701, PdfDingbatsGlyphNameToUnicode('a1'));
  Assert.AreEqual($20, PdfDingbatsGlyphNameToUnicode('space'));
  Assert.AreEqual(-1, PdfDingbatsGlyphNameToUnicode('A'));
  Assert.AreEqual(-1, PdfDingbatsGlyphNameToUnicode(''));
end;

{ TPdfStandardFontTests }

procedure CheckFont(const Name: string; Flags: Integer; Expected: TPdfStandardFont; ExpectedResult: Boolean);
var
  Font: TPdfStandardFont;
  R: Boolean;
begin
  R := PdfStandardFontByName(Name, Flags, Font);
  Assert.AreEqual(ExpectedResult, R, Name + ': result');
  Assert.AreEqual(PdfStandardFontName(Expected), PdfStandardFontName(Font), Name + ': font');
end;

procedure TPdfStandardFontTests.StandardNames;
var
  F: TPdfStandardFont;
begin
  for F := Low(TPdfStandardFont) to High(TPdfStandardFont) do
    CheckFont(PdfStandardFontName(F), 0, F, True);
  CheckFont('Times-Roman', 0, sfTimesRoman, True);
  CheckFont('Courier-BoldOblique', 0, sfCourierBoldOblique, True);
  CheckFont('helvetica-bold', 0, sfHelveticaBold, True);
end;

procedure TPdfStandardFontTests.ArialFamily;
begin
  CheckFont('Arial', 0, sfHelvetica, True);
  CheckFont('Arial,Bold', 0, sfHelveticaBold, True);
  CheckFont('ABCDEF+Arial-BoldItalicMT', 0, sfHelveticaBoldOblique, True);
  CheckFont('ArialMT', 0, sfHelvetica, True);
  CheckFont('Arial,Italic', 0, sfHelveticaOblique, True);
  CheckFont('Arial Bold', 0, sfHelveticaBold, True);
  CheckFont('Arial_BoldItalic', 0, sfHelveticaBoldOblique, True);
end;

procedure TPdfStandardFontTests.TimesFamily;
begin
  CheckFont('TimesNewRomanPS-BoldMT', 0, sfTimesBold, True);
  CheckFont('TimesNewRomanPSMT', 0, sfTimesRoman, True);
  CheckFont('TimesNewRoman,BoldItalic', 0, sfTimesBoldItalic, True);
  CheckFont('Times New Roman', 0, sfTimesRoman, True);
end;

procedure TPdfStandardFontTests.CourierFamily;
begin
  CheckFont('CourierNewPSMT', 0, sfCourier, True);
  CheckFont('CourierNew,Bold', 0, sfCourierBold, True);
  CheckFont('Courier-Italic', 0, sfCourierOblique, True);
end;

procedure TPdfStandardFontTests.SymbolicFonts;
begin
  CheckFont('Symbol', 0, sfSymbol, True);
  CheckFont('Symbol,Bold', 0, sfSymbol, True);
  CheckFont('ZapfDingbats', 0, sfZapfDingbats, True);
  CheckFont('Dingbats', 0, sfZapfDingbats, True);
  CheckFont('XYZABC+ZapfDingbats', 0, sfZapfDingbats, True);
end;

procedure TPdfStandardFontTests.FamilyWithStyleWords;
begin
  CheckFont('ArialBold', 0, sfHelveticaBold, True);
  CheckFont('Arial-BoldOblique', 0, sfHelveticaBoldOblique, True);
  CheckFont('HelveticaNeue-Bold', 0, sfHelveticaBold, True);
  CheckFont('TimesNewRomanBold', 0, sfTimesBold, True);
  CheckFont('Times-Bold-Italic', 0, sfTimesBoldItalic, True);
  CheckFont('CourierNewPS-BoldItalicMT', 0, sfCourierBoldOblique, True);
  CheckFont('CourierStd-Bold', 0, sfCourierBold, True);
end;

procedure TPdfStandardFontTests.NonStandardMap;
begin
  CheckFont('Calibri-Bold', 0, sfHelveticaBold, True);
  CheckFont('LucidaConsole', 0, sfCourier, True);
  CheckFont('TrebuchetMS-Italic', 0, sfHelveticaOblique, True);
end;

procedure TPdfStandardFontTests.UnknownNamesGuess;
begin
  CheckFont('Wingdings', 0, sfHelvetica, False);
  CheckFont('Garamond', PdfFontFlagSerif, sfTimesRoman, False);
  CheckFont('Garamond', 0, sfTimesRoman, False);  // pdf.js serif font list
  CheckFont('Consolas', PdfFontFlagFixedPitch, sfCourier, False);
  CheckFont('Verdana-Bold', 0, sfHelveticaBold, False);
  CheckFont('Verdana', PdfFontFlagForceBold or PdfFontFlagItalic, sfHelveticaBoldOblique, False);
  CheckFont('Georgia-Italic', 0, sfTimesItalic, False);
  CheckFont('MinionPro-Semibold', PdfFontFlagSerif, sfTimesBold, False);
  CheckFont('SourceSansPro-Black', 0, sfHelveticaBold, False);
  CheckFont('DejaVuSerif', 0, sfTimesRoman, False);
  CheckFont('MicrosoftSansSerif', 0, sfHelvetica, False);
  CheckFont('Symbola', 0, sfHelvetica, False);
  CheckFont('', 0, sfHelvetica, False);
end;

procedure TPdfStandardFontTests.CanonicalNames;
begin
  Assert.AreEqual('Times-BoldItalic', PdfStandardFontName(sfTimesBoldItalic));
  Assert.AreEqual('Helvetica-BoldOblique', PdfStandardFontName(sfHelveticaBoldOblique));
  Assert.AreEqual('Times-Roman', PdfStandardFontName(sfTimesRoman));
  Assert.AreEqual('ZapfDingbats', PdfStandardFontName(sfZapfDingbats));
end;

procedure TPdfStandardFontTests.Kinds;
var
  F: TPdfStandardFont;
begin
  for F := Low(TPdfStandardFont) to High(TPdfStandardFont) do
  begin
    Assert.AreEqual(F in [sfSymbol, sfZapfDingbats], PdfStandardFontIsSymbolic(F), PdfStandardFontName(F));
    Assert.AreEqual(F <= sfHelveticaBoldOblique, PdfStandardFontIsTrueType(F), PdfStandardFontName(F));
  end;
end;

procedure TPdfStandardFontTests.ResourceData;
const
  // Sizes of the files in Resources/Fonts.
  Sizes: array[TPdfStandardFont] of Integer = (
    139512, 137052, 162036, 135124,
    19469, 19395, 21227, 20733,
    17597, 18055, 18746, 19151, 16729, 29513);
var
  F: TPdfStandardFont;
  Data: TBytes;
begin
  for F := Low(TPdfStandardFont) to High(TPdfStandardFont) do
  begin
    Data := PdfStandardFontData(F);
    Assert.AreEqual(Sizes[F], Integer(Length(Data)), PdfStandardFontName(F) + ' size');
    if PdfStandardFontIsTrueType(F) then
    begin
      Assert.AreEqual(0, Integer(Data[0]), PdfStandardFontName(F));
      Assert.AreEqual(1, Integer(Data[1]), PdfStandardFontName(F));
      Assert.AreEqual(0, Integer(Data[2]), PdfStandardFontName(F));
      Assert.AreEqual(0, Integer(Data[3]), PdfStandardFontName(F));
    end
    else
    begin
      // The Foxit '.pfb' files from pdf.js are bare CFF: major 1, minor 0, header size 4.
      Assert.AreEqual($01, Integer(Data[0]), PdfStandardFontName(F));
      Assert.AreEqual($00, Integer(Data[1]), PdfStandardFontName(F));
      Assert.AreEqual($04, Integer(Data[2]), PdfStandardFontName(F));
    end;
  end;
end;

procedure TPdfStandardFontTests.ResourceDataIsCached;
var
  A, B: TBytes;
begin
  A := PdfStandardFontData(sfCourier);
  B := PdfStandardFontData(sfCourier);
  Assert.IsTrue(Pointer(A) = Pointer(B));
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfEncodingTableTests);
  TDUnitX.RegisterTestFixture(TPdfGlyphListTests);
  TDUnitX.RegisterTestFixture(TPdfStandardFontTests);

end.
