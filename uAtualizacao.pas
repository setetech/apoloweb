unit uAtualizacao;

{ ============================================================================
  Atualizacao da versao do caixa (aba Atualizacao da tela de Documentos
  Fiscais - controle 20 da rotina 8002).

  O ApoloWeb.exe novo fica compactado (.zip) num link configurado em
  [atualizacao] url do apoloweb.ini - a principio um arquivo do Google Drive
  compartilhado como "Qualquer pessoa com o link".

  Fluxo:
    1. BaixarNovaVersao: baixa o .zip para C:\Apolo\atualizacao\ e extrai o
       ApoloWeb.exe dele (roda em thread, chamado pelo bridge);
    2. InstalarNovaVersao: renomeia o exe em execucao para ApoloWeb.exe.old
       (o Windows permite renomear um exe aberto, nao sobrescrever), copia o
       novo no lugar e agenda a reabertura para quando este processo terminar;
    3. LimparAtualizacaoAnterior: na abertura seguinte apaga o .old.

  Os assets web vao embutidos no exe, entao trocar o exe atualiza a tela junto.
  ============================================================================ }

interface

uses
  System.SysUtils, System.Classes;

const
  ATUALIZACAO_SECAO      = 'atualizacao';
  ATUALIZACAO_CHAVE_URL  = 'url';
  ATUALIZACAO_URL_PADRAO =
    'https://drive.google.com/file/d/13OhbXdvV3UwVQFi10UJPxg7nqAyxGFH9/view';
  ATUALIZACAO_EXE        = 'ApoloWeb.exe';

type
  // ATotal = -1 quando o servidor nao informa o tamanho
  TProgressoDownload = reference to procedure(ABaixado, ATotal: Int64);

// Link configurado em [atualizacao] url do apoloweb.ini. Sem a chave, grava o
// link padrao no ini para ficar visivel a quem for trocar.
function UrlAtualizacaoConfigurada: string;

// Link de compartilhamento do Google Drive (/file/d/<id>/view, open?id=,
// uc?id=) vira o de download direto. Outro link volta como veio.
function LinkDownloadDireto(const AUrl: string): string;

// Baixa o .zip de AUrl e extrai o ApoloWeb.exe para PastaAtualizacao.
// Retorna o caminho do exe extraido; levanta excecao com a causa em texto
// para o operador quando algo da errado.
function BaixarNovaVersao(const AUrl: string;
  AProgresso: TProgressoDownload): string;

// Troca o exe em execucao por AExeNovo e agenda a reabertura do caixa para
// quando este processo terminar. Retorna False se a troca foi feita mas nao
// foi possivel agendar a reabertura (o operador abre o caixa na mao).
function InstalarNovaVersao(const AExeNovo: string): Boolean;

// Apaga o ApoloWeb.exe.old deixado pela atualizacao anterior
procedure LimparAtualizacaoAnterior;

function PastaAtualizacao: string;

implementation

uses
  Winapi.Windows, System.IniFiles, System.IOUtils, System.Zip, System.StrUtils,
  System.RegularExpressions, System.Net.HttpClient, System.Net.URLClient,
  uConstantesWeb, uSyncLog;

type
  // OnReceiveData do THTTPClient e' "of object": precisa de um objeto
  TReceptorProgresso = class
  private
    FProgresso: TProgressoDownload;
  public
    constructor Create(AProgresso: TProgressoDownload);
    procedure OnReceiveData(const Sender: TObject; AContentLength,
      AReadCount: Int64; var AAbort: Boolean);
  end;

constructor TReceptorProgresso.Create(AProgresso: TProgressoDownload);
begin
  inherited Create;
  FProgresso := AProgresso;
end;

procedure TReceptorProgresso.OnReceiveData(const Sender: TObject;
  AContentLength, AReadCount: Int64; var AAbort: Boolean);
begin
  if Assigned(FProgresso) then
    if AContentLength > 0 then
      FProgresso(AReadCount, AContentLength)
    else
      FProgresso(AReadCount, -1);
end;

function PastaAtualizacao: string;
begin
  Result := PASTA_RAIZ + 'atualizacao\';
end;

function ArquivoAntigo: string;
begin
  Result := ParamStr(0) + '.old';
end;

function UrlAtualizacaoConfigurada: string;
var
  LIni: TIniFile;
begin
  Result := ATUALIZACAO_URL_PADRAO;
  try
    LIni := TIniFile.Create(ARQ_APOLOWEB_INI);
    try
      if LIni.ValueExists(ATUALIZACAO_SECAO, ATUALIZACAO_CHAVE_URL) then
        Result := Trim(LIni.ReadString(ATUALIZACAO_SECAO, ATUALIZACAO_CHAVE_URL, ''))
      else
        LIni.WriteString(ATUALIZACAO_SECAO, ATUALIZACAO_CHAVE_URL,
          ATUALIZACAO_URL_PADRAO);
    finally
      LIni.Free;
    end;
  except
    // ini sem permissao de escrita: segue com o padrao
  end;
end;

function LinkDownloadDireto(const AUrl: string): string;
var
  LMatch: TMatch;
begin
  Result := Trim(AUrl);
  if not ContainsText(Result, 'drive.google.com') then Exit;

  // https://drive.google.com/file/d/<id>/view?usp=sharing
  LMatch := TRegEx.Match(Result, '/file/d/([A-Za-z0-9_-]+)');
  if not LMatch.Success then
    // https://drive.google.com/open?id=<id> e .../uc?id=<id>&export=download
    LMatch := TRegEx.Match(Result, '[?&]id=([A-Za-z0-9_-]+)');
  if not LMatch.Success then Exit;

  // drive.usercontent com confirm=t pula a pagina "nao foi possivel verificar
  // virus" que o Drive mostra para arquivos grandes
  Result := 'https://drive.usercontent.google.com/download?id=' +
    LMatch.Groups[1].Value + '&export=download&confirm=t';
end;

// Primeiros bytes do arquivo baixado, para distinguir .zip de pagina HTML
function InicioDoArquivo(const AArquivo: string; ATamanho: Integer): TBytes;
var
  LStream: TFileStream;
begin
  LStream := TFileStream.Create(AArquivo, fmOpenRead or fmShareDenyWrite);
  try
    if LStream.Size < ATamanho then
      ATamanho := LStream.Size;
    SetLength(Result, ATamanho);
    if ATamanho > 0 then
      LStream.ReadBuffer(Result[0], ATamanho);
  finally
    LStream.Free;
  end;
end;

function EhZip(const AArquivo: string): Boolean;
var
  LBytes: TBytes;
begin
  LBytes := InicioDoArquivo(AArquivo, 2);
  Result := (Length(LBytes) = 2) and (LBytes[0] = Ord('P')) and (LBytes[1] = Ord('K'));
end;

procedure Baixar(const AUrl, ADestino: string; AProgresso: TProgressoDownload);
var
  LHttp: THTTPClient;
  LReceptor: TReceptorProgresso;
  LStream: TFileStream;
  LResp: IHTTPResponse;
begin
  LReceptor := TReceptorProgresso.Create(AProgresso);
  LHttp := THTTPClient.Create;
  try
    LHttp.HandleRedirects := True;
    LHttp.ConnectionTimeout := 30000;
    LHttp.ResponseTimeout := 120000;
    LHttp.OnReceiveData := LReceptor.OnReceiveData;

    LStream := TFileStream.Create(ADestino, fmCreate);
    try
      LResp := LHttp.Get(AUrl, LStream);
    finally
      LStream.Free;
    end;

    if LResp.StatusCode <> 200 then
      raise Exception.CreateFmt('O servidor respondeu HTTP %d (%s) ao baixar a nova versao',
        [LResp.StatusCode, LResp.StatusText]);
  finally
    LHttp.Free;
    LReceptor.Free;
  end;
end;

function BaixarNovaVersao(const AUrl: string;
  AProgresso: TProgressoDownload): string;
var
  LUrl, LZip, LPagina: string;
  LZipFile: TZipFile;
  LBytes: TBytes;
  LMatch: TMatch;
  I, LIdx: Integer;
begin
  if Trim(AUrl) = '' then
    raise Exception.Create('Link da nova versao nao configurado em [' +
      ATUALIZACAO_SECAO + '] ' + ATUALIZACAO_CHAVE_URL + ' do ' +
      ExtractFileName(ARQ_APOLOWEB_INI));

  ForceDirectories(PastaAtualizacao);
  LZip := PastaAtualizacao + 'ApoloWeb.zip';
  Result := PastaAtualizacao + ATUALIZACAO_EXE;
  if FileExists(Result) then
    System.SysUtils.DeleteFile(Result);

  LUrl := LinkDownloadDireto(AUrl);
  SyncLog('ATUALIZACAO: baixando %s', [LUrl]);
  Baixar(LUrl, LZip, AProgresso);

  // Arquivo que o Drive nao consegue verificar ainda pode voltar como pagina
  // de confirmacao com um uuid no formulario; tenta mais uma vez com ele
  if not EhZip(LZip) then
  begin
    LPagina := TEncoding.UTF8.GetString(InicioDoArquivo(LZip, 65536));
    LMatch := TRegEx.Match(LPagina, 'name="uuid"\s+value="([^"]+)"');
    if LMatch.Success then
    begin
      SyncLog('ATUALIZACAO: Drive pediu confirmacao, repetindo com uuid');
      Baixar(LUrl + '&uuid=' + LMatch.Groups[1].Value, LZip, AProgresso);
    end;
  end;

  if not EhZip(LZip) then
    raise Exception.Create('O link nao devolveu um arquivo .zip. Confira se o ' +
      'arquivo existe e esta compartilhado como "Qualquer pessoa com o link".');

  LZipFile := TZipFile.Create;
  try
    LZipFile.Open(LZip, zmRead);
    LIdx := -1;
    for I := 0 to LZipFile.FileCount - 1 do
      if SameText(ExtractFileName(StringReplace(LZipFile.FileNames[I], '/', '\',
        [rfReplaceAll])), ATUALIZACAO_EXE) then
      begin
        LIdx := I;
        Break;
      end;
    if LIdx < 0 then
      raise Exception.Create('O .zip baixado nao contem o ' + ATUALIZACAO_EXE);

    LZipFile.Read(LIdx, LBytes);
  finally
    LZipFile.Free;
  end;

  if (Length(LBytes) < 2) or (LBytes[0] <> Ord('M')) or (LBytes[1] <> Ord('Z')) then
    raise Exception.Create('O ' + ATUALIZACAO_EXE + ' dentro do .zip nao e um executavel valido');

  TFile.WriteAllBytes(Result, LBytes);
  System.SysUtils.DeleteFile(LZip);
  SyncLog('ATUALIZACAO: %s extraido (%d bytes, versao %s)',
    [Result, Length(LBytes), VersaoArquivo(Result)]);
end;

function InstalarNovaVersao(const AExeNovo: string): Boolean;
var
  LAtual, LAntigo, LCmd: string;
  LSI: TStartupInfo;
  LPI: TProcessInformation;
begin
  LAtual := ParamStr(0);
  LAntigo := ArquivoAntigo;

  if not FileExists(AExeNovo) then
    raise Exception.Create('Arquivo da nova versao nao encontrado: ' + AExeNovo);

  if FileExists(LAntigo) and not System.SysUtils.DeleteFile(LAntigo) then
    raise Exception.Create('Nao foi possivel apagar ' + LAntigo + ': ' +
      SysErrorMessage(GetLastError));

  if not RenameFile(LAtual, LAntigo) then
    raise Exception.Create('Nao foi possivel renomear o executavel atual: ' +
      SysErrorMessage(GetLastError));

  if not CopyFile(PChar(AExeNovo), PChar(LAtual), False) then
  begin
    LCmd := SysErrorMessage(GetLastError);
    RenameFile(LAntigo, LAtual);  // volta a versao atual
    raise Exception.Create('Nao foi possivel copiar a nova versao: ' + LCmd);
  end;
  SyncLog('ATUALIZACAO: %s substituido (versao anterior em %s)', [LAtual, LAntigo]);

  // Reabre so depois que este processo terminar: duas instancias ao mesmo
  // tempo disputariam o SQLite, o TEF e a impressora
  LCmd := Format('powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden ' +
    '-Command "Wait-Process -Id %d -ErrorAction SilentlyContinue; ' +
    'Start-Process -FilePath ''%s'' -WorkingDirectory ''%s''"',
    [GetCurrentProcessId, LAtual, ExtractFileDir(LAtual)]);
  UniqueString(LCmd);

  FillChar(LSI, SizeOf(LSI), 0);
  LSI.cb := SizeOf(LSI);
  LSI.dwFlags := STARTF_USESHOWWINDOW;
  LSI.wShowWindow := SW_HIDE;
  Result := CreateProcess(nil, PChar(LCmd), nil, nil, False, CREATE_NO_WINDOW,
    nil, nil, LSI, LPI);
  if Result then
  begin
    CloseHandle(LPI.hThread);
    CloseHandle(LPI.hProcess);
  end
  else
    SyncLog('ATUALIZACAO: nao agendou a reabertura: %s', [SysErrorMessage(GetLastError)]);
end;

procedure LimparAtualizacaoAnterior;
begin
  try
    if FileExists(ArquivoAntigo) then
      System.SysUtils.DeleteFile(ArquivoAntigo);
  except
    // fica para a proxima abertura
  end;
end;

end.
