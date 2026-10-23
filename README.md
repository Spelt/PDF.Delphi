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
| 2 | Graphics (`Pdf.Render.Skia`) | nog niet begonnen |
| 3 | Tekst en fonts | nog niet begonnen |
| 4 | Viewer-component (`TPdfViewer`) | nog niet begonnen |
| 5 | Extra's | nog niet begonnen |

Beeldcodecs (DCT, JPX, JBIG2, CCITT) laat `Pdf.Core` bewust ongedecodeerd door
naar de renderer (`IPdfStream.ImageFilter`).

## Omgeving

- Delphi 13.1 (Studio 37.0). `Pdf.Core` gebruikt alleen de RTL
  (`System.ZLib`, `System.Hash`, generics) en compileert voor alle platformen.
- Tests: DUnitX zoals meegeleverd met Delphi (`$(BDS)\source\DUnitX`).

## Indeling

```
Source/Core/        Pdf.Core.* units (geen Skia, geen FMX)
Packages/           PdfCore.dpk / .dproj (runtime package, alle platformen)
Tests/              Pdf.Tests.dpr / .dproj (DUnitX console) en Pdf.Tests.*.pas
Tests/Data/         kleine testbestanden, o.a. versleutelde PDF's + generator
Tests/Corpus/       (leeg) eigen test-PDF's; wordt door Pdf.Tests.Corpus gelezen
Build/dcc.sh        commandline-build met dcc64 vanuit Git Bash
```

## Bouwen en testen

Vanuit de IDE: open `Tests\Pdf.Tests.dproj` of `Packages\PdfCore.dproj`.

Vanaf de commandline (Git Bash, Win64):

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
