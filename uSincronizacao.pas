unit uSincronizacao;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.DateUtils, System.StrUtils, System.Variants,
  Vcl.ExtCtrls, Uni,Data.DB, uSQLiteDB, uConstantesWeb, uTypesApoloWeb;

type
  TSincronizador = class
  private
    FSQLite: TSQLiteDB;
    FTimerRetry: TTimer;
    FSincronizando: Boolean;

    procedure OnTimerRetry(Sender: TObject);

    // Download Oracle -> SQLite
    procedure SincronizarProdutos(AConn: TUniConnection);
    procedure SincronizarClientes(AConn: TUniConnection);
    procedure SincronizarFuncionarios(AConn: TUniConnection);
    procedure SincronizarPermissoes(AConn: TUniConnection);
    procedure SincronizarMeiosPagamento(AConn: TUniConnection);
    procedure SincronizarEmpresa(AConn: TUniConnection);
    procedure SincronizarParametros(AConn: TUniConnection);
    procedure SincronizarBandeiras(AConn: TUniConnection);

    // Upload SQLite -> Oracle
    procedure EnviarVendasPendentes(AConn: TUniConnection);
    procedure EnviarNumerarioPendente(AConn: TUniConnection);

    procedure RegistrarLog(const ATabela, AOperacao, ARegistroId, AStatus: string;
      const AErro: string = '');
  public
    constructor Create(ASQLite: TSQLiteDB);
    destructor Destroy; override;

    // Verifica se precisa sincronizar (data_atualizacao_servidor > data_atualizacao_caixa)
    function PrecisaSincronizar(AConn: TUniConnection): Boolean;

    // Atualiza data_atualizacao_caixa na msapolo_caixa apos sync
    procedure AtualizarDataSincCaixa(AConn: TUniConnection);

    // Download completo (na abertura do caixa)
    procedure DownloadCompleto(AConn: TUniConnection);

    // Upload de vendas (apos cada venda)
    procedure UploadVenda(AConn: TUniConnection; ACupomId: Integer);

    // Sincronizacao pendente
    procedure ProcessarPendentes(AConn: TUniConnection);

    // Iniciar timer de retry
    procedure IniciarRetry;
    procedure PararRetry;

    property Sincronizando: Boolean read FSincronizando;
  end;

implementation

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
  // Sera chamado pelo form principal com a conexao Oracle
end;

// =========================================================================
// VERIFICACAO DE NECESSIDADE DE SYNC
// =========================================================================

function TSincronizador.PrecisaSincronizar(AConn: TUniConnection): Boolean;
var
  LQuery: TUniQuery;
  LDtServidor, LDtCaixa: Variant;
begin
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
        Result := False  // Servidor nao tem data, nada a atualizar
      else if VarIsNull(LDtCaixa) then
        Result := True   // Caixa nunca sincronizou
      else
        Result := TDateTime(LDtServidor) > TDateTime(LDtCaixa);
    end;
  finally
    LQuery.Free;
  end;
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
    AConn.CommitRetaining;
  finally
    LQuery.Free;
  end;
end;

// =========================================================================
// DOWNLOAD (Oracle -> SQLite)
// =========================================================================

procedure TSincronizador.DownloadCompleto(AConn: TUniConnection);
begin
  if FSincronizando then Exit;
  FSincronizando := True;
  try
    SincronizarFuncionarios(AConn);
    SincronizarProdutos(AConn);
    SincronizarClientes(AConn);
    SincronizarPermissoes(AConn);
    SincronizarMeiosPagamento(AConn);
    SincronizarEmpresa(AConn);
    SincronizarParametros(AConn);
    SincronizarBandeiras(AConn);

    FSQLite.SalvarEstado('ULTIMA_SINCRONIZACAO', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    RegistrarLog('TODAS', 'DOWNLOAD', '', 'OK');
  except
    on E: Exception do
      RegistrarLog('TODAS', 'DOWNLOAD', '', 'ERRO', E.Message);
  end;
  FSincronizando := False;
end;

procedure TSincronizador.SincronizarProdutos(AConn: TUniConnection);
var
  LQuery: TUniQuery;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    LQuery.SQL.Text :=
      'SELECT codprod, codbarra, descricao, unidade, embalagem, ' +
      'ncm, extipi, cest, prod_origem, ean_valido, ' +
      'permite_dig_preco, permite_dig_desc, permite_dig_qtde, permite_dig_codigo, ' +
      'pesoobrigatorio, pesovariavel, id, perdesconto, peracrescimo, ' +
      'pcusto, qtdisponivel, pvenda, pvendaatac, poferta, dtfimoferta, ' +
      'qtminiatac, maxperdesc, codecf, versaoreg, codtrib, ' +
      'impleitransparencia, aliqicms, icms_cst, cfop, csosn, icms_percbasered, ' +
      'pis_cst, pis_ppis, pis_qbcprod, pis_valiqprod, ' +
      'pisst_ppis, pisst_qbcprod, pisst_valiqprod, ' +
      'cofins_cst, cofins_pcofins, cofins_qbcprod, cofins_valiqprod, ' +
      'cofinsst_pcofins, cofinsst_qbcprod, cofinsst_valiqprod, codfilial ' +
      'FROM msapolo_produtos WHERE codfilial = :codfilial';
    LQuery.ParamByName('codfilial').AsString := FSQLite.ObterEstado(KEY_CODFILIAL, '');
    LQuery.Open;

    // Usar transacao para performance
    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      // Limpar e recarregar (full sync)
      FSQLite.ExecutarSQL('DELETE FROM produtos');

      while not LQuery.Eof do
      begin
        FSQLite.ExecutarSQL(
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
          'cofinsst_pcofins, cofinsst_qbcprod, cofinsst_valiqprod, codfilial) ' +
          'VALUES (:p0,:p1,:p2,:p3,:p4,:p5,:p6,:p7,:p8,:p9,' +
          ':p10,:p11,:p12,:p13,:p14,:p15,:p16,:p17,:p18,:p19,' +
          ':p20,:p21,:p22,:p23,:p24,:p25,:p26,:p27,:p28,:p29,' +
          ':p30,:p31,:p32,:p33,:p34,:p35,:p36,:p37,:p38,:p39,' +
          ':p40,:p41,:p42,:p43,:p44,:p45,:p46,:p47,:p48,:p49,:p50)',
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
            LQuery.FieldByName('codfilial').AsString
          ]
        );
        LQuery.Next;
      end;

      FSQLite.ExecutarSQL('COMMIT');
      RegistrarLog('produtos', 'DOWNLOAD', '', 'OK');
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
  LQuery: TUniQuery;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    LQuery.SQL.Text := 'SELECT codcli, cnpj, nome, endereco, bairro, cidade, uf, cep, fax, limcredito FROM mscliente';
    LQuery.Open;

    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      FSQLite.ExecutarSQL('DELETE FROM clientes');
      while not LQuery.Eof do
      begin
        FSQLite.ExecutarSQL(
          'INSERT INTO clientes (codcli, cpf_cnpj, nome, endereco, bairro, cidade, uf, cep, telefone, limite_credito) ' +
          'VALUES (:p0,:p1,:p2,:p3,:p4,:p5,:p6,:p7,:p8,:p9)',
          [LQuery.FieldByName('codcli').AsInteger, LQuery.FieldByName('cnpj').AsString,
           LQuery.FieldByName('nome').AsString, LQuery.FieldByName('endereco').AsString,
           LQuery.FieldByName('bairro').AsString, LQuery.FieldByName('cidade').AsString,
           LQuery.FieldByName('uf').AsString, LQuery.FieldByName('cep').AsString,
           LQuery.FieldByName('fax').AsString, LQuery.FieldByName('limcredito').AsFloat]
        );
        LQuery.Next;
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

procedure TSincronizador.SincronizarFuncionarios(AConn: TUniConnection);
var
  LQuery: TUniQuery;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    LQuery.SQL.Text :=
      'SELECT matricula, nome, ofuscar(senhadb,usuariodb) senhadb, usuariodb, cargo FROM msfunc ' +
      'WHERE dtexclusao IS NULL AND ''S'' IN (ind_supervisor_cx, ind_operador_cx, ind_vendedor)';
    LQuery.Open;

    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      FSQLite.ExecutarSQL('DELETE FROM funcionarios');
      while not LQuery.Eof do
      begin
        FSQLite.ExecutarSQL(
          'INSERT INTO funcionarios (matricula, nome, senhadb, usuario, cargo) VALUES (:p0,:p1,:p2,:p3,:p4)',
          [LQuery.FieldByName('matricula').AsInteger, LQuery.FieldByName('nome').AsString,
           LQuery.FieldByName('senhadb').AsString, LQuery.FieldByName('usuariodb').AsString,
           LQuery.FieldByName('cargo').AsString]
        );
        LQuery.Next;
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
  LQuery: TUniQuery;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    LQuery.SQL.Text := 'SELECT matricula, controle FROM msacesso WHERE codrotina = 8002';
    LQuery.Open;

    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      FSQLite.ExecutarSQL('DELETE FROM permissoes');
      while not LQuery.Eof do
      begin
        FSQLite.ExecutarSQL(
          'INSERT INTO permissoes (matricula, codcontrole) VALUES (:p0,:p1)',
          [LQuery.FieldByName('matricula').AsInteger, LQuery.FieldByName('controle').AsInteger]
        );
        LQuery.Next;
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
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    LQuery.SQL.Text :=
      'SELECT codcob, cobranca, tipocob FROM mscob';
    LQuery.Open;

    FSQLite.ExecutarSQL('BEGIN TRANSACTION');
    try
      FSQLite.ExecutarSQL('DELETE FROM meios_pagamento');
      while not LQuery.Eof do
      begin
        FSQLite.ExecutarSQL(
          'INSERT INTO meios_pagamento (codcob, descricao, tipo, ativo) ' +
          'VALUES (:p0, :p1, :p2, 1)',
          [LQuery.FieldByName('codcob').AsString,
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

procedure TSincronizador.SincronizarEmpresa(AConn: TUniConnection);
var
  LQuery: TUniQuery;
  LCodFilial: string;
begin
  LCodFilial := FSQLite.ObterEstado(KEY_CODFILIAL, '');
  if LCodFilial = '' then Exit;

  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
    LQuery.SQL.Text :=
      'SELECT codfilial, codconsumidor, razaosocial, nome_fantasia, cnpj, ie, endereco, ender_numero, ender_complemento, ' +
      'bairro, cidade, uf, cep, codcidade, crt, fone ' +
      'FROM msfilial WHERE codfilial = :codfilial';
    LQuery.ParamByName('codfilial').AsString := LCodFilial;
    LQuery.Open;

    if not LQuery.IsEmpty then
    begin
      FSQLite.ExecutarSQL('DELETE FROM empresa');
      FSQLite.ExecutarSQL(
        'INSERT INTO empresa (id, razao_social, fantasia, cnpj, ie, ' +
        'endereco, numero, complemento, bairro, cidade, uf, cep, ' +
        'cod_cidade_ibge, regime_tributario, fone) ' +
        'VALUES (1, :p0, :p1, :p2, :p3, :p4, :p5, :p6, :p7, :p8, :p9, :p10, :p11, :p12, :p13)',
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
         LQuery.FieldByName('fone').AsString]
      );
      RegistrarLog('empresa', 'DOWNLOAD', '', 'OK');
    end;
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

procedure TSincronizador.SincronizarBandeiras(AConn: TUniConnection);
var
  LQuery: TUniQuery;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := AConn;
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

// =========================================================================
// UPLOAD (SQLite -> Oracle)
// =========================================================================

procedure TSincronizador.UploadVenda(AConn: TUniConnection; ACupomId: Integer);
var
  LCupom, LItens, LPagtos: TUniQuery;
  LInsert: TUniQuery;
  LNumTrans: Int64;
begin
  if not AConn.Connected then Exit;

  try
    // Ler cupom do SQLite
    LCupom := FSQLite.ExecutarSelect(
      'SELECT * FROM cupons WHERE id = ' + IntToStr(ACupomId)
    );
    try
      if LCupom.IsEmpty then Exit;

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
            while not LItens.Eof do
            begin
              LInsert.SQL.Text :=
                'INSERT INTO msapolo_venda_item (numtrans, numseqitem, codprod, codbarra, ' +
                'descricao, unidade, qt, punit, vlprod, vldesconto, ' +
                'ncm, cfop, cest, icms_cst, csosn, aliqicms, ' +
                'pis_cst, cofins_cst, aliqpis, aliqcofins, ' +
                'codvendedor, dtcancel, obscancel, emoferta, ptabela, prod_origem) ' +
                'VALUES (:numtrans, :numseqitem, :codprod, :codbarra, ' +
                ':descricao, :unidade, :qt, :punit, :vlprod, :vldesconto, ' +
                ':ncm, :cfop, :cest, :icms_cst, :csosn, :aliqicms, ' +
                ':pis_cst, :cofins_cst, :aliqpis, :aliqcofins, ' +
                ':codvendedor, :dtcancel, :obscancel, :emoferta, :ptabela, :prod_origem)';

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
              LInsert.Execute;
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
            while not LPagtos.Eof do
            begin
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

              LInsert.ParamByName('numtrans').AsLargeInt := LNumTrans;
              LInsert.ParamByName('codcob').AsString := LPagtos.FieldByName('codcob').AsString;
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
              LPagtos.Next;
            end;
          finally
            LPagtos.Free;
          end;
        finally
          LInsert.Free;
        end;

        AConn.Commit;

        // Marcar como sincronizado no SQLite
        FSQLite.ExecutarSQL(
          'UPDATE cupons SET sincronizado = 1, dt_sincronizacao = datetime(''now'',''localtime'') ' +
          'WHERE id = ' + IntToStr(ACupomId)
        );

        RegistrarLog('cupons', 'UPLOAD', IntToStr(ACupomId), 'OK');
      except
        AConn.Rollback;
        raise;
      end;
    finally
      LCupom.Free;
    end;
  except
    on E: Exception do
    begin
      RegistrarLog('cupons', 'UPLOAD', IntToStr(ACupomId), 'ERRO', E.Message);
    end;
  end;
end;

procedure TSincronizador.ProcessarPendentes(AConn: TUniConnection);
begin
  if FSincronizando then Exit;
  if not AConn.Connected then Exit;

  FSincronizando := True;
  try
    EnviarVendasPendentes(AConn);
    EnviarNumerarioPendente(AConn);
  finally
    FSincronizando := False;
  end;
end;

procedure TSincronizador.EnviarVendasPendentes(AConn: TUniConnection);
var
  LQuery: TUniQuery;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT id FROM cupons WHERE sincronizado = 0 AND codoper = ''V'' ORDER BY id LIMIT 10'
  );
  try
    while not LQuery.Eof do
    begin
      UploadVenda(AConn, LQuery.FieldByName('id').AsInteger);
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

      while not LQuery.Eof do
      begin
        try
          LInsert.SQL.Text :=
            'INSERT INTO msapolo_numerario (codfilial, numcaixa, tipo, valor, ' +
            'dthora, codoperador, codsupervisor, motivo) ' +
            'VALUES (:codfilial, :numcaixa, :tipo, :valor, ' +
            'TO_DATE(:dthora, ''YYYY-MM-DD HH24:MI:SS''), :codoperador, :codsupervisor, :motivo)';

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
