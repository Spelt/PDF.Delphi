#!/bin/sh
# Builds the FMX demo (DemoFMX/PdfViewerDemo.dpr) for Win64 into Build/out with dcc64.
# The IDE generates PdfViewerDemo.res itself; here an empty one is created when missing.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'
BDS='C:\Program Files (x86)\Embarcadero\Studio\37.0'
ROOTU="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cygpath -w "$ROOTU")"
OUT="$ROOT\\Build\\out"
mkdir -p "$ROOTU/Build/out/demo_dcu"
for rc in "$ROOTU"/Resources/*.rc; do
  res="${rc%.rc}.res"
  if [ ! -f "$res" ] || [ "$rc" -nt "$res" ]; then
    (cd "$ROOTU/Resources" && "$BDS\\bin\\brcc32.exe" -fo"$(basename "$res")" "$(basename "$rc")" >/dev/null) || exit 1
  fi
done
cd "$ROOTU/DemoFMX" || exit 1
if [ ! -f Demo.Styles.res ] || [ Demo.Styles.rc -nt Demo.Styles.res ] || [ Styles/Dark.style -nt Demo.Styles.res ]; then
  "$BDS\\bin\\brcc32.exe" -foDemo.Styles.res Demo.Styles.rc >/dev/null || exit 1
fi
if [ ! -f PdfViewerDemo.res ]; then
  printf '1 RCDATA { "PdfViewerDemo" }\n' > PdfViewerDemo.rc
  "$BDS\\bin\\brcc32.exe" -foPdfViewerDemo.res PdfViewerDemo.rc >/dev/null && rm -f PdfViewerDemo.rc
fi
"$BDS\\bin\\dcc64.exe" -B -Q -H \
  -U"$BDS\\lib\\win64\\release;$ROOT\\Source\\Core;$ROOT\\Source\\Render;$ROOT\\Source\\Font;$ROOT\\Source\\Viewer" \
  -R"$ROOT\\Resources" "-NSSystem;System.Win;Winapi;Data;Xml;FMX" \
  -E"$OUT" -N0"$OUT\\demo_dcu" -NH"$OUT\\demo_dcu" PdfViewerDemo.dpr
