unit uConstantesWeb;

interface

const
  // Versao do sistema
  VERSAO_SISTEMA = '1.0.0';
  NOME_SISTEMA = 'ApoloWeb';

  // Pastas principais
  PASTA_RAIZ = 'C:\Apolo\';
  PASTA_WEB = 'C:\Apolo\web\';
  PASTA_XML = 'C:\Apolo\XML\';
  PASTA_NFCE = 'C:\Apolo\NFC-e\';
  PASTA_BKP = 'C:\Apolo\BKP\';
  PASTA_DFE = 'C:\Apolo\XML\DFE\';
  PASTA_SCHEMAS = 'C:\Apolo\Schemas\';

  // Banco SQLite
  ARQUIVO_SQLITE = 'C:\Apolo\ApoloWeb.db';

  // Configuracao XML/INI
  ARQ_CONFIG_XML = 'C:\Apolo\Apolo.xml';
  ARQ_CONFIG_INI = 'C:\Apolo\Apolo.ini';
  ARQ_APOLOWEB_INI = 'C:\Apolo\apoloweb.ini';  // conexao Oracle, TEF, impressao

  // Permissoes de acesso (codigos de controle)
  PA_REG_PRODUTO              = 01;
  PA_APLICAR_DESCONTO_ITEM    = 02;
  PA_APLICAR_DESCONTO_PGTO    = 03;
  PA_CANCELAR_ITEM            = 04;
  PA_CANCELAR_CUPOM           = 05;
  PA_FECHAMENTO_CAIXA         = 06;
  PA_CADASTROS_BASICOS        = 07;
  PA_PARAMETROS_GERAIS        = 08;
  PA_PAGAMENTOS_PRAZO         = 09;
  PA_ABRIR_GAVETA             = 10;
  PA_AUTORIZAR_CHEQUE         = 11;
  PA_VISUALIZAR_RESUMO        = 12;
  PA_CREDITO_TROCA_DEVOLUCAO  = 13;
  PA_FUNCOES_TEF              = 14;
  PA_REIMPRIMIR_CUPOM         = 15;
  PA_EMITIR_SUPRIMENTO        = 16;
  PA_CONSULTAR_PRODUTO        = 17;
  PA_EFETUAR_SANGRIA          = 18;
  PA_ALTERAR_PRECO            = 19;

  // Estados do caixa - DEVEM espelhar Ord(TEstadoCaixa) de uTypesApoloWeb
  // (ecFechado=0, ecLivre=1, ecRegistrando=2, ecPagamento=3), pois KEY_ESTADO
  // no SQLite e gravado com Ord(FEstadoCaixa) pelo uBridge.
  ESTADO_FECHADO     = 0;
  ESTADO_LIVRE       = 1;
  ESTADO_REGISTRANDO = 2;
  ESTADO_PAGAMENTO   = 3;

  // Impressao do cupom (DANFCe) - executaveis externos p/ modo PDF
  EXE_SUMATRA    = 'C:\Apolo\SumatraPDF.exe';
  EXE_PRINTCUPON = 'C:\Apolo\PrintCupon.exe';

  // Chaves do estado_caixa (SQLite)
  KEY_PRODUTOS_VERSAOREG = 'PRODUTOS_VERSAOREG'; // max(versaoreg) da ultima carga
  KEY_ULTIMA_SYNC_AUTO   = 'ULTIMA_SYNC_AUTO';   // quando a sync periodica rodou (retaguarda sem carimbo)
  KEY_TOTAL_DINHEIRO   = 'TOTAL_DINHEIRO';
  KEY_NUMCUPOM         = 'NUMCUPOM';
  KEY_NUMCAIXA         = 'NUMCAIXA';
  KEY_NUMSERIE         = 'NUMSERIE';
  KEY_ESTADO           = 'ESTADO';
  KEY_NUMSEQ_FECHAM    = 'NUMSEQ_FECHAMENTO';
  KEY_DT_FECHAMENTO    = 'DT_FECHAMENTO';
  KEY_STRING_FECHAM    = 'STRING_FECHAMENTO';
  KEY_PROX_NUM_NOTA    = 'PROX_NUM_NOTA';
  KEY_PROX_NUM_CUPOM   = 'PROX_NUM_CUPOM';
  KEY_SERIE_NFCE       = 'SERIE_NFCE';
  KEY_OPERADOR         = 'OPERADOR';
  KEY_MATRICULA        = 'MATRICULA';
  KEY_CODFILIAL        = 'CODFILIAL';
  KEY_HD_SERIAL        = 'HD_SERIAL';
  KEY_CODCONSUMIDOR    = 'CODCONSUMIDOR';

  // Arquivos gerados a partir de BLOBs do Oracle
  ARQUIVO_CERTIFICADO = 'C:\Apolo\certificado.pfx';
  ARQUIVO_LOGO        = 'C:\Apolo\logo_nfce.png';

  // TEF (ScopeAPI)
  KEY_TEF_HABILITADO = 'TEF_HABILITADO';
  KEY_TEF_URL        = 'TEF_URL';
  KEY_TEF_MODO       = 'TEF_MODO';
  TEF_URL_PADRAO     = 'https://dev-tefgpapi.tefbr.com.br';

  // TEF modo=arquivo: intercambio intpos com o gerenciador Tef_Dial/GetPay
  TEF_MODO_HTTP         = 'http';
  TEF_MODO_ARQUIVO      = 'arquivo';
  TEF_PASTA_REQ_PADRAO  = 'C:\Tef_Dial\Req\';
  TEF_PASTA_RESP_PADRAO = 'C:\Tef_Dial\Resp\';
  TEF_TIMEOUT_PADRAO    = 120;  // segundos aguardando a resposta do pinpad

  // TEF modo=clisitef: CliSiTef32I.dll chamada direto (SiTef / Fiserv)
  TEF_MODO_CLISITEF     = 'clisitef';
  TEF_SITEF_DLL_PADRAO  = 'C:\Apolo\clisitef\CliSiTef32I.dll';  // kit CliSiTef do PDV
  TEF_SITEF_IP_PADRAO   = 'tls-prod.fiservapp.com';  // SiTef da Fiserv em producao

  // TEF + PIX: onde o QR Code e' apresentado ao cliente
  //   pinpad = a adquirente desenha o QR no visor do pinpad (independe do PDV)
  //   tela   = o PDV exibe o BR Code devolvido pelo gerenciador
  TEF_PIX_QR_PINPAD = 'pinpad';
  TEF_PIX_QR_TELA   = 'tela';
  TEF_PIX_QR_PADRAO = TEF_PIX_QR_PINPAD;
  // 'auto' = acha o BR Code pelo formato ('000201...'), sem depender de qual
  // campo/chave o gerenciador usa. Aceita tambem uma lista fixa.
  TEF_PIX_QR_AUTO   = 'auto';

  // Intervalo do monitor de conexao (ms). 3 minutos porque cada verificacao
  // consulta o StatusServico do SEFAZ, e a NT trata consulta em intervalo
  // menor como consumo indevido (rejeicao 656). Nao precisa ser mais rapido:
  // quem detecta queda na hora e' a propria falha de envio da NFCe, que ja
  // entra em contingencia sozinha; o monitor cuida da VOLTA.
  INTERVALO_MONITOR_CONEXAO = 180000; // 3 minutos
  MAX_TENTATIVAS_CONTINGENCIA = 3;
  // Cache da resposta do StatusServico, em dias (para comparar com Now).
  // Fica abaixo do tick do monitor para que cada verificacao dele seja uma
  // consulta de verdade, e serve de piso caso alguem mais chame.
  INTERVALO_STATUS_SERVICO_SEFAZ = 150 / (24 * 60 * 60); // 150 segundos
  // Verificacoes de conexao que podem ser puladas seguidas por causa de venda
  // aberta antes de consultar assim mesmo (5 x 3 min = 15 min). Protege contra
  // venda esquecida na tela, que deixa o estado preso em REGISTRANDO.
  MAX_PROBES_PULADOS = 5;
  INTERVALO_RETRY_SYNC = 300000; // 5 minutos
  INTERVALO_SYNC_AUTO  = 60000;  // 1 minuto - verificacao automatica

// Localiza o XML da NFCe dentro de APasta (PASTA_NFCE + 'autorizadas\' ou
// 'contingencia\'). A chave passou a ser gravada com 44 digitos, mas os
// arquivos antigos foram salvos com o prefixo 'NFe' - tenta os dois nomes.
// Retorna '' se nenhum existir.
function CaminhoXmlNFCe(const APasta, AChave: string): string;

// Nome canonico (44 digitos) para gravar XMLs novos.
function NomeArqXmlNFCe(const APasta, AChave: string): string;

// Ultimo recurso: varre PASTA_NFCE inteira atras do XML da chave. O ACBr
// tambem grava por conta propria em NFC-e\XML\AAAAMM\NFCe\<chave>-nfe.xml,
// entao notas antigas existem em disco mesmo com autorizadas\ vazia.
function LocalizarXmlNFCe(const AChave: string): string;

// Versao do EXE em execucao, lida do VERSIONINFO gravado pelo build
// (FileVersion do .dproj, que o Delphi incrementa a cada compilacao).
// Cai em VERSAO_SISTEMA quando o executavel nao tem VERSIONINFO.
function VersaoExecutavel: string;

// NCM com 8 digitos, zeros a esquerda inclusive. Na retaguarda a coluna e'
// numerica em parte dos cadastros, entao a mesma NCM aparece como '04029900'
// e como '4029900' - sem normalizar, a regra de IBS/CBS do produto nao e'
// encontrada e o item sai sem o grupo. Texto que nao e' NCM volta como veio.
function NormalizarNCM(const ANcm: string): string;

implementation

uses
  Winapi.Windows, System.SysUtils, System.IOUtils, System.Types;

function NormalizarNCM(const ANcm: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(ANcm) do
    if CharInSet(ANcm[I], ['0'..'9']) then
      Result := Result + ANcm[I];

  if (Result = '') or (Length(Result) > 8) then
    Exit(Trim(ANcm));

  while Length(Result) < 8 do
    Result := '0' + Result;
end;

function ChaveSemPrefixo(const AChave: string): string;
begin
  Result := Trim(AChave);
  if (Length(Result) > 3) and SameText(Copy(Result, 1, 3), 'NFe') then
    Result := Copy(Result, 4, MaxInt);
end;

function NomeArqXmlNFCe(const APasta, AChave: string): string;
begin
  Result := IncludeTrailingPathDelimiter(APasta) + ChaveSemPrefixo(AChave) + '.xml';
end;

function CaminhoXmlNFCe(const APasta, AChave: string): string;
var
  LChave, LDir: string;
begin
  LChave := ChaveSemPrefixo(AChave);
  LDir := IncludeTrailingPathDelimiter(APasta);

  Result := LDir + LChave + '.xml';
  if FileExists(Result) then Exit;

  Result := LDir + 'NFe' + LChave + '.xml';
  if FileExists(Result) then Exit;

  // Nome usado pelo ACBr (PathNFe): <chave>-nfe.xml
  Result := LDir + LChave + '-nfe.xml';
  if FileExists(Result) then Exit;

  Result := '';
end;

function LocalizarXmlNFCe(const AChave: string): string;
var
  LChave: string;
  LArquivos: TStringDynArray;
begin
  Result := '';
  LChave := ChaveSemPrefixo(AChave);
  if LChave = '' then Exit;

  Result := CaminhoXmlNFCe(PASTA_NFCE + 'autorizadas\', LChave);
  if Result <> '' then Exit;

  if not DirectoryExists(PASTA_NFCE) then Exit;

  try
    LArquivos := TDirectory.GetFiles(PASTA_NFCE, '*' + LChave + '*.xml',
      TSearchOption.soAllDirectories);
    if Length(LArquivos) > 0 then
      Result := LArquivos[0];
  except
    Result := '';
  end;
end;

function VersaoExecutavel: string;
var
  LArq: string;
  LTam, LHandle: DWORD;
  LBuf: TBytes;
  LPtr: Pointer;
  LLen: UINT;
  LInfo: PVSFixedFileInfo;
begin
  Result := VERSAO_SISTEMA;
  try
    LArq := ParamStr(0);
    LHandle := 0;
    LTam := GetFileVersionInfoSize(PChar(LArq), LHandle);
    if LTam = 0 then Exit;

    SetLength(LBuf, LTam);
    if not GetFileVersionInfo(PChar(LArq), 0, LTam, Pointer(LBuf)) then Exit;
    if not VerQueryValue(Pointer(LBuf), '\', LPtr, LLen) then Exit;
    if LLen < SizeOf(TVSFixedFileInfo) then Exit;

    LInfo := PVSFixedFileInfo(LPtr);
    Result := Format('%d.%d.%d.%d', [
      HiWord(LInfo.dwFileVersionMS), LoWord(LInfo.dwFileVersionMS),
      HiWord(LInfo.dwFileVersionLS), LoWord(LInfo.dwFileVersionLS)]);
  except
    Result := VERSAO_SISTEMA;
  end;
end;

end.
