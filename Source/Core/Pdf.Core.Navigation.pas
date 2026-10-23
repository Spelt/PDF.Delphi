{*******************************************************************************
  Pdf.Core.Navigation
  Destinations (ISO 32000-1 §12.3.2), named destinations (/Dests and the
  /Names /Dests name tree, §7.9.6), actions (§12.6: GoTo, URI, GoToR, Launch,
  Named), the document outline (§12.3.3) and annotations (§12.5) with their
  appearance streams. No rendering here: Pdf.Core stays free of Skia.
*******************************************************************************}
unit Pdf.Core.Navigation;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.Math,
  Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Document;

type
  TPdfDestinationKind = (dkNone, dkXYZ, dkFit, dkFitH, dkFitV, dkFitR, dkFitB, dkFitBH, dkFitBV);

  /// <summary>A resolved explicit destination. Coordinates are in the page's user space; Has* tells which were given.</summary>
  TPdfDestination = record
    Kind: TPdfDestinationKind;
    /// <summary>Zero-based page index, -1 when the page could not be resolved (e.g. remote file).</summary>
    PageIndex: Integer;
    Left, Top, Right, Bottom, Zoom: Double;
    HasLeft, HasTop, HasZoom: Boolean;
    function IsValid: Boolean;
    class function None: TPdfDestination; static;
  end;

  TPdfActionKind = (akNone, akGoTo, akGoToRemote, akURI, akLaunch, akNamed, akJavaScript, akOther);

  TPdfAction = record
    Kind: TPdfActionKind;
    Dest: TPdfDestination;
    /// <summary>URI for akURI, file name for akGoToRemote/akLaunch, name for akNamed (NextPage, PrevPage, FirstPage, LastPage), /S for akOther.</summary>
    Target: string;
    class function None: TPdfAction; static;
  end;

  TPdfOutlineItem = class
  private
    FTitle: string;
    FDest: TPdfDestination;
    FAction: TPdfAction;
    FChildren: TObjectList<TPdfOutlineItem>;
    FLevel: Integer;
    FIsOpen: Boolean;
    FParent: TPdfOutlineItem;
  public
    constructor Create(AParent: TPdfOutlineItem);
    destructor Destroy; override;
    property Title: string read FTitle;
    /// <summary>Destination (from /Dest or a GoTo action); PageIndex -1 when none.</summary>
    property Dest: TPdfDestination read FDest;
    property Action: TPdfAction read FAction;
    property Children: TObjectList<TPdfOutlineItem> read FChildren;
    property Level: Integer read FLevel;
    property IsOpen: Boolean read FIsOpen;
    property Parent: TPdfOutlineItem read FParent;
  end;

  TPdfAnnotationFlag = (afInvisible, afHidden, afPrint, afNoZoom, afNoRotate, afNoView, afReadOnly, afLocked,
    afToggleNoView, afLockedContents);
  TPdfAnnotationFlags = set of TPdfAnnotationFlag;

  TPdfAnnotation = class
  private
    FDict: IPdfDictionary;
    FSubtype: string;
    FRect: TPdfRectangle;
    FFlags: TPdfAnnotationFlags;
    FContents: string;
    FAction: TPdfAction;
    FDest: TPdfDestination;
    FAppearance: IPdfStream;
    FAppearanceState: string;
    FIsLink: Boolean;
  public
    property Dictionary: IPdfDictionary read FDict;
    property Subtype: string read FSubtype;
    /// <summary>Normalised /Rect in page user space.</summary>
    property Rect: TPdfRectangle read FRect;
    property Flags: TPdfAnnotationFlags read FFlags;
    property Contents: string read FContents;
    /// <summary>Link annotations: the action (/A) or a GoTo built from /Dest.</summary>
    property Action: TPdfAction read FAction;
    property Dest: TPdfDestination read FDest;
    /// <summary>Normal appearance stream for the current /AS state (nil when absent).</summary>
    property Appearance: IPdfStream read FAppearance;
    property AppearanceState: string read FAppearanceState;
    property IsLink: Boolean read FIsLink;
    /// <summary>False for hidden/noview annotations and popups: nothing to draw.</summary>
    function IsVisible: Boolean;
  end;

  /// <summary>Document-level navigation data, built lazily from the catalog. Create one per document.</summary>
  TPdfNavigation = class
  private
    FDocument: TPdfDocument;
    FNamedDests: TDictionary<string, IPdfObject>;
    FNamedDestsLoaded: Boolean;
    FOutline: TObjectList<TPdfOutlineItem>;
    FOutlineLoaded: Boolean;
    FPageIndexByObj: TDictionary<Integer, Integer>;
    procedure LoadNamedDests;
    procedure WalkNameTree(const Node: IPdfDictionary; Depth: Integer; Visited: TDictionary<Pointer, Boolean>);
    procedure LoadOutline;
    procedure WalkOutline(const First: IPdfDictionary; Parent: TPdfOutlineItem; Level: Integer; Visited: TDictionary<Pointer, Boolean>);
    function PageIndexOf(const PageRef: IPdfObject): Integer;
  public
    constructor Create(ADocument: TPdfDocument);
    destructor Destroy; override;
    /// <summary>Resolves a destination object: an explicit array, a name/string looked up in /Dests or the name tree,
    /// or a dictionary with /D. Never raises; PageIndex is -1 when unresolvable.</summary>
    function ResolveDestination(const Obj: IPdfObject): TPdfDestination;
    /// <summary>Parses an action dictionary (/A); follows /Next only one level deep for GoTo.</summary>
    function ParseAction(const Obj: IPdfObject): TPdfAction;
    /// <summary>Annotations of a page with their appearance streams; the caller owns the list.</summary>
    function LoadAnnotations(Page: TPdfPage): TObjectList<TPdfAnnotation>;
    /// <summary>Top-level outline items (bookmarks); empty when the document has none.</summary>
    property Outline: TObjectList<TPdfOutlineItem> read FOutline;
    function OutlineCount: Integer;
    property Document: TPdfDocument read FDocument;
  end;

implementation

{ TPdfDestination }

function TPdfDestination.IsValid: Boolean;
begin
  Result := (Kind <> dkNone) and (PageIndex >= 0);
end;

class function TPdfDestination.None: TPdfDestination;
begin
  Result := Default(TPdfDestination);
  Result.PageIndex := -1;
end;

{ TPdfAction }

class function TPdfAction.None: TPdfAction;
begin
  Result := Default(TPdfAction);
  Result.Dest := TPdfDestination.None;
end;

{ TPdfOutlineItem }

constructor TPdfOutlineItem.Create(AParent: TPdfOutlineItem);
begin
  inherited Create;
  FParent := AParent;
  FChildren := TObjectList<TPdfOutlineItem>.Create(True);
  FDest := TPdfDestination.None;
  FAction := TPdfAction.None;
end;

destructor TPdfOutlineItem.Destroy;
begin
  FChildren.Free;
  inherited;
end;

{ TPdfAnnotation }

function TPdfAnnotation.IsVisible: Boolean;
begin
  Result := not (afHidden in FFlags) and not (afNoView in FFlags) and (FSubtype <> 'Popup');
end;

{ TPdfNavigation }

constructor TPdfNavigation.Create(ADocument: TPdfDocument);
begin
  inherited Create;
  FDocument := ADocument;
  FNamedDests := TDictionary<string, IPdfObject>.Create;
  FOutline := TObjectList<TPdfOutlineItem>.Create(True);
  FPageIndexByObj := TDictionary<Integer, Integer>.Create;
end;

destructor TPdfNavigation.Destroy;
begin
  FPageIndexByObj.Free;
  FOutline.Free;
  FNamedDests.Free;
  inherited;
end;

function TPdfNavigation.PageIndexOf(const PageRef: IPdfObject): Integer;
var
  Ref: IPdfReference;
  I: Integer;
  Dict: IPdfDictionary;
begin
  Result := -1;
  if (PageRef = nil) or not FDocument.IsLoaded then
    Exit;
  if PdfIsNumber(PageRef) then
  begin
    // Remote destinations and some broken files give a page number
    Result := Integer(PdfAsInteger(PageRef));
    if (Result < 0) or (Result >= FDocument.PageCount) then
      Result := -1;
    Exit;
  end;
  Ref := PdfAsReference(PageRef);
  if Ref <> nil then
  begin
    if FPageIndexByObj.Count = 0 then
      for I := 0 to FDocument.PageCount - 1 do
        if FDocument.Pages[I].ObjectNumber >= 0 then
          FPageIndexByObj.AddOrSetValue(FDocument.Pages[I].ObjectNumber, I);
    if not FPageIndexByObj.TryGetValue(Ref.Num, Result) then
      Result := -1;
    Exit;
  end;
  Dict := PdfAsDictionary(PageRef);
  if Dict <> nil then
    for I := 0 to FDocument.PageCount - 1 do
      if Pointer(FDocument.Pages[I].Dictionary) = Pointer(Dict) then
        Exit(I);
end;

function TPdfNavigation.ResolveDestination(const Obj: IPdfObject): TPdfDestination;
var
  O: IPdfObject;
  Arr: IPdfArray;
  Dict: IPdfDictionary;
  Name, Kind: string;
  S: IPdfString;
  Target: IPdfObject;

  function Num(Index: Integer; out Has: Boolean): Double;
  var
    Item: IPdfObject;
  begin
    Item := Arr.Get(Index);
    Has := PdfIsNumber(Item);
    if Has then
      Result := PdfAsNumber(Item)
    else
      Result := 0;
  end;

var
  HasR, HasB: Boolean;
begin
  Result := TPdfDestination.None;
  O := FDocument.Resolve(Obj);
  if PdfIsNull(O) then
    Exit;
  // Name or string: look it up
  Name := '';
  if PdfIsName(O) then
    Name := (O as IPdfName).Name
  else
  begin
    S := PdfAsString(O);
    if S <> nil then
      Name := PdfBytesToLatin1(S.Bytes);
  end;
  if Name <> '' then
  begin
    LoadNamedDests;
    if not FNamedDests.TryGetValue(Name, Target) then
      Exit;
    O := FDocument.Resolve(Target);
  end;
  Dict := PdfAsDictionary(O);
  if Dict <> nil then
    O := Dict.Get('D');
  Arr := PdfAsArray(O);
  if (Arr = nil) or (Arr.Count = 0) then
    Exit;
  Result.PageIndex := PageIndexOf(Arr[0]);
  Kind := Arr.GetName(1, 'Fit');
  if Kind = 'XYZ' then
  begin
    Result.Kind := dkXYZ;
    Result.Left := Num(2, Result.HasLeft);
    Result.Top := Num(3, Result.HasTop);
    Result.Zoom := Num(4, Result.HasZoom);
    if Result.HasZoom and (Result.Zoom <= 0) then
      Result.HasZoom := False;
  end
  else if Kind = 'Fit' then
    Result.Kind := dkFit
  else if Kind = 'FitH' then
  begin
    Result.Kind := dkFitH;
    Result.Top := Num(2, Result.HasTop);
  end
  else if Kind = 'FitV' then
  begin
    Result.Kind := dkFitV;
    Result.Left := Num(2, Result.HasLeft);
  end
  else if Kind = 'FitR' then
  begin
    Result.Kind := dkFitR;
    Result.Left := Num(2, Result.HasLeft);
    Result.Bottom := Num(3, HasB);
    Result.Right := Num(4, HasR);
    Result.Top := Num(5, Result.HasTop);
    if not (Result.HasLeft and HasB and HasR and Result.HasTop) then
      Result.Kind := dkFit;
  end
  else if Kind = 'FitB' then
    Result.Kind := dkFitB
  else if Kind = 'FitBH' then
  begin
    Result.Kind := dkFitBH;
    Result.Top := Num(2, Result.HasTop);
  end
  else if Kind = 'FitBV' then
  begin
    Result.Kind := dkFitBV;
    Result.Left := Num(2, Result.HasLeft);
  end
  else
    Result.Kind := dkFit;
end;

procedure TPdfNavigation.LoadNamedDests;
var
  Dests, Names: IPdfDictionary;
  Key: string;
  Visited: TDictionary<Pointer, Boolean>;
begin
  if FNamedDestsLoaded then
    Exit;
  FNamedDestsLoaded := True;
  if not FDocument.IsLoaded then
    Exit;
  Dests := FDocument.Catalog.GetDictionary('Dests');
  if Dests <> nil then
    for Key in Dests.Keys do
      FNamedDests.AddOrSetValue(Key, Dests.GetRaw(Key));
  Names := FDocument.Catalog.GetDictionary('Names');
  if Names <> nil then
  begin
    Visited := TDictionary<Pointer, Boolean>.Create;
    try
      WalkNameTree(Names.GetDictionary('Dests'), 0, Visited);
    finally
      Visited.Free;
    end;
  end;
end;

procedure TPdfNavigation.WalkNameTree(const Node: IPdfDictionary; Depth: Integer; Visited: TDictionary<Pointer, Boolean>);
var
  Names, Kids: IPdfArray;
  I: Integer;
  S: IPdfString;
  Key: string;
  Kid: IPdfDictionary;
begin
  if (Node = nil) or (Depth > 32) or Visited.ContainsKey(Pointer(Node)) then
    Exit;
  Visited.Add(Pointer(Node), True);
  Names := Node.GetArray('Names');
  if Names <> nil then
  begin
    I := 0;
    while I + 1 < Names.Count do
    begin
      S := PdfAsString(Names.Get(I));
      if S <> nil then
      begin
        Key := PdfBytesToLatin1(S.Bytes);
        if not FNamedDests.ContainsKey(Key) then
          FNamedDests.Add(Key, Names[I + 1]);
      end;
      Inc(I, 2);
    end;
  end;
  Kids := Node.GetArray('Kids');
  if Kids <> nil then
    for I := 0 to Kids.Count - 1 do
    begin
      Kid := Kids.GetDictionary(I);
      if Kid <> nil then
        WalkNameTree(Kid, Depth + 1, Visited);
    end;
end;

function TPdfNavigation.ParseAction(const Obj: IPdfObject): TPdfAction;
var
  Dict, F: IPdfDictionary;
  S: string;
  Str: IPdfString;
  FileObj: IPdfObject;
begin
  Result := TPdfAction.None;
  Dict := PdfAsDictionary(FDocument.Resolve(Obj));
  if Dict = nil then
    Exit;
  S := Dict.GetName('S');
  if S = 'GoTo' then
  begin
    Result.Kind := akGoTo;
    Result.Dest := ResolveDestination(Dict.GetRaw('D'));
  end
  else if S = 'URI' then
  begin
    Result.Kind := akURI;
    Str := Dict.GetString('URI');
    if Str <> nil then
      Result.Target := TEncoding.UTF8.GetString(Str.Bytes);
  end
  else if (S = 'GoToR') or (S = 'Launch') then
  begin
    if S = 'GoToR' then
      Result.Kind := akGoToRemote
    else
      Result.Kind := akLaunch;
    FileObj := Dict.Get('F');
    Str := PdfAsString(FileObj);
    if Str = nil then
    begin
      F := PdfAsDictionary(FileObj);
      if F <> nil then
      begin
        Str := F.GetString('UF');
        if Str = nil then
          Str := F.GetString('F');
      end;
    end;
    if Str <> nil then
      Result.Target := Str.AsText;
    if S = 'GoToR' then
      Result.Dest := ResolveDestination(Dict.GetRaw('D'));
  end
  else if S = 'Named' then
  begin
    Result.Kind := akNamed;
    Result.Target := Dict.GetName('N');
  end
  else if S = 'JavaScript' then
    Result.Kind := akJavaScript
  else if S <> '' then
  begin
    Result.Kind := akOther;
    Result.Target := S;
  end;
end;

procedure TPdfNavigation.LoadOutline;
var
  Root: IPdfDictionary;
  Visited: TDictionary<Pointer, Boolean>;
begin
  if FOutlineLoaded then
    Exit;
  FOutlineLoaded := True;
  if not FDocument.IsLoaded then
    Exit;
  Root := FDocument.Catalog.GetDictionary('Outlines');
  if Root = nil then
    Exit;
  Visited := TDictionary<Pointer, Boolean>.Create;
  try
    WalkOutline(Root.GetDictionary('First'), nil, 0, Visited);
  finally
    Visited.Free;
  end;
end;

procedure TPdfNavigation.WalkOutline(const First: IPdfDictionary; Parent: TPdfOutlineItem; Level: Integer;
  Visited: TDictionary<Pointer, Boolean>);
var
  Node: IPdfDictionary;
  Item: TPdfOutlineItem;
  Title: IPdfString;
  Count: Integer;
  List: TObjectList<TPdfOutlineItem>;
begin
  Node := First;
  Count := 0;
  if Parent = nil then
    List := FOutline
  else
    List := Parent.Children;
  while (Node <> nil) and (Level < 32) and (Count < 10000) and not Visited.ContainsKey(Pointer(Node)) do
  begin
    Visited.Add(Pointer(Node), True);
    Item := TPdfOutlineItem.Create(Parent);
    Item.FLevel := Level;
    Title := Node.GetString('Title');
    if Title <> nil then
      Item.FTitle := Title.AsText;
    Item.FIsOpen := Node.GetInteger('Count', 0) > 0;
    if Node.Contains('Dest') then
      Item.FDest := ResolveDestination(Node.GetRaw('Dest'))
    else if Node.Contains('A') then
    begin
      Item.FAction := ParseAction(Node.GetRaw('A'));
      if Item.FAction.Kind in [akGoTo, akGoToRemote] then
        Item.FDest := Item.FAction.Dest;
    end;
    List.Add(Item);
    WalkOutline(Node.GetDictionary('First'), Item, Level + 1, Visited);
    Node := Node.GetDictionary('Next');
    Inc(Count);
  end;
end;

function TPdfNavigation.OutlineCount: Integer;
begin
  LoadOutline;
  Result := FOutline.Count;
end;

function TPdfNavigation.LoadAnnotations(Page: TPdfPage): TObjectList<TPdfAnnotation>;
var
  Arr: IPdfArray;
  I: Integer;
  Dict, AP, N: IPdfDictionary;
  A: TPdfAnnotation;
  FlagBits: Integer;
  R: TPdfRectangle;
  NormalObj: IPdfObject;
  Contents: IPdfString;
  Key: string;
begin
  Result := TObjectList<TPdfAnnotation>.Create(True);
  Arr := Page.GetAnnotations;
  if Arr = nil then
    Exit;
  for I := 0 to Arr.Count - 1 do
  begin
    Dict := Arr.GetDictionary(I);
    if Dict = nil then
      Continue;
    A := TPdfAnnotation.Create;
    A.FDict := Dict;
    A.FSubtype := Dict.GetName('Subtype');
    if Dict.GetRectangle('Rect', R) then
      A.FRect := R
    else
      A.FRect := TPdfRectangle.Empty;
    FlagBits := Integer(Dict.GetInteger('F', 0));
    A.FFlags := [];
    if FlagBits and 1 <> 0 then Include(A.FFlags, afInvisible);
    if FlagBits and 2 <> 0 then Include(A.FFlags, afHidden);
    if FlagBits and 4 <> 0 then Include(A.FFlags, afPrint);
    if FlagBits and 8 <> 0 then Include(A.FFlags, afNoZoom);
    if FlagBits and 16 <> 0 then Include(A.FFlags, afNoRotate);
    if FlagBits and 32 <> 0 then Include(A.FFlags, afNoView);
    if FlagBits and 64 <> 0 then Include(A.FFlags, afReadOnly);
    if FlagBits and 128 <> 0 then Include(A.FFlags, afLocked);
    if FlagBits and 256 <> 0 then Include(A.FFlags, afToggleNoView);
    if FlagBits and 512 <> 0 then Include(A.FFlags, afLockedContents);
    Contents := Dict.GetString('Contents');
    if Contents <> nil then
      A.FContents := Contents.AsText;
    A.FAction := TPdfAction.None;
    A.FDest := TPdfDestination.None;
    A.FIsLink := A.FSubtype = 'Link';
    if A.FIsLink then
    begin
      if Dict.Contains('A') then
        A.FAction := ParseAction(Dict.GetRaw('A'));
      if Dict.Contains('Dest') then
      begin
        A.FDest := ResolveDestination(Dict.GetRaw('Dest'));
        if A.FAction.Kind = akNone then
        begin
          A.FAction.Kind := akGoTo;
          A.FAction.Dest := A.FDest;
        end;
      end
      else if A.FAction.Kind in [akGoTo, akGoToRemote] then
        A.FDest := A.FAction.Dest;
    end;
    // Appearance: /AP /N is a stream or a dictionary of states selected by /AS
    AP := Dict.GetDictionary('AP');
    if AP <> nil then
    begin
      NormalObj := AP.Get('N');
      A.FAppearance := PdfAsStream(NormalObj);
      if A.FAppearance = nil then
      begin
        N := PdfAsDictionary(NormalObj);
        if N <> nil then
        begin
          A.FAppearanceState := Dict.GetName('AS');
          if (A.FAppearanceState <> '') and N.Contains(A.FAppearanceState) then
            A.FAppearance := N.GetStream(A.FAppearanceState)
          else if (A.FAppearanceState = '') and (N.Count > 0) then
          begin
            // No /AS: a single state is used (pdf.js behaviour)
            for Key in N.Keys do
            begin
              A.FAppearance := N.GetStream(Key);
              if A.FAppearance <> nil then
                Break;
            end;
          end;
        end;
      end;
    end;
    Result.Add(A);
  end;
end;

end.
