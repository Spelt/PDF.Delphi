program PdfViewerMobileDemo;

uses
  System.StartUpCopy,
  FMX.Types,
  FMX.Forms,
  FMX.Skia,
  Mobile.Main in 'Mobile.Main.pas' {MainForm};

{$R *.res}
{$R 'MobileDemo.res' 'MobileDemo.rc'}

begin
  GlobalUseSkia := True;

  GlobalUseMetal := true;
  GlobalUseVulkan := true;

  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
