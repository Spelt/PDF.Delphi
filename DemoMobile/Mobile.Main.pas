unit Mobile.Main;

{ Minimal mobile demo for TPdfViewer (Android and iOS; also runs on the desktop): shows the PDF that is
  embedded as a resource (MobileDemo.rc), with pinch to zoom, double tap, dragging and page buttons.
  The viewer is placed at design time (install Packages\PdfViewerFMXDsgn first). }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.StdCtrls, FMX.Controls.Presentation,
  FMX.PdfViewer, System.Skia, FMX.Skia;

type
  TMainForm = class(TForm)
    TopBar: TToolBar;
    TitleLabel: TLabel;
    FitButton: TSpeedButton;
    BottomBar: TToolBar;
    PrevButton: TSpeedButton;
    PageLabel: TLabel;
    NextButton: TSpeedButton;
    Viewer: TPdfViewer;
    procedure FormCreate(Sender: TObject);
    procedure FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF);
    procedure FitButtonClick(Sender: TObject);
    procedure PrevButtonClick(Sender: TObject);
    procedure NextButtonClick(Sender: TObject);
    procedure ViewerPageChange(Sender: TObject; PageIndex: Integer);
  private
    procedure LoadEmbeddedPdf;
    procedure UpdatePageInfo;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.fmx}

procedure TMainForm.FormCreate(Sender: TObject);
begin
  LoadEmbeddedPdf;
  UpdatePageInfo;
end;

procedure TMainForm.FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF);
begin
  // Keep the toolbars clear of the status bar, notch and home indicator
  Padding.Rect := AInsets;
end;

procedure TMainForm.LoadEmbeddedPdf;
var
  Stream: TResourceStream;
begin
  Stream := TResourceStream.Create(HInstance, 'TEST_PDF', RT_RCDATA);
  try
    Viewer.LoadFromStream(Stream); // the document keeps its own copy of the data
  finally
    Stream.Free;
  end;
end;

procedure TMainForm.UpdatePageInfo;
begin
  if Viewer.IsLoaded then
    PageLabel.Text := Format('%d / %d', [Viewer.CurrentPage + 1, Viewer.PageCount])
  else
    PageLabel.Text := '- / -';
  PrevButton.Enabled := Viewer.IsLoaded and (Viewer.CurrentPage > 0);
  NextButton.Enabled := Viewer.IsLoaded and (Viewer.CurrentPage < Viewer.PageCount - 1);
end;

procedure TMainForm.FitButtonClick(Sender: TObject);
begin
  Viewer.FitWidth;
end;

procedure TMainForm.PrevButtonClick(Sender: TObject);
begin
  Viewer.PreviousPage;
end;

procedure TMainForm.NextButtonClick(Sender: TObject);
begin
  Viewer.NextPage;
end;

procedure TMainForm.ViewerPageChange(Sender: TObject; PageIndex: Integer);
begin
  UpdatePageInfo;
end;

end.
