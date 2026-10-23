program PdfViewerDemo;

uses
  System.StartUpCopy,
  FMX.Types,
  FMX.Forms,
  Demo.Main in 'Demo.Main.pas' {MainForm},
  Demo.Icons in 'Demo.Icons.pas',
  Demo.Settings in 'Demo.Settings.pas',
  Demo.Printing in 'Demo.Printing.pas',
  Demo.Password in 'Demo.Password.pas' {PasswordForm},
  Demo.PrintDialog in 'Demo.PrintDialog.pas' {PrintForm};

{$R *.res}
{$R 'Demo.Styles.res' 'Demo.Styles.rc'}

begin
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
