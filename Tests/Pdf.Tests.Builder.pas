unit Pdf.Tests.Builder;

{ Builds small PDF files in memory for the xref and document tests:
  classic xref tables, xref streams with object streams, incremental updates. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.IOUtils,
  Pdf.Core.Types;

type
  TPdfTestBuilder = class
  private
    FBodies: TList<string>;
    FVersion: string;
    function ObjectHeader(Num: Integer): string;
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary>Adds an object body (Latin-1 source) and returns its object number (1-based, sequential).</summary>
    function Add(const Body: string): Integer;
    /// <summary>Adds a stream object; Dict is the dictionary source without /Length, e.g. '<< /Filter /FlateDecode >>'.</summary>
    function AddStream(const Dict, Data: string): Integer;
    procedure Replace(Num: Integer; const Body: string);
    function Count: Integer;
    /// <summary>Classic layout: header, objects, xref table, trailer.</summary>
    function Build(RootNum: Integer; const ExtraTrailer: string = ''): TBytes;
    /// <summary>PDF 1.5 layout: the objects in ObjStmNums are packed in an object stream, the table is an xref stream.</summary>
    function BuildWithXRefStream(RootNum: Integer; const ObjStmNums: TArray<Integer>; const ExtraTrailer: string = ''): TBytes;
    /// <summary>Appends an incremental update (classic table with /Prev) that replaces or adds the given objects.</summary>
    class function AppendUpdate(const Base: TBytes; const Nums: array of Integer; const Bodies: array of string;
      RootNum: Integer; const ExtraTrailer: string = ''): TBytes;
    /// <summary>Catalog (1), Pages (2) and PageCount pages, each with a content stream "BT (Page n) Tj ET".</summary>
    class function SimpleDocument(PageCount: Integer; const PagesExtra: string = ''; const PageExtra: string = ''): TPdfTestBuilder;
    property Version: string read FVersion write FVersion;
  end;

/// <summary>Folder Tests\Data, located by walking up from the executable.</summary>
function TestDataPath: string;
function TestDataFile(const Name: string): string;
function BytesOf(const S: string): TBytes;
function StrOf(const B: TBytes): string;
function LoadFileBytes(const FileName: string): TBytes;

implementation

function BytesOf(const S: string): TBytes;
begin
  Result := PdfLatin1ToBytes(S);
end;

function StrOf(const B: TBytes): string;
begin
  Result := PdfBytesToLatin1(B);
end;

function LoadFileBytes(const FileName: string): TBytes;
begin
  Result := TFile.ReadAllBytes(FileName);
end;

function TestDataPath: string;
var
  Dir: string;
  I: Integer;
begin
  Dir := ExtractFilePath(ParamStr(0));
  for I := 0 to 6 do
  begin
    if TDirectory.Exists(TPath.Combine(Dir, 'Tests\Data')) then
      Exit(TPath.Combine(Dir, 'Tests\Data'));
    if TDirectory.Exists(TPath.Combine(Dir, 'Data')) and TFile.Exists(TPath.Combine(Dir, 'Pdf.Tests.dpr')) then
      Exit(TPath.Combine(Dir, 'Data'));
    Dir := TPath.GetFullPath(TPath.Combine(Dir, '..'));
  end;
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'Data');
end;

function TestDataFile(const Name: string): string;
begin
  Result := TPath.Combine(TestDataPath, Name);
end;

{ TPdfTestBuilder }

constructor TPdfTestBuilder.Create;
begin
  inherited Create;
  FBodies := TList<string>.Create;
  FVersion := '1.4';
end;

destructor TPdfTestBuilder.Destroy;
begin
  FBodies.Free;
  inherited;
end;

function TPdfTestBuilder.Add(const Body: string): Integer;
begin
  FBodies.Add(Body);
  Result := FBodies.Count;
end;

function TPdfTestBuilder.AddStream(const Dict, Data: string): Integer;
var
  D: string;
begin
  D := Trim(Dict);
  Delete(D, Length(D) - 1, 2); // remove '>>'
  Result := Add(D + ' /Length ' + IntToStr(Length(Data)) + ' >>' + #10 + 'stream'#10 + Data + #10'endstream');
end;

procedure TPdfTestBuilder.Replace(Num: Integer; const Body: string);
begin
  FBodies[Num - 1] := Body;
end;

function TPdfTestBuilder.Count: Integer;
begin
  Result := FBodies.Count;
end;

function TPdfTestBuilder.ObjectHeader(Num: Integer): string;
begin
  Result := IntToStr(Num) + ' 0 obj'#10;
end;

function TPdfTestBuilder.Build(RootNum: Integer; const ExtraTrailer: string): TBytes;
var
  S: string;
  Offsets: TArray<Integer>;
  I, XRefPos: Integer;
begin
  S := '%PDF-' + FVersion + #10'%'#$E2#$E3#$CF#$D3#10;
  SetLength(Offsets, FBodies.Count);
  for I := 0 to FBodies.Count - 1 do
  begin
    Offsets[I] := Length(S);
    S := S + ObjectHeader(I + 1) + FBodies[I] + #10'endobj'#10;
  end;
  XRefPos := Length(S);
  S := S + 'xref'#10'0 ' + IntToStr(FBodies.Count + 1) + #10'0000000000 65535 f'#13#10;
  for I := 0 to FBodies.Count - 1 do
    S := S + Format('%.10d 00000 n'#13#10, [Offsets[I]]);
  S := S + 'trailer'#10'<< /Size ' + IntToStr(FBodies.Count + 1) + ' /Root ' + IntToStr(RootNum) + ' 0 R ' + ExtraTrailer + ' >>'#10 +
    'startxref'#10 + IntToStr(XRefPos) + #10'%%EOF'#10;
  Result := BytesOf(S);
end;

function TPdfTestBuilder.BuildWithXRefStream(RootNum: Integer; const ObjStmNums: TArray<Integer>; const ExtraTrailer: string): TBytes;
var
  S, Header, Bodies, ObjStm: string;
  Offsets: TArray<Integer>;
  I, N, StmNum, XRefNum, XRefPos, StmOffset: Integer;
  InStm: TArray<Boolean>;
  Idx: TArray<Integer>;
  Entries: TBytes;
  P: Integer;

  procedure Entry(T: Byte; F2: Cardinal; F3: Word);
  begin
    Entries[P] := T;
    Entries[P + 1] := F2 shr 24;
    Entries[P + 2] := (F2 shr 16) and $FF;
    Entries[P + 3] := (F2 shr 8) and $FF;
    Entries[P + 4] := F2 and $FF;
    Entries[P + 5] := F3 shr 8;
    Entries[P + 6] := F3 and $FF;
    Inc(P, 7);
  end;

begin
  N := FBodies.Count;
  StmNum := N + 1;
  XRefNum := N + 2;
  SetLength(InStm, N + 1);
  SetLength(Idx, N + 1);
  for I := 0 to High(ObjStmNums) do
  begin
    InStm[ObjStmNums[I]] := True;
    Idx[ObjStmNums[I]] := I;
  end;
  S := '%PDF-1.5'#10'%'#$E2#$E3#$CF#$D3#10;
  SetLength(Offsets, N + 1);
  for I := 1 to N do
    if not InStm[I] then
    begin
      Offsets[I] := Length(S);
      S := S + ObjectHeader(I) + FBodies[I - 1] + #10'endobj'#10;
    end;
  // Object stream
  Header := '';
  Bodies := '';
  for I := 0 to High(ObjStmNums) do
  begin
    Header := Header + IntToStr(ObjStmNums[I]) + ' ' + IntToStr(Length(Bodies)) + ' ';
    Bodies := Bodies + FBodies[ObjStmNums[I] - 1] + #10;
  end;
  ObjStm := Header + Bodies;
  StmOffset := Length(S);
  S := S + ObjectHeader(StmNum) + '<< /Type /ObjStm /N ' + IntToStr(Length(ObjStmNums)) + ' /First ' + IntToStr(Length(Header)) +
    ' /Length ' + IntToStr(Length(ObjStm)) + ' >>'#10'stream'#10 + ObjStm + #10'endstream'#10'endobj'#10;
  // XRef stream
  XRefPos := Length(S);
  SetLength(Entries, 7 * (N + 3));
  P := 0;
  Entry(0, 0, 65535);
  for I := 1 to N do
    if InStm[I] then
      Entry(2, StmNum, Idx[I])
    else
      Entry(1, Offsets[I], 0);
  Entry(1, StmOffset, 0);
  Entry(1, XRefPos, 0);
  S := S + ObjectHeader(XRefNum) + '<< /Type /XRef /Size ' + IntToStr(N + 3) + ' /W [1 4 2] /Root ' + IntToStr(RootNum) + ' 0 R ' +
    ExtraTrailer + ' /Length ' + IntToStr(Length(Entries)) + ' >>'#10'stream'#10 + StrOf(Entries) + #10'endstream'#10'endobj'#10 +
    'startxref'#10 + IntToStr(XRefPos) + #10'%%EOF'#10;
  Result := BytesOf(S);
end;

class function TPdfTestBuilder.AppendUpdate(const Base: TBytes; const Nums: array of Integer; const Bodies: array of string;
  RootNum: Integer; const ExtraTrailer: string): TBytes;
var
  S, BaseStr: string;
  I, P, XRefPos, MaxNum: Integer;
  Prev: Int64;
  Offsets: TArray<Integer>;
begin
  BaseStr := StrOf(Base);
  P := BaseStr.LastIndexOf('startxref');
  Prev := StrToInt64(Trim(Copy(BaseStr, P + 10, 20)).Split([#10, #13, '%'])[0]);
  S := BaseStr;
  if not S.EndsWith(#10) then
    S := S + #10;
  SetLength(Offsets, Length(Nums));
  MaxNum := 0;
  for I := 0 to High(Nums) do
  begin
    Offsets[I] := Length(S);
    S := S + IntToStr(Nums[I]) + ' 0 obj'#10 + Bodies[I] + #10'endobj'#10;
    if Nums[I] > MaxNum then
      MaxNum := Nums[I];
  end;
  XRefPos := Length(S);
  S := S + 'xref'#10;
  for I := 0 to High(Nums) do
    S := S + IntToStr(Nums[I]) + ' 1'#10 + Format('%.10d 00000 n'#13#10, [Offsets[I]]);
  S := S + 'trailer'#10'<< /Size ' + IntToStr(MaxNum + 1) + ' /Root ' + IntToStr(RootNum) + ' 0 R /Prev ' + IntToStr(Prev) + ' ' +
    ExtraTrailer + ' >>'#10'startxref'#10 + IntToStr(XRefPos) + #10'%%EOF'#10;
  Result := BytesOf(S);
end;

class function TPdfTestBuilder.SimpleDocument(PageCount: Integer; const PagesExtra, PageExtra: string): TPdfTestBuilder;
var
  I, PagesNum, PageNum, ContentNum: Integer;
  Kids: string;
begin
  Result := TPdfTestBuilder.Create;
  Result.Add('<< /Type /Catalog /Pages 2 0 R >>');
  PagesNum := Result.Add(''); // placeholder, filled below
  Kids := '';
  for I := 1 to PageCount do
  begin
    ContentNum := Result.Count + 2;
    PageNum := Result.Add('<< /Type /Page /Parent ' + IntToStr(PagesNum) + ' 0 R /Contents ' + IntToStr(ContentNum) + ' 0 R ' + PageExtra + ' >>');
    Result.AddStream('<< >>', 'BT /F1 12 Tf 10 10 Td (Page ' + IntToStr(I) + ') Tj ET');
    Kids := Kids + IntToStr(PageNum) + ' 0 R ';
  end;
  Result.Replace(PagesNum, '<< /Type /Pages /Count ' + IntToStr(PageCount) + ' /Kids [' + Kids + '] ' + PagesExtra + ' >>');
end;

end.
