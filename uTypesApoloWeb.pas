unit uTypesApoloWeb;

interface

uses
  System.SysUtils, System.Variants;

// Funcoes utilitarias para converter Variant com valor padrao
function VarToFloatDef(const AValue: Variant; ADefault: Double): Double;
function VarToIntDef(const AValue: Variant; ADefault: Integer): Integer;

// Validacao de GTIN (EAN-8, EAN-13, EAN-14). Retorna o GTIN se valido, senao 'SEM GTIN'
function ValidarGTIN(const ACodBarra: string): string;

type
  // Tipo de conexao com o servidor
  TConexaoServidor = (conSoap, conBroker, conDireta);

  // Tipo de contingencia NFCe (corrigido - antes era apenas Boolean)
  TTipoContingencia = (
    tcNenhuma,   // Operacao normal
    tcOffLine,   // Contingencia offline (SEFAZ totalmente indisponivel)
    tcSVCAN,     // SVC-AN (Servico Virtual de Contingencia - Ambiente Nacional)
    tcSVCRS,     // SVC-RS (Servico Virtual de Contingencia - Rio Grande do Sul)
    tcSVCSP      // SVC-SP (Servico Virtual de Contingencia - Sao Paulo)
  );

  // Status de documento NFCe na contingencia
  TStatusContingencia = (
    scPendente,    // Aguardando envio
    scEnviado,     // Enviado ao SEFAZ
    scAutorizado,  // Autorizado pelo SEFAZ
    scRejeitado,   // Rejeitado pelo SEFAZ
    scCancelado    // Cancelado
  );

  // Estado do caixa
  TEstadoCaixa = (
    ecFechado,       // Caixa fechado
    ecLivre,         // Caixa aberto, sem venda
    ecRegistrando,   // Registrando itens
    ecPagamento      // Aguardando pagamento
  );

  // Tipo de numerario
  TTipoNumerario = (tnSangria, tnSuprimento);

  // Tipo de pagamento
  TTipoPagamento = (
    tpDinheiro,
    tpCheque,
    tpCartaoCredito,
    tpCartaoDebito,
    tpPOS,
    tpBoleta,
    tpCobranca,
    tpCredito,
    tpPix
  );

  // Parametros da filial carregados do Oracle (msfilial)
  TParametrosFilial = record
    CodFilial: string;
    RazaoSocial: string;
    Fantasia: string;
    CNPJ: string;
    IE: string;
    Endereco: string;
    Numero: string;
    Bairro: string;
    CEP: string;
    Cidade: string;
    CodCidade: string;
    UF: string;
    Fone: string;
    CSC: string;
    IDCSC: string;
    SenhaCertificado: string;
    AmbienteNFe: string;    // '1'=Producao, '2'=Homologacao
    UFWebService: string;
    CodConsumidor: Integer;
    CRT: Integer;            // Codigo Regime Tributario
    RegimeTributario: Integer;
  end;

  // Resultado generico de operacao
  TResultadoOperacao = record
    Sucesso: Boolean;
    Mensagem: string;
    Dados: string; // JSON com dados adicionais
  end;

  // Informacoes do item de venda
  TItemVenda = record
    NumSeqItem: Integer;
    CodProd: Int64;
    CodBarra: string;
    Descricao: string;
    Unidade: string;
    Embalagem: string;
    Quantidade: Double;
    PrecoUnit: Double;
    ValorTotal: Double;
    ValorDesconto: Double;
    ValorDescontoItem: Double;
    NCM: string;
    CFOP: string;
    CEST: string;
    ICMS_CST: string;
    CSOSN: string;
    AliqICMS: Double;
    PIS_CST: string;
    COFINS_CST: string;
    AliqPIS: Double;
    AliqCOFINS: Double;
    ValorPIS: Double;
    ValorCOFINS: Double;
    CodVendedor: Integer;
    EmOferta: Boolean;
    OrigemRegistro: string;
  end;

  // Informacoes do cupom/venda
  TCupomVenda = record
    CupomId: Integer;
    NumCupom: Integer;
    NumNota: Double;
    SerieNFCe: Integer;
    DataMovto: TDateTime;
    CodOperador: Integer;
    CodCliente: Integer;
    NomeCliente: string;
    CPF_CNPJ: string;
    QtdeItens: Integer;
    ValorVenda: Double;
    ValorDesconto: Double;
    ValorEncargo: Double;
    ValorTroco: Double;
    ChaveNFe: string;
    ProtocoloNFe: string;
    URLQrCode: string;
    Estado: TEstadoCaixa;
  end;

  // Helper para converter tipos
  TContingenciaHelper = record helper for TTipoContingencia
    function ToString: string;
    function ToACBrTpEmis: Integer;
  end;

  TEstadoCaixaHelper = record helper for TEstadoCaixa
    function ToString: string;
    function ToInteger: Integer;
    class function FromInteger(AValue: Integer): TEstadoCaixa; static;
  end;

implementation

function VarToFloatDef(const AValue: Variant; ADefault: Double): Double;
begin
  if VarIsNull(AValue) or VarIsEmpty(AValue) then
    Result := ADefault
  else
  try
    Result := AValue;
  except
    Result := ADefault;
  end;
end;

function VarToIntDef(const AValue: Variant; ADefault: Integer): Integer;
begin
  if VarIsNull(AValue) or VarIsEmpty(AValue) then
    Result := ADefault
  else
  try
    Result := AValue;
  except
    Result := ADefault;
  end;
end;

function ValidarGTIN(const ACodBarra: string): string;
var
  LCod: string;
  LLen, I, LSoma, LDigito, LDigCalc: Integer;
begin
  LCod := Trim(ACodBarra);

  // Vazio ou nao numerico -> SEM GTIN
  if LCod = '' then
    Exit('SEM GTIN');

  LLen := Length(LCod);

  // GTIN valido: 8, 12, 13 ou 14 digitos
  if not (LLen in [8, 12, 13, 14]) then
    Exit('SEM GTIN');

  // Verificar se todos sao digitos
  for I := 1 to LLen do
    if not CharInSet(LCod[I], ['0'..'9']) then
      Exit('SEM GTIN');

  // Calcular digito verificador (modulo 10)
  LSoma := 0;
  for I := 1 to LLen - 1 do
  begin
    LDigito := Ord(LCod[LLen - I]) - Ord('0');
    if Odd(I) then
      LSoma := LSoma + LDigito * 3
    else
      LSoma := LSoma + LDigito;
  end;

  LDigCalc := (10 - (LSoma mod 10)) mod 10;

  if LDigCalc = (Ord(LCod[LLen]) - Ord('0')) then
    Result := LCod
  else
    Result := 'SEM GTIN';
end;

{ TContingenciaHelper }

function TContingenciaHelper.ToString: string;
begin
  case Self of
    tcNenhuma: Result := 'NORMAL';
    tcOffLine: Result := 'OFFLINE';
    tcSVCAN:   Result := 'SVC_AN';
    tcSVCRS:   Result := 'SVC_RS';
    tcSVCSP:   Result := 'SVC_SP';
  end;
end;

function TContingenciaHelper.ToACBrTpEmis: Integer;
begin
  // Mapeamento para ACBr TpcnTipoEmissao
  // teNormal=0, teContingencia=1, teSCAN=2, teDPEC=3, teFSDA=4,
  // teSVCAN=6, teSVCRS=7, teSVCSP=8, teOffLine=9
  case Self of
    tcNenhuma: Result := 0;  // teNormal
    tcOffLine: Result := 9;  // teOffLine
    tcSVCAN:   Result := 6;  // teSVCAN
    tcSVCRS:   Result := 7;  // teSVCRS
    tcSVCSP:   Result := 8;  // teSVCSP
  else
    Result := 0;
  end;
end;

{ TEstadoCaixaHelper }

function TEstadoCaixaHelper.ToString: string;
begin
  case Self of
    ecFechado:     Result := 'FECHADO';
    ecLivre:       Result := 'LIVRE';
    ecRegistrando: Result := 'REGISTRANDO';
    ecPagamento:   Result := 'PAGAMENTO';
  else
    Result := 'DESCONHECIDO';
  end;
end;

function TEstadoCaixaHelper.ToInteger: Integer;
begin
  Result := Ord(Self);
end;

class function TEstadoCaixaHelper.FromInteger(AValue: Integer): TEstadoCaixa;
begin
  case AValue of
    0: Result := ecFechado;
    1: Result := ecLivre;
    2: Result := ecRegistrando;
    3: Result := ecPagamento;
  else
    Result := ecFechado;
  end;
end;

end.
