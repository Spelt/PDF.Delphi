{*******************************************************************************
  Pdf.Font.Loader
  Builds a usable font from a PDF font dictionary (ISO 32000-1 §9): simple
  fonts (Type1, TrueType), composite fonts (Type0 with CIDFontType0/2) and
  Type3 fonts. Resolves encodings, widths, CMaps and CIDToGIDMap, loads the
  embedded font program (or a standard-14 substitute) and maps character
  codes to glyph outlines in text space.
  Portions derived from pdf.js (Mozilla, Apache License 2.0).
*******************************************************************************}
unit Pdf.Font.Loader;

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Character, System.Generics.Collections,
  Pdf.Core.Types, Pdf.Core.Objects, Pdf.Font.Glyphs, Pdf.Font.TrueType, Pdf.Font.CFF,
  Pdf.Font.Type1, Pdf.Font.Encodings, Pdf.Font.GlyphList, Pdf.Font.StandardFonts, Pdf.Font.CMap;

type
  TPdfFontKind = (fkType1, fkTrueType, fkType3, fkType0);

  /// <summary>One decoded character of a string shown with Tj/TJ.</summary>
  TPdfGlyphInfo = record
    Code: Integer;
    CID: Integer;
    /// <summary>Glyph index in the font program; -1 when the glyph cannot be found (advance only).</summary>
    GID: Integer;
    /// <summary>Horizontal advance w0 in text space units (already divided by 1000).</summary>
    Width: Double;
    /// <summary>Vertical fonts: advance w1 and position vector (vx, vy), text space units.</summary>
    W1, VX, VY: Double;
    /// <summary>True for a single-byte code 32: word spacing applies.</summary>
    IsSpace: Boolean;
    NumBytes: Integer;
  end;

  TPdfFont = class
  private
    FDict: IPdfDictionary;
    FResolver: IPdfResolver;
    FKind: TPdfFontKind;
    FBaseFont: string;
    FFlags: Integer;
    FSymbolic: Boolean;
    FProgram: TPdfGlyphSource;        // owned: outlines
    FSfnt: TPdfTrueTypeFont;          // owned when the program is an OpenType CFF (cmap/post lookups), else = FProgram or nil
    FIsSubstitute: Boolean;
    FStandardFont: TPdfStandardFont;
    FProgramMatrix: TPdfMatrix;
    // simple fonts
    FFirstChar: Integer;
    FWidths: TArray<Double>;          // text space (/1000), indexed by code - FirstChar; nil when absent
    FMissingWidth: Double;
    FHasWidths: Boolean;
    FNames: TPdfEncodingTable;        // glyph name per code (base encoding + Differences)
    FHasDifferences: array[0..255] of Boolean;
    FHasEncoding: Boolean;            // /Encoding present
    FBaseEncodingIsBuiltin: Boolean;
    FCodeToGID: array[0..255] of Integer; // cached, -2 = not computed
    // composite fonts
    FCMap: TPdfCMap;                  // owned unless predefined
    FCMapOwned: Boolean;
    FCIDToGID: TBytes;                // CIDToGIDMap stream data (nil = identity)
    FDefaultWidth: Double;
    FCIDWidths: TDictionary<Integer, Double>;
    FVertical: Boolean;
    FDefaultVY, FDefaultW1: Double;
    FCIDVertical: TDictionary<Integer, TArray<Double>>; // cid -> [w1, vx, vy]
    FToUnicode: TPdfCMap;             // owned: /ToUnicode (loaded lazily)
    FToUnicodeLoaded: Boolean;
    FAscent, FDescent: Double;
    FCIDIsGID: Boolean;               // CIDFontType0 with a non-CID-keyed CFF
    // type3
    FFontMatrix: TPdfMatrix;
    FCharProcs: IPdfDictionary;
    FType3Resources: IPdfDictionary;
    // cache
    FOutlines: TDictionary<Integer, TPdfGlyphOutline>;
    FOutlineMissing: TDictionary<Integer, Boolean>;
    procedure LoadDescriptor(const Descriptor: IPdfDictionary);
    procedure LoadProgram(const Descriptor: IPdfDictionary);
    procedure LoadSubstitute;
    procedure LoadSimpleFont;
    procedure LoadSimpleWidths;
    procedure LoadSimpleEncoding;
    procedure LoadType0Font;
    procedure LoadCIDWidths(const CIDFont: IPdfDictionary);
    procedure LoadType3Font;
    function SimpleGlyph(Code: Integer): Integer;
    function GlyphFromName(const Name: string; Code: Integer): Integer;
    function GlyphFromUnicode(CodePoint: Integer): Integer;
    function CIDGlyph(CID, Code, NumBytes: Integer): Integer;
    function SimpleWidth(Code, GID: Integer): Double;
    function ProgramAdvance(GID: Integer): Double;
    function GetIsType3: Boolean;
    function GetHasProgram: Boolean;
    procedure EnsureToUnicode;
    /// <summary>True when GID is a usable glyph. Glyph 0 is .notdef in TrueType and CFF, but a Type1 subset
    /// may well have a real glyph (e.g. 'A') as its first charstring.</summary>
    function Found(GID: Integer): Boolean; inline;
  public
    /// <summary>Loads a font dictionary. Never raises for a bad dictionary: falls back to Helvetica.</summary>
    constructor Create(const Dict: IPdfDictionary; const Resolver: IPdfResolver);
    destructor Destroy; override;
    /// <summary>Splits a string operand into glyphs with advances.</summary>
    function Decode(const Bytes: TBytes): TArray<TPdfGlyphInfo>;
    /// <summary>Glyph outline in text space (1 em = 1), cached. False when the glyph has no outline.</summary>
    function GetOutline(GID: Integer; out Outline: TPdfGlyphOutline): Boolean;
    /// <summary>Type3: the glyph procedure for a code (nil when absent).</summary>
    function Type3GlyphProc(Code: Integer): IPdfStream;
    /// <summary>Unicode text of a decoded glyph: /ToUnicode, then the glyph name through the Adobe Glyph List,
    /// then the code itself for simple fonts. '' when unknown.</summary>
    function GlyphUnicode(const G: TPdfGlyphInfo): string;
    /// <summary>Typographic ascent/descent in text space (em units) from the descriptor; defaults 0.75 and -0.25.</summary>
    property Ascent: Double read FAscent;
    property Descent: Double read FDescent;
    property Kind: TPdfFontKind read FKind;
    property BaseFont: string read FBaseFont;
    property Flags: Integer read FFlags;
    property IsSymbolic: Boolean read FSymbolic;
    property IsType3: Boolean read GetIsType3;
    property Vertical: Boolean read FVertical;
    /// <summary>True when no usable embedded program was found and a standard font is used instead.</summary>
    property IsSubstitute: Boolean read FIsSubstitute;
    property HasProgram: Boolean read GetHasProgram;
    /// <summary>Type3 only: glyph space to text space.</summary>
    property FontMatrix: TPdfMatrix read FFontMatrix;
    /// <summary>Type3 only: /Resources of the font (may be nil: use the page resources).</summary>
    property Type3Resources: IPdfDictionary read FType3Resources;
    property Dictionary: IPdfDictionary read FDict;
    property Programme: TPdfGlyphSource read FProgram;
  end;

implementation

{ helpers }

function IsGlyphIndexName(const Name: string; out Index: Integer): Boolean;
var
  Prefix: string;
  Digits: string;
begin
  Result := False;
  Index := -1;
  if Name = '' then
    Exit;
  if Name.StartsWith('glyph') then
    Prefix := 'glyph'
  else if Name.StartsWith('cid') then
    Prefix := 'cid'
  else if Name.StartsWith('index') then
    Prefix := 'index'
  else if (Name[1] = 'g') or (Name[1] = 'G') or (Name[1] = 'c') then
    Prefix := Name[1]
  else
    Exit;
  Digits := Copy(Name, Length(Prefix) + 1, MaxInt);
  if (Digits = '') or not TryStrToInt(Digits, Index) or (Index < 0) then
  begin
    Index := -1;
    Exit;
  end;
  Result := True;
end;

{ TPdfFont }

constructor TPdfFont.Create(const Dict: IPdfDictionary; const Resolver: IPdfResolver);
var
  Subtype: string;
  I: Integer;
begin
  inherited Create;
  FDict := Dict;
  FResolver := Resolver;
  FOutlines := TDictionary<Integer, TPdfGlyphOutline>.Create;
  FOutlineMissing := TDictionary<Integer, Boolean>.Create;
  FCIDWidths := TDictionary<Integer, Double>.Create;
  FCIDVertical := TDictionary<Integer, TArray<Double>>.Create;
  FProgramMatrix := TPdfMatrix.Scaling(0.001, 0.001);
  FFontMatrix := TPdfMatrix.Scaling(0.001, 0.001);
  FDefaultWidth := 1;
  FDefaultVY := 0.88;
  FDefaultW1 := -1;
  FAscent := 0.75;
  FDescent := -0.25;
  for I := 0 to 255 do
    FCodeToGID[I] := -2;
  if FDict = nil then
    FDict := PdfDictionary(Resolver);
  FBaseFont := FDict.GetName('BaseFont');
  Subtype := FDict.GetName('Subtype');
  if Subtype = 'Type0' then
    FKind := fkType0
  else if Subtype = 'Type3' then
    FKind := fkType3
  else if Subtype = 'TrueType' then
    FKind := fkTrueType
  else if (Subtype = 'Type1') or (Subtype = 'MMType1') then
    FKind := fkType1
  else if FDict.Contains('CharProcs') then
    FKind := fkType3
  else if FDict.Contains('DescendantFonts') then
    FKind := fkType0
  else
    FKind := fkType1;
  try
    case FKind of
      fkType0: LoadType0Font;
      fkType3: LoadType3Font;
    else
      LoadSimpleFont;
    end;
  except
    on E: Exception do
    begin
      // Anything unexpected: fall back to a plain Helvetica so that text still advances
      FreeAndNil(FProgram);
      FSfnt := nil;
      if FKind <> fkType3 then
      begin
        FKind := fkType1;
        LoadSubstitute;
      end;
    end;
  end;
end;

destructor TPdfFont.Destroy;
begin
  if (FSfnt <> nil) and (FSfnt <> TObject(FProgram)) then
    FSfnt.Free;
  FProgram.Free;
  if FCMapOwned then
    FCMap.Free;
  FToUnicode.Free;
  FCIDVertical.Free;
  FCIDWidths.Free;
  FOutlineMissing.Free;
  FOutlines.Free;
  inherited;
end;

function TPdfFont.GetIsType3: Boolean;
begin
  Result := FKind = fkType3;
end;

function TPdfFont.Found(GID: Integer): Boolean;
begin
  Result := (GID > 0) or ((GID = 0) and (FProgram is TPdfType1Font) and (TPdfType1Font(FProgram).GlyphName(0) <> '.notdef'));
end;

function TPdfFont.GetHasProgram: Boolean;
begin
  Result := FProgram <> nil;
end;

{ Descriptor and program }

procedure TPdfFont.LoadDescriptor(const Descriptor: IPdfDictionary);
begin
  if Descriptor = nil then
  begin
    FSymbolic := False;
    Exit;
  end;
  FFlags := Integer(Descriptor.GetInteger('Flags', 0));
  // Symbolic (bit 3) and not Nonsymbolic (bit 6)
  FSymbolic := ((FFlags and 4) <> 0) and ((FFlags and 32) = 0);
  FMissingWidth := Descriptor.GetNumber('MissingWidth', 0) / 1000;
  if Descriptor.GetNumber('Ascent', 0) > 0 then
    FAscent := EnsureRange(Descriptor.GetNumber('Ascent', 750) / 1000, 0.3, 2);
  if Descriptor.GetNumber('Descent', 0) < 0 then
    FDescent := EnsureRange(Descriptor.GetNumber('Descent', -250) / 1000, -1, 0);
end;

procedure TPdfFont.LoadProgram(const Descriptor: IPdfDictionary);
var
  Stream: IPdfStream;
  Data: TBytes;
  Key: string;
  TT: TPdfTrueTypeFont;
begin
  FProgram := nil;
  FSfnt := nil;
  if Descriptor = nil then
    Exit;
  for Key in TArray<string>.Create('FontFile2', 'FontFile3', 'FontFile') do
  begin
    Stream := Descriptor.GetStream(Key);
    if Stream = nil then
      Continue;
    try
      Data := Stream.GetDecodedData;
    except
      Continue;
    end;
    if Length(Data) < 4 then
      Continue;
    try
      if TPdfTrueTypeFont.IsTrueType(Data) then
      begin
        TT := TPdfTrueTypeFont.Create(Data);
        if TT.HasCFF and TPdfCFFFont.IsCFF(TT.CFFData) then
        begin
          FSfnt := TT;
          FProgram := TPdfCFFFont.Create(TT.CFFData);
        end
        else if TT.HasGlyf then
        begin
          FSfnt := TT;
          FProgram := TT;
        end
        else
        begin
          TT.Free;
          Continue;
        end;
      end
      else if TPdfCFFFont.IsCFF(Data) then
        FProgram := TPdfCFFFont.Create(Data)
      else if TPdfType1Font.IsType1(Data) then
        FProgram := TPdfType1Font.Create(Data)
      else
        Continue;
    except
      on EPdfFontError do
      begin
        if (FSfnt <> nil) and (FSfnt <> TObject(FProgram)) then
          FSfnt.Free;
        FSfnt := nil;
        FreeAndNil(FProgram);
        Continue;
      end;
    end;
    if (FProgram <> nil) and (FProgram.GlyphCount > 0) then
      Break;
    if FSfnt <> nil then
      FreeAndNil(FSfnt);
    FreeAndNil(FProgram);
  end;
  if FProgram <> nil then
    FProgramMatrix := FProgram.FontMatrix;
end;

procedure TPdfFont.LoadSubstitute;
var
  Data: TBytes;
  TT: TPdfTrueTypeFont;
begin
  FIsSubstitute := True;
  PdfStandardFontByName(FBaseFont, FFlags, FStandardFont);
  Data := PdfStandardFontData(FStandardFont);
  try
    // Sniff the format: Liberation is TrueType, the Foxit fonts are bare CFF
    if TPdfTrueTypeFont.IsTrueType(Data) then
    begin
      TT := TPdfTrueTypeFont.Create(Data);
      FSfnt := TT;
      if TT.HasCFF then
        FProgram := TPdfCFFFont.Create(TT.CFFData)
      else
        FProgram := TT;
    end
    else if TPdfCFFFont.IsCFF(Data) then
      FProgram := TPdfCFFFont.Create(Data)
    else
      FProgram := TPdfType1Font.Create(Data);
    FProgramMatrix := FProgram.FontMatrix;
  except
    if (FSfnt <> nil) and (FSfnt <> TObject(FProgram)) then
      FSfnt.Free;
    FSfnt := nil;
    FreeAndNil(FProgram);
  end;
end;

{ Simple fonts }

procedure TPdfFont.LoadSimpleFont;
var
  Descriptor: IPdfDictionary;
begin
  Descriptor := FDict.GetDictionary('FontDescriptor');
  LoadDescriptor(Descriptor);
  LoadProgram(Descriptor);
  if FProgram = nil then
  begin
    // Standard 14 fonts have no descriptor: the name decides symbolic-ness
    LoadSubstitute;
    if Descriptor = nil then
      FSymbolic := PdfStandardFontIsSymbolic(FStandardFont);
  end;
  LoadSimpleWidths;
  LoadSimpleEncoding;
end;

procedure TPdfFont.LoadSimpleWidths;
var
  Arr: IPdfArray;
  I: Integer;
begin
  FFirstChar := Integer(FDict.GetInteger('FirstChar', 0));
  Arr := FDict.GetArray('Widths');
  FHasWidths := (Arr <> nil) and (Arr.Count > 0);
  if FHasWidths then
  begin
    SetLength(FWidths, Arr.Count);
    for I := 0 to Arr.Count - 1 do
      FWidths[I] := Arr.GetNumber(I, FMissingWidth * 1000) / 1000;
  end;
end;

procedure TPdfFont.LoadSimpleEncoding;
var
  EncObj: IPdfObject;
  EncDict: IPdfDictionary;
  Base: PPdfEncodingTable;
  BaseName: string;
  Diff: IPdfArray;
  I, Code: Integer;
  Item: IPdfObject;
  UseBuiltin: Boolean;
begin
  for I := 0 to 255 do
  begin
    FNames[I] := '';
    FHasDifferences[I] := False;
  end;
  EncObj := FDict.Get('Encoding');
  FHasEncoding := not PdfIsNull(EncObj);
  Base := nil;
  BaseName := '';
  if PdfIsName(EncObj) then
    BaseName := (EncObj as IPdfName).Name
  else
  begin
    EncDict := PdfAsDictionary(EncObj);
    if EncDict <> nil then
      BaseName := EncDict.GetName('BaseEncoding');
  end;
  if BaseName <> '' then
    Base := PdfEncodingByName(BaseName);
  // Default base encoding
  UseBuiltin := False;
  if Base = nil then
  begin
    if FIsSubstitute and (FStandardFont = sfSymbol) then
      Base := PdfSymbolEncoding          // names of the Symbol font, looked up in the substitute
    else if FIsSubstitute and (FStandardFont = sfZapfDingbats) then
      Base := PdfZapfDingbatsEncoding
    else if FSymbolic and not FIsSubstitute then
    begin
      UseBuiltin := True;                // embedded symbolic font: its built-in encoding; names only from Differences
      if (FProgram = nil) or not FProgram.HasCodeMap then
        Base := PdfStandardEncoding;     // ... unless the program has no code mapping at all
    end
    else
      Base := PdfStandardEncoding;
  end;
  FBaseEncodingIsBuiltin := UseBuiltin;
  if Base <> nil then
    for I := 0 to 255 do
      FNames[I] := Base^[I];
  // Differences
  if EncDict <> nil then
  begin
    Diff := EncDict.GetArray('Differences');
    if Diff <> nil then
    begin
      Code := 0;
      for I := 0 to Diff.Count - 1 do
      begin
        Item := Diff.Get(I);
        if PdfIsNumber(Item) then
          Code := Integer(PdfAsInteger(Item))
        else if PdfIsName(Item) then
        begin
          if (Code >= 0) and (Code <= 255) then
          begin
            FNames[Code] := (Item as IPdfName).Name;
            FHasDifferences[Code] := True;
          end;
          Inc(Code);
        end;
      end;
    end;
  end;
end;

function TPdfFont.GlyphFromUnicode(CodePoint: Integer): Integer;
var
  Name: string;
begin
  Result := -1;
  if (CodePoint < 0) or (FProgram = nil) then
    Exit;
  if (FSfnt <> nil) and FSfnt.HasUnicodeMap then
    Result := FSfnt.GlyphByUnicode(CodePoint);
  if not Found(Result) and FProgram.HasGlyphNames then
  begin
    Name := PdfUnicodeToGlyphName(CodePoint);
    if Name <> '' then
      Result := FProgram.GlyphByName(Name);
    if not Found(Result) then
      Result := FProgram.GlyphByName(Format('uni%.4X', [CodePoint]));
  end;
  if not Found(Result) then
    Result := -1;
end;

function TPdfFont.GlyphFromName(const Name: string; Code: Integer): Integer;
var
  U, Idx: Integer;
begin
  Result := -1;
  if (Name = '') or (FProgram = nil) then
    Exit;
  if FProgram.HasGlyphNames then
  begin
    Result := FProgram.GlyphByName(Name);
    if Found(Result) then
      Exit;
  end;
  U := PdfGlyphNameToUnicode(Name);
  if U < 0 then
    U := PdfDingbatsGlyphNameToUnicode(Name);
  if U >= 0 then
  begin
    Result := GlyphFromUnicode(U);
    if Found(Result) then
      Exit;
  end;
  // gXX / cidXX / GXX: glyph index
  if IsGlyphIndexName(Name, Idx) and (Idx < FProgram.GlyphCount) then
    Exit(Idx);
  Result := -1;
end;

function TPdfFont.SimpleGlyph(Code: Integer): Integer;
var
  Name: string;
  TT: TPdfTrueTypeFont;
  StdName: string;
  U: Integer;
begin
  if (Code < 0) or (Code > 255) then
    Exit(-1);
  if FCodeToGID[Code] <> -2 then
    Exit(FCodeToGID[Code]);
  Result := -1;
  Name := FNames[Code];
  if FProgram <> nil then
  begin
    if FSfnt <> nil then
    begin
      TT := FSfnt;
      // TrueType (pdf.js heuristics, simplified)
      if FSymbolic and not FHasDifferences[Code] and not FIsSubstitute then
      begin
        Result := TT.GlyphBySymbolCode(Code);
        if not Found(Result) then
          Result := TT.GlyphByMacCode(Code);
        if not Found(Result) and (Name <> '') then
          Result := GlyphFromName(Name, Code);
        if not Found(Result) and TT.HasUnicodeCmap then
        begin
          StdName := PdfStandardEncoding^[Code];
          if StdName <> '' then
            Result := GlyphFromUnicode(PdfGlyphNameToUnicode(StdName));
        end;
      end
      else
      begin
        if Name <> '' then
        begin
          U := PdfGlyphNameToUnicode(Name);
          if (U >= 0) and TT.HasUnicodeCmap then
            Result := TT.GlyphByUnicode(U);
          if not Found(Result) then
            Result := GlyphFromName(Name, Code);
        end;
        if not Found(Result) and not FIsSubstitute then
        begin
          Result := TT.GlyphBySymbolCode(Code);
          if not Found(Result) then
            Result := TT.GlyphByMacCode(Code);
        end;
        if not Found(Result) and (Name = '') and TT.HasUnicodeCmap then
          Result := TT.GlyphByUnicode(Code);
      end;
      if not Found(Result) and not FIsSubstitute and not TT.HasCmap then
      begin
        // No cmap at all: glyph names via post, else the code is the glyph index
        if (Name <> '') and TT.HasPostNames then
          Result := TT.GlyphByName(Name);
        if not Found(Result) and (Code < TT.GlyphCount) then
          Result := Code;
      end;
    end
    else
    begin
      // Type1 / CFF program
      if (Name <> '') and (FHasDifferences[Code] or not FBaseEncodingIsBuiltin or not FProgram.HasCodeMap) then
        Result := GlyphFromName(Name, Code);
      if not Found(Result) and FProgram.HasCodeMap and (FBaseEncodingIsBuiltin or (Name = '') or not FHasEncoding) then
        Result := FProgram.GlyphByCode(Code);
      if not Found(Result) and (Name <> '') then
        Result := GlyphFromName(Name, Code);
      if not Found(Result) and FProgram.HasCodeMap then
        Result := FProgram.GlyphByCode(Code);
    end;
  end;
  if not Found(Result) then
    Result := -1;
  FCodeToGID[Code] := Result;
end;

function TPdfFont.ProgramAdvance(GID: Integer): Double;
var
  Adv: Single;
  X, Y: Double;
begin
  Result := -1;
  if (FProgram = nil) or (GID < 0) then
    Exit;
  Adv := FProgram.GetAdvance(GID);
  if Adv < 0 then
    Exit;
  X := Adv;
  Y := 0;
  // Only the scale part of the matrix applies to an advance
  Result := X * FProgramMatrix.A + Y * FProgramMatrix.C;
end;

function TPdfFont.SimpleWidth(Code, GID: Integer): Double;
var
  I: Integer;
  W: Double;
begin
  if FHasWidths then
  begin
    I := Code - FFirstChar;
    if (I >= 0) and (I < Length(FWidths)) then
      Exit(FWidths[I]);
    if FMissingWidth > 0 then
      Exit(FMissingWidth);
  end;
  W := ProgramAdvance(GID);
  if W >= 0 then
    Exit(W);
  if FMissingWidth > 0 then
    Exit(FMissingWidth);
  if FHasWidths then
    Exit(0);
  Result := 0.5;
end;

{ Composite fonts }

procedure TPdfFont.LoadType0Font;
var
  Descendants: IPdfArray;
  CIDFont, Descriptor: IPdfDictionary;
  EncObj: IPdfObject;
  Stream: IPdfStream;
  ParentName: string;
  Parent: TPdfCMap;
  SubType: string;
  MapObj: IPdfObject;
begin
  // Encoding CMap
  EncObj := FDict.Get('Encoding');
  FCMap := nil;
  FCMapOwned := False;
  if PdfIsName(EncObj) then
    FCMap := TPdfCMap.Predefined((EncObj as IPdfName).Name)
  else
  begin
    Stream := PdfAsStream(EncObj);
    if Stream <> nil then
    begin
      Parent := nil;
      ParentName := Stream.Dict.GetName('UseCMap');
      if ParentName <> '' then
        Parent := TPdfCMap.Predefined(ParentName);
      FCMap := TPdfCMap.Parse(Stream.GetDecodedData, Parent);
      FCMapOwned := True;
    end;
  end;
  if FCMap = nil then
  begin
    FCMap := TPdfCMap.Identity(False);
    FCMapOwned := True;
  end;
  FVertical := FCMap.Vertical;
  // Descendant CIDFont
  Descendants := FDict.GetArray('DescendantFonts');
  CIDFont := nil;
  if Descendants <> nil then
    CIDFont := Descendants.GetDictionary(0);
  if CIDFont = nil then
    CIDFont := PdfDictionary(FResolver);
  SubType := CIDFont.GetName('Subtype');
  Descriptor := CIDFont.GetDictionary('FontDescriptor');
  LoadDescriptor(Descriptor);
  LoadProgram(Descriptor);
  if FProgram = nil then
  begin
    LoadSubstitute;
    EnsureToUnicode;
  end
  else
  begin
    MapObj := CIDFont.Get('CIDToGIDMap');
    Stream := PdfAsStream(MapObj);
    if Stream <> nil then
      FCIDToGID := Stream.GetDecodedData;
    FCIDIsGID := (SubType = 'CIDFontType0') and not FProgram.IsCIDKeyed;
  end;
  LoadCIDWidths(CIDFont);
end;

procedure TPdfFont.LoadCIDWidths(const CIDFont: IPdfDictionary);
var
  W, Inner, DW2: IPdfArray;
  I, J, First, Last: Integer;
  Item: IPdfObject;
  V: TArray<Double>;
begin
  FDefaultWidth := CIDFont.GetNumber('DW', 1000) / 1000;
  W := CIDFont.GetArray('W');
  if W <> nil then
  begin
    I := 0;
    while I < W.Count do
    begin
      First := Integer(W.GetInteger(I, 0));
      Item := W.Get(I + 1);
      if (Item <> nil) and (Item.Kind = okArray) then
      begin
        Inner := Item as IPdfArray;
        for J := 0 to Inner.Count - 1 do
          FCIDWidths.AddOrSetValue(First + J, Inner.GetNumber(J, 0) / 1000);
        Inc(I, 2);
      end
      else
      begin
        Last := Integer(W.GetInteger(I + 1, First));
        if (Last >= First) and (Last - First < 65536) then
          for J := First to Last do
            FCIDWidths.AddOrSetValue(J, W.GetNumber(I + 2, 0) / 1000);
        Inc(I, 3);
      end;
    end;
  end;
  DW2 := CIDFont.GetArray('DW2');
  if (DW2 <> nil) and (DW2.Count >= 2) then
  begin
    FDefaultVY := DW2.GetNumber(0, 880) / 1000;
    FDefaultW1 := DW2.GetNumber(1, -1000) / 1000;
  end;
  W := CIDFont.GetArray('W2');
  if W <> nil then
  begin
    I := 0;
    while I < W.Count do
    begin
      First := Integer(W.GetInteger(I, 0));
      Item := W.Get(I + 1);
      if (Item <> nil) and (Item.Kind = okArray) then
      begin
        Inner := Item as IPdfArray;
        J := 0;
        while J + 2 < Inner.Count do
        begin
          V := [Inner.GetNumber(J) / 1000, Inner.GetNumber(J + 1) / 1000, Inner.GetNumber(J + 2) / 1000];
          FCIDVertical.AddOrSetValue(First + J div 3, V);
          Inc(J, 3);
        end;
        Inc(I, 2);
      end
      else
      begin
        Last := Integer(W.GetInteger(I + 1, First));
        V := [W.GetNumber(I + 2) / 1000, W.GetNumber(I + 3) / 1000, W.GetNumber(I + 4) / 1000];
        if (Last >= First) and (Last - First < 65536) then
          for J := First to Last do
            FCIDVertical.AddOrSetValue(J, V);
        Inc(I, 5);
      end;
    end;
  end;
end;

function TPdfFont.CIDGlyph(CID, Code, NumBytes: Integer): Integer;
var
  Text: string;
  U: Integer;
begin
  Result := -1;
  if FProgram = nil then
    Exit;
  if FIsSubstitute then
  begin
    // Non-embedded CID font: go through ToUnicode to the substitute's glyphs
    if FToUnicode <> nil then
    begin
      U := -1;
      if FToUnicode.HasUnicodeMappings then
      begin
        Text := FToUnicode.ToUnicode(Code, NumBytes);
        if Text <> '' then
        begin
          if (Length(Text) >= 2) and Text[1].IsHighSurrogate and Text[2].IsLowSurrogate then
            U := Char.ConvertToUtf32(Text, 1)
          else
            U := Ord(Text[1]);
        end;
      end
      else if FToUnicode.IsIdentity then
        U := Code
      else
      begin
        // CID-only ToUnicode maps: pdf.js treats the values as code points
        U := FToUnicode.LookupCID(Code, NumBytes);
        if U = 0 then
          U := -1;
      end;
      if U >= 0 then
        Result := GlyphFromUnicode(U);
    end;
    if Result < 0 then
      Result := -1;
    Exit;
  end;
  if FCIDToGID <> nil then
  begin
    if 2 * CID + 1 < Length(FCIDToGID) then
      Result := (FCIDToGID[2 * CID] shl 8) or FCIDToGID[2 * CID + 1]
    else
      Result := 0;
  end
  else if FProgram.IsCIDKeyed then
    Result := FProgram.GlyphByCID(CID)
  else
    Result := CID;
  if (Result < 0) or (Result >= FProgram.GlyphCount) then
    Result := -1;
end;

{ Type3 }

procedure TPdfFont.LoadType3Font;
var
  Arr: IPdfArray;
  V: TArray<Double>;
begin
  FFontMatrix := TPdfMatrix.Scaling(0.001, 0.001);
  Arr := FDict.GetArray('FontMatrix');
  if (Arr <> nil) and Arr.GetNumbers(V, 6) then
    FFontMatrix := TPdfMatrix.Create(V[0], V[1], V[2], V[3], V[4], V[5]);
  FCharProcs := FDict.GetDictionary('CharProcs');
  FType3Resources := FDict.GetDictionary('Resources');
  LoadDescriptor(FDict.GetDictionary('FontDescriptor'));
  LoadSimpleWidths;
  LoadSimpleEncoding;
end;

procedure TPdfFont.EnsureToUnicode;
var
  TU: IPdfStream;
begin
  if FToUnicodeLoaded then
    Exit;
  FToUnicodeLoaded := True;
  TU := FDict.GetStream('ToUnicode');
  if TU <> nil then
    try
      FToUnicode := TPdfCMap.Parse(TU.GetDecodedData, nil);
    except
      FToUnicode := nil;
    end;
end;

function TPdfFont.GlyphUnicode(const G: TPdfGlyphInfo): string;
var
  Name: string;
  U: Integer;
begin
  Result := '';
  EnsureToUnicode;
  if (FToUnicode <> nil) and FToUnicode.HasUnicodeMappings then
  begin
    Result := FToUnicode.ToUnicode(G.Code, G.NumBytes);
    if Result <> '' then
      Exit;
  end;
  if FKind = fkType0 then
    Exit('');
  if (G.Code >= 0) and (G.Code <= 255) then
  begin
    Name := FNames[G.Code];
    if (Name = '') and (G.Code >= 128) then
      Name := PdfWinAnsiEncoding^[G.Code]; // symbolic fonts without names: the usual Windows meaning of the code
    if Name <> '' then
    begin
      U := PdfGlyphNameToUnicode(Name);
      if (U < 0) and (FIsSubstitute and (FStandardFont = sfZapfDingbats)) then
        U := PdfDingbatsGlyphNameToUnicode(Name);
      if (U > 0) and (U <= $10FFFF) then
        Exit(Char.ConvertFromUtf32(U));
    end;
    if (G.Code >= 32) and (G.Code <> 127) then
      Result := Char(G.Code);
  end;
end;

function TPdfFont.Type3GlyphProc(Code: Integer): IPdfStream;
var
  Name: string;
begin
  Result := nil;
  if (FCharProcs = nil) or (Code < 0) or (Code > 255) then
    Exit;
  Name := FNames[Code];
  if Name = '' then
    Exit;
  Result := FCharProcs.GetStream(Name);
end;

{ Decoding and outlines }

function TPdfFont.Decode(const Bytes: TBytes): TArray<TPdfGlyphInfo>;
var
  N, I, Pos, Code, CID, NumBytes: Integer;
  G: TPdfGlyphInfo;
  V: TArray<Double>;
  X, Y: Double;
begin
  N := 0;
  SetLength(Result, Length(Bytes));
  if FKind = fkType0 then
  begin
    Pos := 0;
    while Pos < Length(Bytes) do
    begin
      FCMap.NextCode(Bytes, Pos, Code, CID, NumBytes);
      if NumBytes <= 0 then
        Break;
      G := Default(TPdfGlyphInfo);
      G.Code := Code;
      G.CID := CID;
      G.NumBytes := NumBytes;
      G.IsSpace := (NumBytes = 1) and (Code = 32);
      G.GID := CIDGlyph(CID, Code, NumBytes);
      if not FCIDWidths.TryGetValue(CID, G.Width) then
        G.Width := FDefaultWidth;
      if FVertical then
      begin
        if FCIDVertical.TryGetValue(CID, V) then
        begin
          G.W1 := V[0];
          G.VX := V[1];
          G.VY := V[2];
        end
        else
        begin
          G.W1 := FDefaultW1;
          G.VX := G.Width / 2;
          G.VY := FDefaultVY;
        end;
      end;
      Result[N] := G;
      Inc(N);
    end;
  end
  else
  begin
    for I := 0 to High(Bytes) do
    begin
      G := Default(TPdfGlyphInfo);
      G.Code := Bytes[I];
      G.CID := G.Code;
      G.NumBytes := 1;
      G.IsSpace := G.Code = 32;
      if FKind = fkType3 then
      begin
        G.GID := G.Code;
        X := 0;
        if FHasWidths and (G.Code - FFirstChar >= 0) and (G.Code - FFirstChar < Length(FWidths)) then
          X := FWidths[G.Code - FFirstChar] * 1000; // glyph space
        Y := 0;
        // Width through the font matrix (x component only)
        G.Width := X * FFontMatrix.A + Y * FFontMatrix.C;
      end
      else
      begin
        G.GID := SimpleGlyph(G.Code);
        G.Width := SimpleWidth(G.Code, G.GID);
      end;
      Result[N] := G;
      Inc(N);
    end;
  end;
  SetLength(Result, N);
end;

function TPdfFont.GetOutline(GID: Integer; out Outline: TPdfGlyphOutline): Boolean;
begin
  Outline.Clear;
  if (FProgram = nil) or (GID < 0) then
    Exit(False);
  if FOutlines.TryGetValue(GID, Outline) then
    Exit(True);
  if FOutlineMissing.ContainsKey(GID) then
    Exit(False);
  try
    Result := FProgram.GetOutline(GID, Outline);
  except
    Result := False;
  end;
  if Result then
  begin
    Outline.Trim;
    Outline.Transform(FProgramMatrix);
    FOutlines.Add(GID, Outline);
  end
  else
    FOutlineMissing.Add(GID, True);
end;

end.
