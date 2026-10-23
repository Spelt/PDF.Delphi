unit Pdf.Tests.Lexer;

interface

uses
  System.SysUtils, DUnitX.TestFramework, Pdf.Core.Types, Pdf.Core.Lexer;

type
  [TestFixture]
  TPdfLexerTests = class
  private
    function Tokens(const Source: string): TArray<TPdfToken>;
  public
    [Test] procedure Integers;
    [Test] procedure Reals;
    [Test] procedure MalformedNumbers;
    [Test] procedure LiteralStrings;
    [Test] procedure LiteralStringEscapes;
    [Test] procedure HexStrings;
    [Test] procedure Names;
    [Test] procedure Delimiters;
    [Test] procedure Keywords;
    [Test] procedure Comments;
    [Test] procedure StrayDelimitersAreSkipped;
    [Test] procedure FindBytes;
    [Test] procedure ReadUnsignedInt;
  end;

implementation

function TPdfLexerTests.Tokens(const Source: string): TArray<TPdfToken>;
var
  L: TPdfLexer;
  T: TPdfToken;
begin
  Result := nil;
  L := TPdfLexer.Create(PdfLatin1ToBytes(Source));
  try
    repeat
      T := L.NextToken;
      Result := Result + [T];
    until T.Kind = tkEOF;
  finally
    L.Free;
  end;
end;

procedure TPdfLexerTests.Integers;
var
  T: TArray<TPdfToken>;
begin
  T := Tokens('0 42 -17 +5 0000000016 65535');
  Assert.AreEqual(7, Integer(Length(T)));
  Assert.AreEqual(tkNumber, T[0].Kind);
  Assert.IsTrue(T[0].IsInteger);
  Assert.AreEqual<Int64>(0, T[0].IntValue);
  Assert.AreEqual<Int64>(42, T[1].IntValue);
  Assert.AreEqual<Int64>(-17, T[2].IntValue);
  Assert.AreEqual<Int64>(5, T[3].IntValue);
  Assert.AreEqual<Int64>(16, T[4].IntValue);
  Assert.AreEqual<Int64>(65535, T[5].IntValue);
  Assert.AreEqual(0, T[0].Position);
  Assert.AreEqual(2, T[1].Position);
end;

procedure TPdfLexerTests.Reals;
var
  T: TArray<TPdfToken>;
begin
  T := Tokens('3.14 -.5 4. 0.0 -0.002 6.');
  Assert.AreEqual(7, Integer(Length(T)));
  Assert.IsFalse(T[0].IsInteger);
  Assert.AreEqual(3.14, T[0].NumberValue, 1E-9);
  Assert.AreEqual(-0.5, T[1].NumberValue, 1E-9);
  Assert.AreEqual(4.0, T[2].NumberValue, 1E-9);
  Assert.AreEqual(0.0, T[3].NumberValue, 1E-9);
  Assert.AreEqual(-0.002, T[4].NumberValue, 1E-9);
  Assert.AreEqual(6.0, T[5].NumberValue, 1E-9);
end;

procedure TPdfLexerTests.MalformedNumbers;
var
  T: TArray<TPdfToken>;
begin
  // Seen in the wild: double signs, trailing minus, exponent, lone sign
  T := Tokens('--5 34.5-2 1e3 - 7');
  Assert.AreEqual(6, Integer(Length(T)));
  Assert.AreEqual<Int64>(-5, T[0].IntValue);
  Assert.AreEqual(34.5, T[1].NumberValue, 1E-9);
  Assert.AreEqual(1000.0, T[2].NumberValue, 1E-9);
  Assert.AreEqual(tkNumber, T[3].Kind);
  Assert.AreEqual<Int64>(0, T[3].IntValue);
  Assert.AreEqual<Int64>(7, T[4].IntValue);
end;

procedure TPdfLexerTests.LiteralStrings;
var
  T: TArray<TPdfToken>;
begin
  T := Tokens('(Hello) (nested (paren) ok) ()');
  Assert.AreEqual(4, Integer(Length(T)));
  Assert.AreEqual(tkString, T[0].Kind);
  Assert.IsFalse(T[0].IsHexString);
  Assert.AreEqual('Hello', T[0].Text);
  Assert.AreEqual('nested (paren) ok', T[1].Text);
  Assert.AreEqual('', T[2].Text);
end;

procedure TPdfLexerTests.LiteralStringEscapes;
var
  T: TArray<TPdfToken>;
begin
  T := Tokens('(a\n\r\t\b\f\(\)\\\101\12\0053x\q)' + '(line1\' + #13#10 + 'line2)' + '(cr' + #13 + 'lf' + #13#10 + 'end)');
  Assert.AreEqual(4, Integer(Length(T)));
  Assert.AreEqual('a'#10#13#9#8#12'()\A'#10#5'3xq', T[0].Text);
  Assert.AreEqual('line1line2', T[1].Text);
  Assert.AreEqual('cr'#10'lf'#10'end', T[2].Text);
end;

procedure TPdfLexerTests.HexStrings;
var
  T: TArray<TPdfToken>;
begin
  T := Tokens('<48656C6C6F> <48 65 6c 6C 6F> <4> <> <41zz42>');
  Assert.AreEqual(6, Integer(Length(T)));
  Assert.IsTrue(T[0].IsHexString);
  Assert.AreEqual('Hello', T[0].Text);
  Assert.AreEqual('Hello', T[1].Text);
  Assert.AreEqual(#$40, T[2].Text);
  Assert.AreEqual('', T[3].Text);
  Assert.AreEqual('AB', T[4].Text);
end;

procedure TPdfLexerTests.Names;
var
  T: TArray<TPdfToken>;
begin
  T := Tokens('/Type /A#20B /Lime#20Green /paired#28#29parentheses /A;Name_With-Various***Characters? /1.2 / /F#2fx');
  Assert.AreEqual(9, Integer(Length(T)));
  Assert.AreEqual(tkName, T[0].Kind);
  Assert.AreEqual('Type', T[0].Text);
  Assert.AreEqual('A B', T[1].Text);
  Assert.AreEqual('Lime Green', T[2].Text);
  Assert.AreEqual('paired()parentheses', T[3].Text);
  Assert.AreEqual('A;Name_With-Various***Characters?', T[4].Text);
  Assert.AreEqual('1.2', T[5].Text);
  Assert.AreEqual('', T[6].Text);
  Assert.AreEqual('F/x', T[7].Text);
end;

procedure TPdfLexerTests.Delimiters;
var
  T: TArray<TPdfToken>;
begin
  T := Tokens('[<<>>]{}');
  Assert.AreEqual(7, Integer(Length(T)));
  Assert.AreEqual(tkArrayOpen, T[0].Kind);
  Assert.AreEqual(tkDictOpen, T[1].Kind);
  Assert.AreEqual(tkDictClose, T[2].Kind);
  Assert.AreEqual(tkArrayClose, T[3].Kind);
  Assert.AreEqual(tkBraceOpen, T[4].Kind);
  Assert.AreEqual(tkBraceClose, T[5].Kind);
end;

procedure TPdfLexerTests.Keywords;
var
  T: TArray<TPdfToken>;
begin
  T := Tokens('obj endobj R true null T* '' " BT/F1');
  Assert.AreEqual(11, Integer(Length(T)));
  Assert.IsTrue(T[0].IsKeyword('obj'));
  Assert.IsTrue(T[1].IsKeyword('endobj'));
  Assert.IsTrue(T[2].IsKeyword('R'));
  Assert.IsTrue(T[3].IsKeyword('true'));
  Assert.IsTrue(T[4].IsKeyword('null'));
  Assert.IsTrue(T[5].IsKeyword('T*'));
  Assert.IsTrue(T[6].IsKeyword(''''));
  Assert.IsTrue(T[7].IsKeyword('"'));
  Assert.IsTrue(T[8].IsKeyword('BT'));
  Assert.AreEqual(tkName, T[9].Kind);
  Assert.IsFalse(T[0].IsKeyword('ob'));
end;

procedure TPdfLexerTests.Comments;
var
  T: TArray<TPdfToken>;
begin
  T := Tokens('1 % comment ) ( << ' + #13#10 + '2 %another' + #10 + '%%EOF');
  Assert.AreEqual(3, Integer(Length(T)));
  Assert.AreEqual<Int64>(1, T[0].IntValue);
  Assert.AreEqual<Int64>(2, T[1].IntValue);
end;

procedure TPdfLexerTests.StrayDelimitersAreSkipped;
var
  T: TArray<TPdfToken>;
begin
  T := Tokens(') 1 > 2');
  Assert.AreEqual(3, Integer(Length(T)));
  Assert.AreEqual<Int64>(1, T[0].IntValue);
  Assert.AreEqual<Int64>(2, T[1].IntValue);
end;

procedure TPdfLexerTests.FindBytes;
var
  D: TBytes;
begin
  D := PdfLatin1ToBytes('xx startxref 12 %%EOF startxref 99');
  Assert.AreEqual(3, PdfFindBytes(D, 'startxref', 0));
  Assert.AreEqual(22, PdfFindBytes(D, 'startxref', 4));
  Assert.AreEqual(22, PdfFindBytesBackward(D, 'startxref'));
  Assert.AreEqual(3, PdfFindBytesBackward(D, 'startxref', 22));
  Assert.AreEqual(-1, PdfFindBytes(D, 'nothere', 0));
  Assert.IsTrue(PdfMatchBytes(D, 3, 'startxref'));
  Assert.IsFalse(PdfMatchBytes(D, 4, 'startxref'));
end;

procedure TPdfLexerTests.ReadUnsignedInt;
var
  D: TBytes;
  P: Integer;
  V: Int64;
begin
  D := PdfLatin1ToBytes('startxref'#13#10'  1234'#10'%%EOF');
  P := 9;
  Assert.IsTrue(PdfReadUnsignedInt(D, P, V));
  Assert.AreEqual<Int64>(1234, V);
  Assert.AreEqual(Ord('4'), Integer(D[P - 1]));
  P := 0;
  Assert.IsFalse(PdfReadUnsignedInt(D, P, V));
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfLexerTests);

end.
