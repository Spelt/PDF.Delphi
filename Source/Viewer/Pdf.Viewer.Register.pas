{*******************************************************************************
  Pdf.Viewer.Register
  Design-time registration of TPdfViewer and TPdfThumbnails (package PdfViewerFMXDsgn).
*******************************************************************************}
unit Pdf.Viewer.Register;

interface

procedure Register;

implementation

uses
  System.Classes, FMX.PdfViewer, FMX.PdfThumbnails;

procedure Register;
begin
  RegisterComponents('PDF', [TPdfViewer, TPdfThumbnails]);
end;

end.
