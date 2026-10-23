{*******************************************************************************
  Pdf.Codec.JPX
  JPEG 2000 decoder for the JPXDecode filter: JP2 files (boxes) and raw J2K
  codestreams (ITU-T T.800 / ISO/IEC 15444-1 part 1).

  Ported from pdf.js src/core/jpx.js (the former pure-JS JpxImage; Copyright
  2012 Mozilla Foundation, Apache License 2.0, see NOTICE), with these additions:
  COC markers, vertically causal context formation, a standard tag tree
  decoder, subsampled components, image/tile offsets, palettes (pclr/cmap),
  channel definitions (cdef), colour space detection (colr), sYCC to RGB,
  precisions other than 8 bits, reduced-resolution decoding, and bounds checks
  everywhere (corrupt data gives a partial image or EPdfFilterError).

  Not supported (EPdfFilterError, like pdf.js): selective arithmetic coding
  bypass, termination on each coding pass, packed packet headers (PPM/PPT) and
  progression order changes (POC). Region of interest (RGN) is ignored.
*******************************************************************************}
unit Pdf.Codec.JPX;

interface

uses
  System.SysUtils, Pdf.Core.Types;

type
  TPdfJPXColorSpace = (jcUnknown, jcGray, jcRGB, jcCMYK, jcYCC);

  /// <summary>A decoded JPEG 2000 image.</summary>
  TPdfJPXImage = record
    Width, Height: Integer;
    /// <summary>Number of colour components in Data (alpha channel excluded; see HasAlpha).</summary>
    Components: Integer;
    /// <summary>8-bit interleaved samples, row-major, Components (+1 when HasAlpha) bytes per pixel.</summary>
    Data: TBytes;
    /// <summary>From the JP2 colr box (or inferred from the component count for raw J2K codestreams).
    /// YCC sources (colr sYCC / YCbCr) are converted, so they report jcRGB;
    /// jcUnknown for palette indices (Options.IsIndexed) and unusual component counts.</summary>
    ColorSpace: TPdfJPXColorSpace;
    /// <summary>True when a 4th (or 2nd for gray) channel is an alpha channel (cdef box or SMaskInData);
    /// it is appended per pixel.</summary>
    HasAlpha: Boolean;
    /// <summary>Original precision of the first component (samples are scaled to 8 bits).</summary>
    BitDepth: Integer;
    /// <summary>Resolution levels actually skipped (requested ReduceLevels, clamped, or raised to respect
    /// Options.MaxSamples).</summary>
    ReducedLevels: Integer;
  end;

  /// <summary>Decoding options for PdfJPXDecode.</summary>
  TPdfJPXOptions = record
    /// <summary>Skip that many resolution levels (each halves width and height; 0 = full size).</summary>
    ReduceLevels: Integer;
    /// <summary>/SMaskInData of the image dictionary is non-zero: without a cdef alpha channel, the last
    /// component is taken as alpha (when ColorComponents + 1 components are present, or 2, 4 or 5 components
    /// when ColorComponents is 0).</summary>
    SMaskInData: Boolean;
    /// <summary>Number of colour components of the PDF /ColorSpace (0 = unknown); only used with SMaskInData.</summary>
    ColorComponents: Integer;
    /// <summary>The PDF colour space is /Indexed: return the raw palette indices of the first component
    /// (no pclr expansion, no precision scaling, values clamped to 0..255).</summary>
    IsIndexed: Boolean;
    /// <summary>Upper bound for Width * Height * channels of the result; more resolution levels are skipped
    /// until the image fits (0 = default of 2^27). EPdfFilterError when even the lowest resolution is too big.</summary>
    MaxSamples: Int64;
    class function Default: TPdfJPXOptions; static;
  end;

  /// <summary>Header information (no decoding of the image data).</summary>
  TPdfJPXInfo = record
    Width, Height: Integer;
    /// <summary>Number of codestream components (before palette expansion).</summary>
    Components: Integer;
    BitDepth: Integer;
    /// <summary>Decomposition levels of the main COD marker (the maximum useful ReduceLevels).</summary>
    DecompositionLevels: Integer;
    ColorSpace: TPdfJPXColorSpace;
    HasPalette: Boolean;
    HasAlpha: Boolean;
  end;

/// <summary>Decodes a JP2 file (with boxes) or a raw J2K codestream. ReduceLevels > 0 skips that many resolution
/// levels (for thumbnails; 0 = full size). Raises EPdfFilterError for unsupported or unusable data; damaged
/// tile data gives a partially decoded image.</summary>
function PdfJPXDecode(const Data: TBytes; ReduceLevels: Integer = 0): TPdfJPXImage; overload;
/// <summary>PdfJPXDecode with the PDF-specific options (SMaskInData, Indexed colour space, size limit).</summary>
function PdfJPXDecode(const Data: TBytes; const Options: TPdfJPXOptions): TPdfJPXImage; overload;
/// <summary>Reads the image size, component count and colour space from the headers; False when Data is not a
/// readable JPEG 2000 stream.</summary>
function PdfJPXReadInfo(const Data: TBytes; out Info: TPdfJPXInfo): Boolean;
/// <summary>True when Data starts with a JP2 signature box or a J2K codestream (SOC + SIZ).</summary>
function PdfIsJPX(const Data: TBytes): Boolean;

implementation

{$POINTERMATH ON}

uses
  System.Math, System.Generics.Collections, Pdf.Codec.JPX.Primitives;

const
  DefaultMaxSamples = Int64(1) shl 27;
  MaxCodeblocks = 1 shl 22;
  MaxPrecincts = 1 shl 22;

  // Code-block style bits (Table A.19)
  StyleBypass = $01;
  StyleReset = $02;
  StyleTermAll = $04;
  StyleCausal = $08;
  StyleSegmentation = $20;

  UniformContext = 17;
  RunLengthContext = 18;

type
  EJpxUnsupported = class(EPdfFilterError);

  TJpxSubbandKind = (sbLL, sbHL, sbLH, sbHH);

  TJpxCoding = record
    Defined: Boolean;
    CustomPrecincts, SopMarkers, EphMarkers: Boolean;
    Progression, Layers, MCT: Integer;
    Levels, Xcb, Ycb, Style: Integer;
    Reversible: Boolean;
    /// PPx in the low, PPy in the high nibble, per resolution level
    Precincts: TArray<Byte>;
  end;

  TJpxQuant = record
    Defined: Boolean;
    ScalarExpounded: Boolean;
    GuardBits: Integer;
    Epsilon, Mu: TArray<Integer>;
  end;

  TJpxComponentInfo = record
    Precision: Integer;
    Signed: Boolean;
    XRsiz, YRsiz: Integer;
    X0, X1, Y0, Y1: Integer;
  end;

  TJpxChunk = record
    Start, Len: Integer;
  end;

  TJpxPrecinct = class
  public
    CbxMin, CbyMin, CbxMax, CbyMax: Integer;
    Inclusion, ZeroBitPlanes: TJpxTagTree;
    destructor Destroy; override;
  end;

  TJpxCodeblock = class
  public
    Cbx, Cby: Integer;
    X0, Y0, X1, Y1: Integer;
    PrecinctNumber: Integer;
    Precinct: TJpxPrecinct;
    Lblock: Integer;
    Included: Boolean;
    ZeroBitPlanes: Integer;
    Passes: Integer;
    Chunks: TArray<TJpxChunk>;
    ChunkCount: Integer;
    procedure AddChunk(Start, Len: Integer);
  end;

  TJpxResolution = class;

  TJpxSubband = class
  public
    Kind: TJpxSubbandKind;
    X0, Y0, X1, Y1: Integer;
    Resolution: TJpxResolution;
    Codeblocks: TObjectList<TJpxCodeblock>;
    Precincts: TObjectList<TJpxPrecinct>;
    constructor Create;
    destructor Destroy; override;
  end;

  TJpxResolution = class
  public
    X0, Y0, X1, Y1: Integer;
    Level: Integer;
    PPx, PPy: Integer;
    NumWide, NumHigh, NumPrecincts: Integer;
    PrecinctWidthInSubband, PrecinctHeightInSubband: Integer;
    Subbands: TObjectList<TJpxSubband>;
    /// Code-blocks of each precinct in packet order (sub-band order, then raster order)
    PacketBlocks: TArray<TArray<TJpxCodeblock>>;
    constructor Create;
    destructor Destroy; override;
  end;

  TJpxTileComponent = class
  public
    X0, Y0, X1, Y1: Integer;
    Coding: TJpxCoding;
    Quant: TJpxQuant;
    Resolutions: TObjectList<TJpxResolution>;
    constructor Create;
    destructor Destroy; override;
  end;

  TJpxTile = class;

  TJpxPacket = record
    Resolution: TJpxResolution;
    Precinct: Integer;
    Layer: Integer;
  end;

  TJpxPrecinctSize = record
    Width, Height: Int64;
  end;

  TJpxComponentPrecinctSizes = record
    Resolutions: TArray<TJpxPrecinctSize>;
    MinWidth, MinHeight: Int64;
    MaxNumWide, MaxNumHigh: Integer;
  end;

  /// Packet sequence of a tile (B.12.1), resumable like the pdf.js iterators
  TJpxPacketIterator = class
  private
    FTile: TJpxTile;
    FOrder, FLayers, FComponents, FMaxLevels: Integer;
    L, R, C, P, PX, PY: Integer;
    FMaxPrecinctsInLevel: TArray<Integer>;
    FSizes: TArray<TJpxComponentPrecinctSizes>;
    FMinWidth, FMinHeight: Int64;
    FMaxNumWide, FMaxNumHigh: Integer;
    procedure ComputePrecinctSizes;
    function PrecinctIndex(APX, APY: Integer; const Size: TJpxPrecinctSize; MinW, MinH: Int64;
      Res: TJpxResolution): Integer;
    function Levels(Comp: Integer): Integer;
    function MakePacket(Res: TJpxResolution; Precinct, Layer: Integer; out Packet: TJpxPacket): Boolean;
  public
    constructor Create(Tile: TJpxTile);
    function Next(out Packet: TJpxPacket): Boolean;
  end;

  TJpxTile = class
  public
    Index: Integer;
    X0, Y0, X1, Y1: Integer;
    Components: TObjectList<TJpxTileComponent>;
    Initialized, Broken: Boolean;
    Coding: TJpxCoding;
    Iterator: TJpxPacketIterator;
    // tile-part header (part 0) settings, applied at the first SOD
    HdrValid: Boolean;
    HdrCOD: TJpxCoding;
    HdrCOC: TArray<TJpxCoding>;
    HdrQCD: TJpxQuant;
    HdrQCC: TArray<TJpxQuant>;
    constructor Create;
    destructor Destroy; override;
  end;

  TJpxPaletteMap = record
    Component: Integer;
    PaletteColumn: Integer;
  end;

  TJpxChannelDef = record
    Channel, Typ, Assoc: Integer;
  end;

  /// Information from the JP2 boxes
  TJpxBoxes = record
    CodestreamStart, CodestreamEnd: Integer;
    HasColr: Boolean;
    ColrMethod: Integer;
    EnumCS: Cardinal;
    IccSpace: Cardinal;
    PaletteEntries, PaletteColumns: Integer;
    PaletteDepth: TArray<Integer>;
    Palette: TArray<Integer>;
    PaletteMap: TArray<TJpxPaletteMap>;
    ChannelDefs: TArray<TJpxChannelDef>;
  end;

  /// Coefficient bit modeling (Annex D), one instance reused for all code-blocks of a tile-component
  TJpxBitModel = class
  private
    FWidth, FHeight: Integer;
    FLabels: PByte;
    FCausal: Boolean;
    FNeighbors, FSigns, FFlags, FBitsDecoded: TBytes;
    FMagnitude: TArray<Cardinal>;
    FContexts: array[0..18] of Byte;
    procedure SetNeighborsSignificance(Row, Column, Index: Integer);
    function DecodeSignBit(Row, Column, Index: Integer): Integer;
  public
    Decoder: TJpxMQDecoder;
    procedure Init(Width, Height: Integer; Kind: TJpxSubbandKind; ZeroBitPlanes: Integer; Causal: Boolean);
    procedure ResetContexts;
    procedure SignificancePropagationPass;
    procedure MagnitudeRefinementPass;
    procedure CleanupPass;
    procedure CheckSegmentationSymbol;
  end;

  TJpxDecoder = class
  private
    FData: TBytes;
    FBoxes: TJpxBoxes;
    FHaveSIZ: Boolean;
    FXsiz, FYsiz, FXOsiz, FYOsiz, FXTsiz, FYTsiz, FXTOsiz, FYTOsiz: Integer;
    FComps: TArray<TJpxComponentInfo>;
    FMainHeader: Boolean;
    FCOD: TJpxCoding;
    FCOC: TArray<TJpxCoding>;
    FQCD: TJpxQuant;
    FQCC: TArray<TJpxQuant>;
    FTiles: TObjectList<TJpxTile>;
    FCurTile: TJpxTile;
    FCurPartIndex: Integer;
    FCurTileDataEnd: Integer;
    FCodeblockCount: Int64;
    function B(Pos: Integer): Integer; inline;
    function U16(Pos: Integer): Integer; inline;
    function U32(Pos: Integer): Int64; inline;
    procedure ParseBoxes(Start, Finish: Integer);
    procedure ParseCodestream(Start, Finish: Integer; HeaderOnly: Boolean);
    procedure ReadSIZ(Pos, Len: Integer);
    function ReadQuant(Pos, Finish: Integer; Sqcd: Integer): TJpxQuant;
    procedure ReadCOD(Pos, Len: Integer);
    procedure ReadCOC(Pos, Len: Integer);
    procedure ReadQCD(Pos, Len: Integer);
    procedure ReadQCC(Pos, Len: Integer);
    procedure ReadSOT(Pos, Len, Finish: Integer);
    procedure InitializeTile(Tile: TJpxTile);
    procedure BuildPackets(Tile: TJpxTile);
    procedure BuildCodeblocks(Subband: TJpxSubband; XcbShift, YcbShift: Integer);
    procedure ParseTilePackets(Tile: TJpxTile; Start, Len: Integer);
    function TransformTileComponent(Tile: TJpxTile; C, Reduce: Integer; Model: TJpxBitModel;
      out Left, Top: Integer): TJpxBand;
    procedure CopyCoefficients(var Coefficients: TArray<Single>; LevelWidth, LevelHeight: Integer;
      Subband: TJpxSubband; Delta: Double; Mb: Integer; Reversible: Boolean; const Coding: TJpxCoding;
      Model: TJpxBitModel);
    function ColorSpaceFromBoxes(out CS: TPdfJPXColorSpace; out IsYCC: Boolean): Boolean;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    procedure Parse(HeaderOnly: Boolean);
    function Decode(const Options: TPdfJPXOptions): TPdfJPXImage;
    procedure GetInfo(out Info: TPdfJPXInfo);
  end;

function CeilDiv(A, B: Int64): Int64; inline;
begin
  if A >= 0 then
    Result := (A + B - 1) div B
  else
    Result := -((-A) div B);
end;

function FloorDiv(A, B: Int64): Int64; inline;
begin
  if A >= 0 then
    Result := A div B
  else
    Result := -((-A + B - 1) div B);
end;

function Sar(X, N: Integer): Integer; inline;
begin
  if X >= 0 then
    Result := X shr N
  else
    Result := not ((not X) shr N);
end;

procedure Fail(const Msg: string);
begin
  raise EPdfFilterError.Create('JPX: ' + Msg);
end;

procedure Unsupported(const Msg: string);
begin
  raise EJpxUnsupported.Create('JPX: ' + Msg);
end;

{ TJpxPrecinct }

destructor TJpxPrecinct.Destroy;
begin
  Inclusion.Free;
  ZeroBitPlanes.Free;
  inherited;
end;

{ TJpxCodeblock }

procedure TJpxCodeblock.AddChunk(Start, Len: Integer);
begin
  if ChunkCount = Length(Chunks) then
    SetLength(Chunks, ChunkCount * 2 + 2);
  Chunks[ChunkCount].Start := Start;
  Chunks[ChunkCount].Len := Len;
  Inc(ChunkCount);
end;

{ TJpxSubband }

constructor TJpxSubband.Create;
begin
  inherited;
  Codeblocks := TObjectList<TJpxCodeblock>.Create(True);
  Precincts := TObjectList<TJpxPrecinct>.Create(True);
end;

destructor TJpxSubband.Destroy;
begin
  Codeblocks.Free;
  Precincts.Free;
  inherited;
end;

{ TJpxResolution }

constructor TJpxResolution.Create;
begin
  inherited;
  Subbands := TObjectList<TJpxSubband>.Create(True);
end;

destructor TJpxResolution.Destroy;
begin
  Subbands.Free;
  inherited;
end;

{ TJpxTileComponent }

constructor TJpxTileComponent.Create;
begin
  inherited;
  Resolutions := TObjectList<TJpxResolution>.Create(True);
end;

destructor TJpxTileComponent.Destroy;
begin
  Resolutions.Free;
  inherited;
end;

{ TJpxTile }

constructor TJpxTile.Create;
begin
  inherited;
  Components := TObjectList<TJpxTileComponent>.Create(True);
end;

destructor TJpxTile.Destroy;
begin
  Iterator.Free;
  Components.Free;
  inherited;
end;

{ TJpxPacketIterator }

constructor TJpxPacketIterator.Create(Tile: TJpxTile);
var
  Comp, Lev, Res: Integer;
  MaxP: Integer;
begin
  inherited Create;
  FTile := Tile;
  FOrder := Tile.Coding.Progression;
  FLayers := Tile.Coding.Layers;
  FComponents := Tile.Components.Count;
  FMaxLevels := 0;
  for Comp := 0 to FComponents - 1 do
    FMaxLevels := Max(FMaxLevels, Levels(Comp));
  case FOrder of
    0, 1, 2:
      begin
        SetLength(FMaxPrecinctsInLevel, FMaxLevels + 1);
        for Lev := 0 to FMaxLevels do
        begin
          MaxP := 0;
          for Comp := 0 to FComponents - 1 do
          begin
            Res := Lev;
            if Res < Tile.Components[Comp].Resolutions.Count then
              MaxP := Max(MaxP, Tile.Components[Comp].Resolutions[Res].NumPrecincts);
          end;
          FMaxPrecinctsInLevel[Lev] := MaxP;
        end;
      end;
    3, 4:
      ComputePrecinctSizes;
  else
    Unsupported(Format('unsupported progression order %d', [FOrder]));
  end;
end;

function TJpxPacketIterator.Levels(Comp: Integer): Integer;
begin
  Result := FTile.Components[Comp].Coding.Levels;
end;

procedure TJpxPacketIterator.ComputePrecinctSizes;
var
  Comp, Res: Integer;
  Scale: Int64;
  Resolution: TJpxResolution;
  S: TJpxComponentPrecinctSizes;
begin
  // getPrecinctSizesInImageScale
  FMinWidth := High(Int64);
  FMinHeight := High(Int64);
  FMaxNumWide := 0;
  FMaxNumHigh := 0;
  SetLength(FSizes, FComponents);
  for Comp := 0 to FComponents - 1 do
  begin
    SetLength(S.Resolutions, Levels(Comp) + 1);
    S.MinWidth := High(Int64);
    S.MinHeight := High(Int64);
    S.MaxNumWide := 0;
    S.MaxNumHigh := 0;
    Scale := 1;
    for Res := Levels(Comp) downto 0 do
    begin
      Resolution := FTile.Components[Comp].Resolutions[Res];
      S.Resolutions[Res].Width := Scale shl Resolution.PPx;
      S.Resolutions[Res].Height := Scale shl Resolution.PPy;
      S.MinWidth := Min(S.MinWidth, S.Resolutions[Res].Width);
      S.MinHeight := Min(S.MinHeight, S.Resolutions[Res].Height);
      S.MaxNumWide := Max(S.MaxNumWide, Resolution.NumWide);
      S.MaxNumHigh := Max(S.MaxNumHigh, Resolution.NumHigh);
      Scale := Scale shl 1;
    end;
    FMinWidth := Min(FMinWidth, S.MinWidth);
    FMinHeight := Min(FMinHeight, S.MinHeight);
    FMaxNumWide := Max(FMaxNumWide, S.MaxNumWide);
    FMaxNumHigh := Max(FMaxNumHigh, S.MaxNumHigh);
    FSizes[Comp] := S;
    S.Resolutions := nil;
  end;
end;

function TJpxPacketIterator.PrecinctIndex(APX, APY: Integer; const Size: TJpxPrecinctSize; MinW, MinH: Int64;
  Res: TJpxResolution): Integer;
var
  PosX, PosY, IX, IY: Int64;
begin
  // getPrecinctIndexIfExist (with the width/height of the row index in the right place)
  Result := -1;
  if (Size.Width <= 0) or (Size.Height <= 0) then
    Exit;
  PosX := Int64(APX) * MinW;
  PosY := Int64(APY) * MinH;
  if (PosX mod Size.Width <> 0) or (PosY mod Size.Height <> 0) then
    Exit;
  IX := PosX div Size.Width;
  IY := PosY div Size.Height;
  if (IX >= Res.NumWide) or (IY >= Res.NumHigh) then
    Exit;
  Result := Integer(IY * Res.NumWide + IX);
end;

function TJpxPacketIterator.MakePacket(Res: TJpxResolution; Precinct, Layer: Integer; out Packet: TJpxPacket): Boolean;
begin
  Packet.Resolution := Res;
  Packet.Precinct := Precinct;
  Packet.Layer := Layer;
  Result := True;
end;

function TJpxPacketIterator.Next(out Packet: TJpxPacket): Boolean;
var
  Res: TJpxResolution;
  K: Integer;
begin
  case FOrder of
    0:
      begin
        // B.12.1.1 Layer-resolution-component-position
        while L < FLayers do
        begin
          while R <= FMaxLevels do
          begin
            while C < FComponents do
            begin
              if R <= Levels(C) then
              begin
                Res := FTile.Components[C].Resolutions[R];
                if P < Res.NumPrecincts then
                begin
                  Inc(P);
                  Exit(MakePacket(Res, P - 1, L, Packet));
                end;
                P := 0;
              end;
              Inc(C);
            end;
            C := 0;
            Inc(R);
          end;
          R := 0;
          Inc(L);
        end;
      end;
    1:
      begin
        // B.12.1.2 Resolution-layer-component-position
        while R <= FMaxLevels do
        begin
          while L < FLayers do
          begin
            while C < FComponents do
            begin
              if R <= Levels(C) then
              begin
                Res := FTile.Components[C].Resolutions[R];
                if P < Res.NumPrecincts then
                begin
                  Inc(P);
                  Exit(MakePacket(Res, P - 1, L, Packet));
                end;
                P := 0;
              end;
              Inc(C);
            end;
            C := 0;
            Inc(L);
          end;
          L := 0;
          Inc(R);
        end;
      end;
    2:
      begin
        // B.12.1.3 Resolution-position-component-layer
        while R <= FMaxLevels do
        begin
          while P < FMaxPrecinctsInLevel[R] do
          begin
            while C < FComponents do
            begin
              if R <= Levels(C) then
              begin
                Res := FTile.Components[C].Resolutions[R];
                if P < Res.NumPrecincts then
                begin
                  if L < FLayers then
                  begin
                    Inc(L);
                    Exit(MakePacket(Res, P, L - 1, Packet));
                  end;
                  L := 0;
                end;
              end;
              Inc(C);
            end;
            C := 0;
            Inc(P);
          end;
          P := 0;
          Inc(R);
        end;
      end;
    3:
      begin
        // B.12.1.4 Position-component-resolution-layer
        while PY < FMaxNumHigh do
        begin
          while PX < FMaxNumWide do
          begin
            while C < FComponents do
            begin
              while R <= Levels(C) do
              begin
                Res := FTile.Components[C].Resolutions[R];
                K := PrecinctIndex(PX, PY, FSizes[C].Resolutions[R], FMinWidth, FMinHeight, Res);
                if K >= 0 then
                begin
                  if L < FLayers then
                  begin
                    Inc(L);
                    Exit(MakePacket(Res, K, L - 1, Packet));
                  end;
                  L := 0;
                end;
                Inc(R);
              end;
              R := 0;
              Inc(C);
            end;
            C := 0;
            Inc(PX);
          end;
          PX := 0;
          Inc(PY);
        end;
      end;
    4:
      begin
        // B.12.1.5 Component-position-resolution-layer
        while C < FComponents do
        begin
          while PY < FSizes[C].MaxNumHigh do
          begin
            while PX < FSizes[C].MaxNumWide do
            begin
              while R <= Levels(C) do
              begin
                Res := FTile.Components[C].Resolutions[R];
                K := PrecinctIndex(PX, PY, FSizes[C].Resolutions[R], FSizes[C].MinWidth, FSizes[C].MinHeight, Res);
                if K >= 0 then
                begin
                  if L < FLayers then
                  begin
                    Inc(L);
                    Exit(MakePacket(Res, K, L - 1, Packet));
                  end;
                  L := 0;
                end;
                Inc(R);
              end;
              R := 0;
              Inc(PX);
            end;
            PX := 0;
            Inc(PY);
          end;
          PY := 0;
          Inc(C);
        end;
      end;
  end;
  Result := False;
end;

{ TJpxBitModel }

const
  // Table D.1: index = 0dddvvhh (sum of diagonal, vertical and horizontal neighbours)
  LLAndLHContextsLabel: array[0..74] of Byte = (
    0, 5, 8, 0, 3, 7, 8, 0, 4, 7, 8, 0, 0, 0, 0, 0, 1, 6, 8, 0, 3, 7, 8, 0, 4,
    7, 8, 0, 0, 0, 0, 0, 2, 6, 8, 0, 3, 7, 8, 0, 4, 7, 8, 0, 0, 0, 0, 0, 2, 6,
    8, 0, 3, 7, 8, 0, 4, 7, 8, 0, 0, 0, 0, 0, 2, 6, 8, 0, 3, 7, 8, 0, 4, 7, 8);
  HLContextLabel: array[0..74] of Byte = (
    0, 3, 4, 0, 5, 7, 7, 0, 8, 8, 8, 0, 0, 0, 0, 0, 1, 3, 4, 0, 6, 7, 7, 0, 8,
    8, 8, 0, 0, 0, 0, 0, 2, 3, 4, 0, 6, 7, 7, 0, 8, 8, 8, 0, 0, 0, 0, 0, 2, 3,
    4, 0, 6, 7, 7, 0, 8, 8, 8, 0, 0, 0, 0, 0, 2, 3, 4, 0, 6, 7, 7, 0, 8, 8, 8);
  HHContextLabel: array[0..74] of Byte = (
    0, 1, 2, 0, 1, 2, 2, 0, 2, 2, 2, 0, 0, 0, 0, 0, 3, 4, 5, 0, 4, 5, 5, 0, 5,
    5, 5, 0, 0, 0, 0, 0, 6, 7, 7, 0, 7, 7, 7, 0, 7, 7, 7, 0, 0, 0, 0, 0, 8, 8,
    8, 0, 8, 8, 8, 0, 8, 8, 8, 0, 0, 0, 0, 0, 8, 8, 8, 0, 8, 8, 8, 0, 8, 8, 8);

var
  // 256-entry copies so that any neighbour byte is a valid index
  LabelTables: array[0..2, 0..255] of Byte;

procedure InitLabelTables;
var
  I: Integer;
begin
  FillChar(LabelTables, SizeOf(LabelTables), 0);
  for I := 0 to 74 do
  begin
    LabelTables[0, I] := LLAndLHContextsLabel[I];
    LabelTables[1, I] := HLContextLabel[I];
    LabelTables[2, I] := HHContextLabel[I];
  end;
end;

{$R-}{$Q-}

procedure TJpxBitModel.Init(Width, Height: Integer; Kind: TJpxSubbandKind; ZeroBitPlanes: Integer; Causal: Boolean);
var
  Count: Integer;
begin
  FWidth := Width;
  FHeight := Height;
  FCausal := Causal;
  case Kind of
    sbHH: FLabels := @LabelTables[2, 0];
    sbHL: FLabels := @LabelTables[1, 0];
  else
    FLabels := @LabelTables[0, 0];
  end;
  Count := Width * Height;
  if Length(FNeighbors) < Count then
  begin
    SetLength(FNeighbors, Count);
    SetLength(FSigns, Count);
    SetLength(FFlags, Count);
    SetLength(FBitsDecoded, Count);
    SetLength(FMagnitude, Count);
  end;
  FillChar(FNeighbors[0], Count, 0);
  FillChar(FSigns[0], Count, 0);
  FillChar(FFlags[0], Count, 0);
  FillChar(FBitsDecoded[0], Count, Byte(ZeroBitPlanes));
  FillChar(FMagnitude[0], Count * SizeOf(Cardinal), 0);
  ResetContexts;
end;

procedure TJpxBitModel.ResetContexts;
begin
  FillChar(FContexts, SizeOf(FContexts), 0);
  FContexts[0] := (4 shl 1) or 0;
  FContexts[UniformContext] := (46 shl 1) or 0;
  FContexts[RunLengthContext] := (3 shl 1) or 0;
end;

procedure TJpxBitModel.SetNeighborsSignificance(Row, Column, Index: Integer);
var
  N: PByte;
  Left, Right: Boolean;
  I: Integer;
begin
  N := @FNeighbors[0];
  Left := Column > 0;
  Right := Column + 1 < FWidth;
  // vertically causal mode: the last row of the stripe above does not see this stripe
  if (Row > 0) and not (FCausal and ((Row and 3) = 0)) then
  begin
    I := Index - FWidth;
    if Left then
      Inc(N[I - 1], $10);
    if Right then
      Inc(N[I + 1], $10);
    Inc(N[I], $04);
  end;
  if Row + 1 < FHeight then
  begin
    I := Index + FWidth;
    if Left then
      Inc(N[I - 1], $10);
    if Right then
      Inc(N[I + 1], $10);
    Inc(N[I], $04);
  end;
  if Left then
    Inc(N[Index - 1], $01);
  if Right then
    Inc(N[Index + 1], $01);
  N[Index] := N[Index] or $80;
end;

function TJpxBitModel.DecodeSignBit(Row, Column, Index: Integer): Integer;
var
  Mag: PCardinal;
  Sign: PByte;
  Contribution, Sign0, Sign1, HorizontalContribution: Integer;
  Significance1, Below: Boolean;
begin
  Mag := @FMagnitude[0];
  Sign := @FSigns[0];
  // horizontal contribution
  Significance1 := (Column > 0) and (Mag[Index - 1] <> 0);
  if (Column + 1 < FWidth) and (Mag[Index + 1] <> 0) then
  begin
    Sign1 := Sign[Index + 1];
    if Significance1 then
    begin
      Sign0 := Sign[Index - 1];
      Contribution := 1 - Sign1 - Sign0;
    end
    else
      Contribution := 1 - Sign1 - Sign1;
  end
  else if Significance1 then
  begin
    Sign0 := Sign[Index - 1];
    Contribution := 1 - Sign0 - Sign0;
  end
  else
    Contribution := 0;
  HorizontalContribution := 3 * Contribution;

  // vertical contribution combined with the horizontal one
  Significance1 := (Row > 0) and (Mag[Index - FWidth] <> 0);
  Below := (Row + 1 < FHeight) and not (FCausal and ((Row and 3) = 3));
  if Below and (Mag[Index + FWidth] <> 0) then
  begin
    Sign1 := Sign[Index + FWidth];
    if Significance1 then
    begin
      Sign0 := Sign[Index - FWidth];
      Contribution := 1 - Sign1 - Sign0 + HorizontalContribution;
    end
    else
      Contribution := 1 - Sign1 - Sign1 + HorizontalContribution;
  end
  else if Significance1 then
  begin
    Sign0 := Sign[Index - FWidth];
    Contribution := 1 - Sign0 - Sign0 + HorizontalContribution;
  end
  else
    Contribution := HorizontalContribution;

  if Contribution >= 0 then
    Result := Decoder.ReadBit(@FContexts[9 + Contribution])
  else
    Result := Decoder.ReadBit(@FContexts[9 - Contribution]) xor 1;
end;

procedure TJpxBitModel.SignificancePropagationPass;
var
  W, H, I0, J, I1, I, Index: Integer;
  Mag: PCardinal;
  Neigh, Flags, Bits, Signs: PByte;
begin
  W := FWidth;
  H := FHeight;
  Mag := @FMagnitude[0];
  Neigh := @FNeighbors[0];
  Flags := @FFlags[0];
  Bits := @FBitsDecoded[0];
  Signs := @FSigns[0];
  I0 := 0;
  while I0 < H do
  begin
    for J := 0 to W - 1 do
    begin
      Index := I0 * W + J;
      for I1 := 0 to 3 do
      begin
        I := I0 + I1;
        if I >= H then
          Break;
        // clear processed flag first
        Flags[Index] := Flags[Index] and not 1;
        if (Mag[Index] = 0) and (Neigh[Index] <> 0) then
        begin
          if Decoder.ReadBit(@FContexts[FLabels[Neigh[Index]]]) <> 0 then
          begin
            Signs[Index] := Byte(DecodeSignBit(I, J, Index));
            Mag[Index] := 1;
            SetNeighborsSignificance(I, J, Index);
            Flags[Index] := Flags[Index] or 2;
          end;
          Inc(Bits[Index]);
          Flags[Index] := Flags[Index] or 1;
        end;
        Inc(Index, W);
      end;
    end;
    Inc(I0, 4);
  end;
end;

procedure TJpxBitModel.MagnitudeRefinementPass;
var
  W, Len, Width4, Index0, IndexNext, J, Index, Ctx, Bit: Integer;
  Mag: PCardinal;
  Neigh, Flags, Bits: PByte;
begin
  W := FWidth;
  Len := FWidth * FHeight;
  Width4 := W * 4;
  Mag := @FMagnitude[0];
  Neigh := @FNeighbors[0];
  Flags := @FFlags[0];
  Bits := @FBitsDecoded[0];
  Index0 := 0;
  while Index0 < Len do
  begin
    IndexNext := Min(Len, Index0 + Width4);
    for J := 0 to W - 1 do
    begin
      Index := Index0 + J;
      while Index < IndexNext do
      begin
        // significant but not those that have just become
        if (Mag[Index] <> 0) and ((Flags[Index] and 1) = 0) then
        begin
          Ctx := 16;
          if (Flags[Index] and 2) <> 0 then
          begin
            Flags[Index] := Flags[Index] xor 2;
            // first refinement
            if (Neigh[Index] and 127) = 0 then
              Ctx := 15
            else
              Ctx := 14;
          end;
          Bit := Decoder.ReadBit(@FContexts[Ctx]);
          Mag[Index] := (Mag[Index] shl 1) or Cardinal(Bit);
          Inc(Bits[Index]);
          Flags[Index] := Flags[Index] or 1;
        end;
        Inc(Index, W);
      end;
    end;
    Index0 := IndexNext;
  end;
end;

procedure TJpxBitModel.CleanupPass;
var
  W, H, I0, INext, IndexBase, J, Index0, Index, I1, I, I2, Hi, Lo: Integer;
  CheckAllEmpty, AllEmpty: Boolean;
  Mag: PCardinal;
  Neigh, Flags, Bits, Signs: PByte;
  OneRowDown, TwoRowsDown, ThreeRowsDown: Integer;
begin
  W := FWidth;
  H := FHeight;
  Mag := @FMagnitude[0];
  Neigh := @FNeighbors[0];
  Flags := @FFlags[0];
  Bits := @FBitsDecoded[0];
  Signs := @FSigns[0];
  OneRowDown := W;
  TwoRowsDown := W * 2;
  ThreeRowsDown := W * 3;
  I0 := 0;
  while I0 < H do
  begin
    INext := Min(I0 + 4, H);
    IndexBase := I0 * W;
    CheckAllEmpty := I0 + 3 < H;
    for J := 0 to W - 1 do
    begin
      Index0 := IndexBase + J;
      // using the property: labels[neighborsSignificance[index]] = 0 when neighborsSignificance[index] = 0
      AllEmpty := CheckAllEmpty and
        (Flags[Index0] = 0) and (Flags[Index0 + OneRowDown] = 0) and
        (Flags[Index0 + TwoRowsDown] = 0) and (Flags[Index0 + ThreeRowsDown] = 0) and
        (Neigh[Index0] = 0) and (Neigh[Index0 + OneRowDown] = 0) and
        (Neigh[Index0 + TwoRowsDown] = 0) and (Neigh[Index0 + ThreeRowsDown] = 0);
      I1 := 0;
      Index := Index0;
      I := I0;
      if AllEmpty then
      begin
        if Decoder.ReadBit(@FContexts[RunLengthContext]) = 0 then
        begin
          Inc(Bits[Index0]);
          Inc(Bits[Index0 + OneRowDown]);
          Inc(Bits[Index0 + TwoRowsDown]);
          Inc(Bits[Index0 + ThreeRowsDown]);
          Continue; // next column
        end;
        // two uniform bits, most significant first (evaluated in this order on purpose)
        Hi := Decoder.ReadBit(@FContexts[UniformContext]);
        Lo := Decoder.ReadBit(@FContexts[UniformContext]);
        I1 := (Hi shl 1) or Lo;
        if I1 <> 0 then
        begin
          I := I0 + I1;
          Inc(Index, I1 * W);
        end;
        Signs[Index] := Byte(DecodeSignBit(I, J, Index));
        Mag[Index] := 1;
        SetNeighborsSignificance(I, J, Index);
        Flags[Index] := Flags[Index] or 2;
        Index := Index0;
        for I2 := I0 to I do
        begin
          Inc(Bits[Index]);
          Inc(Index, W);
        end;
        Inc(I1);
      end;
      I := I0 + I1;
      while I < INext do
      begin
        if (Mag[Index] = 0) and ((Flags[Index] and 1) = 0) then
        begin
          if Decoder.ReadBit(@FContexts[FLabels[Neigh[Index]]]) = 1 then
          begin
            Signs[Index] := Byte(DecodeSignBit(I, J, Index));
            Mag[Index] := 1;
            SetNeighborsSignificance(I, J, Index);
            Flags[Index] := Flags[Index] or 2;
          end;
          Inc(Bits[Index]);
        end;
        Inc(I);
        Inc(Index, W);
      end;
    end;
    I0 := INext;
  end;
end;

procedure TJpxBitModel.CheckSegmentationSymbol;
var
  Symbol, K: Integer;
begin
  Symbol := 0;
  for K := 0 to 3 do
    Symbol := (Symbol shl 1) or Decoder.ReadBit(@FContexts[UniformContext]);
  if Symbol <> $A then
    Fail('invalid segmentation symbol');
end;

{ TJpxDecoder }

constructor TJpxDecoder.Create(const Data: TBytes);
begin
  inherited Create;
  FData := Data;
  FTiles := TObjectList<TJpxTile>.Create(True);
  FBoxes.CodestreamStart := -1;
end;

destructor TJpxDecoder.Destroy;
begin
  FTiles.Free;
  inherited;
end;

function TJpxDecoder.B(Pos: Integer): Integer;
begin
  if (Pos >= 0) and (Pos < Length(FData)) then
    Result := FData[Pos]
  else
    Result := 0;
end;

function TJpxDecoder.U16(Pos: Integer): Integer;
begin
  Result := (B(Pos) shl 8) or B(Pos + 1);
end;

function TJpxDecoder.U32(Pos: Integer): Int64;
begin
  Result := (Int64(B(Pos)) shl 24) or (B(Pos + 1) shl 16) or (B(Pos + 2) shl 8) or B(Pos + 3);
end;

procedure TJpxDecoder.ParseBoxes(Start, Finish: Integer);
var
  P, DS, BoxEnd, HeaderSize, I, N, NC, Bytes, K, V, Z: Integer;
  LBox, TBox, XL, Entry: Int64;
  Depth: TArray<Integer>;
  Def: TJpxChannelDef;
  Map: TJpxPaletteMap;
begin
  P := Start;
  while P + 8 <= Finish do
  begin
    HeaderSize := 8;
    LBox := U32(P);
    TBox := U32(P + 4);
    if LBox = 1 then
    begin
      // XLBox
      XL := (U32(P + 8) shl 32) or U32(P + 12);
      HeaderSize := 16;
      LBox := XL;
    end
    else if LBox = 0 then
      LBox := Finish - P;
    if LBox < HeaderSize then
    begin
      if FBoxes.CodestreamStart >= 0 then
        Break;
      Fail('invalid box field size');
    end;
    if LBox > Finish - P then
      LBox := Finish - P;
    BoxEnd := P + Integer(LBox);
    DS := P + HeaderSize;
    case TBox of
      $6A703268: // 'jp2h' super box
        ParseBoxes(DS, BoxEnd);
      $636F6C72: // 'colr'
        if not FBoxes.HasColr then
        begin
          FBoxes.HasColr := True;
          FBoxes.ColrMethod := B(DS);
          if FBoxes.ColrMethod = 1 then
            FBoxes.EnumCS := Cardinal(U32(DS + 3))
          else if FBoxes.ColrMethod in [2, 3] then
            // ICC profile: data colour space signature at offset 16 of the profile header
            FBoxes.IccSpace := Cardinal(U32(DS + 3 + 16));
        end;
      $70636C72: // 'pclr'
        begin
          N := U16(DS);
          NC := B(DS + 2);
          if (N > 0) and (N <= 1024) and (NC > 0) then
          begin
            FBoxes.PaletteEntries := N;
            FBoxes.PaletteColumns := NC;
            SetLength(FBoxes.PaletteDepth, NC);
            SetLength(Depth, NC);
            for K := 0 to NC - 1 do
              Depth[K] := (B(DS + 3 + K) and $7F) + 1;
            SetLength(FBoxes.Palette, N * NC);
            I := DS + 3 + NC;
            for V := 0 to N - 1 do
              for K := 0 to NC - 1 do
              begin
                Bytes := (Depth[K] + 7) div 8;
                Entry := 0;
                for Z := 0 to Bytes - 1 do
                  Entry := (Entry shl 8) or B(I + Z);
                // entries deeper than 16 bits are kept at 16 bits
                if Depth[K] > 16 then
                  Entry := Entry shr (Depth[K] - 16);
                FBoxes.Palette[V * NC + K] := Integer(Entry);
                Inc(I, Bytes);
              end;
            for K := 0 to NC - 1 do
              FBoxes.PaletteDepth[K] := Min(Depth[K], 16);
          end;
        end;
      $636D6170: // 'cmap'
        begin
          N := (BoxEnd - DS) div 4;
          SetLength(FBoxes.PaletteMap, N);
          for K := 0 to N - 1 do
          begin
            Map.Component := U16(DS + 4 * K);
            if B(DS + 4 * K + 2) = 1 then
              Map.PaletteColumn := B(DS + 4 * K + 3)
            else
              Map.PaletteColumn := -1;
            FBoxes.PaletteMap[K] := Map;
          end;
        end;
      $63646566: // 'cdef'
        begin
          N := U16(DS);
          if (N > 0) and (DS + 2 + 6 * N <= BoxEnd) then
          begin
            SetLength(FBoxes.ChannelDefs, N);
            for K := 0 to N - 1 do
            begin
              Def.Channel := U16(DS + 2 + 6 * K);
              Def.Typ := U16(DS + 4 + 6 * K);
              Def.Assoc := U16(DS + 6 + 6 * K);
              FBoxes.ChannelDefs[K] := Def;
            end;
          end;
        end;
      $6A703263: // 'jp2c'
        if FBoxes.CodestreamStart < 0 then
        begin
          FBoxes.CodestreamStart := DS;
          FBoxes.CodestreamEnd := BoxEnd;
        end;
    end;
    // 'jP  ', 'ftyp', 'rreq', 'res ', 'ihdr', 'uuid', ... are not needed
    P := BoxEnd;
  end;
end;

procedure TJpxDecoder.Parse(HeaderOnly: Boolean);
var
  I: Integer;
begin
  if (Length(FData) >= 2) and (FData[0] = $FF) and (FData[1] = $4F) then
  begin
    // No box header, immediate start of codestream (SOC)
    FBoxes.CodestreamStart := 0;
    FBoxes.CodestreamEnd := Length(FData);
  end
  else
  begin
    ParseBoxes(0, Length(FData));
    if FBoxes.CodestreamStart < 0 then
    begin
      // Not a JP2 file with a jp2c box: look for an embedded codestream (SOC followed by SIZ)
      for I := 0 to Length(FData) - 4 do
        if (FData[I] = $FF) and (FData[I + 1] = $4F) and (FData[I + 2] = $FF) and (FData[I + 3] = $51) then
        begin
          FBoxes.CodestreamStart := I;
          FBoxes.CodestreamEnd := Length(FData);
          Break;
        end;
      if FBoxes.CodestreamStart < 0 then
        Fail('no codestream found');
    end;
  end;
  ParseCodestream(FBoxes.CodestreamStart, FBoxes.CodestreamEnd, HeaderOnly);
end;

procedure TJpxDecoder.ParseCodestream(Start, Finish: Integer; HeaderOnly: Boolean);
var
  P, Code, Len: Integer;
begin
  P := Start;
  try
    while P + 1 < Finish do
    begin
      Code := U16(P);
      Inc(P, 2);
      Len := 0;
      case Code of
        $FF4F: // SOC
          FMainHeader := True;
        $FFD9: // EOC
          Break;
        $FF93: // SOD
          begin
            if FCurTile = nil then
              Fail('SOD without SOT');
            if not FCurTile.Initialized then
            begin
              if FCurTile.Broken then
                Fail('damaged tile');
              FCurTile.Broken := True;
              InitializeTile(FCurTile);
              BuildPackets(FCurTile);
              FCurTile.Broken := False;
              FCurTile.Initialized := True;
            end;
            if FCurTileDataEnd < P then
              Fail('invalid tile-part length');
            ParseTilePackets(FCurTile, P, FCurTileDataEnd - P);
            // moving to the end of the data
            P := FCurTileDataEnd;
            Continue;
          end;
      else
        // all other markers have a length
        if (Code < $FF30) or (Code > $FF3F) then
        begin
          Len := U16(P);
          if (Len < 2) or (P + Len > Finish) then
            Fail(Format('invalid marker segment length (%.4x)', [Code]));
        end;
        case Code of
          $FF51: ReadSIZ(P, Len);
          $FF52: ReadCOD(P, Len);
          $FF53: ReadCOC(P, Len);
          $FF5C: ReadQCD(P, Len);
          $FF5D: ReadQCC(P, Len);
          $FF90:
            begin
              if HeaderOnly then
                Exit;
              ReadSOT(P, Len, Finish);
            end;
          $FF60, $FF61:
            Unsupported('packed packet headers (PPM/PPT) are not supported');
          $FF5F:
            Unsupported('progression order changes (POC) are not supported');
          $FF30..$FF3F, // reserved markers without parameters
          $FF50, // CAP
          $FF55, // TLM
          $FF57, // PLM
          $FF58, // PLT
          $FF59, // CPF
          $FF5E, // RGN (ignored)
          $FF63, // CRG
          $FF64: // COM
            ; // skipping content
        else
          Fail(Format('unknown codestream code %.4x', [Code]));
        end;
      end;
      Inc(P, Len);
    end;
  except
    on E: EJpxUnsupported do
      raise;
    on E: Exception do
    begin
      // Trying to recover: everything decoded so far is kept, like pdf.js
      if not FHaveSIZ or HeaderOnly then
      begin
        if E is EPdfFilterError then
          raise;
        raise EPdfFilterError.Create('JPX: ' + E.Message);
      end;
    end;
  end;
  if not FHaveSIZ then
    Fail('no size marker found in JPX stream');
end;

procedure TJpxDecoder.ReadSIZ(Pos, Len: Integer);
var
  Csiz, I, J, P, Q, NumX, NumY: Integer;
  V: array[0..7] of Int64;
  Tile: TJpxTile;
  TC: TJpxTileComponent;
  Comp: TJpxComponentInfo;
begin
  if FHaveSIZ then
    Fail('duplicate SIZ marker');
  for I := 0 to 7 do
  begin
    V[I] := U32(Pos + 4 + 4 * I);
    if V[I] > MaxInt div 2 then
      Fail('image too large');
  end;
  FXsiz := V[0];
  FYsiz := V[1];
  FXOsiz := V[2];
  FYOsiz := V[3];
  FXTsiz := V[4];
  FYTsiz := V[5];
  FXTOsiz := V[6];
  FYTOsiz := V[7];
  Csiz := U16(Pos + 36);
  if (FXsiz <= FXOsiz) or (FYsiz <= FYOsiz) then
    Fail('invalid image size');
  if (FXTsiz <= 0) or (FYTsiz <= 0) or (FXTOsiz > FXOsiz) or (FYTOsiz > FYOsiz) then
    Fail('invalid tile size');
  if (Csiz < 1) or (Pos + 38 + 3 * Csiz > Pos + Len) then
    Fail('invalid component count');
  SetLength(FComps, Csiz);
  J := Pos + 38;
  for I := 0 to Csiz - 1 do
  begin
    Comp.Precision := (B(J) and $7F) + 1;
    Comp.Signed := (B(J) and $80) <> 0;
    Comp.XRsiz := B(J + 1);
    Comp.YRsiz := B(J + 2);
    if (Comp.XRsiz = 0) or (Comp.YRsiz = 0) then
      Fail('invalid component subsampling');
    if Comp.Precision > 38 then
      Fail('invalid component precision');
    Inc(J, 3);
    // Section B.2 Component mapping
    Comp.X0 := CeilDiv(FXOsiz, Comp.XRsiz);
    Comp.X1 := CeilDiv(FXsiz, Comp.XRsiz);
    Comp.Y0 := CeilDiv(FYOsiz, Comp.YRsiz);
    Comp.Y1 := CeilDiv(FYsiz, Comp.YRsiz);
    FComps[I] := Comp;
  end;
  // Section B.3 Division into tile and tile-components
  NumX := CeilDiv(FXsiz - FXTOsiz, FXTsiz);
  NumY := CeilDiv(FYsiz - FYTOsiz, FYTsiz);
  if Int64(NumX) * NumY > 65535 then
    Fail('too many tiles');
  for Q := 0 to NumY - 1 do
    for P := 0 to NumX - 1 do
    begin
      Tile := TJpxTile.Create;
      FTiles.Add(Tile);
      Tile.Index := FTiles.Count - 1;
      Tile.X0 := Max(FXTOsiz + P * FXTsiz, FXOsiz);
      Tile.Y0 := Max(FYTOsiz + Q * FYTsiz, FYOsiz);
      Tile.X1 := Min(FXTOsiz + (P + 1) * FXTsiz, FXsiz);
      Tile.Y1 := Min(FYTOsiz + (Q + 1) * FYTsiz, FYsiz);
      for I := 0 to Csiz - 1 do
      begin
        TC := TJpxTileComponent.Create;
        Tile.Components.Add(TC);
        TC.X0 := CeilDiv(Tile.X0, FComps[I].XRsiz);
        TC.Y0 := CeilDiv(Tile.Y0, FComps[I].YRsiz);
        TC.X1 := CeilDiv(Tile.X1, FComps[I].XRsiz);
        TC.Y1 := CeilDiv(Tile.Y1, FComps[I].YRsiz);
      end;
    end;
  SetLength(FCOC, Csiz);
  SetLength(FQCC, Csiz);
  FHaveSIZ := True;
end;

function TJpxDecoder.ReadQuant(Pos, Finish: Integer; Sqcd: Integer): TJpxQuant;
var
  EntrySize, N: Integer;
begin
  case Sqcd and $1F of
    0:
      begin
        EntrySize := 1;
        Result.ScalarExpounded := True;
      end;
    1:
      begin
        EntrySize := 2;
        Result.ScalarExpounded := False;
      end;
    2:
      begin
        EntrySize := 2;
        Result.ScalarExpounded := True;
      end;
  else
    Fail(Format('invalid SQcd value %d', [Sqcd]));
    EntrySize := 1;
  end;
  Result.Defined := True;
  Result.GuardBits := Sqcd shr 5;
  N := (Finish - Pos) div EntrySize;
  if N < 1 then
    Fail('missing quantization step sizes');
  SetLength(Result.Epsilon, N);
  SetLength(Result.Mu, N);
  N := 0;
  while Pos + EntrySize <= Finish do
  begin
    if EntrySize = 1 then
    begin
      Result.Epsilon[N] := B(Pos) shr 3;
      Result.Mu[N] := 0;
    end
    else
    begin
      Result.Epsilon[N] := B(Pos) shr 3;
      Result.Mu[N] := ((B(Pos) and 7) shl 8) or B(Pos + 1);
    end;
    Inc(Pos, EntrySize);
    Inc(N);
  end;
end;

procedure TJpxDecoder.ReadQCD(Pos, Len: Integer);
var
  Q: TJpxQuant;
begin
  Q := ReadQuant(Pos + 3, Pos + Len, B(Pos + 2));
  if FMainHeader then
    FQCD := Q
  else if FCurTile <> nil then
  begin
    FCurTile.HdrQCD := Q;
    SetLength(FCurTile.HdrQCC, 0);
    SetLength(FCurTile.HdrQCC, Length(FComps));
  end;
end;

procedure TJpxDecoder.ReadQCC(Pos, Len: Integer);
var
  J, C: Integer;
  Q: TJpxQuant;
begin
  if not FHaveSIZ then
    Fail('QCC before SIZ');
  J := Pos + 2;
  if Length(FComps) < 257 then
  begin
    C := B(J);
    Inc(J);
  end
  else
  begin
    C := U16(J);
    Inc(J, 2);
  end;
  Q := ReadQuant(J + 1, Pos + Len, B(J));
  if C >= Length(FComps) then
    Exit;
  if FMainHeader then
    FQCC[C] := Q
  else if FCurTile <> nil then
  begin
    if Length(FCurTile.HdrQCC) <> Length(FComps) then
      SetLength(FCurTile.HdrQCC, Length(FComps));
    FCurTile.HdrQCC[C] := Q;
  end;
end;

/// Reads SPcod / SPcoc (decomposition levels, code-block size and style, transform, precinct sizes)
procedure ReadCodingParams(Dec: TJpxDecoder; J, Finish: Integer; CustomPrecincts: Boolean; var Cod: TJpxCoding);
var
  N, K: Integer;
begin
  Cod.Levels := Dec.B(J);
  Cod.Xcb := (Dec.B(J + 1) and $F) + 2;
  Cod.Ycb := (Dec.B(J + 2) and $F) + 2;
  Cod.Style := Dec.B(J + 3);
  Cod.Reversible := Dec.B(J + 4) = 1;
  Cod.CustomPrecincts := CustomPrecincts;
  Inc(J, 5);
  if Cod.Levels > 32 then
    Fail('too many decomposition levels');
  if (Cod.Xcb > 10) or (Cod.Ycb > 10) or (Cod.Xcb + Cod.Ycb > 12) then
    Fail('invalid code-block size');
  if (Cod.Style and StyleBypass) <> 0 then
    Unsupported('selective arithmetic coding bypass is not supported');
  if (Cod.Style and StyleTermAll) <> 0 then
    Unsupported('termination on each coding pass is not supported');
  Cod.Precincts := nil;
  if CustomPrecincts then
  begin
    N := Finish - J;
    if N < 0 then
      N := 0;
    SetLength(Cod.Precincts, N);
    for K := 0 to N - 1 do
      Cod.Precincts[K] := Byte(Dec.B(J + K));
  end;
end;

procedure TJpxDecoder.ReadCOD(Pos, Len: Integer);
var
  Cod: TJpxCoding;
  Scod: Integer;
begin
  Scod := B(Pos + 2);
  Cod.Defined := True;
  Cod.SopMarkers := (Scod and 2) <> 0;
  Cod.EphMarkers := (Scod and 4) <> 0;
  Cod.Progression := B(Pos + 3);
  Cod.Layers := U16(Pos + 4);
  Cod.MCT := B(Pos + 6);
  if Cod.Layers < 1 then
    Fail('invalid number of layers');
  ReadCodingParams(Self, Pos + 7, Pos + Len, (Scod and 1) <> 0, Cod);
  if FMainHeader then
    FCOD := Cod
  else if FCurTile <> nil then
  begin
    FCurTile.HdrCOD := Cod;
    SetLength(FCurTile.HdrCOC, 0);
    SetLength(FCurTile.HdrCOC, Length(FComps));
  end;
end;

procedure TJpxDecoder.ReadCOC(Pos, Len: Integer);
var
  J, C: Integer;
  Coc: TJpxCoding;
begin
  if not FHaveSIZ then
    Fail('COC before SIZ');
  J := Pos + 2;
  if Length(FComps) < 257 then
  begin
    C := B(J);
    Inc(J);
  end
  else
  begin
    C := U16(J);
    Inc(J, 2);
  end;
  Coc := Default(TJpxCoding);
  Coc.Defined := True;
  ReadCodingParams(Self, J + 1, Pos + Len, (B(J) and 1) <> 0, Coc);
  if C >= Length(FComps) then
    Exit;
  if FMainHeader then
    FCOC[C] := Coc
  else if FCurTile <> nil then
  begin
    if Length(FCurTile.HdrCOC) <> Length(FComps) then
      SetLength(FCurTile.HdrCOC, Length(FComps));
    FCurTile.HdrCOC[C] := Coc;
  end;
end;

procedure TJpxDecoder.ReadSOT(Pos, Len, Finish: Integer);
var
  Index: Integer;
  Psot: Int64;
  Tile: TJpxTile;
begin
  if not FHaveSIZ then
    Fail('SOT before SIZ');
  Index := U16(Pos + 2);
  Psot := U32(Pos + 4);
  if Index >= FTiles.Count then
    Fail('invalid tile index');
  Tile := FTiles[Index];
  FMainHeader := False;
  FCurTile := Tile;
  FCurPartIndex := B(Pos + 8);
  if Psot = 0 then
  begin
    // the last tile-part extends to the EOC marker
    FCurTileDataEnd := Finish;
    if (Finish - 2 >= Pos) and (B(Finish - 2) = $FF) and (B(Finish - 1) = $D9) then
      FCurTileDataEnd := Finish - 2;
  end
  else
  begin
    if Psot < 14 then
      Fail('invalid tile-part length');
    FCurTileDataEnd := Integer(Min(Int64(Finish), Int64(Pos) - 2 + Psot));
  end;
  if not Tile.Initialized and ((FCurPartIndex = 0) or not Tile.HdrValid) then
  begin
    // reset component specific settings
    Tile.HdrValid := True;
    Tile.HdrCOD := FCOD;
    Tile.HdrCOC := Copy(FCOC);
    Tile.HdrQCD := FQCD;
    Tile.HdrQCC := Copy(FQCC);
  end;
  if Tile.Initialized then
    // markers in the header of later tile-parts do not change the coding of the tile
    FCurTile := Tile;
end;

procedure TJpxDecoder.InitializeTile(Tile: TJpxTile);
var
  C: Integer;
  Comp: TJpxTileComponent;
  Cod: TJpxCoding;
  Coc: TJpxCoding;
begin
  if not Tile.HdrValid then
  begin
    Tile.HdrCOD := FCOD;
    Tile.HdrCOC := Copy(FCOC);
    Tile.HdrQCD := FQCD;
    Tile.HdrQCC := Copy(FQCC);
    Tile.HdrValid := True;
  end;
  if not Tile.HdrCOD.Defined then
    Fail('missing COD marker');
  if not Tile.HdrQCD.Defined then
    Fail('missing QCD marker');
  for C := 0 to Tile.Components.Count - 1 do
  begin
    Comp := Tile.Components[C];
    Cod := Tile.HdrCOD;
    if (C < Length(Tile.HdrCOC)) and Tile.HdrCOC[C].Defined then
    begin
      Coc := Tile.HdrCOC[C];
      Cod.Levels := Coc.Levels;
      Cod.Xcb := Coc.Xcb;
      Cod.Ycb := Coc.Ycb;
      Cod.Style := Coc.Style;
      Cod.Reversible := Coc.Reversible;
      Cod.CustomPrecincts := Coc.CustomPrecincts;
      Cod.Precincts := Coc.Precincts;
    end;
    Comp.Coding := Cod;
    if (C < Length(Tile.HdrQCC)) and Tile.HdrQCC[C].Defined then
      Comp.Quant := Tile.HdrQCC[C]
    else
      Comp.Quant := Tile.HdrQCD;
  end;
  Tile.Coding := Tile.HdrCOD;
end;

procedure TJpxDecoder.BuildCodeblocks(Subband: TJpxSubband; XcbShift, YcbShift: Integer);
var
  CbW, CbH, Cbx0, Cby0, Cbx1, Cby1, I, J, PI, PJ, Num: Integer;
  CB: TJpxCodeblock;
  Res: TJpxResolution;
  Precinct: TJpxPrecinct;
  X0, Y0, X1, Y1: Integer;
begin
  // Section B.7 Division sub-band into code-blocks
  CbW := 1 shl XcbShift;
  CbH := 1 shl YcbShift;
  Cbx0 := Subband.X0 shr XcbShift;
  Cby0 := Subband.Y0 shr YcbShift;
  Cbx1 := (Subband.X1 + CbW - 1) shr XcbShift;
  Cby1 := (Subband.Y1 + CbH - 1) shr YcbShift;
  if (Subband.X1 <= Subband.X0) or (Subband.Y1 <= Subband.Y0) then
    Exit;
  Inc(FCodeblockCount, Int64(Cbx1 - Cbx0) * (Cby1 - Cby0));
  if FCodeblockCount > MaxCodeblocks then
    Fail('too many code-blocks');
  Res := Subband.Resolution;
  for J := Cby0 to Cby1 - 1 do
    for I := Cbx0 to Cbx1 - 1 do
    begin
      X0 := Max(Subband.X0, CbW * I);
      Y0 := Max(Subband.Y0, CbH * J);
      X1 := Min(Subband.X1, CbW * (I + 1));
      Y1 := Min(Subband.Y1, CbH * (J + 1));
      if (X1 <= X0) or (Y1 <= Y0) then
        Continue;
      // Precinct number for this code-block; the position is relative to its subband
      PI := (X0 - Subband.X0) div Res.PrecinctWidthInSubband;
      PJ := (Y0 - Subband.Y0) div Res.PrecinctHeightInSubband;
      Num := PI + PJ * Res.NumWide;
      CB := TJpxCodeblock.Create;
      Subband.Codeblocks.Add(CB);
      CB.Cbx := I;
      CB.Cby := J;
      CB.X0 := X0;
      CB.Y0 := Y0;
      CB.X1 := X1;
      CB.Y1 := Y1;
      CB.PrecinctNumber := Num;
      CB.Lblock := 3;
      // building precinct for the sub-band
      while Subband.Precincts.Count <= Num do
        Subband.Precincts.Add(nil);
      Precinct := Subband.Precincts[Num];
      if Precinct <> nil then
      begin
        if I < Precinct.CbxMin then
          Precinct.CbxMin := I
        else if I > Precinct.CbxMax then
          Precinct.CbxMax := I;
        if J < Precinct.CbyMin then
          Precinct.CbyMin := J
        else if J > Precinct.CbyMax then
          Precinct.CbyMax := J;
      end
      else
      begin
        Precinct := TJpxPrecinct.Create;
        Precinct.CbxMin := I;
        Precinct.CbyMin := J;
        Precinct.CbxMax := I;
        Precinct.CbyMax := J;
        Subband.Precincts[Num] := Precinct;
      end;
      CB.Precinct := Precinct;
    end;
end;

procedure TJpxDecoder.BuildPackets(Tile: TJpxTile);
var
  C, R, NL, PPx, PPy, Xcb_, Ycb_, Count, PN: Integer;
  Comp: TJpxTileComponent;
  Res: TJpxResolution;
  Scale, BScale: Int64;
  SB: TJpxSubband;
  CB: TJpxCodeblock;
  Counts: TArray<Integer>;
  PW, PH: Int64;

  procedure AddSubband(AKind: TJpxSubbandKind; HalfX, HalfY: Boolean);
  begin
    SB := TJpxSubband.Create;
    Res.Subbands.Add(SB);
    SB.Kind := AKind;
    SB.Resolution := Res;
    if AKind = sbLL then
    begin
      SB.X0 := CeilDiv(Comp.X0, Scale);
      SB.Y0 := CeilDiv(Comp.Y0, Scale);
      SB.X1 := CeilDiv(Comp.X1, Scale);
      SB.Y1 := CeilDiv(Comp.Y1, Scale);
    end
    else
    begin
      // ceil(tc / bscale - 0.5) for the high-pass directions
      if HalfX then
      begin
        SB.X0 := CeilDiv(2 * Int64(Comp.X0) - BScale, 2 * BScale);
        SB.X1 := CeilDiv(2 * Int64(Comp.X1) - BScale, 2 * BScale);
      end
      else
      begin
        SB.X0 := CeilDiv(Comp.X0, BScale);
        SB.X1 := CeilDiv(Comp.X1, BScale);
      end;
      if HalfY then
      begin
        SB.Y0 := CeilDiv(2 * Int64(Comp.Y0) - BScale, 2 * BScale);
        SB.Y1 := CeilDiv(2 * Int64(Comp.Y1) - BScale, 2 * BScale);
      end
      else
      begin
        SB.Y0 := CeilDiv(Comp.Y0, BScale);
        SB.Y1 := CeilDiv(Comp.Y1, BScale);
      end;
    end;
    BuildCodeblocks(SB, Xcb_, Ycb_);
  end;

begin
  for C := 0 to Tile.Components.Count - 1 do
  begin
    Comp := Tile.Components[C];
    NL := Comp.Coding.Levels;
    // Section B.5 Resolution levels and sub-bands
    for R := 0 to NL do
    begin
      // getBlocksDimensions
      if not Comp.Coding.CustomPrecincts then
      begin
        PPx := 15;
        PPy := 15;
      end
      else if Length(Comp.Coding.Precincts) > 0 then
      begin
        PN := Min(R, High(Comp.Coding.Precincts));
        PPx := Comp.Coding.Precincts[PN] and $F;
        PPy := Comp.Coding.Precincts[PN] shr 4;
      end
      else
      begin
        PPx := 15;
        PPy := 15;
      end;
      if R > 0 then
      begin
        Xcb_ := Min(Comp.Coding.Xcb, PPx - 1);
        Ycb_ := Min(Comp.Coding.Ycb, PPy - 1);
      end
      else
      begin
        Xcb_ := Min(Comp.Coding.Xcb, PPx);
        Ycb_ := Min(Comp.Coding.Ycb, PPy);
      end;
      Xcb_ := Max(Xcb_, 0);
      Ycb_ := Max(Ycb_, 0);

      Res := TJpxResolution.Create;
      Comp.Resolutions.Add(Res);
      Scale := Int64(1) shl (NL - R);
      Res.X0 := CeilDiv(Comp.X0, Scale);
      Res.Y0 := CeilDiv(Comp.Y0, Scale);
      Res.X1 := CeilDiv(Comp.X1, Scale);
      Res.Y1 := CeilDiv(Comp.Y1, Scale);
      Res.Level := R;
      // Section B.6 Division resolution to precincts
      Res.PPx := PPx;
      Res.PPy := PPy;
      PW := Int64(1) shl PPx;
      PH := Int64(1) shl PPy;
      if R = 0 then
      begin
        Res.PrecinctWidthInSubband := 1 shl PPx;
        Res.PrecinctHeightInSubband := 1 shl PPy;
      end
      else
      begin
        Res.PrecinctWidthInSubband := 1 shl Max(PPx - 1, 0);
        Res.PrecinctHeightInSubband := 1 shl Max(PPy - 1, 0);
      end;
      if Res.X1 > Res.X0 then
        Res.NumWide := CeilDiv(Res.X1, PW) - FloorDiv(Res.X0, PW)
      else
        Res.NumWide := 0;
      if Res.Y1 > Res.Y0 then
        Res.NumHigh := CeilDiv(Res.Y1, PH) - FloorDiv(Res.Y0, PH)
      else
        Res.NumHigh := 0;
      if Int64(Res.NumWide) * Res.NumHigh > MaxPrecincts then
        Fail('too many precincts');
      Res.NumPrecincts := Res.NumWide * Res.NumHigh;

      if R = 0 then
        AddSubband(sbLL, False, False)
      else
      begin
        BScale := Int64(1) shl (NL - R + 1);
        // three sub-bands (HL, LH and HH) with rest of decompositions
        AddSubband(sbHL, True, False);
        AddSubband(sbLH, False, True);
        AddSubband(sbHH, True, True);
      end;

      // createPacket: code-blocks of every precinct, sub-bands ordered LL / HL, LH, HH
      SetLength(Res.PacketBlocks, Res.NumPrecincts);
      SetLength(Counts, Res.NumPrecincts);
      for Count := 0 to Res.NumPrecincts - 1 do
        Counts[Count] := 0;
      for SB in Res.Subbands do
        for CB in SB.Codeblocks do
          if (CB.PrecinctNumber >= 0) and (CB.PrecinctNumber < Res.NumPrecincts) then
            Inc(Counts[CB.PrecinctNumber]);
      for Count := 0 to Res.NumPrecincts - 1 do
      begin
        SetLength(Res.PacketBlocks[Count], Counts[Count]);
        Counts[Count] := 0;
      end;
      for SB in Res.Subbands do
        for CB in SB.Codeblocks do
          if (CB.PrecinctNumber >= 0) and (CB.PrecinctNumber < Res.NumPrecincts) then
          begin
            Res.PacketBlocks[CB.PrecinctNumber][Counts[CB.PrecinctNumber]] := CB;
            Inc(Counts[CB.PrecinctNumber]);
          end;
    end;
  end;
  // Generate the packets sequence
  Tile.Iterator := TJpxPacketIterator.Create(Tile);
end;

procedure TJpxDecoder.ParseTilePackets(Tile: TJpxTile; Start, Len: Integer);
type
  TQueueItem = record
    Codeblock: TJpxCodeblock;
    Passes, DataLength: Integer;
  end;
var
  R: TJpxPacketBitReader;
  Packet: TJpxPacket;
  Blocks: TArray<TJpxCodeblock>;
  Queue: TArray<TQueueItem>;
  QueueCount, I, Col, Row, Passes, Bits, ZB, Value: Integer;
  CB: TJpxCodeblock;
  Precinct: TJpxPrecinct;
  Included, FirstTime: Boolean;
  Sop, Eph: Boolean;

  function ReadCodingPasses: Integer;
  begin
    if R.ReadBits(1) = 0 then
      Exit(1);
    if R.ReadBits(1) = 0 then
      Exit(2);
    Result := Integer(R.ReadBits(2));
    if Result < 3 then
      Exit(Result + 3);
    Result := Integer(R.ReadBits(5));
    if Result < 31 then
      Exit(Result + 6);
    Result := Integer(R.ReadBits(7)) + 37;
  end;

begin
  if Tile.Iterator = nil then
    Exit;
  R.Init(FData, Start);
  Sop := Tile.Coding.SopMarkers;
  Eph := Tile.Coding.EphMarkers;
  while R.Position < Len do
  begin
    R.AlignToByte;
    if Sop and R.SkipMarkerIfEqual($91) then
      // Skip also marker segment length and packet sequence ID
      R.SkipBytes(4);
    if not Tile.Iterator.Next(Packet) then
      Break; // out of packets: the rest of the tile-part is padding
    if R.ReadBits(1) = 0 then
      Continue; // empty packet
    Blocks := Packet.Resolution.PacketBlocks[Packet.Precinct];
    if Length(Queue) < Length(Blocks) then
      SetLength(Queue, Length(Blocks));
    QueueCount := 0;
    for I := 0 to High(Blocks) do
    begin
      CB := Blocks[I];
      Precinct := CB.Precinct;
      Col := CB.Cbx - Precinct.CbxMin;
      Row := CB.Cby - Precinct.CbyMin;
      if Precinct.Inclusion = nil then
      begin
        // building inclusion and zero bit-planes trees
        Precinct.Inclusion := TJpxTagTree.Create(Precinct.CbxMax - Precinct.CbxMin + 1,
          Precinct.CbyMax - Precinct.CbyMin + 1);
        Precinct.ZeroBitPlanes := TJpxTagTree.Create(Precinct.CbxMax - Precinct.CbxMin + 1,
          Precinct.CbyMax - Precinct.CbyMin + 1);
      end;
      FirstTime := False;
      if CB.Included then
        Included := R.ReadBits(1) <> 0
      else
      begin
        Included := Precinct.Inclusion.Decode(R, Col, Row, Packet.Layer + 1);
        if Included then
        begin
          CB.Included := True;
          FirstTime := True;
        end;
      end;
      if not Included then
        Continue;
      if FirstTime then
      begin
        ZB := 1;
        while not Precinct.ZeroBitPlanes.Decode(R, Col, Row, ZB) do
        begin
          Inc(ZB);
          if ZB > 64 then
            Fail('invalid number of zero bit-planes');
        end;
        Value := Precinct.ZeroBitPlanes.LeafValue(Col, Row);
        CB.ZeroBitPlanes := Value;
      end;
      Passes := ReadCodingPasses;
      while R.ReadBits(1) <> 0 do
      begin
        Inc(CB.Lblock);
        if CB.Lblock > 32 then
          Fail('invalid code-block length indicator');
      end;
      // rounding down log2
      Bits := JpxFloorLog2(Cardinal(Passes)) + CB.Lblock;
      Queue[QueueCount].Codeblock := CB;
      Queue[QueueCount].Passes := Passes;
      Queue[QueueCount].DataLength := Integer(R.ReadBits(Bits) and $7FFFFFFF);
      Inc(QueueCount);
    end;
    R.AlignToByte;
    if Eph then
      R.SkipMarkerIfEqual($92);
    for I := 0 to QueueCount - 1 do
    begin
      CB := Queue[I].Codeblock;
      if R.Position + Int64(Queue[I].DataLength) > Len then
        Queue[I].DataLength := Max(0, Len - R.Position);
      CB.AddChunk(Start + R.Position, Queue[I].DataLength);
      Inc(CB.Passes, Queue[I].Passes);
      Inc(R.Position, Queue[I].DataLength);
    end;
  end;
end;

procedure TJpxDecoder.CopyCoefficients(var Coefficients: TArray<Single>; LevelWidth, LevelHeight: Integer;
  Subband: TJpxSubband; Delta: Double; Mb: Integer; Reversible: Boolean; const Coding: TJpxCoding;
  Model: TJpxBitModel);
var
  X0, Y0, Width, Right, Bottom, BlockWidth, BlockHeight, TotalLength, Position, I, J, K, CodingPassType,
    Offset, Row, LevelOffset, Pos, Nb, CoefCount: Integer;
  CB: TJpxCodeblock;
  Encoded: TBytes;
  MagnitudeCorrection, N: Double;
  Interleave, Segmentation, Reset, Causal: Boolean;
  Mag: PCardinal;
  Sign, Bits: PByte;
begin
  X0 := Subband.X0;
  Y0 := Subband.Y0;
  Width := Subband.X1 - Subband.X0;
  if Subband.Kind in [sbHL, sbHH] then
    Right := 1
  else
    Right := 0;
  if Subband.Kind in [sbLH, sbHH] then
    Bottom := LevelWidth
  else
    Bottom := 0;
  Segmentation := (Coding.Style and StyleSegmentation) <> 0;
  Reset := (Coding.Style and StyleReset) <> 0;
  Causal := (Coding.Style and StyleCausal) <> 0;
  if Reversible then
    MagnitudeCorrection := 0
  else
    MagnitudeCorrection := 0.5;
  Interleave := Subband.Kind <> sbLL;
  CoefCount := Length(Coefficients);

  for CB in Subband.Codeblocks do
  begin
    BlockWidth := CB.X1 - CB.X0;
    BlockHeight := CB.Y1 - CB.Y0;
    if (BlockWidth <= 0) or (BlockHeight <= 0) or (CB.ChunkCount = 0) then
      Continue;
    Model.Init(BlockWidth, BlockHeight, Subband.Kind, CB.ZeroBitPlanes, Causal);
    // collect data
    TotalLength := 0;
    for J := 0 to CB.ChunkCount - 1 do
      Inc(TotalLength, Max(0, Min(CB.Chunks[J].Len, Length(FData) - CB.Chunks[J].Start)));
    SetLength(Encoded, TotalLength);
    Position := 0;
    for J := 0 to CB.ChunkCount - 1 do
    begin
      K := Max(0, Min(CB.Chunks[J].Len, Length(FData) - CB.Chunks[J].Start));
      if K > 0 then
        Move(FData[CB.Chunks[J].Start], Encoded[Position], K);
      Inc(Position, K);
    end;
    // decoding the item; a damaged code-block keeps what was decoded before the error
    Model.Decoder.Init(Encoded, 0, TotalLength);
    CodingPassType := 2; // first bit plane starts from cleanup
    try
      for J := 0 to CB.Passes - 1 do
      begin
        case CodingPassType of
          0: Model.SignificancePropagationPass;
          1: Model.MagnitudeRefinementPass;
          2:
            begin
              Model.CleanupPass;
              if Segmentation then
                Model.CheckSegmentationSymbol;
            end;
        end;
        if Reset then
          Model.ResetContexts;
        CodingPassType := (CodingPassType + 1) mod 3;
      end;
    except
      on E: EPdfFilterError do
        ;
    end;

    Offset := CB.X0 - X0 + (CB.Y0 - Y0) * Width;
    Mag := @Model.FMagnitude[0];
    Sign := @Model.FSigns[0];
    Bits := @Model.FBitsDecoded[0];
    Position := 0;
    // Do the interleaving of Section F.3.3 here, so we do not need to copy later. LL level is not interleaved.
    for J := 0 to BlockHeight - 1 do
    begin
      Row := Offset div Width; // row in the non-interleaved subband
      LevelOffset := 2 * Row * (LevelWidth - Width) + Right + Bottom;
      for I := 0 to BlockWidth - 1 do
      begin
        if Mag[Position] <> 0 then
        begin
          N := (Mag[Position] + MagnitudeCorrection) * Delta;
          if Sign[Position] <> 0 then
            N := -N;
          Nb := Bits[Position];
          if Interleave then
            Pos := LevelOffset + (Offset shl 1)
          else
            Pos := Offset;
          if not (Reversible and (Nb >= Mb)) and (Mb <> Nb) then
          begin
            if (Mb > Nb) and (Mb - Nb < 31) then
              N := N * (1 shl (Mb - Nb))
            else
              N := N * Power(2, Mb - Nb);
          end;
          if (Pos >= 0) and (Pos < CoefCount) then
            Coefficients[Pos] := N;
        end;
        Inc(Offset);
        Inc(Position);
      end;
      Inc(Offset, Width - BlockWidth);
    end;
  end;
end;

function TJpxDecoder.TransformTileComponent(Tile: TJpxTile; C, Reduce: Integer; Model: TJpxBitModel;
  out Left, Top: Integer): TJpxBand;
const
  SubbandsGainLog2: array[TJpxSubbandKind] of Integer = (0, 1, 1, 2);
var
  Comp: TJpxTileComponent;
  Quant: TJpxQuant;
  NL, Last, Precision, BIndex, I, Mu, Epsilon, Mb, Width, Height: Integer;
  Res: TJpxResolution;
  SB: TJpxSubband;
  Bands: TArray<TJpxBand>;
  Delta: Double;
  Reversible: Boolean;
begin
  Comp := Tile.Components[C];
  Quant := Comp.Quant;
  NL := Comp.Coding.Levels;
  Last := Max(0, NL - Reduce);
  Precision := FComps[C].Precision;
  Reversible := Comp.Coding.Reversible;
  BIndex := 0;
  SetLength(Bands, Last + 1);
  for I := 0 to Last do
  begin
    Res := Comp.Resolutions[I];
    Width := Max(0, Res.X1 - Res.X0);
    Height := Max(0, Res.Y1 - Res.Y0);
    Bands[I].Width := Width;
    Bands[I].Height := Height;
    // Allocate space for the whole sublevel (zero-initialized).
    SetLength(Bands[I].Items, Width * Height);
    for SB in Res.Subbands do
    begin
      if not Quant.ScalarExpounded then
      begin
        // formula E-5
        Mu := Quant.Mu[0];
        Epsilon := Quant.Epsilon[0];
        if I > 0 then
          Inc(Epsilon, 1 - I);
      end
      else
      begin
        Mu := Quant.Mu[Min(BIndex, High(Quant.Mu))];
        Epsilon := Quant.Epsilon[Min(BIndex, High(Quant.Epsilon))];
        Inc(BIndex);
      end;
      // calculate quantization coefficient (Section E.1.1.1)
      if Reversible then
        Delta := 1
      else
        Delta := Power(2, Precision + SubbandsGainLog2[SB.Kind] - Epsilon) * (1 + Mu / 2048);
      Mb := Quant.GuardBits + Epsilon - 1;
      if (Width > 0) and (Height > 0) then
        CopyCoefficients(Bands[I].Items, Width, Height, SB, Delta, Mb, Reversible, Comp.Coding, Model);
    end;
  end;
  Result := JpxInverseTransform(Bands, Reversible, Comp.X0, Comp.Y0);
  Left := Comp.Resolutions[Last].X0;
  Top := Comp.Resolutions[Last].Y0;
end;

function TJpxDecoder.ColorSpaceFromBoxes(out CS: TPdfJPXColorSpace; out IsYCC: Boolean): Boolean;
begin
  CS := jcUnknown;
  IsYCC := False;
  Result := False;
  if not FBoxes.HasColr then
    Exit;
  if FBoxes.ColrMethod = 1 then
  begin
    Result := True;
    case FBoxes.EnumCS of
      16, 20, 21, 22: CS := jcRGB;      // sRGB, e-sRGB, ROMM-RGB
      0, 15, 17: CS := jcGray;         // bi-level, greyscale
      12: CS := jcCMYK;
      1, 3, 18, 24:                    // YCbCr(1), YCbCr(2), sYCC, e-sYCC
        begin
          CS := jcRGB;
          IsYCC := True;
        end;
    else
      Result := False;
    end;
  end
  else if FBoxes.ColrMethod in [2, 3] then
  begin
    Result := True;
    case FBoxes.IccSpace of
      $52474220: CS := jcRGB;  // 'RGB '
      $47524159: CS := jcGray; // 'GRAY'
      $434D594B: CS := jcCMYK; // 'CMYK'
      $59436272:               // 'YCbr'
        begin
          CS := jcRGB;
          IsYCC := True;
        end;
    else
      Result := False;
    end;
  end;
end;

procedure TJpxDecoder.GetInfo(out Info: TPdfJPXInfo);
var
  IsYCC: Boolean;
  Def: TJpxChannelDef;
begin
  Info := Default(TPdfJPXInfo);
  Info.Width := FXsiz - FXOsiz;
  Info.Height := FYsiz - FYOsiz;
  Info.Components := Length(FComps);
  if Length(FComps) > 0 then
    Info.BitDepth := FComps[0].Precision;
  if FCOD.Defined then
    Info.DecompositionLevels := FCOD.Levels;
  Info.HasPalette := (FBoxes.PaletteEntries > 0) and (Length(FBoxes.PaletteMap) > 0);
  for Def in FBoxes.ChannelDefs do
    if Def.Typ in [1, 2] then
      Info.HasAlpha := True;
  if not ColorSpaceFromBoxes(Info.ColorSpace, IsYCC) then
    case Info.Components - Ord(Info.HasAlpha) of
      1: Info.ColorSpace := jcGray;
      3: Info.ColorSpace := jcRGB;
      4: Info.ColorSpace := jcCMYK;
    end;
end;

function TJpxDecoder.Decode(const Options: TPdfJPXOptions): TPdfJPXImage;
type
  TChannel = record
    Plane: Integer;
    PaletteColumn: Integer;
    Precision: Integer;
  end;
var
  NC, C, MinLevels, Reduce, S, OutW, OutH, OX, OY, X, Y, I, J, K, Idx, Ch, NColor, NOut,
    Prec, PX, PY, MaxV, Mid, CompW, CompH, BW, BH, ValueShift: Integer;
  Tile: TJpxTile;
  MaxSamples: Int64;
  Model: TJpxBitModel;
  Bands: TArray<TJpxBand>;
  Lefts, Tops: TArray<Integer>;
  Planes: TArray<TArray<Word>>;
  PlaneX0, PlaneY0, PlaneW, PlaneH, PlanePrec: TArray<Integer>;
  MapX, MapY: TArray<TArray<Integer>>;
  Channels: TArray<TChannel>;
  Order: TArray<Integer>;
  AlphaChannel: Integer;
  Y0, Y1, Y2, G, D, Half: Double;
  MCTDone, IsYCC, HaveCS, Applied: Boolean;
  CS: TPdfJPXColorSpace;
  Row: TArray<Byte>;
  V, Ent: Integer;
  Def: TJpxChannelDef;
  RR, GG, BB, Cb, Cr: Double;
  Items0, Items1, Items2: TArray<Single>;

  function Clamp8(Value: Double): Byte; inline;
  begin
    if Value <= 0 then
      Result := 0
    else if Value >= 255 then
      Result := 255
    else
      Result := Byte(Round(Value));
  end;

begin
  Result := Default(TPdfJPXImage);
  NC := Length(FComps);
  MaxSamples := Options.MaxSamples;
  if MaxSamples <= 0 then
    MaxSamples := DefaultMaxSamples;

  // Reduction: limited by the decomposition levels of every tile-component
  MinLevels := MaxInt;
  for Tile in FTiles do
    if Tile.Initialized then
      for C := 0 to Tile.Components.Count - 1 do
        MinLevels := Min(MinLevels, Tile.Components[C].Coding.Levels);
  if MinLevels = MaxInt then
  begin
    if FCOD.Defined then
      MinLevels := FCOD.Levels
    else
      MinLevels := 0;
  end;
  Reduce := EnsureRange(Options.ReduceLevels, 0, MinLevels);
  while True do
  begin
    S := 1 shl Reduce;
    OutW := CeilDiv(FXsiz, S) - CeilDiv(FXOsiz, S);
    OutH := CeilDiv(FYsiz, S) - CeilDiv(FYOsiz, S);
    if Int64(OutW) * OutH * Max(NC, 3) <= MaxSamples then
      Break;
    if Reduce >= MinLevels then
      Fail(Format('image too large (%d x %d x %d)', [FXsiz - FXOsiz, FYsiz - FYOsiz, NC]));
    Inc(Reduce);
  end;
  OX := CeilDiv(FXOsiz, S);
  OY := CeilDiv(FYOsiz, S);

  // Component planes at (reduced) component resolution, precision limited to 16 bits
  SetLength(Planes, NC);
  SetLength(PlaneX0, NC);
  SetLength(PlaneY0, NC);
  SetLength(PlaneW, NC);
  SetLength(PlaneH, NC);
  SetLength(PlanePrec, NC);
  for C := 0 to NC - 1 do
  begin
    PlaneX0[C] := CeilDiv(FComps[C].X0, S);
    PlaneY0[C] := CeilDiv(FComps[C].Y0, S);
    PlaneW[C] := Max(1, CeilDiv(FComps[C].X1, S) - PlaneX0[C]);
    PlaneH[C] := Max(1, CeilDiv(FComps[C].Y1, S) - PlaneY0[C]);
    PlanePrec[C] := Min(FComps[C].Precision, 16);
    SetLength(Planes[C], PlaneW[C] * PlaneH[C]);
    // tiles without data stay at the DC level (zero coefficients)
    Mid := 1 shl (PlanePrec[C] - 1);
    for I := 0 to High(Planes[C]) do
      Planes[C][I] := Word(Mid);
  end;

  Model := TJpxBitModel.Create;
  try
    SetLength(Bands, NC);
    SetLength(Lefts, NC);
    SetLength(Tops, NC);
    for Tile in FTiles do
    begin
      if not Tile.Initialized then
        Continue;
      for C := 0 to NC - 1 do
        Bands[C] := TransformTileComponent(Tile, C, Reduce, Model, Lefts[C], Tops[C]);

      // Section G.2.2 Inverse multi component transform
      MCTDone := False;
      if (Tile.Coding.MCT <> 0) and (NC >= 3) and (Bands[0].Width = Bands[1].Width) and
        (Bands[0].Width = Bands[2].Width) and (Bands[0].Height = Bands[1].Height) and
        (Bands[0].Height = Bands[2].Height) and (Length(Bands[0].Items) = Length(Bands[1].Items)) and
        (Length(Bands[0].Items) = Length(Bands[2].Items)) then
      begin
        MCTDone := True;
        Items0 := Bands[0].Items;
        Items1 := Bands[1].Items;
        Items2 := Bands[2].Items;
        if not Tile.Components[0].Coding.Reversible then
        begin
          // inverse irreversible multiple component transform
          for J := 0 to High(Items0) do
          begin
            Y0 := Items0[J];
            Y1 := Items1[J];
            Y2 := Items2[J];
            Items0[J] := Y0 + 1.402 * Y2;
            Items1[J] := Y0 - 0.34413 * Y1 - 0.71414 * Y2;
            Items2[J] := Y0 + 1.772 * Y1;
          end;
        end
        else
        begin
          // inverse reversible multiple component transform
          for J := 0 to High(Items0) do
          begin
            Y0 := Items0[J];
            Y1 := Items1[J];
            Y2 := Items2[J];
            G := Y0 - Sar(Trunc(Y2 + Y1), 2);
            Items0[J] := G + Y2;
            Items1[J] := G;
            Items2[J] := G + Y1;
          end;
        end;
      end;
      if not MCTDone then
        ; // components are independent

      // DC level shift and precision clamp into the component planes
      for C := 0 to NC - 1 do
      begin
        Prec := FComps[C].Precision;
        MaxV := (1 shl PlanePrec[C]) - 1;
        ValueShift := Prec - PlanePrec[C];
        Half := Int64(1) shl (Prec - 1);
        BW := Bands[C].Width;
        BH := Bands[C].Height;
        if Length(Bands[C].Items) < BW * BH then
          Continue;
        for Y := 0 to BH - 1 do
        begin
          PY := Tops[C] - PlaneY0[C] + Y;
          if (PY < 0) or (PY >= PlaneH[C]) then
            Continue;
          for X := 0 to BW - 1 do
          begin
            PX := Lefts[C] - PlaneX0[C] + X;
            if (PX < 0) or (PX >= PlaneW[C]) then
              Continue;
            D := Bands[C].Items[Y * BW + X] + Half;
            if ValueShift > 0 then
              D := D / (Int64(1) shl ValueShift);
            D := Floor(D + 0.5);
            if D <= 0 then
              V := 0
            else if D >= MaxV then
              V := MaxV
            else
              V := Trunc(D);
            Planes[C][PY * PlaneW[C] + PX] := Word(V);
          end;
        end;
      end;
      for C := 0 to NC - 1 do
        Bands[C].Items := nil;
    end;
  finally
    Model.Free;
  end;

  // Map output pixels to component samples (subsampled components are replicated)
  SetLength(MapX, NC);
  SetLength(MapY, NC);
  for C := 0 to NC - 1 do
  begin
    CompW := PlaneW[C];
    CompH := PlaneH[C];
    SetLength(MapX[C], OutW);
    SetLength(MapY[C], OutH);
    for X := 0 to OutW - 1 do
      MapX[C][X] := EnsureRange((X + OX) div FComps[C].XRsiz - PlaneX0[C], 0, CompW - 1);
    for Y := 0 to OutH - 1 do
      MapY[C][Y] := EnsureRange((Y + OY) div FComps[C].YRsiz - PlaneY0[C], 0, CompH - 1) * CompW;
  end;

  // Channels: palette expansion (pclr/cmap) unless the PDF wants the indices
  Applied := False;
  if Options.IsIndexed then
  begin
    SetLength(Channels, 1);
    Channels[0].Plane := 0;
    Channels[0].PaletteColumn := -1;
    Channels[0].Precision := 0; // raw values
  end
  else if (FBoxes.PaletteEntries > 0) and (Length(FBoxes.PaletteMap) > 0) then
  begin
    Applied := True;
    SetLength(Channels, Length(FBoxes.PaletteMap));
    for I := 0 to High(FBoxes.PaletteMap) do
    begin
      Channels[I].Plane := EnsureRange(FBoxes.PaletteMap[I].Component, 0, NC - 1);
      Channels[I].PaletteColumn := FBoxes.PaletteMap[I].PaletteColumn;
      if (Channels[I].PaletteColumn >= 0) and (Channels[I].PaletteColumn < FBoxes.PaletteColumns) then
        Channels[I].Precision := FBoxes.PaletteDepth[Channels[I].PaletteColumn]
      else
      begin
        Channels[I].PaletteColumn := -1;
        Channels[I].Precision := PlanePrec[Channels[I].Plane];
      end;
    end;
  end
  else
  begin
    SetLength(Channels, NC);
    for I := 0 to NC - 1 do
    begin
      Channels[I].Plane := I;
      Channels[I].PaletteColumn := -1;
      Channels[I].Precision := PlanePrec[I];
    end;
  end;

  // Channel order and alpha from cdef (colour channels by association, then the opacity channel)
  AlphaChannel := -1;
  SetLength(Order, 0);
  if (not Options.IsIndexed) and (Length(FBoxes.ChannelDefs) > 0) then
  begin
    for K := 1 to Length(Channels) do
      for Def in FBoxes.ChannelDefs do
        if (Def.Typ = 0) and (Def.Assoc = K) and (Def.Channel < Length(Channels)) then
        begin
          Order := Order + [Def.Channel];
          Break;
        end;
    for Def in FBoxes.ChannelDefs do
      if (Def.Typ in [1, 2]) and (Def.Channel < Length(Channels)) and (AlphaChannel < 0) then
        AlphaChannel := Def.Channel;
    if Length(Order) = 0 then
      for K := 0 to High(Channels) do
        if K <> AlphaChannel then
          Order := Order + [K];
  end
  else
    for K := 0 to High(Channels) do
      Order := Order + [K];
  if Options.IsIndexed then
    SetLength(Order, 1);

  // SMaskInData: the last component is the alpha channel
  if Options.SMaskInData and (AlphaChannel < 0) and not Options.IsIndexed then
  begin
    NColor := Length(Order);
    if ((Options.ColorComponents > 0) and (NColor = Options.ColorComponents + 1)) or
      ((Options.ColorComponents <= 0) and (NColor in [2, 4, 5])) then
    begin
      AlphaChannel := Order[NColor - 1];
      SetLength(Order, NColor - 1);
    end;
  end;
  NColor := Length(Order);

  // Colour space
  HaveCS := ColorSpaceFromBoxes(CS, IsYCC);
  if Options.IsIndexed then
  begin
    CS := jcUnknown;
    IsYCC := False;
  end
  else
  begin
    if HaveCS and not Applied then
    begin
      // the box must fit the channel count
      if ((CS = jcGray) and (NColor <> 1)) or ((CS = jcRGB) and (NColor <> 3)) or ((CS = jcCMYK) and (NColor <> 4)) then
      begin
        HaveCS := False;
        IsYCC := False;
      end;
    end;
    if not HaveCS then
    begin
      case NColor of
        1: CS := jcGray;
        3: CS := jcRGB;
        4: CS := jcCMYK;
      else
        CS := jcUnknown;
      end;
    end;
    if IsYCC and (NColor <> 3) then
      IsYCC := False;
  end;

  // Interleave to 8 bits
  NOut := NColor + Ord(AlphaChannel >= 0);
  Result.Width := OutW;
  Result.Height := OutH;
  Result.Components := NColor;
  Result.HasAlpha := AlphaChannel >= 0;
  Result.ColorSpace := CS;
  Result.BitDepth := FComps[0].Precision;
  Result.ReducedLevels := Reduce;
  SetLength(Result.Data, Int64(OutW) * OutH * NOut);
  SetLength(Row, NOut);
  Idx := 0;
  for Y := 0 to OutH - 1 do
    for X := 0 to OutW - 1 do
    begin
      for K := 0 to NOut - 1 do
      begin
        if K < NColor then
          Ch := Order[K]
        else
          Ch := AlphaChannel;
        I := Channels[Ch].Plane;
        V := Planes[I][MapY[I][Y] + MapX[I][X]];
        if Channels[Ch].PaletteColumn >= 0 then
        begin
          Ent := EnsureRange(V, 0, FBoxes.PaletteEntries - 1);
          V := FBoxes.Palette[Ent * FBoxes.PaletteColumns + Channels[Ch].PaletteColumn];
        end;
        Prec := Channels[Ch].Precision;
        if Prec <= 0 then
          V := EnsureRange(V, 0, 255)
        else if Prec > 8 then
          V := V shr (Prec - 8)
        else if Prec < 8 then
        begin
          MaxV := (1 shl Prec) - 1;
          V := (EnsureRange(V, 0, MaxV) * 255 + MaxV div 2) div MaxV;
        end;
        Row[K] := Byte(EnsureRange(V, 0, 255));
      end;
      if IsYCC then
      begin
        // sYCC to RGB
        Y0 := Row[0];
        Cb := Row[1] - 128;
        Cr := Row[2] - 128;
        RR := Y0 + 1.402 * Cr;
        GG := Y0 - 0.344136 * Cb - 0.714136 * Cr;
        BB := Y0 + 1.772 * Cb;
        Row[0] := Clamp8(RR);
        Row[1] := Clamp8(GG);
        Row[2] := Clamp8(BB);
      end;
      Move(Row[0], Result.Data[Idx], NOut);
      Inc(Idx, NOut);
    end;
end;

{ Public API }

class function TPdfJPXOptions.Default: TPdfJPXOptions;
begin
  Result.ReduceLevels := 0;
  Result.SMaskInData := False;
  Result.ColorComponents := 0;
  Result.IsIndexed := False;
  Result.MaxSamples := 0;
end;

function PdfJPXDecode(const Data: TBytes; ReduceLevels: Integer): TPdfJPXImage;
var
  Options: TPdfJPXOptions;
begin
  Options := TPdfJPXOptions.Default;
  Options.ReduceLevels := ReduceLevels;
  Result := PdfJPXDecode(Data, Options);
end;

function PdfJPXDecode(const Data: TBytes; const Options: TPdfJPXOptions): TPdfJPXImage;
var
  Decoder: TJpxDecoder;
begin
  if Length(Data) < 2 then
    raise EPdfFilterError.Create('JPX: empty stream');
  Decoder := TJpxDecoder.Create(Data);
  try
    try
      Decoder.Parse(False);
      Result := Decoder.Decode(Options);
    except
      on E: EPdfFilterError do
        raise;
      on E: EOutOfMemory do
        raise EPdfFilterError.Create('JPX: out of memory');
      on E: Exception do
        raise EPdfFilterError.Create('JPX: ' + E.Message);
    end;
  finally
    Decoder.Free;
  end;
end;

function PdfJPXReadInfo(const Data: TBytes; out Info: TPdfJPXInfo): Boolean;
var
  Decoder: TJpxDecoder;
begin
  Info := Default(TPdfJPXInfo);
  Decoder := TJpxDecoder.Create(Data);
  try
    try
      Decoder.Parse(True);
      Decoder.GetInfo(Info);
      Result := (Info.Width > 0) and (Info.Height > 0);
    except
      Result := False;
    end;
  finally
    Decoder.Free;
  end;
end;

function PdfIsJPX(const Data: TBytes): Boolean;
begin
  Result := False;
  if (Length(Data) >= 4) and (Data[0] = $FF) and (Data[1] = $4F) and (Data[2] = $FF) and (Data[3] = $51) then
    Exit(True);
  // JP2 signature box: length 12, type 'jP  ', contents 0D 0A 87 0A
  if (Length(Data) >= 12) and (Data[0] = 0) and (Data[1] = 0) and (Data[2] = 0) and (Data[3] = 12) and
    (Data[4] = $6A) and (Data[5] = $50) and (Data[6] = $20) and (Data[7] = $20) and
    (Data[8] = $0D) and (Data[9] = $0A) and (Data[10] = $87) and (Data[11] = $0A) then
    Result := True;
end;

initialization
  InitLabelTables;
end.
