unit Demo.Printing;

{ Printing through FMX.Printer (Windows and macOS): every page is rendered by
  the viewer at the printer's resolution and drawn scaled to fit the paper. }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Math, System.Skia,
  FMX.Graphics, FMX.Skia, FMX.PdfViewer;

/// <summary>True when this platform can print.</summary>
function PrintingSupported: Boolean;
/// <summary>Installed printers; the index of the active one in ActiveIndex (-1 when none).</summary>
function PrinterNames(out ActiveIndex: Integer): TArray<string>;
/// <summary>Prints pages FirstPage..LastPage (0-based, inclusive) of the viewer's document. Raises on printer errors.</summary>
procedure PrintPdfPages(Viewer: TPdfViewer; PrinterIndex, FirstPage, LastPage: Integer; const JobTitle: string);

implementation

{$IF DEFINED(MSWINDOWS) or DEFINED(MACOS)}
uses
  FMX.Printer;
{$ENDIF}

function PrintingSupported: Boolean;
begin
  {$IF DEFINED(MSWINDOWS) or DEFINED(MACOS)}
  Result := True;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function PrinterNames(out ActiveIndex: Integer): TArray<string>;
{$IF DEFINED(MSWINDOWS) or DEFINED(MACOS)}
var
  I: Integer;
begin
  ActiveIndex := -1;
  SetLength(Result, Printer.Count);
  for I := 0 to Printer.Count - 1 do
  begin
    Result[I] := Printer.Printers[I].Title;
    if Printer.Printers[I] = Printer.ActivePrinter then
      ActiveIndex := I;
  end;
  if (ActiveIndex < 0) and (Length(Result) > 0) then
    ActiveIndex := 0;
end;
{$ELSE}
begin
  ActiveIndex := -1;
  Result := nil;
end;
{$ENDIF}

procedure PrintPdfPages(Viewer: TPdfViewer; PrinterIndex, FirstPage, LastPage: Integer; const JobTitle: string);
{$IF DEFINED(MSWINDOWS) or DEFINED(MACOS)}
var
  I, DpiX, DpiY: Integer;
  Img: ISkImage;
  Bmp: TBitmap;
  PageW, PageH, Scale, DrawW, DrawH: Double;
  Dest: TRectF;
  Size: TSizeF;
begin
  if (Viewer = nil) or not Viewer.IsLoaded or (Printer.Count = 0) then
    Exit;
  FirstPage := EnsureRange(FirstPage, 0, Viewer.PageCount - 1);
  LastPage := EnsureRange(LastPage, FirstPage, Viewer.PageCount - 1);
  if (PrinterIndex >= 0) and (PrinterIndex < Printer.Count) then
    Printer.ActivePrinter := Printer.Printers[PrinterIndex];
  Printer.ActivePrinter.SelectDPI(300, 300);
  Printer.Title := JobTitle;
  Printer.BeginDoc;
  try
    for I := FirstPage to LastPage do
    begin
      if I > FirstPage then
        Printer.NewPage;
      DpiX := Max(72, Printer.ActivePrinter.ActiveDPI.X);
      DpiY := Max(72, Printer.ActivePrinter.ActiveDPI.Y);
      PageW := Printer.PageWidth;   // device pixels at the active DPI
      PageH := Printer.PageHeight;
      Size := Viewer.PageSize(I);   // points as shown (includes the view rotation)
      if (Size.Width <= 0) or (Size.Height <= 0) then
        Continue;
      // Scale to fit the paper; render at the printer resolution, never above the fitted size
      Scale := Min(PageW / Size.Width, PageH / Size.Height);
      Scale := Min(Scale, DpiX / 72);
      Img := Viewer.RenderPageToImage(I, Scale);
      if Img = nil then
        Continue;
      DrawW := Size.Width * Scale;
      DrawH := Size.Height * Scale * (DpiY / DpiX);
      Dest := TRectF.Create(0, 0, DrawW, DrawH);
      Dest.Offset((PageW - DrawW) / 2, (PageH - DrawH) / 2);
      Bmp := TBitmap.CreateFromSkImage(Img);
      try
        Printer.Canvas.DrawBitmap(Bmp, TRectF.Create(0, 0, Bmp.Width, Bmp.Height), Dest, 1, True);
      finally
        Bmp.Free;
      end;
      Img := nil;
    end;
  finally
    Printer.EndDoc;
  end;
end;
{$ELSE}
begin
  raise Exception.Create('Printing is not supported on this platform');
end;
{$ENDIF}

end.
