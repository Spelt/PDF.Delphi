program PdfViewerMobileDemo;

uses
  System.StartUpCopy,
  FMX.Forms,
  Mobile.Main in 'Mobile.Main.pas' {MainForm};

{$R *.res}
{$R 'MobileDemo.res' 'MobileDemo.rc'}

begin
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
