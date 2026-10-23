program PdfViewerDemo;

uses
  System.StartUpCopy,
  FMX.Types,
  FMX.Forms,
  Demo.Main in 'Demo.Main.pas' {MainForm};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
