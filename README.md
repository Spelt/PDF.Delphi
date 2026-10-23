# Pdf.Delphi — FMX PDF Viewer

A PDF renderer written in Delphi that renders identically on every FMX
platform. Skia does the drawing; the parser, the graphics interpreter and the
font engine are our own code, with no native third-party libraries. pdf.js
(Apache 2.0) served as the reference for structure and edge cases; see
`NOTICE`.

What is covered: the full PDF object model with damaged-file recovery and
encryption (RC4, AES-128/256); paths, clipping, colour spaces, functions,
images, shadings (including meshes) and patterns; text with embedded TrueType,
CFF and Type1 fonts parsed by the library itself and drawn as outlines, plus
substitutes for the standard 14 fonts; CCITT, JBIG2 and JPEG 2000 decoders;
annotations, links, bookmarks, soft masks; text extraction, search and
selection; and `TPdfViewer`, a viewer control with background rendering and
a page cache, for FMX and for the VCL.

Not covered yet, on purpose: ICC colour management (ICCBased falls back to
the component count), knockout groups, transfer functions (`/TR`), JPEG 2000
with the arithmetic-coder bypass mode, and a CJK substitute font for
non-embedded CID fonts without a ToUnicode map.

## Requirements

- Delphi 13.1 (Studio 37.0) with the bundled Skia (`System.Skia`, `FMX.Skia`,
  `Vcl.Skia`). `Pdf.Core` and `Pdf.Font` use only the RTL and compile for
  every platform; `Pdf.Render` and the framework-independent viewer logic
  (`Pdf.Viewer.*`) add `System.Skia`; only `FMX.Pdf*` depends on FMX and only
  `Vcl.Pdf*` on the VCL.
- Packages: `PdfEngine` (parser, fonts, renderer and viewer logic; RTL and
  Skia only), `PdfViewerFMX` and `PdfViewerVCL` (the controls, both on top of
  `PdfEngine`), and the design-time packages `PdfViewerFMXDsgn` and
  `PdfViewerVCLDsgn`. Both design-time packages can be installed side by side.
- Tests: DUnitX as shipped with Delphi (`$(BDS)\source\DUnitX`).

## Building and testing

From the IDE: open `Packages\PdfDelphi.groupproj` (the five packages), or
the individual projects `Tests\Pdf.Tests.dproj`, `Demo\PdfViewerDemo.dproj`
(FMX) and `DemoVCL\PdfViewerVclDemo.dproj` (VCL).

From the command line (Git Bash, Win64). The script compiles
`Resources/*.rc` to `.res` with `brcc32` first; the test executable needs
`sk4d.dll` from `$(BDS)\bin64` next to it, which the script does not copy:

```bash
sh Build/dcc.sh Tests/Pdf.Tests.dpr && Build/out/Pdf.Tests.exe --exitbehavior:Continue
```

The demo application:

```bash
sh Build/demo.sh && Build/out/PdfViewerDemo.exe some.pdf
```

The corpus tests (`Pdf.Tests.Corpus` and `Pdf.Tests.Render`) read every PDF
from the folders named in the environment variable `PDF_CORPUS_DIRS`
(separated by `;`) and from `Tests\Corpus`; point it at a checkout of
pdf.js's `test/pdfs` for the full run.

## Usage

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

`Doc.Trailer`, `Doc.Catalog` and `Doc.Resolve(...)` give access to the raw
object model (`IPdfDictionary`, `IPdfArray`, `IPdfStream`, ...). Dictionaries
and arrays resolve indirect references themselves through `Get(...)`;
`GetRaw(...)` returns the unresolved value.

## Rendering

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

Every operator runs inside its own exception handler: a broken operator or
XObject costs only that element, never the page. Text extraction lives in
`Pdf.Render.Text` (`TPdfTextPage.Extract`), navigation data (destinations,
outline, annotations) in `Pdf.Core.Navigation` (`TPdfNavigation`).

## Viewer component

Build `PdfEngine` and `PdfViewerFMX`, then install
`Packages\PdfViewerFMXDsgn.dproj` to get `TPdfViewer` and `TPdfThumbnails` on
the "PDF" palette page, or create the viewer in code:

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

Pages are rendered at `Zoom x screen scale` on a background thread; the UI
thread only draws finished `ISkImage`s and shows the nearest cached rendition
scaled while a sharp one is pending. `CacheLimitMB` bounds the memory
(256 MB by default, 96 MB on mobile). `RenderPageToImage(Index, Scale)`
returns a page as an image for thumbnails or export.

Further viewer features:

- Layout: `DisplayMode` chooses continuous or one-row-at-a-time scrolling,
  with single or facing pages (`FacingCoverPage` keeps the first page alone);
  `Rotation` (0, 90, 180, 270) rotates the whole view on top of each page's
  own `/Rotate`. `RowPages` returns the pages shown side by side.
- Encrypted files: `OnPasswordRequest` asks the application for a password
  and retries; without a handler the load fails with `EPdfPasswordError`.
- Companion controls: `AddChangeListener` reports document, page, zoom,
  scroll, rotation, layout, selection, search and rendered-image changes;
  `RequestPageImage` / `TryGetPageImage` render through the viewer's own
  background queue and cache. `TPdfThumbnails` (`FMX.PdfThumbnails`) uses
  these for a thumbnail strip that follows and navigates a `TPdfViewer`.
- Links: clicks follow GoTo destinations and Named actions directly; URIs go
  to `OnOpenURI` (the control never launches a browser itself). `OnLinkClick`
  can intercept any action.
- Bookmarks: `Outline` (a tree of `TPdfOutlineItem`), `GoToOutlineItem`,
  `GoToDestination`; all navigation data is available through `Navigation`.
- Text: dragging over text selects it (double-click a word, Ctrl+A the page),
  Ctrl+C copies, `SelectedText`; `Find(text)` highlights every match in the
  document, `FindNext`/`FindPrevious` (F3 / Shift+F3) jump to them, Esc
  clears. `TextPage(Index)` returns the extracted text with glyph positions.
  Text extraction briefly pauses the render thread, because the object model
  is not thread-safe. `SearchMatch(I)` and `GoToMatch(I)` expose the results
  for a result list.
- Input: mouse wheel scrolls (Ctrl+wheel zooms, Shift+wheel scrolls
  horizontally), drag pans, pinch and double-tap zoom on touch devices,
  keyboard navigation with the arrow, page and home/end keys, `+`/`-`/`0`.

### VCL

`Vcl.PdfViewer` and `Vcl.PdfThumbnails` offer the same `TPdfViewer` and
`TPdfThumbnails` for VCL applications, with the same properties, methods and
events; install `Packages\PdfViewerVCLDsgn.dproj` (after `PdfEngine` and
`PdfViewerVCL`) for the palette. They are windowed controls drawn with
`Vcl.Skia` and use native scroll bars. Coordinates in the API (`ZoomAt`,
`PageAtPoint`, `PointToPage`) are logical pixels, i.e. client pixels divided
by `ScaleFactor`; give the application a PerMonitorV2 manifest so pages are
rendered at the monitor's resolution. Pinch zoom works on touch screens;
double-tap zoom is FMX only.

Both frameworks share `TPdfViewerController` (`Pdf.Viewer.Controller`) and
`TPdfThumbnailsController`: all behaviour (layout, zoom, scrolling, selection,
search, links, drawing on an `ISkCanvas`) lives there, and the controls only
forward input and paint requests through `IPdfControlHost`. The shared API is
declared once in `Pdf.Viewer.ApiDecl.inc`/`Pdf.Viewer.ApiImpl.inc`; viewer
types such as `TPdfDisplayMode` are re-exported by both control units.

## Demo

`Demo\PdfViewerDemo.dproj` is a complete viewer built on the two controls,
with everything placed at design time: an icon toolbar with page field and
zoom slider, a sidebar with thumbnails, bookmarks, search results and
document properties, a status bar, light and dark theme (the dark theme is
the `Dark.style` that ships with Delphi, embedded as a resource), drag and
drop, recent files, rotation and page-layout modes, PNG export, clipboard
(page image and text), printing, a password prompt and a keyboard-shortcut
overlay (F1). Settings persist in `%APPDATA%\PdfViewerDemo\settings.ini`.

`DemoVCL\PdfViewerVclDemo.dproj` is a small VCL counterpart: a toolbar
(open, page navigation, zoom, fit width/page, rotate, search), a thumbnail
strip and the viewer, placed at design time (install `PdfViewerVCLDsgn`
first). Files open from the button, Ctrl+O, drag and drop or the command
line.
