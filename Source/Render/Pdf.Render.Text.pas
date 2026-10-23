{*******************************************************************************
  Pdf.Render.Text
  Text extraction built on the renderer's glyph reporting: collects glyph
  boxes with their Unicode text, groups them into lines, produces the page
  text with spaces and line breaks, and supports search and selection by
  position. Coordinates are those of the matrix used for extraction (the
  viewer uses TPdfPageRenderer.PageMatrix(Page, 1): display points, y down).
*******************************************************************************}
unit Pdf.Render.Text;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.Math, System.Character, System.Generics.Collections,
  System.Generics.Defaults, System.Skia,
  Pdf.Core.Types, Pdf.Core.Document, Pdf.Font.Loader, Pdf.Render.Skia;

type
  TPdfTextGlyph = record
    Text: string;
    /// <summary>Axis-aligned bounding box of the glyph quad.</summary>
    Bounds: TRectF;
    /// <summary>Baseline start/end points (bottom-left and bottom-right of the quad).</summary>
    BaseStart, BaseEnd: TPointF;
    FontSize: Single;
    IsSpace: Boolean;
    /// <summary>Line this glyph belongs to (index into Lines), -1 before Finish.</summary>
    Line: Integer;
    /// <summary>Offset of Text in the page text.</summary>
    CharIndex: Integer;
  end;

  TPdfTextLine = record
    FirstGlyph, LastGlyph: Integer;
    Bounds: TRectF;
    /// <summary>Offset of the line's first character in the page text.</summary>
    CharIndex: Integer;
    CharLength: Integer;
  end;

  TPdfTextMatch = record
    /// <summary>Character range in the page text.</summary>
    CharIndex, CharLength: Integer;
    FirstGlyph, LastGlyph: Integer;
    /// <summary>One rectangle per line the match spans.</summary>
    Rects: TArray<TRectF>;
  end;

  TPdfTextPage = class(TPdfTextSink)
  private
    FGlyphs: TList<TPdfTextGlyph>;
    FLines: TList<TPdfTextLine>;
    FText: string;
    FFinished: Boolean;
    FPageIndex: Integer;
    procedure Finish;
    function GlyphRectsForRange(FirstGlyph, LastGlyph: Integer): TArray<TRectF>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddGlyph(const Text: string; const Quad: TArray<TPointF>; FontSize: Single; IsSpace: Boolean;
      Font: TPdfFont); override;
    /// <summary>Runs the renderer in text-only mode over Page with Matrix (e.g. TPdfPageRenderer.PageMatrix(Page, 1)).</summary>
    class function Extract(Page: TPdfPage; const Matrix: TPdfMatrix; Renderer: TPdfPageRenderer = nil): TPdfTextPage; static;
    /// <summary>Page text with spaces between words and line breaks between lines.</summary>
    function Text: string;
    function GlyphCount: Integer;
    function LineCount: Integer;
    function Glyph(Index: Integer): TPdfTextGlyph;
    function Line(Index: Integer): TPdfTextLine;
    /// <summary>Glyph under a point, or the nearest glyph on the nearest line when Nearest is True; -1 when none.</summary>
    function GlyphAt(const P: TPointF; Nearest: Boolean = False): Integer;
    /// <summary>All occurrences of Query (case-insensitive by default), with highlight rectangles.</summary>
    function Find(const Query: string; CaseSensitive: Boolean = False; WholeWord: Boolean = False): TArray<TPdfTextMatch>;
    /// <summary>Rectangles covering the glyphs between two glyph indexes (in reading order, either order given).</summary>
    function SelectionRects(GlyphA, GlyphB: Integer): TArray<TRectF>;
    /// <summary>Text between two glyph indexes (inclusive), with the same spaces and line breaks as Text.</summary>
    function SelectionText(GlyphA, GlyphB: Integer): string;
    property PageIndex: Integer read FPageIndex write FPageIndex;
  end;

implementation

{ TPdfTextPage }

constructor TPdfTextPage.Create;
begin
  inherited Create;
  FGlyphs := TList<TPdfTextGlyph>.Create;
  FLines := TList<TPdfTextLine>.Create;
  FPageIndex := -1;
end;

destructor TPdfTextPage.Destroy;
begin
  FLines.Free;
  FGlyphs.Free;
  inherited;
end;

procedure TPdfTextPage.AddGlyph(const Text: string; const Quad: TArray<TPointF>; FontSize: Single; IsSpace: Boolean;
  Font: TPdfFont);
var
  G: TPdfTextGlyph;
  I: Integer;
begin
  if Length(Quad) < 4 then
    Exit;
  G := Default(TPdfTextGlyph);
  G.Text := Text;
  G.FontSize := FontSize;
  G.IsSpace := IsSpace or ((Text = ' ') or (Text = #$A0));
  G.BaseStart := Quad[0];
  G.BaseEnd := Quad[1];
  G.Bounds := TRectF.Create(Quad[0], Quad[0]);
  for I := 1 to 3 do
  begin
    G.Bounds.Left := Min(G.Bounds.Left, Quad[I].X);
    G.Bounds.Top := Min(G.Bounds.Top, Quad[I].Y);
    G.Bounds.Right := Max(G.Bounds.Right, Quad[I].X);
    G.Bounds.Bottom := Max(G.Bounds.Bottom, Quad[I].Y);
  end;
  G.Line := -1;
  G.CharIndex := -1;
  FGlyphs.Add(G);
  FFinished := False;
end;

class function TPdfTextPage.Extract(Page: TPdfPage; const Matrix: TPdfMatrix; Renderer: TPdfPageRenderer): TPdfTextPage;
var
  R: TPdfPageRenderer;
  Own: Boolean;
  Recorder: ISkPictureRecorder;
  Canvas: ISkCanvas;
  SavedSink: TPdfTextSink;
  SavedTextOnly: Boolean;
begin
  Result := TPdfTextPage.Create;
  Result.FPageIndex := Page.Index;
  Own := Renderer = nil;
  if Own then
    R := TPdfPageRenderer.Create(Page.Document)
  else
    R := Renderer;
  SavedSink := R.TextSink;
  SavedTextOnly := R.TextOnly;
  try
    R.TextSink := Result;
    R.TextOnly := True;
    Recorder := TSkPictureRecorder.Create;
    Canvas := Recorder.BeginRecording(TRectF.Create(-1E6, -1E6, 1E6, 1E6));
    try
      R.RenderPage(Page, Canvas, Matrix);
    except
      // keep what was collected
    end;
    Recorder.FinishRecording;
  finally
    R.TextSink := SavedSink;
    R.TextOnly := SavedTextOnly;
    if Own then
      R.Free;
  end;
  Result.Finish;
end;

procedure TPdfTextPage.Finish;
var
  I, N: Integer;
  G, Prev: TPdfTextGlyph;
  L: TPdfTextLine;
  SB: TStringBuilder;
  SameLine: Boolean;
  Gap, Tol, Size: Double;
  LineIdx: Integer;
  LastWasSpace: Boolean;
begin
  if FFinished then
    Exit;
  FFinished := True;
  FLines.Clear;
  SB := TStringBuilder.Create;
  try
    N := FGlyphs.Count;
    LineIdx := -1;
    LastWasSpace := True;
    for I := 0 to N - 1 do
    begin
      G := FGlyphs[I];
      SameLine := False;
      if I > 0 then
      begin
        Prev := FGlyphs[I - 1];
        Size := Max(1, Max(G.FontSize, Prev.FontSize));
        Tol := 0.5 * Size;
        // Same line: baselines close and the glyph does not jump back far to the left
        SameLine := (Abs(G.BaseStart.Y - Prev.BaseEnd.Y) < Tol) and (G.BaseStart.X > Prev.BaseStart.X - 2 * Size) and
          (G.BaseStart.X < Prev.BaseEnd.X + 8 * Size);
      end;
      if not SameLine then
      begin
        if LineIdx >= 0 then
        begin
          L := FLines[LineIdx];
          L.CharLength := SB.Length - L.CharIndex;
          FLines[LineIdx] := L;
          SB.Append(#10);
        end;
        L := Default(TPdfTextLine);
        L.FirstGlyph := I;
        L.LastGlyph := I;
        L.Bounds := G.Bounds;
        L.CharIndex := SB.Length;
        FLines.Add(L);
        LineIdx := FLines.Count - 1;
        LastWasSpace := True;
      end
      else
      begin
        Prev := FGlyphs[I - 1];
        Gap := G.BaseStart.X - Prev.BaseEnd.X;
        Size := Max(1, Max(G.FontSize, Prev.FontSize));
        if (Gap > 0.2 * Size) and not LastWasSpace and not G.IsSpace then
        begin
          SB.Append(' ');
          LastWasSpace := True;
        end;
        L := FLines[LineIdx];
        L.LastGlyph := I;
        L.Bounds := TRectF.Union(L.Bounds, G.Bounds);
        FLines[LineIdx] := L;
      end;
      G.Line := LineIdx;
      G.CharIndex := SB.Length;
      if G.IsSpace then
      begin
        if not LastWasSpace then
          SB.Append(' ');
        LastWasSpace := True;
      end
      else if G.Text <> '' then
      begin
        SB.Append(G.Text);
        LastWasSpace := False;
      end;
      FGlyphs[I] := G;
    end;
    if LineIdx >= 0 then
    begin
      L := FLines[LineIdx];
      L.CharLength := SB.Length - L.CharIndex;
      FLines[LineIdx] := L;
    end;
    FText := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TPdfTextPage.Text: string;
begin
  Finish;
  Result := FText;
end;

function TPdfTextPage.GlyphCount: Integer;
begin
  Result := FGlyphs.Count;
end;

function TPdfTextPage.LineCount: Integer;
begin
  Finish;
  Result := FLines.Count;
end;

function TPdfTextPage.Glyph(Index: Integer): TPdfTextGlyph;
begin
  Finish;
  Result := FGlyphs[Index];
end;

function TPdfTextPage.Line(Index: Integer): TPdfTextLine;
begin
  Finish;
  Result := FLines[Index];
end;

function TPdfTextPage.GlyphAt(const P: TPointF; Nearest: Boolean): Integer;
var
  I, J, BestLine: Integer;
  L: TPdfTextLine;
  D, BestD: Double;
  R: TRectF;
begin
  Finish;
  Result := -1;
  for I := 0 to FGlyphs.Count - 1 do
    if FGlyphs[I].Bounds.Contains(P) then
      Exit(I);
  if not Nearest or (FLines.Count = 0) then
    Exit;
  // Nearest line by vertical distance, then nearest glyph horizontally on that line
  BestLine := -1;
  BestD := MaxDouble;
  for I := 0 to FLines.Count - 1 do
  begin
    R := FLines[I].Bounds;
    if (P.Y >= R.Top) and (P.Y <= R.Bottom) then
      D := 0
    else
      D := Min(Abs(P.Y - R.Top), Abs(P.Y - R.Bottom));
    if D < BestD then
    begin
      BestD := D;
      BestLine := I;
    end;
  end;
  if BestLine < 0 then
    Exit;
  L := FLines[BestLine];
  BestD := MaxDouble;
  for J := L.FirstGlyph to L.LastGlyph do
  begin
    R := FGlyphs[J].Bounds;
    if (P.X >= R.Left) and (P.X <= R.Right) then
      D := 0
    else
      D := Min(Abs(P.X - R.Left), Abs(P.X - R.Right));
    if D < BestD then
    begin
      BestD := D;
      Result := J;
    end;
  end;
end;

function TPdfTextPage.GlyphRectsForRange(FirstGlyph, LastGlyph: Integer): TArray<TRectF>;
var
  I: Integer;
  Cur: TRectF;
  CurLine: Integer;
  Have: Boolean;
begin
  Result := nil;
  Have := False;
  CurLine := -1;
  Cur := TRectF.Empty;
  for I := Max(0, FirstGlyph) to Min(FGlyphs.Count - 1, LastGlyph) do
  begin
    if FGlyphs[I].IsSpace and (FGlyphs[I].Text = '') then
      Continue;
    if not Have or (FGlyphs[I].Line <> CurLine) then
    begin
      if Have then
        Result := Result + [Cur];
      Cur := FGlyphs[I].Bounds;
      CurLine := FGlyphs[I].Line;
      Have := True;
    end
    else
      Cur := TRectF.Union(Cur, FGlyphs[I].Bounds);
  end;
  if Have then
    Result := Result + [Cur];
end;

function TPdfTextPage.Find(const Query: string; CaseSensitive, WholeWord: Boolean): TArray<TPdfTextMatch>;
var
  Hay, Needle: string;
  Pos, Start, I, FirstG, LastG: Integer;
  M: TPdfTextMatch;

  function IsWordChar(C: Char): Boolean;
  begin
    Result := C.IsLetterOrDigit or (C = '_');
  end;

  function GlyphForChar(CharIdx: Integer; Last: Boolean): Integer;
  var
    K: Integer;
  begin
    Result := -1;
    for K := 0 to FGlyphs.Count - 1 do
    begin
      if FGlyphs[K].CharIndex > CharIdx then
        Break;
      if (FGlyphs[K].CharIndex <= CharIdx) and (FGlyphs[K].Text <> '') then
        Result := K;
    end;
  end;

begin
  Finish;
  Result := nil;
  if Query = '' then
    Exit;
  if CaseSensitive then
  begin
    Hay := FText;
    Needle := Query;
  end
  else
  begin
    Hay := FText.ToLower;
    Needle := Query.ToLower;
  end;
  if Length(Hay) <> Length(FText) then
  begin
    // Case folding changed the length (rare scripts): fall back to case-sensitive search
    Hay := FText;
    Needle := Query;
  end;
  Start := 1;
  while True do
  begin
    Pos := Hay.IndexOf(Needle, Start - 1);
    if Pos < 0 then
      Break;
    Start := Pos + 2;
    if WholeWord then
    begin
      if (Pos > 0) and IsWordChar(Hay.Chars[Pos - 1]) then
        Continue;
      if (Pos + Length(Needle) < Length(Hay)) and IsWordChar(Hay.Chars[Pos + Length(Needle)]) then
        Continue;
    end;
    M := Default(TPdfTextMatch);
    M.CharIndex := Pos;
    M.CharLength := Length(Needle);
    FirstG := GlyphForChar(Pos, False);
    LastG := GlyphForChar(Pos + Length(Needle) - 1, True);
    if (FirstG < 0) or (LastG < FirstG) then
      Continue;
    M.FirstGlyph := FirstG;
    M.LastGlyph := LastG;
    M.Rects := GlyphRectsForRange(FirstG, LastG);
    Result := Result + [M];
  end;
  for I := 0 to High(Result) do
    if Length(Result[I].Rects) = 0 then
      Result[I].Rects := [FGlyphs[Result[I].FirstGlyph].Bounds];
end;

function TPdfTextPage.SelectionRects(GlyphA, GlyphB: Integer): TArray<TRectF>;
begin
  Finish;
  if (GlyphA < 0) or (GlyphB < 0) then
    Exit(nil);
  Result := GlyphRectsForRange(Min(GlyphA, GlyphB), Max(GlyphA, GlyphB));
end;

function TPdfTextPage.SelectionText(GlyphA, GlyphB: Integer): string;
var
  A, B, StartChar, EndChar: Integer;
begin
  Finish;
  Result := '';
  if (GlyphA < 0) or (GlyphB < 0) or (FGlyphs.Count = 0) then
    Exit;
  A := Min(GlyphA, GlyphB);
  B := Max(GlyphA, GlyphB);
  A := EnsureRange(A, 0, FGlyphs.Count - 1);
  B := EnsureRange(B, 0, FGlyphs.Count - 1);
  StartChar := FGlyphs[A].CharIndex;
  EndChar := FGlyphs[B].CharIndex + Max(1, Length(FGlyphs[B].Text));
  if B + 1 < FGlyphs.Count then
    EndChar := Min(EndChar, FGlyphs[B + 1].CharIndex)
  else
    EndChar := Min(EndChar, Length(FText));
  if EndChar > StartChar then
    Result := Copy(FText, StartChar + 1, EndChar - StartChar);
end;

end.
