unit uMonitorConexao;

{ Monitor de conexao do caixa.

  Decide quando entrar em contingencia OFFLINE e quando o caixa pode voltar a
  emitir online. NAO sabe testar nada sozinho: o teste vem de fora, pelo
  OnTestarConexao (o form usa o StatusServico do SEFAZ e, como alternativa, a
  conexao com o Oracle). Aqui mora so' a politica.

  Historico do que deu errado antes (08/09/2026, caixa 33 - 96% das vendas do
  dia emitidas offline sem uma unica queda real):

  1. O teste era um HEAD na pagina de disponibilidade do portal nacional e uma
     URL de Broker lida do registro (que nao existia, entao dava False sempre).
     Nenhum dos dois diz se o webservice de NFCe da UF esta no ar.
  2. FFalhasConsecutivas so' zerava quando um teste passava, e a entrada em
     contingencia era reavaliada a cada tick. Depois de 3 falhas o caixa
     reentrava em contingencia todo minuto - inclusive logo depois de sair.
     As 11:43 a fila zerou e ele saiu; as 11:45 uma venda saiu normal e foi
     autorizada na hora; as 11:48 ja estava offline de novo.
  3. A volta so' era notificada na transicao offline->online do proprio
     monitor. A contingencia aberta pela falha de envio da NFCe nao passa por
     aqui, entao nao havia transicao para notificar e ninguem retransmitia:
     as notas do dia 05 so' subiram no dia 08, ~71h depois. }

interface

uses
  System.SysUtils, System.Classes, Vcl.ExtCtrls,
  uSQLiteDB, uTypesApoloWeb, uConstantesWeb, uContingencia;

type
  TOnStatusConexaoChanged = procedure(AOnline: Boolean; ATipo: TTipoContingencia) of object;
  TTesteConexao = function: Boolean of object;

  TMonitorConexao = class
  private
    FTimer: TTimer;
    FSQLite: TSQLiteDB;
    FContingencia: TContingenciaManager;
    FOnStatusChanged: TOnStatusConexaoChanged;
    FOnTestarConexao: TTesteConexao;
    FFalhasConsecutivas: Integer;
    FUltimaVerificacao: TDateTime;
    FOnline: Boolean;

    procedure OnTimer(Sender: TObject);
    function ConexaoDisponivel: Boolean;
  public
    constructor Create(ASQLite: TSQLiteDB; AContingencia: TContingenciaManager);
    destructor Destroy; override;

    procedure Iniciar;
    procedure Parar;
    function VerificarAgora: Boolean;

    property Online: Boolean read FOnline;
    property OnStatusChanged: TOnStatusConexaoChanged read FOnStatusChanged write FOnStatusChanged;
    // Teste de conectividade. Sem ele o monitor considera o caixa online e
    // nunca entra em contingencia sozinho - o que e' melhor que entrar por
    // engano, porque a falha real de envio da NFCe ja cobre esse caso.
    property OnTestarConexao: TTesteConexao read FOnTestarConexao write FOnTestarConexao;
  end;

implementation

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

procedure TMonitorConexao.Iniciar;
begin
  FTimer.Enabled := True;
end;

procedure TMonitorConexao.Parar;
begin
  FTimer.Enabled := False;
end;

function TMonitorConexao.ConexaoDisponivel: Boolean;
begin
  if not Assigned(FOnTestarConexao) then
    Exit(True);
  try
    Result := FOnTestarConexao;
  except
    Result := False;
  end;
end;

function TMonitorConexao.VerificarAgora: Boolean;
var
  LAnterior: Boolean;
begin
  LAnterior := FOnline;
  FUltimaVerificacao := Now;

  if ConexaoDisponivel then
  begin
    FFalhasConsecutivas := 0;
    FOnline := True;

    // Notificar a volta quando o monitor estava offline OU quando o caixa
    // esta em contingencia com o monitor se achando online - e' o caso da
    // contingencia aberta pela falha de envio da NFCe, que nunca gerou
    // transicao e por isso deixava as notas paradas por horas.
    if Assigned(FOnStatusChanged) and
       ((not LAnterior) or FContingencia.EstaEmContingencia) then
      FOnStatusChanged(True, tcNenhuma);
  end
  else if FContingencia.EstaEmContingencia then
  begin
    // Ja esta offline: nao acumular falhas. Sem isso o contador continuava
    // subindo durante toda a contingencia e, no instante em que a fila
    // zerava e o caixa saia, o proximo tick ja o jogava de volta.
    FFalhasConsecutivas := 0;
    FOnline := False;
    if LAnterior and Assigned(FOnStatusChanged) then
      FOnStatusChanged(False, FContingencia.TipoAtual);
  end
  else
  begin
    Inc(FFalhasConsecutivas);

    if FFalhasConsecutivas >= MAX_TENTATIVAS_CONTINGENCIA then
    begin
      FOnline := False;
      FContingencia.EntrarContingencia(tcOffLine,
        'Perda de conexao detectada automaticamente apos ' +
        IntToStr(FFalhasConsecutivas) + ' tentativas');
      // Sair da contingencia exige 3 falhas NOVAS para reentrar
      FFalhasConsecutivas := 0;

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

end.
