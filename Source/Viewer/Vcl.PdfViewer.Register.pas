{*******************************************************************************
  Vcl.PdfViewer.Register
  Design-time registration of TPdfViewer and TPdfThumbnails (package PdfViewerVCLDsgn).
*******************************************************************************}
unit Vcl.PdfViewer.Register;

interface

procedure Register;

implementation

uses
  System.Classes, Vcl.PdfViewer, Vcl.PdfThumbnails;

procedure Register;
begin
  RegisterComponents('PDF', [TPdfViewer, TPdfThumbnails]);
end;

end.
