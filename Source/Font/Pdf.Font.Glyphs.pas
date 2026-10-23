{*******************************************************************************
  Pdf.Font.Glyphs
  Shared types for font programs: a glyph outline (in glyph units) and the
  abstract glyph source implemented by the TrueType, CFF and Type1 parsers.
  Font programs are parsed and rasterised by this library itself (outlines
  are drawn as Skia paths), so no platform font manager is involved and
  every platform renders text identically.
*******************************************************************************}
unit Pdf.Font.Glyphs;

interface

uses
  System.SysUtils, System.Math, Pdf.Core.Types;

type
  EPdfFontError = class(EPdfException);

  TPdfOutlineKind = (glMove, glLine, glQuad, glCubic, glClose);

  TPdfOutlineCmd = record
    Kind: TPdfOutlineKind;
    X1, Y1, X2, Y2, X3, Y3: Single;
  end;

  /// <summary>A glyph outline in glyph units (y up). Built with the helper methods; the renderer converts it to a Skia path.</summary>
  TPdfGlyphOutline = record
    Cmds: TArray<TPdfOutlineCmd>;
    Count: Integer;
    /// <summary>Advance width in glyph units (0 when the program does not know it).</summary>
    Advance: Single;
    procedure Clear;
    procedure MoveTo(X, Y: Single);
    procedure LineTo(X, Y: Single);
    procedure QuadTo(CX, CY, X, Y: Single);
    procedure CubicTo(C1X, C1Y, C2X, C2Y, X, Y: Single);
    procedure Close;
    /// <summary>Removes unused capacity; call when the outline is complete.</summary>
    procedure Trim;
    function IsEmpty: Boolean;
    /// <summary>Applies M to every point.</summary>
    procedure Transform(const M: TPdfMatrix);
    /// <summary>Appends Other translated by (DX, DY) (composite glyphs, seac).</summary>
    procedure Append(const Other: TPdfGlyphOutline; DX, DY: Single);
    /// <summary>Appends Other transformed by M (composite glyphs with scale).</summary>
    procedure AppendTransformed(const Other: TPdfGlyphOutline; const M: TPdfMatrix);
  end;

  /// <summary>A parsed font program that produces outlines by glyph index. All lookups return -1 when unavailable.</summary>
  TPdfGlyphSource = class abstract
  public
    /// <summary>Glyph space to text space (1 em = 1.0): TrueType 1/unitsPerEm, CFF/Type1 /FontMatrix.</summary>
    function FontMatrix: TPdfMatrix; virtual; abstract;
    function GlyphCount: Integer; virtual; abstract;
    /// <summary>Outline of glyph GID in glyph units. False when GID is out of range or the glyph data is unusable;
    /// an empty glyph (space) returns True with no commands.</summary>
    function GetOutline(GID: Integer; out Outline: TPdfGlyphOutline): Boolean; virtual; abstract;
    /// <summary>Advance width of GID in glyph units, or -1 when the program carries no metrics.</summary>
    function GetAdvance(GID: Integer): Single; virtual;
    /// <summary>Glyph index for a PostScript glyph name (CFF charset, Type1 CharStrings, TrueType post table); -1 when unknown.</summary>
    function GlyphByName(const Name: string): Integer; virtual;
    /// <summary>Glyph index for a Unicode code point through the font's own cmap ((3,1), (0,x), (3,10)); -1 when unavailable.</summary>
    function GlyphByUnicode(CodePoint: Integer): Integer; virtual;
    /// <summary>Glyph index for a raw single-byte code: Type1/CFF built-in encoding, or a TrueType (3,0) symbol cmap
    /// (tries Code, $F000+Code, $F100+Code, $F200+Code) and then the (1,0) Macintosh cmap; -1 when unavailable.</summary>
    function GlyphByCode(Code: Integer): Integer; virtual;
    /// <summary>CID-keyed CFF: glyph index for a CID through the charset. Other programs return CID when it is in range, else -1.</summary>
    function GlyphByCID(CID: Integer): Integer; virtual;
    function IsCIDKeyed: Boolean; virtual;
    /// <summary>True when GlyphByName can succeed (the program has glyph names).</summary>
    function HasGlyphNames: Boolean; virtual;
    /// <summary>True when GlyphByUnicode can succeed.</summary>
    function HasUnicodeMap: Boolean; virtual;
    /// <summary>True when GlyphByCode can succeed.</summary>
    function HasCodeMap: Boolean; virtual;
    /// <summary>Number of glyphs that have outline data; -1 when unknown. Used to detect broken subsets.</summary>
    function OutlineCount: Integer; virtual;
  end;

implementation

{ TPdfGlyphOutline }

procedure TPdfGlyphOutline.Clear;
begin
  Cmds := nil;
  Count := 0;
  Advance := 0;
end;

procedure TPdfGlyphOutline.MoveTo(X, Y: Single);
begin
  if Count >= Length(Cmds) then
    SetLength(Cmds, Max(16, Length(Cmds) * 2));
  Cmds[Count].Kind := glMove;
  Cmds[Count].X1 := X;
  Cmds[Count].Y1 := Y;
  Inc(Count);
end;

procedure TPdfGlyphOutline.LineTo(X, Y: Single);
begin
  if Count >= Length(Cmds) then
    SetLength(Cmds, Max(16, Length(Cmds) * 2));
  Cmds[Count].Kind := glLine;
  Cmds[Count].X1 := X;
  Cmds[Count].Y1 := Y;
  Inc(Count);
end;

procedure TPdfGlyphOutline.QuadTo(CX, CY, X, Y: Single);
begin
  if Count >= Length(Cmds) then
    SetLength(Cmds, Max(16, Length(Cmds) * 2));
  Cmds[Count].Kind := glQuad;
  Cmds[Count].X1 := CX;
  Cmds[Count].Y1 := CY;
  Cmds[Count].X2 := X;
  Cmds[Count].Y2 := Y;
  Inc(Count);
end;

procedure TPdfGlyphOutline.CubicTo(C1X, C1Y, C2X, C2Y, X, Y: Single);
begin
  if Count >= Length(Cmds) then
    SetLength(Cmds, Max(16, Length(Cmds) * 2));
  Cmds[Count].Kind := glCubic;
  Cmds[Count].X1 := C1X;
  Cmds[Count].Y1 := C1Y;
  Cmds[Count].X2 := C2X;
  Cmds[Count].Y2 := C2Y;
  Cmds[Count].X3 := X;
  Cmds[Count].Y3 := Y;
  Inc(Count);
end;

procedure TPdfGlyphOutline.Close;
begin
  if (Count > 0) and (Cmds[Count - 1].Kind = glClose) then
    Exit;
  if Count >= Length(Cmds) then
    SetLength(Cmds, Max(16, Length(Cmds) * 2));
  Cmds[Count].Kind := glClose;
  Inc(Count);
end;

procedure TPdfGlyphOutline.Trim;
begin
  SetLength(Cmds, Count);
end;

function TPdfGlyphOutline.IsEmpty: Boolean;
begin
  Result := Count = 0;
end;

procedure TPdfGlyphOutline.Transform(const M: TPdfMatrix);
var
  I: Integer;
  X, Y: Double;
begin
  for I := 0 to Count - 1 do
  begin
    X := Cmds[I].X1;
    Y := Cmds[I].Y1;
    M.Apply(X, Y);
    Cmds[I].X1 := X;
    Cmds[I].Y1 := Y;
    if Cmds[I].Kind in [glQuad, glCubic] then
    begin
      X := Cmds[I].X2;
      Y := Cmds[I].Y2;
      M.Apply(X, Y);
      Cmds[I].X2 := X;
      Cmds[I].Y2 := Y;
    end;
    if Cmds[I].Kind = glCubic then
    begin
      X := Cmds[I].X3;
      Y := Cmds[I].Y3;
      M.Apply(X, Y);
      Cmds[I].X3 := X;
      Cmds[I].Y3 := Y;
    end;
  end;
end;

procedure TPdfGlyphOutline.Append(const Other: TPdfGlyphOutline; DX, DY: Single);
begin
  AppendTransformed(Other, TPdfMatrix.Translation(DX, DY));
end;

procedure TPdfGlyphOutline.AppendTransformed(const Other: TPdfGlyphOutline; const M: TPdfMatrix);
var
  I: Integer;
  C: TPdfOutlineCmd;
  X, Y: Double;
begin
  for I := 0 to Other.Count - 1 do
  begin
    C := Other.Cmds[I];
    X := C.X1;
    Y := C.Y1;
    M.Apply(X, Y);
    C.X1 := X;
    C.Y1 := Y;
    if C.Kind in [glQuad, glCubic] then
    begin
      X := C.X2;
      Y := C.Y2;
      M.Apply(X, Y);
      C.X2 := X;
      C.Y2 := Y;
    end;
    if C.Kind = glCubic then
    begin
      X := C.X3;
      Y := C.Y3;
      M.Apply(X, Y);
      C.X3 := X;
      C.Y3 := Y;
    end;
    if Count >= Length(Cmds) then
      SetLength(Cmds, Max(16, Length(Cmds) * 2));
    Cmds[Count] := C;
    Inc(Count);
  end;
end;

{ TPdfGlyphSource }

function TPdfGlyphSource.GetAdvance(GID: Integer): Single;
begin
  Result := -1;
end;

function TPdfGlyphSource.GlyphByName(const Name: string): Integer;
begin
  Result := -1;
end;

function TPdfGlyphSource.GlyphByUnicode(CodePoint: Integer): Integer;
begin
  Result := -1;
end;

function TPdfGlyphSource.GlyphByCode(Code: Integer): Integer;
begin
  Result := -1;
end;

function TPdfGlyphSource.GlyphByCID(CID: Integer): Integer;
begin
  if (CID >= 0) and (CID < GlyphCount) then
    Result := CID
  else
    Result := -1;
end;

function TPdfGlyphSource.IsCIDKeyed: Boolean;
begin
  Result := False;
end;

function TPdfGlyphSource.HasGlyphNames: Boolean;
begin
  Result := False;
end;

function TPdfGlyphSource.HasUnicodeMap: Boolean;
begin
  Result := False;
end;

function TPdfGlyphSource.HasCodeMap: Boolean;
begin
  Result := False;
end;

function TPdfGlyphSource.OutlineCount: Integer;
begin
  Result := -1;
end;

end.
