{ Included in the interface of FMX.PdfViewer and Vcl.PdfViewer: re-exports the viewer types of
  Pdf.Viewer.Controller, so that code using a viewer control only needs the control's unit. }

type
  TPdfZoomMode = Pdf.Viewer.Controller.TPdfZoomMode;
  TPdfPageChangeEvent = Pdf.Viewer.Controller.TPdfPageChangeEvent;
  TPdfLoadErrorEvent = Pdf.Viewer.Controller.TPdfLoadErrorEvent;
  TPdfLinkClickEvent = Pdf.Viewer.Controller.TPdfLinkClickEvent;
  TPdfOpenURIEvent = Pdf.Viewer.Controller.TPdfOpenURIEvent;
  TPdfSearchMatch = Pdf.Viewer.Controller.TPdfSearchMatch;
  TPdfRenderErrorNotify = Pdf.Viewer.Controller.TPdfRenderErrorNotify;
  TPdfDisplayMode = Pdf.Viewer.Controller.TPdfDisplayMode;
  TPdfPasswordEvent = Pdf.Viewer.Controller.TPdfPasswordEvent;
  TPdfViewerChange = Pdf.Viewer.Controller.TPdfViewerChange;
  TPdfViewerChangeEvent = Pdf.Viewer.Controller.TPdfViewerChangeEvent;
  TPdfPageRenderedEvent = Pdf.Viewer.Controller.TPdfPageRenderedEvent;

const
  zmCustom = Pdf.Viewer.Controller.zmCustom;
  zmFitWidth = Pdf.Viewer.Controller.zmFitWidth;
  zmFitPage = Pdf.Viewer.Controller.zmFitPage;
  dmContinuous = Pdf.Viewer.Controller.dmContinuous;
  dmSinglePage = Pdf.Viewer.Controller.dmSinglePage;
  dmFacingContinuous = Pdf.Viewer.Controller.dmFacingContinuous;
  dmFacing = Pdf.Viewer.Controller.dmFacing;
  vcDocument = Pdf.Viewer.Controller.vcDocument;
  vcPage = Pdf.Viewer.Controller.vcPage;
  vcZoom = Pdf.Viewer.Controller.vcZoom;
  vcScroll = Pdf.Viewer.Controller.vcScroll;
  vcRotation = Pdf.Viewer.Controller.vcRotation;
  vcDisplayMode = Pdf.Viewer.Controller.vcDisplayMode;
  vcPageImage = Pdf.Viewer.Controller.vcPageImage;
  vcSelection = Pdf.Viewer.Controller.vcSelection;
  vcSearch = Pdf.Viewer.Controller.vcSearch;
