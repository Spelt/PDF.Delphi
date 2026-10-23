unit VclDemo.Main;

{ Small VCL demo for Vcl.PdfViewer: a toolbar, a thumbnail strip, the viewer and a status bar. The viewer
  and thumbnails are placed at design time (install Packages\PdfViewerVCLDsgn first). Open a file with the
  button, Ctrl+O, by dropping it on the window or as the first command-line parameter. }

interface

uses
  Winapi.Windows, Winapi.Messages, Winapi.ShellAPI,
  System.SysUtils, System.Classes, System.UITypes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Skia,
  Vcl.PdfViewer, Vcl.PdfThumbnails;

type
  TMainForm = class(TForm)
    ToolBar: TPanel;
    OpenButton: TButton;
    PrevButton: TButton;
    PageLabel: TLabel;
    NextButton: TButton;
    ZoomOutButton: TButton;
    ZoomLabel: TLabel;
    ZoomInButton: TButton;
    FitWidthButton: TButton;
    FitPageButton: TButton;
    RotateButton: TButton;
    FindNextButton: TButton;
    FindPrevButton: TButton;
    SearchEdit: TEdit;
    Thumbnails: TPdfThumbnails;
    Splitter: TSplitter;
    Viewer: TPdfViewer;
    StatusBar: TStatusBar;
    OpenDialog: TOpenDialog;
    procedure FormCreate(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure OpenButtonClick(Sender: TObject);
    procedure PrevButtonClick(Sender: TObject);
    procedure NextButtonClick(Sender: TObject);
    procedure ZoomOutButtonClick(Sender: TObject);
    procedure ZoomInButtonClick(Sender: TObject);
    procedure FitWidthButtonClick(Sender: TObject);
    procedure FitPageButtonClick(Sender: TObject);
    procedure RotateButtonClick(Sender: TObject);
    procedure FindNextButtonClick(Sender: TObject);
    procedure FindPrevButtonClick(Sender: TObject);
    procedure SearchEditKeyPress(Sender: TObject; var Key: Char);
    procedure ViewerPageChange(Sender: TObject; PageIndex: Integer);
    procedure ViewerZoomChange(Sender: TObject);
    procedure ViewerLoadError(Sender: TObject; const FileName: string; E: Exception; var Handled: Boolean);
    procedure ViewerPasswordRequest(Sender: TObject; const FileName: string; Attempt: Integer;
      var Password: string; var Cancel: Boolean);
    procedure ViewerOpenURI(Sender: TObject; const URI: string);
    procedure ViewerSelectionChange(Sender: TObject);
  private
    FLastQuery: string;
    procedure WMDropFiles(var Message: TWMDropFiles); message WM_DROPFILES;
    procedure OpenFile(const FileName: string);
    procedure Search(Backwards: Boolean);
    procedure UpdateUI;
  protected
    procedure CreateWnd; override;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.dfm}

procedure TMainForm.FormCreate(Sender: TObject);
begin
  UpdateUI;
  if (ParamCount > 0) and FileExists(ParamStr(1)) then
    OpenFile(ParamStr(1));
end;

procedure TMainForm.CreateWnd;
begin
  inherited;
  DragAcceptFiles(Handle, True);
end;

procedure TMainForm.WMDropFiles(var Message: TWMDropFiles);
var
  Name: array[0..MAX_PATH] of Char;
begin
  try
    if DragQueryFile(Message.Drop, 0, Name, Length(Name)) > 0 then
      OpenFile(Name);
  finally
    DragFinish(Message.Drop);
  end;
end;

procedure TMainForm.OpenFile(const FileName: string);
begin
  Viewer.LoadFromFile(FileName);
  if Viewer.IsLoaded then
  begin
    Caption := ExtractFileName(FileName) + ' - PdfViewer VCL-demo';
    FLastQuery := '';
    Viewer.SetFocus;
  end;
  UpdateUI;
end;

procedure TMainForm.UpdateUI;
var
  Loaded: Boolean;
begin
  Loaded := Viewer.IsLoaded;
  if Loaded then
    PageLabel.Caption := Format('%d / %d', [Viewer.CurrentPage + 1, Viewer.PageCount])
  else
    PageLabel.Caption := '- / -';
  ZoomLabel.Caption := Format('%d%%', [Round(Viewer.Zoom * 100)]);
  PrevButton.Enabled := Loaded and (Viewer.CurrentPage > 0);
  NextButton.Enabled := Loaded and (Viewer.CurrentPage < Viewer.PageCount - 1);
  ZoomOutButton.Enabled := Loaded;
  ZoomInButton.Enabled := Loaded;
  FitWidthButton.Enabled := Loaded;
  FitPageButton.Enabled := Loaded;
  RotateButton.Enabled := Loaded;
  SearchEdit.Enabled := Loaded;
  FindNextButton.Enabled := Loaded;
  FindPrevButton.Enabled := Loaded;
  if not Loaded then
    StatusBar.SimpleText := 'Open een PDF (knop, Ctrl+O of sleep een bestand op het venster)'
  else if Viewer.SearchMatchCount > 0 then
    StatusBar.SimpleText := Format('Resultaat %d van %d voor "%s"', [Viewer.ActiveMatch + 1, Viewer.SearchMatchCount,
      Viewer.SearchQuery])
  else if Viewer.HasSelection then
    StatusBar.SimpleText := Format('%d tekens geselecteerd (Ctrl+C kopieert)', [Length(Viewer.SelectedText)])
  else
    StatusBar.SimpleText := Viewer.FileName;
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (ssCtrl in Shift) and (Key = Ord('O')) then
  begin
    OpenButtonClick(nil);
    Key := 0;
  end
  else if (ssCtrl in Shift) and (Key = Ord('F')) and SearchEdit.Enabled then
  begin
    SearchEdit.SetFocus;
    SearchEdit.SelectAll;
    Key := 0;
  end;
end;

procedure TMainForm.OpenButtonClick(Sender: TObject);
begin
  if OpenDialog.Execute then
    OpenFile(OpenDialog.FileName);
end;

procedure TMainForm.PrevButtonClick(Sender: TObject);
begin
  Viewer.PreviousPage;
end;

procedure TMainForm.NextButtonClick(Sender: TObject);
begin
  Viewer.NextPage;
end;

procedure TMainForm.ZoomOutButtonClick(Sender: TObject);
begin
  Viewer.ZoomOut;
end;

procedure TMainForm.ZoomInButtonClick(Sender: TObject);
begin
  Viewer.ZoomIn;
end;

procedure TMainForm.FitWidthButtonClick(Sender: TObject);
begin
  Viewer.FitWidth;
end;

procedure TMainForm.FitPageButtonClick(Sender: TObject);
begin
  Viewer.FitPage;
end;

procedure TMainForm.RotateButtonClick(Sender: TObject);
begin
  Viewer.RotateClockwise;
end;

procedure TMainForm.Search(Backwards: Boolean);
var
  Query: string;
begin
  Query := Trim(SearchEdit.Text);
  if Query <> FLastQuery then
  begin
    FLastQuery := Query;
    if Viewer.Find(Query) = 0 then
      StatusBar.SimpleText := Format('"%s" niet gevonden', [Query])
    else
      UpdateUI;
    Exit;
  end;
  if Backwards then
    Viewer.FindPrevious
  else
    Viewer.FindNext;
  UpdateUI;
end;

procedure TMainForm.FindNextButtonClick(Sender: TObject);
begin
  Search(False);
end;

procedure TMainForm.FindPrevButtonClick(Sender: TObject);
begin
  Search(True);
end;

procedure TMainForm.SearchEditKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    Search(GetKeyState(VK_SHIFT) < 0);
    Key := #0;
  end;
end;

procedure TMainForm.ViewerPageChange(Sender: TObject; PageIndex: Integer);
begin
  UpdateUI;
end;

procedure TMainForm.ViewerZoomChange(Sender: TObject);
begin
  UpdateUI;
end;

procedure TMainForm.ViewerSelectionChange(Sender: TObject);
begin
  UpdateUI;
end;

procedure TMainForm.ViewerLoadError(Sender: TObject; const FileName: string; E: Exception; var Handled: Boolean);
begin
  MessageDlg(Format('Kan %s niet openen:'#13#10'%s', [ExtractFileName(FileName), E.Message]), mtError, [mbOK], 0);
  Handled := True;
end;

procedure TMainForm.ViewerPasswordRequest(Sender: TObject; const FileName: string; Attempt: Integer;
  var Password: string; var Cancel: Boolean);
var
  Prompt: string;
begin
  if Attempt = 1 then
    Prompt := 'Dit document is beveiligd. Wachtwoord:'
  else
    Prompt := 'Onjuist wachtwoord, probeer opnieuw:';
  // A first prompt character below #32 makes InputQuery mask the input
  Cancel := not InputQuery(ExtractFileName(FileName), [#31 + Prompt], Password);
end;

procedure TMainForm.ViewerOpenURI(Sender: TObject; const URI: string);
begin
  if MessageDlg(Format('Deze link openen in de browser?'#13#10'%s', [URI]), mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    ShellExecute(Handle, 'open', PChar(URI), nil, nil, SW_SHOWNORMAL);
end;

end.
