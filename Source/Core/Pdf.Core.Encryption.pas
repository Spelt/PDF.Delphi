{*******************************************************************************
  Pdf.Core.Encryption
  The PDF standard security handler (PDF 32000-1 7.6.3, ISO 32000-2 7.6.4):
  password validation, file key derivation and per-object decryption for
  revisions 2, 3, 4 (RC4 / AESV2), 5 (Adobe Extension Level 3) and 6 (AESV3).

  Works on plain values only (TPdfEncryptParams); resolving the /Encrypt
  dictionary, /CF, /StmF and /StrF is the caller's job.

  Portions derived from pdf.js (Mozilla, Apache License 2.0),
  src/core/crypto.js (CipherTransformFactory, PDF17/PDF20 algorithms).
*******************************************************************************}
unit Pdf.Core.Encryption;

{$R-}
{$Q-}

interface

uses
  System.SysUtils, System.Math, Pdf.Core.Types, Pdf.Core.Crypto;

type
  /// <summary>Decryption method of a crypt filter.</summary>
  TPdfCryptMethod = (cmNone, cmRC4, cmAESV2, cmAESV3);

  /// <summary>Plain values of a standard security handler /Encrypt dictionary.</summary>
  TPdfEncryptParams = record
    /// <summary>/V (algorithm) and /R (revision).</summary>
    V, R: Integer;
    /// <summary>/Length in bits; 40 when missing (V=1). Values below 40 are taken as bytes.</summary>
    KeyLengthBits: Integer;
    /// <summary>Signed 32-bit /P permission flags.</summary>
    P: Integer;
    /// <summary>Raw bytes of /O, /U, /OE, /UE and /Perms (the latter three only for R &gt;= 5).</summary>
    O, U, OE, UE, Perms: TBytes;
    /// <summary>First element of the trailer /ID (may be empty).</summary>
    ID0: TBytes;
    /// <summary>/EncryptMetadata; True by default.</summary>
    EncryptMetadata: Boolean;
    /// <summary>Methods for streams and strings, resolved by the caller from /CF /StmF /StrF.
    /// For V &lt; 4 both are cmRC4.</summary>
    StreamMethod, StringMethod: TPdfCryptMethod;
  end;

  /// <summary>Standard security handler: validates a password and decrypts strings and streams.</summary>
  TPdfStandardSecurityHandler = class
  private
    FParams: TPdfEncryptParams;
    FFileKey: TBytes;
    FIsOwner: Boolean;
    FPermsValid: Boolean;
    FKeyLength: Integer;
    function ComputeFileKeyR4(const PaddedPassword: TBytes): TBytes;
    function CheckUserR4(const PaddedPassword: TBytes; out Key: TBytes): Boolean;
    function DecodeUserPasswordFromOwner(const PaddedOwner: TBytes): TBytes;
    procedure OpenR4(const Password: string);
    procedure OpenR6(const Password: string);
    procedure VerifyPerms;
    function ObjectKey(ObjNum, ObjGen: Integer; AES: Boolean): TBytes;
  public
    /// <summary>Validates Password (user first, then owner) and derives the file key.
    /// Raises EPdfPasswordError when neither matches and EPdfEncryptionError for
    /// unsupported or malformed parameters.</summary>
    constructor Create(const Params: TPdfEncryptParams; const Password: string = '');
    /// <summary>Decrypts a string of object ObjNum/ObjGen with the string method.</summary>
    function DecryptString(const Data: TBytes; ObjNum, ObjGen: Integer): TBytes;
    /// <summary>Decrypts a stream of object ObjNum/ObjGen with the stream method.</summary>
    function DecryptStream(const Data: TBytes; ObjNum, ObjGen: Integer): TBytes;
    /// <summary>Decrypts with an explicit method (used for /Identity crypt filters on
    /// individual streams). cmNone returns Data unchanged.</summary>
    function Decrypt(const Data: TBytes; ObjNum, ObjGen: Integer; Method: TPdfCryptMethod): TBytes;
    /// <summary>True when the owner password matched.</summary>
    property IsOwner: Boolean read FIsOwner;
    /// <summary>The derived file encryption key.</summary>
    property FileKey: TBytes read FFileKey;
    /// <summary>The parameters this handler was created with (normalised key length).</summary>
    property Params: TPdfEncryptParams read FParams;
    /// <summary>R &gt;= 5 only: True when /Perms decrypted with the file key carries the
    /// 'adb' marker. A mismatch is not treated as an error.</summary>
    property PermsValid: Boolean read FPermsValid;
  end;

/// <summary>The 32-byte padding string of Algorithm 2 step (a).</summary>
function PdfPasswordPad: TBytes;
/// <summary>Password bytes for R &lt;= 4: Latin-1 bytes, truncated/padded to 32 bytes with
/// the standard padding string.</summary>
function PdfPadPassword(const Password: string): TBytes;

implementation

const
  PasswordPadding: array[0..31] of Byte = (
    $28, $BF, $4E, $5E, $4E, $75, $8A, $41, $64, $00, $4E, $56, $FF, $FA, $01, $08,
    $2E, $2E, $00, $B6, $D0, $68, $3E, $80, $2F, $0C, $A9, $FE, $64, $53, $69, $7A);

function PdfPasswordPad: TBytes;
begin
  SetLength(Result, 32);
  Move(PasswordPadding[0], Result[0], 32);
end;

function PdfPadPassword(const Password: string): TBytes;
var
  Raw: TBytes;
  N: Integer;
begin
  Raw := PdfLatin1ToBytes(Password);
  N := Min(Integer(Length(Raw)), 32);
  SetLength(Result, 32);
  if N > 0 then
    Move(Raw[0], Result[0], N);
  if N < 32 then
    Move(PasswordPadding[0], Result[N], 32 - N);
end;

function FixedBytes(const Data: TBytes; Len: Integer): TBytes;
begin
  // First Len bytes of Data, zero-padded when Data is shorter
  SetLength(Result, Len);
  FillChar(Result[0], Len, 0);
  if Length(Data) > 0 then
    Move(Data[0], Result[0], Min(Integer(Length(Data)), Len));
end;

function SameBytes(const A: TBytes; AStart: Integer; const B: TBytes; BStart, Len: Integer): Boolean;
var
  I: Integer;
begin
  if (AStart + Len > Length(A)) or (BStart + Len > Length(B)) then
    Exit(False);
  for I := 0 to Len - 1 do
    if A[AStart + I] <> B[BStart + I] then
      Exit(False);
  Result := True;
end;

function XorKey(const Key: TBytes; Value: Byte): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(Key));
  for I := 0 to Integer(Length(Key)) - 1 do
    Result[I] := Key[I] xor Value;
end;

function Int32LE(Value: Integer): TBytes;
var
  C: Cardinal;
begin
  C := Cardinal(Value);
  SetLength(Result, 4);
  Result[0] := Byte(C);
  Result[1] := Byte(C shr 8);
  Result[2] := Byte(C shr 16);
  Result[3] := Byte(C shr 24);
end;

{ ---------------------------------------------------------------------------- }
{ R5 / R6 hashes                                                               }
{ ---------------------------------------------------------------------------- }

/// Algorithm 2.B (ISO 32000-2): hardened hash used by R6.
function HashR6(const Password, Salt, UserData: TBytes): TBytes;
var
  K, K1, E, Unit1, Key, IV: TBytes;
  I, J, UnitLen, Sum: Integer;
begin
  K := PdfSHA256(PdfConcatBytes(PdfConcatBytes(Password, Salt), UserData));
  I := 0;
  while True do
  begin
    Unit1 := PdfConcatBytes(PdfConcatBytes(Password, K), UserData);
    UnitLen := Integer(Length(Unit1));
    SetLength(K1, UnitLen * 64);
    for J := 0 to 63 do
      Move(Unit1[0], K1[J * UnitLen], UnitLen);
    Key := PdfCopyBytes(K, 0, 16);
    IV := PdfCopyBytes(K, 16, 16);
    E := PdfAESCBCEncryptNoPad(Key, IV, K1);
    Sum := 0;
    for J := 0 to 15 do
      Inc(Sum, E[J]);
    case Sum mod 3 of
      0: K := PdfSHA256(E);
      1: K := PdfSHA384(E);
    else
      K := PdfSHA512(E);
    end;
    Inc(I);
    // I = number of rounds done so far (pdf.js: while (i < 64 || e.at(-1) > i - 32))
    if (I >= 64) and (E[High(E)] <= I - 32) then
      Break;
  end;
  Result := PdfCopyBytes(K, 0, 32);
end;

function HashR5(const Password, Salt, UserData: TBytes): TBytes;
begin
  Result := PdfSHA256(PdfConcatBytes(PdfConcatBytes(Password, Salt), UserData));
end;

{ ---------------------------------------------------------------------------- }
{ TPdfStandardSecurityHandler                                                  }
{ ---------------------------------------------------------------------------- }

constructor TPdfStandardSecurityHandler.Create(const Params: TPdfEncryptParams; const Password: string);
var
  Bits: Integer;
begin
  inherited Create;
  FParams := Params;
  if not (FParams.V in [1, 2, 4, 5]) then
    raise EPdfEncryptionError.CreateFmt('Unsupported encryption algorithm /V %d', [FParams.V]);
  if not (FParams.R in [2..6]) then
    raise EPdfEncryptionError.CreateFmt('Unsupported security handler revision /R %d', [FParams.R]);

  // Normalise the key length (pdf.js tolerance: values below 40 are bytes)
  Bits := FParams.KeyLengthBits;
  if FParams.V = 1 then
    Bits := 40
  else if Bits <= 0 then
  begin
    if FParams.V >= 4 then
      Bits := 128
    else
      Bits := 40;
  end
  else if Bits < 40 then
    Bits := Bits * 8;
  if (FParams.StreamMethod = cmAESV2) or (FParams.StringMethod = cmAESV2) then
    Bits := 128;
  if FParams.R >= 5 then
    Bits := 256
  else
    Bits := EnsureRange(Bits - Bits mod 8, 40, 128);
  FParams.KeyLengthBits := Bits;
  if FParams.R = 2 then
    FKeyLength := 5
  else
    FKeyLength := Bits div 8;

  if FParams.R >= 5 then
    OpenR6(Password)
  else
    OpenR4(Password);
end;

function TPdfStandardSecurityHandler.ComputeFileKeyR4(const PaddedPassword: TBytes): TBytes;
var
  Buf, Hash: TBytes;
  I: Integer;
begin
  // Algorithm 2
  Buf := PdfConcatBytes(PaddedPassword, FixedBytes(FParams.O, 32));
  Buf := PdfConcatBytes(Buf, Int32LE(FParams.P));
  Buf := PdfConcatBytes(Buf, FParams.ID0);
  if (FParams.R >= 4) and not FParams.EncryptMetadata then
    Buf := PdfConcatBytes(Buf, Int32LE(-1));
  Hash := PdfMD5(Buf);
  if FParams.R >= 3 then
    for I := 1 to 50 do
      Hash := PdfMD5(PdfCopyBytes(Hash, 0, FKeyLength));
  Result := PdfCopyBytes(Hash, 0, FKeyLength);
end;

function TPdfStandardSecurityHandler.CheckUserR4(const PaddedPassword: TBytes; out Key: TBytes): Boolean;
var
  Check: TBytes;
  I: Integer;
begin
  Key := ComputeFileKeyR4(PaddedPassword);
  if FParams.R = 2 then
  begin
    // Algorithm 4
    Check := PdfRC4(Key, PdfPasswordPad);
    Result := SameBytes(Check, 0, FParams.U, 0, 32);
  end
  else
  begin
    // Algorithm 5
    Check := PdfMD5(PdfConcatBytes(PdfPasswordPad, FParams.ID0));
    Check := PdfRC4(Key, Check);
    for I := 1 to 19 do
      Check := PdfRC4(XorKey(Key, Byte(I)), Check);
    Result := SameBytes(Check, 0, FParams.U, 0, 16);
  end;
  if not Result then
    Key := nil;
end;

function TPdfStandardSecurityHandler.DecodeUserPasswordFromOwner(const PaddedOwner: TBytes): TBytes;
var
  Hash, Key: TBytes;
  I: Integer;
begin
  // Algorithm 7 (via Algorithm 3 steps a-d)
  Hash := PdfMD5(PaddedOwner);
  if FParams.R >= 3 then
    for I := 1 to 50 do
      Hash := PdfMD5(Hash);
  Key := PdfCopyBytes(Hash, 0, FKeyLength);
  Result := FixedBytes(FParams.O, 32);
  if FParams.R = 2 then
    Result := PdfRC4(Key, Result)
  else
    for I := 19 downto 0 do
      Result := PdfRC4(XorKey(Key, Byte(I)), Result);
end;

procedure TPdfStandardSecurityHandler.OpenR4(const Password: string);
var
  Padded, Key: TBytes;
begin
  Padded := PdfPadPassword(Password);
  if CheckUserR4(Padded, Key) then
  begin
    FFileKey := Key;
    FIsOwner := False;
    Exit;
  end;
  if CheckUserR4(DecodeUserPasswordFromOwner(Padded), Key) then
  begin
    FFileKey := Key;
    FIsOwner := True;
    Exit;
  end;
  raise EPdfPasswordError.Create('Incorrect password');
end;

procedure TPdfStandardSecurityHandler.OpenR6(const Password: string);
type
  THashFunc = function(const Password, Salt, UserData: TBytes): TBytes;
var
  Pw, O, U, Intermediate, ZeroIV: TBytes;
  Hash: THashFunc;
begin
  Pw := TEncoding.UTF8.GetBytes(Password);
  if Length(Pw) > 127 then
    SetLength(Pw, 127);
  if (Length(FParams.O) < 48) or (Length(FParams.U) < 48) then
    raise EPdfEncryptionError.Create('Invalid /O or /U length for revision 5/6');
  O := PdfCopyBytes(FParams.O, 0, 48);
  U := PdfCopyBytes(FParams.U, 0, 48);
  if FParams.R = 6 then
    Hash := HashR6
  else
    Hash := HashR5;
  SetLength(ZeroIV, 16);
  FillChar(ZeroIV[0], 16, 0);

  if SameBytes(Hash(Pw, PdfCopyBytes(U, 32, 8), nil), 0, U, 0, 32) then
  begin
    if Length(FParams.UE) < 32 then
      raise EPdfEncryptionError.Create('Invalid /UE length');
    Intermediate := Hash(Pw, PdfCopyBytes(U, 40, 8), nil);
    FFileKey := PdfAESCBCDecryptNoPad(Intermediate, ZeroIV, PdfCopyBytes(FParams.UE, 0, 32));
    FIsOwner := False;
  end
  else if SameBytes(Hash(Pw, PdfCopyBytes(O, 32, 8), U), 0, O, 0, 32) then
  begin
    if Length(FParams.OE) < 32 then
      raise EPdfEncryptionError.Create('Invalid /OE length');
    Intermediate := Hash(Pw, PdfCopyBytes(O, 40, 8), U);
    FFileKey := PdfAESCBCDecryptNoPad(Intermediate, ZeroIV, PdfCopyBytes(FParams.OE, 0, 32));
    FIsOwner := True;
  end
  else
    raise EPdfPasswordError.Create('Incorrect password');
  VerifyPerms;
end;

procedure TPdfStandardSecurityHandler.VerifyPerms;
var
  ZeroIV, Plain: TBytes;
begin
  FPermsValid := False;
  if Length(FParams.Perms) < 16 then
    Exit;
  SetLength(ZeroIV, 16);
  FillChar(ZeroIV[0], 16, 0);
  Plain := PdfAESCBCDecryptNoPad(FFileKey, ZeroIV, PdfCopyBytes(FParams.Perms, 0, 16));
  FPermsValid := (Plain[9] = Ord('a')) and (Plain[10] = Ord('d')) and (Plain[11] = Ord('b'));
end;

function TPdfStandardSecurityHandler.ObjectKey(ObjNum, ObjGen: Integer; AES: Boolean): TBytes;
var
  Buf: TBytes;
  N: Integer;
begin
  // Algorithm 1
  N := Integer(Length(FFileKey));
  SetLength(Buf, N + 5 + IfThen(AES, 4, 0));
  if N > 0 then
    Move(FFileKey[0], Buf[0], N);
  Buf[N] := Byte(ObjNum);
  Buf[N + 1] := Byte(ObjNum shr 8);
  Buf[N + 2] := Byte(ObjNum shr 16);
  Buf[N + 3] := Byte(ObjGen);
  Buf[N + 4] := Byte(ObjGen shr 8);
  if AES then
  begin
    Buf[N + 5] := $73;
    Buf[N + 6] := $41;
    Buf[N + 7] := $6C;
    Buf[N + 8] := $54;
  end;
  Result := PdfCopyBytes(PdfMD5(Buf), 0, Min(N + 5, 16));
end;

function TPdfStandardSecurityHandler.Decrypt(const Data: TBytes; ObjNum, ObjGen: Integer;
  Method: TPdfCryptMethod): TBytes;
begin
  case Method of
    cmRC4:
      Result := PdfRC4(ObjectKey(ObjNum, ObjGen, False), Data);
    cmAESV2:
      Result := PdfAESCBCDecrypt(ObjectKey(ObjNum, ObjGen, True), Data);
    cmAESV3:
      Result := PdfAESCBCDecrypt(FFileKey, Data);
  else
    Result := Data;
  end;
end;

function TPdfStandardSecurityHandler.DecryptString(const Data: TBytes; ObjNum, ObjGen: Integer): TBytes;
begin
  Result := Decrypt(Data, ObjNum, ObjGen, FParams.StringMethod);
end;

function TPdfStandardSecurityHandler.DecryptStream(const Data: TBytes; ObjNum, ObjGen: Integer): TBytes;
begin
  Result := Decrypt(Data, ObjNum, ObjGen, FParams.StreamMethod);
end;

end.
