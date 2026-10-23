unit Pdf.Tests.XRef;

interface

uses
  System.SysUtils, System.Generics.Collections, DUnitX.TestFramework,
  Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.XRef, Pdf.Tests.Builder;

type
  [TestFixture]
  TPdfXRefTests = class
  private
    FOpened: TList<TPdfXRef>;
    FKeep: TList<IPdfResolver>;
    /// <summary>Creates and parses an xref; the fixture detaches it in TearDown (the trailer keeps a reference cycle alive until then).</summary>
    function Open(const Data: TBytes; const Password: string = ''): TPdfXRef;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure ClassicTable;
    [Test] procedure IncrementalUpdateNewestWins;
    [Test] procedure XRefStreamAndObjectStream;
    [Test] procedure WrongStartXRefOffsetTriggersReconstruct;
    [Test] procedure MissingXRefUsesTrailerFromScan;
    [Test] procedure NoTrailerFindsCatalogByScan;
    [Test] procedure GarbageBeforeHeader;
    [Test] procedure ShiftedOffsetsAreRepairedOnFetch;
    [Test] procedure FreeAndMissingObjectsAreNull;
    [Test] procedure ReferenceCycleDoesNotHang;
    [Test] procedure SubsectionStartingAtOneIsCorrected;
    [Test] procedure EncryptedSampleIsDecrypted;
    [Test] procedure DetachMakesFetchesNull;
  end;

implementation

procedure TPdfXRefTests.Setup;
begin
  FOpened := TList<TPdfXRef>.Create;
  FKeep := TList<IPdfResolver>.Create;
end;

procedure TPdfXRefTests.TearDown;
var
  X: TPdfXRef;
begin
  for X in FOpened do
    X.Detach;
  FOpened.Free;
  FKeep.Free;
end;

function TPdfXRefTests.Open(const Data: TBytes; const Password: string): TPdfXRef;
var
  Keep: IPdfResolver;
begin
  Result := TPdfXRef.Create(Data, Password);
  Keep := Result;
  try
    Result.Parse;
  except
    Result.Detach;
    raise;
  end;
  FOpened.Add(Result);
  FKeep.Add(Keep);
end;

procedure TPdfXRefTests.ClassicTable;
var
  B: TPdfTestBuilder;
  X: TPdfXRef;
  XI: IPdfResolver;
  E: TPdfXRefEntry;
begin
  B := TPdfTestBuilder.SimpleDocument(2);
  try
    X := Open(B.Build(1));
    XI := X;
    Assert.IsFalse(X.IsReconstructed);
    Assert.IsFalse(X.IsEncrypted);
    Assert.AreEqual<Int64>(7, X.Trailer.GetInteger('Size'));
    Assert.AreEqual(okReference, X.Trailer.GetRaw('Root').Kind);
    Assert.IsTrue(PdfAsDictionary(X.Trailer.Get('Root')).IsType('Catalog'));
    Assert.AreEqual(7, Integer(Length(X.ObjectNumbers)));
    Assert.IsTrue(X.TryGetEntry(0, E));
    Assert.AreEqual(xeFree, E.EntryType);
    Assert.IsTrue(X.TryGetEntry(3, E));
    Assert.AreEqual(xeOffset, E.EntryType);
    Assert.IsTrue(PdfAsDictionary(X.FetchObject(3, 0)).IsType('Page'));
    Assert.AreEqual(okStream, X.FetchObject(4, 0).Kind);
    Assert.AreEqual(4, PdfAsStream(X.FetchObject(4, 0)).ObjNum);
    // Same instance from the cache
    Assert.IsTrue(X.FetchObject(3, 0) = X.FetchObject(3, 0));
  finally
    B.Free;
  end;
end;

procedure TPdfXRefTests.IncrementalUpdateNewestWins;
var
  B: TPdfTestBuilder;
  Data: TBytes;
  X: TPdfXRef;
  XI: IPdfResolver;
begin
  B := TPdfTestBuilder.SimpleDocument(1);
  try
    Data := B.Build(1, '/ID [<01> <02>]');
    Data := TPdfTestBuilder.AppendUpdate(Data, [3, 5], ['<< /Type /Page /Parent 2 0 R /Rotate 90 >>', '(new object)'], 1);
    X := Open(Data);
    XI := X;
    Assert.IsFalse(X.IsReconstructed);
    Assert.AreEqual<Int64>(90, PdfAsDictionary(X.FetchObject(3, 0)).GetInteger('Rotate'));
    Assert.AreEqual('new object', PdfAsString(X.FetchObject(5, 0)).AsText);
    // Objects and trailer keys from the previous section are still there
    Assert.AreEqual(okStream, X.FetchObject(4, 0).Kind);
    Assert.IsNotNull(X.Trailer.GetArray('ID'));
    Assert.IsTrue(X.Trailer.Contains('Prev'));
  finally
    B.Free;
  end;
end;

procedure TPdfXRefTests.XRefStreamAndObjectStream;
var
  B: TPdfTestBuilder;
  X: TPdfXRef;
  XI: IPdfResolver;
  E: TPdfXRefEntry;
begin
  B := TPdfTestBuilder.SimpleDocument(2);
  try
    // Catalog, Pages and both page dicts live in an object stream; content streams stay direct
    X := Open(B.BuildWithXRefStream(1, [1, 2, 3, 5]));
    XI := X;
    Assert.IsFalse(X.IsReconstructed);
    Assert.IsTrue(X.TryGetEntry(1, E));
    Assert.AreEqual(xeCompressed, E.EntryType);
    Assert.AreEqual<Int64>(7, E.Offset);
    Assert.IsTrue(X.TryGetEntry(4, E));
    Assert.AreEqual(xeOffset, E.EntryType);
    Assert.IsTrue(PdfAsDictionary(X.FetchObject(1, 0)).IsType('Catalog'));
    Assert.IsTrue(PdfAsDictionary(X.FetchObject(5, 0)).IsType('Page'));
    Assert.AreEqual(okStream, X.FetchObject(6, 0).Kind);
    Assert.IsTrue(X.Trailer.IsType('XRef'));
    Assert.IsTrue(PdfAsDictionary(X.Trailer.Get('Root')).IsType('Catalog'));
    // Resolving through the dictionary works too
    Assert.AreEqual(2, PdfAsDictionary(X.FetchObject(1, 0)).GetDictionary('Pages').GetArray('Kids').Count);
  finally
    B.Free;
  end;
end;

procedure TPdfXRefTests.WrongStartXRefOffsetTriggersReconstruct;
var
  B: TPdfTestBuilder;
  S: string;
  X: TPdfXRef;
  XI: IPdfResolver;
begin
  B := TPdfTestBuilder.SimpleDocument(1);
  try
    S := StrOf(B.Build(1));
    S := StringReplace(S, 'startxref'#10, 'startxref'#10'9', []); // prefix a digit: wrong offset
    X := Open(BytesOf(S));
    XI := X;
    Assert.IsTrue(X.IsReconstructed);
    Assert.IsTrue(PdfAsDictionary(X.Trailer.Get('Root')).IsType('Catalog'));
    Assert.IsTrue(PdfAsDictionary(X.FetchObject(3, 0)).IsType('Page'));
    Assert.AreEqual('BT /F1 12 Tf 10 10 Td (Page 1) Tj ET', StrOf(PdfAsStream(X.FetchObject(4, 0)).GetDecodedData));
  finally
    B.Free;
  end;
end;

procedure TPdfXRefTests.MissingXRefUsesTrailerFromScan;
var
  B: TPdfTestBuilder;
  S: string;
  X: TPdfXRef;
  XI: IPdfResolver;
  P: Integer;
begin
  B := TPdfTestBuilder.SimpleDocument(1);
  try
    S := StrOf(B.Build(1, '/Info 4 0 R'));
    // Cut out the xref table but keep the trailer dictionary
    P := S.IndexOf('xref'#10);
    S := Copy(S, 1, P) + Copy(S, S.IndexOf('trailer') + 1, MaxInt);
    X := Open(BytesOf(S));
    XI := X;
    Assert.IsTrue(X.IsReconstructed);
    Assert.IsTrue(PdfAsDictionary(X.Trailer.Get('Root')).IsType('Catalog'));
    Assert.IsTrue(X.Trailer.Contains('Info'));
  finally
    B.Free;
  end;
end;

procedure TPdfXRefTests.NoTrailerFindsCatalogByScan;
var
  B: TPdfTestBuilder;
  S: string;
  X: TPdfXRef;
  XI: IPdfResolver;
begin
  B := TPdfTestBuilder.SimpleDocument(1);
  try
    S := StrOf(B.Build(1));
    S := Copy(S, 1, S.IndexOf('xref'#10)); // nothing after the last endobj
    X := Open(BytesOf(S));
    XI := X;
    Assert.IsTrue(X.IsReconstructed);
    Assert.AreEqual(1, PdfAsReference(X.Trailer.GetRaw('Root')).Num);
    Assert.IsTrue(PdfAsDictionary(X.Trailer.Get('Root')).IsType('Catalog'));
  finally
    B.Free;
  end;
end;

procedure TPdfXRefTests.GarbageBeforeHeader;
var
  B: TPdfTestBuilder;
  X: TPdfXRef;
  XI: IPdfResolver;
begin
  B := TPdfTestBuilder.SimpleDocument(1);
  try
    X := Open(BytesOf('GARBAGE LINE'#13#10) + B.Build(1));
    XI := X;
    Assert.AreEqual(14, X.Base);
    Assert.IsFalse(X.IsReconstructed);
    Assert.IsTrue(PdfAsDictionary(X.FetchObject(3, 0)).IsType('Page'));
  finally
    B.Free;
  end;
end;

procedure TPdfXRefTests.ShiftedOffsetsAreRepairedOnFetch;
var
  B: TPdfTestBuilder;
  S: string;
  X: TPdfXRef;
  XI: IPdfResolver;
begin
  B := TPdfTestBuilder.SimpleDocument(1);
  try
    S := StrOf(B.Build(1));
    // Insert bytes after the header so that every table offset is off by 20, startxref too
    S := StringReplace(S, '%PDF-1.4'#10, '%PDF-1.4'#10 + StringOfChar('%', 19) + #10, []);
    X := Open(BytesOf(S));
    XI := X;
    // The table itself was found by scanning (startxref is wrong), objects come out right
    Assert.IsTrue(PdfAsDictionary(X.FetchObject(3, 0)).IsType('Page'));
    Assert.IsTrue(PdfAsDictionary(X.FetchObject(1, 0)).IsType('Catalog'));
  finally
    B.Free;
  end;
end;

procedure TPdfXRefTests.FreeAndMissingObjectsAreNull;
var
  B: TPdfTestBuilder;
  X: TPdfXRef;
  XI: IPdfResolver;
begin
  B := TPdfTestBuilder.SimpleDocument(1);
  try
    X := Open(B.Build(1));
    XI := X;
    Assert.AreEqual(okNull, X.FetchObject(0, 0).Kind);
    Assert.AreEqual(okNull, X.FetchObject(999, 0).Kind);
    Assert.AreEqual(okNull, X.FetchObject(-5, 0).Kind);
    Assert.AreEqual(okNull, X.Resolve(PdfReference(999, 0)).Kind);
    Assert.AreEqual(okNull, X.Resolve(nil).Kind);
    Assert.AreEqual<Int64>(3, PdfAsInteger(X.Resolve(PdfInteger(3))));
  finally
    B.Free;
  end;
end;

procedure TPdfXRefTests.ReferenceCycleDoesNotHang;
var
  B: TPdfTestBuilder;
  X: TPdfXRef;
  XI: IPdfResolver;
begin
  B := TPdfTestBuilder.Create;
  try
    B.Add('<< /Type /Catalog /Pages 2 0 R /Loop 3 0 R >>');
    B.Add('<< /Type /Pages /Kids [] /Count 0 >>');
    B.Add('4 0 R');
    B.Add('3 0 R');
    B.Add('<< /Length 5 0 R >>'#10'stream'#10'abc'#10'endstream'); // /Length refers to itself
    X := Open(B.Build(1));
    XI := X;
    Assert.AreEqual(okNull, X.Resolve(PdfReference(3, 0)).Kind);
    Assert.AreEqual('abc', StrOf(PdfAsStream(X.FetchObject(5, 0)).RawData));
  finally
    B.Free;
  end;
end;

procedure TPdfXRefTests.SubsectionStartingAtOneIsCorrected;
var
  B: TPdfTestBuilder;
  S: string;
  X: TPdfXRef;
  XI: IPdfResolver;
begin
  B := TPdfTestBuilder.SimpleDocument(1);
  try
    S := StrOf(B.Build(1));
    S := StringReplace(S, 'xref'#10'0 5', 'xref'#10'1 5', []);
    X := Open(BytesOf(S));
    XI := X;
    Assert.IsFalse(X.IsReconstructed);
    Assert.IsTrue(PdfAsDictionary(X.FetchObject(1, 0)).IsType('Catalog'));
  finally
    B.Free;
  end;
end;

procedure TPdfXRefTests.EncryptedSampleIsDecrypted;
var
  X: TPdfXRef;
  XI: IPdfResolver;
  Content: string;
begin
  X := Open(LoadFileBytes(TestDataFile('enc_aes128.pdf')));
  XI := X;
  Assert.IsTrue(X.IsEncrypted);
  Assert.IsFalse(X.SecurityHandler.IsOwner);
  Content := StrOf(PdfAsStream(X.FetchObject(4, 0)).GetDecodedData);
  Assert.IsTrue(Content.Contains('(Hello) Tj'), Content);
  // Owner password
  X := Open(LoadFileBytes(TestDataFile('enc_aes128.pdf')), 'owner');
  XI := X;
  Assert.IsTrue(X.SecurityHandler.IsOwner);
  // Wrong password
  Assert.WillRaise(
    procedure
    begin
      Open(LoadFileBytes(TestDataFile('enc_aes256_user.pdf')), 'wrong');
    end, EPdfPasswordError);
end;

procedure TPdfXRefTests.DetachMakesFetchesNull;
var
  B: TPdfTestBuilder;
  X: TPdfXRef;
  XI: IPdfResolver;
  Page: IPdfDictionary;
begin
  B := TPdfTestBuilder.SimpleDocument(1);
  try
    X := Open(B.Build(1));
    XI := X;
    Page := PdfAsDictionary(X.FetchObject(3, 0));
    X.Detach;
    Assert.AreEqual(okNull, X.FetchObject(3, 0).Kind);
    // Objects that are still referenced survive, but their references resolve to null now
    Assert.IsTrue(Page.IsType('Page'));
    Assert.AreEqual(okNull, Page.Get('Contents').Kind);
  finally
    B.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfXRefTests);

end.
