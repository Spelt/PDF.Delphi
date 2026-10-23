{*******************************************************************************
  Pdf.Core.Crypto
  Cryptographic primitives used by the PDF standard security handler:
  MD5, SHA-256/384/512 (via System.Hash), RC4 and AES (pure Pascal,
  table-based, 128/192/256-bit keys) in CBC mode.

  Portions derived from pdf.js (Mozilla, Apache License 2.0), in particular
  the tolerant AES-CBC decryption semantics of src/core/crypto.js.
  The AES round structure follows the public-domain "rijndael-alg-fst"
  reference implementation (Rijmen, Bosselaers, Barreto).

  Pure cross-platform Delphi: no OS crypto APIs.
*******************************************************************************}
unit Pdf.Core.Crypto;

{$R-}
{$Q-}

interface

uses
  System.SysUtils, System.Hash, Pdf.Core.Types;

/// <summary>MD5 digest of Data (16 bytes).</summary>
function PdfMD5(const Data: TBytes): TBytes;
/// <summary>SHA-256 digest of Data (32 bytes).</summary>
function PdfSHA256(const Data: TBytes): TBytes;
/// <summary>SHA-384 digest of Data (48 bytes).</summary>
function PdfSHA384(const Data: TBytes): TBytes;
/// <summary>SHA-512 digest of Data (64 bytes).</summary>
function PdfSHA512(const Data: TBytes): TBytes;

/// <summary>RC4 encryption/decryption (the operation is symmetric). An empty key
/// returns an unmodified copy of Data.</summary>
function PdfRC4(const Key, Data: TBytes): TBytes;

/// <summary>AES-CBC decrypt where the first 16 bytes of Data are the IV; strips
/// PKCS#5 padding when valid. Tolerant: data shorter than 16 bytes gives an empty
/// result; when the length is not a multiple of 16 the trailing partial block is
/// ignored; invalid padding is not stripped. Key length 16, 24 or 32 bytes
/// (EPdfEncryptionError otherwise).</summary>
function PdfAESCBCDecrypt(const Key, Data: TBytes): TBytes;

/// <summary>AES-CBC encryption without padding. Data length must be a multiple
/// of 16 and IV must be 16 bytes (EPdfEncryptionError otherwise). Used by the
/// ISO 32000-2 (R6) password hash.</summary>
function PdfAESCBCEncryptNoPad(const Key, IV, Data: TBytes): TBytes;

/// <summary>AES-CBC decryption without padding. Data length must be a multiple
/// of 16 and IV must be 16 bytes (EPdfEncryptionError otherwise). Used to decrypt
/// /UE and /OE (zero IV) and /Perms (one block, zero IV = ECB).</summary>
function PdfAESCBCDecryptNoPad(const Key, IV, Data: TBytes): TBytes;

implementation

{ ---------------------------------------------------------------------------- }
{ Hashes                                                                       }
{ ---------------------------------------------------------------------------- }

function PdfMD5(const Data: TBytes): TBytes;
var
  H: THashMD5;
begin
  H := THashMD5.Create;
  if Length(Data) > 0 then
    H.Update(Data, Cardinal(Length(Data)));
  Result := H.HashAsBytes;
end;

function SHA2(const Data: TBytes; Version: THashSHA2.TSHA2Version): TBytes;
var
  H: THashSHA2;
begin
  H := THashSHA2.Create(Version);
  if Length(Data) > 0 then
    H.Update(Data, Cardinal(Length(Data)));
  Result := H.HashAsBytes;
end;

function PdfSHA256(const Data: TBytes): TBytes;
begin
  Result := SHA2(Data, THashSHA2.TSHA2Version.SHA256);
end;

function PdfSHA384(const Data: TBytes): TBytes;
begin
  Result := SHA2(Data, THashSHA2.TSHA2Version.SHA384);
end;

function PdfSHA512(const Data: TBytes): TBytes;
begin
  Result := SHA2(Data, THashSHA2.TSHA2Version.SHA512);
end;

{ ---------------------------------------------------------------------------- }
{ RC4                                                                          }
{ ---------------------------------------------------------------------------- }

function PdfRC4(const Key, Data: TBytes): TBytes;
var
  S: array[0..255] of Byte;
  I, J, K, KeyLen: Integer;
  T: Byte;
begin
  SetLength(Result, Length(Data));
  if Length(Data) = 0 then
    Exit;
  KeyLen := Integer(Length(Key));
  if KeyLen = 0 then
  begin
    Move(Data[0], Result[0], Length(Data));
    Exit;
  end;
  for I := 0 to 255 do
    S[I] := Byte(I);
  J := 0;
  for I := 0 to 255 do
  begin
    J := (J + S[I] + Key[I mod KeyLen]) and $FF;
    T := S[I];
    S[I] := S[J];
    S[J] := T;
  end;
  I := 0;
  J := 0;
  for K := 0 to Integer(Length(Data)) - 1 do
  begin
    I := (I + 1) and $FF;
    J := (J + S[I]) and $FF;
    T := S[I];
    S[I] := S[J];
    S[J] := T;
    Result[K] := Data[K] xor S[(S[I] + S[J]) and $FF];
  end;
end;

{ ---------------------------------------------------------------------------- }
{ AES                                                                          }
{ ---------------------------------------------------------------------------- }

type
  TAESBlock = array[0..15] of Byte;
  TAESRoundKeys = array[0..59] of Cardinal;

  TAESContext = record
    Rounds: Integer;
    EncKey: TAESRoundKeys;
    DecKey: TAESRoundKeys;
  end;

var
  SBox, InvSBox: array[0..255] of Byte;
  Te0, Te1, Te2, Te3: array[0..255] of Cardinal;
  Td0, Td1, Td2, Td3: array[0..255] of Cardinal;
  RCon: array[0..9] of Cardinal;

function GFMul(A, B: Byte): Byte;
var
  R: Byte;
begin
  R := 0;
  while B <> 0 do
  begin
    if (B and 1) <> 0 then
      R := R xor A;
    if (A and $80) <> 0 then
      A := Byte((A shl 1) xor $1B)
    else
      A := Byte(A shl 1);
    B := Byte(B shr 1);
  end;
  Result := R;
end;

function RotR8(X: Cardinal): Cardinal; inline;
begin
  Result := (X shr 8) or (X shl 24);
end;

procedure InitAESTables;
var
  Exp: array[0..255] of Byte;
  Log: array[0..255] of Byte;
  I: Integer;
  X, Inv, S: Byte;
  R: Cardinal;
begin
  // Exp/log tables over GF(2^8) with generator 3
  X := 1;
  for I := 0 to 255 do
  begin
    Exp[I] := X;
    Log[X] := Byte(I);
    X := X xor GFMul(X, 2);
  end;
  for I := 0 to 255 do
  begin
    if I = 0 then
      Inv := 0
    else
      Inv := Exp[(255 - Log[I]) mod 255];
    // Affine transform
    S := Inv;
    S := S xor Byte((Inv shl 1) or (Inv shr 7));
    S := S xor Byte((Inv shl 2) or (Inv shr 6));
    S := S xor Byte((Inv shl 3) or (Inv shr 5));
    S := S xor Byte((Inv shl 4) or (Inv shr 4));
    S := S xor $63;
    SBox[I] := S;
    InvSBox[S] := Byte(I);
  end;
  for I := 0 to 255 do
  begin
    S := SBox[I];
    Te0[I] := (Cardinal(GFMul(S, 2)) shl 24) or (Cardinal(S) shl 16) or
      (Cardinal(S) shl 8) or Cardinal(GFMul(S, 3));
    Te1[I] := RotR8(Te0[I]);
    Te2[I] := RotR8(Te1[I]);
    Te3[I] := RotR8(Te2[I]);
    S := InvSBox[I];
    Td0[I] := (Cardinal(GFMul(S, $0E)) shl 24) or (Cardinal(GFMul(S, $09)) shl 16) or
      (Cardinal(GFMul(S, $0D)) shl 8) or Cardinal(GFMul(S, $0B));
    Td1[I] := RotR8(Td0[I]);
    Td2[I] := RotR8(Td1[I]);
    Td3[I] := RotR8(Td2[I]);
  end;
  R := 1;
  for I := 0 to 9 do
  begin
    RCon[I] := R shl 24;
    R := GFMul(Byte(R), 2);
  end;
end;

function SubWord(W: Cardinal): Cardinal; inline;
begin
  Result := (Cardinal(SBox[W shr 24]) shl 24) or
    (Cardinal(SBox[(W shr 16) and $FF]) shl 16) or
    (Cardinal(SBox[(W shr 8) and $FF]) shl 8) or
    Cardinal(SBox[W and $FF]);
end;

function InvMixColumnWord(W: Cardinal): Cardinal; inline;
begin
  Result := Td0[SBox[W shr 24]] xor Td1[SBox[(W shr 16) and $FF]] xor
    Td2[SBox[(W shr 8) and $FF]] xor Td3[SBox[W and $FF]];
end;

procedure AESInit(var Ctx: TAESContext; const Key: TBytes);
var
  Nk, Total, I, J: Integer;
  T: Cardinal;
begin
  case Integer(Length(Key)) of
    16: Nk := 4;
    24: Nk := 6;
    32: Nk := 8;
  else
    raise EPdfEncryptionError.CreateFmt('Invalid AES key length: %d bytes', [Integer(Length(Key))]);
  end;
  Ctx.Rounds := Nk + 6;
  Total := 4 * (Ctx.Rounds + 1);
  for I := 0 to Nk - 1 do
    Ctx.EncKey[I] := (Cardinal(Key[4 * I]) shl 24) or (Cardinal(Key[4 * I + 1]) shl 16) or
      (Cardinal(Key[4 * I + 2]) shl 8) or Cardinal(Key[4 * I + 3]);
  for I := Nk to Total - 1 do
  begin
    T := Ctx.EncKey[I - 1];
    if I mod Nk = 0 then
      T := SubWord((T shl 8) or (T shr 24)) xor RCon[I div Nk - 1]
    else if (Nk > 6) and (I mod Nk = 4) then
      T := SubWord(T);
    Ctx.EncKey[I] := Ctx.EncKey[I - Nk] xor T;
  end;
  // Decryption key schedule for the equivalent inverse cipher: reverse the
  // order of the round keys, then apply InvMixColumns to all but the first and last.
  for I := 0 to Ctx.Rounds do
    for J := 0 to 3 do
      Ctx.DecKey[4 * I + J] := Ctx.EncKey[4 * (Ctx.Rounds - I) + J];
  for I := 4 to 4 * Ctx.Rounds - 1 do
    Ctx.DecKey[I] := InvMixColumnWord(Ctx.DecKey[I]);
end;

function GetU32(const B: TAESBlock; Offset: Integer): Cardinal; inline;
begin
  Result := (Cardinal(B[Offset]) shl 24) or (Cardinal(B[Offset + 1]) shl 16) or
    (Cardinal(B[Offset + 2]) shl 8) or Cardinal(B[Offset + 3]);
end;

procedure PutU32(var B: TAESBlock; Offset: Integer; V: Cardinal); inline;
begin
  B[Offset] := Byte(V shr 24);
  B[Offset + 1] := Byte(V shr 16);
  B[Offset + 2] := Byte(V shr 8);
  B[Offset + 3] := Byte(V);
end;

procedure AESEncryptBlock(const Ctx: TAESContext; const Input: TAESBlock; out Output: TAESBlock);
var
  S0, S1, S2, S3, T0, T1, T2, T3: Cardinal;
  R, K: Integer;
begin
  S0 := GetU32(Input, 0) xor Ctx.EncKey[0];
  S1 := GetU32(Input, 4) xor Ctx.EncKey[1];
  S2 := GetU32(Input, 8) xor Ctx.EncKey[2];
  S3 := GetU32(Input, 12) xor Ctx.EncKey[3];
  K := 4;
  for R := 1 to Ctx.Rounds - 1 do
  begin
    T0 := Te0[S0 shr 24] xor Te1[(S1 shr 16) and $FF] xor Te2[(S2 shr 8) and $FF] xor Te3[S3 and $FF] xor Ctx.EncKey[K];
    T1 := Te0[S1 shr 24] xor Te1[(S2 shr 16) and $FF] xor Te2[(S3 shr 8) and $FF] xor Te3[S0 and $FF] xor Ctx.EncKey[K + 1];
    T2 := Te0[S2 shr 24] xor Te1[(S3 shr 16) and $FF] xor Te2[(S0 shr 8) and $FF] xor Te3[S1 and $FF] xor Ctx.EncKey[K + 2];
    T3 := Te0[S3 shr 24] xor Te1[(S0 shr 16) and $FF] xor Te2[(S1 shr 8) and $FF] xor Te3[S2 and $FF] xor Ctx.EncKey[K + 3];
    S0 := T0;
    S1 := T1;
    S2 := T2;
    S3 := T3;
    Inc(K, 4);
  end;
  // Final round: no MixColumns
  PutU32(Output, 0, ((Cardinal(SBox[S0 shr 24]) shl 24) or (Cardinal(SBox[(S1 shr 16) and $FF]) shl 16) or
    (Cardinal(SBox[(S2 shr 8) and $FF]) shl 8) or Cardinal(SBox[S3 and $FF])) xor Ctx.EncKey[K]);
  PutU32(Output, 4, ((Cardinal(SBox[S1 shr 24]) shl 24) or (Cardinal(SBox[(S2 shr 16) and $FF]) shl 16) or
    (Cardinal(SBox[(S3 shr 8) and $FF]) shl 8) or Cardinal(SBox[S0 and $FF])) xor Ctx.EncKey[K + 1]);
  PutU32(Output, 8, ((Cardinal(SBox[S2 shr 24]) shl 24) or (Cardinal(SBox[(S3 shr 16) and $FF]) shl 16) or
    (Cardinal(SBox[(S0 shr 8) and $FF]) shl 8) or Cardinal(SBox[S1 and $FF])) xor Ctx.EncKey[K + 2]);
  PutU32(Output, 12, ((Cardinal(SBox[S3 shr 24]) shl 24) or (Cardinal(SBox[(S0 shr 16) and $FF]) shl 16) or
    (Cardinal(SBox[(S1 shr 8) and $FF]) shl 8) or Cardinal(SBox[S2 and $FF])) xor Ctx.EncKey[K + 3]);
end;

procedure AESDecryptBlock(const Ctx: TAESContext; const Input: TAESBlock; out Output: TAESBlock);
var
  S0, S1, S2, S3, T0, T1, T2, T3: Cardinal;
  R, K: Integer;
begin
  S0 := GetU32(Input, 0) xor Ctx.DecKey[0];
  S1 := GetU32(Input, 4) xor Ctx.DecKey[1];
  S2 := GetU32(Input, 8) xor Ctx.DecKey[2];
  S3 := GetU32(Input, 12) xor Ctx.DecKey[3];
  K := 4;
  for R := 1 to Ctx.Rounds - 1 do
  begin
    T0 := Td0[S0 shr 24] xor Td1[(S3 shr 16) and $FF] xor Td2[(S2 shr 8) and $FF] xor Td3[S1 and $FF] xor Ctx.DecKey[K];
    T1 := Td0[S1 shr 24] xor Td1[(S0 shr 16) and $FF] xor Td2[(S3 shr 8) and $FF] xor Td3[S2 and $FF] xor Ctx.DecKey[K + 1];
    T2 := Td0[S2 shr 24] xor Td1[(S1 shr 16) and $FF] xor Td2[(S0 shr 8) and $FF] xor Td3[S3 and $FF] xor Ctx.DecKey[K + 2];
    T3 := Td0[S3 shr 24] xor Td1[(S2 shr 16) and $FF] xor Td2[(S1 shr 8) and $FF] xor Td3[S0 and $FF] xor Ctx.DecKey[K + 3];
    S0 := T0;
    S1 := T1;
    S2 := T2;
    S3 := T3;
    Inc(K, 4);
  end;
  PutU32(Output, 0, ((Cardinal(InvSBox[S0 shr 24]) shl 24) or (Cardinal(InvSBox[(S3 shr 16) and $FF]) shl 16) or
    (Cardinal(InvSBox[(S2 shr 8) and $FF]) shl 8) or Cardinal(InvSBox[S1 and $FF])) xor Ctx.DecKey[K]);
  PutU32(Output, 4, ((Cardinal(InvSBox[S1 shr 24]) shl 24) or (Cardinal(InvSBox[(S0 shr 16) and $FF]) shl 16) or
    (Cardinal(InvSBox[(S3 shr 8) and $FF]) shl 8) or Cardinal(InvSBox[S2 and $FF])) xor Ctx.DecKey[K + 1]);
  PutU32(Output, 8, ((Cardinal(InvSBox[S2 shr 24]) shl 24) or (Cardinal(InvSBox[(S1 shr 16) and $FF]) shl 16) or
    (Cardinal(InvSBox[(S0 shr 8) and $FF]) shl 8) or Cardinal(InvSBox[S3 and $FF])) xor Ctx.DecKey[K + 2]);
  PutU32(Output, 12, ((Cardinal(InvSBox[S3 shr 24]) shl 24) or (Cardinal(InvSBox[(S2 shr 16) and $FF]) shl 16) or
    (Cardinal(InvSBox[(S1 shr 8) and $FF]) shl 8) or Cardinal(InvSBox[S0 and $FF])) xor Ctx.DecKey[K + 3]);
end;

{ CBC helpers working on a raw byte range of Data. }

procedure CBCDecryptRange(const Ctx: TAESContext; const IV: TAESBlock; const Data: TBytes;
  Start, BlockCount: Integer; var Output: TBytes; OutStart: Integer);
var
  Prev, Cur, Plain: TAESBlock;
  B, I: Integer;
begin
  Prev := IV;
  for B := 0 to BlockCount - 1 do
  begin
    Move(Data[Start + 16 * B], Cur[0], 16);
    AESDecryptBlock(Ctx, Cur, Plain);
    for I := 0 to 15 do
      Output[OutStart + 16 * B + I] := Plain[I] xor Prev[I];
    Prev := Cur;
  end;
end;

procedure CheckNoPadArgs(const IV, Data: TBytes);
begin
  if Length(IV) <> 16 then
    raise EPdfEncryptionError.CreateFmt('Invalid AES IV length: %d bytes', [Integer(Length(IV))]);
  if Length(Data) mod 16 <> 0 then
    raise EPdfEncryptionError.CreateFmt('AES data length %d is not a multiple of 16', [Integer(Length(Data))]);
end;

function PdfAESCBCDecrypt(const Key, Data: TBytes): TBytes;
var
  Ctx: TAESContext;
  IV: TAESBlock;
  BlockCount, OutLen, Pad, I: Integer;
  Valid: Boolean;
begin
  AESInit(Ctx, Key);
  BlockCount := (Integer(Length(Data)) - 16) div 16;
  if (Length(Data) < 16) or (BlockCount <= 0) then
    Exit(nil);
  Move(Data[0], IV[0], 16);
  OutLen := BlockCount * 16;
  SetLength(Result, OutLen);
  CBCDecryptRange(Ctx, IV, Data, 16, BlockCount, Result, 0);
  // Strip PKCS#5 padding only when it is well formed
  Pad := Result[OutLen - 1];
  if (Pad >= 1) and (Pad <= 16) then
  begin
    Valid := True;
    for I := OutLen - Pad to OutLen - 1 do
      if Result[I] <> Pad then
      begin
        Valid := False;
        Break;
      end;
    if Valid then
      SetLength(Result, OutLen - Pad);
  end;
end;

function PdfAESCBCEncryptNoPad(const Key, IV, Data: TBytes): TBytes;
var
  Ctx: TAESContext;
  Prev, Cur: TAESBlock;
  B, I: Integer;
begin
  CheckNoPadArgs(IV, Data);
  AESInit(Ctx, Key);
  SetLength(Result, Length(Data));
  Move(IV[0], Prev[0], 16);
  for B := 0 to Integer(Length(Data)) div 16 - 1 do
  begin
    for I := 0 to 15 do
      Cur[I] := Data[16 * B + I] xor Prev[I];
    AESEncryptBlock(Ctx, Cur, Prev);
    Move(Prev[0], Result[16 * B], 16);
  end;
end;

function PdfAESCBCDecryptNoPad(const Key, IV, Data: TBytes): TBytes;
var
  Ctx: TAESContext;
  IVBlock: TAESBlock;
begin
  CheckNoPadArgs(IV, Data);
  AESInit(Ctx, Key);
  SetLength(Result, Length(Data));
  if Length(Data) = 0 then
    Exit;
  Move(IV[0], IVBlock[0], 16);
  CBCDecryptRange(Ctx, IVBlock, Data, 0, Integer(Length(Data)) div 16, Result, 0);
end;

initialization
  InitAESTables;

end.
