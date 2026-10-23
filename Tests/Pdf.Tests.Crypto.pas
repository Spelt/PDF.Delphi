{*******************************************************************************
  Pdf.Tests.Crypto
  DUnitX fixtures for Pdf.Core.Crypto (primitives) and Pdf.Core.Encryption
  (standard security handler).

  The handler tests use a small independent *encryptor* written here
  (Algorithms 2, 3, 4, 5 and the R5/R6 procedures) plus values taken from the
  sample files Tests/Data/enc_*.pdf, which were produced by a separate Node.js /
  OpenSSL implementation and verified to open in Poppler (pdftotext).
*******************************************************************************}
unit Pdf.Tests.Crypto;

interface

uses
  System.SysUtils, DUnitX.TestFramework,
  Pdf.Core.Types, Pdf.Core.Crypto, Pdf.Core.Encryption;

type
  [TestFixture]
  TPdfCryptoPrimitiveTests = class
  public
    [Test] procedure AES128_FIPS197;
    [Test] procedure AES192_FIPS197;
    [Test] procedure AES256_FIPS197;
    [Test] procedure AES128_CBC_SP800_38A;
    [Test] procedure AESCBC_PKCS5_RoundTrip;
    [Test] procedure AESCBC_Tolerance;
    [Test] procedure AES_InvalidArguments;
    [Test] procedure RC4_Vectors;
    [Test] procedure RC4_EmptyInputs;
    [Test] procedure Hash_Vectors;
  end;

  [TestFixture]
  TPdfSecurityHandlerTests = class
  public
    [Test] procedure R2_EmptyUserPassword;
    [Test] procedure R3_UserAndOwnerPasswords;
    [Test] procedure R4_EncryptMetadataFalse;
    [Test] procedure Legacy_WrongPasswordRaises;
    [Test] procedure Legacy_EmptyPasswordFallsBackToOwner;
    [Test] procedure RC4_StringRoundTrip;
    [Test] procedure AESV2_StreamRoundTrip;
    [Test] procedure R6_UserOwnerWrong;
    [Test] procedure R6_UnicodePassword;
    [Test] procedure R5_UserOwnerWrong;
    [Test] procedure AESV3_RoundTrip;
    [Test] procedure IdentityMethod;
    [Test] procedure UnsupportedParamsRaise;
  end;

  /// Values of the sample files in Tests/Data (see Build/scratch/make_encrypted.js).
  [TestFixture]
  TPdfEncryptedSampleTests = class
  public
    [Test] procedure Sample_RC4_40;
    [Test] procedure Sample_RC4_128;
    [Test] procedure Sample_AES128;
    [Test] procedure Sample_AES256;
    [Test] procedure Sample_AES256_UserPassword;
  end;

implementation

{ ---------------------------------------------------------------------------- }
{ Helpers                                                                      }
{ ---------------------------------------------------------------------------- }

function HexToBytes(const Hex: string): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(Hex) div 2);
  for I := 0 to Integer(Length(Result)) - 1 do
    Result[I] := Byte(StrToInt('$' + Copy(Hex, 2 * I + 1, 2)));
end;

function BytesToHex(const Data: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Integer(Length(Data)) - 1 do
    Result := Result + IntToHex(Data[I], 2);
end;

function Seq(Start, Count: Integer): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
    Result[I] := Byte(Start + I);
end;

function ZeroBytes(Count: Integer): TBytes;
begin
  SetLength(Result, Count);
  if Count > 0 then
    FillChar(Result[0], Count, 0);
end;

function Cat(const Parts: array of TBytes): TBytes;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to Integer(High(Parts)) do
    Result := PdfConcatBytes(Result, Parts[I]);
end;

function AsciiBytes(const S: string): TBytes;
begin
  Result := TEncoding.ASCII.GetBytes(S);
end;

procedure AssertBytes(const Expected, Actual: TBytes; const Msg: string = '');
begin
  Assert.AreEqual(BytesToHex(Expected), BytesToHex(Actual), Msg);
end;

{ ---------------------------------------------------------------------------- }
{ Independent test encryptor                                                   }
{ ---------------------------------------------------------------------------- }

const
  PadHex = '28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A';

function TestPad(const Password: string): TBytes;
begin
  Result := Copy(PdfConcatBytes(PdfLatin1ToBytes(Password), HexToBytes(PadHex)), 0, 32);
end;

function XorBytes(const Key: TBytes; V: Byte): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(Key));
  for I := 0 to Integer(Length(Key)) - 1 do
    Result[I] := Key[I] xor V;
end;

function LE32(V: Integer): TBytes;
begin
  Result := TBytes.Create(Byte(V), Byte(V shr 8), Byte(V shr 16), Byte(V shr 24));
end;

/// Builds /O, /U and the file key for R2/R3/R4 (Algorithms 3, 2, 4/5).
/// ForceOwnerPw: use OwnerPw even when empty (Algorithm 3 would substitute the user password).
procedure LegacyEncrypt(R, KeyBits: Integer; const UserPw, OwnerPw: string; P: Integer;
  const ID0: TBytes; EncryptMetadata, ForceOwnerPw: Boolean; out O, U, Key: TBytes);
var
  N, I: Integer;
  H, OKey: TBytes;
begin
  if R = 2 then
    N := 5
  else
    N := KeyBits div 8;
  // Algorithm 3
  if (OwnerPw <> '') or ForceOwnerPw then
    H := PdfMD5(TestPad(OwnerPw))
  else
    H := PdfMD5(TestPad(UserPw));
  if R >= 3 then
    for I := 1 to 50 do
      H := PdfMD5(H);
  OKey := Copy(H, 0, N);
  O := PdfRC4(OKey, TestPad(UserPw));
  if R >= 3 then
    for I := 1 to 19 do
      O := PdfRC4(XorBytes(OKey, Byte(I)), O);
  // Algorithm 2
  H := Cat([TestPad(UserPw), O, LE32(P), ID0]);
  if (R >= 4) and not EncryptMetadata then
    H := Cat([H, HexToBytes('FFFFFFFF')]);
  H := PdfMD5(H);
  if R >= 3 then
    for I := 1 to 50 do
      H := PdfMD5(Copy(H, 0, N));
  Key := Copy(H, 0, N);
  // Algorithm 4 / 5
  if R = 2 then
    U := PdfRC4(Key, HexToBytes(PadHex))
  else
  begin
    U := PdfRC4(Key, PdfMD5(Cat([HexToBytes(PadHex), ID0])));
    for I := 1 to 19 do
      U := PdfRC4(XorBytes(Key, Byte(I)), U);
    U := Cat([U, Seq($E0, 16)]);
  end;
end;

/// ISO 32000-2 Algorithm 2.B, written independently of Pdf.Core.Encryption.
function TestHashR6(const Pw, Salt, UData: TBytes): TBytes;
var
  K, E, Block, K1: TBytes;
  Round, J, Sum: Integer;
  Done: Boolean;
begin
  K := PdfSHA256(Cat([Pw, Salt, UData]));
  Round := 0;
  Done := False;
  while not Done do
  begin
    Block := Cat([Pw, K, UData]);
    K1 := nil;
    for J := 1 to 64 do
      K1 := Cat([K1, Block]);
    E := PdfAESCBCEncryptNoPad(Copy(K, 0, 16), Copy(K, 16, 16), K1);
    Sum := 0;
    for J := 0 to 15 do
      Sum := Sum + E[J];
    if Sum mod 3 = 0 then
      K := PdfSHA256(E)
    else if Sum mod 3 = 1 then
      K := PdfSHA384(E)
    else
      K := PdfSHA512(E);
    Round := Round + 1;
    Done := (Round >= 64) and (E[Length(E) - 1] <= Round - 32);
  end;
  Result := Copy(K, 0, 32);
end;

function TestHash(R: Integer; const Pw, Salt, UData: TBytes): TBytes;
begin
  if R = 6 then
    Result := TestHashR6(Pw, Salt, UData)
  else
    Result := PdfSHA256(Cat([Pw, Salt, UData]));
end;

/// Builds /U /UE /O /OE /Perms for R5/R6 with fixed salts.
procedure ModernEncrypt(R: Integer; const UserPw, OwnerPw: string; P: Integer; const FileKey: TBytes;
  out O, U, OE, UE, Perms: TBytes);
var
  UPw, OPw, UVS, UKS, OVS, OKS, IV0: TBytes;
begin
  UPw := TEncoding.UTF8.GetBytes(UserPw);
  OPw := TEncoding.UTF8.GetBytes(OwnerPw);
  UVS := Seq($10, 8);
  UKS := Seq($20, 8);
  OVS := Seq($30, 8);
  OKS := Seq($40, 8);
  IV0 := ZeroBytes(16);
  U := Cat([TestHash(R, UPw, UVS, nil), UVS, UKS]);
  UE := PdfAESCBCEncryptNoPad(TestHash(R, UPw, UKS, nil), IV0, FileKey);
  O := Cat([TestHash(R, OPw, OVS, U), OVS, OKS]);
  OE := PdfAESCBCEncryptNoPad(TestHash(R, OPw, OKS, U), IV0, FileKey);
  Perms := PdfAESCBCEncryptNoPad(FileKey, IV0,
    Cat([LE32(P), HexToBytes('FFFFFFFF'), AsciiBytes('Tadb'), Seq(1, 4)]));
end;

/// Algorithm 1, written independently.
function TestObjectKey(const FileKey: TBytes; Num, Gen: Integer; AES: Boolean): TBytes;
var
  B: TBytes;
  N: Integer;
begin
  B := Cat([FileKey, TBytes.Create(Byte(Num), Byte(Num shr 8), Byte(Num shr 16),
    Byte(Gen), Byte(Gen shr 8))]);
  if AES then
    B := Cat([B, AsciiBytes('sAlT')]);
  N := Integer(Length(FileKey)) + 5;
  if N > 16 then
    N := 16;
  Result := Copy(PdfMD5(B), 0, N);
end;

/// AES-CBC with PKCS#5 padding; result = IV + ciphertext.
function TestAESEncrypt(const Key, IV, Plain: TBytes): TBytes;
var
  PadLen: Integer;
  Padded: TBytes;
begin
  PadLen := 16 - Integer(Length(Plain)) mod 16;
  Padded := Cat([Plain, ZeroBytes(PadLen)]);
  FillChar(Padded[Length(Plain)], PadLen, PadLen);
  Result := Cat([IV, PdfAESCBCEncryptNoPad(Key, IV, Padded)]);
end;

function LegacyParams(R, KeyBits: Integer; const UserPw, OwnerPw: string; Method: TPdfCryptMethod;
  EncryptMetadata: Boolean; out Key: TBytes; ForceOwnerPw: Boolean = False): TPdfEncryptParams;
begin
  Result := Default(TPdfEncryptParams);
  case R of
    2: Result.V := 1;
    3: Result.V := 2;
  else
    Result.V := 4;
  end;
  Result.R := R;
  Result.KeyLengthBits := KeyBits;
  Result.P := -1340;
  Result.ID0 := HexToBytes('00112233445566778899AABBCCDDEEFF');
  Result.EncryptMetadata := EncryptMetadata;
  Result.StreamMethod := Method;
  Result.StringMethod := Method;
  LegacyEncrypt(R, KeyBits, UserPw, OwnerPw, Result.P, Result.ID0, EncryptMetadata, ForceOwnerPw,
    Result.O, Result.U, Key);
end;

function ModernParams(R: Integer; const UserPw, OwnerPw: string; const FileKey: TBytes): TPdfEncryptParams;
begin
  Result := Default(TPdfEncryptParams);
  Result.V := 5;
  Result.R := R;
  Result.KeyLengthBits := 256;
  Result.P := -3904;
  Result.EncryptMetadata := True;
  Result.StreamMethod := cmAESV3;
  Result.StringMethod := cmAESV3;
  ModernEncrypt(R, UserPw, OwnerPw, Result.P, FileKey, Result.O, Result.U, Result.OE, Result.UE, Result.Perms);
end;

procedure CheckOpens(const Params: TPdfEncryptParams; const Password: string; ExpectOwner: Boolean;
  const ExpectedKey: TBytes);
var
  H: TPdfStandardSecurityHandler;
begin
  H := TPdfStandardSecurityHandler.Create(Params, Password);
  try
    Assert.IsTrue(ExpectOwner = H.IsOwner, 'IsOwner for password "' + Password + '"');
    AssertBytes(ExpectedKey, H.FileKey, 'FileKey for password "' + Password + '"');
  finally
    H.Free;
  end;
end;

procedure CheckRaises(const Params: TPdfEncryptParams; const Password: string; EClass: ExceptClass);
begin
  Assert.WillRaise(
    procedure
    begin
      TPdfStandardSecurityHandler.Create(Params, Password).Free;
    end, EClass);
end;

{ ---------------------------------------------------------------------------- }
{ TPdfCryptoPrimitiveTests                                                     }
{ ---------------------------------------------------------------------------- }

procedure CheckAESBlock(KeyLen: Integer; const ExpectedHex: string);
var
  Key, Plain, IV0, Cipher: TBytes;
begin
  Key := Seq(0, KeyLen);
  Plain := HexToBytes('00112233445566778899AABBCCDDEEFF');
  IV0 := ZeroBytes(16);
  // Single block with a zero IV is plain ECB
  Cipher := PdfAESCBCEncryptNoPad(Key, IV0, Plain);
  Assert.AreEqual(ExpectedHex, BytesToHex(Cipher), 'encrypt');
  AssertBytes(Plain, PdfAESCBCDecryptNoPad(Key, IV0, Cipher), 'decrypt');
end;

procedure TPdfCryptoPrimitiveTests.AES128_FIPS197;
begin
  CheckAESBlock(16, '69C4E0D86A7B0430D8CDB78070B4C55A');
end;

procedure TPdfCryptoPrimitiveTests.AES192_FIPS197;
begin
  CheckAESBlock(24, 'DDA97CA4864CDFE06EAF70A0EC0D7191');
end;

procedure TPdfCryptoPrimitiveTests.AES256_FIPS197;
begin
  CheckAESBlock(32, '8EA2B7CA516745BFEAFC49904B496089');
end;

procedure TPdfCryptoPrimitiveTests.AES128_CBC_SP800_38A;
var
  Key, IV, Plain, Cipher: TBytes;
begin
  // NIST SP 800-38A F.2.1 / F.2.2 (first two blocks)
  Key := HexToBytes('2B7E151628AED2A6ABF7158809CF4F3C');
  IV := Seq(0, 16);
  Plain := HexToBytes('6BC1BEE22E409F96E93D7E117393172AAE2D8A571E03AC9C9EB76FAC45AF8E51');
  Cipher := PdfAESCBCEncryptNoPad(Key, IV, Plain);
  Assert.AreEqual('7649ABAC8119B246CEE98E9B12E9197D5086CB9B507219EE95DB113A917678B2', BytesToHex(Cipher));
  AssertBytes(Plain, PdfAESCBCDecryptNoPad(Key, IV, Cipher));
  // Without padding bytes at the end, PdfAESCBCDecrypt must not strip anything
  AssertBytes(Plain, PdfAESCBCDecrypt(Key, Cat([IV, Cipher])));
end;

procedure TPdfCryptoPrimitiveTests.AESCBC_PKCS5_RoundTrip;
var
  KeyLen, Len: Integer;
  Key, IV, Plain, Enc: TBytes;
begin
  for KeyLen in [16, 32] do
    for Len in [0, 1, 5, 15, 16, 17, 31, 32, 33, 100] do
    begin
      Key := Seq(KeyLen, KeyLen);
      IV := Seq($90, 16);
      Plain := Seq(Len * 3, Len);
      Enc := TestAESEncrypt(Key, IV, Plain);
      Assert.AreEqual(Integer(16 + (Len div 16 + 1) * 16), Integer(Length(Enc)));
      AssertBytes(Plain, PdfAESCBCDecrypt(Key, Enc), Format('key %d, len %d', [KeyLen, Len]));
    end;
end;

procedure TPdfCryptoPrimitiveTests.AESCBC_Tolerance;
var
  Key, IV, Plain, Enc, Bad: TBytes;
begin
  Key := Seq(1, 16);
  IV := Seq($50, 16);
  // Shorter than one block, or IV only: empty result
  Assert.AreEqual(0, Integer(Length(PdfAESCBCDecrypt(Key, nil))));
  Assert.AreEqual(0, Integer(Length(PdfAESCBCDecrypt(Key, Seq(0, 10)))));
  Assert.AreEqual(0, Integer(Length(PdfAESCBCDecrypt(Key, IV))));
  // Trailing partial block is ignored
  Plain := AsciiBytes('Hello, encrypted world!');
  Enc := TestAESEncrypt(Key, IV, Plain);
  AssertBytes(Plain, PdfAESCBCDecrypt(Key, Cat([Enc, Seq(7, 5)])), 'partial block');
  // Invalid padding (last block ends in 0) is not stripped
  Bad := Cat([Seq(65, 31), ZeroBytes(1)]);
  Enc := Cat([IV, PdfAESCBCEncryptNoPad(Key, IV, Bad)]);
  AssertBytes(Bad, PdfAESCBCDecrypt(Key, Enc), 'zero pad byte');
  // Inconsistent padding (last byte 3 but preceding bytes differ) is not stripped
  Bad := Cat([Seq(65, 29), TBytes.Create(1, 2, 3)]);
  Enc := Cat([IV, PdfAESCBCEncryptNoPad(Key, IV, Bad)]);
  AssertBytes(Bad, PdfAESCBCDecrypt(Key, Enc), 'inconsistent pad');
  // A full padding block (16 x 16) is stripped
  Enc := TestAESEncrypt(Key, IV, Seq(0, 16));
  AssertBytes(Seq(0, 16), PdfAESCBCDecrypt(Key, Enc), 'full pad block');
end;

procedure TPdfCryptoPrimitiveTests.AES_InvalidArguments;
begin
  Assert.WillRaise(
    procedure
    begin
      PdfAESCBCDecrypt(Seq(0, 10), Seq(0, 32));
    end, EPdfEncryptionError);
  Assert.WillRaise(
    procedure
    begin
      PdfAESCBCEncryptNoPad(Seq(0, 16), Seq(0, 16), Seq(0, 17));
    end, EPdfEncryptionError);
  Assert.WillRaise(
    procedure
    begin
      PdfAESCBCDecryptNoPad(Seq(0, 16), Seq(0, 8), Seq(0, 16));
    end, EPdfEncryptionError);
  Assert.AreEqual(0, Integer(Length(PdfAESCBCEncryptNoPad(Seq(0, 32), Seq(0, 16), nil))));
end;

procedure TPdfCryptoPrimitiveTests.RC4_Vectors;
begin
  Assert.AreEqual('BBF316E8D940AF0AD3', BytesToHex(PdfRC4(AsciiBytes('Key'), AsciiBytes('Plaintext'))));
  Assert.AreEqual('1021BF0420', BytesToHex(PdfRC4(AsciiBytes('Wiki'), AsciiBytes('pedia'))));
  Assert.AreEqual('45A01F645FC35B383552544B9BF5',
    BytesToHex(PdfRC4(AsciiBytes('Secret'), AsciiBytes('Attack at dawn'))));
  // Symmetric
  Assert.AreEqual('Plaintext', TEncoding.ASCII.GetString(
    PdfRC4(AsciiBytes('Key'), HexToBytes('BBF316E8D940AF0AD3'))));
end;

procedure TPdfCryptoPrimitiveTests.RC4_EmptyInputs;
begin
  Assert.AreEqual(0, Integer(Length(PdfRC4(AsciiBytes('Key'), nil))));
  AssertBytes(AsciiBytes('abc'), PdfRC4(nil, AsciiBytes('abc')));
end;

procedure TPdfCryptoPrimitiveTests.Hash_Vectors;
var
  Abc: TBytes;
begin
  Abc := AsciiBytes('abc');
  Assert.AreEqual('900150983CD24FB0D6963F7D28E17F72', BytesToHex(PdfMD5(Abc)));
  Assert.AreEqual('D41D8CD98F00B204E9800998ECF8427E', BytesToHex(PdfMD5(nil)));
  Assert.AreEqual('BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD',
    BytesToHex(PdfSHA256(Abc)));
  Assert.AreEqual('E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855',
    BytesToHex(PdfSHA256(nil)));
  Assert.AreEqual('CB00753F45A35E8BB5A03D699AC65007272C32AB0EDED1631A8B605A43FF5BED' +
    '8086072BA1E7CC2358BAECA134C825A7', BytesToHex(PdfSHA384(Abc)));
  Assert.AreEqual('DDAF35A193617ABACC417349AE20413112E6FA4E89A97EA20A9EEEE64B55D39A' +
    '2192992A274FC1A836BA3C23A3FEEBBD454D4423643CE80E2A9AC94FA54CA49F', BytesToHex(PdfSHA512(Abc)));
end;

{ ---------------------------------------------------------------------------- }
{ TPdfSecurityHandlerTests                                                     }
{ ---------------------------------------------------------------------------- }

procedure TPdfSecurityHandlerTests.R2_EmptyUserPassword;
var
  P: TPdfEncryptParams;
  Key: TBytes;
begin
  P := LegacyParams(2, 40, '', 'secret', cmRC4, True, Key);
  Assert.AreEqual(5, Integer(Length(Key)));
  CheckOpens(P, '', False, Key);
  CheckOpens(P, 'secret', True, Key);
  CheckRaises(P, 'wrong', EPdfPasswordError);
end;

procedure TPdfSecurityHandlerTests.R3_UserAndOwnerPasswords;
var
  P: TPdfEncryptParams;
  Key: TBytes;
  Bits: Integer;
begin
  for Bits in [40, 64, 128] do
  begin
    P := LegacyParams(3, Bits, 'user', 'owner', cmRC4, True, Key);
    Assert.AreEqual(Bits div 8, Integer(Length(Key)));
    CheckOpens(P, 'user', False, Key);
    CheckOpens(P, 'owner', True, Key);
    CheckRaises(P, '', EPdfPasswordError);
  end;
end;

procedure TPdfSecurityHandlerTests.R4_EncryptMetadataFalse;
var
  P, P2: TPdfEncryptParams;
  Key, Key2: TBytes;
begin
  P := LegacyParams(4, 128, '', 'owner', cmAESV2, False, Key);
  P2 := LegacyParams(4, 128, '', 'owner', cmAESV2, True, Key2);
  Assert.AreNotEqual(BytesToHex(Key), BytesToHex(Key2), 'EncryptMetadata must change the key');
  CheckOpens(P, '', False, Key);
  CheckOpens(P, 'owner', True, Key);
  CheckOpens(P2, '', False, Key2);
end;

procedure TPdfSecurityHandlerTests.Legacy_WrongPasswordRaises;
var
  P: TPdfEncryptParams;
  Key: TBytes;
begin
  P := LegacyParams(4, 128, 'user', 'owner', cmRC4, True, Key);
  CheckRaises(P, 'Owner', EPdfPasswordError);
  CheckRaises(P, '', EPdfPasswordError);
end;

procedure TPdfSecurityHandlerTests.Legacy_EmptyPasswordFallsBackToOwner;
var
  P: TPdfEncryptParams;
  Key: TBytes;
begin
  // Explicitly empty owner password with a non-empty user password: opening with
  // no password fails the user check and must then succeed through the owner path.
  P := LegacyParams(3, 128, 'user', '', cmRC4, True, Key, True);
  CheckOpens(P, '', True, Key);
  CheckOpens(P, 'user', False, Key);
  CheckRaises(P, 'nope', EPdfPasswordError);
  P := LegacyParams(2, 40, 'user', '', cmRC4, True, Key, True);
  CheckOpens(P, '', True, Key);
  P := LegacyParams(4, 128, 'user', '', cmAESV2, True, Key, True);
  CheckOpens(P, '', True, Key);
end;

procedure TPdfSecurityHandlerTests.RC4_StringRoundTrip;
var
  P: TPdfEncryptParams;
  Key, Plain, Enc: TBytes;
  H: TPdfStandardSecurityHandler;
  R: Integer;
begin
  Plain := AsciiBytes('A secret string (with parens)');
  for R in [2, 3] do
  begin
    P := LegacyParams(R, 128, '', 'owner', cmRC4, True, Key);
    H := TPdfStandardSecurityHandler.Create(P, '');
    try
      Enc := PdfRC4(TestObjectKey(Key, 12, 0, False), Plain);
      AssertBytes(Plain, H.DecryptString(Enc, 12, 0), 'string');
      Enc := PdfRC4(TestObjectKey(Key, $123456, 7, False), Plain);
      AssertBytes(Plain, H.DecryptStream(Enc, $123456, 7), 'stream');
      Assert.AreNotEqual(BytesToHex(Plain), BytesToHex(H.DecryptString(Enc, 12, 0)), 'other object key');
    finally
      H.Free;
    end;
  end;
end;

procedure TPdfSecurityHandlerTests.AESV2_StreamRoundTrip;
var
  P: TPdfEncryptParams;
  Key, Plain, Enc: TBytes;
  H: TPdfStandardSecurityHandler;
begin
  P := LegacyParams(4, 128, '', 'owner', cmAESV2, True, Key);
  Plain := AsciiBytes('BT /F1 12 Tf 72 712 Td (AESV2 stream) Tj ET');
  Enc := TestAESEncrypt(TestObjectKey(Key, 5, 0, True), Seq($A0, 16), Plain);
  H := TPdfStandardSecurityHandler.Create(P, 'owner');
  try
    Assert.IsTrue(H.IsOwner);
    AssertBytes(Plain, H.DecryptStream(Enc, 5, 0));
    AssertBytes(Plain, H.DecryptString(Enc, 5, 0));
    AssertBytes(Plain, H.Decrypt(Enc, 5, 0, cmAESV2));
  finally
    H.Free;
  end;
end;

procedure TPdfSecurityHandlerTests.R6_UserOwnerWrong;
var
  P: TPdfEncryptParams;
  FileKey: TBytes;
  H: TPdfStandardSecurityHandler;
begin
  FileKey := Seq($61, 32);
  P := ModernParams(6, 'user', 'owner', FileKey);
  CheckOpens(P, 'user', False, FileKey);
  CheckOpens(P, 'owner', True, FileKey);
  CheckRaises(P, '', EPdfPasswordError);
  CheckRaises(P, 'User', EPdfPasswordError);
  H := TPdfStandardSecurityHandler.Create(P, 'user');
  try
    Assert.IsTrue(H.PermsValid, 'Perms');
  finally
    H.Free;
  end;
  // Empty user password
  P := ModernParams(6, '', 'owner', FileKey);
  CheckOpens(P, '', False, FileKey);
  CheckOpens(P, 'owner', True, FileKey);
  // A corrupt /Perms does not prevent opening
  P.Perms := ZeroBytes(16);
  H := TPdfStandardSecurityHandler.Create(P, '');
  try
    Assert.IsFalse(H.PermsValid);
    AssertBytes(FileKey, H.FileKey);
  finally
    H.Free;
  end;
end;

procedure TPdfSecurityHandlerTests.R6_UnicodePassword;
var
  P: TPdfEncryptParams;
  FileKey: TBytes;
begin
  FileKey := Seq($11, 32);
  P := ModernParams(6, 'p'#$00E4'ssw'#$00F6'rd', #$20AC'uro', FileKey);
  CheckOpens(P, 'p'#$00E4'ssw'#$00F6'rd', False, FileKey);
  CheckOpens(P, #$20AC'uro', True, FileKey);
  CheckRaises(P, 'password', EPdfPasswordError);
end;

procedure TPdfSecurityHandlerTests.R5_UserOwnerWrong;
var
  P: TPdfEncryptParams;
  FileKey: TBytes;
begin
  FileKey := Seq($81, 32);
  P := ModernParams(5, 'user', 'owner', FileKey);
  CheckOpens(P, 'user', False, FileKey);
  CheckOpens(P, 'owner', True, FileKey);
  CheckRaises(P, 'x', EPdfPasswordError);
end;

procedure TPdfSecurityHandlerTests.AESV3_RoundTrip;
var
  P: TPdfEncryptParams;
  FileKey, Plain, Enc: TBytes;
  H: TPdfStandardSecurityHandler;
begin
  FileKey := Seq($C1, 32);
  P := ModernParams(6, '', 'owner', FileKey);
  Plain := AsciiBytes('AESV3 uses the file key directly for every object');
  Enc := TestAESEncrypt(FileKey, Seq($33, 16), Plain);
  H := TPdfStandardSecurityHandler.Create(P);
  try
    AssertBytes(Plain, H.DecryptStream(Enc, 1, 0));
    AssertBytes(Plain, H.DecryptString(Enc, 999, 3), 'object number is irrelevant');
  finally
    H.Free;
  end;
end;

procedure TPdfSecurityHandlerTests.IdentityMethod;
var
  P: TPdfEncryptParams;
  Key, Data: TBytes;
  H: TPdfStandardSecurityHandler;
begin
  P := LegacyParams(4, 128, '', 'owner', cmAESV2, True, Key);
  P.StringMethod := cmNone;
  Data := AsciiBytes('not encrypted');
  H := TPdfStandardSecurityHandler.Create(P);
  try
    AssertBytes(Data, H.Decrypt(Data, 3, 0, cmNone));
    AssertBytes(Data, H.DecryptString(Data, 3, 0));
  finally
    H.Free;
  end;
end;

procedure TPdfSecurityHandlerTests.UnsupportedParamsRaise;
var
  P: TPdfEncryptParams;
  Key: TBytes;
begin
  P := LegacyParams(3, 128, '', 'owner', cmRC4, True, Key);
  P.R := 7;
  CheckRaises(P, '', EPdfEncryptionError);
  P.R := 1;
  CheckRaises(P, '', EPdfEncryptionError);
  P.R := 3;
  P.V := 3;
  CheckRaises(P, '', EPdfEncryptionError);
  P := ModernParams(6, '', 'owner', Seq(0, 32));
  P.U := Copy(P.U, 0, 40);
  CheckRaises(P, '', EPdfEncryptionError);
end;

{ ---------------------------------------------------------------------------- }
{ TPdfEncryptedSampleTests                                                     }
{ ---------------------------------------------------------------------------- }

const
  // trailer /ID[0] shared by all samples
  SAMPLE_ID0 = '0C92B42BC7B33D80C5D5415C4EF60E50';
  // the content stream is object 4 0 in every sample
  SAMPLE_CONTENT = 'BT /F1 24 Tf 20 40 Td (Hello) Tj ET'#10;

  // enc_rc4_40.pdf: V=1 R=2 P=-4 user="" owner="owner"
  RC4_40_O = 'C92422687FACEE686E373F10B5C7D04738053152F7E2EE30E11C69EC442576AB';
  RC4_40_U = '470CA099DC89672E9E00527C3D482F23CFBEECD1089499719FBD59C73C250973';
  RC4_40_FILEKEY = '842B40B945';
  RC4_40_STREAM =
    'B0E4C032E9104857EF45319990721300D54720CC8D12415D28EBACC2FB6C4847' +
    'A8D2E543';

  // enc_rc4_128.pdf: V=2 R=3 Length=128 P=-4 user="" owner="owner"
  RC4_128_O = '566FA873EE33C797CD3B904FDADF814AFA34DF9A38F6ED41B984E2C6DA2AA6F5';
  RC4_128_U = '960B95D2EBBE3E502454521077C0603D00000000000000000000000000000000';
  RC4_128_FILEKEY = '338F9B725D380002E9FCD2FF2C466888';
  RC4_128_STREAM =
    'C1FEFCFBC35C784B9FCA97B0600F64190BB768721488330E4AFAEB35613E30F7' +
    '87EBE1C0';

  // enc_aes128.pdf: V=4 R=4 Length=128 /StdCF AESV2 P=-4 user="" owner="owner"
  AES128_O = '566FA873EE33C797CD3B904FDADF814AFA34DF9A38F6ED41B984E2C6DA2AA6F5';
  AES128_U = '960B95D2EBBE3E502454521077C0603D00000000000000000000000000000000';
  AES128_FILEKEY = '338F9B725D380002E9FCD2FF2C466888';
  AES128_STREAM =
    'A0A1A2A3A4A5A6A7A8A9AAABACADAEAFA8DE310EEA3FD21065DA74CECE1D0114' +
    'C04F0B44F955343211676C46D3B1BBA6A2F3E2F0090AF7FAE8A7BC45EB4E821F';

  // enc_aes256.pdf: V=5 R=6 Length=256 /StdCF AESV3 P=-4 user="" owner="owner"
  AES256_O =
    '1E176CECCA2994E8557A48A44C9CC18D1E3A48631F0366CAC8941B897275D9C4' +
    '21222324252627283132333435363738';
  AES256_U =
    '8D1EFB4F1BDBB651341704C2139DE4F6BE05D6D4609AF56916B21646ED74825C' +
    '01020304050607081112131415161718';
  AES256_OE = '095C642E9B9D176DDA204B6B109B2F7FB47ADFDA2101D923B270AA47CDCFBB3C';
  AES256_UE = 'BD68D8F23E4A1C4602617A5D81B8114A8A53C5ABC49D918A8D2A7E3AA9F0BD01';
  AES256_PERMS = '73FAF0E6BFD585942E0536CD740A7FB5';
  AES256_FILEKEY = '9F836E0A4AE0BC852B58CB8E0BA15A0CCFE4FDE78812F2F2AC31947330367DAE';
  AES256_STREAM =
    'A0A1A2A3A4A5A6A7A8A9AAABACADAEAFFFD633D2C1D3EB2EBBAA257C262DEE88' +
    'FF16F52D27B6C40AB87F8AE48AC71BA81678DDDCD584A51C0DD87A29208E8CEE';

  // enc_aes256_user.pdf: V=5 R=6 Length=256 /StdCF AESV3 P=-4 user="user" owner="owner"
  AES256_USER_O =
    '7E1314D50A58A555C4F7B9CF875A1981C87FCA8FCDE1587F76A28FCFDF5E00D3' +
    '21222324252627283132333435363738';
  AES256_USER_U =
    '17424B40EAD366F7DDEF0FF073608AA68BA701714B5CEF3409B94C4FFA763726' +
    '01020304050607081112131415161718';
  AES256_USER_OE = 'DC3517341E8101DBDECFE7C9605BA2614DC934921ABA1AB4D7895B101AB95FC0';
  AES256_USER_UE = 'BFE39D7CE743FF2EB970D4CCECE6728BD6FF4F806557D309C8F14B47203B1D37';
  AES256_USER_PERMS = '8AE17C4DADE3CD2790F36E6CC8E3AB7A';
  AES256_USER_FILEKEY = 'A59C6E4D13DC0765796912F8660EB163BE446973BD163718E5E10CE0E0580302';
  AES256_USER_STREAM =
    'A0A1A2A3A4A5A6A7A8A9AAABACADAEAF5BF57EF74E64567A5C0435D9FFDF47C6' +
    '77D1FEBF2CBD87D500038BE41C4D108479433E148953332646DC811D14BC7A42';

function SampleParams(V, R, Bits: Integer; Method: TPdfCryptMethod;
  const O, U, OE, UE, Perms: string): TPdfEncryptParams;
begin
  Result := Default(TPdfEncryptParams);
  Result.V := V;
  Result.R := R;
  Result.KeyLengthBits := Bits;
  Result.P := -4;
  Result.O := HexToBytes(O);
  Result.U := HexToBytes(U);
  Result.OE := HexToBytes(OE);
  Result.UE := HexToBytes(UE);
  Result.Perms := HexToBytes(Perms);
  Result.ID0 := HexToBytes(SAMPLE_ID0);
  Result.EncryptMetadata := True;
  Result.StreamMethod := Method;
  Result.StringMethod := Method;
end;

procedure CheckSample(const Params: TPdfEncryptParams; const Password: string; ExpectOwner: Boolean;
  const FileKeyHex, StreamHex: string);
var
  H: TPdfStandardSecurityHandler;
  Plain: string;
begin
  H := TPdfStandardSecurityHandler.Create(Params, Password);
  try
    Assert.IsTrue(ExpectOwner = H.IsOwner, 'IsOwner');
    Assert.AreEqual(FileKeyHex, BytesToHex(H.FileKey), 'FileKey');
    Plain := PdfBytesToLatin1(H.DecryptStream(HexToBytes(StreamHex), 4, 0));
    Assert.Contains(Plain, 'Hello');
    Assert.AreEqual(SAMPLE_CONTENT, Plain);
    if Params.R >= 5 then
      Assert.IsTrue(H.PermsValid, 'Perms');
  finally
    H.Free;
  end;
end;

procedure TPdfEncryptedSampleTests.Sample_RC4_40;
var
  P: TPdfEncryptParams;
begin
  P := SampleParams(1, 2, 0, cmRC4, RC4_40_O, RC4_40_U, '', '', '');
  CheckSample(P, '', False, RC4_40_FILEKEY, RC4_40_STREAM);
  CheckSample(P, 'owner', True, RC4_40_FILEKEY, RC4_40_STREAM);
  CheckRaises(P, 'wrong', EPdfPasswordError);
end;

procedure TPdfEncryptedSampleTests.Sample_RC4_128;
var
  P: TPdfEncryptParams;
begin
  P := SampleParams(2, 3, 128, cmRC4, RC4_128_O, RC4_128_U, '', '', '');
  CheckSample(P, '', False, RC4_128_FILEKEY, RC4_128_STREAM);
  CheckSample(P, 'owner', True, RC4_128_FILEKEY, RC4_128_STREAM);
  CheckRaises(P, 'wrong', EPdfPasswordError);
end;

procedure TPdfEncryptedSampleTests.Sample_AES128;
var
  P: TPdfEncryptParams;
begin
  P := SampleParams(4, 4, 128, cmAESV2, AES128_O, AES128_U, '', '', '');
  CheckSample(P, '', False, AES128_FILEKEY, AES128_STREAM);
  CheckSample(P, 'owner', True, AES128_FILEKEY, AES128_STREAM);
  CheckRaises(P, 'wrong', EPdfPasswordError);
end;

procedure TPdfEncryptedSampleTests.Sample_AES256;
var
  P: TPdfEncryptParams;
begin
  P := SampleParams(5, 6, 256, cmAESV3, AES256_O, AES256_U, AES256_OE, AES256_UE, AES256_PERMS);
  CheckSample(P, '', False, AES256_FILEKEY, AES256_STREAM);
  CheckSample(P, 'owner', True, AES256_FILEKEY, AES256_STREAM);
  CheckRaises(P, 'wrong', EPdfPasswordError);
end;

procedure TPdfEncryptedSampleTests.Sample_AES256_UserPassword;
var
  P: TPdfEncryptParams;
begin
  P := SampleParams(5, 6, 256, cmAESV3, AES256_USER_O, AES256_USER_U, AES256_USER_OE, AES256_USER_UE,
    AES256_USER_PERMS);
  CheckRaises(P, '', EPdfPasswordError);
  CheckSample(P, 'user', False, AES256_USER_FILEKEY, AES256_USER_STREAM);
  CheckSample(P, 'owner', True, AES256_USER_FILEKEY, AES256_USER_STREAM);
end;

initialization
  TDUnitX.RegisterTestFixture(TPdfCryptoPrimitiveTests);
  TDUnitX.RegisterTestFixture(TPdfSecurityHandlerTests);
  TDUnitX.RegisterTestFixture(TPdfEncryptedSampleTests);

end.
