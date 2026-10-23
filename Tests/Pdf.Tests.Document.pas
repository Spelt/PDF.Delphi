unit Pdf.Tests.Document;

interface

uses
  System.SysUtils, DUnitX.TestFramework, Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Document, Pdf.Tests.Builder;

type
  [TestFixture]
  TPdfDocumentTests = class
  private
    FDoc: TPdfDocument;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure SimpleDocumentPages;
    [Test] procedure DefaultMediaBoxAndRotateNormalisation;
    [Test] procedure InheritedAttributes;
    [Test] procedure CropBoxIntersectsMediaBox;
    [Test] procedure NestedPageTreeWithWrongCount;
    [Test] procedure PageTreeLoopTerminates;
    [Test] procedure BrokenPageTreeIsRecoveredByScanning;
    [Test] procedure ContentArrayIsConcatenated;
    [Test] procedure InfoAndVersion;
    [Test] procedure InvalidInputRaises;
    [Test] procedure EncryptedSamplesOpen;
    [Test] procedure UserPasswordRequired;
    [Test] procedure CloseAndReload;
    [Test] procedure RepeatedLoadsDoNotLeak;
  end;

implementation

procedure TPdfDocumentTests.Setup;
begin
  FDoc := TPdfDocument.Create;
end;

procedure TPdfDocumentTests.TearDown;
begin
  FDoc.Free;
end;

procedure TPdfDocumentTests.SimpleDocumentPages;
var
  B: TPdfTestBuilder;
  P: TPdfPage;
begin
  B := TPdfTestBuilder.SimpleDocument(3);
  try
    FDoc.LoadFromBytes(B.Build(1));
    Assert.IsTrue(FDoc.IsLoaded);
    Assert.AreEqual('1.4', FDoc.Version);
    Assert.AreEqual(3, FDoc.PageCount);
    Assert.IsFalse(FDoc.PageTreeRecovered);
    P := FDoc.Pages[1];
    Assert.AreEqual(1, P.Index);
    Assert.AreEqual(5, P.ObjectNumber);
    Assert.IsTrue(P.Dictionary.IsType('Page'));
    Assert.AreEqual(1, Integer(Length(P.GetContentStreams)));
    Assert.AreEqual('BT /F1 12 Tf 10 10 Td (Page 2) Tj ET'#10, StrOf(P.GetContentData));
    Assert.IsNotNull(P.Resources);
    Assert.AreEqual(0, P.Resources.Count);
    Assert.IsNull(P.GetAnnotations);
    Assert.WillRaise(procedure begin FDoc.Pages[3]; end, EPdfException);
  finally
    B.Free;
  end;
end;

procedure TPdfDocumentTests.DefaultMediaBoxAndRotateNormalisation;
var
  B: TPdfTestBuilder;
  P: TPdfPage;
begin
  B := TPdfTestBuilder.SimpleDocument(1, '', '/Rotate -90 /MediaBox [0 0 0 0]');
  try
    FDoc.LoadFromBytes(B.Build(1));
    P := FDoc.Pages[0];
    Assert.AreEqual(612.0, P.MediaBox.Width, 1E-9);
    Assert.AreEqual(792.0, P.MediaBox.Height, 1E-9);
    Assert.AreEqual(270, P.Rotate);
    Assert.AreEqual(792.0, P.GetDisplayWidth, 1E-9);
    Assert.AreEqual(612.0, P.GetDisplayHeight, 1E-9);
  finally
    B.Free;
  end;
  B := TPdfTestBuilder.SimpleDocument(1, '', '/Rotate 450');
  try
    FDoc.LoadFromBytes(B.Build(1));
    Assert.AreEqual(90, FDoc.Pages[0].Rotate);
  finally
    B.Free;
  end;
end;

procedure TPdfDocumentTests.InheritedAttributes;
var
  B: TPdfTestBuilder;
  P: TPdfPage;
begin
  B := TPdfTestBuilder.SimpleDocument(2, '/MediaBox [0 0 200 100] /Rotate 180 /Resources << /Font << /F1 7 0 R >> >>', '');
  try
    B.Replace(5, '<< /Type /Page /Parent 2 0 R /Contents 6 0 R /MediaBox [10 10 110 60] /Rotate 0 >>');
    B.Add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
    FDoc.LoadFromBytes(B.Build(1));
    P := FDoc.Pages[0];
    Assert.AreEqual(200.0, P.MediaBox.Width, 1E-9);
    Assert.AreEqual(180, P.Rotate);
    Assert.IsTrue(P.Resources.GetDictionary('Font').GetDictionary('F1').IsType('Font'));
    P := FDoc.Pages[1];
    Assert.AreEqual(100.0, P.MediaBox.Width, 1E-9);
    Assert.AreEqual(10.0, P.MediaBox.X0, 1E-9);
    Assert.AreEqual(0, P.Rotate);
    Assert.IsTrue(P.Resources.Contains('Font'));
  finally
    B.Free;
  end;
end;

procedure TPdfDocumentTests.CropBoxIntersectsMediaBox;
var
  B: TPdfTestBuilder;
  P: TPdfPage;
begin
  B := TPdfTestBuilder.SimpleDocument(1, '', '/MediaBox [0 0 100 100] /CropBox [50 50 300 300]');
  try
    FDoc.LoadFromBytes(B.Build(1));
    P := FDoc.Pages[0];
    Assert.AreEqual(50.0, P.CropBox.X0, 1E-9);
    Assert.AreEqual(100.0, P.CropBox.X1, 1E-9);
    Assert.AreEqual(50.0, P.GetDisplayWidth, 1E-9);
  finally
    B.Free;
  end;
  B := TPdfTestBuilder.SimpleDocument(1, '', '/MediaBox [0 0 100 100] /CropBox [500 500 600 600]');
  try
    FDoc.LoadFromBytes(B.Build(1));
    // No overlap: fall back to the MediaBox
    Assert.AreEqual(100.0, FDoc.Pages[0].CropBox.Width, 1E-9);
  finally
    B.Free;
  end;
end;

procedure TPdfDocumentTests.NestedPageTreeWithWrongCount;
var
  B: TPdfTestBuilder;
begin
  B := TPdfTestBuilder.Create;
  try
    B.Add('<< /Type /Catalog /Pages 2 0 R >>');
    B.Add('<< /Type /Pages /Count 99 /Kids [3 0 R 6 0 R null 42 0 R] >>');
    B.Add('<< /Type /Pages /Parent 2 0 R /Count 2 /Kids [4 0 R 5 0 R] >>');
    B.Add('<< /Type /Page /Parent 3 0 R >>');
    B.Add('<< /Parent 3 0 R /Contents 7 0 R >>'); // no /Type but has /Contents
    B.Add('<< /Type /Page /Parent 2 0 R >>');
    B.AddStream('<< >>', 'q Q');
    FDoc.LoadFromBytes(B.Build(1));
    Assert.AreEqual(3, FDoc.PageCount);
    Assert.AreEqual(4, FDoc.Pages[0].ObjectNumber);
    Assert.AreEqual(5, FDoc.Pages[1].ObjectNumber);
    Assert.AreEqual(6, FDoc.Pages[2].ObjectNumber);
    Assert.AreEqual('q Q'#10, StrOf(FDoc.Pages[1].GetContentData));
  finally
    B.Free;
  end;
end;

procedure TPdfDocumentTests.PageTreeLoopTerminates;
var
  B: TPdfTestBuilder;
begin
  B := TPdfTestBuilder.Create;
  try
    B.Add('<< /Type /Catalog /Pages 2 0 R >>');
    B.Add('<< /Type /Pages /Count 1 /Kids [3 0 R 2 0 R] >>');
    B.Add('<< /Type /Pages /Parent 2 0 R /Kids [2 0 R 4 0 R 4 0 R] >>');
    B.Add('<< /Type /Page /Parent 3 0 R >>');
    FDoc.LoadFromBytes(B.Build(1));
    Assert.AreEqual(1, FDoc.PageCount);
  finally
    B.Free;
  end;
end;

procedure TPdfDocumentTests.BrokenPageTreeIsRecoveredByScanning;
var
  B: TPdfTestBuilder;
begin
  B := TPdfTestBuilder.SimpleDocument(2, '/MediaBox [0 0 300 300]');
  try
    B.Replace(1, '<< /Type /Catalog /Pages 99 0 R >>'); // dangling reference
    FDoc.LoadFromBytes(B.Build(1));
    Assert.AreEqual(2, FDoc.PageCount);
    Assert.IsTrue(FDoc.PageTreeRecovered);
    Assert.AreEqual(3, FDoc.Pages[0].ObjectNumber);
    // Inherited through /Parent
    Assert.AreEqual(300.0, FDoc.Pages[1].MediaBox.Width, 1E-9);
    Assert.AreEqual('BT /F1 12 Tf 10 10 Td (Page 2) Tj ET'#10, StrOf(FDoc.Pages[1].GetContentData));
  finally
    B.Free;
  end;
end;

procedure TPdfDocumentTests.ContentArrayIsConcatenated;
var
  B: TPdfTestBuilder;
begin
  B := TPdfTestBuilder.Create;
  try
    B.Add('<< /Type /Catalog /Pages 2 0 R >>');
    B.Add('<< /Type /Pages /Count 1 /Kids [3 0 R] >>');
    B.Add('<< /Type /Page /Parent 2 0 R /Contents [4 0 R 99 0 R 5 0 R] >>');
    B.AddStream('<< >>', 'q 1 0 0 1 0 0 cm');
    B.AddStream('<< >>', 'Q');
    FDoc.LoadFromBytes(B.Build(1));
    Assert.AreEqual(2, Integer(Length(FDoc.Pages[0].GetContentStreams)));
    Assert.AreEqual('q 1 0 0 1 0 0 cm'#10'Q'#10, StrOf(FDoc.Pages[0].GetContentData));
  finally
    B.Free;
  end;
end;

procedure TPdfDocumentTests.InfoAndVersion;
var
  B: TPdfTestBuilder;
begin
  B := TPdfTestBuilder.SimpleDocument(1);
  try
    B.Replace(1, '<< /Type /Catalog /Pages 2 0 R /Version /1.6 >>');
    B.Add('<< /Title (Testdocument) /Author <FEFF00C9006400> >>');
    FDoc.LoadFromBytes(B.Build(1, '/Info 5 0 R'));
    Assert.AreEqual('1.6', FDoc.Version);
    Assert.AreEqual('Testdocument', FDoc.GetInfoText('Title'));
    Assert.AreEqual(#$00C9'd', FDoc.GetInfoText('Author'));
    Assert.AreEqual('', FDoc.GetInfoText('Subject'));
    Assert.IsTrue(FDoc.Catalog.IsType('Catalog'));
    Assert.IsTrue(FDoc.Trailer.Contains('Root'));
  finally
    B.Free;
  end;
end;

procedure TPdfDocumentTests.InvalidInputRaises;
begin
  Assert.WillRaise(procedure begin FDoc.LoadFromBytes(nil); end, EPdfInvalidDocument);
  Assert.WillRaise(procedure begin FDoc.LoadFromBytes(BytesOf('this is not a pdf file at all')); end, EPdfInvalidDocument);
  Assert.IsFalse(FDoc.IsLoaded);
  Assert.WillRaise(procedure begin FDoc.PageCount; end, EPdfException);
end;

procedure TPdfDocumentTests.EncryptedSamplesOpen;
const
  Files: array[0..3] of string = ('enc_rc4_40.pdf', 'enc_rc4_128.pdf', 'enc_aes128.pdf', 'enc_aes256.pdf');
var
  F: string;
  Content: string;
begin
  for F in Files do
  begin
    FDoc.LoadFromFile(TestDataFile(F));
    Assert.IsTrue(FDoc.IsEncrypted, F);
    Assert.AreEqual(1, FDoc.PageCount, F);
    Content := StrOf(FDoc.Pages[0].GetContentData);
    Assert.IsTrue(Content.Contains('(Hello) Tj'), F + ': ' + Content);
  end;
end;

procedure TPdfDocumentTests.UserPasswordRequired;
begin
  Assert.WillRaise(procedure begin FDoc.LoadFromFile(TestDataFile('enc_aes256_user.pdf')); end, EPdfPasswordError);
  Assert.IsFalse(FDoc.IsLoaded);
  FDoc.LoadFromFile(TestDataFile('enc_aes256_user.pdf'), 'user');
  Assert.IsTrue(StrOf(FDoc.Pages[0].GetContentData).Contains('(Hello) Tj'));
  FDoc.LoadFromFile(TestDataFile('enc_aes256_user.pdf'), 'owner');
  Assert.IsTrue(FDoc.XRef.SecurityHandler.IsOwner);
  Assert.IsTrue(StrOf(FDoc.Pages[0].GetContentData).Contains('(Hello) Tj'));
end;

procedure TPdfDocumentTests.CloseAndReload;
var
  B: TPdfTestBuilder;
  Page: IPdfDictionary;
begin
  B := TPdfTestBuilder.SimpleDocument(2);
  try
    FDoc.LoadFromBytes(B.Build(1));
    Page := FDoc.Pages[0].Dictionary;
    FDoc.Close;
    Assert.IsFalse(FDoc.IsLoaded);
    // A dictionary kept by the caller stays valid, references now resolve to null
    Assert.IsTrue(Page.IsType('Page'));
    Assert.AreEqual(okNull, Page.Get('Contents').Kind);
    FDoc.LoadFromBytes(B.Build(1));
    Assert.AreEqual(2, FDoc.PageCount);
  finally
    B.Free;
  end;
end;

{$WARN SYMBOL_PLATFORM OFF}
procedure TPdfDocumentTests.RepeatedLoadsDoNotLeak;
var
  B: TPdfTestBuilder;
  Data, Enc: TBytes;
  I: Integer;
  Before, After: NativeUInt;

  function AllocatedBytes: NativeUInt;
  var
    State: TMemoryManagerState;
    J: Integer;
  begin
    GetMemoryManagerState(State);
    Result := State.TotalAllocatedMediumBlockSize + State.TotalAllocatedLargeBlockSize;
    for J := 0 to High(State.SmallBlockTypeStates) do
      Inc(Result, State.SmallBlockTypeStates[J].UseableBlockSize * State.SmallBlockTypeStates[J].AllocatedBlockCount);
  end;

  procedure Round;
  var
    Doc: TPdfDocument;
    K: Integer;
  begin
    Doc := TPdfDocument.Create;
    try
      Doc.LoadFromBytes(Data);
      for K := 0 to Doc.PageCount - 1 do
        Doc.Pages[K].GetContentData;
      Doc.LoadFromBytes(Enc);
      Doc.Pages[0].GetContentData;
      try
        Doc.LoadFromBytes(Enc, 'wrong');
      except
        on EPdfPasswordError do
          ;
      end;
    finally
      Doc.Free;
    end;
  end;

begin
  B := TPdfTestBuilder.SimpleDocument(5);
  try
    Data := B.Build(1);
  finally
    B.Free;
  end;
  Enc := LoadFileBytes(TestDataFile('enc_aes256_user.pdf'));
  // Password-protected file: open with the right password inside Round via a wrapper
  Enc := LoadFileBytes(TestDataFile('enc_aes128.pdf'));
  Round;
  Before := AllocatedBytes;
  for I := 1 to 50 do
    Round;
  After := AllocatedBytes;
  Assert.IsTrue(After <= Before + 4096, Format('Allocated bytes grew from %d to %d over 50 rounds', [Before, After]));
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfDocumentTests);

end.
