#!/bin/sh
# Usage: Build/dcc.sh <project.dpr> [extra dcc64 args]
# Compiles a project with Delphi 13 (Studio 37.0) dcc64 into Build/out (Win64).
# Resources/*.rc are compiled to .res first when missing or outdated.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'
BDS='C:\Program Files (x86)\Embarcadero\Studio\37.0'
ROOTU="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cygpath -w "$ROOTU")"
OUT="$ROOT\\Build\\out"
mkdir -p "$(cygpath -u "$OUT")"
for rc in "$ROOTU"/Resources/*.rc; do
  [ -f "$rc" ] || continue
  res="${rc%.rc}.res"
  if [ ! -f "$res" ] || [ "$rc" -nt "$res" ]; then
    (cd "$ROOTU/Resources" && "$BDS\\bin\\brcc32.exe" -fo"$(basename "$res")" "$(basename "$rc")" >/dev/null) || exit 1
  fi
done
DPR="$(cygpath -w "$1")"; shift
"$BDS\\bin\\dcc64.exe" -B -Q -H \
  -U"$BDS\\lib\\win64\\release;$BDS\\source\\DUnitX;$ROOT\\Source\\Core;$ROOT\\Source\\Render;$ROOT\\Source\\Font;$ROOT\\Source\\Viewer;$ROOT\\Tests" \
  -I"$BDS\\source\\DUnitX" -R"$ROOT\\Resources" \
  "-NSSystem;System.Win;Winapi;Data;Xml" \
  -E"$OUT" -N0"$OUT" -NH"$OUT" "$@" "$DPR"
