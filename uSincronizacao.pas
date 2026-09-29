unit uSincronizacao;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.DateUtils, System.StrUtils, System.Variants,
  System.Diagnostics, System.IOUtils,
  Vcl.ExtCtrls, Uni,Data.DB, uSQLiteDB, uConstantesWeb, uTypesApoloWeb, uSyncLog;

type
  TSincronizador = class
  private
    FSQLite: TSQLiteDB;
    FTimerRetry: TTimer;
    FSincronizando: Boolean;
    FCertificadoRenovado: Boolean;
    FOnRetry: TNotifyEvent;
    // Retaguarda sem as tabelas/sequence de venda: nao adianta insistir a cada
    // ciclo. Marca uma vez, avisa uma vez, e so volta a tentar no proximo start
    FRetaguardaSemVenda: Boolean;
    FAvisouMsLogCupom: Boolean;
    // Cache da checagem da coluna prox_numnota_nfce: uma ida ao
    // all_tab_columns por sessao, nao uma por venda
    FProxNotaColunaVerificada: Boolean;
    FTemProxNotaColuna: Boolean;

    // Quando a retaguarda nao carimba data_atualizacao_servidor (ORDOTY), a
    // sync periodica roda por intervalo fixo em vez de por sinal do servidor
    function UltimaSyncAuto: TDateTime;

    // Espelho do contador de numeracao NFCe na msapolo_caixa (so avanca)
    procedure EspelharProxNumNota(AConn: TUniConnection);
    // numtrans da venda que ja subiu para msapolo_venda, ou 0 se nao subiu.
    // Usa (codfilial, numcaixa, numcupom) - que tem indice na retaguarda -
    // mais a datamovto, para o caso de o SQLite ter sido recriado e a
    // numeracao de cupom ter recomecado.
    function NumTransVendaNoOracle(AConn: TUniConnection;
      ACupom: TUniQuery): Int64;

    procedure OnTimerRetry(Sender: TObject);

    // Download Oracle -> SQLite
    function OracleTemColuna(AConn: TUniConnection; const ATabela, AColuna: string): Boolean;
    procedure SincronizarProdutos(AConn: TUniConnection; AFullReload: Boolean);
    procedure SincronizarCodBarras(AConn: TUniConnection);
    procedure SincronizarClientes(AConn: TUniConnection);
    procedure SincronizarFuncionarios(AConn: TUniConnection);
    procedure SincronizarPermissoes(AConn: TUniConnection);
    procedure SincronizarMeiosPagamento(AConn: TUniConnection);
    procedure SincronizarMeioPagto(AConn: TUniConnection);
    procedure SincronizarPlanoPagto(AConn: TUniConnection);
    procedure SincronizarEmpresa(AConn: TUniConnection);
    procedure SincronizarPixCD(AConn: TUniConnection);
    procedure SincronizarParametros(AConn: TUniConnection);
    procedure SincronizarBandeiras(AConn: TUniConnection);
    procedure SincronizarTribIBSCBS(AConn: TUniConnection);
    procedure SincronizarCaixa(AConn: TUniConnection);
    procedure SincronizarCertificado(AConn: TUniConnection);

    // Upload SQLite -> Oracle
    procedure EnviarVendasPendentes(AConn: TUniConnection);
    // Preenche a chavenfe na msapolo_venda depois que a NFCe e' autorizada:
    // a venda sobe antes de a nota existir, e sem isso a MSNF sai sem numero
    procedure AtualizarChavesNoOracle(AConn: TUniConnection);
    procedure EnviarDocEletronicosPendentes(AConn: TUniConnection);
    procedure EnviarNumerarioPendente(AConn: TUniConnection);
    function CodCobERP(const ACodCobPdv: string; ACodTipoTransacao: Integer): string;
    function MontarXmlCupom(ACupomId: Integer;NumTrans:Double): string;

    procedure RegistrarLog(const ATabela, AOperacao, ARegistroId, AStatus: string;
      const AErro: string = '');
    // Executa uma etapa do download cronometrando e logando em arquivo
    procedure ExecutarEtapa(const ANome: string; AAcao: TProc);
  public
    constructor Create(ASQLite: TSQLiteDB);
    destructor Destroy; override;

    // Verifica se precisa sincronizar (data_atualizacao_servidor > data_atualizacao_caixa)
    function PrecisaSincronizar(AConn: TUniConnection): Boolean;

    // Atualiza data_atualizacao_caixa na msapolo_caixa apos sync
    procedure AtualizarDataSincCaixa(AConn: TUniConnection);

    // Download completo (na abertura do caixa). AForcarFull recarrega produtos
    // do zero; senao produtos e incremental via versaoreg quando possivel.
    procedure DownloadCompleto(AConn: TUniConnection; AForcarFull: Boolean = False);

    // Upload de vendas (apos cada venda)
    procedure UploadVenda(AConn: TUniConnection; ACupomId: Integer);

    // Upload do XML NFCe para msdoceletronico
    procedure UploadDocEletronico(AConn: TUniConnection; ACupomId: Integer);

    // Leva para a retaguarda as NFCe canceladas: marca codoper='C' na
    // msapolo_venda e grava o procEventoNFe na msdoceletronico. Roda em lote
    // (cancelada = 1 AND cancel_enviado = 0), entao serve tanto para o disparo
    // imediato do cancelamento quanto para o ciclo de retry.
    procedure UploadCancelamentos(AConn: TUniConnection);

    // Sincronizacao pendente
    procedure ProcessarPendentes(AConn: TUniConnection);

    // Iniciar timer de retry
    procedure IniciarRetry;
    procedure PararRetry;

    property Sincronizando: Boolean read FSincronizando;
    // True quando a carga precisou rebaixar o certificado (arquivo ausente)
    property CertificadoRenovado: Boolean read FCertificadoRenovado;
    // Assinado pelo form principal: dispara ProcessarPendentes com a conexao
    property OnRetry: TNotifyEvent read FOnRetry write FOnRetry;
  end;

implementation

const
  // Sem o carimbo data_atualizacao_servidor nao ha como saber se algo mudou;
  // este e o intervalo da sync periodica nesse cenario. Abertura do caixa e
  // F5 (carga geral) continuam sincronizando na hora, independente disto.
  INTERVALO_SYNC_SEM_CARIMBO_MIN = 30;

{ Query Oracle somente-leitura para os loops de download. O FetchRows default
  do UniDAC (25) faz um round-trip de rede a cada 25 linhas - numa tabela de
  produtos grande isso vira milhares de idas e voltas. }
procedure ConfigurarLeituraOracle(AQuery: TUniQuery);
begin
  AQuery.ReadOnly := True;
  AQuery.UniDirectional := True;
  AQuery.FetchRows := 2000;
end;

{ TSincronizador }

constructor TSincronizador.Create(ASQLite: TSQLiteDB);
begin
  inherited Create;
  FSQLite := ASQLite;
  FSincronizando := False;

  FTimerRetry := TTimer.Create(nil);
  FTimerRetry.Interval := INTERVALO_RETRY_SYNC;
  FTimerRetry.OnTimer := OnTimerRetry;
  FTimerRetry.Enabled := False;
end;

destructor TSincronizador.Destroy;
begin
  FTimerRetry.Enabled := False;
  FTimerRetry.Free;
  inherited;
end;

procedure TSincronizador.IniciarRetry;
begin
  FTimerRetry.Enabled := True;
end;

procedure TSincronizador.PararRetry;
begin
  FTimerRetry.Enabled := False;
end;

procedure TSincronizador.OnTimerRetry(Sender: TObject);
begin
  // O timer vive aqui, mas a conexao Oracle e do form principal: ele assina
  // OnRetry e chama ProcessarPendentes. Sem esse repasse o timer era inerte
  // e nada era reenviado quando o Oracle voltava.
  if Assigned(FOnRetry) then
    FOnRetry(Self);
end;

// =========================================================================
// VERIFICACAO DE NECESSIDADE DE SYNC
// =========================================================================

{ O contador que VALE e o do SQLite do caixa (offline nao depende de nada
  daqui). Esta copia na msapolo_caixa e backup de desastre: se o banco local
  se perder, a proxima sincronizacao repoe a numeracao do ponto certo em vez
  de renascer em 1 e colidir com as proprias notas ja emitidas. O GREATEST
  garante que o espelho nunca retrocede - nem se um caixa com contador velho
  subir depois. }
procedure TSincronizador.EspelharProxNumNota(AConn: TUniConnection);
var
  LQry: TUniQuery;
  LProx, LNumCaixa: Integer;
begin
  try
    if not FProxNotaColunaVerificada then
    begin
      FTemProxNotaColuna :=
        OracleTemColuna(AConn, 'msapolo_caixa', 'prox_numnota_nfce');
      FProxNotaColunaVerificada := True;
    end;
    if not FTemProxNotaColuna then Exit;

    LProx := StrToIntDef(FSQLite.ObterEstado(KEY_PROX_NUM_NOTA, '0'), 0);
    LNumCaixa := StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '0'), 0);
    if (LProx <= 0) or (LNumCaixa = 0) then Exit;

    LQry := TUniQuery.Create(nil);
    try
      LQry.Connection := AConn;
      LQry.SQL.Text :=
        'UPDATE msapolo_caixa SET prox_numnota_nfce = ' +
        'GREATEST(NVL(prox_numnota_nfce, 0), :prox) WHERE numcaixa = :numcaixa';
      LQry.ParamByName('prox').AsInteger := LProx;
      LQry.ParamByName('numcaixa').AsInteger := LNumCaixa;
      LQry.Execute;
      if AConn.InTransaction then
        AConn.CommitRetaining;
    finally
      LQry.Free;
    end;
  except
    // Espelho e acessorio: falhar aqui nao pode derrubar o upload da venda
    on E: Exception do
      SyncLog('prox_numnota_nfce: falha ao espelhar na retaguarda: %s',
        [Trim(Copy(E.Message, 1, 120))]);
  end;
end;

function TSincronizador.UltimaSyncAuto: TDateTime;
var
  LVal: string;
begin
  LVal := FSQLite.ObterEstado(KEY_ULTIMA_SYNC_AUTO, '');
  // Sem registro = nunca rodou; devolve uma data antiga para disparar a sync
  if not TryStrToDateTime(LVal, Result, TFormatSettings.Invariant) then
    Result := 0;
end;

function TSincronizador.PrecisaSincronizar(AConn: TUniConnection): Boolean;
var
  LQuery: TUniQuery;
  LDtServidor, LDtCaixa: Variant;
  LQtdFunc: Variant;
  LSw: TStopwatch;
begin
  LSw := TStopwatch.StartNew;
  // Se o SQLite tem apenas dados de seed (poucos registros), forcar sync
  LQtdFunc := FSQLite.ExecutarScalar('SELECT COUNT(*) FROM funcionarios');
  if (not VarIsNull(LQtdFunc)) and (Integer(LQtdFunc) <= 2) then
  begin
    Result := True;
    Exit;
  end;

  Result := True; // Por padrao, sincroniza

  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    LQuery.SQL.Text :=
      'SELECT data_atualizacao_servidor, data_atualizacao_caixa ' +
      'FROM msapolo_caixa WHERE numseriehd = :numseriehd';
    LQuery.ParamByName('numseriehd').AsString := FSQLite.ObterEstado(KEY_HD_SERIAL, '');
    LQuery.Open;

    if not LQuery.IsEmpty then
    begin
      LDtServidor := LQuery.FieldByName('data_atualizacao_servidor').Value;
      LDtCaixa := LQuery.FieldByName('data_atualizacao_caixa').Value;

      if VarIsNull(LDtServidor) then
        // Retaguarda que NAO carimba data_atualizacao_servidor (caso ORDOTY:
        // o campo fica NULL para sempre). Tratar NULL como "forca sync" fazia
        // o timer de 60s baixar a carga inteira a cada minuto, o dia todo.
        // Sem o carimbo nao ha sinal de mudanca - sincroniza num intervalo
        // fixo (e na abertura/F5, que nao passam por aqui).
        Result := VarIsNull(LDtCaixa) or
          (MinutesBetween(Now, UltimaSyncAuto) >= INTERVALO_SYNC_SEM_CARIMBO_MIN)
      else if VarIsNull(LDtCaixa) then
        Result := True   // Caixa nunca sincronizou
      else
        Result := TDateTime(LDtServidor) > TDateTime(LDtCaixa);
    end
    else
    begin
      // Sem linha para este serial o download nao registra nada e o caixa nem
      // teria subido (CarregarParametrosCaixa exige a linha). Sincronizar em
      // loop nao conserta cadastro - avisa e espera.
      SyncLog('PrecisaSincronizar: numseriehd "%s" NAO encontrado na ' +
        'msapolo_caixa - verifique o cadastro do caixa',
        [FSQLite.ObterEstado(KEY_HD_SERIAL, '')]);
      Result := False;
    end;
  finally
    LQuery.Free;
  end;
  SyncLog('PrecisaSincronizar = %s (consulta msapolo_caixa em %d ms)',
    [BoolToStr(Result, True), LSw.ElapsedMilliseconds]);
end;

procedure TSincronizador.AtualizarDataSincCaixa(AConn: TUniConnection);
var
  LQuery: TUniQuery;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    LQuery.SQL.Text :=
      'UPDATE msapolo_caixa SET data_atualizacao_caixa = SYSDATE ' +
      'WHERE numseriehd = :numseriehd';
    LQuery.ParamByName('numseriehd').AsString := FSQLite.ObterEstado(KEY_HD_SERIAL, '');
    LQuery.Execute;
    // Com AutoCommit (default) o Execute ja commitou; CommitRetaining sem
    // transacao ativa lanca "Can't perform operation on inactive transaction",
    // o que impedia esta data de ser gravada e forcava download completo em
    // TODO login (PrecisaSincronizar sempre True).
    if AConn.InTransaction then
      AConn.CommitRetaining;

    // "Gravada OK" com 0 linhas atingidas era mentira: o caixa 33 logou isso
    // por dias com a data parada em 23/08 (serial sem linha correspondente).
    if LQuery.RowsAffected > 0 then
      SyncLog('AtualizarDataSincCaixa: data_atualizacao_caixa gravada OK')
    else
      SyncLog('AtualizarDataSincCaixa: NENHUMA linha atualizada - numseriehd ' +
        '"%s" nao encontrado na msapolo_caixa (cadastro do caixa?)',
        [FSQLite.ObterEstado(KEY_HD_SERIAL, '')]);
  finally
    LQuery.Free;
  end;

  // Carimbo local da sync periodica: e ele que espaca as cargas quando a
  // retaguarda nao preenche data_atualizacao_servidor (ver PrecisaSincronizar)
  FSQLite.SalvarEstado(KEY_ULTIMA_SYNC_AUTO,
    DateTimeToStr(Now, TFormatSettings.Invariant));
end;

// =========================================================================
// DOWNLOAD (Oracle -> SQLite)
// =========================================================================

procedure TSincronizador.ExecutarEtapa(const ANome: string; AAcao: TProc);
var
  LSw: TStopwatch;
begin
  LSw := TStopwatch.StartNew;
  try
    AAcao();
    SyncLog('  %-16s OK    em %6d ms', [ANome, LSw.ElapsedMilliseconds]);
  except
    on E: Exception do
    begin
      SyncLog('  %-16s ERRO  em %6d ms - %s', [ANome, LSw.ElapsedMilliseconds, E.Message]);
      raise;
    end;
  end;
end;

procedure TSincronizador.DownloadCompleto(AConn: TUniConnection; AForcarFull: Boolean);
var
  LSw: TStopwatch;
begin
  if FSincronizando then Exit;
  FSincronizando := True;
  FCertificadoRenovado := False;
  LSw := TStopwatch.StartNew;
  SyncLog('=== DOWNLOAD COMPLETO: inicio (servidor %s, full=%s) ===',
    [AConn.Server, BoolToStr(AForcarFull, True)]);
  try
    ExecutarEtapa('funcionarios',    procedure begin SincronizarFuncionarios(AConn) end);
    ExecutarEtapa('produtos',        procedure begin SincronizarProdutos(AConn, AForcarFull) end);
    ExecutarEtapa('codbarras',       procedure begin SincronizarCodBarras(AConn) end);
    ExecutarEtapa('clientes',        procedure begin SincronizarClientes(AConn) end);
    ExecutarEtapa('permissoes',      procedure begin SincronizarPermissoes(AConn) end);
    ExecutarEtapa('meios_pagamento', procedure begin SincronizarMeiosPagamento(AConn) end);
    ExecutarEtapa('meiopagto',       procedure begin SincronizarMeioPagto(AConn) end);
    ExecutarEtapa('planos_pagamento',procedure begin SincronizarPlanoPagto(AConn) end);
    ExecutarEtapa('empresa',         procedure begin SincronizarEmpresa(AConn) end);
    ExecutarEtapa('pixcd',           procedure begin SincronizarPixCD(AConn) end);
    ExecutarEtapa('parametros',      procedure begin SincronizarParametros(AConn) end);
    ExecutarEtapa('bandeiras',       procedure begin SincronizarBandeiras(AConn) end);
    ExecutarEtapa('trib_ibs_cbs',    procedure begin SincronizarTribIBSCBS(AConn) end);
    ExecutarEtapa('caixa',           procedure begin SincronizarCaixa(AConn) end);
    ExecutarEtapa('certificado',     procedure begin SincronizarCertificado(AConn) end);

    FSQLite.SalvarEstado('ULTIMA_SINCRONIZACAO', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    RegistrarLog('TODAS', 'DOWNLOAD', '', 'OK');
    SyncLog('=== DOWNLOAD COMPLETO: fim OK em %d ms ===', [LSw.ElapsedMilliseconds]);
  except
    on E: Exception do
    begin
      RegistrarLog('TODAS', 'DOWNLOAD', '', 'ERRO', E.Message);
      SyncLog('=== DOWNLOAD COMPLETO: FALHOU em %d ms - %s ===', [LSw.ElapsedMilliseconds, E.Message]);
    end;
  end;
  FSincronizando := False;
end;

// Verifica se uma coluna existe numa tabela acessivel do Oracle. Usado para
// tolerar bases de cliente onde a coluna ainda nao foi criada pelo ERP.
function TSincronizador.OracleTemColuna(AConn: TUniConnection;
  const ATabela, AColuna: string): Boolean;
var
  LQuery: TUniQuery;
begin
  Result := False;
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    LQuery.SQL.Text :=
      'SELECT COUNT(*) FROM all_tab_columns ' +
      'WHERE table_name = :tabela AND column_name = :coluna';
    LQuery.ParamByName('tabela').AsString := UpperCase(ATabela);
    LQuery.ParamByName('coluna').AsString := UpperCase(AColuna);
    try
      LQuery.Open;
      Result := LQuery.Fields[0].AsInteger > 0;
    except
      on E: Exception do
        RegistrarLog('produtos', 'CHECK_COLUNA', ATabela + '.' + AColuna,
          'ERRO', E.Message);
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TSincronizador.SincronizarProdutos(AConn: TUniConnection; AFullReload: Boolean);
var
  LQuery, LIns, LInsUnid: TUniQuery;
  LSw: TStopwatch;
  LQtd: Integer;
  LMsOpen, LMsLoop: Int64;
  LUltimaVersao, LMaxVersao: string;
  LIncremental, LTemQtUnit, LTemQtUnitTemp: Boolean;
  LExprQtUnit, LJoinQtUnit: string;
begin
  LSw := TStopwatch.StartNew;
  LQtd := 0;

  // QTUNIT (quantidade por embalagem) pode ainda nao existir na
  // msapolo_produtos do cliente; nesse caso tenta buscar da
  // msapolo_produto_temp (origem da carga do ERP) e, em ultimo caso,
  // assume 1 para nao quebrar o download de produtos
  LTemQtUnit := OracleTemColuna(AConn, 'msapolo_produtos', 'qtunit');
  LTemQtUnitTemp := (not LTemQtUnit) and
    OracleTemColuna(AConn, 'msapolo_produto_temp', 'qtunit');
  LJoinQtUnit := '';
  if LTemQtUnit then
    LExprQtUnit := 'p.qtunit'
  else if LTemQtUnitTemp then
  begin
    LExprQtUnit := 'NVL(t.qtunit, 1) as qtunit';
    LJoinQtUnit := ' LEFT JOIN msapolo_produto_temp t ' +
      'ON t.codprod = p.codprod AND t.codbarra = p.codbarra';
  end
  else
    LExprQtUnit := '1 as qtunit';

  // Incremental: baixar so o que mudou desde a ultima carga (versaoreg =
  // sysdate gravado pelo ERP a cada alteracao). Full: F5/carga geral ou
  // primeira sincronizacao (sem versao armazenada).
  LUltimaVersao := FSQLite.ObterEstado(KEY_PRODUTOS_VERSAOREG, '');
  LIncremental := (not AFullReload) and (LUltimaVersao <> '');

  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    ConfigurarLeituraOracle(LQuery);
    LQuery.SQL.Text :=
      'SELECT p.codprod, p.codbarra, p.descricao, p.unidade, p.embalagem, ' +
      'p.ncm, p.extipi, p.cest, p.prod_origem, p.ean_valido, ' +
      'p.permite_dig_preco, p.permite_dig_desc, p.permite_dig_qtde, p.permite_dig_codigo, ' +
      'p.pesoobrigatorio, p.pesovariavel, p.id, p.perdesconto, p.peracrescimo, ' +
      'p.pcusto, p.qtdisponivel, p.pvenda, p.pvendaatac, p.poferta, p.dtfimoferta, ' +
      'p.qtminiatac, p.maxperdesc, p.codecf, p.versaoreg, p.codtrib, ' +
      'p.impleitransparencia, p.aliqicms, p.icms_cst, p.cfop, p.csosn, p.icms_percbasered, ' +
      'p.pis_cst, p.pis_ppis, p.pis_qbcprod, p.pis_valiqprod, ' +
      'p.pisst_ppis, p.pisst_qbcprod, p.pisst_valiqprod, ' +
      'p.cofins_cst, p.cofins_pcofins, p.cofins_qbcprod, p.cofins_valiqprod, ' +
      'p.cofinsst_pcofins, p.cofinsst_qbcprod, p.cofinsst_valiqprod, p.codfilial, ' +
      LExprQtUnit + ' ' +
      'FROM msapolo_produtos p' + LJoinQtUnit +
      ' WHERE p.codfilial = :codfilial';
    if LIncremental then
      // >= (nao >) para nao perder alteracoes no mesmo segundo da ultima
      // carga; o INSERT OR REPLACE torna o re-upsert da borda inofensivo
      LQuery.SQL.Text := LQuery.SQL.Text +
        ' AND p.versaoreg >= TO_DATE(:versao, ''YYYY-MM-DD HH24:MI:SS'')';
    // msapolo_produtos tem 1 linha por (codprod, codbarra) - uma por
    // embalagem/EAN do produto. O PDV guarda 1 linha por codprod (INSERT OR
    // REPLACE), entao ordenamos para que a linha "principal" chegue por
    // ultimo e venca: EAN valido > demais; empate decidido pelo maior id.
    // Os outros codigos do produto continuam pesquisaveis via mscodbarra.
    LQuery.SQL.Text := LQuery.SQL.Text +
      ' ORDER BY DECODE(p.ean_valido, ''S'', 1, 0), p.id';
    LQuery.ParamByName('codfilial').AsString := FSQLite.ObterEstado(KEY_CODFILIAL, '');
    if LIncremental then
      LQuery.ParamByName('versao').AsString := LUltimaVersao;
    LQuery.Open;
    LMsOpen := LSw.ElapsedMilliseconds; // execucao no Oracle + 1o bloco de fetch

    // Usar transacao para performance
    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      // Full: limpar e recarregar. Incremental: so upsert dos alterados.
      if not LIncremental then
      begin
        FSQLite.ExecutarSQL('DELETE FROM produtos');
        FSQLite.ExecutarSQL('DELETE FROM produto_unidades');
      end;

      // INSERT preparado UMA vez, reexecutado por linha (so rebind de params)
      LIns := FSQLite.CriarComando(
          'INSERT OR REPLACE INTO produtos (codprod, codbarra, descricao, unidade, embalagem, ' +
          'ncm, extipi, cest, prod_origem, ean_valido, ' +
          'permite_dig_preco, permite_dig_desc, permite_dig_qtde, permite_dig_codigo, ' +
          'pesoobrigatorio, pesovariavel, id_oracle, perdesconto, peracrescimo, ' +
          'pcusto, qtdisponivel, pvenda, pvendaatac, poferta, dtfimoferta, ' +
          'qtminiatac, maxperdesc, codecf, versaoreg, codtrib, ' +
          'impleitransparencia, aliqicms, icms_cst, cfop, csosn, icms_percbasered, ' +
          'pis_cst, pis_ppis, pis_qbcprod, pis_valiqprod, ' +
          'pisst_ppis, pisst_qbcprod, pisst_valiqprod, ' +
          'cofins_cst, cofins_pcofins, cofins_qbcprod, cofins_valiqprod, ' +
          'cofinsst_pcofins, cofinsst_qbcprod, cofinsst_valiqprod, codfilial, qtunit) ' +
          'VALUES (:p0,:p1,:p2,:p3,:p4,:p5,:p6,:p7,:p8,:p9,' +
          ':p10,:p11,:p12,:p13,:p14,:p15,:p16,:p17,:p18,:p19,' +
          ':p20,:p21,:p22,:p23,:p24,:p25,:p26,:p27,:p28,:p29,' +
          ':p30,:p31,:p32,:p33,:p34,:p35,:p36,:p37,:p38,:p39,' +
          ':p40,:p41,:p42,:p43,:p44,:p45,:p46,:p47,:p48,:p49,:p50,:p51)');
      // Unidade de CADA (codprod, codbarra) - a tabela produtos colapsa para
      // a linha principal, mas a unidade da embalagem bipada fica preservada
      // em produto_unidades para o registro do item usar a unidade certa
      LInsUnid := FSQLite.CriarComando(
          'INSERT OR REPLACE INTO produto_unidades (codbarra, codprod, unidade, qtunit, ' +
          'descricao, pvenda, poferta, dtfimoferta) ' +
          'VALUES (:p0, :p1, :p2, :p3, :p4, :p5, :p6, :p7)');
      try
      while not LQuery.Eof do
      begin
        if Trim(LQuery.FieldByName('codbarra').AsString) <> '' then
          FSQLite.ExecutarComando(LInsUnid,
            [
              Trim(LQuery.FieldByName('codbarra').AsString),
              LQuery.FieldByName('codprod').AsLargeInt,
              LQuery.FieldByName('unidade').AsString,
              LQuery.FieldByName('qtunit').AsFloat,
              LQuery.FieldByName('descricao').AsString,
              LQuery.FieldByName('pvenda').AsFloat,
              LQuery.FieldByName('poferta').AsFloat,
              LQuery.FieldByName('dtfimoferta').AsString
            ]
          );
        FSQLite.ExecutarComando(LIns,
          [
            LQuery.FieldByName('codprod').AsLargeInt,
            LQuery.FieldByName('codbarra').AsString,
            LQuery.FieldByName('descricao').AsString,
            LQuery.FieldByName('unidade').AsString,
            LQuery.FieldByName('embalagem').AsString,
            LQuery.FieldByName('ncm').AsString,
            LQuery.FieldByName('extipi').AsString,
            LQuery.FieldByName('cest').AsString,
            LQuery.FieldByName('prod_origem').AsString,
            LQuery.FieldByName('ean_valido').AsString,
            LQuery.FieldByName('permite_dig_preco').AsString,
            LQuery.FieldByName('permite_dig_desc').AsString,
            LQuery.FieldByName('permite_dig_qtde').AsString,
            LQuery.FieldByName('permite_dig_codigo').AsString,
            LQuery.FieldByName('pesoobrigatorio').AsString,
            LQuery.FieldByName('pesovariavel').AsString,
            LQuery.FieldByName('id').AsLargeInt,
            LQuery.FieldByName('perdesconto').AsFloat,
            LQuery.FieldByName('peracrescimo').AsFloat,
            LQuery.FieldByName('pcusto').AsFloat,
            LQuery.FieldByName('qtdisponivel').AsFloat,
            LQuery.FieldByName('pvenda').AsFloat,
            LQuery.FieldByName('pvendaatac').AsFloat,
            LQuery.FieldByName('poferta').AsFloat,
            LQuery.FieldByName('dtfimoferta').AsString,
            LQuery.FieldByName('qtminiatac').AsInteger,
            LQuery.FieldByName('maxperdesc').AsFloat,
            LQuery.FieldByName('codecf').AsString,
            LQuery.FieldByName('versaoreg').AsString,
            LQuery.FieldByName('codtrib').AsFloat,
            LQuery.FieldByName('impleitransparencia').AsFloat,
            LQuery.FieldByName('aliqicms').AsFloat,
            LQuery.FieldByName('icms_cst').AsString,
            LQuery.FieldByName('cfop').AsFloat,
            LQuery.FieldByName('csosn').AsString,
            LQuery.FieldByName('icms_percbasered').AsFloat,
            LQuery.FieldByName('pis_cst').AsString,
            LQuery.FieldByName('pis_ppis').AsFloat,
            LQuery.FieldByName('pis_qbcprod').AsFloat,
            LQuery.FieldByName('pis_valiqprod').AsFloat,
            LQuery.FieldByName('pisst_ppis').AsFloat,
            LQuery.FieldByName('pisst_qbcprod').AsFloat,
            LQuery.FieldByName('pisst_valiqprod').AsFloat,
            LQuery.FieldByName('cofins_cst').AsString,
            LQuery.FieldByName('cofins_pcofins').AsFloat,
            LQuery.FieldByName('cofins_qbcprod').AsFloat,
            LQuery.FieldByName('cofins_valiqprod').AsFloat,
            LQuery.FieldByName('cofinsst_pcofins').AsFloat,
            LQuery.FieldByName('cofinsst_qbcprod').AsFloat,
            LQuery.FieldByName('cofinsst_valiqprod').AsFloat,
            LQuery.FieldByName('codfilial').AsString,
            LQuery.FieldByName('qtunit').AsFloat
          ]
        );
        Inc(LQtd);
        LQuery.Next;
      end;
      finally
        LIns.Free;
        LInsUnid.Free;
      end;

      FSQLite.ExecutarSQL('COMMIT');
      LMsLoop := LSw.ElapsedMilliseconds - LMsOpen;
      SyncLog('    produtos (%s): SELECT Oracle %d ms | fetch+gravacao SQLite %d ms | %d regs (%d regs/s)',
        [IfThen(LIncremental, 'incremental desde ' + LUltimaVersao, 'full'),
         LMsOpen, LMsLoop, LQtd,
         Trunc(LQtd / ((LMsLoop + 1) / 1000))]);
      RegistrarLog('produtos', 'DOWNLOAD', '', 'OK',
        Format('%d regs em %d ms', [LQtd, LSw.ElapsedMilliseconds]));
    except
      FSQLite.ExecutarSQL('ROLLBACK');
      raise;
    end;
  finally
    LQuery.Free;
  end;

  // Guardar o max(versaoreg) do servidor como marco da proxima carga
  // incremental (so ha o que atualizar se veio registro ou era full)
  if AFullReload or (LQtd > 0) or (LUltimaVersao = '') then
  begin
    LQuery := TUniQuery.Create(nil);
    try
      LQuery.Connection := AConn;
      // O WHERE do incremental usa >= para nao perder alteracao no mesmo
      // segundo da carga. O preco disso: marcador == MAX rebaixa a borda toda
      // vez - e quando um job do ERP carimba a TABELA INTEIRA num segundo so
      // (10 mil produtos com versaoreg identico), "a borda" vira a tabela
      // completa, re-baixada a cada ciclo para sempre. Passados 5 segundos do
      // MAX, nenhum update futuro recebe versaoreg <= MAX (versaoreg =
      // sysdate), entao e seguro guardar MAX + 1s e matar a borda.
      LQuery.SQL.Text :=
        'SELECT CASE WHEN SYSDATE - MAX(versaoreg) > 5/86400 ' +
        'THEN TO_CHAR(MAX(versaoreg) + 1/86400, ''YYYY-MM-DD HH24:MI:SS'') ' +
        'ELSE TO_CHAR(MAX(versaoreg), ''YYYY-MM-DD HH24:MI:SS'') END ' +
        'FROM msapolo_produtos WHERE codfilial = :codfilial';
      LQuery.ParamByName('codfilial').AsString := FSQLite.ObterEstado(KEY_CODFILIAL, '');
      LQuery.Open;
      LMaxVersao := LQuery.Fields[0].AsString;
      if LMaxVersao <> '' then
        FSQLite.SalvarEstado(KEY_PRODUTOS_VERSAOREG, LMaxVersao);
    finally
      LQuery.Free;
    end;
  end;
end;

// Codigos de barras adicionais dos produtos (mscodbarra do Colosso). O
// msapolo_produtos traz apenas o codbarra principal; os demais EANs do
// produto ficam nessa tabela auxiliar. Falha na leitura (ex: sem grant)
// e logada e nao aborta o restante do download.
procedure TSincronizador.SincronizarCodBarras(AConn: TUniConnection);
var
  LQuery: TUniQuery;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    ConfigurarLeituraOracle(LQuery);
    LQuery.SQL.Text :=
      'SELECT codprod, codbarra, descricao FROM mscodbarra';
    try
      LQuery.Open;
    except
      on E: Exception do
      begin
        RegistrarLog('codbarras', 'DOWNLOAD', '', 'ERRO', E.Message);
        Exit;
      end;
    end;

    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      FSQLite.ExecutarSQL('DELETE FROM codbarras');
      while not LQuery.Eof do
      begin
        FSQLite.ExecutarSQL(
          'INSERT OR REPLACE INTO codbarras (codbarra, codprod, descricao) ' +
          'VALUES (:p0, :p1, :p2)',
          [Trim(LQuery.FieldByName('codbarra').AsString),
           LQuery.FieldByName('codprod').AsLargeInt,
           LQuery.FieldByName('descricao').AsString]
        );
        LQuery.Next;
      end;
      FSQLite.ExecutarSQL('COMMIT');
      RegistrarLog('codbarras', 'DOWNLOAD', '', 'OK');
    except
      FSQLite.ExecutarSQL('ROLLBACK');
      raise;
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TSincronizador.SincronizarClientes(AConn: TUniConnection);
var
  LQuery, LIns: TUniQuery;
  LSw: TStopwatch;
  LQtd: Integer;
  LMsOpen, LMsLoop: Int64;
begin
  LSw := TStopwatch.StartNew;
  LQtd := 0;
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    ConfigurarLeituraOracle(LQuery);
    LQuery.SQL.Text := 'SELECT codcli, cnpj, nome, endereco, bairro, cidade, uf, cep, fax, limcredito FROM mscliente';
    LQuery.Open;
    LMsOpen := LSw.ElapsedMilliseconds;

    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      FSQLite.ExecutarSQL('DELETE FROM clientes');
      LIns := FSQLite.CriarComando(
          'INSERT INTO clientes (codcli, cpf_cnpj, nome, endereco, bairro, cidade, uf, cep, telefone, limite_credito) ' +
          'VALUES (:p0,:p1,:p2,:p3,:p4,:p5,:p6,:p7,:p8,:p9)');
      try
        while not LQuery.Eof do
        begin
          FSQLite.ExecutarComando(LIns,
            [LQuery.FieldByName('codcli').AsInteger, LQuery.FieldByName('cnpj').AsString,
             LQuery.FieldByName('nome').AsString, LQuery.FieldByName('endereco').AsString,
             LQuery.FieldByName('bairro').AsString, LQuery.FieldByName('cidade').AsString,
             LQuery.FieldByName('uf').AsString, LQuery.FieldByName('cep').AsString,
             LQuery.FieldByName('fax').AsString, LQuery.FieldByName('limcredito').AsFloat]
          );
          Inc(LQtd);
          LQuery.Next;
        end;
      finally
        LIns.Free;
      end;
      FSQLite.ExecutarSQL('COMMIT');
      LMsLoop := LSw.ElapsedMilliseconds - LMsOpen;
      SyncLog('    clientes: SELECT Oracle %d ms | fetch+gravacao SQLite %d ms | %d regs (%d regs/s)',
        [LMsOpen, LMsLoop, LQtd,
         Trunc(LQtd / ((LMsLoop + 1) / 1000))]);
      RegistrarLog('clientes', 'DOWNLOAD', '', 'OK',
        Format('%d regs em %d ms', [LQtd, LSw.ElapsedMilliseconds]));
    except
      FSQLite.ExecutarSQL('ROLLBACK');
      raise;
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TSincronizador.SincronizarFuncionarios(AConn: TUniConnection);
var
  LQuery, LIns: TUniQuery;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    ConfigurarLeituraOracle(LQuery);
    LQuery.SQL.Text :=
      'SELECT matricula, nome, ofuscar(senhadb,usuariodb) senhadb, usuariodb, cargo, ind_vendedor FROM msfunc ' +
      'WHERE dtexclusao IS NULL AND ''S'' IN (ind_supervisor_cx, ind_operador_cx, ind_vendedor)';
    LQuery.Open;

    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      FSQLite.ExecutarSQL('DELETE FROM funcionarios');
      LIns := FSQLite.CriarComando(
          'INSERT INTO funcionarios (matricula, nome, senhadb, usuario, cargo, ind_vendedor) VALUES (:p0,:p1,:p2,:p3,:p4,:p5)');
      try
        while not LQuery.Eof do
        begin
          FSQLite.ExecutarComando(LIns,
            [LQuery.FieldByName('matricula').AsInteger, LQuery.FieldByName('nome').AsString,
             LQuery.FieldByName('senhadb').AsString, LQuery.FieldByName('usuariodb').AsString,
             LQuery.FieldByName('cargo').AsString, LQuery.FieldByName('ind_vendedor').AsString]
          );
          LQuery.Next;
        end;
      finally
        LIns.Free;
      end;
      FSQLite.ExecutarSQL('COMMIT');
    except
      FSQLite.ExecutarSQL('ROLLBACK');
      raise;
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TSincronizador.SincronizarPermissoes(AConn: TUniConnection);
var
  LQuery, LIns: TUniQuery;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    ConfigurarLeituraOracle(LQuery);
    LQuery.SQL.Text := 'SELECT matricula, controle FROM msacesso WHERE codrotina = 8002';
    LQuery.Open;

    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      FSQLite.ExecutarSQL('DELETE FROM permissoes');
      LIns := FSQLite.CriarComando(
          'INSERT INTO permissoes (matricula, codcontrole) VALUES (:p0,:p1)');
      try
        while not LQuery.Eof do
        begin
          FSQLite.ExecutarComando(LIns,
            [LQuery.FieldByName('matricula').AsInteger, LQuery.FieldByName('controle').AsInteger]
          );
          LQuery.Next;
        end;
      finally
        LIns.Free;
      end;
      FSQLite.ExecutarSQL('COMMIT');
    except
      FSQLite.ExecutarSQL('ROLLBACK');
      raise;
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TSincronizador.SincronizarMeiosPagamento(AConn: TUniConnection);
var
  LQuery: TUniQuery;
  LCodCob: string;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    ConfigurarLeituraOracle(LQuery);
    LQuery.SQL.Text :=
      'SELECT codcob, cobranca, tipocob FROM mscob';
    LQuery.Open;

    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      FSQLite.ExecutarSQL('DELETE FROM meios_pagamento');
      while not LQuery.Eof do
      begin
        // codcob no Oracle pode vir numerico ('1'); o PDV usa sempre 2 digitos
        // ('01'). Sem o padding o JOIN em cupom_pagamentos nao bate e a
        // descricao do meio de pagamento fica em branco na tela.
        // Codigos alfanumericos ('D', 'CH', 'PIX') ficam como estao.
        LCodCob := Trim(LQuery.FieldByName('codcob').AsString);
        while (Length(LCodCob) < 2) and (LCodCob <> '') and
              CharInSet(LCodCob[1], ['0'..'9']) do
          LCodCob := '0' + LCodCob;

        FSQLite.ExecutarSQL(
          'INSERT INTO meios_pagamento (codcob, descricao, tipo, ativo) ' +
          'VALUES (:p0, :p1, :p2, 1)',
          [LCodCob,
           LQuery.FieldByName('cobranca').AsString,
           LQuery.FieldByName('tipocob').AsString]
        );
        LQuery.Next;
      end;
      FSQLite.ExecutarSQL('COMMIT');
      RegistrarLog('meios_pagamento', 'DOWNLOAD', '', 'OK');
    except
      FSQLite.ExecutarSQL('ROLLBACK');
      raise;
    end;
  finally
    LQuery.Free;
  end;
end;

// Cadastro de meios de pagamento do PDV (msapolo_meiopagto, mesmo modelo de
// msapolo_bandeiras). A tabela pode nao existir em retaguardas antigas:
// falha na leitura do Oracle e logada e nao aborta o restante do download.
procedure TSincronizador.SincronizarMeioPagto(AConn: TUniConnection);
var
  LQuery: TUniQuery;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    ConfigurarLeituraOracle(LQuery);
    LQuery.SQL.Text :=
      'SELECT id, descricao, codcob, ordem, obg_dtvenc, obg_documento, ' +
      'permite_troco, cmp FROM msapolo_meiopagto ORDER BY ordem';
    try
      LQuery.Open;
    except
      on E: Exception do
      begin
        RegistrarLog('meiopagto', 'DOWNLOAD', '', 'ERRO', E.Message);
        Exit;
      end;
    end;

    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      FSQLite.ExecutarSQL('DELETE FROM meiopagto');
      while not LQuery.Eof do
      begin
        FSQLite.ExecutarSQL(
          'INSERT INTO meiopagto (id, descricao, codcob, ordem, obg_dtvenc, ' +
          'obg_documento, permite_troco, cmp) ' +
          'VALUES (:p0, :p1, :p2, :p3, :p4, :p5, :p6, :p7)',
          [LQuery.FieldByName('id').AsInteger,
           LQuery.FieldByName('descricao').AsString,
           Trim(LQuery.FieldByName('codcob').AsString),
           LQuery.FieldByName('ordem').AsInteger,
           LQuery.FieldByName('obg_dtvenc').AsString,
           LQuery.FieldByName('obg_documento').AsString,
           LQuery.FieldByName('permite_troco').AsString,
           LQuery.FieldByName('cmp').AsString]
        );
        LQuery.Next;
      end;
      FSQLite.ExecutarSQL('COMMIT');
      RegistrarLog('meiopagto', 'DOWNLOAD', '', 'OK');
    except
      FSQLite.ExecutarSQL('ROLLBACK');
      raise;
    end;
  finally
    LQuery.Free;
  end;
end;

// Planos de pagamento da aba Cobranca (msapolo_planopagto, mesmo modelo de
// msapolo_meiopagto). Tabela pode nao existir em retaguardas antigas:
// falha na leitura do Oracle e logada e nao aborta o restante do download.
procedure TSincronizador.SincronizarPlanoPagto(AConn: TUniConnection);
var
  LQuery: TUniQuery;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    ConfigurarLeituraOracle(LQuery);
    LQuery.SQL.Text :=
      'SELECT codplpag, descricao, numparcela, txplano, prazos ' +
      'FROM msapolo_planopagto ORDER BY codplpag';
    try
      LQuery.Open;
    except
      on E: Exception do
      begin
        RegistrarLog('planos_pagamento', 'DOWNLOAD', '', 'ERRO', E.Message);
        Exit;
      end;
    end;

    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      FSQLite.ExecutarSQL('DELETE FROM planos_pagamento');
      while not LQuery.Eof do
      begin
        FSQLite.ExecutarSQL(
          'INSERT INTO planos_pagamento (codplpag, descricao, qtdeparcelas, txplano, prazos) ' +
          'VALUES (:p0, :p1, :p2, :p3, :p4)',
          [LQuery.FieldByName('codplpag').AsInteger,
           LQuery.FieldByName('descricao').AsString,
           LQuery.FieldByName('numparcela').AsInteger,
           LQuery.FieldByName('txplano').AsFloat,
           Trim(LQuery.FieldByName('prazos').AsString)]
        );
        LQuery.Next;
      end;
      FSQLite.ExecutarSQL('COMMIT');
      RegistrarLog('planos_pagamento', 'DOWNLOAD', '', 'OK');
    except
      FSQLite.ExecutarSQL('ROLLBACK');
      raise;
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TSincronizador.SincronizarEmpresa(AConn: TUniConnection);
var
  LQuery: TUniQuery;
  LCodFilial, LExprChavePix: string;
begin
  LCodFilial := FSQLite.ObterEstado(KEY_CODFILIAL, '');
  if LCodFilial = '' then Exit;

  // chave_pix pode ainda nao existir na msfilial do cliente
  if OracleTemColuna(AConn, 'msfilial', 'chave_pix') then
    LExprChavePix := 'chave_pix'
  else
    LExprChavePix := 'NULL as chave_pix';

  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    LQuery.SQL.Text :=
      'SELECT codfilial, codconsumidor, razaosocial, nome_fantasia, cnpj, ie, endereco, ender_numero, ender_complemento, ' +
      'bairro, cidade, uf, cep, codcidade, crt, fone, ' + LExprChavePix + ' ' +
      'FROM msfilial WHERE codfilial = :codfilial';
    LQuery.ParamByName('codfilial').AsString := LCodFilial;
    LQuery.Open;

    if not LQuery.IsEmpty then
    begin
      FSQLite.ExecutarSQL('DELETE FROM empresa');
      FSQLite.ExecutarSQL(
        'INSERT INTO empresa (id, razao_social, fantasia, cnpj, ie, ' +
        'endereco, numero, complemento, bairro, cidade, uf, cep, ' +
        'cod_cidade_ibge, regime_tributario, fone, chave_pix) ' +
        'VALUES (1, :p0, :p1, :p2, :p3, :p4, :p5, :p6, :p7, :p8, :p9, :p10, :p11, :p12, :p13, :p14)',
        [LQuery.FieldByName('razaosocial').AsString,
         LQuery.FieldByName('nome_fantasia').AsString,
         LQuery.FieldByName('cnpj').AsString,
         LQuery.FieldByName('ie').AsString,
         LQuery.FieldByName('endereco').AsString,
         LQuery.FieldByName('ender_numero').AsString,
         LQuery.FieldByName('ender_complemento').AsString,
         LQuery.FieldByName('bairro').AsString,
         LQuery.FieldByName('cidade').AsString,
         LQuery.FieldByName('uf').AsString,
         LQuery.FieldByName('cep').AsString,
         LQuery.FieldByName('codcidade').AsString,
         LQuery.FieldByName('crt').AsInteger,
         LQuery.FieldByName('fone').AsString,
         Trim(LQuery.FieldByName('chave_pix').AsString)]
      );
      RegistrarLog('empresa', 'DOWNLOAD', '', 'OK');
    end;
  finally
    LQuery.Free;
  end;
end;

{ Configuracao da API Pix (cobranca dinamica via ACBrPIXCD). A tabela
  msapolo_pixcd e' cadastrada na retaguarda (ver docs\msapolo_pixcd.sql);
  enquanto nao existir no Oracle do cliente a etapa apenas e' pulada e o
  PDV segue com o QR estatico + confirmacao manual. }
procedure TSincronizador.SincronizarPixCD(AConn: TUniConnection);
var
  LQuery: TUniQuery;
  LCodFilial: string;
begin
  LCodFilial := FSQLite.ObterEstado(KEY_CODFILIAL, '');
  if LCodFilial = '' then Exit;

  if not OracleTemColuna(AConn, 'msapolo_pixcd', 'psp') then
  begin
    SyncLog('  pixcd: tabela msapolo_pixcd nao existe no Oracle - etapa pulada');
    Exit;
  end;

  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    // LTRIM dos zeros porque msfilial.codfilial e' '1' e o PDV grava '01'
    LQuery.SQL.Text :=
      'SELECT psp, ambiente, chave_pix, client_id, client_secret, chave_extra, ' +
      'arq_certificado, arq_chave_privada, arq_pfx, senha_pfx, expiracao_seg, ativo ' +
      'FROM msapolo_pixcd ' +
      'WHERE LTRIM(codfilial, ''0'') = LTRIM(:codfilial, ''0'')';
    LQuery.ParamByName('codfilial').AsString := LCodFilial;
    LQuery.Open;

    FSQLite.ExecutarSQL('DELETE FROM pixcd_config');
    if not LQuery.IsEmpty then
    begin
      FSQLite.ExecutarSQL(
        'INSERT INTO pixcd_config (id, psp, ambiente, chave_pix, client_id, ' +
        'client_secret, chave_extra, arq_certificado, arq_chave_privada, ' +
        'arq_pfx, senha_pfx, expiracao_seg, ativo) ' +
        'VALUES (1, :p0, :p1, :p2, :p3, :p4, :p5, :p6, :p7, :p8, :p9, :p10, :p11)',
        [Trim(LQuery.FieldByName('psp').AsString),
         LQuery.FieldByName('ambiente').AsInteger,
         Trim(LQuery.FieldByName('chave_pix').AsString),
         Trim(LQuery.FieldByName('client_id').AsString),
         Trim(LQuery.FieldByName('client_secret').AsString),
         Trim(LQuery.FieldByName('chave_extra').AsString),
         Trim(LQuery.FieldByName('arq_certificado').AsString),
         Trim(LQuery.FieldByName('arq_chave_privada').AsString),
         Trim(LQuery.FieldByName('arq_pfx').AsString),
         Trim(LQuery.FieldByName('senha_pfx').AsString),
         LQuery.FieldByName('expiracao_seg').AsInteger,
         Trim(LQuery.FieldByName('ativo').AsString)]
      );
    end;
    RegistrarLog('pixcd', 'DOWNLOAD', '', 'OK');
  finally
    LQuery.Free;
  end;
end;

procedure TSincronizador.SincronizarParametros(AConn: TUniConnection);
var
  LQuery: TUniQuery;
  LNumCaixa: Integer;
  LCodFilial: string;
begin
  LNumCaixa := StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '1'), 1);
  LCodFilial := FSQLite.ObterEstado(KEY_CODFILIAL, '');

  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    ConfigurarLeituraOracle(LQuery);
    LQuery.SQL.Text :=
      'SELECT numcaixa, parametro, conteudo FROM msapolo_parametros ' +
      'WHERE codfilial = :codfilial AND (numcaixa = :numcaixa OR numcaixa IS NULL)';
    LQuery.ParamByName('codfilial').AsString := LCodFilial;
    LQuery.ParamByName('numcaixa').AsInteger := LNumCaixa;
    LQuery.Open;

    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      FSQLite.ExecutarSQL('DELETE FROM parametros');
      while not LQuery.Eof do
      begin
        FSQLite.ExecutarSQL(
          'INSERT INTO parametros (parametro, conteudo, numcaixa) ' +
          'VALUES (:p0, :p1, :p2)',
          [LQuery.FieldByName('parametro').AsString,
           LQuery.FieldByName('conteudo').AsString,
           LQuery.FieldByName('numcaixa').AsInteger]
        );
        LQuery.Next;
      end;
      FSQLite.ExecutarSQL('COMMIT');
      RegistrarLog('parametros', 'DOWNLOAD', '', 'OK');
    except
      FSQLite.ExecutarSQL('ROLLBACK');
      raise;
    end;
  finally
    LQuery.Free;
  end;
end;

{ Serie da NFC-e do caixa. Ate aqui a serie vinha do SERIE_NFCE local, que e'
  digitado na tela de configuracao e silenciosamente diverge do cadastro: as
  notas saiam na serie 1 enquanto a msapolo_caixa dizia outra coisa. A serie
  entra na chave de acesso, entao divergir significa emitir numeracao fiscal
  errada - por isso o cadastro manda. }
procedure TSincronizador.SincronizarCaixa(AConn: TUniConnection);
var
  LQuery: TUniQuery;
  LNumCaixa, LSerieCad, LSerieLocal: Integer;
  LProxCad, LProxLocal: Integer;
  LTemProxNota: Boolean;
begin
  LNumCaixa := StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '0'), 0);
  if LNumCaixa = 0 then
  begin
    SyncLog('    caixa: NUMCAIXA nao configurado, serie_nfce nao atualizada');
    Exit;
  end;

  // prox_numnota_nfce e opcional no cadastro: serve para a retaguarda mandar
  // o caixa PULAR a numeracao - necessario quando a serie ja foi usada por
  // outro emissor (caso da serie 13: o sistema antigo da loja emitiu ate um
  // numero que so o SEFAZ conhece, e continuar do 35 dava Duplicidade).
  LTemProxNota := OracleTemColuna(AConn, 'msapolo_caixa', 'prox_numnota_nfce');

  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    ConfigurarLeituraOracle(LQuery);
    if LTemProxNota then
      LQuery.SQL.Text :=
        'SELECT serie_nfce, prox_numnota_nfce FROM msapolo_caixa ' +
        'WHERE numcaixa = :numcaixa'
    else
      LQuery.SQL.Text :=
        'SELECT serie_nfce FROM msapolo_caixa WHERE numcaixa = :numcaixa';
    LQuery.ParamByName('numcaixa').AsInteger := LNumCaixa;

    try
      LQuery.Open;
    except
      on E: Exception do
      begin
        SyncLog('    caixa: falha ao ler msapolo_caixa (%s)',
          [Trim(Copy(E.Message, 1, 80))]);
        Exit;
      end;
    end;

    if LQuery.IsEmpty or LQuery.FieldByName('serie_nfce').IsNull then
    begin
      // Nao sobrescrever com nada: melhor manter a serie atual e avisar do
      // que zerar a numeracao de uma nota fiscal
      SyncLog('    caixa: numcaixa %d sem serie_nfce em msapolo_caixa - ' +
        'serie local mantida. Cadastrar o caixa na retaguarda.', [LNumCaixa]);
      Exit;
    end;

    LSerieCad := LQuery.FieldByName('serie_nfce').AsInteger;
    LSerieLocal := StrToIntDef(FSQLite.ObterEstado(KEY_SERIE_NFCE, '0'), 0);

    if LSerieCad <> LSerieLocal then
      SyncLog('    caixa: serie_nfce do caixa %d mudou de %d para %d ' +
        '(cadastro da retaguarda)', [LNumCaixa, LSerieLocal, LSerieCad]);

    FSQLite.SalvarEstado(KEY_SERIE_NFCE, IntToStr(LSerieCad));

    // Adotar o pulo de numeracao vindo do cadastro. So avanca, nunca
    // retrocede: voltar numeracao de NFCe e receita certa de Duplicidade.
    if LTemProxNota and (not LQuery.FieldByName('prox_numnota_nfce').IsNull) then
    begin
      LProxCad := LQuery.FieldByName('prox_numnota_nfce').AsInteger;
      LProxLocal := StrToIntDef(FSQLite.ObterEstado(KEY_PROX_NUM_NOTA, '1'), 1);
      if LProxCad > LProxLocal then
      begin
        FSQLite.SalvarEstado(KEY_PROX_NUM_NOTA, IntToStr(LProxCad));
        SyncLog('    caixa: numeracao NFCe do caixa %d avancada de %d para %d ' +
          '(prox_numnota_nfce da retaguarda)', [LNumCaixa, LProxLocal, LProxCad]);
      end;
    end;
  finally
    LQuery.Free;
  end;
end;

{ Tributacao IBS/CBS da filial, vinda do cadastro da retaguarda.
  Uma linha por regra; codprod/ncm nulos = regra geral. O join com
  ms_trib_ibs_cbs ja e' feito aqui, entao o PDV so precisa escolher a regra
  mais especifica na hora de emitir (ver ResolverIBSCBS em uNFCeWeb.pas).

  As tabelas podem nao existir em retaguardas mais antigas: nesse caso a
  etapa apenas registra e segue, sem derrubar a carga. }
procedure TSincronizador.SincronizarTribIBSCBS(AConn: TUniConnection);
var
  LQuery: TUniQuery;
  LCodFilial, LQtd: Integer;
  LNcm, LCodProd: Variant;
  LTemGRed: Boolean;

  // Colunas do gRed (IBSUF_PREDALIQ e companhia) sao novas na ms_trib_ibs_cbs:
  // em retaguarda que ainda nao rodou o ALTER TABLE, o SELECT completo estoura
  // ORA-00904 e a carga cai na forma antiga, sem reducao de aliquota
  function AbrirComGRed: Boolean;
  begin
    LQuery.SQL.Text :=
      'SELECT n.codfilial, t.ativo habilitado, t.cst, t.cclasstrib, ' +
      '       t.aliq_ibs pibsuf, t.aliq_cbs pcbs, t.pibsmun, ' +
      '       t.ibsuf_predaliq, t.ibsuf_paliqefet, ' +
      '       t.ibsmun_predaliq, t.ibsmun_paliqefet, ' +
      '       t.cbs_predaliq, t.cbs_paliqefet, ' +
      '       n.ncm, n.codprod ' +
      '  FROM msncm_ibs_cbs n, ms_trib_ibs_cbs t ' +
      ' WHERE t.id = n.id_ibs_cbs ' +
      '   AND n.modelo IN (0, 65) ' +
      '   AND n.codfilial = :codfilial';
    LQuery.ParamByName('codfilial').AsInteger := LCodFilial;
    try
      LQuery.Open;
      Result := True;
    except
      Result := False;
    end;
  end;

  // Numero opcional: NULL no Oracle continua NULL aqui, para distinguir
  // "sem reducao cadastrada" de "reducao de 0%"
  function ValorOuNulo(const ACampo: string): Variant;
  begin
    if (not LTemGRed) or LQuery.FieldByName(ACampo).IsNull then
      Result := Null
    else
      Result := LQuery.FieldByName(ACampo).AsFloat;
  end;

begin
  LCodFilial := StrToIntDef(FSQLite.ObterEstado(KEY_CODFILIAL, '0'), 0);
  LQtd := 0;

  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    ConfigurarLeituraOracle(LQuery);

    LTemGRed := AbrirComGRed;
    if not LTemGRed then
    begin
      SyncLog('    trib_ibs_cbs: retaguarda sem as colunas de gRed ' +
        '(IBSUF_PREDALIQ etc) - carga sem reducao de aliquota');

      LQuery.Close;
      LQuery.SQL.Text :=
        'SELECT n.codfilial, t.ativo habilitado, t.cst, t.cclasstrib, ' +
        '       t.aliq_ibs pibsuf, t.aliq_cbs pcbs, t.pibsmun, ' +
        '       n.ncm, n.codprod ' +
        '  FROM msncm_ibs_cbs n, ms_trib_ibs_cbs t ' +
        ' WHERE t.id = n.id_ibs_cbs ' +
        '   AND n.modelo IN (0, 65) ' +
        '   AND n.codfilial = :codfilial';
      LQuery.ParamByName('codfilial').AsInteger := LCodFilial;

      try
        LQuery.Open;
      except
        on E: Exception do
        begin
          // ORA-00942: retaguarda sem o cadastro de IBS/CBS
          RegistrarLog('trib_ibs_cbs', 'DOWNLOAD', '', 'ERRO', E.Message);
          SyncLog('    trib_ibs_cbs: cadastro indisponivel (%s)',
            [Trim(Copy(E.Message, 1, 80))]);
          Exit;
        end;
      end;
    end;

    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      FSQLite.ExecutarSQL('DELETE FROM trib_ibs_cbs');
      while not LQuery.Eof do
      begin
        // NULL no Oracle tem que continuar NULL aqui: gravar '' ou 0 apagaria
        // a distincao entre "regra do NCM tal" e "regra geral da filial"
        if LQuery.FieldByName('ncm').IsNull or
           (Trim(LQuery.FieldByName('ncm').AsString) = '') then
          LNcm := Null
        else
          // Zero a esquerda: parte do cadastro grava a NCM como numero
          // ('4029900'), e o produto traz os 8 digitos ('04029900')
          LNcm := NormalizarNCM(LQuery.FieldByName('ncm').AsString);

        if LQuery.FieldByName('codprod').IsNull or
           (LQuery.FieldByName('codprod').AsInteger = 0) then
          LCodProd := Null
        else
          LCodProd := LQuery.FieldByName('codprod').AsInteger;

        FSQLite.ExecutarSQL(
          'INSERT INTO trib_ibs_cbs ' +
          '(codfilial, ncm, codprod, habilitado, cst, cclasstrib, pibsuf, pibsmun, pcbs, ' +
          ' ibsuf_predaliq, ibsuf_paliqefet, ibsmun_predaliq, ibsmun_paliqefet, ' +
          ' cbs_predaliq, cbs_paliqefet) ' +
          'VALUES (:p0, :p1, :p2, :p3, :p4, :p5, :p6, :p7, :p8, ' +
          '        :p9, :p10, :p11, :p12, :p13, :p14)',
          [LQuery.FieldByName('codfilial').AsInteger,
           LNcm,
           LCodProd,
           LQuery.FieldByName('habilitado').AsInteger,
           Trim(LQuery.FieldByName('cst').AsString),
           Trim(LQuery.FieldByName('cclasstrib').AsString),
           LQuery.FieldByName('pibsuf').AsFloat,
           LQuery.FieldByName('pibsmun').AsFloat,
           LQuery.FieldByName('pcbs').AsFloat,
           ValorOuNulo('ibsuf_predaliq'),
           ValorOuNulo('ibsuf_paliqefet'),
           ValorOuNulo('ibsmun_predaliq'),
           ValorOuNulo('ibsmun_paliqefet'),
           ValorOuNulo('cbs_predaliq'),
           ValorOuNulo('cbs_paliqefet')]
        );
        Inc(LQtd);
        LQuery.Next;
      end;
      FSQLite.ExecutarSQL('COMMIT');
      RegistrarLog('trib_ibs_cbs', 'DOWNLOAD', '', 'OK');
      SyncLog('    trib_ibs_cbs: %d regra(s) para a filial %d', [LQtd, LCodFilial]);
    except
      FSQLite.ExecutarSQL('ROLLBACK');
      raise;
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TSincronizador.SincronizarBandeiras(AConn: TUniConnection);
var
  LQuery: TUniQuery;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    ConfigurarLeituraOracle(LQuery);
    LQuery.SQL.Text :=
      'SELECT codigo, bandeira, tband FROM msapolo_bandeiras WHERE NVL(ativo, ''S'') = ''S''';
    LQuery.Open;

    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      FSQLite.ExecutarSQL('DELETE FROM bandeiras');
      while not LQuery.Eof do
      begin
        FSQLite.ExecutarSQL(
          'INSERT INTO bandeiras (codbandeira, descricao, tband) VALUES (:p0, :p1, :p2)',
          [LQuery.FieldByName('codigo').AsInteger,
           LQuery.FieldByName('bandeira').AsString,
           LQuery.FieldByName('tband').AsString]
        );
        LQuery.Next;
      end;
      FSQLite.ExecutarSQL('COMMIT');
      RegistrarLog('bandeiras', 'DOWNLOAD', '', 'OK');
    except
      FSQLite.ExecutarSQL('ROLLBACK');
      raise;
    end;
  finally
    LQuery.Free;
  end;
end;

// Certificado digital: o PFX vive em disco (ARQUIVO_CERTIFICADO), extraido do
// BLOB msfilial.certificado_digital na abertura do app. Se o arquivo sumir
// (limpeza de disco, restore, troca de maquina) a NFCe para de assinar. A carga
// geral confere a existencia e rebaixa o certificado quando nao encontra.
procedure TSincronizador.SincronizarCertificado(AConn: TUniConnection);
var
  LQuery: TUniQuery;
  LBlobStream: TStream;
  LFileStream: TFileStream;
  LCodFilial, LSenha: string;
begin
  LCodFilial := FSQLite.ObterEstado(KEY_CODFILIAL, '');
  if LCodFilial = '' then
  begin
    SyncLog('  certificado: CODFILIAL nao definido - etapa ignorada');
    Exit;
  end;

  // Arquivo presente e nao vazio: nada a renovar
  if FileExists(ARQUIVO_CERTIFICADO) and (TFile.GetSize(ARQUIVO_CERTIFICADO) > 0) then
    Exit;

  SyncLog('  certificado: arquivo ausente/vazio (%s) - rebaixando do Oracle',
    [ARQUIVO_CERTIFICADO]);

  // Falha aqui nao pode abortar a carga geral: apenas registra no log
  try
    LQuery := TUniQuery.Create(nil);
    try
      LQuery.Connection := AConn;
      LQuery.SQL.Text :=
        'SELECT certificado_digital, senha_certificado FROM msfilial ' +
        'WHERE codfilial = :codfilial';
      LQuery.ParamByName('codfilial').AsString := LCodFilial;
      LQuery.Open;

      if LQuery.IsEmpty or LQuery.FieldByName('certificado_digital').IsNull then
      begin
        SyncLog('  certificado: msfilial.certificado_digital nulo para filial %s',
          [LCodFilial]);
        RegistrarLog('certificado', 'DOWNLOAD', LCodFilial, 'ERRO',
          'certificado_digital nulo no Oracle');
        Exit;
      end;

      LBlobStream := LQuery.CreateBlobStream(
        LQuery.FieldByName('certificado_digital'), bmRead);
      try
        if LBlobStream.Size <= 0 then
        begin
          SyncLog('  certificado: BLOB com 0 bytes para filial %s', [LCodFilial]);
          RegistrarLog('certificado', 'DOWNLOAD', LCodFilial, 'ERRO',
            'BLOB do certificado vazio');
          Exit;
        end;

        ForceDirectories(ExtractFilePath(ARQUIVO_CERTIFICADO));
        LFileStream := TFileStream.Create(ARQUIVO_CERTIFICADO, fmCreate);
        try
          LFileStream.CopyFrom(LBlobStream, LBlobStream.Size);
        finally
          LFileStream.Free;
        end;
        SyncLog('  certificado: gravado %s (%d bytes)',
          [ARQUIVO_CERTIFICADO, LBlobStream.Size]);
      finally
        LBlobStream.Free;
      end;

      // A senha do PFX pode ter mudado junto com o certificado
      LSenha := LQuery.FieldByName('senha_certificado').AsString;
      FSQLite.SalvarEstado('SENHA_CERTIFICADO', LSenha);

      // Sinaliza para o form recarregar o ACBr com o certificado novo
      FCertificadoRenovado := True;
      RegistrarLog('certificado', 'DOWNLOAD', LCodFilial, 'OK');
    finally
      LQuery.Free;
    end;
  except
    on E: Exception do
    begin
      SyncLog('  certificado: ERRO ao rebaixar - %s', [E.Message]);
      RegistrarLog('certificado', 'DOWNLOAD', LCodFilial, 'ERRO', E.Message);
    end;
  end;
end;

// =========================================================================
// UPLOAD (SQLite -> Oracle)
// =========================================================================

{ Traduz o codcob interno do PDV para a cobranca do ERP.

  O PDV usa codigos proprios na tela (01 dinheiro, 02 cheque, 03 cartao TEF,
  17 PIX, 99 POS), mas msapolo_venda_pagto e' tabela de retaguarda: o que vai
  para MSPARCELAS.codcob tem que ser codigo do MSCOB.

  Credito x debito sai de codtipotransacao (1=credito, 2=debito), gravado pela
  tela tanto no TEF quanto no POS.

  A aba Cobranca (Cobrancas Adicionais) ja envia o codcob do proprio cadastro
  msapolo_meiopagto, entao passa direto. }
function TSincronizador.CodCobERP(const ACodCobPdv: string;
  ACodTipoTransacao: Integer): string;
var
  LCod: string;
begin
  LCod := Trim(ACodCobPdv);

  if LCod = '01' then Exit('D');       // dinheiro
  if LCod = '02' then Exit('CH');      // cheque
  if LCod = '17' then Exit('PIX');     // TEF PIX

  if LCod = '03' then                  // TEF cartao
  begin
    if ACodTipoTransacao = 2 then Exit('CDEBT');
    Exit('CCRED');
  end;

  if LCod = '99' then                  // POS (maquineta nao integrada)
  begin
    if ACodTipoTransacao = 2 then Exit('POSD');
    Exit('POSC');
  end;

  // Demais: o codcob ja veio do cadastro de cobrancas adicionais
  Result := LCod;
end;

function TSincronizador.NumTransVendaNoOracle(AConn: TUniConnection;
  ACupom: TUniQuery): Int64;
var
  LQ: TUniQuery;
begin
  Result := 0;
  LQ := TUniQuery.Create(nil);
  try
    LQ.Connection := AConn;
    LQ.SQL.Text :=
      'SELECT MAX(numtrans) FROM msapolo_venda ' +
      ' WHERE codfilial = :codfilial AND numcaixa = :numcaixa ' +
      '   AND numcupom = :numcupom AND datamovto = :datamovto';
    LQ.ParamByName('codfilial').AsString := ACupom.FieldByName('codfilial').AsString;
    LQ.ParamByName('numcaixa').AsInteger := ACupom.FieldByName('numcaixa').AsInteger;
    LQ.ParamByName('numcupom').AsInteger := ACupom.FieldByName('numcupom').AsInteger;
    LQ.ParamByName('datamovto').AsString := ACupom.FieldByName('datamovto').AsString;
    LQ.Open;
    if not LQ.Fields[0].IsNull then
      Result := LQ.Fields[0].AsLargeInt;
  finally
    LQ.Free;
  end;
end;

procedure TSincronizador.UploadVenda(AConn: TUniConnection; ACupomId: Integer);
var
  LCupom, LItens, LPagtos: TUniQuery;
  LInsert: TUniQuery;
  LNumTrans: Int64;
  LSw: TStopwatch;
  LQtdItens, LQtdPagtos: Integer;
  LTemQtUnit: Boolean;
begin
  if not AConn.Connected then Exit;
  LSw := TStopwatch.StartNew;
  LQtdItens := 0;
  LQtdPagtos := 0;

  try
    // Ler cupom do SQLite. sincronizado = 0 evita duplicar em msapolo_venda
    // quando o upload imediato (fim da venda) e o retry se cruzam.
    LCupom := FSQLite.ExecutarSelect(
      'SELECT * FROM cupons WHERE id = ' + IntToStr(ACupomId) +
      ' AND sincronizado = 0'
    );
    try
      if LCupom.IsEmpty then Exit;

      // O Commit no Oracle e a marcacao sincronizado=1 no SQLite nao sao
      // atomicos. Caindo entre os dois (SQLite travado, queda de energia,
      // app morto), o cupom continua sincronizado=0 e o ciclo seguinte
      // inseria a MESMA venda outra vez, com outro numtrans - duplicata no
      // ERP que so' aparece na conferencia. Ja estando la, completa a
      // marcacao local e sai.
      LNumTrans := NumTransVendaNoOracle(AConn, LCupom);
      if LNumTrans > 0 then
      begin
        FSQLite.ExecutarSQL(
          'UPDATE cupons SET sincronizado = 1, numtrans = ' + IntToStr(LNumTrans) + ', ' +
          'dt_sincronizacao = datetime(''now'',''localtime'') ' +
          'WHERE id = ' + IntToStr(ACupomId)
        );
        SyncLog('UPLOAD venda cupom=%d: ja estava no Oracle (numtrans=%d), ' +
          'so completou a marcacao local', [ACupomId, LNumTrans]);
        Exit;
      end;

      // Iniciar transacao no Oracle
      AConn.StartTransaction;
      try
        // Inserir cabecalho no Oracle (msapolo_venda)
        LInsert := TUniQuery.Create(nil);
        try
          LInsert.Connection := AConn;

          // Obter proximo numtrans da sequence Oracle
          LInsert.SQL.Text := 'SELECT msapolo_venda_seq.NEXTVAL FROM DUAL';
          LInsert.Open;
          LNumTrans := LInsert.Fields[0].AsLargeInt;
          LInsert.Close;

          // Inserir cabecalho
          LInsert.SQL.Text :=
            'INSERT INTO msapolo_venda (numtrans, codfilial, numcaixa, numcupom, ' +
            'codoper, datamovto, dthriniciovenda, dthrfimvenda, ' +
            'codoperador, codsupervisor, codcli, cpf_cnpj, descnomecliente, ' +
            'qtdeitens, valorvenda, valordesc, valorencargo, valortroco, ' +
            'chavenfe, protocolo_nfe, numserieequip, versao, ' +
            'tipo_contingencia, dt_contingencia, contingencia_justificativa) ' +
            'VALUES (:numtrans, :codfilial, :numcaixa, :numcupom, ' +
            ':codoper, :datamovto, :dthriniciovenda, :dthrfimvenda, ' +
            ':codoperador, :codsupervisor, :codcli, :cpf_cnpj, :descnomecliente, ' +
            ':qtdeitens, :valorvenda, :valordesc, :valorencargo, :valortroco, ' +
            ':chavenfe, :protocolo_nfe, :numserieequip, :versao, ' +
            ':tipo_contingencia, :dt_contingencia, :contingencia_justificativa)';

          LInsert.ParamByName('numtrans').AsLargeInt := LNumTrans;
          LInsert.ParamByName('codfilial').AsString := LCupom.FieldByName('codfilial').AsString;
          LInsert.ParamByName('numcaixa').AsInteger := LCupom.FieldByName('numcaixa').AsInteger;
          LInsert.ParamByName('numcupom').AsInteger := LCupom.FieldByName('numcupom').AsInteger;
          LInsert.ParamByName('codoper').AsString := LCupom.FieldByName('codoper').AsString;
          LInsert.ParamByName('datamovto').AsString := LCupom.FieldByName('datamovto').AsString;
          LInsert.ParamByName('dthriniciovenda').AsString := LCupom.FieldByName('dthriniciovenda').AsString;
          LInsert.ParamByName('dthrfimvenda').AsString := LCupom.FieldByName('dthrfimvenda').AsString;
          LInsert.ParamByName('codoperador').AsInteger := LCupom.FieldByName('codoperador').AsInteger;
          LInsert.ParamByName('codsupervisor').AsInteger := LCupom.FieldByName('codsupervisor').AsInteger;
          LInsert.ParamByName('codcli').AsInteger := LCupom.FieldByName('codcli').AsInteger;
          LInsert.ParamByName('cpf_cnpj').AsString := LCupom.FieldByName('cpf_cnpj').AsString;
          LInsert.ParamByName('descnomecliente').AsString := LCupom.FieldByName('descnomecliente').AsString;
          LInsert.ParamByName('qtdeitens').AsInteger := LCupom.FieldByName('qtdeitens').AsInteger;
          LInsert.ParamByName('valorvenda').AsFloat := LCupom.FieldByName('valorvenda').AsFloat;
          LInsert.ParamByName('valordesc').AsFloat := LCupom.FieldByName('valordesc').AsFloat;
          LInsert.ParamByName('valorencargo').AsFloat := LCupom.FieldByName('valorencargo').AsFloat;
          LInsert.ParamByName('valortroco').AsFloat := LCupom.FieldByName('valortroco').AsFloat;
          LInsert.ParamByName('chavenfe').AsString := LCupom.FieldByName('chavenfe').AsString;
          LInsert.ParamByName('protocolo_nfe').AsString := LCupom.FieldByName('protocolo_nfe').AsString;
          LInsert.ParamByName('numserieequip').AsString := LCupom.FieldByName('numserieequip').AsString;
          LInsert.ParamByName('versao').AsString := LCupom.FieldByName('versao').AsString;
          LInsert.ParamByName('tipo_contingencia').AsString := LCupom.FieldByName('tipo_contingencia').AsString;
          LInsert.ParamByName('dt_contingencia').AsString := LCupom.FieldByName('dt_contingencia').AsString;
          LInsert.ParamByName('contingencia_justificativa').AsString := LCupom.FieldByName('contingencia_justificativa').AsString;
          LInsert.Execute;

          // Inserir itens
          LItens := FSQLite.ExecutarSelect(
            'SELECT * FROM cupom_itens WHERE cupom_id = ' + IntToStr(ACupomId)
          );
          try
            // QTUNIT pode ainda nao existir na msapolo_venda_item da
            // retaguarda; nesse caso o upload segue sem a coluna
            LTemQtUnit := OracleTemColuna(AConn, 'msapolo_venda_item', 'qtunit');

            // SQL fixo: atribuir UMA vez fora do loop (dentro do loop forca
            // re-parse/re-prepare a cada item)
            LInsert.SQL.Text :=
              'INSERT INTO msapolo_venda_item (numtrans, numseqitem, codprod, codbarra, ' +
              'descricao, unidade, qt, punit, vlprod, vldesconto, ' +
              'ncm, cfop, cest, icms_cst, csosn, aliqicms, ' +
              'pis_cst, cofins_cst, aliqpis, aliqcofins, ' +
              'codvendedor, dtcancel, obscancel, emoferta, ptabela, prod_origem' +
              IfThen(LTemQtUnit, ', qtunit', '') + ') ' +
              'VALUES (:numtrans, :numseqitem, :codprod, :codbarra, ' +
              ':descricao, :unidade, :qt, :punit, :vlprod, :vldesconto, ' +
              ':ncm, :cfop, :cest, :icms_cst, :csosn, :aliqicms, ' +
              ':pis_cst, :cofins_cst, :aliqpis, :aliqcofins, ' +
              ':codvendedor, :dtcancel, :obscancel, :emoferta, :ptabela, :prod_origem' +
              IfThen(LTemQtUnit, ', :qtunit', '') + ')';
            while not LItens.Eof do
            begin
              LInsert.ParamByName('numtrans').AsLargeInt := LNumTrans;
              LInsert.ParamByName('numseqitem').AsInteger := LItens.FieldByName('numseqitem').AsInteger;
              LInsert.ParamByName('codprod').AsLargeInt := LItens.FieldByName('codprod').AsLargeInt;
              LInsert.ParamByName('codbarra').AsString := LItens.FieldByName('codbarra').AsString;
              LInsert.ParamByName('descricao').AsString := LItens.FieldByName('descricao').AsString;
              LInsert.ParamByName('unidade').AsString := LItens.FieldByName('unidade').AsString;
              LInsert.ParamByName('qt').AsFloat := LItens.FieldByName('qt').AsFloat;
              LInsert.ParamByName('punit').AsFloat := LItens.FieldByName('punit').AsFloat;
              LInsert.ParamByName('vlprod').AsFloat := LItens.FieldByName('vlprod').AsFloat;
              LInsert.ParamByName('vldesconto').AsFloat := LItens.FieldByName('vldesconto').AsFloat;
              LInsert.ParamByName('ncm').AsString := LItens.FieldByName('ncm').AsString;
              LInsert.ParamByName('cfop').AsString := LItens.FieldByName('cfop').AsString;
              LInsert.ParamByName('cest').AsString := LItens.FieldByName('cest').AsString;
              LInsert.ParamByName('icms_cst').AsString := LItens.FieldByName('icms_cst').AsString;
              LInsert.ParamByName('csosn').AsString := LItens.FieldByName('csosn').AsString;
              LInsert.ParamByName('aliqicms').AsFloat := LItens.FieldByName('aliqicms').AsFloat;
              LInsert.ParamByName('pis_cst').AsString := LItens.FieldByName('pis_cst').AsString;
              LInsert.ParamByName('cofins_cst').AsString := LItens.FieldByName('cofins_cst').AsString;
              LInsert.ParamByName('aliqpis').AsFloat := LItens.FieldByName('aliqpis').AsFloat;
              LInsert.ParamByName('aliqcofins').AsFloat := LItens.FieldByName('aliqcofins').AsFloat;
              LInsert.ParamByName('codvendedor').AsInteger := LItens.FieldByName('codvendedor').AsInteger;
              LInsert.ParamByName('dtcancel').AsString := LItens.FieldByName('dtcancel').AsString;
              LInsert.ParamByName('obscancel').AsString := LItens.FieldByName('obscancel').AsString;
              LInsert.ParamByName('emoferta').AsString := LItens.FieldByName('emoferta').AsString;
              LInsert.ParamByName('ptabela').AsFloat := LItens.FieldByName('ptabela').AsFloat;
              LInsert.ParamByName('prod_origem').AsString := LItens.FieldByName('prod_origem').AsString;
              if LTemQtUnit then
                LInsert.ParamByName('qtunit').AsFloat := LItens.FieldByName('qtunit').AsFloat;
              LInsert.Execute;
              Inc(LQtdItens);
              LItens.Next;
            end;
          finally
            LItens.Free;
          end;

          // Inserir pagamentos
          LPagtos := FSQLite.ExecutarSelect(
            'SELECT * FROM cupom_pagamentos WHERE cupom_id = ' + IntToStr(ACupomId)
          );
          try
            LInsert.SQL.Text :=
              'INSERT INTO msapolo_venda_pagto (numtrans, codcob, valor, ' +
              'numbanco, numagencia, numcontacorrente, numcheque, numcmc7, ' +
              'cpf_cnpj_cheque, dtpredatado, ' +
              'codtipotransacao, codmodotransacao, codbandeira, codrede, ' +
              'codautorizacao, nsu, numparcela, qtdeparcela, codplpag, dtvenc) ' +
              'VALUES (:numtrans, :codcob, :valor, ' +
              ':numbanco, :numagencia, :numcontacorrente, :numcheque, :numcmc7, ' +
              ':cpf_cnpj_cheque, :dtpredatado, ' +
              ':codtipotransacao, :codmodotransacao, :codbandeira, :codrede, ' +
              ':codautorizacao, :nsu, :numparcela, :qtdeparcela, :codplpag, :dtvenc)';
            while not LPagtos.Eof do
            begin
              LInsert.ParamByName('numtrans').AsLargeInt := LNumTrans;
              LInsert.ParamByName('codcob').AsString := CodCobERP(
                LPagtos.FieldByName('codcob').AsString,
                LPagtos.FieldByName('codtipotransacao').AsInteger);
              LInsert.ParamByName('valor').AsFloat := LPagtos.FieldByName('valor').AsFloat;
              LInsert.ParamByName('numbanco').AsInteger := LPagtos.FieldByName('numbanco').AsInteger;
              LInsert.ParamByName('numagencia').AsString := LPagtos.FieldByName('numagencia').AsString;
              LInsert.ParamByName('numcontacorrente').AsString := LPagtos.FieldByName('numcontacorrente').AsString;
              LInsert.ParamByName('numcheque').AsString := LPagtos.FieldByName('numcheque').AsString;
              LInsert.ParamByName('numcmc7').AsString := LPagtos.FieldByName('numcmc7').AsString;
              LInsert.ParamByName('cpf_cnpj_cheque').AsString := LPagtos.FieldByName('cpf_cnpj_cheque').AsString;
              LInsert.ParamByName('dtpredatado').AsString := LPagtos.FieldByName('dtpredatado').AsString;
              LInsert.ParamByName('codtipotransacao').AsInteger := LPagtos.FieldByName('codtipotransacao').AsInteger;
              LInsert.ParamByName('codmodotransacao').AsInteger := LPagtos.FieldByName('codmodotransacao').AsInteger;
              LInsert.ParamByName('codbandeira').AsInteger := LPagtos.FieldByName('codbandeira').AsInteger;
              LInsert.ParamByName('codrede').AsInteger := LPagtos.FieldByName('codrede').AsInteger;
              LInsert.ParamByName('codautorizacao').AsString := LPagtos.FieldByName('codautorizacao').AsString;
              LInsert.ParamByName('nsu').AsString := LPagtos.FieldByName('nsu').AsString;
              LInsert.ParamByName('numparcela').AsInteger := LPagtos.FieldByName('numparcela').AsInteger;
              LInsert.ParamByName('qtdeparcela').AsInteger := LPagtos.FieldByName('qtdeparcela').AsInteger;
              LInsert.ParamByName('codplpag').AsInteger := LPagtos.FieldByName('codplpag').AsInteger;
              LInsert.ParamByName('dtvenc').AsString := LPagtos.FieldByName('dtvenc').AsString;
              LInsert.Execute;
              Inc(LQtdPagtos);
              LPagtos.Next;
            end;
          finally
            LPagtos.Free;
          end;
        finally
          LInsert.Free;
        end;

        AConn.Commit;
      except
        AConn.Rollback;
        raise;
      end;

      // Daqui para baixo a venda JA esta commitada no Oracle: nada mais pode
      // cair no except acima, que faria Rollback depois do Commit e deixaria
      // o cupom com sincronizado=0 - marcado para subir de novo.

      // Marcar como sincronizado no SQLite. numtrans guarda o numero que a
      // msapolo_venda recebeu - e' por ele que da' para achar a venda no
      // Oracle depois, quando a chave da NFCe finalmente existir.
      FSQLite.ExecutarSQL(
        'UPDATE cupons SET sincronizado = 1, numtrans = ' + IntToStr(LNumTrans) + ', ' +
        'dt_sincronizacao = datetime(''now'',''localtime'') ' +
        'WHERE id = ' + IntToStr(ACupomId)
      );

      RegistrarLog('cupons', 'UPLOAD', IntToStr(ACupomId), 'OK');
      SyncLog('UPLOAD venda cupom=%d numtrans=%d: %d itens + %d pagtos em %d ms',
        [ACupomId, LNumTrans, LQtdItens, LQtdPagtos, LSw.ElapsedMilliseconds]);

      // Backup da numeracao NFCe junto com a venda (ver EspelharProxNumNota).
      // Falhar aqui nao pode desfazer a venda nem impedir a marcacao acima.
      try
        EspelharProxNumNota(AConn);
      except
        on E: Exception do
          SyncLog('UPLOAD venda cupom=%d: espelho da numeracao falhou - [%s] %s',
            [ACupomId, E.ClassName, E.Message]);
      end;
    finally
      LCupom.Free;
    end;
  except
    on E: Exception do
    begin
      RegistrarLog('cupons', 'UPLOAD', IntToStr(ACupomId), 'ERRO', E.Message);

      // ORA-02289 (sequence inexistente) / ORA-00942 (tabela ou view
      // inexistente): a retaguarda nao tem msapolo_venda_seq nem as tabelas
      // msapolo_venda/_item/_pagto. Repetir a cada 5 min so enche o log; o
      // cupom continua com sincronizado = 0 e sobe assim que o DBA criar.
      if (Pos('ORA-02289', E.Message) > 0) or (Pos('ORA-00942', E.Message) > 0) then
      begin
        FRetaguardaSemVenda := True;
        SyncLog('UPLOAD venda: retaguarda sem as tabelas/sequence de venda ' +
          '(%s). Uploads de venda SUSPENSOS ate o proximo start. ' +
          'Criar msapolo_venda, msapolo_venda_item, msapolo_venda_pagto e ' +
          'a sequence msapolo_venda_seq no schema do Oracle.',
          [Trim(Copy(E.Message, 1, 60))]);
      end
      else
        SyncLog('UPLOAD venda cupom=%d: ERRO em %d ms - %s',
          [ACupomId, LSw.ElapsedMilliseconds, E.Message]);
    end;
  end;
end;

{ Leva a chave da NFCe ate a msapolo_venda.

  A venda sobe no fim do cupom (DoFinalizarVenda), ANTES de a NFCe existir -
  de proposito, para o cupom chegar na retaguarda mesmo que a nota falhe. So
  que ate aqui ninguem voltava para preencher a chave depois da autorizacao, e
  a msapolo_venda ficava com chavenfe vazia para sempre. Como a MSAPOLO_GERAR_NF
  tira serie e numnota da chave, a MSNF saia com numnota 0.

  Casa pelo numtrans quando ele existe (gravado no upload). Cupom antigo, de
  antes dessa coluna, cai no trio codfilial+numcaixa+numcupom - o codfilial vai
  com LTRIM porque o PDV grava '01' e o Oracle guarda '1'.

  So preenche onde esta vazio: se a chave ja estiver la, nao reescreve. }
{ NFCe canceladas -> retaguarda.

  Sao dois registros: a msapolo_venda passa a codoper='C', para o ERP parar de
  faturar a venda, e a msdoceletronico recebe o procEventoNFe com tipo='C', que
  e o comprovante do cancelamento. So marca cancel_enviado depois dos dois, e
  cada cupom vai em seu proprio try: uma retaguarda sem a coluna ou sem a
  tabela nao pode travar a fila inteira. }
procedure TSincronizador.UploadCancelamentos(AConn: TUniConnection);
const
  MAX_POR_CICLO = 50;
var
  LCupons, LQry: TUniQuery;
  LStream: TStringStream;
  LWhere, LChave, LXml: string;
  LCupomId, LQtd: Integer;
  LNumTrans: Double;
begin
  if not AConn.Connected then Exit;

  LCupons := FSQLite.ExecutarSelect(
    'SELECT id, numtrans, numcaixa, codfilial, numcupom, numnota, chavenfe, ' +
    'xml_cancelamento, dthr_cancelamento ' +
    'FROM cupons ' +
    'WHERE cancelada = 1 AND cancel_enviado = 0 ' +
    'ORDER BY id LIMIT ' + IntToStr(MAX_POR_CICLO)
  );
  try
    if LCupons.IsEmpty then Exit;

    LQtd := 0;
    LQry := TUniQuery.Create(nil);
    try
      LQry.Connection := AConn;

      while not LCupons.Eof do
      begin
        LCupomId := LCupons.FieldByName('id').AsInteger;
        LChave := Trim(LCupons.FieldByName('chavenfe').AsString);
        LXml := LCupons.FieldByName('xml_cancelamento').AsString;

        // Mesma chave de localizacao do AtualizarChavesNoOracle: numtrans
        // quando existe, senao filial+caixa+cupom (LTRIM porque o PDV grava
        // '01' e o Oracle guarda '1').
        if LCupons.FieldByName('numtrans').AsLargeInt > 0 then
          LWhere := 'numtrans = :numtrans'
        else
          LWhere := 'LTRIM(codfilial, ''0'') = LTRIM(:codfilial, ''0'') ' +
                    'AND numcaixa = :numcaixa AND numcupom = :numcupom';

        try
          // 1. Marcar a venda como cancelada
          LQry.SQL.Text :=
            'UPDATE msapolo_venda SET codoper = ''C'' WHERE ' + LWhere;
          if LCupons.FieldByName('numtrans').AsLargeInt > 0 then
            LQry.ParamByName('numtrans').AsLargeInt := LCupons.FieldByName('numtrans').AsLargeInt
          else
          begin
            LQry.ParamByName('codfilial').AsString := LCupons.FieldByName('codfilial').AsString;
            LQry.ParamByName('numcaixa').AsInteger := LCupons.FieldByName('numcaixa').AsInteger;
            LQry.ParamByName('numcupom').AsInteger := LCupons.FieldByName('numcupom').AsInteger;
          end;
          LQry.Execute;
          if AConn.InTransaction then
            AConn.CommitRetaining;

          // 2. Gravar o evento de cancelamento (acessorio: se o XML nao veio,
          //    a venda ja foi marcada e o cupom nao pode ficar rodando eterno)
          if (LXml <> '') and (LChave <> '') then
          begin
            LQry.SQL.Text :=
              'SELECT COUNT(*) QTD FROM msdoceletronico ' +
              'WHERE chavenfe = :chavenfe AND tipo = ''C''';
            LQry.ParamByName('chavenfe').AsString := LChave;
            LQry.Open;
            if LQry.FieldByName('QTD').AsInteger = 0 then
            begin
              LQry.Close;

              LQry.SQL.Text := 'SELECT SEQ_PROX_NUMTRANS_MOV.nextval FROM DUAL';
              LQry.Open;
              LNumTrans := LQry.Fields[0].AsFloat;
              LQry.Close;

              LQry.SQL.Text :=
                'INSERT INTO msdoceletronico (numtrans, xml_nfe, tipo, data, ' +
                'chavenfe, numnota, dtemissao, dtenvio) ' +
                'VALUES (:numtrans, :xml_nfe, ''C'', SYSDATE, ' +
                ':chavenfe, :numnota, SYSDATE, SYSDATE)';
              LQry.ParamByName('numtrans').AsFloat := LNumTrans;
              LQry.ParamByName('chavenfe').AsString := LChave;
              LQry.ParamByName('numnota').AsInteger :=
                Trunc(LCupons.FieldByName('numnota').AsFloat);
              LQry.ParamByName('xml_nfe').ParamType := ptInput;
              LQry.ParamByName('xml_nfe').DataType := ftOraClob;
              LStream := TStringStream.Create(LXml, TEncoding.UTF8);
              try
                LQry.ParamByName('xml_nfe').LoadFromStream(LStream, ftOraClob);
              finally
                LStream.Free;
              end;
              LQry.ExecSQL;
              if AConn.InTransaction then
                AConn.CommitRetaining;
            end
            else
              LQry.Close;
          end;

          FSQLite.ExecutarSQL(
            'UPDATE cupons SET cancel_enviado = 1 WHERE id = ' + IntToStr(LCupomId));
          Inc(LQtd);
          RegistrarLog('cancelamento', 'UPLOAD', IntToStr(LCupomId), 'OK', LChave);
        except
          on E: Exception do
          begin
            SyncLog('CANCEL upload cupom=%d chave=%s: [%s] %s',
              [LCupomId, LChave, E.ClassName, E.Message]);
            RegistrarLog('cancelamento', 'UPLOAD', IntToStr(LCupomId), 'ERRO',
              E.Message);
          end;
        end;

        LCupons.Next;
      end;
    finally
      LQry.Free;
    end;

    if LQtd > 0 then
      SyncLog('CANCEL: %d cancelamento(s) enviado(s) para a retaguarda', [LQtd]);
  finally
    LCupons.Free;
  end;
end;

procedure TSincronizador.AtualizarChavesNoOracle(AConn: TUniConnection);
const
  MAX_POR_CICLO = 200;
var
  LCupons, LQry: TUniQuery;
  LSw: TStopwatch;
  LWhere: string;
  LQtd: Integer;
begin
  if not AConn.Connected then Exit;
  if FRetaguardaSemVenda then Exit;

  LQtd := 0;
  LSw := TStopwatch.StartNew;

  LCupons := FSQLite.ExecutarSelect(
    'SELECT id, numtrans, numcaixa, codfilial, numcupom, chavenfe, protocolo_nfe ' +
    'FROM cupons ' +
    'WHERE sincronizado = 1 AND chave_enviada = 0 ' +
    '  AND COALESCE(chavenfe, '''') <> '''' ' +
    'ORDER BY id LIMIT ' + IntToStr(MAX_POR_CICLO)
  );
  try
    if LCupons.IsEmpty then Exit;

    LQry := TUniQuery.Create(nil);
    try
      LQry.Connection := AConn;

      while not LCupons.Eof do
      begin
        if LCupons.FieldByName('numtrans').AsLargeInt > 0 then
          LWhere := 'numtrans = :numtrans'
        else
          LWhere := 'LTRIM(codfilial, ''0'') = LTRIM(:codfilial, ''0'') ' +
                    'AND numcaixa = :numcaixa AND numcupom = :numcupom';

        try
          LQry.SQL.Text :=
            // Sobrescreve tambem quando a retaguarda esta com chave SEM
            // protocolo: e a chave de uma nota que o SEFAZ negou. Quando a
            // nota e regerada (mesmo numero, chave nova), sem isto o ERP
            // ficava amarrado para sempre a chave que nunca foi autorizada.
            // Linha ja autorizada (chave E protocolo) nao e tocada.
            'UPDATE msapolo_venda SET chavenfe = :chavenfe, ' +
            'protocolo_nfe = :protocolo WHERE ' + LWhere +
            ' AND (NVL(TRIM(chavenfe), ''x'') = ''x''' +
            '      OR NVL(TRIM(protocolo_nfe), ''x'') = ''x'')';
          LQry.ParamByName('chavenfe').AsString := LCupons.FieldByName('chavenfe').AsString;
          LQry.ParamByName('protocolo').AsString := LCupons.FieldByName('protocolo_nfe').AsString;
          if LCupons.FieldByName('numtrans').AsLargeInt > 0 then
            LQry.ParamByName('numtrans').AsLargeInt := LCupons.FieldByName('numtrans').AsLargeInt
          else
          begin
            LQry.ParamByName('codfilial').AsString := LCupons.FieldByName('codfilial').AsString;
            LQry.ParamByName('numcaixa').AsInteger := LCupons.FieldByName('numcaixa').AsInteger;
            LQry.ParamByName('numcupom').AsInteger := LCupons.FieldByName('numcupom').AsInteger;
          end;
          LQry.Execute;
          // Com AutoCommit (default) o Execute ja commitou. Commit aqui
          // lancaria "Can't perform operation on inactive transaction" -
          // mesma armadilha ja documentada em AtualizarDataSincCaixa.
          if AConn.InTransaction then
            AConn.CommitRetaining;

          if LQry.RowsAffected > 0 then
            Inc(LQtd);

          // RowsAffected = 0 tem duas causas: a venda ainda nao subiu (tenta
          // no proximo ciclo) ou a chave ja estava la (nada a fazer). So o
          // segundo caso pode ser marcado, senao o cupom fica rodando eterno.
          LQry.SQL.Text :=
            'SELECT COUNT(*) QTD FROM msapolo_venda WHERE ' + LWhere +
            ' AND NVL(TRIM(chavenfe), ''x'') <> ''x''';
          if LCupons.FieldByName('numtrans').AsLargeInt > 0 then
            LQry.ParamByName('numtrans').AsLargeInt := LCupons.FieldByName('numtrans').AsLargeInt
          else
          begin
            LQry.ParamByName('codfilial').AsString := LCupons.FieldByName('codfilial').AsString;
            LQry.ParamByName('numcaixa').AsInteger := LCupons.FieldByName('numcaixa').AsInteger;
            LQry.ParamByName('numcupom').AsInteger := LCupons.FieldByName('numcupom').AsInteger;
          end;
          LQry.Open;
          if LQry.FieldByName('QTD').AsInteger > 0 then
          begin
            FSQLite.ExecutarSQL(
              'UPDATE cupons SET chave_enviada = 1 WHERE id = ' +
              IntToStr(LCupons.FieldByName('id').AsInteger)
            );
          end;
          LQry.Close;
        except
          on E: Exception do
          begin
            if AConn.InTransaction then
              AConn.Rollback;
            SyncLog('CHAVE venda cupom=%d: ERRO - %s',
              [LCupons.FieldByName('numcupom').AsInteger,
               Trim(Copy(E.Message, 1, 120))]);
          end;
        end;

        LCupons.Next;
      end;
    finally
      LQry.Free;
    end;
  finally
    LCupons.Free;
  end;

  if LQtd > 0 then
    SyncLog('CHAVE: %d chave(s) de NFCe gravada(s) na msapolo_venda em %d ms',
      [LQtd, LSw.ElapsedMilliseconds]);
end;

procedure TSincronizador.ProcessarPendentes(AConn: TUniConnection);
var
  LSw: TStopwatch;
  LPend: Variant;
begin
  if FSincronizando then Exit;
  if not AConn.Connected then Exit;

  FSincronizando := True;
  LSw := TStopwatch.StartNew;
  try
    LPend := FSQLite.ExecutarScalar(
      'SELECT COUNT(*) FROM cupons WHERE sincronizado = 0 AND codoper = ''V''');
    if (not VarIsNull(LPend)) and (Integer(LPend) > 0) then
      SyncLog('PENDENTES: %d venda(s) aguardando upload', [Integer(LPend)]);

    EnviarVendasPendentes(AConn);
    AtualizarChavesNoOracle(AConn);
    UploadCancelamentos(AConn);
    EnviarDocEletronicosPendentes(AConn);
    EnviarNumerarioPendente(AConn);

    if (not VarIsNull(LPend)) and (Integer(LPend) > 0) then
      SyncLog('PENDENTES: ciclo concluido em %d ms', [LSw.ElapsedMilliseconds]);
  finally
    FSincronizando := False;
  end;
end;

procedure TSincronizador.EnviarVendasPendentes(AConn: TUniConnection);
const
  TAM_LOTE = 20;
  MAX_POR_CICLO = 500;  // trava de seguranca: nao prender o caixa a noite toda
var
  LQuery: TUniQuery;
  LEnviados, LNoLote, LUltimoId: Integer;
begin
  if FRetaguardaSemVenda then Exit;

  // Drenar a fila em lotes, e nao 10 por ciclo: com o retry a cada 5 min um
  // acumulo de 74 vendas levava mais de meia hora para chegar na retaguarda
  LEnviados := 0;
  LUltimoId := 0;
  repeat
    LNoLote := 0;

    // Avancar por id (id > LUltimoId) em vez de repetir o mesmo SELECT:
    // UploadVenda engole o erro e deixa sincronizado = 0, entao um cupom que
    // falha voltaria no lote seguinte e prenderia o laco. Quem falhou fica
    // para o proximo ciclo de retry.
    LQuery := FSQLite.ExecutarSelect(
      'SELECT id FROM cupons WHERE sincronizado = 0 AND codoper = ''V'' ' +
      'AND id > ' + IntToStr(LUltimoId) + ' ORDER BY id LIMIT ' + IntToStr(TAM_LOTE)
    );
    try
      while not LQuery.Eof do
      begin
        LUltimoId := LQuery.FieldByName('id').AsInteger;
        UploadVenda(AConn, LUltimoId);
        Inc(LNoLote);
        Inc(LEnviados);
        LQuery.Next;
      end;
    finally
      LQuery.Free;
    end;

    if FRetaguardaSemVenda then Break;
    if LNoLote < TAM_LOTE then Break;
    if LEnviados >= MAX_POR_CICLO then
    begin
      SyncLog('UPLOAD venda: %d no ciclo (limite). O resto vai no proximo retry.',
        [LEnviados]);
      Break;
    end;
  until False;
end;

function TSincronizador.MontarXmlCupom(ACupomId: Integer;NumTrans:Double): string;
var
  LCupom, LItens, LPagtos: TUniQuery;
  LSB: TStringBuilder;

  function Attr(const ANome, AValor: string): string;
  begin
    Result := ' ' + ANome + '="' + AValor + '"';
  end;

  function AttrInt(const ANome: string; AValor: Integer): string;
  begin
    Result := ' ' + ANome + '="' + IntToStr(AValor) + '"';
  end;

  function AttrFloat(const ANome: string; AValor: Double): string;
  begin
    Result := ' ' + ANome + '="' + FormatFloat('0.00', AValor) + '"';
  end;

  function FieldStr(AQuery: TUniQuery; const AField: string): string;
  begin
    Result := AQuery.FieldByName(AField).AsString;
  end;

  function FieldInt(AQuery: TUniQuery; const AField: string): Integer;
  begin
    Result := AQuery.FieldByName(AField).AsInteger;
  end;

  function FieldFloat(AQuery: TUniQuery; const AField: string): Double;
  begin
    Result := AQuery.FieldByName(AField).AsFloat;
  end;

begin
  Result := '';
  LSB := TStringBuilder.Create;
  try
    // Ler cupom
    LCupom := FSQLite.ExecutarSelect(
      'SELECT * FROM cupons WHERE id = ' + IntToStr(ACupomId));
    try
      if LCupom.IsEmpty then Exit;

      // Header
      LSB.Append('<?xml version="1.0" encoding="UTF-8"?>');
      LSB.Append('<cupom');
      LSB.Append(AttrInt('id', ACupomId));
      LSB.Append(Attr('codoper', FieldStr(LCupom, 'codoper')));
      LSB.Append(Attr('especie', FieldStr(LCupom, 'especie')));
      LSB.Append(AttrInt('numnota', Trunc(FieldFloat(LCupom, 'numnota'))));
      LSB.Append(AttrInt('numtrans', Trunc(numtrans)));
      LSB.Append(AttrInt('serienfce', FieldInt(LCupom, 'serienfce')));
      LSB.Append(Attr('codfilial', FieldStr(LCupom, 'codfilial')));
      LSB.Append(AttrInt('numcaixa', FieldInt(LCupom, 'numcaixa')));
      LSB.Append(Attr('datamovto', FieldStr(LCupom, 'datamovto')));
      LSB.Append(Attr('dthriniciovenda', FieldStr(LCupom, 'dthriniciovenda')));
      LSB.Append(Attr('dthrfimvenda', FieldStr(LCupom, 'dthrfimvenda')));
      LSB.Append(Attr('chavenfe', FieldStr(LCupom, 'chavenfe')));
      LSB.Append(Attr('protocolo_nfe', FieldStr(LCupom, 'protocolo_nfe')));
      LSB.Append(AttrFloat('valorvenda', FieldFloat(LCupom, 'valorvenda')));
      LSB.Append(AttrFloat('valordesc', FieldFloat(LCupom, 'valordesc')));
      LSB.Append(AttrFloat('valordescsubtotal', FieldFloat(LCupom, 'valordescsubtotal')));
      LSB.Append(AttrFloat('valorencargo', FieldFloat(LCupom, 'valorencargo')));
      LSB.Append(AttrFloat('valortroco', FieldFloat(LCupom, 'valortroco')));
      LSB.Append(AttrFloat('valorcancel', FieldFloat(LCupom, 'valorcancel')));
      LSB.Append(AttrFloat('valoracrescimo', FieldFloat(LCupom, 'valoracrescimo')));
      LSB.Append(AttrInt('qtdeitens', FieldInt(LCupom, 'qtdeitens')));
      LSB.Append(AttrInt('qtdeitemcancel', FieldInt(LCupom, 'qtdeitemcancel')));
      LSB.Append(AttrInt('numcupom', FieldInt(LCupom, 'numcupom')));
      LSB.Append(AttrInt('ccf', FieldInt(LCupom, 'ccf')));
      LSB.Append(Attr('obs', FieldStr(LCupom, 'obs')));
      LSB.Append(Attr('obscancel', FieldStr(LCupom, 'obscancel')));
      LSB.Append('>');

      // Consumidor
      LSB.Append('<consumidor');
      LSB.Append(Attr('cpf_cnpj', FieldStr(LCupom, 'cpf_cnpj')));
      LSB.Append(AttrInt('codcli', FieldInt(LCupom, 'codcli')));
      LSB.Append(Attr('nome', FieldStr(LCupom, 'descnomecliente')));
      LSB.Append('/>');

      // Usuarios
      LSB.Append('<usuarios');
      LSB.Append(AttrInt('operador', FieldInt(LCupom, 'codoperador')));
      LSB.Append(AttrInt('supervisor', FieldInt(LCupom, 'codsupervisor')));
      LSB.Append('/>');

      // Itens
      LSB.Append('<itens>');
      LItens := FSQLite.ExecutarSelect(
        'SELECT * FROM cupom_itens WHERE cupom_id = ' + IntToStr(ACupomId) +
        ' ORDER BY numseqitem');
      try
        while not LItens.Eof do
        begin
          LSB.Append('<item');
          LSB.Append(AttrInt('seq', FieldInt(LItens, 'numseqitem')));
          LSB.Append(AttrInt('codprod', FieldInt(LItens, 'codprod')));
          LSB.Append(Attr('codbarra', FieldStr(LItens, 'codbarra')));
          LSB.Append(Attr('descricao', FieldStr(LItens, 'descricao')));
          LSB.Append(Attr('unidade', FieldStr(LItens, 'unidade')));
          LSB.Append(AttrFloat('qt', FieldFloat(LItens, 'qt')));
          LSB.Append(AttrFloat('punit', FieldFloat(LItens, 'punit')));
          LSB.Append(AttrFloat('vlprod', FieldFloat(LItens, 'vlprod')));
          LSB.Append(AttrFloat('vldesconto', FieldFloat(LItens, 'vldesconto')));
          LSB.Append(AttrFloat('vldescitem', FieldFloat(LItens, 'vldescitem')));
          LSB.Append(AttrFloat('vldesc_atacado', FieldFloat(LItens, 'vldesc_atacado')));
          LSB.Append(AttrInt('codvendedor', FieldInt(LItens, 'codvendedor')));
          LSB.Append(AttrInt('codoperador', FieldInt(LItens, 'codoperador')));
          if FieldStr(LItens, 'dtcancel') <> '' then
            LSB.Append(Attr('cancelado', 'S'))
          else
            LSB.Append(Attr('cancelado', 'N'));
          LSB.Append(Attr('dtcancel', FieldStr(LItens, 'dtcancel')));
          LSB.Append(Attr('obscancel', FieldStr(LItens, 'obscancel')));
          LSB.Append(Attr('emoferta', FieldStr(LItens, 'emoferta')));
          LSB.Append(AttrFloat('ptabela', FieldFloat(LItens, 'ptabela')));
          LSB.Append('/>');
          LItens.Next;
        end;
      finally
        LItens.Free;
      end;
      LSB.Append('</itens>');

      // Pagamentos
      LSB.Append('<pagamentos>');
      LPagtos := FSQLite.ExecutarSelect(
        'SELECT * FROM cupom_pagamentos WHERE cupom_id = ' + IntToStr(ACupomId));
      try
        while not LPagtos.Eof do
        begin
          LSB.Append('<pagamento');
          LSB.Append(Attr('codcob', FieldStr(LPagtos, 'codcob')));
          LSB.Append(AttrFloat('valor', FieldFloat(LPagtos, 'valor')));
          LSB.Append(AttrInt('codbandeira', FieldInt(LPagtos, 'codbandeira')));
          LSB.Append(Attr('codautorizacao', FieldStr(LPagtos, 'codautorizacao')));
          LSB.Append(Attr('nsu', FieldStr(LPagtos, 'nsu')));
          LSB.Append(AttrInt('numparcela', FieldInt(LPagtos, 'numparcela')));
          LSB.Append(AttrInt('qtdeparcela', FieldInt(LPagtos, 'qtdeparcela')));
          LSB.Append(AttrFloat('valorparcela', FieldFloat(LPagtos, 'valorparcela')));
          LSB.Append(AttrInt('codplpag', FieldInt(LPagtos, 'codplpag')));
          LSB.Append('/>');
          LPagtos.Next;
        end;
      finally
        LPagtos.Free;
      end;
      LSB.Append('</pagamentos>');

      LSB.Append('</cupom>');
      Result := LSB.ToString;
    finally
      LCupom.Free;
    end;
  finally
    LSB.Free;
  end;
end;

procedure TSincronizador.UploadDocEletronico(AConn: TUniConnection; ACupomId: Integer);
var
  LCupom: TUniQuery;
  LInsert: TUniQuery;
  LNumTrans: TUniQuery;
  LChaveNFe, LXmlContent, LXmlCupom: string;
  LNumNota: Integer;
  LDtEmissao, LDtEnvio: string;
  LXmlPath: string;
  LStream: TStringStream;
  NumTrans: Double;
  LSw: TStopwatch;
begin
  if not AConn.Connected then Exit;
  LSw := TStopwatch.StartNew;

  try
    // Ler dados do cupom no SQLite
    LCupom := FSQLite.ExecutarSelect(
      'SELECT chavenfe, numnota, dthriniciovenda, dthrfimvenda ' +
      'FROM cupons WHERE id = ' + IntToStr(ACupomId)
    );
    try
      if LCupom.IsEmpty then Exit;

      LChaveNFe := LCupom.FieldByName('chavenfe').AsString;
      if LChaveNFe = '' then Exit;

      LNumNota := Trunc(LCupom.FieldByName('numnota').AsFloat);
      LDtEmissao := LCupom.FieldByName('dthriniciovenda').AsString;
      LDtEnvio := LCupom.FieldByName('dthrfimvenda').AsString;

      // Ler XML autorizado. LocalizarXmlNFCe cobre os nomes antigos (prefixo
      // 'NFe') e as notas que so existem na arvore do ACBr (NFC-e\XML\...)
      LXmlPath := LocalizarXmlNFCe(LChaveNFe);
      if LXmlPath = '' then
      begin
        RegistrarLog('doceletronico', 'UPLOAD', IntToStr(ACupomId), 'ERRO',
          'Arquivo XML nao encontrado em ' + PASTA_NFCE + ' para a chave ' + LChaveNFe);
        SyncLog('UPLOAD doceletronico cupom=%d: XML nao encontrado (chave %s)',
          [ACupomId, LChaveNFe]);
        Exit;
      end;

      LStream := TStringStream.Create('', TEncoding.UTF8);
      try
        LStream.LoadFromFile(LXmlPath);
        LXmlContent := LStream.DataString;
      finally
        LStream.Free;
      end;

      if LXmlContent = '' then
      begin
        RegistrarLog('doceletronico', 'UPLOAD', IntToStr(ACupomId), 'ERRO',
          'Arquivo XML vazio');
        Exit;
      end;

      LInsert := TUniQuery.Create(nil);
      try
        LInsert.Connection := AConn;

        // Verificar duplicidade pela chavenfe
        LInsert.SQL.Text :=
          'SELECT COUNT(*) QTD FROM msdoceletronico WHERE chavenfe = :chavenfe';
        LInsert.ParamByName('chavenfe').AsString := LChaveNFe;
        LInsert.Open;
        if LInsert.FieldByName('QTD').AsInteger > 0 then
        begin
          // Ja existe no Oracle, apenas marcar como enviado no SQLite
          FSQLite.ExecutarSQL(
            'UPDATE cupons SET doceletronico_enviado = 1 WHERE id = ' +
            IntToStr(ACupomId)
          );
          RegistrarLog('doceletronico', 'UPLOAD', IntToStr(ACupomId), 'OK',
            'Ja existia no Oracle');
          Exit;
        end;
        LInsert.Close;

        LNumTrans := TUniQuery.Create(nil);
        try
          LNumTrans.Connection := AConn;
          LNumTrans.SQL.Text:='SELECT SEQ_PROX_NUMTRANS_MOV.nextval FROM DUAL';
          LNumTrans.Open;
          NumTrans:=LNumTrans.Fields[0].AsFloat;
        finally
          LNumTrans.Close;
          LNumTrans.Free;
        end;


        // Inserir no Oracle
        LInsert.SQL.Text :=
          'INSERT INTO msdoceletronico (numtrans, xml_nfe, tipo, data, ' +
          'chavenfe, numnota, dtemissao, dtenvio) ' +
          'VALUES (:numtrans, :xml_nfe, ''P'', SYSDATE, ' +
          ':chavenfe, :numnota, ' +
          'TO_DATE(:dtemissao, ''YYYY-MM-DD HH24:MI:SS''), ' +
          'TO_DATE(:dtenvio, ''YYYY-MM-DD HH24:MI:SS''))';

        LInsert.ParamByName('numtrans').AsFloat := NumTrans;
        LInsert.ParamByName('chavenfe').AsString := LChaveNFe;
        LInsert.ParamByName('numnota').AsInteger := LNumNota;
        LInsert.ParamByName('dtemissao').AsString := LDtEmissao;
        LInsert.ParamByName('dtenvio').AsString := LDtEnvio;


        // XML como CLOB
        LInsert.ParamByName('xml_nfe').ParamType := ptInput;
        LInsert.ParamByName('xml_nfe').DataType := ftOraClob;
        LStream := TStringStream.Create(LXmlContent, TEncoding.UTF8);
        try
          LInsert.ParamByName('xml_nfe').LoadFromStream(LStream, ftOraClob);
        finally
          LStream.Free;
        end;

        LInsert.ExecSQL;

        // Marcar como enviado ANTES do log do cupom: o registro fiscal
        // (msdoceletronico) ja esta gravado. Deixar para depois fazia uma
        // falha no mslog_cupom reprocessar o cupom em todo ciclo de retry.
        FSQLite.ExecutarSQL(
          'UPDATE cupons SET doceletronico_enviado = 1 WHERE id = ' +
          IntToStr(ACupomId)
        );

        // Gravar log do cupom em MSLOG_CUPOM (acessorio: nem toda retaguarda
        // tem essa tabela, e a ausencia dela nao pode derrubar o upload fiscal)
        LXmlCupom := MontarXmlCupom(ACupomId,NumTrans);
        if LXmlCupom <> '' then
        begin
          try
            LInsert.SQL.Text :=
              'INSERT INTO mslog_cupom (numtrans, conteudo) VALUES (:numtrans, :conteudo)';
            LInsert.ParamByName('numtrans').AsFloat := NumTrans;
            LInsert.ParamByName('conteudo').ParamType := ptInput;
            LInsert.ParamByName('conteudo').DataType := ftOraClob;
            LStream := TStringStream.Create(LXmlCupom, TEncoding.UTF8);
            try
              LInsert.ParamByName('conteudo').LoadFromStream(LStream, ftOraClob);
            finally
              LStream.Free;
            end;
            LInsert.ExecSQL;
          except
            on E: Exception do
            begin
              RegistrarLog('mslog_cupom', 'UPLOAD', IntToStr(ACupomId), 'ERRO', E.Message);
              if not FAvisouMsLogCupom then
              begin
                FAvisouMsLogCupom := True;
                SyncLog('UPLOAD mslog_cupom: %s (aviso unico por sessao)', [E.Message]);
              end;
            end;
          end;
        end;

        RegistrarLog('doceletronico', 'UPLOAD', IntToStr(ACupomId), 'OK');
        SyncLog('UPLOAD doceletronico cupom=%d: XML %d KB (CLOB) em %d ms',
          [ACupomId, Length(LXmlContent) div 1024, LSw.ElapsedMilliseconds]);
      finally
        LInsert.Free;
      end;
    finally
      LCupom.Free;
    end;
  except
    on E: Exception do
    begin
      RegistrarLog('doceletronico', 'UPLOAD', IntToStr(ACupomId), 'ERRO', E.Message);
    end;
  end;
end;

procedure TSincronizador.EnviarDocEletronicosPendentes(AConn: TUniConnection);
var
  LQuery: TUniQuery;
begin
  // protocolo_nfe preenchido = nota autorizada, com XML em autorizadas\.
  // Cupom em contingencia ja tem chavenfe mas ainda nao tem XML autorizado:
  // so entra na fila depois que a retransmissao for aceita pelo SEFAZ.
  LQuery := FSQLite.ExecutarSelect(
    'SELECT id FROM cupons ' +
    'WHERE doceletronico_enviado = 0 ' +
    'AND chavenfe IS NOT NULL AND chavenfe <> '''' ' +
    'AND protocolo_nfe IS NOT NULL AND protocolo_nfe <> '''' ' +
    'AND codoper = ''V'' ' +
    'ORDER BY id LIMIT 10'
  );
  try
    while not LQuery.Eof do
    begin
      UploadDocEletronico(AConn, LQuery.FieldByName('id').AsInteger);
      LQuery.Next;
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TSincronizador.EnviarNumerarioPendente(AConn: TUniConnection);
var
  LQuery: TUniQuery;
  LInsert: TUniQuery;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT * FROM numerario WHERE sincronizado = 0 ORDER BY id LIMIT 20'
  );
  try
    LInsert := TUniQuery.Create(nil);
    try
      LInsert.Connection := AConn;
      LInsert.SQL.Text :=
        'INSERT INTO msapolo_numerario (codfilial, numcaixa, tipo, valor, ' +
        'dthora, codoperador, codsupervisor, motivo) ' +
        'VALUES (:codfilial, :numcaixa, :tipo, :valor, ' +
        'TO_DATE(:dthora, ''YYYY-MM-DD HH24:MI:SS''), :codoperador, :codsupervisor, :motivo)';

      while not LQuery.Eof do
      begin
        try
          LInsert.ParamByName('codfilial').AsString := LQuery.FieldByName('codfilial').AsString;
          LInsert.ParamByName('numcaixa').AsInteger := LQuery.FieldByName('numcaixa').AsInteger;
          LInsert.ParamByName('tipo').AsString := LQuery.FieldByName('tipo').AsString;
          LInsert.ParamByName('valor').AsFloat := LQuery.FieldByName('valor').AsFloat;
          LInsert.ParamByName('dthora').AsString := LQuery.FieldByName('dthora').AsString;
          LInsert.ParamByName('codoperador').AsInteger := LQuery.FieldByName('codoperador').AsInteger;
          LInsert.ParamByName('codsupervisor').AsInteger := LQuery.FieldByName('codsupervisor').AsInteger;
          LInsert.ParamByName('motivo').AsString := LQuery.FieldByName('motivo').AsString;
          LInsert.Execute;

          FSQLite.ExecutarSQL(
            'UPDATE numerario SET sincronizado = 1 WHERE id = ' +
            IntToStr(LQuery.FieldByName('id').AsInteger)
          );

          RegistrarLog('numerario', 'UPLOAD', IntToStr(LQuery.FieldByName('id').AsInteger), 'OK');
        except
          on E: Exception do
            RegistrarLog('numerario', 'UPLOAD', IntToStr(LQuery.FieldByName('id').AsInteger), 'ERRO', E.Message);
        end;
        LQuery.Next;
      end;
    finally
      LInsert.Free;
    end;
  finally
    LQuery.Free;
  end;
end;

procedure TSincronizador.RegistrarLog(const ATabela, AOperacao, ARegistroId,
  AStatus, AErro: string);
begin
  try
    FSQLite.ExecutarSQL(
      'INSERT INTO sync_log (tabela, operacao, registro_id, dt_operacao, status, erro) ' +
      'VALUES (:p0, :p1, :p2, datetime(''now'',''localtime''), :p3, :p4)',
      [ATabela, AOperacao, ARegistroId, AStatus, AErro]
    );
  except
    // Nao falhar por causa de log
  end;
end;

end.
