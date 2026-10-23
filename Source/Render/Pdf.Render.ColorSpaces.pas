{*******************************************************************************
  Pdf.Render.ColorSpaces
  Colour spaces (ISO 32000-1 §8.6): Device*, CalGray/CalRGB/Lab, ICCBased
  (by component count), Indexed, Separation, DeviceN and Pattern.
  Converts component values to sRGB for Skia.
  Portions derived from pdf.js (Mozilla, Apache License 2.0).
*******************************************************************************}
unit Pdf.Render.ColorSpaces;

interface

uses
  System.SysUtils, System.Math, System.UITypes, System.Generics.Collections,
  Pdf.Core.Types, Pdf.Core.Objects, Pdf.Render.Functions;

type
  TPdfColorSpaceFamily = (csDeviceGray, csDeviceRGB, csDeviceCMYK, csCalGray, csCalRGB,
    csLab, csICCBased, csIndexed, csSeparation, csDeviceN, csPattern);

  /// <summary>sRGB components in 0..1.</summary>
  TPdfRGB = record
    R, G, B: Single;
    class function Create(AR, AG, AB: Single): TPdfRGB; static; inline;
    function ToAlphaColor(Alpha: Single = 1): TAlphaColor;
  end;

  TPdfColorSpace = class
  private
    FFamily: TPdfColorSpaceFamily;
    FNComponents: Integer;
    class function ParseLevel(const Obj: IPdfObject; const Resources: IPdfDictionary; const Resolver: IPdfResolver;
      Depth: Integer): TPdfColorSpace; static;
    class function ParseName(const Name: string; const Resources: IPdfDictionary; const Resolver: IPdfResolver;
      Depth: Integer): TPdfColorSpace; static;
    class function ParseArray(const Arr: IPdfArray; const Resources: IPdfDictionary; const Resolver: IPdfResolver;
      Depth: Integer): TPdfColorSpace; static;
  protected
    constructor CreateFamily(AFamily: TPdfColorSpaceFamily; ANComponents: Integer);
  public
    /// <summary>Parses a colour space object: a name (DeviceGray, DeviceRGB, DeviceCMYK, Pattern, the
    /// abbreviations G, RGB, CMYK, I, or a key of the /ColorSpace resource dictionary) or an array
    /// ([/ICCBased stream], [/Indexed base hival lookup], [/Separation name alt tint], [/DeviceN names alt tint attrs],
    /// [/Pattern base], [/CalRGB dict], [/CalGray dict], [/Lab dict]). Returns nil when the object is not a
    /// usable colour space; the caller then falls back to DeviceGray. The caller owns the result.</summary>
    class function Parse(const Obj: IPdfObject; const Resources: IPdfDictionary; const Resolver: IPdfResolver): TPdfColorSpace; static;
    class function DeviceGray: TPdfColorSpace; static;
    class function DeviceRGB: TPdfColorSpace; static;
    class function DeviceCMYK: TPdfColorSpace; static;
    class function Pattern(ABase: TPdfColorSpace = nil): TPdfColorSpace; static;
    /// <summary>Converts component values (nominal ranges, e.g. 0..1, Indexed 0..hival, Lab L 0..100) to sRGB.
    /// Missing components count as 0. For Pattern returns black.</summary>
    function ToRGB(const Comps: TArray<Double>): TPdfRGB; virtual;
    function ToAlphaColor(const Comps: TArray<Double>; Alpha: Single = 1): TAlphaColor;
    /// <summary>Initial colour when the space is selected (black; CMYK 0 0 0 1; Separation/DeviceN all 1; Indexed 0; Lab 0 0 0).</summary>
    function InitialColor: TArray<Double>; virtual;
    /// <summary>Default /Decode array for image samples with the given bit depth: [0 1 ...], Indexed [0 2^bpc-1], Lab [0 100 amin amax bmin bmax].</summary>
    function DefaultDecode(BitsPerComponent: Integer): TArray<Double>; virtual;
    /// <summary>True for a Separation /None colour space: nothing is painted.</summary>
    function IsNone: Boolean; virtual;
    /// <summary>For Indexed: the base colour space; for Pattern: the underlying space for uncoloured patterns (may be nil).</summary>
    function BaseColorSpace: TPdfColorSpace; virtual;
    /// <summary>Indexed only: highest valid index; -1 otherwise.</summary>
    function HiVal: Integer; virtual;
    /// <summary>Indexed only: sRGB of one palette entry (clamped to 0..HiVal).</summary>
    function LookupRGB(Index: Integer): TPdfRGB; virtual;
    property Family: TPdfColorSpaceFamily read FFamily;
    property NComponents: Integer read FNComponents;
    function IsPattern: Boolean; inline;
  end;

implementation

const
  /// <summary>Maximum nesting of colour spaces (base/alternate spaces and resource names); stops reference loops.</summary>
  MaxColorSpaceDepth = 8;
  /// <summary>Maximum number of DeviceN colourants (ISO 32000-1 Annex C).</summary>
  MaxDeviceNComponents = 32;

{ TPdfRGB }

class function TPdfRGB.Create(AR, AG, AB: Single): TPdfRGB;
begin
  Result.R := AR;
  Result.G := AG;
  Result.B := AB;
end;

function TPdfRGB.ToAlphaColor(Alpha: Single): TAlphaColor;

  function Clamp(V: Single): Byte;
  begin
    if V <= 0 then
      Result := 0
    else if V >= 1 then
      Result := 255
    else
      Result := Round(V * 255);
  end;

begin
  Result := (TAlphaColor(Clamp(Alpha)) shl 24) or (TAlphaColor(Clamp(R)) shl 16) or
            (TAlphaColor(Clamp(G)) shl 8) or TAlphaColor(Clamp(B));
end;

type
  /// <summary>DeviceGray/RGB/CMYK, and CalGray/CalRGB treated as their device counterparts.</summary>
  TPdfDeviceColorSpace = class(TPdfColorSpace)
  public
    function ToRGB(const Comps: TArray<Double>): TPdfRGB; override;
  end;

  /// <summary>ICCBased: the profile is not interpreted; the components are converted as DeviceGray/RGB/CMYK by N.</summary>
  TPdfICCBasedColorSpace = class(TPdfDeviceColorSpace)
  private
    FRange: TArray<Double>;
  public
    constructor Create(N: Integer; const ARange: TArray<Double>);
    function InitialColor: TArray<Double>; override;
    function DefaultDecode(BitsPerComponent: Integer): TArray<Double>; override;
  end;

  /// <summary>CIE L*a*b* converted to XYZ with the space's white point, then to sRGB.</summary>
  TPdfLabColorSpace = class(TPdfColorSpace)
  private
    FXW, FYW, FZW: Double;
    FAMin, FAMax, FBMin, FBMax: Double;
  public
    constructor Create(const Dict: IPdfDictionary; const Resolver: IPdfResolver);
    function ToRGB(const Comps: TArray<Double>): TPdfRGB; override;
    function DefaultDecode(BitsPerComponent: Integer): TArray<Double>; override;
  end;

  TPdfIndexedColorSpace = class(TPdfColorSpace)
  private
    FBase: TPdfColorSpace;
    FHiVal: Integer;
    FPalette: TArray<TPdfRGB>;
  public
    /// <summary>Takes ownership of ABase. Lookup may be shorter than (hival+1)*n bytes; missing entries are 0.</summary>
    constructor Create(ABase: TPdfColorSpace; AHiVal: Integer; const Lookup: TBytes);
    destructor Destroy; override;
    function ToRGB(const Comps: TArray<Double>): TPdfRGB; override;
    function InitialColor: TArray<Double>; override;
    function DefaultDecode(BitsPerComponent: Integer): TArray<Double>; override;
    function BaseColorSpace: TPdfColorSpace; override;
    function HiVal: Integer; override;
    function LookupRGB(Index: Integer): TPdfRGB; override;
  end;

  /// <summary>Separation and DeviceN: the tint transform maps the components into the alternate space.
  /// One-component spaces cache 256 quantised tints (not thread-safe, like the rest of a page render).</summary>
  TPdfTintColorSpace = class(TPdfColorSpace)
  private
    FAlternate: TPdfColorSpace;
    FTint: TPdfFunction;
    FIsAll: Boolean;
    FIsNone: Boolean;
    FCache: array[0..255] of TPdfRGB;
    FCached: array[0..255] of Boolean;
    function Transform(const Comps: TArray<Double>): TPdfRGB;
  public
    /// <summary>Takes ownership of AAlternate and ATint (either may be nil for /All and /None).</summary>
    constructor Create(AFamily: TPdfColorSpaceFamily; ANComponents: Integer; AAlternate: TPdfColorSpace;
      ATint: TPdfFunction; AIsAll, AIsNone: Boolean);
    destructor Destroy; override;
    function ToRGB(const Comps: TArray<Double>): TPdfRGB; override;
    function InitialColor: TArray<Double>; override;
    function IsNone: Boolean; override;
  end;

  TPdfPatternColorSpace = class(TPdfColorSpace)
  private
    FBase: TPdfColorSpace;
  public
    constructor Create(ABase: TPdfColorSpace);
    destructor Destroy; override;
    function BaseColorSpace: TPdfColorSpace; override;
  end;

{ Helpers }

function Comp(const Comps: TArray<Double>; I: Integer): Double; inline;
begin
  if I < Length(Comps) then
  begin
    Result := Comps[I];
    if IsNaN(Result) then
      Result := 0;
  end
  else
    Result := 0;
end;

function Clamp01(V: Double): Double; inline;
begin
  if V <= 0 then
    Result := 0
  else if V >= 1 then
    Result := 1
  else
    Result := V;
end;

function GetNumbers(const Dict: IPdfDictionary; const Key: string; const Resolver: IPdfResolver;
  out Values: TArray<Double>): Boolean;
var
  Arr: IPdfArray;
  Item: IPdfObject;
  I: Integer;
begin
  Values := nil;
  if Dict = nil then
    Exit(False);
  Arr := PdfAsArray(PdfResolve(Resolver, Dict.Get(Key)));
  if Arr = nil then
    Exit(False);
  SetLength(Values, Arr.Count);
  for I := 0 to Arr.Count - 1 do
  begin
    Item := PdfResolve(Resolver, Arr.Get(I));
    if not PdfIsNumber(Item) then
    begin
      Values := nil;
      Exit(False);
    end;
    Values[I] := PdfAsNumber(Item);
  end;
  Result := True;
end;

{ TPdfColorSpace }

constructor TPdfColorSpace.CreateFamily(AFamily: TPdfColorSpaceFamily; ANComponents: Integer);
begin
  inherited Create;
  FFamily := AFamily;
  FNComponents := ANComponents;
end;

class function TPdfColorSpace.DeviceGray: TPdfColorSpace;
begin
  Result := TPdfDeviceColorSpace.CreateFamily(csDeviceGray, 1);
end;

class function TPdfColorSpace.DeviceRGB: TPdfColorSpace;
begin
  Result := TPdfDeviceColorSpace.CreateFamily(csDeviceRGB, 3);
end;

class function TPdfColorSpace.DeviceCMYK: TPdfColorSpace;
begin
  Result := TPdfDeviceColorSpace.CreateFamily(csDeviceCMYK, 4);
end;

class function TPdfColorSpace.Pattern(ABase: TPdfColorSpace): TPdfColorSpace;
begin
  Result := TPdfPatternColorSpace.Create(ABase);
end;

class function TPdfColorSpace.Parse(const Obj: IPdfObject; const Resources: IPdfDictionary; const Resolver: IPdfResolver): TPdfColorSpace;
begin
  Result := ParseLevel(Obj, Resources, Resolver, 0);
end;

class function TPdfColorSpace.ParseLevel(const Obj: IPdfObject; const Resources: IPdfDictionary;
  const Resolver: IPdfResolver; Depth: Integer): TPdfColorSpace;
var
  O: IPdfObject;
  Arr: IPdfArray;
begin
  Result := nil;
  if Depth > MaxColorSpaceDepth then
    Exit;
  try
    O := PdfResolve(Resolver, Obj);
    if PdfIsName(O) then
      Result := ParseName((O as IPdfName).Name, Resources, Resolver, Depth)
    else
    begin
      Arr := PdfAsArray(O);
      if (Arr <> nil) and (Arr.Count > 0) then
        Result := ParseArray(Arr, Resources, Resolver, Depth);
    end;
  except
    // Parse never raises; sub-parsers free what they built before re-raising.
    Result := nil;
  end;
end;

class function TPdfColorSpace.ParseName(const Name: string; const Resources: IPdfDictionary;
  const Resolver: IPdfResolver; Depth: Integer): TPdfColorSpace;
var
  CSDict: IPdfDictionary;
begin
  Result := nil;
  if (Name = 'DeviceGray') or (Name = 'G') then
    Exit(DeviceGray);
  if (Name = 'DeviceRGB') or (Name = 'RGB') then
    Exit(DeviceRGB);
  if (Name = 'DeviceCMYK') or (Name = 'CMYK') then
    Exit(DeviceCMYK);
  if Name = 'CalGray' then
    Exit(TPdfDeviceColorSpace.CreateFamily(csCalGray, 1));
  if Name = 'CalRGB' then
    Exit(TPdfDeviceColorSpace.CreateFamily(csCalRGB, 3));
  if Name = 'Pattern' then
    Exit(Pattern(nil));
  // Any other name is a key of the /ColorSpace resource dictionary. The depth limit stops
  // resources that refer to themselves (/CS0 /CS0) or to each other.
  if (Resources <> nil) and (Name <> '') then
  begin
    CSDict := PdfAsDictionary(PdfResolve(Resolver, Resources.Get('ColorSpace')));
    if (CSDict <> nil) and CSDict.Contains(Name) then
      Result := ParseLevel(CSDict.GetRaw(Name), Resources, Resolver, Depth + 1);
  end;
end;

class function TPdfColorSpace.ParseArray(const Arr: IPdfArray; const Resources: IPdfDictionary;
  const Resolver: IPdfResolver; Depth: Integer): TPdfColorSpace;
var
  FamilyName: string;
  Base, Alt: TPdfColorSpace;
  Tint: TPdfFunction;
  O: IPdfObject;
  Dict: IPdfDictionary;
  Names: IPdfArray;
  Lookup: TBytes;
  Range: TArray<Double>;
  N, I, Hi: Integer;
  AllNone: Boolean;
  Colorant: string;
begin
  Result := nil;
  FamilyName := PdfAsName(PdfResolve(Resolver, Arr.Get(0)));
  if FamilyName = '' then
    Exit;

  // [/DeviceRGB], [/Pattern] and friends: a family name in a one-element (or over-long) array.
  if (FamilyName = 'DeviceGray') or (FamilyName = 'G') or (FamilyName = 'DeviceRGB') or (FamilyName = 'RGB') or
     (FamilyName = 'DeviceCMYK') or (FamilyName = 'CMYK') then
    Exit(ParseName(FamilyName, nil, Resolver, Depth));

  if FamilyName = 'CalGray' then
    Exit(TPdfDeviceColorSpace.CreateFamily(csCalGray, 1));
  if FamilyName = 'CalRGB' then
    Exit(TPdfDeviceColorSpace.CreateFamily(csCalRGB, 3));

  if FamilyName = 'Lab' then
  begin
    if Arr.Count > 1 then
      Dict := PdfAsDictionary(PdfResolve(Resolver, Arr.Get(1)))
    else
      Dict := nil;
    Exit(TPdfLabColorSpace.Create(Dict, Resolver));
  end;

  if FamilyName = 'Pattern' then
  begin
    // [/Pattern base]: base space for uncoloured tiling patterns (never Pattern itself).
    Base := nil;
    if Arr.Count > 1 then
    begin
      Base := ParseLevel(Arr.Get(1), Resources, Resolver, Depth + 1);
      if (Base <> nil) and Base.IsPattern then
        FreeAndNil(Base);
    end;
    Exit(Pattern(Base));
  end;

  if FamilyName = 'ICCBased' then
  begin
    if Arr.Count < 2 then
      Exit;
    Dict := PdfAsDictionary(PdfResolve(Resolver, Arr.Get(1)));
    if Dict = nil then
      Exit;
    N := PdfAsInteger(PdfResolve(Resolver, Dict.Get('N')), 0);
    if N in [1, 3, 4] then
    begin
      if not GetNumbers(Dict, 'Range', Resolver, Range) or (Length(Range) < 2 * N) then
        Range := nil
      else
        SetLength(Range, 2 * N);
      Exit(TPdfICCBasedColorSpace.Create(N, Range));
    end;
    // Invalid /N: use the alternate space (which may itself be anything but Pattern).
    if Dict.Contains('Alternate') then
    begin
      Result := ParseLevel(Dict.GetRaw('Alternate'), Resources, Resolver, Depth + 1);
      if (Result <> nil) and Result.IsPattern then
        FreeAndNil(Result);
    end;
    Exit;
  end;

  if (FamilyName = 'Indexed') or (FamilyName = 'I') then
  begin
    if Arr.Count < 4 then
      Exit;
    O := PdfResolve(Resolver, Arr.Get(2));
    if not PdfIsNumber(O) then
      Exit;
    Hi := Trunc(EnsureRange(PdfAsNumber(O), 0, 255));
    O := PdfResolve(Resolver, Arr.Get(3));
    if O.Kind = okString then
      Lookup := (O as IPdfString).Bytes
    else if O.Kind = okStream then
      Lookup := (O as IPdfStream).GetDecodedData
    else
      Exit;
    Base := ParseLevel(Arr.Get(1), Resources, Resolver, Depth + 1);
    if Base = nil then
      Exit;
    if Base.Family in [csIndexed, csPattern] then
    begin
      Base.Free;
      Exit;
    end;
    Exit(TPdfIndexedColorSpace.Create(Base, Hi, Lookup));
  end;

  if (FamilyName = 'Separation') or (FamilyName = 'DeviceN') then
  begin
    if Arr.Count < 4 then
      Exit;
    O := PdfResolve(Resolver, Arr.Get(1));
    Colorant := '';
    if FamilyName = 'Separation' then
    begin
      N := 1;
      Colorant := PdfAsName(O);
      if (Colorant = '') and (O.Kind = okString) then
        Colorant := (O as IPdfString).AsText;
      AllNone := Colorant = 'None';
    end
    else
    begin
      Names := PdfAsArray(O);
      if (Names = nil) or (Names.Count = 0) or (Names.Count > MaxDeviceNComponents) then
        Exit;
      N := Names.Count;
      AllNone := True;
      for I := 0 to N - 1 do
        if PdfAsName(PdfResolve(Resolver, Names.Get(I))) <> 'None' then
          AllNone := False;
    end;
    Alt := nil;
    Tint := nil;
    try
      Alt := ParseLevel(Arr.Get(2), Resources, Resolver, Depth + 1);
      if (Alt <> nil) and Alt.IsPattern then
        FreeAndNil(Alt);
      Tint := TPdfFunction.Parse(Arr.Get(3), Resolver);
      if ((Alt = nil) or (Tint = nil)) and not AllNone and (Colorant <> 'All') then
      begin
        FreeAndNil(Alt);
        FreeAndNil(Tint);
        Exit;
      end;
      if FamilyName = 'Separation' then
        Result := TPdfTintColorSpace.Create(csSeparation, 1, Alt, Tint, Colorant = 'All', AllNone)
      else
        Result := TPdfTintColorSpace.Create(csDeviceN, N, Alt, Tint, False, AllNone);
    except
      Alt.Free;
      Tint.Free;
      raise;
    end;
  end;
end;

function TPdfColorSpace.ToRGB(const Comps: TArray<Double>): TPdfRGB;
begin
  Result := TPdfRGB.Create(0, 0, 0);
end;

function TPdfColorSpace.ToAlphaColor(const Comps: TArray<Double>; Alpha: Single): TAlphaColor;
begin
  Result := ToRGB(Comps).ToAlphaColor(Alpha);
end;

function TPdfColorSpace.InitialColor: TArray<Double>;
var
  I: Integer;
begin
  SetLength(Result, Max(FNComponents, 1));
  for I := 0 to High(Result) do
    Result[I] := 0;
  if FFamily = csDeviceCMYK then
    Result[3] := 1;
end;

function TPdfColorSpace.DefaultDecode(BitsPerComponent: Integer): TArray<Double>;
var
  I: Integer;
begin
  SetLength(Result, 2 * Max(FNComponents, 1));
  for I := 0 to High(Result) do
    Result[I] := I and 1;
end;

function TPdfColorSpace.IsNone: Boolean;
begin
  Result := False;
end;

function TPdfColorSpace.BaseColorSpace: TPdfColorSpace;
begin
  Result := nil;
end;

function TPdfColorSpace.HiVal: Integer;
begin
  Result := -1;
end;

function TPdfColorSpace.LookupRGB(Index: Integer): TPdfRGB;
begin
  Result := TPdfRGB.Create(0, 0, 0);
end;

function TPdfColorSpace.IsPattern: Boolean;
begin
  Result := FFamily = csPattern;
end;

{ TPdfDeviceColorSpace }

function TPdfDeviceColorSpace.ToRGB(const Comps: TArray<Double>): TPdfRGB;

  function C(I: Integer): Single;
  begin
    Result := Clamp01(Comp(Comps, I));
  end;

var
  K: Single;
  Kind: Integer;
begin
  // Kind: number of device components the values are interpreted as.
  case Family of
    csDeviceRGB, csCalRGB:
      Kind := 3;
    csDeviceCMYK:
      Kind := 4;
    csICCBased:
      Kind := NComponents;
  else
    Kind := 1;
  end;
  case Kind of
    3:
      Result := TPdfRGB.Create(C(0), C(1), C(2));
    4:
      begin
        // Simple naive conversion. pdf.js uses a polynomial fit of a typical (SWOP-like) profile,
        // which gives less saturated, more realistic colours; good enough for v1.
        K := C(3);
        Result := TPdfRGB.Create((1 - C(0)) * (1 - K), (1 - C(1)) * (1 - K), (1 - C(2)) * (1 - K));
      end;
  else
    Result := TPdfRGB.Create(C(0), C(0), C(0));
  end;
end;

{ TPdfICCBasedColorSpace }

constructor TPdfICCBasedColorSpace.Create(N: Integer; const ARange: TArray<Double>);
begin
  inherited CreateFamily(csICCBased, N);
  FRange := ARange;
end;

function TPdfICCBasedColorSpace.InitialColor: TArray<Double>;
var
  I: Integer;
begin
  // 0 for every component, unless 0 lies outside /Range (ISO 32000-1 §8.6.5.5).
  SetLength(Result, NComponents);
  for I := 0 to NComponents - 1 do
    if Length(FRange) >= 2 * NComponents then
      Result[I] := EnsureRange(0.0, Min(FRange[2 * I], FRange[2 * I + 1]), Max(FRange[2 * I], FRange[2 * I + 1]))
    else
      Result[I] := 0;
end;

function TPdfICCBasedColorSpace.DefaultDecode(BitsPerComponent: Integer): TArray<Double>;
begin
  if Length(FRange) >= 2 * NComponents then
    Result := Copy(FRange, 0, 2 * NComponents)
  else
    Result := inherited DefaultDecode(BitsPerComponent);
end;

{ TPdfLabColorSpace }

constructor TPdfLabColorSpace.Create(const Dict: IPdfDictionary; const Resolver: IPdfResolver);
var
  V: TArray<Double>;
begin
  inherited CreateFamily(csLab, 3);
  // /WhitePoint is required; tolerate its absence with D50.
  if GetNumbers(Dict, 'WhitePoint', Resolver, V) and (Length(V) >= 3) and (V[0] > 0) and (V[1] > 0) and (V[2] > 0) then
  begin
    FXW := V[0];
    FYW := V[1];
    FZW := V[2];
  end
  else
  begin
    FXW := 0.9642;
    FYW := 1;
    FZW := 0.8249;
  end;
  if GetNumbers(Dict, 'Range', Resolver, V) and (Length(V) >= 4) then
  begin
    FAMin := Min(V[0], V[1]);
    FAMax := Max(V[0], V[1]);
    FBMin := Min(V[2], V[3]);
    FBMax := Max(V[2], V[3]);
  end
  else
  begin
    FAMin := -100;
    FAMax := 100;
    FBMin := -100;
    FBMax := 100;
  end;
end;

function TPdfLabColorSpace.ToRGB(const Comps: TArray<Double>): TPdfRGB;

  // Inverse of the CIE f() function (ISO 32000-1 §8.6.5.4).
  function G(X: Double): Double;
  begin
    if X >= 6 / 29 then
      Result := X * X * X
    else
      Result := (108 / 841) * (X - 4 / 29);
  end;

  // Linear sRGB -> gamma-encoded sRGB (IEC 61966-2-1).
  function Gamma(V: Double): Single;
  begin
    V := Clamp01(V);
    if V <= 0.0031308 then
      Result := 12.92 * V
    else
      Result := 1.055 * Power(V, 1 / 2.4) - 0.055;
  end;

var
  L, A, B, M, X, Y, Z, R, Gr, Bl: Double;
begin
  L := EnsureRange(Comp(Comps, 0), 0, 100);
  A := EnsureRange(Comp(Comps, 1), FAMin, FAMax);
  B := EnsureRange(Comp(Comps, 2), FBMin, FBMax);
  M := (L + 16) / 116;
  X := FXW * G(M + A / 500);
  Y := FYW * G(M);
  Z := FZW * G(M - B / 200);
  // XYZ -> linear sRGB. A white point with Z < 1 is taken to be D50 and uses the Bradford-adapted
  // matrix, otherwise D65 (as pdf.js does, after http://www.color.org/srgb.pdf).
  if FZW < 1 then
  begin
    R := X * 3.1339 + Y * -1.6170 + Z * -0.4906;
    Gr := X * -0.9785 + Y * 1.9160 + Z * 0.0333;
    Bl := X * 0.0720 + Y * -0.2290 + Z * 1.4057;
  end
  else
  begin
    R := X * 3.2406 + Y * -1.5372 + Z * -0.4986;
    Gr := X * -0.9689 + Y * 1.8758 + Z * 0.0415;
    Bl := X * 0.0557 + Y * -0.2040 + Z * 1.0570;
  end;
  Result := TPdfRGB.Create(Gamma(R), Gamma(Gr), Gamma(Bl));
end;

function TPdfLabColorSpace.DefaultDecode(BitsPerComponent: Integer): TArray<Double>;
begin
  Result := TArray<Double>.Create(0, 100, FAMin, FAMax, FBMin, FBMax);
end;

{ TPdfIndexedColorSpace }

constructor TPdfIndexedColorSpace.Create(ABase: TPdfColorSpace; AHiVal: Integer; const Lookup: TBytes);
var
  NC, I, C, P: Integer;
  Decode: TArray<Double>;
  Comps: TArray<Double>;
  B: Byte;
begin
  inherited CreateFamily(csIndexed, 1);
  FBase := ABase;
  FHiVal := EnsureRange(AHiVal, 0, 255);
  // Precompute the palette through the base space. Lookup bytes map onto the base space's
  // default decode range (0..1, or e.g. 0..100 / amin..amax for Lab).
  NC := Max(FBase.NComponents, 1);
  Decode := FBase.DefaultDecode(8);
  SetLength(Comps, NC);
  SetLength(FPalette, FHiVal + 1);
  for I := 0 to FHiVal do
  begin
    for C := 0 to NC - 1 do
    begin
      P := I * NC + C;
      if P < Length(Lookup) then
        B := Lookup[P]
      else
        B := 0;
      if 2 * C + 1 < Length(Decode) then
        Comps[C] := Decode[2 * C] + B * (Decode[2 * C + 1] - Decode[2 * C]) / 255
      else
        Comps[C] := B / 255;
    end;
    FPalette[I] := FBase.ToRGB(Comps);
  end;
end;

destructor TPdfIndexedColorSpace.Destroy;
begin
  FBase.Free;
  inherited;
end;

function TPdfIndexedColorSpace.ToRGB(const Comps: TArray<Double>): TPdfRGB;
var
  V: Double;
begin
  V := EnsureRange(Comp(Comps, 0), 0, FHiVal);
  Result := FPalette[Round(V)];
end;

function TPdfIndexedColorSpace.InitialColor: TArray<Double>;
begin
  Result := [0];
end;

function TPdfIndexedColorSpace.DefaultDecode(BitsPerComponent: Integer): TArray<Double>;
begin
  BitsPerComponent := EnsureRange(BitsPerComponent, 1, 16);
  Result := TArray<Double>.Create(0, (1 shl BitsPerComponent) - 1);
end;

function TPdfIndexedColorSpace.BaseColorSpace: TPdfColorSpace;
begin
  Result := FBase;
end;

function TPdfIndexedColorSpace.HiVal: Integer;
begin
  Result := FHiVal;
end;

function TPdfIndexedColorSpace.LookupRGB(Index: Integer): TPdfRGB;
begin
  Result := FPalette[EnsureRange(Index, 0, FHiVal)];
end;

{ TPdfTintColorSpace }

constructor TPdfTintColorSpace.Create(AFamily: TPdfColorSpaceFamily; ANComponents: Integer;
  AAlternate: TPdfColorSpace; ATint: TPdfFunction; AIsAll, AIsNone: Boolean);
begin
  inherited CreateFamily(AFamily, ANComponents);
  FAlternate := AAlternate;
  FTint := ATint;
  FIsAll := AIsAll;
  FIsNone := AIsNone;
end;

destructor TPdfTintColorSpace.Destroy;
begin
  FTint.Free;
  FAlternate.Free;
  inherited;
end;

function TPdfTintColorSpace.Transform(const Comps: TArray<Double>): TPdfRGB;
begin
  if (FAlternate = nil) or (FTint = nil) then
    Result := TPdfRGB.Create(1, 1, 1)
  else
    Result := FAlternate.ToRGB(FTint.Evaluate(Comps));
end;

function TPdfTintColorSpace.ToRGB(const Comps: TArray<Double>): TPdfRGB;
var
  T: Double;
  K, I: Integer;
  C: TArray<Double>;
begin
  if NComponents = 1 then
  begin
    T := Clamp01(Comp(Comps, 0));
    if FIsAll then
      // /All: every colourant at this tint, i.e. registration black.
      Exit(TPdfRGB.Create(1 - T, 1 - T, 1 - T));
    K := Round(T * 255);
    if not FCached[K] then
    begin
      FCache[K] := Transform(TArray<Double>.Create(K / 255));
      FCached[K] := True;
    end;
    Result := FCache[K];
  end
  else
  begin
    SetLength(C, NComponents);
    for I := 0 to NComponents - 1 do
      C[I] := Clamp01(Comp(Comps, I));
    Result := Transform(C);
  end;
end;

function TPdfTintColorSpace.InitialColor: TArray<Double>;
var
  I: Integer;
begin
  SetLength(Result, NComponents);
  for I := 0 to NComponents - 1 do
    Result[I] := 1;
end;

function TPdfTintColorSpace.IsNone: Boolean;
begin
  Result := FIsNone;
end;

{ TPdfPatternColorSpace }

constructor TPdfPatternColorSpace.Create(ABase: TPdfColorSpace);
begin
  inherited CreateFamily(csPattern, 1);
  FBase := ABase;
end;

destructor TPdfPatternColorSpace.Destroy;
begin
  FBase.Free;
  inherited;
end;

function TPdfPatternColorSpace.BaseColorSpace: TPdfColorSpace;
begin
  Result := FBase;
end;

end.
