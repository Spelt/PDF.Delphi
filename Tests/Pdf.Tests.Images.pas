{*******************************************************************************
  Pdf.Tests.Images
  DUnitX tests for Pdf.Render.Images (image XObjects and inline images).
*******************************************************************************}
unit Pdf.Tests.Images;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.IOUtils, System.UITypes, System.Diagnostics, System.Skia,
  DUnitX.TestFramework, Pdf.Core.Types, Pdf.Core.Objects, Pdf.Core.Parser, Pdf.Core.Document,
  Pdf.Render.Images;

type
  [TestFixture]
  TImageDecoderTests = class
  private
    function Decode(const Stream: IPdfStream; out IsStencil: Boolean; out Reason: string;
      FillColor: TAlphaColor = TAlphaColors.Black): ISkImage; overload;
    function Decode(const Stream: IPdfStream): ISkImage; overload;
    procedure CheckColor(const Img: ISkImage; X, Y: Integer; Expected: TAlphaColor; Tolerance: Integer = 0);
    procedure CheckTransparent(const Img: ISkImage; X, Y: Integer);
  public
    [Test] procedure Gray8;
    [Test] procedure RGB8;
    [Test] procedure CMYK8;
    [Test] procedure Gray1WithRowPadding;
    [Test] procedure Gray2;
    [Test] procedure Gray4;
    [Test] procedure RGB16;
    [Test] procedure DecodeInversion;
    [Test] procedure RGBDecodeInversion;
    [Test] procedure StencilMask;
    [Test] procedure StencilMaskInvertedDecode;
    [Test] procedure Indexed2Bit;
    [Test] procedure Indexed8BitWithDecode;
    [Test] procedure SMaskSmallerThanImage;
    [Test] procedure MaskStencilStream;
    [Test] procedure MaskColorKey;
    [Test] procedure MaskColorKeyIndexed;
    [Test] procedure TruncatedDataDoesNotRaise;
    [Test] procedure EmptyDataReturnsNil;
    [Test] procedure ZeroSizeReturnsNil;
    [Test] procedure MissingSizeReturnsNil;
    [Test] procedure TooLargeReturnsNil;
    [Test] procedure JPXNotSupported;
    [Test] procedure JBIG2NotSupported;
    [Test] procedure BadBitsPerComponent;
    [Test] procedure CorruptFlateDoesNotRaise;
    [Test] procedure InlineAbbreviations;
    [Test] procedure InlineStencilAbbreviations;
    [Test] procedure InlineHexFilterAndResourceColorSpace;
    [Test] procedure GetSizeAndIsStencil;
    [Test] procedure UnknownColorSpaceGuessesFromDataSize;
    [Test] procedure Jpeg;
    [Test] procedure JpegWithSMask;
    [Test] procedure JpegGrayWithDecodeInversion;
    [Test] procedure InvalidJpegReturnsNil;
    [Test] procedure MakeSkImageRGBAPremultiplies;
    [Test] procedure LargeBilevelScan;
    [Test] procedure RealPdfImages;
    [Test] procedure CmykJpegFromCorpus;
    [Test] procedure JpegSizeComesFromData;
  end;

implementation

const
  CorpusDir = 'C:\Users\EDWARD~1\AppData\Local\Temp\claude\pdfjs-corpus\pdfjs\test\pdfs\';

function Dict(const Source: string): IPdfDictionary;
begin
  Result := PdfAsDictionary(PdfParseObject(Source));
  Assert.IsNotNull(Result, 'dictionary source does not parse: ' + Source);
end;

function MakeImage(const DictSource: string; const Data: TBytes): IPdfStream;
begin
  Result := PdfStream(Dict(DictSource), Data);
end;

function MakeJpeg(Width, Height: Integer; Left, Right: TAlphaColor): TBytes;
var
  Surface: ISkSurface;
  Paint: ISkPaint;
begin
  Surface := TSkSurface.MakeRaster(Width, Height);
  Surface.Canvas.Clear(Left);
  Paint := TSkPaint.Create;
  Paint.Color := Right;
  Surface.Canvas.DrawRect(TRectF.Create(Width div 2, 0, Width, Height), Paint);
  Result := Surface.MakeImageSnapshot.Encode(TSkEncodedImageFormat.JPEG, 100);
end;

function ScratchDir: string;
begin
  Result := TPath.GetFullPath(TPath.Combine(ExtractFilePath(ParamStr(0)), '..\scratch'));
end;

{ TImageDecoderTests }

function TImageDecoderTests.Decode(const Stream: IPdfStream; out IsStencil: Boolean; out Reason: string;
  FillColor: TAlphaColor): ISkImage;
begin
  Result := TPdfImageDecoder.Decode(Stream, nil, nil, FillColor, IsStencil, Reason);
end;

function TImageDecoderTests.Decode(const Stream: IPdfStream): ISkImage;
var
  IsStencil: Boolean;
  Reason: string;
begin
  Result := Decode(Stream, IsStencil, Reason);
  Assert.IsNotNull(Result, 'decode failed: ' + Reason);
  Assert.IsFalse(IsStencil, 'IsStencil');
end;

procedure TImageDecoderTests.CheckColor(const Img: ISkImage; X, Y: Integer; Expected: TAlphaColor; Tolerance: Integer);
var
  Actual: TAlphaColor;
  Shift: Integer;
  Ok: Boolean;
begin
  Actual := Img.PeekPixels.GetColor(X, Y);
  Ok := True;
  Shift := 0;
  while Shift < 32 do
  begin
    if Abs(Integer((Actual shr Shift) and $FF) - Integer((Expected shr Shift) and $FF)) > Tolerance then
      Ok := False;
    Inc(Shift, 8);
  end;
  Assert.IsTrue(Ok, Format('pixel (%d,%d): expected %.8x, got %.8x', [X, Y, Expected, Actual]));
end;

procedure TImageDecoderTests.CheckTransparent(const Img: ISkImage; X, Y: Integer);
begin
  Assert.AreEqual<Cardinal>(0, Img.PeekPixels.GetColor(X, Y) shr 24, Format('alpha at (%d,%d)', [X, Y]));
end;


procedure TImageDecoderTests.Gray8;
var
  Img: ISkImage;
begin
  Img := Decode(MakeImage('<< /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 >>',
    TBytes.Create(0, 85, 170, 255)));
  Assert.AreEqual(2, Img.Width);
  Assert.AreEqual(2, Img.Height);
  CheckColor(Img, 0, 0, $FF000000);
  CheckColor(Img, 1, 0, $FF555555);
  CheckColor(Img, 0, 1, $FFAAAAAA);
  CheckColor(Img, 1, 1, $FFFFFFFF);
end;

procedure TImageDecoderTests.RGB8;
var
  Img: ISkImage;
begin
  Img := Decode(MakeImage('<< /Width 3 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 >>',
    TBytes.Create(255, 0, 0, 0, 255, 0, 10, 20, 30)));
  CheckColor(Img, 0, 0, $FFFF0000);
  CheckColor(Img, 1, 0, $FF00FF00);
  CheckColor(Img, 2, 0, $FF0A141E);
end;

procedure TImageDecoderTests.CMYK8;
var
  Img: ISkImage;
begin
  Img := Decode(MakeImage('<< /Width 4 /Height 1 /ColorSpace /DeviceCMYK /BitsPerComponent 8 >>',
    TBytes.Create(0, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 255, 0, 255, 255, 0)));
  CheckColor(Img, 0, 0, $FFFFFFFF);
  CheckColor(Img, 1, 0, $FF00FFFF);
  CheckColor(Img, 2, 0, $FF000000);
  CheckColor(Img, 3, 0, $FFFF0000);
end;

procedure TImageDecoderTests.Gray1WithRowPadding;
var
  Img: ISkImage;
  X: Integer;
begin
  // Width 10: two bytes per row, the last 6 bits of each row are padding.
  // Row 0: 1010101010, row 1: 0000000001.
  Img := Decode(MakeImage('<< /Width 10 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 1 >>',
    TBytes.Create($AA, $BF, $00, $40)));
  for X := 0 to 9 do
    if X mod 2 = 0 then
      CheckColor(Img, X, 0, $FFFFFFFF)
    else
      CheckColor(Img, X, 0, $FF000000);
  for X := 0 to 8 do
    CheckColor(Img, X, 1, $FF000000);
  CheckColor(Img, 9, 1, $FFFFFFFF);
end;

procedure TImageDecoderTests.Gray2;
var
  Img: ISkImage;
begin
  Img := Decode(MakeImage('<< /Width 5 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 2 >>',
    TBytes.Create($1B, $C0)));
  CheckColor(Img, 0, 0, $FF000000);
  CheckColor(Img, 1, 0, $FF555555);
  CheckColor(Img, 2, 0, $FFAAAAAA);
  CheckColor(Img, 3, 0, $FFFFFFFF);
  CheckColor(Img, 4, 0, $FFFFFFFF);
end;

procedure TImageDecoderTests.Gray4;
var
  Img: ISkImage;
begin
  Img := Decode(MakeImage('<< /Width 3 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 4 >>',
    TBytes.Create($0F, $80)));
  CheckColor(Img, 0, 0, $FF000000);
  CheckColor(Img, 1, 0, $FFFFFFFF);
  CheckColor(Img, 2, 0, $FF888888);
end;

procedure TImageDecoderTests.RGB16;
var
  Img: ISkImage;
begin
  Img := Decode(MakeImage('<< /Width 2 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 16 >>',
    TBytes.Create($FF, $FF, $80, $00, $00, $00,  $00, $00, $00, $FF, $FF, $FF)));
  CheckColor(Img, 0, 0, $FFFF8000, 1);
  CheckColor(Img, 1, 0, $FF0000FF, 1);
end;

procedure TImageDecoderTests.DecodeInversion;
var
  Img: ISkImage;
begin
  Img := Decode(MakeImage('<< /Width 3 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Decode [1 0] >>',
    TBytes.Create(0, 255, 85)));
  CheckColor(Img, 0, 0, $FFFFFFFF);
  CheckColor(Img, 1, 0, $FF000000);
  CheckColor(Img, 2, 0, $FFAAAAAA);
end;

procedure TImageDecoderTests.RGBDecodeInversion;
var
  Img: ISkImage;
begin
  Img := Decode(MakeImage('<< /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Decode [1 0 0 1 1 0] >>',
    TBytes.Create(255, 255, 0)));
  CheckColor(Img, 0, 0, $FF00FFFF);
end;

procedure TImageDecoderTests.StencilMask;
var
  Img: ISkImage;
  IsStencil: Boolean;
  Reason: string;
begin
  // Samples 0 1 0 (+ padding): 0 paints the fill colour.
  Img := Decode(MakeImage('<< /Width 3 /Height 1 /ImageMask true >>', TBytes.Create($40)), IsStencil, Reason,
    TAlphaColors.Red);
  Assert.IsNotNull(Img, Reason);
  Assert.IsTrue(IsStencil, 'IsStencil');
  CheckColor(Img, 0, 0, TAlphaColors.Red);
  CheckTransparent(Img, 1, 0);
  CheckColor(Img, 2, 0, TAlphaColors.Red);
end;

procedure TImageDecoderTests.StencilMaskInvertedDecode;
var
  Img: ISkImage;
  IsStencil: Boolean;
  Reason: string;
begin
  Img := Decode(MakeImage('<< /Width 3 /Height 1 /ImageMask true /BitsPerComponent 1 /Decode [1 0] >>',
    TBytes.Create($40)), IsStencil, Reason, $FF102030);
  Assert.IsNotNull(Img, Reason);
  Assert.IsTrue(IsStencil, 'IsStencil');
  CheckTransparent(Img, 0, 0);
  CheckColor(Img, 1, 0, $FF102030);
  CheckTransparent(Img, 2, 0);
end;

procedure TImageDecoderTests.Indexed2Bit;
var
  Img: ISkImage;
begin
  // Depends on Pdf.Render.ColorSpaces parsing [/Indexed ...].
  Img := Decode(MakeImage('<< /Width 4 /Height 1 /BitsPerComponent 2 ' +
    '/ColorSpace [/Indexed /DeviceRGB 3 <FF0000 00FF00 0000FF FFFFFF>] >>', TBytes.Create($1B)));
  CheckColor(Img, 0, 0, $FFFF0000);
  CheckColor(Img, 1, 0, $FF00FF00);
  CheckColor(Img, 2, 0, $FF0000FF);
  CheckColor(Img, 3, 0, $FFFFFFFF);
end;

procedure TImageDecoderTests.Indexed8BitWithDecode;
var
  Img: ISkImage;
begin
  // Depends on Pdf.Render.ColorSpaces parsing [/Indexed ...]. Decode [1 0] maps raw 0 -> index 1.
  Img := Decode(MakeImage('<< /Width 2 /Height 1 /BitsPerComponent 1 /Decode [1 0] ' +
    '/ColorSpace [/Indexed /DeviceRGB 1 <FF0000 0000FF>] >>', TBytes.Create($40)));
  CheckColor(Img, 0, 0, $FF0000FF);
  CheckColor(Img, 1, 0, $FFFF0000);
end;

procedure TImageDecoderTests.SMaskSmallerThanImage;
var
  Base, SMask: IPdfStream;
  Data: TBytes;
  Img: ISkImage;
  I: Integer;
begin
  SetLength(Data, 4 * 4 * 3);
  for I := 0 to 15 do
    Data[I * 3] := 255;
  Base := MakeImage('<< /Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8 >>', Data);
  SMask := MakeImage('<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 >>',
    TBytes.Create(255, 0, 0, 255));
  Base.Dict.SetValue('SMask', SMask);
  Img := Decode(Base);
  Assert.AreEqual(4, Img.Width);
  CheckColor(Img, 0, 0, $FFFF0000);
  CheckColor(Img, 1, 1, $FFFF0000);
  CheckTransparent(Img, 2, 0);
  CheckTransparent(Img, 3, 1);
  CheckTransparent(Img, 0, 3);
  CheckColor(Img, 3, 3, $FFFF0000);
end;

procedure TImageDecoderTests.MaskStencilStream;
var
  Base, Mask: IPdfStream;
  Img: ISkImage;
begin
  Base := MakeImage('<< /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 >>',
    TBytes.Create(255, 255, 255, 255));
  // Mask 1x2: top row 0 (painted), bottom row 1 (masked out).
  Mask := MakeImage('<< /Width 1 /Height 2 /ImageMask true /BitsPerComponent 1 >>', TBytes.Create($00, $80));
  Base.Dict.SetValue('Mask', Mask);
  Img := Decode(Base);
  CheckColor(Img, 0, 0, $FFFFFFFF);
  CheckColor(Img, 1, 0, $FFFFFFFF);
  CheckTransparent(Img, 0, 1);
  CheckTransparent(Img, 1, 1);
end;

procedure TImageDecoderTests.MaskColorKey;
var
  Img: ISkImage;
begin
  Img := Decode(MakeImage('<< /Width 3 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Mask [250 255 0 5 0 5] >>',
    TBytes.Create(255, 0, 0, 0, 255, 0, 252, 6, 0)));
  CheckTransparent(Img, 0, 0);
  CheckColor(Img, 1, 0, $FF00FF00);
  CheckColor(Img, 2, 0, $FFFC0600);
end;

procedure TImageDecoderTests.MaskColorKeyIndexed;
var
  Img: ISkImage;
begin
  // Colour key on the raw palette index. Gray 4-bit instead of Indexed so it does not depend on the colour-space unit.
  Img := Decode(MakeImage('<< /Width 4 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 4 /Mask [1 2] >>',
    TBytes.Create($01, $2F)));
  CheckColor(Img, 0, 0, $FF000000);
  CheckTransparent(Img, 1, 0);
  CheckTransparent(Img, 2, 0);
  CheckColor(Img, 3, 0, $FFFFFFFF);
end;

procedure TImageDecoderTests.TruncatedDataDoesNotRaise;
var
  Img: ISkImage;
begin
  Img := Decode(MakeImage('<< /Width 10 /Height 10 /ColorSpace /DeviceRGB /BitsPerComponent 8 >>',
    TBytes.Create(255, 255, 255, 0, 0)));
  Assert.AreEqual(10, Img.Width);
  CheckColor(Img, 0, 0, $FFFFFFFF);
  CheckColor(Img, 1, 0, $FF000000);
  CheckColor(Img, 9, 9, $FF000000);
  Img := Decode(MakeImage('<< /Width 100 /Height 3 /ColorSpace /DeviceGray /BitsPerComponent 1 >>', TBytes.Create($FF)));
  CheckColor(Img, 0, 0, $FFFFFFFF);
  CheckColor(Img, 99, 2, $FF000000);
  Img := Decode(MakeImage('<< /Width 7 /Height 3 /ColorSpace /DeviceCMYK /BitsPerComponent 4 /Mask [0 1 0 1 0 1 0 1] >>',
    TBytes.Create($12)));
  CheckTransparent(Img, 6, 2);
end;

procedure TImageDecoderTests.EmptyDataReturnsNil;
var
  IsStencil: Boolean;
  Reason: string;
begin
  Assert.IsNull(Decode(MakeImage('<< /Width 4 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8 >>', nil),
    IsStencil, Reason));
  Assert.IsNotEmpty(Reason);
end;

procedure TImageDecoderTests.ZeroSizeReturnsNil;
var
  IsStencil: Boolean;
  Reason: string;
begin
  Assert.IsNull(Decode(MakeImage('<< /Width 0 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8 >>',
    TBytes.Create(1, 2, 3)), IsStencil, Reason));
  Assert.IsNotEmpty(Reason);
  Assert.IsNull(Decode(MakeImage('<< /Width 4 /Height -1 /ColorSpace /DeviceGray /BitsPerComponent 8 >>',
    TBytes.Create(1, 2, 3)), IsStencil, Reason));
  Assert.IsNotEmpty(Reason);
end;

procedure TImageDecoderTests.MissingSizeReturnsNil;
var
  IsStencil: Boolean;
  Reason: string;
begin
  Assert.IsNull(Decode(MakeImage('<< /ColorSpace /DeviceGray /BitsPerComponent 8 >>', TBytes.Create(1)), IsStencil, Reason));
  Assert.IsNotEmpty(Reason);
  Assert.IsNull(TPdfImageDecoder.Decode(nil, nil, nil, 0, IsStencil, Reason));
  Assert.IsNotEmpty(Reason);
end;

procedure TImageDecoderTests.TooLargeReturnsNil;
var
  IsStencil: Boolean;
  Reason: string;
begin
  Assert.IsNull(Decode(MakeImage('<< /Width 100000 /Height 100000 /ColorSpace /DeviceGray /BitsPerComponent 1 >>',
    TBytes.Create(1)), IsStencil, Reason));
  Assert.Contains(Reason, 'too large');
end;

procedure TImageDecoderTests.JPXNotSupported;
var
  IsStencil: Boolean;
  Reason: string;
begin
  Assert.IsNull(Decode(MakeImage('<< /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /JPXDecode >>',
    TBytes.Create(0, 0, 0, $0C, $6A, $50)), IsStencil, Reason));
  Assert.AreEqual('JPXDecode not supported', Reason);
end;

procedure TImageDecoderTests.JBIG2NotSupported;
var
  IsStencil: Boolean;
  Reason: string;
begin
  Assert.IsNull(Decode(MakeImage('<< /Width 4 /Height 4 /ImageMask true /Filter [/AHx /JBIG2Decode] >>',
    nil), IsStencil, Reason));
  Assert.Contains(Reason, 'not supported');
  Assert.IsNull(Decode(MakeImage('<< /W 4 /H 4 /IM true /F /CCF >>', TBytes.Create(1)), IsStencil, Reason));
  Assert.AreEqual('CCITTFaxDecode not supported', Reason);
end;

procedure TImageDecoderTests.BadBitsPerComponent;
var
  IsStencil: Boolean;
  Reason: string;
  Img: ISkImage;
begin
  Assert.IsNull(Decode(MakeImage('<< /Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 32 >>',
    TBytes.Create(1, 2, 3, 4, 5, 6, 7, 8)), IsStencil, Reason));
  Assert.IsNotEmpty(Reason);
  // Unusual but well-defined depths (here 12 bits) go through the generic bit reader: 0xFFF, 0x000.
  Img := Decode(MakeImage('<< /Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 12 >>',
    TBytes.Create($FF, $F0, $00)));
  CheckColor(Img, 0, 0, $FFFFFFFF);
  CheckColor(Img, 1, 0, $FF000000);
end;

procedure TImageDecoderTests.CorruptFlateDoesNotRaise;
var
  IsStencil: Boolean;
  Reason: string;
begin
  Decode(MakeImage('<< /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode >>',
    TBytes.Create(1, 2, 3, 4, 5, 6, 7)), IsStencil, Reason);
  Assert.Pass('no exception: ' + Reason);
end;

procedure TImageDecoderTests.InlineAbbreviations;
var
  Img: ISkImage;
begin
  Img := Decode(MakeImage('<< /W 2 /H 1 /BPC 8 /CS /G /D [1 0] /I true >>', TBytes.Create(0, 255)));
  Assert.AreEqual(2, Img.Width);
  CheckColor(Img, 0, 0, $FFFFFFFF);
  CheckColor(Img, 1, 0, $FF000000);
  Img := Decode(MakeImage('<< /W 1 /H 1 /BPC 8 /CS /RGB >>', TBytes.Create(1, 2, 3)));
  CheckColor(Img, 0, 0, $FF010203);
  Img := Decode(MakeImage('<< /W 1 /H 1 /BPC 8 /CS /CMYK >>', TBytes.Create(0, 0, 255, 0)));
  CheckColor(Img, 0, 0, $FFFFFF00);
end;

procedure TImageDecoderTests.InlineStencilAbbreviations;
var
  Img: ISkImage;
  IsStencil: Boolean;
  Reason: string;
begin
  Img := Decode(MakeImage('<< /W 2 /H 1 /IM true /D [1 0] >>', TBytes.Create($80)), IsStencil, Reason, TAlphaColors.Blue);
  Assert.IsNotNull(Img, Reason);
  Assert.IsTrue(IsStencil);
  CheckColor(Img, 0, 0, TAlphaColors.Blue);
  CheckTransparent(Img, 1, 0);
end;

procedure TImageDecoderTests.InlineHexFilterAndResourceColorSpace;
var
  Img: ISkImage;
  Resources: IPdfDictionary;
  IsStencil: Boolean;
  Reason: string;
begin
  Img := Decode(MakeImage('<< /W 2 /H 1 /BPC 8 /CS /RGB /F /AHx >>', TEncoding.ASCII.GetBytes('FF0000 0000FF>')));
  CheckColor(Img, 0, 0, $FFFF0000);
  CheckColor(Img, 1, 0, $FF0000FF);
  // A named colour space from the resources.
  Resources := Dict('<< /ColorSpace << /CS0 /DeviceRGB >> >>');
  Img := TPdfImageDecoder.Decode(MakeImage('<< /W 1 /H 1 /BPC 8 /CS /CS0 >>', TBytes.Create(0, 128, 255)),
    Resources, nil, 0, IsStencil, Reason);
  Assert.IsNotNull(Img, Reason);
  CheckColor(Img, 0, 0, $FF0080FF);
end;

procedure TImageDecoderTests.GetSizeAndIsStencil;
var
  W, H: Integer;
begin
  Assert.IsTrue(TPdfImageDecoder.GetSize(Dict('<< /Width 12 /Height 7 >>'), W, H));
  Assert.AreEqual(12, W);
  Assert.AreEqual(7, H);
  Assert.IsTrue(TPdfImageDecoder.GetSize(Dict('<< /W 3 /H 5 >>'), W, H));
  Assert.AreEqual(3, W);
  Assert.AreEqual(5, H);
  Assert.IsFalse(TPdfImageDecoder.GetSize(Dict('<< /Width 3 >>'), W, H));
  Assert.IsFalse(TPdfImageDecoder.GetSize(Dict('<< /Width 0 /Height 5 >>'), W, H));
  Assert.IsFalse(TPdfImageDecoder.GetSize(nil, W, H));
  Assert.IsTrue(TPdfImageDecoder.IsStencilMask(Dict('<< /ImageMask true >>')));
  Assert.IsTrue(TPdfImageDecoder.IsStencilMask(Dict('<< /IM true >>')));
  Assert.IsFalse(TPdfImageDecoder.IsStencilMask(Dict('<< /ImageMask false >>')));
  Assert.IsFalse(TPdfImageDecoder.IsStencilMask(Dict('<< >>')));
end;

procedure TImageDecoderTests.UnknownColorSpaceGuessesFromDataSize;
var
  Img: ISkImage;
begin
  Img := Decode(MakeImage('<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /NoSuchSpace >>',
    TBytes.Create(255, 0, 0, 0, 0, 255)));
  CheckColor(Img, 0, 0, $FFFF0000);
  CheckColor(Img, 1, 0, $FF0000FF);
end;

procedure TImageDecoderTests.Jpeg;
var
  Img: ISkImage;
  Jpg: TBytes;
begin
  Jpg := MakeJpeg(32, 16, TAlphaColors.Red, TAlphaColors.Blue);
  Img := Decode(MakeImage('<< /Width 32 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode >>', Jpg));
  Assert.AreEqual(32, Img.Width);
  Assert.AreEqual(16, Img.Height);
  Img := Img.MakeRasterImage;
  CheckColor(Img, 4, 8, TAlphaColors.Red, 12);
  CheckColor(Img, 28, 8, TAlphaColors.Blue, 12);
end;

procedure TImageDecoderTests.JpegWithSMask;
var
  Base: IPdfStream;
  Img: ISkImage;
begin
  Base := MakeImage('<< /Width 32 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCT >>',
    MakeJpeg(32, 16, TAlphaColors.Red, TAlphaColors.Blue));
  Base.Dict.SetValue('SMask', MakeImage('<< /Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 >>',
    TBytes.Create(255, 0)));
  Img := Decode(Base);
  Assert.AreEqual(32, Img.Width);
  CheckColor(Img, 4, 8, TAlphaColors.Red, 12);
  CheckTransparent(Img, 28, 8);
end;

procedure TImageDecoderTests.JpegGrayWithDecodeInversion;
var
  Img: ISkImage;
begin
  Img := Decode(MakeImage('<< /Width 16 /Height 16 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode /Decode [1 0] >>',
    MakeJpeg(16, 16, TAlphaColors.White, TAlphaColors.Black)));
  CheckColor(Img, 2, 8, $FF000000, 12);
  CheckColor(Img, 13, 8, $FFFFFFFF, 12);
end;

procedure TImageDecoderTests.InvalidJpegReturnsNil;
var
  IsStencil: Boolean;
  Reason: string;
begin
  Assert.IsNull(Decode(MakeImage('<< /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode >>',
    TBytes.Create($FF, $D8, $FF, $E0, 1, 2, 3)), IsStencil, Reason));
  Assert.Contains(Reason, 'DCTDecode');
end;

procedure TImageDecoderTests.MakeSkImageRGBAPremultiplies;
var
  Buf: TBytes;
  Img: ISkImage;
  Px: TBytes;
  Info: TSkImageInfo;
begin
  Buf := TBytes.Create(255, 0, 0, 255,  255, 255, 255, 0,  200, 100, 50, 128);
  Img := PdfMakeSkImageRGBA(3, 1, Buf);
  Assert.IsNotNull(Img);
  CheckColor(Img, 0, 0, $FFFF0000);
  CheckTransparent(Img, 1, 0);
  // Stored premultiplied.
  SetLength(Px, 12);
  Info := TSkImageInfo.Create(3, 1, TSkColorType.RGBA8888, TSkAlphaType.Premul);
  Assert.IsTrue(Img.ReadPixels(Info, PByte(Px), 12));
  Assert.AreEqual<Byte>(100, Px[8]);
  Assert.AreEqual<Byte>(50, Px[9]);
  Assert.AreEqual<Byte>(128, Px[11]);
  // The caller's buffer is left alone.
  Assert.AreEqual<Byte>(200, Buf[8]);
  Assert.IsNull(PdfMakeSkImageRGBA(3, 2, Buf));
  Assert.IsNull(PdfMakeSkImageRGBA(0, 1, Buf));
end;

procedure TImageDecoderTests.LargeBilevelScan;
const
  W = 5000;
  H = 7000;
var
  Data: TBytes;
  Img: ISkImage;
  SW: TStopwatch;
  I: Integer;
begin
  SetLength(Data, ((W + 7) div 8) * H);
  for I := 0 to High(Data) do
    if I mod 7 = 0 then
      Data[I] := $5A;
  SW := TStopwatch.StartNew;
  Img := Decode(MakeImage(Format('<< /Width %d /Height %d /ColorSpace /DeviceGray /BitsPerComponent 1 /Decode [1 0] >>', [W, H]), Data));
  SW.Stop;
  Assert.AreEqual(W, Img.Width);
  Assert.AreEqual(H, Img.Height);
  CheckColor(Img, 0, 0, $FFFFFFFF);
  CheckColor(Img, 1, 0, $FF000000);
  CheckColor(Img, 8, 0, $FFFFFFFF);
  TDUnitX.CurrentRunner.Log(TLogLevel.Information, Format('5000x7000 1-bit scan decoded in %d ms', [SW.ElapsedMilliseconds]));
end;

procedure TImageDecoderTests.CmykJpegFromCorpus;
var
  Doc: TPdfDocument;
  Stream, Inverted, InvertedMasked: IPdfStream;
  Jpg: TBytes;
  Plain, Fast, Slow: ISkImage;
  C: TAlphaColor;
  X, Y: Integer;
  Header: string;
begin
  if not TFile.Exists(CorpusDir + 'cmykjpeg.pdf') then
    Assert.Pass('pdf.js corpus not present');
  Doc := TPdfDocument.Create;
  try
    Doc.LoadFromFile(CorpusDir + 'cmykjpeg.pdf');
    Stream := Doc.Pages[0].Resources.GetDictionary('XObject').GetStream('Im0');
    Assert.IsNotNull(Stream);
    // No /Decode: the stored samples are plain CMYK (pdf.js semantics), recovered from two extra Skia decodes.
    Plain := Decode(Stream);
    Jpg := Stream.GetDecodedData;
  finally
    Doc.Free;
  end;
  Assert.AreEqual(200, Plain.Width);
  C := Plain.PeekPixels.GetColor(20, 5);   // sky
  Assert.IsTrue((C and $FF) > ((C shr 16) and $FF) + 40, Format('sky should be blue, got %.8x', [C]));
  C := Plain.PeekPixels.GetColor(150, 140); // sand
  Assert.IsTrue(((C shr 16) and $FF) >= (C and $FF), Format('sand should not be blue, got %.8x', [C]));
  // With /Decode [1 0 1 0 1 0 1 0] Skia's own (Adobe-inverted) conversion is used directly; the generic
  // path (forced here by an opaque SMask) must give the same colours.
  Header := '<< /Width 200 /Height 150 /ColorSpace /DeviceCMYK /BitsPerComponent 8 /Filter /DCTDecode /Decode [1 0 1 0 1 0 1 0] >>';
  Inverted := MakeImage(Header, Jpg);
  Fast := Decode(Inverted).MakeRasterImage;
  InvertedMasked := MakeImage(Header, Jpg);
  InvertedMasked.Dict.SetValue('SMask', MakeImage('<< /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray >>',
    TBytes.Create(255)));
  Slow := Decode(InvertedMasked);
  Y := 0;
  while Y < 150 do
  begin
    X := 0;
    while X < 200 do
    begin
      CheckColor(Slow, X, Y, Fast.PeekPixels.GetColor(X, Y), 6);
      Inc(X, 13);
    end;
    Inc(Y, 11);
  end;
end;

procedure TImageDecoderTests.JpegSizeComesFromData;
var
  Img: ISkImage;
  Base: IPdfStream;
begin
  // A wrong (huge) /Width /Height does not matter: the JPEG's own size is used.
  Img := Decode(MakeImage('<< /Width 100000 /Height 100000 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode >>',
    MakeJpeg(32, 16, TAlphaColors.Red, TAlphaColors.Blue)));
  Assert.AreEqual(32, Img.Width);
  Assert.AreEqual(16, Img.Height);
  Base := MakeImage('<< /Width 3 /Height 3 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode >>',
    MakeJpeg(32, 16, TAlphaColors.Red, TAlphaColors.Blue));
  Base.Dict.SetValue('Mask', PdfParseObject('[0 10 0 10 245 255]'));
  Img := Decode(Base);
  Assert.AreEqual(32, Img.Width);
  CheckColor(Img, 4, 8, TAlphaColors.Red, 12);
  CheckTransparent(Img, 28, 8);
end;

procedure TImageDecoderTests.RealPdfImages;
const
  Files: array[0..5] of string = ('cmykjpeg.pdf', 'issue1905.pdf', 'colorkeymask.pdf', 'smaskdim.pdf',
    'smask_alpha_bc.pdf', 'issue1293r.pdf');
var
  FileName, Key, Reason, PngName: string;
  Doc: TPdfDocument;
  XObjects: IPdfDictionary;
  Stream: IPdfStream;
  Img: ISkImage;
  IsStencil: Boolean;
  Decoded, Failed: Integer;
  Log: TStringBuilder;
begin
  if not TDirectory.Exists(CorpusDir) then
    Assert.Pass('pdf.js corpus not present');
  Decoded := 0;
  Failed := 0;
  Log := TStringBuilder.Create;
  try
    for FileName in Files do
    begin
      if not TFile.Exists(CorpusDir + FileName) then
        Continue;
      Doc := TPdfDocument.Create;
      try
        Doc.LoadFromFile(CorpusDir + FileName);
        if Doc.PageCount = 0 then
          Continue;
        XObjects := nil;
        if Doc.Pages[0].Resources <> nil then
          XObjects := Doc.Pages[0].Resources.GetDictionary('XObject');
        if XObjects = nil then
          Continue;
        for Key in XObjects.Keys do
        begin
          Stream := XObjects.GetStream(Key);
          if (Stream = nil) or (Stream.Dict.GetName('Subtype') <> 'Image') then
            Continue;
          Img := TPdfImageDecoder.Decode(Stream, Doc.Pages[0].Resources, Doc.Resolver, TAlphaColors.Black, IsStencil, Reason);
          if Img = nil then
          begin
            Inc(Failed);
            Log.AppendFormat('%s %s: nil (%s); ', [FileName, Key, Reason]);
            Continue;
          end;
          Inc(Decoded);
          Log.AppendFormat('%s %s: %dx%d; ', [FileName, Key, Img.Width, Img.Height]);
          if TDirectory.Exists(ScratchDir) then
          begin
            PngName := TPath.Combine(ScratchDir, 'img_' + ChangeFileExt(FileName, '') + '_' + Key + '.png');
            TFile.WriteAllBytes(PngName, Img.Encode(TSkEncodedImageFormat.PNG));
          end;
        end;
      finally
        Doc.Free;
      end;
    end;
    TDUnitX.CurrentRunner.Log(TLogLevel.Information, Log.ToString);
  finally
    Log.Free;
  end;
  Assert.IsTrue(Decoded > 0, Format('no corpus image decoded (%d failed)', [Failed]));
end;

initialization
  TDUnitX.RegisterTestFixture(TImageDecoderTests);

end.
