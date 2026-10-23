# Resources

- `Fonts/`: substitutes for the standard 14 fonts, taken from pdf.js:
  Liberation Sans (SIL Open Font License, `LICENSE_LIBERATION`) for Helvetica/Arial,
  and the Foxit Type1 fonts (BSD, `LICENSE_FOXIT`) for Times (FoxitSerif), Courier (FoxitFixed),
  Symbol and ZapfDingbats.
- `CMaps/`: the predefined CJK CMaps in pdf.js's compact binary format (Adobe, BSD, `LICENSE`).
- `*.rc` files list these as RCDATA resources; `Build/dcc.sh` and the dproj files compile them to `*.res`
  (generated, not committed).
