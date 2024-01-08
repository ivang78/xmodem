unit Unit1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ComCtrls,
  LazSerial, Inifiles;

type

  { TMainForm }

  TMainForm = class(TForm)
    Button1: TButton;
    Button2: TButton;
    Button3: TButton;
    Button4: TButton;
    CheckBox1: TCheckBox;
    Edit1: TEdit;
    Label3: TLabel;
    Memo1: TMemo;
    OpenDialog1: TOpenDialog;
    Serial: TLazSerial;
    StatusBar1: TStatusBar;
    procedure Button1Click(Sender: TObject);
    procedure Button2Click(Sender: TObject);
    procedure Button3Click(Sender: TObject);
    procedure Button4Click(Sender: TObject);
    procedure Edit1Change(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure writeSerialByte(b: byte);
    procedure writeSerialString(s: string);
    procedure XModem_Init (curMode: byte);
    procedure XModem_outputByte(inChar: byte);
    function XModem_sync: byte;
    function XModem_waitACK(var resFunc:boolean): byte;
    procedure XModem_sendFile(fileName: string);
    function XModem_receiveSync(var resFunc:boolean): byte;
    function XModem_receiveByte(var resFunc:boolean): byte;
    procedure XModem_receiveFile(fileName: string);
    procedure XModem_addLog(str: string);

  private

  public

  end;

const
  SOH      = $01;
  STX      = $02;
  EOT      = $04;
  ENQ      = $05;
  ACK      = $06;
  LF       = $0a;
  CR       = $0d;
  DLE      = $10;
  XON      = $11;
  XOFF     = $13;
  NAK      = $15;
  CAN      = $18;
  EOF      = $1a;
  ModeXModem = 0;
  ModeYModem = 1;
  SYNC_TIMEOUT = 30;
  MAX_RETRY = 30;
  IniFile = 'xmodem.ini';

var
  MainForm: TMainForm;
  UART_Delay: integer;
  packetNo, checksumBuf, mode, oldChecksum : byte;
  res: boolean;
  inBytesCounter: byte;
  filepos : Int64;
  packetLen : word;
  crcBuf : integer;
  fileName : string;

implementation

{$R *.lfm}

{ TMainForm }

procedure TMainForm.Button1Click(Sender: TObject);
begin
  Serial.ShowSetupDialog;
end;

procedure TMainForm.Button2Click(Sender: TObject);
var
   ym: byte;
begin
  try
    Serial.Active:= True;
  except
    ShowMessage('Не удалось подключить');
  end;
  ym := 0;
  if CheckBox1.Checked = true then
     ym := 1;
  XModem_Init(ym);
  XModem_sendFile(fileName);
end;

procedure TMainForm.Button3Click(Sender: TObject);
begin
  try
    Serial.Active:= True;
  except
    ShowMessage('Не удалось подключить');
  end;
  XModem_Init(0);
  XModem_receiveFile(fileName);
end;

procedure TMainForm.Button4Click(Sender: TObject);
begin
  if openDialog1.Execute then
  begin
    fileName := openDialog1.FileName;
    StatusBar1.Simpletext := '  File: ' + ExtractFileName(fileName);
  end;
end;

procedure TMainForm.Edit1Change(Sender: TObject);
var
    SettFile : TIniFile;
begin
  // Write settings from ini file
  SettFile := TIniFile.Create(IniFile);
  UART_Delay := StrToInt(Edit1.Text);
  SettFile.WriteInteger('Main', 'UART_Delay', UART_Delay);
  SettFile.Free;
end;

procedure TMainForm.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  if Serial.Active then
    Serial.Active := false;
end;

procedure TMainForm.FormCreate(Sender: TObject);
var
    SettFile : TIniFile;
begin
  // Read settings from ini file
  SettFile := TIniFile.Create(IniFile);
  UART_Delay := SettFile.ReadInteger('Main', 'UART_Delay', 5);
  Edit1.Text := IntToStr(UART_Delay);
  SettFile.Free;
end;

procedure TMainForm.writeSerialByte(b: byte);
begin
  Serial.WriteData(Chr(b));
  sleep(UART_Delay);
end;

procedure TMainForm.writeSerialString(s: string);
var
   i: integer;
begin
  for i := 0 to Length(s) - 1 do
  begin
    Serial.WriteData(s[i]);
    sleep(UART_Delay);
  end;
end;

// ---------------------------------------------------------
// Initialize XModem session
Procedure TMainForm.XModem_Init (curMode: byte);
begin
  packetNo := 1;
  crcBuf := 0;
  checksumBuf := 0;
  filepos := 0;
  packetLen := 128;
  mode := curMode;

  // UART delay from settings
  UART_Delay := StrToInt(Edit1.Text);

  // Clear output
  Memo1.Lines.Clear;
end;

// ---------------------------------------------------------
// Send out a byte of payload data,
// includes checksumming
Procedure TMainForm.XModem_outputByte(inChar: byte);
var
   j: byte;
begin
  checksumBuf := checksumBuf + inChar;
  crcBuf := crcBuf xor (inChar shl 8);
  j := 8;
  repeat
    if (crcBuf and $8000) <> 0 then
      crcBuf := (crcBuf shl 1) xor $1021
    else
      crcBuf := crcBuf shl 1;
    Dec(j);
  until j = 0;
  writeSerialByte(inChar);
end;

// ---------------------------------------------------------
// Wait for either C or NACK as a sync packet.
// Determines protocol details, like block size
// and checksum algorithm.
function TMainForm.XModem_sync: byte;
var
  tryNo: byte;
  inChar: byte;
begin
  tryNo := 0;
  repeat
    inChar := Serial.SynSer.RecvByte(1000);
    tryNo := tryNo + 1;
    if tryNo = SYNC_TIMEOUT then
    begin
      XModem_addLog('Sync TIMEOUT');
      exit(255);
    end;
  until (inChar = ord('C')) or (inChar = NAK);
  XModem_addLog('Sync OK');
  packetLen := 128;
  if inChar = NAK then
    oldChecksum := 1
  else
    oldChecksum := 0;
  exit(0);
end;

// ---------------------------------------------------------
// Wait for the remote to acknowledge or cancel.
// Returns the received char if no timeout occured or
// a CAN was received. In this cases, it returns -1.
function TMainForm.XModem_waitACK(var resFunc:boolean): byte;
var
  i: byte;
  inChar: byte;
begin
  resFunc := true;
  i := 0;
  repeat
    inChar := Serial.SynSer.RecvByte(1000);
    Inc(i);
    if (i > 200) then
      begin
        XModem_addLog('waitACK ERROR');
        resFunc := false;
        Exit(255);
      end;
    if (inChar = CAN) then
      begin
        XModem_addLog('waitACK CAN');
        Exit(CAN);
      end;
  until (inChar = NAK) or (inChar = ACK) or (inChar = ord('C'));
  XModem_addLog('waitACK OK');
  Exit(inChar);
end;

// ---------------------------------------------------------
// Send file
Procedure TMainForm.XModem_sendFile(fileName: string);
var
  inChar: byte;
  i, j: integer;
  tryNo: byte;
  filesz: int64;
  filenstr : string;
  filesstr : string;
  dataFile : file of byte;
label
  err;
begin
  // Rewind data file before sending the file..
  system.Assign(dataFile, fileName);
  FileMode := 0;
  Reset(dataFile);
  filesz := FileSize(dataFile);
  // When doing YModem, send block 0 to inform host about
  // file name to be received
  if (mode = ModeYModem) then
  begin
    if (XModem_sync <> 0) then
      goto err;
    // Send header for virtual block 0 (file name)
    writeSerialByte(SOH);
    writeSerialByte($00);
    writeSerialByte($FF);
    filenstr := ExtractFileName(fileName);
    for i := 0 to Length(filenstr) - 1 do
    begin
      XModem_outputByte(ord(filenstr[i + 1]));
    end;
    filesstr := IntToStr(filesz);
    XModem_outputByte($00);
    i := Length(filenstr);
    for j := 0 to Length(filesstr) - 1 do
    begin
      XModem_outputByte(ord(filesstr[j]));
      Inc(i);
    end;
    for i := i to 127 do
    begin
      XModem_outputByte($00);
    end;
    if (oldChecksum > 0) then
      writeSerialByte(checksumBuf)
    else
    begin
      writeSerialByte(crcBuf shr 8);
      writeSerialByte(crcBuf and $FF);
    end;
    {Discard ACK/NAK/CAN, in case
    we communicate to an XMODEM-1k client
    which might not know about the 0 block.}
    XModem_waitACK(res);
  end;

  if (XModem_sync <> 0) then
    goto err;
  packetNo := 1;
  while not system.eof(dataFile) do
  begin
    filepos := system.FilePos(dataFile);
    // Sending a packet will be retried
    tryNo := 0;
    repeat
      // Seek to start of current data block,
      // will advance through the file as
      // block will be acked..
      Seek(dataFile, filepos);
      // Reset checksum stuff
      checksumBuf := $00;
      crcBuf := $00;
      // Try to use 1K(1024 byte) mode if possible
      if (mode = ModeYModem) and (FileSize(dataFile) - filepos >= 128) then
        packetLen := 1024 // 1K mode
      else
        packetLen := 128; // normal mode
      // Try to send packet, so header first
      if (packetLen = 128) then
        writeSerialByte(SOH)
      else
        writeSerialByte(STX);

      writeSerialByte(packetNo);
      writeSerialByte(NOT packetNo);
      for i := 0 to packetLen - 1 do
      begin
        if (not system.eof(dataFile)) then
           Read(dataFile, inChar)
        else
          inChar := EOF;
        XModem_outputByte(inChar);
      end;
      // Send out checksum, either CRC-16 CCITT or
      // classical inverse of sum of bytes.
      // Depending on how the received introduced himself
      if (oldChecksum > 0) then
        writeSerialByte(checksumBuf)
      else
      begin
        writeSerialByte(crcBuf shr 8);
        writeSerialByte(crcBuf and $FF);
      end;
      inChar := XModem_waitACK(res);
      if (inChar = CAN) then
        goto err;
      tryNo := tryNo + 1;
      if (tryNo > MAX_RETRY) then
        goto err;
    until (inChar = ACK);
    packetNo := packetNo + 1;
  end;

  // Send EOT and wait for ACK
  tryNo := 0;
  repeat
    writeSerialByte(EOT);
    inChar := XModem_waitACK(res);
    tryNo := tryNo + 1;
    // When timed out, leave immediately
    if (tryNo = SYNC_TIMEOUT) then
      goto err;
  until (inChar = ACK);

  // Send "all 00 data" to finish YModem.
  if (mode = ModeYModem) then
  begin
    // wait 'C' from Rx(PC)
    XModem_sync;
    // send header.
    writeSerialByte(SOH);
    writeSerialByte($00);
    writeSerialByte($FF);
    // Reset checksum stuff
    checksumBuf := 0;
    crcBuf := 0;
    // send all '00' data (128byte)
    for i := 0 to 127 do
    begin
      XModem_outputByte($00);
    end;
    // send checksum/CRC
    if (oldChecksum > 0) then
    begin
      writeSerialByte(checksumBuf); // need debug
    end
    else
    begin
      writeSerialByte(crcBuf shr 8);
      writeSerialByte(crcBuf and $FF);
    end;
    // Wait ACK from Rx.
    if (ACK <> XModem_waitACK(res)) then
      goto err;
  end;

  system.Close(dataFile);
  XModem_addLog('Finish sending.');
  exit;
err:
  system.Close(dataFile);
  XModem_addLog('Send error.');
end;

// ---------------------------------------------------------
// Send NACK as a sync packet for receiving file.
// Return first received byte if sync ok or 0 is sync timeout
function TMainForm.XModem_receiveSync(var resFunc:boolean): byte;
var
  tryNo: byte;
  inChar: byte;
begin
  resFunc := true;
  tryNo := 0;
  inBytesCounter := 0;
  repeat
    XModem_outputByte(NAK);
  	inChar := Serial.SynSer.RecvByte(1000);
  	if Serial.SynSer.LastError = 0 then
    begin
      oldChecksum := 1;
      packetLen := 128;
      XModem_addLog('Sync OK');
      exit(inChar);
    end;
    tryNo := tryNo + 1;
  until (tryNo = SYNC_TIMEOUT);
  XModem_addLog('Sync TIMEOUT');
  resFunc := false;
  exit(255);
end;

// ---------------------------------------------------------
// Receive byte of payload data,
// includes checksumming
function TMainForm.XModem_receiveByte(var resFunc:boolean): byte;
var
  j, inChar: byte;
begin
  resFunc := true;
  inChar := Serial.SynSer.RecvByte(1000);
  if Serial.SynSer.LastError <> 0 then
  begin
    resFunc := false;
    exit(255);
  end;

  Inc(inBytesCounter);
  checksumBuf := checksumBuf + inChar;
  crcBuf := crcBuf xor (inChar shl 8);
  j := 8;
  repeat
    if (crcBuf and $8000) <> 0 then
      crcBuf := (crcBuf shl 1) xor $1021
    else
      crcBuf := crcBuf shl 1;
    Dec(j);
  until j = 0;
  exit(inChar);
end;

// ---------------------------------------------------------
// Receive file
Procedure TMainForm.XModem_receiveFile(fileName: string);
var
  inChar, lastPacket, j: byte;
  receiveBuffer: array[1..133] of byte;
  dataFile: file of byte;
  foundEof, syncRead: boolean;
  fPos: longint;
begin
  // Rewind data file before sending the file..
  system.Assign(dataFile, fileName);
  system.Rewrite(dataFile);

  lastPacket := 0;
  // Receive sync from transmitter
  inChar := XModem_receiveSync(res);
  if res = true then
  begin
    foundEof := false;
    syncRead := true;
    repeat
      // Get first byte of packet, from SYNC procedure or directly from port
      if syncRead = true then
      begin
	syncRead := false;
      end
      else
      begin
  	inChar := Serial.SynSer.RecvByte(1000);
      end;
	  
      if inChar = SOH then // SOH found, the next data is packet data
      begin
        receiveBuffer[1] := inChar;
	// Read packet NO
	receiveBuffer[2] := Serial.SynSer.RecvByte(1000);
	// Read packet NO ext
	receiveBuffer[3] := Serial.SynSer.RecvByte(1000);
        // Reset checksum stuff
        checksumBuf := $00;
        crcBuf := $00;
	// Read packet data
	for j := 4 to packetLen + 3 do
	  receiveBuffer[j] := XModem_receiveByte(res);

	// Read CRC8
	receiveBuffer[132] := Serial.SynSer.RecvByte(1000);
	// Check data
	if (receiveBuffer[2] + receiveBuffer[3] = 255) and (receiveBuffer[132] = checksumBuf) then // OK ?
	begin
	  // Send ACK
	  writeSerialByte(ACK);
          // Repeat packet? Rewind to previous packet
          if receiveBuffer[2] = lastPacket then
          begin
            fPos := system.FilePos(dataFile);
            if fPos > packetLen then
               fPos := fPos - packetLen;
            system.Seek(dataFile, fPos);
          end;
          lastPacket := receiveBuffer[2];
	  // Save part of file...
	  for j := 4 to packetLen + 3 do
	    Write(dataFile, receiveBuffer[j]);
		
	  XModem_addLog('Packet ' + IntToStr(receiveBuffer[2]) + ' with CRC8 ' + IntToStr(receiveBuffer[132]) + ' OK');
	end
	else
	begin
  	  // Send NAK
	  writeSerialByte(NAK);

	  XModem_addLog('Packet ' + IntToStr(receiveBuffer[2]) + ' with CRC8 ' + IntToStr(receiveBuffer[132]) + ' ERROR');
	end;
      end
      else if inChar = EOT then // EOT found, end of transmission
      begin
  	// Send ACK
	writeSerialByte(ACK);
		
	foundEof := true;
        system.Close(dataFile);
		
	XModem_addLog('Receive OK');
      end;
    until foundEof = true;
  end;
end;

procedure TMainForm.XModem_addLog(str: string);
begin
  Memo1.Lines.Add(str);
end;

end.
