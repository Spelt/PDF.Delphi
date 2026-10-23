# Pdf.Delphi — FMX PDF Viewer

Een eigen PDF-renderer in Delphi die op alle FMX-platformen identiek rendert.
Skia doet het tekenwerk, de parser en interpreter zijn eigen code. pdf.js
(Apache 2.0) is de leidraad voor structuur en edge cases; zie `NOTICE`.

Het projectplan (fasen, teststrategie, risico's) staat in het Claude-document
"FMX PDF Viewer — Projectplan".

## Status

| Fase | Onderdeel | Status |
|---|---|---|
| 1 | Parser (`Pdf.Core`) | **Klaar**: lexer, objectmodel, xref (tabellen, streams, `/Prev`, `/XRefStm`, object streams), herstel door scannen, filters (Flate, LZW, ASCII85, ASCIIHex, RunLength, PNG/TIFF-predictors), standaard security handler (RC4 40/128, AES-128, AES-256 / R2–R6), document en paginaboom met overerving |
| 2 | Graphics (`Pdf.Render.Skia`) | **Klaar**: content-stream-interpreter met inline images, graphics state (`q`/`Q`, CTM, lijnparameters, dash, ExtGState alpha en blend modes), paden met nonzero/even-odd vullen, stroken en clippen, kleurruimtes (Device*, Cal*, Lab, ICCBased, Indexed, Separation, DeviceN, Pattern), functies type 0/2/3/4, images (1–16 bpc, Decode, ImageMask, SMask, Mask, DCT via Skia), form XObjects met transparency groups, shadings type 1–3, shading- en tiling-patronen. Tekst wordt gevolgd maar nog niet getekend (optionele plaatshouderkaders) |
| 3 | Tekst en fonts (`Pdf.Font.*`) | **Klaar**: eigen parsers voor TrueType (glyf, cmap, post), CFF/Type2 (incl. CID-keyed) en Type1 (eexec, flex, seac); glyphs worden als paden getekend, dus geen platform-fontmanager en identieke uitvoer op elk platform. Fontloader met encodings (Standard, WinAnsi, MacRoman, Symbol, ZapfDingbats, Differences), Adobe Glyph List, widths, Type0 met embedded en voorgedefinieerde CMaps (169 Adobe-CMaps als resource), CIDToGIDMap, verticale metrics, Type3-fonts, standaard-14-substitutie (Liberation Sans en Foxit-fonts uit pdf.js). Render modes 0–7 inclusief tekst-clipping |
| 4 | Viewer-component (`TPdfViewer`) | **Klaar**: FMX-control op `TSkCustomControl` met verticale scroll van alle pagina's, alleen zichtbare pagina's renderen, achtergrondrendering in een eigen thread met prioriteitswachtrij, LRU-cache met geheugenlimiet, eerst de geschaalde oude weergave en daarna scherp, Zoom/FitWidth/FitPage, pinch-to-zoom en dubbeltik, muiswiel (Ctrl = zoom), slepen, scrollbalken, toetsenbord, `GoToPage`, `OnPageChange`, `OnLoadError`, `RenderPageToImage`. Packages `PdfViewerFMX` (runtime) en `PdfViewerFMXDsgn` (designtime), demo-app in `Demo/` |
| 5 | Extra's | **Klaar**: klikbare links (URI, GoTo, GoToR, Named), annotaties via hun appearance streams (met `/AS`-states), bladwijzers (`/Outlines`) en named destinations (`/Dests` en de name tree), soft masks uit ExtGState (alpha en luminosity), tekstextractie met zoeken en selectie (`Pdf.Render.Text`), decoders voor CCITT Fax, JBIG2 en JPEG 2000 (`Pdf.Codec.*`, pure Delphi) en mesh-shadings type 4–7 |

Beeldcodecs (DCT, JPX, JBIG2, CCITT) laat `Pdf.Core` bewust ongedecodeerd door
naar de renderer (`IPdfStream.ImageFilter`); de renderer decodeert DCT via
Skia en de andere drie met de eigen decoders in `Pdf.Codec.*`.

Nog open (bewust): ICC-kleurprofielen (ICCBased valt terug op het aantal
componenten), knockout-groepen, transfer functions (`/TR`), JPX met
arithmetic-coder bypass, en een CJK-substituutfont voor niet-ingebedde
CID-fonts zonder ToUnicode.

## Omgeving

- Delphi 13.1 (Studio 37.0). `Pdf.Core` gebruikt alleen de RTL
  (`System.ZLib`, `System.Hash`, generics) en compileert voor alle platformen.
- Tests: DUnitX zoals meegeleverd met Delphi (`$(BDS)\source\DUnitX`).

## Indeling

```
Source/Core/        Pdf.Core.* units (geen Skia, geen FMX)
Source/Render/      Pdf.Render.* units (System.Skia, geen FMX) en Pdf.Codec.* (CCITT, JBIG2, JPX)
Source/Font/        Pdf.Font.* units: fontprogramma's, encodings, CMaps, loader (geen Skia)
Source/Viewer/      Pdf.Viewer.* (layout, cache, renderthread; geen FMX) en FMX.PdfViewer
Resources/          substituutfonts en CMaps als RCDATA (*.rc, zie Resources/README.md)
Tools/              generator voor de encoding- en glyphlist-tabellen (Node.js)
Packages/           PdfCore, PdfRenderSkia, PdfViewerFMX (runtime) en PdfViewerFMXDsgn (designtime)
Demo/               PdfViewerDemo: FMX-app met openen, bladeren en zoomen
Tests/              Pdf.Tests.dpr / .dproj (DUnitX console) en Pdf.Tests.*.pas
Tests/Data/         kleine testbestanden, o.a. versleutelde PDF's + generator
Tests/Corpus/       (leeg) eigen test-PDF's; wordt door Pdf.Tests.Corpus gelezen
Build/dcc.sh        commandline-build met dcc64 vanuit Git Bash
```

## Bouwen en testen

Vanuit de IDE: open `Tests\Pdf.Tests.dproj` of `Packages\PdfCore.dproj`.

Vanaf de commandline (Git Bash, Win64; de tests hebben `sk4d.dll` uit
`$(BDS)\bin64` naast de exe nodig, `Build/dcc.sh` kopieert die niet; het
script compileert wel eerst `Resources/*.rc` naar `.res` met `brcc32`):

```bash
sh Build/dcc.sh Tests/Pdf.Tests.dpr && Build/out/Pdf.Tests.exe --exitbehavior:Continue
```

### Corpustest

`Pdf.Tests.Corpus` opent elke PDF in `Tests\Corpus` en in de mappen uit de
omgevingsvariabele `PDF_CORPUS_DIRS` (gescheiden door `;`) en leest alle
pagina's. Voor het pdf.js-corpus:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/mozilla/pdf.js.git
cd pdf.js && git sparse-checkout set test/pdfs
```

```bash
PDF_CORPUS_DIRS="C:\pad\naar\pdf.js\test\pdfs" Build/out/Pdf.Tests.exe --exitbehavior:Continue
```

Een bestand slaagt als het zonder exception opent (een wachtwoordfout telt als
geslaagd) en alle pagina-inhoud binnen 20 s gelezen kan worden.
`Pdf.Tests.Render.TPdfRenderCorpusTests` rendert daarnaast de eerste drie
pagina's van elk bestand op 200 px.

## Renderen

```pascal
uses System.Skia, Pdf.Core.Document, Pdf.Render.Skia;

var
  Doc: TPdfDocument;
  Renderer: TPdfPageRenderer;
  Image: ISkImage;
begin
  Doc := TPdfDocument.Create;
  Renderer := TPdfPageRenderer.Create(Doc);
  try
    Doc.LoadFromFile('brochure.pdf');
    Image := Renderer.RenderToImage(Doc.Pages[0], 2.0);   // 144 dpi
    Image.EncodeToFile('pagina1.png');
    // Of op een eigen canvas: Renderer.RenderPage(Page, Canvas, TPdfPageRenderer.PageMatrix(Page, Scale));
    // Renderer.ErrorCount / Errors: operators die een exception gaven (de rest van de pagina gaat door)
  finally
    Renderer.Free;
    Doc.Free;
  end;
end;
```

## Gebruik

```pascal
uses Pdf.Core.Document, Pdf.Core.Objects;

var
  Doc: TPdfDocument;
  Page: TPdfPage;
begin
  Doc := TPdfDocument.Create;
  try
    Doc.LoadFromFile('factuur.pdf');            // optioneel: wachtwoord als 2e parameter
    Writeln(Doc.Version, ' ', Doc.PageCount, ' pagina''s');
    Page := Doc.Pages[0];
    Writeln(Page.MediaBox.Width:0:0, ' x ', Page.MediaBox.Height:0:0, ' rotate ', Page.Rotate);
    // Page.GetContentData: gedecodeerde content stream(s), klaar voor fase 2
    // Page.Resources: /Resources met overerving toegepast
  finally
    Doc.Free;
  end;
end;
```

`Doc.Trailer`, `Doc.Catalog` en `Doc.Resolve(...)` geven toegang tot het ruwe
objectmodel (`IPdfDictionary`, `IPdfArray`, `IPdfStream`, ...). Dictionary's en
arrays lossen indirecte verwijzingen zelf op via `Get(...)`; `GetRaw(...)`
geeft de onopgeloste waarde.

## Viewer-component

Installeer `Packages\PdfViewerFMXDsgn.dproj` (na `PdfCore`, `PdfRenderSkia` en
`PdfViewerFMX`) voor een `TPdfViewer` op het palet "PDF", of maak hem in code:

```pascal
uses FMX.PdfViewer;

Viewer := TPdfViewer.Create(Self);
Viewer.Parent := Self;
Viewer.Align := TAlignLayout.Client;
Viewer.ZoomMode := zmFitWidth;             // of zmFitPage, of Zoom := 1.5
Viewer.OnPageChange := ViewerPageChange;   // (Sender; PageIndex: Integer)
Viewer.LoadFromFile('brochure.pdf');       // optioneel wachtwoord als 2e parameter
Viewer.GoToPage(3);
```

Rendering gebeurt op `Zoom x schermschaal` in een eigen thread; de UI-thread
tekent alleen kant-en-klare `ISkImage`s. `CacheLimitMB` begrenst het geheugen
(standaard 256 MB, op mobiel 96 MB). `RenderPageToImage(Index, Scale)` geeft
een pagina als afbeelding voor thumbnails of export.

Verder in de viewer:

- Links: klikken volgt GoTo-bestemmingen en Named-acties zelf; URI's gaan
  naar `OnOpenURI` (het control start zelf geen browser). `OnLinkClick` kan
  elke actie onderscheppen.
- Bladwijzers: `Outline` (boom van `TPdfOutlineItem`), `GoToOutlineItem`,
  `GoToDestination`; alle navigatiedata zit in `Navigation` (`TPdfNavigation`
  uit `Pdf.Core.Navigation`).
- Tekst: slepen over tekst selecteert (dubbelklik een woord, Ctrl+A de
  pagina), Ctrl+C kopieert, `SelectedText`; `Find(tekst)` markeert alle
  treffers in het document, `FindNext`/`FindPrevious` (F3 / Shift+F3)
  springen ernaartoe, Esc wist. `TextPage(Index)` geeft de geëxtraheerde
  tekst met glyph-posities (`TPdfTextPage` uit `Pdf.Render.Text`).
  Tekstextractie pauzeert de renderthread kort, omdat het objectmodel niet
  thread-safe is.

## Ontwerpkeuzes

- Objecten zijn interfaces (ref-counted). Containers houden een verwijzing
  naar de resolver van het document, zodat `Dict.Get('Pages')` indirecte
  objecten transparant ophaalt. Na `Doc.Close`/`Doc.Free` blijven losse
  objecten geldig, maar verwijzingen lossen op naar `null`.
- Tolerantie boven strictheid: foute `/Length`, ontbrekende `endobj`,
  kapotte xref-offsets, rommel vóór de header, lussen in de paginaboom en
  ontbrekende `/Type`-sleutels worden opgevangen zoals pdf.js dat doet.
- Decryptie gebeurt bij het ophalen van een object; objecten in object
  streams worden niet nogmaals ontsleuteld. Bestanden waarvan alleen
  bijlagen versleuteld zijn (`/AuthEvent /EFOpen`) openen zonder wachtwoord.
- De renderer tekent in gebruikerscoördinaten onder de CTM (`Canvas.Concat`),
  zodat lijndiktes en dash-patronen correct meeschalen; clips worden naar
  apparaatcoördinaten getransformeerd. Tiling-patronen worden eenmalig als
  `ISkPicture` opgenomen en als herhalende shader geschilderd; shading-
  patronen als Skia-gradients met transparante stops voor `/Extend false`.
- Elke operator draait in een eigen try/except: een kapotte operator of
  XObject kost alleen dat element, niet de pagina.
- Fonts: `Pdf.Font.Loader.TPdfFont` vertaalt een fontdictionary naar
  "bytes in, glyphs met breedtes uit" (`Decode`) en levert glyph-outlines in
  tekstruimte (`GetOutline`, gecachet). De renderer maakt daar Skia-paden van
  (cache per font en glyph) en tekent ze onder de tekstmatrix, zodat alle
  render modes, Tz, Ts en clipping met gewone padbewerkingen werken.
  Niet-ingebedde fonts krijgen een standaard-14-substituut op naam en
  descriptor-flags; niet-ingebedde CID-fonts gaan via ToUnicode naar het
  substituut.
