unit uTEF;

{ ============================================================================
  Cliente TEF com DOIS modos de integracao, selecionaveis em apoloweb.ini:

  [TEF]
  habilitado=1
  modo=http                       ; http | arquivo
  url=http://127.0.0.1:8000/api   ; usado quando modo=http
  pasta_req=C:\Tef_Dial\Req\      ; usado quando modo=arquivo
  pasta_resp=C:\Tef_Dial\Resp\    ; usado quando modo=arquivo
  timeout=120                     ; segundos de espera pela resposta
  debug=1                         ; grava C:\Apolo\logs\tef-AAAAMMDD.log
  pix_qr=pinpad                   ; pinpad | tela  (onde o QR do PIX aparece)
  pix_qr_campos=auto              ; so com pix_qr=tela + modo=arquivo
  pix_qr_chaves=auto              ; so com pix_qr=tela + modo=http

  modo=http    -> POST JSON no TefGpAPI (exige TefGpAPI.exe no ar na porta 8000)
  modo=arquivo -> padrao TEF Dedicado: grava intpos.001 na pasta Req e aguarda
                  a resposta na pasta Resp, falando direto com o gerenciador
                  Tef_Dial/GetPay (dispensa a API HTTP)

  Os dois implementam ITEFClient e devolvem o mesmo TTEFResposta, entao o
  restante do sistema (uBridge) nao enxerga diferenca.

  --------------------------------------------------------------------------
  QR CODE DO PIX (pix_qr)
  --------------------------------------------------------------------------
  Quem gera o BR Code de um PIX via TEF e' a adquirente, nao o PDV. Dai as
  duas formas de o cliente enxergar esse QR:

  pix_qr=pinpad (padrao)
      A adquirente desenha o QR no visor do pinpad. O PDV nao recebe payload
      nenhum e nao tem o que exibir - so troca o texto da tela de espera para
      mandar o cliente olhar o pinpad. Funciona com qualquer gerenciador.

  pix_qr=tela
      O PDV exibe o QR devolvido pelo gerenciador. Exige que o gerenciador
      mande o BR Code de volta; quando ele vem ANTES do resultado (resposta
      intermediaria, sem o 009-000), o QR entra na tela com a transacao ainda
      em curso - que e' o unico jeito util. Se o BR Code so chegar junto com o
      resultado, ele fica registrado no log e a tela nao muda: nesse caso o
      pinpad e' o unico caminho.

  Nao ha numero de campo padronizado para o BR Code no intercambio por
  arquivo - cada gerenciador usa o seu. Por isso pix_qr_campos/pix_qr_chaves
  aceitam 'auto' (padrao): o payload e' reconhecido pelo formato, porque todo
  BR Code comeca em '000201' (payload format indicator do EMV). Se o auto
  errar, fixe os campos: pix_qr_campos=950,133 ou pix_qr_chaves=qrCode,emv.

  A numeracao dos campos do modo arquivo foi conferida contra a resposta real
  do gerenciador registrada em C:\Tef_Dial\TefGpAPI\Log\2026-08-15.log (RESP_GP).
  ============================================================================ }

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Net.HttpClient,
  System.Net.URLClient, System.NetEncoding, System.IOUtils, System.DateUtils,
  System.Generics.Collections, uConstantesWeb;

type
  TTEFModo = (tmHTTP, tmArquivo);

  // Onde o QR Code de um PIX via TEF e' apresentado ao cliente
  TTEFPixQr = (pqPinpad, pqTela);

  // Disparado assim que o BR Code aparece na conversa com o gerenciador -
  // idealmente antes do resultado, com a transacao ainda em curso. Corre na
  // THREAD DO TEF: quem assina precisa marshalar para a thread principal.
  TTEFQrCodeProc = reference to procedure(const APayload: string);

  TTEFResposta = record
    Sucesso: Boolean;
    IdReq: Integer;
    Valor: Double;
    Status: string;
    Adquirente: string;
    TipoTransacao: string;
    NSU: string;
    CodigoAutorizacao: string;
    Parcelas: Integer;
    DataHora: string;
    Controle: string;
    Bandeira: string;
    CodigoAutorizacaoGp: string;
    TxId: string;
    End2End: string;
    CnpjAdquirente: string;
    CodigoBandeira: string;
    CodigoCredenciadora: string;
    TipoCartao: string;
    TipoFinanc: string;
    Bin: string;
    Erro: string;
    QrCode: string;           // BR Code do PIX, quando o gerenciador devolve
    // O operador pediu para cancelar enquanto a transacao estava no ar. Com
    // Sucesso=True a aprovacao chegou DEPOIS do pedido: nao entra na venda e
    // tem de ser desfeita.
    CanceladoOperador: Boolean;
    ImpressoCliente: TArray<string>;
    ImpressoLoja: TArray<string>;
  end;

  // Configuracao lida do apoloweb.ini (secao [TEF])
  TTEFConfig = record
    Habilitado: Boolean;
    Modo: TTEFModo;
    Url: string;
    PastaReq: string;
    PastaResp: string;
    TimeoutSeg: Integer;
    Debug: Boolean;
    Identificacao: Integer;   // numero do caixa
    PixQr: TTEFPixQr;         // pinpad (padrao) | tela
    PixQrCampos: string;      // modo arquivo: 'auto' ou lista (ex: 950,133)
    PixQrChaves: string;      // modo http: 'auto' ou lista (ex: qrCode,emv)
    function ModoTexto: string;
    function PixQrTexto: string;
    function Descricao: string;
  end;

  ITEFClient = interface
    ['{7E3A9C21-4D58-4B0E-9E2F-6A1C3D5F8B04}']
    function Transacionar(ADocFiscal: Integer; AValorTotal: Double;
      const ATipoTransacao, AParcelas: string): TTEFResposta;
    function Confirmar(ADocFiscal: Integer; const AControle: string): TTEFResposta;
    function Desfazer(ADocFiscal: Integer; const AControle: string): TTEFResposta;
    function Cancelar(ADocFiscal: Integer; AValor: Double;
      const ANSU, AControle: string): TTEFResposta;
    function ConsultarStatus: Boolean;
    function Administracao: TTEFResposta;
    function GetIdentificacao: Integer;
    procedure SetIdentificacao(AValue: Integer);
    function Modo: TTEFModo;
    function Descricao: string;
    // pix_qr=tela: quem quiser exibir o QR assina aqui (ver TTEFQrCodeProc)
    procedure SetOnQrCode(const AProc: TTEFQrCodeProc);
    function PixQrNaTela: Boolean;
    // Chamado da thread principal com Transacionar em curso na thread do TEF.
    // So sinaliza: quem desiste (ou nao) e' a propria espera da transacao.
    procedure SolicitarCancelamento;
    property Identificacao: Integer read GetIdentificacao write SetIdentificacao;
  end;

  { Base comum aos dois modos (identificacao da automacao, log, mapeamentos) }
  TTEFClientBase = class(TInterfacedObject, ITEFClient)
  protected
    FNomeAutomacao: string;
    FVersaoAutomacao: string;
    FEmpresaAutomacao: string;
    FRegistroCertificacao: string;
    FIdentificacao: Integer;
    FVersaoInterface: Integer;
    FTimeoutSeg: Integer;
    FDebug: Boolean;
    FPixQr: TTEFPixQr;
    FPixQrCampos: string;
    FPixQrChaves: string;
    FOnQrCode: TTEFQrCodeProc;
    FQrNotificado: Boolean;   // um aviso por transacao (o .sts e' relido em loop)
    FCancelarEspera: Boolean; // SolicitarCancelamento (escrito na thread principal)
    procedure Log(const AMsg: string); overload;
    procedure Log(const AFmt: string; const AArgs: array of const); overload;
    function MapearComando(const ATipoTransacao: string): string;
    // Zera o controle de "ja avisei" - chamar no inicio de cada transacao
    procedure ReiniciarQrCode;
    // Loga e dispara FOnQrCode uma unica vez por transacao
    procedure NotificarQrCode(const APayload: string);
    // Varre o JSON atras do BR Code (chaves de FPixQrChaves ou heuristica)
    function ExtrairQrCodeDoJson(AJson: TJSONObject): string;
  public
    constructor Create(const AConfig: TTEFConfig);

    function Transacionar(ADocFiscal: Integer; AValorTotal: Double;
      const ATipoTransacao, AParcelas: string): TTEFResposta; virtual; abstract;
    function Confirmar(ADocFiscal: Integer; const AControle: string): TTEFResposta; virtual; abstract;
    function Desfazer(ADocFiscal: Integer; const AControle: string): TTEFResposta; virtual; abstract;
    function Cancelar(ADocFiscal: Integer; AValor: Double;
      const ANSU, AControle: string): TTEFResposta; virtual; abstract;
    function ConsultarStatus: Boolean; virtual; abstract;
    function Administracao: TTEFResposta; virtual; abstract;
    function Modo: TTEFModo; virtual; abstract;
    function Descricao: string; virtual; abstract;

    procedure SetOnQrCode(const AProc: TTEFQrCodeProc);
    function PixQrNaTela: Boolean;
    procedure SolicitarCancelamento;

    function GetIdentificacao: Integer;
    procedure SetIdentificacao(AValue: Integer);
    property Identificacao: Integer read GetIdentificacao write SetIdentificacao;
  end;

  { ---------------------------------------------------------------------
    Modo HTTP - API REST do TefGpAPI (comportamento original)
    --------------------------------------------------------------------- }
  TTEFClientHTTP = class(TTEFClientBase)
  private
    FBaseURL: string;
    // ATimeoutSeg = 0 usa o timeout configurado; o ADM passa o proprio,
    // porque quem responde e uma pessoa no menu do gerenciador
    function DoPost(const AEndpoint: string; ABody: TJSONObject;
      ATimeoutSeg: Integer = 0): TJSONObject;
    function ParseResposta(AJson: TJSONObject): TTEFResposta;
    function ParseStringArray(AArr: TJSONArray): TArray<string>;
    procedure AddIdentificacaoAutomacao(ABody: TJSONObject);
  public
    constructor Create(const AConfig: TTEFConfig);

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

    property BaseURL: string read FBaseURL write FBaseURL;
  end;

  { ---------------------------------------------------------------------
    Modo ARQUIVO - intercambio intpos.001 / intpos.sts (TEF Dedicado)
    --------------------------------------------------------------------- }

  // Parser de arquivo no formato "NNN-NNN = valor"
  TTEFCampos = class
  private
    FItens: TDictionary<string, string>;
    FBruto: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Carregar(const ATexto: string);
    function Existe(const AChave: string): Boolean;
    function Valor(const AChave: string; const ADefault: string = ''): string;
    function ValorCampo(ACampo: Integer; const ADefault: string = ''): string;
    function ValorCampoInt(ACampo: Integer; ADefault: Integer = 0): Integer;
    function Linhas(ACampo, AQtde: Integer): TArray<string>;
    // BR Code do PIX. ACampos = 'auto' (varre tudo procurando o formato) ou
    // uma lista de numeros de campo: o primeiro preenchido vale.
    function LocalizarBRCode(const ACampos: string): string;
    property Bruto: string read FBruto;
  end;

  // Montador do arquivo de requisicao
  TTEFRequisicao = class
  private
    FLinhas: TStringList;
  public
    constructor Create(const AComando: string);
    destructor Destroy; override;
    procedure Campo(ACampo: Integer; const AValor: string); overload;
    procedure Campo(ACampo, ASub: Integer; const AValor: string); overload;
    procedure CampoInt(ACampo, AValor: Integer);
    function Texto: string;
  end;

  TTEFClientArquivo = class(TTEFClientBase)
  private
    FPastaReq: string;
    FPastaResp: string;
    FTipoSolicitado: string;  // credito/debito/pix pedido pelo caixa
    FRequisicaoRetirada: Boolean; // cancelado antes de o gerenciador ler o intpos.001
    function ArqReqTmp: string;
    function ArqReq: string;
    function ArqResp: string;
    function ArqSts: string;
    function ArqAtivo: string;
    procedure ValidarPastas;
    procedure LimparRespostaAnterior;
    procedure GravarRequisicao(const ATexto: string);
    procedure DescartarRequisicao;
    // Apaga o intpos.001 se o gerenciador ainda nao o pegou. False = ele ja
    // leu (a transacao esta no pinpad) ou o arquivo esta em uso.
    function RetirarRequisicao: Boolean;
    function LerSeCompleto(const APath: string; out ATexto: string): Boolean;
    // Procura o BR Code no que acabou de chegar e avisa a tela. Devolve True
    // quando o arquivo e' so o QR (resposta intermediaria, sem o 009-000) e a
    // espera pelo resultado tem de continuar.
    function TratarQrCodeParcial(ACampos: TTEFCampos): Boolean;
    function AguardarResposta(const AComando: string; ATimeoutSeg: Integer;
      ACampos: TTEFCampos; AAceitaSts: Boolean = False): Boolean;
    function MontarResposta(ACampos: TTEFCampos): TTEFResposta;
    function Executar(ARequisicao: TTEFRequisicao; const AComando: string;
      ATimeoutSeg: Integer; AObrigaResposta: Boolean;
      AAceitaSts: Boolean = False): TTEFResposta;
  public
    constructor Create(const AConfig: TTEFConfig);

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
  end;

function TEFModoFromString(const AValor: string): TTEFModo;
function TEFPixQrFromString(const AValor: string): TTEFPixQr;
// True quando o texto tem cara de BR Code do PIX (payload EMV do BACEN)
function EhBRCodePix(const AValor: string): Boolean;
function CriarTEFClient(const AConfig: TTEFConfig): ITEFClient;

implementation

uses
  uTEFLog;

const
  // Arquivos do intercambio (padrao TEF Dedicado)
  ARQ_INTPOS_TMP = 'intpos.tmp';
  ARQ_INTPOS     = 'intpos.001';
  ARQ_INTPOS_STS = 'intpos.sts';
  ARQ_ATIVO      = 'Ativo.001';

  // Campos (conferidos no RESP_GP do gerenciador)
  // ATENCAO: no intercambio por arquivo o Tef_Dial so despacha os comandos
  // CRT / ATV / ADM / CNF / NCN / CNC / CDP. CDB e PIX (aceitos pela API HTTP
  // do TefGpAPI, que os traduz) sao IGNORADOS em silencio pelo gerenciador -
  // nem o intpos.sts de "recebi" e' gerado e o pinpad nunca acende. Debito e
  // carteira digital se pedem com CRT + CP_TIPOTRANSAC (ver FIN_* abaixo).
  CP_COMANDO      = 0;    // 000-000  CRT/CNC/ADM/CNF/NCN/ATV
  CP_IDENTIFICA   = 1;    // 001-000  identificacao do PDV
  CP_DOCFISCAL    = 2;    // 002-000  documento fiscal
  CP_VALOR        = 3;    // 003-000  valor em centavos
  CP_MOEDA        = 4;    // 004-000
  CP_STATUS_TRANSAC = 9;  // 009-000  status DA TRANSACAO (0 = aprovada)
  CP_ADQUIRENTE   = 10;   // 010-000  REDE, CIELO, ...
  CP_TIPOTRANSAC  = 11;   // 011-000  tipo de financiamento (FIN_* abaixo)
  CP_NSU          = 12;   // 012-000
  CP_AUTORIZACAO  = 13;   // 013-000
  CP_PARCELAS     = 18;   // 018-000
  CP_DATA         = 22;   // 022-000  DDMMAAAA
  CP_HORA         = 23;   // 023-000  HHMMSS
  CP_CONTROLE     = 27;   // 027-000  chave usada no CNF/NCN
  CP_QTD_LOJA     = 28;   // 028-000  qtde de linhas da via da loja
  CP_LINHA_LOJA   = 29;   // 029-nnn  linhas da via da loja
  CP_MENSAGEM     = 30;   // 030-000  mensagem / erro
  CP_BANDEIRA     = 40;   // 040-000  VISA, MASTERCARD, ...
  CP_CNPJ_ADQ     = 600;  // 600-000
  CP_COD_BANDEIRA = 601;  // 601-000
  CP_COD_CREDENC  = 603;  // 603-000
  CP_QTD_CLIENTE  = 710;  // 710-000  qtde de linhas da via do cliente
  CP_LINHA_CLIENT = 711;  // 711-nnn  linhas da via do cliente
  CP_BIN          = 740;  // 740-000
  CP_TIPO_CARTAO  = 731;  // 731-000  1=credito 2=debito 3=voucher
  CP_TIPO_FINANC  = 732;  // 732-000  1=a vista 2/3=parcelado 4/5=pre-datado
  CP_STATUS       = 999;  // 999-999  terminador do arquivo

  // 999-999 e' o TERMINADOR do arquivo (sempre 0 quando o arquivo esta
  // integro) - NAO e' o resultado da transacao. Quem diz se aprovou e' o
  // 009-000. Ler o terminador fazia venda cancelada no pinpad (009-000=77)
  // virar APROVADA e o PDV mandar o CNF em cima de uma transacao inexistente.
  CHAVE_TERMINADOR = '999-999';

  // 011-000 - tabela do proprio Tef_Dial
  FIN_CREDITO_AVISTA    = 10;  // VENDA CREDITO A VISTA
  FIN_CREDITO_PARC_ADM  = 11;  // VENDA CREDITO PARCELADO (administradora)
  FIN_CREDITO_PARC_LOJA = 12;  // VENDA CREDITO PARCELADO (estabelecimento)
  FIN_DEBITO_AVISTA     = 20;  // VENDA DEBITO A VISTA
  FIN_CARTEIRA_DIGITAL  = 50;  // PIX / carteiras digitais

  INTERVALO_POLL_MS = 200;

  // Depois de retirar o intpos.001 num cancelamento, ainda espera um pouco:
  // o gerenciador pode ter lido o arquivo no mesmo instante em que foi
  // apagado, e uma aprovacao nessa brecha precisa ser capturada para ser
  // desfeita.
  CARENCIA_CANCELAMENTO_SEG = 3;

  // O ADM nao e uma transacao: quem esta do outro lado e uma PESSOA navegando
  // o menu do gerenciador (reimpressao, relatorios, funcoes da adquirente).
  // Com o timeout de venda o PDV desistia no meio, jogava fora a resposta que
  // chegava depois ("descartando resposta anterior") e o operador ficava sem
  // retorno nenhum. 15 minutos e o teto - o menu fecha muito antes disso.
  TIMEOUT_ADM_SEG = 900;

  // 009-000 devolvido quando o operador sai do menu / desiste da operacao.
  // Nao e falha: e o caminho normal de quem so foi consultar alguma coisa.
  ST_CANCELADA_OPERADOR = '77';

function ChaveCampo(ACampo, ASub: Integer): string;
begin
  Result := Format('%.3d-%.3d', [ACampo, ASub]);
end;

function TEFModoFromString(const AValor: string): TTEFModo;
begin
  if SameText(Trim(AValor), 'arquivo') then
    Result := tmArquivo
  else
    Result := tmHTTP;
end;

function TEFPixQrFromString(const AValor: string): TTEFPixQr;
begin
  if SameText(Trim(AValor), 'tela') then
    Result := pqTela
  else
    Result := pqPinpad;   // padrao: quem desenha o QR e' a adquirente
end;

// Todo BR Code comeca com o payload format indicator '000201' e carrega o GUI
// do arranjo ('br.gov.bcb.pix') ou, nos QR dinamicos, a URL do payload no PSP.
// Exigir os dois evita confundir com NSU/valor/data que tambem sao numericos.
function EhBRCodePix(const AValor: string): Boolean;
var
  LTexto: string;
begin
  LTexto := Trim(AValor);
  Result := (Length(LTexto) >= 40) and (Copy(LTexto, 1, 6) = '000201') and
    ((Pos('BR.GOV.BCB.PIX', UpperCase(LTexto)) > 0) or
     (Pos('5204', LTexto) > 0));   // merchant category code: presente em todos
end;

function CriarTEFClient(const AConfig: TTEFConfig): ITEFClient;
begin
  case AConfig.Modo of
    tmArquivo: Result := TTEFClientArquivo.Create(AConfig);
  else
    Result := TTEFClientHTTP.Create(AConfig);
  end;
end;

{ TTEFConfig }

function TTEFConfig.ModoTexto: string;
begin
  if Modo = tmArquivo then
    Result := 'arquivo'
  else
    Result := 'http';
end;

function TTEFConfig.PixQrTexto: string;
begin
  if PixQr = pqTela then
    Result := 'tela'
  else
    Result := 'pinpad';
end;

function TTEFConfig.Descricao: string;
begin
  if Modo = tmArquivo then
    Result := Format('arquivo (req=%s resp=%s)', [PastaReq, PastaResp])
  else
    Result := Format('http (%s)', [Url]);
  Result := Result + Format(' | QR PIX: %s', [PixQrTexto]);
end;

{ TTEFClientBase }

constructor TTEFClientBase.Create(const AConfig: TTEFConfig);
begin
  inherited Create;
  FNomeAutomacao := NOME_SISTEMA;
  FVersaoAutomacao := VERSAO_SISTEMA;
  FEmpresaAutomacao := 'Sete Sistemas';
  FRegistroCertificacao := '';
  FVersaoInterface := 1;
  FIdentificacao := AConfig.Identificacao;
  FDebug := AConfig.Debug;
  FTimeoutSeg := AConfig.TimeoutSeg;
  FPixQr := AConfig.PixQr;
  FPixQrCampos := Trim(AConfig.PixQrCampos);
  FPixQrChaves := Trim(AConfig.PixQrChaves);
  if FPixQrCampos = '' then FPixQrCampos := 'auto';
  if FPixQrChaves = '' then FPixQrChaves := 'auto';
  if FIdentificacao <= 0 then
    FIdentificacao := 1;
  if FTimeoutSeg <= 0 then
    FTimeoutSeg := 120;
end;

procedure TTEFClientBase.SetOnQrCode(const AProc: TTEFQrCodeProc);
begin
  FOnQrCode := AProc;
end;

function TTEFClientBase.PixQrNaTela: Boolean;
begin
  Result := FPixQr = pqTela;
end;

procedure TTEFClientBase.SolicitarCancelamento;
begin
  FCancelarEspera := True;
  Log('cancelamento solicitado pelo operador');
end;

procedure TTEFClientBase.ReiniciarQrCode;
begin
  FQrNotificado := False;
end;

// O BR Code vale a pena registrar mesmo com pix_qr=pinpad: e' assim que se
// descobre se o gerenciador devolve o payload e em que momento, para entao
// poder ligar o pix_qr=tela.
procedure TTEFClientBase.NotificarQrCode(const APayload: string);
begin
  if (APayload = '') or FQrNotificado then Exit;
  FQrNotificado := True;

  Log('QR Code PIX recebido do gerenciador (%d caracteres): %s',
    [Length(APayload), APayload]);

  if FPixQr <> pqTela then
  begin
    Log('pix_qr=pinpad - QR nao vai para a tela do PDV');
    Exit;
  end;

  if Assigned(FOnQrCode) then
    FOnQrCode(APayload)
  else
    Log('pix_qr=tela mas ninguem assinou OnQrCode - QR descartado');
end;

function TTEFClientBase.ExtrairQrCodeDoJson(AJson: TJSONObject): string;
var
  LPar: TJSONPair;
  LChaves: TArray<string>;
  LChave, LValor: string;
begin
  Result := '';
  if AJson = nil then Exit;

  // Lista explicita: respeita a ordem informada, sem checar formato (o
  // integrador que fixou o campo sabe o que esta pedindo)
  if not SameText(FPixQrChaves, 'auto') then
  begin
    LChaves := FPixQrChaves.Split([',', ';']);
    for LChave in LChaves do
    begin
      LValor := Trim(AJson.GetValue<string>(Trim(LChave), ''));
      if LValor <> '' then Exit(LValor);
    end;
    Exit;
  end;

  // auto: qualquer string do JSON que tenha cara de BR Code
  for LPar in AJson do
  begin
    if LPar.JsonValue is TJSONString then
    begin
      LValor := Trim(LPar.JsonValue.Value);
      if EhBRCodePix(LValor) then
        Exit(LValor);
    end;
  end;
end;

function TTEFClientBase.GetIdentificacao: Integer;
begin
  Result := FIdentificacao;
end;

procedure TTEFClientBase.SetIdentificacao(AValue: Integer);
begin
  if AValue > 0 then
    FIdentificacao := AValue;
end;

procedure TTEFClientBase.Log(const AMsg: string);
begin
  if FDebug then
    TEFLog(AMsg);
end;

procedure TTEFClientBase.Log(const AFmt: string; const AArgs: array of const);
begin
  if FDebug then
    TEFLog(AFmt, AArgs);
end;

// credito -> CRT | debito -> CDB | pix -> PIX
// SO PARA O MODO HTTP: sao os codigos que o TefGpAPI entende e traduz para o
// gerenciador. No modo arquivo o Tef_Dial nao conhece CDB/PIX - la a
// TTEFClientArquivo.Transacionar manda CRT e diferencia pelo campo 011-000.
function TTEFClientBase.MapearComando(const ATipoTransacao: string): string;
begin
  if SameText(ATipoTransacao, 'debito') then
    Result := 'CDB'
  else if SameText(ATipoTransacao, 'pix') then
    Result := 'PIX'
  else
    Result := 'CRT';
end;

{ ===========================================================================
  TTEFClientHTTP
  =========================================================================== }

constructor TTEFClientHTTP.Create(const AConfig: TTEFConfig);
begin
  inherited Create(AConfig);
  FBaseURL := AConfig.Url;
end;

function TTEFClientHTTP.Modo: TTEFModo;
begin
  Result := tmHTTP;
end;

function TTEFClientHTTP.Descricao: string;
begin
  Result := 'http (' + FBaseURL + ')';
end;

procedure TTEFClientHTTP.AddIdentificacaoAutomacao(ABody: TJSONObject);
begin
  ABody.AddPair('versaoInterface', TJSONNumber.Create(FVersaoInterface));
  ABody.AddPair('nomeAutomacao', FNomeAutomacao);
  ABody.AddPair('versaoAutomacao', FVersaoAutomacao);
  ABody.AddPair('registroCertificacao', FRegistroCertificacao);
end;

function TTEFClientHTTP.DoPost(const AEndpoint: string; ABody: TJSONObject;
  ATimeoutSeg: Integer): TJSONObject;
var
  LHttp: THTTPClient;
  LReqStream: TStringStream;
  LResponse: IHTTPResponse;
  LUrl, LBodyStr, LRespStr: string;
  LTimeout: Integer;
begin
  Result := nil;
  LTimeout := ATimeoutSeg;
  if LTimeout <= 0 then
    LTimeout := FTimeoutSeg;

  LHttp := THTTPClient.Create;
  try
    LHttp.ConnectionTimeout := 10000;           // 10s para conectar
    LHttp.ResponseTimeout := LTimeout * 1000;   // pinpad (ou operador) demora
    LHttp.ContentType := 'application/json';

    LUrl := FBaseURL + '/' + AEndpoint;
    LBodyStr := ABody.ToJSON;
    Log('HTTP POST %s -> %s', [LUrl, LBodyStr]);

    LReqStream := TStringStream.Create(LBodyStr, TEncoding.UTF8);
    try
      LResponse := LHttp.Post(LUrl, LReqStream);
      LRespStr := LResponse.ContentAsString(TEncoding.UTF8);

      if LResponse.StatusCode in [200, 201] then
      begin
        Log('HTTP %d <- %s', [LResponse.StatusCode, LRespStr]);
        Result := TJSONObject.ParseJSONValue(LRespStr) as TJSONObject;
      end
      else
      begin
        Log('HTTP ERRO %d <- %s', [LResponse.StatusCode, LRespStr]);
        raise Exception.CreateFmt('TEF HTTP %d: %s', [LResponse.StatusCode, LRespStr]);
      end;
    finally
      LReqStream.Free;
    end;
  finally
    LHttp.Free;
  end;
end;

function TTEFClientHTTP.ParseStringArray(AArr: TJSONArray): TArray<string>;
var
  I: Integer;
begin
  if AArr = nil then Exit(nil);
  SetLength(Result, AArr.Count);
  for I := 0 to AArr.Count - 1 do
    Result[I] := AArr.Items[I].Value;
end;

function TTEFClientHTTP.ParseResposta(AJson: TJSONObject): TTEFResposta;
var
  LArrCliente, LArrLoja: TJSONArray;
begin
  Result := Default(TTEFResposta);

  if AJson = nil then
  begin
    Result.Erro := 'Resposta vazia do servidor TEF';
    Exit;
  end;

  Result.IdReq := AJson.GetValue<Integer>('idReq', 0);
  Result.Valor := AJson.GetValue<Double>('valor', 0);
  Result.Status := AJson.GetValue<string>('status', '');
  Result.Adquirente := AJson.GetValue<string>('adquirente', '');
  Result.TipoTransacao := AJson.GetValue<string>('tipoTransacao', '');
  Result.NSU := AJson.GetValue<string>('nsu', '');
  Result.CodigoAutorizacao := AJson.GetValue<string>('codigoAutorizacao', '');
  Result.Parcelas := AJson.GetValue<Integer>('parcelas', 1);
  Result.DataHora := AJson.GetValue<string>('dataHora', '');
  Result.Controle := AJson.GetValue<string>('controle', '');
  Result.Bandeira := AJson.GetValue<string>('bandeira', '');
  Result.CodigoAutorizacaoGp := AJson.GetValue<string>('codigoAutorizacaoGp', '');
  Result.TxId := AJson.GetValue<string>('txId', '');
  Result.End2End := AJson.GetValue<string>('end2end', '');
  Result.CnpjAdquirente := AJson.GetValue<string>('cnpjAdiquirente', '');
  Result.CodigoBandeira := AJson.GetValue<string>('codigoBandeira', '');
  Result.CodigoCredenciadora := AJson.GetValue<string>('codigoCredenciadora', '');
  Result.TipoCartao := AJson.GetValue<string>('tipoCartao', '');
  Result.TipoFinanc := AJson.GetValue<string>('tipoFinanc', '');
  Result.Bin := AJson.GetValue<string>('bin', '');
  Result.Erro := AJson.GetValue<string>('erro', '');
  Result.QrCode := ExtrairQrCodeDoJson(AJson);

  if AJson.TryGetValue<TJSONArray>('impressoCliente', LArrCliente) then
    Result.ImpressoCliente := ParseStringArray(LArrCliente);
  if AJson.TryGetValue<TJSONArray>('impressoLoja', LArrLoja) then
    Result.ImpressoLoja := ParseStringArray(LArrLoja);

  Result.Sucesso := (Result.Erro = '') and (Result.Status <> '');
end;

function TTEFClientHTTP.Transacionar(ADocFiscal: Integer; AValorTotal: Double;
  const ATipoTransacao, AParcelas: string): TTEFResposta;
var
  LBody, LResp: TJSONObject;
begin
  ReiniciarQrCode;
  FCancelarEspera := False;

  LBody := TJSONObject.Create;
  try
    LBody.AddPair('comando', MapearComando(ATipoTransacao));
    LBody.AddPair('identificacao', TJSONNumber.Create(FIdentificacao));
    LBody.AddPair('docFiscal', TJSONNumber.Create(ADocFiscal));
    LBody.AddPair('valorTotal', TJSONNumber.Create(Round(AValorTotal * 100))); // centavos
    LBody.AddPair('moeda', TJSONNumber.Create(0));
    LBody.AddPair('tipoTransacao', ATipoTransacao);
    LBody.AddPair('parcelas', AParcelas);
    LBody.AddPair('capAutomacao', TJSONNumber.Create(0));
    LBody.AddPair('empresaAutomacao', FEmpresaAutomacao);
    AddIdentificacaoAutomacao(LBody);

    LResp := DoPost('tefgp-req', LBody);
    try
      Result := ParseResposta(LResp);
    finally
      LResp.Free;
    end;
  finally
    LBody.Free;
  end;

  // O POST e' bloqueante: aqui o QR so chega junto com o resultado, tarde
  // demais para o cliente ler. Fica no log, que e' o que permite descobrir
  // se o TefGpAPI devolve o payload e em qual chave.
  NotificarQrCode(Result.QrCode);

  // O POST nao tem como ser interrompido: o pedido de cancelamento so marca
  // o desfecho, para uma aprovacao tardia ser desfeita e nao registrada
  Result.CanceladoOperador := FCancelarEspera;
  FCancelarEspera := False;
end;

function TTEFClientHTTP.Confirmar(ADocFiscal: Integer; const AControle: string): TTEFResposta;
var
  LBody, LResp: TJSONObject;
begin
  LBody := TJSONObject.Create;
  try
    LBody.AddPair('comando', 'CNF');
    LBody.AddPair('identificacao', TJSONNumber.Create(FIdentificacao));
    LBody.AddPair('docFiscal', TJSONNumber.Create(ADocFiscal));
    LBody.AddPair('controle', AControle);
    AddIdentificacaoAutomacao(LBody);

    LResp := DoPost('tefgp-conf', LBody);
    try
      if LResp <> nil then
        Result := ParseResposta(LResp)
      else
      begin
        // Conf pode retornar vazio em caso de OK
        Result := Default(TTEFResposta);
        Result.Sucesso := True;
      end;
    finally
      LResp.Free;
    end;
  finally
    LBody.Free;
  end;
end;

function TTEFClientHTTP.Desfazer(ADocFiscal: Integer; const AControle: string): TTEFResposta;
var
  LBody, LResp: TJSONObject;
begin
  LBody := TJSONObject.Create;
  try
    LBody.AddPair('comando', 'NCN');
    LBody.AddPair('identificacao', TJSONNumber.Create(FIdentificacao));
    LBody.AddPair('docFiscal', TJSONNumber.Create(ADocFiscal));
    LBody.AddPair('controle', AControle);
    AddIdentificacaoAutomacao(LBody);

    LResp := DoPost('tefgp-desfaz', LBody);
    try
      if LResp <> nil then
        Result := ParseResposta(LResp)
      else
      begin
        Result := Default(TTEFResposta);
        Result.Sucesso := True;
      end;
    finally
      LResp.Free;
    end;
  finally
    LBody.Free;
  end;
end;

function TTEFClientHTTP.Cancelar(ADocFiscal: Integer; AValor: Double;
  const ANSU, AControle: string): TTEFResposta;
var
  LBody, LResp: TJSONObject;
begin
  LBody := TJSONObject.Create;
  try
    LBody.AddPair('comando', 'CNC');
    LBody.AddPair('identificacao', TJSONNumber.Create(FIdentificacao));
    LBody.AddPair('docFiscal', TJSONNumber.Create(ADocFiscal));
    LBody.AddPair('valorTotal', TJSONNumber.Create(Round(AValor * 100))); // centavos
    LBody.AddPair('moeda', TJSONNumber.Create(0));
    LBody.AddPair('nsu', ANSU);
    LBody.AddPair('controle', AControle);
    LBody.AddPair('capAutomacao', TJSONNumber.Create(0));
    LBody.AddPair('empresaAutomacao', FEmpresaAutomacao);
    AddIdentificacaoAutomacao(LBody);

    LResp := DoPost('tefgp-cancel', LBody);
    try
      Result := ParseResposta(LResp);
    finally
      LResp.Free;
    end;
  finally
    LBody.Free;
  end;
end;

function TTEFClientHTTP.ConsultarStatus: Boolean;
var
  LBody, LResp: TJSONObject;
begin
  Result := False;
  LBody := TJSONObject.Create;
  try
    try
      LResp := DoPost('tefgp-status', LBody);
      try
        Result := (LResp <> nil);
      finally
        LResp.Free;
      end;
    except
      on E: Exception do
      begin
        Log('status HTTP indisponivel: %s', [E.Message]);
        Result := False;
      end;
    end;
  finally
    LBody.Free;
  end;
end;

function TTEFClientHTTP.Administracao: TTEFResposta;
var
  LBody, LResp: TJSONObject;
begin
  LBody := TJSONObject.Create;
  try
    LBody.AddPair('comando', 'ADM');
    LBody.AddPair('identificacao', TJSONNumber.Create(FIdentificacao));
    AddIdentificacaoAutomacao(LBody);

    LResp := DoPost('tefgp-adm', LBody, TIMEOUT_ADM_SEG);
    try
      Result := ParseResposta(LResp);
    finally
      LResp.Free;
    end;
  finally
    LBody.Free;
  end;
end;

{ ===========================================================================
  TTEFCampos - parser do arquivo "NNN-NNN = valor"
  =========================================================================== }

constructor TTEFCampos.Create;
begin
  inherited Create;
  FItens := TDictionary<string, string>.Create;
end;

destructor TTEFCampos.Destroy;
begin
  FItens.Free;
  inherited;
end;

procedure TTEFCampos.Carregar(const ATexto: string);
var
  LLinhas: TStringList;
  I, LPos: Integer;
  LLinha, LChave, LValor: string;
begin
  FBruto := ATexto;
  FItens.Clear;
  LLinhas := TStringList.Create;
  try
    LLinhas.Text := ATexto;
    for I := 0 to LLinhas.Count - 1 do
    begin
      LLinha := LLinhas[I];
      LPos := Pos('=', LLinha);
      if LPos <= 0 then Continue;

      LChave := Trim(Copy(LLinha, 1, LPos - 1));
      LValor := Trim(Copy(LLinha, LPos + 1, MaxInt));

      // Linhas de comprovante vem entre aspas e preservam os espacos internos
      if (Length(LValor) >= 2) and (LValor[1] = '"') and
         (LValor[Length(LValor)] = '"') then
        LValor := Copy(LValor, 2, Length(LValor) - 2);

      if LChave <> '' then
        FItens.AddOrSetValue(LChave, LValor);
    end;
  finally
    LLinhas.Free;
  end;
end;

function TTEFCampos.Existe(const AChave: string): Boolean;
begin
  Result := FItens.ContainsKey(AChave);
end;

function TTEFCampos.Valor(const AChave: string; const ADefault: string): string;
begin
  if not FItens.TryGetValue(AChave, Result) then
    Result := ADefault;
end;

function TTEFCampos.ValorCampo(ACampo: Integer; const ADefault: string): string;
begin
  Result := Trim(Valor(ChaveCampo(ACampo, 0), ADefault));
end;

function TTEFCampos.ValorCampoInt(ACampo, ADefault: Integer): Integer;
begin
  Result := StrToIntDef(Trim(ValorCampo(ACampo, '')), ADefault);
end;

// Linhas de comprovante: 029-001..029-nnn (loja) e 711-001..711-nnn (cliente).
// AQtde vem do campo de contagem; para na primeira lacuna depois dela.
function TTEFCampos.Linhas(ACampo, AQtde: Integer): TArray<string>;
var
  I, LMax: Integer;
  LLista: TStringList;
begin
  LLista := TStringList.Create;
  try
    LMax := AQtde;
    if LMax <= 0 then LMax := 99;
    for I := 1 to LMax do
    begin
      if not Existe(ChaveCampo(ACampo, I)) then
      begin
        if I > AQtde then Break;
        Continue;
      end;
      LLista.Add(Valor(ChaveCampo(ACampo, I)));
    end;
    Result := LLista.ToStringArray;
  finally
    LLista.Free;
  end;
end;

// BR Code do PIX no intpos. Nao ha campo padronizado - cada gerenciador usa o
// seu -, por isso o padrao e' 'auto': varre todos os campos e aceita o que
// tiver o formato de BR Code. ACampos com uma lista ('950,133') fixa a busca
// e dispensa a heuristica.
function TTEFCampos.LocalizarBRCode(const ACampos: string): string;
var
  LLista: TArray<string>;
  LItem, LValor: string;
  LCampo: Integer;
  LPar: TPair<string, string>;
begin
  Result := '';

  if not SameText(Trim(ACampos), 'auto') then
  begin
    LLista := ACampos.Split([',', ';']);
    for LItem in LLista do
    begin
      LCampo := StrToIntDef(Trim(LItem), -1);
      if LCampo < 0 then Continue;
      LValor := ValorCampo(LCampo, '');
      if LValor <> '' then Exit(LValor);
    end;
    Exit;
  end;

  for LPar in FItens do
    if EhBRCodePix(LPar.Value) then
      Exit(Trim(LPar.Value));
end;

{ TTEFRequisicao }

constructor TTEFRequisicao.Create(const AComando: string);
begin
  inherited Create;
  FLinhas := TStringList.Create;
  Campo(CP_COMANDO, AComando);
end;

destructor TTEFRequisicao.Destroy;
begin
  FLinhas.Free;
  inherited;
end;

procedure TTEFRequisicao.Campo(ACampo: Integer; const AValor: string);
begin
  Campo(ACampo, 0, AValor);
end;

procedure TTEFRequisicao.Campo(ACampo, ASub: Integer; const AValor: string);
begin
  if AValor = '' then Exit;
  FLinhas.Add(ChaveCampo(ACampo, ASub) + ' = ' + AValor);
end;

procedure TTEFRequisicao.CampoInt(ACampo, AValor: Integer);
begin
  Campo(ACampo, 0, IntToStr(AValor));
end;

function TTEFRequisicao.Texto: string;
begin
  Result := FLinhas.Text + ChaveCampo(CP_STATUS, CP_STATUS) + ' = 0' + sLineBreak;
end;

{ ===========================================================================
  TTEFClientArquivo
  =========================================================================== }

constructor TTEFClientArquivo.Create(const AConfig: TTEFConfig);
begin
  inherited Create(AConfig);
  FPastaReq := IncludeTrailingPathDelimiter(Trim(AConfig.PastaReq));
  FPastaResp := IncludeTrailingPathDelimiter(Trim(AConfig.PastaResp));
end;

function TTEFClientArquivo.Modo: TTEFModo;
begin
  Result := tmArquivo;
end;

function TTEFClientArquivo.Descricao: string;
begin
  Result := Format('arquivo (req=%s resp=%s)', [FPastaReq, FPastaResp]);
end;

function TTEFClientArquivo.ArqReqTmp: string;
begin
  Result := FPastaReq + ARQ_INTPOS_TMP;
end;

function TTEFClientArquivo.ArqReq: string;
begin
  Result := FPastaReq + ARQ_INTPOS;
end;

function TTEFClientArquivo.ArqResp: string;
begin
  Result := FPastaResp + ARQ_INTPOS;
end;

function TTEFClientArquivo.ArqSts: string;
begin
  Result := FPastaResp + ARQ_INTPOS_STS;
end;

function TTEFClientArquivo.ArqAtivo: string;
begin
  Result := FPastaResp + ARQ_ATIVO;
end;

procedure TTEFClientArquivo.ValidarPastas;
begin
  if (Length(FPastaReq) <= 1) or (Length(FPastaResp) <= 1) then
    raise Exception.Create('Pastas de intercambio TEF nao configuradas ' +
      '(apoloweb.ini: [TEF] pasta_req / pasta_resp)');
  if not TDirectory.Exists(FPastaReq) then
    raise Exception.CreateFmt('Pasta de requisicao TEF nao encontrada: %s', [FPastaReq]);
  if not TDirectory.Exists(FPastaResp) then
    raise Exception.CreateFmt('Pasta de resposta TEF nao encontrada: %s', [FPastaResp]);
end;

// Resposta velha na pasta faria a transacao nova "aprovar" com dados antigos
procedure TTEFClientArquivo.LimparRespostaAnterior;
begin
  try
    if TFile.Exists(ArqResp) then
    begin
      Log('descartando resposta anterior: %s', [ArqResp]);
      TFile.Delete(ArqResp);
    end;
  except
    on E: Exception do
      Log('falha ao apagar resposta anterior: %s', [E.Message]);
  end;
end;

procedure TTEFClientArquivo.GravarRequisicao(const ATexto: string);
begin
  // grava em .tmp e renomeia: o gerenciador so enxerga o arquivo completo
  if TFile.Exists(ArqReqTmp) then
    TFile.Delete(ArqReqTmp);
  if TFile.Exists(ArqReq) then
    TFile.Delete(ArqReq);

  TFile.WriteAllText(ArqReqTmp, ATexto, TEncoding.ANSI);
  TFile.Move(ArqReqTmp, ArqReq);
  Log('REQ -> %s'#13#10'%s', [ArqReq, ATexto]);
end;

// No timeout o arquivo precisa sumir: senao o gerenciador processa a venda
// depois que o operador ja desistiu dela.
procedure TTEFClientArquivo.DescartarRequisicao;
begin
  try
    if TFile.Exists(ArqReq) then
    begin
      TFile.Delete(ArqReq);
      Log('requisicao descartada por timeout: %s', [ArqReq]);
    end;
  except
    on E: Exception do
      Log('falha ao descartar requisicao: %s', [E.Message]);
  end;
end;

// O gerenciador apaga o intpos.001 da pasta Req quando o le. Se o arquivo
// ainda existe, a transacao nem comecou e da para desistir dela aqui.
function TTEFClientArquivo.RetirarRequisicao: Boolean;
begin
  Result := False;
  try
    if TFile.Exists(ArqReq) then
    begin
      TFile.Delete(ArqReq);
      Result := not TFile.Exists(ArqReq);
    end;
  except
    on E: Exception do
      Log('falha ao retirar a requisicao: %s', [E.Message]);
  end;
end;

// Le sem travar o arquivo e so aceita quando ja tem o terminador 999-999,
// evitando pegar um arquivo pela metade enquanto o gerenciador escreve.
function TTEFClientArquivo.LerSeCompleto(const APath: string; out ATexto: string): Boolean;
var
  LStream: TFileStream;
  LBytes: TBytes;
begin
  Result := False;
  ATexto := '';
  try
    LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(LBytes, LStream.Size);
      if Length(LBytes) > 0 then
        LStream.ReadBuffer(LBytes[0], Length(LBytes));
    finally
      LStream.Free;
    end;
    ATexto := TEncoding.ANSI.GetString(LBytes);
    Result := Pos(CHAVE_TERMINADOR, ATexto) > 0;
  except
    // arquivo em uso pelo gerenciador: tenta de novo no proximo ciclo
    Result := False;
  end;
end;

// So o intpos.001 da pasta de resposta e' o RESULTADO da transacao. O
// intpos.sts e' apenas o "recebi a requisicao" do gerenciador (e o heartbeat
// ATV) e chega em milissegundos - aceita-lo como resposta fazia o PDV aprovar
// a venda antes de o cliente passar o cartao, mandar o CNF no meio do fluxo
// (Tef_Dial reclama "-2 - Erro no arquivo" e devolve "OPERACAO CANCELADA") e
// so receber o resultado de verdade na venda seguinte.
function TTEFClientArquivo.AguardarResposta(const AComando: string;
  ATimeoutSeg: Integer; ACampos: TTEFCampos; AAceitaSts: Boolean): Boolean;
var
  LFim, LFimCarencia: TDateTime;
  LTexto: string;
  LAckLogado, LCancelTratado: Boolean;
begin
  Result := False;
  LFim := IncSecond(Now, ATimeoutSeg);
  LAckLogado := False;
  LCancelTratado := False;

  while Now < LFim do
  begin
    // Cancelamento pelo operador (so a venda - CNF/NCN/ATV nao se cancelam).
    // Com o intpos.001 ainda na pasta Req, o gerenciador nao comecou nada:
    // retira o arquivo e encerra depois da carencia. Se ele ja leu, o pinpad
    // esta com a transacao e o PDV nao tem como aborta-la - segue esperando
    // o desfecho ate o timeout, para uma aprovacao tardia ser desfeita.
    if FCancelarEspera and (not LCancelTratado) and SameText(AComando, 'CRT') then
    begin
      LCancelTratado := True;
      if RetirarRequisicao then
      begin
        FRequisicaoRetirada := True;
        LFimCarencia := IncSecond(Now, CARENCIA_CANCELAMENTO_SEG);
        if LFimCarencia < LFim then
          LFim := LFimCarencia;
        Log('cancelado antes de o gerenciador ler %s - requisicao retirada', [ArqReq]);
      end
      else
        Log('cancelamento com a requisicao ja no gerenciador - aguardando o ' +
          'desfecho (aprovacao que chegar sera desfeita)');
    end;

    if TFile.Exists(ArqResp) and LerSeCompleto(ArqResp, LTexto) then
    begin
      ACampos.Carregar(LTexto);
      if SameText(ACampos.ValorCampo(CP_COMANDO), AComando) then
      begin
        Log('RESP <- %s'#13#10'%s', [ArqResp, LTexto]);
        try
          TFile.Delete(ArqResp);
        except
          on E: Exception do
            Log('falha ao apagar %s: %s', [ArqResp, E.Message]);
        end;

        // O PIX pode vir em duas etapas: primeiro o BR Code, depois o
        // resultado. Consumir a etapa do QR como se fosse o resultado
        // aprovaria a venda antes de o cliente pagar.
        if TratarQrCodeParcial(ACampos) then
          Continue;

        Exit(True);
      end;
    end;

    if TFile.Exists(ArqSts) and LerSeCompleto(ArqSts, LTexto) then
    begin
      ACampos.Carregar(LTexto);
      if SameText(ACampos.ValorCampo(CP_COMANDO), AComando) then
      begin
        // ATV (consulta de status) se resolve no proprio .sts
        if AAceitaSts then
        begin
          Log('RESP <- %s'#13#10'%s', [ArqSts, LTexto]);
          Exit(True);
        end;

        if not LAckLogado then
        begin
          LAckLogado := True;
          Log('ACK <- %s (gerenciador recebeu %s; aguardando o resultado em %s)',
            [ArqSts, AComando, ArqResp]);
        end;

        // Ha gerenciador que despacha o BR Code no proprio .sts
        NotificarQrCode(ACampos.LocalizarBRCode(FPixQrCampos));
      end;
    end;

    Sleep(INTERVALO_POLL_MS);
  end;
end;

// Resposta com BR Code e SEM 009-000 e' a etapa intermediaria do PIX: manda o
// QR para a tela e devolve True para a espera continuar. Com 009-000 o
// arquivo e' o resultado da transacao - o QR (se houver) so vale para log.
function TTEFClientArquivo.TratarQrCodeParcial(ACampos: TTEFCampos): Boolean;
var
  LPayload: string;
begin
  LPayload := ACampos.LocalizarBRCode(FPixQrCampos);
  Result := (LPayload <> '') and
            (not ACampos.Existe(ChaveCampo(CP_STATUS_TRANSAC, 0)));

  NotificarQrCode(LPayload);

  if Result then
    Log('resposta intermediaria (QR sem 009-000) - seguindo a espera do resultado');
end;

function TTEFClientArquivo.MontarResposta(ACampos: TTEFCampos): TTEFResposta;
var
  LStatus, LData, LHora, LTipoCartao, LTipoFinanc: string;
begin
  Result := Default(TTEFResposta);

  // O resultado da transacao esta no 009-000; o 999-999 e' so o terminador do
  // arquivo (vem 0 ate em "OPERACAO CANCELADA"). O ATV nao traz 009-000, entao
  // ai vale o terminador mesmo.
  if ACampos.Existe(ChaveCampo(CP_STATUS_TRANSAC, 0)) then
    LStatus := ACampos.ValorCampo(CP_STATUS_TRANSAC, '0')
  else
    LStatus := Trim(ACampos.Valor(CHAVE_TERMINADOR, '0'));

  Result.Sucesso := (LStatus = '0');
  if Result.Sucesso then
    Result.Status := 'APROVADA'
  else
  begin
    // Desistencia do operador (sair do menu ADM, abortar a venda no pinpad)
    // nao e recusa da adquirente - a tela trata os dois casos diferente.
    if LStatus = ST_CANCELADA_OPERADOR then
      Result.Status := 'CANCELADA'
    else
      Result.Status := 'NEGADA';
    Result.Erro := ACampos.ValorCampo(CP_MENSAGEM);
    if Result.Erro = '' then
      Result.Erro := Format('TEF retornou status %s', [LStatus]);
  end;

  Result.IdReq := ACampos.ValorCampoInt(CP_IDENTIFICA, FIdentificacao);
  Result.Valor := ACampos.ValorCampoInt(CP_VALOR, 0) / 100;
  Result.Adquirente := ACampos.ValorCampo(CP_ADQUIRENTE);
  Result.TipoTransacao := ACampos.ValorCampo(CP_TIPOTRANSAC);
  Result.NSU := ACampos.ValorCampo(CP_NSU);
  Result.CodigoAutorizacao := ACampos.ValorCampo(CP_AUTORIZACAO);
  Result.CodigoAutorizacaoGp := Result.CodigoAutorizacao;
  Result.Parcelas := ACampos.ValorCampoInt(CP_PARCELAS, 1);
  Result.Controle := ACampos.ValorCampo(CP_CONTROLE);
  Result.Bandeira := ACampos.ValorCampo(CP_BANDEIRA);
  Result.CnpjAdquirente := ACampos.ValorCampo(CP_CNPJ_ADQ);
  Result.CodigoBandeira := ACampos.ValorCampo(CP_COD_BANDEIRA);
  Result.CodigoCredenciadora := ACampos.ValorCampo(CP_COD_CREDENC);
  Result.Bin := ACampos.ValorCampo(CP_BIN);

  // Como tudo sai como CRT, o tipo real vem do 731-000 da resposta; sem ele
  // vale o que o operador escolheu na tela.
  LTipoCartao := ACampos.ValorCampo(CP_TIPO_CARTAO);
  if LTipoCartao = '2' then
    Result.TipoCartao := 'DEBITO'
  else if LTipoCartao = '1' then
    Result.TipoCartao := 'CREDITO'
  else if FTipoSolicitado = 'debito' then
    Result.TipoCartao := 'DEBITO'
  else if FTipoSolicitado = 'pix' then
    Result.TipoCartao := 'PIX'
  else
    Result.TipoCartao := 'CREDITO';

  // 732-000: 1 = a vista | 2,3 = parcelado | 4,5 = pre-datado
  LTipoFinanc := ACampos.ValorCampo(CP_TIPO_FINANC);
  if (LTipoFinanc = '2') or (LTipoFinanc = '3') then
    Result.TipoFinanc := 'PARCELADO'
  else if LTipoFinanc = '1' then
    Result.TipoFinanc := 'AVISTA'
  else if Result.Parcelas > 1 then
    Result.TipoFinanc := 'PARCELADO'
  else
    Result.TipoFinanc := 'AVISTA';

  // 022-000 = DDMMAAAA e 023-000 = HHMMSS -> ISO, igual ao modo HTTP
  LData := ACampos.ValorCampo(CP_DATA);
  LHora := ACampos.ValorCampo(CP_HORA);
  if Length(LData) = 8 then
  begin
    Result.DataHora := Copy(LData, 5, 4) + '-' + Copy(LData, 3, 2) + '-' +
      Copy(LData, 1, 2);
    if Length(LHora) = 6 then
      Result.DataHora := Result.DataHora + 'T' + Copy(LHora, 1, 2) + ':' +
        Copy(LHora, 3, 2) + ':' + Copy(LHora, 5, 2)
    else
      Result.DataHora := Result.DataHora + 'T00:00:00';
  end;

  Result.QrCode := ACampos.LocalizarBRCode(FPixQrCampos);

  Result.ImpressoCliente := ACampos.Linhas(CP_LINHA_CLIENT,
    ACampos.ValorCampoInt(CP_QTD_CLIENTE, 0));
  Result.ImpressoLoja := ACampos.Linhas(CP_LINHA_LOJA,
    ACampos.ValorCampoInt(CP_QTD_LOJA, 0));
end;

function TTEFClientArquivo.Executar(ARequisicao: TTEFRequisicao;
  const AComando: string; ATimeoutSeg: Integer;
  AObrigaResposta: Boolean; AAceitaSts: Boolean): TTEFResposta;
var
  LCampos: TTEFCampos;
begin
  Result := Default(TTEFResposta);
  ValidarPastas;
  LimparRespostaAnterior;
  GravarRequisicao(ARequisicao.Texto);

  LCampos := TTEFCampos.Create;
  try
    if AguardarResposta(AComando, ATimeoutSeg, LCampos, AAceitaSts) then
      Result := MontarResposta(LCampos)
    else
    begin
      DescartarRequisicao;
      if AObrigaResposta then
      begin
        Result.Status := 'TIMEOUT';
        Result.Erro := Format(
          'Sem resposta do gerenciador TEF em %ds (verifique se o Tef_Dial ' +
          'esta em execucao e monitorando %s)', [ATimeoutSeg, FPastaReq]);
      end
      else
      begin
        // CNF/NCN nem sempre geram arquivo de resposta
        Log('%s sem arquivo de resposta - assumindo OK', [AComando]);
        Result.Sucesso := True;
      end;
    end;
  finally
    LCampos.Free;
  end;
end;

function TTEFClientArquivo.Transacionar(ADocFiscal: Integer; AValorTotal: Double;
  const ATipoTransacao, AParcelas: string): TTEFResposta;
var
  LReq: TTEFRequisicao;
  LParcelas, LFinanciamento: Integer;
begin
  ReiniciarQrCode;
  FCancelarEspera := False;
  FRequisicaoRetirada := False;

  LParcelas := StrToIntDef(Trim(AParcelas), 1);
  if LParcelas < 1 then LParcelas := 1;

  // Cartao/carteira e' SEMPRE CRT no intercambio por arquivo; o que separa
  // credito de debito e de PIX e' o 011-000. Mandar CDB/PIX no 000-000 (como
  // faz a API HTTP, que traduz antes de chegar aqui) faz o Tef_Dial descartar
  // o intpos.001 sem responder nada - o pinpad nem chega a ser acionado.
  FTipoSolicitado := LowerCase(Trim(ATipoTransacao));
  if FTipoSolicitado = 'debito' then
    LFinanciamento := FIN_DEBITO_AVISTA
  else if FTipoSolicitado = 'pix' then
    LFinanciamento := FIN_CARTEIRA_DIGITAL
  else if LParcelas > 1 then
    LFinanciamento := FIN_CREDITO_PARC_ADM
  else
    LFinanciamento := FIN_CREDITO_AVISTA;

  LReq := TTEFRequisicao.Create('CRT');
  try
    LReq.CampoInt(CP_IDENTIFICA, FIdentificacao);
    LReq.CampoInt(CP_DOCFISCAL, ADocFiscal);
    LReq.CampoInt(CP_VALOR, Round(AValorTotal * 100)); // centavos
    LReq.CampoInt(CP_MOEDA, 0);
    LReq.CampoInt(CP_TIPOTRANSAC, LFinanciamento);
    LReq.Campo(CP_PARCELAS, Format('%.2d', [LParcelas]));
    LReq.Campo(CP_DATA, FormatDateTime('ddmmyyyy', Now));
    LReq.Campo(CP_HORA, FormatDateTime('hhnnss', Now));

    Result := Executar(LReq, 'CRT', FTimeoutSeg, True);
  finally
    LReq.Free;
  end;

  Result.CanceladoOperador := FCancelarEspera;
  // Retirada sem resposta na carencia: o gerenciador nunca viu a venda. Nao
  // e' timeout - e' o cancelamento que o operador pediu.
  if Result.CanceladoOperador and FRequisicaoRetirada and (not Result.Sucesso) then
  begin
    Result.Status := 'CANCELADA';
    Result.Erro := 'Transacao cancelada pelo operador';
  end;
  FCancelarEspera := False;
  FRequisicaoRetirada := False;
end;

function TTEFClientArquivo.Confirmar(ADocFiscal: Integer; const AControle: string): TTEFResposta;
var
  LReq: TTEFRequisicao;
begin
  LReq := TTEFRequisicao.Create('CNF');
  try
    LReq.CampoInt(CP_IDENTIFICA, FIdentificacao);
    LReq.CampoInt(CP_DOCFISCAL, ADocFiscal);
    LReq.Campo(CP_CONTROLE, AControle);
    Result := Executar(LReq, 'CNF', 30, False);
  finally
    LReq.Free;
  end;
end;

function TTEFClientArquivo.Desfazer(ADocFiscal: Integer; const AControle: string): TTEFResposta;
var
  LReq: TTEFRequisicao;
begin
  LReq := TTEFRequisicao.Create('NCN');
  try
    LReq.CampoInt(CP_IDENTIFICA, FIdentificacao);
    LReq.CampoInt(CP_DOCFISCAL, ADocFiscal);
    LReq.Campo(CP_CONTROLE, AControle);
    Result := Executar(LReq, 'NCN', 30, False);
  finally
    LReq.Free;
  end;
end;

function TTEFClientArquivo.Cancelar(ADocFiscal: Integer; AValor: Double;
  const ANSU, AControle: string): TTEFResposta;
var
  LReq: TTEFRequisicao;
begin
  LReq := TTEFRequisicao.Create('CNC');
  try
    LReq.CampoInt(CP_IDENTIFICA, FIdentificacao);
    LReq.CampoInt(CP_DOCFISCAL, ADocFiscal);
    LReq.CampoInt(CP_VALOR, Round(AValor * 100));
    LReq.CampoInt(CP_MOEDA, 0);
    LReq.Campo(CP_NSU, ANSU);
    LReq.Campo(CP_CONTROLE, AControle);
    Result := Executar(LReq, 'CNC', FTimeoutSeg, True);
  finally
    LReq.Free;
  end;
end;

function TTEFClientArquivo.Administracao: TTEFResposta;
var
  LReq: TTEFRequisicao;
begin
  LReq := TTEFRequisicao.Create('ADM');
  try
    LReq.CampoInt(CP_IDENTIFICA, FIdentificacao);
    // Timeout proprio: o menu e navegado por uma pessoa, nao pelo pinpad
    Result := Executar(LReq, 'ADM', TIMEOUT_ADM_SEG, True);
  finally
    LReq.Free;
  end;
end;

// O gerenciador publica Ativo.001 / intpos.sts com 000-000 = ATV enquanto
// esta no ar. Se nenhum existir, manda um ATV e espera alguns segundos.
function TTEFClientArquivo.ConsultarStatus: Boolean;
var
  LTexto: string;
  LCampos: TTEFCampos;
  LReq: TTEFRequisicao;
  LResp: TTEFResposta;
begin
  Result := False;
  try
    ValidarPastas;

    LCampos := TTEFCampos.Create;
    try
      if (TFile.Exists(ArqAtivo) and LerSeCompleto(ArqAtivo, LTexto)) or
         (TFile.Exists(ArqSts) and LerSeCompleto(ArqSts, LTexto)) then
      begin
        LCampos.Carregar(LTexto);
        if SameText(LCampos.ValorCampo(CP_COMANDO), 'ATV') and
           (Trim(LCampos.Valor(CHAVE_TERMINADOR, '0')) = '0') then
          Exit(True);
      end;
    finally
      LCampos.Free;
    end;

    LReq := TTEFRequisicao.Create('ATV');
    try
      LReq.CampoInt(CP_IDENTIFICA, FIdentificacao);
      LResp := Executar(LReq, 'ATV', 10, True, True);
      Result := LResp.Sucesso;
    finally
      LReq.Free;
    end;
  except
    on E: Exception do
    begin
      Log('status arquivo indisponivel: %s', [E.Message]);
      Result := False;
    end;
  end;
end;

end.
