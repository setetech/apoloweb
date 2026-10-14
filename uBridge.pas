unit uBridge;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Variants, System.DateUtils,
  System.IniFiles,
  System.Math, System.StrUtils, System.IOUtils, System.NetEncoding,
  Winapi.ShellAPI, Winapi.Windows,
  Uni, uSQLiteDB, uConstantesWeb, uTypesApoloWeb, uTEF, Data.DB,WinSpool, Printers,
  uContingencia, uSyncLog, uTEFLog, uPixCD, uTEFCliSiTef;


type
  TOnGerarNFCeEvent = procedure(ACupomId: Integer; var AChaveNFe, AProtocolo: string) of object;
  TOnRetransmitirEvent = procedure(var AQtdEnviados, AQtdErros: Integer) of object;
  // Regeracao dos documentos REJEITADOS escolhidos na tela: monta a NFCe de
  // novo a partir do cupom em vez de reenviar o XML que o SEFAZ ja negou.
  // Mesmo arranjo do TOnRetransmitirEvent - o TNFCeWebManager mora no form.
  TOnRegerarNFCeEvent = procedure(const AIds: TArray<Integer>;
    var AQtdOk, AQtdErro: Integer; var AMensagem: string) of object;
  TOnSincronizarEvent = procedure of object;
  // Disparado ao fechar a venda, para subir o cupom para a retaguarda
  TOnUploadVendaEvent = procedure(ACupomId: Integer) of object;
  // Cancelamento de NFCe (evento 110111). O TNFCeWebManager mora no form, o
  // bridge chega nele por aqui - mesmo arranjo do TOnGerarNFCeEvent.
  TOnCancelarNFCeEvent = procedure(ACupomId: Integer; const AJustificativa: string;
    var ASucesso: Boolean; var AMensagem: string) of object;
  // Reimpressao (2a via) do DANFCe - nao fala com a SEFAZ, so recarrega o XML
  // autorizado do disco e imprime. Mesmo arranjo do cancelamento.
  TOnReimprimirNFCeEvent = procedure(const AChaveNFe: string;
    var ASucesso: Boolean; var AMensagem: string) of object;

  // Dados da embalagem bipada (linha codprod+codbarra do msapolo_produtos,
  // preservada em produto_unidades no SQLite)
  TEmbalagemInfo = record
    Encontrada: Boolean;
    CodBarra: string;   // como esta cadastrado (pode diferir do bipado: "47" x "00047")
    Unidade: string;
    QtUnit: Double;
    Descricao: string;
    PVenda: Double;
    POferta: Double;
    DtFimOferta: string;
  end;

  TApoloBridge = class
  private
    FSQLite: TSQLiteDB;
    FCupomAtualId: Integer;
    FMatriculaLogada: Integer;
    FNomeOperador: string;
    FEstadoCaixa: TEstadoCaixa;
    // Estado unico de contingencia (o mesmo objeto usado por uNFCeWeb).
    // Antes o bridge mantinha uma copia propria que nao enxergava a
    // contingencia automatica disparada por falha de comunicacao.
    FContingenciaMgr: TContingenciaManager;
    FOnGerarNFCe: TOnGerarNFCeEvent;
    FOnCancelarNFCe: TOnCancelarNFCeEvent;
    FOnReimprimirNFCe: TOnReimprimirNFCeEvent;
    FOnRetransmitir: TOnRetransmitirEvent;
    FOnRegerarNFCe: TOnRegerarNFCeEvent;
    FOnUploadVenda: TOnUploadVendaEvent;
    FOnSincronizar: TOnSincronizarEvent;
    FOnForcarSincronizacao: TOnSincronizarEvent;
    FOnFecharApp: TNotifyEvent;
    FOnEnviarParaJS: TProc<string, string>;

    // Cobranca PIX dinamica (criado sob demanda no primeiro uso)
    FPixCDMgr: TPixCDManager;

    // TEF (interface: implementacao http ou arquivo, conforme apoloweb.ini)
    FTEFClient: ITEFClient;
    FTEFHabilitado: Boolean;
    FTEFDescricao: string;
    FTEFConfig: TTEFConfig;
    FTEFNumCaixa: Integer;
    // Venda TEF na thread do TEF (inclusive o desfazimento de uma aprovacao
    // que chegou depois do cancelamento). So a thread principal le e escreve.
    FTEFEmCurso: Boolean;
    function DoObterConfigTEF(const AData: string): string;
    function DoIniciarPagamentoTEF(const AData: string): string;
    function DoCancelarTEF(const AData: string): string;
    function DoConsultarStatusTEF(const AData: string): string;
    function DoObterParametrosTEF(const AData: string): string;
    function DoSalvarParametrosTEF(const AData: string): string;
    function DoTestarTEF(const AData: string): string;
    // modo=clisitef: resposta da tela a um menu/pergunta/coleta da CliSiTef
    function DoResponderTEF(const AData: string): string;
    // modo=clisitef: arquivos do kit (CliSiTef.ini / CONFITLS.INI)
    function DoLerKitCliSiTef(const AData: string): string;
    function DoSalvarKitCliSiTef(const AData: string): string;
    function KitCliSiTefJson(const ADll: string): TJSONObject;

    // TEF administrativo (aba TEF da tela de Documentos Fiscais)
    function DoAdministracaoTEF(const AData: string): string;
    function DoListarTransacoesTEF(const AData: string): string;
    function DoEstornarTEF(const AData: string): string;
    function DoReimprimirComprovanteTEF(const AData: string): string;

    // Cancelamento de NFCe (evento 110111)
    function DoListarNFCeCancelaveis(const AData: string): string;
    function DoCancelarNFCe(const AData: string): string;

    // Reimpressao (2a via) do DANFCe
    function DoReimprimirCupom(const AData: string): string;

    // Impressora do cupom (secao [impressao] do apoloweb.ini)
    function DoObterParametrosImpressora(const AData: string): string;
    function DoSalvarParametrosImpressora(const AData: string): string;
    function DoTestarImpressao(const AData: string): string;
    function ImprimirTexto(const ATexto, AImpressora: string): string;
    function LerConfigTEFDoJson(const AData: string; out AConfig: TTEFConfig;
      out AErro: string): Boolean;
    procedure ImprimirComprovantesTEF(ACupomId: Integer);
    procedure ConfirmarTEFPendentes(ACupomId: Integer);
    procedure DesfazerTEFPendentes(ACupomId: Integer);
    procedure DispararResolucaoTEF(ACupomId, AId: Integer;
      const AControle: string; AConfirmar: Boolean);
    // NCN de uma aprovacao que nao entrou na venda; libera FTEFEmCurso ao fim
    procedure DesfazerTEFNaoRegistrado(ACupomId: Integer; const AControle: string);
    // Estorno (CNC) em thread; o desfecho chega pelo 'tefEstornoResultado'
    procedure EstornarTEFEmSegundoPlano(AId, ACupomId: Integer; AValor: Double;
      const ANSU, AControle: string);
    // Vias devolvidas pelo menu administrativo (reimpressao, relatorios)
    procedure ImprimirViasTEF(const ACliente, ALoja: TArray<string>);

    // Autenticacao
    function DoLogin(const AData: string): string;
    function DoObterPermissoes(const AData: string): string;

    // Produtos
    function ObterEmbalagem(ACodProd: Int64; const ACodBarra: string): TEmbalagemInfo;
    function DoBuscarProduto(const AData: string): string;
    function DoListarProdutos(const AData: string): string;

    // Venda
    function DoIniciarVenda(const AData: string): string;
    function DoAdicionarItem(const AData: string): string;
    function DoRemoverItem(const AData: string): string;
    function DoAplicarDesconto(const AData: string): string;
    function DoAplicarDescontoItem(const AData: string): string;
    function DoCancelarVenda(const AData: string): string;
    function DoObterItensCupom(const AData: string): string;
    function DoObterResumoCupom(const AData: string): string;

    // Pagamento
    function DoRegistrarPagamento(const AData: string): string;
    function DoRemoverPagamento(const AData: string): string;
    function DoFinalizarVenda(const AData: string): string;
    function DoListarMeiosPagamento(const AData: string): string;
    function DoListarMeioPagto(const AData: string): string;
    function DoListarPlanosPagamento(const AData: string): string;
    function DoListarBandeiras(const AData: string): string;
    function DoObterResumoPagamento(const AData: string): string;

    // PIX manual: payload BR Code (EMV) montado com a chave da filial
    // (msfilial.chave_pix, espelhada em empresa.chave_pix no SQLite)
    function GerarPayloadPix(AValor: Double; out APayload, AChave,
      AErro: string): Boolean;
    function DoObterPixQRCode(const AData: string): string;
    function DoImprimirPixQRCode(const AData: string): string;

    // PIX dinamico (API Pix via ACBrPIXCD): cobranca com confirmacao
    // automatica do recebimento. Config na pixcd_config (msapolo_pixcd).
    function ObterPixCDMgr: TPixCDManager;
    function DoIniciarCobrancaPix(const AData: string): string;
    function DoConsultarCobrancaPix(const AData: string): string;
    function DoCancelarCobrancaPix(const AData: string): string;

    // Caixa
    function DoAbrirCaixa(const AData: string): string;
    function DoFecharCaixa(const AData: string): string;
    function DoEfetuarSangria(const AData: string): string;
    function DoEfetuarSuprimento(const AData: string): string;
    function DoObterEstadoCaixa(const AData: string): string;
    procedure ImprimirResumoFechamento;
    function MontarResumoOperador(const ADia: string; AMatricula: Integer): string;
    function DinheiroEmCaixaOperador(const ADia: string; AMatricula: Integer): Double;
    function MontarViasComprovante(const ATitulo, ARotuloValor: string;
      AValor: Double; const AMotivo: string; ACodSupervisor: Integer): TArray<string>;
    function ImprimirTextoCupom(const ATexto: string): string;
    function DoImprimirComprovante(const AData: string): string;

    // NFCe
    function DoGerarNFCe(const AData: string): string;
    function DoListarNFCePendentes(const AData: string): string;
    function DoDescartarNFCePendentes(const AData: string): string;
    function DoRetransmitirContingencia(const AData: string): string;
    function DoRegerarNFCeRejeitadas(const AData: string): string;

    // Logotipo da loja (impresso no DANFCe / PDF)
    function DoObterLogo(const AData: string): string;
    function DoSalvarLogo(const AData: string): string;
    function DoRemoverLogo(const AData: string): string;
    procedure AplicarLogoDANFE;

    // Contingencia
    function DoObterStatusConexao(const AData: string): string;
    function DoEntrarContingencia(const AData: string): string;
    function DoSairContingencia(const AData: string): string;
    function DoListarDocContingencia(const AData: string): string;

    // Clientes
    function DoBuscarCliente(const AData: string): string;
    function DoIdentificarConsumidor(const AData: string): string;
    function DoVincularCliente(const AData: string): string;

    // Vendedor
    function DoBuscarVendedor(const AData: string): string;

    // Pre-Venda
    function DoListarPreVendas(const AData: string): string;
    function DoImportarPreVenda(const AData: string): string;

    // Utilidades internas
    function CriarRespostaSucesso(const AMensagem: string; ADados: TJSONValue = nil): string;
    function CriarRespostaErro(const AMensagem: string): string;
    function ObterProximoNumCupom: Integer;
    procedure AtualizarTotaisCupom(ACupomId: Integer);
    function CalcularTotalCupom(ACupomId: Integer): Double;
    function CalcularTotalPago(ACupomId: Integer): Double;
    function ValidarSenha(AMatricula: Integer; const ASenha: string): Boolean;
    function PossuiAcesso(AMatricula, ACodControle: Integer): Boolean;
    function ValidarAutorizacao(ACodControle: Integer; AJson: TJSONObject;
      out AMatriculaAutorizou: Integer; out AErro: string): Boolean;
    function CriarRespostaSemPermissao(const AMensagem: string): string;
    function ContingenciaAtual: TTipoContingencia;
  public
    constructor Create(AOwner: TComponent; ASQLite: TSQLiteDB;
      AContingencia: TContingenciaManager);
    destructor Destroy; override;

    procedure InicializarTEF(const AConfig: TTEFConfig; ANumCaixa: Integer);
    procedure RawPrintToPrinter(const PrinterName, FileName: string);
    function ProcessarAcao(const AAction, AData: string): string;

    property SQLite: TSQLiteDB read FSQLite;
    property CupomAtualId: Integer read FCupomAtualId;
    property MatriculaLogada: Integer read FMatriculaLogada;
    property NomeOperador: string read FNomeOperador;
    property EstadoCaixa: TEstadoCaixa read FEstadoCaixa;
    property Contingencia: TTipoContingencia read ContingenciaAtual;
    property OnGerarNFCe: TOnGerarNFCeEvent read FOnGerarNFCe write FOnGerarNFCe;
    property OnCancelarNFCe: TOnCancelarNFCeEvent read FOnCancelarNFCe write FOnCancelarNFCe;
    property OnReimprimirNFCe: TOnReimprimirNFCeEvent read FOnReimprimirNFCe write FOnReimprimirNFCe;
    property OnRetransmitir: TOnRetransmitirEvent read FOnRetransmitir write FOnRetransmitir;
    property OnRegerarNFCe: TOnRegerarNFCeEvent read FOnRegerarNFCe write FOnRegerarNFCe;
    property OnUploadVenda: TOnUploadVendaEvent read FOnUploadVenda write FOnUploadVenda;
    property OnSincronizar: TOnSincronizarEvent read FOnSincronizar write FOnSincronizar;
    property OnForcarSincronizacao: TOnSincronizarEvent read FOnForcarSincronizacao write FOnForcarSincronizacao;
    property OnFecharApp: TNotifyEvent read FOnFecharApp write FOnFecharApp;
    property OnEnviarParaJS: TProc<string, string> read FOnEnviarParaJS write FOnEnviarParaJS;
    property TEFHabilitado: Boolean read FTEFHabilitado;
    // [TEF] pix_qr=tela: o PDV exibe o QR devolvido pelo gerenciador em vez
    // de mandar o cliente ler no visor do pinpad
    function TEFPixQrNaTela: Boolean;
  end;

implementation

uses
  System.Generics.Collections,
  uDmApoloWeb;  // logotipo do DANFCe (ACBrNFeDANFCe)

{ TApoloBridge }

const
  // Controles da rotina 8002 (mssubrotina), sincronizados de msacesso para a
  // tabela local "permissoes" (matricula, codcontrole)
  CTRL_DESCONTO_ITEM  = 2;   // Aplicar desconto no item
  CTRL_DESCONTO_VENDA = 3;   // Desconto no total da venda
  CTRL_CANCELAR_ITEM  = 4;   // Cancelar item vendido
  CTRL_CANCELAR_VENDA = 5;   // Cancelamento da venda
  CTRL_FECHAR_CAIXA   = 6;   // Fechamento do caixa
  CTRL_SANGRIA        = 18;  // Sangria

  // Meio centavo. Valor em Double nao fecha exato na casa do centavo, entao
  // comparacao de dinheiro usa esta folga em vez de = ou <.
  TOLERANCIA_CENTAVO = 0.005;

  // Janela em que a SEFAZ homologa cancelamento de NFCe (modelo 65) contada da
  // autorizacao. Passou disso, o evento volta rejeitado - a tela avisa antes.
  PRAZO_CANCEL_NFCE_MIN = 30;

constructor TApoloBridge.Create(AOwner: TComponent; ASQLite: TSQLiteDB;
  AContingencia: TContingenciaManager);
begin
  inherited Create;
  FSQLite := ASQLite;
  FCupomAtualId := 0;
  FMatriculaLogada := 0;
  FEstadoCaixa := ecFechado;
  FContingenciaMgr := AContingencia;
  FTEFHabilitado := False;
  FTEFClient := nil;
  FTEFDescricao := '';

  // Restaurar estado do caixa
  FEstadoCaixa := TEstadoCaixa.FromInteger(
    StrToIntDef(FSQLite.ObterEstado(KEY_ESTADO, '0'), 0)
  );
  FMatriculaLogada := StrToIntDef(FSQLite.ObterEstado(KEY_MATRICULA, '0'), 0);
  FNomeOperador := FSQLite.ObterEstado(KEY_OPERADOR, '');

  // Restaurar venda em andamento (recuperacao apos queda de energia)
  if FEstadoCaixa in [ecRegistrando, ecPagamento] then
  begin
    var LCupomId: Variant;
    LCupomId := FSQLite.ExecutarScalar(
      'SELECT id FROM cupons WHERE dthrfimvenda IS NULL AND codoper <> ''C'' ORDER BY id DESC LIMIT 1'
    );
    if not VarIsNull(LCupomId) and not VarIsEmpty(LCupomId) then
      FCupomAtualId := Integer(LCupomId)
    else
    begin
      // Estado inconsistente - nao ha cupom ativo, resetar para livre
      FEstadoCaixa := ecLivre;
      FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));
    end;
  end;
end;

function TApoloBridge.ContingenciaAtual: TTipoContingencia;
begin
  if Assigned(FContingenciaMgr) then
    Result := FContingenciaMgr.TipoAtual
  else
    Result := tcNenhuma;
end;


procedure TApoloBridge.RawPrintToPrinter(const PrinterName, FileName: string);
var
  hPrinter: THandle;
  DocInfo: TDocInfo1;
  f: File of Byte;
  Buffer: array[0..8191] of Byte;
  BytesRead, BytesWritten: DWORD;
begin
  // Abre a impressora
  if not OpenPrinter(PChar(PrinterName), hPrinter, nil) then
    RaiseLastOSError;

  try
    // Prepara as informa��es do documento
    FillChar(DocInfo, SizeOf(DocInfo), 0);
    DocInfo.pDocName := PChar('Impressao Direta Delphi');
    DocInfo.pDataType := 'RAW'; // Importante: Diz ao Windows que � dado cru
    // Inicia o trabalho de impress�o
    // CORRE��O AQUI: Verificar se o retorno � 0 (zero) em vez de usar 'not'
    if StartDocPrinter(hPrinter, 1, @DocInfo) = 0 then
      RaiseLastOSError;

    try
      // Abre o arquivo texto
      AssignFile(f, FileName);
      FileMode := fmOpenRead or fmShareDenyWrite;
      Reset(f);

      try
        // L� e envia em blocos de 8KB
        BlockRead(f, Buffer, SizeOf(Buffer), BytesRead);
        while BytesRead > 0 do
        begin
          if not WritePrinter(hPrinter, @Buffer, BytesRead, BytesWritten) then
            RaiseLastOSError;
          BlockRead(f, Buffer, SizeOf(Buffer), BytesRead);
        end;
      finally
        CloseFile(f);
      end;
    finally
      // Finaliza o documento
      EndDocPrinter(hPrinter);
    end;
  finally
    ClosePrinter(hPrinter);
  end;
end;

// Cria o cliente TEF conforme o modo configurado ([TEF] modo=http|arquivo).
// No modo http exige a url; no modo arquivo, as pastas de intercambio.
procedure TApoloBridge.InicializarTEF(const AConfig: TTEFConfig; ANumCaixa: Integer);
var
  LConfig: TTEFConfig;
begin
  FTEFClient := nil;
  FTEFDescricao := '';

  // Guarda a config mesmo desligada: a tela de parametros edita esses valores
  LConfig := AConfig;
  LConfig.Identificacao := ANumCaixa;
  FTEFConfig := LConfig;
  FTEFNumCaixa := ANumCaixa;

  FTEFHabilitado := AConfig.Habilitado;
  if not FTEFHabilitado then
    Exit;

  if (LConfig.Modo = tmHTTP) and (Trim(LConfig.Url) = '') then
  begin
    TEFLog('TEF habilitado em modo http sem url configurada - TEF desligado');
    FTEFHabilitado := False;
    Exit;
  end;

  if (LConfig.Modo = tmArquivo) and
     ((Trim(LConfig.PastaReq) = '') or (Trim(LConfig.PastaResp) = '')) then
  begin
    TEFLog('TEF habilitado em modo arquivo sem pasta_req/pasta_resp - TEF desligado');
    FTEFHabilitado := False;
    Exit;
  end;

  if (LConfig.Modo = tmCliSiTef) and
     ((Trim(LConfig.SitefDll) = '') or (Trim(LConfig.SitefIP) = '') or
      (Trim(LConfig.SitefLoja) = '') or (Trim(LConfig.SitefTerminal) = '')) then
  begin
    TEFLog('TEF habilitado em modo clisitef sem sitef_dll/sitef_ip/sitef_loja/' +
      'sitef_terminal - TEF desligado');
    FTEFHabilitado := False;
    Exit;
  end;

  FTEFClient := CriarTEFClient(LConfig);
  FTEFDescricao := FTEFClient.Descricao;

  // pix_qr=tela: o gerenciador devolve o BR Code no meio da transacao e o PDV
  // pinta o QR na hora. Dispara na thread do TEF - por isso o TThread.Queue.
  FTEFClient.SetOnQrCode(
    procedure(const APayload: string)
    var
      LPayload: string;
    begin
      LPayload := APayload;
      TThread.Queue(nil,
        procedure
        var
          LJson: TJSONObject;
        begin
          if not Assigned(FOnEnviarParaJS) then Exit;
          LJson := TJSONObject.Create;
          try
            LJson.AddPair('payload', LPayload);
            FOnEnviarParaJS('tefPixQrCode', LJson.ToJSON);
          finally
            LJson.Free;
          end;
        end
      );
    end
  );

  // modo=clisitef: os menus, perguntas e coletas da CliSiTef sao desenhados
  // pela tela do PDV (web/js/tefinterativo.js). Dispara na thread da DLL.
  FTEFClient.SetOnInteracao(
    procedure(const AJson: string)
    var
      LJsonTxt: string;
    begin
      LJsonTxt := AJson;
      TThread.Queue(nil,
        procedure
        begin
          if Assigned(FOnEnviarParaJS) then
            FOnEnviarParaJS('tefInteracao', LJsonTxt);
        end
      );
    end
  );

  TEFLog('TEF inicializado: caixa=%d modo=%s', [ANumCaixa, FTEFDescricao]);
end;

function TApoloBridge.TEFPixQrNaTela: Boolean;
begin
  Result := FTEFConfig.PixQr = pqTela;
end;

destructor TApoloBridge.Destroy;
begin
  FTEFClient := nil;  // interface: liberada por contagem de referencia
  FreeAndNil(FPixCDMgr);
  inherited;
end;

function TApoloBridge.ProcessarAcao(const AAction, AData: string): string;
begin
  try
    // Autenticacao
    if AAction = 'login' then Result := DoLogin(AData)
    else if AAction = 'obterPermissoes' then Result := DoObterPermissoes(AData)
    // Produtos
    else if AAction = 'buscarProduto' then Result := DoBuscarProduto(AData)
    else if AAction = 'listarProdutos' then Result := DoListarProdutos(AData)
    // Venda
    else if AAction = 'iniciarVenda' then Result := DoIniciarVenda(AData)
    else if AAction = 'adicionarItem' then Result := DoAdicionarItem(AData)
    else if AAction = 'removerItem' then Result := DoRemoverItem(AData)
    else if AAction = 'aplicarDesconto' then Result := DoAplicarDesconto(AData)
    else if AAction = 'aplicarDescontoItem' then Result := DoAplicarDescontoItem(AData)
    else if AAction = 'cancelarVenda' then Result := DoCancelarVenda(AData)
    else if AAction = 'obterItensCupom' then Result := DoObterItensCupom(AData)
    else if AAction = 'obterResumoCupom' then Result := DoObterResumoCupom(AData)
    // Pagamento
    else if AAction = 'registrarPagamento' then Result := DoRegistrarPagamento(AData)
    else if AAction = 'removerPagamento' then Result := DoRemoverPagamento(AData)
    else if AAction = 'finalizarVenda' then Result := DoFinalizarVenda(AData)
    else if AAction = 'listarMeiosPagamento' then Result := DoListarMeiosPagamento(AData)
    else if AAction = 'listarMeioPagto' then Result := DoListarMeioPagto(AData)
    else if AAction = 'listarPlanosPagamento' then Result := DoListarPlanosPagamento(AData)
    else if AAction = 'listarBandeiras' then Result := DoListarBandeiras(AData)
    else if AAction = 'obterResumoPagamento' then Result := DoObterResumoPagamento(AData)
    else if AAction = 'obterPixQRCode' then Result := DoObterPixQRCode(AData)
    else if AAction = 'imprimirPixQRCode' then Result := DoImprimirPixQRCode(AData)
    else if AAction = 'iniciarCobrancaPix' then Result := DoIniciarCobrancaPix(AData)
    else if AAction = 'consultarCobrancaPix' then Result := DoConsultarCobrancaPix(AData)
    else if AAction = 'cancelarCobrancaPix' then Result := DoCancelarCobrancaPix(AData)
    // Caixa
    else if AAction = 'abrirCaixa' then Result := DoAbrirCaixa(AData)
    else if AAction = 'fecharCaixa' then Result := DoFecharCaixa(AData)
    else if AAction = 'efetuarSangria' then Result := DoEfetuarSangria(AData)
    else if AAction = 'efetuarSuprimento' then Result := DoEfetuarSuprimento(AData)
    else if AAction = 'imprimirComprovante' then Result := DoImprimirComprovante(AData)
    else if AAction = 'obterEstadoCaixa' then Result := DoObterEstadoCaixa(AData)
    // NFCe
    else if AAction = 'gerarNFCe' then Result := DoGerarNFCe(AData)
    else if AAction = 'listarNFCePendentes' then Result := DoListarNFCePendentes(AData)
    else if AAction = 'descartarNFCePendentes' then Result := DoDescartarNFCePendentes(AData)
    else if AAction = 'retransmitirContingencia' then Result := DoRetransmitirContingencia(AData)
    else if AAction = 'regerarNFCeRejeitadas' then Result := DoRegerarNFCeRejeitadas(AData)
    else if AAction = 'listarNFCeCancelaveis' then Result := DoListarNFCeCancelaveis(AData)
    else if AAction = 'cancelarNFCe' then Result := DoCancelarNFCe(AData)
    else if AAction = 'reimprimirCupom' then Result := DoReimprimirCupom(AData)
    // Logotipo da loja (DANFCe / PDF)
    else if AAction = 'obterLogo' then Result := DoObterLogo(AData)
    else if AAction = 'salvarLogo' then Result := DoSalvarLogo(AData)
    else if AAction = 'removerLogo' then Result := DoRemoverLogo(AData)
    // Contingencia
    else if AAction = 'obterStatusConexao' then Result := DoObterStatusConexao(AData)
    else if AAction = 'entrarContingencia' then Result := DoEntrarContingencia(AData)
    else if AAction = 'sairContingencia' then Result := DoSairContingencia(AData)
    else if AAction = 'listarDocContingencia' then Result := DoListarDocContingencia(AData)
    // Clientes
    else if AAction = 'buscarCliente' then Result := DoBuscarCliente(AData)
    else if AAction = 'identificarConsumidor' then Result := DoIdentificarConsumidor(AData)
    else if AAction = 'vincularCliente' then Result := DoVincularCliente(AData)
    // Vendedor
    else if AAction = 'buscarVendedor' then Result := DoBuscarVendedor(AData)
    // Pre-venda
    else if AAction = 'listarPreVendas' then Result := DoListarPreVendas(AData)
    else if AAction = 'importarPreVenda' then Result := DoImportarPreVenda(AData)
    // TEF
    else if AAction = 'obterConfigTEF' then Result := DoObterConfigTEF(AData)
    else if AAction = 'iniciarPagamentoTEF' then Result := DoIniciarPagamentoTEF(AData)
    else if AAction = 'cancelarTEF' then Result := DoCancelarTEF(AData)
    else if AAction = 'consultarStatusTEF' then Result := DoConsultarStatusTEF(AData)
    else if AAction = 'obterParametrosTEF' then Result := DoObterParametrosTEF(AData)
    else if AAction = 'salvarParametrosTEF' then Result := DoSalvarParametrosTEF(AData)
    else if AAction = 'testarTEF' then Result := DoTestarTEF(AData)
    else if AAction = 'responderTEF' then Result := DoResponderTEF(AData)
    else if AAction = 'lerKitCliSiTef' then Result := DoLerKitCliSiTef(AData)
    else if AAction = 'salvarKitCliSiTef' then Result := DoSalvarKitCliSiTef(AData)
    else if AAction = 'administracaoTEF' then Result := DoAdministracaoTEF(AData)
    else if AAction = 'listarTransacoesTEF' then Result := DoListarTransacoesTEF(AData)
    else if AAction = 'estornarTEF' then Result := DoEstornarTEF(AData)
    else if AAction = 'reimprimirComprovanteTEF' then Result := DoReimprimirComprovanteTEF(AData)
    // Impressora
    else if AAction = 'obterParametrosImpressora' then Result := DoObterParametrosImpressora(AData)
    else if AAction = 'salvarParametrosImpressora' then Result := DoSalvarParametrosImpressora(AData)
    else if AAction = 'testarImpressao' then Result := DoTestarImpressao(AData)
    // Sistema
    else if AAction = 'forcarSincronizacao' then
    begin
      if Assigned(FOnForcarSincronizacao) then
      begin
        FOnForcarSincronizacao;
        Result := CriarRespostaSucesso('Carga geral iniciada');
      end
      else
        Result := CriarRespostaErro('Sincronizacao nao disponivel');
    end
    else if AAction = 'fecharApp' then
    begin
      Result := CriarRespostaSucesso('Encerrando...');
      if Assigned(FOnFecharApp) then
        FOnFecharApp(Self);
    end
    else
      Result := CriarRespostaErro('Acao desconhecida: ' + AAction);
  except
    on E: Exception do
      Result := CriarRespostaErro('Erro: ' + E.Message);
  end;
end;

// =========================================================================
// RESPOSTAS
// =========================================================================

function TApoloBridge.CriarRespostaSucesso(const AMensagem: string;
  ADados: TJSONValue): string;
var
  LJson: TJSONObject;
begin
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('sucesso', TJSONBool.Create(True));
    LJson.AddPair('mensagem', AMensagem);
    if ADados <> nil then
      LJson.AddPair('dados', ADados)
    else
      LJson.AddPair('dados', TJSONObject.Create);
    Result := LJson.ToJSON;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.CriarRespostaErro(const AMensagem: string): string;
var
  LJson: TJSONObject;
begin
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('sucesso', TJSONBool.Create(False));
    LJson.AddPair('mensagem', AMensagem);
    LJson.AddPair('dados', TJSONObject.Create);
    Result := LJson.ToJSON;
  finally
    LJson.Free;
  end;
end;

// =========================================================================
// AUTENTICACAO
// =========================================================================

function TApoloBridge.DoLogin(const AData: string): string;
var
  LJson: TJSONObject;
  LMatricula: Integer;
  LSenha: string;
  LQuery: TUniQuery;
  LDados: TJSONObject;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LMatricula := LJson.GetValue<Integer>('matricula', 0);
    LSenha := LJson.GetValue<string>('senha', '');

    if LMatricula = 0 then
      Exit(CriarRespostaErro('Informe a matricula'));

    if not ValidarSenha(LMatricula, LSenha) then
      Exit(CriarRespostaErro('Matricula ou senha invalida'));

    // Obter dados do funcionario
    LQuery := FSQLite.ExecutarSelect(
      'SELECT matricula, nome, cargo FROM funcionarios WHERE matricula = ' +
      IntToStr(LMatricula)
    );
    try
      if LQuery.IsEmpty then
        Exit(CriarRespostaErro('Funcionario nao encontrado'));

      FMatriculaLogada := LMatricula;
      FNomeOperador := LQuery.FieldByName('nome').AsString;

      FSQLite.SalvarEstado(KEY_MATRICULA, IntToStr(LMatricula));
      FSQLite.SalvarEstado(KEY_OPERADOR, FNomeOperador);

      // Sincronizar dados (produtos, funcionarios, etc.) do Oracle
      if Assigned(FOnSincronizar) then
      begin
        try
          FOnSincronizar;
        except
          // Falha na sync nao impede o login (pode estar offline)
        end;
      end;

      LDados := TJSONObject.Create;
      LDados.AddPair('matricula', TJSONNumber.Create(LMatricula));
      LDados.AddPair('nome', LQuery.FieldByName('nome').AsString);
      LDados.AddPair('cargo', LQuery.FieldByName('cargo').AsString);
      LDados.AddPair('estadoCaixa', TJSONNumber.Create(Ord(FEstadoCaixa)));
      LDados.AddPair('cupomAtualId', TJSONNumber.Create(FCupomAtualId));

      Result := CriarRespostaSucesso('Login realizado com sucesso', LDados);
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.ValidarSenha(AMatricula: Integer;
  const ASenha: string): Boolean;
var
  LQuery: TUniQuery;
  LSenhaDB, LUsuario: string;
begin
  Result := False;

  LQuery := FSQLite.ExecutarSelect(
    'SELECT senhadb, usuario FROM funcionarios WHERE matricula = ' +
    IntToStr(AMatricula)
  );
  try
    if LQuery.IsEmpty then Exit;

    LSenhaDB := LQuery.FieldByName('senhadb').AsString;
    LUsuario := LQuery.FieldByName('usuario').AsString;
    Result := (UpperCase(ASenha) = UpperCase(LSenhaDB));

    // Ofuscar a senha informada com a mesma logica do sistema original
    //LSenhaOfuscada := Ofuscar(ASenha, LUsuario);
    //Result := (LSenhaOfuscada = LSenhaDB);
  finally
    LQuery.Free;
  end;
end;


function TApoloBridge.PossuiAcesso(AMatricula, ACodControle: Integer): Boolean;
var
  LVal: Variant;
begin
  LVal := FSQLite.ExecutarScalar(
    'SELECT COUNT(*) FROM permissoes WHERE matricula = ' +
    IntToStr(AMatricula) + ' AND codcontrole = ' + IntToStr(ACodControle)
  );
  Result := (not VarIsNull(LVal)) and (LVal > 0);
end;

// Verifica se o operador logado possui o controle (rotina 8002). Se nao
// possuir, aceita autorizacao de um supervisor enviada no proprio JSON da
// action (supMatricula/supSenha), desde que o autorizador tenha o controle.
// AErro vazio + Result=False significa "pedir autorizacao ao frontend".
function TApoloBridge.ValidarAutorizacao(ACodControle: Integer;
  AJson: TJSONObject; out AMatriculaAutorizou: Integer;
  out AErro: string): Boolean;
var
  LSupMatricula: Integer;
  LSupSenha: string;
begin
  Result := False;
  AErro := '';
  AMatriculaAutorizou := FMatriculaLogada;

  if PossuiAcesso(FMatriculaLogada, ACodControle) then
    Exit(True);

  LSupMatricula := AJson.GetValue<Integer>('supMatricula', 0);
  LSupSenha := AJson.GetValue<string>('supSenha', '');

  if LSupMatricula = 0 then
    Exit; // sem credenciais de autorizador: frontend deve solicitar

  if not ValidarSenha(LSupMatricula, LSupSenha) then
  begin
    AErro := 'Matricula ou senha do autorizador invalida';
    Exit;
  end;

  if not PossuiAcesso(LSupMatricula, ACodControle) then
  begin
    AErro := 'Autorizador nao possui permissao para esta operacao';
    Exit;
  end;

  AMatriculaAutorizou := LSupMatricula;
  Result := True;
end;

// Resposta de erro com dados.requerAutorizacao=true: o frontend abre o
// dialogo de matricula/senha do autorizador e reenvia a action.
function TApoloBridge.CriarRespostaSemPermissao(const AMensagem: string): string;
var
  LJson, LDados: TJSONObject;
begin
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('sucesso', TJSONBool.Create(False));
    LJson.AddPair('mensagem', AMensagem);
    LDados := TJSONObject.Create;
    LDados.AddPair('requerAutorizacao', TJSONBool.Create(True));
    LJson.AddPair('dados', LDados);
    Result := LJson.ToJSON;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoObterPermissoes(const AData: string): string;
var
  LJson: TJSONObject;
  LMatricula: Integer;
  LQuery: TUniQuery;
  LArr: TJSONArray;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LMatricula := LJson.GetValue<Integer>('matricula', FMatriculaLogada);

    LQuery := FSQLite.ExecutarSelect(
      'SELECT codcontrole FROM permissoes WHERE matricula = ' +
      IntToStr(LMatricula)
    );
    try
      LArr := TJSONArray.Create;
      while not LQuery.Eof do
      begin
        LArr.Add(LQuery.FieldByName('codcontrole').AsInteger);
        LQuery.Next;
      end;

      Result := CriarRespostaSucesso('OK', LArr);
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

// =========================================================================
// PRODUTOS
// =========================================================================

// Dados da embalagem correspondente ao codigo de barras bipado.
// msapolo_produtos tem 1 linha por (codprod, codbarra), cada uma com
// unidade, qtunit, descricao e preco proprios; a tabela produtos guarda so
// a linha principal, entao os dados de cada EAN vem de produto_unidades.
// Encontrada=False quando o codigo nao esta la (usar dados da principal).
function TApoloBridge.ObterEmbalagem(ACodProd: Int64; const ACodBarra: string): TEmbalagemInfo;
var
  LQuery: TUniQuery;
  LCod, LCodNum: string;
begin
  Result := Default(TEmbalagemInfo);
  LCod := Trim(ACodBarra);
  if LCod = '' then Exit;

  // Zeros a esquerda sao ignorados, como no DoBuscarProduto: a etiqueta de
  // balanca traz o codigo com 5 digitos ("00047") e o cadastro da embalagem
  // KG tem o barcode curto "47". Sem isso a embalagem KG nao era achada, o
  // produto voltava como UN/pesovariavel=N e a etiqueta era rejeitada.
  LCodNum := LCod;
  if StrToInt64Def(LCod, -1) >= 0 then
    LCodNum := IntToStr(StrToInt64Def(LCod, -1));
  LCod := StringReplace(LCod, '''', '''''', [rfReplaceAll]);

  LQuery := FSQLite.ExecutarSelect(
    'SELECT codbarra, unidade, qtunit, descricao, pvenda, poferta, dtfimoferta ' +
    'FROM produto_unidades WHERE codbarra IN (''' + LCod + ''',''' + LCodNum +
    ''') AND codprod = ' + IntToStr(ACodProd) +
    ' ORDER BY CASE WHEN codbarra = ''' + LCod + ''' THEN 0 ELSE 1 END'
  );
  try
    if not LQuery.IsEmpty then
    begin
      Result.Encontrada := True;
      Result.CodBarra := Trim(LQuery.FieldByName('codbarra').AsString);
      Result.Unidade := Trim(LQuery.FieldByName('unidade').AsString);
      Result.QtUnit := LQuery.FieldByName('qtunit').AsFloat;
      Result.Descricao := Trim(LQuery.FieldByName('descricao').AsString);
      Result.PVenda := LQuery.FieldByName('pvenda').AsFloat;
      Result.POferta := LQuery.FieldByName('poferta').AsFloat;
      Result.DtFimOferta := LQuery.FieldByName('dtfimoferta').AsString;
    end;
  finally
    LQuery.Free;
  end;
end;

function TApoloBridge.DoBuscarProduto(const AData: string): string;
var
  LJson: TJSONObject;
  LCodigo, LCodNum, LUnidade, LDescricao, LDtFimOferta: string;
  LQtUnit, LPVenda, LPOferta: Double;
  LEmb: TEmbalagemInfo;
  LQuery: TUniQuery;
  LProd, LItem: TJSONObject;
  LArray: TJSONArray;
  LSQL: string;
  LEhNumerico, LExato: Boolean;
  I: Integer;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LCodigo := Trim(LJson.GetValue<string>('codigo', ''));
    if LCodigo = '' then
      Exit(CriarRespostaErro('Informe o codigo ou codigo de barras'));

    // Verificar se o texto eh numerico (codigo/barras) ou descricao
    LEhNumerico := True;
    for I := 1 to Length(LCodigo) do
      if not CharInSet(LCodigo[I], ['0'..'9']) then
      begin
        LEhNumerico := False;
        Break;
      end;

    // exato=true: so' o codigo inteiro, sem cair no formato de etiqueta de
    // balanca (o pos.js pergunta isso antes de decompor um "2..." de 13 digitos)
    LExato := LJson.GetValue<Boolean>('exato', False);

    if LEhNumerico then
    begin
      // Busca exata por codigo de barras (principal ou adicional) ou codprod.
      // produto_unidades tem uma linha por EAN do produto - a tabela produtos
      // colapsa para uma so, entao o EAN da outra embalagem so existe la
      // (e nem sempre esta na mscodbarra, que alimenta codbarras)
      // Zeros a esquerda sao ignorados tanto no codprod quanto no codbarra:
      // a etiqueta de balanca traz o codigo com 5 digitos ("00002"), e o
      // cadastro pode ter o barcode curto "2"
      LCodNum := IntToStr(StrToInt64Def(LCodigo, -1));
      LSQL := 'SELECT * FROM produtos WHERE codbarra IN (''' +
        LCodigo + ''',''' + LCodNum + ''') OR codprod = ' + LCodNum + ' ' +
        'OR codprod IN (SELECT codprod FROM codbarras WHERE codbarra IN (''' +
        LCodigo + ''',''' + LCodNum + ''')) ' +
        'OR codprod IN (SELECT codprod FROM produto_unidades WHERE codbarra IN (''' +
        LCodigo + ''',''' + LCodNum + ''')) LIMIT 20';
    end
    else
    begin
      // Busca parcial por descricao (case-insensitive)
      LSQL := 'SELECT * FROM produtos WHERE UPPER(descricao) LIKE ''%' +
        AnsiUpperCase(StringReplace(LCodigo, '''', '''''', [rfReplaceAll])) +
        '%'' LIMIT 20';
    end;

    LQuery := FSQLite.ExecutarSelect(LSQL);

    // Peso variavel: 13 digitos comecando com 2, e SO' se o codigo inteiro nao
    // for de nenhum produto. O ERP gera EAN interno "2000000" + codprod para
    // produto sem EAN, e antes o LIKE '2000000%' vinha primeiro: casava com
    // todos esses produtos e devolvia o primeiro da tabela. Buscando "VASO H88"
    // (2000000169323) o caixa registrava o MILHO 16079 (2000000160795).
    if LQuery.IsEmpty and (not LExato) and LEhNumerico and
       (Length(LCodigo) = 13) and (LCodigo[1] = '2') then
    begin
      LQuery.Free;
      LQuery := FSQLite.ExecutarSelect(
        'SELECT * FROM produtos WHERE codbarra LIKE ''' +
        Copy(LCodigo, 1, 7) + '%'' ' +
        'OR codprod IN (SELECT codprod FROM produto_unidades WHERE codbarra LIKE ''' +
        Copy(LCodigo, 1, 7) + '%'') LIMIT 20');
    end;

    try
      if LQuery.IsEmpty then
        Exit(CriarRespostaErro('Produto nao encontrado'));

      // Se retornou exatamente 1 registro, devolver como produto unico
      // Se retornou varios, devolver como lista para o frontend escolher
      if (LQuery.RecordCount = 1) or LEhNumerico then
      begin
        // Resultado unico (compativel com fluxo existente)
        // Dados da embalagem bipada (unidade, qtunit, descricao e preco
        // podem diferir da linha principal colapsada em produtos)
        LEmb := ObterEmbalagem(LQuery.FieldByName('codprod').AsLargeInt, LCodigo);

        LUnidade := LEmb.Unidade;
        if LUnidade = '' then
          LUnidade := LQuery.FieldByName('unidade').AsString;

        LQtUnit := LEmb.QtUnit;
        if LQtUnit <= 0 then
          LQtUnit := LQuery.FieldByName('qtunit').AsFloat;
        if LQtUnit <= 0 then
          LQtUnit := 1;

        LDescricao := LEmb.Descricao;
        if LDescricao = '' then
          LDescricao := LQuery.FieldByName('descricao').AsString;

        if LEmb.Encontrada and (LEmb.PVenda > 0) then
        begin
          LPVenda := LEmb.PVenda;
          LPOferta := LEmb.POferta;
          LDtFimOferta := LEmb.DtFimOferta;
        end
        else
        begin
          LPVenda := LQuery.FieldByName('pvenda').AsFloat;
          LPOferta := LQuery.FieldByName('poferta').AsFloat;
          LDtFimOferta := LQuery.FieldByName('dtfimoferta').AsString;
        end;

        LProd := TJSONObject.Create;
        LProd.AddPair('codprod', TJSONNumber.Create(LQuery.FieldByName('codprod').AsLargeInt));
        LProd.AddPair('codbarra', IfThen(LEmb.Encontrada, LEmb.CodBarra,
          LQuery.FieldByName('codbarra').AsString));
        LProd.AddPair('descricao', LDescricao);
        LProd.AddPair('unidade', LUnidade);
        LProd.AddPair('qtunit', TJSONNumber.Create(LQtUnit));
        LProd.AddPair('embalagem', LQuery.FieldByName('embalagem').AsString);
        LProd.AddPair('pvenda', TJSONNumber.Create(LPVenda));
        LProd.AddPair('pvendaatac', TJSONNumber.Create(LQuery.FieldByName('pvendaatac').AsFloat));
        LProd.AddPair('poferta', TJSONNumber.Create(LPOferta));
        LProd.AddPair('dtfimoferta', LDtFimOferta);
        LProd.AddPair('qtminiatac', TJSONNumber.Create(LQuery.FieldByName('qtminiatac').AsInteger));
        LProd.AddPair('pesovariavel', LQuery.FieldByName('pesovariavel').AsString);
        LProd.AddPair('permite_dig_preco', LQuery.FieldByName('permite_dig_preco').AsString);
        LProd.AddPair('permite_dig_desc', LQuery.FieldByName('permite_dig_desc').AsString);
        LProd.AddPair('permite_dig_qtde', LQuery.FieldByName('permite_dig_qtde').AsString);
        LProd.AddPair('maxperdesc', TJSONNumber.Create(LQuery.FieldByName('maxperdesc').AsFloat));
        LProd.AddPair('ncm', LQuery.FieldByName('ncm').AsString);
        LProd.AddPair('cfop', TJSONNumber.Create(LQuery.FieldByName('cfop').AsFloat));
        LProd.AddPair('cest', LQuery.FieldByName('cest').AsString);
        LProd.AddPair('icms_cst', LQuery.FieldByName('icms_cst').AsString);
        LProd.AddPair('csosn', LQuery.FieldByName('csosn').AsString);
        LProd.AddPair('aliqicms', TJSONNumber.Create(LQuery.FieldByName('aliqicms').AsFloat));
        LProd.AddPair('pis_cst', LQuery.FieldByName('pis_cst').AsString);
        LProd.AddPair('cofins_cst', LQuery.FieldByName('cofins_cst').AsString);
        LProd.AddPair('pis_ppis', TJSONNumber.Create(LQuery.FieldByName('pis_ppis').AsFloat));
        LProd.AddPair('cofins_pcofins', TJSONNumber.Create(LQuery.FieldByName('cofins_pcofins').AsFloat));
        LProd.AddPair('impleitransparencia', TJSONNumber.Create(LQuery.FieldByName('impleitransparencia').AsFloat));

        if (LPOferta > 0) and
           (LDtFimOferta >= FormatDateTime('yyyy-mm-dd', Now)) then
          LProd.AddPair('emOferta', TJSONBool.Create(True))
        else
          LProd.AddPair('emOferta', TJSONBool.Create(False));

        Result := CriarRespostaSucesso('Produto encontrado', LProd);
      end
      else
      begin
        // Multiplos resultados - devolver lista para o frontend exibir
        LProd := TJSONObject.Create;
        LArray := TJSONArray.Create;
        while not LQuery.Eof do
        begin
          LItem := TJSONObject.Create;
          LItem.AddPair('codprod', TJSONNumber.Create(LQuery.FieldByName('codprod').AsLargeInt));
          LItem.AddPair('codbarra', LQuery.FieldByName('codbarra').AsString);
          LItem.AddPair('descricao', LQuery.FieldByName('descricao').AsString);
          LItem.AddPair('unidade', LQuery.FieldByName('unidade').AsString);
          LItem.AddPair('pvenda', TJSONNumber.Create(LQuery.FieldByName('pvenda').AsFloat));
          LArray.AddElement(LItem);
          LQuery.Next;
        end;
        LProd.AddPair('produtos', LArray);
        LProd.AddPair('total', TJSONNumber.Create(LArray.Count));
        Result := CriarRespostaSucesso('lista', LProd);
      end;
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoListarProdutos(const AData: string): string;
var
  LJson: TJSONObject;
  LFiltro: string;
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LProd: TJSONObject;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LFiltro := LJson.GetValue<string>('filtro', '');

    if LFiltro = '' then
      Exit(CriarRespostaErro('Informe um filtro de busca'));

    LFiltro := StringReplace(LFiltro, '''', '''''', [rfReplaceAll]);

    // 1 linha por embalagem (produto_unidades espelha as linhas de
    // msapolo_produtos); produto sem embalagem cadastrada cai na linha
    // principal de produtos. Cada linha traz codbarra, descricao, unidade,
    // qtunit e preco proprios da embalagem.
    LQuery := FSQLite.ExecutarSelect(
      'SELECT p.codprod, ' +
      'COALESCE(u.codbarra, p.codbarra) as codbarra, ' +
      'COALESCE(NULLIF(TRIM(u.descricao), ''''), p.descricao) as descricao, ' +
      'COALESCE(NULLIF(TRIM(u.unidade), ''''), p.unidade) as unidade, ' +
      'CASE WHEN COALESCE(u.qtunit, 0) > 0 THEN u.qtunit ' +
      '     WHEN COALESCE(p.qtunit, 0) > 0 THEN p.qtunit ELSE 1 END as qtunit, ' +
      'p.embalagem, ' +
      'CASE WHEN COALESCE(u.pvenda, 0) > 0 THEN u.pvenda ELSE p.pvenda END as pvenda, ' +
      'p.pvendaatac, ' +
      'CASE WHEN COALESCE(u.pvenda, 0) > 0 THEN COALESCE(u.poferta, 0) ELSE p.poferta END as poferta, ' +
      'CASE WHEN COALESCE(u.pvenda, 0) > 0 THEN u.dtfimoferta ELSE p.dtfimoferta END as dtfimoferta, ' +
      'p.qtminiatac, p.qtdisponivel ' +
      'FROM produtos p ' +
      'LEFT JOIN produto_unidades u ON u.codprod = p.codprod ' +
      'WHERE ' +
      'COALESCE(NULLIF(TRIM(u.descricao), ''''), p.descricao) LIKE ''%' + LFiltro + '%'' OR ' +
      'CAST(p.codprod AS TEXT) = ''' + LFiltro + ''' OR ' +
      'p.codbarra LIKE ''%' + LFiltro + '%'' OR ' +
      'u.codbarra LIKE ''%' + LFiltro + '%'' OR ' +
      'p.codprod IN (SELECT codprod FROM codbarras WHERE codbarra LIKE ''%' + LFiltro + '%'') ' +
      // Match exato de codigo/barras primeiro; depois ordem alfabetica
      'ORDER BY CASE WHEN CAST(p.codprod AS TEXT) = ''' + LFiltro + ''' ' +
      '  OR p.codbarra = ''' + LFiltro + ''' ' +
      '  OR u.codbarra = ''' + LFiltro + ''' THEN 0 ELSE 1 END, descricao ' +
      'LIMIT 100'
    );
    try
      LArr := TJSONArray.Create;
      while not LQuery.Eof do
      begin
        LProd := TJSONObject.Create;
        LProd.AddPair('codprod', TJSONNumber.Create(LQuery.FieldByName('codprod').AsLargeInt));
        LProd.AddPair('codbarra', LQuery.FieldByName('codbarra').AsString);
        LProd.AddPair('descricao', LQuery.FieldByName('descricao').AsString);
        LProd.AddPair('unidade', LQuery.FieldByName('unidade').AsString);
        LProd.AddPair('qtunit', TJSONNumber.Create(LQuery.FieldByName('qtunit').AsFloat));
        LProd.AddPair('embalagem', LQuery.FieldByName('embalagem').AsString);
        LProd.AddPair('pvenda', TJSONNumber.Create(LQuery.FieldByName('pvenda').AsFloat));
        LProd.AddPair('pvendaatac', TJSONNumber.Create(LQuery.FieldByName('pvendaatac').AsFloat));
        LProd.AddPair('poferta', TJSONNumber.Create(LQuery.FieldByName('poferta').AsFloat));
        LProd.AddPair('qtdisponivel', TJSONNumber.Create(LQuery.FieldByName('qtdisponivel').AsFloat));
        LArr.AddElement(LProd);
        LQuery.Next;
      end;

      Result := CriarRespostaSucesso('OK', LArr);
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

// =========================================================================
// VENDA
// =========================================================================

function TApoloBridge.DoIniciarVenda(const AData: string): string;
var
  LNumCupom: Integer;
  LDados: TJSONObject;
begin
  if FEstadoCaixa = ecFechado then
    Exit(CriarRespostaErro('Abra o caixa antes de iniciar uma venda'));

  // Recuperar de venda interrompida (crash/fechamento inesperado)
  if (FEstadoCaixa = ecRegistrando) or (FEstadoCaixa = ecPagamento) then
  begin
    if FCupomAtualId > 0 then
    begin
      FSQLite.ExecutarSQL(
        'UPDATE cupons SET codoper = ''C'', dthrfimvenda = datetime(''now'',''localtime''), ' +
        'obscancel = ''Cancelado automaticamente - venda interrompida'' WHERE id = ' +
        IntToStr(FCupomAtualId)
      );
    end;
    FEstadoCaixa := ecLivre;
    FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));
    FCupomAtualId := 0;
  end;

  if FEstadoCaixa <> ecLivre then
    Exit(CriarRespostaErro('Caixa nao esta livre para nova venda'));

  if FMatriculaLogada = 0 then
    Exit(CriarRespostaErro('Nenhum operador logado'));

  LNumCupom := ObterProximoNumCupom;

  FSQLite.ExecutarSQL(
    'INSERT INTO cupons (codoper, numcaixa, datamovto, dthriniciovenda, ' +
    'codoperador, numcupom, numserieequip, versao, codfilial) ' +
    'VALUES (:p0, :p1, :p2, :p3, :p4, :p5, :p6, :p7, :p8)',
    [
      'V',
      StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '1'), 1),
      FormatDateTime('yyyy-mm-dd', Now),
      FormatDateTime('yyyy-mm-dd hh:nn:ss', Now),
      FMatriculaLogada,
      LNumCupom,
      FSQLite.ObterEstado(KEY_NUMSERIE, ''),
      VERSAO_SISTEMA,
      // Exatamente como veio de msapolo_caixa.codfilial. Estava fixo em '01'
      // e a retaguarda usa '1' - com o zero a esquerda os JOINs por codfilial
      // no ERP nao batem.
      FSQLite.ObterEstado(KEY_CODFILIAL, '')
    ]
  );

  // Obter o ID gerado
  FCupomAtualId := FSQLite.ExecutarScalar('SELECT last_insert_rowid()');

  // Atualizar estado
  FEstadoCaixa := ecRegistrando;
  FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));

  LDados := TJSONObject.Create;
  LDados.AddPair('cupomId', TJSONNumber.Create(FCupomAtualId));
  LDados.AddPair('numCupom', TJSONNumber.Create(LNumCupom));
  LDados.AddPair('dataInicio', FormatDateTime('dd/mm/yyyy hh:nn:ss', Now));

  Result := CriarRespostaSucesso('Venda iniciada', LDados);
end;

function TApoloBridge.DoAdicionarItem(const AData: string): string;
var
  LJson: TJSONObject;
  LCodProd: Int64;
  LQtde, LPrecoUnit, LValorBruto, LValorTotal, LDesconto, LMaxPerDesc,
    LQtUnit, LPTabela: Double;
  LEmb: TEmbalagemInfo;
  LEmOferta: Boolean;
  LQuery: TUniQuery;
  LNumSeq: Integer;
  LDados: TJSONObject;
  LDescricao, LUnidade, LCodBarra: string;
begin
  if FEstadoCaixa <> ecRegistrando then
    Exit(CriarRespostaErro('Nao esta no modo de registro de itens'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LCodProd := LJson.GetValue<Int64>('codprod', 0);
    LQtde := LJson.GetValue<Double>('quantidade', 1);

    if LCodProd = 0 then
      Exit(CriarRespostaErro('Codigo do produto invalido'));
    if LQtde <= 0 then
      Exit(CriarRespostaErro('Quantidade invalida'));

    // Buscar produto
    LQuery := FSQLite.ExecutarSelect(
      'SELECT * FROM produtos WHERE codprod = ' + IntToStr(LCodProd)
    );
    try
      if LQuery.IsEmpty then
        Exit(CriarRespostaErro('Produto nao encontrado'));

      LDescricao := LQuery.FieldByName('descricao').AsString;
      LUnidade := LQuery.FieldByName('unidade').AsString;
      LCodBarra := LQuery.FieldByName('codbarra').AsString;

      // Dados da embalagem bipada: o mesmo codprod pode ter unidade,
      // descricao, qtunit e preco proprios por codigo de barras (ex: UN
      // pelo EAN da embalagem e KG pelo codigo avulso)
      LEmb := ObterEmbalagem(LCodProd, LJson.GetValue<string>('codbarra', ''));
      if LEmb.Encontrada then
      begin
        LCodBarra := LEmb.CodBarra;
        if LEmb.Unidade <> '' then
          LUnidade := LEmb.Unidade;
        if LEmb.Descricao <> '' then
          LDescricao := LEmb.Descricao;
      end;

      // Quantidade fracionada so e permitida para unidades KG ou metro
      if (Frac(LQtde) <> 0) and
         (UpperCase(Trim(LUnidade)) <> 'KG') and
         (UpperCase(Trim(LUnidade)) <> 'MT') and
         (UpperCase(Trim(LUnidade)) <> 'M') then
        Exit(CriarRespostaErro('Produto com unidade "' + Trim(LUnidade) +
          '" nao permite quantidade fracionada'));

      // Preco: da embalagem bipada quando existir; senao, linha principal
      if LEmb.Encontrada and (LEmb.PVenda > 0) then
      begin
        LPTabela := LEmb.PVenda;
        LEmOferta := (LEmb.POferta > 0) and
          (LEmb.DtFimOferta >= FormatDateTime('yyyy-mm-dd', Now));
        LPrecoUnit := LPTabela;
        if LEmOferta then
          LPrecoUnit := LEmb.POferta;
      end
      else
      begin
        LPTabela := LQuery.FieldByName('pvenda').AsFloat;
        LEmOferta := (LQuery.FieldByName('poferta').AsFloat > 0) and
          (LQuery.FieldByName('dtfimoferta').AsString >= FormatDateTime('yyyy-mm-dd', Now));
        LPrecoUnit := LPTabela;
        if LEmOferta then
          LPrecoUnit := LQuery.FieldByName('poferta').AsFloat;
      end;

      // Preco manual
      if LJson.GetValue<Double>('precoManual', 0) > 0 then
        LPrecoUnit := LJson.GetValue<Double>('precoManual', 0);

      // Etiqueta de balanca (EAN-13 prefixo 2): o codigo traz o PRECO pesado,
      // nao a quantidade. A quantidade e o preco da etiqueta dividido pelo
      // preco vigente (tabela ou oferta), com 3 casas: 0,73 / 13,00 = 0,056
      if (LJson.GetValue<Double>('precoEtiqueta', 0) > 0) and (LPrecoUnit > 0) then
      begin
        LQtde := RoundTo(LJson.GetValue<Double>('precoEtiqueta', 0) / LPrecoUnit, -3);
        if LQtde <= 0 then
          LQtde := 0.001;
      end;

      // vlprod = valor BRUTO do item (qt * punit). O desconto do item fica em
      // vldesconto/vldescitem e so' e' abatido no total do cupom e na base dos
      // impostos - e' a convencao que a NFCe (vProd + vDesc) e o Oracle esperam.
      LValorBruto := RoundTo(LQtde * LPrecoUnit, -2);

      LDesconto := RoundTo(LJson.GetValue<Double>('desconto', 0), -2);
      if LDesconto < 0 then LDesconto := 0;
      if LDesconto > LValorBruto then LDesconto := LValorBruto;

      // Limite de desconto do produto (msapolo_produtos.maxperdesc)
      LMaxPerDesc := LQuery.FieldByName('maxperdesc').AsFloat;
      if (LDesconto > 0) and (LMaxPerDesc > 0) and
         (LDesconto > RoundTo(LValorBruto * LMaxPerDesc / 100, -2)) then
        Exit(CriarRespostaErro(Format(
          'Desconto acima do limite do produto (%.2f%%)', [LMaxPerDesc])));

      // Valor liquido - base dos impostos
      LValorTotal := RoundTo(LValorBruto - LDesconto, -2);

      // QTUNIT informativo (quantidade por embalagem do EAN bipado). Nao
      // altera quantidade nem valor - apenas sobe para a retaguarda no item.
      LQtUnit := LEmb.QtUnit;
      if LQtUnit <= 0 then
        LQtUnit := LQuery.FieldByName('qtunit').AsFloat;
      if LQtUnit <= 0 then
        LQtUnit := 1;

      // Proximo sequencial
      LNumSeq := FSQLite.ExecutarScalar(
        'SELECT COALESCE(MAX(numseqitem), 0) + 1 FROM cupom_itens WHERE cupom_id = ' +
        IntToStr(FCupomAtualId)
      );

      // Inserir item
      FSQLite.ExecutarSQL(
        'INSERT INTO cupom_itens (cupom_id, numseqitem, codprod, codbarra, ' +
        'descricao, unidade, embalagem, qt, punit, vlprod, vldesconto, vldescitem, ' +
        'ncm, cfop, cest, icms_cst, csosn, aliqicms, pis_cst, cofins_cst, ' +
        'aliqpis, aliqcofins, valorpis, valorcofins, impleitransparencia, ' +
        'codvendedor, emoferta, ptabela, prod_origem, codfilial, numcaixa, numserieequip, ' +
        'qtunit) ' +
        'VALUES (:p0,:p1,:p2,:p3,:p4,:p5,:p6,:p7,:p8,:p9,:p10,:p11,' +
        ':p12,:p13,:p14,:p15,:p16,:p17,:p18,:p19,:p20,:p21,:p22,:p23,:p24,' +
        ':p25,:p26,:p27,:p28,:p29,:p30,:p31,:p32)',
        [
          FCupomAtualId, LNumSeq, LCodProd, LCodBarra,
          LDescricao, LUnidade, LQuery.FieldByName('embalagem').AsString,
          LQtde, LPrecoUnit, LValorBruto, LDesconto, LDesconto,
          LQuery.FieldByName('ncm').AsString,
          LQuery.FieldByName('cfop').AsString,
          LQuery.FieldByName('cest').AsString,
          LQuery.FieldByName('icms_cst').AsString,
          LQuery.FieldByName('csosn').AsString,
          LQuery.FieldByName('aliqicms').AsFloat,
          LQuery.FieldByName('pis_cst').AsString,
          LQuery.FieldByName('cofins_cst').AsString,
          LQuery.FieldByName('pis_ppis').AsFloat,
          LQuery.FieldByName('cofins_pcofins').AsFloat,
          RoundTo(LValorTotal * LQuery.FieldByName('pis_ppis').AsFloat / 100, -2),
          RoundTo(LValorTotal * LQuery.FieldByName('cofins_pcofins').AsFloat / 100, -2),
          RoundTo(LValorTotal * LQuery.FieldByName('impleitransparencia').AsFloat / 100, -2),
          IfThen(LJson.GetValue<Integer>('codvendedor', 0) > 0,
            LJson.GetValue<Integer>('codvendedor', 0), FMatriculaLogada),
          IfThen(LEmOferta, 'S', 'N'),
          LPTabela,
          LQuery.FieldByName('prod_origem').AsString,
          FSQLite.ObterEstado(KEY_CODFILIAL, ''),
          StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '1'), 1),
          FSQLite.ObterEstado(KEY_NUMSERIE, ''),
          LQtUnit
        ]
      );

      AtualizarTotaisCupom(FCupomAtualId);

      LDados := TJSONObject.Create;
      LDados.AddPair('numSeqItem', TJSONNumber.Create(LNumSeq));
      LDados.AddPair('codprod', TJSONNumber.Create(LCodProd));
      LDados.AddPair('descricao', LDescricao);
      LDados.AddPair('unidade', LUnidade);
      LDados.AddPair('quantidade', TJSONNumber.Create(LQtde));
      LDados.AddPair('precoUnit', TJSONNumber.Create(LPrecoUnit));
      LDados.AddPair('valorBruto', TJSONNumber.Create(LValorBruto));
      LDados.AddPair('desconto', TJSONNumber.Create(LDesconto));
      LDados.AddPair('valorTotal', TJSONNumber.Create(LValorTotal));
      LDados.AddPair('maxPerDesc', TJSONNumber.Create(LMaxPerDesc));
      LDados.AddPair('totalCupom', TJSONNumber.Create(CalcularTotalCupom(FCupomAtualId)));

      Result := CriarRespostaSucesso('Item adicionado', LDados);
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoRemoverItem(const AData: string): string;
var
  LJson: TJSONObject;
  LSeqItem, LMatAutorizou: Integer;
  LErro, LObs: string;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    if not ValidarAutorizacao(CTRL_CANCELAR_ITEM, LJson, LMatAutorizou, LErro) then
    begin
      if LErro = '' then
        LErro := 'Operador sem permissao para cancelar item';
      Exit(CriarRespostaSemPermissao(LErro));
    end;

    LSeqItem := LJson.GetValue<Integer>('numSeqItem', 0);

    if LMatAutorizou <> FMatriculaLogada then
      LObs := 'Cancelado com autorizacao da matricula ' + IntToStr(LMatAutorizou)
    else
      LObs := 'Cancelado pelo operador';

    FSQLite.ExecutarSQL(
      'UPDATE cupom_itens SET dtcancel = datetime(''now'',''localtime''), ' +
      'obscancel = :p0 ' +
      'WHERE cupom_id = ' + IntToStr(FCupomAtualId) +
      ' AND numseqitem = ' + IntToStr(LSeqItem),
      [LObs]
    );

    AtualizarTotaisCupom(FCupomAtualId);

    Result := CriarRespostaSucesso('Item removido');
  finally
    LJson.Free;
  end;
end;

// Desconto no TOTAL da venda (subtotal). Exige o controle 3 da rotina 8002;
// sem permissao o frontend pede matricula/senha de um autorizador.
function TApoloBridge.DoAplicarDesconto(const AData: string): string;
var
  LJson: TJSONObject;
  LValor, LBase: Double;
  LTipo, LErro: string;
  LMatAutorizou: Integer;
begin
  if FCupomAtualId = 0 then
    Exit(CriarRespostaErro('Nenhuma venda em andamento'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    if not ValidarAutorizacao(CTRL_DESCONTO_VENDA, LJson, LMatAutorizou, LErro) then
    begin
      if LErro = '' then
        LErro := 'Operador sem permissao para desconto no total da venda';
      Exit(CriarRespostaSemPermissao(LErro));
    end;

    LValor := LJson.GetValue<Double>('valor', 0);
    LTipo := LJson.GetValue<string>('tipo', 'valor'); // 'valor' ou 'percentual'

    if LValor < 0 then
      Exit(CriarRespostaErro('Valor de desconto invalido'));

    // Base = subtotal liquido dos itens (ja' descontados os descontos de item)
    LBase := VarToFloatDef(FSQLite.ExecutarScalar(
      'SELECT COALESCE(SUM(vlprod - vldesconto), 0) FROM cupom_itens ' +
      'WHERE cupom_id = ' + IntToStr(FCupomAtualId) + ' AND dtcancel IS NULL'), 0);

    if LTipo = 'percentual' then
    begin
      if LValor > 100 then
        Exit(CriarRespostaErro('Percentual invalido (maximo 100%)'));
      LValor := RoundTo(LBase * LValor / 100, -2);
    end
    else
      LValor := RoundTo(LValor, -2);

    if LValor > LBase then
      Exit(CriarRespostaErro('Desconto maior que o total da venda'));

    // valordescsubtotal = desconto no subtotal; valordesc (total) e' recalculado
    // por AtualizarTotaisCupom somando tambem os descontos de item.
    FSQLite.ExecutarSQL(
      'UPDATE cupons SET valordescsubtotal = :p0 WHERE id = :p1',
      [LValor, FCupomAtualId]
    );
    AtualizarTotaisCupom(FCupomAtualId);

    Result := CriarRespostaSucesso('Desconto aplicado');
  finally
    LJson.Free;
  end;
end;

// Desconto aplicado a UM item do cupom (Shift+F3 no PDV).
// Aceita valor em R$ ou percentual sobre o valor bruto do item, respeita o
// limite de desconto do produto (maxperdesc) e recalcula os impostos do item
// sobre o valor liquido. Valor 0 remove o desconto.
function TApoloBridge.DoAplicarDescontoItem(const AData: string): string;
var
  LJson: TJSONObject;
  LQuery: TUniQuery;
  LSeqItem, LMatAutorizou: Integer;
  LValor, LBruto, LLiquido, LMaxPerDesc, LPerc: Double;
  LAliqPis, LAliqCofins, LPerLeiTransp: Double;
  LTipo, LDescricao, LErro: string;
  LVal: Variant;
  LDados: TJSONObject;
begin
  if FCupomAtualId = 0 then
    Exit(CriarRespostaErro('Nenhuma venda em andamento'));
  if FEstadoCaixa <> ecRegistrando then
    Exit(CriarRespostaErro('Desconto por item so e permitido durante o registro'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    if not ValidarAutorizacao(CTRL_DESCONTO_ITEM, LJson, LMatAutorizou, LErro) then
    begin
      if LErro = '' then
        LErro := 'Operador sem permissao para desconto no item';
      Exit(CriarRespostaSemPermissao(LErro));
    end;

    LSeqItem := LJson.GetValue<Integer>('numSeqItem', 0);
    LValor := LJson.GetValue<Double>('valor', 0);
    LTipo := LJson.GetValue<string>('tipo', 'valor'); // 'valor' ou 'percentual'

    if LSeqItem <= 0 then
      Exit(CriarRespostaErro('Numero do item invalido'));
    if LValor < 0 then
      Exit(CriarRespostaErro('Valor de desconto invalido'));

    LQuery := FSQLite.ExecutarSelect(
      'SELECT descricao, codprod, vlprod, aliqpis, aliqcofins, dtcancel ' +
      'FROM cupom_itens WHERE cupom_id = ' + IntToStr(FCupomAtualId) +
      ' AND numseqitem = ' + IntToStr(LSeqItem)
    );
    try
      if LQuery.IsEmpty then
        Exit(CriarRespostaErro('Item ' + IntToStr(LSeqItem) + ' nao encontrado'));
      if not LQuery.FieldByName('dtcancel').IsNull then
        Exit(CriarRespostaErro('Item ' + IntToStr(LSeqItem) + ' esta cancelado'));

      LDescricao := LQuery.FieldByName('descricao').AsString;
      LBruto := LQuery.FieldByName('vlprod').AsFloat;
      LAliqPis := LQuery.FieldByName('aliqpis').AsFloat;
      LAliqCofins := LQuery.FieldByName('aliqcofins').AsFloat;

      // Percentual da lei da transparencia vem da tabela de produtos
      LVal := FSQLite.ExecutarScalar(
        'SELECT COALESCE(impleitransparencia, 0) FROM produtos WHERE codprod = ' +
        LQuery.FieldByName('codprod').AsString);
      LPerLeiTransp := VarToFloatDef(LVal, 0);

      // Limite de desconto do produto (0 = sem limite configurado)
      LVal := FSQLite.ExecutarScalar(
        'SELECT COALESCE(maxperdesc, 0) FROM produtos WHERE codprod = ' +
        LQuery.FieldByName('codprod').AsString);
      LMaxPerDesc := VarToFloatDef(LVal, 0);
    finally
      LQuery.Free;
    end;

    if LBruto <= 0 then
      Exit(CriarRespostaErro('Item sem valor para desconto'));

    if LTipo = 'percentual' then
    begin
      if LValor > 100 then
        Exit(CriarRespostaErro('Percentual invalido (maximo 100%)'));
      LValor := RoundTo(LBruto * LValor / 100, -2);
    end
    else
      LValor := RoundTo(LValor, -2);

    if LValor > LBruto then
      Exit(CriarRespostaErro('Desconto maior que o valor do item'));

    LPerc := RoundTo(LValor / LBruto * 100, -2);
    if (LValor > 0) and (LMaxPerDesc > 0) and (LPerc > LMaxPerDesc) then
      Exit(CriarRespostaErro(Format(
        'Desconto de %.2f%% acima do limite do produto (%.2f%%)',
        [LPerc, LMaxPerDesc])));

    LLiquido := RoundTo(LBruto - LValor, -2);

    // Impostos do item incidem sobre o liquido
    FSQLite.ExecutarSQL(
      'UPDATE cupom_itens SET vldesconto = :p0, vldescitem = :p0, ' +
      'valorpis = :p1, valorcofins = :p2, impleitransparencia = :p3 ' +
      'WHERE cupom_id = :p4 AND numseqitem = :p5',
      [
        LValor,
        RoundTo(LLiquido * LAliqPis / 100, -2),
        RoundTo(LLiquido * LAliqCofins / 100, -2),
        RoundTo(LLiquido * LPerLeiTransp / 100, -2),
        FCupomAtualId,
        LSeqItem
      ]
    );

    AtualizarTotaisCupom(FCupomAtualId);

    LDados := TJSONObject.Create;
    LDados.AddPair('numSeqItem', TJSONNumber.Create(LSeqItem));
    LDados.AddPair('descricao', LDescricao);
    LDados.AddPair('valorBruto', TJSONNumber.Create(LBruto));
    LDados.AddPair('desconto', TJSONNumber.Create(LValor));
    LDados.AddPair('percentual', TJSONNumber.Create(LPerc));
    LDados.AddPair('valorTotal', TJSONNumber.Create(LLiquido));
    LDados.AddPair('totalCupom', TJSONNumber.Create(CalcularTotalCupom(FCupomAtualId)));

    if LValor = 0 then
      Result := CriarRespostaSucesso('Desconto removido do item ' + IntToStr(LSeqItem), LDados)
    else
      Result := CriarRespostaSucesso(
        Format('Desconto de %.2f%% aplicado ao item %d', [LPerc, LSeqItem]), LDados);
  finally
    LJson.Free;
  end;
end;

// Cancelamento da venda inteira (F12). Exige o controle 5 da rotina 8002;
// sem permissao o frontend pede matricula/senha de um autorizador.
function TApoloBridge.DoCancelarVenda(const AData: string): string;
var
  LJson: TJSONObject;
  LCupomId: Variant;
  LMatAutorizou: Integer;
  LErro, LObs: string;
begin
  if FEstadoCaixa = ecFechado then
    Exit(CriarRespostaErro('Caixa fechado'));

  // A action pode chegar sem payload (F12 direto); segue com objeto vazio
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then
    LJson := TJSONObject.Create;

  try
    // Recuperacao: sem venda em memoria, procurar cupom aberto orfao
    // (sobra de queda de energia / encerramento abrupto)
    if FCupomAtualId = 0 then
    begin
      LCupomId := FSQLite.ExecutarScalar(
        'SELECT id FROM cupons WHERE dthrfimvenda IS NULL AND codoper <> ''C'' ' +
        'ORDER BY id DESC LIMIT 1');
      if (not VarIsNull(LCupomId)) and (not VarIsEmpty(LCupomId)) then
        FCupomAtualId := Integer(LCupomId);
    end;

    if FCupomAtualId = 0 then
    begin
      // Nada a cancelar. Se o estado persistido ficou preso em
      // registrando/pagamento, normalizar para liberar o caixa (e a carga geral).
      // Nao e' um cancelamento de venda, entao nao exige autorizacao.
      FEstadoCaixa := ecLivre;
      FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));
      Exit(CriarRespostaSucesso('Nao havia venda em andamento (estado do caixa normalizado)'));
    end;

    if not ValidarAutorizacao(CTRL_CANCELAR_VENDA, LJson, LMatAutorizou, LErro) then
    begin
      if LErro = '' then
        LErro := 'Operador sem permissao para cancelar a venda';
      Exit(CriarRespostaSemPermissao(LErro));
    end;

    // Desfazer transacoes TEF pendentes desta venda
    DesfazerTEFPendentes(FCupomAtualId);

    if LMatAutorizou <> FMatriculaLogada then
      LObs := 'Cancelado com autorizacao da matricula ' + IntToStr(LMatAutorizou)
    else
      LObs := 'Cancelado pelo operador';

    FSQLite.ExecutarSQL(
      'UPDATE cupons SET codoper = ''C'', dthrfimvenda = datetime(''now'',''localtime''), ' +
      'obscancel = :p0 WHERE id = ' + IntToStr(FCupomAtualId),
      [LObs]
    );

    FEstadoCaixa := ecLivre;
    FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));
    FCupomAtualId := 0;

    Result := CriarRespostaSucesso('Venda cancelada');
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoObterItensCupom(const AData: string): string;
var
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LItem: TJSONObject;
begin
  if FCupomAtualId = 0 then
    Exit(CriarRespostaErro('Nenhuma venda em andamento'));

  LQuery := FSQLite.ExecutarSelect(
    'SELECT numseqitem, codprod, codbarra, descricao, unidade, ' +
    'qt, punit, vlprod, vldesconto, emoferta, dtcancel ' +
    'FROM cupom_itens WHERE cupom_id = ' + IntToStr(FCupomAtualId) +
    ' ORDER BY numseqitem'
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('seq', TJSONNumber.Create(LQuery.FieldByName('numseqitem').AsInteger));
      LItem.AddPair('codprod', TJSONNumber.Create(LQuery.FieldByName('codprod').AsInteger));
      LItem.AddPair('codbarra', LQuery.FieldByName('codbarra').AsString);
      LItem.AddPair('descricao', LQuery.FieldByName('descricao').AsString);
      LItem.AddPair('unidade', LQuery.FieldByName('unidade').AsString);
      LItem.AddPair('quantidade', TJSONNumber.Create(LQuery.FieldByName('qt').AsFloat));
      LItem.AddPair('precoUnit', TJSONNumber.Create(LQuery.FieldByName('punit').AsFloat));
      LItem.AddPair('valorBruto', TJSONNumber.Create(LQuery.FieldByName('vlprod').AsFloat));
      LItem.AddPair('desconto', TJSONNumber.Create(LQuery.FieldByName('vldesconto').AsFloat));
      LItem.AddPair('valorTotal', TJSONNumber.Create(RoundTo(
        LQuery.FieldByName('vlprod').AsFloat -
        LQuery.FieldByName('vldesconto').AsFloat, -2)));
      LItem.AddPair('emOferta', LQuery.FieldByName('emoferta').AsString = 'S');
      LItem.AddPair('cancelado', not LQuery.FieldByName('dtcancel').IsNull);
      LArr.AddElement(LItem);
      LQuery.Next;
    end;

    Result := CriarRespostaSucesso('OK', LArr);
  finally
    LQuery.Free;
  end;
end;

function TApoloBridge.DoObterResumoCupom(const AData: string): string;
var
  LQuery: TUniQuery;
  LDados: TJSONObject;
begin
  if FCupomAtualId = 0 then
    Exit(CriarRespostaErro('Nenhuma venda em andamento'));

  LQuery := FSQLite.ExecutarSelect(
    'SELECT qtdeitens, valorvenda, valordesc, valordescsubtotal, ' +
    'valorencargo, valortroco FROM cupons WHERE id = ' + IntToStr(FCupomAtualId)
  );
  try
    LDados := TJSONObject.Create;
    LDados.AddPair('qtdeitens', TJSONNumber.Create(LQuery.FieldByName('qtdeitens').AsInteger));
    LDados.AddPair('subtotal', TJSONNumber.Create(LQuery.FieldByName('valorvenda').AsFloat));
    LDados.AddPair('desconto', TJSONNumber.Create(LQuery.FieldByName('valordesc').AsFloat));
    LDados.AddPair('descontoSubtotal', TJSONNumber.Create(
      LQuery.FieldByName('valordescsubtotal').AsFloat));
    LDados.AddPair('descontoItens', TJSONNumber.Create(RoundTo(
      LQuery.FieldByName('valordesc').AsFloat -
      LQuery.FieldByName('valordescsubtotal').AsFloat, -2)));
    LDados.AddPair('acrescimo', TJSONNumber.Create(LQuery.FieldByName('valorencargo').AsFloat));
    LDados.AddPair('total', TJSONNumber.Create(CalcularTotalCupom(FCupomAtualId)));
    LDados.AddPair('totalPago', TJSONNumber.Create(CalcularTotalPago(FCupomAtualId)));

    Result := CriarRespostaSucesso('OK', LDados);
  finally
    LQuery.Free;
  end;
end;

// =========================================================================
// PAGAMENTO
// =========================================================================

function TApoloBridge.DoRegistrarPagamento(const AData: string): string;
var
  LJson: TJSONObject;
  LCodCob: string;
  LValor: Double;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LCodCob := LJson.GetValue<string>('codcob', '');
    LValor := LJson.GetValue<Double>('valor', 0);

    if LValor <= 0 then
      Exit(CriarRespostaErro('Valor invalido'));

    // Sem estas guardas o pagamento entrava com cupom_id 0 (caixa fechado ou
    // livre, front dessincronizado) e virava linha orfa em cupom_pagamentos,
    // contada no fechamento sem venda nenhuma por tras. DoAdicionarItem ja
    // valida assim; aqui tinha ficado de fora.
    if FCupomAtualId = 0 then
      Exit(CriarRespostaErro('Nenhuma venda em andamento'));
    if not (FEstadoCaixa in [ecRegistrando, ecPagamento]) then
      Exit(CriarRespostaErro('Caixa nao esta em uma venda'));

    if FEstadoCaixa = ecRegistrando then
    begin
      FEstadoCaixa := ecPagamento;
      FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));
    end;

    FSQLite.ExecutarSQL(
      'INSERT INTO cupom_pagamentos (cupom_id, codcob, valor, ' +
      'numbanco, numagencia, numcontacorrente, numcheque, numcmc7, ' +
      'cpf_cnpj_cheque, dtpredatado, ' +
      'codtipotransacao, codmodotransacao, codbandeira, codrede, ' +
      'codautorizacao, nsu, numparcela, qtdeparcela, ' +
      'codplpag, dtvenc, dthroperacao) ' +
      'VALUES (:p0, :p1, :p2, ' +
      ':p3, :p4, :p5, :p6, :p7, :p8, :p9, ' +
      ':p10, :p11, :p12, :p13, :p14, :p15, :p16, :p17, ' +
      ':p18, :p19, datetime(''now'',''localtime''))',
      [
        FCupomAtualId, LCodCob, LValor,
        LJson.GetValue<Integer>('numbanco', 0),
        LJson.GetValue<string>('numagencia', ''),
        LJson.GetValue<string>('numcontacorrente', ''),
        LJson.GetValue<string>('numcheque', ''),
        LJson.GetValue<string>('numcmc7', ''),
        LJson.GetValue<string>('cpf_cnpj_cheque', ''),
        LJson.GetValue<string>('dtpredatado', ''),
        LJson.GetValue<Integer>('codtipotransacao', 0),
        LJson.GetValue<Integer>('codmodotransacao', 0),
        LJson.GetValue<Integer>('codbandeira', 0),
        LJson.GetValue<Integer>('codrede', 0),
        LJson.GetValue<string>('codautorizacao', ''),
        LJson.GetValue<string>('nsu', ''),
        LJson.GetValue<Integer>('numparcela', 0),
        LJson.GetValue<Integer>('qtdeparcela', 0),
        LJson.GetValue<Integer>('codplpag', 0),
        LJson.GetValue<string>('dtvenc', '')
      ]
    );

    Result := DoObterResumoPagamento('{}');
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoRemoverPagamento(const AData: string): string;
var
  LJson: TJSONObject;
  LId: Integer;
  LNSU: Variant;
  LNSUStr, LControle: string;
  LTefQuery: TUniQuery;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LId := LJson.GetValue<Integer>('id', 0);

    // Verificar se o pagamento tem TEF pendente associado (pelo NSU)
    if FTEFHabilitado and (FTEFClient <> nil) then
    begin
      LNSU := FSQLite.ExecutarScalar(
        'SELECT nsu FROM cupom_pagamentos WHERE id = ' + IntToStr(LId) +
        ' AND cupom_id = ' + IntToStr(FCupomAtualId)
      );
      if not VarIsNull(LNSU) and not VarIsEmpty(LNSU) then
      begin
        LNSUStr := VarToStr(LNSU);
        if LNSUStr <> '' then
        begin
          LTefQuery := FSQLite.ExecutarSelect(
            'SELECT id, controle FROM tef_pendentes WHERE cupom_id = ' +
            IntToStr(FCupomAtualId) + ' AND nsu = ''' + LNSUStr + ''' AND status = ''PENDENTE'''
          );
          try
            if not LTefQuery.Eof then
            begin
              LControle := LTefQuery.FieldByName('controle').AsString;
              var LTefId := LTefQuery.FieldByName('id').AsInteger;
              // Desfazer TEF em thread
              TThread.CreateAnonymousThread(
                procedure
                begin
                  try
                    FTEFClient.Desfazer(FCupomAtualId, LControle);
                    TThread.Queue(nil,
                      procedure
                      begin
                        FSQLite.ExecutarSQL(
                          'UPDATE tef_pendentes SET status = ''DESFEITO'', ' +
                          'dthr_confirmacao = datetime(''now'',''localtime'') WHERE id = ' +
                          IntToStr(LTefId)
                        );
                      end
                    );
                  except
                    // Falha no desfazimento
                  end;
                end
              ).Start;
            end;
          finally
            LTefQuery.Free;
          end;
        end;
      end;
    end;

    FSQLite.ExecutarSQL(
      'DELETE FROM cupom_pagamentos WHERE id = ' + IntToStr(LId) +
      ' AND cupom_id = ' + IntToStr(FCupomAtualId)
    );
    Result := DoObterResumoPagamento('{}');
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoFinalizarVenda(const AData: string): string;
var
  LTotal, LTotalPago, LTroco: Double;
  LDados: TJSONObject;
  LCodConsumidor: Integer;
begin
  if FEstadoCaixa <> ecPagamento then
    Exit(CriarRespostaErro('Nao esta no modo de pagamento'));

  LTotal := CalcularTotalCupom(FCupomAtualId);
  LTotalPago := CalcularTotalPago(FCupomAtualId);

  // Tolerancia de meio centavo: os dois lados ja vem arredondados, mas uma
  // diferenca menor que isso nao e' falta de pagamento - e' ruido de Double.
  if LTotalPago < LTotal - TOLERANCIA_CENTAVO then
    Exit(CriarRespostaErro('Pagamento insuficiente. Faltam R$ ' +
      FormatFloat('#,##0.00', LTotal - LTotalPago)));

  LTroco := Max(RoundTo(LTotalPago - LTotal, -2), 0);

  // Atualizar cupom
  FSQLite.ExecutarSQL(
    'UPDATE cupons SET dthrfimvenda = datetime(''now'',''localtime''), ' +
    'valortroco = :p0, codoper = ''V'' WHERE id = :p1',
    [LTroco, FCupomAtualId]
  );

  // Venda sem cliente identificado fecha com o consumidor padrao da filial
  // (msfilial.codconsumidor). Sem isso a venda sobe com codcli 0, que nao
  // existe em mscliente, e o MSNF do ERP fica sem cliente valido.
  // E' o mesmo codigo que DoIdentificarConsumidor ja aplica quando o CPF
  // informado nao esta no cadastro.
  LCodConsumidor := StrToIntDef(FSQLite.ObterEstado(KEY_CODCONSUMIDOR, '0'), 0);
  if LCodConsumidor > 0 then
    FSQLite.ExecutarSQL(
      'UPDATE cupons SET codcli = :p0 ' +
      'WHERE id = :p1 AND (codcli IS NULL OR codcli = 0)',
      [LCodConsumidor, FCupomAtualId]
    )
  else
    SyncLog('VENDA cupom=%d: msfilial.codconsumidor nao configurado, ' +
      'venda sobe com codcli 0', [FCupomAtualId]);

  // Atualizar saldo dinheiro
  FSQLite.SalvarEstado(KEY_TOTAL_DINHEIRO,
    FloatToStr(StrToFloatDef(FSQLite.ObterEstado(KEY_TOTAL_DINHEIRO, '0'), 0) +
      LTotalPago - LTroco)
  );

  LDados := TJSONObject.Create;
  LDados.AddPair('cupomId', TJSONNumber.Create(FCupomAtualId));
  LDados.AddPair('total', TJSONNumber.Create(LTotal));
  LDados.AddPair('totalPago', TJSONNumber.Create(LTotalPago));
  LDados.AddPair('troco', TJSONNumber.Create(LTroco));

  // Voltar para estado livre
  FEstadoCaixa := ecLivre;
  FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));

  // Confirmar transacoes TEF pendentes desta venda
  ConfirmarTEFPendentes(FCupomAtualId);

  // Subir a venda para a retaguarda. Independe da NFCe: o cupom existe e
  // precisa chegar no Oracle mesmo que a nota falhe ou caia em contingencia.
  // Se o Oracle estiver fora, fica sincronizado=0 e o retry cuida depois.
  if Assigned(FOnUploadVenda) then
  begin
    try
      FOnUploadVenda(FCupomAtualId);
    except
      on E: Exception do
        SyncLog('UPLOAD venda cupom=%d: falha no disparo imediato - [%s] %s',
          [FCupomAtualId, E.ClassName, E.Message]);
    end;
  end;

  // Guardar o cupomId antes de resetar
  Result := CriarRespostaSucesso('Venda finalizada', LDados);

  FCupomAtualId := 0;
end;

function TApoloBridge.DoListarMeiosPagamento(const AData: string): string;
var
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT codcob, descricao, tipo FROM meios_pagamento WHERE ativo = 1 ORDER BY codcob'
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('codcob', LQuery.FieldByName('codcob').AsString);
      LObj.AddPair('descricao', LQuery.FieldByName('descricao').AsString);
      LObj.AddPair('tipo', LQuery.FieldByName('tipo').AsString);
      LArr.AddElement(LObj);
      LQuery.Next;
    end;
    Result := CriarRespostaSucesso('OK', LArr);
  finally
    LQuery.Free;
  end;
end;

// Planos de pagamento da aba Cobranca (msapolo_planopagto sincronizada)
function TApoloBridge.DoListarPlanosPagamento(const AData: string): string;
var
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT codplpag, descricao, qtdeparcelas, txplano, prazos FROM planos_pagamento ' +
    'ORDER BY codplpag'
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('codplpag', TJSONNumber.Create(LQuery.FieldByName('codplpag').AsInteger));
      LObj.AddPair('descricao', LQuery.FieldByName('descricao').AsString);
      LObj.AddPair('qtdeparcelas', TJSONNumber.Create(LQuery.FieldByName('qtdeparcelas').AsInteger));
      LObj.AddPair('txplano', TJSONNumber.Create(LQuery.FieldByName('txplano').AsFloat));
      LObj.AddPair('prazos', LQuery.FieldByName('prazos').AsString);
      LArr.AddElement(LObj);
      LQuery.Next;
    end;
    Result := CriarRespostaSucesso('OK', LArr);
  finally
    LQuery.Free;
  end;
end;

// Cadastro de meios de pagamento do PDV (msapolo_meiopagto sincronizada),
// usado na aba Cobranca do modal de pagamento
function TApoloBridge.DoListarMeioPagto(const AData: string): string;
var
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT id, descricao, codcob, ordem, obg_dtvenc, obg_documento, ' +
    'permite_troco, cmp FROM meiopagto ORDER BY ordem, descricao'
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('id', TJSONNumber.Create(LQuery.FieldByName('id').AsInteger));
      LObj.AddPair('descricao', LQuery.FieldByName('descricao').AsString);
      LObj.AddPair('codcob', LQuery.FieldByName('codcob').AsString);
      LObj.AddPair('obg_dtvenc', LQuery.FieldByName('obg_dtvenc').AsString);
      LObj.AddPair('obg_documento', LQuery.FieldByName('obg_documento').AsString);
      LObj.AddPair('permite_troco', LQuery.FieldByName('permite_troco').AsString);
      LObj.AddPair('cmp', LQuery.FieldByName('cmp').AsString);
      LArr.AddElement(LObj);
      LQuery.Next;
    end;
    Result := CriarRespostaSucesso('OK', LArr);
  finally
    LQuery.Free;
  end;
end;

function TApoloBridge.DoListarBandeiras(const AData: string): string;
var
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT codbandeira, descricao, tband FROM bandeiras ORDER BY descricao'
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('codbandeira', TJSONNumber.Create(LQuery.FieldByName('codbandeira').AsInteger));
      LObj.AddPair('descricao', LQuery.FieldByName('descricao').AsString);
      LObj.AddPair('tband', LQuery.FieldByName('tband').AsString);
      LArr.AddElement(LObj);
      LQuery.Next;
    end;
    Result := CriarRespostaSucesso('OK', LArr);
  finally
    LQuery.Free;
  end;
end;

function TApoloBridge.DoObterResumoPagamento(const AData: string): string;
var
  LTotal, LTotalPago, LRestante: Double;
  LDados: TJSONObject;
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
  LCodCob, LDescricao: string;

  // Descricao padrao quando meios_pagamento ainda nao foi sincronizado
  // ou nao possui o codigo (ex.: PIX/POS criados pelo proprio PDV)
  function DescricaoPadrao(const ACodCob: string): string;
  begin
    if ACodCob = '01' then Result := 'Dinheiro'
    else if ACodCob = '02' then Result := 'Cheque'
    else if ACodCob = '03' then Result := 'Cartao'
    else if ACodCob = '05' then Result := 'Cobranca'
    else if ACodCob = '17' then Result := 'PIX'
    else if ACodCob = '99' then Result := 'POS'
    else Result := 'Cod. ' + ACodCob;
  end;

begin
  LTotal := CalcularTotalCupom(FCupomAtualId);
  LTotalPago := CalcularTotalPago(FCupomAtualId);
  // Arredondar antes de mandar ao front: e' com o restante daqui que o
  // payment.js decide auto-finalizar, e um residuo de 1e-13 fazia ele pedir
  // uma finalizacao que o DoFinalizarVenda recusava.
  LRestante := Max(RoundTo(LTotal - LTotalPago, -2), 0);

  LDados := TJSONObject.Create;
  LDados.AddPair('total', TJSONNumber.Create(LTotal));
  LDados.AddPair('totalPago', TJSONNumber.Create(LTotalPago));
  LDados.AddPair('restante', TJSONNumber.Create(LRestante));
  LDados.AddPair('troco', TJSONNumber.Create(Max(RoundTo(LTotalPago - LTotal, -2), 0)));

  // Listar pagamentos registrados
  // JOIN normalizado (LTRIM dos zeros a esquerda) porque o codcob gravado no
  // cupom usa 2 digitos e o vindo do Oracle pode estar sem o zero a esquerda
  LQuery := FSQLite.ExecutarSelect(
    'SELECT p.id, p.codcob, ' +
    'COALESCE(NULLIF(TRIM(mp.descricao), ''''), m.descricao) as descricao, p.valor ' +
    'FROM cupom_pagamentos p ' +
    'LEFT JOIN meiopagto mp ON mp.codcob = p.codcob ' +
    'LEFT JOIN meios_pagamento m ' +
    '  ON LTRIM(TRIM(p.codcob), ''0'') = LTRIM(TRIM(m.codcob), ''0'') ' +
    'WHERE p.cupom_id = ' + IntToStr(FCupomAtualId) + ' ORDER BY p.id'
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LCodCob := LQuery.FieldByName('codcob').AsString;
      LDescricao := Trim(LQuery.FieldByName('descricao').AsString);
      if LDescricao = '' then
        LDescricao := DescricaoPadrao(LCodCob);

      LObj := TJSONObject.Create;
      LObj.AddPair('id', TJSONNumber.Create(LQuery.FieldByName('id').AsInteger));
      LObj.AddPair('codcob', LCodCob);
      LObj.AddPair('descricao', LDescricao);
      LObj.AddPair('valor', TJSONNumber.Create(LQuery.FieldByName('valor').AsFloat));
      LArr.AddElement(LObj);
      LQuery.Next;
    end;
    LDados.AddPair('pagamentos', LArr);
  finally
    LQuery.Free;
  end;

  Result := CriarRespostaSucesso('OK', LDados);
end;

// =========================================================================
// PIX MANUAL (QR Code)
// =========================================================================

// Payload do PIX estatico no padrao BR Code (EMV-MPM) do Banco Central:
// campos TLV (id + tamanho em 2 digitos + valor) encerrados pelo CRC16.
// A chave vem de msfilial.chave_pix (espelhada em empresa.chave_pix);
// nome e cidade do recebedor saem do cadastro da propria filial.
function TApoloBridge.GerarPayloadPix(AValor: Double; out APayload, AChave,
  AErro: string): Boolean;

  // Nome/cidade entram no payload em ASCII puro (o CRC e calculado byte a
  // byte e apps de banco rejeitam acento fora de UTF-8 anunciado).
  // Mapeamento por codepoint para nao depender de literais acentuados.
  function MapAcento(ACh: Char): Char;
  begin
    case Ord(ACh) of
      $C0..$C5: Result := 'A';
      $C7:      Result := 'C';
      $C8..$CB: Result := 'E';
      $CC..$CF: Result := 'I';
      $D1:      Result := 'N';
      $D2..$D6: Result := 'O';
      $D9..$DC: Result := 'U';
      $E0..$E5: Result := 'a';
      $E7:      Result := 'c';
      $E8..$EB: Result := 'e';
      $EC..$EF: Result := 'i';
      $F1:      Result := 'n';
      $F2..$F6: Result := 'o';
      $F9..$FC: Result := 'u';
    else
      Result := ACh;
    end;
  end;

  function SemAcento(const S: string): string;
  var
    LCh, LMap: Char;
  begin
    Result := '';
    for LCh in S do
    begin
      LMap := MapAcento(LCh);
      if (Ord(LMap) >= 32) and (Ord(LMap) < 127) then
        Result := Result + LMap;
      // demais caracteres (controle/unicode) sao descartados
    end;
  end;

  function EMV(const AId, AConteudo: string): string;
  begin
    Result := AId + Format('%2.2d', [Length(AConteudo)]) + AConteudo;
  end;

  // CRC16-CCITT-FALSE (poly $1021, init $FFFF) - campo 63 do BR Code
  function CRC16Pix(const S: string): string;
  var
    LBytes: TBytes;
    LCrc: Word;
    I, J: Integer;
  begin
    LBytes := TEncoding.ASCII.GetBytes(S);
    LCrc := $FFFF;
    for I := 0 to High(LBytes) do
    begin
      LCrc := LCrc xor (Word(LBytes[I]) shl 8);
      for J := 1 to 8 do
        if (LCrc and $8000) <> 0 then
          LCrc := Word(LCrc shl 1) xor $1021
        else
          LCrc := Word(LCrc shl 1);
    end;
    Result := IntToHex(LCrc, 4);
  end;

var
  LQuery: TUniQuery;
  LNome, LCidade, LValorStr: string;
  LFmt: TFormatSettings;
begin
  Result := False;
  APayload := '';
  AChave := '';
  AErro := '';

  if AValor <= 0 then
  begin
    AErro := 'Valor invalido para o PIX';
    Exit;
  end;

  LQuery := FSQLite.ExecutarSelect(
    'SELECT chave_pix, fantasia, razao_social, cidade FROM empresa WHERE id = 1');
  try
    if LQuery.Eof then
    begin
      AErro := 'Cadastro da filial nao sincronizado';
      Exit;
    end;
    AChave := Trim(LQuery.FieldByName('chave_pix').AsString);
    LNome := Trim(LQuery.FieldByName('fantasia').AsString);
    if LNome = '' then
      LNome := Trim(LQuery.FieldByName('razao_social').AsString);
    LCidade := Trim(LQuery.FieldByName('cidade').AsString);
  finally
    LQuery.Free;
  end;

  if AChave = '' then
  begin
    AErro := 'Chave PIX nao configurada na filial (msfilial.chave_pix)';
    Exit;
  end;

  // Limites do BR Code: nome ate 25, cidade ate 15 caracteres
  LNome := Copy(Trim(SemAcento(UpperCase(LNome))), 1, 25);
  LCidade := Copy(Trim(SemAcento(UpperCase(LCidade))), 1, 15);
  if LNome = '' then LNome := 'LOJA';
  if LCidade = '' then LCidade := 'BRASIL';

  LFmt := TFormatSettings.Create;
  LFmt.DecimalSeparator := '.';
  LFmt.ThousandSeparator := #0;
  LValorStr := FormatFloat('0.00', AValor, LFmt);

  APayload :=
    EMV('00', '01') +                                        // payload format
    EMV('26', EMV('00', 'br.gov.bcb.pix') + EMV('01', AChave)) + // conta PIX
    EMV('52', '0000') +                                      // categoria
    EMV('53', '986') +                                       // moeda BRL
    EMV('54', LValorStr) +                                   // valor
    EMV('58', 'BR') +
    EMV('59', LNome) +
    EMV('60', LCidade) +
    EMV('62', EMV('05', '***'));                             // txid livre
  APayload := APayload + '6304' + CRC16Pix(APayload + '6304');

  Result := True;
end;

function TApoloBridge.DoObterPixQRCode(const AData: string): string;
var
  LJson: TJSONObject;
  LValor: Double;
  LPayload, LChave, LErro: string;
  LDados: TJSONObject;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LValor := LJson.GetValue<Double>('valor', 0);
    if not GerarPayloadPix(LValor, LPayload, LChave, LErro) then
      Exit(CriarRespostaErro(LErro));

    LDados := TJSONObject.Create;
    LDados.AddPair('payload', LPayload);
    LDados.AddPair('chave', LChave);
    LDados.AddPair('valor', TJSONNumber.Create(LValor));
    Result := CriarRespostaSucesso('OK', LDados);
  finally
    LJson.Free;
  end;
end;

// Imprime o QR Code do PIX na impressora termica (tag <qrcode> do
// ACBrPosPrinter). Nos modos PDF/texto nao ha como desenhar o QR - o
// operador apresenta o codigo pela tela.
function TApoloBridge.DoImprimirPixQRCode(const AData: string): string;
var
  LJson: TJSONObject;
  LValor: Double;
  LPayload, LChave, LErro: string;
  LTexto: TStringBuilder;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LValor := LJson.GetValue<Double>('valor', 0);

    // Cobranca dinamica manda o payload pronto (copia e cola do PSP);
    // sem payload, monta o BR Code estatico com a chave da filial
    LPayload := Trim(LJson.GetValue<string>('payload', ''));
    if LPayload <> '' then
      LChave := ''
    else if not GerarPayloadPix(LValor, LPayload, LChave, LErro) then
      Exit(CriarRespostaErro(LErro));

    if not (Assigned(DmApoloWeb) and DmApoloWeb.ImpressaoEscPos and
       (DmApoloWeb.PosPrinter <> nil)) then
      Exit(CriarRespostaErro(
        'Impressao do QR Code disponivel apenas com impressora ESCPOS'));

    LTexto := TStringBuilder.Create;
    try
      LTexto.AppendLine('</zera></ce>');
      LTexto.AppendLine('<n>PAGUE COM PIX</n>');
      LTexto.AppendLine('VALOR: R$ ' + FormatFloat('#,##0.00', LValor));
      LTexto.AppendLine('<qrcode_tipo>2</qrcode_tipo>' +
        '<qrcode_largura>5</qrcode_largura>' +
        '<qrcode_error>0</qrcode_error>');
      LTexto.AppendLine('<qrcode>' + LPayload + '</qrcode>');
      if LChave <> '' then
        LTexto.AppendLine('CHAVE: ' + LChave);
      LTexto.AppendLine('</corte_total>');

      DmApoloWeb.PosPrinter.Ativar;
      DmApoloWeb.PosPrinter.Imprimir(LTexto.ToString);
    finally
      LTexto.Free;
    end;

    Result := CriarRespostaSucesso('QR Code impresso');
  finally
    LJson.Free;
  end;
end;

// =========================================================================
// PIX DINAMICO (API Pix via ACBrPIXCD)
// =========================================================================

function TApoloBridge.ObterPixCDMgr: TPixCDManager;
begin
  if FPixCDMgr = nil then
    FPixCDMgr := TPixCDManager.Create(FSQLite);
  Result := FPixCDMgr;
end;

// Cria a cobranca imediata (cob) no PSP e devolve o payload do QR dinamico.
// Sem configuracao na pixcd_config retorna erro - o frontend entao cai no
// QR estatico com confirmacao manual.
function TApoloBridge.DoIniciarCobrancaPix(const AData: string): string;
var
  LJson: TJSONObject;
  LValor: Double;
  LTxId, LPayload, LErro: string;
  LDados: TJSONObject;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LValor := LJson.GetValue<Double>('valor', 0);

    if not ObterPixCDMgr.CriarCobranca(LValor, LTxId, LPayload, LErro) then
      Exit(CriarRespostaErro(LErro));

    LDados := TJSONObject.Create;
    LDados.AddPair('txid', LTxId);
    LDados.AddPair('payload', LPayload);
    LDados.AddPair('valor', TJSONNumber.Create(LValor));
    Result := CriarRespostaSucesso('OK', LDados);
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoConsultarCobrancaPix(const AData: string): string;
var
  LJson: TJSONObject;
  LTxId, LStatus, LE2E, LErro: string;
  LDados: TJSONObject;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LTxId := LJson.GetValue<string>('txid', '');

    if not ObterPixCDMgr.ConsultarCobranca(LTxId, LStatus, LE2E, LErro) then
      Exit(CriarRespostaErro(LErro));

    LDados := TJSONObject.Create;
    LDados.AddPair('txid', LTxId);
    LDados.AddPair('status', LStatus);
    LDados.AddPair('e2eid', LE2E);
    LDados.AddPair('pago', TJSONBool.Create(LStatus = 'CONCLUIDA'));
    Result := CriarRespostaSucesso('OK', LDados);
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoCancelarCobrancaPix(const AData: string): string;
var
  LJson: TJSONObject;
  LTxId, LErro: string;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LTxId := LJson.GetValue<string>('txid', '');

    if not ObterPixCDMgr.CancelarCobranca(LTxId, LErro) then
      Exit(CriarRespostaErro(LErro));

    Result := CriarRespostaSucesso('Cobranca cancelada');
  finally
    LJson.Free;
  end;
end;

// =========================================================================
// CAIXA
// =========================================================================

function TApoloBridge.DoAbrirCaixa(const AData: string): string;
var
  LJson: TJSONObject;
  LValorSuprimento: Double;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LValorSuprimento := LJson.GetValue<Double>('valorSuprimento', 0);

    // Sincronizar precos/dados antes de abrir o caixa
    if Assigned(FOnSincronizar) then
    begin
      try
        FOnSincronizar;
      except
        // Falha na sync nao impede abertura (pode estar offline)
      end;
    end;

    // Registrar suprimento inicial
    FSQLite.ExecutarSQL(
      'INSERT INTO numerario (tipo, valor, dthora, codoperador, motivo, codfilial, numcaixa) ' +
      'VALUES (''SUPRIMENTO'', :p0, datetime(''now'',''localtime''), :p1, ' +
      '''Suprimento de abertura'', :p2, :p3)',
      [LValorSuprimento, FMatriculaLogada,
       FSQLite.ObterEstado(KEY_CODFILIAL, ''),
       StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '1'), 1)]
    );

    FSQLite.SalvarEstado(KEY_TOTAL_DINHEIRO, FloatToStr(LValorSuprimento));

    FEstadoCaixa := ecLivre;
    FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));

    Result := CriarRespostaSucesso('Caixa aberto com sucesso');
  finally
    LJson.Free;
  end;
end;

// Fechamento do caixa (F10). Exige o controle 6 da rotina 8002; sem permissao
// o frontend pede matricula/senha de um autorizador.
function TApoloBridge.DoFecharCaixa(const AData: string): string;
var
  LJson, LDados: TJSONObject;
  LQuery: TUniQuery;
  LTotalVendas, LTotalSangrias, LTotalSuprimentos, LSaldoDinheiro: Double;
  LQtdVendas, LMatAutorizou: Integer;
  LErro, LDia, LFiltroOper: string;
begin
  if FEstadoCaixa <> ecLivre then
    Exit(CriarRespostaErro('Finalize a venda em andamento antes de fechar o caixa'));

  // A action pode chegar sem payload; segue com objeto vazio
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then
    LJson := TJSONObject.Create;
  try
    if not ValidarAutorizacao(CTRL_FECHAR_CAIXA, LJson, LMatAutorizou, LErro) then
    begin
      if LErro = '' then
        LErro := 'Operador sem permissao para fechar o caixa';
      Exit(CriarRespostaSemPermissao(LErro));
    end;
  finally
    LJson.Free;
  end;

  // Resumo do dia do operador logado: o acerto na retaguarda (ROT6030) e por
  // caixa + dia + operador, entao o fechamento mostra a mesma sessao.
  LDia := FormatDateTime('yyyy-mm-dd', Now);
  LFiltroOper := ' AND COALESCE(codoperador, 0) = ' + IntToStr(FMatriculaLogada);
  LQuery := FSQLite.ExecutarSelect(
    'SELECT COUNT(*) as qtd, COALESCE(SUM(valorvenda - valordesc + valorencargo), 0) as total ' +
    'FROM cupons WHERE codoper = ''V'' AND datamovto = ''' + LDia + '''' + LFiltroOper
  );
  try
    LQtdVendas := LQuery.FieldByName('qtd').AsInteger;
    LTotalVendas := LQuery.FieldByName('total').AsFloat;
  finally
    LQuery.Free;
  end;

  LTotalSangrias := VarToFloatDef(FSQLite.ExecutarScalar(
    'SELECT COALESCE(SUM(valor), 0) FROM numerario WHERE tipo = ''SANGRIA'' AND ' +
    'DATE(dthora) = ''' + LDia + '''' + LFiltroOper), 0);

  LTotalSuprimentos := VarToFloatDef(FSQLite.ExecutarScalar(
    'SELECT COALESCE(SUM(valor), 0) FROM numerario WHERE tipo = ''SUPRIMENTO'' AND ' +
    'DATE(dthora) = ''' + LDia + '''' + LFiltroOper), 0);

  LSaldoDinheiro := DinheiroEmCaixaOperador(LDia, FMatriculaLogada);

  FEstadoCaixa := ecFechado;
  FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));
  FSQLite.SalvarEstado(KEY_DT_FECHAMENTO, FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));

  // Emitir o resumo impresso; falha na impressora nao invalida o fechamento
  try
    ImprimirResumoFechamento;
  except
  end;

  LDados := TJSONObject.Create;
  LDados.AddPair('qtdVendas', TJSONNumber.Create(LQtdVendas));
  LDados.AddPair('totalVendas', TJSONNumber.Create(LTotalVendas));
  LDados.AddPair('totalSangrias', TJSONNumber.Create(LTotalSangrias));
  LDados.AddPair('totalSuprimentos', TJSONNumber.Create(LTotalSuprimentos));
  LDados.AddPair('saldoDinheiro', TJSONNumber.Create(LSaldoDinheiro));

  Result := CriarRespostaSucesso('Caixa fechado', LDados);
end;

// Dinheiro que o operador deve ter no caixa no dia: recebido em dinheiro
// (codcob 01) menos troco, mais suprimentos, menos sangrias. E' o "calculado"
// do meio D que a ROT6030 confere na sessao caixa + dia + operador.
function TApoloBridge.DinheiroEmCaixaOperador(const ADia: string;
  AMatricula: Integer): Double;
var
  LFiltro: string;
begin
  LFiltro := ' AND COALESCE(codoperador, 0) = ' + IntToStr(AMatricula);
  Result :=
    VarToFloatDef(FSQLite.ExecutarScalar(
      'SELECT COALESCE(SUM(p.valor), 0) FROM cupom_pagamentos p ' +
      'JOIN cupons c ON c.id = p.cupom_id ' +
      'WHERE p.codcob = ''01'' AND c.codoper = ''V'' AND c.datamovto = ''' + ADia + ''' ' +
      'AND COALESCE(c.codoperador, 0) = ' + IntToStr(AMatricula)), 0)
    - VarToFloatDef(FSQLite.ExecutarScalar(
      'SELECT COALESCE(SUM(valortroco), 0) FROM cupons ' +
      'WHERE codoper = ''V'' AND datamovto = ''' + ADia + '''' + LFiltro), 0)
    + VarToFloatDef(FSQLite.ExecutarScalar(
      'SELECT COALESCE(SUM(valor), 0) FROM numerario WHERE tipo = ''SUPRIMENTO'' ' +
      'AND DATE(dthora) = ''' + ADia + '''' + LFiltro), 0)
    - VarToFloatDef(FSQLite.ExecutarScalar(
      'SELECT COALESCE(SUM(valor), 0) FROM numerario WHERE tipo = ''SANGRIA'' ' +
      'AND DATE(dthora) = ''' + ADia + '''' + LFiltro), 0);
end;

// Resumo de UM operador no dia: totais, cancelamentos e recebimentos por
// forma de pagamento. Mesma chave do acerto na retaguarda (ROT6030):
// caixa + dia + operador.
function TApoloBridge.MontarResumoOperador(const ADia: string;
  AMatricula: Integer): string;
const
  LARGURA = 40;
var
  LTexto: TStringBuilder;
  LQuery: TUniQuery;
  LFiltro, LNome: string;
  LQtdVendas: Integer;
  LTotalVendas, LTroco, LCancelCupom, LCancelItens, LSangrias, LSuprimentos,
  LTotalRecebido, LValor: Double;

  function Centralizar(const ATexto: string): string;
  begin
    if Length(ATexto) >= LARGURA then
      Result := ATexto
    else
      Result := StringOfChar(' ', (LARGURA - Length(ATexto)) div 2) + ATexto;
  end;

  function LinhaValor(const ALabel, AValor: string): string;
  begin
    Result := Copy(ALabel + StringOfChar('.', 22), 1, 22) + ':' +
      Format('%*s', [LARGURA - 23, AValor]);
  end;

  function LinhaMoeda(const ALabel: string; AValor: Double): string;
  begin
    Result := LinhaValor(ALabel, FormatFloat('#,##0.00', AValor));
  end;

begin
  LFiltro := ' AND COALESCE(codoperador, 0) = ' + IntToStr(AMatricula);
  LTexto := TStringBuilder.Create;
  try
    // Cabecalho da empresa
    LQuery := FSQLite.ExecutarSelect('SELECT razao_social, cnpj FROM empresa WHERE id = 1');
    try
      if not LQuery.Eof then
      begin
        LTexto.AppendLine(Centralizar(Trim(LQuery.FieldByName('razao_social').AsString)));
        LTexto.AppendLine(Centralizar('CNPJ: ' + Trim(LQuery.FieldByName('cnpj').AsString)));
      end;
    finally
      LQuery.Free;
    end;

    if AMatricula = FMatriculaLogada then
      LNome := FNomeOperador
    else
      LNome := VarToStr(FSQLite.ExecutarScalar(
        'SELECT nome FROM funcionarios WHERE matricula = ' + IntToStr(AMatricula)));

    LTexto.AppendLine(StringOfChar('=', LARGURA));
    LTexto.AppendLine(Centralizar('RESUMO DE FECHAMENTO DE CAIXA'));
    LTexto.AppendLine('MOVIMENTO: ' + Copy(ADia, 9, 2) + '/' + Copy(ADia, 6, 2) + '/' +
      Copy(ADia, 1, 4) + '  IMPRESSO: ' + FormatDateTime('hh:nn:ss', Now));
    LTexto.AppendLine('MAQUINA: CAIXA-' +
      Format('%2.2d', [StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '1'), 1)]));
    LTexto.AppendLine('OPERADOR: ' + IntToStr(AMatricula) + ' - ' + Trim(LNome));
    LTexto.AppendLine(StringOfChar('=', LARGURA));

    // Totais do dia (mesma formula do fechamento: valorvenda - valordesc + valorencargo)
    LQuery := FSQLite.ExecutarSelect(
      'SELECT COUNT(*) as qtd, ' +
      'COALESCE(SUM(valorvenda - valordesc + valorencargo), 0) as total, ' +
      'COALESCE(SUM(valortroco), 0) as troco ' +
      'FROM cupons WHERE codoper = ''V'' AND datamovto = ''' + ADia + '''' + LFiltro
    );
    try
      LQtdVendas := LQuery.FieldByName('qtd').AsInteger;
      LTotalVendas := LQuery.FieldByName('total').AsFloat;
      LTroco := LQuery.FieldByName('troco').AsFloat;
    finally
      LQuery.Free;
    end;

    LCancelCupom := VarToFloatDef(FSQLite.ExecutarScalar(
      'SELECT COALESCE(SUM(valorvenda - valordesc + valorencargo), 0) FROM cupons ' +
      'WHERE codoper = ''C'' AND datamovto = ''' + ADia + '''' + LFiltro), 0);

    LCancelItens := VarToFloatDef(FSQLite.ExecutarScalar(
      'SELECT COALESCE(SUM(valorcancel), 0) FROM cupons ' +
      'WHERE datamovto = ''' + ADia + '''' + LFiltro), 0);

    LSangrias := VarToFloatDef(FSQLite.ExecutarScalar(
      'SELECT COALESCE(SUM(valor), 0) FROM numerario WHERE tipo = ''SANGRIA'' AND ' +
      'DATE(dthora) = ''' + ADia + '''' + LFiltro), 0);

    LSuprimentos := VarToFloatDef(FSQLite.ExecutarScalar(
      'SELECT COALESCE(SUM(valor), 0) FROM numerario WHERE tipo = ''SUPRIMENTO'' AND ' +
      'DATE(dthora) = ''' + ADia + '''' + LFiltro), 0);

    LTexto.AppendLine(LinhaValor('QTDE VENDAS', IntToStr(LQtdVendas)));
    LTexto.AppendLine(LinhaMoeda('TOTAL VENDAS', LTotalVendas));
    LTexto.AppendLine(LinhaMoeda('CANCEL CUPOM', LCancelCupom));
    LTexto.AppendLine(LinhaMoeda('CANCEL ITENS', LCancelItens));
    LTexto.AppendLine(LinhaMoeda('SUPRIMENTOS', LSuprimentos));
    LTexto.AppendLine(LinhaMoeda('SANGRIAS', LSangrias));

    // Recebimentos por forma de pagamento
    LTexto.AppendLine(Centralizar('***** FORMAS DE PAGAMENTO *****'));
    LTotalRecebido := 0;
    LQuery := FSQLite.ExecutarSelect(
      'SELECT COALESCE(NULLIF(TRIM(cad.descricao), ''''), ' +
      '  NULLIF(TRIM(mp.descricao), ''''), ''COBRANCA '' || p.codcob) as descricao, ' +
      'SUM(p.valor) as total ' +
      'FROM cupom_pagamentos p ' +
      'JOIN cupons c ON c.id = p.cupom_id ' +
      'LEFT JOIN meiopagto cad ON cad.codcob = p.codcob ' +
      'LEFT JOIN meios_pagamento mp ON mp.codcob = p.codcob ' +
      'WHERE c.codoper = ''V'' AND c.datamovto = ''' + ADia + ''' ' +
      'AND COALESCE(c.codoperador, 0) = ' + IntToStr(AMatricula) + ' ' +
      'GROUP BY p.codcob ORDER BY p.codcob'
    );
    try
      while not LQuery.Eof do
      begin
        LValor := LQuery.FieldByName('total').AsFloat;
        LTotalRecebido := LTotalRecebido + LValor;
        LTexto.AppendLine(LinhaMoeda(
          UpperCase(Trim(LQuery.FieldByName('descricao').AsString)), LValor));
        LQuery.Next;
      end;
    finally
      LQuery.Free;
    end;

    if LTroco > 0 then
      LTexto.AppendLine(LinhaMoeda('(-) TROCO', LTroco));
    LTexto.AppendLine(StringOfChar('-', LARGURA));
    LTexto.AppendLine(LinhaMoeda('TOTAL RECEBIDO', LTotalRecebido - LTroco));
    LTexto.AppendLine(LinhaMoeda('DINHEIRO EM CAIXA', DinheiroEmCaixaOperador(ADia, AMatricula)));
    LTexto.AppendLine(StringOfChar('=', LARGURA));
    LTexto.AppendLine('');
    LTexto.AppendLine('');
    LTexto.AppendLine('ASSINATURA: ' + StringOfChar('_', LARGURA - 12));
    LTexto.AppendLine(StringOfChar('=', LARGURA));
    Result := LTexto.ToString;
  finally
    LTexto.Free;
  end;
end;

// Resumo impresso do fechamento de caixa: UM resumo por operador que teve
// movimento no dia neste caixa (o logado primeiro) -- a mesma sessao que a
// ROT6030 acerta (caixa + dia + operador). Com [impressao] modo=ESCPOS sai na
// termica via ACBrPosPrinter, com corte entre os operadores; senao vai como
// texto cru para a impressora padrao (mesmo caminho dos comprovantes TEF).
procedure TApoloBridge.ImprimirResumoFechamento;
var
  LQuery: TUniQuery;
  LDia, LArquivo: string;
  LOperadores: TList<Integer>;
  LResumos: TStringBuilder;
  LEscPos: Boolean;
  I, LMat: Integer;
begin
  LDia := FormatDateTime('yyyy-mm-dd', Now);
  LEscPos := Assigned(DmApoloWeb) and DmApoloWeb.ImpressaoEscPos and
    (DmApoloWeb.PosPrinter <> nil);

  LOperadores := TList<Integer>.Create;
  LResumos := TStringBuilder.Create;
  try
    LOperadores.Add(FMatriculaLogada);
    LQuery := FSQLite.ExecutarSelect(
      'SELECT COALESCE(codoperador, 0) as mat FROM cupons WHERE datamovto = ''' + LDia + ''' ' +
      'UNION SELECT COALESCE(codoperador, 0) FROM numerario WHERE DATE(dthora) = ''' + LDia + ''' ' +
      'ORDER BY 1');
    try
      while not LQuery.Eof do
      begin
        LMat := LQuery.FieldByName('mat').AsInteger;
        if not LOperadores.Contains(LMat) then
          LOperadores.Add(LMat);
        LQuery.Next;
      end;
    finally
      LQuery.Free;
    end;

    for I := 0 to LOperadores.Count - 1 do
    begin
      if LEscPos then
        LResumos.Append('</zera>' + sLineBreak + MontarResumoOperador(LDia, LOperadores[I]) +
          '</corte_total>')
      else
        LResumos.Append(MontarResumoOperador(LDia, LOperadores[I]) +
          sLineBreak + sLineBreak + sLineBreak);
    end;

    if LEscPos then
    begin
      DmApoloWeb.PosPrinter.Ativar;
      DmApoloWeb.PosPrinter.Imprimir(LResumos.ToString);
    end
    else
    begin
      LArquivo := 'c:\apolo\resumo_fechamento.txt';
      TFile.WriteAllText(LArquivo, LResumos.ToString, TEncoding.ANSI);
      RawPrintToPrinter(Printer.Printers[Printer.PrinterIndex], LArquivo);
    end;
  finally
    LResumos.Free;
    LOperadores.Free;
  end;
end;

// Monta as DUAS vias do comprovante de numerario (sangria/suprimento): 1a
// caixa, 2a cofre, cada uma com cabecalho da empresa e espaco para assinatura.
// O texto vai para o preview na tela e depois volta em DoImprimirComprovante.
function TApoloBridge.MontarViasComprovante(const ATitulo, ARotuloValor: string;
  AValor: Double; const AMotivo: string; ACodSupervisor: Integer): TArray<string>;
const
  LARGURA = 40;
  ROTULO_VIA: array[0..1] of string = ('1a VIA - CAIXA', '2a VIA - COFRE');
var
  LQuery: TUniQuery;
  LNomeSupervisor, LCabecalho: string;
  LVia: Integer;

  function Centralizar(const ATexto: string): string;
  begin
    if Length(ATexto) >= LARGURA then
      Result := ATexto
    else
      Result := StringOfChar(' ', (LARGURA - Length(ATexto)) div 2) + ATexto;
  end;

  function MontarVia(const ARotulo: string): string;
  var
    LTexto: TStringBuilder;
  begin
    LTexto := TStringBuilder.Create;
    try
      if LCabecalho <> '' then
        LTexto.Append(LCabecalho);
      LTexto.AppendLine(StringOfChar('=', LARGURA));
      LTexto.AppendLine(Centralizar(ATitulo));
      LTexto.AppendLine(Centralizar(ARotulo));
      LTexto.AppendLine(StringOfChar('=', LARGURA));
      LTexto.AppendLine('DATA: ' + FormatDateTime('dd/mm/yyyy', Now) +
        '  HORA: ' + FormatDateTime('hh:nn:ss', Now));
      LTexto.AppendLine('MAQUINA: CAIXA-' +
        Format('%2.2d', [StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '1'), 1)]));
      LTexto.AppendLine('OPERADOR: ' + IntToStr(FMatriculaLogada) + ' - ' + FNomeOperador);
      if ACodSupervisor <> 0 then
        LTexto.AppendLine('AUTORIZOU: ' + IntToStr(ACodSupervisor) + ' - ' + LNomeSupervisor);
      LTexto.AppendLine('MOTIVO: ' + AMotivo);
      LTexto.AppendLine(StringOfChar('-', LARGURA));
      LTexto.AppendLine(ARotuloValor + ': R$ ' + FormatFloat('#,##0.00', AValor));
      LTexto.AppendLine(StringOfChar('-', LARGURA));
      LTexto.AppendLine('');
      LTexto.AppendLine('');
      LTexto.AppendLine('ASSINATURA: ' + StringOfChar('_', LARGURA - 12));
      LTexto.AppendLine(StringOfChar('=', LARGURA));
      Result := LTexto.ToString;
    finally
      LTexto.Free;
    end;
  end;

begin
  LCabecalho := '';
  LQuery := FSQLite.ExecutarSelect('SELECT razao_social, cnpj FROM empresa WHERE id = 1');
  try
    if not LQuery.Eof then
      LCabecalho :=
        Centralizar(Trim(LQuery.FieldByName('razao_social').AsString)) + sLineBreak +
        Centralizar('CNPJ: ' + Trim(LQuery.FieldByName('cnpj').AsString)) + sLineBreak;
  finally
    LQuery.Free;
  end;

  LNomeSupervisor := '';
  if ACodSupervisor <> 0 then
    LNomeSupervisor := VarToStr(FSQLite.ExecutarScalar(
      'SELECT nome FROM funcionarios WHERE matricula = ' + IntToStr(ACodSupervisor)));

  SetLength(Result, 2);
  for LVia := 0 to 1 do
    Result[LVia] := MontarVia(ROTULO_VIA[LVia]);
end;

// Imprime um bloco de texto pelo caminho do cupom: ESCPOS na termica (com
// corte no fim) ou texto cru na impressora do cupom. Retorna '' quando saiu.
function TApoloBridge.ImprimirTextoCupom(const ATexto: string): string;
var
  LImpressora: string;
begin
  Result := '';
  if Assigned(DmApoloWeb) and DmApoloWeb.ImpressaoEscPos and
     (DmApoloWeb.PosPrinter <> nil) then
  begin
    try
      DmApoloWeb.PosPrinter.Ativar;
      DmApoloWeb.PosPrinter.Imprimir('</zera>' + sLineBreak +
        ATexto + '</corte_total>');
    except
      on E: Exception do
        Result := E.Message;
    end;
  end
  else
  begin
    if Assigned(DmApoloWeb) then
      LImpressora := DmApoloWeb.ImpressoraCupom
    else
      LImpressora := '';
    Result := ImprimirTexto(
      ATexto + sLineBreak + sLineBreak + sLineBreak, LImpressora);
  end;
end;

// Imprime as vias que o frontend confirmou no preview (sangria/suprimento).
// Cada via e um job proprio - em ESCPOS a guilhotina corta entre elas.
function TApoloBridge.DoImprimirComprovante(const AData: string): string;
var
  LJson: TJSONObject;
  LVias: TJSONArray;
  LErro: string;
  I: Integer;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LVias := LJson.GetValue('vias') as TJSONArray;
    if (LVias = nil) or (LVias.Count = 0) then
      Exit(CriarRespostaErro('Nenhuma via para imprimir'));

    for I := 0 to LVias.Count - 1 do
    begin
      LErro := ImprimirTextoCupom(LVias.Items[I].Value);
      // Impressora falhou: nao adianta insistir nas vias seguintes
      if LErro <> '' then
        Exit(CriarRespostaErro('Falha ao imprimir comprovante: ' + LErro));
    end;

    Result := CriarRespostaSucesso('Comprovante impresso');
  finally
    LJson.Free;
  end;
end;

// Sangria (retirada de dinheiro do caixa). Exige o controle 18 da rotina 8002;
// sem permissao o frontend pede matricula/senha de um autorizador, que fica
// gravado em numerario.codsupervisor (sobe para msapolo_numerario).
function TApoloBridge.DoEfetuarSangria(const AData: string): string;
var
  LJson, LDados: TJSONObject;
  LArrVias: TJSONArray;
  LValor: Double;
  LMotivo, LErro, LVia: string;
  LSaldoAtual: Double;
  LMatAutorizou, LCodSupervisor: Integer;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    if not ValidarAutorizacao(CTRL_SANGRIA, LJson, LMatAutorizou, LErro) then
    begin
      if LErro = '' then
        LErro := 'Operador sem permissao para efetuar sangria';
      Exit(CriarRespostaSemPermissao(LErro));
    end;

    LValor := LJson.GetValue<Double>('valor', 0);
    LMotivo := LJson.GetValue<string>('motivo', 'Sangria');

    if LValor <= 0 then
      Exit(CriarRespostaErro('Valor invalido'));

    LSaldoAtual := StrToFloatDef(FSQLite.ObterEstado(KEY_TOTAL_DINHEIRO, '0'), 0);
    if LValor > LSaldoAtual then
      Exit(CriarRespostaErro('Valor da sangria maior que o saldo em caixa'));

    if LMatAutorizou <> FMatriculaLogada then
      LCodSupervisor := LMatAutorizou
    else
      LCodSupervisor := 0;

    FSQLite.ExecutarSQL(
      'INSERT INTO numerario (tipo, valor, dthora, codoperador, motivo, codfilial, numcaixa, codsupervisor) ' +
      'VALUES (''SANGRIA'', :p0, datetime(''now'',''localtime''), :p1, :p2, :p3, :p4, :p5)',
      [LValor, FMatriculaLogada, LMotivo,
       FSQLite.ObterEstado(KEY_CODFILIAL, ''),
       StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '1'), 1),
       LCodSupervisor]
    );

    FSQLite.SalvarEstado(KEY_TOTAL_DINHEIRO, FloatToStr(LSaldoAtual - LValor));

    // As vias vao para o preview na tela; a impressao so acontece quando o
    // operador confirmar (action imprimirComprovante)
    LDados := TJSONObject.Create;
    LArrVias := TJSONArray.Create;
    for LVia in MontarViasComprovante('COMPROVANTE DE SANGRIA', 'VALOR RETIRADO',
        LValor, LMotivo, LCodSupervisor) do
      LArrVias.Add(LVia);
    LDados.AddPair('vias', LArrVias);

    Result := CriarRespostaSucesso('Sangria realizada: R$ ' +
      FormatFloat('#,##0.00', LValor), LDados);
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoEfetuarSuprimento(const AData: string): string;
var
  LJson, LDados: TJSONObject;
  LArrVias: TJSONArray;
  LValor: Double;
  LSaldoAtual: Double;
  LVia: string;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LValor := LJson.GetValue<Double>('valor', 0);

    if LValor <= 0 then
      Exit(CriarRespostaErro('Valor invalido'));

    FSQLite.ExecutarSQL(
      'INSERT INTO numerario (tipo, valor, dthora, codoperador, motivo, codfilial, numcaixa) ' +
      'VALUES (''SUPRIMENTO'', :p0, datetime(''now'',''localtime''), :p1, ''Suprimento'', :p2, :p3)',
      [LValor, FMatriculaLogada,
       FSQLite.ObterEstado(KEY_CODFILIAL, ''),
       StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '1'), 1)]
    );

    LSaldoAtual := StrToFloatDef(FSQLite.ObterEstado(KEY_TOTAL_DINHEIRO, '0'), 0);
    FSQLite.SalvarEstado(KEY_TOTAL_DINHEIRO, FloatToStr(LSaldoAtual + LValor));

    // As vias vao para o preview na tela; a impressao so acontece quando o
    // operador confirmar (action imprimirComprovante)
    LDados := TJSONObject.Create;
    LArrVias := TJSONArray.Create;
    for LVia in MontarViasComprovante('COMPROVANTE DE SUPRIMENTO', 'VALOR SUPRIDO',
        LValor, 'Suprimento', 0) do
      LArrVias.Add(LVia);
    LDados.AddPair('vias', LArrVias);

    Result := CriarRespostaSucesso('Suprimento realizado: R$ ' +
      FormatFloat('#,##0.00', LValor), LDados);
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoObterEstadoCaixa(const AData: string): string;
var
  LDados: TJSONObject;
  LNumCupom: Variant;
begin
  LDados := TJSONObject.Create;
  LDados.AddPair('estado', TJSONNumber.Create(Ord(FEstadoCaixa)));
  LDados.AddPair('estadoTexto', TEstadoCaixa(FEstadoCaixa).ToString);
  LDados.AddPair('numCaixa', FSQLite.ObterEstado(KEY_NUMCAIXA, '0'));
  LDados.AddPair('operador', FNomeOperador);
  LDados.AddPair('matricula', TJSONNumber.Create(FMatriculaLogada));
  LDados.AddPair('saldoDinheiro', TJSONNumber.Create(
    StrToFloatDef(FSQLite.ObterEstado(KEY_TOTAL_DINHEIRO, '0'), 0)));
  LDados.AddPair('contingencia', ContingenciaAtual.ToString);
  LDados.AddPair('cupomAtualId', TJSONNumber.Create(FCupomAtualId));

  // Incluir numCupom da venda em andamento
  if FCupomAtualId > 0 then
  begin
    LNumCupom := FSQLite.ExecutarScalar(
      'SELECT numcupom FROM cupons WHERE id = ' + IntToStr(FCupomAtualId)
    );
    if not VarIsNull(LNumCupom) then
      LDados.AddPair('numCupom', TJSONNumber.Create(Integer(LNumCupom)))
    else
      LDados.AddPair('numCupom', TJSONNumber.Create(0));
  end;

  Result := CriarRespostaSucesso('OK', LDados);
end;

// =========================================================================
// NFCE
// =========================================================================

function TApoloBridge.DoGerarNFCe(const AData: string): string;
var
  LJson: TJSONObject;
  LQuery: TUniQuery;
  LCupomId: Integer;
  LNumNota, LSerieNFCe: Integer;
  LDados: TJSONObject;
  LChaveNFe, LProtocolo: string;
  LManual: Boolean;
begin
  LManual := False;
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then
    LCupomId := FCupomAtualId
  else
  begin
    try
      LCupomId := LJson.GetValue<Integer>('cupomId', FCupomAtualId);
      LManual := LJson.GetValue<Boolean>('manual', False);
    finally
      LJson.Free;
    end;
  end;

  if LCupomId = 0 then
    Exit(CriarRespostaErro('Nenhum cupom informado para gerar NFCe'));

  // So' cupom FECHADO e ainda sem nota entra aqui. Cada chamada consome um
  // numero de NFCe, entao um clique repetido (ou um cupom que ja' caiu em
  // contingencia e tem a chave gravada) nao pode gerar uma segunda nota.
  LQuery := FSQLite.ExecutarSelect(
    'SELECT codoper, cancelada, chavenfe, dthrfimvenda FROM cupons WHERE id = ' +
    IntToStr(LCupomId));
  try
    if LQuery.Eof then
      Exit(CriarRespostaErro('Cupom nao encontrado'));
    if (LQuery.FieldByName('codoper').AsString <> 'V') or
       (Trim(LQuery.FieldByName('dthrfimvenda').AsString) = '') then
      Exit(CriarRespostaErro('Cupom nao esta fechado - nao gera NFCe'));
    if LQuery.FieldByName('cancelada').AsInteger = 1 then
      Exit(CriarRespostaErro('Cupom cancelado - nao gera NFCe'));
    if Trim(LQuery.FieldByName('chavenfe').AsString) <> '' then
      Exit(CriarRespostaErro('Cupom ja tem NFCe emitida - use Reimprimir'));
  finally
    LQuery.Free;
  end;

  if LManual then
    SyncLog('NFCe: emissao manual do cupom %d (venda fechada sem nota) ' +
      'pela tela Documentos Fiscais (matricula %d)', [LCupomId, FMatriculaLogada]);

  if Assigned(FOnGerarNFCe) then
  begin
    try
      // Atribuir proximo numero de nota e serie ao cupom antes de gerar
      LNumNota := StrToIntDef(FSQLite.ObterEstado(KEY_PROX_NUM_NOTA, '1'), 1);
      LSerieNFCe := StrToIntDef(FSQLite.ObterEstado(KEY_SERIE_NFCE, '1'), 1);
      FSQLite.ExecutarSQL(
        'UPDATE cupons SET numnota = :p0, serienfce = :p1 WHERE id = :p2',
        [LNumNota, LSerieNFCe, LCupomId]
      );

      // Incrementar proximo numero (consumido independente do resultado)
      FSQLite.SalvarEstado(KEY_PROX_NUM_NOTA, IntToStr(LNumNota + 1));

      FOnGerarNFCe(LCupomId, LChaveNFe, LProtocolo);

      // Atualizar cupom com chave e protocolo, sem apagar o que ja esta la:
      // em contingencia o EnviarNFCe grava a chave e volta sem protocolo, e um
      // UPDATE incondicional zerava a chave de quem tinha acabado de grava-la.
      // Cupom sem chavenfe nao vincula o XML na retaguarda.
      if LChaveNFe <> '' then
        FSQLite.ExecutarSQL(
          'UPDATE cupons SET chavenfe = :p0 WHERE id = :p1',
          [LChaveNFe, LCupomId]
        );
      if LProtocolo <> '' then
        FSQLite.ExecutarSQL(
          'UPDATE cupons SET protocolo_nfe = :p0 WHERE id = :p1',
          [LProtocolo, LCupomId]
        );

      // Imprimir comprovantes TEF vinculados ao cupom
      ImprimirComprovantesTEF(LCupomId);

      LDados := TJSONObject.Create;
      LDados.AddPair('cupomId', TJSONNumber.Create(LCupomId));
      LDados.AddPair('chaveNFe', LChaveNFe);
      LDados.AddPair('protocolo', LProtocolo);
      LDados.AddPair('status', 'AUTORIZADA');

      Result := CriarRespostaSucesso('NFCe gerada com sucesso', LDados);
    except
      on E: Exception do
      begin
        // Persistir o motivo: o toast do front some em segundos e o erro
        // real fica irrastreavel (cupom sem chavenfe e sem XML)
        SyncLog('NFCe: erro ao gerar (cupom %d): [%s] %s',
          [LCupomId, E.ClassName, E.Message]);

        // Se falhou e estamos em contingencia, registrar como pendente
        if ContingenciaAtual <> tcNenhuma then
        begin
          LDados := TJSONObject.Create;
          LDados.AddPair('cupomId', TJSONNumber.Create(LCupomId));
          LDados.AddPair('status', 'CONTINGENCIA');
          LDados.AddPair('mensagem', 'NFCe salva em contingencia: ' + E.Message);
          Result := CriarRespostaSucesso('NFCe registrada em contingencia', LDados);
        end
        else
          Result := CriarRespostaErro('Erro ao gerar NFCe: ' + E.Message);
      end;
    end;
  end
  else
    Result := CriarRespostaErro('Modulo NFCe nao configurado. Verifique a integracao com ACBr.');
end;

function TApoloBridge.DoListarNFCePendentes(const AData: string): string;
var
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT nc.id, nc.tipo_contingencia, nc.chave_nfe, nc.numnota, ' +
    // A rejeicao do SEFAZ e gravada em motivo_rejeicao (AtualizarStatusDoc);
    // ultimo_erro so recebe falha de comunicacao (IncrementarTentativa). Lendo
    // so o segundo, a coluna Erro da tela ficava VAZIA justamente nas linhas
    // REJEITADO - o operador via o status e nenhum motivo.
    'nc.dt_geracao, nc.status, nc.tentativas, ' +
    'COALESCE(NULLIF(TRIM(nc.motivo_rejeicao), ''''), nc.ultimo_erro, '''') ' +
    '  AS ultimo_erro, ' +
    'c.valorvenda, c.numcupom ' +
    'FROM nfce_contingencia nc ' +
    'LEFT JOIN cupons c ON nc.cupom_id = c.id ' +
    'WHERE nc.status IN (''PENDENTE'', ''REJEITADO'') ' +
    'ORDER BY nc.dt_geracao DESC'
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('id', TJSONNumber.Create(LQuery.FieldByName('id').AsInteger));
      LObj.AddPair('tipoContingencia', LQuery.FieldByName('tipo_contingencia').AsString);
      LObj.AddPair('chaveNFe', LQuery.FieldByName('chave_nfe').AsString);
      LObj.AddPair('numNota', TJSONNumber.Create(LQuery.FieldByName('numnota').AsInteger));
      LObj.AddPair('numCupom', TJSONNumber.Create(LQuery.FieldByName('numcupom').AsInteger));
      LObj.AddPair('dtGeracao', LQuery.FieldByName('dt_geracao').AsString);
      LObj.AddPair('status', LQuery.FieldByName('status').AsString);
      LObj.AddPair('tentativas', TJSONNumber.Create(LQuery.FieldByName('tentativas').AsInteger));
      LObj.AddPair('ultimoErro', LQuery.FieldByName('ultimo_erro').AsString);
      LObj.AddPair('valorVenda', TJSONNumber.Create(LQuery.FieldByName('valorvenda').AsFloat));
      LArr.AddElement(LObj);
      LQuery.Next;
    end;
    Result := CriarRespostaSucesso('OK', LArr);
  finally
    LQuery.Free;
  end;
end;


{ Descarte manual dos rejeitados da fila de NFCe.

  O front so' deixa marcar linha REJEITADO, mas quem garante e' o
  DescartarDocs: PENDENTE ainda tem envio a fazer e nao pode sumir por um id
  errado vindo do JS. Nada e' enviado a SEFAZ aqui - documento rejeitado nunca
  foi autorizado, entao nao existe cancelamento; o registro fica no banco com
  status DESCARTADO, a data e a matricula de quem tirou. }
function TApoloBridge.DoDescartarNFCePendentes(const AData: string): string;
var
  LJson: TJSONObject;
  LIdsJson: TJSONValue;
  LArr: TJSONArray;
  LIds: TArray<Integer>;
  LDados: TJSONObject;
  LQtd, I: Integer;
begin
  if FContingenciaMgr = nil then
    Exit(CriarRespostaErro('Modulo de contingencia nao configurado.'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then
    Exit(CriarRespostaErro('Dados invalidos'));

  try
    LIdsJson := LJson.GetValue('ids');
    if not (LIdsJson is TJSONArray) then
      Exit(CriarRespostaErro('Nenhum documento selecionado'));

    LArr := LIdsJson as TJSONArray;
    SetLength(LIds, LArr.Count);
    for I := 0 to LArr.Count - 1 do
      LIds[I] := StrToIntDef(LArr.Items[I].Value, 0);

    LQtd := FContingenciaMgr.DescartarDocs(LIds, FMatriculaLogada);
  finally
    LJson.Free;
  end;

  if LQtd = 0 then
    Exit(CriarRespostaErro('Nenhum documento removido. So documento ' +
      'REJEITADO pode sair da fila; PENDENTE ainda tem envio a fazer.'));

  SyncLog('NFCe: %d documento(s) descartado(s) da fila (matricula %d)',
    [LQtd, FMatriculaLogada]);

  LDados := TJSONObject.Create;
  LDados.AddPair('descartados', TJSONNumber.Create(LQtd));
  Result := CriarRespostaSucesso(
    IntToStr(LQtd) + ' documento(s) removido(s) da fila', LDados);
end;
{ Regeracao dos documentos REJEITADOS marcados na tela.

  Retransmitir reenvia o XML original: resolve rejeicao por comunicacao, nao
  rejeicao de CONTEUDO. Uma nota que saiu com o total errado e reenviada mil
  vezes recebe mil vezes a mesma negativa. Aqui a nota e montada de novo do
  cupom, com o mesmo numero e chave nova - quem decide o que pode ou nao ser
  regerado (duplicidade nao pode) e o TNFCeWebManager.RegerarDoc. }
function TApoloBridge.DoRegerarNFCeRejeitadas(const AData: string): string;
var
  LJson: TJSONObject;
  LIdsJson: TJSONValue;
  LArr: TJSONArray;
  LIds: TArray<Integer>;
  LDados: TJSONObject;
  LQtdOk, LQtdErro, I: Integer;
  LMensagem: string;
begin
  if not Assigned(FOnRegerarNFCe) then
    Exit(CriarRespostaErro('Modulo NFCe nao inicializado.'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then
    Exit(CriarRespostaErro('Dados invalidos'));

  try
    LIdsJson := LJson.GetValue('ids');
    if not (LIdsJson is TJSONArray) then
      Exit(CriarRespostaErro('Nenhum documento selecionado'));

    LArr := LIdsJson as TJSONArray;
    SetLength(LIds, LArr.Count);
    for I := 0 to LArr.Count - 1 do
      LIds[I] := StrToIntDef(LArr.Items[I].Value, 0);
  finally
    LJson.Free;
  end;

  if Length(LIds) = 0 then
    Exit(CriarRespostaErro('Nenhum documento selecionado'));

  LQtdOk := 0;
  LQtdErro := 0;
  LMensagem := '';
  try
    FOnRegerarNFCe(LIds, LQtdOk, LQtdErro, LMensagem);
  except
    on E: Exception do
      Exit(CriarRespostaErro('Falha ao regerar: ' + E.Message));
  end;

  SyncLog('NFCe: regeracao manual - %d autorizada(s), %d com erro (matricula %d)',
    [LQtdOk, LQtdErro, FMatriculaLogada]);

  LDados := TJSONObject.Create;
  LDados.AddPair('autorizadas', TJSONNumber.Create(LQtdOk));
  LDados.AddPair('erros', TJSONNumber.Create(LQtdErro));
  LDados.AddPair('detalhe', LMensagem);

  if LQtdOk = 0 then
  begin
    // CriarRespostaErro nao leva dados: o JSON tem que ser liberado aqui
    LDados.Free;
    Result := CriarRespostaErro('Nenhuma nota autorizada. ' + LMensagem);
  end
  else if LQtdErro = 0 then
    Result := CriarRespostaSucesso(
      IntToStr(LQtdOk) + ' nota(s) autorizada(s).', LDados)
  else
    Result := CriarRespostaSucesso(
      IntToStr(LQtdOk) + ' nota(s) autorizada(s), ' + IntToStr(LQtdErro) +
      ' com erro. ' + LMensagem, LDados);
end;

function TApoloBridge.DoRetransmitirContingencia(const AData: string): string;
var
  LQtdEnviados, LQtdErros: Integer;
  LDados: TJSONObject;
begin
  // Retransmitir e justamente o que se faz DENTRO da contingencia: exigir
  // sair antes travava o caixa, ja que sair exige zero pendentes

  if Assigned(FOnRetransmitir) then
  begin
    try
      LQtdEnviados := 0;
      LQtdErros := 0;
      FOnRetransmitir(LQtdEnviados, LQtdErros);

      LDados := TJSONObject.Create;
      LDados.AddPair('enviados', TJSONNumber.Create(LQtdEnviados));
      LDados.AddPair('erros', TJSONNumber.Create(LQtdErros));

      if LQtdErros = 0 then
        Result := CriarRespostaSucesso(
          'Retransmissao concluida. ' + IntToStr(LQtdEnviados) + ' documento(s) enviado(s).', LDados)
      else
        Result := CriarRespostaSucesso(
          'Retransmissao parcial. ' + IntToStr(LQtdEnviados) + ' enviado(s), ' +
          IntToStr(LQtdErros) + ' erro(s).', LDados);
    except
      on E: Exception do
        Result := CriarRespostaErro('Erro na retransmissao: ' + E.Message);
    end;
  end
  else
    Result := CriarRespostaErro('Modulo de retransmissao nao configurado.');
end;

// =========================================================================
// LOGOTIPO DA LOJA (impresso no DANFCe / PDF)
//
// O arquivo fica em ARQUIVO_LOGO (C:\Apolo\logo_nfce.png) e e' consumido pelo
// TACBrNFCeDANFeFPDF, que exige PNG. O front converte qualquer imagem para PNG
// redimensionado antes de enviar - aqui so' validamos e gravamos.
// =========================================================================

const
  LOGO_TAMANHO_MAXIMO = 512 * 1024;  // 512 KB ja' e' muito para um cupom
  LOGO_ASSINATURA_PNG: array[0..7] of Byte = ($89, $50, $4E, $47, $0D, $0A, $1A, $0A);

// Reaplica (ou limpa) o logo no DANFCe em memoria, para o proximo cupom sair
// com o logo novo sem precisar reiniciar o aplicativo.
procedure TApoloBridge.AplicarLogoDANFE;
begin
  if not Assigned(DmApoloWeb) or not Assigned(DmApoloWeb.ACBrNFeDANFCe) then Exit;

  try
    if FileExists(ARQUIVO_LOGO) then
      DmApoloWeb.ACBrNFeDANFCe.Logo := ARQUIVO_LOGO
    else
      DmApoloWeb.ACBrNFeDANFCe.Logo := '';
  except
    // Formato incompativel - o cupom continua saindo, apenas sem logo
  end;
end;

function TApoloBridge.DoObterLogo(const AData: string): string;
var
  LDados: TJSONObject;
  LBytes: TBytes;
begin
  LDados := TJSONObject.Create;
  LDados.AddPair('arquivo', ARQUIVO_LOGO);
  LDados.AddPair('pastaPDF', PASTA_NFCE + 'PDF\');

  if not FileExists(ARQUIVO_LOGO) then
  begin
    LDados.AddPair('existe', TJSONBool.Create(False));
    Exit(CriarRespostaSucesso('Nenhum logotipo configurado', LDados));
  end;

  try
    LBytes := TFile.ReadAllBytes(ARQUIVO_LOGO);
  except
    on E: Exception do
    begin
      LDados.Free;
      Exit(CriarRespostaErro('Nao foi possivel ler o logotipo: ' + E.Message));
    end;
  end;

  LDados.AddPair('existe', TJSONBool.Create(True));
  LDados.AddPair('tamanhoBytes', TJSONNumber.Create(Length(LBytes)));
  LDados.AddPair('modificadoEm',
    FormatDateTime('dd/mm/yyyy hh:nn', TFile.GetLastWriteTime(ARQUIVO_LOGO)));

  // Só devolve a imagem para preview se ela for pequena: a resposta volta ao JS
  // dentro de um ExecuteScript, entao nao vale a pena trafegar arquivos grandes.
  if Length(LBytes) <= LOGO_TAMANHO_MAXIMO then
    LDados.AddPair('dataUrl',
      'data:image/png;base64,' + TNetEncoding.Base64.EncodeBytesToString(LBytes))
  else
    LDados.AddPair('dataUrl', '');

  Result := CriarRespostaSucesso('OK', LDados);
end;

function TApoloBridge.DoSalvarLogo(const AData: string): string;
var
  LJson: TJSONObject;
  LImagem: string;
  LPos, I: Integer;
  LBytes: TBytes;
  LDados: TJSONObject;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LImagem := Trim(LJson.GetValue<string>('imagem', ''));
    if LImagem = '' then
      Exit(CriarRespostaErro('Nenhuma imagem recebida'));

    // Aceita tanto data URL ("data:image/png;base64,AAA...") quanto base64 puro
    LPos := Pos(',', LImagem);
    if StartsText('data:', LImagem) and (LPos > 0) then
      LImagem := Copy(LImagem, LPos + 1, MaxInt);

    try
      LBytes := TNetEncoding.Base64.DecodeStringToBytes(LImagem);
    except
      Exit(CriarRespostaErro('Imagem corrompida (base64 invalido)'));
    end;

    if Length(LBytes) = 0 then
      Exit(CriarRespostaErro('Imagem vazia'));
    if Length(LBytes) > LOGO_TAMANHO_MAXIMO then
      Exit(CriarRespostaErro(Format(
        'Imagem muito grande (%d KB). O limite e de %d KB.',
        [Length(LBytes) div 1024, LOGO_TAMANHO_MAXIMO div 1024])));

    // O DANFCe em PDF (TACBrNFCeDANFeFPDF) so aceita PNG
    if Length(LBytes) < Length(LOGO_ASSINATURA_PNG) then
      Exit(CriarRespostaErro('Arquivo de imagem invalido'));
    for I := Low(LOGO_ASSINATURA_PNG) to High(LOGO_ASSINATURA_PNG) do
      if LBytes[I] <> LOGO_ASSINATURA_PNG[I] then
        Exit(CriarRespostaErro('O logotipo precisa estar em PNG'));

    try
      ForceDirectories(ExtractFilePath(ARQUIVO_LOGO));
      TFile.WriteAllBytes(ARQUIVO_LOGO, LBytes);
    except
      on E: Exception do
        Exit(CriarRespostaErro('Nao foi possivel gravar o logotipo: ' + E.Message));
    end;

    AplicarLogoDANFE;

    LDados := TJSONObject.Create;
    LDados.AddPair('arquivo', ARQUIVO_LOGO);
    LDados.AddPair('tamanhoBytes', TJSONNumber.Create(Length(LBytes)));

    Result := CriarRespostaSucesso('Logotipo salvo. Sera impresso nos proximos cupons.', LDados);
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoRemoverLogo(const AData: string): string;
begin
  if not FileExists(ARQUIVO_LOGO) then
    Exit(CriarRespostaErro('Nao ha logotipo configurado'));

  try
    TFile.Delete(ARQUIVO_LOGO);
  except
    on E: Exception do
      Exit(CriarRespostaErro('Nao foi possivel remover o logotipo: ' + E.Message));
  end;

  AplicarLogoDANFE;

  Result := CriarRespostaSucesso('Logotipo removido');
end;

// =========================================================================
// CONTINGENCIA
// =========================================================================

function TApoloBridge.DoObterStatusConexao(const AData: string): string;
var
  LDados: TJSONObject;
begin
  LDados := TJSONObject.Create;
  LDados.AddPair('online', TJSONBool.Create(ContingenciaAtual = tcNenhuma));
  LDados.AddPair('tipo', ContingenciaAtual.ToString);

  Result := CriarRespostaSucesso('OK', LDados);
end;

function TApoloBridge.DoEntrarContingencia(const AData: string): string;
var
  LJson: TJSONObject;
  LTipo, LJustificativa: string;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LTipo := LJson.GetValue<string>('tipo', 'OFFLINE');
    LJustificativa := LJson.GetValue<string>('justificativa', '');

    if LJustificativa = '' then
      Exit(CriarRespostaErro('Informe a justificativa para entrar em contingencia'));

    if not Assigned(FContingenciaMgr) then
      Exit(CriarRespostaErro('Modulo de contingencia nao inicializado'));

    if TTipoContingencia.FromString(LTipo) = tcNenhuma then
      Exit(CriarRespostaErro('Tipo de contingencia invalido'));

    FContingenciaMgr.EntrarContingencia(
      TTipoContingencia.FromString(LTipo), LJustificativa);

    Result := CriarRespostaSucesso('Contingencia ativada: ' +
      ContingenciaAtual.ToString);
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoSairContingencia(const AData: string): string;
begin
  if not Assigned(FContingenciaMgr) then
    Exit(CriarRespostaErro('Modulo de contingencia nao inicializado'));

  // SairContingencia ja recusa quando ainda ha pendentes
  try
    FContingenciaMgr.SairContingencia;
    Result := CriarRespostaSucesso('Modo normal restaurado');
  except
    on E: Exception do
      Result := CriarRespostaErro(E.Message);
  end;
end;

function TApoloBridge.DoListarDocContingencia(const AData: string): string;
begin
  Result := DoListarNFCePendentes(AData);
end;

// =========================================================================
// CLIENTES
// =========================================================================

function TApoloBridge.DoBuscarCliente(const AData: string): string;
var
  LJson: TJSONObject;
  LFiltro: string;
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LFiltro := LJson.GetValue<string>('filtro', '');

    // Nome com apostrofo (Sant'Ana, D'Angelo) quebrava o SQL e a busca voltava
    // erro em vez de resultado. Mesmo escape que DoBuscarProduto ja faz.
    LFiltro := StringReplace(LFiltro, '''', '''''', [rfReplaceAll]);

    LQuery := FSQLite.ExecutarSelect(
      'SELECT codcli, cpf_cnpj, nome, cidade, uf, limite_credito ' +
      'FROM clientes WHERE ' +
      'nome LIKE ''%' + LFiltro + '%'' OR ' +
      'cpf_cnpj LIKE ''%' + LFiltro + '%'' OR ' +
      'CAST(codcli AS TEXT) = ''' + LFiltro + ''' ' +
      'ORDER BY nome LIMIT 50'
    );
    try
      LArr := TJSONArray.Create;
      while not LQuery.Eof do
      begin
        LObj := TJSONObject.Create;
        LObj.AddPair('codcli', TJSONNumber.Create(LQuery.FieldByName('codcli').AsInteger));
        LObj.AddPair('cpf_cnpj', LQuery.FieldByName('cpf_cnpj').AsString);
        LObj.AddPair('nome', LQuery.FieldByName('nome').AsString);
        LObj.AddPair('cidade', LQuery.FieldByName('cidade').AsString);
        LObj.AddPair('uf', LQuery.FieldByName('uf').AsString);
        LObj.AddPair('limiteCredito', TJSONNumber.Create(LQuery.FieldByName('limite_credito').AsFloat));
        LArr.AddElement(LObj);
        LQuery.Next;
      end;
      Result := CriarRespostaSucesso('OK', LArr);
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoBuscarVendedor(const AData: string): string;
var
  LJson: TJSONObject;
  LMatricula: Integer;
  LQuery: TUniQuery;
  LDados: TJSONObject;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LMatricula := LJson.GetValue<Integer>('matricula', 0);
    if LMatricula = 0 then
      Exit(CriarRespostaErro('Informe a matricula'));

    LQuery := FSQLite.ExecutarSelect(
      'SELECT matricula, nome FROM funcionarios WHERE matricula = ' +
      IntToStr(LMatricula) + ' AND ind_vendedor = ''S'''
    );
    try
      if LQuery.IsEmpty then
        Exit(CriarRespostaErro('Vendedor nao encontrado'));

      LDados := TJSONObject.Create;
      LDados.AddPair('matricula', TJSONNumber.Create(LMatricula));
      LDados.AddPair('nome', LQuery.FieldByName('nome').AsString);

      Result := CriarRespostaSucesso('OK', LDados);
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoIdentificarConsumidor(const AData: string): string;
var
  LJson: TJSONObject;
  LCpfCnpj, LCpfCnpjLimpo: string;
  LQuery: TUniQuery;
  LDados: TJSONObject;
  LCodCli: Integer;
  LNomeCliente: string;
  I: Integer;
begin
  if FCupomAtualId = 0 then
    Exit(CriarRespostaErro('Inicie uma venda antes de identificar o consumidor'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LCpfCnpj := Trim(LJson.GetValue<string>('cpfCnpj', ''));

    if LCpfCnpj = '' then
      Exit(CriarRespostaErro('Informe o CPF ou CNPJ'));

    // Limpar formatacao (remover pontos, tracos, barras)
    LCpfCnpjLimpo := '';
    for I := 1 to Length(LCpfCnpj) do
      if CharInSet(LCpfCnpj[I], ['0'..'9']) then
        LCpfCnpjLimpo := LCpfCnpjLimpo + LCpfCnpj[I];

    if (Length(LCpfCnpjLimpo) <> 11) and (Length(LCpfCnpjLimpo) <> 14) then
      Exit(CriarRespostaErro('CPF deve ter 11 digitos ou CNPJ deve ter 14 digitos'));

    // Buscar na tabela de clientes (sincronizada do mscliente)
    LQuery := FSQLite.ExecutarSelect(
      'SELECT codcli, cpf_cnpj, nome, endereco, bairro, cidade, uf ' +
      'FROM clientes WHERE REPLACE(REPLACE(REPLACE(REPLACE(cpf_cnpj, ''.'', ''''), ''-'', ''''), ''/'', ''''), '' '', '''') = ''' +
      LCpfCnpjLimpo + ''' LIMIT 1'
    );
    try
      LDados := TJSONObject.Create;

      if not LQuery.IsEmpty then
      begin
        // Cliente encontrado no cadastro (mscliente)
        LCodCli := LQuery.FieldByName('codcli').AsInteger;
        LNomeCliente := LQuery.FieldByName('nome').AsString;

        // Atualizar cupom com dados do cliente cadastrado
        FSQLite.ExecutarSQL(
          'UPDATE cupons SET codcli = :p0, cpf_cnpj = :p1, descnomecliente = :p2 WHERE id = :p3',
          [LCodCli, LCpfCnpjLimpo, LNomeCliente, FCupomAtualId]
        );

        LDados.AddPair('encontrado', TJSONBool.Create(True));
        LDados.AddPair('codcli', TJSONNumber.Create(LCodCli));
        LDados.AddPair('cpfCnpj', LCpfCnpjLimpo);
        LDados.AddPair('nome', LNomeCliente);
        LDados.AddPair('cidade', LQuery.FieldByName('cidade').AsString);
        LDados.AddPair('uf', LQuery.FieldByName('uf').AsString);

        Result := CriarRespostaSucesso('Cliente identificado: ' + LNomeCliente, LDados);
      end
      else
      begin
        // Cliente NAO encontrado - usar codconsumidor da msfilial
        LCodCli := StrToIntDef(FSQLite.ObterEstado(KEY_CODCONSUMIDOR, '0'), 0);

        if LCodCli = 0 then
          Exit(CriarRespostaErro('Codigo do consumidor padrao nao configurado na filial (msfilial.codconsumidor)'));

        // Atualizar cupom com consumidor generico + CPF/CNPJ informado
        FSQLite.ExecutarSQL(
          'UPDATE cupons SET codcli = :p0, cpf_cnpj = :p1, descnomecliente = :p2 WHERE id = :p3',
          [LCodCli, LCpfCnpjLimpo, 'CONSUMIDOR', FCupomAtualId]
        );

        LDados.AddPair('encontrado', TJSONBool.Create(False));
        LDados.AddPair('codcli', TJSONNumber.Create(LCodCli));
        LDados.AddPair('cpfCnpj', LCpfCnpjLimpo);
        LDados.AddPair('nome', 'CONSUMIDOR');
        LDados.AddPair('cidade', '');
        LDados.AddPair('uf', '');

        Result := CriarRespostaSucesso(
          'CPF/CNPJ registrado. Cliente nao cadastrado, usando consumidor padrao.', LDados);
      end;
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoVincularCliente(const AData: string): string;
var
  LJson: TJSONObject;
  LCodCli: Integer;
  LQuery: TUniQuery;
  LDados: TJSONObject;
begin
  if FCupomAtualId = 0 then
    Exit(CriarRespostaErro('Inicie uma venda antes de vincular o cliente'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LCodCli := LJson.GetValue<Integer>('codcli', 0);

    if LCodCli = 0 then
      Exit(CriarRespostaErro('Codigo do cliente invalido'));

    // Buscar dados do cliente
    LQuery := FSQLite.ExecutarSelect(
      'SELECT codcli, cpf_cnpj, nome, cidade, uf FROM clientes WHERE codcli = ' +
      IntToStr(LCodCli)
    );
    try
      if LQuery.IsEmpty then
        Exit(CriarRespostaErro('Cliente nao encontrado'));

      // Atualizar cupom com dados do cliente
      FSQLite.ExecutarSQL(
        'UPDATE cupons SET codcli = :p0, cpf_cnpj = :p1, descnomecliente = :p2 WHERE id = :p3',
        [LCodCli,
         LQuery.FieldByName('cpf_cnpj').AsString,
         LQuery.FieldByName('nome').AsString,
         FCupomAtualId]
      );

      LDados := TJSONObject.Create;
      LDados.AddPair('codcli', TJSONNumber.Create(LCodCli));
      LDados.AddPair('cpfCnpj', LQuery.FieldByName('cpf_cnpj').AsString);
      LDados.AddPair('nome', LQuery.FieldByName('nome').AsString);
      LDados.AddPair('cidade', LQuery.FieldByName('cidade').AsString);
      LDados.AddPair('uf', LQuery.FieldByName('uf').AsString);

      Result := CriarRespostaSucesso('Cliente vinculado: ' + LQuery.FieldByName('nome').AsString, LDados);
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

// =========================================================================
// PRE-VENDA
// =========================================================================

function TApoloBridge.DoListarPreVendas(const AData: string): string;
var
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT id, numtrans, numped, data, codcob, obs ' +
    'FROM prevenda WHERE processado = 0 ORDER BY data DESC'
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('id', TJSONNumber.Create(LQuery.FieldByName('id').AsInteger));
      LObj.AddPair('numtrans', TJSONNumber.Create(LQuery.FieldByName('numtrans').AsInteger));
      LObj.AddPair('numped', TJSONNumber.Create(LQuery.FieldByName('numped').AsInteger));
      LObj.AddPair('data', LQuery.FieldByName('data').AsString);
      LObj.AddPair('codcob', LQuery.FieldByName('codcob').AsString);
      LObj.AddPair('obs', LQuery.FieldByName('obs').AsString);
      LArr.AddElement(LObj);
      LQuery.Next;
    end;
    Result := CriarRespostaSucesso('OK', LArr);
  finally
    LQuery.Free;
  end;
end;

function TApoloBridge.DoImportarPreVenda(const AData: string): string;
var
  LJson: TJSONObject;
  LPreVendaId, LNumTrans: Integer;
  LQuery: TUniQuery;
  LConteudo: string;
  LCodProd: Int64;
  LQtde, LPreco: Double;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LPreVendaId := LJson.GetValue<Integer>('id', 0);
    if LPreVendaId = 0 then
      Exit(CriarRespostaErro('ID da pre-venda nao informado'));

    // Buscar pre-venda no SQLite
    LQuery := FSQLite.ExecutarSelect(
      'SELECT * FROM prevenda WHERE id = ' + IntToStr(LPreVendaId) + ' AND processado = 0'
    );
    try
      if LQuery.IsEmpty then
        Exit(CriarRespostaErro('Pre-venda nao encontrada ou ja processada'));

      LNumTrans := LQuery.FieldByName('numtrans').AsInteger;
      LConteudo := LQuery.FieldByName('conteudo').AsString;
    finally
      LQuery.Free;
    end;

    // Iniciar venda com base na pre-venda
    Result := DoIniciarVenda('{}');

    // Parsear o conteudo da pre-venda (XML armazenado como texto)
    // A pre-venda contem os itens no formato do sistema original
    // Processar cada item e adicionar ao cupom
    LQuery := FSQLite.ExecutarSelect(
      'SELECT codprod, qt, punit FROM prevenda_itens WHERE prevenda_id = ' + IntToStr(LPreVendaId)
    );
    try
      while not LQuery.Eof do
      begin
        LCodProd := LQuery.FieldByName('codprod').AsLargeInt;
        LQtde := LQuery.FieldByName('qt').AsFloat;
        LPreco := LQuery.FieldByName('punit').AsFloat;

        DoAdicionarItem(
          '{"codprod":' + IntToStr(LCodProd) +
          ',"quantidade":' + FloatToStr(LQtde) +
          ',"precoManual":' + FloatToStr(LPreco) + '}'
        );

        LQuery.Next;
      end;
    finally
      LQuery.Free;
    end;

    // Vincular cliente se existir
    LQuery := FSQLite.ExecutarSelect(
      'SELECT codcli FROM prevenda WHERE id = ' + IntToStr(LPreVendaId)
    );
    try
      if (not LQuery.IsEmpty) and (LQuery.FieldByName('codcli').AsInteger > 0) then
      begin
        FSQLite.ExecutarSQL(
          'UPDATE cupons SET codcli = :p0 WHERE id = :p1',
          [LQuery.FieldByName('codcli').AsInteger, FCupomAtualId]
        );
      end;
    finally
      LQuery.Free;
    end;

    // Marcar pre-venda como processada
    FSQLite.ExecutarSQL(
      'UPDATE prevenda SET processado = 1, dt_importacao = datetime(''now'',''localtime'') ' +
      'WHERE id = ' + IntToStr(LPreVendaId)
    );

    Result := CriarRespostaSucesso('Pre-venda ' + IntToStr(LNumTrans) + ' importada com sucesso');
  finally
    LJson.Free;
  end;
end;

// =========================================================================
// UTILIDADES
// =========================================================================

function TApoloBridge.ObterProximoNumCupom: Integer;
var
  LNum: Integer;
begin
  LNum := StrToIntDef(FSQLite.ObterEstado(KEY_PROX_NUM_CUPOM, '1'), 1);
  FSQLite.SalvarEstado(KEY_PROX_NUM_CUPOM, IntToStr(LNum + 1));
  Result := LNum;
end;

// Recalcula os agregados do cupom a partir dos itens ativos.
//   valorvenda = soma dos valores BRUTOS dos itens (subtotal)
//   valordesc  = desconto no subtotal + soma dos descontos de item
// Mantem a formula usada em todo o sistema (inclusive no fechamento de caixa
// e no upload para o Oracle): total = valorvenda - valordesc + valorencargo.
procedure TApoloBridge.AtualizarTotaisCupom(ACupomId: Integer);
begin
  if ACupomId = 0 then Exit;

  FSQLite.ExecutarSQL(
    'UPDATE cupons SET ' +
    'qtdeitens = (SELECT COUNT(*) FROM cupom_itens WHERE cupom_id = ' +
      IntToStr(ACupomId) + ' AND dtcancel IS NULL), ' +
    'valorvenda = (SELECT COALESCE(SUM(vlprod), 0) FROM cupom_itens WHERE cupom_id = ' +
      IntToStr(ACupomId) + ' AND dtcancel IS NULL), ' +
    'valordesc = COALESCE(valordescsubtotal, 0) + ' +
      '(SELECT COALESCE(SUM(vldesconto), 0) FROM cupom_itens WHERE cupom_id = ' +
      IntToStr(ACupomId) + ' AND dtcancel IS NULL) ' +
    'WHERE id = ' + IntToStr(ACupomId)
  );
end;

function TApoloBridge.CalcularTotalCupom(ACupomId: Integer): Double;
var
  LVal: Variant;
  LSubtotal, LDesconto, LAcrescimo: Double;
begin
  // Subtotal dos itens ativos
  LVal := FSQLite.ExecutarScalar(
    'SELECT COALESCE(SUM(vlprod), 0) FROM cupom_itens WHERE cupom_id = ' +
    IntToStr(ACupomId) + ' AND dtcancel IS NULL'
  );
  LSubtotal := VarToFloatDef(LVal, 0);

  // Desconto do cupom
  LVal := FSQLite.ExecutarScalar(
    'SELECT COALESCE(valordesc, 0) FROM cupons WHERE id = ' + IntToStr(ACupomId)
  );
  LDesconto := VarToFloatDef(LVal, 0);

  // Acrescimo
  LVal := FSQLite.ExecutarScalar(
    'SELECT COALESCE(valorencargo, 0) FROM cupons WHERE id = ' + IntToStr(ACupomId)
  );
  LAcrescimo := VarToFloatDef(LVal, 0);

  Result := RoundTo(LSubtotal - LDesconto + LAcrescimo, -2);
end;

{ Soma dos pagamentos, arredondada ao centavo.

  Sem o RoundTo, somar tres ou mais pagamentos em Double erra por ~1e-13 para
  MENOS: 813,64 + 1,39 + 1,42 da 816,4499999999999 e nao 816,45. Como
  CalcularTotalCupom ja arredonda, a comparacao em DoFinalizarVenda dizia
  "pago < total" e recusava a venda com "Pagamento insuficiente. Faltam
  R$ 0,00" - com o front, que le o restante ja formatado em 2 casas,
  insistindo em finalizar. Numa simulacao de 300 mil vendas com 3 a 5
  pagamentos, 17% caiam nisso. }
function TApoloBridge.CalcularTotalPago(ACupomId: Integer): Double;
var
  LVal: Variant;
begin
  LVal := FSQLite.ExecutarScalar(
    'SELECT COALESCE(SUM(valor), 0) FROM cupom_pagamentos WHERE cupom_id = ' +
    IntToStr(ACupomId)
  );
  Result := RoundTo(VarToFloatDef(LVal, 0), -2);
end;

// =========================================================================
// TEF (ScopeAPI)
// =========================================================================

function TApoloBridge.DoObterConfigTEF(const AData: string): string;
var
  LDados: TJSONObject;
begin
  LDados := TJSONObject.Create;
  LDados.AddPair('tefHabilitado', TJSONBool.Create(FTEFHabilitado));
  LDados.AddPair('tefModo', FTEFDescricao);
  // Decide o que a tela de pagamento faz num PIX pelo TEF: mandar o cliente
  // olhar o pinpad ou esperar o BR Code para desenhar o QR aqui
  LDados.AddPair('tefPixQrTela',
    TJSONBool.Create(FTEFConfig.PixQr = pqTela));
  // Base do watchdog da tela de espera (payment.js)
  LDados.AddPair('tefTimeout', TJSONNumber.Create(FTEFConfig.TimeoutSeg));
  // clisitef: menus e coletas vem para a tela do PDV (nao ha gerenciador)
  LDados.AddPair('tefInterativo',
    TJSONBool.Create(FTEFHabilitado and (FTEFConfig.Modo = tmCliSiTef)));
  Result := CriarRespostaSucesso('OK', LDados);
end;

// =========================================================================
// TEF - parametrizacao pela tela do PDV (grava na secao [TEF] do
// apoloweb.ini e recria o cliente na hora, sem reiniciar o caixa)
// =========================================================================

function TApoloBridge.DoObterParametrosTEF(const AData: string): string;
var
  LDados: TJSONObject;
begin
  LDados := TJSONObject.Create;
  LDados.AddPair('habilitado', TJSONBool.Create(FTEFConfig.Habilitado));
  LDados.AddPair('modo', FTEFConfig.ModoTexto);
  LDados.AddPair('url', FTEFConfig.Url);
  LDados.AddPair('pastaReq', FTEFConfig.PastaReq);
  LDados.AddPair('pastaResp', FTEFConfig.PastaResp);
  LDados.AddPair('timeout', TJSONNumber.Create(FTEFConfig.TimeoutSeg));
  LDados.AddPair('debug', TJSONBool.Create(FTEFConfig.Debug));
  LDados.AddPair('pixQr', FTEFConfig.PixQrTexto);
  LDados.AddPair('pixQrCampos', FTEFConfig.PixQrCampos);
  LDados.AddPair('pixQrChaves', FTEFConfig.PixQrChaves);
  LDados.AddPair('sitefDll', FTEFConfig.SitefDll);
  LDados.AddPair('sitefIp', FTEFConfig.SitefIP);
  LDados.AddPair('sitefLoja', FTEFConfig.SitefLoja);
  LDados.AddPair('sitefTerminal', FTEFConfig.SitefTerminal);
  LDados.AddPair('sitefParamAdic', FTEFConfig.SitefParamAdic);
  LDados.AddPair('kit', KitCliSiTefJson(FTEFConfig.SitefDll));
  LDados.AddPair('numCaixa', TJSONNumber.Create(FTEFNumCaixa));
  LDados.AddPair('arquivoIni', ARQ_APOLOWEB_INI);
  LDados.AddPair('descricao', FTEFDescricao);
  LDados.AddPair('ativo', TJSONBool.Create(FTEFClient <> nil));
  Result := CriarRespostaSucesso('OK', LDados);
end;

// Monta um TTEFConfig a partir do JSON da tela, validando o que o modo exige.
function TApoloBridge.LerConfigTEFDoJson(const AData: string;
  out AConfig: TTEFConfig; out AErro: string): Boolean;
var
  LJson: TJSONObject;
begin
  Result := False;
  AErro := '';
  AConfig := FTEFConfig;

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then
  begin
    AErro := 'Dados invalidos';
    Exit;
  end;

  try
    AConfig.Habilitado := LJson.GetValue<Boolean>('habilitado', FTEFConfig.Habilitado);
    AConfig.Modo := TEFModoFromString(LJson.GetValue<string>('modo', FTEFConfig.ModoTexto));
    AConfig.Url := Trim(LJson.GetValue<string>('url', FTEFConfig.Url));
    AConfig.PastaReq := Trim(LJson.GetValue<string>('pastaReq', FTEFConfig.PastaReq));
    AConfig.PastaResp := Trim(LJson.GetValue<string>('pastaResp', FTEFConfig.PastaResp));
    AConfig.TimeoutSeg := LJson.GetValue<Integer>('timeout', FTEFConfig.TimeoutSeg);
    AConfig.Debug := LJson.GetValue<Boolean>('debug', FTEFConfig.Debug);
    AConfig.PixQr := TEFPixQrFromString(
      LJson.GetValue<string>('pixQr', FTEFConfig.PixQrTexto));
    AConfig.PixQrCampos := Trim(LJson.GetValue<string>('pixQrCampos',
      FTEFConfig.PixQrCampos));
    AConfig.PixQrChaves := Trim(LJson.GetValue<string>('pixQrChaves',
      FTEFConfig.PixQrChaves));
    if AConfig.PixQrCampos = '' then AConfig.PixQrCampos := TEF_PIX_QR_AUTO;
    if AConfig.PixQrChaves = '' then AConfig.PixQrChaves := TEF_PIX_QR_AUTO;
    AConfig.SitefDll := Trim(LJson.GetValue<string>('sitefDll', FTEFConfig.SitefDll));
    AConfig.SitefIP := Trim(LJson.GetValue<string>('sitefIp', FTEFConfig.SitefIP));
    AConfig.SitefLoja := Trim(LJson.GetValue<string>('sitefLoja', FTEFConfig.SitefLoja));
    AConfig.SitefTerminal := Trim(LJson.GetValue<string>('sitefTerminal',
      FTEFConfig.SitefTerminal));
    AConfig.SitefParamAdic := Trim(LJson.GetValue<string>('sitefParamAdic',
      FTEFConfig.SitefParamAdic));
    AConfig.Identificacao := FTEFNumCaixa;

    if (AConfig.TimeoutSeg < 10) or (AConfig.TimeoutSeg > 600) then
    begin
      AErro := 'Timeout deve ficar entre 10 e 600 segundos';
      Exit;
    end;

    if AConfig.Habilitado and (AConfig.Modo = tmHTTP) and (AConfig.Url = '') then
    begin
      AErro := 'Informe a URL da API TEF';
      Exit;
    end;

    if AConfig.Habilitado and (AConfig.Modo = tmArquivo) then
    begin
      if (AConfig.PastaReq = '') or (AConfig.PastaResp = '') then
      begin
        AErro := 'Informe as pastas de requisicao e resposta';
        Exit;
      end;
      if not TDirectory.Exists(AConfig.PastaReq) then
      begin
        AErro := 'Pasta de requisicao nao encontrada: ' + AConfig.PastaReq;
        Exit;
      end;
      if not TDirectory.Exists(AConfig.PastaResp) then
      begin
        AErro := 'Pasta de resposta nao encontrada: ' + AConfig.PastaResp;
        Exit;
      end;
    end;

    if AConfig.Habilitado and (AConfig.Modo = tmCliSiTef) then
    begin
      if not TFile.Exists(AConfig.SitefDll) then
      begin
        AErro := 'CliSiTef nao encontrada: ' + AConfig.SitefDll;
        Exit;
      end;
      if AConfig.SitefIP = '' then
      begin
        AErro := 'Informe o endereco do servidor SiTef';
        Exit;
      end;
      // Loja e terminal tem 8 posicoes; numero curto ganha zeros a esquerda
      if (AConfig.SitefLoja <> '') and (Length(AConfig.SitefLoja) < 8) and
         (StrToInt64Def(AConfig.SitefLoja, -1) >= 0) then
        AConfig.SitefLoja := StringOfChar('0', 8 - Length(AConfig.SitefLoja)) +
          AConfig.SitefLoja;
      if (AConfig.SitefTerminal <> '') and (Length(AConfig.SitefTerminal) < 8) and
         (StrToInt64Def(AConfig.SitefTerminal, -1) >= 0) then
        AConfig.SitefTerminal := StringOfChar('0', 8 - Length(AConfig.SitefTerminal)) +
          AConfig.SitefTerminal;
      if Length(AConfig.SitefLoja) <> 8 then
      begin
        AErro := 'O codigo da loja SiTef deve ter 8 caracteres';
        Exit;
      end;
      if Length(AConfig.SitefTerminal) <> 8 then
      begin
        AErro := 'O codigo do terminal SiTef deve ter 8 caracteres';
        Exit;
      end;
    end;

    Result := True;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoSalvarParametrosTEF(const AData: string): string;
var
  LConfig: TTEFConfig;
  LErro: string;
  LIni: TIniFile;
  LDados: TJSONObject;
begin
  if not LerConfigTEFDoJson(AData, LConfig, LErro) then
    Exit(CriarRespostaErro(LErro));

  try
    LIni := TIniFile.Create(ARQ_APOLOWEB_INI);
    try
      LIni.WriteBool('TEF', 'habilitado', LConfig.Habilitado);
      LIni.WriteString('TEF', 'modo', LConfig.ModoTexto);
      LIni.WriteString('TEF', 'url', LConfig.Url);
      LIni.WriteString('TEF', 'pasta_req', LConfig.PastaReq);
      LIni.WriteString('TEF', 'pasta_resp', LConfig.PastaResp);
      LIni.WriteInteger('TEF', 'timeout', LConfig.TimeoutSeg);
      LIni.WriteBool('TEF', 'debug', LConfig.Debug);
      LIni.WriteString('TEF', 'pix_qr', LConfig.PixQrTexto);
      LIni.WriteString('TEF', 'pix_qr_campos', LConfig.PixQrCampos);
      LIni.WriteString('TEF', 'pix_qr_chaves', LConfig.PixQrChaves);
      LIni.WriteString('TEF', 'sitef_dll', LConfig.SitefDll);
      LIni.WriteString('TEF', 'sitef_ip', LConfig.SitefIP);
      LIni.WriteString('TEF', 'sitef_loja', LConfig.SitefLoja);
      LIni.WriteString('TEF', 'sitef_terminal', LConfig.SitefTerminal);
      LIni.WriteString('TEF', 'sitef_param_adic', LConfig.SitefParamAdic);
    finally
      LIni.Free;
    end;
  except
    on E: Exception do
      Exit(CriarRespostaErro('Nao foi possivel gravar o ' +
        ExtractFileName(ARQ_APOLOWEB_INI) + ': ' + E.Message));
  end;

  // Aplica sem reiniciar o caixa
  InicializarTEF(LConfig, FTEFNumCaixa);
  TEFLog('parametros TEF salvos pela tela do PDV: %s', [FTEFConfig.Descricao]);

  LDados := TJSONObject.Create;
  LDados.AddPair('descricao', FTEFDescricao);
  LDados.AddPair('ativo', TJSONBool.Create(FTEFClient <> nil));
  Result := CriarRespostaSucesso('Parametros do TEF salvos', LDados);
end;

// Testa com os valores da tela (ainda nao salvos), sem mexer no cliente ativo
function TApoloBridge.DoTestarTEF(const AData: string): string;
var
  LConfig: TTEFConfig;
  LErro: string;
  LCliente: ITEFClient;
  LOnline: Boolean;
  LDados: TJSONObject;
begin
  if not LerConfigTEFDoJson(AData, LConfig, LErro) then
    Exit(CriarRespostaErro(LErro));

  LConfig.Habilitado := True;
  try
    LCliente := CriarTEFClient(LConfig);
    LOnline := LCliente.ConsultarStatus;
  except
    on E: Exception do
      Exit(CriarRespostaErro(E.Message));
  end;

  LDados := TJSONObject.Create;
  LDados.AddPair('online', TJSONBool.Create(LOnline));
  LDados.AddPair('descricao', LConfig.Descricao);
  if LOnline then
    Result := CriarRespostaSucesso('Gerenciador TEF respondeu', LDados)
  else
    Result := CriarRespostaSucesso('Gerenciador TEF nao respondeu', LDados);
end;

// Estado do kit CliSiTef para a aba TEF. O token nunca vai para a tela: so
// se ele esta configurado.
function TApoloBridge.KitCliSiTefJson(const ADll: string): TJSONObject;
var
  LKit: TCliSiTefKit;
begin
  LKit := CliSiTefLerKit(ADll);
  Result := TJSONObject.Create;
  Result.AddPair('pasta', LKit.Pasta);
  Result.AddPair('versao', LKit.Versao);
  Result.AddPair('dllExiste', TJSONBool.Create(LKit.DllExiste));
  Result.AddPair('iniExiste', TJSONBool.Create(LKit.IniExiste));
  Result.AddPair('portaPinPad', LKit.PortaPinPad);
  Result.AddPair('trace', TJSONBool.Create(LKit.Trace));
  Result.AddPair('tlsExiste', TJSONBool.Create(LKit.TlsExiste));
  Result.AddPair('tlsTipo', LKit.TlsTipo);
  Result.AddPair('tlsUrl', LKit.TlsUrl);
  Result.AddPair('tokenConfigurado', TJSONBool.Create(LKit.TokenConfigurado));
end;

// A tela trocou o caminho da DLL: mostra o kit daquela pasta
function TApoloBridge.DoLerKitCliSiTef(const AData: string): string;
var
  LJson: TJSONObject;
  LDll: string;
begin
  LDll := FTEFConfig.SitefDll;
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson <> nil then
  try
    LDll := Trim(LJson.GetValue<string>('dll', LDll));
  finally
    LJson.Free;
  end;
  Result := CriarRespostaSucesso('OK', KitCliSiTefJson(LDll));
end;

{ Grava porta do pinpad e trace no CliSiTef.ini e o TLS (URL, token) no
  CONFITLS.INI da pasta da DLL. Token vazio = mantem o gravado. Vale na
  proxima operacao TEF (o ConfiguraIntSiTefInterativo e' refeito). }
function TApoloBridge.DoSalvarKitCliSiTef(const AData: string): string;
var
  LJson: TJSONObject;
  LDll, LPorta, LUrl, LToken: string;
  LTrace: Boolean;
begin
  if FTEFEmCurso then
    Exit(CriarRespostaErro('Ha uma transacao TEF em andamento'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));
  try
    LDll := Trim(LJson.GetValue<string>('dll', FTEFConfig.SitefDll));
    LPorta := Trim(LJson.GetValue<string>('portaPinPad', ''));
    LTrace := LJson.GetValue<Boolean>('trace', False);
    LUrl := Trim(LJson.GetValue<string>('tlsUrl', ''));
    LToken := Trim(LJson.GetValue<string>('token', ''));
  finally
    LJson.Free;
  end;

  try
    CliSiTefGravarKit(LDll, LPorta, LTrace, LUrl, LToken);
  except
    on E: Exception do
      Exit(CriarRespostaErro(E.Message));
  end;
  Result := CriarRespostaSucesso('Configuracao do kit CliSiTef salva',
    KitCliSiTefJson(LDll));
end;

// modo=clisitef: a tela respondeu um menu/pergunta/coleta ('tefInteracao').
// id 0 + acao=cancelar = desistir com o pinpad esperando (sem pergunta na tela)
function TApoloBridge.DoResponderTEF(const AData: string): string;
var
  LJson: TJSONObject;
begin
  if FTEFClient = nil then
    Exit(CriarRespostaErro('TEF nao inicializado'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));
  try
    FTEFClient.ResponderInteracao(LJson.GetValue<Integer>('id', 0),
      LJson.GetValue<string>('acao', 'ok'), LJson.GetValue<string>('valor', ''));
  finally
    LJson.Free;
  end;
  Result := CriarRespostaSucesso('OK');
end;

// =========================================================================
// TEF ADMINISTRATIVO - aba TEF da tela de Documentos Fiscais
// =========================================================================

{ Menu administrativo do gerenciador (comando ADM). Quem desenha o menu -
  reimpressao, relatorios, testes de comunicacao, funcoes da adquirente - e o
  proprio Tef_Dial, na tela dele. Aqui so se dispara e se espera o retorno,
  que pode demorar o timeout inteiro enquanto o operador navega o menu. }
function TApoloBridge.DoAdministracaoTEF(const AData: string): string;
begin
  if not FTEFHabilitado then
    Exit(CriarRespostaErro('TEF nao habilitado'));
  if FTEFClient = nil then
    Exit(CriarRespostaErro('TEF nao inicializado'));

  // Retorna na hora; o resultado chega por 'tefAdmResultado'
  Result := CriarRespostaSucesso('Menu administrativo aberto no gerenciador');

  TThread.CreateAnonymousThread(
    procedure
    var
      LResp: TTEFResposta;
      LErro: string;
    begin
      LErro := '';
      try
        LResp := FTEFClient.Administracao;
      except
        on E: Exception do
        begin
          LErro := E.Message;
          LResp := Default(TTEFResposta);
        end;
      end;

      TThread.Queue(nil,
        procedure
        var
          LJson: TJSONObject;
        begin
          LJson := TJSONObject.Create;
          try
            if LErro <> '' then
            begin
              LJson.AddPair('sucesso', TJSONBool.Create(False));
              LJson.AddPair('status', 'ERRO');
              LJson.AddPair('erro', LErro);
            end
            else
            begin
              LJson.AddPair('sucesso', TJSONBool.Create(LResp.Sucesso));
              // 'CANCELADA' = operador saiu do menu; a tela nao trata como falha
              LJson.AddPair('status', LResp.Status);
              LJson.AddPair('erro', LResp.Erro);
              LJson.AddPair('nsu', LResp.NSU);
              // CliSiTef devolve as vias (reimpressao, estorno pelo menu)
              // para a automacao imprimir; os gerenciadores imprimem sozinhos
              if (Length(LResp.ImpressoCliente) > 0) or
                 (Length(LResp.ImpressoLoja) > 0) then
              try
                ImprimirViasTEF(LResp.ImpressoCliente, LResp.ImpressoLoja);
              except
                on E: Exception do
                  LJson.AddPair('erroImpressao', E.Message);
              end;
            end;
            if Assigned(FOnEnviarParaJS) then
              FOnEnviarParaJS('tefAdmResultado', LJson.ToJSON);
          finally
            LJson.Free;
          end;
        end
      );
    end
  ).Start;
end;

{ Transacoes TEF do dia, para estorno e reimpressao. Sai de tef_pendentes, que
  e onde o pagamento por cartao fica registrado com o controle usado no CNC. }
function TApoloBridge.DoListarTransacoesTEF(const AData: string): string;
var
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT t.id, t.cupom_id, t.controle, t.nsu, t.cod_autorizacao, t.valor, ' +
    't.tipo_transacao, t.bandeira, t.parcelas, t.status, t.dthr_transacao, ' +
    '(CASE WHEN t.comprovante_cliente <> '''' OR t.comprovante_loja <> '''' ' +
    'THEN 1 ELSE 0 END) AS tem_comprovante, ' +
    'c.numcupom ' +
    'FROM tef_pendentes t ' +
    'LEFT JOIN cupons c ON t.cupom_id = c.id ' +
    'WHERE date(t.dthr_transacao) = date(''now'',''localtime'') ' +
    'ORDER BY t.dthr_transacao DESC'
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('id', TJSONNumber.Create(LQuery.FieldByName('id').AsInteger));
      LObj.AddPair('cupomId', TJSONNumber.Create(LQuery.FieldByName('cupom_id').AsInteger));
      LObj.AddPair('numCupom', TJSONNumber.Create(LQuery.FieldByName('numcupom').AsInteger));
      LObj.AddPair('controle', LQuery.FieldByName('controle').AsString);
      LObj.AddPair('nsu', LQuery.FieldByName('nsu').AsString);
      LObj.AddPair('codAutorizacao', LQuery.FieldByName('cod_autorizacao').AsString);
      LObj.AddPair('valor', TJSONNumber.Create(LQuery.FieldByName('valor').AsFloat));
      LObj.AddPair('tipoTransacao', LQuery.FieldByName('tipo_transacao').AsString);
      LObj.AddPair('bandeira', LQuery.FieldByName('bandeira').AsString);
      LObj.AddPair('parcelas', TJSONNumber.Create(LQuery.FieldByName('parcelas').AsInteger));
      LObj.AddPair('status', LQuery.FieldByName('status').AsString);
      LObj.AddPair('dthrTransacao', LQuery.FieldByName('dthr_transacao').AsString);
      LObj.AddPair('temComprovante',
        TJSONBool.Create(LQuery.FieldByName('tem_comprovante').AsInteger = 1));
      LArr.AddElement(LObj);
      LQuery.Next;
    end;
    Result := CriarRespostaSucesso('OK', LArr);
  finally
    LQuery.Free;
  end;
end;

{ Estorno de uma transacao TEF ja concluida (comando CNC). Exige a mesma
  permissao do cancelamento de venda: e dinheiro voltando para o cliente. }
function TApoloBridge.DoEstornarTEF(const AData: string): string;
var
  LJson: TJSONObject;
  LQuery: TUniQuery;
  LId, LCupomId, LMatAutorizou: Integer;
  LControle, LNSU, LStatus, LErro: string;
  LValor: Double;
begin
  if not FTEFHabilitado then
    Exit(CriarRespostaErro('TEF nao habilitado'));
  if FTEFClient = nil then
    Exit(CriarRespostaErro('TEF nao inicializado'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));
  try
    LId := LJson.GetValue<Integer>('id', 0);
    if LId <= 0 then Exit(CriarRespostaErro('Transacao nao informada'));

    if not ValidarAutorizacao(CTRL_CANCELAR_VENDA, LJson, LMatAutorizou, LErro) then
    begin
      if LErro = '' then
        LErro := 'Operador sem permissao para estornar transacao TEF';
      Exit(CriarRespostaSemPermissao(LErro));
    end;

    LQuery := FSQLite.ExecutarSelect(
      'SELECT cupom_id, controle, nsu, valor, status FROM tef_pendentes ' +
      'WHERE id = ' + IntToStr(LId)
    );
    try
      if LQuery.Eof then Exit(CriarRespostaErro('Transacao nao encontrada'));
      LCupomId := LQuery.FieldByName('cupom_id').AsInteger;
      LControle := LQuery.FieldByName('controle').AsString;
      LNSU := LQuery.FieldByName('nsu').AsString;
      LValor := LQuery.FieldByName('valor').AsFloat;
      LStatus := LQuery.FieldByName('status').AsString;
    finally
      LQuery.Free;
    end;

    if SameText(LStatus, 'ESTORNADO') or SameText(LStatus, 'DESFEITO') then
      Exit(CriarRespostaErro('Esta transacao ja foi estornada'));
  finally
    LJson.Free;
  end;

  // Retorna na hora; o resultado chega por 'tefEstornoResultado'
  Result := CriarRespostaSucesso('Estorno enviado ao gerenciador, aguarde...');
  EstornarTEFEmSegundoPlano(LId, LCupomId, LValor, LNSU, LControle);
end;

{ Metodo proprio para o anonimo capturar os parametros por valor (ver
  DispararResolucaoTEF). No modo clisitef o estorno conversa com o operador
  pela tela, entao nunca pode rodar preso na thread principal. }
procedure TApoloBridge.EstornarTEFEmSegundoPlano(AId, ACupomId: Integer;
  AValor: Double; const ANSU, AControle: string);
var
  LNSU, LControle: string;
begin
  LNSU := ANSU;
  LControle := AControle;
  TThread.CreateAnonymousThread(
    procedure
    var
      LResp: TTEFResposta;
      LErroThread: string;
    begin
      LErroThread := '';
      try
        LResp := FTEFClient.Cancelar(ACupomId, AValor, LNSU, LControle);
      except
        on E: Exception do
        begin
          LErroThread := E.Message;
          LResp := Default(TTEFResposta);
        end;
      end;

      TThread.Queue(nil,
        procedure
        var
          LJsonResp: TJSONObject;
        begin
          if (LErroThread = '') and LResp.Sucesso then
          begin
            FSQLite.ExecutarSQL(
              'UPDATE tef_pendentes SET status = ''ESTORNADO'', ' +
              'dthr_confirmacao = datetime(''now'',''localtime'') WHERE id = ' +
              IntToStr(AId)
            );
            // CliSiTef devolve o comprovante do estorno para a automacao
            if (Length(LResp.ImpressoCliente) > 0) or
               (Length(LResp.ImpressoLoja) > 0) then
            try
              ImprimirViasTEF(LResp.ImpressoCliente, LResp.ImpressoLoja);
            except
              on E: Exception do
                TEFLog('falha ao imprimir comprovante do estorno: ' + E.Message);
            end;
          end;

          LJsonResp := TJSONObject.Create;
          try
            LJsonResp.AddPair('sucesso',
              TJSONBool.Create((LErroThread = '') and LResp.Sucesso));
            LJsonResp.AddPair('nsu', LNSU);
            if LErroThread <> '' then
              LJsonResp.AddPair('erro', LErroThread)
            else
              LJsonResp.AddPair('erro', LResp.Erro);
            if Assigned(FOnEnviarParaJS) then
              FOnEnviarParaJS('tefEstornoResultado', LJsonResp.ToJSON);
          finally
            LJsonResp.Free;
          end;
        end
      );
    end
  ).Start;
end;

{ Reimpressao das vias de cliente e loja de uma transacao TEF. Sai do que ficou
  gravado em tef_pendentes - nao fala com o gerenciador. }
function TApoloBridge.DoReimprimirComprovanteTEF(const AData: string): string;
var
  LJson: TJSONObject;
  LId: Integer;
  LCupomId: Integer;
  LQuery: TUniQuery;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));
  try
    LId := LJson.GetValue<Integer>('id', 0);
  finally
    LJson.Free;
  end;
  if LId <= 0 then Exit(CriarRespostaErro('Transacao nao informada'));

  LQuery := FSQLite.ExecutarSelect(
    'SELECT cupom_id, comprovante_cliente, comprovante_loja FROM tef_pendentes ' +
    'WHERE id = ' + IntToStr(LId)
  );
  try
    if LQuery.Eof then Exit(CriarRespostaErro('Transacao nao encontrada'));
    if (LQuery.FieldByName('comprovante_cliente').AsString = '') and
       (LQuery.FieldByName('comprovante_loja').AsString = '') then
      Exit(CriarRespostaErro('Esta transacao nao tem comprovante guardado'));
    LCupomId := LQuery.FieldByName('cupom_id').AsInteger;
  finally
    LQuery.Free;
  end;

  try
    ImprimirComprovantesTEF(LCupomId);
  except
    on E: Exception do
      Exit(CriarRespostaErro('Falha ao imprimir: ' + E.Message));
  end;

  Result := CriarRespostaSucesso('Comprovante enviado para a impressora');
end;

// =========================================================================
// CANCELAMENTO DE NFCe - evento 110111
// =========================================================================

{ Notas autorizadas do dia que ainda podem ser canceladas. minutos e o tempo
  desde o fechamento da venda: a SEFAZ so homologa cancelamento de NFCe dentro
  de 30 minutos da autorizacao, e passar disso vira rejeicao. A conta e feita
  aqui para a tela poder avisar antes de gastar uma ida ao SEFAZ. }
function TApoloBridge.DoListarNFCeCancelaveis(const AData: string): string;
var
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
  LMin: Integer;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT id, numnota, numcupom, chavenfe, protocolo_nfe, valorvenda, ' +
    'dthrfimvenda, cancelada, ' +
    'CAST((julianday(''now'',''localtime'') - julianday(dthrfimvenda)) ' +
    '* 1440 AS INTEGER) AS minutos, ' +
    'CASE WHEN chavenfe IS NULL OR chavenfe = '''' THEN 1 ELSE 0 END AS sem_nfce ' +
    'FROM cupons c ' +
    'WHERE codoper = ''V'' ' +
    'AND date(dthrfimvenda) = date(''now'',''localtime'') ' +
    'AND ( (chavenfe IS NOT NULL AND chavenfe <> '''' ' +
    '       AND protocolo_nfe IS NOT NULL AND protocolo_nfe <> '''') ' +
    // Venda fechada que ficou SEM nota e fora da fila de contingencia: o
    // front nao chegou a pedir o gerarNFCe (timeout, queda do app entre o
    // fechamento e a emissao). Nao aparecia em lugar nenhum - cupom 312 de
    // 11/09/2026 ficou orfao assim. Aqui ela entra com o botao Emitir NFCe.
    '   OR (cancelada = 0 AND (chavenfe IS NULL OR chavenfe = '''') ' +
    '       AND NOT EXISTS (SELECT 1 FROM nfce_contingencia nc ' +
    '                       WHERE nc.cupom_id = c.id)) ) ' +
    'ORDER BY dthrfimvenda DESC'
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LMin := LQuery.FieldByName('minutos').AsInteger;
      LObj := TJSONObject.Create;
      LObj.AddPair('semNfce', TJSONBool.Create(LQuery.FieldByName('sem_nfce').AsInteger = 1));
      LObj.AddPair('cupomId', TJSONNumber.Create(LQuery.FieldByName('id').AsInteger));
      LObj.AddPair('numNota', TJSONNumber.Create(LQuery.FieldByName('numnota').AsInteger));
      LObj.AddPair('numCupom', TJSONNumber.Create(LQuery.FieldByName('numcupom').AsInteger));
      LObj.AddPair('chaveNFe', LQuery.FieldByName('chavenfe').AsString);
      LObj.AddPair('protocolo', LQuery.FieldByName('protocolo_nfe').AsString);
      LObj.AddPair('valor', TJSONNumber.Create(LQuery.FieldByName('valorvenda').AsFloat));
      LObj.AddPair('dthrVenda', LQuery.FieldByName('dthrfimvenda').AsString);
      LObj.AddPair('minutos', TJSONNumber.Create(LMin));
      LObj.AddPair('cancelada',
        TJSONBool.Create(LQuery.FieldByName('cancelada').AsInteger = 1));
      LObj.AddPair('noPrazo', TJSONBool.Create(LMin <= PRAZO_CANCEL_NFCE_MIN));
      LArr.AddElement(LObj);
      LQuery.Next;
    end;
    Result := CriarRespostaSucesso('OK', LArr);
  finally
    LQuery.Free;
  end;
end;

{ Cancelamento completo: evento no SEFAZ, cupom marcado, TEF da venda estornado
  e a venda remarcada para subir de novo para a retaguarda.

  A ordem importa. O evento vem primeiro porque e o unico passo que pode ser
  recusado por terceiro; so depois que a SEFAZ homologa e que faz sentido
  devolver o dinheiro do cartao e avisar o Oracle. }
function TApoloBridge.DoCancelarNFCe(const AData: string): string;
var
  LJson: TJSONObject;
  LCupomId, LMatAutorizou: Integer;
  LJustificativa, LErro, LMensagem: string;
  LSucesso: Boolean;
  LDados: TJSONObject;
  LQuery: TUniQuery;
  LEstornos, LFalhasEstorno, LEstornosDisparados: Integer;
begin
  if not Assigned(FOnCancelarNFCe) then
    Exit(CriarRespostaErro('Cancelamento de NFCe nao disponivel (NFCe nao inicializada)'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));
  try
    LCupomId := LJson.GetValue<Integer>('cupomId', 0);
    LJustificativa := Trim(LJson.GetValue<string>('justificativa', ''));

    if LCupomId <= 0 then
      Exit(CriarRespostaErro('Nota nao informada'));
    if (Length(LJustificativa) < 15) or (Length(LJustificativa) > 255) then
      Exit(CriarRespostaErro('A justificativa deve ter de 15 a 255 caracteres'));

    if not ValidarAutorizacao(CTRL_CANCELAR_VENDA, LJson, LMatAutorizou, LErro) then
    begin
      if LErro = '' then
        LErro := 'Operador sem permissao para cancelar nota fiscal';
      Exit(CriarRespostaSemPermissao(LErro));
    end;
  finally
    LJson.Free;
  end;

  // 1. Evento de cancelamento no SEFAZ (pelo TNFCeWebManager, que mora no form)
  LSucesso := False;
  LMensagem := '';
  try
    FOnCancelarNFCe(LCupomId, LJustificativa, LSucesso, LMensagem);
  except
    on E: Exception do
      Exit(CriarRespostaErro('Falha ao cancelar NFCe: ' + E.Message));
  end;

  if not LSucesso then
  begin
    if LMensagem = '' then
      LMensagem := 'A SEFAZ nao homologou o cancelamento';
    Exit(CriarRespostaErro(LMensagem));
  end;

  // 2. Registrar quem autorizou
  FSQLite.ExecutarSQL(
    'UPDATE cupons SET cancelado_por = :p0 WHERE id = :p1',
    [LMatAutorizou, LCupomId]
  );

  // 3. Estornar o TEF da venda (CNC). A nota ja esta cancelada; se o estorno
  //    falhar, o operador resolve pela lista de transacoes da aba TEF - por
  //    isso a contagem volta na resposta em vez de abortar tudo.
  LEstornos := 0;
  LFalhasEstorno := 0;
  LEstornosDisparados := 0;
  if FTEFHabilitado and (FTEFClient <> nil) then
  begin
    LQuery := FSQLite.ExecutarSelect(
      'SELECT id, controle, nsu, valor FROM tef_pendentes ' +
      'WHERE cupom_id = ' + IntToStr(LCupomId) +
      ' AND status NOT IN (''ESTORNADO'', ''DESFEITO'')'
    );
    try
      while not LQuery.Eof do
      begin
        // CliSiTef: o estorno pergunta coisas na tela (tipo, senha, cartao) e
        // este handler roda dentro do evento do WebView2, que nao entrega a
        // resposta enquanto ele nao voltar. Vai para segundo plano; cada
        // desfecho chega pelo 'tefEstornoResultado'.
        if FTEFConfig.Modo = tmCliSiTef then
        begin
          EstornarTEFEmSegundoPlano(LQuery.FieldByName('id').AsInteger, LCupomId,
            LQuery.FieldByName('valor').AsFloat, LQuery.FieldByName('nsu').AsString,
            LQuery.FieldByName('controle').AsString);
          Inc(LEstornosDisparados);
          LQuery.Next;
          Continue;
        end;
        try
          if FTEFClient.Cancelar(LCupomId,
               LQuery.FieldByName('valor').AsFloat,
               LQuery.FieldByName('nsu').AsString,
               LQuery.FieldByName('controle').AsString).Sucesso then
          begin
            FSQLite.ExecutarSQL(
              'UPDATE tef_pendentes SET status = ''ESTORNADO'', ' +
              'dthr_confirmacao = datetime(''now'',''localtime'') WHERE id = ' +
              IntToStr(LQuery.FieldByName('id').AsInteger)
            );
            Inc(LEstornos);
          end
          else
            Inc(LFalhasEstorno);
        except
          on E: Exception do
          begin
            Inc(LFalhasEstorno);
            SyncLog('CANCEL NFCe cupom=%d: falha no estorno TEF nsu=%s - %s',
              [LCupomId, LQuery.FieldByName('nsu').AsString, E.Message]);
          end;
        end;
        LQuery.Next;
      end;
    finally
      LQuery.Free;
    end;
  end;

  // 4. Subir o cancelamento para a retaguarda. Se o Oracle estiver fora,
  //    cancel_enviado fica 0 e o retry da sincronizacao cuida depois.
  if Assigned(FOnUploadVenda) then
  begin
    try
      FOnUploadVenda(LCupomId);
    except
      on E: Exception do
        SyncLog('CANCEL NFCe cupom=%d: falha no disparo do upload - [%s] %s',
          [LCupomId, E.ClassName, E.Message]);
    end;
  end;

  if LFalhasEstorno > 0 then
    LMensagem := LMensagem + Format(
      ' ATENCAO: %d transacao(oes) TEF nao puderam ser estornadas - ' +
      'estorne pela aba TEF.', [LFalhasEstorno]);
  if LEstornosDisparados > 0 then
    LMensagem := LMensagem + Format(
      ' Estorno TEF de %d transacao(oes) em andamento - siga as instrucoes ' +
      'na tela e no pinpad.', [LEstornosDisparados]);

  LDados := TJSONObject.Create;
  LDados.AddPair('cupomId', TJSONNumber.Create(LCupomId));
  LDados.AddPair('estornosTEF', TJSONNumber.Create(LEstornos));
  LDados.AddPair('falhasEstornoTEF', TJSONNumber.Create(LFalhasEstorno));
  LDados.AddPair('estornosTEFEmAndamento', TJSONNumber.Create(LEstornosDisparados));
  Result := CriarRespostaSucesso(LMensagem, LDados);
end;

{ Reimpressao (2a via) do DANFCe. Nao fala com a SEFAZ: o TNFCeWebManager
  recarrega o XML autorizado do disco e manda para a impressora configurada.
  Nota cancelada nao sai de novo - seria entregar ao cliente o documento de
  uma venda desfeita. }
function TApoloBridge.DoReimprimirCupom(const AData: string): string;
var
  LJson: TJSONObject;
  LQuery: TUniQuery;
  LCupomId: Integer;
  LChave, LMensagem: string;
  LSucesso: Boolean;
begin
  if not Assigned(FOnReimprimirNFCe) then
    Exit(CriarRespostaErro('Reimpressao nao disponivel (NFCe nao inicializada)'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));
  try
    LCupomId := LJson.GetValue<Integer>('cupomId', 0);
  finally
    LJson.Free;
  end;
  if LCupomId <= 0 then
    Exit(CriarRespostaErro('Cupom nao informado'));

  LQuery := FSQLite.ExecutarSelect(
    'SELECT chavenfe, cancelada FROM cupons WHERE id = ' + IntToStr(LCupomId));
  try
    if LQuery.Eof then Exit(CriarRespostaErro('Cupom nao encontrado'));
    if LQuery.FieldByName('cancelada').AsInteger = 1 then
      Exit(CriarRespostaErro('Nota cancelada nao pode ser reimpressa'));
    LChave := Trim(LQuery.FieldByName('chavenfe').AsString);
    if LChave = '' then
      Exit(CriarRespostaErro('Cupom sem NFCe emitida - nada a reimprimir'));
  finally
    LQuery.Free;
  end;

  LSucesso := False;
  LMensagem := '';
  try
    FOnReimprimirNFCe(LChave, LSucesso, LMensagem);
  except
    on E: Exception do
      Exit(CriarRespostaErro('Falha ao reimprimir: ' + E.Message));
  end;

  if not LSucesso then
  begin
    if LMensagem = '' then
      LMensagem := 'Falha ao reimprimir o cupom';
    Exit(CriarRespostaErro(LMensagem));
  end;

  Result := CriarRespostaSucesso('Cupom enviado para a impressora');
end;

// =========================================================================
// IMPRESSORA DO CUPOM - parametrizacao pela tela do PDV
// (secao [impressao] do apoloweb.ini)
// =========================================================================

function TApoloBridge.DoObterParametrosImpressora(const AData: string): string;
var
  LDados: TJSONObject;
  LImpressoras, LModelos: TJSONArray;
  LPadrao, LModelo: string;
  I: Integer;
begin
  LDados := TJSONObject.Create;

  LDados.AddPair('modo', DmApoloWeb.ModoImpressao);
  LDados.AddPair('impressora', DmApoloWeb.ImpressoraCupom);
  LDados.AddPair('escposModelo', DmApoloWeb.EscPosModelo);
  LDados.AddPair('escposPorta', DmApoloWeb.EscPosPorta);
  LDados.AddPair('escposColunas', TJSONNumber.Create(DmApoloWeb.EscPosColunas));
  LDados.AddPair('arquivoIni', ARQ_APOLOWEB_INI);

  // Impressoras instaladas no Windows (a lista alimenta o combo da tela)
  LImpressoras := TJSONArray.Create;
  LPadrao := '';
  try
    for I := 0 to Printer.Printers.Count - 1 do
      LImpressoras.Add(Printer.Printers[I]);
    if Printer.Printers.Count > 0 then
      LPadrao := Printer.Printers[Printer.PrinterIndex];
  except
    // maquina sem impressora instalada: lista vazia
  end;
  LDados.AddPair('impressoras', LImpressoras);
  LDados.AddPair('impressoraPadrao', LPadrao);

  LModelos := TJSONArray.Create;
  for LModelo in DmApoloWeb.ModelosPosPrinter do
    LModelos.Add(LModelo);
  LDados.AddPair('escposModelos', LModelos);

  // O modo SUMATRA depende destes executaveis (o segundo e o fallback)
  LDados.AddPair('temSumatra', TJSONBool.Create(FileExists(EXE_SUMATRA)));
  LDados.AddPair('temPrintCupon', TJSONBool.Create(FileExists(EXE_PRINTCUPON)));

  Result := CriarRespostaSucesso('OK', LDados);
end;

function TApoloBridge.DoSalvarParametrosImpressora(const AData: string): string;
var
  LJson: TJSONObject;
  LModo, LImpressora, LEscModelo, LEscPorta: string;
  LColunas: Integer;
  LIni: TIniFile;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LModo := UpperCase(Trim(LJson.GetValue<string>('modo', 'SUMATRA')));
    LImpressora := Trim(LJson.GetValue<string>('impressora', ''));
    LEscModelo := Trim(LJson.GetValue<string>('escposModelo', 'ppEscPosEpson'));
    LEscPorta := Trim(LJson.GetValue<string>('escposPorta', ''));
    LColunas := LJson.GetValue<Integer>('escposColunas', 48);

    if (LModo <> 'SUMATRA') and (LModo <> 'ESCPOS') then
      Exit(CriarRespostaErro('Modo de impressao invalido'));

    if (LColunas < 24) or (LColunas > 80) then
      Exit(CriarRespostaErro('Colunas deve ficar entre 24 e 80'));

    // Sem porta e sem impressora o ACBrPosPrinter nao tem para onde imprimir
    if (LModo = 'ESCPOS') and (LEscPorta = '') and (LImpressora = '') then
      Exit(CriarRespostaErro(
        'No modo ESCPOS informe a porta ou escolha a impressora'));

    if (LImpressora <> '') and (Printer.Printers.IndexOf(LImpressora) < 0) then
      Exit(CriarRespostaErro('Impressora nao instalada neste Windows: ' + LImpressora));

    try
      LIni := TIniFile.Create(ARQ_APOLOWEB_INI);
      try
        LIni.WriteString('impressao', 'modo', LModo);
        LIni.WriteString('impressao', 'impressora', LImpressora);
        LIni.WriteString('impressao', 'escpos_modelo', LEscModelo);
        LIni.WriteString('impressao', 'escpos_porta', LEscPorta);
        LIni.WriteInteger('impressao', 'escpos_colunas', LColunas);
      finally
        LIni.Free;
      end;
    except
      on E: Exception do
        Exit(CriarRespostaErro('Nao foi possivel gravar o ' +
          ExtractFileName(ARQ_APOLOWEB_INI) + ': ' + E.Message));
    end;

    // Aplica no ACBr sem reiniciar o caixa
    try
      DmApoloWeb.RecarregarConfiguracaoImpressao;
    except
      on E: Exception do
        Exit(CriarRespostaErro('Parametros gravados, mas a impressora nao pode ' +
          'ser reconfigurada agora: ' + E.Message));
    end;

    Result := CriarRespostaSucesso('Parametros da impressora salvos');
  finally
    LJson.Free;
  end;
end;

// Texto cru pelo spooler do Windows - mesmo caminho do resumo de fechamento
// quando o caixa nao esta em ESC/POS. Retorna '' quando imprimiu.
function TApoloBridge.ImprimirTexto(const ATexto, AImpressora: string): string;
var
  LArquivo, LImpressora: string;
begin
  Result := '';
  LImpressora := Trim(AImpressora);
  try
    if LImpressora = '' then
    begin
      if Printer.Printers.Count = 0 then
        Exit('Nenhuma impressora instalada no Windows');
      LImpressora := Printer.Printers[Printer.PrinterIndex];
    end;

    LArquivo := PASTA_RAIZ + 'teste_impressao.txt';
    TFile.WriteAllText(LArquivo, ATexto, TEncoding.ANSI);
    RawPrintToPrinter(LImpressora, LArquivo);
  except
    on E: Exception do
      Result := E.Message;
  end;
end;

// Imprime um cupom de teste com a configuracao JA SALVA (a tela avisa quando
// ha alteracao pendente). Em ESCPOS sai pela termica via ACBrPosPrinter; nos
// demais casos vai como texto cru para a impressora do Windows.
function TApoloBridge.DoTestarImpressao(const AData: string): string;
var
  LTexto: TStringBuilder;
  LErro, LLargura: string;
  LColunas: Integer;
  LDados: TJSONObject;
begin
  LColunas := DmApoloWeb.EscPosColunas;
  if (LColunas < 24) or (LColunas > 80) then
    LColunas := 48;
  LLargura := StringOfChar('=', LColunas);

  LTexto := TStringBuilder.Create;
  try
    LTexto.AppendLine(LLargura);
    LTexto.AppendLine('TESTE DE IMPRESSAO - ' + NOME_SISTEMA);
    LTexto.AppendLine(LLargura);
    LTexto.AppendLine('Caixa......: ' + FSQLite.ObterEstado(KEY_NUMCAIXA, '?'));
    LTexto.AppendLine('Modo.......: ' + DmApoloWeb.ModoImpressao);
    if DmApoloWeb.ImpressaoEscPos then
    begin
      LTexto.AppendLine('Modelo.....: ' + DmApoloWeb.EscPosModelo);
      // A porta EFETIVA do componente, nao a do ini: quando as duas divergem
      // e porque a reconfiguracao nao pegou, e era exatamente isso que ficava
      // invisivel (cupom saindo na porta antiga, ou em lugar nenhum).
      if DmApoloWeb.PosPrinter <> nil then
        LTexto.AppendLine('Porta......: ' + DmApoloWeb.PosPrinter.Porta)
      else
        LTexto.AppendLine('Porta......: ' + DmApoloWeb.EscPosPorta);
      LTexto.AppendLine('Colunas....: ' + IntToStr(DmApoloWeb.EscPosColunas));
    end;
    LTexto.AppendLine('Impressora.: ' + DmApoloWeb.ImpressoraCupom);
    LTexto.AppendLine('Data/hora..: ' + FormatDateTime('dd/mm/yyyy hh:nn:ss', Now));
    LTexto.AppendLine(StringOfChar('-', LColunas));
    LTexto.AppendLine('0123456789 ABCDEFGHIJ acentos: aeiou');
    LTexto.AppendLine('Se esta linha saiu inteira, a largura esta correta.');
    LTexto.AppendLine(LLargura);

    LErro := '';
    if DmApoloWeb.ImpressaoEscPos and (DmApoloWeb.PosPrinter <> nil) then
    begin
      try
        DmApoloWeb.PosPrinter.Ativar;
        DmApoloWeb.PosPrinter.Imprimir('</zera>' + sLineBreak +
          LTexto.ToString + '</corte_total>');
      except
        on E: Exception do
          LErro := E.Message;
      end;
    end
    else
      LErro := ImprimirTexto(
        LTexto.ToString + sLineBreak + sLineBreak + sLineBreak,
        DmApoloWeb.ImpressoraCupom);
  finally
    LTexto.Free;
  end;

  if LErro <> '' then
    Exit(CriarRespostaErro('Falha ao imprimir: ' + LErro));

  LDados := TJSONObject.Create;
  LDados.AddPair('modo', DmApoloWeb.ModoImpressao);
  Result := CriarRespostaSucesso('Cupom de teste enviado para a impressora', LDados);
end;

function TApoloBridge.DoConsultarStatusTEF(const AData: string): string;
var
  LOnline: Boolean;
  LDados: TJSONObject;
begin
  if not FTEFHabilitado then
    Exit(CriarRespostaErro('TEF nao habilitado'));
  if FTEFClient = nil then
    Exit(CriarRespostaErro('TEF nao inicializado'));

  LOnline := FTEFClient.ConsultarStatus;
  LDados := TJSONObject.Create;
  LDados.AddPair('online', TJSONBool.Create(LOnline));
  Result := CriarRespostaSucesso('OK', LDados);
end;

function TApoloBridge.DoIniciarPagamentoTEF(const AData: string): string;
var
  LJson: TJSONObject;
  LValor: Double;
  LTipoTransacao, LParcelas: string;
  LDocFiscal, LCupomId: Integer;
begin
  if not FTEFHabilitado then
    Exit(CriarRespostaErro('TEF nao habilitado'));
  if FTEFClient = nil then
    Exit(CriarRespostaErro('TEF nao inicializado'));

  if (FEstadoCaixa <> ecRegistrando) and (FEstadoCaixa <> ecPagamento) then
    Exit(CriarRespostaErro('Nao ha venda em andamento'));

  // Depois de um cancelamento a tela libera o operador, mas o gerenciador
  // pode seguir com a transacao anterior ate o timeout. Um intpos.001 novo
  // por cima dela seria ignorado (ou trocaria a resposta de uma pela outra).
  if FTEFEmCurso then
    Exit(CriarRespostaErro('O TEF ainda esta finalizando a transacao ' +
      'anterior. Cancele no pinpad e aguarde alguns segundos.'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LValor := LJson.GetValue<Double>('valor', 0);
    LTipoTransacao := LJson.GetValue<string>('tipoTransacao', 'credito');
    LParcelas := LJson.GetValue<string>('parcelas', '01');

    if LValor <= 0 then
      Exit(CriarRespostaErro('Valor invalido'));

    // Transicionar para estado pagamento se necessario
    if FEstadoCaixa = ecRegistrando then
    begin
      FEstadoCaixa := ecPagamento;
      FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));
    end;

    LDocFiscal := FCupomAtualId;
    LCupomId := FCupomAtualId;

    // Retornar imediatamente - TEF roda em thread separada
    Result := CriarRespostaSucesso('Processando TEF, aguarde...');
    FTEFEmCurso := True;

    // Thread para chamada TEF (pode levar ate 120s no pinpad)
    TThread.CreateAnonymousThread(
      procedure
      var
        LResp: TTEFResposta;
        LResultJson: TJSONObject;
        LCodCob: string;
        LCodTipoTransacao: Integer;
      begin
        try
          LResp := FTEFClient.Transacionar(LDocFiscal, LValor, LTipoTransacao, LParcelas);

          TThread.Queue(nil,
            procedure
            begin
              // Liberado aqui; so o desfazimento abaixo o segura ate o NCN
              FTEFEmCurso := False;
              LResultJson := TJSONObject.Create;
              try
                LResultJson.AddPair('sucesso', TJSONBool.Create(LResp.Sucesso and
                  not LResp.CanceladoOperador));
                // Vai nos dois desfechos: e' o que faz a tela fechar o modal
                // do QR tambem quando o PIX e' recusado ou da timeout
                LResultJson.AddPair('ehPix',
                  TJSONBool.Create(SameText(LTipoTransacao, 'pix')));
                LResultJson.AddPair('canceladoOperador',
                  TJSONBool.Create(LResp.CanceladoOperador));

                // Aprovacao que chegou depois de o operador cancelar: a tela
                // ja foi liberada e a venda pode ter seguido com outro meio de
                // pagamento. Nao entra no cupom - vai direto para o NCN.
                if LResp.Sucesso and LResp.CanceladoOperador then
                begin
                  TEFLog(Format('TEF aprovado (NSU %s, controle %s, venda %d) ' +
                    'DEPOIS do cancelamento pelo operador - desfazendo',
                    [LResp.NSU, LResp.Controle, LCupomId]));
                  DesfazerTEFNaoRegistrado(LCupomId, LResp.Controle);
                  LResultJson.AddPair('desfeita', TJSONBool.Create(True));
                  LResultJson.AddPair('erro',
                    'O TEF aprovou depois do cancelamento (NSU ' + LResp.NSU +
                    ') e a transacao foi desfeita. Confira o pinpad/comprovante ' +
                    'antes de cobrar de novo.');
                end
                else

                // Este bloco roda na thread principal, FORA do try/except da
                // thread do TEF. Uma excecao aqui (ex: "database is locked" do
                // SQLite com a sincronizacao gravando) pulava o envio do
                // tefResultado: o modal do QR PIX (sem ESC) ficava na tela para
                // sempre, sem comprovante e sem cupom, com a transacao aprovada
                // e nunca confirmada. Agora a falha vira resultado de erro e a
                // transacao e' desfeita, ja' que nao ficou registrada na venda.
                if LResp.Sucesso then
                try
                  // Usar valor da resposta TEF; se zero, usar o valor solicitado
                  var LValorFinal: Double;
                  if LResp.Valor > 0 then
                    LValorFinal := LResp.Valor
                  else
                    LValorFinal := LValor;

                  // Determinar codcob
                  if SameText(LTipoTransacao, 'pix') then
                    LCodCob := '17'
                  else
                    LCodCob := '03';

                  // codtipotransacao: 1=credito, 2=debito. O PIX nao e nem um
                  // nem outro - marcar como credito subia PIX disfarcado de
                  // cartao para a retaguarda (msapolo_venda_pagto) e ainda
                  // fazia a NFCe cair no ramo de cartao se o meiopagto do
                  // retaguarda mapeasse o codcob 17 para cmp 03/04.
                  if SameText(LTipoTransacao, 'debito') then
                    LCodTipoTransacao := 2
                  else if SameText(LTipoTransacao, 'pix') then
                    LCodTipoTransacao := 0
                  else
                    LCodTipoTransacao := 1;

                  // Montar comprovantes TEF como texto
                  var LCompCliente := '';
                  var LCompLoja := '';
                  var I: Integer;
                  for I := 0 to High(LResp.ImpressoCliente) do
                  begin
                    if LCompCliente <> '' then LCompCliente := LCompCliente + #13#10;
                    LCompCliente := LCompCliente + LResp.ImpressoCliente[I];
                  end;
                  for I := 0 to High(LResp.ImpressoLoja) do
                  begin
                    if LCompLoja <> '' then LCompLoja := LCompLoja + #13#10;
                    LCompLoja := LCompLoja + LResp.ImpressoLoja[I];
                  end;

                  // Registrar transacao TEF pendente (para confirmar/desfazer depois)
                  FSQLite.ExecutarSQL(
                    'INSERT INTO tef_pendentes (cupom_id, controle, nsu, cod_autorizacao, ' +
                    'valor, tipo_transacao, bandeira, parcelas, codcob, status, dthr_transacao, ' +
                    'comprovante_cliente, comprovante_loja) ' +
                    'VALUES (:p0, :p1, :p2, :p3, :p4, :p5, :p6, :p7, :p8, ''PENDENTE'', ' +
                    'datetime(''now'',''localtime''), :p9, :p10)',
                    [LCupomId, LResp.Controle, LResp.NSU, LResp.CodigoAutorizacao,
                     LValorFinal, LTipoTransacao, LResp.Bandeira,
                     LResp.Parcelas, LCodCob, LCompCliente, LCompLoja]
                  );

                  // Registrar pagamento no cupom (mesmo fluxo do DoRegistrarPagamento)
                  FSQLite.ExecutarSQL(
                    'INSERT INTO cupom_pagamentos (cupom_id, codcob, valor, ' +
                    'codtipotransacao, codbandeira, codautorizacao, nsu, ' +
                    'qtdeparcela, dthroperacao) ' +
                    'VALUES (:p0, :p1, :p2, :p3, :p4, :p5, :p6, :p7, ' +
                    'datetime(''now'',''localtime''))',
                    [LCupomId, LCodCob, LValorFinal,
                     LCodTipoTransacao, StrToIntDef(LResp.CodigoBandeira, 0),
                     LResp.CodigoAutorizacao, LResp.NSU, LResp.Parcelas]
                  );

                  LResultJson.AddPair('nsu', LResp.NSU);
                  LResultJson.AddPair('codAutorizacao', LResp.CodigoAutorizacao);
                  LResultJson.AddPair('bandeira', LResp.Bandeira);
                  LResultJson.AddPair('valor', TJSONNumber.Create(LValorFinal));
                  LResultJson.AddPair('controle', LResp.Controle);
                  LResultJson.AddPair('tipoTransacao', LResp.TipoTransacao);
                  LResultJson.AddPair('parcelas', TJSONNumber.Create(LResp.Parcelas));
                  LResultJson.AddPair('tipoCartao', LResp.TipoCartao);
                  LResultJson.AddPair('qrCode', LResp.QrCode);
                except
                  on E: Exception do
                  begin
                    var LErroReg := E.Message;
                    TEFLog(Format('TEF aprovado (NSU %s, controle %s) mas falhou ' +
                      'ao registrar na venda %d: %s - desfazendo',
                      [LResp.NSU, LResp.Controle, LCupomId, LErroReg]));

                    // Nao deixar tef_pendentes orfao (o 2o INSERT pode ter
                    // falhado depois do 1o) nem pagamento parcial no cupom
                    try
                      FSQLite.ExecutarSQL(
                        'DELETE FROM cupom_pagamentos WHERE cupom_id = :p0 ' +
                        'AND nsu = :p1 AND codcob = :p2',
                        [LCupomId, LResp.NSU, LCodCob]);
                      FSQLite.ExecutarSQL(
                        'DELETE FROM tef_pendentes WHERE cupom_id = :p0 ' +
                        'AND controle = :p1 AND status = ''PENDENTE''',
                        [LCupomId, LResp.Controle]);
                    except
                      on E2: Exception do
                        TEFLog('falha ao limpar registro TEF: ' + E2.Message);
                    end;

                    DesfazerTEFNaoRegistrado(LCupomId, LResp.Controle);

                    LResultJson.Free;
                    LResultJson := TJSONObject.Create;
                    LResultJson.AddPair('sucesso', TJSONBool.Create(False));
                    LResultJson.AddPair('ehPix',
                      TJSONBool.Create(SameText(LTipoTransacao, 'pix')));
                    LResultJson.AddPair('erro',
                      'Transacao aprovada mas nao foi possivel registrar na ' +
                      'venda (' + LErroReg + '). A transacao foi desfeita - ' +
                      'repita o pagamento.');
                  end;
                end
                else
                  LResultJson.AddPair('erro', LResp.Erro);

                if Assigned(FOnEnviarParaJS) then
                  FOnEnviarParaJS('tefResultado', LResultJson.ToJSON);
              finally
                LResultJson.Free;
              end;
            end
          );
        except
          on E: Exception do
          begin
            var LErrMsg := E.Message; // capturar antes do Queue (E sera destruido)
            TThread.Queue(nil,
              procedure
              var
                LErrJson: TJSONObject;
              begin
                FTEFEmCurso := False;
                LErrJson := TJSONObject.Create;
                try
                  LErrJson.AddPair('sucesso', TJSONBool.Create(False));
                  LErrJson.AddPair('erro', LErrMsg);
                  if Assigned(FOnEnviarParaJS) then
                    FOnEnviarParaJS('tefResultado', LErrJson.ToJSON);
                finally
                  LErrJson.Free;
                end;
              end
            );
          end;
        end;
      end
    ).Start;
  finally
    LJson.Free;
  end;
end;

// Cada via (cliente e loja) sai como um bloco proprio pelo caminho do cupom:
// em ESCPOS a guilhotina corta entre elas; nos demais modos vai texto cru.
procedure TApoloBridge.ImprimirComprovantesTEF(ACupomId: Integer);
var
  LQuery: TUniQuery;
  LTexto, LErro: string;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT nsu, comprovante_cliente, comprovante_loja FROM tef_pendentes ' +
    'WHERE cupom_id = ' + IntToStr(ACupomId) +
    ' AND (comprovante_cliente <> '''' OR comprovante_loja <> '''')'
  );
  try
    while not LQuery.Eof do
    begin
      // Imprimir via cliente (1a via)
      LTexto := LQuery.FieldByName('comprovante_cliente').AsString;
      if LTexto <> '' then
      begin
        LErro := ImprimirTextoCupom(LTexto);
        if LErro <> '' then
          raise Exception.Create(LErro);
      end;

      // Imprimir via loja (2a via)
      LTexto := LQuery.FieldByName('comprovante_loja').AsString;
      if LTexto <> '' then
      begin
        LErro := ImprimirTextoCupom(LTexto);
        if LErro <> '' then
          raise Exception.Create(LErro);
      end;

      LQuery.Next;
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TApoloBridge.ImprimirViasTEF(const ACliente, ALoja: TArray<string>);
var
  LErro: string;
begin
  if Length(ACliente) > 0 then
  begin
    LErro := ImprimirTextoCupom(string.Join(#13#10, ACliente));
    if LErro <> '' then
      raise Exception.Create(LErro);
  end;
  if Length(ALoja) > 0 then
  begin
    LErro := ImprimirTextoCupom(string.Join(#13#10, ALoja));
    if LErro <> '' then
      raise Exception.Create(LErro);
  end;
end;

procedure TApoloBridge.ConfirmarTEFPendentes(ACupomId: Integer);
var
  LQuery: TUniQuery;
begin
  if (FTEFClient = nil) or (not FTEFHabilitado) then Exit;

  LQuery := FSQLite.ExecutarSelect(
    'SELECT id, controle FROM tef_pendentes ' +
    'WHERE cupom_id = ' + IntToStr(ACupomId) + ' AND status = ''PENDENTE'''
  );
  try
    while not LQuery.Eof do
    begin
      DispararResolucaoTEF(ACupomId, LQuery.FieldByName('id').AsInteger,
        LQuery.FieldByName('controle').AsString, True);
      LQuery.Next;
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TApoloBridge.DesfazerTEFPendentes(ACupomId: Integer);
var
  LQuery: TUniQuery;
begin
  if (FTEFClient = nil) or (not FTEFHabilitado) then Exit;

  LQuery := FSQLite.ExecutarSelect(
    'SELECT id, controle FROM tef_pendentes ' +
    'WHERE cupom_id = ' + IntToStr(ACupomId) + ' AND status = ''PENDENTE'''
  );
  try
    while not LQuery.Eof do
    begin
      DispararResolucaoTEF(ACupomId, LQuery.FieldByName('id').AsInteger,
        LQuery.FieldByName('controle').AsString, False);
      LQuery.Next;
    end;
  finally
    LQuery.Free;
  end;
end;

{ Desfaz (NCN) uma aprovacao que nao entrou na venda - cancelada pelo
  operador antes de chegar, ou que falhou ao gravar no cupom. Mantem
  FTEFEmCurso ligado ate o NCN terminar: uma venda TEF nova disparada nesse
  meio-tempo disputaria os mesmos arquivos com o desfazimento. Metodo proprio
  para o anonimo capturar os parametros por valor (ver DispararResolucaoTEF). }
procedure TApoloBridge.DesfazerTEFNaoRegistrado(ACupomId: Integer;
  const AControle: string);
var
  LControle: string;
begin
  LControle := AControle;
  FTEFEmCurso := True;
  TThread.CreateAnonymousThread(
    procedure
    begin
      try
        FTEFClient.Desfazer(ACupomId, LControle);
        TEFLog(Format('TEF controle %s (venda %d) desfeito', [LControle, ACupomId]));
      except
        on E: Exception do
          TEFLog('falha ao desfazer TEF nao registrado: ' + E.Message);
      end;
      TThread.Queue(nil,
        procedure
        begin
          FTEFEmCurso := False;
        end
      );
    end
  ).Start;
end;

// Pedido do operador na tela de espera (botao / ESC). Retorna na hora: o
// desfecho chega pelo tefResultado com canceladoOperador=true - em ate
// ~3s se o gerenciador ainda nao tinha lido a venda, ou quando ele responder
// (ate o timeout) se o pinpad ja estava com ela.
function TApoloBridge.DoCancelarTEF(const AData: string): string;
begin
  if (FTEFClient = nil) or (not FTEFEmCurso) then
    Exit(CriarRespostaErro('Nenhuma transacao TEF em andamento'));

  FTEFClient.SolicitarCancelamento;
  TEFLog('cancelamento do TEF pedido pelo operador (venda %d)', [FCupomAtualId]);
  Result := CriarRespostaSucesso('Cancelamento solicitado');
end;

{ Confirma (ou desfaz) UMA transacao TEF em thread.

  Existe para o metodo anonimo capturar os parametros DESTA chamada. Antes o
  thread era criado dentro do laco e capturava as variaveis locais LId e
  LControle - que em Delphi sao capturadas por referencia, nao por valor. Numa
  venda com dois cartoes o laco ja' tinha andado quando os threads liam as
  variaveis: os dois podiam confirmar o controle do ultimo cartao e o primeiro
  ficava PENDENTE no TEF, sujeito a desfazimento. }
procedure TApoloBridge.DispararResolucaoTEF(ACupomId, AId: Integer;
  const AControle: string; AConfirmar: Boolean);
var
  LControle: string;
begin
  LControle := AControle;
  TThread.CreateAnonymousThread(
    procedure
    var
      LStatus: string;
    begin
      try
        if AConfirmar then
        begin
          FTEFClient.Confirmar(ACupomId, LControle);
          LStatus := 'CONFIRMADO';
        end
        else
        begin
          FTEFClient.Desfazer(ACupomId, LControle);
          LStatus := 'DESFEITO';
        end;
        TThread.Queue(nil,
          procedure
          begin
            FSQLite.ExecutarSQL(
              'UPDATE tef_pendentes SET status = ' + QuotedStr(LStatus) + ', ' +
              'dthr_confirmacao = datetime(''now'',''localtime'') WHERE id = ' +
              IntToStr(AId)
            );
          end
        );
      except
        // Falha na confirmacao/desfazimento - permanece PENDENTE para retry
        // futuro
      end;
    end
  ).Start;
end;

end.
