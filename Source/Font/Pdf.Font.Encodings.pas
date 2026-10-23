{*******************************************************************************
  Pdf.Font.Encodings
  The predefined simple font encodings (code -> glyph name).

  GENERATED FILE - DO NOT EDIT. Generated from the pdf.js sources (Mozilla
  Foundation, Apache License 2.0, see NOTICE) by Tools/gen_font_tables.js:
    node Tools/gen_font_tables.js <pdf.js>/src/core
*******************************************************************************}
unit Pdf.Font.Encodings;

interface

type
  /// <summary>Glyph name for each code 0..255 of a simple font encoding; '' means the code is unmapped.</summary>
  TPdfEncodingTable = array[0..255] of string;
  PPdfEncodingTable = ^TPdfEncodingTable;

/// <summary>Adobe StandardEncoding.</summary>
function PdfStandardEncoding: PPdfEncodingTable;
/// <summary>WinAnsiEncoding.</summary>
function PdfWinAnsiEncoding: PPdfEncodingTable;
/// <summary>MacRomanEncoding.</summary>
function PdfMacRomanEncoding: PPdfEncodingTable;
/// <summary>MacExpertEncoding.</summary>
function PdfMacExpertEncoding: PPdfEncodingTable;
/// <summary>Built-in encoding of the Symbol font.</summary>
function PdfSymbolEncoding: PPdfEncodingTable;
/// <summary>Built-in encoding of the ZapfDingbats font.</summary>
function PdfZapfDingbatsEncoding: PPdfEncodingTable;
/// <summary>Adobe ExpertEncoding.</summary>
function PdfExpertEncoding: PPdfEncodingTable;
/// <summary>The table for a PDF /Encoding or /BaseEncoding name: 'StandardEncoding', 'WinAnsiEncoding',
/// 'MacRomanEncoding' or 'MacExpertEncoding' (case-sensitive); nil for anything else.</summary>
function PdfEncodingByName(const Name: string): PPdfEncodingTable;
/// <summary>Code of a glyph name in StandardEncoding (used by the seac operator), -1 when absent.</summary>
function PdfStandardEncodingCode(const GlyphName: string): Integer;

implementation

uses
  System.SysUtils;

const
  /// <summary>Adobe StandardEncoding (PDF 32000-1 Annex D).</summary>
  StandardEncodingTable: TPdfEncodingTable = (
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 0..15
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 16..31
    'space', 'exclam', 'quotedbl', 'numbersign', 'dollar', 'percent', 'ampersand', 'quoteright', 'parenleft', 'parenright', 'asterisk', 'plus', 'comma',
    'hyphen', 'period', 'slash',  // 32..47
    'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'colon', 'semicolon', 'less', 'equal', 'greater', 'question',  // 48..63
    'at', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',  // 64..79
    'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'bracketleft', 'backslash', 'bracketright', 'asciicircum', 'underscore',  // 80..95
    'quoteleft', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o',  // 96..111
    'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'braceleft', 'bar', 'braceright', 'asciitilde', '',  // 112..127
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 128..143
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 144..159
    '', 'exclamdown', 'cent', 'sterling', 'fraction', 'yen', 'florin', 'section', 'currency', 'quotesingle', 'quotedblleft', 'guillemotleft', 'guilsinglleft',
    'guilsinglright', 'fi', 'fl',  // 160..175
    '', 'endash', 'dagger', 'daggerdbl', 'periodcentered', '', 'paragraph', 'bullet', 'quotesinglbase', 'quotedblbase', 'quotedblright', 'guillemotright',
    'ellipsis', 'perthousand', '', 'questiondown',  // 176..191
    '', 'grave', 'acute', 'circumflex', 'tilde', 'macron', 'breve', 'dotaccent', 'dieresis', '', 'ring', 'cedilla', '', 'hungarumlaut', 'ogonek', 'caron',  // 192..207
    'emdash', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 208..223
    '', 'AE', '', 'ordfeminine', '', '', '', '', 'Lslash', 'Oslash', 'OE', 'ordmasculine', '', '', '', '',  // 224..239
    '', 'ae', '', '', '', 'dotlessi', '', '', 'lslash', 'oslash', 'oe', 'germandbls', '', '', '', ''  // 240..255
  );

  /// <summary>WinAnsiEncoding (Windows code page 1252), as pdf.js fills it (bullet for the undefined codes from 127 up, space at 160, hyphen at 173).</summary>
  WinAnsiEncodingTable: TPdfEncodingTable = (
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 0..15
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 16..31
    'space', 'exclam', 'quotedbl', 'numbersign', 'dollar', 'percent', 'ampersand', 'quotesingle', 'parenleft', 'parenright', 'asterisk', 'plus', 'comma',
    'hyphen', 'period', 'slash',  // 32..47
    'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'colon', 'semicolon', 'less', 'equal', 'greater', 'question',  // 48..63
    'at', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',  // 64..79
    'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'bracketleft', 'backslash', 'bracketright', 'asciicircum', 'underscore',  // 80..95
    'grave', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o',  // 96..111
    'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'braceleft', 'bar', 'braceright', 'asciitilde', 'bullet',  // 112..127
    'Euro', 'bullet', 'quotesinglbase', 'florin', 'quotedblbase', 'ellipsis', 'dagger', 'daggerdbl', 'circumflex', 'perthousand', 'Scaron', 'guilsinglleft',
    'OE', 'bullet', 'Zcaron', 'bullet',  // 128..143
    'bullet', 'quoteleft', 'quoteright', 'quotedblleft', 'quotedblright', 'bullet', 'endash', 'emdash', 'tilde', 'trademark', 'scaron', 'guilsinglright', 'oe',
    'bullet', 'zcaron', 'Ydieresis',  // 144..159
    'space', 'exclamdown', 'cent', 'sterling', 'currency', 'yen', 'brokenbar', 'section', 'dieresis', 'copyright', 'ordfeminine', 'guillemotleft', 'logicalnot',
    'hyphen', 'registered', 'macron',  // 160..175
    'degree', 'plusminus', 'twosuperior', 'threesuperior', 'acute', 'mu', 'paragraph', 'periodcentered', 'cedilla', 'onesuperior', 'ordmasculine',
    'guillemotright', 'onequarter', 'onehalf', 'threequarters', 'questiondown',  // 176..191
    'Agrave', 'Aacute', 'Acircumflex', 'Atilde', 'Adieresis', 'Aring', 'AE', 'Ccedilla', 'Egrave', 'Eacute', 'Ecircumflex', 'Edieresis', 'Igrave', 'Iacute',
    'Icircumflex', 'Idieresis',  // 192..207
    'Eth', 'Ntilde', 'Ograve', 'Oacute', 'Ocircumflex', 'Otilde', 'Odieresis', 'multiply', 'Oslash', 'Ugrave', 'Uacute', 'Ucircumflex', 'Udieresis', 'Yacute',
    'Thorn', 'germandbls',  // 208..223
    'agrave', 'aacute', 'acircumflex', 'atilde', 'adieresis', 'aring', 'ae', 'ccedilla', 'egrave', 'eacute', 'ecircumflex', 'edieresis', 'igrave', 'iacute',
    'icircumflex', 'idieresis',  // 224..239
    'eth', 'ntilde', 'ograve', 'oacute', 'ocircumflex', 'otilde', 'odieresis', 'divide', 'oslash', 'ugrave', 'uacute', 'ucircumflex', 'udieresis', 'yacute',
    'thorn', 'ydieresis'  // 240..255
  );

  /// <summary>MacRomanEncoding (PDF 32000-1 Annex D, plus the Mac OS additions pdf.js uses).</summary>
  MacRomanEncodingTable: TPdfEncodingTable = (
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 0..15
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 16..31
    'space', 'exclam', 'quotedbl', 'numbersign', 'dollar', 'percent', 'ampersand', 'quotesingle', 'parenleft', 'parenright', 'asterisk', 'plus', 'comma',
    'hyphen', 'period', 'slash',  // 32..47
    'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'colon', 'semicolon', 'less', 'equal', 'greater', 'question',  // 48..63
    'at', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',  // 64..79
    'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'bracketleft', 'backslash', 'bracketright', 'asciicircum', 'underscore',  // 80..95
    'grave', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o',  // 96..111
    'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'braceleft', 'bar', 'braceright', 'asciitilde', '',  // 112..127
    'Adieresis', 'Aring', 'Ccedilla', 'Eacute', 'Ntilde', 'Odieresis', 'Udieresis', 'aacute', 'agrave', 'acircumflex', 'adieresis', 'atilde', 'aring',
    'ccedilla', 'eacute', 'egrave',  // 128..143
    'ecircumflex', 'edieresis', 'iacute', 'igrave', 'icircumflex', 'idieresis', 'ntilde', 'oacute', 'ograve', 'ocircumflex', 'odieresis', 'otilde', 'uacute',
    'ugrave', 'ucircumflex', 'udieresis',  // 144..159
    'dagger', 'degree', 'cent', 'sterling', 'section', 'bullet', 'paragraph', 'germandbls', 'registered', 'copyright', 'trademark', 'acute', 'dieresis',
    'notequal', 'AE', 'Oslash',  // 160..175
    'infinity', 'plusminus', 'lessequal', 'greaterequal', 'yen', 'mu', 'partialdiff', 'summation', 'product', 'pi', 'integral', 'ordfeminine', 'ordmasculine',
    'Omega', 'ae', 'oslash',  // 176..191
    'questiondown', 'exclamdown', 'logicalnot', 'radical', 'florin', 'approxequal', 'Delta', 'guillemotleft', 'guillemotright', 'ellipsis', 'space', 'Agrave',
    'Atilde', 'Otilde', 'OE', 'oe',  // 192..207
    'endash', 'emdash', 'quotedblleft', 'quotedblright', 'quoteleft', 'quoteright', 'divide', 'lozenge', 'ydieresis', 'Ydieresis', 'fraction', 'currency',
    'guilsinglleft', 'guilsinglright', 'fi', 'fl',  // 208..223
    'daggerdbl', 'periodcentered', 'quotesinglbase', 'quotedblbase', 'perthousand', 'Acircumflex', 'Ecircumflex', 'Aacute', 'Edieresis', 'Egrave', 'Iacute',
    'Icircumflex', 'Idieresis', 'Igrave', 'Oacute', 'Ocircumflex',  // 224..239
    'apple', 'Ograve', 'Uacute', 'Ucircumflex', 'Ugrave', 'dotlessi', 'circumflex', 'tilde', 'macron', 'breve', 'dotaccent', 'ring', 'cedilla', 'hungarumlaut',
    'ogonek', 'caron'  // 240..255
  );

  /// <summary>MacExpertEncoding.</summary>
  MacExpertEncodingTable: TPdfEncodingTable = (
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 0..15
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 16..31
    'space', 'exclamsmall', 'Hungarumlautsmall', 'centoldstyle', 'dollaroldstyle', 'dollarsuperior', 'ampersandsmall', 'Acutesmall', 'parenleftsuperior',
    'parenrightsuperior', 'twodotenleader', 'onedotenleader', 'comma', 'hyphen', 'period', 'fraction',  // 32..47
    'zerooldstyle', 'oneoldstyle', 'twooldstyle', 'threeoldstyle', 'fouroldstyle', 'fiveoldstyle', 'sixoldstyle', 'sevenoldstyle', 'eightoldstyle',
    'nineoldstyle', 'colon', 'semicolon', '', 'threequartersemdash', '', 'questionsmall',  // 48..63
    '', '', '', '', 'Ethsmall', '', '', 'onequarter', 'onehalf', 'threequarters', 'oneeighth', 'threeeighths', 'fiveeighths', 'seveneighths', 'onethird',
    'twothirds',  // 64..79
    '', '', '', '', '', '', 'ff', 'fi', 'fl', 'ffi', 'ffl', 'parenleftinferior', '', 'parenrightinferior', 'Circumflexsmall', 'hypheninferior',  // 80..95
    'Gravesmall', 'Asmall', 'Bsmall', 'Csmall', 'Dsmall', 'Esmall', 'Fsmall', 'Gsmall', 'Hsmall', 'Ismall', 'Jsmall', 'Ksmall', 'Lsmall', 'Msmall', 'Nsmall',
    'Osmall',  // 96..111
    'Psmall', 'Qsmall', 'Rsmall', 'Ssmall', 'Tsmall', 'Usmall', 'Vsmall', 'Wsmall', 'Xsmall', 'Ysmall', 'Zsmall', 'colonmonetary', 'onefitted', 'rupiah',
    'Tildesmall', '',  // 112..127
    '', 'asuperior', 'centsuperior', '', '', '', '', 'Aacutesmall', 'Agravesmall', 'Acircumflexsmall', 'Adieresissmall', 'Atildesmall', 'Aringsmall',
    'Ccedillasmall', 'Eacutesmall', 'Egravesmall',  // 128..143
    'Ecircumflexsmall', 'Edieresissmall', 'Iacutesmall', 'Igravesmall', 'Icircumflexsmall', 'Idieresissmall', 'Ntildesmall', 'Oacutesmall', 'Ogravesmall',
    'Ocircumflexsmall', 'Odieresissmall', 'Otildesmall', 'Uacutesmall', 'Ugravesmall', 'Ucircumflexsmall', 'Udieresissmall',  // 144..159
    '', 'eightsuperior', 'fourinferior', 'threeinferior', 'sixinferior', 'eightinferior', 'seveninferior', 'Scaronsmall', '', 'centinferior', 'twoinferior', '',
    'Dieresissmall', '', 'Caronsmall', 'osuperior',  // 160..175
    'fiveinferior', '', 'commainferior', 'periodinferior', 'Yacutesmall', '', 'dollarinferior', '', '', 'Thornsmall', '', 'nineinferior', 'zeroinferior',
    'Zcaronsmall', 'AEsmall', 'Oslashsmall',  // 176..191
    'questiondownsmall', 'oneinferior', 'Lslashsmall', '', '', '', '', '', '', 'Cedillasmall', '', '', '', '', '', 'OEsmall',  // 192..207
    'figuredash', 'hyphensuperior', '', '', '', '', 'exclamdownsmall', '', 'Ydieresissmall', '', 'onesuperior', 'twosuperior', 'threesuperior', 'foursuperior',
    'fivesuperior', 'sixsuperior',  // 208..223
    'sevensuperior', 'ninesuperior', 'zerosuperior', '', 'esuperior', 'rsuperior', 'tsuperior', '', '', 'isuperior', 'ssuperior', 'dsuperior', '', '', '', '',  // 224..239
    '', 'lsuperior', 'Ogoneksmall', 'Brevesmall', 'Macronsmall', 'bsuperior', 'nsuperior', 'msuperior', 'commasuperior', 'periodsuperior', 'Dotaccentsmall',
    'Ringsmall', '', '', '', ''  // 240..255
  );

  /// <summary>Built-in encoding of the Symbol font.</summary>
  SymbolEncodingTable: TPdfEncodingTable = (
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 0..15
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 16..31
    'space', 'exclam', 'universal', 'numbersign', 'existential', 'percent', 'ampersand', 'suchthat', 'parenleft', 'parenright', 'asteriskmath', 'plus', 'comma',
    'minus', 'period', 'slash',  // 32..47
    'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'colon', 'semicolon', 'less', 'equal', 'greater', 'question',  // 48..63
    'congruent', 'Alpha', 'Beta', 'Chi', 'Delta', 'Epsilon', 'Phi', 'Gamma', 'Eta', 'Iota', 'theta1', 'Kappa', 'Lambda', 'Mu', 'Nu', 'Omicron',  // 64..79
    'Pi', 'Theta', 'Rho', 'Sigma', 'Tau', 'Upsilon', 'sigma1', 'Omega', 'Xi', 'Psi', 'Zeta', 'bracketleft', 'therefore', 'bracketright', 'perpendicular',
    'underscore',  // 80..95
    'radicalex', 'alpha', 'beta', 'chi', 'delta', 'epsilon', 'phi', 'gamma', 'eta', 'iota', 'phi1', 'kappa', 'lambda', 'mu', 'nu', 'omicron',  // 96..111
    'pi', 'theta', 'rho', 'sigma', 'tau', 'upsilon', 'omega1', 'omega', 'xi', 'psi', 'zeta', 'braceleft', 'bar', 'braceright', 'similar', '',  // 112..127
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 128..143
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 144..159
    'Euro', 'Upsilon1', 'minute', 'lessequal', 'fraction', 'infinity', 'florin', 'club', 'diamond', 'heart', 'spade', 'arrowboth', 'arrowleft', 'arrowup',
    'arrowright', 'arrowdown',  // 160..175
    'degree', 'plusminus', 'second', 'greaterequal', 'multiply', 'proportional', 'partialdiff', 'bullet', 'divide', 'notequal', 'equivalence', 'approxequal',
    'ellipsis', 'arrowvertex', 'arrowhorizex', 'carriagereturn',  // 176..191
    'aleph', 'Ifraktur', 'Rfraktur', 'weierstrass', 'circlemultiply', 'circleplus', 'emptyset', 'intersection', 'union', 'propersuperset', 'reflexsuperset',
    'notsubset', 'propersubset', 'reflexsubset', 'element', 'notelement',  // 192..207
    'angle', 'gradient', 'registerserif', 'copyrightserif', 'trademarkserif', 'product', 'radical', 'dotmath', 'logicalnot', 'logicaland', 'logicalor',
    'arrowdblboth', 'arrowdblleft', 'arrowdblup', 'arrowdblright', 'arrowdbldown',  // 208..223
    'lozenge', 'angleleft', 'registersans', 'copyrightsans', 'trademarksans', 'summation', 'parenlefttp', 'parenleftex', 'parenleftbt', 'bracketlefttp',
    'bracketleftex', 'bracketleftbt', 'bracelefttp', 'braceleftmid', 'braceleftbt', 'braceex',  // 224..239
    '', 'angleright', 'integral', 'integraltp', 'integralex', 'integralbt', 'parenrighttp', 'parenrightex', 'parenrightbt', 'bracketrighttp', 'bracketrightex',
    'bracketrightbt', 'bracerighttp', 'bracerightmid', 'bracerightbt', ''  // 240..255
  );

  /// <summary>Built-in encoding of the ZapfDingbats font.</summary>
  ZapfDingbatsEncodingTable: TPdfEncodingTable = (
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 0..15
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 16..31
    'space', 'a1', 'a2', 'a202', 'a3', 'a4', 'a5', 'a119', 'a118', 'a117', 'a11', 'a12', 'a13', 'a14', 'a15', 'a16',  // 32..47
    'a105', 'a17', 'a18', 'a19', 'a20', 'a21', 'a22', 'a23', 'a24', 'a25', 'a26', 'a27', 'a28', 'a6', 'a7', 'a8',  // 48..63
    'a9', 'a10', 'a29', 'a30', 'a31', 'a32', 'a33', 'a34', 'a35', 'a36', 'a37', 'a38', 'a39', 'a40', 'a41', 'a42',  // 64..79
    'a43', 'a44', 'a45', 'a46', 'a47', 'a48', 'a49', 'a50', 'a51', 'a52', 'a53', 'a54', 'a55', 'a56', 'a57', 'a58',  // 80..95
    'a59', 'a60', 'a61', 'a62', 'a63', 'a64', 'a65', 'a66', 'a67', 'a68', 'a69', 'a70', 'a71', 'a72', 'a73', 'a74',  // 96..111
    'a203', 'a75', 'a204', 'a76', 'a77', 'a78', 'a79', 'a81', 'a82', 'a83', 'a84', 'a97', 'a98', 'a99', 'a100', '',  // 112..127
    'a89', 'a90', 'a93', 'a94', 'a91', 'a92', 'a205', 'a85', 'a206', 'a86', 'a87', 'a88', 'a95', 'a96', '', '',  // 128..143
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 144..159
    '', 'a101', 'a102', 'a103', 'a104', 'a106', 'a107', 'a108', 'a112', 'a111', 'a110', 'a109', 'a120', 'a121', 'a122', 'a123',  // 160..175
    'a124', 'a125', 'a126', 'a127', 'a128', 'a129', 'a130', 'a131', 'a132', 'a133', 'a134', 'a135', 'a136', 'a137', 'a138', 'a139',  // 176..191
    'a140', 'a141', 'a142', 'a143', 'a144', 'a145', 'a146', 'a147', 'a148', 'a149', 'a150', 'a151', 'a152', 'a153', 'a154', 'a155',  // 192..207
    'a156', 'a157', 'a158', 'a159', 'a160', 'a161', 'a163', 'a164', 'a196', 'a165', 'a192', 'a166', 'a167', 'a168', 'a169', 'a170',  // 208..223
    'a171', 'a172', 'a173', 'a162', 'a174', 'a175', 'a176', 'a177', 'a178', 'a179', 'a193', 'a180', 'a199', 'a181', 'a200', 'a182',  // 224..239
    '', 'a201', 'a183', 'a184', 'a197', 'a185', 'a194', 'a198', 'a186', 'a195', 'a187', 'a188', 'a189', 'a190', 'a191', ''  // 240..255
  );

  /// <summary>Adobe ExpertEncoding (CFF predefined encoding 1).</summary>
  ExpertEncodingTable: TPdfEncodingTable = (
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 0..15
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 16..31
    'space', 'exclamsmall', 'Hungarumlautsmall', '', 'dollaroldstyle', 'dollarsuperior', 'ampersandsmall', 'Acutesmall', 'parenleftsuperior',
    'parenrightsuperior', 'twodotenleader', 'onedotenleader', 'comma', 'hyphen', 'period', 'fraction',  // 32..47
    'zerooldstyle', 'oneoldstyle', 'twooldstyle', 'threeoldstyle', 'fouroldstyle', 'fiveoldstyle', 'sixoldstyle', 'sevenoldstyle', 'eightoldstyle',
    'nineoldstyle', 'colon', 'semicolon', 'commasuperior', 'threequartersemdash', 'periodsuperior', 'questionsmall',  // 48..63
    '', 'asuperior', 'bsuperior', 'centsuperior', 'dsuperior', 'esuperior', '', '', '', 'isuperior', '', '', 'lsuperior', 'msuperior', 'nsuperior', 'osuperior',  // 64..79
    '', '', 'rsuperior', 'ssuperior', 'tsuperior', '', 'ff', 'fi', 'fl', 'ffi', 'ffl', 'parenleftinferior', '', 'parenrightinferior', 'Circumflexsmall',
    'hyphensuperior',  // 80..95
    'Gravesmall', 'Asmall', 'Bsmall', 'Csmall', 'Dsmall', 'Esmall', 'Fsmall', 'Gsmall', 'Hsmall', 'Ismall', 'Jsmall', 'Ksmall', 'Lsmall', 'Msmall', 'Nsmall',
    'Osmall',  // 96..111
    'Psmall', 'Qsmall', 'Rsmall', 'Ssmall', 'Tsmall', 'Usmall', 'Vsmall', 'Wsmall', 'Xsmall', 'Ysmall', 'Zsmall', 'colonmonetary', 'onefitted', 'rupiah',
    'Tildesmall', '',  // 112..127
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 128..143
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',  // 144..159
    '', 'exclamdownsmall', 'centoldstyle', 'Lslashsmall', '', '', 'Scaronsmall', 'Zcaronsmall', 'Dieresissmall', 'Brevesmall', 'Caronsmall', '',
    'Dotaccentsmall', '', '', 'Macronsmall',  // 160..175
    '', '', 'figuredash', 'hypheninferior', '', '', 'Ogoneksmall', 'Ringsmall', 'Cedillasmall', '', '', '', 'onequarter', 'onehalf', 'threequarters',
    'questiondownsmall',  // 176..191
    'oneeighth', 'threeeighths', 'fiveeighths', 'seveneighths', 'onethird', 'twothirds', '', '', 'zerosuperior', 'onesuperior', 'twosuperior', 'threesuperior',
    'foursuperior', 'fivesuperior', 'sixsuperior', 'sevensuperior',  // 192..207
    'eightsuperior', 'ninesuperior', 'zeroinferior', 'oneinferior', 'twoinferior', 'threeinferior', 'fourinferior', 'fiveinferior', 'sixinferior',
    'seveninferior', 'eightinferior', 'nineinferior', 'centinferior', 'dollarinferior', 'periodinferior', 'commainferior',  // 208..223
    'Agravesmall', 'Aacutesmall', 'Acircumflexsmall', 'Atildesmall', 'Adieresissmall', 'Aringsmall', 'AEsmall', 'Ccedillasmall', 'Egravesmall', 'Eacutesmall',
    'Ecircumflexsmall', 'Edieresissmall', 'Igravesmall', 'Iacutesmall', 'Icircumflexsmall', 'Idieresissmall',  // 224..239
    'Ethsmall', 'Ntildesmall', 'Ogravesmall', 'Oacutesmall', 'Ocircumflexsmall', 'Otildesmall', 'Odieresissmall', 'OEsmall', 'Oslashsmall', 'Ugravesmall',
    'Uacutesmall', 'Ucircumflexsmall', 'Udieresissmall', 'Yacutesmall', 'Thornsmall', 'Ydieresissmall'  // 240..255
  );

  /// <summary>Glyph names of StandardEncoding in ordinal order, for binary search.</summary>
  StdNames: array[0..148] of string = (
    'A', 'AE', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'Lslash', 'M', 'N', 'O', 'OE', 'Oslash', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y',
    'Z', 'a', 'acute', 'ae', 'ampersand', 'asciicircum', 'asciitilde', 'asterisk', 'at', 'b', 'backslash', 'bar', 'braceleft', 'braceright', 'bracketleft',
    'bracketright', 'breve', 'bullet', 'c', 'caron', 'cedilla', 'cent', 'circumflex', 'colon', 'comma', 'currency', 'd', 'dagger', 'daggerdbl', 'dieresis',
    'dollar', 'dotaccent', 'dotlessi', 'e', 'eight', 'ellipsis', 'emdash', 'endash', 'equal', 'exclam', 'exclamdown', 'f', 'fi', 'five', 'fl', 'florin', 'four',
    'fraction', 'g', 'germandbls', 'grave', 'greater', 'guillemotleft', 'guillemotright', 'guilsinglleft', 'guilsinglright', 'h', 'hungarumlaut', 'hyphen', 'i',
    'j', 'k', 'l', 'less', 'lslash', 'm', 'macron', 'n', 'nine', 'numbersign', 'o', 'oe', 'ogonek', 'one', 'ordfeminine', 'ordmasculine', 'oslash', 'p',
    'paragraph', 'parenleft', 'parenright', 'percent', 'period', 'periodcentered', 'perthousand', 'plus', 'q', 'question', 'questiondown', 'quotedbl',
    'quotedblbase', 'quotedblleft', 'quotedblright', 'quoteleft', 'quoteright', 'quotesinglbase', 'quotesingle', 'r', 'ring', 's', 'section', 'semicolon',
    'seven', 'six', 'slash', 'space', 'sterling', 't', 'three', 'tilde', 'two', 'u', 'underscore', 'v', 'w', 'x', 'y', 'yen', 'z', 'zero'
  );
  /// <summary>Codes matching <c>StdNames</c>.</summary>
  StdCodes: array[0..148] of Byte = (
    65, 225, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 232, 77, 78, 79, 234, 233, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 97, 194, 241, 38, 94, 126, 42,
    64, 98, 92, 124, 123, 125, 91, 93, 198, 183, 99, 207, 203, 162, 195, 58, 44, 168, 100, 178, 179, 200, 36, 199, 245, 101, 56, 188, 208, 177, 61, 33, 161,
    102, 174, 53, 175, 166, 52, 164, 103, 251, 193, 62, 171, 187, 172, 173, 104, 205, 45, 105, 106, 107, 108, 60, 248, 109, 197, 110, 57, 35, 111, 250, 206, 49,
    227, 235, 249, 112, 182, 40, 41, 37, 46, 180, 189, 43, 113, 63, 191, 34, 185, 170, 186, 96, 39, 184, 169, 114, 202, 115, 167, 59, 55, 54, 47, 32, 163, 116,
    51, 196, 50, 117, 95, 118, 119, 120, 121, 165, 122, 48
  );

function PdfStandardEncoding: PPdfEncodingTable;
begin
  Result := @StandardEncodingTable;
end;

function PdfWinAnsiEncoding: PPdfEncodingTable;
begin
  Result := @WinAnsiEncodingTable;
end;

function PdfMacRomanEncoding: PPdfEncodingTable;
begin
  Result := @MacRomanEncodingTable;
end;

function PdfMacExpertEncoding: PPdfEncodingTable;
begin
  Result := @MacExpertEncodingTable;
end;

function PdfSymbolEncoding: PPdfEncodingTable;
begin
  Result := @SymbolEncodingTable;
end;

function PdfZapfDingbatsEncoding: PPdfEncodingTable;
begin
  Result := @ZapfDingbatsEncodingTable;
end;

function PdfExpertEncoding: PPdfEncodingTable;
begin
  Result := @ExpertEncodingTable;
end;

function PdfEncodingByName(const Name: string): PPdfEncodingTable;
begin
  if Name = 'StandardEncoding' then
    Result := @StandardEncodingTable
  else if Name = 'WinAnsiEncoding' then
    Result := @WinAnsiEncodingTable
  else if Name = 'MacRomanEncoding' then
    Result := @MacRomanEncodingTable
  else if Name = 'MacExpertEncoding' then
    Result := @MacExpertEncodingTable
  else
    Result := nil;
end;

function PdfStandardEncodingCode(const GlyphName: string): Integer;
var
  Lo, Hi, Mid, C: Integer;
begin
  Lo := Low(StdNames);
  Hi := High(StdNames);
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) shr 1;
    C := CompareStr(StdNames[Mid], GlyphName);
    if C = 0 then
      Exit(StdCodes[Mid]);
    if C < 0 then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Result := -1;
end;

end.
