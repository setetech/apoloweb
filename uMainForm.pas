unit uMainForm;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.Edge, Vcl.ExtCtrls, Winapi.WebView2, ActiveX,
  uBridge, uSQLiteDB, uConstantesWeb, uTypesApoloWeb,
  uContingencia, uNFCeWeb, uMonitorConexao, uSincronizacao;

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
    FSincronizando: Boolean;
    FTimerSync: TTimer;
    procedure InicializarSistema;
    procedure EnviarParaJS(const AAction, AData: string);
    procedure ProcessarMensagemJS(const AJson: string);
    procedure ConfigurarEdgeBrowser;
    // Callbacks para bridge
    procedure DoGerarNFCe(ACupomId: Integer; var AChaveNFe, AProtocolo: string);
    procedure DoRetransmitir(var AQtdEnviados, AQtdErros: Integer);
    procedure DoSincronizarDados;
    procedure OnStatusConexaoChanged(AOnline: Boolean; ATipo: TTipoContingencia);
    procedure TimerSyncTimer(Sender: TObject);
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
  System.JSON, System.IOUtils, Uni, uDmApoloWeb, uFrmConfigConexao;

procedure TFrmMain.FormCreate(Sender: TObject);
begin
  FWebViewReady := False;

  // Configurar form
  Caption := NOME_SISTEMA + ' - Frente de Caixa v' + VERSAO_SISTEMA;
  WindowState := wsMaximized;
  KeyPreview := True;
  Color := clBlack;

  // Configurar EdgeBrowser PRIMEIRO (prioridade - nao depende de nada)
  ConfigurarEdgeBrowser;

  // Inicializar modulos de negocio com protecao
  try
    // Usar SQLite do DataModule (instancia unica)
    FSQLite := DmApoloWeb.SQLiteDB;

    FContingencia := TContingenciaManager.Create(FSQLite);
    FSincronizador := TSincronizador.Create(FSQLite);

    // NFCe Manager (depende do ACBr no DataModule)
    if Assigned(DmApoloWeb) and Assigned(DmApoloWeb.ACBrNFe) then
      FNFCeManager := TNFCeWebManager.Create(FSQLite, DmApoloWeb.ACBrNFe, FContingencia)
    else
      FNFCeManager := nil;

    // Monitor de conexao
    FMonitorConexao := TMonitorConexao.Create(FSQLite, FContingencia);
    FMonitorConexao.OnStatusChanged := OnStatusConexaoChanged;

    // Inicializar Bridge com callbacks
    FBridge := TApoloBridge.Create(Self, FSQLite);
    FBridge.OnGerarNFCe := DoGerarNFCe;
    FBridge.OnRetransmitir := DoRetransmitir;
    FBridge.OnSincronizar := DoSincronizarDados;

    // Timer de sincronizacao automatica
    FTimerSync := TTimer.Create(Self);
    FTimerSync.Interval := INTERVALO_SYNC_AUTO;
    FTimerSync.OnTimer := TimerSyncTimer;
    FTimerSync.Enabled := False; // Ativado apos InicializarSistema
  except
    on E: Exception do
      Caption := 'ApoloWeb - ERRO init: ' + E.Message;
  end;
end;

procedure TFrmMain.FormDestroy(Sender: TObject);
begin
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

procedure TFrmMain.EdgeBrowserCreateWebViewCompleted(
  Sender: TCustomEdgeBrowser; AResult: HRESULT);
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
    end;

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
    Caption := 'ApoloWeb - ERRO na navegacao. Status: ' + IntToStr(WebErrorStatus);
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
begin
  // Enviar informacoes iniciais para o frontend
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('versao', VERSAO_SISTEMA);
    LJson.AddPair('sistema', NOME_SISTEMA);

    LEstado := FSQLite.ObterEstado(KEY_ESTADO, '0');
    LJson.AddPair('estadoCaixa', TJSONNumber.Create(StrToIntDef(LEstado, 0)));
    LJson.AddPair('numCaixa', FSQLite.ObterEstado(KEY_NUMCAIXA, '0'));
    LJson.AddPair('codFilial', FSQLite.ObterEstado(KEY_CODFILIAL, ''));
    LJson.AddPair('hdSerial', FSQLite.ObterEstado(KEY_HD_SERIAL, ''));
    LJson.AddPair('operador', FSQLite.ObterEstado(KEY_OPERADOR, ''));

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
      if DmApoloWeb.ConectadoOracle then
        Caption := NOME_SISTEMA + ' v' + VERSAO_SISTEMA +
          ' | Caixa: ' + IntToStr(DmApoloWeb.NumCaixa) +
          ' | Filial: ' + DmApoloWeb.CodFilial
      else
        Caption := NOME_SISTEMA + ' v' + VERSAO_SISTEMA + ' | OFFLINE';
    end;
    Key := 0;
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
begin
  if not Assigned(FNFCeManager) then
    raise Exception.Create('Modulo NFCe nao inicializado. Verifique o ACBr.');

  LResultado := FNFCeManager.EnviarNFCe(ACupomId);

  if LResultado.Sucesso then
  begin
    // Extrair chave e protocolo do resultado
    AChaveNFe := LResultado.Mensagem;
    AProtocolo := LResultado.Dados;
  end
  else
    raise Exception.Create(LResultado.Mensagem);
end;

procedure TFrmMain.DoRetransmitir(var AQtdEnviados, AQtdErros: Integer);
var
  LDocId: Integer;
  LResultado: TResultadoOperacao;
begin
  if not Assigned(FNFCeManager) then
    raise Exception.Create('Modulo NFCe nao inicializado.');

  AQtdEnviados := 0;
  AQtdErros := 0;

  // Processar todos os documentos pendentes
  LDocId := FContingencia.ObterProximoDocParaEnvio;
  while LDocId > 0 do
  begin
    try
      // Obter cupom_id do documento
      LResultado := FNFCeManager.EnviarNFCe(LDocId);
      if LResultado.Sucesso then
      begin
        FContingencia.AtualizarStatusDoc(LDocId, scAutorizado, LResultado.Dados);
        Inc(AQtdEnviados);
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

  // Se voltou online, iniciar sincronizacao de pendentes
  if AOnline and Assigned(DmApoloWeb) and DmApoloWeb.UniConnOracle.Connected then
  begin
    FSincronizador.ProcessarPendentes(DmApoloWeb.UniConnOracle);
  end;
end;

procedure TFrmMain.DoSincronizarDados;
var
  LConnStr: string;
  LSincronizador: TSincronizador;
  LEstado: Integer;
begin
  if FSincronizando then Exit;

  // Nao sincronizar com venda aberta (registrando ou pagamento)
  LEstado := StrToIntDef(FSQLite.ObterEstado(KEY_ESTADO, '0'), 0);
  if LEstado <> ESTADO_LIVRE then
  begin
    ExecuteJS('if(window.ApoloApp) ApoloApp.hideSyncOverlay()');
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
            // Verificar se precisa sincronizar (comparar datas no Oracle)
            if LSincronizador.PrecisaSincronizar(LConn) then
            begin
              LSincronizador.DownloadCompleto(LConn);
              // Atualizar data_atualizacao_caixa no Oracle
              LSincronizador.AtualizarDataSincCaixa(LConn);
            end;
          finally
            LConn.Disconnect;
          end;
        finally
          LConn.Free;
        end;
      except
        // Falha na sincronizacao nao eh fatal
      end;

      TThread.Queue(nil,
        procedure
        begin
          FSincronizando := False;
          ExecuteJS('if(window.ApoloApp) ApoloApp.hideSyncOverlay()');
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
  if StrToIntDef(FSQLite.ObterEstado(KEY_ESTADO, '0'), 0) <> ESTADO_LIVRE then Exit;

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
        // Falha silenciosa na sync automatica
      end;

      TThread.Queue(nil,
        procedure
        begin
          FSincronizando := False;
        end
      );
    end
  ).Start;
end;

end.
