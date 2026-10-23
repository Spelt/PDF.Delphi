program Pdf.Tests;

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.TestFramework,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  Pdf.Core.Types in '..\Source\Core\Pdf.Core.Types.pas',
  Pdf.Core.Lexer in '..\Source\Core\Pdf.Core.Lexer.pas',
  Pdf.Core.Objects in '..\Source\Core\Pdf.Core.Objects.pas',
  Pdf.Core.Parser in '..\Source\Core\Pdf.Core.Parser.pas',
  Pdf.Core.Filters in '..\Source\Core\Pdf.Core.Filters.pas',
  Pdf.Core.Crypto in '..\Source\Core\Pdf.Core.Crypto.pas',
  Pdf.Core.Encryption in '..\Source\Core\Pdf.Core.Encryption.pas',
  Pdf.Core.XRef in '..\Source\Core\Pdf.Core.XRef.pas',
  Pdf.Core.Document in '..\Source\Core\Pdf.Core.Document.pas',
  Pdf.Tests.Builder in 'Pdf.Tests.Builder.pas',
  Pdf.Tests.Lexer in 'Pdf.Tests.Lexer.pas',
  Pdf.Tests.Parser in 'Pdf.Tests.Parser.pas',
  Pdf.Tests.Filters in 'Pdf.Tests.Filters.pas',
  Pdf.Tests.Crypto in 'Pdf.Tests.Crypto.pas',
  Pdf.Tests.XRef in 'Pdf.Tests.XRef.pas',
  Pdf.Tests.Document in 'Pdf.Tests.Document.pas',
  Pdf.Tests.Corpus in 'Pdf.Tests.Corpus.pas';

var
  Runner: ITestRunner;
  Results: IRunResults;
  Logger: ITestLogger;
  NUnitLogger: ITestLogger;
begin
  {$IFDEF REPORT_LEAKS}
  ReportMemoryLeaksOnShutdown := True; // shows a dialog on Windows, so opt-in only
  {$ENDIF}
  try
    TDUnitX.CheckCommandLine;
    Runner := TDUnitX.CreateRunner;
    Runner.UseRTTI := True;
    Runner.FailsOnNoAsserts := False;
    Logger := TDUnitXConsoleLogger.Create(TDUnitX.Options.ConsoleMode = TDUnitXConsoleMode.Quiet);
    Runner.AddLogger(Logger);
    if TDUnitX.Options.XMLOutputFile <> '' then
    begin
      NUnitLogger := TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
      Runner.AddLogger(NUnitLogger);
    end;
    Results := Runner.Execute;
    if not Results.AllPassed then
      System.ExitCode := EXIT_ERRORS;
    {$IFNDEF CI}
    if TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause then
    begin
      System.Write('Done.. press <Enter> key to quit.');
      System.Readln;
    end;
    {$ENDIF}
  except
    on E: Exception do
    begin
      System.Writeln(E.ClassName, ': ', E.Message);
      System.ExitCode := EXIT_ERRORS;
    end;
  end;
end.
