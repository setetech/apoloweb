unit uTEFCliSiTef;

{ ============================================================================
  TEF direto pela CliSiTef32I.dll (SiTef / Fiserv) - [TEF] modo=clisitef

  Nao ha gerenciador no meio (nem Tef_Dial, nem TefGpAPI): o proprio PDV
  carrega a DLL e conversa com ela pelas rotinas interativas

    ConfiguraIntSiTefInterativoEx(IP, Loja, Terminal, 0, ParamAdic)
    IniciaFuncaoSiTefInterativo(Funcao, Valor, Cupom, Data, Hora, Operador, Restricoes)
    ContinuaFuncaoSiTefInterativo(...)   <- laco ate devolver <> 10000
    FinalizaFuncaoSiTefInterativo(Confirma, Cupom, Data, Hora, ParamAdic)
    VerificaPresencaPinPad

  --------------------------------------------------------------------------
  A CLISITEF E' INTERATIVA
  --------------------------------------------------------------------------
  Cada ContinuaFuncaoSiTefInterativo devolve um "proximo comando": mostrar uma
  mensagem, apresentar um menu (credito a vista / parcelado ...), perguntar
  sim/nao, coletar um campo (parcelas, CPF, data, NSU). Nenhum desses comandos
  tem tela pronta - quem desenha e' a automacao. Aqui eles viram JSON e saem
  por ITEFClient.SetOnInteracao (o uBridge empurra para o WebView como
  'tefInteracao'); a resposta volta por ResponderInteracao ('responderTEF').

  --------------------------------------------------------------------------
  UMA THREAD SO PARA A DLL
  --------------------------------------------------------------------------
  A CliSiTef guarda estado global (a transacao em curso, a configuracao) e
  nao e' reentrante. O uBridge chama o cliente de threads anonimas diferentes
  (venda, confirmacao, desfazimento, estorno, teste) - todas as chamadas a DLL
  passam por uma fila e rodam numa unica thread dedicada (TCliSiTefThread),
  uma de cada vez, no processo inteiro. Quem chama espera a sua vez.

  --------------------------------------------------------------------------
  CONFIRMACAO
  --------------------------------------------------------------------------
  O FinalizaFuncaoSiTefInterativo identifica as transacoes por cupom fiscal +
  data fiscal. Sem parametro adicional ele confirma/desfaz TODOS os
  pagamentos do cupom; com NumeroPagamentoCupom=N entre chaves (N = campo 161 da
  resposta) so aquele. Por isso o 'controle' devolvido em TTEFResposta leva
  cupom|AAAAMMDD|HHMMSS|N, e todas as transacoes de uma venda usam a data e a
  hora fiscal da primeira.

  --------------------------------------------------------------------------
  PARAMETROS ADICIONAIS ([TEF] sitef_param_adic)
  --------------------------------------------------------------------------
  Lista chave=valor separada por ';' (ex: PortaPinPad=AUTO_USB). Vai entre
  colchetes no ConfiguraIntSiTefInterativoEx. Se o texto ja vier com
  colchetes, vai como esta.

  TLS da Fiserv: o kit em C:\Apolo\clisitef traz o CONFITLS.INI
  (TipoComunicacaoExterna, URLTLS e o TokenRegistro) e a propria DLL resolve.
  So quando NAO houver CONFITLS.INI na pasta da DLL, servidor *.fiservapp.com
  e nenhum TipoComunicacaoExterna informado, entra TipoComunicacaoExterna=
  TLSGWP - o mesmo padrao do ACBr. O conteudo do CONFITLS.INI nunca vai para o
  log (tem o token).

  --------------------------------------------------------------------------
  PASTA DO KIT
  --------------------------------------------------------------------------
  A CliSiTef procura CliSiTef.ini / CONFITLS.INI na pasta dela e no diretorio
  corrente, e carrega libcurl32, libemv, QREncode32 e RechargeRPC por NOME
  (LoadLibraryA, sem caminho). O ApoloWeb.dpr faz SetDllDirectory para
  c:\colosso\prod\dlls, o que tira a pasta do kit da busca - entao:
    - essas DLLs sao pre-carregadas pelo caminho completo antes da CliSiTef
      (um modulo ja carregado e' reaproveitado pelo nome);
    - o diretorio corrente vira a pasta da DLL durante a carga e o
      ConfiguraIntSiTefInterativo, e volta ao que era logo depois.
  O libcurl32 do kit usa o Schannel do Windows (CRYPT32), nao o OpenSSL: nao
  conflita com libcrypto-1_1 / libssl-1_1 / libeay32 do C:\Apolo.
  ============================================================================ }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON,
  System.Generics.Collections, uTEF;

type
  TTEFClientCliSiTef = class(TTEFClientBase)
  private
    FDll: string;
    FIP: string;
    FLoja: string;
    FTerminal: string;
    FParamAdic: string;

    // Pergunta no ar: escrita na thread da DLL, respondida pela principal
    FLockResp: TCriticalSection;
    FEventoResp: TEvent;
    FSeqPergunta: Integer;
    FPerguntaId: Integer;        // 0 = nenhuma pergunta esperando
    FRespAcao: string;
    FRespValor: string;
    // A operacao foi pedida pela thread principal (ex: teste de conexao):
    // ninguem vai conseguir responder pergunta nenhuma - o handler do WebView2
    // esta preso esperando. Pergunta, nesse caso, e' cancelada na hora.
    FChamadaDaPrincipal: Boolean;

    // Data/hora fiscal de cada venda (so mexido na thread da DLL)
    FDataHoraCupom: TDictionary<Integer, TDateTime>;
    FUltimaMensagem: string;

    function ParamAdicConfig: string;
    procedure Preparar;
    procedure NaThreadDaDLL(const AProc: TProc; ATimeoutMs: Cardinal = INFINITE);

    procedure Interagir(AJson: TJSONObject);
    procedure Mensagem(const ATexto, AVisor: string);
    function Perguntar(AJson: TJSONObject; out AValor: string): Integer;

    function ExecutarFuncao(AFuncao: Integer; AValor: Double;
      const ACupom: string; ADataHora: TDateTime; const ARestricoes: string;
      AAutomaticas, ACampos: TDictionary<Integer, string>): Integer;
    function MontarResposta(ARetorno: Integer; ACampos: TDictionary<Integer, string>;
      const ATipoSolicitado: string; const ACupom: string;
      ADataHora: TDateTime): TTEFResposta;
    procedure Finalizar(AConfirma: Boolean; const AControle: string);
  public
    constructor Create(const AConfig: TTEFConfig);
    destructor Destroy; override;

    function Transacionar(ADocFiscal: Integer; AValorTotal: Double;
      const ATipoTransacao, AParcelas: string): TTEFResposta; override;
    function Confirmar(ADocFiscal: Integer; const AControle: string): TTEFResposta; override;
    function Desfazer(ADocFiscal: Integer; const AControle: string): TTEFResposta; override;
    function Cancelar(ADocFiscal: Integer; AValor: Double;
      const ANSU, AControle: string): TTEFResposta; override;
    function ConsultarStatus: Boolean; override;
    function Administracao: TTEFResposta; override;
    function Modo: TTEFModo; override;
    function Descricao: string; override;

    procedure SolicitarCancelamento; override;
    procedure ResponderInteracao(AId: Integer; const AAcao, AValor: string); override;
  end;

  { Arquivos do kit (pasta da DLL), editaveis pela aba TEF do PDV:
      CliSiTef.ini  [PinPadCompartilhado] Porta, [CliSiTef] HabilitaTrace
      CONFITLS.INI  [ConfiguracaoTLS] TipoComunicacaoExterna, URLTLS,
                    TokenRegistro
    O token nunca sai daqui: so se informa SE esta configurado. }
  TCliSiTefKit = record
    Pasta: string;
    Versao: string;            // 1a linha do RELEASE.TXT do kit
    DllExiste: Boolean;
    IniExiste: Boolean;
    PortaPinPad: string;       // AUTO_USB, COM3, ...
    Trace: Boolean;
    TlsExiste: Boolean;
    TlsTipo: string;
    TlsUrl: string;
    TokenConfigurado: Boolean;
  end;

// Texto do retorno da IniciaFuncao/ContinuaFuncao (0 = sucesso)
function CliSiTefErroTransacao(ARetorno: Integer): string;
function CliSiTefErroConfiguracao(ARetorno: Integer): string;

function CliSiTefLerKit(const ADll: string): TCliSiTefKit;
// ATokenNovo vazio mantem o token gravado. Levanta excecao com o motivo.
procedure CliSiTefGravarKit(const ADll, APortaPinPad: string; ATrace: Boolean;
  const ATlsUrl, ATokenNovo: string);
// O kit mudou: a proxima operacao refaz o ConfiguraIntSiTefInterativo
procedure CliSiTefReconfigurar;
// Token de registro da Fiserv: 0000-0000-0000-0000
function CliSiTefTokenValido(const AToken: string): Boolean;

implementation

uses
  Winapi.Windows, Winapi.Messages, System.StrUtils, System.DateUtils,
  System.IOUtils, Vcl.Forms, uTEFLog;

const
  // Funcoes do IniciaFuncaoSiTefInterativo
  FN_DEBITO        = 2;
  FN_CREDITO       = 3;
  FN_ADMINISTRATIVO = 110;
  FN_CARTEIRA_DIGITAL = 122;   // PIX / carteiras digitais
  FN_CANCELAMENTO  = 200;

  RET_SUCESSO   = 0;
  RET_CONTINUA  = 10000;

  // ContinuaNavegacao
  CONT_CONTINUA = 0;
  CONT_RETORNA  = 1;    // volta para a coleta/menu anterior
  CONT_ENCERRA  = -1;   // aborta a funcao

  TAM_BUFFER = 20480;
  // Alocado alem do TAM_BUFFER informado a DLL: um estouro pequeno dela cai
  // na folga em vez de no cabecalho do bloco vizinho do heap
  FOLGA_BUFFER = 4096;

  // Tipos de campo (ProximoComando = 0)
  TC_MODALIDADE      = 100;  // 2 digitos tipo cartao + 2 digitos financiamento
  TC_DATAHORA        = 105;  // AAAAMMDDhhmmss
  TC_CANCELAMENTO    = 110;  // a funcao foi um cancelamento: tem de confirmar
  TC_VIA_CLIENTE     = 121;
  TC_VIA_LOJA        = 122;
  TC_INSTITUICAO     = 131;
  TC_BANDEIRA        = 132;  // codigo da bandeira padrao SiTef
  TC_NSU_SITEF       = 133;
  TC_NSU_HOST        = 134;
  TC_AUTORIZACAO     = 135;
  TC_BIN             = 136;
  TC_REDE            = 156;  // nome da instituicao / rede
  TC_REDE_AUTORIZ    = 158;
  TC_NUM_PAGAMENTO   = 161;  // numero do pagamento no cupom (NumeroPagamentoCupom)
  TC_PARCELAS        = 505;
  TC_DATA_CANCELAR   = 515;  // DDMMAAAA da transacao a cancelar
  TC_NSU_CANCELAR    = 516;
  TC_VALOR_CANCELAR  = 146;
  TC_VALOR_CANCELAR2 = 147;
  TC_QRCODE          = 584;

  // Espera maxima por uma resposta da tela; depois disso a coleta e' cancelada
  ESPERA_MINIMA_RESPOSTA_SEG = 60;
  // Teste de conexao/pinpad chamado da thread principal
  TIMEOUT_STATUS_MS = 20000;

  // Carregadas pela CliSiTef por nome; vao antes, pelo caminho do kit
  DEPENDENCIAS_KIT: array[0..3] of string = ('libcurl32.dll', 'libemv.dll',
    'QREncode32.dll', 'RechargeRPC.dll');
  ARQ_CONFITLS = 'CONFITLS.INI';
  ARQ_CLISITEF_INI = 'CliSiTef.ini';
  ARQ_RELEASE = 'RELEASE.TXT';

type
  TConfiguraIntSiTefInterativoEx = function(pEnderecoIP, pCodigoLoja,
    pNumeroTerminal: PAnsiChar; ConfiguraResultado: SmallInt;
    pParametrosAdicionais: PAnsiChar): Integer; stdcall;
  TConfiguraIntSiTefInterativo = function(pEnderecoIP, pCodigoLoja,
    pNumeroTerminal: PAnsiChar; ConfiguraResultado: SmallInt): Integer; stdcall;
  TIniciaFuncaoSiTefInterativo = function(Modalidade: Integer;
    pValor, pNumeroCuponFiscal, pDataFiscal, pHorario, pOperador,
    pRestricoes: PAnsiChar): Integer; stdcall;
  // Comando/TamMinimo/TamMaximo vao como ponteiro para um Integer inteiro (ver
  // ExecutarFuncao): o manual diz short*, mas se a DLL gravar 4 bytes ali ela
  // nao pode invadir as variaveis vizinhas. Com SmallInt local, o fim de toda
  // funcao (venda, PIX, ADM) dava "Invalid pointer operation" - inclusive
  // depois de a transacao ser APROVADA, que ficava pendente e sem registro.
  TContinuaFuncaoSiTefInterativo = function(pProximoComando: PInteger;
    pTipoCampo: PInteger; pTamanhoMinimo: PInteger; pTamanhoMaximo: PInteger;
    pBuffer: PAnsiChar; TamMaxBuffer: Integer;
    ContinuaNavegacao: Integer): Integer; stdcall;
  TFinalizaFuncaoSiTefInterativo = procedure(pConfirma: SmallInt;
    pCupomFiscal, pDataFiscal, pHoraFiscal, pParamAdic: PAnsiChar); stdcall;
  TVerificaPresencaPinPad = function: Integer; stdcall;
  TObtemVersao = function(pVersaoCliSiTef, pVersaoCliSiTefI: PAnsiChar): Integer; stdcall;

  { Uma chamada enfileirada para a thread da DLL }
  ICliSiTefTarefa = interface
    ['{5D0E7B6C-2A41-4F3B-8E19-C7A2B4D6E801}']
    procedure Rodar;
    function Esperar(ATimeoutMs: Cardinal; ABombearMensagens: Boolean): Boolean;
    procedure Abandonar;
    function Erro: string;
  end;

  TCliSiTefTarefa = class(TInterfacedObject, ICliSiTefTarefa)
  private
    FProc: TProc;
    FFim: TEvent;
    FErro: string;
    FLock: TCriticalSection;
    FIniciada: Boolean;
    FAbandonada: Boolean;
  public
    constructor Create(const AProc: TProc);
    destructor Destroy; override;
    procedure Rodar;
    function Esperar(ATimeoutMs: Cardinal; ABombearMensagens: Boolean): Boolean;
    procedure Abandonar;
    function Erro: string;
  end;

  { A thread unica da DLL - dona do handle e da configuracao }
  TCliSiTefThread = class(TThread)
  private
    FFila: TThreadedQueue<ICliSiTefTarefa>;
    FOcupada: Boolean;
    FHandle: HMODULE;
    FDependencias: TList<HMODULE>;
    FCaminho: string;
    FAssinatura: string;   // dll|ip|loja|terminal|param da ultima configuracao
    FConfiguraEx: TConfiguraIntSiTefInterativoEx;
    FConfigura: TConfiguraIntSiTefInterativo;
    FInicia: TIniciaFuncaoSiTefInterativo;
    FContinua: TContinuaFuncaoSiTefInterativo;
    FFinaliza: TFinalizaFuncaoSiTefInterativo;
    FPresencaPinPad: TVerificaPresencaPinPad;
    FObtemVersao: TObtemVersao;
    procedure Descarregar;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Enfileirar(const ATarefa: ICliSiTefTarefa);
    // Daqui para baixo: SO dentro de uma tarefa (na propria thread)
    procedure Carregar(const ACaminho: string);
    procedure Configurar(const ACaminho, AIP, ALoja, ATerminal, AParamAdic: string);
    property Ocupada: Boolean read FOcupada;
    property Inicia: TIniciaFuncaoSiTefInterativo read FInicia;
    property Continua: TContinuaFuncaoSiTefInterativo read FContinua;
    property Finaliza: TFinalizaFuncaoSiTefInterativo read FFinaliza;
    property PresencaPinPad: TVerificaPresencaPinPad read FPresencaPinPad;
  end;

var
  GLockThread: TCriticalSection;
  GThread: TCliSiTefThread;
  // Kit alterado pela tela: o proximo Configurar nao pode pular a chamada
  GForcarConfiguracao: Boolean;

function ThreadDaDLL: TCliSiTefThread;
begin
  GLockThread.Enter;
  try
    if GThread = nil then
      GThread := TCliSiTefThread.Create;
    Result := GThread;
  finally
    GLockThread.Leave;
  end;
end;

function CliSiTefErroTransacao(ARetorno: Integer): string;
begin
  case ARetorno of
    0: Result := '';
    -1: Result := 'CliSiTef nao inicializada';
    -2: Result := 'Operacao cancelada pelo operador';
    -3: Result := 'Codigo de funcao invalido';
    -4: Result := 'Falta de memoria para rodar a funcao';
    -5: Result := 'Sem comunicacao com o SiTef';
    -6: Result := 'Operacao cancelada pelo cliente no pinpad';
    -8: Result := 'A CliSiTef nao tem a funcao pedida (DLL desatualizada?)';
    -9: Result := 'ContinuaFuncaoSiTefInterativo sem funcao iniciada';
    -10: Result := 'Parametro obrigatorio nao informado pela automacao';
    -12: Result := 'Funcao interativa anterior nao foi concluida';
    -13: Result := 'Documento fiscal nao encontrado na CliSiTef';
    -15: Result := 'Operacao cancelada pela automacao';
    -20: Result := 'Parametro invalido passado para a funcao';
    -21: Result := 'Palavra proibida na coleta pelo pinpad';
    -25: Result := 'Correspondente bancario: realize a sangria';
    -30: Result := 'Erro de acesso a arquivo da CliSiTef';
    -40: Result := 'Transacao negada pelo SiTef';
    -41: Result := 'Dados invalidos';
    -43: Result := 'Falha no pinpad';
    -50: Result := 'Transacao nao segura';
    -100: Result := 'Erro interno da CliSiTef';
  else
    if ARetorno < 0 then
      Result := Format('Erro interno da CliSiTef (%d)', [ARetorno])
    else
      Result := Format('Negada pelo autorizador (%d)', [ARetorno]);
  end;
end;

function CliSiTefErroConfiguracao(ARetorno: Integer): string;
begin
  case ARetorno of
    0: Result := '';
    1: Result := 'Endereco IP do SiTef invalido ou nao resolvido';
    2: Result := 'Codigo da loja invalido';
    3: Result := 'Codigo do terminal invalido';
    6: Result := 'Erro na inicializacao do TCP/IP';
    7: Result := 'Falta de memoria';
    8: Result := 'CliSiTef nao encontrada ou com problema na inicializacao';
    9: Result := 'Configuracao de servidores SiTef excedida';
    10: Result := 'Erro de acesso na pasta da CliSiTef';
    11: Result := 'Dados invalidos passados pela automacao';
    12: Result := 'Modo seguro nao ativo';
    13: Result := 'Caminho da biblioteca invalido';
  else
    Result := Format('ConfiguraIntSiTefInterativo retornou %d', [ARetorno]);
  end;
end;

// CliSiTef manda quebra de linha como '@' ou '/n' nos textos de tela
function AjustarTexto(const ATexto: string): string;
begin
  Result := TrimRight(ATexto);
  Result := StringReplace(Result, '/n', #10, [rfReplaceAll]);
  Result := StringReplace(Result, '@', #10, [rfReplaceAll]);
end;

function ValorSiTef(AValor: Double): string;
var
  LFmt: TFormatSettings;
begin
  LFmt := TFormatSettings.Create;
  LFmt.DecimalSeparator := ',';
  LFmt.ThousandSeparator := #0;
  Result := FormatFloat('0.00', AValor, LFmt);
end;

{ Arquivos .ini do kit

  Sem TIniFile: o CliSiTef.ini do kit vem em UTF-8 com BOM, e a API
  GetPrivateProfileString do Windows le o BOM como parte do nome da primeira
  secao - [CliSiTef] sumiria e a gravacao criaria outra igual. Aqui a linha e'
  trocada no lugar, preservando codificacao, BOM, comentarios e o resto. }

type
  TIniTexto = class
  private
    FArquivo: string;
    FLinhas: TStringList;
    FEncoding: TEncoding;
    function AcharSecao(const ASecao: string): Integer;
    function AcharChave(AInicio: Integer; const AChave: string): Integer;
  public
    constructor Create(const AArquivo: string);
    destructor Destroy; override;
    function Ler(const ASecao, AChave: string; const APadrao: string = ''): string;
    procedure Gravar(const ASecao, AChave, AValor: string);
    procedure Salvar;
  end;

constructor TIniTexto.Create(const AArquivo: string);
var
  LBytes: TBytes;
  LTamBom: Integer;
begin
  inherited Create;
  FArquivo := AArquivo;
  FLinhas := TStringList.Create;
  FEncoding := TEncoding.ANSI;
  if FileExists(AArquivo) then
  begin
    LBytes := TFile.ReadAllBytes(AArquivo);
    FEncoding := nil;
    LTamBom := TEncoding.GetBufferEncoding(LBytes, FEncoding, TEncoding.ANSI);
    FLinhas.Text := FEncoding.GetString(LBytes, LTamBom, Length(LBytes) - LTamBom);
  end;
end;

destructor TIniTexto.Destroy;
begin
  FLinhas.Free;
  inherited;
end;

function TIniTexto.AcharSecao(const ASecao: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FLinhas.Count - 1 do
    if SameText(Trim(FLinhas[I]), '[' + ASecao + ']') then Exit(I);
  Result := -1;
end;

// Linha da chave dentro da secao que comeca em AInicio (-1 se nao houver)
function TIniTexto.AcharChave(AInicio: Integer; const AChave: string): Integer;
var
  LLinha: string;
  I, LPos: Integer;
begin
  for I := AInicio + 1 to FLinhas.Count - 1 do
  begin
    LLinha := Trim(FLinhas[I]);
    if LLinha.StartsWith('[') then Break;
    LPos := Pos('=', LLinha);
    if (LPos > 0) and SameText(Trim(Copy(LLinha, 1, LPos - 1)), AChave) then Exit(I);
  end;
  Result := -1;
end;

function TIniTexto.Ler(const ASecao, AChave, APadrao: string): string;
var
  LSecao, LLinha: Integer;
  LTexto: string;
begin
  Result := APadrao;
  LSecao := AcharSecao(ASecao);
  if LSecao < 0 then Exit;
  LLinha := AcharChave(LSecao, AChave);
  if LLinha < 0 then Exit;
  LTexto := FLinhas[LLinha];
  Result := Trim(Copy(LTexto, Pos('=', LTexto) + 1, MaxInt));
end;

procedure TIniTexto.Gravar(const ASecao, AChave, AValor: string);
var
  LSecao, LLinha, LFim: Integer;
begin
  LSecao := AcharSecao(ASecao);
  if LSecao < 0 then
  begin
    if (FLinhas.Count > 0) and (Trim(FLinhas[FLinhas.Count - 1]) <> '') then
      FLinhas.Add('');
    FLinhas.Add('[' + ASecao + ']');
    FLinhas.Add(AChave + '=' + AValor);
    Exit;
  end;

  LLinha := AcharChave(LSecao, AChave);
  if LLinha >= 0 then
  begin
    FLinhas[LLinha] := AChave + '=' + AValor;
    Exit;
  end;

  // Chave nova: no fim da secao, antes das linhas em branco que a separam
  LFim := LSecao + 1;
  while (LFim < FLinhas.Count) and (not Trim(FLinhas[LFim]).StartsWith('[')) do
    Inc(LFim);
  while (LFim > LSecao + 1) and (Trim(FLinhas[LFim - 1]) = '') do
    Dec(LFim);
  FLinhas.Insert(LFim, AChave + '=' + AValor);
end;

procedure TIniTexto.Salvar;
var
  LTexto: string;
  LBom, LCorpo, LTudo: TBytes;
begin
  LTexto := FLinhas.Text;   // CRLF
  LBom := FEncoding.GetPreamble;
  LCorpo := FEncoding.GetBytes(LTexto);
  SetLength(LTudo, Length(LBom) + Length(LCorpo));
  if Length(LBom) > 0 then
    Move(LBom[0], LTudo[0], Length(LBom));
  if Length(LCorpo) > 0 then
    Move(LCorpo[0], LTudo[Length(LBom)], Length(LCorpo));
  TFile.WriteAllBytes(FArquivo, LTudo);
end;

function CliSiTefTokenValido(const AToken: string): Boolean;
var
  I: Integer;
begin
  Result := Length(AToken) = 19;
  if not Result then Exit;
  for I := 1 to 19 do
    if I in [5, 10, 15] then
      Result := Result and (AToken[I] = '-')
    else
      Result := Result and CharInSet(AToken[I], ['0'..'9']);
end;

function CliSiTefLerKit(const ADll: string): TCliSiTefKit;
var
  LIni: TIniTexto;
  LRelease: TStringList;
  LLinha: string;
begin
  Result := Default(TCliSiTefKit);
  Result.Pasta := ExtractFilePath(Trim(ADll));
  Result.DllExiste := (Trim(ADll) <> '') and FileExists(Trim(ADll));
  if Result.Pasta = '' then Exit;

  if FileExists(Result.Pasta + ARQ_RELEASE) then
  begin
    LRelease := TStringList.Create;
    try
      try
        LRelease.LoadFromFile(Result.Pasta + ARQ_RELEASE);
        for LLinha in LRelease do
          if Trim(LLinha) <> '' then
          begin
            Result.Versao := Trim(LLinha);
            Break;
          end;
      except
        // versao e' so informativa
      end;
    finally
      LRelease.Free;
    end;
  end;

  Result.IniExiste := FileExists(Result.Pasta + ARQ_CLISITEF_INI);
  LIni := TIniTexto.Create(Result.Pasta + ARQ_CLISITEF_INI);
  try
    Result.PortaPinPad := LIni.Ler('PinPadCompartilhado', 'Porta');
    Result.Trace := LIni.Ler('CliSiTef', 'HabilitaTrace', '0') = '1';
  finally
    LIni.Free;
  end;

  Result.TlsExiste := FileExists(Result.Pasta + ARQ_CONFITLS);
  LIni := TIniTexto.Create(Result.Pasta + ARQ_CONFITLS);
  try
    Result.TlsTipo := LIni.Ler('ConfiguracaoTLS', 'TipoComunicacaoExterna');
    Result.TlsUrl := LIni.Ler('ConfiguracaoTLS', 'URLTLS');
    Result.TokenConfigurado := LIni.Ler('ConfiguracaoTLS', 'TokenRegistro') <> '';
  finally
    LIni.Free;
  end;
end;

procedure CliSiTefGravarKit(const ADll, APortaPinPad: string; ATrace: Boolean;
  const ATlsUrl, ATokenNovo: string);
var
  LPasta: string;
  LIni: TIniTexto;
begin
  LPasta := ExtractFilePath(Trim(ADll));
  if (LPasta = '') or (not TDirectory.Exists(LPasta)) then
    raise Exception.CreateFmt('Pasta do kit CliSiTef nao encontrada: %s', [LPasta]);
  if (ATokenNovo <> '') and not CliSiTefTokenValido(ATokenNovo) then
    raise Exception.Create('O token de registro deve ter o formato 0000-0000-0000-0000');
  if ThreadDaDLL.Ocupada then
    raise Exception.Create('Ha uma operacao TEF em andamento - tente quando ela terminar');

  LIni := TIniTexto.Create(LPasta + ARQ_CLISITEF_INI);
  try
    if Trim(APortaPinPad) <> '' then
      LIni.Gravar('PinPadCompartilhado', 'Porta', UpperCase(Trim(APortaPinPad)));
    LIni.Gravar('CliSiTef', 'HabilitaTrace', IfThen(ATrace, '1', '0'));
    LIni.Salvar;
  finally
    LIni.Free;
  end;

  // TLS: so mexe no CONFITLS.INI se ele existir ou se a tela mandou algo
  if FileExists(LPasta + ARQ_CONFITLS) or (Trim(ATlsUrl) <> '') or (ATokenNovo <> '') then
  begin
    LIni := TIniTexto.Create(LPasta + ARQ_CONFITLS);
    try
      if LIni.Ler('ConfiguracaoTLS', 'TipoComunicacaoExterna') = '' then
        LIni.Gravar('ConfiguracaoTLS', 'TipoComunicacaoExterna', 'TLSGWP');
      if Trim(ATlsUrl) <> '' then
        LIni.Gravar('ConfiguracaoTLS', 'URLTLS', Trim(ATlsUrl));
      if ATokenNovo <> '' then
        LIni.Gravar('ConfiguracaoTLS', 'TokenRegistro', ATokenNovo);
      LIni.Salvar;
    finally
      LIni.Free;
    end;
  end;

  TEFLog('kit CliSiTef alterado pela tela: pasta=%s porta=%s trace=%d url=%s token %s',
    [LPasta, APortaPinPad, Ord(ATrace), ATlsUrl,
     IfThen(ATokenNovo <> '', 'trocado', 'mantido')]);
  CliSiTefReconfigurar;
end;

procedure CliSiTefReconfigurar;
begin
  GForcarConfiguracao := True;
end;

{ TCliSiTefTarefa }

constructor TCliSiTefTarefa.Create(const AProc: TProc);
begin
  inherited Create;
  FProc := AProc;
  FFim := TEvent.Create(nil, True, False, '');
  FLock := TCriticalSection.Create;
end;

destructor TCliSiTefTarefa.Destroy;
begin
  FFim.Free;
  FLock.Free;
  inherited;
end;

procedure TCliSiTefTarefa.Rodar;
begin
  FLock.Enter;
  try
    if FAbandonada then Exit;   // quem pediu ja desistiu de esperar
    FIniciada := True;
  finally
    FLock.Leave;
  end;

  try
    try
      FProc();
    except
      on E: Exception do
        FErro := E.Message;
    end;
  finally
    FProc := nil;   // solta o que a closure segurava (cliente, dicionarios)
    FFim.SetEvent;
  end;
end;

// Da thread principal nao basta esperar: os TThread.Queue que levam as
// mensagens da CliSiTef para a tela precisam rodar enquanto isso
function TCliSiTefTarefa.Esperar(ATimeoutMs: Cardinal; ABombearMensagens: Boolean): Boolean;
var
  LInicio: UInt64;
  LHandle: THandle;
begin
  if not ABombearMensagens then
    Exit(FFim.WaitFor(ATimeoutMs) = wrSignaled);

  LInicio := TThread.GetTickCount64;
  LHandle := FFim.Handle;
  repeat
    if FFim.WaitFor(0) = wrSignaled then Exit(True);
    MsgWaitForMultipleObjects(1, LHandle, False, 100, QS_ALLINPUT);
    CheckSynchronize;
    Application.ProcessMessages;
  until (ATimeoutMs <> INFINITE) and (TThread.GetTickCount64 - LInicio >= ATimeoutMs);
  Result := FFim.WaitFor(0) = wrSignaled;
end;

procedure TCliSiTefTarefa.Abandonar;
begin
  FLock.Enter;
  try
    if not FIniciada then
      FAbandonada := True;
  finally
    FLock.Leave;
  end;
end;

function TCliSiTefTarefa.Erro: string;
begin
  Result := FErro;
end;

{ TCliSiTefThread }

constructor TCliSiTefThread.Create;
begin
  // Fila sem limite pratico; o PopItem acorda a cada 500ms para ver Terminated
  FFila := TThreadedQueue<ICliSiTefTarefa>.Create(64, INFINITE, 500);
  FDependencias := TList<HMODULE>.Create;
  inherited Create(False);
  FreeOnTerminate := False;
end;

// Nao descarrega a DLL: no fim do processo a CliSiTef ainda pode ter threads
// proprias (comunicacao, pinpad) e o FreeLibrary arriscaria travar a saida
destructor TCliSiTefThread.Destroy;
begin
  inherited;   // Terminate + WaitFor
  FFila.Free;
  FDependencias.Free;
end;

procedure TCliSiTefThread.Enfileirar(const ATarefa: ICliSiTefTarefa);
begin
  if FFila.PushItem(ATarefa) <> wrSignaled then
    raise Exception.Create('Fila da CliSiTef indisponivel');
end;

procedure TCliSiTefThread.Execute;
var
  LTarefa: ICliSiTefTarefa;
begin
  NameThreadForDebugging('CliSiTef');
  while not Terminated do
  begin
    LTarefa := nil;
    if FFila.PopItem(LTarefa) <> wrSignaled then
    begin
      if FFila.ShutDown then Break;
      Continue;
    end;
    if LTarefa = nil then Continue;

    FOcupada := True;
    try
      LTarefa.Rodar;
    finally
      FOcupada := False;
      LTarefa := nil;
    end;
  end;
end;

procedure TCliSiTefThread.Descarregar;
begin
  if FHandle <> 0 then
  begin
    FreeLibrary(FHandle);
    FHandle := 0;
  end;
  for var LDep in FDependencias do
    FreeLibrary(LDep);
  FDependencias.Clear;
  FCaminho := '';
  FAssinatura := '';
  FConfiguraEx := nil;
  FConfigura := nil;
  FInicia := nil;
  FContinua := nil;
  FFinaliza := nil;
  FPresencaPinPad := nil;
  FObtemVersao := nil;
end;

procedure TCliSiTefThread.Carregar(const ACaminho: string);

  function Obrigatoria(const ANome: string): Pointer;
  begin
    Result := GetProcAddress(FHandle, PChar(ANome));
    if Result = nil then
      raise Exception.CreateFmt('Funcao %s nao encontrada em %s', [ANome, ACaminho]);
  end;

var
  LVersao, LVersaoI: array[0..255] of AnsiChar;
  LPasta, LDep: string;
  LModulo: HMODULE;
begin
  if (FHandle <> 0) and SameText(FCaminho, ACaminho) then Exit;

  Descarregar;
  if not FileExists(ACaminho) then
    raise Exception.CreateFmt('CliSiTef nao encontrada: %s', [ACaminho]);

  // A CliSiTef carrega estas por nome; com o SetDllDirectory do ApoloWeb a
  // pasta do kit nao entra na busca. Ja carregadas, o nome e' reaproveitado.
  LPasta := ExtractFilePath(ACaminho);
  for LDep in DEPENDENCIAS_KIT do
  begin
    if not FileExists(LPasta + LDep) then Continue;
    LModulo := GetModuleHandle(PChar(LDep));
    if LModulo <> 0 then
    begin
      TEFLog('CliSiTef: %s ja estava carregada de outro lugar - mantida', [LDep]);
      Continue;
    end;
    LModulo := LoadLibraryEx(PChar(LPasta + LDep), 0, LOAD_WITH_ALTERED_SEARCH_PATH);
    if LModulo = 0 then
      TEFLog('CliSiTef: falha ao pre-carregar %s: %s',
        [LPasta + LDep, SysErrorMessage(GetLastError)])
    else
      FDependencias.Add(LModulo);
  end;

  // ALTERED_SEARCH_PATH: as DLLs que a CliSiTef carrega (pinpad, libemv,
  // libcurl, QREncode) estao na pasta dela, nao na do ApoloWeb.exe
  FHandle := LoadLibraryEx(PChar(ACaminho), 0, LOAD_WITH_ALTERED_SEARCH_PATH);
  if FHandle = 0 then
    raise Exception.CreateFmt('Nao foi possivel carregar %s: %s',
      [ACaminho, SysErrorMessage(GetLastError)]);

  try
    FCaminho := ACaminho;
    @FConfiguraEx := GetProcAddress(FHandle, 'ConfiguraIntSiTefInterativoEx');
    if not Assigned(FConfiguraEx) then
      @FConfigura := Obrigatoria('ConfiguraIntSiTefInterativo');
    @FInicia := Obrigatoria('IniciaFuncaoSiTefInterativo');
    @FContinua := Obrigatoria('ContinuaFuncaoSiTefInterativo');
    @FFinaliza := Obrigatoria('FinalizaFuncaoSiTefInterativo');
    @FPresencaPinPad := GetProcAddress(FHandle, 'VerificaPresencaPinPad');
    @FObtemVersao := GetProcAddress(FHandle, 'ObtemVersao');
  except
    Descarregar;
    raise;
  end;

  if Assigned(FObtemVersao) then
  begin
    FillChar(LVersao, SizeOf(LVersao), 0);
    FillChar(LVersaoI, SizeOf(LVersaoI), 0);
    FObtemVersao(@LVersao[0], @LVersaoI[0]);
    TEFLog('CliSiTef carregada: %s (versao %s / %s)',
      [ACaminho, string(AnsiString(PAnsiChar(@LVersao[0]))),
       string(AnsiString(PAnsiChar(@LVersaoI[0])))]);
  end
  else
    TEFLog('CliSiTef carregada: %s', [ACaminho]);
end;

procedure TCliSiTefThread.Configurar(const ACaminho, AIP, ALoja, ATerminal,
  AParamAdic: string);
var
  LAssinatura, LDirAnterior, LPasta: string;
  LRet: Integer;
begin
  LAssinatura := ACaminho + '|' + AIP + '|' + ALoja + '|' + ATerminal + '|' + AParamAdic;
  if (LAssinatura = FAssinatura) and (FHandle <> 0) and
     (not GForcarConfiguracao) then Exit;
  GForcarConfiguracao := False;

  // CliSiTef.ini / CONFITLS.INI: a DLL olha a pasta dela e o diretorio
  // corrente. Corrente = pasta do kit so durante a carga e a configuracao.
  LDirAnterior := GetCurrentDir;
  LPasta := ExcludeTrailingPathDelimiter(ExtractFilePath(ACaminho));
  if (LPasta <> '') and not SetCurrentDir(LPasta) then
    TEFLog('CliSiTef: nao foi possivel mudar o diretorio corrente para %s', [LPasta]);
  try
    Carregar(ACaminho);
    TEFLog('CliSiTef: %s %s', [ARQ_CONFITLS,
      IfThen(FileExists(IncludeTrailingPathDelimiter(LPasta) + ARQ_CONFITLS),
        'presente na pasta da DLL', 'NAO encontrado na pasta da DLL')]);

    if Assigned(FConfiguraEx) then
      LRet := FConfiguraEx(PAnsiChar(AnsiString(AIP)), PAnsiChar(AnsiString(ALoja)),
        PAnsiChar(AnsiString(ATerminal)), 0, PAnsiChar(AnsiString(AParamAdic)))
    else
      LRet := FConfigura(PAnsiChar(AnsiString(AIP)), PAnsiChar(AnsiString(ALoja)),
        PAnsiChar(AnsiString(ATerminal)), 0);
  finally
    SetCurrentDir(LDirAnterior);
  end;

  TEFLog('ConfiguraIntSiTefInterativo%s ip=%s loja=%s terminal=%s param=%s -> %d',
    [IfThen(Assigned(FConfiguraEx), 'Ex', ''), AIP, ALoja, ATerminal,
     AParamAdic, LRet]);

  if LRet <> 0 then
  begin
    FAssinatura := '';
    raise Exception.Create('CliSiTef: ' + CliSiTefErroConfiguracao(LRet));
  end;
  FAssinatura := LAssinatura;
end;

{ TTEFClientCliSiTef }

constructor TTEFClientCliSiTef.Create(const AConfig: TTEFConfig);
begin
  inherited Create(AConfig);
  FDll := Trim(AConfig.SitefDll);
  FIP := Trim(AConfig.SitefIP);
  FLoja := Trim(AConfig.SitefLoja);
  FTerminal := Trim(AConfig.SitefTerminal);
  FParamAdic := Trim(AConfig.SitefParamAdic);
  FLockResp := TCriticalSection.Create;
  FEventoResp := TEvent.Create(nil, True, False, '');
  FDataHoraCupom := TDictionary<Integer, TDateTime>.Create;
end;

destructor TTEFClientCliSiTef.Destroy;
begin
  FDataHoraCupom.Free;
  FEventoResp.Free;
  FLockResp.Free;
  inherited;
end;

function TTEFClientCliSiTef.Modo: TTEFModo;
begin
  Result := tmCliSiTef;
end;

function TTEFClientCliSiTef.Descricao: string;
begin
  Result := Format('clisitef (%s loja=%s terminal=%s)', [FIP, FLoja, FTerminal]);
end;

function TTEFClientCliSiTef.ParamAdicConfig: string;
var
  LItens: TStringList;
begin
  if Pos('[', FParamAdic) > 0 then
    Exit(FParamAdic);   // o integrador mandou pronto

  LItens := TStringList.Create;
  try
    LItens.StrictDelimiter := True;
    LItens.Delimiter := ';';
    LItens.DelimitedText := FParamAdic;
    for var I := LItens.Count - 1 downto 0 do
    begin
      LItens[I] := Trim(LItens[I]);
      if LItens[I] = '' then LItens.Delete(I);
    end;

    // Com CONFITLS.INI a DLL ja sabe o TLS (e o token); repetir aqui so
    // arriscaria divergir dele
    if ContainsText(FIP, 'fiservapp.com') and
       (LItens.IndexOfName('TipoComunicacaoExterna') < 0) and
       (not FileExists(ExtractFilePath(FDll) + ARQ_CONFITLS)) then
      LItens.Add('TipoComunicacaoExterna=TLSGWP');

    if LItens.Count = 0 then
      Result := ''
    else
      Result := '[' + string.Join(';', LItens.ToStringArray) + ']';
  finally
    LItens.Free;
  end;
end;

// Na thread da DLL
procedure TTEFClientCliSiTef.Preparar;
begin
  ThreadDaDLL.Configurar(FDll, FIP, FLoja, FTerminal, ParamAdicConfig);
end;

procedure TTEFClientCliSiTef.NaThreadDaDLL(const AProc: TProc; ATimeoutMs: Cardinal);
var
  LThread: TCliSiTefThread;
  LTarefa: ICliSiTefTarefa;
  LPrincipal: Boolean;
begin
  LThread := ThreadDaDLL;
  if TThread.CurrentThread.ThreadID = LThread.ThreadID then
  begin
    AProc();
    Exit;
  end;

  LPrincipal := TThread.CurrentThread.ThreadID = MainThreadID;
  LTarefa := TCliSiTefTarefa.Create(
    procedure
    begin
      FChamadaDaPrincipal := LPrincipal;
      try
        AProc();
      finally
        FChamadaDaPrincipal := False;
      end;
    end);
  LThread.Enfileirar(LTarefa);
  if not LTarefa.Esperar(ATimeoutMs, LPrincipal) then
  begin
    LTarefa.Abandonar;
    raise Exception.Create('CliSiTef ocupada com outra operacao - tente de novo');
  end;
  if LTarefa.Erro <> '' then
    raise Exception.Create(LTarefa.Erro);
end;

procedure TTEFClientCliSiTef.Interagir(AJson: TJSONObject);
begin
  try
    if Assigned(FOnInteracao) then
      FOnInteracao(AJson.ToJSON);
  finally
    AJson.Free;
  end;
end;

procedure TTEFClientCliSiTef.Mensagem(const ATexto, AVisor: string);
var
  LJson: TJSONObject;
begin
  LJson := TJSONObject.Create;
  LJson.AddPair('tipo', 'mensagem');
  LJson.AddPair('visor', AVisor);
  LJson.AddPair('texto', AjustarTexto(ATexto));
  Interagir(LJson);
end;

// Manda a pergunta para a tela e espera a resposta. Devolve CONT_CONTINUA
// (respondida, valor em AValor), CONT_RETORNA (voltar) ou CONT_ENCERRA.
function TTEFClientCliSiTef.Perguntar(AJson: TJSONObject; out AValor: string): Integer;
var
  LId: Integer;
  LInicio: UInt64;
  LLimiteMs: UInt64;
  LAcao: string;
begin
  AValor := '';

  if FChamadaDaPrincipal or (not Assigned(FOnInteracao)) then
  begin
    Log('CliSiTef pediu interacao (%s) sem tela para responder - cancelando',
      [AJson.ToJSON]);
    AJson.Free;
    Exit(CONT_ENCERRA);
  end;

  FLockResp.Enter;
  try
    Inc(FSeqPergunta);
    LId := FSeqPergunta;
    FPerguntaId := LId;
    FRespAcao := '';
    FRespValor := '';
    FEventoResp.ResetEvent;
  finally
    FLockResp.Leave;
  end;

  AJson.AddPair('id', TJSONNumber.Create(LId));
  Interagir(AJson);

  LLimiteMs := UInt64(FTimeoutSeg) * 1000;
  if LLimiteMs < ESPERA_MINIMA_RESPOSTA_SEG * 1000 then
    LLimiteMs := ESPERA_MINIMA_RESPOSTA_SEG * 1000;
  LInicio := TThread.GetTickCount64;
  LAcao := '';
  repeat
    if FEventoResp.WaitFor(250) = wrSignaled then Break;
    if FCancelarEspera then
    begin
      LAcao := 'cancelar';
      Break;
    end;
    if TThread.GetTickCount64 - LInicio >= LLimiteMs then
    begin
      Log('CliSiTef: sem resposta da tela em %ds - cancelando a coleta',
        [LLimiteMs div 1000]);
      LAcao := 'cancelar';
      Break;
    end;
  until False;

  FLockResp.Enter;
  try
    if LAcao = '' then
    begin
      LAcao := FRespAcao;
      AValor := FRespValor;
    end;
    FPerguntaId := 0;
  finally
    FLockResp.Leave;
  end;

  if SameText(LAcao, 'voltar') then
    Result := CONT_RETORNA
  else if SameText(LAcao, 'ok') then
    Result := CONT_CONTINUA
  else
    Result := CONT_ENCERRA;
end;

procedure TTEFClientCliSiTef.SolicitarCancelamento;
begin
  inherited;
  // Se houver pergunta na tela, ela cai na hora (Perguntar ve o flag)
  FEventoResp.SetEvent;
end;

procedure TTEFClientCliSiTef.ResponderInteracao(AId: Integer; const AAcao, AValor: string);
begin
  // id 0: o operador desistiu sem pergunta na tela (ex: aguardando o pinpad)
  if AId = 0 then
  begin
    if SameText(AAcao, 'cancelar') then
      SolicitarCancelamento;
    Exit;
  end;

  FLockResp.Enter;
  try
    if AId <> FPerguntaId then
    begin
      Log('resposta a pergunta %d ignorada (pergunta atual: %d)', [AId, FPerguntaId]);
      Exit;
    end;
    FRespAcao := AAcao;
    FRespValor := AValor;
    FEventoResp.SetEvent;
  finally
    FLockResp.Leave;
  end;
end;

{ O laco interativo. Roda na thread da DLL. AAutomaticas: respostas que o PDV
  ja sabe (parcelas, dados do cancelamento) - o campo nem vai para a tela.
  ACampos recebe tudo o que a CliSiTef devolveu (comando 0). }
function TTEFClientCliSiTef.ExecutarFuncao(AFuncao: Integer; AValor: Double;
  const ACupom: string; ADataHora: TDateTime; const ARestricoes: string;
  AAutomaticas, ACampos: TDictionary<Integer, string>): Integer;
var
  LThread: TCliSiTefThread;
  LBuffer: PAnsiChar;
  // Integer (4 bytes) mesmo onde a DLL fala em short - ver o tipo
  // TContinuaFuncaoSiTefInterativo. O valor valido e' a palavra baixa.
  LComando, LMin, LMax, LTipoCampo: Integer;
  LContinua, LRet: Integer;
  LTexto, LResposta, LTitulo, LValorStr, LData, LHora, LOperador: string;
  LJson: TJSONObject;
  LOpcoes: TJSONArray;
  LRespA: AnsiString;
begin
  Preparar;
  LThread := ThreadDaDLL;
  FUltimaMensagem := '';

  LValorStr := ValorSiTef(AValor);
  LData := FormatDateTime('yyyymmdd', ADataHora);
  LHora := FormatDateTime('hhnnss', ADataHora);
  LOperador := 'CX' + IntToStr(FIdentificacao);

  Log('IniciaFuncaoSiTefInterativo funcao=%d valor=%s cupom=%s data=%s hora=%s restricoes=%s',
    [AFuncao, LValorStr, ACupom, LData, LHora, ARestricoes]);
  LRet := LThread.Inicia(AFuncao, PAnsiChar(AnsiString(LValorStr)),
    PAnsiChar(AnsiString(ACupom)), PAnsiChar(AnsiString(LData)),
    PAnsiChar(AnsiString(LHora)), PAnsiChar(AnsiString(LOperador)),
    PAnsiChar(AnsiString(ARestricoes)));
  Log('IniciaFuncaoSiTefInterativo -> %d', [LRet]);
  if LRet <> RET_CONTINUA then
    Exit(LRet);

  LBuffer := AllocMem(TAM_BUFFER + FOLGA_BUFFER);
  try
    LContinua := CONT_CONTINUA;
    LTitulo := '';
    repeat
      LComando := 0;
      LTipoCampo := 0;
      LMin := 0;
      LMax := 0;
      LRet := LThread.Continua(@LComando, @LTipoCampo, @LMin, @LMax, LBuffer,
        TAM_BUFFER, LContinua);
      // short* no manual: so a palavra baixa vale (com sinal)
      LComando := PSmallInt(@LComando)^;
      LMin := PSmallInt(@LMin)^;
      LMax := PSmallInt(@LMax)^;

      LTexto := string(AnsiString(LBuffer));
      LContinua := CONT_CONTINUA;
      LResposta := '';
      if LRet <> RET_CONTINUA then
      begin
        Log('ContinuaFuncaoSiTefInterativo -> %d (fim do laco)', [LRet]);
        Break;
      end;

      // Comando 23 (consulta se interrompe) chega em rajada enquanto o
      // pinpad espera o cartao - nao vale uma linha de log cada
      if LComando <> 23 then
        Log('CliSiTef <- comando=%d campo=%d min=%d max=%d "%s"',
          [LComando, LTipoCampo, LMin, LMax, LTexto]);

      case LComando of
        0:  // valor devolvido para a automacao guardar
          begin
            ACampos.AddOrSetValue(LTipoCampo, LTexto);
            if LTipoCampo = TC_QRCODE then
              NotificarQrCode(Trim(LTexto));
          end;

        1, 2, 3:  // mensagem no visor do operador / cliente / ambos
          begin
            FUltimaMensagem := AjustarTexto(LTexto);
            case LComando of
              1: Mensagem(LTexto, 'operador');
              2: Mensagem(LTexto, 'cliente');
            else
              Mensagem(LTexto, 'todos');
            end;
          end;

        4:  // titulo do proximo menu
          LTitulo := AjustarTexto(LTexto);

        11: Mensagem('', 'operador');
        12: Mensagem('', 'cliente');
        13: Mensagem('', 'todos');
        14: LTitulo := '';
        15: Mensagem(LTexto, 'cabecalho');
        16: Mensagem('', 'cabecalho');

        20:  // sim / nao  (0 = sim, 1 = nao)
          begin
            LJson := TJSONObject.Create;
            LJson.AddPair('tipo', 'simnao');
            LJson.AddPair('titulo', AjustarTexto(LTexto));
            LContinua := Perguntar(LJson, LResposta);
          end;

        21:  // menu "1:Opcao;2:Opcao;"
          begin
            LJson := TJSONObject.Create;
            LJson.AddPair('tipo', 'menu');
            LJson.AddPair('titulo', IfThen(LTitulo <> '', LTitulo, 'Selecione'));
            LOpcoes := TJSONArray.Create;
            for var LItem in LTexto.Split([';']) do
            begin
              if Trim(LItem) = '' then Continue;
              var LPos := Pos(':', LItem);
              var LOpcao := TJSONObject.Create;
              if LPos > 0 then
              begin
                LOpcao.AddPair('codigo', Trim(Copy(LItem, 1, LPos - 1)));
                LOpcao.AddPair('texto', AjustarTexto(Copy(LItem, LPos + 1, MaxInt)));
              end
              else
              begin
                LOpcao.AddPair('codigo', Trim(LItem));
                LOpcao.AddPair('texto', AjustarTexto(LItem));
              end;
              LOpcoes.AddElement(LOpcao);
            end;
            LJson.AddPair('opcoes', LOpcoes);
            LContinua := Perguntar(LJson, LResposta);
          end;

        22:  // mensagem + aguardar tecla
          begin
            LJson := TJSONObject.Create;
            LJson.AddPair('tipo', 'aviso');
            LJson.AddPair('titulo', IfThen(Trim(LTexto) <> '', AjustarTexto(LTexto),
              'Pressione OK para continuar'));
            // Aqui nao ha o que cancelar: e' so o "ok, li"
            Perguntar(LJson, LResposta);
            LResposta := '';
            LContinua := CONT_CONTINUA;
          end;

        23:  // o pinpad esta esperando: a automacao quer interromper?
          if FCancelarEspera then
          begin
            Log('CliSiTef: interrompendo a pedido do operador');
            LContinua := CONT_ENCERRA;
          end;

        29:  // campo sem operador: so resposta automatica
          if AAutomaticas.TryGetValue(LTipoCampo, LResposta) then
            Log('CliSiTef -> campo %d automatico "%s"', [LTipoCampo, LResposta]);

        30, 31, 34, 35, 41:  // coleta de campo
          begin
            if AAutomaticas.TryGetValue(LTipoCampo, LResposta) then
              Log('CliSiTef -> campo %d automatico "%s"', [LTipoCampo, LResposta])
            else
            begin
              LJson := TJSONObject.Create;
              LJson.AddPair('tipo', 'campo');
              LJson.AddPair('titulo', AjustarTexto(LTexto));
              LJson.AddPair('campo', TJSONNumber.Create(LTipoCampo));
              LJson.AddPair('min', TJSONNumber.Create(LMin));
              LJson.AddPair('max', TJSONNumber.Create(LMax));
              LJson.AddPair('numerico', TJSONBool.Create(LComando in [31, 34, 35]));
              LJson.AddPair('monetario', TJSONBool.Create(LComando = 34));
              LJson.AddPair('mascarado', TJSONBool.Create(LComando = 41));
              LJson.AddPair('codigoBarras', TJSONBool.Create(LComando = 35));
              LContinua := Perguntar(LJson, LResposta);
              if (LContinua = CONT_CONTINUA) and (LComando = 34) then
                LResposta := StringReplace(Trim(LResposta), '.', ',', [rfReplaceAll]);
            end;
            if LContinua = CONT_CONTINUA then
              ACampos.AddOrSetValue(LTipoCampo, LResposta);
          end;

        50:  // QR Code na tela
          NotificarQrCode(Trim(LTexto));

        52:  // rodape do QR Code
          Mensagem(LTexto, 'cliente');
      end;

      if LContinua <> CONT_CONTINUA then
        LResposta := '';
      if LComando <> 23 then
      begin
        if LComando = 41 then
          Log('CliSiTef -> continua=%d resposta="***"', [LContinua])
        else if (LResposta <> '') or (LContinua <> CONT_CONTINUA) then
          Log('CliSiTef -> continua=%d resposta="%s"', [LContinua, LResposta]);
      end;

      LRespA := AnsiString(LResposta);
      if Length(LRespA) >= TAM_BUFFER then
        SetLength(LRespA, TAM_BUFFER - 1);
      FillChar(LBuffer^, TAM_BUFFER, 0);
      if LRespA <> '' then
        Move(PAnsiChar(LRespA)^, LBuffer^, Length(LRespA));
    until False;
  finally
    // Daqui em diante a CliSiTef ja deu o resultado (pode ser APROVADA): uma
    // falha na limpeza nao pode virar excecao e jogar a aprovacao fora - ela
    // ficaria pendente no SiTef, sem cupom e sem confirmacao
    try
      FreeMem(LBuffer);
    except
      on E: Exception do
        TEFLog('CliSiTef: falha ao liberar o buffer da DLL (%s) - resultado %d mantido',
          [E.Message, LRet]);
    end;
    try
      LJson := TJSONObject.Create;
      LJson.AddPair('tipo', 'fim');
      Interagir(LJson);
    except
      on E: Exception do
        TEFLog('CliSiTef: falha ao fechar a tela interativa (%s)', [E.Message]);
    end;
  end;

  Log('ContinuaFuncaoSiTefInterativo terminou -> %d (%s)',
    [LRet, CliSiTefErroTransacao(LRet)]);
  Result := LRet;
end;

function TTEFClientCliSiTef.MontarResposta(ARetorno: Integer;
  ACampos: TDictionary<Integer, string>; const ATipoSolicitado: string;
  const ACupom: string; ADataHora: TDateTime): TTEFResposta;

  function Campo(ATipo: Integer): string;
  begin
    if not ACampos.TryGetValue(ATipo, Result) then
      Result := '';
    Result := Trim(Result);
  end;

  function Linhas(const ATexto: string): TArray<string>;
  var
    LTexto: string;
  begin
    LTexto := StringReplace(ATexto, #13#10, #10, [rfReplaceAll]);
    LTexto := StringReplace(LTexto, #13, #10, [rfReplaceAll]);
    while (LTexto <> '') and (LTexto[Length(LTexto)] = #10) do
      Delete(LTexto, Length(LTexto), 1);
    if LTexto = '' then
      Result := nil
    else
      Result := LTexto.Split([#10]);
  end;

var
  LModalidade, LDataHora: string;
  LCampo: TPair<Integer, string>;
begin
  Result := Default(TTEFResposta);
  Result.IdReq := FIdentificacao;

  // Tudo o que a CliSiTef devolveu fica no log: e' assim que se ajusta o
  // mapeamento abaixo para a rede/bandeira de cada cliente
  for LCampo in ACampos do
    if (LCampo.Key <> TC_VIA_CLIENTE) and (LCampo.Key <> TC_VIA_LOJA) then
      Log('CliSiTef campo %d = "%s"', [LCampo.Key, LCampo.Value]);

  Result.Sucesso := ARetorno = RET_SUCESSO;
  if Result.Sucesso then
    Result.Status := 'APROVADA'
  else
  begin
    case ARetorno of
      -2, -6, -15: Result.Status := 'CANCELADA';
    else
      Result.Status := 'NEGADA';
    end;
    Result.Erro := CliSiTefErroTransacao(ARetorno);
    // Negada pelo autorizador: o motivo de verdade e' a ultima mensagem
    if (ARetorno > 0) and (FUltimaMensagem <> '') then
      Result.Erro := FUltimaMensagem + ' (' + Result.Erro + ')';
  end;

  Result.NSU := Campo(TC_NSU_HOST);
  if Result.NSU = '' then
    Result.NSU := Campo(TC_NSU_SITEF);
  Result.CodigoAutorizacao := Campo(TC_AUTORIZACAO);
  Result.CodigoAutorizacaoGp := Result.CodigoAutorizacao;
  Result.CodigoBandeira := Campo(TC_BANDEIRA);
  Result.Bandeira := Campo(TC_REDE);
  if Result.Bandeira = '' then
    Result.Bandeira := Result.CodigoBandeira;
  Result.Adquirente := Campo(TC_REDE_AUTORIZ);
  if Result.Adquirente = '' then
    Result.Adquirente := Campo(TC_INSTITUICAO);
  Result.CodigoCredenciadora := Result.Adquirente;
  Result.Bin := Campo(TC_BIN);
  Result.Parcelas := StrToIntDef(Campo(TC_PARCELAS), 1);
  if Result.Parcelas < 1 then Result.Parcelas := 1;
  Result.QrCode := Campo(TC_QRCODE);

  // 100: 2 digitos do tipo (01 debito, 02 credito, 03 voucher) + 2 do
  // financiamento (00 a vista, 01 pre-datado, 02 parc. loja, 03 parc. adm)
  LModalidade := Campo(TC_MODALIDADE);
  Result.TipoTransacao := LModalidade;
  case StrToIntDef(Copy(LModalidade, 1, 2), 0) of
    1: Result.TipoCartao := 'DEBITO';
    2: Result.TipoCartao := 'CREDITO';
    3: Result.TipoCartao := 'VOUCHER';
  else
    if ATipoSolicitado = 'debito' then
      Result.TipoCartao := 'DEBITO'
    else if ATipoSolicitado = 'pix' then
      Result.TipoCartao := 'PIX'
    else
      Result.TipoCartao := 'CREDITO';
  end;
  if (Copy(LModalidade, 3, 2) = '02') or (Copy(LModalidade, 3, 2) = '03') or
     (Result.Parcelas > 1) then
    Result.TipoFinanc := 'PARCELADO'
  else
    Result.TipoFinanc := 'AVISTA';

  // 105 = AAAAMMDDhhmmss -> ISO, como nos outros modos
  LDataHora := Campo(TC_DATAHORA);
  if Length(LDataHora) >= 8 then
  begin
    Result.DataHora := Copy(LDataHora, 1, 4) + '-' + Copy(LDataHora, 5, 2) + '-' +
      Copy(LDataHora, 7, 2);
    if Length(LDataHora) >= 14 then
      Result.DataHora := Result.DataHora + 'T' + Copy(LDataHora, 9, 2) + ':' +
        Copy(LDataHora, 11, 2) + ':' + Copy(LDataHora, 13, 2)
    else
      Result.DataHora := Result.DataHora + 'T00:00:00';
  end;

  // A chave do Finaliza: cupom|data|hora fiscal|numero do pagamento no cupom
  Result.Controle := ACupom + '|' + FormatDateTime('yyyymmdd', ADataHora) + '|' +
    FormatDateTime('hhnnss', ADataHora) + '|' + Campo(TC_NUM_PAGAMENTO);

  Result.ImpressoCliente := Linhas(Campo(TC_VIA_CLIENTE));
  Result.ImpressoLoja := Linhas(Campo(TC_VIA_LOJA));
end;

// Na thread da DLL. AControle = cupom|AAAAMMDD|HHMMSS|numpagamento
procedure TTEFClientCliSiTef.Finalizar(AConfirma: Boolean; const AControle: string);
var
  LPartes: TArray<string>;
  LCupom, LData, LHora, LParam: string;
begin
  LPartes := AControle.Split(['|']);
  if Length(LPartes) < 3 then
    raise Exception.CreateFmt('Controle CliSiTef invalido: "%s"', [AControle]);
  LCupom := LPartes[0];
  LData := LPartes[1];
  LHora := LPartes[2];
  LParam := '';
  if (Length(LPartes) > 3) and (Trim(LPartes[3]) <> '') then
    LParam := '{NumeroPagamentoCupom=' + Trim(LPartes[3]) + '}';

  Preparar;
  Log('FinalizaFuncaoSiTefInterativo confirma=%d cupom=%s data=%s hora=%s param=%s',
    [Ord(AConfirma), LCupom, LData, LHora, LParam]);
  ThreadDaDLL.Finaliza(Ord(AConfirma), PAnsiChar(AnsiString(LCupom)),
    PAnsiChar(AnsiString(LData)), PAnsiChar(AnsiString(LHora)),
    PAnsiChar(AnsiString(LParam)));
end;

function TTEFClientCliSiTef.Transacionar(ADocFiscal: Integer; AValorTotal: Double;
  const ATipoTransacao, AParcelas: string): TTEFResposta;
var
  LGuarda: IInterface;
  LResp: TTEFResposta;
  LTipo: string;
  LFuncao, LParcelas: Integer;
begin
  LGuarda := Self;   // a tarefa na fila nao pode sobreviver ao cliente
  ReiniciarQrCode;
  FCancelarEspera := False;

  LTipo := LowerCase(Trim(ATipoTransacao));
  if LTipo = 'debito' then
    LFuncao := FN_DEBITO
  else if LTipo = 'pix' then
    LFuncao := FN_CARTEIRA_DIGITAL
  else
    LFuncao := FN_CREDITO;
  LParcelas := StrToIntDef(Trim(AParcelas), 1);

  LResp := Default(TTEFResposta);
  NaThreadDaDLL(
    procedure
    var
      LAuto, LCampos: TDictionary<Integer, string>;
      LDataHora: TDateTime;
      LRet: Integer;
    begin
      // Todos os cartoes de uma venda com a mesma data/hora fiscal: e' o que
      // a CliSiTef usa para agrupar os pagamentos do cupom
      if not FDataHoraCupom.TryGetValue(ADocFiscal, LDataHora) then
      begin
        LDataHora := Now;
        FDataHoraCupom.AddOrSetValue(ADocFiscal, LDataHora);
      end;

      LAuto := TDictionary<Integer, string>.Create;
      LCampos := TDictionary<Integer, string>.Create;
      try
        // O operador ja informou as parcelas na tela de pagamento
        if (LFuncao = FN_CREDITO) and (LParcelas > 1) then
          LAuto.Add(TC_PARCELAS, IntToStr(LParcelas));

        LRet := ExecutarFuncao(LFuncao, AValorTotal, IntToStr(ADocFiscal),
          LDataHora, '', LAuto, LCampos);
        LResp := MontarResposta(LRet, LCampos, LTipo, IntToStr(ADocFiscal), LDataHora);
        if LResp.Sucesso then
          LResp.Valor := AValorTotal;
      finally
        LAuto.Free;
        LCampos.Free;
      end;
    end);

  Result := LResp;
  if (not Result.Sucesso) and FCancelarEspera then
  begin
    Result.Status := 'CANCELADA';
    if Result.Erro = '' then
      Result.Erro := 'Transacao cancelada pelo operador';
  end;
  Result.CanceladoOperador := FCancelarEspera;
  FCancelarEspera := False;
end;

function TTEFClientCliSiTef.Confirmar(ADocFiscal: Integer; const AControle: string): TTEFResposta;
var
  LGuarda: IInterface;
  LControle: string;
begin
  LGuarda := Self;
  LControle := AControle;
  NaThreadDaDLL(
    procedure
    begin
      Finalizar(True, LControle);
    end);
  Result := Default(TTEFResposta);
  Result.Sucesso := True;
  Result.Status := 'CONFIRMADA';
end;

function TTEFClientCliSiTef.Desfazer(ADocFiscal: Integer; const AControle: string): TTEFResposta;
var
  LGuarda: IInterface;
  LControle: string;
begin
  LGuarda := Self;
  LControle := AControle;
  NaThreadDaDLL(
    procedure
    begin
      Finalizar(False, LControle);
    end);
  Result := Default(TTEFResposta);
  Result.Sucesso := True;
  Result.Status := 'DESFEITA';
end;

{ Estorno (funcao 200). Os dados da transacao original vao como respostas
  automaticas; o que a CliSiTef pedir alem disso (tipo de cancelamento,
  senha, cartao) vai para a tela. Cupom proprio, confirmado na hora. }
function TTEFClientCliSiTef.Cancelar(ADocFiscal: Integer; AValor: Double;
  const ANSU, AControle: string): TTEFResposta;
var
  LGuarda: IInterface;
  LResp: TTEFResposta;
  LNSU, LControle: string;
begin
  LGuarda := Self;
  FCancelarEspera := False;
  LNSU := ANSU;
  LControle := AControle;
  LResp := Default(TTEFResposta);
  NaThreadDaDLL(
    procedure
    var
      LAuto, LCampos: TDictionary<Integer, string>;
      LPartes: TArray<string>;
      LDataOriginal, LCupom: string;
      LAgora: TDateTime;
      LRet: Integer;
    begin
      LPartes := LControle.Split(['|']);
      // controle: cupom|AAAAMMDD|... -> a CliSiTef quer DDMMAAAA
      if (Length(LPartes) > 1) and (Length(LPartes[1]) = 8) then
        LDataOriginal := Copy(LPartes[1], 7, 2) + Copy(LPartes[1], 5, 2) +
          Copy(LPartes[1], 1, 4)
      else
        LDataOriginal := FormatDateTime('ddmmyyyy', Now);

      LAgora := Now;
      LCupom := FormatDateTime('yyyymmddhhnnss', LAgora);
      LAuto := TDictionary<Integer, string>.Create;
      LCampos := TDictionary<Integer, string>.Create;
      try
        LAuto.Add(TC_VALOR_CANCELAR, ValorSiTef(AValor));
        LAuto.Add(TC_VALOR_CANCELAR2, ValorSiTef(AValor));
        LAuto.Add(TC_DATA_CANCELAR, LDataOriginal);
        LAuto.Add(TC_NSU_CANCELAR, LNSU);

        LRet := ExecutarFuncao(FN_CANCELAMENTO, AValor, LCupom, LAgora, '',
          LAuto, LCampos);
        LResp := MontarResposta(LRet, LCampos, '', LCupom, LAgora);
        if LResp.Sucesso then
        begin
          LResp.Valor := AValor;
          Finalizar(True, LResp.Controle);
        end;
      finally
        LAuto.Free;
        LCampos.Free;
      end;
    end);
  Result := LResp;
  FCancelarEspera := False;
end;

{ Menu administrativo (funcao 110). Quem navega e' o operador, pela tela do
  PDV. Se a operacao escolhida for um cancelamento (campo 110), confirma;
  reimpressao e consultas nao tem o que confirmar. }
function TTEFClientCliSiTef.Administracao: TTEFResposta;
var
  LGuarda: IInterface;
  LResp: TTEFResposta;
begin
  LGuarda := Self;
  FCancelarEspera := False;
  LResp := Default(TTEFResposta);
  NaThreadDaDLL(
    procedure
    var
      LAuto, LCampos: TDictionary<Integer, string>;
      LAgora: TDateTime;
      LCupom: string;
      LRet: Integer;
    begin
      LAgora := Now;
      LCupom := FormatDateTime('yyyymmddhhnnss', LAgora);
      LAuto := TDictionary<Integer, string>.Create;
      LCampos := TDictionary<Integer, string>.Create;
      try
        LRet := ExecutarFuncao(FN_ADMINISTRATIVO, 0, LCupom, LAgora, '',
          LAuto, LCampos);
        LResp := MontarResposta(LRet, LCampos, '', LCupom, LAgora);
        if LResp.Sucesso and LCampos.ContainsKey(TC_CANCELAMENTO) then
          Finalizar(True, LResp.Controle);
      finally
        LAuto.Free;
        LCampos.Free;
      end;
    end);
  Result := LResp;
  FCancelarEspera := False;
end;

{ Carrega a DLL, configura e pergunta pelo pinpad. Com uma transacao no ar a
  DLL esta ocupada e o pinpad em uso: responde "no ar" sem entrar na fila. }
function TTEFClientCliSiTef.ConsultarStatus: Boolean;
var
  LGuarda: IInterface;
  LPresenca: Integer;
begin
  LGuarda := Self;
  if ThreadDaDLL.Ocupada then
  begin
    Log('status: CliSiTef ocupada com uma transacao - considerada no ar');
    Exit(True);
  end;

  LPresenca := -999;
  NaThreadDaDLL(
    procedure
    begin
      Preparar;
      if Assigned(ThreadDaDLL.PresencaPinPad) then
        LPresenca := ThreadDaDLL.PresencaPinPad();
    end, TIMEOUT_STATUS_MS);

  Log('VerificaPresencaPinPad -> %d', [LPresenca]);
  if LPresenca = -999 then
    Result := True   // DLL sem a funcao: configurou, e' o que da para saber
  else
    Result := LPresenca = 1;
end;

initialization
  GLockThread := TCriticalSection.Create;

finalization
  // Uma tarefa presa (pergunta na tela, pinpad) seguraria o WaitFor do
  // Destroy para sempre - nesse caso a thread morre junto com o processo
  if (GThread <> nil) and (not GThread.Ocupada) then
  begin
    GThread.Terminate;
    GThread.FFila.DoShutDown;
    GThread.Free;
  end;
  GLockThread.Free;

end.
