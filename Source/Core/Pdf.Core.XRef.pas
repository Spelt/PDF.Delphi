{*******************************************************************************
  Pdf.Core.XRef
  Cross-reference handling (ISO 32000-1 §7.5): classic xref tables, xref
  streams, incremental updates (/Prev, /XRefStm), object streams (/ObjStm),
  reconstruction by scanning the file when the table is damaged, object
  fetching with caching, and transparent decryption of fetched objects.
  Portions derived from pdf.js (Mozilla, Apache License 2.0).
*******************************************************************************}
unit Pdf.Core.XRef;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.Math,
  Pdf.Core.Types, Pdf.Core.Lexer, Pdf.Core.Objects, Pdf.Core.Parser,
  Pdf.Core.Encryption;

type
  TPdfXRefEntryType = (xeFree, xeOffset, xeCompressed);

  TPdfXRefEntry = record
    EntryType: TPdfXRefEntryType;
    /// <summary>File offset (xeOffset) or number of the object stream (xeCompressed).</summary>
    Offset: Int64;
    /// <summary>Generation (xeOffset) or index inside the object stream (xeCompressed).</summary>
    Gen: Integer;
  end;

  TPdfXRef = class(TInterfacedObject, IPdfResolver)
  private type
    TObjStm = class
      Data: TBytes;
      First: Integer;
      Nums: TArray<Integer>;
      Offsets: TArray<Integer>;
    end;
  private
    FData: TBytes;
    FBase: Integer;
    FPassword: string;
    FEntries: TDictionary<Integer, TPdfXRefEntry>;
    FCache: TDictionary<Integer, IPdfObject>;
    FObjStms: TObjectDictionary<Integer, TObjStm>;
    FPending: TDictionary<Integer, Boolean>;
    FTrailer: IPdfDictionary;
    FSecurity: TPdfStandardSecurityHandler;
    FEncryptObjNum: Integer;
    FReconstructed: Boolean;
    FReconstructing: Boolean;
    FDetached: Boolean;
    FXRefStreamObjects: TList<Integer>;
    procedure AddEntry(Num: Integer; const Entry: TPdfXRefEntry);
    procedure ReadXRefChain(StartOffset: Int64);
    function ReadXRefSection(Offset: Int64): IPdfDictionary;
    function ReadXRefTable(Parser: TPdfParser): IPdfDictionary;
    function ReadXRefStream(const Stream: IPdfStream): IPdfDictionary;
    procedure MergeTrailer(const T: IPdfDictionary);
    function ParseAtOffset(Num: Integer; Offset: Int64; out FoundNum, FoundGen: Integer): IPdfObject;
    function FetchCompressed(Num, StmNum, Index: Integer): IPdfObject;
    function GetObjStm(StmNum: Integer): TObjStm;
    procedure SetupEncryption;
    function DecryptObject(const Obj: IPdfObject; Num, Gen: Integer): IPdfObject;
    function CryptMethodFromCF(const CF: IPdfDictionary; const Name: string; var KeyBits: Integer): TPdfCryptMethod;
    function GetIsEncrypted: Boolean;
    function FindRootInObjects: Boolean;
  public
    /// <summary>Data is the whole file; Password is tried as user and as owner password.</summary>
    constructor Create(const Data: TBytes; const Password: string = '');
    destructor Destroy; override;
    /// <summary>Reads the xref chain starting at 'startxref'; falls back to Reconstruct on any problem.
    /// Raises EPdfPasswordError when the document is encrypted and the password does not match.</summary>
    procedure Parse;
    /// <summary>Rebuilds the table by scanning the file for "n g obj" and 'trailer'.</summary>
    procedure Reconstruct;
    /// <summary>Releases caches and data; afterwards every fetch returns null. Called by the owning document.</summary>
    procedure Detach;
    { IPdfResolver }
    function Resolve(const Obj: IPdfObject): IPdfObject;
    function FetchObject(Num, Gen: Integer): IPdfObject;
    function TryGetEntry(Num: Integer; out Entry: TPdfXRefEntry): Boolean;
    /// <summary>All object numbers known to the table, ascending.</summary>
    function ObjectNumbers: TArray<Integer>;
    property Trailer: IPdfDictionary read FTrailer;
    property IsEncrypted: Boolean read GetIsEncrypted;
    property SecurityHandler: TPdfStandardSecurityHandler read FSecurity;
    property IsReconstructed: Boolean read FReconstructed;
    property Data: TBytes read FData;
    /// <summary>Offset of the %PDF header; file offsets are relative to it.</summary>
    property Base: Integer read FBase;
  end;

implementation

const
  MaxReferenceDepth = 64;

{ TPdfXRef }

constructor TPdfXRef.Create(const Data: TBytes; const Password: string);
var
  P: Integer;
begin
  inherited Create;
  FData := Data;
  FPassword := Password;
  FEntries := TDictionary<Integer, TPdfXRefEntry>.Create;
  FCache := TDictionary<Integer, IPdfObject>.Create;
  FObjStms := TObjectDictionary<Integer, TObjStm>.Create([doOwnsValues]);
  FPending := TDictionary<Integer, Boolean>.Create;
  FXRefStreamObjects := TList<Integer>.Create;
  FEncryptObjNum := -1;
  FTrailer := PdfDictionary(Self);
  // Offsets are relative to the %PDF header, which may be preceded by garbage.
  P := PdfFindBytes(FData, '%PDF', 0, Min(Length(FData), 1024 + 4));
  if P > 0 then
    FBase := P;
end;

destructor TPdfXRef.Destroy;
begin
  FSecurity.Free;
  FXRefStreamObjects.Free;
  FPending.Free;
  FObjStms.Free;
  FCache.Free;
  FEntries.Free;
  inherited;
end;

procedure TPdfXRef.Detach;
var
  Keep: IPdfResolver;
begin
  // The trailer and cached objects hold references to this resolver (a cycle that
  // only Detach breaks). Keep ourselves alive until the method has finished.
  Keep := Self;
  FDetached := True;
  FCache.Clear;
  FObjStms.Clear;
  FEntries.Clear;
  FTrailer := PdfDictionary(nil);
  FData := nil;
  Keep := nil;
end;

function TPdfXRef.GetIsEncrypted: Boolean;
begin
  Result := FSecurity <> nil;
end;

procedure TPdfXRef.AddEntry(Num: Integer; const Entry: TPdfXRefEntry);
begin
  // The first definition seen is the newest (we walk from the last update backwards).
  if (Num >= 0) and not FEntries.ContainsKey(Num) then
    FEntries.Add(Num, Entry);
end;

function TPdfXRef.TryGetEntry(Num: Integer; out Entry: TPdfXRefEntry): Boolean;
begin
  Result := FEntries.TryGetValue(Num, Entry);
end;

function TPdfXRef.ObjectNumbers: TArray<Integer>;
begin
  Result := FEntries.Keys.ToArray;
  TArray.Sort<Integer>(Result);
end;

procedure TPdfXRef.Parse;
var
  P: Integer;
  Offset: Int64;
  Ok: Boolean;
begin
  Ok := False;
  try
    P := PdfFindBytesBackward(FData, 'startxref');
    if P >= 0 then
    begin
      P := P + 9;
      if PdfReadUnsignedInt(FData, P, Offset) then
      begin
        ReadXRefChain(Offset);
        Ok := FTrailer.Contains('Root');
      end;
    end;
  except
    on E: EPdfException do
      Ok := False;
  end;
  if not Ok then
    Reconstruct;
  SetupEncryption;
end;

procedure TPdfXRef.ReadXRefChain(StartOffset: Int64);
var
  Queue: TList<Int64>;
  Seen: TDictionary<Int64, Boolean>;
  Offset: Int64;
  T: IPdfDictionary;
  Obj: IPdfObject;
begin
  Queue := TList<Int64>.Create;
  Seen := TDictionary<Int64, Boolean>.Create;
  try
    Queue.Add(StartOffset);
    while Queue.Count > 0 do
    begin
      Offset := Queue[0];
      Queue.Delete(0);
      if Seen.ContainsKey(Offset) or (Offset < 0) or (Offset >= Length(FData)) then
        Continue;
      Seen.Add(Offset, True);
      T := ReadXRefSection(Offset);
      if T = nil then
        Continue;
      MergeTrailer(T);
      // Hybrid files: the xref stream takes precedence over the /Prev table
      Obj := T.GetRaw('XRefStm');
      if PdfIsNumber(Obj) then
        Queue.Insert(0, PdfAsInteger(Obj));
      Obj := T.GetRaw('Prev');
      if PdfIsNumber(Obj) then
        Queue.Add(PdfAsInteger(Obj));
    end;
  finally
    Seen.Free;
    Queue.Free;
  end;
end;

function TPdfXRef.ReadXRefSection(Offset: Int64): IPdfDictionary;
var
  Parser: TPdfParser;
  Tok: TPdfToken;
  Num, Gen: Integer;
  Obj: IPdfObject;
  Stream: IPdfStream;
begin
  Parser := TPdfParser.Create(FData, Integer(Offset) + FBase, Self);
  try
    Parser.Lexer.SkipWhitespaceAndComments;
    if PdfMatchBytes(FData, Parser.Position, 'xref') then
    begin
      Tok := Parser.Lexer.NextToken;
      if not Tok.IsKeyword('xref') then
        raise EPdfSyntaxError.Create('xref keyword expected');
      Exit(ReadXRefTable(Parser));
    end;
    if not Parser.AtObjectHeader(Num, Gen) then
      raise EPdfSyntaxError.CreateFmt('No xref section at offset %d', [Offset]);
    Obj := Parser.ParseIndirectObject(Num, Gen);
    Stream := PdfAsStream(Obj);
    if (Stream = nil) or not Stream.Dict.IsType('XRef') then
      raise EPdfSyntaxError.CreateFmt('Object at offset %d is not an xref stream', [Offset]);
    FXRefStreamObjects.Add(Num);
    Result := ReadXRefStream(Stream);
  finally
    Parser.Free;
  end;
end;

function TPdfXRef.ReadXRefTable(Parser: TPdfParser): IPdfDictionary;
var
  Tok, T1, T2: TPdfToken;
  Start, Count, I: Int64;
  Entry: TPdfXRefEntry;
  Obj: IPdfObject;
  FirstInSubsection: Boolean;
begin
  Result := nil;
  while True do
  begin
    Tok := Parser.Lexer.NextToken;
    if Tok.Kind = tkEOF then
      Break;
    if Tok.IsKeyword('trailer') then
    begin
      Obj := Parser.ParseObject;
      Result := PdfAsDictionary(Obj);
      Break;
    end;
    if (Tok.Kind <> tkNumber) or not Tok.IsInteger then
      raise EPdfSyntaxError.CreateFmt('Invalid xref table at offset %d', [Tok.Position]);
    Start := Tok.IntValue;
    T1 := Parser.Lexer.NextToken;
    if (T1.Kind <> tkNumber) or not T1.IsInteger then
      raise EPdfSyntaxError.CreateFmt('Invalid xref subsection at offset %d', [Tok.Position]);
    Count := T1.IntValue;
    FirstInSubsection := True;
    I := 0;
    while I < Count do
    begin
      Parser.Lexer.SkipWhitespaceAndComments;
      if PdfMatchBytes(FData, Parser.Lexer.Position, 'trailer') then
        Break; // fewer entries than announced
      T1 := Parser.Lexer.NextToken;
      if (T1.Kind <> tkNumber) or not T1.IsInteger then
        raise EPdfSyntaxError.CreateFmt('Invalid xref entry at offset %d', [T1.Position]);
      T2 := Parser.Lexer.NextToken;
      if (T2.Kind <> tkNumber) or not T2.IsInteger then
        raise EPdfSyntaxError.CreateFmt('Invalid xref entry at offset %d', [T2.Position]);
      Tok := Parser.Lexer.NextToken;
      if Tok.IsKeyword('n') then
      begin
        Entry.EntryType := xeOffset;
        Entry.Offset := T1.IntValue;
        Entry.Gen := Integer(T2.IntValue);
      end
      else if Tok.IsKeyword('f') then
      begin
        Entry.EntryType := xeFree;
        Entry.Offset := 0;
        Entry.Gen := Integer(T2.IntValue);
      end
      else
        raise EPdfSyntaxError.CreateFmt('Invalid xref entry type at offset %d', [Tok.Position]);
      // Some writers number the first subsection from 1 although it starts with the head of the free list.
      if FirstInSubsection and (Start = 1) and (Entry.EntryType = xeFree) and (Entry.Gen = 65535) then
        Start := 0;
      FirstInSubsection := False;
      AddEntry(Integer(Start + I), Entry);
      Inc(I);
    end;
  end;
  if Result = nil then
    Result := PdfDictionary(Self);
end;

function TPdfXRef.ReadXRefStream(const Stream: IPdfStream): IPdfDictionary;
var
  Dict: IPdfDictionary;
  WArr, IndexArr: IPdfArray;
  W: array[0..2] of Integer;
  Data: TBytes;
  Pos, I, J, K, Size, EntrySize: Integer;
  Start, Count: Int64;
  Fields: array[0..2] of Int64;
  Entry: TPdfXRefEntry;
  Ranges: TList<Int64>;
begin
  Dict := Stream.Dict;
  Result := Dict;
  WArr := Dict.GetArray('W');
  if (WArr = nil) or (WArr.Count < 3) then
    raise EPdfSyntaxError.Create('xref stream without valid /W');
  for I := 0 to 2 do
    W[I] := Integer(WArr.GetInteger(I, 0));
  EntrySize := W[0] + W[1] + W[2];
  if (EntrySize <= 0) or (W[0] < 0) or (W[1] < 0) or (W[2] < 0) or (W[1] > 8) or (W[2] > 8) or (W[0] > 8) then
    raise EPdfSyntaxError.Create('xref stream with invalid /W');
  Size := Integer(Dict.GetInteger('Size', 0));
  Ranges := TList<Int64>.Create;
  try
    IndexArr := Dict.GetArray('Index');
    if IndexArr <> nil then
    begin
      I := 0;
      while I + 1 < IndexArr.Count do
      begin
        Ranges.Add(IndexArr.GetInteger(I, 0));
        Ranges.Add(IndexArr.GetInteger(I + 1, 0));
        Inc(I, 2);
      end;
    end
    else
    begin
      Ranges.Add(0);
      Ranges.Add(Size);
    end;
    Data := Stream.GetDecodedData;
    Pos := 0;
    I := 0;
    while I + 1 < Ranges.Count do
    begin
      Start := Ranges[I];
      Count := Ranges[I + 1];
      Inc(I, 2);
      J := 0;
      while (J < Count) and (Pos + EntrySize <= Length(Data)) do
      begin
        for K := 0 to 2 do
        begin
          Fields[K] := 0;
          if W[K] > 0 then
          begin
            Fields[K] := 0;
            while W[K] > 0 do
            begin
              Fields[K] := (Fields[K] shl 8) or Data[Pos];
              Inc(Pos);
              Dec(W[K]);
            end;
            W[K] := Integer(WArr.GetInteger(K, 0));
          end
          else if K = 0 then
            Fields[K] := 1; // default type when the first field is absent
        end;
        case Fields[0] of
          0:
            begin
              Entry.EntryType := xeFree;
              Entry.Offset := 0;
              Entry.Gen := Integer(Fields[2]);
            end;
          1:
            begin
              Entry.EntryType := xeOffset;
              Entry.Offset := Fields[1];
              Entry.Gen := Integer(Fields[2]);
            end;
          2:
            begin
              Entry.EntryType := xeCompressed;
              Entry.Offset := Fields[1];
              Entry.Gen := Integer(Fields[2]);
            end;
        else
          begin
            Inc(J);
            Continue; // unknown type: ignore the entry
          end;
        end;
        AddEntry(Integer(Start + J), Entry);
        Inc(J);
      end;
    end;
  finally
    Ranges.Free;
  end;
end;

procedure TPdfXRef.MergeTrailer(const T: IPdfDictionary);
var
  Key: string;
begin
  if T = nil then
    Exit;
  for Key in T.Keys do
    if not FTrailer.Contains(Key) then
      FTrailer.SetValue(Key, T.GetRaw(Key));
end;

function TPdfXRef.ParseAtOffset(Num: Integer; Offset: Int64; out FoundNum, FoundGen: Integer): IPdfObject;
var
  Parser: TPdfParser;
begin
  Result := nil;
  FoundNum := -1;
  FoundGen := 0;
  Offset := Offset + FBase;
  if (Offset < 0) or (Offset >= Length(FData)) then
    Exit;
  Parser := TPdfParser.Create(FData, Integer(Offset), Self);
  try
    if not Parser.AtObjectHeader(FoundNum, FoundGen) then
      Exit;
    if FoundNum <> Num then
      Exit;
    Result := Parser.ParseIndirectObject(FoundNum, FoundGen);
  finally
    Parser.Free;
  end;
end;

function TPdfXRef.GetObjStm(StmNum: Integer): TObjStm;
var
  Obj: IPdfObject;
  Stream: IPdfStream;
  N, First, I: Integer;
  Lexer: TPdfLexer;
  T1, T2: TPdfToken;
begin
  if FObjStms.TryGetValue(StmNum, Result) then
    Exit;
  Result := nil;
  Obj := FetchObject(StmNum, 0);
  Stream := PdfAsStream(Obj);
  if Stream = nil then
    Exit;
  Result := TObjStm.Create;
  FObjStms.Add(StmNum, Result);
  try
    Result.Data := Stream.GetDecodedData;
  except
    on EPdfException do
      Exit; // stays empty: all objects inside resolve to null
  end;
  N := Integer(Stream.Dict.GetInteger('N', 0));
  First := Integer(Stream.Dict.GetInteger('First', 0));
  Result.First := First;
  if (N <= 0) or (First < 0) or (First > Length(Result.Data)) then
    Exit;
  SetLength(Result.Nums, N);
  SetLength(Result.Offsets, N);
  Lexer := TPdfLexer.Create(Result.Data, 0, First);
  try
    for I := 0 to N - 1 do
    begin
      T1 := Lexer.NextToken;
      T2 := Lexer.NextToken;
      if (T1.Kind <> tkNumber) or (T2.Kind <> tkNumber) then
      begin
        SetLength(Result.Nums, I);
        SetLength(Result.Offsets, I);
        Break;
      end;
      Result.Nums[I] := Integer(T1.IntValue);
      Result.Offsets[I] := Integer(T2.IntValue);
    end;
  finally
    Lexer.Free;
  end;
end;

function TPdfXRef.FetchCompressed(Num, StmNum, Index: Integer): IPdfObject;
var
  Stm: TObjStm;
  I, Idx, Pos: Integer;
  Parser: TPdfParser;
begin
  Result := PdfNull;
  Stm := GetObjStm(StmNum);
  if (Stm = nil) or (Length(Stm.Nums) = 0) then
    Exit;
  Idx := -1;
  if (Index >= 0) and (Index < Length(Stm.Nums)) and (Stm.Nums[Index] = Num) then
    Idx := Index
  else
    for I := 0 to High(Stm.Nums) do
      if Stm.Nums[I] = Num then
      begin
        Idx := I;
        Break;
      end;
  if Idx < 0 then
    Exit;
  Pos := Stm.First + Stm.Offsets[Idx];
  if (Pos < 0) or (Pos >= Length(Stm.Data)) then
    Exit;
  Parser := TPdfParser.Create(Stm.Data, Pos, Self, False);
  try
    Result := Parser.ParseObject;
    if (Result = nil) or (Result.Kind = okOperator) then
      Result := PdfNull;
  finally
    Parser.Free;
  end;
end;

function TPdfXRef.FetchObject(Num, Gen: Integer): IPdfObject;
var
  Entry: TPdfXRefEntry;
  FoundNum, FoundGen: Integer;
begin
  if FDetached or (Num < 0) then
    Exit(PdfNull);
  if FCache.TryGetValue(Num, Result) then
    Exit;
  if FPending.ContainsKey(Num) then
    Exit(PdfNull); // reference cycle (e.g. /Length pointing at the stream itself)
  if not FEntries.TryGetValue(Num, Entry) then
    Exit(PdfNull);
  FPending.Add(Num, True);
  try
    Result := nil;
    case Entry.EntryType of
      xeFree:
        Result := PdfNull;
      xeOffset:
        begin
          Result := ParseAtOffset(Num, Entry.Offset, FoundNum, FoundGen);
          if Result = nil then
          begin
            // The offset is wrong: rebuild the table once and try again.
            if not FReconstructed and not FReconstructing then
            begin
              FPending.Remove(Num);
              Reconstruct;
              Exit(FetchObject(Num, Gen));
            end;
            Result := PdfNull;
          end
          else if (FSecurity <> nil) and (Num <> FEncryptObjNum) then
            Result := DecryptObject(Result, FoundNum, FoundGen);
        end;
      xeCompressed:
        Result := FetchCompressed(Num, Integer(Entry.Offset), Entry.Gen);
    end;
    if Result = nil then
      Result := PdfNull;
    if Result.Kind = okStream then
      (Result as IPdfStream).SetObjectNumber(Num, Gen);
    FCache.AddOrSetValue(Num, Result);
  finally
    FPending.Remove(Num);
  end;
end;

function TPdfXRef.Resolve(const Obj: IPdfObject): IPdfObject;
var
  Depth: Integer;
  Ref: IPdfReference;
begin
  Result := Obj;
  Depth := 0;
  while (Result <> nil) and (Result.Kind = okReference) and (Depth < MaxReferenceDepth) do
  begin
    Ref := Result as IPdfReference;
    Result := FetchObject(Ref.Num, Ref.Gen);
    Inc(Depth);
  end;
  if (Result = nil) or (Result.Kind = okReference) then
    Result := PdfNull;
end;

{ Reconstruction }

procedure TPdfXRef.Reconstruct;
var
  P, Len, NumStart, GenStart, Q, Num, Gen, ObjEnd: Integer;
  Entry: TPdfXRefEntry;
  Trailers: TList<IPdfDictionary>;
  Parser: TPdfParser;
  Obj: IPdfObject;
  T: IPdfDictionary;
  I: Integer;
  NewTrailer: IPdfDictionary;
  Root: IPdfDictionary;
  Stream: IPdfStream;
  Nums: TArray<Integer>;

  function IsBoundary(Pos: Integer): Boolean;
  begin
    Result := (Pos < 0) or not IsPdfRegular(FData[Pos]);
  end;

begin
  if FReconstructing then
    Exit;
  FReconstructing := True;
  Trailers := TList<IPdfDictionary>.Create;
  try
    FEntries.Clear;
    FCache.Clear;
    FObjStms.Clear;
    FXRefStreamObjects.Clear;
    FReconstructed := True;
    Len := Length(FData);
    P := 0;
    while P < Len do
    begin
      if (FData[P] = Ord('o')) and PdfMatchBytes(FData, P, 'obj') and IsBoundary(P + 3) then
      begin
        // Walk back: whitespace, generation digits, whitespace, object number digits, boundary
        Q := P - 1;
        while (Q >= 0) and IsPdfWhitespace(FData[Q]) do
          Dec(Q);
        GenStart := Q;
        while (GenStart >= 0) and IsPdfDigit(FData[GenStart]) do
          Dec(GenStart);
        if (GenStart = Q) or (Q = P - 1) then
        begin
          Inc(P, 3);
          Continue;
        end;
        Q := GenStart;
        while (Q >= 0) and IsPdfWhitespace(FData[Q]) do
          Dec(Q);
        if Q = GenStart then
        begin
          Inc(P, 3);
          Continue;
        end;
        NumStart := Q;
        while (NumStart >= 0) and IsPdfDigit(FData[NumStart]) do
          Dec(NumStart);
        if (NumStart = Q) or not IsBoundary(NumStart) then
        begin
          Inc(P, 3);
          Continue;
        end;
        Inc(NumStart);
        Num := 0;
        Q := NumStart;
        while IsPdfDigit(FData[Q]) and (Num < 100000000) do
        begin
          Num := Num * 10 + (FData[Q] - Ord('0'));
          Inc(Q);
        end;
        Gen := 0;
        Q := GenStart + 1;
        while IsPdfDigit(FData[Q]) and (Gen < 1000000) do
        begin
          Gen := Gen * 10 + (FData[Q] - Ord('0'));
          Inc(Q);
        end;
        Entry.EntryType := xeOffset;
        Entry.Offset := NumStart - FBase;
        Entry.Gen := Gen;
        FEntries.AddOrSetValue(Num, Entry); // later definitions win
        // Skip the object body so that 'obj' inside stream data is not matched.
        ObjEnd := P + 3;
        Parser := TPdfParser.Create(FData, NumStart, Self);
        try
          try
            Obj := Parser.ParseIndirectObject(Num, Gen);
            ObjEnd := Max(ObjEnd, Parser.Position);
            Stream := PdfAsStream(Obj);
            if (Stream <> nil) and Stream.Dict.IsType('XRef') then
            begin
              FXRefStreamObjects.Add(Num);
              Trailers.Add(Stream.Dict);
            end;
          except
            on EPdfException do
              ;
          end;
        finally
          Parser.Free;
        end;
        P := ObjEnd;
        Continue;
      end
      else if (FData[P] = Ord('t')) and PdfMatchBytes(FData, P, 'trailer') then
      begin
        Parser := TPdfParser.Create(FData, P + 7, Self);
        try
          try
            Obj := Parser.ParseObject;
            T := PdfAsDictionary(Obj);
            if T <> nil then
              Trailers.Add(T);
          except
            on EPdfException do
              ;
          end;
          P := Max(P + 7, Parser.Position);
        finally
          Parser.Free;
        end;
        Continue;
      end;
      Inc(P);
    end;

    // Build the trailer: newest (last in file) trailer with a usable /Root wins, other keys are merged.
    NewTrailer := PdfDictionary(Self);
    for I := Trailers.Count - 1 downto 0 do
    begin
      T := Trailers[I];
      if not NewTrailer.Contains('Root') then
      begin
        Root := PdfAsDictionary(Resolve(T.GetRaw('Root')));
        if (Root <> nil) and (Root.Contains('Pages') or Root.IsType('Catalog')) then
          NewTrailer.SetValue('Root', T.GetRaw('Root'));
      end;
      for var Key in T.Keys do
        if (Key <> 'Root') and not NewTrailer.Contains(Key) then
          NewTrailer.SetValue(Key, T.GetRaw(Key));
    end;
    // Keep /Encrypt and /ID from a trailer we read before reconstruction if the scan found none.
    for var Key in ['Encrypt', 'ID', 'Info'] do
      if not NewTrailer.Contains(Key) and FTrailer.Contains(Key) then
        NewTrailer.SetValue(Key, FTrailer.GetRaw(Key));
    FTrailer := NewTrailer;
    if not FTrailer.Contains('Root') then
      if not FindRootInObjects then
      begin
        Nums := ObjectNumbers;
        if Length(Nums) = 0 then
          raise EPdfInvalidDocument.Create('No PDF objects found in the file');
      end;
  finally
    Trailers.Free;
    FReconstructing := False;
  end;
end;

function TPdfXRef.FindRootInObjects: Boolean;
var
  Num: Integer;
  Obj: IPdfObject;
  Dict: IPdfDictionary;
  Best: Integer;
  BestOffset: Int64;
  Entry: TPdfXRefEntry;
begin
  Best := -1;
  BestOffset := -1;
  for Num in ObjectNumbers do
  begin
    Obj := FetchObject(Num, 0);
    Dict := nil;
    if (Obj <> nil) and (Obj.Kind = okDictionary) then
      Dict := Obj as IPdfDictionary;
    if (Dict <> nil) and Dict.IsType('Catalog') and Dict.Contains('Pages') then
    begin
      FEntries.TryGetValue(Num, Entry);
      if Entry.Offset >= BestOffset then
      begin
        Best := Num;
        BestOffset := Entry.Offset;
      end;
    end;
  end;
  Result := Best >= 0;
  if Result then
    FTrailer.SetValue('Root', PdfReference(Best, 0));
end;

{ Encryption }

function TPdfXRef.CryptMethodFromCF(const CF: IPdfDictionary; const Name: string; var KeyBits: Integer): TPdfCryptMethod;
var
  Filter: IPdfDictionary;
  CFM: string;
  Len: Integer;
begin
  if (Name = '') or (Name = 'Identity') then
    Exit(cmNone);
  if CF = nil then
    Exit(cmNone);
  Filter := CF.GetDictionary(Name);
  if Filter = nil then
    Exit(cmNone);
  CFM := Filter.GetName('CFM', 'None');
  if CFM = 'V2' then
    Result := cmRC4
  else if CFM = 'AESV2' then
    Result := cmAESV2
  else if CFM = 'AESV3' then
    Result := cmAESV3
  else
    Result := cmNone;
  Len := Integer(Filter.GetInteger('Length', 0));
  if Len > 0 then
  begin
    if Len <= 40 then
      Len := Len * 8; // given in bytes
    KeyBits := Len;
  end;
end;

procedure TPdfXRef.SetupEncryption;
var
  EncRaw: IPdfObject;
  Enc, CF: IPdfDictionary;
  Params: TPdfEncryptParams;
  IDArr: IPdfArray;
  S: IPdfString;
  Ref: IPdfReference;
  KeyBits: Integer;

  function Bytes(const Key: string): TBytes;
  var
    Str: IPdfString;
  begin
    Str := Enc.GetString(Key);
    if Str <> nil then
      Result := Str.Bytes
    else
      Result := nil;
  end;

begin
  FreeAndNil(FSecurity);
  FEncryptObjNum := -1;
  EncRaw := FTrailer.GetRaw('Encrypt');
  if PdfIsNull(EncRaw) then
    Exit;
  Ref := PdfAsReference(EncRaw);
  if Ref <> nil then
    FEncryptObjNum := Ref.Num;
  Enc := PdfAsDictionary(Resolve(EncRaw));
  if Enc = nil then
    Exit;
  if Enc.GetName('Filter', 'Standard') <> 'Standard' then
    raise EPdfEncryptionError.CreateFmt('Unsupported security handler /%s', [Enc.GetName('Filter')]);
  Params := Default(TPdfEncryptParams);
  Params.V := Integer(Enc.GetInteger('V', 0));
  Params.R := Integer(Enc.GetInteger('R', 2));
  Params.KeyLengthBits := Integer(Enc.GetInteger('Length', 40));
  Params.P := Integer(Cardinal(Enc.GetInteger('P', -1) and $FFFFFFFF));
  Params.O := Bytes('O');
  Params.U := Bytes('U');
  Params.OE := Bytes('OE');
  Params.UE := Bytes('UE');
  Params.Perms := Bytes('Perms');
  // V=1 and V=2 ignore /EncryptMetadata (ISO 32000-2, Table 21); pdf.js does the same.
  Params.EncryptMetadata := Enc.GetBoolean('EncryptMetadata', True) or (Params.V < 4);
  IDArr := FTrailer.GetArray('ID');
  if IDArr <> nil then
  begin
    S := PdfAsString(IDArr.Get(0));
    if S <> nil then
      Params.ID0 := S.Bytes;
  end;
  if Params.V >= 4 then
  begin
    CF := Enc.GetDictionary('CF');
    KeyBits := Params.KeyLengthBits;
    Params.StreamMethod := CryptMethodFromCF(CF, Enc.GetName('StmF', 'Identity'), KeyBits);
    Params.StringMethod := CryptMethodFromCF(CF, Enc.GetName('StrF', 'Identity'), KeyBits);
    Params.KeyLengthBits := KeyBits;
  end
  else
  begin
    Params.StreamMethod := cmRC4;
    Params.StringMethod := cmRC4;
  end;
  try
    FSecurity := TPdfStandardSecurityHandler.Create(Params, FPassword);
  except
    on EPdfPasswordError do
    begin
      // When neither streams nor strings are encrypted (/StmF and /StrF Identity, typically
      // /AuthEvent /EFOpen: only embedded files need the password) the document itself is readable.
      if (Params.StreamMethod = cmNone) and (Params.StringMethod = cmNone) then
        FSecurity := nil
      else
        raise;
    end;
  end;
  // Objects fetched while reading the xref chain were parsed before the handler existed.
  FCache.Clear;
  FObjStms.Clear;
end;

function TPdfXRef.DecryptObject(const Obj: IPdfObject; Num, Gen: Integer): IPdfObject;
var
  I: Integer;
  Arr: IPdfArray;
  Dict: IPdfDictionary;
  Stream: IPdfStream;
  Key: string;
  Item, NewItem: IPdfObject;
  Names: TArray<string>;
  Identity: Boolean;
begin
  Result := Obj;
  if Obj = nil then
    Exit;
  case Obj.Kind of
    okString:
      Result := PdfString(FSecurity.DecryptString((Obj as IPdfString).Bytes, Num, Gen), (Obj as IPdfString).IsHex);
    okArray:
      begin
        Arr := Obj as IPdfArray;
        for I := 0 to Arr.Count - 1 do
        begin
          Item := Arr[I];
          NewItem := DecryptObject(Item, Num, Gen);
          if NewItem <> Item then
            Arr[I] := NewItem;
        end;
      end;
    okDictionary:
      begin
        Dict := Obj as IPdfDictionary;
        for Key in Dict.Keys do
        begin
          Item := Dict.GetRaw(Key);
          NewItem := DecryptObject(Item, Num, Gen);
          if NewItem <> Item then
            Dict.SetValue(Key, NewItem);
        end;
      end;
    okStream:
      begin
        Stream := Obj as IPdfStream;
        DecryptObject(Stream.Dict, Num, Gen);
        if Stream.Dict.IsType('XRef') then
          Exit;
        if Stream.Dict.IsType('Metadata') and not FSecurity.Params.EncryptMetadata then
          Exit;
        // A stream with its own /Crypt filter named /Identity is stored unencrypted.
        Identity := False;
        Names := Stream.GetFilterNames;
        for I := 0 to High(Names) do
          if Names[I] = 'Crypt' then
          begin
            Identity := True;
            Dict := nil;
            Item := Stream.Dict.Get('DecodeParms', 'DP');
            if (Item <> nil) and (Item.Kind = okArray) then
              Dict := (Item as IPdfArray).GetDictionary(I)
            else
              Dict := PdfAsDictionary(Item);
            if (Dict <> nil) and (Dict.GetName('Name', 'Identity') <> 'Identity') then
              Identity := False;
          end;
        if not Identity then
          Stream.RawData := FSecurity.DecryptStream(Stream.RawData, Num, Gen);
      end;
  end;
end;

end.
