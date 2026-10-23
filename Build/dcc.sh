#!/bin/sh
# Usage: Build/dcc.sh <project.dpr> [extra dcc64 args]
# Compiles a project with Delphi 13 (Studio 37.0) dcc64 into Build/out (Win64).
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'
BDS='C:\Program Files (x86)\Embarcadero\Studio\37.0'
ROOT="$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")"
OUT="$ROOT\Build\out"
mkdir -p "$(cygpath -u "$OUT")"
DPR="$(cygpath -w "$1")"; shift
"$BDS\bin\dcc64.exe" -B -Q -H \
  -U"$BDS\lib\win64\release;$BDS\source\DUnitX;$ROOT\Source\Core;$ROOT\Source\Render;$ROOT\Tests" \
  -I"$BDS\source\DUnitX" \
  "-NSSystem;System.Win;Winapi;Data;Xml" \
  -E"$OUT" -N0"$OUT" -NH"$OUT" "$@" "$DPR"
