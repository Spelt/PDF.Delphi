unit Demo.Settings;

{ Persistent demo settings (theme, sidebar, display mode, recent files) in an
  INI file under the user's application-data folder. }

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.IniFiles;

type
  TDemoSettings = class
  private const
    MaxRecent = 10;
  private
    FIni: TMemIniFile;
    FRecent: TStringList;
    FFileName: string;
    procedure LoadRecent;
    procedure SaveRecent;
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary>Writes the INI file (called from Save and from the destructor).</summary>
    procedure Save;
    function ReadString(const Key, Default: string): string;
    function ReadInteger(const Key: string; Default: Integer): Integer;
    function ReadBool(const Key: string; Default: Boolean): Boolean;
    procedure WriteString(const Key, Value: string);
    procedure WriteInteger(const Key: string; Value: Integer);
    procedure WriteBool(const Key: string; Value: Boolean);
    /// <summary>Moves (or adds) a file to the front of the recent list.</summary>
    procedure AddRecent(const FileName: string);
    procedure RemoveRecent(const FileName: string);
    procedure ClearRecent;
    property Recent: TStringList read FRecent;
    property FileName: string read FFileName;
  end;

implementation

const
  Section = 'Viewer';

constructor TDemoSettings.Create;
var
  Dir: string;
begin
  inherited Create;
  Dir := TPath.Combine(TPath.GetHomePath, 'PdfViewerDemo');
  try
    TDirectory.CreateDirectory(Dir);
  except
    Dir := TPath.GetTempPath;
  end;
  FFileName := TPath.Combine(Dir, 'settings.ini');
  FIni := TMemIniFile.Create(FFileName, TEncoding.UTF8);
  FRecent := TStringList.Create;
  LoadRecent;
end;

destructor TDemoSettings.Destroy;
begin
  Save;
  FRecent.Free;
  FIni.Free;
  inherited;
end;

procedure TDemoSettings.Save;
begin
  SaveRecent;
  try
    FIni.UpdateFile;
  except
    // a read-only profile must not break the viewer
  end;
end;

function TDemoSettings.ReadString(const Key, Default: string): string;
begin
  Result := FIni.ReadString(Section, Key, Default);
end;

function TDemoSettings.ReadInteger(const Key: string; Default: Integer): Integer;
begin
  Result := FIni.ReadInteger(Section, Key, Default);
end;

function TDemoSettings.ReadBool(const Key: string; Default: Boolean): Boolean;
begin
  Result := FIni.ReadBool(Section, Key, Default);
end;

procedure TDemoSettings.WriteString(const Key, Value: string);
begin
  FIni.WriteString(Section, Key, Value);
end;

procedure TDemoSettings.WriteInteger(const Key: string; Value: Integer);
begin
  FIni.WriteInteger(Section, Key, Value);
end;

procedure TDemoSettings.WriteBool(const Key: string; Value: Boolean);
begin
  FIni.WriteBool(Section, Key, Value);
end;

procedure TDemoSettings.LoadRecent;
var
  I: Integer;
  S: string;
begin
  FRecent.Clear;
  for I := 0 to MaxRecent - 1 do
  begin
    S := FIni.ReadString('Recent', 'File' + IntToStr(I), '');
    if S <> '' then
      FRecent.Add(S);
  end;
end;

procedure TDemoSettings.SaveRecent;
var
  I: Integer;
begin
  FIni.EraseSection('Recent');
  for I := 0 to FRecent.Count - 1 do
    FIni.WriteString('Recent', 'File' + IntToStr(I), FRecent[I]);
end;

procedure TDemoSettings.AddRecent(const FileName: string);
var
  I: Integer;
begin
  I := FRecent.IndexOf(FileName);
  if I >= 0 then
    FRecent.Delete(I);
  FRecent.Insert(0, FileName);
  while FRecent.Count > MaxRecent do
    FRecent.Delete(FRecent.Count - 1);
end;

procedure TDemoSettings.RemoveRecent(const FileName: string);
var
  I: Integer;
begin
  I := FRecent.IndexOf(FileName);
  if I >= 0 then
    FRecent.Delete(I);
end;

procedure TDemoSettings.ClearRecent;
begin
  FRecent.Clear;
end;

end.
