unit Pdf.Tests.Corpus;

{ Opens every PDF in the corpus folders and reads all pages. A file passes when
  it loads without an exception (a password error counts as a pass), every
  page's content can be fetched, and it does so within a time limit.

  Folders: Tests\Corpus (next to Tests\Data) plus every folder in the
  environment variable PDF_CORPUS_DIRS (separated by ';'), searched recursively.
  Point PDF_CORPUS_DIRS at a checkout of pdf.js\test\pdfs for the full run. }

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Diagnostics, System.Generics.Collections,
  DUnitX.TestFramework, Pdf.Core.Types, Pdf.Core.Document, Pdf.Tests.Builder;

type
  [TestFixture]
  TPdfCorpusTests = class
  private
    function CorpusFiles: TArray<string>;
  public
    [Test] procedure AllFilesOpenAndAllPagesLoad;
  end;

implementation

const
  MaxMillisecondsPerFile = 20000;

function TPdfCorpusTests.CorpusFiles: TArray<string>;
var
  Dirs: TList<string>;
  Dir, Env: string;
  Files: TList<string>;
begin
  Dirs := TList<string>.Create;
  Files := TList<string>.Create;
  try
    Dirs.Add(TPath.GetFullPath(TPath.Combine(TestDataPath, '..\Corpus')));
    Env := GetEnvironmentVariable('PDF_CORPUS_DIRS');
    for Dir in Env.Split([';']) do
      if Trim(Dir) <> '' then
        Dirs.Add(Trim(Dir));
    for Dir in Dirs do
      if TDirectory.Exists(Dir) then
        Files.AddRange(TDirectory.GetFiles(Dir, '*.pdf', TSearchOption.soAllDirectories));
    Files.Sort;
    Result := Files.ToArray;
  finally
    Files.Free;
    Dirs.Free;
  end;
end;

procedure TPdfCorpusTests.AllFilesOpenAndAllPagesLoad;
var
  Files: TArray<string>;
  F: string;
  Doc: TPdfDocument;
  Failures: TStringList;
  I, PasswordCount, OkCount: Integer;
  SW: TStopwatch;
begin
  Files := CorpusFiles;
  if Length(Files) = 0 then
  begin
    TDUnitX.CurrentRunner.Log(TLogLevel.Warning, 'No corpus files found (set PDF_CORPUS_DIRS or fill Tests\Corpus)');
    Assert.Pass('No corpus files');
    Exit;
  end;
  Failures := TStringList.Create;
  Doc := TPdfDocument.Create;
  try
    PasswordCount := 0;
    OkCount := 0;
    for F in Files do
    begin
      SW := TStopwatch.StartNew;
      try
        Doc.LoadFromFile(F);
        for I := 0 to Doc.PageCount - 1 do
          Doc.Pages[I].GetContentData;
        Doc.Close;
        if SW.ElapsedMilliseconds > MaxMillisecondsPerFile then
          Failures.Add(Format('%s: took %d ms', [ExtractFileName(F), SW.ElapsedMilliseconds]))
        else
          Inc(OkCount);
      except
        on E: EPdfPasswordError do
          Inc(PasswordCount);
        on E: Exception do
          Failures.Add(Format('%s: %s: %s', [ExtractFileName(F), E.ClassName, E.Message]));
      end;
    end;
    TDUnitX.CurrentRunner.Log(TLogLevel.Information,
      Format('Corpus: %d files, %d ok, %d need a password, %d failed', [Length(Files), OkCount, PasswordCount, Failures.Count]));
    Assert.AreEqual(0, Failures.Count, #10 + Failures.Text);
  finally
    Doc.Free;
    Failures.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfCorpusTests);

end.
