{*******************************************************************************
  Pdf.Core.Document
  Document-level access: loading, header version, trailer, catalog, info
  dictionary and the page tree with inherited attributes (/Resources,
  /MediaBox, /CropBox, /Rotate). Falls back to scanning for page objects
  when the page tree is damaged.
*******************************************************************************}
unit Pdf.Core.Document;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.Math,
  Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.XRef;

type
  TPdfDocument = class;

  TPdfPage = class
  private
    FDocument: TPdfDocument;
    FIndex: Integer;
    FDict: IPdfDictionary;
    FObjNum: Integer;
    FMediaBox: TPdfRectangle;
    FCropBox: TPdfRectangle;
    FRotate: Integer;
    FResources: IPdfDictionary;
    FUserUnit: Double;
  public
    constructor Create(ADocument: TPdfDocument; AIndex: Integer; const ADict: IPdfDictionary; AObjNum: Integer);
    /// <summary>All content streams of the page in order (empty for a blank page).</summary>
    function GetContentStreams: TArray<IPdfStream>;
    /// <summary>Decoded content of all streams concatenated, separated by LF.</summary>
    function GetContentData: TBytes;
    /// <summary>The /Annots array (resolved) or nil.</summary>
    function GetAnnotations: IPdfArray;
    /// <summary>CropBox intersected with MediaBox: the area a viewer shows.</summary>
    function GetDisplayBox: TPdfRectangle;
    /// <summary>Display width/height in points after applying /Rotate.</summary>
    function GetDisplayWidth: Double;
    function GetDisplayHeight: Double;
    property Document: TPdfDocument read FDocument;
    /// <summary>Zero-based page index.</summary>
    property Index: Integer read FIndex;
    property Dictionary: IPdfDictionary read FDict;
    /// <summary>Object number of the page dictionary, or -1 for a direct object.</summary>
    property ObjectNumber: Integer read FObjNum;
    property MediaBox: TPdfRectangle read FMediaBox;
    property CropBox: TPdfRectangle read FCropBox;
    /// <summary>0, 90, 180 or 270.</summary>
    property Rotate: Integer read FRotate;
    /// <summary>Resources with inheritance applied (never nil, may be empty).</summary>
    property Resources: IPdfDictionary read FResources;
    property UserUnit: Double read FUserUnit;
  end;

  TPdfDocument = class
  private type
    TInherited = record
      Resources, MediaBox, CropBox, Rotate: IPdfObject;
    end;
  private
    FXRef: TPdfXRef;
    FResolver: IPdfResolver;
    FPages: TObjectList<TPdfPage>;
    FPagesLoaded: Boolean;
    FVersion: string;
    FCatalog: IPdfDictionary;
    FLoaded: Boolean;
    FPageTreeRecovered: Boolean;
    function GetPageCount: Integer;
    function GetPage(Index: Integer): TPdfPage;
    function GetTrailer: IPdfDictionary;
    function GetInfo: IPdfDictionary;
    function GetIsEncrypted: Boolean;
    procedure LoadPages;
    procedure WalkPageTree(const RootDict: IPdfDictionary);
    procedure AddPage(const Dict: IPdfDictionary; ObjNum: Integer; const Inh: TInherited);
    procedure RecoverPagesByScanning;
    procedure ReadHeaderVersion(const Data: TBytes);
    procedure CheckLoaded;
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary>Opens a file. Password is tried as user and as owner password.
    /// Raises EPdfPasswordError for a wrong password and EPdfInvalidDocument when no objects are found.</summary>
    procedure LoadFromFile(const FileName: string; const Password: string = '');
    procedure LoadFromStream(Stream: TStream; const Password: string = '');
    procedure LoadFromBytes(const Data: TBytes; const Password: string = '');
    procedure Close;
    function Resolve(const Obj: IPdfObject): IPdfObject;
    /// <summary>Text value from the /Info dictionary (Title, Author, Subject, Creator, Producer ...), '' when absent.</summary>
    function GetInfoText(const Key: string): string;
    property IsLoaded: Boolean read FLoaded;
    /// <summary>Version from the header, overridden by /Version in the catalog when higher (e.g. '1.7').</summary>
    property Version: string read FVersion;
    property PageCount: Integer read GetPageCount;
    property Pages[Index: Integer]: TPdfPage read GetPage;
    property Catalog: IPdfDictionary read FCatalog;
    property Trailer: IPdfDictionary read GetTrailer;
    property Info: IPdfDictionary read GetInfo;
    property IsEncrypted: Boolean read GetIsEncrypted;
    /// <summary>True when the pages were found by scanning instead of through the page tree.</summary>
    property PageTreeRecovered: Boolean read FPageTreeRecovered;
    property XRef: TPdfXRef read FXRef;
    property Resolver: IPdfResolver read FResolver;
  end;

implementation

const
  DefaultPageWidth = 612;
  DefaultPageHeight = 792;
  MaxPageTreeDepth = 64;

{ TPdfPage }

constructor TPdfPage.Create(ADocument: TPdfDocument; AIndex: Integer; const ADict: IPdfDictionary; AObjNum: Integer);
begin
  inherited Create;
  FDocument := ADocument;
  FIndex := AIndex;
  FDict := ADict;
  FObjNum := AObjNum;
  FUserUnit := 1;
end;

function TPdfPage.GetContentStreams: TArray<IPdfStream>;
var
  Obj: IPdfObject;
  Arr: IPdfArray;
  I, N: Integer;
  S: IPdfStream;
begin
  Result := nil;
  Obj := FDict.Get('Contents');
  if Obj = nil then
    Exit;
  case Obj.Kind of
    okStream:
      begin
        SetLength(Result, 1);
        Result[0] := Obj as IPdfStream;
      end;
    okArray:
      begin
        Arr := Obj as IPdfArray;
        SetLength(Result, Arr.Count);
        N := 0;
        for I := 0 to Arr.Count - 1 do
        begin
          S := Arr.GetStream(I);
          if S <> nil then
          begin
            Result[N] := S;
            Inc(N);
          end;
        end;
        SetLength(Result, N);
      end;
  end;
end;

function TPdfPage.GetContentData: TBytes;
var
  Streams: TArray<IPdfStream>;
  I: Integer;
  Part: TBytes;
  Total: Integer;
  Parts: TArray<TBytes>;
  P: Integer;
begin
  Streams := GetContentStreams;
  SetLength(Parts, Length(Streams));
  Total := 0;
  for I := 0 to High(Streams) do
  begin
    try
      Part := Streams[I].GetDecodedData;
    except
      on EPdfException do
        Part := nil; // a broken stream must not hide the others
    end;
    Parts[I] := Part;
    Inc(Total, Length(Part) + 1);
  end;
  SetLength(Result, Total);
  P := 0;
  for I := 0 to High(Parts) do
  begin
    if Length(Parts[I]) > 0 then
    begin
      Move(Parts[I][0], Result[P], Length(Parts[I]));
      Inc(P, Length(Parts[I]));
    end;
    Result[P] := $0A;
    Inc(P);
  end;
end;

function TPdfPage.GetAnnotations: IPdfArray;
begin
  Result := FDict.GetArray('Annots');
end;

function TPdfPage.GetDisplayBox: TPdfRectangle;
begin
  Result := FCropBox;
end;

function TPdfPage.GetDisplayWidth: Double;
begin
  if (FRotate = 90) or (FRotate = 270) then
    Result := FCropBox.Height
  else
    Result := FCropBox.Width;
end;

function TPdfPage.GetDisplayHeight: Double;
begin
  if (FRotate = 90) or (FRotate = 270) then
    Result := FCropBox.Width
  else
    Result := FCropBox.Height;
end;

{ TPdfDocument }

constructor TPdfDocument.Create;
begin
  inherited Create;
  FPages := TObjectList<TPdfPage>.Create(True);
end;

destructor TPdfDocument.Destroy;
begin
  Close;
  FPages.Free;
  inherited;
end;

procedure TPdfDocument.Close;
begin
  FPages.Clear;
  FPagesLoaded := False;
  FPageTreeRecovered := False;
  FCatalog := nil;
  FLoaded := False;
  FVersion := '';
  if FXRef <> nil then
    FXRef.Detach;
  FXRef := nil;
  FResolver := nil;
end;

procedure TPdfDocument.CheckLoaded;
begin
  if not FLoaded then
    raise EPdfException.Create('No document loaded');
end;

procedure TPdfDocument.LoadFromFile(const FileName: string; const Password: string);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    LoadFromStream(FS, Password);
  finally
    FS.Free;
  end;
end;

procedure TPdfDocument.LoadFromStream(Stream: TStream; const Password: string);
var
  Data: TBytes;
  Size: Int64;
begin
  Size := Stream.Size - Stream.Position;
  if Size > High(Integer) then
    raise EPdfInvalidDocument.Create('File too large');
  SetLength(Data, Size);
  if Size > 0 then
    Stream.ReadBuffer(Data[0], Size);
  LoadFromBytes(Data, Password);
end;

procedure TPdfDocument.LoadFromBytes(const Data: TBytes; const Password: string);
var
  CatalogVersion: string;
begin
  Close;
  if Length(Data) = 0 then
    raise EPdfInvalidDocument.Create('Empty file');
  FXRef := TPdfXRef.Create(Data, Password);
  FResolver := FXRef; // keeps the xref alive; objects hold their own references
  try
    ReadHeaderVersion(Data);
    FXRef.Parse;
    FCatalog := PdfAsDictionary(FXRef.Trailer.Get('Root'));
    if FCatalog = nil then
    begin
      // Root missing or pointing nowhere: try again after a full scan
      if not FXRef.IsReconstructed then
        FXRef.Reconstruct;
      FCatalog := PdfAsDictionary(FXRef.Trailer.Get('Root'));
    end;
    if FCatalog = nil then
      FCatalog := PdfDictionary(FResolver);
    CatalogVersion := FCatalog.GetName('Version');
    if (CatalogVersion <> '') and (CompareStr(CatalogVersion, FVersion) > 0) then
      FVersion := CatalogVersion;
    FLoaded := True;
  except
    Close;
    raise;
  end;
end;

procedure TPdfDocument.ReadHeaderVersion(const Data: TBytes);
var
  P, E: Integer;
begin
  FVersion := '';
  P := FXRef.Base;
  if (P + 8 <= Length(Data)) and (Data[P] = Ord('%')) and (Data[P + 1] = Ord('P')) and
     (Data[P + 2] = Ord('D')) and (Data[P + 3] = Ord('F')) and (Data[P + 4] = Ord('-')) then
  begin
    E := P + 5;
    while (E < Length(Data)) and (E < P + 12) and (IsPdfDigit(Data[E]) or (Data[E] = Ord('.'))) do
      Inc(E);
    FVersion := PdfBytesToLatin1(Data, P + 5, E - (P + 5));
  end;
  if FVersion = '' then
    FVersion := '1.4';
end;

function TPdfDocument.Resolve(const Obj: IPdfObject): IPdfObject;
begin
  if FResolver = nil then
    Result := PdfResolve(nil, Obj)
  else
    Result := FResolver.Resolve(Obj);
end;

function TPdfDocument.GetTrailer: IPdfDictionary;
begin
  CheckLoaded;
  Result := FXRef.Trailer;
end;

function TPdfDocument.GetInfo: IPdfDictionary;
begin
  CheckLoaded;
  Result := FXRef.Trailer.GetDictionary('Info');
end;

function TPdfDocument.GetIsEncrypted: Boolean;
begin
  Result := (FXRef <> nil) and FXRef.IsEncrypted;
end;

function TPdfDocument.GetInfoText(const Key: string): string;
var
  Info: IPdfDictionary;
  S: IPdfString;
begin
  Result := '';
  Info := GetInfo;
  if Info = nil then
    Exit;
  S := Info.GetString(Key);
  if S <> nil then
    Result := S.AsText;
end;

function TPdfDocument.GetPageCount: Integer;
begin
  CheckLoaded;
  if not FPagesLoaded then
    LoadPages;
  Result := FPages.Count;
end;

function TPdfDocument.GetPage(Index: Integer): TPdfPage;
begin
  CheckLoaded;
  if not FPagesLoaded then
    LoadPages;
  if (Index < 0) or (Index >= FPages.Count) then
    raise EPdfException.CreateFmt('Page index %d out of range', [Index]);
  Result := FPages[Index];
end;

procedure TPdfDocument.LoadPages;
var
  PagesRoot: IPdfDictionary;
begin
  FPagesLoaded := True;
  FPages.Clear;
  PagesRoot := FCatalog.GetDictionary('Pages');
  if PagesRoot <> nil then
    WalkPageTree(PagesRoot);
  if FPages.Count = 0 then
    RecoverPagesByScanning;
end;

procedure TPdfDocument.AddPage(const Dict: IPdfDictionary; ObjNum: Integer; const Inh: TInherited);
var
  Page: TPdfPage;
  R: TPdfRectangle;
  Arr: IPdfArray;
  V: TArray<Double>;
  Rot: Integer;

  function ReadRect(const Obj: IPdfObject; out Rect: TPdfRectangle): Boolean;
  begin
    Result := False;
    Arr := PdfAsArray(Resolve(Obj));
    if (Arr <> nil) and (Arr.Count >= 4) and Arr.GetNumbers(V, 4) then
    begin
      Rect := TPdfRectangle.Create(V[0], V[1], V[2], V[3]).Normalized;
      Result := (Rect.Width >= 1) and (Rect.Height >= 1) and (Rect.Width < 1E6) and (Rect.Height < 1E6);
    end;
  end;

begin
  Page := TPdfPage.Create(Self, FPages.Count, Dict, ObjNum);
  FPages.Add(Page);
  // Resources
  Page.FResources := PdfAsDictionary(Resolve(Inh.Resources));
  if Page.FResources = nil then
    Page.FResources := PdfDictionary(FResolver);
  // MediaBox
  if not ReadRect(Inh.MediaBox, R) then
    R := TPdfRectangle.Create(0, 0, DefaultPageWidth, DefaultPageHeight);
  Page.FMediaBox := R;
  // CropBox
  if ReadRect(Inh.CropBox, R) then
  begin
    R := R.Intersect(Page.FMediaBox);
    if R.IsEmpty then
      R := Page.FMediaBox;
  end
  else
    R := Page.FMediaBox;
  Page.FCropBox := R;
  // Rotate
  Rot := Integer(PdfAsInteger(Resolve(Inh.Rotate), 0));
  Rot := Round(Rot / 90) * 90;
  Rot := Rot mod 360;
  if Rot < 0 then
    Inc(Rot, 360);
  Page.FRotate := Rot;
  Page.FUserUnit := Dict.GetNumber('UserUnit', 1);
  if Page.FUserUnit <= 0 then
    Page.FUserUnit := 1;
end;

procedure TPdfDocument.WalkPageTree(const RootDict: IPdfDictionary);
type
  TFrame = record
    Dict: IPdfDictionary;
    ObjNum: Integer;
    Inh: TInherited;
    Depth: Integer;
  end;
var
  Stack: TList<TFrame>;
  Visited: TDictionary<Pointer, Boolean>;
  Frame, Child: TFrame;
  Kids: IPdfArray;
  I: Integer;
  KidRaw, KidObj: IPdfObject;
  KidDict: IPdfDictionary;
  Ref: IPdfReference;
  IsPages: Boolean;

  procedure Inherit(var Inh: TInherited; const Dict: IPdfDictionary);
  begin
    if Dict.Contains('Resources') then
      Inh.Resources := Dict.GetRaw('Resources');
    if Dict.Contains('MediaBox') then
      Inh.MediaBox := Dict.GetRaw('MediaBox');
    if Dict.Contains('CropBox') then
      Inh.CropBox := Dict.GetRaw('CropBox');
    if Dict.Contains('Rotate') then
      Inh.Rotate := Dict.GetRaw('Rotate');
  end;

begin
  Stack := TList<TFrame>.Create;
  Visited := TDictionary<Pointer, Boolean>.Create;
  try
    Frame := Default(TFrame);
    Frame.Dict := RootDict;
    Frame.ObjNum := -1;
    Stack.Add(Frame);
    Visited.AddOrSetValue(Pointer(RootDict), True);
    while Stack.Count > 0 do
    begin
      Frame := Stack[Stack.Count - 1];
      Stack.Delete(Stack.Count - 1);
      Inherit(Frame.Inh, Frame.Dict);
      Kids := Frame.Dict.GetArray('Kids');
      if (Kids = nil) and (PdfAsDictionary(Frame.Dict.Get('Kids')) <> nil) then
      begin
        // Damaged file: /Kids is a single node instead of an array
        Kids := PdfArray(FResolver);
        Kids.Add(Frame.Dict.GetRaw('Kids'));
      end;
      IsPages := (Kids <> nil) or Frame.Dict.IsType('Pages');
      if IsPages and (Frame.Depth < MaxPageTreeDepth) then
      begin
        if Kids = nil then
          Continue;
        // Push in reverse so that the first kid is processed first
        for I := Kids.Count - 1 downto 0 do
        begin
          KidRaw := Kids[I];
          KidObj := Resolve(KidRaw);
          KidDict := PdfAsDictionary(KidObj);
          if KidDict = nil then
            Continue;
          if Visited.ContainsKey(Pointer(KidDict)) then
            Continue; // cycle or shared node
          Visited.Add(Pointer(KidDict), True);
          Child := Default(TFrame);
          Child.Dict := KidDict;
          Child.Inh := Frame.Inh;
          Child.Depth := Frame.Depth + 1;
          Ref := PdfAsReference(KidRaw);
          if Ref <> nil then
            Child.ObjNum := Ref.Num
          else
            Child.ObjNum := -1;
          Stack.Add(Child);
        end;
      end
      else if Frame.Dict.IsType('Page') or
              (not Frame.Dict.Contains('Type') and (Frame.Dict.Contains('Contents') or Frame.Dict.Contains('MediaBox'))) then
        AddPage(Frame.Dict, Frame.ObjNum, Frame.Inh);
    end;
  finally
    Visited.Free;
    Stack.Free;
  end;
end;

procedure TPdfDocument.RecoverPagesByScanning;
var
  Num: Integer;
  Obj: IPdfObject;
  Dict, Parent: IPdfDictionary;
  Inh: TInherited;
  Depth: Integer;
  Seen: TDictionary<Pointer, Boolean>;
begin
  if FXRef = nil then
    Exit;
  FPageTreeRecovered := True;
  if not FXRef.IsReconstructed then
  begin
    FXRef.Reconstruct;
    FCatalog := PdfAsDictionary(FXRef.Trailer.Get('Root'));
    if FCatalog = nil then
      FCatalog := PdfDictionary(FResolver);
  end;
  Seen := TDictionary<Pointer, Boolean>.Create;
  try
    for Num in FXRef.ObjectNumbers do
    begin
      Obj := FXRef.FetchObject(Num, 0);
      if (Obj = nil) or (Obj.Kind <> okDictionary) then
        Continue;
      Dict := Obj as IPdfDictionary;
      // A page dictionary, or an untyped dictionary that looks like one (damaged /Type key)
      if not Dict.IsType('Page') and
         not (not Dict.Contains('Type') and Dict.Contains('Contents') and Dict.Contains('Parent')) then
        Continue;
      // Inherit through the /Parent chain
      Inh := Default(TInherited);
      Parent := Dict;
      Depth := 0;
      Seen.Clear;
      while (Parent <> nil) and (Depth < MaxPageTreeDepth) and not Seen.ContainsKey(Pointer(Parent)) do
      begin
        Seen.Add(Pointer(Parent), True);
        if (Inh.Resources = nil) and Parent.Contains('Resources') then
          Inh.Resources := Parent.GetRaw('Resources');
        if (Inh.MediaBox = nil) and Parent.Contains('MediaBox') then
          Inh.MediaBox := Parent.GetRaw('MediaBox');
        if (Inh.CropBox = nil) and Parent.Contains('CropBox') then
          Inh.CropBox := Parent.GetRaw('CropBox');
        if (Inh.Rotate = nil) and Parent.Contains('Rotate') then
          Inh.Rotate := Parent.GetRaw('Rotate');
        Parent := Parent.GetDictionary('Parent');
        Inc(Depth);
      end;
      AddPage(Dict, Num, Inh);
    end;
  finally
    Seen.Free;
  end;
end;

end.
