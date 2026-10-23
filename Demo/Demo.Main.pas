unit Demo.Main;

{ Demo for TPdfViewer: open a file, navigate, zoom, search, bookmarks. The viewer
  is placed on the form at design time (install Packages\PdfViewerFMXDsgn first). }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.IOUtils,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls, FMX.Layouts,
  FMX.Controls.Presentation, FMX.Edit, FMX.ListBox, Pdf.Core.Navigation, FMX.PdfViewer;

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
    SearchEdit: TEdit;
    FindNextButton: TSpeedButton;
    FindPrevButton: TSpeedButton;
    OutlineButton: TSpeedButton;
    OutlineList: TListBox;
    StatusLabel: TLabel;
    Viewer: TPdfViewer;
    procedure SearchEditKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure FindNextButtonClick(Sender: TObject);
    procedure FindPrevButtonClick(Sender: TObject);
    procedure OutlineButtonClick(Sender: TObject);
    procedure OutlineListItemClick(const Sender: TCustomListBox; const Item: TListBoxItem);
    procedure FormCreate(Sender: TObject);
    procedure OpenButtonClick(Sender: TObject);
    procedure PrevButtonClick(Sender: TObject);
    procedure NextButtonClick(Sender: TObject);
    procedure ZoomOutButtonClick(Sender: TObject);
    procedure ZoomInButtonClick(Sender: TObject);
    procedure FitWidthButtonClick(Sender: TObject);
    procedure FitPageButtonClick(Sender: TObject);
    procedure ViewerPageChange(Sender: TObject; PageIndex: Integer);
    procedure ViewerZoomChange(Sender: TObject);
    procedure ViewerLoadError(Sender: TObject; const FileName: string; E: Exception; var Handled: Boolean);
    procedure ViewerOpenURI(Sender: TObject; const URI: string);
    procedure ViewerSelectionChange(Sender: TObject);
  private
    procedure UpdateStatus;
    procedure OpenFile(const FileName: string);
    procedure FillOutline;
    procedure DoFind;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.fmx}

uses
  {$IFDEF MSWINDOWS}Winapi.ShellAPI, Winapi.Windows,{$ENDIF}
  System.Generics.Collections;

procedure TMainForm.FormCreate(Sender: TObject);
begin
  OutlineList.Visible := False;
  OpenDialog.Filter := 'PDF-bestanden (*.pdf)|*.pdf|Alle bestanden (*.*)|*.*';
  UpdateStatus;
  if (ParamCount >= 1) and TFile.Exists(ParamStr(1)) then
    OpenFile(ParamStr(1));
end;

procedure TMainForm.OpenFile(const FileName: string);
begin
  Viewer.LoadFromFile(FileName);
  Caption := 'PdfViewer - ' + ExtractFileName(FileName);
  FillOutline;
  UpdateStatus;
  Viewer.SetFocus;
end;

procedure TMainForm.FillOutline;

  procedure AddItems(const Items: TObjectList<TPdfOutlineItem>; Level: Integer);
  var
    It: TPdfOutlineItem;
    LI: TListBoxItem;
  begin
    for It in Items do
    begin
      LI := TListBoxItem.Create(OutlineList);
      LI.Text := StringOfChar(' ', Level * 3) + It.Title;
      LI.TagObject := It;
      OutlineList.AddObject(LI);
      AddItems(It.Children, Level + 1);
    end;
  end;

begin
  OutlineList.BeginUpdate;
  try
    OutlineList.Clear;
    if (Viewer.Outline <> nil) and (Viewer.Outline.Count > 0) then
      AddItems(Viewer.Outline, 0);
  finally
    OutlineList.EndUpdate;
  end;
  OutlineButton.Enabled := OutlineList.Count > 0;
  if OutlineList.Count = 0 then
    OutlineList.Visible := False;
end;

procedure TMainForm.OutlineButtonClick(Sender: TObject);
begin
  OutlineList.Visible := not OutlineList.Visible and (OutlineList.Count > 0);
end;

procedure TMainForm.OutlineListItemClick(const Sender: TCustomListBox; const Item: TListBoxItem);
begin
  if (Item <> nil) and (Item.TagObject is TPdfOutlineItem) then
    Viewer.GoToOutlineItem(TPdfOutlineItem(Item.TagObject));
end;

procedure TMainForm.DoFind;
var
  N: Integer;
begin
  N := Viewer.Find(SearchEdit.Text);
  if SearchEdit.Text = '' then
    StatusLabel.Text := ''
  else if N = 0 then
    StatusLabel.Text := 'Niet gevonden: ' + SearchEdit.Text
  else
    StatusLabel.Text := Format('%d / %d gevonden', [Viewer.ActiveMatch + 1, N]);
end;

procedure TMainForm.SearchEditKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if Key = vkReturn then
  begin
    if SameText(Viewer.SearchQuery, SearchEdit.Text) and (Viewer.SearchMatchCount > 0) then
    begin
      if ssShift in Shift then
        Viewer.FindPrevious
      else
        Viewer.FindNext;
      StatusLabel.Text := Format('%d / %d gevonden', [Viewer.ActiveMatch + 1, Viewer.SearchMatchCount]);
    end
    else
      DoFind;
    Key := 0;
  end
  else if Key = vkEscape then
  begin
    SearchEdit.Text := '';
    Viewer.ClearSearch;
    UpdateStatus;
    Key := 0;
  end;
end;

procedure TMainForm.FindNextButtonClick(Sender: TObject);
begin
  if not SameText(Viewer.SearchQuery, SearchEdit.Text) then
    DoFind
  else if Viewer.FindNext then
    StatusLabel.Text := Format('%d / %d gevonden', [Viewer.ActiveMatch + 1, Viewer.SearchMatchCount]);
end;

procedure TMainForm.FindPrevButtonClick(Sender: TObject);
begin
  if not SameText(Viewer.SearchQuery, SearchEdit.Text) then
    DoFind
  else if Viewer.FindPrevious then
    StatusLabel.Text := Format('%d / %d gevonden', [Viewer.ActiveMatch + 1, Viewer.SearchMatchCount]);
end;

procedure TMainForm.ViewerOpenURI(Sender: TObject; const URI: string);
begin
  {$IFDEF MSWINDOWS}
  ShellExecute(0, 'open', PChar(URI), nil, nil, 1);
  {$ELSE}
  ShowMessage('Link: ' + URI);
  {$ENDIF}
end;

procedure TMainForm.ViewerSelectionChange(Sender: TObject);
var
  S: string;
begin
  S := Viewer.SelectedText;
  if S <> '' then
    StatusLabel.Text := Format('%d tekens geselecteerd (Ctrl+C kopieert)', [Length(S)])
  else
    UpdateStatus;
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
  if Viewer.IsLoaded then
  begin
    PageLabel.Text := Format('%d / %d', [Viewer.CurrentPage + 1, Viewer.PageCount]);
    StatusLabel.Text := Format('%s  -  PDF %s', [ExtractFileName(Viewer.FileName), Viewer.Document.Version]);
  end
  else
  begin
    PageLabel.Text := '- / -';
    StatusLabel.Text := 'Open een PDF (knop links, of sleep een pad als argument mee)';
  end;
  ZoomLabel.Text := Format('%d%%', [Round(Viewer.Zoom * 100)]);
end;

end.
