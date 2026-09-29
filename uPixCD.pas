unit uPixCD;

{ Cobranca PIX dinamica via API Pix dos PSPs (ACBrPIXCD).

  A configuracao vem da tabela pixcd_config do SQLite (espelho da
  msapolo_pixcd do Oracle, cadastrada na retaguarda - ver
  docs\msapolo_pixcd.sql). Sem configuracao ativa o PDV continua no QR
  estatico com confirmacao manual (uBridge.GerarPayloadPix).

  Fluxo: CriarCobranca gera a cob no PSP e devolve o payload (copia e cola)
  para o QR; o frontend consulta ConsultarCobranca em loop e, quando o
  status vira CONCLUIDA, registra o pagamento sozinho com o endToEndId. }

interface

uses
  System.SysUtils, System.Classes,
  Uni, Data.DB,
  ACBrPIXCD, ACBrPIXBase,
  uSQLiteDB;

type
  TPixCDConfig = record
    PSP: string;
    Ambiente: Integer;          // 1=producao, 2=teste/homologacao
    ChavePix: string;
    ClientID: string;
    ClientSecret: string;
    ChaveExtra: string;         // BB: developer_application_key; MercadoPago: access_token
    ArqCertificado: string;
    ArqChavePrivada: string;
    ArqPFX: string;
    SenhaPFX: string;
    ExpiracaoSeg: Integer;
    // Recebedor (tabela empresa)
    NomeRecebedor: string;
    CidadeRecebedor: string;
    UFRecebedor: string;
    CEPRecebedor: string;
    function Hash: string;
  end;

  TPixCDManager = class
  private
    FSQLite: TSQLiteDB;
    FPixCD: TACBrPixCD;
    FPSP: TACBrPSP;
    FConfig: TPixCDConfig;
    FConfigHash: string;
    function LerConfig(out AConfig: TPixCDConfig; out AErro: string): Boolean;
    function MontarPSP(const AConfig: TPixCDConfig; out AErro: string): Boolean;
    function GarantirConfigurado(out AErro: string): Boolean;
    function DescreverProblema(const AOperacao: string): string;
  public
    constructor Create(ASQLite: TSQLiteDB);
    destructor Destroy; override;

    // Ha configuracao ativa no pixcd_config? (nao valida credenciais)
    function Habilitado: Boolean;

    function CriarCobranca(AValor: Double; out ATxId, ACopiaECola,
      AErro: string): Boolean;
    // AStatus: ATIVA | CONCLUIDA | REMOVIDA_PELO_USUARIO_RECEBEDOR | REMOVIDA_PELO_PSP
    function ConsultarCobranca(const ATxId: string; out AStatus, AEndToEndId,
      AErro: string): Boolean;
    function CancelarCobranca(const ATxId: string; out AErro: string): Boolean;
  end;

implementation

uses
  ACBrPIXPSPBancoDoBrasil, ACBrPIXPSPItau, ACBrPIXPSPSicoob, ACBrPIXPSPSicredi,
  ACBrPIXPSPBradesco, ACBrPIXPSPSantander, ACBrPIXPSPInter,
  ACBrPIXPSPGerenciaNet, ACBrPIXPSPMercadoPago, ACBrPIXPSPC6Bank,
  ACBrPIXPSPAilos, ACBrPIXPSPBanrisul, ACBrPIXPSPPagSeguro, ACBrPIXPSPCielo,
  uConstantesWeb;

{ TPixCDConfig }

function TPixCDConfig.Hash: string;
begin
  Result := PSP + '|' + IntToStr(Ambiente) + '|' + ChavePix + '|' + ClientID +
    '|' + ClientSecret + '|' + ChaveExtra + '|' + ArqCertificado + '|' +
    ArqChavePrivada + '|' + ArqPFX + '|' + SenhaPFX + '|' +
    IntToStr(ExpiracaoSeg) + '|' + NomeRecebedor + '|' + CidadeRecebedor;
end;

{ TPixCDManager }

constructor TPixCDManager.Create(ASQLite: TSQLiteDB);
begin
  inherited Create;
  FSQLite := ASQLite;
end;

destructor TPixCDManager.Destroy;
begin
  FreeAndNil(FPSP);
  FreeAndNil(FPixCD);
  inherited;
end;

function TPixCDManager.LerConfig(out AConfig: TPixCDConfig;
  out AErro: string): Boolean;
var
  LQuery: TUniQuery;
begin
  Result := False;
  AErro := '';
  AConfig := Default(TPixCDConfig);

  LQuery := FSQLite.ExecutarSelect(
    'SELECT psp, ambiente, chave_pix, client_id, client_secret, chave_extra, ' +
    'arq_certificado, arq_chave_privada, arq_pfx, senha_pfx, expiracao_seg ' +
    'FROM pixcd_config WHERE id = 1 AND UPPER(COALESCE(ativo, ''S'')) = ''S''');
  try
    if LQuery.Eof then
    begin
      AErro := 'Cobranca PIX dinamica nao configurada (msapolo_pixcd)';
      Exit;
    end;
    AConfig.PSP := Trim(LQuery.FieldByName('psp').AsString);
    AConfig.Ambiente := LQuery.FieldByName('ambiente').AsInteger;
    AConfig.ChavePix := Trim(LQuery.FieldByName('chave_pix').AsString);
    AConfig.ClientID := Trim(LQuery.FieldByName('client_id').AsString);
    AConfig.ClientSecret := Trim(LQuery.FieldByName('client_secret').AsString);
    AConfig.ChaveExtra := Trim(LQuery.FieldByName('chave_extra').AsString);
    AConfig.ArqCertificado := Trim(LQuery.FieldByName('arq_certificado').AsString);
    AConfig.ArqChavePrivada := Trim(LQuery.FieldByName('arq_chave_privada').AsString);
    AConfig.ArqPFX := Trim(LQuery.FieldByName('arq_pfx').AsString);
    AConfig.SenhaPFX := Trim(LQuery.FieldByName('senha_pfx').AsString);
    AConfig.ExpiracaoSeg := LQuery.FieldByName('expiracao_seg').AsInteger;
  finally
    LQuery.Free;
  end;

  if AConfig.PSP = '' then
  begin
    AErro := 'PSP nao informado na configuracao PIX (msapolo_pixcd.psp)';
    Exit;
  end;
  if AConfig.ExpiracaoSeg <= 0 then
    AConfig.ExpiracaoSeg := 300;

  // Recebedor e chave fallback vem do cadastro da filial
  LQuery := FSQLite.ExecutarSelect(
    'SELECT razao_social, fantasia, cidade, uf, cep, chave_pix ' +
    'FROM empresa WHERE id = 1');
  try
    if not LQuery.Eof then
    begin
      AConfig.NomeRecebedor := Trim(LQuery.FieldByName('fantasia').AsString);
      if AConfig.NomeRecebedor = '' then
        AConfig.NomeRecebedor := Trim(LQuery.FieldByName('razao_social').AsString);
      AConfig.CidadeRecebedor := Trim(LQuery.FieldByName('cidade').AsString);
      AConfig.UFRecebedor := Trim(LQuery.FieldByName('uf').AsString);
      AConfig.CEPRecebedor := Trim(LQuery.FieldByName('cep').AsString);
      if AConfig.ChavePix = '' then
        AConfig.ChavePix := Trim(LQuery.FieldByName('chave_pix').AsString);
    end;
  finally
    LQuery.Free;
  end;

  if AConfig.ChavePix = '' then
  begin
    AErro := 'Chave PIX nao configurada (msapolo_pixcd.chave_pix ou msfilial.chave_pix)';
    Exit;
  end;

  Result := True;
end;

function TPixCDManager.MontarPSP(const AConfig: TPixCDConfig;
  out AErro: string): Boolean;
var
  LNome: string;
  LBB: TACBrPSPBancoDoBrasil;
  LMP: TACBrPSPMercadoPago;
  LCert: TACBrPSPCertificate;
begin
  Result := False;
  AErro := '';
  FreeAndNil(FPSP);

  LNome := UpperCase(AConfig.PSP);
  LNome := StringReplace(LNome, ' ', '', [rfReplaceAll]);

  if (LNome = 'BB') or (LNome = 'BANCODOBRASIL') then
  begin
    LBB := TACBrPSPBancoDoBrasil.Create(nil);
    LBB.DeveloperApplicationKey := AConfig.ChaveExtra;
    FPSP := LBB;
  end
  else if LNome = 'ITAU' then
    FPSP := TACBrPSPItau.Create(nil)
  else if LNome = 'SICOOB' then
    FPSP := TACBrPSPSicoob.Create(nil)
  else if LNome = 'SICREDI' then
    FPSP := TACBrPSPSicredi.Create(nil)
  else if LNome = 'BRADESCO' then
    FPSP := TACBrPSPBradesco.Create(nil)
  else if LNome = 'SANTANDER' then
    FPSP := TACBrPSPSantander.Create(nil)
  else if LNome = 'INTER' then
    FPSP := TACBrPSPInter.Create(nil)
  else if (LNome = 'EFI') or (LNome = 'GERENCIANET') then
    FPSP := TACBrPSPGerenciaNet.Create(nil)
  else if LNome = 'MERCADOPAGO' then
  begin
    LMP := TACBrPSPMercadoPago.Create(nil);
    LMP.AccessToken := AConfig.ChaveExtra;
    FPSP := LMP;
  end
  else if (LNome = 'C6') or (LNome = 'C6BANK') then
    FPSP := TACBrPSPC6Bank.Create(nil)
  else if LNome = 'AILOS' then
    FPSP := TACBrPSPAilos.Create(nil)
  else if LNome = 'BANRISUL' then
    FPSP := TACBrPSPBanrisul.Create(nil)
  else if LNome = 'PAGSEGURO' then
    FPSP := TACBrPSPPagSeguro.Create(nil)
  else if LNome = 'CIELO' then
    FPSP := TACBrPSPCielo.Create(nil)
  else
  begin
    AErro := 'PSP nao suportado: ' + AConfig.PSP;
    Exit;
  end;

  // Credenciais comuns aos PSPs com certificado/OAuth (maioria)
  if FPSP is TACBrPSPCertificate then
  begin
    LCert := TACBrPSPCertificate(FPSP);
    LCert.ClientID := AConfig.ClientID;
    LCert.ClientSecret := AConfig.ClientSecret;
    if AConfig.ArqCertificado <> '' then
      LCert.ArquivoCertificado := AConfig.ArqCertificado;
    if AConfig.ArqChavePrivada <> '' then
      LCert.ArquivoChavePrivada := AConfig.ArqChavePrivada;
    if AConfig.ArqPFX <> '' then
      LCert.ArquivoPFX := AConfig.ArqPFX;
    if AConfig.SenhaPFX <> '' then
      LCert.SenhaPFX := AnsiString(AConfig.SenhaPFX);
  end;

  FPSP.ChavePIX := AConfig.ChavePix;
  Result := True;
end;

function TPixCDManager.GarantirConfigurado(out AErro: string): Boolean;
var
  LConfig: TPixCDConfig;
begin
  Result := False;
  if not LerConfig(LConfig, AErro) then
    Exit;

  if (FPixCD <> nil) and (FPSP <> nil) and (FConfigHash = LConfig.Hash) then
    Exit(True);

  if FPixCD = nil then
  begin
    FPixCD := TACBrPixCD.Create(nil);
    FPixCD.ArqLOG := PASTA_RAIZ + 'pixcd.log';
    FPixCD.NivelLog := 2;
    FPixCD.TimeOut := 30000;
    FPixCD.DadosAutomacao.NomeAplicacao := 'ApoloWeb';
    FPixCD.DadosAutomacao.VersaoAplicacao := VERSAO_SISTEMA;
  end;

  if not MontarPSP(LConfig, AErro) then
    Exit;

  if LConfig.Ambiente = 1 then
    FPixCD.Ambiente := ambProducao
  else
    FPixCD.Ambiente := ambTeste;

  FPixCD.Recebedor.Nome := LConfig.NomeRecebedor;
  FPixCD.Recebedor.Cidade := LConfig.CidadeRecebedor;
  FPixCD.Recebedor.UF := LConfig.UFRecebedor;
  FPixCD.Recebedor.CEP := LConfig.CEPRecebedor;

  FPixCD.PSP := FPSP;

  FConfig := LConfig;
  FConfigHash := LConfig.Hash;
  Result := True;
end;

// title/detail do problema retornado pela API; fallback generico quando o
// PSP nao devolveu um problema estruturado
function TPixCDManager.DescreverProblema(const AOperacao: string): string;
begin
  Result := Trim(FPSP.epCob.Problema.title + ' ' + FPSP.epCob.Problema.detail);
  if Result = '' then
    Result := 'Falha na operacao ' + AOperacao + ' junto ao PSP';
end;

function TPixCDManager.Habilitado: Boolean;
var
  LConfig: TPixCDConfig;
  LErro: string;
begin
  Result := LerConfig(LConfig, LErro);
end;

function TPixCDManager.CriarCobranca(AValor: Double; out ATxId, ACopiaECola,
  AErro: string): Boolean;
begin
  Result := False;
  ATxId := '';
  ACopiaECola := '';

  if AValor <= 0 then
  begin
    AErro := 'Valor invalido para a cobranca PIX';
    Exit;
  end;

  if not GarantirConfigurado(AErro) then
    Exit;

  try
    FPSP.epCob.Clear;
    FPSP.epCob.CobSolicitada.chave := FConfig.ChavePix;
    FPSP.epCob.CobSolicitada.calendario.expiracao := FConfig.ExpiracaoSeg;
    FPSP.epCob.CobSolicitada.valor.original := AValor;
    FPSP.epCob.CobSolicitada.solicitacaoPagador := 'Venda PDV ApoloWeb';

    // TxId vazio: POST /cob - o proprio PSP gera o txid
    if not FPSP.epCob.CriarCobrancaImediata then
    begin
      AErro := DescreverProblema('criar cobranca');
      Exit;
    end;

    ATxId := FPSP.epCob.CobGerada.txId;
    ACopiaECola := Trim(FPSP.epCob.CobGerada.pixCopiaECola);
    // Alguns PSPs so devolvem o location; o BR Code dinamico e' montado local
    if (ACopiaECola = '') and (FPSP.epCob.CobGerada.location <> '') then
      ACopiaECola := FPixCD.GerarQRCodeDinamico(FPSP.epCob.CobGerada.location);

    if (ATxId = '') or (ACopiaECola = '') then
    begin
      AErro := 'PSP nao retornou txid/QR Code da cobranca';
      Exit;
    end;

    Result := True;
  except
    on E: Exception do
      AErro := 'Erro ao criar cobranca PIX: ' + E.Message;
  end;
end;

function TPixCDManager.ConsultarCobranca(const ATxId: string; out AStatus,
  AEndToEndId, AErro: string): Boolean;
begin
  Result := False;
  AStatus := '';
  AEndToEndId := '';

  if Trim(ATxId) = '' then
  begin
    AErro := 'TxId nao informado';
    Exit;
  end;

  if not GarantirConfigurado(AErro) then
    Exit;

  try
    FPSP.epCob.Clear;
    if not FPSP.epCob.ConsultarCobrancaImediata(ATxId) then
    begin
      AErro := DescreverProblema('consultar cobranca');
      Exit;
    end;

    AStatus := PIXStatusCobrancaToString(FPSP.epCob.CobCompleta.status);
    if FPSP.epCob.CobCompleta.pix.Count > 0 then
      AEndToEndId := FPSP.epCob.CobCompleta.pix[0].endToEndId;
    Result := True;
  except
    on E: Exception do
      AErro := 'Erro ao consultar cobranca PIX: ' + E.Message;
  end;
end;

function TPixCDManager.CancelarCobranca(const ATxId: string;
  out AErro: string): Boolean;
begin
  Result := False;

  if Trim(ATxId) = '' then
  begin
    AErro := 'TxId nao informado';
    Exit;
  end;

  if not GarantirConfigurado(AErro) then
    Exit;

  try
    FPSP.epCob.Clear;
    FPSP.epCob.CobRevisada.status := stcREMOVIDA_PELO_USUARIO_RECEBEDOR;
    if not FPSP.epCob.RevisarCobrancaImediata(ATxId) then
    begin
      AErro := DescreverProblema('cancelar cobranca');
      Exit;
    end;
    Result := True;
  except
    on E: Exception do
      AErro := 'Erro ao cancelar cobranca PIX: ' + E.Message;
  end;
end;

end.
