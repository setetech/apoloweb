unit uConexaoWeb;

interface

uses
  System.SysUtils, System.Classes, System.JSON,
  Winapi.Windows, System.Win.Registry,
  System.Net.URLClient, System.Net.HttpClient, System.Net.HttpClientComponent,
  Uni, uSQLiteDB, uTypesApoloWeb, uConstantesWeb;

type
  TConexaoWeb = class
  private
    FSQLite: TSQLiteDB;
    FTipoConexao: TConexaoServidor;

    // Broker
    FURL_Broker: string;
    FUsuario_Broker: string;
    FSenha_Broker: string;
    FPorta_Broker: Integer;
    FMD5_Broker: string;

    // SOAP/WebService Oracle
    FURL_WSOra: string;
    FUsuario_WSOra: string;
    FSenha_WSOra: string;
    FPorta_WSOra: Integer;

    procedure CarregarConfiguracao;
  public
    constructor Create(ASQLite: TSQLiteDB);

    // Executar comando no servidor via Broker
    function ExecutarCmdBroker(const ASQL: string): string;

    // Executar comando via SOAP
    function ExecutarCmdSoap(const ASQL: string): string;

    // Obter dados do servidor (generico)
    function ObterDados(const ASQL: string): string;

    // Verificar conexao
    function TestarConexao: Boolean;

    // Data/hora do servidor
    function DataHoraServidor: TDateTime;

    property TipoConexao: TConexaoServidor read FTipoConexao;
  end;

implementation

uses
  System.NetEncoding, System.Hash;

{ TConexaoWeb }

constructor TConexaoWeb.Create(ASQLite: TSQLiteDB);
begin
  inherited Create;
  FSQLite := ASQLite;
  CarregarConfiguracao;
end;

procedure TConexaoWeb.CarregarConfiguracao;
var
  LReg: TRegistry;
begin
  FTipoConexao := conDireta;

  LReg := TRegistry.Create;
  try
    LReg.RootKey := HKEY_CURRENT_USER;

    // Broker
    if LReg.OpenKey(REG_SEC_BROKER, False) then
    begin
      if LReg.ValueExists('URL') then FURL_Broker := LReg.ReadString('URL');
      if LReg.ValueExists('usuario') then FUsuario_Broker := LReg.ReadString('usuario');
      if LReg.ValueExists('senha') then FSenha_Broker := LReg.ReadString('senha');
      if LReg.ValueExists('Porta') then FPorta_Broker := LReg.ReadInteger('Porta');
      if LReg.ValueExists('MD5') then FMD5_Broker := LReg.ReadString('MD5');
      if FPorta_Broker > 0 then FTipoConexao := conBroker;
      LReg.CloseKey;
    end;

    // Web Service Oracle
    if LReg.OpenKey(REG_SEC_WSORA, False) then
    begin
      if LReg.ValueExists('URL') then FURL_WSOra := LReg.ReadString('URL');
      if LReg.ValueExists('usuario') then FUsuario_WSOra := LReg.ReadString('usuario');
      if LReg.ValueExists('senha') then FSenha_WSOra := LReg.ReadString('senha');
      if LReg.ValueExists('Porta') then FPorta_WSOra := LReg.ReadInteger('Porta');
      if FPorta_WSOra > 0 then FTipoConexao := conSoap;
      LReg.CloseKey;
    end;
  finally
    LReg.Free;
  end;
end;

function TConexaoWeb.ExecutarCmdBroker(const ASQL: string): string;
var
  LHTTP: TNetHTTPClient;
  LParams: TStringList;
  LResp: IHTTPResponse;
  LURL: string;
  LHeaders: TNetHeaders;
begin
  Result := '';

  LURL := FURL_Broker;
  if Pos('/cmdsql', LowerCase(LURL)) = 0 then
    LURL := LURL + '/cmdsql';

  LHTTP := TNetHTTPClient.Create(nil);
  LParams := TStringList.Create;
  try
    LHTTP.ConnectionTimeout := 10000;
    LHTTP.ResponseTimeout := 30000;
    LHTTP.ContentType := 'application/x-www-form-urlencoded';

    SetLength(LHeaders, 1);
    LHeaders[0] := TNameValuePair.Create('Authorization', FMD5_Broker);

    LParams.Add('sql=' + TNetEncoding.URL.Encode(ASQL));

    try
      LResp := LHTTP.Post(LURL, LParams, nil, nil, LHeaders);
      Result := LResp.ContentAsString;
    except
      on E: Exception do
        raise Exception.Create('Erro na comunicacao com Broker: ' + E.Message);
    end;
  finally
    LParams.Free;
    LHTTP.Free;
  end;
end;

function TConexaoWeb.ExecutarCmdSoap(const ASQL: string): string;
var
  LHTTP: TNetHTTPClient;
  LRequest: TStringStream;
  LResp: IHTTPResponse;
  LEnvelope: string;
begin
  Result := '';

  // Montar envelope SOAP
  LEnvelope :=
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">' +
    '<SOAP-ENV:Body>' +
    '<sql>' + ASQL + '</sql>' +
    '</SOAP-ENV:Body>' +
    '</SOAP-ENV:Envelope>';

  LHTTP := TNetHTTPClient.Create(nil);
  LRequest := TStringStream.Create(LEnvelope, TEncoding.UTF8);
  try
    LHTTP.ConnectionTimeout := 10000;
    LHTTP.ResponseTimeout := 30000;
    LHTTP.ContentType := 'text/xml; charset=utf-8';

    try
      LResp := LHTTP.Post(FURL_WSOra, LRequest);
      Result := LResp.ContentAsString;
    except
      on E: Exception do
        raise Exception.Create('Erro na comunicacao SOAP: ' + E.Message);
    end;
  finally
    LRequest.Free;
    LHTTP.Free;
  end;
end;

function TConexaoWeb.ObterDados(const ASQL: string): string;
begin
  case FTipoConexao of
    conBroker: Result := ExecutarCmdBroker(ASQL);
    conSoap:   Result := ExecutarCmdSoap(ASQL);
  else
    Result := ''; // Para conexao direta, usar UniDAC diretamente
  end;
end;

function TConexaoWeb.TestarConexao: Boolean;
begin
  try
    case FTipoConexao of
      conBroker:
      begin
        ExecutarCmdBroker('SELECT 1 FROM DUAL');
        Result := True;
      end;
      conSoap:
      begin
        ExecutarCmdSoap('SELECT 1 FROM DUAL');
        Result := True;
      end;
    else
      Result := False;
    end;
  except
    Result := False;
  end;
end;

function TConexaoWeb.DataHoraServidor: TDateTime;
var
  LResp: string;
begin
  Result := Now;
  try
    LResp := ObterDados('SELECT TO_CHAR(SYSDATE, ''YYYY-MM-DD HH24:MI:SS'') dt FROM DUAL');
    // Parsear resposta - depende do formato de retorno do broker/soap
  except
    // Em caso de falha, usar data local
  end;
end;

end.
