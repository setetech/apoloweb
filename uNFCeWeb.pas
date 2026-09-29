unit uNFCeWeb;

interface

uses
  System.SysUtils, System.Classes, System.DateUtils, System.JSON, System.Math,  Winapi.Windows,
  System.IniFiles, System.IOUtils,
  // ACBrDFe.Conversao vem ANTES de pcnConversaoNFe de proposito: as duas
  // declaram StrToCSTICMS/StrToCSOSNIcms com assinaturas diferentes, e o
  // codigo existente usa a forma (out ok, s) da pcnConversaoNFe, que precisa
  // ganhar a resolucao. De ACBrDFe.Conversao so se usa TCSTIBSCBS, qualificado.
  ACBrBase, ACBrDFe, ACBrDFe.Conversao,
  ACBrNFe, ACBrNFeNotasFiscais, pcnConversao,pcnConversaoNFe,uTypesApoloWeb,
  Uni,uConstantesWeb, uContingencia,Data.db,  uSQLiteDB, Winapi.ShellAPI, uSyncLog;

type
  // Reducao de aliquota de um dos tributos (gRed do XML). pAliqEfet e' a
  // aliquota que sobra depois da reducao e e' ela que calcula o valor;
  // zerado nos dois campos = a regra nao reduz nada.
  TReducaoIBSCBS = record
    pRedAliq: Double;
    pAliqEfet: Double;
    function TemReducao: Boolean;
  end;

  // Regra de IBS/CBS aplicada a um item, ja resolvida (cadastro da retaguarda
  // ou fallback do ini)
  TRegraIBSCBS = record
    Habilitado: Boolean;
    Cst: string;
    ClassTrib: string;
    pIBSUF: Double;
    pIBSMun: Double;
    pCBS: Double;
    RedIBSUF: TReducaoIBSCBS;
    RedIBSMun: TReducaoIBSCBS;
    RedCBS: TReducaoIBSCBS;
    // CST de aliquota reduzida sem gRed = rejeicao "Nao informado o grupo de
    // reducao de aliquota Estadual"
    function ExigeReducao: Boolean;
  end;

  TNFCeWebManager = class
  private
    FSQLite: TSQLiteDB;
    FACBrNFe: TACBrNFe;
    FContingencia: TContingenciaManager;

    // Dados da empresa (carregados do SQLite)
    FCNPJ: string;
    FIE: string;
    FRazaoSocial: string;
    FFantasia: string;
    FEndereco: string;
    FNumero: string;
    FBairro: string;
    FCidade: string;
    FUF: string;
    FCEP: string;
    FCodCidadeIBGE: string;
    FRegimeTributario: Integer;
    FFone: string;

    // Reforma tributaria (IBS/CBS). A regra vem do cadastro da retaguarda
    // (msncm_ibs_cbs + ms_trib_ibs_cbs, espelhados em trib_ibs_cbs), resolvida
    // por item. O [ibscbs] do apoloweb.ini so entra se nao houver cadastro.
    FIBSCBSTemCadastro: Boolean;
    FIBSCBSIni: TRegraIBSCBS;
    FIBSCBSAvisouSemRegra: Boolean;
    FIBSCBSAvisouSemReducao: Boolean;
    // Acumuladores do documento, montados em PreencherItens
    FTotIBSCBSvBC: Double;
    FTotvIBSUF: Double;
    FTotvIBSMun: Double;
    FTotvCBS: Double;

    // Ultima consulta ao StatusServico. A NT do SEFAZ trata consulta em
    // intervalo menor que 3 minutos como consumo indevido (rejeicao 656),
    // entao a resposta fica em cache ate o intervalo vencer.
    FStatusUltimaConsulta: TDateTime;
    FStatusUltimoResultado: Boolean;

    procedure CarregarConfigIBSCBS;
    function ResolverIBSCBS(ACodProd: Int64; const ANcm: string;
      out ARegra: TRegraIBSCBS): Boolean;
    procedure PreencherIBSCBSItem(AIndice: Integer; ACodProd: Int64;
      const ANcm: string; ABase: Double);
    procedure CarregarDadosEmpresa;
    procedure PreencherIdentificacao(ACupomId: Integer);
    procedure PreencherEmitente;
    procedure PreencherDestinatario(ACupomId: Integer);
    procedure PreencherItens(ACupomId: Integer;
      var ATotVProd, ATotVDesc, ATotVOutro, ATotVBC, ATotVICMS, ATotVPIS,
      ATotVCOFINS: Double);
    procedure PreencherTotais(
      ATotVProd, ATotVDesc, ATotVOutro, ATotVBC, ATotVICMS, ATotVPIS,
      ATotVCOFINS: Double);
    procedure PreencherPagamentos(ACupomId: Integer);
    procedure PreencherInfoAdicionais(ACupomId: Integer;
      ATotImpLei: Double);

    // Impressao parametrizada ([impressao] do apoloweb.ini):
    // ESCPOS = direto na termica via ACBr; SUMATRA = PDF + app externo
    procedure ImprimirNotaCarregada;
    procedure ImprimirPDFExterno(const AArqPDF: string);

    function CarregarXmlDoc(ADocId: Integer; out ACupomId: Integer;
      out AChaveNFe, AErro: string): Boolean;
    function ResolverDuplicidade(ADocId, ACupomId: Integer;
      const AChaveNFe: string; var AResult: TResultadoOperacao): Boolean;
  public
    constructor Create(ASQLite: TSQLiteDB; AACBrNFe: TACBrNFe;
      AContingencia: TContingenciaManager);
    destructor Destroy; override;

    /// Gerar XML da NFCe a partir do cupom
    function GerarXMLNFCe(ACupomId: Integer): string;

    /// Assinar e enviar NFCe
    function EnviarNFCe(ACupomId: Integer): TResultadoOperacao;

    /// Retransmite ao SEFAZ um documento ja gerado e guardado em
    /// nfce_contingencia (ADocId = nfce_contingencia.id, NAO e cupom_id).
    /// Reenvia o XML original assinado - nao regera a nota.
    function RetransmitirDoc(ADocId: Integer): TResultadoOperacao;

    /// Monta a NFCe DE NOVO a partir do cupom e transmite, mantendo o mesmo
    /// numero e ganhando cNF/chave novos (ADocId = nfce_contingencia.id).
    /// So para documento REJEITADO cujo XML saiu com conteudo errado -
    /// retransmitir o mesmo XML nesses casos repete a rejeicao para sempre.
    function RegerarDoc(ADocId: Integer): TResultadoOperacao;

    /// Cancela no SEFAZ a NFCe do cupom (evento 110111). Exige nota ja
    /// autorizada (chavenfe + protocolo_nfe gravados) e justificativa de 15 a
    /// 255 caracteres. Grava o procEventoNFe em NFC-e\canceladas\ e nas
    /// colunas de cancelamento do cupom. NAO mexe no TEF nem no Oracle - disso
    /// cuida o TApoloBridge.DoCancelarNFCe.
    function CancelarNFCe(ACupomId: Integer;
      const AJustificativa: string): TResultadoOperacao;

    /// Reimprimir DANFCe
    procedure ImprimirDANFCe(const AChaveNFe: string);

    /// Pergunta ao webservice de NFCe da UF se o servico esta no ar
    /// (cStat 107). E' a unica prova de que da' para emitir online - ping em
    /// portal ou em servidor de banco nao diz nada sobre isso.
    /// A resposta fica em cache por INTERVALO_STATUS_SERVICO_SEFAZ.
    function SefazDisponivel: Boolean;

    property Contingencia: TContingenciaManager read FContingencia;
  end;

implementation

uses
  System.Win.Registry, System.Variants, uDmApoloWeb;

{ Distingue rejeicao definitiva do SEFAZ (nao adianta reenviar o mesmo XML)
  de falha transitoria (rede, timeout, servico fora do ar - reenviar resolve). }
function ErroPermanenteSefaz(const AMsg: string): Boolean;
const
  MARCAS: array[0..4] of string = (
    'Rejeicao',           // resposta do SEFAZ (ACBr sem acentos)
    'Rejeição',           // idem, com acento
    'Ambiente do XML',    // tpAmb do XML <> ambiente configurado
    'CNPJ do Documento',  // CNPJ do XML <> CNPJ do certificado
    'Duplicidade'         // nota ja autorizada com essa chave
  );
var
  LMsg: string;
  I: Integer;
begin
  Result := False;
  LMsg := UpperCase(AMsg);
  for I := Low(MARCAS) to High(MARCAS) do
    if Pos(UpperCase(MARCAS[I]), LMsg) > 0 then
      Exit(True);
end;

Function SomenteNumeroInteiro(Const Texto:String):String;
Var i:Integer;
begin {Retira todos caracteres que n�o sejam num�ricos Inteiro}
  Result:='';
  For i:=1 To Length(Texto) do
    If CharInSet(Texto[i], ['0'..'9']) Then
      Result:=Result+Texto[i];
end;


{ TReducaoIBSCBS }

function TReducaoIBSCBS.TemReducao: Boolean;
begin
  // Mesmo criterio do ACBr para gerar o gRed no XML
  Result := (pRedAliq > 0) or (pAliqEfet > 0);
end;

{ TRegraIBSCBS }

function TRegraIBSCBS.ExigeReducao: Boolean;
begin
  // CSTs de aliquota reduzida da NT da reforma tributaria. Sem o gRed a SEFAZ
  // devolve "Nao informado o grupo de reducao de aliquota Estadual".
  Result := (Cst = '200') or (Cst = '220') or (Cst = '221') or (Cst = '222');
end;

{ TNFCeWebManager }

constructor TNFCeWebManager.Create(ASQLite: TSQLiteDB; AACBrNFe: TACBrNFe;
  AContingencia: TContingenciaManager);
begin
  inherited Create;
  FSQLite := ASQLite;
  FACBrNFe := AACBrNFe;
  FContingencia := AContingencia;
  FStatusUltimaConsulta := 0;
  FStatusUltimoResultado := False;
  CarregarDadosEmpresa;
  CarregarConfigIBSCBS;
end;

{ Consulta o StatusServico do webservice de NFCe da UF.

  Era o buraco do monitor de conexao: ele decidia "caixa offline" com um HEAD
  na pagina de disponibilidade do portal nacional, que nada tem a ver com o
  webservice que o caixa usa para emitir. Aqui a pergunta e' feita a quem sabe
  responder - com o certificado, no ambiente configurado.

  cStat 107 = servico em operacao. Qualquer outra coisa (ou excecao) conta
  como indisponivel. Cache de INTERVALO_STATUS_SERVICO_SEFAZ porque consulta
  em intervalo menor e' consumo indevido (rejeicao 656). }
function TNFCeWebManager.SefazDisponivel: Boolean;
begin
  if (FStatusUltimaConsulta > 0) and
     (Now - FStatusUltimaConsulta < INTERVALO_STATUS_SERVICO_SEFAZ) then
    Exit(FStatusUltimoResultado);

  FStatusUltimaConsulta := Now;
  FStatusUltimoResultado := False;
  try
    FACBrNFe.WebServices.StatusServico.Executar;
    FStatusUltimoResultado := FACBrNFe.WebServices.StatusServico.cStat = 107;
    if not FStatusUltimoResultado then
      SyncLog('SEFAZ: StatusServico cStat=%d - %s',
        [FACBrNFe.WebServices.StatusServico.cStat,
         FACBrNFe.WebServices.StatusServico.xMotivo]);
  except
    on E: Exception do
      SyncLog('SEFAZ: StatusServico falhou - [%s] %s', [E.ClassName, E.Message]);
  end;
  Result := FStatusUltimoResultado;
end;

{ A fonte da tributacao IBS/CBS e' o cadastro da retaguarda, espelhado em
  trib_ibs_cbs pela carga. O [ibscbs] do apoloweb.ini so vale quando a tabela
  local esta vazia - retaguarda antiga, sem o cadastro - para o caixa nao
  parar de emitir. Havendo cadastro, ele manda: um item sem regra fica sem o
  grupo IBS/CBS e o log diz qual produto/NCM ficou de fora. }
procedure TNFCeWebManager.CarregarConfigIBSCBS;
var
  LIni: TIniFile;
  LArq: string;

  // Aliquota e' valor fiscal: aceitar tanto '0.90' quanto '0,90' evita que um
  // separador decimal diferente do esperado vire silenciosamente o default
  function LerAliquota(const AChave: string; ADefault: Double): Double;
  var
    LTexto: string;
    LFmt: TFormatSettings;
  begin
    LTexto := Trim(LIni.ReadString('ibscbs', AChave, ''));
    if LTexto = '' then Exit(ADefault);

    LFmt := TFormatSettings.Invariant;
    LTexto := StringReplace(LTexto, ',', '.', [rfReplaceAll]);
    Result := StrToFloatDef(LTexto, ADefault, LFmt);
  end;

var
  LQtd: Variant;
begin
  FIBSCBSAvisouSemRegra := False;
  FIBSCBSAvisouSemReducao := False;
  FIBSCBSIni := Default(TRegraIBSCBS);
  FIBSCBSIni.Habilitado := True;
  FIBSCBSIni.Cst := '000';        // tributacao integral
  FIBSCBSIni.ClassTrib := '000001';
  FIBSCBSIni.pIBSUF := 0.1;
  FIBSCBSIni.pIBSMun := 0;
  FIBSCBSIni.pCBS := 0.9;

  LQtd := Null;
  try
    LQtd := FSQLite.ExecutarScalar('SELECT COUNT(*) FROM trib_ibs_cbs');
  except
    // tabela ainda nao criada (banco de versao anterior)
  end;
  FIBSCBSTemCadastro := (not VarIsNull(LQtd)) and (Integer(LQtd) > 0);

  if FIBSCBSTemCadastro then
  begin
    SyncLog('IBSCBS: usando o cadastro da retaguarda (%d regra(s) em trib_ibs_cbs)',
      [Integer(LQtd)]);
    Exit;
  end;

  LArq := 'C:\Apolo\apoloweb.ini';
  if not FileExists(LArq) then Exit;

  LIni := TIniFile.Create(LArq);
  try
    FIBSCBSIni.Habilitado := LIni.ReadInteger('ibscbs', 'habilitado', 1) = 1;
    FIBSCBSIni.Cst       := Trim(LIni.ReadString('ibscbs', 'cst', FIBSCBSIni.Cst));
    FIBSCBSIni.ClassTrib := Trim(LIni.ReadString('ibscbs', 'cclasstrib', FIBSCBSIni.ClassTrib));
    FIBSCBSIni.pIBSUF    := LerAliquota('pibsuf', FIBSCBSIni.pIBSUF);
    FIBSCBSIni.pIBSMun   := LerAliquota('pibsmun', FIBSCBSIni.pIBSMun);
    FIBSCBSIni.pCBS      := LerAliquota('pcbs', FIBSCBSIni.pCBS);

    // gRed do fallback: so faz sentido com cClassTrib de aliquota reduzida
    FIBSCBSIni.RedIBSUF.pRedAliq   := LerAliquota('ibsuf_predaliq', 0);
    FIBSCBSIni.RedIBSUF.pAliqEfet  := LerAliquota('ibsuf_paliqefet', 0);
    FIBSCBSIni.RedIBSMun.pRedAliq  := LerAliquota('ibsmun_predaliq', 0);
    FIBSCBSIni.RedIBSMun.pAliqEfet := LerAliquota('ibsmun_paliqefet', 0);
    FIBSCBSIni.RedCBS.pRedAliq     := LerAliquota('cbs_predaliq', 0);
    FIBSCBSIni.RedCBS.pAliqEfet    := LerAliquota('cbs_paliqefet', 0);
  finally
    LIni.Free;
  end;

  SyncLog('IBSCBS: sem cadastro na retaguarda, usando [ibscbs] do ini - ' +
    'habilitado=%s CST=%s cClassTrib=%s pIBSUF=%s pIBSMun=%s pCBS=%s',
    [BoolToStr(FIBSCBSIni.Habilitado, True), FIBSCBSIni.Cst, FIBSCBSIni.ClassTrib,
     FormatFloat('0.0000', FIBSCBSIni.pIBSUF), FormatFloat('0.0000', FIBSCBSIni.pIBSMun),
     FormatFloat('0.0000', FIBSCBSIni.pCBS)]);
end;

{ Escolhe a regra de IBS/CBS do item, do mais especifico para o mais generico:
    1. linha do codprod
    2. linha do ncm (sem codprod)
    3. linha com codprod e ncm nulos - vale para todos os produtos
  Retorna False quando nao ha nenhuma regra aplicavel. }
function TNFCeWebManager.ResolverIBSCBS(ACodProd: Int64; const ANcm: string;
  out ARegra: TRegraIBSCBS): Boolean;
var
  LQuery: TUniQuery;
begin
  Result := False;
  ARegra := Default(TRegraIBSCBS);

  if not FIBSCBSTemCadastro then
  begin
    // Sem cadastro: cai no que veio do ini
    ARegra := FIBSCBSIni;
    Exit(True);
  end;

  // ORDER BY coloca primeiro a regra do produto, depois a do NCM, depois a
  // geral - um unico SELECT resolve a precedencia
  LQuery := FSQLite.ExecutarSelect(
    'SELECT habilitado, cst, cclasstrib, pibsuf, pibsmun, pcbs, ' +
    '       ibsuf_predaliq, ibsuf_paliqefet, ' +
    '       ibsmun_predaliq, ibsmun_paliqefet, ' +
    '       cbs_predaliq, cbs_paliqefet, ' +
    '       CASE WHEN codprod IS NOT NULL THEN 1 ' +
    '            WHEN ncm IS NOT NULL THEN 2 ' +
    '            ELSE 3 END AS prioridade ' +
    '  FROM trib_ibs_cbs ' +
    ' WHERE (codprod = ' + IntToStr(ACodProd) + ') ' +
    '    OR (codprod IS NULL AND ncm = ' + QuotedStr(NormalizarNCM(ANcm)) + ') ' +
    '    OR (codprod IS NULL AND ncm IS NULL) ' +
    // O id desempata NCM com mais de uma regra no cadastro (acontece): sem
    // ele o SQLite escolhe qualquer uma e a mesma venda muda de tributacao
    ' ORDER BY prioridade, id LIMIT 1'
  );
  try
    if LQuery.IsEmpty then Exit;

    ARegra.Habilitado := LQuery.FieldByName('habilitado').AsInteger = 1;
    ARegra.Cst        := Trim(LQuery.FieldByName('cst').AsString);
    ARegra.ClassTrib  := Trim(LQuery.FieldByName('cclasstrib').AsString);
    ARegra.pIBSUF     := LQuery.FieldByName('pibsuf').AsFloat;
    ARegra.pIBSMun    := LQuery.FieldByName('pibsmun').AsFloat;
    ARegra.pCBS       := LQuery.FieldByName('pcbs').AsFloat;

    ARegra.RedIBSUF.pRedAliq   := LQuery.FieldByName('ibsuf_predaliq').AsFloat;
    ARegra.RedIBSUF.pAliqEfet  := LQuery.FieldByName('ibsuf_paliqefet').AsFloat;
    ARegra.RedIBSMun.pRedAliq  := LQuery.FieldByName('ibsmun_predaliq').AsFloat;
    ARegra.RedIBSMun.pAliqEfet := LQuery.FieldByName('ibsmun_paliqefet').AsFloat;
    ARegra.RedCBS.pRedAliq     := LQuery.FieldByName('cbs_predaliq').AsFloat;
    ARegra.RedCBS.pAliqEfet    := LQuery.FieldByName('cbs_paliqefet').AsFloat;

    Result := True;
  finally
    LQuery.Free;
  end;
end;

{ Grupo IBSCBS do item (NT da reforma tributaria). Sem ele o SEFAZ rejeita com
  "IBS/CBS nao informado". ABase e' o valor liquido do item (vProd - vDesc);
  o ACBr exige vIBS/vCBS coerentes com base x aliquota, senao rejeita de novo. }
procedure TNFCeWebManager.PreencherIBSCBSItem(AIndice: Integer; ACodProd: Int64;
  const ANcm: string; ABase: Double);
var
  LvIBSUF, LvIBSMun, LvCBS: Double;
  LEfetUF, LEfetMun, LEfetCBS: Double;
  LCstIBS: TCSTIBSCBS;
  LRegra: TRegraIBSCBS;

  // Aliquota que vale para o valor do tributo. Com pAliqEfet cadastrada, e'
  // ela (regra da retaguarda, Bloco_Calcular_IBS_CBS em uTributacaoNFe.pas);
  // com so o pRedAliq preenchido - o caso do cadastro do ORDOTY, que grava
  // reducao de 100% e deixa a efetiva vazia - deriva do percentual reduzido,
  // senao o XML sairia dizendo "reduzi 100%" e cobrando a aliquota cheia.
  function AliquotaEfetiva(APCheia: Double; const ARed: TReducaoIBSCBS): Double;
  begin
    if ARed.pAliqEfet > 0 then
      Result := ARed.pAliqEfet
    else if ARed.pRedAliq > 0 then
      Result := RoundTo(APCheia * (1 - ARed.pRedAliq / 100), -4)
    else
      Result := APCheia;
  end;

begin
  if not ResolverIBSCBS(ACodProd, ANcm, LRegra) then
  begin
    // Item sem regra e' furo de cadastro, nao situacao normal: sem o grupo a
    // SEFAZ rejeita a nota inteira, entao registra qual produto ficou de fora
    if not FIBSCBSAvisouSemRegra then
    begin
      FIBSCBSAvisouSemRegra := True;
      SyncLog('IBSCBS: sem regra para codprod=%d ncm=%s - item sai sem o grupo ' +
        '(aviso unico por nota). Conferir msncm_ibs_cbs da filial.',
        [ACodProd, ANcm]);
    end;
    Exit;
  end;

  if not LRegra.Habilitado then Exit;
  if LRegra.ClassTrib = '' then Exit;

  if not ACBrDFe.Conversao.TryStrToCSTIBSCBS(LRegra.Cst, LCstIBS) then Exit;
  if LCstIBS = cstNenhum then Exit;

  // CST de aliquota reduzida sem pRedAliq/pAliqEfet no cadastro sai sem o
  // gRed e o SEFAZ rejeita a nota inteira - furo de cadastro, nao de codigo
  if LRegra.ExigeReducao and
     not (LRegra.RedIBSUF.TemReducao or LRegra.RedIBSMun.TemReducao or
          LRegra.RedCBS.TemReducao) then
  begin
    if not FIBSCBSAvisouSemReducao then
    begin
      FIBSCBSAvisouSemReducao := True;
      SyncLog('IBSCBS: CST %s (cClassTrib %s) exige o grupo de reducao mas o ' +
        'cadastro nao tem pRedAliq/pAliqEfet - codprod=%d ncm=%s. Preencher ' +
        'IBSUF_PREDALIQ/IBSUF_PALIQEFET (e CBS_*) em ms_trib_ibs_cbs.',
        [LRegra.Cst, LRegra.ClassTrib, ACodProd, ANcm]);
    end;
  end;

  LEfetUF  := AliquotaEfetiva(LRegra.pIBSUF,  LRegra.RedIBSUF);
  LEfetMun := AliquotaEfetiva(LRegra.pIBSMun, LRegra.RedIBSMun);
  LEfetCBS := AliquotaEfetiva(LRegra.pCBS,    LRegra.RedCBS);

  LvIBSUF  := RoundTo(ABase * LEfetUF  / 100, -2);
  LvIBSMun := RoundTo(ABase * LEfetMun / 100, -2);
  LvCBS    := RoundTo(ABase * LEfetCBS / 100, -2);

  with FACBrNFe.NotasFiscais.Items[0].NFe.Det[AIndice].Imposto.IBSCBS do
  begin
    CST := LCstIBS;
    cClassTrib := LRegra.ClassTrib;

    gIBSCBS.vBC := ABase;

    // pIBSUF/pIBSMun/pCBS continuam sendo a aliquota cheia: o gRed e' que diz
    // quanto dela foi reduzida e qual sobrou (o ACBr so gera o grupo quando
    // um dos dois percentuais e' maior que zero)
    gIBSCBS.gIBSUF.pIBSUF := LRegra.pIBSUF;
    if LRegra.RedIBSUF.TemReducao then
    begin
      gIBSCBS.gIBSUF.gRed.pRedAliq := LRegra.RedIBSUF.pRedAliq;
      gIBSCBS.gIBSUF.gRed.pAliqEfet := LEfetUF;
    end;
    gIBSCBS.gIBSUF.vIBSUF := LvIBSUF;

    gIBSCBS.gIBSMun.pIBSMun := LRegra.pIBSMun;
    if LRegra.RedIBSMun.TemReducao then
    begin
      gIBSCBS.gIBSMun.gRed.pRedAliq := LRegra.RedIBSMun.pRedAliq;
      gIBSCBS.gIBSMun.gRed.pAliqEfet := LEfetMun;
    end;
    gIBSCBS.gIBSMun.vIBSMun := LvIBSMun;

    gIBSCBS.vIBS := LvIBSUF + LvIBSMun;

    gIBSCBS.gCBS.pCBS := LRegra.pCBS;
    if LRegra.RedCBS.TemReducao then
    begin
      gIBSCBS.gCBS.gRed.pRedAliq := LRegra.RedCBS.pRedAliq;
      gIBSCBS.gCBS.gRed.pAliqEfet := LEfetCBS;
    end;
    gIBSCBS.gCBS.vCBS := LvCBS;
  end;

  FTotIBSCBSvBC := FTotIBSCBSvBC + ABase;
  FTotvIBSUF    := FTotvIBSUF + LvIBSUF;
  FTotvIBSMun   := FTotvIBSMun + LvIBSMun;
  FTotvCBS      := FTotvCBS + LvCBS;
end;

destructor TNFCeWebManager.Destroy;
begin
  inherited;
end;

procedure TNFCeWebManager.CarregarDadosEmpresa;
var
  LQuery: TUniQuery;
begin
  LQuery := FSQLite.ExecutarSelect('SELECT * FROM empresa WHERE id = 1');
  try
    if not LQuery.IsEmpty then
    begin
      FCNPJ := LQuery.FieldByName('cnpj').AsString;
      FIE := LQuery.FieldByName('ie').AsString;
      FRazaoSocial := LQuery.FieldByName('razao_social').AsString;
      FFantasia := LQuery.FieldByName('fantasia').AsString;
      FEndereco := LQuery.FieldByName('endereco').AsString;
      FNumero := LQuery.FieldByName('numero').AsString;
      FBairro := LQuery.FieldByName('bairro').AsString;
      FCidade := LQuery.FieldByName('cidade').AsString;
      FUF := LQuery.FieldByName('uf').AsString;
      FCEP := LQuery.FieldByName('cep').AsString;
      FCodCidadeIBGE := LQuery.FieldByName('cod_cidade_ibge').AsString;
      FRegimeTributario := LQuery.FieldByName('regime_tributario').AsInteger;
      FFone := LQuery.FieldByName('fone').AsString;
    end;
  finally
    LQuery.Free;
  end;
end;

function TNFCeWebManager.GerarXMLNFCe(ACupomId: Integer): string;
var
  LTotVProd, LTotVDesc, LTotVOutro, LTotVBC, LTotVICMS, LTotVPIS,
  LTotVCOFINS: Double;
begin
  Result := '';
  LTotVProd := 0; LTotVDesc := 0; LTotVOutro := 0; LTotVBC := 0;
  LTotVICMS := 0; LTotVPIS := 0; LTotVCOFINS := 0;

  FACBrNFe.NotasFiscais.Clear;
  FACBrNFe.NotasFiscais.Add;

  // Reler a cada nota: a carga do Oracle pode ter populado trib_ibs_cbs
  // depois do Create, e ai a nota ja tem que sair com a regra da retaguarda
  CarregarConfigIBSCBS;

  try
    PreencherIdentificacao(ACupomId);
    PreencherEmitente;
    PreencherDestinatario(ACupomId);
    PreencherItens(ACupomId, LTotVProd, LTotVDesc, LTotVOutro, LTotVBC,
      LTotVICMS, LTotVPIS, LTotVCOFINS);
    PreencherTotais(LTotVProd, LTotVDesc, LTotVOutro, LTotVBC,
      LTotVICMS, LTotVPIS, LTotVCOFINS);

    // NFC-e nao permite frete
    FACBrNFe.NotasFiscais.Items[0].NFe.Transp.modFrete := mfSemFrete;

    PreencherPagamentos(ACupomId);
    PreencherInfoAdicionais(ACupomId, 0);

    // Gerar XML
    FACBrNFe.NotasFiscais.GerarNFe;
    Result := FACBrNFe.NotasFiscais.Items[0].XMLOriginal;
  except
    on E: Exception do
      raise Exception.Create('Erro ao gerar XML NFCe: ' + E.Message);
  end;
end;

function TNFCeWebManager.EnviarNFCe(ACupomId: Integer): TResultadoOperacao;
var
  LXml, LChaveNFe, LProtocolo: string;
  LNumNota: Integer;
  LDocId: Integer;
begin
  Result.Sucesso := False;
  Result.Mensagem := '';

  // CSC/IdCSC sao obrigatorios no QR-Code da NFC-e; sem eles a SEFAZ rejeita
  if (Trim(FACBrNFe.Configuracoes.Geral.CSC) = '') or
     (Trim(FACBrNFe.Configuracoes.Geral.IdCSC) = '') then
  begin
    if FACBrNFe.Configuracoes.WebServices.Ambiente = taHomologacao then
      Result.Mensagem := 'CSC/IdCSC nao configurados para a filial. Gere o ' +
        'CSC de HOMOLOGACAO no portal da SEFAZ e grave em msfilial.csc e msfilial.idcsc.'
    else
      Result.Mensagem := 'CSC/IdCSC nao configurados para a filial. Gere o ' +
        'CSC de PRODUCAO no portal da SEFAZ e grave em msfilial.csc e msfilial.idcsc.';
    Exit;
  end;

  try
    // 1. Gerar XML
    LXml := GerarXMLNFCe(ACupomId);
    if LXml = '' then
    begin
      Result.Mensagem := 'Falha ao gerar XML da NFCe';
      Exit;
    end;

    // 2. Assinar
    if FileExists(FACBrNFe.Configuracoes.Certificados.ArquivoPFX) then
    begin
      try
        FACBrNFe.NotasFiscais.Assinar;
      except
        on E: Exception do
        begin
          Result.Mensagem := 'Erro ao assinar NFCe: ' + E.Message;
          Exit;
        end;
      end;
    end
    else
    begin
      Result.Mensagem := 'Certificado digital nao encontrado';
      Exit;
    end;

    // 2.1 Validar schema localmente antes de enviar
    try
      FACBrNFe.NotasFiscais.Validar;
    except
      on E: Exception do
      begin
        Result.Mensagem := 'Falha na validacao do schema: ' + E.Message;
        Exit;
      end;
    end;

    // infNFe.ID vem como 'NFe' + 44 digitos; retaguarda e SEFAZ usam so os 44
    LChaveNFe := SomenteNumeroInteiro(FACBrNFe.NotasFiscais.Items[0].NFe.infNFe.ID);
    LNumNota := FACBrNFe.NotasFiscais.Items[0].NFe.Ide.nNF;

    // 3. Verificar se estamos em contingencia
    if FContingencia.EstaEmContingencia then
    begin
      // Salvar localmente para envio posterior
      LDocId := FContingencia.RegistrarDocContingencia(
        ACupomId, LChaveNFe, LNumNota,
        NomeArqXmlNFCe(PASTA_NFCE + 'contingencia\', LChaveNFe),
        LXml
      );

      // Gravar chave no cupom mesmo em contingencia: sem isso a venda sobe
      // para a retaguarda sem chavenfe e o XML nunca e vinculado
      FSQLite.ExecutarSQL(
        'UPDATE cupons SET chavenfe = :p0 WHERE id = :p1',
        [LChaveNFe, ACupomId]
      );

      // Salvar arquivo XML
      ForceDirectories(PASTA_NFCE + 'contingencia\');
      FACBrNFe.NotasFiscais.Items[0].GravarXML(
        NomeArqXmlNFCe(PASTA_NFCE + 'contingencia\', LChaveNFe)
      );

      Result.Sucesso := True;
      Result.Mensagem := 'NFCe salva em contingencia (Doc #' + IntToStr(LDocId) + ')';
      Result.Dados := '{"chaveNFe":"' + LChaveNFe + '","contingencia":true}';

      // Imprimir o DANFCe de contingencia ANTES do Exit: este Exit pulava o
      // passo 5 e, com o caixa em contingencia, NENHUM cupom saia na
      // impressora - o cliente ia embora sem documento justamente no cenario
      // em que o papel e a unica prova da venda.
      try
        ImprimirNotaCarregada;
      except
        on E: Exception do
          SyncLog('NFCe: falha na impressao do DANFCe (contingencia): [%s] %s',
            [E.ClassName, E.Message]);
      end;
      Exit;
    end;

    // 4. Enviar ao SEFAZ (modo normal)
    try
      FACBrNFe.Enviar(1, False, True); // Lote=1, Imprimir=False, Sincrono=True

      if FACBrNFe.NotasFiscais.Items[0].Confirmada then
      begin
        LProtocolo := FACBrNFe.NotasFiscais.Items[0].NFe.procNFe.nProt;

        // Atualizar cupom com protocolo
        FSQLite.ExecutarSQL(
          'UPDATE cupons SET chavenfe = :p0, protocolo_nfe = :p1 WHERE id = :p2',
          [LChaveNFe, LProtocolo, ACupomId]
        );

        // Salvar arquivo autorizado
        ForceDirectories(PASTA_NFCE + 'autorizadas\');
        FACBrNFe.NotasFiscais.Items[0].GravarXML(
          NomeArqXmlNFCe(PASTA_NFCE + 'autorizadas\', LChaveNFe)
        );

        Result.Sucesso := True;
        Result.Mensagem := 'NFCe autorizada. Protocolo: ' + LProtocolo;
        Result.Dados := '{"chaveNFe":"' + LChaveNFe + '","protocolo":"' + LProtocolo + '"}';
      end
      else
      begin
        Result.Mensagem := 'NFCe rejeitada: ' +
          FACBrNFe.NotasFiscais.Items[0].Msg;
      end;
    except
      on E: Exception do
      begin
        // Rejeicao definitiva NAO e falha de comunicacao: o SEFAZ respondeu e
        // disse NAO (duplicidade, ambiente errado...). Entrar em contingencia
        // aqui fazia UMA nota rejeitada envenenar o caixa: todas as vendas
        // seguintes paravam de ser enviadas (e de imprimir) ate alguem sair
        // da contingencia na mao. Foi o que aconteceu em 25/08 com a
        // "Duplicidade de NF-e" da serie 13.
        if ErroPermanenteSefaz(E.Message) then
        begin
          Result.Sucesso := False;
          Result.Mensagem := 'NFCe rejeitada pelo SEFAZ: ' + E.Message;
          SyncLog('NFCe: REJEITADA no envio (cupom %d): %s', [ACupomId, E.Message]);
          Exit;
        end;

        // Falha de comunicacao - entrar em contingencia automatica
        Result.Mensagem := 'Falha ao enviar NFCe: ' + E.Message +
          '. Documento salvo para retransmissao.';

        // Registrar como contingencia automatica
        if not FContingencia.EstaEmContingencia then
          FContingencia.EntrarContingencia(tcOffLine, 'Falha de comunicacao com SEFAZ: ' + E.Message);

        LDocId := FContingencia.RegistrarDocContingencia(
          ACupomId, LChaveNFe, LNumNota,
          NomeArqXmlNFCe(PASTA_NFCE + 'contingencia\', LChaveNFe),
          LXml
        );

        FSQLite.ExecutarSQL(
          'UPDATE cupons SET chavenfe = :p0 WHERE id = :p1',
          [LChaveNFe, ACupomId]
        );

        ForceDirectories(PASTA_NFCE + 'contingencia\');
        FACBrNFe.NotasFiscais.Items[0].GravarXML(
          NomeArqXmlNFCe(PASTA_NFCE + 'contingencia\', LChaveNFe)
        );

        SyncLog('NFCe: contingencia automatica (cupom %d, doc %d): %s',
          [ACupomId, LDocId, E.Message]);

        Result.Sucesso := True; // Venda continua, NFCe sera reenviada
        Result.Dados := '{"chaveNFe":"' + LChaveNFe + '","contingencia":true}';
      end;
    end;

    // 5. Imprimir DANFCe (nota ja carregada em NotasFiscais - nao recarregar
    // XML nem gerar PDF em duplicidade como antes)
    try
      ImprimirNotaCarregada;
    except
      // Nao impedir a venda se falhar impressao; logar para diagnostico
      on E: Exception do
        SyncLog('NFCe: falha na impressao do DANFCe: [%s] %s',
          [E.ClassName, E.Message]);
    end;

  except
    on E: Exception do
      Result.Mensagem := 'Erro inesperado: ' + E.Message;
  end;
end;

{ Carrega em FACBrNFe.NotasFiscais o XML ORIGINAL assinado de um documento de
  nfce_contingencia (do banco, ou do disco quando o CLOB local veio vazio). }
function TNFCeWebManager.CarregarXmlDoc(ADocId: Integer; out ACupomId: Integer;
  out AChaveNFe, AErro: string): Boolean;
var
  LQuery: TUniQuery;
  LXml, LArq: string;
begin
  Result := False;
  ACupomId := 0;
  AChaveNFe := '';
  AErro := '';
  LArq := '';

  LQuery := FSQLite.ExecutarSelect(
    'SELECT cupom_id, chave_nfe, xml_conteudo, xml_path ' +
    'FROM nfce_contingencia WHERE id = ' + IntToStr(ADocId)
  );
  try
    if LQuery.IsEmpty then
    begin
      AErro := 'Documento ' + IntToStr(ADocId) + ' nao encontrado';
      Exit;
    end;

    ACupomId := LQuery.FieldByName('cupom_id').AsInteger;
    AChaveNFe := SomenteNumeroInteiro(LQuery.FieldByName('chave_nfe').AsString);
    LXml := LQuery.FieldByName('xml_conteudo').AsString;
  finally
    LQuery.Free;
  end;

  // Fallback: XML gravado em disco quando o CLOB local veio vazio
  if Trim(LXml) = '' then
  begin
    LArq := CaminhoXmlNFCe(PASTA_NFCE + 'contingencia\', AChaveNFe);
    if LArq = '' then
    begin
      AErro := 'XML nao encontrado (nem no banco nem em ' +
        PASTA_NFCE + 'contingencia\)';
      Exit;
    end;
  end;

  try
    FACBrNFe.NotasFiscais.Clear;
    if Trim(LXml) <> '' then
      FACBrNFe.NotasFiscais.LoadFromString(LXml)
    else
      FACBrNFe.NotasFiscais.LoadFromFile(LArq);
  except
    on E: Exception do
    begin
      AErro := 'Falha ao carregar o XML do documento ' + IntToStr(ADocId) +
        ': ' + E.Message;
      Exit;
    end;
  end;

  if FACBrNFe.NotasFiscais.Count = 0 then
  begin
    AErro := 'Falha ao carregar o XML do documento ' + IntToStr(ADocId);
    Exit;
  end;

  Result := True;
end;

{ "Duplicidade de NF-e" no reenvio de um documento que caiu em contingencia por
  timeout quase sempre quer dizer: o SEFAZ AUTORIZOU a nota, so' a resposta nao
  chegou. Foi o cupom 2196 em 22/09 - timeout no envio, e no reenvio do MESMO
  XML (mesma chave) o SEFAZ devolveu duplicidade. Tratado como rejeicao, a nota
  ficava REJEITADA no caixa estando valida no SEFAZ, e sem protocolo no ERP.

  Aqui pergunta ao SEFAZ pela chave do XML carregado em NotasFiscais. Se estiver
  autorizada (100/150), o ACBr anexa o protocolo a nota carregada; grava o XML
  autorizado e o protocolo no cupom, igual a uma retransmissao que deu certo.
  Qualquer outra resposta mantem a rejeicao - por exemplo quando o numero foi
  autorizado com OUTRA chave, caso que continua exigindo conferencia manual. }
function TNFCeWebManager.ResolverDuplicidade(ADocId, ACupomId: Integer;
  const AChaveNFe: string; var AResult: TResultadoOperacao): Boolean;
var
  LcStat: Integer;
  LProtocolo, LMotivo: string;
begin
  Result := False;
  if FACBrNFe.NotasFiscais.Count = 0 then Exit;

  try
    FACBrNFe.Consultar;
    LcStat := FACBrNFe.WebServices.Consulta.cStat;
    LProtocolo := FACBrNFe.WebServices.Consulta.Protocolo;
    LMotivo := FACBrNFe.WebServices.Consulta.XMotivo;
  except
    on E: Exception do
    begin
      SyncLog('NFCe: duplicidade doc=%d cupom=%d - consulta da chave %s ' +
        'falhou: [%s] %s', [ADocId, ACupomId, AChaveNFe, E.ClassName, E.Message]);
      Exit;
    end;
  end;

  if not (((LcStat = 100) or (LcStat = 150)) and (LProtocolo <> '')) then
  begin
    SyncLog('NFCe: duplicidade doc=%d cupom=%d - chave %s NAO consta como ' +
      'autorizada (cStat=%d %s). Conferir no portal: o numero pode ter sido ' +
      'autorizado com outra chave.', [ADocId, ACupomId, AChaveNFe, LcStat, LMotivo]);
    AResult.Mensagem := AResult.Mensagem + ' | Consulta da chave: ' +
      IntToStr(LcStat) + ' - ' + LMotivo;
    Exit;
  end;

  FSQLite.ExecutarSQL(
    'UPDATE cupons SET chavenfe = :p0, protocolo_nfe = :p1 WHERE id = :p2',
    [AChaveNFe, LProtocolo, ACupomId]
  );

  // Consultar anexou o protNFe a nota carregada: sai como nfeProc
  ForceDirectories(PASTA_NFCE + 'autorizadas\');
  FACBrNFe.NotasFiscais.Items[0].GravarXML(
    NomeArqXmlNFCe(PASTA_NFCE + 'autorizadas\', AChaveNFe)
  );

  AResult.Sucesso := True;
  AResult.Mensagem := 'NFCe ja estava autorizada no SEFAZ. Protocolo: ' + LProtocolo;
  AResult.Dados := LProtocolo;
  Result := True;

  SyncLog('NFCe: duplicidade doc=%d cupom=%d - nota JA AUTORIZADA no SEFAZ ' +
    '(chave=%s protocolo=%s), marcada como autorizada',
    [ADocId, ACupomId, AChaveNFe, LProtocolo]);
end;

function TNFCeWebManager.RetransmitirDoc(ADocId: Integer): TResultadoOperacao;
var
  LChaveNFe, LProtocolo, LErro: string;
  LCupomId: Integer;
begin
  Result.Sucesso := False;
  Result.Mensagem := '';
  Result.Dados := '';

  // Reenviar o XML ORIGINAL assinado - regerar mudaria a chave/assinatura
  if not CarregarXmlDoc(ADocId, LCupomId, LChaveNFe, LErro) then
  begin
    Result.Mensagem := LErro;
    SyncLog('NFCe: retransmissao ERRO doc=%d - %s', [ADocId, LErro]);
    Exit;
  end;

  try
    FACBrNFe.Enviar(1, False, True); // Lote=1, Imprimir=False, Sincrono=True

    if FACBrNFe.NotasFiscais.Items[0].Confirmada then
    begin
      LProtocolo := FACBrNFe.NotasFiscais.Items[0].NFe.procNFe.nProt;

      FSQLite.ExecutarSQL(
        'UPDATE cupons SET chavenfe = :p0, protocolo_nfe = :p1 WHERE id = :p2',
        [LChaveNFe, LProtocolo, LCupomId]
      );

      // Passa a valer como autorizado: o upload do doc eletronico le daqui
      ForceDirectories(PASTA_NFCE + 'autorizadas\');
      FACBrNFe.NotasFiscais.Items[0].GravarXML(
        NomeArqXmlNFCe(PASTA_NFCE + 'autorizadas\', LChaveNFe)
      );

      Result.Sucesso := True;
      Result.Mensagem := 'NFCe autorizada. Protocolo: ' + LProtocolo;
      Result.Dados := LProtocolo;

      SyncLog('NFCe: retransmissao OK doc=%d cupom=%d chave=%s protocolo=%s',
        [ADocId, LCupomId, LChaveNFe, LProtocolo]);
    end
    else
    begin
      // SEFAZ respondeu e negou: nao adianta insistir com o mesmo XML.
      // 'REJEITADO' em Dados diferencia isso de falha de comunicacao.
      Result.Dados := 'REJEITADO';
      Result.Mensagem := Trim(FACBrNFe.NotasFiscais.Items[0].Msg);
      if Result.Mensagem = '' then
        Result.Mensagem := 'NFCe nao confirmada pelo SEFAZ';
      SyncLog('NFCe: retransmissao REJEITADA doc=%d cupom=%d - %s',
        [ADocId, LCupomId, Result.Mensagem]);
    end;
  except
    on E: Exception do
    begin
      Result.Mensagem := E.Message;

      // O ACBr levanta excecao tanto para queda de rede quanto para rejeicao
      // do SEFAZ. So a segunda e' definitiva - insistir na primeira e' certo,
      // insistir na segunda deixa o documento eternamente PENDENTE.
      if ErroPermanenteSefaz(E.Message) then
      begin
        Result.Dados := 'REJEITADO';
        SyncLog('NFCe: retransmissao REJEITADA doc=%d cupom=%d - %s',
          [ADocId, LCupomId, E.Message]);
      end
      else
        SyncLog('NFCe: retransmissao ERRO doc=%d cupom=%d - [%s] %s',
          [ADocId, LCupomId, E.ClassName, E.Message]);
    end;
  end;

  // Duplicidade no reenvio do mesmo XML: conferir se a nota ja esta autorizada
  if (not Result.Sucesso) and (Result.Dados = 'REJEITADO') and
     (Pos('DUPLICIDADE', UpperCase(Result.Mensagem)) > 0) then
    ResolverDuplicidade(ADocId, LCupomId, LChaveNFe, Result);
end;

{ Regera a NFCe de um documento REJEITADO e transmite.

  RetransmitirDoc reenvia o XML ORIGINAL assinado - certo quando a nota esta
  boa e so' faltou chegar ao SEFAZ. Quando a rejeicao foi de CONTEUDO, reenviar
  o mesmo XML repete a rejeicao para sempre. Foi o que prendeu toda venda com
  desconto no subtotal: o desconto ficava so' no cabecalho do cupom e nao ia
  para os itens, entao a nota saia com vNF BRUTO enquanto o pagamento (e o
  troco) usavam o liquido. O SEFAZ devolvia "Total dos pagamentos menor que o
  valor total da nota" quando nao havia troco e "Valor do troco incorreto"
  quando havia - dois sintomas da mesma conta.

  Aqui a nota e' montada de novo a partir do cupom, com o codigo atual
  (PreencherItens rateia o desconto do cabecalho entre os itens). O numero e' o
  MESMO - PreencherIdentificacao le cupons.numnota - e o cNF/chave saem novos.
  Nota rejeitada nao consome numeracao no SEFAZ, entao reusar o nNF e' o
  caminho certo.

  Duplicidade fica de fora de proposito: nesse caso o numero JA esta autorizado
  no SEFAZ e uma nota nova viraria uma segunda venda. Esse se resolve conferindo
  a nota no portal e descartando o documento da fila. }
function TNFCeWebManager.RegerarDoc(ADocId: Integer): TResultadoOperacao;
var
  LQuery: TUniQuery;
  LXml, LChaveNova, LChaveAntiga, LProtocolo, LStatus, LMotivo, LArqXml: string;
  LCupomId, LNumNota: Integer;
begin
  Result.Sucesso := False;
  Result.Mensagem := '';
  Result.Dados := '';
  LCupomId := 0;
  LNumNota := 0;

  LQuery := FSQLite.ExecutarSelect(
    'SELECT cupom_id, numnota, chave_nfe, status, ' +
    'COALESCE(motivo_rejeicao, '''') AS motivo ' +
    'FROM nfce_contingencia WHERE id = ' + IntToStr(ADocId)
  );
  try
    if LQuery.IsEmpty then
    begin
      Result.Mensagem := 'Documento ' + IntToStr(ADocId) + ' nao encontrado';
      Exit;
    end;
    LCupomId := LQuery.FieldByName('cupom_id').AsInteger;
    LNumNota := LQuery.FieldByName('numnota').AsInteger;
    LChaveAntiga := SomenteNumeroInteiro(LQuery.FieldByName('chave_nfe').AsString);
    LStatus := UpperCase(Trim(LQuery.FieldByName('status').AsString));
    LMotivo := LQuery.FieldByName('motivo').AsString;
  finally
    LQuery.Free;
  end;

  // PENDENTE ainda tem envio do XML original a fazer; AUTORIZADO nao se toca
  if LStatus <> 'REJEITADO' then
  begin
    Result.Mensagem := 'Documento ' + IntToStr(ADocId) + ' esta ' + LStatus +
      ' - so documento REJEITADO pode ser regerado.';
    Exit;
  end;

  if Pos('DUPLICIDADE', UpperCase(LMotivo)) > 0 then
  begin
    // Documento que ficou REJEITADO por duplicidade antes desta correcao (ou
    // cuja consulta falhou na hora): a nota pode estar autorizada no SEFAZ com
    // esta mesma chave. Confere antes de recusar - nunca regera.
    Result.Mensagem := LMotivo;
    if CarregarXmlDoc(ADocId, LCupomId, LChaveAntiga, LXml) and
       ResolverDuplicidade(ADocId, LCupomId, LChaveAntiga, Result) then
      Exit;

    Result.Sucesso := False;
    Result.Dados := '';
    Result.Mensagem := 'Nota ' + IntToStr(LNumNota) + ': rejeicao por ' +
      'duplicidade. Esse numero ja esta autorizado no SEFAZ - regerar criaria ' +
      'uma segunda venda. Confira a nota no portal e use o descarte.';
    Exit;
  end;

  if Trim(VarToStr(FSQLite.ExecutarScalar(
       'SELECT COALESCE(protocolo_nfe, '''') FROM cupons WHERE id = ' +
       IntToStr(LCupomId)))) <> '' then
  begin
    Result.Mensagem := 'Cupom ' + IntToStr(LCupomId) + ' ja tem protocolo de ' +
      'autorizacao - nada a regerar.';
    Exit;
  end;

  // Mesma exigencia do envio normal: sem CSC o QR-Code sai invalido
  if (Trim(FACBrNFe.Configuracoes.Geral.CSC) = '') or
     (Trim(FACBrNFe.Configuracoes.Geral.IdCSC) = '') then
  begin
    Result.Mensagem := 'CSC/IdCSC nao configurados para a filial.';
    Exit;
  end;

  if not FileExists(FACBrNFe.Configuracoes.Certificados.ArquivoPFX) then
  begin
    Result.Mensagem := 'Certificado digital nao encontrado';
    Exit;
  end;

  try
    FACBrNFe.NotasFiscais.Clear;
    LXml := GerarXMLNFCe(LCupomId);
    if LXml = '' then
    begin
      Result.Mensagem := 'Falha ao gerar o XML do cupom ' + IntToStr(LCupomId);
      Exit;
    end;

    FACBrNFe.NotasFiscais.Assinar;
    FACBrNFe.NotasFiscais.Validar;

    LChaveNova := SomenteNumeroInteiro(
      FACBrNFe.NotasFiscais.Items[0].NFe.infNFe.ID);

    FACBrNFe.Enviar(1, False, True); // Lote=1, Imprimir=False, Sincrono=True

    if FACBrNFe.NotasFiscais.Items[0].Confirmada then
    begin
      LProtocolo := FACBrNFe.NotasFiscais.Items[0].NFe.procNFe.nProt;

      ForceDirectories(PASTA_NFCE + 'autorizadas\');
      LArqXml := NomeArqXmlNFCe(PASTA_NFCE + 'autorizadas\', LChaveNova);
      FACBrNFe.NotasFiscais.Items[0].GravarXML(LArqXml);

      // A chave mudou: documento e cupom tem que apontar para a nota nova,
      // senao o upload sobe para a retaguarda a chave que o SEFAZ negou
      FSQLite.ExecutarSQL(
        'UPDATE nfce_contingencia SET chave_nfe = :p0, xml_conteudo = :p1, ' +
        'xml_path = :p2 WHERE id = :p3',
        [LChaveNova, LXml, LArqXml, ADocId]
      );
      // chave_enviada/doceletronico_enviado voltam a zero: a venda ja subiu
      // para a retaguarda com a chave que o SEFAZ negou, e e' a nova que tem
      // que chegar la (AtualizarChavesNoOracle sobrescreve chave sem protocolo)
      FSQLite.ExecutarSQL(
        'UPDATE cupons SET chavenfe = :p0, protocolo_nfe = :p1, ' +
        'chave_enviada = 0, doceletronico_enviado = 0 WHERE id = :p2',
        [LChaveNova, LProtocolo, LCupomId]
      );

      Result.Sucesso := True;
      Result.Mensagem := 'NFCe ' + IntToStr(LNumNota) +
        ' autorizada. Protocolo: ' + LProtocolo;
      Result.Dados := LProtocolo;

      SyncLog('NFCe: regeracao OK doc=%d cupom=%d nota=%d chave %s -> %s ' +
        'protocolo=%s', [ADocId, LCupomId, LNumNota, LChaveAntiga, LChaveNova,
        LProtocolo]);
    end
    else
    begin
      Result.Dados := 'REJEITADO';
      Result.Mensagem := Trim(FACBrNFe.NotasFiscais.Items[0].Msg);
      if Result.Mensagem = '' then
        Result.Mensagem := 'NFCe nao confirmada pelo SEFAZ';
      SyncLog('NFCe: regeracao REJEITADA doc=%d cupom=%d nota=%d - %s',
        [ADocId, LCupomId, LNumNota, Result.Mensagem]);
    end;
  except
    on E: Exception do
    begin
      Result.Mensagem := E.Message;
      if ErroPermanenteSefaz(E.Message) then
      begin
        Result.Dados := 'REJEITADO';
        SyncLog('NFCe: regeracao REJEITADA doc=%d cupom=%d nota=%d - %s',
          [ADocId, LCupomId, LNumNota, E.Message]);
      end
      else
        SyncLog('NFCe: regeracao ERRO doc=%d cupom=%d nota=%d - [%s] %s',
          [ADocId, LCupomId, LNumNota, E.ClassName, E.Message]);
    end;
  end;
end;

{ Cancelamento de NFCe - evento 110111.

  O evento e montado direto da chave e do protocolo que ja estao no cupom, sem
  o Consulta previo que o TACBrNFe.Cancelamento faz: alem de poupar uma ida ao
  SEFAZ, funciona mesmo quando o XML autorizado sumiu da pasta.

  cStat do retorno:
    135 = evento registrado e vinculado a NFe  -> cancelou
    155 = cancelamento homologado fora de prazo -> cancelou (SEFAZ aceitou)
    qualquer outro = rejeicao, e a nota continua valendo. }
function TNFCeWebManager.CancelarNFCe(ACupomId: Integer;
  const AJustificativa: string): TResultadoOperacao;
var
  LQuery: TUniQuery;
  LChave, LProtocolo, LJust, LProtEvento, LXmlEvento: string;
  LCancelada: Integer;
  LcStat: Integer;
  LxMotivo: string;
begin
  Result.Sucesso := False;
  Result.Mensagem := '';
  Result.Dados := '';

  // Regra da SEFAZ: xJust de 15 a 255 caracteres
  LJust := Trim(AJustificativa);
  if (Length(LJust) < 15) or (Length(LJust) > 255) then
  begin
    Result.Mensagem := 'A justificativa deve ter de 15 a 255 caracteres';
    Exit;
  end;

  LQuery := FSQLite.ExecutarSelect(
    'SELECT chavenfe, protocolo_nfe, cancelada FROM cupons WHERE id = ' +
    IntToStr(ACupomId)
  );
  try
    if LQuery.Eof then
    begin
      Result.Mensagem := 'Cupom ' + IntToStr(ACupomId) + ' nao encontrado';
      Exit;
    end;
    LChave := Trim(LQuery.FieldByName('chavenfe').AsString);
    LProtocolo := Trim(LQuery.FieldByName('protocolo_nfe').AsString);
    LCancelada := LQuery.FieldByName('cancelada').AsInteger;
  finally
    LQuery.Free;
  end;

  if LCancelada = 1 then
  begin
    Result.Mensagem := 'Esta NFCe ja foi cancelada';
    Exit;
  end;

  // Sem chave/protocolo a nota nunca foi autorizada: nao ha o que cancelar na
  // SEFAZ. Documento pendente/rejeitado se resolve pelo descarte da fila.
  if (LChave = '') or (LProtocolo = '') then
  begin
    Result.Mensagem := 'NFCe nao autorizada (sem chave ou protocolo). ' +
      'Use o descarte na aba Pendentes.';
    Exit;
  end;

  try
    FACBrNFe.EventoNFe.Evento.Clear;
    with FACBrNFe.EventoNFe.Evento.New do
    begin
      infEvento.CNPJ := SomenteNumeroInteiro(FCNPJ);
      infEvento.cOrgao := StrToIntDef(Copy(LChave, 1, 2), 0);
      infEvento.dhEvento := Now;
      infEvento.tpEvento := teCancelamento;
      infEvento.chNFe := LChave;
      infEvento.nSeqEvento := 1;
      infEvento.detEvento.nProt := LProtocolo;
      infEvento.detEvento.xJust := LJust;
    end;

    FACBrNFe.EnviarEvento(1);

    LcStat := 0;
    LxMotivo := FACBrNFe.WebServices.EnvEvento.xMotivo;
    LProtEvento := '';
    LXmlEvento := '';

    if FACBrNFe.WebServices.EnvEvento.EventoRetorno.retEvento.Count > 0 then
      with FACBrNFe.WebServices.EnvEvento.EventoRetorno.retEvento.Items[0].RetInfEvento do
      begin
        LcStat := cStat;
        LxMotivo := xMotivo;
        LProtEvento := nProt;
        LXmlEvento := string(XML);
      end;

    if not (LcStat in [135, 155]) then
    begin
      Result.Mensagem := Format('Cancelamento rejeitado (%d): %s',
        [LcStat, LxMotivo]);
      SyncLog('NFCe: cancelamento REJEITADO cupom=%d chave=%s - %d %s',
        [ACupomId, LChave, LcStat, LxMotivo]);
      Exit;
    end;

    // Guardar o procEventoNFe junto com as notas, para o arquivo fiscal
    if LXmlEvento <> '' then
    try
      ForceDirectories(PASTA_NFCE + 'canceladas\');
      TFile.WriteAllText(
        NomeArqXmlNFCe(PASTA_NFCE + 'canceladas\', LChave), LXmlEvento);
    except
      on E: Exception do
        SyncLog('NFCe: cancelamento cupom=%d - falha ao gravar XML do evento: %s',
          [ACupomId, E.Message]);
    end;

    FSQLite.ExecutarSQL(
      'UPDATE cupons SET cancelada = 1, ' +
      'dthr_cancelamento = datetime(''now'',''localtime''), ' +
      'protocolo_cancelamento = :p0, justificativa_cancel = :p1, ' +
      'xml_cancelamento = :p2, codoper = ''C'', obscancel = :p3, ' +
      'cancel_enviado = 0 WHERE id = :p4',
      [LProtEvento, LJust, LXmlEvento, 'NFCe cancelada: ' + LJust, ACupomId]
    );

    Result.Sucesso := True;
    Result.Mensagem := Format('NFCe cancelada (%d - %s). Protocolo do evento: %s',
      [LcStat, LxMotivo, LProtEvento]);
    Result.Dados := '{"chaveNFe":"' + LChave + '","protocoloEvento":"' +
      LProtEvento + '","cStat":' + IntToStr(LcStat) + '}';
    SyncLog('NFCe: cancelamento OK cupom=%d chave=%s prot=%s',
      [ACupomId, LChave, LProtEvento]);
  except
    on E: Exception do
    begin
      Result.Mensagem := 'Falha ao cancelar NFCe: ' + E.Message;
      SyncLog('NFCe: cancelamento ERRO cupom=%d chave=%s - [%s] %s',
        [ACupomId, LChave, E.ClassName, E.Message]);
    end;
  end;
end;

procedure TNFCeWebManager.ImprimirDANFCe(const AChaveNFe: string);
var
  LArq: string;
begin
  // Reimpressao: carregar o XML autorizado e imprimir no modo configurado
  LArq := CaminhoXmlNFCe(PASTA_NFCE + 'autorizadas\', AChaveNFe);
  if LArq = '' then
    LArq := CaminhoXmlNFCe(PASTA_NFCE + 'contingencia\', AChaveNFe);
  if LArq = '' then
    raise Exception.Create('XML da NFCe nao encontrado para a chave ' + AChaveNFe);

  FACBrNFe.NotasFiscais.Clear;
  FACBrNFe.NotasFiscais.LoadFromFile(LArq);
  ImprimirNotaCarregada;
end;

{ Imprime a nota em NotasFiscais[0] conforme [impressao] do apoloweb.ini:
    modo=ESCPOS  -> ACBrNFe.DANFE ja e o TACBrNFeDANFeESCPOS (uDmApoloWeb);
                    Imprimir manda ESC/POS direto na termica, sem PDF.
    modo=SUMATRA -> gera o PDF (uma vez) e delega ao app externo. }
procedure TNFCeWebManager.ImprimirNotaCarregada;
var
  ArqPDF: string;
begin
  // Log de cada passo de proposito: em 25/08 o DANFCe "imprimia sem erro" e
  // nao saia papel - sem estas linhas nao havia como saber onde parava.
  if FACBrNFe.NotasFiscais.Count = 0 then
  begin
    SyncLog('DANFCe: nada a imprimir (NotasFiscais vazio)');
    Exit;
  end;

  if Assigned(DmApoloWeb) and DmApoloWeb.ImpressaoEscPos then
  begin
    SyncLog('DANFCe: ESCPOS inicio (DANFE=%s porta="%s" ativo=%s modelo=%s)',
      [FACBrNFe.DANFE.ClassName, DmApoloWeb.PosPrinter.Porta,
       BoolToStr(DmApoloWeb.PosPrinter.Ativo, True), DmApoloWeb.EscPosModelo]);
    // Ativar e cheio se ja ativo; garante porta aberta apos troca de bobina/USB
    DmApoloWeb.PosPrinter.Ativar;
    FACBrNFe.NotasFiscais.Items[0].Imprimir;
    SyncLog('DANFCe: ESCPOS concluido sem excecao');
  end
  else
  begin
    SyncLog('DANFCe: caminho PDF/Sumatra (modo=%s)', [DmApoloWeb.ModoImpressao]);
    ArqPDF := PASTA_NFCE + 'pdf\' +
      SomenteNumeroInteiro(FACBrNFe.NotasFiscais.Items[0].NFe.infNFe.ID) + '-nfe.pdf';
    if not FileExists(ArqPDF) then
    begin
      FACBrNFe.NotasFiscais.Items[0].ImprimirPDF;
      // ImprimirPDF nao retorna o caminho gerado; conferir se saiu onde o
      // fluxo espera (PathPDF + <chave>-nfe.pdf)
      if not FileExists(ArqPDF) then
        SyncLog('NFCe: ImprimirPDF nao gerou o arquivo esperado: ' + ArqPDF);
    end;
    ImprimirPDFExterno(ArqPDF);
  end;
end;

{ Imprime um PDF via app externo: SumatraPDF (leve, silencioso) se existir em
  C:\Apolo; senao mantem o PrintCupon.exe legado como fallback. }
procedure TNFCeWebManager.ImprimirPDFExterno(const AArqPDF: string);
var
  LParams: string;
begin
  if FileExists(EXE_SUMATRA) then
  begin
    if Trim(DmApoloWeb.ImpressoraCupom) <> '' then
      LParams := '-print-to "' + Trim(DmApoloWeb.ImpressoraCupom) + '"'
    else
      LParams := '-print-to-default';
    LParams := LParams + ' -silent -exit-when-done "' + AArqPDF + '"';
    ShellExecute(0, 'open', PChar(EXE_SUMATRA), PChar(LParams), nil, SW_HIDE);
  end
  else
  begin
    SyncLog('NFCe: SumatraPDF nao encontrado em ' + EXE_SUMATRA +
      '; delegando ao PrintCupon');
    ShellExecute(0, 'open', PChar(EXE_PRINTCUPON), PChar('"' + AArqPDF + '"'), nil, SW_HIDE);
  end;
end;

// =========================================================================
// PREENCHIMENTO DO XML NFCe
// =========================================================================

procedure TNFCeWebManager.PreencherIdentificacao(ACupomId: Integer);
var
  LQuery: TUniQuery;
  LNumNota: Integer;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT numnota, serienfce, numcaixa, numserieequip FROM cupons WHERE id = ' +
    IntToStr(ACupomId)
  );
  try
    LNumNota := Trunc(LQuery.FieldByName('numnota').AsFloat);

    with FACBrNFe.NotasFiscais.Items[0].NFe do
    begin
      Ide.cUF := UFtoCUF(FUF);
      Ide.natOp := 'VENDA';
      Ide.modelo := 65; // NFCe
      Ide.serie := LQuery.FieldByName('serienfce').AsInteger;
      Ide.nNF := LNumNota;
      Ide.dEmi := Now;
      Ide.dSaiEnt := Now;
      Ide.tpNF := tnSaida;
      Ide.idDest := doInterna;
      Ide.cMunFG := StrToIntDef(FCodCidadeIBGE, 0);
      Ide.tpImp := tiNFCe;
      Ide.tpAmb := FACBrNFe.Configuracoes.WebServices.Ambiente;
      Ide.finNFe := fnNormal;
      Ide.indFinal := cfConsumidorFinal;
      Ide.indPres := pcPresencial;
      Ide.procEmi := peAplicativoContribuinte;
      Ide.verProc := VERSAO_SISTEMA;

      // ===== CORRECAO PRINCIPAL: Tipo de emissao baseado na contingencia =====
      // BUG ORIGINAL: Sempre usava teOffLine independente do tipo real
      if FContingencia.EstaEmContingencia then
      begin
        case FContingencia.TipoAtual of
          tcOffLine: Ide.tpEmis := teOffLine;
          tcSVCAN:   Ide.tpEmis := teSVCAN;
          tcSVCRS:   Ide.tpEmis := teSVCRS;
          tcSVCSP:   Ide.tpEmis := teOffLine;
        else
          Ide.tpEmis := teOffLine;
        end;

        Ide.dhCont := FContingencia.DtInicio;
        Ide.xJust := FContingencia.Justificativa;
      end
      else
        Ide.tpEmis := teNormal;
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TNFCeWebManager.PreencherEmitente;
var ok:Boolean;
begin
  with FACBrNFe.NotasFiscais.Items[0].NFe do
  begin
    Emit.CNPJCPF := FCNPJ;
    Emit.xNome := FRazaoSocial;
    Emit.xFant := FFantasia;
    Emit.IE := FIE;
    Emit.CRT:=StrToCRT(ok,FRegimeTributario.ToString);
    Emit.EnderEmit.xLgr := FEndereco;
    Emit.EnderEmit.nro := FNumero;
    Emit.EnderEmit.xBairro := FBairro;
    Emit.EnderEmit.cMun := StrToIntDef(FCodCidadeIBGE, 0);
    Emit.EnderEmit.xMun := FCidade;
    Emit.EnderEmit.UF := FUF;
    Emit.EnderEmit.CEP := StrToIntDef(FCEP, 0);
    Emit.EnderEmit.cPais := 1058;
    Emit.EnderEmit.xPais := 'Brasil';
    Emit.EnderEmit.fone := FFone;
  end;
end;

procedure TNFCeWebManager.PreencherDestinatario(ACupomId: Integer);
var
  LQuery: TUniQuery;
  LCPF: string;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT cpf_cnpj, descnomecliente FROM cupons WHERE id = ' + IntToStr(ACupomId)
  );
  try
    LCPF := LQuery.FieldByName('cpf_cnpj').AsString;
    if LCPF <> '' then
    begin
      with FACBrNFe.NotasFiscais.Items[0].NFe do
      begin
        Dest.CNPJCPF := LCPF;
        if LQuery.FieldByName('descnomecliente').AsString <> '' then
          Dest.xNome := LQuery.FieldByName('descnomecliente').AsString;
        Dest.indIEDest := inNaoContribuinte;
      end;
    end;
  finally
    LQuery.Free;
  end;
end;

{ Monta os itens da NFCe.

  O desconto no subtotal (F3 no PDV) e o acrescimo ficam so no cabecalho do
  cupom, mas a NFCe nao tem onde guarda-los: o SEFAZ exige que vDesc e vOutro
  do total sejam a soma dos itens. Sem ratear, vNF sai maior que o total que o
  cliente pagou e a nota volta com "Total dos pagamentos menor que o valor
  total da nota". Por isso o rateio proporcional ao liquido de cada item. }
procedure TNFCeWebManager.PreencherItens(ACupomId: Integer;
  var ATotVProd, ATotVDesc, ATotVOutro, ATotVBC, ATotVICMS, ATotVPIS,
  ATotVCOFINS: Double);
var
  LQuery: TUniQuery;
  LIdx: Integer;
  LVlProd, LVlDesc, LVlOutro, LAliqICMS: Double;
  LDescSub, LEncargo, LBaseRateio, LLiquido, LCumLiquido, LParcela: Double;
  LDescRateado, LOutroRateado: Double;
  LCst: string;
  ok: Boolean;

  // Oracle guarda CST/CSOSN em coluna numerica: '0' chega como '0' mas o
  // ACBr exige 2 digitos ('00'). Completa com zero a esquerda.
  function NormalizarCst(const AValor: string): string;
  begin
    Result := Trim(AValor);
    if Length(Result) = 1 then
      Result := '0' + Result;
  end;
begin
  ATotVProd := 0; ATotVDesc := 0; ATotVOutro := 0; ATotVBC := 0;
  ATotVICMS := 0; ATotVPIS := 0; ATotVCOFINS := 0;
  FTotIBSCBSvBC := 0; FTotvIBSUF := 0; FTotvIBSMun := 0; FTotvCBS := 0;
  FIBSCBSAvisouSemRegra := False;
  FIBSCBSAvisouSemReducao := False;
  LIdx := 0;
  LDescRateado := 0;
  LOutroRateado := 0;
  LCumLiquido := 0;

  // Cabecalho: o que precisa ser rateado entre os itens
  LQuery := FSQLite.ExecutarSelect(
    'SELECT COALESCE(valordescsubtotal, 0) AS descsub, ' +
    'COALESCE(valorencargo, 0) AS encargo FROM cupons WHERE id = ' +
    IntToStr(ACupomId)
  );
  try
    LDescSub := LQuery.FieldByName('descsub').AsFloat;
    LEncargo := LQuery.FieldByName('encargo').AsFloat;
  finally
    LQuery.Free;
  end;

  // Base do rateio = liquido dos itens ativos (mesma base que o PDV usa em
  // DoAplicarDescontoSubtotal)
  LQuery := FSQLite.ExecutarSelect(
    'SELECT ' +
    'COALESCE(SUM(vlprod - vldesconto), 0) AS base FROM cupom_itens ' +
    'WHERE cupom_id = ' + IntToStr(ACupomId) + ' AND dtcancel IS NULL'
  );
  try
    LBaseRateio := LQuery.FieldByName('base').AsFloat;
  finally
    LQuery.Free;
  end;

  // Itens cancelados depois do desconto podem deixar o desconto do cabecalho
  // maior que a base; nesse caso zera o liquido, nunca deixa negativo
  if LDescSub > LBaseRateio then
    LDescSub := LBaseRateio;
  if LBaseRateio <= 0 then
  begin
    LDescSub := 0;
    LEncargo := 0;
  end;

  LQuery := FSQLite.ExecutarSelect(
    'SELECT * FROM cupom_itens WHERE cupom_id = ' + IntToStr(ACupomId) +
    ' AND dtcancel IS NULL ORDER BY numseqitem'
  );
  try
    while not LQuery.Eof do
    begin
      Inc(LIdx);

      LVlProd := LQuery.FieldByName('vlprod').AsFloat;
      LVlDesc := LQuery.FieldByName('vldesconto').AsFloat;
      LLiquido := LVlProd - LVlDesc;

      // Rateio do cabecalho, proporcional ao liquido de cada item. Arredonda
      // sobre o acumulado e desconta o que ja foi rateado: cada parcela fica a
      // no maximo um centavo da proporcional e a soma fecha exata no ultimo
      // item, sem sobra para despejar.
      LVlOutro := 0;
      if LBaseRateio > 0 then
      begin
        LCumLiquido := LCumLiquido + LLiquido;

        LParcela := RoundTo(LDescSub * LCumLiquido / LBaseRateio, -2) - LDescRateado;
        LDescRateado := LDescRateado + LParcela;
        LVlDesc := LVlDesc + LParcela;

        LParcela := RoundTo(LEncargo * LCumLiquido / LBaseRateio, -2) - LOutroRateado;
        LOutroRateado := LOutroRateado + LParcela;
        LVlOutro := LParcela;
      end;

      with FACBrNFe.NotasFiscais.Items[0].NFe.Det.New do
      begin
        // Produto
        Prod.nItem := LIdx;
        Prod.cProd := IntToStr(LQuery.FieldByName('codprod').AsInteger);
        Prod.cEAN := ValidarGTIN(LQuery.FieldByName('codbarra').AsString);
        Prod.xProd := LQuery.FieldByName('descricao').AsString;
        Prod.NCM := LQuery.FieldByName('ncm').AsString;
        Prod.CEST := LQuery.FieldByName('cest').AsString;
        Prod.CFOP := LQuery.FieldByName('cfop').AsString;
        Prod.uCom := LQuery.FieldByName('unidade').AsString;
        Prod.qCom := LQuery.FieldByName('qt').AsFloat;
        Prod.vUnCom := LQuery.FieldByName('punit').AsFloat;
        Prod.vProd := LVlProd;
        Prod.cEANTrib := ValidarGTIN(LQuery.FieldByName('codbarra').AsString);
        Prod.uTrib := LQuery.FieldByName('unidade').AsString;
        Prod.qTrib := LQuery.FieldByName('qt').AsFloat;
        Prod.vUnTrib := LQuery.FieldByName('punit').AsFloat;
        Prod.indTot := itSomaTotalNFe;

        if LVlDesc   > 0 then
          Prod.vDesc := LVlDesc;
        if LVlOutro  > 0 then
          Prod.vOutro := LVlOutro;

        // CFOP nao cadastrado vem como '0' do Oracle -> padrao venda varejo
        if Length(Prod.CFOP) <> 4 then
          Prod.CFOP := '5102';

        // ICMS
        LAliqICMS := LQuery.FieldByName('aliqicms').AsFloat;
        if FRegimeTributario = 1 then
        begin
          // Simples Nacional
          Imposto.ICMS.CSOSN := StrToCSOSNIcms(ok,
            LQuery.FieldByName('csosn').AsString);
          if not ok then
            raise Exception.CreateFmt(
              'Item %d (produto %s): CSOSN invalido no cadastro (''%s''). ' +
              'Corrija o cadastro fiscal do produto no ERP.',
              [LIdx, Prod.cProd, LQuery.FieldByName('csosn').AsString]);
          Imposto.ICMS.orig := oeNacional;

          // Ajustar CFOP conforme CSOSN (SEFAZ valida compatibilidade)
          // CSOSN 500 = ICMS cobrado por ST -> CFOP 5405
          // Demais CSOSN -> CFOP 5102 (nao pode usar 5405)
          if Imposto.ICMS.CSOSN = csosn500 then
          begin
            if Prod.CFOP <> '5405' then Prod.CFOP := '5405';
          end
          else
          begin
            if Prod.CFOP = '5405' then Prod.CFOP := '5102';
          end;
        end
        else
        begin
          LCst := NormalizarCst(LQuery.FieldByName('icms_cst').AsString);
          Imposto.ICMS.CST := StrToCSTICMS(ok, LCst);
          if (not ok) or (LCst = '') then
            raise Exception.CreateFmt(
              'Item %d (produto %s): CST de ICMS invalido no cadastro (''%s''). ' +
              'Corrija o cadastro fiscal do produto no ERP.',
              [LIdx, Prod.cProd, LQuery.FieldByName('icms_cst').AsString]);
          Imposto.ICMS.orig := oeNacional;

          // Ajustar CFOP conforme CST (SEFAZ valida compatibilidade)
          // CST 60 = ICMS cobrado por ST -> CFOP 5405
          // Demais CST -> CFOP 5102 (nao pode usar 5405)
          if Imposto.ICMS.CST = cst60 then
          begin
            if Prod.CFOP <> '5405' then Prod.CFOP := '5405';
          end
          else
          begin
            if Prod.CFOP = '5405' then Prod.CFOP := '5102';
          end;

          if LAliqICMS > 0 then
          begin
            Imposto.ICMS.vBC := LVlProd - LVlDesc;
            Imposto.ICMS.pICMS := LAliqICMS;
            Imposto.ICMS.vICMS := RoundTo((LVlProd - LVlDesc) * LAliqICMS / 100, -2);
            ATotVBC := ATotVBC + Imposto.ICMS.vBC;
            ATotVICMS := ATotVICMS + Imposto.ICMS.vICMS;
          end;
        end;

        // PIS (grupo opcional na NFC-e: sem CST cadastrado, nao gera a tag)
        LCst := NormalizarCst(LQuery.FieldByName('pis_cst').AsString);
        Imposto.PIS.CST := StrToCSTPIS(ok, LCst);
        if ok then
        begin
          Imposto.PIS.vBC := LVlProd - LVlDesc;
          Imposto.PIS.pPIS := LQuery.FieldByName('aliqpis').AsFloat;
          Imposto.PIS.vPIS := LQuery.FieldByName('valorpis').AsFloat;
          ATotVPIS := ATotVPIS + Imposto.PIS.vPIS;
        end;

        // COFINS (grupo opcional na NFC-e: sem CST cadastrado, nao gera a tag)
        LCst := NormalizarCst(LQuery.FieldByName('cofins_cst').AsString);
        Imposto.COFINS.CST := StrToCSTCOFINS(ok, LCst);
        if ok then
        begin
          Imposto.COFINS.vBC := LVlProd - LVlDesc;
          Imposto.COFINS.pCOFINS := LQuery.FieldByName('aliqcofins').AsFloat;
          Imposto.COFINS.vCOFINS := LQuery.FieldByName('valorcofins').AsFloat;
          ATotVCOFINS := ATotVCOFINS + Imposto.COFINS.vCOFINS;
        end;
      end;

      // IBS/CBS (reforma tributaria). Fora do "with" acima porque escreve
      // tambem nos acumuladores do documento, usados em PreencherTotais.
      // codprod e ncm escolhem a regra no cadastro da retaguarda.
      PreencherIBSCBSItem(LIdx - 1,
        LQuery.FieldByName('codprod').AsLargeInt,
        Trim(LQuery.FieldByName('ncm').AsString),
        LVlProd - LVlDesc);

      // Totais
      ATotVProd := ATotVProd + LVlProd;
      ATotVDesc := ATotVDesc + LVlDesc;
      ATotVOutro := ATotVOutro + LVlOutro;

      LQuery.Next;
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TNFCeWebManager.PreencherTotais(
  ATotVProd, ATotVDesc, ATotVOutro, ATotVBC, ATotVICMS, ATotVPIS,
  ATotVCOFINS: Double);
begin
  with FACBrNFe.NotasFiscais.Items[0].NFe do
  begin
    Total.ICMSTot.vBC := ATotVBC;
    Total.ICMSTot.vICMS := ATotVICMS;
    Total.ICMSTot.vProd := ATotVProd;
    Total.ICMSTot.vDesc := ATotVDesc;
    Total.ICMSTot.vOutro := ATotVOutro;
    Total.ICMSTot.vPIS := ATotVPIS;
    Total.ICMSTot.vCOFINS := ATotVCOFINS;
    // Tem que bater com o total do cupom (CalcularTotalCupom no uBridge):
    // valorvenda - valordesc + valorencargo. E o que o cliente pagou.
    Total.ICMSTot.vNF := ATotVProd - ATotVDesc + ATotVOutro;
    Total.ICMSTot.vICMSDeson := 0;
    Total.ICMSTot.vFCPUFDest := 0;
    Total.ICMSTot.vICMSUFDest := 0;
    Total.ICMSTot.vICMSUFRemet := 0;

    // IBSCBSTot: o ACBr so gera o grupo se algum item gerou o IBSCBS dele.
    // Os valores tem que fechar com a soma dos itens, senao o SEFAZ rejeita.
    if FTotIBSCBSvBC > 0 then
    begin
      Total.IBSCBSTot.vBCIBSCBS := FTotIBSCBSvBC;
      Total.IBSCBSTot.gIBS.gIBSUFTot.vIBSUF := FTotvIBSUF;
      Total.IBSCBSTot.gIBS.gIBSMunTot.vIBSMun := FTotvIBSMun;
      Total.IBSCBSTot.gIBS.vIBS := FTotvIBSUF + FTotvIBSMun;
      Total.IBSCBSTot.gCBS.vCBS := FTotvCBS;
    end;
  end;
end;

procedure TNFCeWebManager.PreencherPagamentos(ACupomId: Integer);
var
  LQuery: TUniQuery;
  LTroco: Double;
begin
  // Obter valor do troco do cupom
  LQuery := FSQLite.ExecutarSelect(
    'SELECT valortroco FROM cupons WHERE id = ' + IntToStr(ACupomId)
  );
  try
    LTroco := LQuery.FieldByName('valortroco').AsFloat;
  finally
    LQuery.Free;
  end;

  // Informar troco quando pagamento excede o total da nota
  if LTroco > 0 then
    FACBrNFe.NotasFiscais.Items[0].NFe.pag.vTroco := LTroco;

  // codpag: codigo NFCe do pagamento. Os codcob internos do PDV ('01', '03',
  // '17'...) ja sao codigos NFCe; pagamentos da aba Cobranca gravam o codcob
  // do retaguarda ('D', 'CH'...) e o CMP do cadastro meiopagto faz a traducao.
  LQuery := FSQLite.ExecutarSelect(
    'SELECT p.codcob, p.valor, p.codtipotransacao, p.codautorizacao, ' +
    'p.codbandeira, p.nsu, ' +
    'COALESCE(NULLIF(TRIM(mp.cmp), ''''), p.codcob) AS codpag, ' +
    'CASE WHEN t.id IS NOT NULL THEN 1 ELSE 0 END AS tef_integrado, ' +
    'COALESCE(t.cod_autorizacao, '''') AS tef_cod_aut, ' +
    'COALESCE(t.nsu, '''') AS tef_nsu ' +
    'FROM cupom_pagamentos p ' +
    'LEFT JOIN meiopagto mp ON mp.codcob = p.codcob ' +
    'LEFT JOIN tef_pendentes t ON t.cupom_id = p.cupom_id AND t.nsu = p.nsu ' +
    'WHERE p.cupom_id = ' + IntToStr(ACupomId)
  );
  try
    while not LQuery.Eof do
    begin
      with FACBrNFe.NotasFiscais.Items[0].NFe.pag.New do
      begin
        vPag := LQuery.FieldByName('valor').AsFloat;

        // Mapear codigo de cobranca para forma de pagamento NFe
        case StrToIntDef(LQuery.FieldByName('codpag').AsString, 1) of
          1:  tPag := fpDinheiro;
          2:  tPag := fpCheque;
          3, 4, 99: begin
                // Credito/debito: pelo tipo da transacao quando informado
                // (abas Cartao/POS/TEF); senao pelo proprio codigo NFCe
                // (cadastro meiopagto: cmp 03=credito, 04=debito)
                if LQuery.FieldByName('codtipotransacao').AsInteger = 1 then
                  tPag := fpCartaoCredito
                else if LQuery.FieldByName('codtipotransacao').AsInteger = 2 then
                  tPag := fpCartaoDebito
                else if LQuery.FieldByName('codpag').AsString = '04' then
                  tPag := fpCartaoDebito
                else
                  tPag := fpCartaoCredito;
                // Bandeira so faz sentido em cartao: no PIX o grupo card vai
                // sem ela (o ACBr ja nasce com tBand "nao informado")
                tBand := bcOutros;
              end;
          5:  tPag := fpCreditoLoja;
          17: tPag := fpPagamentoInstantaneo; // PIX
        else
          tPag := fpOutro;
        end;

        // Grupo <card> (YA04). Apesar do nome, o schema o define como "Grupo
        // de Cartoes, PIX, Boletos e outros Pagamentos Eletronicos" - e o
        // SEFAZ cobra ele no PIX tambem. Sem o grupo a nota volta com
        // "Nao informados os dados do cartao de credito/debito nas Formas de
        // Pagamento da Nota Fiscal": a mensagem fala em cartao porque e' de
        // antes do PIX existir, mas o grupo que falta e o mesmo. Era isso que
        // derrubava toda venda paga por PIX - o dinheiro entrava e o cupom
        // nao saia. O ACBr so gera o grupo quando tpIntegra <> tiNaoInformado.
        if tPag in [fpCartaoCredito, fpCartaoDebito, fpPagamentoInstantaneo] then
        begin
          // tiPagIntegrado (1) obrigaria informar o CNPJ da credenciadora, que
          // o PDV nao recebe do TEF. O tiPagNaoIntegrado dispensa CNPJ/tBand/
          // cAut e e' o mesmo que o ACBr usa no ECF virtual de NFCe.
          tpIntegra := tiPagNaoIntegrado;

          // Autorizacao da operacao (cartoes, PIX, boletos). No TEF vem do
          // gerenciador; no PIX dinamico o endToEndId e gravado no nsu.
          cAut := Trim(LQuery.FieldByName('tef_cod_aut').AsString);
          if cAut = '' then
            cAut := Trim(LQuery.FieldByName('codautorizacao').AsString);
          if cAut = '' then
            cAut := Trim(LQuery.FieldByName('tef_nsu').AsString);
          if cAut = '' then
            cAut := Trim(LQuery.FieldByName('nsu').AsString);

          // Cartao mantem o preenchimento defensivo que ja estava em producao.
          // No PIX cAut e opcional, e um numero inventado seria pior do que a
          // ausencia da tag - PIX manual nao tem autorizacao nenhuma.
          if (cAut = '') and (tPag <> fpPagamentoInstantaneo) then
            cAut := '000000';
        end;
      end;

      LQuery.Next;
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TNFCeWebManager.PreencherInfoAdicionais(ACupomId: Integer;
  ATotImpLei: Double);
begin
  with FACBrNFe.NotasFiscais.Items[0].NFe do
  begin
    InfAdic.infCpl := 'Documento emitido por ME/EPP optante pelo Simples Nacional';

    if ATotImpLei > 0 then
      InfAdic.infCpl := InfAdic.infCpl +
        ' | Val.Aprox.Tributos: R$ ' + FormatFloat('#,##0.00', ATotImpLei) +
        ' (Lei 12.741/2012)';

    if FContingencia.EstaEmContingencia then
      InfAdic.infCpl := InfAdic.infCpl +
        ' | EMITIDA EM CONTINGENCIA - ' + FContingencia.TipoAtual.ToString;
  end;
end;

end.
