{*******************************************************************************
  Pdf.Viewer.Cache
  LRU cache of rendered page images with a memory budget. Keys are the page
  index and the render scale (quantised). Thread-safe: the render thread
  stores results while the UI thread reads.
*******************************************************************************}
unit Pdf.Viewer.Cache;

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections, System.SyncObjs, System.Skia;

type
  TPdfCacheKey = record
    Page: Integer;
    ScaleKey: Integer; // Round(Scale * 1000)
    class function Create(APage: Integer; AScale: Double): TPdfCacheKey; static;
    class function ScaleToKey(AScale: Double): Integer; static; inline;
  end;

  TPdfImageCache = class
  private type
    TEntry = class
      Key: TPdfCacheKey;
      Image: ISkImage;
      Bytes: Int64;

    end;
  private
    FLock: TCriticalSection;
    FEntries: TDictionary<Int64, TEntry>;
    FOrder: TList<TEntry>;          // most recently used at the end
    FBytes: Int64;
    FMaxBytes: Int64;
    FHits, FMisses: Int64;
    function KeyToInt(const Key: TPdfCacheKey): Int64; inline;
    procedure Touch(E: TEntry);
    procedure RemoveEntry(E: TEntry);
    procedure EvictToFit(Extra: Int64);
    procedure SetMaxBytes(const Value: Int64);
  public
    /// <summary>MaxBytes: memory budget for the pixel data (default 256 MB).</summary>
    constructor Create(AMaxBytes: Int64 = 256 * 1024 * 1024);
    destructor Destroy; override;
    /// <summary>Stores an image; an existing entry for the same key is replaced. Images larger than the budget are not kept.</summary>
    procedure Put(Page: Integer; Scale: Double; const Image: ISkImage);
    /// <summary>Exact match for page and scale; marks it as recently used.</summary>
    function Get(Page: Integer; Scale: Double; out Image: ISkImage): Boolean;
    function Contains(Page: Integer; Scale: Double): Boolean;
    /// <summary>Any cached image of the page, preferring the scale closest to Scale (used as a blurry placeholder).</summary>
    function GetNearest(Page: Integer; Scale: Double; out Image: ISkImage; out ImageScale: Double): Boolean;
    procedure RemovePage(Page: Integer);
    procedure Clear;
    function Count: Integer;
    property Bytes: Int64 read FBytes;
    property MaxBytes: Int64 read FMaxBytes write SetMaxBytes;
    property Hits: Int64 read FHits;
    property Misses: Int64 read FMisses;
  end;

/// <summary>Approximate memory of an image: width x height x 4.</summary>
function PdfImageBytes(const Image: ISkImage): Int64;

implementation

function PdfImageBytes(const Image: ISkImage): Int64;
begin
  if Image = nil then
    Result := 0
  else
    Result := Int64(Image.Width) * Image.Height * 4;
end;

{ TPdfCacheKey }

class function TPdfCacheKey.ScaleToKey(AScale: Double): Integer;
begin
  Result := Round(AScale * 1000);
end;

class function TPdfCacheKey.Create(APage: Integer; AScale: Double): TPdfCacheKey;
begin
  Result.Page := APage;
  Result.ScaleKey := ScaleToKey(AScale);
end;

{ TPdfImageCache }

constructor TPdfImageCache.Create(AMaxBytes: Int64);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEntries := TDictionary<Int64, TEntry>.Create;
  FOrder := TList<TEntry>.Create;
  FMaxBytes := Max(0, AMaxBytes);
end;

destructor TPdfImageCache.Destroy;
begin
  Clear;
  FOrder.Free;
  FEntries.Free;
  FLock.Free;
  inherited;
end;

function TPdfImageCache.KeyToInt(const Key: TPdfCacheKey): Int64;
begin
  Result := (Int64(Key.Page) shl 32) or (Int64(Cardinal(Key.ScaleKey)));
end;

procedure TPdfImageCache.Touch(E: TEntry);
begin
  FOrder.Remove(E);
  FOrder.Add(E);
end;

procedure TPdfImageCache.RemoveEntry(E: TEntry);
begin
  FOrder.Remove(E);
  FEntries.Remove(KeyToInt(E.Key));
  Dec(FBytes, E.Bytes);
  E.Free;
end;

procedure TPdfImageCache.EvictToFit(Extra: Int64);
begin
  while (FBytes + Extra > FMaxBytes) and (FOrder.Count > 0) do
    RemoveEntry(FOrder[0]);
end;

procedure TPdfImageCache.SetMaxBytes(const Value: Int64);
begin
  FLock.Enter;
  try
    FMaxBytes := Max(0, Value);
    EvictToFit(0);
  finally
    FLock.Leave;
  end;
end;

procedure TPdfImageCache.Put(Page: Integer; Scale: Double; const Image: ISkImage);
var
  Key: TPdfCacheKey;
  E: TEntry;
  Size: Int64;
begin
  if Image = nil then
    Exit;
  Key := TPdfCacheKey.Create(Page, Scale);
  Size := PdfImageBytes(Image);
  FLock.Enter;
  try
    if FEntries.TryGetValue(KeyToInt(Key), E) then
      RemoveEntry(E);
    if Size > FMaxBytes then
      Exit;
    EvictToFit(Size);
    E := TEntry.Create;
    E.Key := Key;
    E.Image := Image;
    E.Bytes := Size;
    FEntries.Add(KeyToInt(Key), E);
    Inc(FBytes, Size);
    Touch(E);
  finally
    FLock.Leave;
  end;
end;

function TPdfImageCache.Get(Page: Integer; Scale: Double; out Image: ISkImage): Boolean;
var
  E: TEntry;
begin
  Image := nil;
  FLock.Enter;
  try
    Result := FEntries.TryGetValue(KeyToInt(TPdfCacheKey.Create(Page, Scale)), E);
    if Result then
    begin
      Image := E.Image;
      Touch(E);
      Inc(FHits);
    end
    else
      Inc(FMisses);
  finally
    FLock.Leave;
  end;
end;

function TPdfImageCache.Contains(Page: Integer; Scale: Double): Boolean;
begin
  FLock.Enter;
  try
    Result := FEntries.ContainsKey(KeyToInt(TPdfCacheKey.Create(Page, Scale)));
  finally
    FLock.Leave;
  end;
end;

function TPdfImageCache.GetNearest(Page: Integer; Scale: Double; out Image: ISkImage; out ImageScale: Double): Boolean;
var
  E, Best: TEntry;
  Want: Integer;
  Dist, BestDist: Double;
begin
  Image := nil;
  ImageScale := 0;
  Best := nil;
  BestDist := MaxDouble;
  Want := TPdfCacheKey.ScaleToKey(Scale);
  FLock.Enter;
  try
    for E in FOrder do
      if E.Key.Page = Page then
      begin
        Dist := Abs(Ln(Max(1, E.Key.ScaleKey) / Max(1, Want)));
        if Dist < BestDist then
        begin
          BestDist := Dist;
          Best := E;
        end;
      end;
    Result := Best <> nil;
    if Result then
    begin
      Image := Best.Image;
      ImageScale := Best.Key.ScaleKey / 1000;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TPdfImageCache.RemovePage(Page: Integer);
var
  E: TEntry;
  ToRemove: TList<TEntry>;
begin
  ToRemove := TList<TEntry>.Create;
  try
    FLock.Enter;
    try
      for E in FOrder do
        if E.Key.Page = Page then
          ToRemove.Add(E);
      for E in ToRemove do
        RemoveEntry(E);
    finally
      FLock.Leave;
    end;
  finally
    ToRemove.Free;
  end;
end;

procedure TPdfImageCache.Clear;
begin
  FLock.Enter;
  try
    while FOrder.Count > 0 do
      RemoveEntry(FOrder[0]);
    FBytes := 0;
  finally
    FLock.Leave;
  end;
end;

function TPdfImageCache.Count: Integer;
begin
  FLock.Enter;
  try
    Result := FEntries.Count;
  finally
    FLock.Leave;
  end;
end;

end.
