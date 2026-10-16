unit uMainForm;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.Edge, Vcl.ExtCtrls, Winapi.WebView2_Colosso, ActiveX,
  uBridge, uSQLiteDB, uConstantesWeb, uTypesApoloWeb, uTEF,
  uContingencia, uNFCeWeb, uMonitorConexao, uSincronizacao, uUploadWorker,
  Winapi.WebView2;

type
  TFrmMain = class(TForm)
    EdgeBrowser: TEdgeBrowser;
    TimerInit: TTimer;
    TimerDiag: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure EdgeBrowserNavigationCompleted(Sender: TCustomEdgeBrowser;
      IsSuccess: Boolean; WebErrorStatus: TOleEnum);
    procedure EdgeBrowserWebMessageReceived(Sender: TCustomEdgeBrowser;
      Args: TWebMessageReceivedEventArgs);
    procedure EdgeBrowserCreateWebViewCompleted(Sender: TCustomEdgeBrowser;
      AResult: HRESULT);
    procedure TimerInitTimer(Sender: TObject);
    procedure TimerDiagTimer(Sender: TObject);
  private
    FBridge: TApoloBridge;
    FSQLite: TSQLiteDB;
    FWebViewReady: Boolean;
    FContingencia: TContingenciaManager;
    FNFCeManager: TNFCeWebManager;
    FMonitorConexao: TMonitorConexao;
    FSincronizador: TSincronizador;
    // Envios para o Oracle (venda, XML, pendentes) fora do thread da tela
    FUploadWorker: TUploadWorker;
    FSincronizando: Boolean;
    // Quantas verificacoes de conexao seguidas foram puladas por causa de
    // venda aberta (ver TestarConexaoServidor)
    FProbesPulados: Integer;
    FTimerSync: TTimer;
    procedure InicializarSistema;
    procedure EnviarParaJS(const AAction, AData: string);
    procedure ProcessarMensagemJS(const AJson: string);
    procedure ConfigurarEdgeBrowser;
    // Callbacks para bridge
    procedure DoGerarNFCe(ACupomId: Integer; var AChaveNFe, AProtocolo: string);
    procedure DoCancelarNFCe(ACupomId: Integer; const AJustificativa: string;
      var ASucesso: Boolean; var AMensagem: string);
    procedure DoReimprimirNFCe(const AChaveNFe: string;
      var ASucesso: Boolean; var AMensagem: string);
    procedure DoRetransmitir(var AQtdEnviados, AQtdErros: Integer);
    procedure DoRegerarNFCe(const AIds: TArray<Integer>;
      var AQtdOk, AQtdErro: Integer; var AMensagem: string);
    procedure DoUploadVenda(ACupomId: Integer);
    procedure ConfigurarUploadWorker;
    procedure DoRetrySync(Sender: TObject);
    procedure DoSincronizarDados;
    procedure DoForcarSincronizacao;
    procedure SincronizarDadosInterno(AForcar: Boolean);
    procedure DoFecharApp(Sender: TObject);
    procedure OnStatusConexaoChanged(AOnline: Boolean; ATipo: TTipoContingencia);
    function TestarConexaoServidor: Boolean;
    procedure TimerSyncTimer(Sender: TObject);
    procedure OcultarTaskbar;
    procedure ExibirTaskbar;
  public
    property Bridge: TApoloBridge read FBridge;
    property SQLite: TSQLiteDB read FSQLite;
    property WebViewReady: Boolean read FWebViewReady;
    property Contingencia: TContingenciaManager read FContingencia;
    property NFCeManager: TNFCeWebManager read FNFCeManager;
    property MonitorConexao: TMonitorConexao read FMonitorConexao;
    property Sincronizador: TSincronizador read FSincronizador;
    procedure ExecuteJS(const AScript: string);
  end;

var
  FrmMain: TFrmMain;

implementation

{$R *.dfm}

uses
  System.JSON, System.IOUtils, Uni, uDmApoloWeb, uFrmConfigConexao, uSyncLog;

procedure TFrmMain.FormCreate(Sender: TObject);
begin
  FWebViewReady := False;

  // Configurar form - tela cheia sem bordas (modo PDV)
  KeyPreview := True;
  Color := clBlack;
  BorderStyle := bsNone;
  OcultarTaskbar;
  SetBounds(0, 0, Screen.Width, Screen.Height);

  // Configurar EdgeBrowser PRIMEIRO (prioridade - nao depende de nada)
  ConfigurarEdgeBrowser;

  // Inicializar modulos de negocio com protecao
  try
    // Usar SQLite do DataModule (instancia unica)
    FSQLite := DmApoloWeb.SQLiteDB;

    FContingencia := TContingenciaManager.Create(FSQLite);
    FSincronizador := TSincronizador.Create(FSQLite);
    FUploadWorker := TUploadWorker.Create(FSQLite.DBPath);

    // NFCe Manager (depende do ACBr no DataModule)
    if Assigned(DmApoloWeb) and Assigned(DmApoloWeb.ACBrNFe) then
      FNFCeManager := TNFCeWebManager.Create(FSQLite, DmApoloWeb.ACBrNFe, FContingencia)
    else
      FNFCeManager := nil;

    // Monitor de conexao
    FMonitorConexao := TMonitorConexao.Create(FSQLite, FContingencia);
    FMonitorConexao.OnStatusChanged := OnStatusConexaoChanged;
    FMonitorConexao.OnTestarConexao := TestarConexaoServidor;

    // Retry de pendentes (vendas, doc eletronico e numerario) a cada
    // INTERVALO_RETRY_SYNC. O timer vive no sincronizador; a conexao e daqui.
    FSincronizador.OnRetry := DoRetrySync;

    // Inicializar Bridge com callbacks
    FBridge := TApoloBridge.Create(Self, FSQLite, FContingencia);
    FBridge.OnGerarNFCe := DoGerarNFCe;
    FBridge.OnCancelarNFCe := DoCancelarNFCe;
    FBridge.OnReimprimirNFCe := DoReimprimirNFCe;
    FBridge.OnRetransmitir := DoRetransmitir;
  FBridge.OnRegerarNFCe := DoRegerarNFCe;
    FBridge.OnUploadVenda := DoUploadVenda;
    FBridge.OnSincronizar := DoSincronizarDados;
    FBridge.OnForcarSincronizacao := DoForcarSincronizacao;
    FBridge.OnFecharApp := DoFecharApp;
    FBridge.OnEnviarParaJS :=
      procedure(AAction, AData: string)
      begin
        EnviarParaJS(AAction, AData);
      end;
    // Inicializar TEF se habilitado
    FBridge.InicializarTEF(DmApoloWeb.TEFConfig, DmApoloWeb.NumCaixa);

    // Timer de sincronizacao automatica
    FTimerSync := TTimer.Create(Self);
    FTimerSync.Interval := INTERVALO_SYNC_AUTO;
    FTimerSync.OnTimer := TimerSyncTimer;
    FTimerSync.Enabled := False; // Ativado apos InicializarSistema
  except
    // O form nao tem borda: o Caption sozinho e' invisivel e a falha so'
    // aparecia depois, como Access Violation no primeiro uso do bridge
    on E: Exception do
    begin
      Caption := 'ApoloWeb - ERRO init: ' + E.Message;
      SyncLog('INIT: falha ao criar os modulos - [%s] %s', [E.ClassName, E.Message]);
    end;
  end;
end;

procedure TFrmMain.FormDestroy(Sender: TObject);
begin
  // Restaurar barra de tarefas do Windows
  ExibirTaskbar;

  if Assigned(FTimerSync) then
  begin
    FTimerSync.Enabled := False;
    FTimerSync.Free;
  end;
  if Assigned(FMonitorConexao) then
  begin
    FMonitorConexao.Parar;
    FMonitorConexao.Free;
  end;
  FSincronizador.Free;
  // Preso numa chamada ao Oracle o thread nao responde ao Terminate; esperar
  // o timeout de rede aqui travaria o fechamento. Nesse caso fica sem Free - o
  // processo termina e leva o thread, e o cupom sobe no proximo start.
  if Assigned(FUploadWorker) then
  begin
    if FUploadWorker.Parar(5000) then
      FUploadWorker.Free
    else
      SyncLog('UPLOAD fila: encerrando com envio em andamento (fica pendente)');
  end;
  FNFCeManager.Free;
  FBridge.Free;
  FContingencia.Free;
  // FSQLite pertence ao DmApoloWeb, nao liberar aqui
end;

procedure TFrmMain.ConfigurarEdgeBrowser;
begin
  EdgeBrowser.Align := alClient;

  // Garantir que a pasta de cache exista
  ForceDirectories('C:\Apolo\WebView2Cache');

  // Setar UserDataFolder em codigo (DFM nao expande variaveis de ambiente)
  EdgeBrowser.UserDataFolder := 'C:\Apolo\WebView2Cache';

  // IMPORTANTE: TEdgeBrowser NAO inicializa automaticamente no CreateWnd.
  // A inicializacao eh disparada pela chamada a Navigate().
  // Navigate com FWebView=nil: chama CreateWebView e salva URL em FLastURI.
  // Apos CreateWebViewCompleted, o componente auto-navega para FLastURI.
  EdgeBrowser.Navigate('https://apolo.local/index.html');

  // Timer de diagnostico - se o WebView nao inicializar em 5s, mostra info
  TimerDiag.Interval := 5000;
  TimerDiag.Enabled := True;
end;

procedure TFrmMain.TimerDiagTimer(Sender: TObject);
begin
  TimerDiag.Enabled := False;
  if not FWebViewReady then
    ShowMessage('WebView2 nao inicializou. Verifique WebView2Loader.dll e WebView2 Runtime.');
end;

procedure TFrmMain.EdgeBrowserCreateWebViewCompleted( Sender: TCustomEdgeBrowser; AResult: HRESULT);
var
  LWebView3: ICoreWebView2_3;
begin
  if Succeeded(AResult) then
  begin
    FWebViewReady := True;

    // Configurar virtual host mapping: mapeia 'apolo.local' para C:\Apolo\web
    // Isso permite usar https://apolo.local/index.html ao inves de file:///
    // Resolve problemas de seguranca com caminhos relativos em file://
    if Assigned(EdgeBrowser.DefaultInterface) and
       Succeeded(EdgeBrowser.DefaultInterface.QueryInterface(ICoreWebView2_3, LWebView3)) then
    begin
      LWebView3.SetVirtualHostNameToFolderMapping(
        'apolo.local',
        PChar(PASTA_WEB),
        COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW
      );
    end
    else
      // Sem ICoreWebView2_3 o virtual host nao e mapeado e a navegacao para
      // https://apolo.local falha em tela branca (BuiltInErrorPage desativada).
      ShowMessage('WebView2 Runtime desatualizado: nao suporta virtual host ' +
        'mapping (requer Runtime 89+).' + sLineBreak +
        'Atualize o "Microsoft Edge WebView2 Runtime" nesta maquina.');

    // Desabilitar context menu do browser (direito clique)
    EdgeBrowser.DefaultContextMenusEnabled := False;
    EdgeBrowser.DevToolsEnabled := {$IFDEF DEBUG}True{$ELSE}False{$ENDIF};
    EdgeBrowser.StatusBarEnabled := False;
    EdgeBrowser.BuiltInErrorPageEnabled := False;

  end
  else
    ShowMessage('Erro ao inicializar WebView2. HRESULT: ' + IntToHex(AResult, 8));
end;


procedure TFrmMain.EdgeBrowserNavigationCompleted(
  Sender: TCustomEdgeBrowser; IsSuccess: Boolean; WebErrorStatus: TOleEnum);
var
  LURL: string;
begin
  LURL := EdgeBrowser.LocationURL;

  // Ignorar navegacao ao about:blank
  if (LURL = '') or (Pos('about:blank', LURL) > 0) then
    Exit;

  if IsSuccess then
  begin
    Caption := NOME_SISTEMA + ' v' + VERSAO_SISTEMA +
      ' | Caixa: ' + IntToStr(DmApoloWeb.NumCaixa) +
      ' | Filial: ' + DmApoloWeb.CodFilial;
    // Frontend carregado, inicializar sistema
    TimerInit.Enabled := True;
  end
  else
  begin
    Caption := 'ApoloWeb - ERRO na navegacao. Status: ' + IntToStr(WebErrorStatus);
    // Form sem borda: o Caption e invisivel, entao mostrar o erro de fato.
    // WebErrorStatus: ver COREWEBVIEW2_WEB_ERROR_STATUS (3=HostNameNotResolved,
    // tipico de virtual host nao mapeado; 14=ERROR_FILE_NOT_FOUND).
    ShowMessage('Falha ao carregar o frontend.' + sLineBreak +
      'URL: ' + LURL + sLineBreak +
      'WebErrorStatus: ' + IntToStr(WebErrorStatus) + sLineBreak + sLineBreak +
      'Verifique se ' + PASTA_WEB + 'index.html existe e se o ' +
      'WebView2 Runtime esta atualizado.');
  end;
end;

procedure TFrmMain.TimerInitTimer(Sender: TObject);
begin
  TimerInit.Enabled := False;
  InicializarSistema;
end;

procedure TFrmMain.InicializarSistema;
var
  LEstado: string;
  LJson: TJSONObject;
  LNumCupom: Variant;
begin
  // Enviar informacoes iniciais para o frontend
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('versao', VERSAO_SISTEMA);
    // Versao do binario em uso (VERSIONINFO) - exibida no rodape do login e
    // no header do PDV para identificar a build instalada na loja.
    LJson.AddPair('versaoExe', VersaoExecutavel);
    LJson.AddPair('sistema', NOME_SISTEMA);

    LEstado := FSQLite.ObterEstado(KEY_ESTADO, '0');
    LJson.AddPair('estadoCaixa', TJSONNumber.Create(StrToIntDef(LEstado, 0)));
    LJson.AddPair('numCaixa', FSQLite.ObterEstado(KEY_NUMCAIXA, '0'));
    LJson.AddPair('codFilial', FSQLite.ObterEstado(KEY_CODFILIAL, ''));
    LJson.AddPair('hdSerial', FSQLite.ObterEstado(KEY_HD_SERIAL, ''));
    LJson.AddPair('operador', FSQLite.ObterEstado(KEY_OPERADOR, ''));

    // TEF
    LJson.AddPair('tefHabilitado', TJSONBool.Create(FBridge.TEFHabilitado));
    LJson.AddPair('tefPixQrTela', TJSONBool.Create(FBridge.TEFPixQrNaTela));

    // Dados da venda em andamento (recuperacao apos queda)
    LJson.AddPair('cupomAtualId', TJSONNumber.Create(FBridge.CupomAtualId));
    if FBridge.CupomAtualId > 0 then
    begin
      LNumCupom := FSQLite.ExecutarScalar(
        'SELECT numcupom FROM cupons WHERE id = ' + IntToStr(FBridge.CupomAtualId)
      );
      if not VarIsNull(LNumCupom) then
        LJson.AddPair('numCupomVenda', TJSONNumber.Create(Integer(LNumCupom)))
      else
        LJson.AddPair('numCupomVenda', TJSONNumber.Create(0));
    end;

    EnviarParaJS('init', LJson.ToJSON);
  finally
    LJson.Free;
  end;

  // Sincronizar dados do Oracle na inicializacao (em thread)
  DoSincronizarDados;

  // Iniciar monitor de conexao
  FMonitorConexao.Iniciar;

  // Ativar timer de sincronizacao automatica
  if Assigned(FTimerSync) then
    FTimerSync.Enabled := True;

  // Ativar retry de pendentes e ja tentar subir o que ficou para tras
  ConfigurarUploadWorker;
  FSincronizador.IniciarRetry;
  DoRetrySync(nil);

  // Contingencia restaurada de uma sessao anterior: avisar em vez de emitir
  // offline em silencio. A retransmissao e' disparada pelo operador (F-key /
  // botao Retransmitir) ou quando o monitor confirmar que voltou online.
  if FContingencia.EstaEmContingencia then
    SyncLog('CONTINGENCIA: app iniciou em %s com %d documento(s) pendente(s)',
      [FContingencia.TipoAtual.ToString, FContingencia.QtdePendentes]);

  // Se NFCe nao foi criado no FormCreate (DM nao estava pronto), tentar agora
  if not Assigned(FNFCeManager) and Assigned(DmApoloWeb) and Assigned(DmApoloWeb.ACBrNFe) then
  begin
    FNFCeManager := TNFCeWebManager.Create(FSQLite, DmApoloWeb.ACBrNFe, FContingencia);
  end;
end;

procedure TFrmMain.EdgeBrowserWebMessageReceived(
  Sender: TCustomEdgeBrowser; Args: TWebMessageReceivedEventArgs);
var  LMsg: PWideChar;
begin
  // Receber mensagens do JavaScript
  Args.ArgsInterface.TryGetWebMessageAsString(LMsg);
  if LMsg <> nil then  begin
    ProcessarMensagemJS(LMsg);
    CoTaskMemFree(LMsg);
  end;
end;

procedure TFrmMain.ProcessarMensagemJS(const AJson: string);
var
  LJsonObj: TJSONObject;
  LAction, LData, LCallbackId: string;
  LResult: string;
begin
  LJsonObj := TJSONObject.ParseJSONValue(AJson) as TJSONObject;
  if LJsonObj = nil then Exit;

  try
    LAction := LJsonObj.GetValue<string>('action', '');
    LData := LJsonObj.GetValue<string>('data', '{}');
    LCallbackId := LJsonObj.GetValue<string>('callbackId', '');

    // Delegar para o Bridge
    LResult := FBridge.ProcessarAcao(LAction, LData);

    // Enviar resposta de volta ao JS
    if LCallbackId <> '' then
      ExecuteJS('window.__apoloCallbacks["' + LCallbackId + '"](' + LResult + ')')
    else
      EnviarParaJS(LAction + '_response', LResult);
  finally
    LJsonObj.Free;
  end;
end;

procedure TFrmMain.EnviarParaJS(const AAction, AData: string);
var
  LScript: string;
begin
  if not FWebViewReady then Exit;

  LScript := 'if(window.ApoloApp && window.ApoloApp.onMessage){' +
    'window.ApoloApp.onMessage(' +
    QuotedStr(AAction) + ',' + AData + ');}';
  ExecuteJS(LScript);
end;

procedure TFrmMain.ExecuteJS(const AScript: string);
begin
  if FWebViewReady and (EdgeBrowser <> nil) then
    EdgeBrowser.ExecuteScript(AScript);
end;

procedure TFrmMain.FormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
var
  LKeyStr: string;
begin
  // Ctrl+F12 = Configuracao (somente matricula 1)
  if (Key = VK_F12) and (ssCtrl in Shift) then
  begin
    if not Assigned(FBridge) or (FBridge.MatriculaLogada <> 1) then
    begin
      Key := 0;
      Exit;
    end;
    if AbrirConfigConexao then
    begin
      // Recarregar configuracao e reconectar
      DmApoloWeb.CarregarConfiguracao;
      DmApoloWeb.ConectarOracle;
      ConfigurarUploadWorker;
      if DmApoloWeb.ConectadoOracle then
        Caption := NOME_SISTEMA + ' v' + VERSAO_SISTEMA +
          ' | Caixa: ' + IntToStr(DmApoloWeb.NumCaixa) +
          ' | Filial: ' + DmApoloWeb.CodFilial
      else
        Caption := NOME_SISTEMA + ' v' + VERSAO_SISTEMA + ' | OFFLINE';
      // Reinicializar TEF com nova configuracao
      FBridge.InicializarTEF(DmApoloWeb.TEFConfig, DmApoloWeb.NumCaixa);
    end;
    Key := 0;
    Exit;
  end;

  // Alt+F4 = Fechar aplicacao
  if (Key = VK_F4) and (ssAlt in Shift) then
  begin
    Close;
    Exit;
  end;

  // Interceptar teclas F1-F12 e repassar ao JS
  case Key of
    VK_F1..VK_F12:
    begin
      LKeyStr := 'F' + IntToStr(Key - VK_F1 + 1);
      EnviarParaJS('keypress', '{"key":"' + LKeyStr + '"}');
      Key := 0; // Consumir a tecla
    end;
    VK_ESCAPE:
    begin
      EnviarParaJS('keypress', '{"key":"Escape"}');
      Key := 0;
    end;
  end;
end;

// =========================================================================
// CALLBACKS NFCe
// =========================================================================

procedure TFrmMain.DoGerarNFCe(ACupomId: Integer;
  var AChaveNFe, AProtocolo: string);
var
  LResultado: TResultadoOperacao;
  LJson: TJSONObject;
begin
  if not Assigned(FNFCeManager) then
    raise Exception.Create('Modulo NFCe nao inicializado. Verifique o ACBr.');

  LResultado := FNFCeManager.EnviarNFCe(ACupomId);

  if LResultado.Sucesso then
  begin
    // Result.Dados vem como JSON:
    //   {"chaveNFe":"...","protocolo":"..."}      (autorizada)
    //   {"chaveNFe":"...","contingencia":true}    (guardada p/ retransmitir)
    // Antes atribuia-se Mensagem/Dados direto, gravando o texto do toast em
    // cupons.chavenfe e quebrando o upload do XML para a retaguarda.
    AChaveNFe := '';
    AProtocolo := '';

    LJson := TJSONObject.ParseJSONValue(LResultado.Dados) as TJSONObject;
    if Assigned(LJson) then
    try
      AChaveNFe := LJson.GetValue<string>('chaveNFe', '');
      AProtocolo := LJson.GetValue<string>('protocolo', '');
    finally
      LJson.Free;
    end;

    if AChaveNFe = '' then
      SyncLog('NFCe: cupom %d sem chave no retorno (dados=%s)',
        [ACupomId, LResultado.Dados]);

    // Upload do XML ao Oracle pela fila (fora do thread da tela). So faz
    // sentido com protocolo: em contingencia ainda nao existe XML autorizado.
    if AProtocolo <> '' then
      FUploadWorker.EnfileirarDocEletronico(ACupomId);
  end
  else
    raise Exception.Create(LResultado.Mensagem);
end;

procedure TFrmMain.DoRetrySync(Sender: TObject);
begin
  // Nao mexer no SQLite com venda aberta (mesma guarda do sync automatico)
  var LEstado := StrToIntDef(FSQLite.ObterEstado(KEY_ESTADO, '0'), 0);
  if (LEstado = ESTADO_REGISTRANDO) or (LEstado = ESTADO_PAGAMENTO) then Exit;

  // A fila tem conexao Oracle propria e reconecta sozinha - nao depende da
  // conexao da tela estar de pe
  FUploadWorker.EnfileirarPendentes;
end;

{ Sobe a venda para a retaguarda pela fila, sem segurar o fechamento.

  Era feito aqui mesmo, no thread da tela: com o link do Oracle oscilando o
  caixa congelava no fim da venda (44 s e 88 s no log de 22/09 da loja) e o
  Windows oferecia "Fechar o programa". A fila tambem roda UploadCancelamentos
  logo depois, para o cancelamento chegar na hora. }
procedure TFrmMain.DoUploadVenda(ACupomId: Integer);
begin
  FUploadWorker.EnfileirarVenda(ACupomId);
end;

{ Passa para a fila os dados da conexao Oracle configurada no DataModule.
  Chamado no start e depois de reconfigurar a conexao (Ctrl+F12). }
procedure TFrmMain.ConfigurarUploadWorker;
begin
  if not Assigned(FUploadWorker) or not Assigned(DmApoloWeb) then Exit;
  FUploadWorker.ConfigurarOracle(
    DmApoloWeb.UniConnOracle.ConnectString,
    DmApoloWeb.UniConnOracle.SpecificOptions.Text);
end;

procedure TFrmMain.DoCancelarNFCe(ACupomId: Integer; const AJustificativa: string;
  var ASucesso: Boolean; var AMensagem: string);
var
  LResultado: TResultadoOperacao;
begin
  ASucesso := False;
  if not Assigned(FNFCeManager) then
  begin
    AMensagem := 'Modulo NFCe nao inicializado. Verifique o ACBr.';
    Exit;
  end;

  LResultado := FNFCeManager.CancelarNFCe(ACupomId, AJustificativa);
  ASucesso := LResultado.Sucesso;
  AMensagem := LResultado.Mensagem;
end;

procedure TFrmMain.DoReimprimirNFCe(const AChaveNFe: string;
  var ASucesso: Boolean; var AMensagem: string);
begin
  ASucesso := False;
  if not Assigned(FNFCeManager) then
  begin
    AMensagem := 'Modulo NFCe nao inicializado. Verifique o ACBr.';
    Exit;
  end;

  try
    FNFCeManager.ImprimirDANFCe(AChaveNFe);
    ASucesso := True;
  except
    on E: Exception do
      AMensagem := E.Message;
  end;
end;

procedure TFrmMain.DoRetransmitir(var AQtdEnviados, AQtdErros: Integer);
var
  LDocId: Integer;
  LResultado: TResultadoOperacao;
  LCupomId: Variant;
begin
  if not Assigned(FNFCeManager) then
    raise Exception.Create('Modulo NFCe nao inicializado.');

  AQtdEnviados := 0;
  AQtdErros := 0;

  // Pedido explicito do operador: dar nova chance aos que ja estouraram o
  // limite de tentativas automaticas
  FContingencia.ReiniciarTentativas;

  // Processar todos os documentos pendentes
  LDocId := FContingencia.ObterProximoDocParaEnvio;
  while LDocId > 0 do
  begin
    try
      // RetransmitirDoc recebe o id do documento e reenvia o XML original
      // assinado. Antes passava-se LDocId para EnviarNFCe (que espera um
      // cupom_id) e a nota era regerada a partir do cupom errado.
      LResultado := FNFCeManager.RetransmitirDoc(LDocId);
      if LResultado.Sucesso then
      begin
        FContingencia.AtualizarStatusDoc(LDocId, scAutorizado, LResultado.Dados);
        Inc(AQtdEnviados);

        // Subir venda (se ainda nao subiu) e o XML recem-autorizado, pela fila
        LCupomId := FSQLite.ExecutarScalar(
          'SELECT cupom_id FROM nfce_contingencia WHERE id = ' + IntToStr(LDocId));
        if not VarIsNull(LCupomId) then
        begin
          FUploadWorker.EnfileirarVenda(Integer(LCupomId));
          FUploadWorker.EnfileirarDocEletronico(Integer(LCupomId));
        end;
      end
      else if LResultado.Dados = 'REJEITADO' then
      begin
        // SEFAZ negou: sai da fila de retransmissao (reenviar o mesmo XML so
        // repete a rejeicao). Fica visivel na tela como REJEITADO.
        FContingencia.AtualizarStatusDoc(LDocId, scRejeitado, '', LResultado.Mensagem);
        Inc(AQtdErros);
      end
      else
      begin
        FContingencia.IncrementarTentativa(LDocId, LResultado.Mensagem);
        Inc(AQtdErros);
      end;
    except
      on E: Exception do
      begin
        FContingencia.IncrementarTentativa(LDocId, E.Message);
        Inc(AQtdErros);
      end;
    end;

    LDocId := FContingencia.ObterProximoDocParaEnvio;
  end;
end;

{ Regera e transmite os documentos REJEITADOS marcados na tela.

  Nao passa pela fila de retransmissao: aquela reenvia o XML original, e o que
  esta preso aqui e justamente a nota cujo XML o SEFAZ ja negou pelo conteudo.
  Cada id vira uma nota nova (mesmo numero, chave nova) e, autorizada, sobe
  para a retaguarda igual a retransmissao faz. }
procedure TFrmMain.DoRegerarNFCe(const AIds: TArray<Integer>;
  var AQtdOk, AQtdErro: Integer; var AMensagem: string);
var
  I: Integer;
  LResultado: TResultadoOperacao;
  LCupomId: Variant;
  LFalhas: string;
begin
  if not Assigned(FNFCeManager) then
    raise Exception.Create('Modulo NFCe nao inicializado.');

  AQtdOk := 0;
  AQtdErro := 0;
  LFalhas := '';

  for I := 0 to High(AIds) do
  begin
    if AIds[I] <= 0 then
      Continue;

    try
      LResultado := FNFCeManager.RegerarDoc(AIds[I]);
    except
      on E: Exception do
      begin
        LResultado.Sucesso := False;
        LResultado.Mensagem := E.Message;
        LResultado.Dados := '';
      end;
    end;

    if LResultado.Sucesso then
    begin
      FContingencia.AtualizarStatusDoc(AIds[I], scAutorizado, LResultado.Dados);
      Inc(AQtdOk);

      // Mesma subida da retransmissao: venda + XML autorizado, pela fila
      LCupomId := FSQLite.ExecutarScalar(
        'SELECT cupom_id FROM nfce_contingencia WHERE id = ' + IntToStr(AIds[I]));
      if not VarIsNull(LCupomId) then
      begin
        FUploadWorker.EnfileirarVenda(Integer(LCupomId));
        FUploadWorker.EnfileirarDocEletronico(Integer(LCupomId));
      end;
    end
    else
    begin
      Inc(AQtdErro);
      // Rejeicao nova substitui a antiga na tela; erro de comunicacao ou
      // recusa local (duplicidade, ja autorizada) tambem tem que aparecer
      FContingencia.AtualizarStatusDoc(AIds[I], scRejeitado, '',
        LResultado.Mensagem);
      if LFalhas <> '' then
        LFalhas := LFalhas + ' | ';
      LFalhas := LFalhas + 'Doc ' + IntToStr(AIds[I]) + ': ' + LResultado.Mensagem;
    end;
  end;

  AMensagem := LFalhas;

  SyncLog('NFCe: regeracao manual - %d autorizada(s), %d com erro',
    [AQtdOk, AQtdErro]);
end;

procedure TFrmMain.DoFecharApp(Sender: TObject);
begin
  Close;
end;

procedure TFrmMain.OnStatusConexaoChanged(AOnline: Boolean;
  ATipo: TTipoContingencia);
var
  LJson: TJSONObject;
begin
  // Notificar frontend sobre mudanca de status
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('online', TJSONBool.Create(AOnline));
    LJson.AddPair('tipo', ATipo.ToString);
    EnviarParaJS('statusConexao', LJson.ToJSON);
  finally
    LJson.Free;
  end;

  if not AOnline then Exit;

  // Voltou online: primeiro tentar autorizar as NFCe presas em contingencia.
  // Cada uma que for autorizada libera o XML para subir; quando a fila zera,
  // o proprio manager sai da contingencia.
  if FContingencia.EstaEmContingencia and Assigned(FNFCeManager) then
  begin
    var LEnviados := 0;
    var LErros := 0;
    try
      DoRetransmitir(LEnviados, LErros);
      SyncLog('CONTINGENCIA: retransmissao automatica - %d enviado(s), %d erro(s)',
        [LEnviados, LErros]);
    except
      on E: Exception do
        SyncLog('CONTINGENCIA: retransmissao automatica falhou - [%s] %s',
          [E.ClassName, E.Message]);
    end;

    // A saida automatica do manager so' acontece quando uma nota e' AUTORIZADA
    // e zera a fila. Se o que sobrou for tudo REJEITADO, QtdePendentes ja e' 0
    // e ninguem autoriza mais nada: o caixa ficava emitindo offline para
    // sempre por causa de notas que nunca vao ser aceitas.
    if FContingencia.EstaEmContingencia and (FContingencia.QtdePendentes = 0) then
    begin
      FContingencia.SairContingencia;
      SyncLog('CONTINGENCIA: fila vazia e SEFAZ no ar - caixa voltou a emitir online');
    end;
  end;

  // Depois subir vendas / doc eletronico / numerario pendentes (pela fila)
  FUploadWorker.EnfileirarPendentes;
end;

{ Teste de conectividade do monitor.

  A pergunta que importa e' "da' para emitir NFCe agora?", e quem responde isso
  e' o StatusServico do webservice da UF - por isso ele vem primeiro. O Oracle
  entra so' como alternativa, para o monitor nao declarar o caixa offline por
  causa de um NFCeManager que ainda nao subiu. }
function TFrmMain.TestarConexaoServidor: Boolean;
var
  LEstado: Integer;
begin
  // A consulta ao SEFAZ e' sincrona e roda no thread da VCL. Caindo no meio de
  // uma venda, o caixa congela ate o timeout com o cliente na frente - entao
  // fora do estado livre devolve o estado atual, sem contar falha nem volta.
  //
  // Mas o estado pode ficar preso: venda aberta e abandonada deixa ESTADO=2
  // gravado indefinidamente (e' o estado do caixa 33 agora), e ai o caixa
  // nunca mais consultaria a SEFAZ nem sairia da contingencia. Depois de
  // MAX_PROBES_PULADOS ciclos consulta assim mesmo - a essa altura nao ha
  // operador digitando, so' uma venda esquecida na tela.
  LEstado := StrToIntDef(FSQLite.ObterEstado(KEY_ESTADO, '0'), 0);
  if not ((LEstado = ESTADO_FECHADO) or (LEstado = ESTADO_LIVRE)) then
  begin
    Inc(FProbesPulados);
    if FProbesPulados < MAX_PROBES_PULADOS then
      Exit(FMonitorConexao.Online);
  end;
  FProbesPulados := 0;

  if Assigned(FNFCeManager) then
    Exit(FNFCeManager.SefazDisponivel);

  Result := Assigned(DmApoloWeb) and DmApoloWeb.UniConnOracle.Connected;
end;

procedure TFrmMain.OcultarTaskbar;
var
  LTaskbar: HWND;
begin
  LTaskbar := FindWindow('Shell_TrayWnd', nil);
  if LTaskbar <> 0 then
    ShowWindow(LTaskbar, SW_HIDE);
end;

procedure TFrmMain.ExibirTaskbar;
var
  LTaskbar: HWND;
begin
  LTaskbar := FindWindow('Shell_TrayWnd', nil);
  if LTaskbar <> 0 then
    ShowWindow(LTaskbar, SW_SHOW);
end;

procedure TFrmMain.DoSincronizarDados;
begin
  SincronizarDadosInterno(False);
end;

procedure TFrmMain.DoForcarSincronizacao;
begin
  SyncLog('CARGA GERAL solicitada pelo operador (F5)');
  SincronizarDadosInterno(True);
end;

procedure TFrmMain.SincronizarDadosInterno(AForcar: Boolean);
var
  LConnStr: string;
  LSincronizador: TSincronizador;
  LEstado: Integer;
begin
  if FSincronizando then Exit;

  // Nao sincronizar com venda aberta (registrando ou pagamento).
  // Fechado e livre podem sincronizar (login acontece com caixa fechado).
  LEstado := StrToIntDef(FSQLite.ObterEstado(KEY_ESTADO, '0'), 0);
  if (LEstado = ESTADO_REGISTRANDO) or (LEstado = ESTADO_PAGAMENTO) then
  begin
    ExecuteJS('if(window.ApoloApp) ApoloApp.hideSyncOverlay()');
    if AForcar then
    begin
      SyncLog('CARGA GERAL bloqueada: KEY_ESTADO=%d (nao livre)', [LEstado]);
      ExecuteJS('Toast.warning("Carga geral indisponivel com venda em andamento. ' +
        'Use F12 para cancelar/normalizar a venda")');
    end;
    Exit;
  end;

  if not Assigned(DmApoloWeb) then
  begin
    ExecuteJS('if(window.ApoloApp) ApoloApp.hideSyncOverlay()');
    Exit;
  end;

  if not DmApoloWeb.ConectadoOracle then
  begin
    DmApoloWeb.ConectarOracle;
    if not DmApoloWeb.ConectadoOracle then
    begin
      ExecuteJS('if(window.ApoloApp) ApoloApp.hideSyncOverlay()');
      Exit;
    end;
  end;

  FSincronizando := True;
  if AForcar then
    ExecuteJS('if(window.ApoloApp) ApoloApp.showSyncOverlay("Carga geral...", "Baixando todos os dados do servidor")')
  else
    ExecuteJS('if(window.ApoloApp) ApoloApp.showSyncOverlay("Sincronizando dados...", "Atualizando produtos e precos")');

  // Capturar dados na main thread
  LConnStr := DmApoloWeb.UniConnOracle.ConnectString;
  LSincronizador := FSincronizador;

  TThread.CreateAnonymousThread(
    procedure
    var
      LConn: TUniConnection;
    begin
      try
        LConn := TUniConnection.Create(nil);
        try
          LConn.ConnectString := LConnStr;
          LConn.LoginPrompt := False;
          LConn.Connect;
          try
            if AForcar or LSincronizador.PrecisaSincronizar(LConn) then
            begin
              // F5/carga geral = recarga full de produtos; senao incremental
              LSincronizador.DownloadCompleto(LConn, AForcar);
              LSincronizador.AtualizarDataSincCaixa(LConn);
            end;
          finally
            LConn.Disconnect;
          end;
        finally
          LConn.Free;
        end;
      except
        // Falha na sincronizacao nao eh fatal, mas precisa ficar visivel no log
        on E: Exception do
          SyncLog('SYNC thread: ERRO %s - %s', [E.ClassName, E.Message]);
      end;

      TThread.Queue(nil,
        procedure
        begin
          // Certificado rebaixado pela carga: reaplica no ACBr
          if LSincronizador.CertificadoRenovado and Assigned(DmApoloWeb) then
            DmApoloWeb.RecarregarConfiguracaoNFCe;
          FSincronizando := False;
          ExecuteJS('if(window.ApoloApp) ApoloApp.hideSyncOverlay()');
          if AForcar then
            ExecuteJS('Toast.success("Carga geral concluida")');
        end
      );
    end
  ).Start;
end;

procedure TFrmMain.TimerSyncTimer(Sender: TObject);
begin
  // Sincronizacao automatica periodica (sem overlay para nao atrapalhar o operador)
  if FSincronizando then Exit;
  if not Assigned(DmApoloWeb) then Exit;
  if not DmApoloWeb.ConectadoOracle then Exit;

  // Nao sincronizar com venda aberta (registrando ou pagamento)
  var LEstadoAuto := StrToIntDef(FSQLite.ObterEstado(KEY_ESTADO, '0'), 0);
  if (LEstadoAuto = ESTADO_REGISTRANDO) or (LEstadoAuto = ESTADO_PAGAMENTO) then Exit;

  // Executar sync silenciosamente (sem mostrar overlay)
  FSincronizando := True;

  var LConnStr := DmApoloWeb.UniConnOracle.ConnectString;
  var LSincronizador := FSincronizador;

  TThread.CreateAnonymousThread(
    procedure
    var
      LConn: TUniConnection;
    begin
      try
        LConn := TUniConnection.Create(nil);
        try
          LConn.ConnectString := LConnStr;
          LConn.LoginPrompt := False;
          LConn.Connect;
          try
            if LSincronizador.PrecisaSincronizar(LConn) then
            begin
              LSincronizador.DownloadCompleto(LConn);
              LSincronizador.AtualizarDataSincCaixa(LConn);
            end;
          finally
            LConn.Disconnect;
          end;
        finally
          LConn.Free;
        end;
      except
        // Falha na sync automatica nao eh fatal, mas fica no log
        on E: Exception do
          SyncLog('SYNC auto: ERRO %s - %s', [E.ClassName, E.Message]);
      end;

      TThread.Queue(nil,
        procedure
        begin
          // Certificado rebaixado pela carga: reaplica no ACBr
          if LSincronizador.CertificadoRenovado and Assigned(DmApoloWeb) then
            DmApoloWeb.RecarregarConfiguracaoNFCe;
          FSincronizando := False;
        end
      );
    end
  ).Start;
end;

end.
