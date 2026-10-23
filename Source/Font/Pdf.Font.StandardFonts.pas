{*******************************************************************************
  Pdf.Font.StandardFonts
  The standard 14 fonts: mapping a /BaseFont name (and the descriptor flags)
  to one of the 14, and the substitute font programs that replace them when a
  PDF does not embed the font: Liberation Sans (TrueType) for Helvetica/Arial
  and the Foxit fonts for Times, Courier, Symbol and ZapfDingbats, the same
  files pdf.js uses (Resources/PdfFonts.rc, RCDATA). Note: despite their .pfb
  extension the Foxit files are bare CFF font programs (header 01 00 04 02,
  Type1-flavoured CFF with a built-in encoding), not PFB-wrapped Type1.
  The name tables follow pdf.js's standard_fonts.js (getStdFontMap, the part of
  getNonStdFontMap that maps to the 14, getSerifFonts); Apache 2.0, see NOTICE.
*******************************************************************************}
unit Pdf.Font.StandardFonts;

{$R PdfFonts.res}

interface

uses
  System.SysUtils;

type
  /// <summary>The standard 14 fonts of PDF 32000-1 9.6.2.2.</summary>
  TPdfStandardFont = (sfHelvetica, sfHelveticaBold, sfHelveticaOblique, sfHelveticaBoldOblique,
    sfTimesRoman, sfTimesBold, sfTimesItalic, sfTimesBoldItalic,
    sfCourier, sfCourierBold, sfCourierOblique, sfCourierBoldOblique, sfSymbol, sfZapfDingbats);

const
  /// <summary>Font descriptor /Flags bits (PDF 32000-1 table 123).</summary>
  PdfFontFlagFixedPitch = 1;
  PdfFontFlagSerif = 2;
  PdfFontFlagSymbolic = 4;
  PdfFontFlagScript = 8;
  PdfFontFlagNonsymbolic = 32;
  PdfFontFlagItalic = 64;
  PdfFontFlagForceBold = $40000;

/// <summary>Maps a /BaseFont name to one of the standard 14 fonts.</summary>
/// <remarks>A subset prefix ('ABCDEF+') is removed and the name is normalised as pdf.js does (',' and '_' become
/// '-', white space is removed), then looked up case-insensitively in pdf.js's standard font map (Arial*, ArialMT,
/// Helvetica*, TimesNewRoman*, Times-*, CourierNew*, Courier*, Symbol, ZapfDingbats, ...) and in the part of its
/// non-standard map that resolves to the 14 (Calibri, TrebuchetMS, LucidaConsole, ...). Failing that, a known
/// family (Helvetica, Arial, Times, TimesNewRoman, Courier, CourierNew, Symbol, ZapfDingbats, Dingbats) followed
/// only by style words (Bold, Italic, Oblique, Roman, MT, PS, Neue, Narrow, ...) is recognised as well.
/// Returns True for a recognised name. For any other name Font receives a best guess and the result is False:
/// Courier when Flags has FixedPitch, Times when Flags has Serif or the family is one of pdf.js's serif fonts
/// (Garamond, Georgia, ...) or contains 'serif' (not 'sans'), else Helvetica; bold when the name contains
/// 'Bold', 'Black', 'Heavy', 'Semibold' or 'Demi' or Flags has ForceBold; italic when the name contains 'Italic'
/// or 'Oblique' or Flags has Italic.</remarks>
function PdfStandardFontByName(const BaseFont: string; Flags: Integer; out Font: TPdfStandardFont): Boolean;
/// <summary>Font program bytes of the substitute (Liberation Sans TTF for the Helvetica family, the Foxit fonts
/// for the rest: bare CFF, despite their .pfb file names), loaded from the RCDATA resources in PdfFonts.res and
/// cached after the first load.</summary>
/// <remarks>Thread-safe. The returned array is shared with the cache: do not modify it.</remarks>
function PdfStandardFontData(Font: TPdfStandardFont): TBytes;
/// <summary>True for Symbol and ZapfDingbats.</summary>
function PdfStandardFontIsSymbolic(Font: TPdfStandardFont): Boolean;
/// <summary>True when the substitute program is a TrueType font (Helvetica family), False for the Foxit fonts
/// (bare CFF programs, parse them with the CFF parser).</summary>
function PdfStandardFontIsTrueType(Font: TPdfStandardFont): Boolean;
/// <summary>Canonical PostScript name ('Helvetica-BoldOblique', 'Times-Roman', ...).</summary>
function PdfStandardFontName(Font: TPdfStandardFont): string;
/// <summary>Name of the RCDATA resource holding the substitute program ('PDFFONT_LIBERATIONSANS_REGULAR', ...).</summary>
function PdfStandardFontResourceName(Font: TPdfStandardFont): string;

implementation

uses
  System.Classes, System.Types, System.SyncObjs;

type
  TStdFontMapEntry = record
    Name: string;
    Font: TPdfStandardFont;
  end;

  TFamily = (fmHelvetica, fmTimes, fmCourier);

const
  StdFontNames: array[TPdfStandardFont] of string = (
    'Helvetica', 'Helvetica-Bold', 'Helvetica-Oblique', 'Helvetica-BoldOblique',
    'Times-Roman', 'Times-Bold', 'Times-Italic', 'Times-BoldItalic',
    'Courier', 'Courier-Bold', 'Courier-Oblique', 'Courier-BoldOblique', 'Symbol', 'ZapfDingbats');

  StdFontResources: array[TPdfStandardFont] of string = (
    'PDFFONT_LIBERATIONSANS_REGULAR', 'PDFFONT_LIBERATIONSANS_BOLD', 'PDFFONT_LIBERATIONSANS_ITALIC',
    'PDFFONT_LIBERATIONSANS_BOLDITALIC',
    'PDFFONT_FOXITSERIF', 'PDFFONT_FOXITSERIFBOLD', 'PDFFONT_FOXITSERIFITALIC', 'PDFFONT_FOXITSERIFBOLDITALIC',
    'PDFFONT_FOXITFIXED', 'PDFFONT_FOXITFIXEDBOLD', 'PDFFONT_FOXITFIXEDITALIC', 'PDFFONT_FOXITFIXEDBOLDITALIC',
    'PDFFONT_FOXITSYMBOL', 'PDFFONT_FOXITDINGBATS');

  /// <summary>pdf.js getStdFontMap, followed by the getNonStdFontMap entries that resolve to one of the 14.</summary>
  StdFontMap: array[0..101] of TStdFontMapEntry = (
    // getStdFontMap: the standard 14
    (Name: 'Times-Roman'; Font: sfTimesRoman), (Name: 'Helvetica'; Font: sfHelvetica),
    (Name: 'Courier'; Font: sfCourier), (Name: 'Symbol'; Font: sfSymbol),
    (Name: 'Times-Bold'; Font: sfTimesBold), (Name: 'Helvetica-Bold'; Font: sfHelveticaBold),
    (Name: 'Courier-Bold'; Font: sfCourierBold), (Name: 'ZapfDingbats'; Font: sfZapfDingbats),
    (Name: 'Times-Italic'; Font: sfTimesItalic), (Name: 'Helvetica-Oblique'; Font: sfHelveticaOblique),
    (Name: 'Courier-Oblique'; Font: sfCourierOblique), (Name: 'Times-BoldItalic'; Font: sfTimesBoldItalic),
    (Name: 'Helvetica-BoldOblique'; Font: sfHelveticaBoldOblique), (Name: 'Courier-BoldOblique'; Font: sfCourierBoldOblique),
    // getStdFontMap: extra mappings
    (Name: 'ArialNarrow'; Font: sfHelvetica), (Name: 'ArialNarrow-Bold'; Font: sfHelveticaBold),
    (Name: 'ArialNarrow-BoldItalic'; Font: sfHelveticaBoldOblique), (Name: 'ArialNarrow-Italic'; Font: sfHelveticaOblique),
    (Name: 'ArialBlack'; Font: sfHelvetica), (Name: 'ArialBlack-Bold'; Font: sfHelveticaBold),
    (Name: 'ArialBlack-BoldItalic'; Font: sfHelveticaBoldOblique), (Name: 'ArialBlack-Italic'; Font: sfHelveticaOblique),
    (Name: 'Arial-Black'; Font: sfHelvetica), (Name: 'Arial-Black-Bold'; Font: sfHelveticaBold),
    (Name: 'Arial-Black-BoldItalic'; Font: sfHelveticaBoldOblique), (Name: 'Arial-Black-Italic'; Font: sfHelveticaOblique),
    (Name: 'Arial'; Font: sfHelvetica), (Name: 'Arial-Bold'; Font: sfHelveticaBold),
    (Name: 'Arial-BoldItalic'; Font: sfHelveticaBoldOblique), (Name: 'Arial-Italic'; Font: sfHelveticaOblique),
    (Name: 'ArialMT'; Font: sfHelvetica), (Name: 'Arial-BoldItalicMT'; Font: sfHelveticaBoldOblique),
    (Name: 'Arial-BoldMT'; Font: sfHelveticaBold), (Name: 'Arial-ItalicMT'; Font: sfHelveticaOblique),
    (Name: 'Arial-BoldItalicMT-BoldItalic'; Font: sfHelveticaBoldOblique), (Name: 'Arial-BoldMT-Bold'; Font: sfHelveticaBold),
    (Name: 'Arial-ItalicMT-Italic'; Font: sfHelveticaOblique), (Name: 'ArialUnicodeMS'; Font: sfHelvetica),
    (Name: 'ArialUnicodeMS-Bold'; Font: sfHelveticaBold), (Name: 'ArialUnicodeMS-BoldItalic'; Font: sfHelveticaBoldOblique),
    (Name: 'ArialUnicodeMS-Italic'; Font: sfHelveticaOblique), (Name: 'Courier-BoldItalic'; Font: sfCourierBoldOblique),
    (Name: 'Courier-Italic'; Font: sfCourierOblique), (Name: 'CourierNew'; Font: sfCourier),
    (Name: 'CourierNew-Bold'; Font: sfCourierBold), (Name: 'CourierNew-BoldItalic'; Font: sfCourierBoldOblique),
    (Name: 'CourierNew-Italic'; Font: sfCourierOblique), (Name: 'CourierNewPS-BoldItalicMT'; Font: sfCourierBoldOblique),
    (Name: 'CourierNewPS-BoldMT'; Font: sfCourierBold), (Name: 'CourierNewPS-ItalicMT'; Font: sfCourierOblique),
    (Name: 'CourierNewPSMT'; Font: sfCourier), (Name: 'Helvetica-BoldItalic'; Font: sfHelveticaBoldOblique),
    (Name: 'Helvetica-Italic'; Font: sfHelveticaOblique), (Name: 'HelveticaLTStd-Bold'; Font: sfHelveticaBold),
    (Name: 'Symbol-Bold'; Font: sfSymbol), (Name: 'Symbol-BoldItalic'; Font: sfSymbol),
    (Name: 'Symbol-Italic'; Font: sfSymbol), (Name: 'TimesNewRoman'; Font: sfTimesRoman),
    (Name: 'TimesNewRoman-Bold'; Font: sfTimesBold), (Name: 'TimesNewRoman-BoldItalic'; Font: sfTimesBoldItalic),
    (Name: 'TimesNewRoman-Italic'; Font: sfTimesItalic), (Name: 'TimesNewRomanPS'; Font: sfTimesRoman),
    (Name: 'TimesNewRomanPS-Bold'; Font: sfTimesBold), (Name: 'TimesNewRomanPS-BoldItalic'; Font: sfTimesBoldItalic),
    (Name: 'TimesNewRomanPS-BoldItalicMT'; Font: sfTimesBoldItalic), (Name: 'TimesNewRomanPS-BoldMT'; Font: sfTimesBold),
    (Name: 'TimesNewRomanPS-Italic'; Font: sfTimesItalic), (Name: 'TimesNewRomanPS-ItalicMT'; Font: sfTimesItalic),
    (Name: 'TimesNewRomanPSMT'; Font: sfTimesRoman), (Name: 'TimesNewRomanPSMT-Bold'; Font: sfTimesBold),
    (Name: 'TimesNewRomanPSMT-BoldItalic'; Font: sfTimesBoldItalic), (Name: 'TimesNewRomanPSMT-Italic'; Font: sfTimesItalic),
    // getNonStdFontMap, entries that resolve to the 14
    (Name: 'Calibri'; Font: sfHelvetica), (Name: 'Calibri-Bold'; Font: sfHelveticaBold),
    (Name: 'Calibri-BoldItalic'; Font: sfHelveticaBoldOblique), (Name: 'Calibri-Italic'; Font: sfHelveticaOblique),
    (Name: 'CenturyGothic'; Font: sfHelvetica), (Name: 'CenturyGothic-Bold'; Font: sfHelveticaBold),
    (Name: 'CenturyGothic-BoldItalic'; Font: sfHelveticaBoldOblique), (Name: 'CenturyGothic-Italic'; Font: sfHelveticaOblique),
    (Name: 'GillSansMT'; Font: sfHelvetica), (Name: 'GillSansMT-Bold'; Font: sfHelveticaBold),
    (Name: 'GillSansMT-BoldItalic'; Font: sfHelveticaBoldOblique), (Name: 'GillSansMT-Italic'; Font: sfHelveticaOblique),
    (Name: 'Impact'; Font: sfHelvetica), (Name: 'ItcSymbol-Bold'; Font: sfHelveticaBold),
    (Name: 'ItcSymbol-BoldItalic'; Font: sfHelveticaBoldOblique), (Name: 'ItcSymbol-Book'; Font: sfHelvetica),
    (Name: 'ItcSymbol-BookItalic'; Font: sfHelveticaOblique), (Name: 'ItcSymbol-Medium'; Font: sfHelvetica),
    (Name: 'ItcSymbol-MediumItalic'; Font: sfHelveticaOblique), (Name: 'LucidaConsole'; Font: sfCourier),
    (Name: 'LucidaConsole-Bold'; Font: sfCourierBold), (Name: 'LucidaConsole-BoldItalic'; Font: sfCourierBoldOblique),
    (Name: 'LucidaConsole-Italic'; Font: sfCourierOblique), (Name: 'LucidaSans-Demi'; Font: sfHelveticaBold),
    (Name: 'NuptialScript'; Font: sfTimesItalic), (Name: 'SegoeUISymbol'; Font: sfHelvetica),
    (Name: 'TrebuchetMS'; Font: sfHelvetica), (Name: 'TrebuchetMS-Bold'; Font: sfHelveticaBold),
    (Name: 'TrebuchetMS-BoldItalic'; Font: sfHelveticaBoldOblique), (Name: 'TrebuchetMS-Italic'; Font: sfHelveticaOblique)
  );

  /// <summary>pdf.js getSerifFonts, lower case with white space removed (compared against the family part of the
  /// normalised name).</summary>
  SerifFonts: array[0..133] of string = (
    'adobejenson', 'adobetext', 'albertus', 'aldus', 'alexandria', 'algerian', 'americantypewriter', 'antiqua', 'apex',
    'arno', 'aster', 'aurora', 'baskerville', 'bell', 'bembo', 'bemboschoolbook', 'benguiat', 'berkeleyoldstyle',
    'bernhardmodern', 'bertholdcity', 'bodoni', 'bauerbodoni', 'bookantiqua', 'bookman', 'bordeauxroman',
    'californianfb', 'calisto', 'calvert', 'capitals', 'cambria', 'cartier', 'caslon', 'catull', 'centaur',
    'centuryoldstyle', 'centuryschoolbook', 'chaparral', 'charissil', 'cheltenham', 'chollaslab', 'clarendon',
    'clearface', 'cochin', 'colonna', 'computermodern', 'concreteroman', 'constantia', 'cooperblack', 'corona',
    'ecotype', 'egyptienne', 'elephant', 'excelsior', 'fairfield', 'ffscala', 'folkard', 'footlight', 'freeserif',
    'frizquadrata', 'garamond', 'gentium', 'georgia', 'gloucester', 'goudyoldstyle', 'goudyschoolbook',
    'goudyprofont', 'granjon', 'guardianegyptian', 'heather', 'hercules', 'hightowertext', 'hiroshige', 'hoeflertext',
    'humanaserif', 'imprint', 'ionicno.5', 'janson', 'joanna', 'korinna', 'lexicon', 'liberationserif',
    'liberationserif', 'linuxlibertine', 'literaturnaya', 'lucida', 'lucidabright', 'melior', 'memphis', 'miller',
    'minion', 'modern', 'monalisa', 'mrseaves', 'msserif', 'museoslab', 'newyork', 'nimbusroman',
    'npsrawlinsonroadway', 'nuptialscript', 'palatino', 'perpetua', 'plantin', 'plantinschoolbook', 'playbill',
    'poorrichard', 'rawlinsonroadway', 'renault', 'requiem', 'rockwell', 'roman', 'rotisserif', 'sabon', 'scala',
    'seagull', 'sistina', 'souvenir', 'stix', 'stoneinformal', 'stoneserif', 'sylfaen', 'times', 'trajan',
    'trinit'#$E9, 'trumpmediaeval', 'utopia', 'valetype', 'bitstreamvera', 'veraserif', 'versailles', 'wanted',
    'weiss', 'widelatin', 'windsor', 'xits'
  );

  /// <summary>Family prefixes (lower case, no separators) recognised in front of style words; longest first.</summary>
  FamilyPrefixes: array[0..16] of TStdFontMapEntry = (
    (Name: 'timesnewroman'; Font: sfTimesRoman), (Name: 'timesroman'; Font: sfTimesRoman),
    (Name: 'times'; Font: sfTimesRoman), (Name: 'couriernew'; Font: sfCourier), (Name: 'courier'; Font: sfCourier),
    (Name: 'helvetica'; Font: sfHelvetica), (Name: 'arialunicodems'; Font: sfHelvetica),
    (Name: 'arialnarrow'; Font: sfHelvetica), (Name: 'arialblack'; Font: sfHelvetica), (Name: 'arialmt'; Font: sfHelvetica),
    (Name: 'arial'; Font: sfHelvetica), (Name: 'zapfdingbats'; Font: sfZapfDingbats),
    (Name: 'itczapfdingbats'; Font: sfZapfDingbats), (Name: 'dingbats'; Font: sfZapfDingbats),
    (Name: 'symbolmt'; Font: sfSymbol), (Name: 'symbol'; Font: sfSymbol), (Name: 'nimbussans'; Font: sfHelvetica)
  );

  /// <summary>Words allowed after a family prefix (lower case); matched greedily, longest first.</summary>
  StyleWords: array[0..28] of string = (
    'semibold', 'demibold', 'extrabold', 'ultrabold', 'boldoblique', 'bolditalic', 'oblique', 'italic', 'regular',
    'condensed', 'narrow', 'normal', 'medium', 'roman', 'black', 'heavy', 'light', 'bold', 'demi', 'book', 'neue',
    'cond', 'psmt', 'std', 'pro', 'mt', 'ps', 'lt', 'it'
  );

var
  FontDataLock: TCriticalSection;
  FontDataCache: array[TPdfStandardFont] of TBytes;

function PdfStandardFontName(Font: TPdfStandardFont): string;
begin
  Result := StdFontNames[Font];
end;

function PdfStandardFontResourceName(Font: TPdfStandardFont): string;
begin
  Result := StdFontResources[Font];
end;

function PdfStandardFontIsSymbolic(Font: TPdfStandardFont): Boolean;
begin
  Result := Font in [sfSymbol, sfZapfDingbats];
end;

function PdfStandardFontIsTrueType(Font: TPdfStandardFont): Boolean;
begin
  Result := Font in [sfHelvetica, sfHelveticaBold, sfHelveticaOblique, sfHelveticaBoldOblique];
end;

/// <summary>pdf.js normalizeFontName: ',' and '_' become '-', white space is removed.</summary>
function NormalizeFontName(const Name: string): string;
var
  Ch: Char;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create(Length(Name));
  try
    for Ch in Name do
      case Ch of
        ',', '_': SB.Append('-');
        #0..' ': ;
      else
        SB.Append(Ch);
      end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

/// <summary>Lower case with '-' removed.</summary>
function CompactName(const Normalized: string): string;
begin
  Result := LowerCase(StringReplace(Normalized, '-', '', [rfReplaceAll]));
end;

/// <summary>True when S consists only of words from StyleWords (or is empty).</summary>
function OnlyStyleWords(const S: string): Boolean;
var
  P, I: Integer;
  Matched: Boolean;
begin
  P := 1;
  while P <= Length(S) do
  begin
    Matched := False;
    for I := Low(StyleWords) to High(StyleWords) do
      if Copy(S, P, Length(StyleWords[I])) = StyleWords[I] then
      begin
        Inc(P, Length(StyleWords[I]));
        Matched := True;
        Break;
      end;
    if not Matched then
      Exit(False);
  end;
  Result := True;
end;

function NameIsBold(const Lower: string): Boolean;
begin
  Result := (Pos('bold', Lower) > 0) or (Pos('black', Lower) > 0) or (Pos('heavy', Lower) > 0) or
    (Pos('demi', Lower) > 0);
end;

function NameIsItalic(const Lower: string): Boolean;
begin
  Result := (Pos('italic', Lower) > 0) or (Pos('oblique', Lower) > 0);
end;

function Compose(Family: TFamily; Bold, Italic: Boolean): TPdfStandardFont;
const
  Fonts: array[TFamily, Boolean, Boolean] of TPdfStandardFont = (
    ((sfHelvetica, sfHelveticaOblique), (sfHelveticaBold, sfHelveticaBoldOblique)),
    ((sfTimesRoman, sfTimesItalic), (sfTimesBold, sfTimesBoldItalic)),
    ((sfCourier, sfCourierOblique), (sfCourierBold, sfCourierBoldOblique)));
begin
  Result := Fonts[Family, Bold, Italic];
end;

function IsSerifName(const Normalized: string): Boolean;
var
  Family: string;
  P, I: Integer;
begin
  Family := LowerCase(Normalized);
  P := Pos('-', Family);
  if P > 0 then
    Family := Copy(Family, 1, P - 1);
  for I := Low(SerifFonts) to High(SerifFonts) do
    if Family = SerifFonts[I] then
      Exit(True);
  Result := (Pos('serif', Family) > 0) and (Pos('sans', Family) = 0);
end;

function PdfStandardFontByName(const BaseFont: string; Flags: Integer; out Font: TPdfStandardFont): Boolean;
var
  Name, Normalized, Compact, Rest: string;
  P, I: Integer;
  Family: TFamily;
  Bold, Italic: Boolean;
begin
  Name := BaseFont;
  P := Name.LastIndexOf('+');
  if P >= 0 then
    Name := Name.Substring(P + 1);
  Normalized := NormalizeFontName(Name);

  // 1. pdf.js's standard and non-standard font maps.
  for I := Low(StdFontMap) to High(StdFontMap) do
    if SameText(StdFontMap[I].Name, Normalized) then
    begin
      Font := StdFontMap[I].Font;
      Exit(True);
    end;

  // 2. A known family followed only by style words ('Arial-BoldOblique', 'TimesNewRomanBold', 'HelveticaNeue').
  Compact := CompactName(Normalized);
  for I := Low(FamilyPrefixes) to High(FamilyPrefixes) do
    if Compact.StartsWith(FamilyPrefixes[I].Name) then
    begin
      Rest := Compact.Substring(Length(FamilyPrefixes[I].Name));
      if not OnlyStyleWords(Rest) then
        Continue;
      Font := FamilyPrefixes[I].Font;
      if not PdfStandardFontIsSymbolic(Font) then
      begin
        case Font of
          sfTimesRoman: Family := fmTimes;
          sfCourier: Family := fmCourier;
        else
          Family := fmHelvetica;
        end;
        Font := Compose(Family, NameIsBold(Rest), NameIsItalic(Rest));
      end;
      Exit(True);
    end;

  // 3. Unknown: guess from the descriptor flags and the name.
  if Flags and PdfFontFlagFixedPitch <> 0 then
    Family := fmCourier
  else if (Flags and PdfFontFlagSerif <> 0) or IsSerifName(Normalized) then
    Family := fmTimes
  else
    Family := fmHelvetica;
  Bold := NameIsBold(Compact) or (Flags and PdfFontFlagForceBold <> 0);
  Italic := NameIsItalic(Compact) or (Flags and PdfFontFlagItalic <> 0);
  Font := Compose(Family, Bold, Italic);
  Result := False;
end;

function PdfStandardFontData(Font: TPdfStandardFont): TBytes;
var
  Stream: TResourceStream;
  Data: TBytes;
begin
  FontDataLock.Enter;
  try
    Result := FontDataCache[Font];
  finally
    FontDataLock.Leave;
  end;
  if Result <> nil then
    Exit;
  Stream := TResourceStream.Create(HInstance, StdFontResources[Font], RT_RCDATA);
  try
    SetLength(Data, Stream.Size);
    if Length(Data) > 0 then
      Stream.ReadBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
  FontDataLock.Enter;
  try
    if FontDataCache[Font] = nil then
      FontDataCache[Font] := Data;
    Result := FontDataCache[Font];
  finally
    FontDataLock.Leave;
  end;
end;

initialization
  FontDataLock := TCriticalSection.Create;

finalization
  FontDataLock.Free;

end.
