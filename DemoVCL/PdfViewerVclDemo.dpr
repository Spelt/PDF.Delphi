program PdfViewerVclDemo;

uses
  Vcl.Forms,
  VclDemo.Main in 'VclDemo.Main.pas' {MainForm};

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
