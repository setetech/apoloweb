unit uUploadWorker;

{ Fila de envio para a retaguarda (Oracle), fora do thread da VCL.

  Antes o fim da venda subia o cupom e o XML para o Oracle ali mesmo, no
  thread da tela. Com o Oracle do outro lado da internet, uma oscilacao no link
  prendia o caixa: no log de 22/09 um UploadVenda levou 44 s e um
  UploadDocEletronico 88 s, com o Windows mostrando "nao esta respondendo" e o
  operador tentado a matar o programa no meio da venda.

  Aqui o envio vira um pedido numa fila, atendido por um unico thread com
  conexoes proprias - Oracle E SQLite. A conexao SQLite da tela nao e'
  compartilhada: o arquivo esta em WAL, entao as duas convivem, e cada uma fica
  num thread so'. Os pedidos sao atendidos em ordem, entao a venda sobe antes do
  XML da nota dela.

  Falhou (Oracle fora, erro no meio)? O cupom continua sincronizado = 0 e o
  retry periodico (tuPendentes) pega de novo - o mesmo contrato de antes. }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  Uni, uSQLiteDB, uSincronizacao;

type
  TTipoUpload = (tuVenda, tuDocEletronico, tuPendentes);

  TJobUpload = record
    Tipo: TTipoUpload;
    CupomId: Integer;
  end;

  TUploadWorker = class(TThread)
  private
    FLock: TCriticalSection;
    FFila: TList<TJobUpload>;
    FEvento: TEvent;

    // Tudo abaixo so' e' usado dentro do Execute (exceto criacao/destruicao)
    FSQLite: TSQLiteDB;
    FSincronizador: TSincronizador;
    FConn: TUniConnection;

    // Protegidos por FLock
    FConnectString: string;
    FOpcoesOracle: string;
    FReconfigurar: Boolean;

    procedure Enfileirar(ATipo: TTipoUpload; ACupomId: Integer);
    function ProximoJob(out AJob: TJobUpload): Boolean;
    function GarantirConexao: Boolean;
    procedure DescartarConexao;
    procedure ExecutarJob(const AJob: TJobUpload);
  protected
    procedure Execute; override;
  public
    // Chamar no thread da VCL: o TSincronizador cria um TTimer
    constructor Create(const ADBPath: string);
    destructor Destroy; override;

    /// Dados de conexao do Oracle (copiados da conexao da tela). Pode ser
    /// chamado de novo apos reconfigurar: a proxima tarefa reconecta.
    procedure ConfigurarOracle(const AConnectString, AOpcoes: string);

    /// Sobe a venda (e cancelamentos pendentes) do cupom
    procedure EnfileirarVenda(ACupomId: Integer);
    /// Sobe o XML autorizado da NFCe do cupom
    procedure EnfileirarDocEletronico(ACupomId: Integer);
    /// Ciclo completo de pendentes (vendas, chaves, cancelamentos, XML, numerario)
    procedure EnfileirarPendentes;

    /// Pede para parar e espera ate ATimeoutMs. False = ainda preso numa
    /// chamada ao Oracle; nesse caso NAO liberar o objeto (o processo termina
    /// e leva o thread junto; o cupom fica pendente para o proximo start).
    function Parar(ATimeoutMs: Cardinal): Boolean;
  end;

implementation

uses
  Winapi.Windows, uSyncLog;

const
  NOME_TIPO: array[TTipoUpload] of string = ('venda', 'doceletronico', 'pendentes');

{ TUploadWorker }

constructor TUploadWorker.Create(const ADBPath: string);
begin
  // Create(False): o thread so' parte no AfterConstruction, depois deste
  // construtor inteiro. Nao chamar Start aqui - com Create(True) + Start o
  // AfterConstruction tenta dar Resume de novo e levanta EThread.
  inherited Create(False);
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FFila := TList<TJobUpload>.Create;
  FEvento := TEvent.Create(nil, False, False, '');

  FSQLite := TSQLiteDB.Create(ADBPath);
  FSincronizador := TSincronizador.Create(FSQLite);

  FConn := TUniConnection.Create(nil);
  FConn.LoginPrompt := False;
end;

destructor TUploadWorker.Destroy;
begin
  Terminate;
  if Assigned(FEvento) then
    FEvento.SetEvent;
  inherited;  // WaitFor

  if Assigned(FConn) then
    DescartarConexao;
  FConn.Free;
  FSincronizador.Free;
  FSQLite.Free;
  FEvento.Free;
  FFila.Free;
  FLock.Free;
end;

function TUploadWorker.Parar(ATimeoutMs: Cardinal): Boolean;
begin
  Terminate;
  FEvento.SetEvent;
  Result := WaitForSingleObject(Handle, ATimeoutMs) = WAIT_OBJECT_0;
end;

procedure TUploadWorker.ConfigurarOracle(const AConnectString, AOpcoes: string);
begin
  FLock.Enter;
  try
    FConnectString := AConnectString;
    FOpcoesOracle := AOpcoes;
    FReconfigurar := True;
  finally
    FLock.Leave;
  end;
end;

procedure TUploadWorker.Enfileirar(ATipo: TTipoUpload; ACupomId: Integer);
var
  LJob: TJobUpload;
  I: Integer;
begin
  FLock.Enter;
  try
    // Pedido igual ainda na fila nao precisa entrar de novo (o retry dispara
    // pendentes a cada ciclo; com o Oracle fora eles se acumulariam)
    for I := 0 to FFila.Count - 1 do
      if (FFila[I].Tipo = ATipo) and (FFila[I].CupomId = ACupomId) then
        Exit;

    LJob.Tipo := ATipo;
    LJob.CupomId := ACupomId;
    FFila.Add(LJob);
  finally
    FLock.Leave;
  end;
  FEvento.SetEvent;
end;

procedure TUploadWorker.EnfileirarVenda(ACupomId: Integer);
begin
  if ACupomId > 0 then
    Enfileirar(tuVenda, ACupomId);
end;

procedure TUploadWorker.EnfileirarDocEletronico(ACupomId: Integer);
begin
  if ACupomId > 0 then
    Enfileirar(tuDocEletronico, ACupomId);
end;

procedure TUploadWorker.EnfileirarPendentes;
begin
  Enfileirar(tuPendentes, 0);
end;

function TUploadWorker.ProximoJob(out AJob: TJobUpload): Boolean;
begin
  FLock.Enter;
  try
    Result := FFila.Count > 0;
    if Result then
    begin
      AJob := FFila[0];
      FFila.Delete(0);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TUploadWorker.DescartarConexao;
begin
  try
    if FConn.Connected then
      FConn.Disconnect;
  except
    // Conexao ja morta: o Disconnect pode reclamar, e tanto faz
  end;
end;

function TUploadWorker.GarantirConexao: Boolean;
var
  LConnectString, LOpcoes: string;
  LReconfigurar: Boolean;
begin
  Result := False;

  if not FSQLite.EstaAberto then
    FSQLite.AbrirBanco;

  FLock.Enter;
  try
    LConnectString := FConnectString;
    LOpcoes := FOpcoesOracle;
    LReconfigurar := FReconfigurar;
    FReconfigurar := False;
  finally
    FLock.Leave;
  end;

  if LConnectString = '' then
    Exit;

  if LReconfigurar then
  begin
    DescartarConexao;
    FConn.ConnectString := LConnectString;
    FConn.SpecificOptions.Text := LOpcoes;
    FConn.LoginPrompt := False;
  end;

  // Connected diz so' que a conexao foi aberta, nao que o link ainda esta
  // de pe'. O Ping custa uma ida ao servidor e evita o erro no meio do upload.
  if FConn.Connected then
  begin
    try
      FConn.Ping;
      Exit(True);
    except
      on E: Exception do
      begin
        SyncLog('UPLOAD fila: conexao Oracle caiu (%s), reconectando', [E.Message]);
        DescartarConexao;
      end;
    end;
  end;

  try
    FConn.Connect;
    Result := FConn.Connected;
  except
    on E: Exception do
      SyncLog('UPLOAD fila: Oracle indisponivel - [%s] %s', [E.ClassName, E.Message]);
  end;
end;

procedure TUploadWorker.ExecutarJob(const AJob: TJobUpload);
begin
  try
    if not GarantirConexao then
    begin
      if AJob.Tipo <> tuPendentes then
        SyncLog('UPLOAD fila: %s cupom=%d fica pendente para o retry',
          [NOME_TIPO[AJob.Tipo], AJob.CupomId]);
      Exit;
    end;

    case AJob.Tipo of
      tuVenda:
        begin
          FSincronizador.UploadVenda(FConn, AJob.CupomId);
          // UploadVenda so' enxerga cupom com sincronizado = 0, entao nao serve
          // para uma venda cancelada depois de ja ter subido. O sweep e' barato
          // e faz o cancelamento chegar na hora.
          FSincronizador.UploadCancelamentos(FConn);
        end;
      tuDocEletronico:
        FSincronizador.UploadDocEletronico(FConn, AJob.CupomId);
      tuPendentes:
        FSincronizador.ProcessarPendentes(FConn);
    end;
  except
    on E: Exception do
    begin
      SyncLog('UPLOAD fila: %s cupom=%d - [%s] %s',
        [NOME_TIPO[AJob.Tipo], AJob.CupomId, E.ClassName, E.Message]);
      // Erro fora do que o sincronizador ja trata: provavelmente a conexao.
      // Recomecar do zero na proxima tarefa.
      DescartarConexao;
    end;
  end;
end;

procedure TUploadWorker.Execute;
var
  LJob: TJobUpload;
begin
  NameThreadForDebugging('ApoloWeb.UploadWorker');
  while not Terminated do
  begin
    while (not Terminated) and ProximoJob(LJob) do
      ExecutarJob(LJob);

    if not Terminated then
      FEvento.WaitFor(INFINITE);
  end;
end;

end.
