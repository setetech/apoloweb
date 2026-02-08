unit uNFCeWeb;

interface

uses
  System.SysUtils, System.Classes, System.DateUtils, System.JSON, System.Math,  Winapi.Windows,
  ACBrBase, ACBrDFe, ACBrNFe, ACBrNFeNotasFiscais, pcnConversao,pcnConversaoNFe,uTypesApoloWeb,
  Uni,uConstantesWeb, uContingencia,Data.db,  uSQLiteDB, Winapi.ShellAPI;

type
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

    procedure CarregarDadosEmpresa;
    procedure PreencherIdentificacao(ACupomId: Integer);
    procedure PreencherEmitente;
    procedure PreencherDestinatario(ACupomId: Integer);
    procedure PreencherItens(ACupomId: Integer;
      var ATotVProd, ATotVDesc, ATotVBC, ATotVICMS, ATotVPIS, ATotVCOFINS: Double);
    procedure PreencherTotais(
      ATotVProd, ATotVDesc, ATotVBC, ATotVICMS, ATotVPIS, ATotVCOFINS: Double);
    procedure PreencherPagamentos(ACupomId: Integer);
    procedure PreencherInfoAdicionais(ACupomId: Integer;
      ATotImpLei: Double);
  public
    constructor Create(ASQLite: TSQLiteDB; AACBrNFe: TACBrNFe;
      AContingencia: TContingenciaManager);
    destructor Destroy; override;

    /// Gerar XML da NFCe a partir do cupom
    function GerarXMLNFCe(ACupomId: Integer): string;

    /// Assinar e enviar NFCe
    function EnviarNFCe(ACupomId: Integer): TResultadoOperacao;

    /// Reimprimir DANFCe
    procedure ImprimirDANFCe(const AChaveNFe: string);

    property Contingencia: TContingenciaManager read FContingencia;
  end;

implementation

uses
  System.Win.Registry, System.Variants;

Function SomenteNumeroInteiro(Const Texto:String):String;
Var i:Integer;
begin {Retira todos caracteres que não sejam numéricos Inteiro}
  Result:='';
  For i:=1 To Length(Texto) do
    If CharInSet(Texto[i], ['0'..'9']) Then
      Result:=Result+Texto[i];
end;


{ TNFCeWebManager }

constructor TNFCeWebManager.Create(ASQLite: TSQLiteDB; AACBrNFe: TACBrNFe;
  AContingencia: TContingenciaManager);
begin
  inherited Create;
  FSQLite := ASQLite;
  FACBrNFe := AACBrNFe;
  FContingencia := AContingencia;
  CarregarDadosEmpresa;
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
  LTotVProd, LTotVDesc, LTotVBC, LTotVICMS, LTotVPIS, LTotVCOFINS: Double;
begin
  Result := '';
  LTotVProd := 0; LTotVDesc := 0; LTotVBC := 0; LTotVICMS := 0;
  LTotVPIS := 0; LTotVCOFINS := 0;

  FACBrNFe.NotasFiscais.Clear;
  FACBrNFe.NotasFiscais.Add;

  try
    PreencherIdentificacao(ACupomId);
    PreencherEmitente;
    PreencherDestinatario(ACupomId);
    PreencherItens(ACupomId, LTotVProd, LTotVDesc, LTotVBC, LTotVICMS, LTotVPIS, LTotVCOFINS);
    PreencherTotais(LTotVProd, LTotVDesc, LTotVBC, LTotVICMS, LTotVPIS, LTotVCOFINS);

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

    LChaveNFe := FACBrNFe.NotasFiscais.Items[0].NFe.infNFe.ID;
    LNumNota := FACBrNFe.NotasFiscais.Items[0].NFe.Ide.nNF;

    // 3. Verificar se estamos em contingencia
    if FContingencia.EstaEmContingencia then
    begin
      // Salvar localmente para envio posterior
      LDocId := FContingencia.RegistrarDocContingencia(
        ACupomId, LChaveNFe, LNumNota,
        PASTA_NFCE + 'contingencia\' + LChaveNFe + '.xml',
        LXml
      );

      // Salvar arquivo XML
      ForceDirectories(PASTA_NFCE + 'contingencia\');
      FACBrNFe.NotasFiscais.Items[0].GravarXML(
        PASTA_NFCE + 'contingencia\' + LChaveNFe + '.xml'
      );

      Result.Sucesso := True;
      Result.Mensagem := 'NFCe salva em contingencia (Doc #' + IntToStr(LDocId) + ')';
      Result.Dados := '{"chaveNFe":"' + LChaveNFe + '","contingencia":true}';
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
          PASTA_NFCE + 'autorizadas\' + LChaveNFe + '.xml'
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
        // Falha de comunicacao - entrar em contingencia automatica
        Result.Mensagem := 'Falha ao enviar NFCe: ' + E.Message +
          '. Documento salvo para retransmissao.';

        // Registrar como contingencia automatica
        if not FContingencia.EstaEmContingencia then
          FContingencia.EntrarContingencia(tcOffLine, 'Falha de comunicacao com SEFAZ: ' + E.Message);

        LDocId := FContingencia.RegistrarDocContingencia(
          ACupomId, LChaveNFe, LNumNota,
          PASTA_NFCE + 'contingencia\' + LChaveNFe + '.xml',
          LXml
        );

        ForceDirectories(PASTA_NFCE + 'contingencia\');
        FACBrNFe.NotasFiscais.Items[0].GravarXML(
          PASTA_NFCE + 'contingencia\' + LChaveNFe + '.xml'
        );

        Result.Sucesso := True; // Venda continua, NFCe sera reenviada
      end;
    end;

    // 5. Imprimir DANFCe
    try
      FACBrNFe.NotasFiscais.Items[0].ImprimirPDF;
      ImprimirDANFCe(FACBrNFe.NotasFiscais.Items[0].NFe.infNFe.ID);
    except
      // Nao impedir a venda se falhar impressao
    end;

  except
    on E: Exception do
      Result.Mensagem := 'Erro inesperado: ' + E.Message;
  end;
end;

procedure TNFCeWebManager.ImprimirDANFCe(const AChaveNFe: string);
var ArqPDF:String;
begin
  ArqPDF:=PASTA_NFCE + 'pdf\' +  SomenteNumeroInteiro(AChaveNFe) + '-nfe.pdf';
  FACBrNFe.NotasFiscais.Clear;
  FACBrNFe.NotasFiscais.LoadFromFile( PASTA_NFCE + 'autorizadas\' + AChaveNFe + '.xml' );
  FACBrNFe.NotasFiscais.Items[0].ImprimirPDF;
  ShellExecute( 0, 'open', 'c:\Apolo\PrintCupon.exe', PChar(ArqPDF), nil,  SW_HIDE  );
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

procedure TNFCeWebManager.PreencherItens(ACupomId: Integer;
  var ATotVProd, ATotVDesc, ATotVBC, ATotVICMS, ATotVPIS, ATotVCOFINS: Double);
var
  LQuery: TUniQuery;
  LIdx: Integer;
  LVlProd, LVlDesc, LAliqICMS: Double;
  ok: Boolean;
begin
  ATotVProd := 0; ATotVDesc := 0; ATotVBC := 0; ATotVICMS := 0;
  ATotVPIS := 0; ATotVCOFINS := 0;
  LIdx := 0;

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

        if LVlDesc > 0 then
          Prod.vDesc := LVlDesc;

        // ICMS
        LAliqICMS := LQuery.FieldByName('aliqicms').AsFloat;
        if FRegimeTributario = 1 then
        begin
          // Simples Nacional
          Imposto.ICMS.CSOSN := StrToCSOSNIcms(ok,
            LQuery.FieldByName('csosn').AsString);
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
          Imposto.ICMS.CST := StrToCSTICMS(ok,
            LQuery.FieldByName('icms_cst').AsString);
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

        // PIS
        Imposto.PIS.CST := StrToCSTPIS(ok, LQuery.FieldByName('pis_cst').AsString);
        Imposto.PIS.vBC := LVlProd - LVlDesc;
        Imposto.PIS.pPIS := LQuery.FieldByName('aliqpis').AsFloat;
        Imposto.PIS.vPIS := LQuery.FieldByName('valorpis').AsFloat;
        ATotVPIS := ATotVPIS + Imposto.PIS.vPIS;

        // COFINS
        Imposto.COFINS.CST := StrToCSTCOFINS(ok, LQuery.FieldByName('cofins_cst').AsString);
        Imposto.COFINS.vBC := LVlProd - LVlDesc;
        Imposto.COFINS.pCOFINS := LQuery.FieldByName('aliqcofins').AsFloat;
        Imposto.COFINS.vCOFINS := LQuery.FieldByName('valorcofins').AsFloat;
        ATotVCOFINS := ATotVCOFINS + Imposto.COFINS.vCOFINS;
      end;

      // Totais
      ATotVProd := ATotVProd + LVlProd;
      ATotVDesc := ATotVDesc + LVlDesc;

      LQuery.Next;
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TNFCeWebManager.PreencherTotais(
  ATotVProd, ATotVDesc, ATotVBC, ATotVICMS, ATotVPIS, ATotVCOFINS: Double);
begin
  with FACBrNFe.NotasFiscais.Items[0].NFe do
  begin
    Total.ICMSTot.vBC := ATotVBC;
    Total.ICMSTot.vICMS := ATotVICMS;
    Total.ICMSTot.vProd := ATotVProd;
    Total.ICMSTot.vDesc := ATotVDesc;
    Total.ICMSTot.vPIS := ATotVPIS;
    Total.ICMSTot.vCOFINS := ATotVCOFINS;
    Total.ICMSTot.vNF := ATotVProd - ATotVDesc;
    Total.ICMSTot.vICMSDeson := 0;
    Total.ICMSTot.vFCPUFDest := 0;
    Total.ICMSTot.vICMSUFDest := 0;
    Total.ICMSTot.vICMSUFRemet := 0;
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

  LQuery := FSQLite.ExecutarSelect(
    'SELECT codcob, valor, codtipotransacao, codautorizacao, codbandeira ' +
    'FROM cupom_pagamentos WHERE cupom_id = ' + IntToStr(ACupomId)
  );
  try
    while not LQuery.Eof do
    begin
      with FACBrNFe.NotasFiscais.Items[0].NFe.pag.New do
      begin
        vPag := LQuery.FieldByName('valor').AsFloat;

        // Mapear codigo de cobranca para forma de pagamento NFe
        case StrToIntDef(LQuery.FieldByName('codcob').AsString, 1) of
          1:  tPag := fpDinheiro;
          2:  tPag := fpCheque;
          3:  begin
                if LQuery.FieldByName('codtipotransacao').AsInteger = 1 then
                  tPag := fpCartaoCredito
                else
                  tPag := fpCartaoDebito;
              end;
          5:  tPag := fpCreditoLoja;
          17: tPag := fpPagamentoInstantaneo; // PIX
          99: tPag := fpOutro;
        else
          tPag := fpOutro;
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
