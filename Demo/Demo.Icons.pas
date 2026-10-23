unit Demo.Icons;

{ Toolbar icons as small inline SVGs (24x24, stroked, no fill). TSkSvg draws them
  at any size; the colour is set with Svg.OverrideColor so the same icons work
  for the light and the dark theme. Hand drawn for this demo, no external icon set. }

interface

uses
  System.SysUtils, System.UITypes, FMX.Types, FMX.Skia;

type
  TDemoIcon = (diOpen, diRecent, diSidebar, diFirst, diPrev, diNext, diLast, diZoomIn, diZoomOut, diFitWidth,
    diFitPage, diRotateLeft, diRotateRight, diLayout, diSearch, diUp, diDown, diPrint, diExport, diCopy, diInfo,
    diHelp, diMoon, diSun, diClose, diFullScreen, diBookmark, diThumbnails, diText, diFile, diFolder);

/// <summary>Complete SVG document for an icon.</summary>
function DemoIconSvg(Icon: TDemoIcon): string;
/// <summary>Assigns an icon to a TSkSvg control (source and colour).</summary>
procedure SetDemoIcon(Svg: TSkSvg; Icon: TDemoIcon; Color: TAlphaColor);
/// <summary>Recolours every TSkSvg below Root (toolbar icons after a theme change).</summary>
procedure RecolorDemoIcons(Root: TFmxObject; Color: TAlphaColor);

implementation

const
  SvgHead = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000000" ' +
    'stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">';
  SvgTail = '</svg>';

  Bodies: array[TDemoIcon] of string = (
    // diOpen
    '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    // diRecent (small chevron)
    '<path d="M8 10l4 4 4-4"/>',
    // diSidebar
    '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16M5.5 8h1.5M5.5 11h1.5M5.5 14h1.5"/>',
    // diFirst
    '<path d="M7 5v14M18 6l-7 6 7 6"/>',
    // diPrev
    '<path d="M14.5 6l-6 6 6 6"/>',
    // diNext
    '<path d="M9.5 6l6 6-6 6"/>',
    // diLast
    '<path d="M17 5v14M6 6l7 6-7 6"/>',
    // diZoomIn
    '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l5 5M8.5 11h5M11 8.5v5"/>',
    // diZoomOut
    '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l5 5M8.5 11h5"/>',
    // diFitWidth
    '<path d="M4 5v14M20 5v14M7.5 12h9M10.5 9l-3 3 3 3M13.5 9l3 3-3 3"/>',
    // diFitPage
    '<path d="M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5"/><rect x="8.5" y="8.5" width="7" height="7" rx="1"/>',
    // diRotateLeft
    '<path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3"/><path d="M4.5 4v5h5"/>',
    // diRotateRight
    '<path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3"/><path d="M19.5 4v5h-5"/>',
    // diLayout
    '<rect x="3" y="5" width="8" height="14" rx="1"/><rect x="13" y="5" width="8" height="14" rx="1"/>',
    // diSearch
    '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l5 5"/>',
    // diUp
    '<path d="M6 14.5l6-6 6 6"/>',
    // diDown
    '<path d="M6 9.5l6 6 6-6"/>',
    // diPrint
    '<path d="M7 8V4h10v4M7 17H4v-7h16v7h-3"/><rect x="7" y="14" width="10" height="6"/>',
    // diExport
    '<path d="M12 4v11M7.5 10.5L12 15l4.5-4.5M4 19h16"/>',
    // diCopy
    '<rect x="8" y="8" width="12" height="12" rx="1.5"/>' +
    '<path d="M16 8V5.5A1.5 1.5 0 0 0 14.5 4h-9A1.5 1.5 0 0 0 4 5.5v9A1.5 1.5 0 0 0 5.5 16H8"/>',
    // diInfo
    '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5v.2"/>',
    // diHelp
    '<circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.3-1 .9-1 1.7M12 17v.2"/>',
    // diMoon
    '<path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/>',
    // diSun
    '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2.5M12 19v2.5M2.5 12H5M19 12h2.5M5.3 5.3l1.8 1.8' +
    'M16.9 16.9l1.8 1.8M5.3 18.7l1.8-1.8M16.9 7.1l1.8-1.8"/>',
    // diClose
    '<path d="M6 6l12 12M18 6L6 18"/>',
    // diFullScreen
    '<path d="M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5"/>',
    // diBookmark
    '<path d="M6 4h12v17l-6-4-6 4z"/>',
    // diThumbnails
    '<rect x="4" y="4" width="7" height="7" rx="1"/><rect x="13" y="4" width="7" height="7" rx="1"/>' +
    '<rect x="4" y="13" width="7" height="7" rx="1"/><rect x="13" y="13" width="7" height="7" rx="1"/>',
    // diText
    '<path d="M5 6h14M5 10h14M5 14h9M5 18h6"/>',
    // diFile
    '<path d="M6 3h8l5 5v13H6z"/><path d="M14 3v5h5"/>',
    // diFolder
    '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M3 11h18"/>'
  );

function DemoIconSvg(Icon: TDemoIcon): string;
begin
  Result := SvgHead + Bodies[Icon] + SvgTail;
end;

procedure SetDemoIcon(Svg: TSkSvg; Icon: TDemoIcon; Color: TAlphaColor);
begin
  if Svg = nil then
    Exit;
  Svg.Svg.Source := DemoIconSvg(Icon);
  Svg.Svg.OverrideColor := Color;
  Svg.HitTest := False;
end;

procedure RecolorDemoIcons(Root: TFmxObject; Color: TAlphaColor);
var
  I: Integer;
begin
  if Root = nil then
    Exit;
  if Root is TSkSvg then
    TSkSvg(Root).Svg.OverrideColor := Color;
  for I := 0 to Root.ChildrenCount - 1 do
    RecolorDemoIcons(Root.Children[I], Color);
end;

end.
