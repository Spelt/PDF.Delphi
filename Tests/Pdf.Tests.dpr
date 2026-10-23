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
  Pdf.Render.Functions in '..\Source\Render\Pdf.Render.Functions.pas',
  Pdf.Render.ColorSpaces in '..\Source\Render\Pdf.Render.ColorSpaces.pas',
  Pdf.Render.Content in '..\Source\Render\Pdf.Render.Content.pas',
  Pdf.Render.State in '..\Source\Render\Pdf.Render.State.pas',
  Pdf.Render.Images in '..\Source\Render\Pdf.Render.Images.pas',
  Pdf.Render.Shading in '..\Source\Render\Pdf.Render.Shading.pas',
  Pdf.Font.Glyphs in '..\Source\Font\Pdf.Font.Glyphs.pas',
  Pdf.Font.TrueType in '..\Source\Font\Pdf.Font.TrueType.pas',
  Pdf.Font.CFF in '..\Source\Font\Pdf.Font.CFF.pas',
  Pdf.Font.Type1 in '..\Source\Font\Pdf.Font.Type1.pas',
  Pdf.Font.Encodings in '..\Source\Font\Pdf.Font.Encodings.pas',
  Pdf.Font.GlyphList in '..\Source\Font\Pdf.Font.GlyphList.pas',
  Pdf.Font.StandardFonts in '..\Source\Font\Pdf.Font.StandardFonts.pas',
  Pdf.Font.CMap in '..\Source\Font\Pdf.Font.CMap.pas',
  Pdf.Font.Loader in '..\Source\Font\Pdf.Font.Loader.pas',
  Pdf.Core.Navigation in '..\Source\Core\Pdf.Core.Navigation.pas',
  Pdf.Codec.CCITT in '..\Source\Render\Pdf.Codec.CCITT.pas',
  Pdf.Codec.JBIG2 in '..\Source\Render\Pdf.Codec.JBIG2.pas',
  Pdf.Codec.JPX in '..\Source\Render\Pdf.Codec.JPX.pas',
  Pdf.Codec.JPX.Primitives in '..\Source\Render\Pdf.Codec.JPX.Primitives.pas',
  Pdf.Codec.JBIG2.Arith in '..\Source\Render\Pdf.Codec.JBIG2.Arith.pas',
  Pdf.Codec.JBIG2.Huffman in '..\Source\Render\Pdf.Codec.JBIG2.Huffman.pas',
  Pdf.Render.Skia in '..\Source\Render\Pdf.Render.Skia.pas',
  Pdf.Render.Text in '..\Source\Render\Pdf.Render.Text.pas',
  Pdf.Viewer.Layout in '..\Source\Viewer\Pdf.Viewer.Layout.pas',
  Pdf.Viewer.Cache in '..\Source\Viewer\Pdf.Viewer.Cache.pas',
  Pdf.Viewer.RenderQueue in '..\Source\Viewer\Pdf.Viewer.RenderQueue.pas',
  Pdf.Tests.Builder in 'Pdf.Tests.Builder.pas',
  Pdf.Tests.Lexer in 'Pdf.Tests.Lexer.pas',
  Pdf.Tests.Parser in 'Pdf.Tests.Parser.pas',
  Pdf.Tests.Filters in 'Pdf.Tests.Filters.pas',
  Pdf.Tests.Crypto in 'Pdf.Tests.Crypto.pas',
  Pdf.Tests.XRef in 'Pdf.Tests.XRef.pas',
  Pdf.Tests.Document in 'Pdf.Tests.Document.pas',
  Pdf.Tests.Corpus in 'Pdf.Tests.Corpus.pas',
  Pdf.Tests.Functions in 'Pdf.Tests.Functions.pas',
  Pdf.Tests.ColorSpaces in 'Pdf.Tests.ColorSpaces.pas',
  Pdf.Tests.Images in 'Pdf.Tests.Images.pas',
  Pdf.Tests.Render in 'Pdf.Tests.Render.pas',
  Pdf.Tests.Font.TrueType in 'Pdf.Tests.Font.TrueType.pas',
  Pdf.Tests.Font.CFF in 'Pdf.Tests.Font.CFF.pas',
  Pdf.Tests.Font.Type1 in 'Pdf.Tests.Font.Type1.pas',
  Pdf.Tests.Font.Tables in 'Pdf.Tests.Font.Tables.pas',
  Pdf.Tests.Font.CMap in 'Pdf.Tests.Font.CMap.pas',
  Pdf.Tests.Text in 'Pdf.Tests.Text.pas',
  Pdf.Tests.Viewer in 'Pdf.Tests.Viewer.pas',
  Pdf.Tests.Phase5 in 'Pdf.Tests.Phase5.pas',
  Pdf.Tests.Codec.CCITT in 'Pdf.Tests.Codec.CCITT.pas',
  Pdf.Tests.Codec.JBIG2 in 'Pdf.Tests.Codec.JBIG2.pas',
  Pdf.Tests.Codec.JPX in 'Pdf.Tests.Codec.JPX.pas',
  Pdf.Tests.Mesh in 'Pdf.Tests.Mesh.pas';

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
