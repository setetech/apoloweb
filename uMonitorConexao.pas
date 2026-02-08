unit uMonitorConexao;

interface

uses
  System.SysUtils, System.Classes, Vcl.ExtCtrls,
  Winapi.Windows, System.Win.Registry,
  System.Net.URLClient, System.Net.HttpClient, System.Net.HttpClientComponent,
  uSQLiteDB, uTypesApoloWeb, uConstantesWeb, uContingencia;

type
  TOnStatusConexaoChanged = procedure(AOnline: Boolean; ATipo: TTipoContingencia) of object;

  TMonitorConexao = class
  private
    FTimer: TTimer;
    FSQLite: TSQLiteDB;
    FContingencia: TContingenciaManager;
    FOnStatusChanged: TOnStatusConexaoChanged;
    FFalhasConsecutivas: Integer;
    FUltimaVerificacao: TDateTime;
    FOnline: Boolean;
    FURL_SEFAZ: string;
    FURL_Broker: string;

    procedure OnTimer(Sender: TObject);
    function TestarConexaoSEFAZ: Boolean;
    function TestarConexaoBroker: Boolean;
    procedure CarregarURLs;
  public
    constructor Create(ASQLite: TSQLiteDB; AContingencia: TContingenciaManager);
    destructor Destroy; override;

    procedure Iniciar;
    procedure Parar;
    function VerificarAgora: Boolean;

    property Online: Boolean read FOnline;
    property OnStatusChanged: TOnStatusConexaoChanged read FOnStatusChanged write FOnStatusChanged;
  end;

implementation

uses
  System.DateUtils;

{ TMonitorConexao }

constructor TMonitorConexao.Create(ASQLite: TSQLiteDB;
  AContingencia: TContingenciaManager);
begin
  inherited Create;
  FSQLite := ASQLite;
  FContingencia := AContingencia;
  FFalhasConsecutivas := 0;
  FOnline := True;
  FUltimaVerificacao := 0;

  CarregarURLs;

  FTimer := TTimer.Create(nil);
  FTimer.Interval := INTERVALO_MONITOR_CONEXAO;
  FTimer.OnTimer := OnTimer;
  FTimer.Enabled := False;
end;

destructor TMonitorConexao.Destroy;
begin
  FTimer.Enabled := False;
  FTimer.Free;
  inherited;
end;

procedure TMonitorConexao.CarregarURLs;
var
  LReg: TRegistry;
begin
  LReg := TRegistry.Create;
  try
    LReg.RootKey := HKEY_CURRENT_USER;

    // URL do Broker
    if LReg.OpenKey(REG_SEC_BROKER, False) then
    begin
      if LReg.ValueExists('URL') then
        FURL_Broker := LReg.ReadString('URL');
      LReg.CloseKey;
    end;

    // SEFAZ - usar URL conhecida baseada no estado (UF agora vem do SQLite)
    if FSQLite.ObterEstado('UF_WEBSERVICE', '') <> '' then
      FURL_SEFAZ := 'https://www.nfe.fazenda.gov.br/portal/disponibilidade.aspx';
  finally
    LReg.Free;
  end;
end;

procedure TMonitorConexao.Iniciar;
begin
  FTimer.Enabled := True;
end;

procedure TMonitorConexao.Parar;
begin
  FTimer.Enabled := False;
end;

function TMonitorConexao.VerificarAgora: Boolean;
var
  LConectouBroker, LConectouSEFAZ: Boolean;
  LAnterior: Boolean;
begin
  LAnterior := FOnline;
  FUltimaVerificacao := Now;

  // Testar conexao com broker/servidor
  LConectouBroker := TestarConexaoBroker;
  LConectouSEFAZ := TestarConexaoSEFAZ;

  if LConectouBroker or LConectouSEFAZ then
  begin
    FFalhasConsecutivas := 0;
    FOnline := True;

    // Se estava em contingencia automatica e voltou, notificar
    if not LAnterior and FOnline then
    begin
      if Assigned(FOnStatusChanged) then
        FOnStatusChanged(True, tcNenhuma);
    end;
  end
  else
  begin
    Inc(FFalhasConsecutivas);

    // Entrar em contingencia apos MAX_TENTATIVAS_CONTINGENCIA falhas
    if FFalhasConsecutivas >= MAX_TENTATIVAS_CONTINGENCIA then
    begin
      FOnline := False;

      if not FContingencia.EstaEmContingencia then
      begin
        FContingencia.EntrarContingencia(tcOffLine,
          'Perda de conexao detectada automaticamente apos ' +
          IntToStr(FFalhasConsecutivas) + ' tentativas');
      end;

      if Assigned(FOnStatusChanged) then
        FOnStatusChanged(False, FContingencia.TipoAtual);
    end;
  end;

  Result := FOnline;
end;

procedure TMonitorConexao.OnTimer(Sender: TObject);
begin
  VerificarAgora;
end;

function TMonitorConexao.TestarConexaoSEFAZ: Boolean;
var
  LHTTP: TNetHTTPClient;
  LResp: IHTTPResponse;
begin
  Result := False;
  if FURL_SEFAZ = '' then Exit;

  LHTTP := TNetHTTPClient.Create(nil);
  try
    LHTTP.ConnectionTimeout := 5000;
    LHTTP.ResponseTimeout := 5000;
    try
      LResp := LHTTP.Head(FURL_SEFAZ);
      Result := (LResp.StatusCode >= 200) and (LResp.StatusCode < 500);
    except
      Result := False;
    end;
  finally
    LHTTP.Free;
  end;
end;

function TMonitorConexao.TestarConexaoBroker: Boolean;
var
  LHTTP: TNetHTTPClient;
  LResp: IHTTPResponse;
begin
  Result := False;
  if FURL_Broker = '' then Exit;

  LHTTP := TNetHTTPClient.Create(nil);
  try
    LHTTP.ConnectionTimeout := 5000;
    LHTTP.ResponseTimeout := 5000;
    try
      LResp := LHTTP.Head(FURL_Broker);
      Result := (LResp.StatusCode >= 200) and (LResp.StatusCode < 500);
    except
      Result := False;
    end;
  finally
    LHTTP.Free;
  end;
end;

end.
