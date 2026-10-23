{*******************************************************************************
  Pdf.Codec.CCITT
  CCITT Group 3 (1D MH and mixed 1D/2D) and Group 4 fax decoder for the
  CCITTFaxDecode filter (ISO 32000-1 7.4.6, ITU-T T.4 / T.6).
  Portions derived from pdf.js (Mozilla, Apache License 2.0), which in turn is
  a port of the Xpdf implementation (Glyph & Cog, LLC, Apache License 2.0).
*******************************************************************************}
unit Pdf.Codec.CCITT;

interface

uses
  System.SysUtils, Pdf.Core.Types;

type
  /// <summary>Decode parameters of the CCITTFaxDecode filter (the /DecodeParms entries).</summary>
  TPdfCCITTParams = record
    /// <summary>Coding scheme: &lt; 0 pure 2D (Group 4), 0 pure 1D (Group 3 MH), &gt; 0 mixed 1D/2D (Group 3 2D).</summary>
    K: Integer;
    /// <summary>Pixels per row; values &lt;= 0 mean the default 1728.</summary>
    Columns: Integer;
    /// <summary>Number of rows; 0 = unknown: decode until EOFB/RTC or the end of the data. When &gt; 0 the
    /// output is limited to this many rows.</summary>
    Rows: Integer;
    /// <summary>False (default): 0 bits are black in the output. True: 1 bits are black.</summary>
    BlackIs1: Boolean;
    /// <summary>EncodedByteAlign: each encoded row (K &lt; 0) or each EOL (K &gt;= 0, fill bits so that the EOL
    /// ends on a byte boundary) is byte aligned.</summary>
    ByteAlign: Boolean;
    /// <summary>EndOfLine: EOL codes are required (they are skipped when present regardless); enables
    /// resynchronisation on the next EOL after a damaged row.</summary>
    EndOfLine: Boolean;
    /// <summary>EndOfBlock: the data ends with an EOFB/RTC marker (default True). When False, decoding stops
    /// after Rows rows.</summary>
    EndOfBlock: Boolean;
    /// <summary>DamagedRowsBeforeError: accepted for completeness, ignored like pdf.js does (damaged rows are
    /// always tolerated).</summary>
    DamagedRowsBeforeError: Integer;
    /// <summary>The PDF defaults: K = 0, Columns = 1728, Rows = 0, EndOfBlock = True, all other flags False.</summary>
    class function Default: TPdfCCITTParams; static;
    /// <summary>Fills the record from the values of a /DecodeParms dictionary (the caller reads the dictionary
    /// and passes the PDF defaults for missing entries).</summary>
    class function Make(K, Columns, Rows: Integer; BlackIs1, ByteAlign, EndOfLine, EndOfBlock: Boolean;
      DamagedRowsBeforeError: Integer = 0): TPdfCCITTParams; static;
  end;

/// <summary>Decodes CCITT fax data to packed 1-bit rows (stride (Columns + 7) div 8, MSB first), exactly like
/// the PDF CCITTFaxDecode filter output: with BlackIs1 = False (default) 0 bits are black, with BlackIs1 = True
/// 1 bits are black. Padding bits at the end of each row are 0 (1 with BlackIs1), as in pdf.js. Rows receives
/// the number of rows produced (at most Params.Rows when that is &gt; 0). Corrupt or truncated data yields the
/// rows decoded so far, the last one completed with white; empty input yields nil with Rows = 0. Raises
/// EPdfFilterError only when the input is non-empty and not a single row could be decoded (or Columns is
/// absurdly large).</summary>
function PdfCCITTDecode(const Data: TBytes; const Params: TPdfCCITTParams; out Rows: Integer): TBytes;

implementation

const
  /// <summary>Largest supported Columns value.</summary>
  MaxColumns = 1 shl 20;
  /// <summary>Upper bound for the decoded output (protects against garbage that decodes to millions of rows).</summary>
  MaxOutputBytes = 256 * 1024 * 1024;
  /// <summary>Accumulated run lengths are clamped to this value (garbage can chain many makeup codes).</summary>
  MaxRunLength = 1 shl 30;

  CcittEOL = -2;
  CcittEOF = -1;
  TwoDimPass = 0;
  TwoDimHoriz = 1;
  TwoDimVert0 = 2;
  TwoDimVertR1 = 3;
  TwoDimVertL1 = 4;
  TwoDimVertR2 = 5;
  TwoDimVertL2 = 6;
  TwoDimVertR3 = 7;
  TwoDimVertL3 = 8;

type
  /// <summary>Lookahead table entry: (number of bits of the code, decoded value); bits &lt;= 0 = no code.</summary>
  TCCITTEntry = array[0..1] of SmallInt;

const
  // The pdf.js/Xpdf lookahead tables, indexed by the next input bits: TwoDimTable by 7 bits; WhiteTable1 by
  // 12 bits starting with 0000000; WhiteTable2 by 9 bits; BlackTable1 by 13 bits starting with 0000000;
  // BlackTable2 by 12 bits minus 64 (0000 01xx xxxx .. 0000 11xx xxxx); BlackTable3 by 6 bits.
  // CcittEOL (-2) marks the EOL code 0000 0000 0001 in the white and black tables.
  TwoDimTable: array[0..127] of TCCITTEntry = (
    (-1, -1), (-1, -1), (7, 8), (7, 7), (6, 6), (6, 6), (6, 5), (6, 5),
    (4, 0), (4, 0), (4, 0), (4, 0), (4, 0), (4, 0), (4, 0), (4, 0),
    (3, 1), (3, 1), (3, 1), (3, 1), (3, 1), (3, 1), (3, 1), (3, 1),
    (3, 1), (3, 1), (3, 1), (3, 1), (3, 1), (3, 1), (3, 1), (3, 1),
    (3, 4), (3, 4), (3, 4), (3, 4), (3, 4), (3, 4), (3, 4), (3, 4),
    (3, 4), (3, 4), (3, 4), (3, 4), (3, 4), (3, 4), (3, 4), (3, 4),
    (3, 3), (3, 3), (3, 3), (3, 3), (3, 3), (3, 3), (3, 3), (3, 3),
    (3, 3), (3, 3), (3, 3), (3, 3), (3, 3), (3, 3), (3, 3), (3, 3),
    (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2),
    (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2),
    (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2),
    (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2),
    (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2),
    (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2),
    (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2),
    (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2), (1, 2)
  );

  WhiteTable1: array[0..31] of TCCITTEntry = (
    (-1, -1), (12, CcittEOL), (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1),
    (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1),
    (11, 1792), (11, 1792), (12, 1984), (12, 2048), (12, 2112), (12, 2176), (12, 2240), (12, 2304),
    (11, 1856), (11, 1856), (11, 1920), (11, 1920), (12, 2368), (12, 2432), (12, 2496), (12, 2560)
  );

  WhiteTable2: array[0..511] of TCCITTEntry = (
    (-1, -1), (-1, -1), (-1, -1), (-1, -1), (8, 29), (8, 29), (8, 30), (8, 30),
    (8, 45), (8, 45), (8, 46), (8, 46), (7, 22), (7, 22), (7, 22), (7, 22),
    (7, 23), (7, 23), (7, 23), (7, 23), (8, 47), (8, 47), (8, 48), (8, 48),
    (6, 13), (6, 13), (6, 13), (6, 13), (6, 13), (6, 13), (6, 13), (6, 13),
    (7, 20), (7, 20), (7, 20), (7, 20), (8, 33), (8, 33), (8, 34), (8, 34),
    (8, 35), (8, 35), (8, 36), (8, 36), (8, 37), (8, 37), (8, 38), (8, 38),
    (7, 19), (7, 19), (7, 19), (7, 19), (8, 31), (8, 31), (8, 32), (8, 32),
    (6, 1), (6, 1), (6, 1), (6, 1), (6, 1), (6, 1), (6, 1), (6, 1),
    (6, 12), (6, 12), (6, 12), (6, 12), (6, 12), (6, 12), (6, 12), (6, 12),
    (8, 53), (8, 53), (8, 54), (8, 54), (7, 26), (7, 26), (7, 26), (7, 26),
    (8, 39), (8, 39), (8, 40), (8, 40), (8, 41), (8, 41), (8, 42), (8, 42),
    (8, 43), (8, 43), (8, 44), (8, 44), (7, 21), (7, 21), (7, 21), (7, 21),
    (7, 28), (7, 28), (7, 28), (7, 28), (8, 61), (8, 61), (8, 62), (8, 62),
    (8, 63), (8, 63), (8, 0), (8, 0), (8, 320), (8, 320), (8, 384), (8, 384),
    (5, 10), (5, 10), (5, 10), (5, 10), (5, 10), (5, 10), (5, 10), (5, 10),
    (5, 10), (5, 10), (5, 10), (5, 10), (5, 10), (5, 10), (5, 10), (5, 10),
    (5, 11), (5, 11), (5, 11), (5, 11), (5, 11), (5, 11), (5, 11), (5, 11),
    (5, 11), (5, 11), (5, 11), (5, 11), (5, 11), (5, 11), (5, 11), (5, 11),
    (7, 27), (7, 27), (7, 27), (7, 27), (8, 59), (8, 59), (8, 60), (8, 60),
    (9, 1472), (9, 1536), (9, 1600), (9, 1728), (7, 18), (7, 18), (7, 18), (7, 18),
    (7, 24), (7, 24), (7, 24), (7, 24), (8, 49), (8, 49), (8, 50), (8, 50),
    (8, 51), (8, 51), (8, 52), (8, 52), (7, 25), (7, 25), (7, 25), (7, 25),
    (8, 55), (8, 55), (8, 56), (8, 56), (8, 57), (8, 57), (8, 58), (8, 58),
    (6, 192), (6, 192), (6, 192), (6, 192), (6, 192), (6, 192), (6, 192), (6, 192),
    (6, 1664), (6, 1664), (6, 1664), (6, 1664), (6, 1664), (6, 1664), (6, 1664), (6, 1664),
    (8, 448), (8, 448), (8, 512), (8, 512), (9, 704), (9, 768), (8, 640), (8, 640),
    (8, 576), (8, 576), (9, 832), (9, 896), (9, 960), (9, 1024), (9, 1088), (9, 1152),
    (9, 1216), (9, 1280), (9, 1344), (9, 1408), (7, 256), (7, 256), (7, 256), (7, 256),
    (4, 2), (4, 2), (4, 2), (4, 2), (4, 2), (4, 2), (4, 2), (4, 2),
    (4, 2), (4, 2), (4, 2), (4, 2), (4, 2), (4, 2), (4, 2), (4, 2),
    (4, 2), (4, 2), (4, 2), (4, 2), (4, 2), (4, 2), (4, 2), (4, 2),
    (4, 2), (4, 2), (4, 2), (4, 2), (4, 2), (4, 2), (4, 2), (4, 2),
    (4, 3), (4, 3), (4, 3), (4, 3), (4, 3), (4, 3), (4, 3), (4, 3),
    (4, 3), (4, 3), (4, 3), (4, 3), (4, 3), (4, 3), (4, 3), (4, 3),
    (4, 3), (4, 3), (4, 3), (4, 3), (4, 3), (4, 3), (4, 3), (4, 3),
    (4, 3), (4, 3), (4, 3), (4, 3), (4, 3), (4, 3), (4, 3), (4, 3),
    (5, 128), (5, 128), (5, 128), (5, 128), (5, 128), (5, 128), (5, 128), (5, 128),
    (5, 128), (5, 128), (5, 128), (5, 128), (5, 128), (5, 128), (5, 128), (5, 128),
    (5, 8), (5, 8), (5, 8), (5, 8), (5, 8), (5, 8), (5, 8), (5, 8),
    (5, 8), (5, 8), (5, 8), (5, 8), (5, 8), (5, 8), (5, 8), (5, 8),
    (5, 9), (5, 9), (5, 9), (5, 9), (5, 9), (5, 9), (5, 9), (5, 9),
    (5, 9), (5, 9), (5, 9), (5, 9), (5, 9), (5, 9), (5, 9), (5, 9),
    (6, 16), (6, 16), (6, 16), (6, 16), (6, 16), (6, 16), (6, 16), (6, 16),
    (6, 17), (6, 17), (6, 17), (6, 17), (6, 17), (6, 17), (6, 17), (6, 17),
    (4, 4), (4, 4), (4, 4), (4, 4), (4, 4), (4, 4), (4, 4), (4, 4),
    (4, 4), (4, 4), (4, 4), (4, 4), (4, 4), (4, 4), (4, 4), (4, 4),
    (4, 4), (4, 4), (4, 4), (4, 4), (4, 4), (4, 4), (4, 4), (4, 4),
    (4, 4), (4, 4), (4, 4), (4, 4), (4, 4), (4, 4), (4, 4), (4, 4),
    (4, 5), (4, 5), (4, 5), (4, 5), (4, 5), (4, 5), (4, 5), (4, 5),
    (4, 5), (4, 5), (4, 5), (4, 5), (4, 5), (4, 5), (4, 5), (4, 5),
    (4, 5), (4, 5), (4, 5), (4, 5), (4, 5), (4, 5), (4, 5), (4, 5),
    (4, 5), (4, 5), (4, 5), (4, 5), (4, 5), (4, 5), (4, 5), (4, 5),
    (6, 14), (6, 14), (6, 14), (6, 14), (6, 14), (6, 14), (6, 14), (6, 14),
    (6, 15), (6, 15), (6, 15), (6, 15), (6, 15), (6, 15), (6, 15), (6, 15),
    (5, 64), (5, 64), (5, 64), (5, 64), (5, 64), (5, 64), (5, 64), (5, 64),
    (5, 64), (5, 64), (5, 64), (5, 64), (5, 64), (5, 64), (5, 64), (5, 64),
    (4, 6), (4, 6), (4, 6), (4, 6), (4, 6), (4, 6), (4, 6), (4, 6),
    (4, 6), (4, 6), (4, 6), (4, 6), (4, 6), (4, 6), (4, 6), (4, 6),
    (4, 6), (4, 6), (4, 6), (4, 6), (4, 6), (4, 6), (4, 6), (4, 6),
    (4, 6), (4, 6), (4, 6), (4, 6), (4, 6), (4, 6), (4, 6), (4, 6),
    (4, 7), (4, 7), (4, 7), (4, 7), (4, 7), (4, 7), (4, 7), (4, 7),
    (4, 7), (4, 7), (4, 7), (4, 7), (4, 7), (4, 7), (4, 7), (4, 7),
    (4, 7), (4, 7), (4, 7), (4, 7), (4, 7), (4, 7), (4, 7), (4, 7),
    (4, 7), (4, 7), (4, 7), (4, 7), (4, 7), (4, 7), (4, 7), (4, 7)
  );

  BlackTable1: array[0..127] of TCCITTEntry = (
    (-1, -1), (-1, -1), (12, CcittEOL), (12, CcittEOL), (-1, -1), (-1, -1), (-1, -1), (-1, -1),
    (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1),
    (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1),
    (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1), (-1, -1),
    (11, 1792), (11, 1792), (11, 1792), (11, 1792), (12, 1984), (12, 1984), (12, 2048), (12, 2048),
    (12, 2112), (12, 2112), (12, 2176), (12, 2176), (12, 2240), (12, 2240), (12, 2304), (12, 2304),
    (11, 1856), (11, 1856), (11, 1856), (11, 1856), (11, 1920), (11, 1920), (11, 1920), (11, 1920),
    (12, 2368), (12, 2368), (12, 2432), (12, 2432), (12, 2496), (12, 2496), (12, 2560), (12, 2560),
    (10, 18), (10, 18), (10, 18), (10, 18), (10, 18), (10, 18), (10, 18), (10, 18),
    (12, 52), (12, 52), (13, 640), (13, 704), (13, 768), (13, 832), (12, 55), (12, 55),
    (12, 56), (12, 56), (13, 1280), (13, 1344), (13, 1408), (13, 1472), (12, 59), (12, 59),
    (12, 60), (12, 60), (13, 1536), (13, 1600), (11, 24), (11, 24), (11, 24), (11, 24),
    (11, 25), (11, 25), (11, 25), (11, 25), (13, 1664), (13, 1728), (12, 320), (12, 320),
    (12, 384), (12, 384), (12, 448), (12, 448), (13, 512), (13, 576), (12, 53), (12, 53),
    (12, 54), (12, 54), (13, 896), (13, 960), (13, 1024), (13, 1088), (13, 1152), (13, 1216),
    (10, 64), (10, 64), (10, 64), (10, 64), (10, 64), (10, 64), (10, 64), (10, 64)
  );

  BlackTable2: array[0..191] of TCCITTEntry = (
    (8, 13), (8, 13), (8, 13), (8, 13), (8, 13), (8, 13), (8, 13), (8, 13),
    (8, 13), (8, 13), (8, 13), (8, 13), (8, 13), (8, 13), (8, 13), (8, 13),
    (11, 23), (11, 23), (12, 50), (12, 51), (12, 44), (12, 45), (12, 46), (12, 47),
    (12, 57), (12, 58), (12, 61), (12, 256), (10, 16), (10, 16), (10, 16), (10, 16),
    (10, 17), (10, 17), (10, 17), (10, 17), (12, 48), (12, 49), (12, 62), (12, 63),
    (12, 30), (12, 31), (12, 32), (12, 33), (12, 40), (12, 41), (11, 22), (11, 22),
    (8, 14), (8, 14), (8, 14), (8, 14), (8, 14), (8, 14), (8, 14), (8, 14),
    (8, 14), (8, 14), (8, 14), (8, 14), (8, 14), (8, 14), (8, 14), (8, 14),
    (7, 10), (7, 10), (7, 10), (7, 10), (7, 10), (7, 10), (7, 10), (7, 10),
    (7, 10), (7, 10), (7, 10), (7, 10), (7, 10), (7, 10), (7, 10), (7, 10),
    (7, 10), (7, 10), (7, 10), (7, 10), (7, 10), (7, 10), (7, 10), (7, 10),
    (7, 10), (7, 10), (7, 10), (7, 10), (7, 10), (7, 10), (7, 10), (7, 10),
    (7, 11), (7, 11), (7, 11), (7, 11), (7, 11), (7, 11), (7, 11), (7, 11),
    (7, 11), (7, 11), (7, 11), (7, 11), (7, 11), (7, 11), (7, 11), (7, 11),
    (7, 11), (7, 11), (7, 11), (7, 11), (7, 11), (7, 11), (7, 11), (7, 11),
    (7, 11), (7, 11), (7, 11), (7, 11), (7, 11), (7, 11), (7, 11), (7, 11),
    (9, 15), (9, 15), (9, 15), (9, 15), (9, 15), (9, 15), (9, 15), (9, 15),
    (12, 128), (12, 192), (12, 26), (12, 27), (12, 28), (12, 29), (11, 19), (11, 19),
    (11, 20), (11, 20), (12, 34), (12, 35), (12, 36), (12, 37), (12, 38), (12, 39),
    (11, 21), (11, 21), (12, 42), (12, 43), (10, 0), (10, 0), (10, 0), (10, 0),
    (7, 12), (7, 12), (7, 12), (7, 12), (7, 12), (7, 12), (7, 12), (7, 12),
    (7, 12), (7, 12), (7, 12), (7, 12), (7, 12), (7, 12), (7, 12), (7, 12),
    (7, 12), (7, 12), (7, 12), (7, 12), (7, 12), (7, 12), (7, 12), (7, 12),
    (7, 12), (7, 12), (7, 12), (7, 12), (7, 12), (7, 12), (7, 12), (7, 12)
  );

  BlackTable3: array[0..63] of TCCITTEntry = (
    (-1, -1), (-1, -1), (-1, -1), (-1, -1), (6, 9), (6, 8), (5, 7), (5, 7),
    (4, 6), (4, 6), (4, 6), (4, 6), (4, 5), (4, 5), (4, 5), (4, 5),
    (3, 1), (3, 1), (3, 1), (3, 1), (3, 1), (3, 1), (3, 1), (3, 1),
    (3, 4), (3, 4), (3, 4), (3, 4), (3, 4), (3, 4), (3, 4), (3, 4),
    (2, 3), (2, 3), (2, 3), (2, 3), (2, 3), (2, 3), (2, 3), (2, 3),
    (2, 3), (2, 3), (2, 3), (2, 3), (2, 3), (2, 3), (2, 3), (2, 3),
    (2, 2), (2, 2), (2, 2), (2, 2), (2, 2), (2, 2), (2, 2), (2, 2),
    (2, 2), (2, 2), (2, 2), (2, 2), (2, 2), (2, 2), (2, 2), (2, 2)
  );


type
  /// <summary>Bit reader state, kept as a record so a speculative lookahead can be undone.</summary>
  TCCITTBitState = record
    Pos: Integer;
    Buf: Cardinal;
    Bits: Integer;
  end;

  /// <summary>Port of the pdf.js CCITTFaxDecoder; ReadRow decodes one row into the changing-elements list.</summary>
  TCCITTDecoder = class
  private
    FData: TBytes;
    FLen: Integer;
    FState: TCCITTBitState;
    FEncoding: Integer;
    FEoline: Boolean;
    FByteAlign: Boolean;
    FEoblock: Boolean;
    FColumns: Integer;
    FRows: Integer;
    /// <summary>Changing elements of the current row: run i ends at FCodingLine[i]; even runs are white.</summary>
    FCodingLine: TArray<Integer>;
    /// <summary>Changing elements of the reference (previous) row, terminated by two Columns entries.</summary>
    FRefLine: TArray<Integer>;
    FRefLen: Integer;
    FCodingPos: Integer;
    FRow: Integer;
    FNextLine2D: Boolean;
    FEof: Boolean;
    FRowsDone: Boolean;
    FErr: Boolean;
    FSeenEOL: Boolean;
    /// <summary>Set when a run-length code lookup ran into the end of the data.</summary>
    FHitEOF: Boolean;
    function LookBits(N: Integer): Integer;
    procedure EatBits(N: Integer); inline;
    function BitPos: Int64; inline;
    procedure AddPixels(A1, BlackPixels: Integer);
    procedure AddPixelsNeg(A1, BlackPixels: Integer);
    procedure SkipRef(var RefPos: Integer); inline;
    function FindTableCode(StartBits, EndBits: Integer; const Table: array of TCCITTEntry; Limit: Integer;
      out Value: Integer; out Ate: Boolean): Boolean;
    function GetTwoDimCode: Integer;
    function GetWhiteCode: Integer;
    function GetBlackCode: Integer;
    function GetRun(Black: Boolean): Integer;
    procedure DecodeRow2D;
    procedure DecodeRow1D;
    function AllowUnalignedEOL: Boolean;
  public
    constructor Create(const Data: TBytes; const Params: TPdfCCITTParams; Columns: Integer);
    /// <summary>Decodes the next row; False at the end of the data (nothing produced).</summary>
    function ReadRow: Boolean;
    /// <summary>Writes the current row as packed bits: white runs 1, black runs 0, padding 0; all bits
    /// inverted when Invert (BlackIs1).</summary>
    procedure WriteRow(Dest: PByte; Stride: Integer; Invert: Boolean);
  end;

{ TPdfCCITTParams }

class function TPdfCCITTParams.Default: TPdfCCITTParams;
begin
  Result.K := 0;
  Result.Columns := 1728;
  Result.Rows := 0;
  Result.BlackIs1 := False;
  Result.ByteAlign := False;
  Result.EndOfLine := False;
  Result.EndOfBlock := True;
  Result.DamagedRowsBeforeError := 0;
end;

class function TPdfCCITTParams.Make(K, Columns, Rows: Integer; BlackIs1, ByteAlign, EndOfLine, EndOfBlock: Boolean;
  DamagedRowsBeforeError: Integer): TPdfCCITTParams;
begin
  Result.K := K;
  Result.Columns := Columns;
  Result.Rows := Rows;
  Result.BlackIs1 := BlackIs1;
  Result.ByteAlign := ByteAlign;
  Result.EndOfLine := EndOfLine;
  Result.EndOfBlock := EndOfBlock;
  Result.DamagedRowsBeforeError := DamagedRowsBeforeError;
end;

{ TCCITTDecoder }

constructor TCCITTDecoder.Create(const Data: TBytes; const Params: TPdfCCITTParams; Columns: Integer);
var
  Code1: Integer;
begin
  inherited Create;
  FData := Data;
  FLen := Length(Data);
  FEncoding := Params.K;
  FEoline := Params.EndOfLine;
  FByteAlign := Params.ByteAlign;
  FEoblock := Params.EndOfBlock;
  FColumns := Columns;
  FRows := Params.Rows;
  if FRows < 0 then
    FRows := 0;
  SetLength(FCodingLine, FColumns + 1);
  FRefLen := FColumns + 2;
  SetLength(FRefLine, FRefLen);
  FCodingLine[0] := FColumns;
  FCodingPos := 0;
  FRow := 0;
  FNextLine2D := FEncoding < 0;

  // Skip leading fill bits and an initial EOL.
  Code1 := LookBits(12);
  while Code1 = 0 do
  begin
    EatBits(1);
    Code1 := LookBits(12);
  end;
  if Code1 = 1 then
  begin
    EatBits(12);
    FSeenEOL := True;
  end;
  if FEncoding > 0 then
  begin
    FNextLine2D := LookBits(1) = 0;
    EatBits(1);
  end;
end;

function TCCITTDecoder.LookBits(N: Integer): Integer;
begin
  while FState.Bits < N do
  begin
    if FState.Pos >= FLen then
    begin
      if FState.Bits = 0 then
        Exit(CcittEOF);
      // Fewer than N bits left: pad with zero bits (like pdf.js).
      Exit(Integer((FState.Buf shl (N - FState.Bits)) and (Cardinal($FFFF) shr (16 - N))));
    end;
    FState.Buf := ((FState.Buf shl 8) or FData[FState.Pos]) and $FFFFFF;
    Inc(FState.Pos);
    Inc(FState.Bits, 8);
  end;
  Result := Integer((FState.Buf shr (FState.Bits - N)) and (Cardinal($FFFF) shr (16 - N)));
end;

procedure TCCITTDecoder.EatBits(N: Integer);
begin
  Dec(FState.Bits, N);
  if FState.Bits < 0 then
    FState.Bits := 0;
end;

function TCCITTDecoder.BitPos: Int64;
begin
  Result := Int64(FState.Pos) * 8 - FState.Bits;
end;

procedure TCCITTDecoder.AddPixels(A1, BlackPixels: Integer);
var
  CodingPos: Integer;
begin
  CodingPos := FCodingPos;
  if A1 > FCodingLine[CodingPos] then
  begin
    if A1 > FColumns then
    begin
      // Row too long.
      FErr := True;
      A1 := FColumns;
    end;
    if ((CodingPos and 1) xor BlackPixels) <> 0 then
      Inc(CodingPos);
    if CodingPos > FColumns then
    begin
      // More changing elements than pixels (garbage only; pdf.js writes past its array here): end the row.
      FErr := True;
      CodingPos := FColumns;
      A1 := FColumns;
    end;
    FCodingLine[CodingPos] := A1;
  end;
  FCodingPos := CodingPos;
end;

procedure TCCITTDecoder.AddPixelsNeg(A1, BlackPixels: Integer);
var
  CodingPos: Integer;
begin
  CodingPos := FCodingPos;
  if A1 > FCodingLine[CodingPos] then
  begin
    if A1 > FColumns then
    begin
      FErr := True;
      A1 := FColumns;
    end;
    if ((CodingPos and 1) xor BlackPixels) <> 0 then
      Inc(CodingPos);
    if CodingPos > FColumns then
    begin
      FErr := True;
      CodingPos := FColumns;
      A1 := FColumns;
    end;
    FCodingLine[CodingPos] := A1;
  end
  else if A1 < FCodingLine[CodingPos] then
  begin
    if A1 < 0 then
    begin
      // Invalid code: a changing element left of the row start.
      FErr := True;
      A1 := 0;
    end;
    while (CodingPos > 0) and (A1 < FCodingLine[CodingPos - 1]) do
      Dec(CodingPos);
    FCodingLine[CodingPos] := A1;
  end;
  FCodingPos := CodingPos;
end;

procedure TCCITTDecoder.SkipRef(var RefPos: Integer);
var
  Cur: Integer;
begin
  Cur := FCodingLine[FCodingPos];
  while (RefPos < FRefLen) and (FRefLine[RefPos] <= Cur) and (FRefLine[RefPos] < FColumns) do
    Inc(RefPos, 2);
end;

function TCCITTDecoder.FindTableCode(StartBits, EndBits: Integer; const Table: array of TCCITTEntry;
  Limit: Integer; out Value: Integer; out Ate: Boolean): Boolean;
var
  I, Code, Index: Integer;
begin
  for I := StartBits to EndBits do
  begin
    Code := LookBits(I);
    if Code = CcittEOF then
    begin
      FHitEOF := True;
      Value := 1;
      Ate := False;
      Exit(True);
    end;
    if I < EndBits then
      Code := Code shl (EndBits - I);
    if (Limit = 0) or (Code >= Limit) then
    begin
      Index := Code - Limit;
      // pdf.js would throw on an index past the table; treat it as "no code of this length".
      if (Index >= 0) and (Index < Length(Table)) and (Table[Index][0] = I) then
      begin
        EatBits(I);
        Value := Table[Index][1];
        Ate := True;
        Exit(True);
      end;
    end;
  end;
  Value := 0;
  Ate := False;
  Result := False;
end;

function TCCITTDecoder.GetTwoDimCode: Integer;
var
  Code, Value: Integer;
  Ate: Boolean;
begin
  if FEoblock then
  begin
    Code := LookBits(7);
    if (Code >= 0) and (TwoDimTable[Code][0] > 0) then
    begin
      EatBits(TwoDimTable[Code][0]);
      Exit(TwoDimTable[Code][1]);
    end;
  end
  else if FindTableCode(1, 7, TwoDimTable, 0, Value, Ate) and Ate then
    Exit(Value);
  // Bad two-dimensional code (or the end of the data).
  Result := CcittEOF;
end;

function TCCITTDecoder.GetWhiteCode: Integer;
var
  Code, Value: Integer;
  Ate: Boolean;
  P: TCCITTEntry;
begin
  if FEoblock then
  begin
    Code := LookBits(12);
    if Code = CcittEOF then
    begin
      FHitEOF := True;
      Exit(1);
    end;
    if Code shr 5 = 0 then
      P := WhiteTable1[Code]
    else
      P := WhiteTable2[Code shr 3];
    if P[0] > 0 then
    begin
      EatBits(P[0]);
      Exit(P[1]);
    end;
  end
  else
  begin
    if FindTableCode(1, 9, WhiteTable2, 0, Value, Ate) then
      Exit(Value);
    if FindTableCode(11, 12, WhiteTable1, 0, Value, Ate) then
      Exit(Value);
  end;
  // Bad white code: skip one bit.
  EatBits(1);
  Result := 1;
end;

function TCCITTDecoder.GetBlackCode: Integer;
var
  Code, Value: Integer;
  Ate: Boolean;
  P: TCCITTEntry;
begin
  if FEoblock then
  begin
    Code := LookBits(13);
    if Code = CcittEOF then
    begin
      FHitEOF := True;
      Exit(1);
    end;
    if Code shr 7 = 0 then
      P := BlackTable1[Code]
    else if Code shr 9 = 0 then
      P := BlackTable2[(Code shr 1) - 64]
    else
      P := BlackTable3[Code shr 7];
    if P[0] > 0 then
    begin
      EatBits(P[0]);
      Exit(P[1]);
    end;
  end
  else
  begin
    if FindTableCode(2, 6, BlackTable3, 0, Value, Ate) then
      Exit(Value);
    if FindTableCode(7, 12, BlackTable2, 64, Value, Ate) then
      Exit(Value);
    if FindTableCode(10, 13, BlackTable1, 0, Value, Ate) then
      Exit(Value);
  end;
  // Bad black code: skip one bit.
  EatBits(1);
  Result := 1;
end;

function TCCITTDecoder.GetRun(Black: Boolean): Integer;
var
  Code: Integer;
begin
  // Makeup codes (>= 64) are followed by more codes of the same colour.
  Result := 0;
  repeat
    if Black then
      Code := GetBlackCode
    else
      Code := GetWhiteCode;
    Inc(Result, Code);
    if Result > MaxRunLength then
      Result := MaxRunLength;
  until Code < 64;
end;

procedure TCCITTDecoder.DecodeRow2D;
var
  I, RefPos, BlackPixels, Code1, Code2: Integer;
begin
  I := 0;
  while FCodingLine[I] < FColumns do
  begin
    FRefLine[I] := FCodingLine[I];
    Inc(I);
  end;
  FRefLine[I] := FColumns;
  Inc(I);
  FRefLine[I] := FColumns;
  FCodingLine[0] := 0;
  FCodingPos := 0;
  RefPos := 0;
  BlackPixels := 0;

  while FCodingLine[FCodingPos] < FColumns do
  begin
    Code1 := GetTwoDimCode;
    case Code1 of
      TwoDimPass:
        if RefPos + 1 < FRefLen then
        begin
          AddPixels(FRefLine[RefPos + 1], BlackPixels);
          if FRefLine[RefPos + 1] < FColumns then
            Inc(RefPos, 2);
        end;
      TwoDimHoriz:
        begin
          FHitEOF := False;
          if BlackPixels <> 0 then
          begin
            Code1 := GetRun(True);
            Code2 := GetRun(False);
          end
          else
          begin
            Code1 := GetRun(False);
            Code2 := GetRun(True);
          end;
          if FHitEOF then
          begin
            // Truncated data: complete the row with white.
            AddPixels(FColumns, 0);
            FEof := True;
            Break;
          end;
          AddPixels(FCodingLine[FCodingPos] + Code1, BlackPixels);
          if FCodingLine[FCodingPos] < FColumns then
            AddPixels(FCodingLine[FCodingPos] + Code2, BlackPixels xor 1);
          SkipRef(RefPos);
        end;
      TwoDimVert0, TwoDimVertR1, TwoDimVertR2, TwoDimVertR3:
        begin
          // Out-of-range reference positions are a no-op, like the undefined reads in pdf.js.
          if RefPos < FRefLen then
            case Code1 of
              TwoDimVert0: AddPixels(FRefLine[RefPos], BlackPixels);
              TwoDimVertR1: AddPixels(FRefLine[RefPos] + 1, BlackPixels);
              TwoDimVertR2: AddPixels(FRefLine[RefPos] + 2, BlackPixels);
            else
              AddPixels(FRefLine[RefPos] + 3, BlackPixels);
            end;
          BlackPixels := BlackPixels xor 1;
          if FCodingLine[FCodingPos] < FColumns then
          begin
            Inc(RefPos);
            SkipRef(RefPos);
          end;
        end;
      TwoDimVertL1, TwoDimVertL2, TwoDimVertL3:
        begin
          if RefPos < FRefLen then
            case Code1 of
              TwoDimVertL1: AddPixelsNeg(FRefLine[RefPos] - 1, BlackPixels);
              TwoDimVertL2: AddPixelsNeg(FRefLine[RefPos] - 2, BlackPixels);
            else
              AddPixelsNeg(FRefLine[RefPos] - 3, BlackPixels);
            end;
          BlackPixels := BlackPixels xor 1;
          if FCodingLine[FCodingPos] < FColumns then
          begin
            if RefPos > 0 then
              Dec(RefPos)
            else
              Inc(RefPos);
            SkipRef(RefPos);
          end;
        end;
      CcittEOF:
        begin
          AddPixels(FColumns, 0);
          FEof := True;
        end;
    else
      AddPixels(FColumns, 0);
      FErr := True;
    end;
  end;
end;

procedure TCCITTDecoder.DecodeRow1D;
var
  BlackPixels, Code1: Integer;
begin
  FCodingLine[0] := 0;
  FCodingPos := 0;
  BlackPixels := 0;
  while FCodingLine[FCodingPos] < FColumns do
  begin
    FHitEOF := False;
    Code1 := GetRun(BlackPixels <> 0);
    if FHitEOF then
    begin
      // Truncated data: complete the row with white (pdf.js would emit 1-pixel runs here).
      AddPixels(FColumns, 0);
      FEof := True;
      Break;
    end;
    AddPixels(FCodingLine[FCodingPos] + Code1, BlackPixels);
    BlackPixels := BlackPixels xor 1;
  end;
end;

function TCCITTDecoder.AllowUnalignedEOL: Boolean;
begin
  // With EncodedByteAlign an EOL may end on a byte boundary (fill bits before it) instead of starting on one.
  // Only a 1D row starting with a white makeup code >= 1792 (0000 0001 ...) can fake such an EOL, so for K = 0
  // without any EOL seen so far this is only trusted when such runs are impossible.
  Result := (FEncoding <> 0) or FEoline or FSeenEOL or (FColumns < 1792);
end;

function TCCITTDecoder.ReadRow: Boolean;
var
  I, Code1: Integer;
  StartBit: Int64;
  GotEOL: Boolean;
  Unaligned, Saved: TCCITTBitState;
begin
  if FRowsDone then
    FEof := True;
  if FEof then
    Exit(False);
  FErr := False;
  StartBit := BitPos;

  if FNextLine2D then
    DecodeRow2D
  else
    DecodeRow1D;

  if BitPos = StartBit then
  begin
    // Nothing consumed: the data ended (or a bad code at the row start); do not emit a fake row.
    FEof := True;
    Exit(False);
  end;

  GotEOL := False;
  Unaligned := FState;
  if FByteAlign then
    FState.Bits := FState.Bits and not 7;

  if not FEoblock and (FRow = FRows - 1) then
    FRowsDone := True
  else
  begin
    if FByteAlign and AllowUnalignedEOL then
    begin
      // An EOL that ends on a byte boundary: fill bits before the EOL (EncodedByteAlign with K >= 0).
      Saved := FState;
      FState := Unaligned;
      while LookBits(12) = 0 do
        EatBits(1);
      if (LookBits(12) = 1) and (((BitPos + 12) and 7) = 0) then
      begin
        EatBits(12);
        GotEOL := True;
      end
      else
        FState := Saved;
    end;
    if not GotEOL then
    begin
      Code1 := LookBits(12);
      if FEoline then
      begin
        while (Code1 <> CcittEOF) and (Code1 <> 1) do
        begin
          EatBits(1);
          Code1 := LookBits(12);
        end;
      end
      else
      begin
        while Code1 = 0 do
        begin
          EatBits(1);
          Code1 := LookBits(12);
        end;
      end;
      if Code1 = 1 then
      begin
        EatBits(12);
        GotEOL := True;
      end
      else if Code1 = CcittEOF then
        FEof := True;
    end;
  end;
  if GotEOL then
    FSeenEOL := True;

  if not FEof and (FEncoding > 0) and not FRowsDone then
  begin
    FNextLine2D := LookBits(1) = 0;
    EatBits(1);
  end;

  if FEoblock and GotEOL then
  begin
    // A second EOL means RTC (K >= 0) or EOFB (K < 0). pdf.js only checks this with EncodedByteAlign; like
    // Xpdf we always do, so the marker does not decode as a garbage row. Fill bits before it are tolerated.
    Saved := FState;
    while LookBits(12) = 0 do
      EatBits(1);
    if LookBits(12) = 1 then
    begin
      EatBits(12);
      if FEncoding > 0 then
        EatBits(1);
      if FEncoding >= 0 then
        for I := 0 to 3 do
        begin
          // Remaining EOLs of the RTC (not validated: the data ends here anyway).
          EatBits(12);
          if FEncoding > 0 then
            EatBits(1);
        end;
      FEof := True;
    end
    else
      FState := Saved;
  end
  else if FErr and FEoline then
  begin
    // Damaged row: resynchronise on the next EOL; like pdf.js the row is dropped when none follows.
    repeat
      Code1 := LookBits(13);
      if Code1 = CcittEOF then
      begin
        FEof := True;
        Exit(False);
      end;
      if Code1 shr 1 = 1 then
        Break;
      EatBits(1);
    until False;
    EatBits(12);
    if FEncoding > 0 then
    begin
      EatBits(1);
      FNextLine2D := (Code1 and 1) = 0;
    end;
  end;

  Inc(FRow);
  Result := True;
end;

/// <summary>Clears the bits of pixels [A, B) in a packed MSB-first row.</summary>
procedure ClearBits(Row: PByte; A, B: Integer);
var
  First, Last: Integer;
  MaskA, MaskB: Byte;
begin
  if A >= B then
    Exit;
  First := A shr 3;
  Last := (B - 1) shr 3;
  MaskA := Byte($FF shr (A and 7));
  MaskB := Byte($FF shl (7 - ((B - 1) and 7)));
  if First = Last then
    Row[First] := Row[First] and Byte(not (MaskA and MaskB))
  else
  begin
    Row[First] := Row[First] and Byte(not MaskA);
    if Last - First > 1 then
      FillChar(Row[First + 1], Last - First - 1, 0);
    Row[Last] := Row[Last] and Byte(not MaskB);
  end;
end;

procedure TCCITTDecoder.WriteRow(Dest: PByte; Stride: Integer; Invert: Boolean);
var
  I, Prev, X: Integer;
begin
  FillChar(Dest^, Stride, $FF);
  if FColumns and 7 <> 0 then
    Dest[Stride - 1] := Byte($FF shl (8 - (FColumns and 7)));
  // Run i covers [FCodingLine[i - 1], FCodingLine[i]); odd runs are black. The list ends at the first
  // element >= Columns (it is non-decreasing up to there).
  Prev := 0;
  I := 0;
  while I <= FColumns do
  begin
    X := FCodingLine[I];
    if X > FColumns then
      X := FColumns;
    if Odd(I) then
      ClearBits(Dest, Prev, X);
    if X >= FColumns then
      Break;
    if X > Prev then
      Prev := X;
    Inc(I);
  end;
  if Invert then
    for I := 0 to Stride - 1 do
      Dest[I] := Dest[I] xor $FF;
end;

function PdfCCITTDecode(const Data: TBytes; const Params: TPdfCCITTParams; out Rows: Integer): TBytes;
var
  Columns, Stride, MaxRows, Capacity: Integer;
  Decoder: TCCITTDecoder;
begin
  Rows := 0;
  Result := nil;
  if Length(Data) = 0 then
    Exit;
  Columns := Params.Columns;
  if Columns <= 0 then
    Columns := 1728;
  if Columns > MaxColumns then
    raise EPdfFilterError.CreateFmt('CCITTFaxDecode: Columns %d too large', [Columns]);
  Stride := (Columns + 7) div 8;
  MaxRows := MaxOutputBytes div Stride;
  if (Params.Rows > 0) and (Params.Rows < MaxRows) then
    MaxRows := Params.Rows;
  // Every row consumes at least one bit, which bounds the initial allocation.
  Capacity := MaxRows;
  if Int64(Capacity) > Int64(Length(Data)) * 8 + 1 then
    Capacity := Length(Data) * 8 + 1;
  if Capacity > 4096 then
    Capacity := 4096;
  SetLength(Result, Capacity * Stride);
  Decoder := TCCITTDecoder.Create(Data, Params, Columns);
  try
    while (Rows < MaxRows) and Decoder.ReadRow do
    begin
      if Rows >= Capacity then
      begin
        if Capacity > MaxRows div 2 then
          Capacity := MaxRows
        else
          Capacity := Capacity * 2;
        SetLength(Result, Capacity * Stride);
      end;
      Decoder.WriteRow(@Result[Rows * Stride], Stride, Params.BlackIs1);
      Inc(Rows);
    end;
  finally
    Decoder.Free;
  end;
  SetLength(Result, Rows * Stride);
  if Rows = 0 then
    raise EPdfFilterError.Create('CCITTFaxDecode: no row could be decoded');
end;

end.
