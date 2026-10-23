unit Demo.Main;

{ Demo for TPdfViewer: open a file, navigate, zoom. The viewer is created in
  code so the demo builds without installing the design-time package. }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.IOUtils,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls, FMX.Layouts,
  FMX.Controls.Presentation, FMX.Edit, FMX.PdfViewer;

type
  TMainForm = class(TForm)
    ToolBar: TToolBar;
    OpenButton: TSpeedButton;
    PrevButton: TSpeedButton;
    NextButton: TSpeedButton;
    PageLabel: TLabel;
    ZoomOutButton: TSpeedButton;
    ZoomInButton: TSpeedButton;
    FitWidthButton: TSpeedButton;
    FitPageButton: TSpeedButton;
    ZoomLabel: TLabel;
    OpenDialog: TOpenDialog;
    StatusLabel: TLabel;
    procedure FormCreate(Sender: TObject);
    procedure OpenButtonClick(Sender: TObject);
    procedure PrevButtonClick(Sender: TObject);
    procedure NextButtonClick(Sender: TObject);
    procedure ZoomOutButtonClick(Sender: TObject);
    procedure ZoomInButtonClick(Sender: TObject);
    procedure FitWidthButtonClick(Sender: TObject);
    procedure FitPageButtonClick(Sender: TObject);
  private
    FViewer: TPdfViewer;
    procedure ViewerPageChange(Sender: TObject; PageIndex: Integer);
    procedure ViewerZoomChange(Sender: TObject);
    procedure ViewerLoadError(Sender: TObject; const FileName: string; E: Exception; var Handled: Boolean);
    procedure UpdateStatus;
    procedure OpenFile(const FileName: string);
  end;

var
  MainForm: TMainForm;

implementation

{$R *.fmx}

procedure TMainForm.FormCreate(Sender: TObject);
begin
  FViewer := TPdfViewer.Create(Self);
  FViewer.Parent := Self;
  FViewer.Align := TAlignLayout.Client;
  FViewer.OnPageChange := ViewerPageChange;
  FViewer.OnZoomChange := ViewerZoomChange;
  FViewer.OnLoadError := ViewerLoadError;
  OpenDialog.Filter := 'PDF-bestanden (*.pdf)|*.pdf|Alle bestanden (*.*)|*.*';
  UpdateStatus;
  if (ParamCount >= 1) and TFile.Exists(ParamStr(1)) then
    OpenFile(ParamStr(1));
end;

procedure TMainForm.OpenFile(const FileName: string);
begin
  FViewer.LoadFromFile(FileName);
  Caption := 'PdfViewer - ' + ExtractFileName(FileName);
  UpdateStatus;
  FViewer.SetFocus;
end;

procedure TMainForm.OpenButtonClick(Sender: TObject);
begin
  if OpenDialog.Execute then
    OpenFile(OpenDialog.FileName);
end;

procedure TMainForm.PrevButtonClick(Sender: TObject);
begin
  FViewer.PreviousPage;
end;

procedure TMainForm.NextButtonClick(Sender: TObject);
begin
  FViewer.NextPage;
end;

procedure TMainForm.ZoomOutButtonClick(Sender: TObject);
begin
  FViewer.ZoomOut;
end;

procedure TMainForm.ZoomInButtonClick(Sender: TObject);
begin
  FViewer.ZoomIn;
end;

procedure TMainForm.FitWidthButtonClick(Sender: TObject);
begin
  FViewer.FitWidth;
end;

procedure TMainForm.FitPageButtonClick(Sender: TObject);
begin
  FViewer.FitPage;
end;

procedure TMainForm.ViewerPageChange(Sender: TObject; PageIndex: Integer);
begin
  UpdateStatus;
end;

procedure TMainForm.ViewerZoomChange(Sender: TObject);
begin
  UpdateStatus;
end;

procedure TMainForm.ViewerLoadError(Sender: TObject; const FileName: string; E: Exception; var Handled: Boolean);
begin
  ShowMessage('Kan ' + ExtractFileName(FileName) + ' niet openen: ' + E.Message);
  Handled := True;
  UpdateStatus;
end;

procedure TMainForm.UpdateStatus;
begin
  if FViewer.IsLoaded then
  begin
    PageLabel.Text := Format('%d / %d', [FViewer.CurrentPage + 1, FViewer.PageCount]);
    StatusLabel.Text := Format('%s  -  PDF %s', [ExtractFileName(FViewer.FileName), FViewer.Document.Version]);
  end
  else
  begin
    PageLabel.Text := '- / -';
    StatusLabel.Text := 'Open een PDF (knop links, of sleep een pad als argument mee)';
  end;
  ZoomLabel.Text := Format('%d%%', [Round(FViewer.Zoom * 100)]);
end;

end.
