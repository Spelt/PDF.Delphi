unit Demo.Main;

{ Demo for TPdfViewer and TPdfThumbnails. Everything on the form is placed at
  design time (install Packages\PdfViewerFMXDsgn first): a toolbar with icon
  buttons, a sidebar with thumbnails, bookmarks, search results and document
  properties, a status bar, light and dark theme, drag and drop, recent files,
  rotation and page layout modes, export, clipboard, printing, a password
  prompt and a keyboard-shortcut overlay. }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.IOUtils, System.Math, System.Actions,
  System.Skia, System.Rtti,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls, FMX.Layouts, FMX.Objects,
  FMX.Controls.Presentation, FMX.Edit, FMX.ListBox, FMX.TreeView, FMX.TabControl, FMX.Menus, FMX.ActnList,
  FMX.Memo, FMX.Memo.Types, FMX.ScrollBox, FMX.Grid, FMX.Grid.Style, FMX.Skia, FMX.Platform,
  Pdf.Core.Navigation, Pdf.Render.Text, FMX.PdfViewer, FMX.PdfThumbnails, Demo.Settings;

type
  TMainForm = class(TForm)
    ToolBar: TToolBar;
    SidebarButton: TSpeedButton;
    SidebarIcon: TSkSvg;
    OpenButton: TSpeedButton;
    OpenIcon: TSkSvg;
    RecentButton: TSpeedButton;
    RecentIcon: TSkSvg;
    FirstButton: TSpeedButton;
    FirstIcon: TSkSvg;
    PrevButton: TSpeedButton;
    PrevIcon: TSkSvg;
    PageEdit: TEdit;
    PageCountLabel: TLabel;
    NextButton: TSpeedButton;
    NextIcon: TSkSvg;
    LastButton: TSpeedButton;
    LastIcon: TSkSvg;
    ZoomOutButton: TSpeedButton;
    ZoomOutIcon: TSkSvg;
    ZoomTrack: TTrackBar;
    ZoomInButton: TSpeedButton;
    ZoomInIcon: TSkSvg;
    ZoomButton: TSpeedButton;
    FitWidthButton: TSpeedButton;
    FitWidthIcon: TSkSvg;
    FitPageButton: TSpeedButton;
    FitPageIcon: TSkSvg;
    RotateLeftButton: TSpeedButton;
    RotateLeftIcon: TSkSvg;
    RotateRightButton: TSpeedButton;
    RotateRightIcon: TSkSvg;
    LayoutButton: TSpeedButton;
    LayoutIcon: TSkSvg;
    HelpButton: TSpeedButton;
    HelpIcon: TSkSvg;
    ThemeButton: TSpeedButton;
    ThemeIcon: TSkSvg;
    FullScreenButton: TSpeedButton;
    FullScreenIcon: TSkSvg;
    InfoButton: TSpeedButton;
    InfoIcon: TSkSvg;
    PrintButton: TSpeedButton;
    PrintIcon: TSkSvg;
    ExportButton: TSpeedButton;
    ExportIcon: TSkSvg;
    FindNextButton: TSpeedButton;
    FindNextIcon: TSkSvg;
    FindPrevButton: TSpeedButton;
    FindPrevIcon: TSkSvg;
    SearchEdit: TEdit;
    StatusBar: TStatusBar;
    StatusLabel: TLabel;
    InfoLabel: TLabel;
    Body: TLayout;
    Sidebar: TLayout;
    SideTabs: TTabControl;
    TabPages: TTabItem;
    Thumbs: TPdfThumbnails;
    TabOutline: TTabItem;
    OutlineTree: TTreeView;
    TabSearch: TTabItem;
    SearchOptions: TLayout;
    CaseCheck: TCheckBox;
    WholeWordCheck: TCheckBox;
    ResultsLabel: TLabel;
    ResultsList: TListBox;
    TabInfo: TTabItem;
    InfoGrid: TStringGrid;
    KeyColumn: TStringColumn;
    ValueColumn: TStringColumn;
    Splitter: TSplitter;
    Viewer: TPdfViewer;
    HelpOverlay: TRectangle;
    HelpPanel: TRectangle;
    HelpTitle: TLabel;
    HelpMemo: TMemo;
    HelpCloseButton: TButton;
    DropOverlay: TRectangle;
    DropLabel: TLabel;
    OpenDialog: TOpenDialog;
    SaveDialog: TSaveDialog;
    RecentMenu: TPopupMenu;
    ZoomMenu: TPopupMenu;
    Zoom50: TMenuItem;
    Zoom75: TMenuItem;
    Zoom100: TMenuItem;
    Zoom125: TMenuItem;
    Zoom150: TMenuItem;
    Zoom200: TMenuItem;
    Zoom300: TMenuItem;
    Zoom400: TMenuItem;
    ZoomSep: TMenuItem;
    ZoomFitWidthItem: TMenuItem;
    ZoomFitPageItem: TMenuItem;
    LayoutMenu: TPopupMenu;
    ModeContinuousItem: TMenuItem;
    ModeSingleItem: TMenuItem;
    ModeFacingContinuousItem: TMenuItem;
    ModeFacingItem: TMenuItem;
    ModeSep: TMenuItem;
    CoverPageItem: TMenuItem;
    ExportMenu: TPopupMenu;
    ExportPng150Item: TMenuItem;
    ExportPng300Item: TMenuItem;
    ExportSep: TMenuItem;
    CopyPageImageItem: TMenuItem;
    CopyPageTextItem: TMenuItem;
    ActionList: TActionList;
    actOpen: TAction;
    actClose: TAction;
    actFirstPage: TAction;
    actPrevPage: TAction;
    actNextPage: TAction;
    actLastPage: TAction;
    actGoToPage: TAction;
    actZoomIn: TAction;
    actZoomOut: TAction;
    actActualSize: TAction;
    actFitWidth: TAction;
    actFitPage: TAction;
    actRotateLeft: TAction;
    actRotateRight: TAction;
    actModeContinuous: TAction;
    actModeSingle: TAction;
    actModeFacingContinuous: TAction;
    actModeFacing: TAction;
    actCoverPage: TAction;
    actSidebar: TAction;
    actSearch: TAction;
    actFindNext: TAction;
    actFindPrev: TAction;
    actPrint: TAction;
    actExportPng150: TAction;
    actExportPng300: TAction;
    actCopyPageImage: TAction;
    actCopyPageText: TAction;
    actProperties: TAction;
    actTheme: TAction;
    actFullScreen: TAction;
    actHelp: TAction;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure actOpenExecute(Sender: TObject);
    procedure actCloseExecute(Sender: TObject);
    procedure actFirstPageExecute(Sender: TObject);
    procedure actPrevPageExecute(Sender: TObject);
    procedure actNextPageExecute(Sender: TObject);
    procedure actLastPageExecute(Sender: TObject);
    procedure actGoToPageExecute(Sender: TObject);
    procedure actZoomInExecute(Sender: TObject);
    procedure actZoomOutExecute(Sender: TObject);
    procedure actActualSizeExecute(Sender: TObject);
    procedure actFitWidthExecute(Sender: TObject);
    procedure actFitPageExecute(Sender: TObject);
    procedure actRotateLeftExecute(Sender: TObject);
    procedure actRotateRightExecute(Sender: TObject);
    procedure actModeExecute(Sender: TObject);
    procedure actCoverPageExecute(Sender: TObject);
    procedure actSidebarExecute(Sender: TObject);
    procedure actSearchExecute(Sender: TObject);
    procedure actFindNextExecute(Sender: TObject);
    procedure actFindPrevExecute(Sender: TObject);
    procedure actPrintExecute(Sender: TObject);
    procedure actExportPngExecute(Sender: TObject);
    procedure actCopyPageImageExecute(Sender: TObject);
    procedure actCopyPageTextExecute(Sender: TObject);
    procedure actPropertiesExecute(Sender: TObject);
    procedure actThemeExecute(Sender: TObject);
    procedure actFullScreenExecute(Sender: TObject);
    procedure actHelpExecute(Sender: TObject);
    procedure RecentButtonClick(Sender: TObject);
    procedure ZoomButtonClick(Sender: TObject);
    procedure LayoutButtonClick(Sender: TObject);
    procedure ExportButtonClick(Sender: TObject);
    procedure ZoomMenuClick(Sender: TObject);
    procedure ZoomTrackChange(Sender: TObject);
    procedure PageEditKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure PageEditExit(Sender: TObject);
    procedure SearchEditKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure SearchOptionChange(Sender: TObject);
    procedure ResultsListItemClick(const Sender: TCustomListBox; const Item: TListBoxItem);
    procedure OutlineTreeChange(Sender: TObject);
    procedure HelpOverlayClick(Sender: TObject);
    procedure FileDragOver(Sender: TObject; const Data: TDragObject; const Point: TPointF; var Operation: TDragOperation);
    procedure FileDragDrop(Sender: TObject; const Data: TDragObject; const Point: TPointF);
    procedure FileDragLeave(Sender: TObject);
    procedure ViewerLoadError(Sender: TObject; const FileName: string; E: Exception; var Handled: Boolean);
    procedure ViewerPasswordRequest(Sender: TObject; const FileName: string; Attempt: Integer; var Password: string;
      var Cancel: Boolean);
    procedure ViewerOpenURI(Sender: TObject; const URI: string);
    procedure ViewerSelectionChange(Sender: TObject);
  private
    FSettings: TDemoSettings;
    FDark: Boolean;
    FDarkStyle: TStyleBook;
    FIconColor: TAlphaColor;
    FUpdating: Integer;
    FStatusOverride: string;
    procedure LoadSettings;
    procedure SaveSettings;
    procedure SetupIcons;
    procedure ApplyTheme(Dark: Boolean);
    procedure OpenFile(const FileName: string);
    procedure ViewerChanged(Sender: TObject; Change: TPdfViewerChange);
    procedure UpdateUI;
    procedure UpdatePageControls;
    procedure UpdateZoomControls;
    procedure UpdateStatus;
    procedure UpdateInfoLabel;
    procedure FillOutline;
    procedure FillInfo;
    procedure FillSearchResults;
    procedure FillHelp;
    procedure DoFind;
    procedure ShowSidebarTab(Tab: TTabItem);
    procedure SetSidebarVisible(Value: Boolean);
    procedure BuildRecentMenu;
    procedure RecentItemClick(Sender: TObject);
    procedure ClearRecentClick(Sender: TObject);
    procedure OutlineItemClick(Sender: TObject);
    procedure ExportPng(Dpi: Integer);
    procedure PopupBelow(Menu: TPopupMenu; Button: TControl);
    procedure SetStatus(const S: string);
    function TrackToZoom(V: Double): Double;
    function ZoomToTrack(Z: Double): Double;
    procedure AddInfo(const Key, Value: string);
    function MatchContext(const SM: TPdfSearchMatch): string;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.fmx}

uses
  {$IFDEF MSWINDOWS}Winapi.ShellAPI, Winapi.Windows,{$ENDIF}
  System.Generics.Collections, System.Character, System.StrUtils, System.Threading, System.Diagnostics,
  FMX.DialogService, FMX.Surfaces, FMX.Styles,
  FMX.Clipboard,
  Demo.Icons, Demo.Password, Demo.PrintDialog, Demo.Printing;

{ Helpers }

function FormatFileSize(Bytes: Int64): string;
begin
  if Bytes < 1024 then
    Result := Format('%d B', [Bytes])
  else if Bytes < 1024 * 1024 then
    Result := Format('%.0f kB', [Bytes / 1024])
  else
    Result := Format('%.1f MB', [Bytes / (1024 * 1024)]);
end;

function PdfDateToStr(const S: string): string;
var
  T: string;
begin
  // D:YYYYMMDDHHmmSS(+HH'mm')
  T := S;
  if T.StartsWith('D:') then
    Delete(T, 1, 2);
  if (Length(T) < 8) or not T.Substring(0, 8).ToCharArray[0].IsDigit then
    Exit(S);
  Result := Copy(T, 1, 4) + '-' + Copy(T, 5, 2) + '-' + Copy(T, 7, 2);
  if Length(T) >= 12 then
    Result := Result + ' ' + Copy(T, 9, 2) + ':' + Copy(T, 11, 2);
end;

function PaperName(W, H: Double): string;
const
  Papers: array[0..5] of record Name: string; W, H: Double end = (
    (Name: 'A3'; W: 842; H: 1191), (Name: 'A4'; W: 595; H: 842), (Name: 'A5'; W: 420; H: 595),
    (Name: 'Letter'; W: 612; H: 792), (Name: 'Legal'; W: 612; H: 1008), (Name: 'Tabloid'; W: 792; H: 1224));
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Papers) do
    if (Abs(W - Papers[I].W) < 3) and (Abs(H - Papers[I].H) < 3) then
      Exit(Papers[I].Name + ' staand')
    else if (Abs(H - Papers[I].W) < 3) and (Abs(W - Papers[I].H) < 3) then
      Exit(Papers[I].Name + ' liggend');
end;

function BitmapToSurface(Bmp: FMX.Graphics.TBitmap): TBitmapSurface;
var
  Data: TBitmapData;
  Y: Integer;
begin
  Result := TBitmapSurface.Create;
  if Bmp.Map(TMapAccess.Read, Data) then
  try
    Result.SetSize(Bmp.Width, Bmp.Height, Data.PixelFormat);
    for Y := 0 to Bmp.Height - 1 do
      Move(Data.GetScanline(Y)^, Result.Scanline[Y]^, Min(Data.Pitch, Result.Pitch));
  finally
    Bmp.Unmap(Data);
  end;
end;

{ Form }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  FSettings := TDemoSettings.Create;
  OpenDialog.Filter := 'PDF-bestanden (*.pdf)|*.pdf|Alle bestanden (*.*)|*.*';
  SaveDialog.Filter := 'PNG-afbeelding (*.png)|*.png';
  Thumbs.Viewer := Viewer;
  Viewer.AddChangeListener(ViewerChanged);
  SetupIcons;
  FillHelp;
  HelpOverlay.Visible := False;
  DropOverlay.Visible := False;
  LoadSettings;
  UpdateUI;
  if (ParamCount >= 1) and TFile.Exists(ParamStr(1)) then
    OpenFile(ParamStr(1));
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  Viewer.RemoveChangeListener(ViewerChanged);
  FSettings.Free;
end;

procedure TMainForm.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  SaveSettings;
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if Key = vkEscape then
  begin
    if HelpOverlay.Visible then
    begin
      HelpOverlay.Visible := False;
      Key := 0;
    end
    else if FullScreen then
    begin
      FullScreen := False;
      Key := 0;
    end;
  end;
end;

procedure TMainForm.LoadSettings;
begin
  FDark := FSettings.ReadBool('DarkTheme', True);
  ApplyTheme(FDark);
  Sidebar.Width := Max(160, FSettings.ReadInteger('SidebarWidth', 280));
  SetSidebarVisible(FSettings.ReadBool('SidebarVisible', True));
  SideTabs.TabIndex := EnsureRange(FSettings.ReadInteger('SidebarTab', 0), 0, SideTabs.TabCount - 1);
  Viewer.DisplayMode := TPdfDisplayMode(EnsureRange(FSettings.ReadInteger('DisplayMode', 0), 0,
    Ord(High(TPdfDisplayMode))));
  Viewer.FacingCoverPage := FSettings.ReadBool('CoverPage', False);
  if FSettings.ReadBool('FitPage', False) then
    Viewer.ZoomMode := zmFitPage;
  OpenDialog.InitialDir := FSettings.ReadString('LastDir', '');
  if FSettings.ReadInteger('WindowWidth', 0) > 400 then
  begin
    Width := FSettings.ReadInteger('WindowWidth', Width);
    Height := FSettings.ReadInteger('WindowHeight', Height);
  end;
end;

procedure TMainForm.SaveSettings;
begin
  FSettings.WriteBool('DarkTheme', FDark);
  FSettings.WriteInteger('SidebarWidth', Round(Sidebar.Width));
  FSettings.WriteBool('SidebarVisible', Sidebar.Visible);
  FSettings.WriteInteger('SidebarTab', SideTabs.TabIndex);
  FSettings.WriteInteger('DisplayMode', Ord(Viewer.DisplayMode));
  FSettings.WriteBool('CoverPage', Viewer.FacingCoverPage);
  FSettings.WriteBool('FitPage', Viewer.ZoomMode = zmFitPage);
  if Viewer.FileName <> '' then
    FSettings.WriteString('LastDir', ExtractFilePath(Viewer.FileName));
  if not FullScreen and (WindowState = TWindowState.wsNormal) then
  begin
    FSettings.WriteInteger('WindowWidth', Width);
    FSettings.WriteInteger('WindowHeight', Height);
  end;
  FSettings.Save;
end;

procedure TMainForm.SetupIcons;
begin
  SetDemoIcon(SidebarIcon, diSidebar, FIconColor);
  SetDemoIcon(OpenIcon, diOpen, FIconColor);
  SetDemoIcon(RecentIcon, diRecent, FIconColor);
  SetDemoIcon(FirstIcon, diFirst, FIconColor);
  SetDemoIcon(PrevIcon, diPrev, FIconColor);
  SetDemoIcon(NextIcon, diNext, FIconColor);
  SetDemoIcon(LastIcon, diLast, FIconColor);
  SetDemoIcon(ZoomOutIcon, diZoomOut, FIconColor);
  SetDemoIcon(ZoomInIcon, diZoomIn, FIconColor);
  SetDemoIcon(FitWidthIcon, diFitWidth, FIconColor);
  SetDemoIcon(FitPageIcon, diFitPage, FIconColor);
  SetDemoIcon(RotateLeftIcon, diRotateLeft, FIconColor);
  SetDemoIcon(RotateRightIcon, diRotateRight, FIconColor);
  SetDemoIcon(LayoutIcon, diLayout, FIconColor);
  SetDemoIcon(HelpIcon, diHelp, FIconColor);
  SetDemoIcon(ThemeIcon, diMoon, FIconColor);
  SetDemoIcon(FullScreenIcon, diFullScreen, FIconColor);
  SetDemoIcon(InfoIcon, diInfo, FIconColor);
  SetDemoIcon(PrintIcon, diPrint, FIconColor);
  SetDemoIcon(ExportIcon, diExport, FIconColor);
  SetDemoIcon(FindNextIcon, diDown, FIconColor);
  SetDemoIcon(FindPrevIcon, diUp, FIconColor);
end;

procedure TMainForm.ApplyTheme(Dark: Boolean);
var
  Stream: TResourceStream;
begin
  FDark := Dark;
  if Dark then
  begin
    if FDarkStyle = nil then
    begin
      FDarkStyle := TStyleBook.Create(Self);
      Stream := TResourceStream.Create(HInstance, 'DEMO_DARK_STYLE', RT_RCDATA);
      try
        FDarkStyle.LoadFromStream(Stream);
      finally
        Stream.Free;
      end;
    end;
    StyleBook := FDarkStyle;
    FIconColor := $FFE6E6E6;
    Viewer.BackgroundColor := $FF262626;
    Thumbs.BackgroundColor := $FF2E2E2E;
    Thumbs.TextColor := $FFD8D8D8;
    HelpOverlay.Fill.Color := $B0000000;
    HelpPanel.Fill.Color := $FF2B2B2B;
    DropOverlay.Fill.Color := $703D8BFF;
  end
  else
  begin
    StyleBook := nil;
    FIconColor := $FF333333;
    Viewer.BackgroundColor := $FFD4D4D4;
    Thumbs.BackgroundColor := $FFE4E4E4;
    Thumbs.TextColor := $FF333333;
    HelpOverlay.Fill.Color := $70000000;
    HelpPanel.Fill.Color := $FFF6F6F6;
    DropOverlay.Fill.Color := $703D8BFF;
  end;
  RecolorDemoIcons(ToolBar, FIconColor);
  if Dark then
    SetDemoIcon(ThemeIcon, diSun, FIconColor)
  else
    SetDemoIcon(ThemeIcon, diMoon, FIconColor);
  ThemeButton.Hint := IfThen(Dark, 'Licht thema (Ctrl+T)', 'Donker thema (Ctrl+T)');
end;

{ Files }

procedure TMainForm.OpenFile(const FileName: string);
begin
  SetStatus('Bezig met laden van ' + ExtractFileName(FileName) + ' ...');
  Application.ProcessMessages;
  Viewer.LoadFromFile(FileName);
  FStatusOverride := '';
  if Viewer.IsLoaded then
  begin
    FSettings.AddRecent(FileName);
    Caption := ExtractFileName(FileName) + ' - PDF Viewer';
    Viewer.SetFocus;
  end
  else
    Caption := 'PDF Viewer';
  UpdateUI;
end;

procedure TMainForm.actOpenExecute(Sender: TObject);
begin
  if OpenDialog.Execute then
    OpenFile(OpenDialog.FileName);
end;

procedure TMainForm.actCloseExecute(Sender: TObject);
begin
  Viewer.Close;
  Caption := 'PDF Viewer';
  UpdateUI;
end;

procedure TMainForm.BuildRecentMenu;
var
  I: Integer;
  Item: TMenuItem;
begin
  RecentMenu.Clear;
  for I := 0 to FSettings.Recent.Count - 1 do
  begin
    Item := TMenuItem.Create(RecentMenu);
    Item.Text := Format('&%d  %s', [(I + 1) mod 10, FSettings.Recent[I]]);
    Item.Tag := I;
    Item.OnClick := RecentItemClick;
    RecentMenu.AddObject(Item);
  end;
  if FSettings.Recent.Count = 0 then
  begin
    Item := TMenuItem.Create(RecentMenu);
    Item.Text := '(geen recente bestanden)';
    Item.Enabled := False;
    RecentMenu.AddObject(Item);
  end
  else
  begin
    Item := TMenuItem.Create(RecentMenu);
    Item.Text := '-';
    RecentMenu.AddObject(Item);
    Item := TMenuItem.Create(RecentMenu);
    Item.Text := 'Lijst wissen';
    Item.OnClick := ClearRecentClick;
    RecentMenu.AddObject(Item);
  end;
end;

procedure TMainForm.RecentItemClick(Sender: TObject);
var
  FileName: string;
begin
  FileName := FSettings.Recent[(Sender as TMenuItem).Tag];
  if TFile.Exists(FileName) then
    OpenFile(FileName)
  else
  begin
    FSettings.RemoveRecent(FileName);
    TDialogService.ShowMessage('Bestand niet gevonden: ' + FileName);
  end;
end;

procedure TMainForm.ClearRecentClick(Sender: TObject);
begin
  FSettings.ClearRecent;
end;

procedure TMainForm.RecentButtonClick(Sender: TObject);
begin
  BuildRecentMenu;
  PopupBelow(RecentMenu, OpenButton);
end;

procedure TMainForm.PopupBelow(Menu: TPopupMenu; Button: TControl);
var
  P: TPointF;
begin
  P := Button.LocalToScreen(TPointF.Create(0, Button.Height));
  Menu.Popup(P.X, P.Y);
end;

{ Drag and drop }

procedure TMainForm.FileDragOver(Sender: TObject; const Data: TDragObject; const Point: TPointF;
  var Operation: TDragOperation);
var
  S: string;
begin
  Operation := TDragOperation.None;
  for S in Data.Files do
    if SameText(ExtractFileExt(S), '.pdf') then
    begin
      Operation := TDragOperation.Copy;
      Break;
    end;
  DropOverlay.Visible := Operation <> TDragOperation.None;
end;

procedure TMainForm.FileDragDrop(Sender: TObject; const Data: TDragObject; const Point: TPointF);
var
  S: string;
begin
  DropOverlay.Visible := False;
  for S in Data.Files do
    if SameText(ExtractFileExt(S), '.pdf') then
    begin
      OpenFile(S);
      Break;
    end;
end;

procedure TMainForm.FileDragLeave(Sender: TObject);
begin
  DropOverlay.Visible := False;
end;

{ Viewer events }

procedure TMainForm.ViewerLoadError(Sender: TObject; const FileName: string; E: Exception; var Handled: Boolean);
begin
  Handled := True;
  FStatusOverride := '';
  TDialogService.ShowMessage(Format('Kan %s niet openen:'#13#10'%s', [ExtractFileName(FileName), E.Message]));
end;

procedure TMainForm.ViewerPasswordRequest(Sender: TObject; const FileName: string; Attempt: Integer;
  var Password: string; var Cancel: Boolean);
begin
  Cancel := not AskPassword(FileName, Attempt, Password);
end;

procedure TMainForm.ViewerOpenURI(Sender: TObject; const URI: string);
begin
  {$IFDEF MSWINDOWS}
  ShellExecute(0, 'open', PChar(URI), nil, nil, 1);
  {$ELSE}
  TDialogService.ShowMessage('Link: ' + URI);
  {$ENDIF}
end;

procedure TMainForm.ViewerSelectionChange(Sender: TObject);
var
  S: string;
begin
  S := Viewer.SelectedText;
  if S <> '' then
    SetStatus(Format('%d tekens geselecteerd - Ctrl+C kopieert', [Length(S)]))
  else
    SetStatus('');
end;

procedure TMainForm.ViewerChanged(Sender: TObject; Change: TPdfViewerChange);
begin
  case Change of
    vcDocument:
      begin
        FillOutline;
        FillInfo;
        ResultsList.Clear;
        ResultsLabel.Text := '';
        UpdateUI;
      end;
    vcPage:
      UpdatePageControls;
    vcZoom:
      UpdateZoomControls;
    vcRotation, vcDisplayMode:
      UpdateUI;
    vcPageImage:
      UpdateInfoLabel;
    vcSearch:
      begin
        if ResultsList.Count = Viewer.SearchMatchCount then
        begin
          Inc(FUpdating);
          try
            ResultsList.ItemIndex := Viewer.ActiveMatch;
          finally
            Dec(FUpdating);
          end;
        end;
        if Viewer.SearchMatchCount > 0 then
          SetStatus(Format('Resultaat %d van %d voor "%s"', [Viewer.ActiveMatch + 1, Viewer.SearchMatchCount,
            Viewer.SearchQuery]))
        else if Viewer.SearchQuery <> '' then
          SetStatus('Niet gevonden: ' + Viewer.SearchQuery)
        else
          SetStatus('');
      end;
  end;
end;

{ UI state }

procedure TMainForm.UpdateUI;
var
  Loaded: Boolean;
begin
  Loaded := Viewer.IsLoaded;
  actClose.Enabled := Loaded;
  actFirstPage.Enabled := Loaded;
  actPrevPage.Enabled := Loaded;
  actNextPage.Enabled := Loaded;
  actLastPage.Enabled := Loaded;
  actGoToPage.Enabled := Loaded;
  actZoomIn.Enabled := Loaded;
  actZoomOut.Enabled := Loaded;
  actActualSize.Enabled := Loaded;
  actFitWidth.Enabled := Loaded;
  actFitPage.Enabled := Loaded;
  actRotateLeft.Enabled := Loaded;
  actRotateRight.Enabled := Loaded;
  actPrint.Enabled := Loaded and PrintingSupported;
  actExportPng150.Enabled := Loaded;
  actExportPng300.Enabled := Loaded;
  actCopyPageImage.Enabled := Loaded;
  actCopyPageText.Enabled := Loaded;
  actFindNext.Enabled := Loaded;
  actFindPrev.Enabled := Loaded;
  FirstButton.Enabled := Loaded;
  PrevButton.Enabled := Loaded;
  NextButton.Enabled := Loaded;
  LastButton.Enabled := Loaded;
  PageEdit.Enabled := Loaded;
  ZoomOutButton.Enabled := Loaded;
  ZoomInButton.Enabled := Loaded;
  ZoomTrack.Enabled := Loaded;
  ZoomButton.Enabled := Loaded;
  FitWidthButton.Enabled := Loaded;
  FitPageButton.Enabled := Loaded;
  RotateLeftButton.Enabled := Loaded;
  RotateRightButton.Enabled := Loaded;
  LayoutButton.Enabled := Loaded;
  PrintButton.Enabled := Loaded and PrintingSupported;
  ExportButton.Enabled := Loaded;
  SearchEdit.Enabled := Loaded;
  FindNextButton.Enabled := Loaded;
  FindPrevButton.Enabled := Loaded;
  actModeContinuous.Checked := Viewer.DisplayMode = dmContinuous;
  actModeSingle.Checked := Viewer.DisplayMode = dmSinglePage;
  actModeFacingContinuous.Checked := Viewer.DisplayMode = dmFacingContinuous;
  actModeFacing.Checked := Viewer.DisplayMode = dmFacing;
  actCoverPage.Checked := Viewer.FacingCoverPage;
  actCoverPage.Enabled := Viewer.DisplayMode in [dmFacingContinuous, dmFacing];
  actSidebar.Checked := Sidebar.Visible;
  actTheme.Checked := FDark;
  UpdatePageControls;
  UpdateZoomControls;
  UpdateStatus;
end;

procedure TMainForm.UpdatePageControls;
begin
  if Viewer.IsLoaded then
  begin
    if not PageEdit.IsFocused then
      PageEdit.Text := IntToStr(Viewer.CurrentPage + 1);
    PageCountLabel.Text := Format('/ %d', [Viewer.PageCount]);
    actFirstPage.Enabled := Viewer.CurrentPage > 0;
    actPrevPage.Enabled := Viewer.CurrentPage > 0;
    actNextPage.Enabled := Viewer.CurrentPage < Viewer.PageCount - 1;
    actLastPage.Enabled := Viewer.CurrentPage < Viewer.PageCount - 1;
    FirstButton.Enabled := actFirstPage.Enabled;
    PrevButton.Enabled := actPrevPage.Enabled;
    NextButton.Enabled := actNextPage.Enabled;
    LastButton.Enabled := actLastPage.Enabled;
  end
  else
  begin
    PageEdit.Text := '';
    PageCountLabel.Text := '/ -';
  end;
  UpdateStatus;
end;

procedure TMainForm.UpdateZoomControls;
begin
  Inc(FUpdating);
  try
    ZoomButton.Text := Format('%d%%', [Round(Viewer.Zoom * 100)]);
    ZoomTrack.Value := ZoomToTrack(Viewer.Zoom);
    actFitWidth.Checked := Viewer.ZoomMode = zmFitWidth;
    actFitPage.Checked := Viewer.ZoomMode = zmFitPage;
    FitWidthButton.IsPressed := Viewer.ZoomMode = zmFitWidth;
    FitPageButton.IsPressed := Viewer.ZoomMode = zmFitPage;
  finally
    Dec(FUpdating);
  end;
end;

procedure TMainForm.SetStatus(const S: string);
begin
  FStatusOverride := S;
  UpdateStatus;
end;

procedure TMainForm.UpdateStatus;
var
  Pages: TArray<Integer>;
begin
  if FStatusOverride <> '' then
    StatusLabel.Text := FStatusOverride
  else if Viewer.IsLoaded then
  begin
    Pages := Viewer.RowPages(Viewer.CurrentPage);
    if Length(Pages) = 2 then
      StatusLabel.Text := Format('%s  -  pagina %d-%d van %d', [ExtractFileName(Viewer.FileName), Pages[0] + 1,
        Pages[1] + 1, Viewer.PageCount])
    else
      StatusLabel.Text := Format('%s  -  pagina %d van %d', [ExtractFileName(Viewer.FileName),
        Viewer.CurrentPage + 1, Viewer.PageCount]);
  end
  else
    StatusLabel.Text := 'Open een PDF (Ctrl+O) of sleep een bestand in het venster';
  UpdateInfoLabel;
end;

procedure TMainForm.UpdateInfoLabel;
var
  S: string;
begin
  if not Viewer.IsLoaded then
  begin
    InfoLabel.Text := '';
    Exit;
  end;
  S := Format('PDF %s  -  %d pagina''s  -  %s', [Viewer.Document.Version, Viewer.PageCount,
    FormatFileSize(TFile.GetSize(Viewer.FileName))]);
  if Viewer.Document.IsEncrypted then
    S := S + '  -  versleuteld';
  if Viewer.Rotation <> 0 then
    S := S + Format('  -  %d'#176, [Viewer.Rotation]);
  if Viewer.RenderErrors > 0 then
    S := S + Format('  -  %d renderfout(en)', [Viewer.RenderErrors]);
  InfoLabel.Text := S;
end;

{ Navigation }

procedure TMainForm.actFirstPageExecute(Sender: TObject);
begin
  Viewer.GoToPage(0);
end;

procedure TMainForm.actPrevPageExecute(Sender: TObject);
begin
  Viewer.PreviousPage;
end;

procedure TMainForm.actNextPageExecute(Sender: TObject);
begin
  Viewer.NextPage;
end;

procedure TMainForm.actLastPageExecute(Sender: TObject);
begin
  Viewer.GoToPage(Viewer.PageCount - 1);
end;

procedure TMainForm.actGoToPageExecute(Sender: TObject);
begin
  PageEdit.SetFocus;
  PageEdit.SelectAll;
end;

procedure TMainForm.PageEditKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
var
  N: Integer;
begin
  if Key = vkReturn then
  begin
    N := StrToIntDef(PageEdit.Text, 0);
    if (N >= 1) and (N <= Viewer.PageCount) then
    begin
      Viewer.GoToPage(N - 1);
      Viewer.SetFocus;
    end
    else
      PageEdit.Text := IntToStr(Viewer.CurrentPage + 1);
    Key := 0;
  end
  else if Key = vkEscape then
  begin
    PageEdit.Text := IntToStr(Viewer.CurrentPage + 1);
    Viewer.SetFocus;
    Key := 0;
  end;
end;

procedure TMainForm.PageEditExit(Sender: TObject);
begin
  if Viewer.IsLoaded then
    PageEdit.Text := IntToStr(Viewer.CurrentPage + 1);
end;

{ Zoom }

function TMainForm.TrackToZoom(V: Double): Double;
begin
  Result := Viewer.MinZoom * Exp(V / ZoomTrack.Max * Ln(Viewer.MaxZoom / Viewer.MinZoom));
end;

function TMainForm.ZoomToTrack(Z: Double): Double;
begin
  Z := EnsureRange(Z, Viewer.MinZoom, Viewer.MaxZoom);
  Result := Ln(Z / Viewer.MinZoom) / Ln(Viewer.MaxZoom / Viewer.MinZoom) * ZoomTrack.Max;
end;

procedure TMainForm.ZoomTrackChange(Sender: TObject);
begin
  if (FUpdating = 0) and Viewer.IsLoaded then
    Viewer.Zoom := TrackToZoom(ZoomTrack.Value);
end;

procedure TMainForm.actZoomInExecute(Sender: TObject);
begin
  Viewer.ZoomIn;
end;

procedure TMainForm.actZoomOutExecute(Sender: TObject);
begin
  Viewer.ZoomOut;
end;

procedure TMainForm.actActualSizeExecute(Sender: TObject);
begin
  Viewer.Zoom := 1;
end;

procedure TMainForm.actFitWidthExecute(Sender: TObject);
begin
  Viewer.FitWidth;
end;

procedure TMainForm.actFitPageExecute(Sender: TObject);
begin
  Viewer.FitPage;
end;

procedure TMainForm.ZoomButtonClick(Sender: TObject);
begin
  PopupBelow(ZoomMenu, ZoomButton);
end;

procedure TMainForm.ZoomMenuClick(Sender: TObject);
var
  Tag: Integer;
begin
  Tag := (Sender as TMenuItem).Tag;
  case Tag of
    -1: Viewer.FitWidth;
    -2: Viewer.FitPage;
  else
    if Tag > 0 then
      Viewer.Zoom := Tag / 100;
  end;
end;

{ Rotation and layout }

procedure TMainForm.actRotateLeftExecute(Sender: TObject);
begin
  Viewer.RotateCounterClockwise;
end;

procedure TMainForm.actRotateRightExecute(Sender: TObject);
begin
  Viewer.RotateClockwise;
end;

procedure TMainForm.LayoutButtonClick(Sender: TObject);
begin
  PopupBelow(LayoutMenu, LayoutButton);
end;

procedure TMainForm.actModeExecute(Sender: TObject);
begin
  if Sender = actModeContinuous then
    Viewer.DisplayMode := dmContinuous
  else if Sender = actModeSingle then
    Viewer.DisplayMode := dmSinglePage
  else if Sender = actModeFacingContinuous then
    Viewer.DisplayMode := dmFacingContinuous
  else if Sender = actModeFacing then
    Viewer.DisplayMode := dmFacing;
  UpdateUI;
end;

procedure TMainForm.actCoverPageExecute(Sender: TObject);
begin
  Viewer.FacingCoverPage := not Viewer.FacingCoverPage;
  UpdateUI;
end;

{ Sidebar }

procedure TMainForm.SetSidebarVisible(Value: Boolean);
begin
  Sidebar.Visible := Value;
  Splitter.Visible := Value;
  actSidebar.Checked := Value;
  SidebarButton.IsPressed := Value;
end;

procedure TMainForm.actSidebarExecute(Sender: TObject);
begin
  SetSidebarVisible(not Sidebar.Visible);
end;

procedure TMainForm.ShowSidebarTab(Tab: TTabItem);
begin
  SetSidebarVisible(True);
  SideTabs.ActiveTab := Tab;
end;

procedure TMainForm.actPropertiesExecute(Sender: TObject);
begin
  ShowSidebarTab(TabInfo);
end;

procedure TMainForm.FillOutline;

  procedure AddItems(const Items: TObjectList<TPdfOutlineItem>; Parent: TFmxObject);
  var
    It: TPdfOutlineItem;
    TI: TTreeViewItem;
  begin
    for It in Items do
    begin
      TI := TTreeViewItem.Create(OutlineTree);
      TI.Text := It.Title;
      TI.TagObject := It;
      TI.OnClick := OutlineItemClick;
      TI.Parent := Parent;
      AddItems(It.Children, TI);
      TI.IsExpanded := It.IsOpen;
    end;
  end;

begin
  Inc(FUpdating);
  OutlineTree.BeginUpdate;
  try
    OutlineTree.Clear;
    if (Viewer.Outline <> nil) and (Viewer.Outline.Count > 0) then
      AddItems(Viewer.Outline, OutlineTree);
  finally
    OutlineTree.EndUpdate;
    Dec(FUpdating);
  end;
  if OutlineTree.Count > 0 then
    TabOutline.Text := 'Inhoud'
  else
    TabOutline.Text := 'Inhoud';
end;

procedure TMainForm.OutlineItemClick(Sender: TObject);
begin
  if (FUpdating = 0) and (Sender is TTreeViewItem) and (TTreeViewItem(Sender).TagObject is TPdfOutlineItem) then
    Viewer.GoToOutlineItem(TPdfOutlineItem(TTreeViewItem(Sender).TagObject));
end;

procedure TMainForm.OutlineTreeChange(Sender: TObject);
begin
  if (FUpdating = 0) and (OutlineTree.Selected <> nil) and (OutlineTree.Selected.TagObject is TPdfOutlineItem) then
    Viewer.GoToOutlineItem(TPdfOutlineItem(OutlineTree.Selected.TagObject));
end;

procedure TMainForm.AddInfo(const Key, Value: string);
var
  Row: Integer;
begin
  if Value = '' then
    Exit;
  Row := InfoGrid.RowCount;
  InfoGrid.RowCount := Row + 1;
  InfoGrid.Cells[0, Row] := Key;
  InfoGrid.Cells[1, Row] := Value;
end;

procedure TMainForm.FillInfo;
var
  W, H: Double;
  Paper: string;
begin
  InfoGrid.RowCount := 0;
  if not Viewer.IsLoaded then
    Exit;
  AddInfo('Bestand', ExtractFileName(Viewer.FileName));
  AddInfo('Map', ExtractFilePath(Viewer.FileName));
  AddInfo('Grootte', FormatFileSize(TFile.GetSize(Viewer.FileName)));
  AddInfo('PDF-versie', Viewer.Document.Version);
  AddInfo('Pagina''s', IntToStr(Viewer.PageCount));
  if Viewer.PageCount > 0 then
  begin
    W := Viewer.Document.Pages[0].GetDisplayWidth;
    H := Viewer.Document.Pages[0].GetDisplayHeight;
    Paper := PaperName(W, H);
    if Paper <> '' then
      Paper := '  (' + Paper + ')';
    AddInfo('Paginaformaat', Format('%.0f x %.0f pt  =  %.0f x %.0f mm%s', [W, H, W * 25.4 / 72, H * 25.4 / 72, Paper]));
  end;
  AddInfo('Titel', Viewer.Document.GetInfoText('Title'));
  AddInfo('Auteur', Viewer.Document.GetInfoText('Author'));
  AddInfo('Onderwerp', Viewer.Document.GetInfoText('Subject'));
  AddInfo('Trefwoorden', Viewer.Document.GetInfoText('Keywords'));
  AddInfo('Gemaakt met', Viewer.Document.GetInfoText('Creator'));
  AddInfo('Producer', Viewer.Document.GetInfoText('Producer'));
  AddInfo('Aangemaakt', PdfDateToStr(Viewer.Document.GetInfoText('CreationDate')));
  AddInfo('Gewijzigd', PdfDateToStr(Viewer.Document.GetInfoText('ModDate')));
  AddInfo('Versleuteld', IfThen(Viewer.Document.IsEncrypted, 'ja', 'nee'));
  if Viewer.Document.PageTreeRecovered then
    AddInfo('Herstel', 'paginaboom hersteld door scannen');
  AddInfo('Bladwijzers', IntToStr(OutlineTree.GlobalCount));
end;

{ Search }

procedure TMainForm.actSearchExecute(Sender: TObject);
begin
  SearchEdit.SetFocus;
  SearchEdit.SelectAll;
end;

procedure TMainForm.DoFind;
var
  N: Integer;
begin
  if not Viewer.IsLoaded then
    Exit;
  SetStatus('Zoeken naar "' + SearchEdit.Text + '" ...');
  Application.ProcessMessages;
  N := Viewer.Find(SearchEdit.Text, CaseCheck.IsChecked, WholeWordCheck.IsChecked);
  FillSearchResults;
  if N > 0 then
    ShowSidebarTab(TabSearch)
  else if SearchEdit.Text <> '' then
    SetStatus('Niet gevonden: ' + SearchEdit.Text)
  else
    SetStatus('');
end;

function TMainForm.MatchContext(const SM: TPdfSearchMatch): string;
const
  Before = 24;
  After = 40;
var
  TP: TPdfTextPage;
  Text: string;
  A, B: Integer;
begin
  TP := Viewer.TextPage(SM.PageIndex);
  if TP = nil then
    Exit('');
  Text := TP.Text;
  A := Max(1, SM.Match.CharIndex + 1 - Before);
  B := Min(Length(Text), SM.Match.CharIndex + 1 + SM.Match.CharLength + After);
  Result := Copy(Text, A, B - A + 1).Replace(#13, ' ').Replace(#10, ' ').Replace('  ', ' ');
  if A > 1 then
    Result := '...' + Result;
  if B < Length(Text) then
    Result := Result + '...';
end;

procedure TMainForm.FillSearchResults;
var
  I, N: Integer;
  Item: TListBoxItem;
  SM: TPdfSearchMatch;
begin
  N := Viewer.SearchMatchCount;
  Inc(FUpdating);
  ResultsList.BeginUpdate;
  try
    ResultsList.Clear;
    for I := 0 to N - 1 do
    begin
      SM := Viewer.SearchMatch(I);
      Item := TListBoxItem.Create(ResultsList);
      Item.Text := Format('p. %d   %s', [SM.PageIndex + 1, MatchContext(SM)]);
      Item.Tag := I;
      Item.WordWrap := True;
      Item.Height := 40;
      ResultsList.AddObject(Item);
    end;
    ResultsList.ItemIndex := Viewer.ActiveMatch;
  finally
    ResultsList.EndUpdate;
    Dec(FUpdating);
  end;
  if Viewer.SearchQuery = '' then
    ResultsLabel.Text := ''
  else if N = 0 then
    ResultsLabel.Text := 'Geen resultaten voor "' + Viewer.SearchQuery + '"'
  else
    ResultsLabel.Text := Format('%d resultaten voor "%s"', [N, Viewer.SearchQuery]);
  if N > 0 then
    TabSearch.Text := 'Zoeken'
  else
    TabSearch.Text := 'Zoeken';
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
    end
    else
      DoFind;
    Key := 0;
  end
  else if Key = vkEscape then
  begin
    SearchEdit.Text := '';
    Viewer.ClearSearch;
    FillSearchResults;
    Viewer.SetFocus;
    Key := 0;
  end;
end;

procedure TMainForm.SearchOptionChange(Sender: TObject);
begin
  if (FUpdating = 0) and (SearchEdit.Text <> '') and Viewer.IsLoaded then
    DoFind;
end;

procedure TMainForm.actFindNextExecute(Sender: TObject);
begin
  if not SameText(Viewer.SearchQuery, SearchEdit.Text) then
    DoFind
  else
    Viewer.FindNext;
end;

procedure TMainForm.actFindPrevExecute(Sender: TObject);
begin
  if not SameText(Viewer.SearchQuery, SearchEdit.Text) then
    DoFind
  else
    Viewer.FindPrevious;
end;

procedure TMainForm.ResultsListItemClick(const Sender: TCustomListBox; const Item: TListBoxItem);
begin
  if (FUpdating = 0) and (Item <> nil) then
    Viewer.GoToMatch(Item.Tag);
end;

{ Export, clipboard, printing }

procedure TMainForm.ExportButtonClick(Sender: TObject);
begin
  PopupBelow(ExportMenu, ExportButton);
end;

procedure TMainForm.actExportPngExecute(Sender: TObject);
begin
  if Sender = actExportPng300 then
    ExportPng(300)
  else
    ExportPng(150);
end;

procedure TMainForm.ExportPng(Dpi: Integer);
var
  Img: ISkImage;
  Page: Integer;
begin
  if not Viewer.IsLoaded then
    Exit;
  Page := Viewer.CurrentPage;
  SaveDialog.FileName := Format('%s-p%d.png', [ChangeFileExt(ExtractFileName(Viewer.FileName), ''), Page + 1]);
  if not SaveDialog.Execute then
    Exit;
  SetStatus(Format('Pagina %d exporteren op %d dpi ...', [Page + 1, Dpi]));
  Application.ProcessMessages;
  Img := Viewer.RenderPageToImage(Page, Dpi / 72);
  if (Img <> nil) and Img.EncodeToFile(SaveDialog.FileName) then
    SetStatus(Format('Pagina %d opgeslagen als %s (%d x %d px)', [Page + 1, ExtractFileName(SaveDialog.FileName),
      Img.Width, Img.Height]))
  else
    SetStatus('Exporteren mislukt');
end;

procedure TMainForm.actCopyPageImageExecute(Sender: TObject);
var
  Img: ISkImage;
  Bmp: FMX.Graphics.TBitmap;
  Surface: TBitmapSurface;
  Svc: IFMXExtendedClipboardService;
begin
  if not Viewer.IsLoaded then
    Exit;
  if not TPlatformServices.Current.SupportsPlatformService(IFMXExtendedClipboardService, Svc) then
  begin
    SetStatus('Het klembord ondersteunt hier geen afbeeldingen');
    Exit;
  end;
  Img := Viewer.RenderPageToImage(Viewer.CurrentPage, 2);
  if Img = nil then
    Exit;
  Bmp := FMX.Graphics.TBitmap.CreateFromSkImage(Img);
  try
    Surface := BitmapToSurface(Bmp);
    try
      Svc.SetImage(Surface);
    finally
      Surface.Free;
    end;
  finally
    Bmp.Free;
  end;
  SetStatus(Format('Pagina %d als afbeelding naar het klembord gekopieerd (%d x %d px)', [Viewer.CurrentPage + 1,
    Img.Width, Img.Height]));
end;

procedure TMainForm.actCopyPageTextExecute(Sender: TObject);
var
  TP: TPdfTextPage;
  Svc: IFMXClipboardService;
  S: string;
begin
  if not Viewer.IsLoaded then
    Exit;
  TP := Viewer.TextPage(Viewer.CurrentPage);
  if TP = nil then
    Exit;
  S := TP.Text;
  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService, Svc) then
  begin
    Svc.SetClipboard(S);
    SetStatus(Format('Tekst van pagina %d gekopieerd (%d tekens)', [Viewer.CurrentPage + 1, Length(S)]));
  end;
end;

procedure TMainForm.actPrintExecute(Sender: TObject);
var
  Printers: TArray<string>;
  Active, PrinterIndex, First, Last: Integer;
  Task: ITask;
  SW: TStopwatch;
begin
  Active := -1;
  if not Viewer.IsLoaded or not PrintingSupported then
    Exit;
  // Enumerating printers can block for a long time when a network printer is unreachable: do it on a task
  SetStatus('Printers opzoeken ...');
  Task := TTask.Run(
    procedure
    begin
      Printers := PrinterNames(Active);
    end);
  SW := TStopwatch.StartNew;
  try
    while not Task.Wait(50) do
    begin
      Application.ProcessMessages;
      if SW.ElapsedMilliseconds > 15000 then
      begin
        SetStatus('');
        TDialogService.ShowMessage('De printerlijst komt niet beschikbaar (een netwerkprinter reageert niet?). Probeer het later opnieuw.');
        Exit;
      end;
    end;
  except
    on E: Exception do
    begin
      SetStatus('');
      TDialogService.ShowMessage('Printers opvragen mislukt: ' + E.Message);
      Exit;
    end;
  end;
  SetStatus('');
  if Length(Printers) = 0 then
  begin
    TDialogService.ShowMessage('Er is geen printer gevonden.');
    Exit;
  end;
  if not ShowPrintDialog(Printers, Active, Viewer.PageCount, Viewer.CurrentPage, PrinterIndex, First, Last) then
    Exit;
  SetStatus(Format('Pagina''s %d-%d afdrukken ...', [First + 1, Last + 1]));
  Application.ProcessMessages;
  try
    PrintPdfPages(Viewer, PrinterIndex, First, Last, ExtractFileName(Viewer.FileName));
    SetStatus(Format('%d pagina''s naar %s gestuurd', [Last - First + 1, Printers[PrinterIndex]]));
  except
    on E: Exception do
    begin
      SetStatus('');
      TDialogService.ShowMessage('Afdrukken mislukt: ' + E.Message);
    end;
  end;
end;

{ Theme, full screen, help }

procedure TMainForm.actThemeExecute(Sender: TObject);
begin
  ApplyTheme(not FDark);
  UpdateUI;
end;

procedure TMainForm.actFullScreenExecute(Sender: TObject);
begin
  FullScreen := not FullScreen;
end;

procedure TMainForm.actHelpExecute(Sender: TObject);
begin
  HelpOverlay.Visible := not HelpOverlay.Visible;
  if HelpOverlay.Visible then
    HelpOverlay.BringToFront;
end;

procedure TMainForm.HelpOverlayClick(Sender: TObject);
begin
  HelpOverlay.Visible := False;
end;

procedure TMainForm.FillHelp;
const
  Lines: array[0..31] of string = (
    'Bestand',
    '  Ctrl+O            Openen            Ctrl+W           Sluiten',
    '  Ctrl+P            Afdrukken         Ctrl+E           Pagina exporteren als PNG',
    '  Ctrl+Shift+C      Pagina als afbeelding kopieren',
    '  Ctrl+Shift+T      Tekst van de pagina kopieren',
    '  Ctrl+I            Documenteigenschappen',
    '  Sleep een PDF in het venster om hem te openen',
    '',
    'Navigeren',
    '  PgUp / PgDn       Schermhoogte      Ctrl+PgUp/PgDn   Vorige/volgende pagina',
    '  Home / End        Begin/einde       Ctrl+Home/End    Eerste/laatste pagina',
    '  Ctrl+G            Naar pagina       Pijltjes         Scrollen',
    '',
    'Zoomen en weergave',
    '  Ctrl+Plus/Min     In-/uitzoomen     Ctrl+muiswiel    Zoomen rond de cursor',
    '  Ctrl+0            Breedte passend   Ctrl+9           Pagina passend',
    '  Ctrl+1            Ware grootte      + / - / 0        Zoomen (viewer)',
    '  Ctrl+R            Rechtsom draaien  Ctrl+Shift+R     Linksom draaien',
    '  Ctrl+Shift+1..4   Doorlopend / Enkele pagina / Dubbel doorlopend / Dubbel',
    '  Ctrl+B            Zijpaneel         Ctrl+T           Licht/donker thema',
    '  F11               Volledig scherm   Esc              Sluit overlay / volledig scherm',
    '',
    'Zoeken en tekst',
    '  Ctrl+F            Zoeken            Enter/Shift+Enter  Volgende/vorige',
    '  F3 / Shift+F3     Volgende/vorige   Esc              Zoekresultaten wissen',
    '  Slepen over tekst Selecteren        Dubbelklik       Woord selecteren',
    '  Ctrl+A            Pagina selecteren Ctrl+C           Selectie kopieren',
    '',
    'Muis en aanraking',
    '  Slepen            Pannen            Shift+muiswiel   Horizontaal scrollen',
    '  Knijpen           Zoomen            Dubbeltikken     Zoom wisselen',
    '  F1                Dit overzicht');
var
  S: string;
begin
  HelpMemo.Lines.BeginUpdate;
  try
    HelpMemo.Lines.Clear;
    for S in Lines do
      HelpMemo.Lines.Add(S);
  finally
    HelpMemo.Lines.EndUpdate;
  end;
end;

end.
