{*******************************************************************************
  Pdf.Viewer.Register
  Design-time registration of TPdfViewer (package PdfViewerFMXDsgn).
*******************************************************************************}
unit Pdf.Viewer.Register;

interface

procedure Register;

implementation

uses
  System.Classes, FMX.PdfViewer;

procedure Register;
begin
  RegisterComponents('PDF', [TPdfViewer]);
end;

end.
