unit uSQLiteDB;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils,Data.DB,
  Uni, SQLiteUniProvider;


type
  TSQLiteDB = class
  private
    FConnection: TUniConnection;
    FDBPath: string;
    procedure CriarTabelasReferencia;
    procedure CriarTabelasTransacionais;
    procedure CriarTabelasControle;
    procedure CriarIndices;
    procedure InserirDadosTeste;
    function ObterVersaoSchema: Integer;
    procedure AtualizarVersaoSchema(AVersao: Integer);
    procedure CriarTabelaTribIBSCBS;
    procedure CriarTabelaPixCDConfig;
    procedure RepararChavesNFCe;
    function Ofuscar(const ATexto, AChave: string): string;
  public
    constructor Create(const ADBPath: string);
    destructor Destroy; override;

    procedure CriarBanco;
    procedure AbrirBanco;
    procedure FecharBanco;
    function EstaAberto: Boolean;

    procedure ExecutarSQL(const ASQL: string); overload;
    procedure ExecutarSQL(const ASQL: string; const AParams: array of Variant); overload;
    function ExecutarSelect(const ASQL: string): TUniQuery; overload;
    function ExecutarSelect(const ASQL: string; const AParams: array of Variant): TUniQuery; overload;
    function ExecutarScalar(const ASQL: string): Variant;

    // Comando preparado para insercao em massa: prepara o SQL UMA vez e
    // reexecuta so trocando os parametros (ExecutarSQL cria/parseia/prepara
    // uma TUniQuery nova a cada chamada - inviavel dentro de loop de sync).
    function CriarComando(const ASQL: string): TUniQuery;
    procedure ExecutarComando(AComando: TUniQuery; const AParams: array of Variant);

    // Estado do caixa (substitui TinyDB)
    procedure SalvarEstado(const AChave, AValor: string);
    function ObterEstado(const AChave: string; const ADefault: string = ''): string;

    property Connection: TUniConnection read FConnection;
    property DBPath: string read FDBPath;
  end;

const
  SCHEMA_VERSION = 24;

implementation

uses
  System.Variants, uConstantesWeb, uSyncLog;

{ TSQLiteDB }

constructor TSQLiteDB.Create(const ADBPath: string);
begin
  inherited Create;
  FDBPath := ADBPath;
  FConnection := TUniConnection.Create(nil);
  FConnection.ProviderName := 'SQLite';
  FConnection.Database := FDBPath;
  FConnection.SpecificOptions.Values['ForceCreateDatabase'] := 'True';
  FConnection.SpecificOptions.Values['Direct'] := 'True';
  FConnection.SpecificOptions.Values['DateFormat'] := 'yyyy-mm-dd';
  FConnection.SpecificOptions.Values['EnableSharedCache'] := 'False';
  // Sem BusyTimeout qualquer lock momentaneo vira "database is locked"
  FConnection.SpecificOptions.Values['BusyTimeout'] := '8000';
  FConnection.LoginPrompt := False;
end;

destructor TSQLiteDB.Destroy;
begin
  FecharBanco;
  FConnection.Free;
  inherited;
end;

procedure TSQLiteDB.CriarBanco;
var
  LDir: string;
begin
  LDir := ExtractFilePath(FDBPath);
  if not DirectoryExists(LDir) then
    ForceDirectories(LDir);

  AbrirBanco;

  // Configuracoes de performance do SQLite
  ExecutarSQL('PRAGMA busy_timeout=8000');
  ExecutarSQL('PRAGMA journal_mode=WAL');
  ExecutarSQL('PRAGMA synchronous=NORMAL');
  ExecutarSQL('PRAGMA foreign_keys=ON');
  ExecutarSQL('PRAGMA cache_size=-8000'); // 8MB cache

  // Criar estado_caixa primeiro (usada para controle de versao do schema)
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS estado_caixa (' +
    'chave TEXT PRIMARY KEY, ' +
    'valor TEXT, ' +
    'dt_atualizacao TEXT)'
  );

  // Migracao incremental v6 -> v7: adicionar coluna doceletronico_enviado
  if ObterVersaoSchema = 6 then
  begin
    try
      ExecutarSQL('ALTER TABLE cupons ADD COLUMN doceletronico_enviado INTEGER DEFAULT 0');
    except
      // Coluna pode ja existir
    end;
    AtualizarVersaoSchema(7);
  end;

  // Migracao incremental v7 -> v8: tabela tef_pendentes
  if ObterVersaoSchema = 7 then
  begin
    ExecutarSQL(
      'CREATE TABLE IF NOT EXISTS tef_pendentes (' +
      '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
      '  cupom_id INTEGER NOT NULL REFERENCES cupons(id),' +
      '  controle TEXT NOT NULL,' +
      '  nsu TEXT,' +
      '  cod_autorizacao TEXT,' +
      '  valor REAL DEFAULT 0,' +
      '  tipo_transacao TEXT,' +
      '  bandeira TEXT,' +
      '  parcelas INTEGER DEFAULT 1,' +
      '  codcob TEXT,' +
      '  status TEXT DEFAULT ''PENDENTE'',' +
      '  dthr_transacao TEXT,' +
      '  dthr_confirmacao TEXT' +
      ')'
    );
    ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_tef_pendentes_cupom ON tef_pendentes(cupom_id)');
    ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_tef_pendentes_status ON tef_pendentes(status)');
    AtualizarVersaoSchema(8);
  end;

  // Migracao incremental v8 -> v9: comprovantes TEF
  if ObterVersaoSchema = 8 then
  begin
    ExecutarSQL('ALTER TABLE tef_pendentes ADD COLUMN comprovante_cliente TEXT DEFAULT ''''');
    ExecutarSQL('ALTER TABLE tef_pendentes ADD COLUMN comprovante_loja TEXT DEFAULT ''''');
    AtualizarVersaoSchema(9);
  end;

  // Migracao incremental v9 -> v10: cadastro de meios de pagamento do PDV
  // (espelho de msapolo_meiopagto do Oracle)
  if ObterVersaoSchema = 9 then
  begin
    ExecutarSQL(
      'CREATE TABLE IF NOT EXISTS meiopagto (' +
      '  id INTEGER PRIMARY KEY,' +
      '  descricao TEXT,' +
      '  codcob TEXT,' +
      '  ordem INTEGER DEFAULT 0,' +
      '  obg_dtvenc TEXT DEFAULT ''N'',' +
      '  obg_documento TEXT DEFAULT ''N'',' +
      '  permite_troco TEXT DEFAULT ''N'',' +
      '  cmp TEXT' +
      ')'
    );
    AtualizarVersaoSchema(10);
  end;

  // Migracao incremental v10 -> v11: taxa do plano de pagamento
  // (espelho de msapolo_planopagto do Oracle)
  if ObterVersaoSchema = 10 then
  begin
    try
      ExecutarSQL('ALTER TABLE planos_pagamento ADD COLUMN txplano REAL DEFAULT 0');
    except
      // Coluna pode ja existir
    end;
    AtualizarVersaoSchema(11);
  end;

  // Migracao incremental v11 -> v12: prazos das parcelas do plano
  // (dias separados por '/', ex: '15/30'; vazio = parcela unica)
  if ObterVersaoSchema = 11 then
  begin
    try
      ExecutarSQL('ALTER TABLE planos_pagamento ADD COLUMN prazos TEXT DEFAULT ''''');
    except
      // Coluna pode ja existir
    end;
    AtualizarVersaoSchema(12);
  end;

  // Migracao incremental v12 -> v13: codigos de barras adicionais por produto
  // (espelho de mscodbarra do Oracle - EANs alem do codbarra principal)
  if ObterVersaoSchema = 12 then
  begin
    ExecutarSQL(
      'CREATE TABLE IF NOT EXISTS codbarras (' +
      '  codbarra TEXT PRIMARY KEY,' +
      '  codprod INTEGER NOT NULL,' +
      '  descricao TEXT' +
      ')'
    );
    ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_codbarras_codprod ON codbarras(codprod)');
    AtualizarVersaoSchema(13);
  end;

  // v14: unidade por codigo de barras. msapolo_produtos tem 1 linha por
  // (codprod, codbarra), cada uma com a propria unidade (ex: mesmo produto
  // vendido em UN por um EAN e em KG por outro); a tabela produtos guarda
  // apenas a linha principal, entao a unidade de cada EAN fica aqui.
  if ObterVersaoSchema = 13 then
  begin
    ExecutarSQL(
      'CREATE TABLE IF NOT EXISTS produto_unidades (' +
      '  codbarra TEXT PRIMARY KEY,' +
      '  codprod INTEGER NOT NULL,' +
      '  unidade TEXT' +
      ')'
    );
    ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_produto_unidades_codprod ON produto_unidades(codprod)');
    AtualizarVersaoSchema(14);
  end;

  // v15: qtunit (quantidade por embalagem do EAN). A quantidade digitada no
  // registro do item e multiplicada por esse fator (ex: digitou 2, qtunit 5
  // -> registra 10). Vem do msapolo_produto_temp/msapolo_produtos.
  if ObterVersaoSchema = 14 then
  begin
    ExecutarSQL('ALTER TABLE produtos ADD COLUMN qtunit REAL DEFAULT 1');
    ExecutarSQL('ALTER TABLE produto_unidades ADD COLUMN qtunit REAL DEFAULT 1');
    AtualizarVersaoSchema(15);
  end;

  // v16: cada embalagem (codprod+codbarra) tem tambem descricao e preco
  // proprios no msapolo_produtos; o registro do item deve usar os dados da
  // embalagem bipada, nao os da linha principal colapsada em produtos
  if ObterVersaoSchema = 15 then
  begin
    ExecutarSQL('ALTER TABLE produto_unidades ADD COLUMN descricao TEXT');
    ExecutarSQL('ALTER TABLE produto_unidades ADD COLUMN pvenda REAL DEFAULT 0');
    ExecutarSQL('ALTER TABLE produto_unidades ADD COLUMN poferta REAL DEFAULT 0');
    ExecutarSQL('ALTER TABLE produto_unidades ADD COLUMN dtfimoferta TEXT');
    AtualizarVersaoSchema(16);
  end;

  // v17: tributacao IBS/CBS vinda da retaguarda (msncm_ibs_cbs + ms_trib_ibs_cbs).
  // A regra e' resolvida do mais especifico para o mais generico:
  // codprod -> ncm -> linha com os dois nulos (vale para todos os produtos).
  if ObterVersaoSchema = 16 then
  begin
    CriarTabelaTribIBSCBS;
    AtualizarVersaoSchema(17);
  end;

  // v18: descarte manual de documento da fila. Rejeitado nunca foi autorizado,
  // entao nao ha o que cancelar na SEFAZ - o descarte so tira da fila local,
  // registrando quem tirou e quando.
  if ObterVersaoSchema = 17 then
  begin
    ExecutarSQL('ALTER TABLE nfce_contingencia ADD COLUMN dt_descarte TEXT');
    ExecutarSQL('ALTER TABLE nfce_contingencia ADD COLUMN descartado_por INTEGER DEFAULT 0');
    AtualizarVersaoSchema(18);
  end;

  // v19: a chavenfe so existe depois que a NFCe e autorizada, e o upload da
  // venda acontece antes disso. chave_enviada marca o cupom cuja chave ja foi
  // levada ate a msapolo_venda no Oracle (ver AtualizarChavesNoOracle).
  if ObterVersaoSchema = 18 then
  begin
    ExecutarSQL('ALTER TABLE cupons ADD COLUMN chave_enviada INTEGER DEFAULT 0');
    AtualizarVersaoSchema(19);
  end;

  // v20: cancelamento de NFCe (evento 110111). O cupom continua existindo com
  // itens e pagamentos - o que muda e o codoper ('C') e este bloco, que guarda
  // o protocolo do evento e o procEventoNFe para a retaguarda e para o arquivo
  // fiscal. cancel_enviado espelha o chave_enviada: marca o cupom cujo
  // cancelamento ja subiu para o Oracle.
  if ObterVersaoSchema = 19 then
  begin
    ExecutarSQL('ALTER TABLE cupons ADD COLUMN cancelada INTEGER DEFAULT 0');
    ExecutarSQL('ALTER TABLE cupons ADD COLUMN dthr_cancelamento TEXT');
    ExecutarSQL('ALTER TABLE cupons ADD COLUMN protocolo_cancelamento TEXT');
    ExecutarSQL('ALTER TABLE cupons ADD COLUMN justificativa_cancel TEXT');
    ExecutarSQL('ALTER TABLE cupons ADD COLUMN xml_cancelamento TEXT');
    ExecutarSQL('ALTER TABLE cupons ADD COLUMN cancelado_por INTEGER DEFAULT 0');
    ExecutarSQL('ALTER TABLE cupons ADD COLUMN cancel_enviado INTEGER DEFAULT 0');
    AtualizarVersaoSchema(20);
  end;

  // v21: chave PIX da filial (msfilial.chave_pix), usada para montar o
  // QR Code (BR Code) apresentado no pagamento com PIX manual
  if ObterVersaoSchema = 20 then
  begin
    ExecutarSQL('ALTER TABLE empresa ADD COLUMN chave_pix TEXT');
    AtualizarVersaoSchema(21);
  end;

  // v22: configuracao da API Pix (ACBrPIXCD), sincronizada da msapolo_pixcd
  // do Oracle. Com ela o QR do PIX manual vira cobranca dinamica com
  // confirmacao automatica do recebimento.
  if ObterVersaoSchema = 21 then
  begin
    CriarTabelaPixCDConfig;
    AtualizarVersaoSchema(22);
  end;

  // v23: qtunit gravado no item do cupom (quantidade por embalagem do EAN
  // bipado). Informativo - nao altera quantidade nem valor do item; sobe
  // para a retaguarda em msapolo_venda_item.qtunit.
  if ObterVersaoSchema = 22 then
  begin
    ExecutarSQL('ALTER TABLE cupom_itens ADD COLUMN qtunit REAL DEFAULT 1');
    AtualizarVersaoSchema(23);
  end;

  // v24: grupo de reducao de aliquota (gRed) do IBS/CBS. cClassTrib de
  // aliquota reduzida (CST 200) exige pRedAliq/pAliqEfet no XML, senao o
  // SEFAZ rejeita com "Nao informado o grupo de reducao de aliquota".
  if ObterVersaoSchema = 23 then
  begin
    ExecutarSQL('ALTER TABLE trib_ibs_cbs ADD COLUMN ibsuf_predaliq REAL');
    ExecutarSQL('ALTER TABLE trib_ibs_cbs ADD COLUMN ibsuf_paliqefet REAL');
    ExecutarSQL('ALTER TABLE trib_ibs_cbs ADD COLUMN ibsmun_predaliq REAL');
    ExecutarSQL('ALTER TABLE trib_ibs_cbs ADD COLUMN ibsmun_paliqefet REAL');
    ExecutarSQL('ALTER TABLE trib_ibs_cbs ADD COLUMN cbs_predaliq REAL');
    ExecutarSQL('ALTER TABLE trib_ibs_cbs ADD COLUMN cbs_paliqefet REAL');
    AtualizarVersaoSchema(24);
  end;

  if ObterVersaoSchema < SCHEMA_VERSION then
  begin
    // Desabilitar foreign keys para permitir DROP de tabelas referenciadas
    ExecutarSQL('PRAGMA foreign_keys=OFF');

    // Dropar tabelas com schema antigo/corrompido para recriar
    ExecutarSQL('DROP TABLE IF EXISTS cupom_pagamentos');
    ExecutarSQL('DROP TABLE IF EXISTS cupom_itens');
    ExecutarSQL('DROP TABLE IF EXISTS cupons');
    ExecutarSQL('DROP TABLE IF EXISTS nfce_contingencia');
    ExecutarSQL('DROP TABLE IF EXISTS numerario');
    ExecutarSQL('DROP TABLE IF EXISTS creditos_cliente');
    ExecutarSQL('DROP TABLE IF EXISTS prevenda_itens');
    ExecutarSQL('DROP TABLE IF EXISTS prevenda');
    ExecutarSQL('DROP TABLE IF EXISTS sync_log');
    ExecutarSQL('DROP TABLE IF EXISTS db_version');
    ExecutarSQL('DROP TABLE IF EXISTS sequencias');
    ExecutarSQL('DROP TABLE IF EXISTS produtos');
    ExecutarSQL('DROP TABLE IF EXISTS codbarras');
    ExecutarSQL('DROP TABLE IF EXISTS produto_unidades');
    ExecutarSQL('DROP TABLE IF EXISTS clientes');
    ExecutarSQL('DROP TABLE IF EXISTS funcionarios');
    ExecutarSQL('DROP TABLE IF EXISTS permissoes');
    ExecutarSQL('DROP TABLE IF EXISTS meios_pagamento');
    ExecutarSQL('DROP TABLE IF EXISTS meiopagto');
    ExecutarSQL('DROP TABLE IF EXISTS bandeiras');
    ExecutarSQL('DROP TABLE IF EXISTS empresa');
    ExecutarSQL('DROP TABLE IF EXISTS pixcd_config');
    ExecutarSQL('DROP TABLE IF EXISTS parametros');
    ExecutarSQL('DROP TABLE IF EXISTS layout_cupom');
    ExecutarSQL('DROP TABLE IF EXISTS aliquotas');
    ExecutarSQL('DROP TABLE IF EXISTS planos_pagamento');

    // Reabilitar foreign keys antes de criar tabelas
    ExecutarSQL('PRAGMA foreign_keys=ON');

    CriarTabelasReferencia;
    CriarTabelasTransacionais;
    CriarTabelasControle;
    CriarIndices;
    InserirDadosTeste;
    AtualizarVersaoSchema(SCHEMA_VERSION);
  end;

  // Correcao de dados, depois das tabelas existirem. Fica fora do
  // versionamento de proposito: subir SCHEMA_VERSION dispara o rebuild acima,
  // que DROPA cupons e nfce_contingencia - o oposto do que se quer aqui.
  RepararChavesNFCe;
end;

procedure TSQLiteDB.AbrirBanco;
begin
  if not FConnection.Connected then
    FConnection.Open;
end;

procedure TSQLiteDB.FecharBanco;
begin
  if FConnection.Connected then
    FConnection.Close;
end;

function TSQLiteDB.EstaAberto: Boolean;
begin
  Result := FConnection.Connected;
end;

procedure TSQLiteDB.ExecutarSQL(const ASQL: string);
var
  LQuery: TUniQuery;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := FConnection;
    LQuery.SQL.Text := ASQL;
    LQuery.Execute;
  finally
    LQuery.Free;
  end;
end;

procedure TSQLiteDB.ExecutarSQL(const ASQL: string; const AParams: array of Variant);
var
  LQuery: TUniQuery;
  I: Integer;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := FConnection;
    LQuery.SQL.Text := ASQL;
    for I := 0 to High(AParams) do
      LQuery.Params[I].Value := AParams[I];
    LQuery.Execute;
  finally
    LQuery.Free;
  end;
end;

function TSQLiteDB.CriarComando(const ASQL: string): TUniQuery;
begin
  Result := TUniQuery.Create(nil);
  Result.Connection := FConnection;
  Result.SQL.Text := ASQL;
  Result.Prepare;
end;

procedure TSQLiteDB.ExecutarComando(AComando: TUniQuery; const AParams: array of Variant);
var
  I: Integer;
begin
  for I := 0 to High(AParams) do
    AComando.Params[I].Value := AParams[I];
  AComando.Execute;
end;

function TSQLiteDB.ExecutarSelect(const ASQL: string): TUniQuery;
begin
  Result := TUniQuery.Create(nil);
  Result.Connection := FConnection;
  Result.SQL.Text := ASQL;
  Result.Open;
end;

function TSQLiteDB.ExecutarSelect(const ASQL: string; const AParams: array of Variant): TUniQuery;
var
  I: Integer;
begin
  Result := TUniQuery.Create(nil);
  Result.Connection := FConnection;
  Result.SQL.Text := ASQL;
  for I := 0 to High(AParams) do
    Result.Params[I].Value := AParams[I];
  Result.Open;
end;

function TSQLiteDB.ExecutarScalar(const ASQL: string): Variant;
var
  LQuery: TUniQuery;
begin
  LQuery := ExecutarSelect(ASQL);
  try
    if not LQuery.IsEmpty then
      Result := LQuery.Fields[0].Value
    else
      Result := Null;
  finally
    LQuery.Free;
  end;
end;

procedure TSQLiteDB.SalvarEstado(const AChave, AValor: string);
begin
  ExecutarSQL(
    'INSERT OR REPLACE INTO estado_caixa (chave, valor, dt_atualizacao) ' +
    'VALUES (:p0, :p1, datetime(''now'',''localtime''))',
    [AChave, AValor]
  );
end;

function TSQLiteDB.ObterEstado(const AChave: string; const ADefault: string): string;
var
  LVal: Variant;
begin
  LVal := ExecutarScalar(
    'SELECT valor FROM estado_caixa WHERE chave = ''' + AChave + ''''
  );
  if VarIsNull(LVal) or VarIsEmpty(LVal) then
    Result := ADefault
  else
    Result := VarToStr(LVal);
end;

function TSQLiteDB.ObterVersaoSchema: Integer;
var
  LVal: Variant;
begin
  try
    LVal := ExecutarScalar('SELECT valor FROM estado_caixa WHERE chave = ''SCHEMA_VERSION''');
    if VarIsNull(LVal) or VarIsEmpty(LVal) then
      Result := 0
    else
      Result := StrToIntDef(VarToStr(LVal), 0);
  except
    Result := 0;
  end;
end;

procedure TSQLiteDB.AtualizarVersaoSchema(AVersao: Integer);
begin
  SalvarEstado('SCHEMA_VERSION', IntToStr(AVersao));
end;

// Espelho de msncm_ibs_cbs + ms_trib_ibs_cbs do Oracle (ja com o join feito).
// codprod/ncm NULL = regra geral da filial; quanto mais preenchido, mais
// especifica a regra. Ver ResolverIBSCBS em uNFCeWeb.pas.
procedure TSQLiteDB.CriarTabelaTribIBSCBS;
begin
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS trib_ibs_cbs (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  codfilial INTEGER,' +
    '  ncm TEXT,' +
    '  codprod INTEGER,' +
    '  habilitado INTEGER DEFAULT 1,' +
    '  cst TEXT,' +
    '  cclasstrib TEXT,' +
    '  pibsuf REAL DEFAULT 0,' +
    '  pibsmun REAL DEFAULT 0,' +
    '  pcbs REAL DEFAULT 0,' +
    // gRed do item: reducao de aliquota. NULL = a regra nao reduz nada
    '  ibsuf_predaliq REAL,' +
    '  ibsuf_paliqefet REAL,' +
    '  ibsmun_predaliq REAL,' +
    '  ibsmun_paliqefet REAL,' +
    '  cbs_predaliq REAL,' +
    '  cbs_paliqefet REAL' +
    ')'
  );
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_trib_ibscbs_prod ON trib_ibs_cbs(codprod)');
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_trib_ibscbs_ncm ON trib_ibs_cbs(ncm)');
end;

// Configuracao da API Pix (cobranca dinamica via ACBrPIXCD), espelho da
// msapolo_pixcd do Oracle. Linha unica (id=1); vazia = PixCD desligado e o
// PIX manual segue com QR estatico + confirmacao manual do operador.
procedure TSQLiteDB.CriarTabelaPixCDConfig;
begin
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS pixcd_config (' +
    '  id INTEGER PRIMARY KEY DEFAULT 1,' +
    '  psp TEXT,' +                       // BB, ITAU, SICOOB, SICREDI, BRADESCO, SANTANDER, INTER, EFI, MERCADOPAGO...
    '  ambiente INTEGER DEFAULT 2,' +     // 1=producao, 2=teste/homologacao
    '  chave_pix TEXT,' +                 // vazio = usa empresa.chave_pix
    '  client_id TEXT,' +
    '  client_secret TEXT,' +
    '  chave_extra TEXT,' +               // BB: developer_application_key; MercadoPago: access_token
    '  arq_certificado TEXT,' +           // caminhos locais no caixa (ex: C:\Apolo\pix\)
    '  arq_chave_privada TEXT,' +
    '  arq_pfx TEXT,' +
    '  senha_pfx TEXT,' +
    '  expiracao_seg INTEGER DEFAULT 300,' +
    '  ativo TEXT DEFAULT ''S''' +
    ')'
  );
end;

// Uma versao anterior gravava em cupons.chavenfe o texto da mensagem
// ("NFCe autorizada. Protocolo: ...") e em cupons.protocolo_nfe o JSON de
// retorno, com os campos chaveNFe e protocolo. Com isso a venda subia para a
// retaguarda com lixo em chavenfe e o XML nunca era localizado.
// O JSON tem os dois valores corretos, entao da para desfazer. Roda uma vez
// (flag REPARO_CHAVENFE) e nao toca no schema.
procedure TSQLiteDB.RepararChavesNFCe;
const
  MARCA_CHAVE = '"chaveNFe":"';
  MARCA_PROTO = '"protocolo":"';
var
  LAfetados: Variant;
begin
  if ObterEstado('REPARO_CHAVENFE', '') = 'OK' then Exit;

  try
    LAfetados := ExecutarScalar(
      'SELECT COUNT(*) FROM cupons WHERE protocolo_nfe LIKE ''%' + MARCA_CHAVE + '%''');

    // Copia de seguranca antes de reescrever chave/protocolo de vendas fiscais
    try
      if FileExists(FDBPath) and (not FileExists(FDBPath + '.bak-reparo')) then
        TFile.Copy(FDBPath, FDBPath + '.bak-reparo');
    except
      // backup e' desejavel, nao obrigatorio
    end;

    // 1) Recuperar chave e protocolo do JSON preso em protocolo_nfe.
    //    substr(...) ate a proxima aspa isola cada valor.
    ExecutarSQL(
      'UPDATE cupons SET ' +
      '  chavenfe = replace(substr(protocolo_nfe, ' +
      '      instr(protocolo_nfe, ''' + MARCA_CHAVE + ''') + 12, ' +
      '      instr(substr(protocolo_nfe, instr(protocolo_nfe, ''' + MARCA_CHAVE + ''') + 12), ''"'') - 1' +
      '    ), ''NFe'', ''''), ' +
      '  protocolo_nfe = CASE WHEN instr(protocolo_nfe, ''' + MARCA_PROTO + ''') > 0 THEN ' +
      '      substr(protocolo_nfe, ' +
      '        instr(protocolo_nfe, ''' + MARCA_PROTO + ''') + 13, ' +
      '        instr(substr(protocolo_nfe, instr(protocolo_nfe, ''' + MARCA_PROTO + ''') + 13), ''"'') - 1' +
      '      ) ELSE '''' END ' +
      'WHERE protocolo_nfe LIKE ''%' + MARCA_CHAVE + '%'''
    );

    // 2) Sobrou cupom sem chave valida mas com documento em contingencia
    ExecutarSQL(
      'UPDATE cupons SET chavenfe = (' +
      '  SELECT replace(nc.chave_nfe, ''NFe'', '''') FROM nfce_contingencia nc ' +
      '  WHERE nc.cupom_id = cupons.id ORDER BY nc.id DESC LIMIT 1) ' +
      'WHERE length(coalesce(chavenfe, '''')) <> 44 ' +
      '  AND EXISTS (SELECT 1 FROM nfce_contingencia nc WHERE nc.cupom_id = cupons.id)'
    );

    // 3) Padronizar tudo em 44 digitos (chave sem o prefixo ''NFe'')
    ExecutarSQL(
      'UPDATE cupons SET chavenfe = substr(chavenfe, 4) ' +
      'WHERE length(chavenfe) = 47 AND substr(chavenfe, 1, 3) = ''NFe'''
    );
    ExecutarSQL(
      'UPDATE nfce_contingencia SET chave_nfe = substr(chave_nfe, 4) ' +
      'WHERE length(chave_nfe) = 47 AND substr(chave_nfe, 1, 3) = ''NFe'''
    );

    // 4) O que continuar invalido vira vazio: melhor a venda subir sem chave
    //    do que com texto de mensagem no lugar dela
    ExecutarSQL(
      'UPDATE cupons SET chavenfe = '''' ' +
      'WHERE chavenfe IS NOT NULL AND chavenfe <> '''' AND length(chavenfe) <> 44'
    );
    ExecutarSQL(
      'UPDATE cupons SET protocolo_nfe = '''' ' +
      'WHERE protocolo_nfe IS NOT NULL AND protocolo_nfe LIKE ''{%'''
    );

    // 5) Chave recuperada => o XML precisa ser reenviado para a retaguarda
    ExecutarSQL(
      'UPDATE cupons SET doceletronico_enviado = 0 ' +
      'WHERE length(coalesce(chavenfe, '''')) = 44 ' +
      '  AND length(coalesce(protocolo_nfe, '''')) > 0'
    );

    SalvarEstado('REPARO_CHAVENFE', 'OK');
    SyncLog('REPARO chavenfe/protocolo_nfe: %s cupom(ns) com JSON no lugar da chave',
      [VarToStr(LAfetados)]);
  except
    on E: Exception do
      SyncLog('REPARO chavenfe: falhou - [%s] %s', [E.ClassName, E.Message]);
  end;
end;

procedure TSQLiteDB.CriarTabelasReferencia;
begin
  // Produtos (espelho de msapolo_produtos no Oracle)
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS produtos (' +
    '  codprod INTEGER PRIMARY KEY,' +
    '  codbarra TEXT,' +
    '  descricao TEXT NOT NULL,' +
    '  unidade TEXT,' +
    '  qtunit REAL DEFAULT 1,' +
    '  embalagem TEXT,' +
    '  ncm TEXT,' +
    '  extipi TEXT,' +
    '  cest TEXT,' +
    '  prod_origem TEXT,' +
    '  ean_valido TEXT DEFAULT ''S'',' +
    '  permite_dig_preco TEXT DEFAULT ''N'',' +
    '  permite_dig_desc TEXT DEFAULT ''N'',' +
    '  permite_dig_qtde TEXT DEFAULT ''S'',' +
    '  permite_dig_codigo TEXT DEFAULT ''N'',' +
    '  pesoobrigatorio TEXT DEFAULT ''N'',' +
    '  pesovariavel TEXT DEFAULT ''N'',' +
    '  id_oracle INTEGER DEFAULT 0,' +
    '  perdesconto REAL DEFAULT 0,' +
    '  peracrescimo REAL DEFAULT 0,' +
    '  pcusto REAL DEFAULT 0,' +
    '  qtdisponivel REAL DEFAULT 0,' +
    '  pvenda REAL DEFAULT 0,' +
    '  pvendaatac REAL DEFAULT 0,' +
    '  poferta REAL DEFAULT 0,' +
    '  dtfimoferta TEXT,' +
    '  qtminiatac INTEGER DEFAULT 0,' +
    '  maxperdesc REAL DEFAULT 0,' +
    '  codecf TEXT,' +
    '  versaoreg TEXT,' +
    '  codtrib REAL DEFAULT 0,' +
    '  impleitransparencia REAL DEFAULT 0,' +
    '  aliqicms REAL DEFAULT 0,' +
    '  icms_cst TEXT,' +
    '  cfop REAL DEFAULT 0,' +
    '  csosn TEXT,' +
    '  icms_percbasered REAL DEFAULT 0,' +
    '  pis_cst TEXT,' +
    '  pis_ppis REAL DEFAULT 0,' +
    '  pis_qbcprod REAL DEFAULT 0,' +
    '  pis_valiqprod REAL DEFAULT 0,' +
    '  pisst_ppis REAL DEFAULT 0,' +
    '  pisst_qbcprod REAL DEFAULT 0,' +
    '  pisst_valiqprod REAL DEFAULT 0,' +
    '  cofins_cst TEXT,' +
    '  cofins_pcofins REAL DEFAULT 0,' +
    '  cofins_qbcprod REAL DEFAULT 0,' +
    '  cofins_valiqprod REAL DEFAULT 0,' +
    '  cofinsst_pcofins REAL DEFAULT 0,' +
    '  cofinsst_qbcprod REAL DEFAULT 0,' +
    '  cofinsst_valiqprod REAL DEFAULT 0,' +
    '  codfilial TEXT' +
    ')'
  );

  // Codigos de barras adicionais (mscodbarra)
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS codbarras (' +
    '  codbarra TEXT PRIMARY KEY,' +
    '  codprod INTEGER NOT NULL,' +
    '  descricao TEXT' +
    ')'
  );
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_codbarras_codprod ON codbarras(codprod)');

  // Dados por embalagem/codigo de barras (1 linha por codprod+codbarra do
  // msapolo_produtos; produtos guarda apenas a linha principal)
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS produto_unidades (' +
    '  codbarra TEXT PRIMARY KEY,' +
    '  codprod INTEGER NOT NULL,' +
    '  unidade TEXT,' +
    '  qtunit REAL DEFAULT 1,' +
    '  descricao TEXT,' +
    '  pvenda REAL DEFAULT 0,' +
    '  poferta REAL DEFAULT 0,' +
    '  dtfimoferta TEXT' +
    ')'
  );
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_produto_unidades_codprod ON produto_unidades(codprod)');

  // Clientes
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS clientes (' +
    '  codcli INTEGER PRIMARY KEY,' +
    '  cpf_cnpj TEXT,' +
    '  nome TEXT NOT NULL,' +
    '  endereco TEXT,' +
    '  bairro TEXT,' +
    '  cidade TEXT,' +
    '  uf TEXT,' +
    '  cep TEXT,' +
    '  telefone TEXT,' +
    '  limite_credito REAL DEFAULT 0,' +
    '  dt_bloqueio TEXT' +
    ')'
  );

  // Funcionarios
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS funcionarios (' +
    '  matricula INTEGER PRIMARY KEY,' +
    '  nome TEXT NOT NULL,' +
    '  senhadb TEXT,' +
    '  usuario TEXT,' +
    '  cargo TEXT,' +
    '  ind_vendedor TEXT DEFAULT ''N''' +
    ')'
  );

  // Permissoes
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS permissoes (' +
    '  matricula INTEGER NOT NULL,' +
    '  codcontrole INTEGER NOT NULL,' +
    '  PRIMARY KEY (matricula, codcontrole)' +
    ')'
  );

  // Meios de Pagamento
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS meios_pagamento (' +
    '  codcob TEXT PRIMARY KEY,' +
    '  descricao TEXT,' +
    '  tipo TEXT,' +
    '  ativo INTEGER DEFAULT 1,' +
    '  exige_vinculado TEXT DEFAULT ''N'',' +
    '  numvias INTEGER DEFAULT 1' +
    ')'
  );

  // Cadastro de meios de pagamento do PDV (msapolo_meiopagto)
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS meiopagto (' +
    '  id INTEGER PRIMARY KEY,' +
    '  descricao TEXT,' +
    '  codcob TEXT,' +
    '  ordem INTEGER DEFAULT 0,' +
    '  obg_dtvenc TEXT DEFAULT ''N'',' +
    '  obg_documento TEXT DEFAULT ''N'',' +
    '  permite_troco TEXT DEFAULT ''N'',' +
    '  cmp TEXT' +
    ')'
  );

  // Bandeiras de Cartao
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS bandeiras (' +
    '  codbandeira INTEGER PRIMARY KEY,' +
    '  descricao TEXT,' +
    '  tband TEXT' +
    ')'
  );

  // Tributacao IBS/CBS por produto/NCM
  CriarTabelaTribIBSCBS;

  // Configuracao da API Pix (cobranca dinamica)
  CriarTabelaPixCDConfig;

  // Empresa
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS empresa (' +
    '  id INTEGER PRIMARY KEY DEFAULT 1,' +
    '  razao_social TEXT,' +
    '  fantasia TEXT,' +
    '  cnpj TEXT,' +
    '  ie TEXT,' +
    '  endereco TEXT,' +
    '  numero TEXT,' +
    '  complemento TEXT,' +
    '  bairro TEXT,' +
    '  cidade TEXT,' +
    '  uf TEXT,' +
    '  cep TEXT,' +
    '  cod_cidade_ibge TEXT,' +
    '  regime_tributario INTEGER DEFAULT 1,' +
    '  fone TEXT,' +
    '  chave_pix TEXT' +
    ')'
  );

  // Parametros
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS parametros (' +
    '  parametro TEXT PRIMARY KEY,' +
    '  conteudo TEXT,' +
    '  numcaixa INTEGER DEFAULT 0' +
    ')'
  );

  // Layout de Cupom
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS layout_cupom (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  tipo TEXT,' +
    '  linha INTEGER,' +
    '  conteudo TEXT,' +
    '  alinhamento TEXT DEFAULT ''E''' +
    ')'
  );

  // Aliquotas ICMS
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS aliquotas (' +
    '  codaliquota INTEGER PRIMARY KEY,' +
    '  descricao TEXT,' +
    '  percentual REAL DEFAULT 0,' +
    '  tipo TEXT' +
    ')'
  );

  // Planos de Pagamento
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS planos_pagamento (' +
    '  codplpag INTEGER PRIMARY KEY,' +
    '  descricao TEXT,' +
    '  qtdeparcelas INTEGER DEFAULT 1,' +
    '  intervalo_dias INTEGER DEFAULT 30,' +
    '  txplano REAL DEFAULT 0,' +
    '  prazos TEXT DEFAULT ''''' +
    ')'
  );
end;

procedure TSQLiteDB.CriarTabelasTransacionais;
begin
  // Cupons (Vendas)
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS cupons (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  codoper TEXT,' +
    '  especie TEXT DEFAULT ''NFC'',' +
    '  numnota REAL DEFAULT 0,' +
    '  serienfce INTEGER DEFAULT 1,' +
    '  codfilial TEXT,' +
    '  numcaixa INTEGER,' +
    '  datamovto TEXT,' +
    '  dthriniciovenda TEXT,' +
    '  dthrfimvenda TEXT,' +
    '  cpf_cnpj TEXT,' +
    '  codcli INTEGER DEFAULT 0,' +
    '  descnomecliente TEXT,' +
    '  codorigempedido INTEGER DEFAULT 0,' +
    '  qtdeitens INTEGER DEFAULT 0,' +
    '  valorvenda REAL DEFAULT 0,' +
    '  qtdeitemcancel INTEGER DEFAULT 0,' +
    '  valorcancel REAL DEFAULT 0,' +
    '  valordesc REAL DEFAULT 0,' +
    '  valordescsubtotal REAL DEFAULT 0,' +
    '  valorencargo REAL DEFAULT 0,' +
    '  valortroco REAL DEFAULT 0,' +
    '  vldesconto REAL DEFAULT 0,' +
    '  codoperador INTEGER,' +
    '  codsupervisor INTEGER DEFAULT 0,' +
    '  numserieequip TEXT,' +
    '  numcupom INTEGER DEFAULT 0,' +
    '  chavenfe TEXT,' +
    '  protocolo_nfe TEXT,' +
    '  url_qrcode TEXT,' +
    '  codcob TEXT,' +
    '  codplpag INTEGER DEFAULT 0,' +
    '  codtipocupom INTEGER DEFAULT 0,' +
    '  codtipovenda INTEGER DEFAULT 0,' +
    '  ccf INTEGER DEFAULT 0,' +
    '  numtrans INTEGER DEFAULT 0,' +
    '  numped INTEGER DEFAULT 0,' +
    '  valoracrescimo REAL DEFAULT 0,' +
    '  vlpagtotitulo REAL DEFAULT 0,' +
    '  vldesconto_atacado REAL DEFAULT 0,' +
    '  vlcredito_troco REAL DEFAULT 0,' +
    '  tpimp TEXT DEFAULT ''T'',' +
    '  versao TEXT,' +
    '  numseqfechamento TEXT,' +
    '  ind_prevenda TEXT DEFAULT ''N'',' +
    '  telefone TEXT,' +
    '  obs TEXT,' +
    '  obscancel TEXT,' +
    '  codprepedido INTEGER DEFAULT 0,' +
    '  tipo_contingencia TEXT,' +
    '  dt_contingencia TEXT,' +
    '  contingencia_justificativa TEXT,' +
    '  estadoenvio INTEGER DEFAULT 0,' +
    '  qtdeenvios INTEGER DEFAULT 0,' +
    '  sincronizado INTEGER DEFAULT 0,' +
    '  dt_sincronizacao TEXT,' +
    '  doceletronico_enviado INTEGER DEFAULT 0,' +
    '  chave_enviada INTEGER DEFAULT 0,' +
    // Cancelamento da NFCe (evento 110111) - ver migration v20
    '  cancelada INTEGER DEFAULT 0,' +
    '  dthr_cancelamento TEXT,' +
    '  protocolo_cancelamento TEXT,' +
    '  justificativa_cancel TEXT,' +
    '  xml_cancelamento TEXT,' +
    '  cancelado_por INTEGER DEFAULT 0,' +
    '  cancel_enviado INTEGER DEFAULT 0' +
    ')'
  );

  // Itens do Cupom
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS cupom_itens (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  cupom_id INTEGER NOT NULL REFERENCES cupons(id),' +
    '  numseqitem INTEGER NOT NULL,' +
    '  codprod INTEGER,' +
    '  codbarra TEXT,' +
    '  descricao TEXT,' +
    '  unidade TEXT,' +
    '  embalagem TEXT,' +
    '  qt REAL DEFAULT 0,' +
    '  qtunit REAL DEFAULT 1,' +
    '  punit REAL DEFAULT 0,' +
    '  vlprod REAL DEFAULT 0,' +
    '  vldesconto REAL DEFAULT 0,' +
    '  vldescitem REAL DEFAULT 0,' +
    '  vldesc_atacado REAL DEFAULT 0,' +
    '  ncm TEXT,' +
    '  extipi TEXT,' +
    '  cfop TEXT,' +
    '  cest TEXT,' +
    '  icms_cst TEXT,' +
    '  csosn TEXT,' +
    '  prod_origem TEXT,' +
    '  aliqicms REAL DEFAULT 0,' +
    '  icms_percbasered REAL DEFAULT 0,' +
    '  pis_cst TEXT,' +
    '  cofins_cst TEXT,' +
    '  aliqpis REAL DEFAULT 0,' +
    '  aliqcofins REAL DEFAULT 0,' +
    '  valorpis REAL DEFAULT 0,' +
    '  valorcofins REAL DEFAULT 0,' +
    '  impleitransparencia REAL DEFAULT 0,' +
    '  codvendedor INTEGER DEFAULT 0,' +
    '  codoperador INTEGER DEFAULT 0,' +
    '  dtcancel TEXT,' +
    '  obscancel TEXT,' +
    '  emoferta TEXT DEFAULT ''N'',' +
    '  origemregistro TEXT,' +
    '  ptabela REAL DEFAULT 0,' +
    '  ptabelaatac REAL DEFAULT 0,' +
    '  qtminiatac REAL DEFAULT 0,' +
    '  codfilial TEXT,' +
    '  numcaixa INTEGER DEFAULT 0,' +
    '  numserieequip TEXT,' +
    '  numcupom REAL DEFAULT 0,' +
    '  numseqfechamento TEXT,' +
    '  cbenef TEXT' +
    ')'
  );

  // Pagamentos do Cupom
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS cupom_pagamentos (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  cupom_id INTEGER NOT NULL REFERENCES cupons(id),' +
    '  codcob TEXT,' +
    '  valor REAL DEFAULT 0,' +
    '  indice TEXT,' +
    '  numbanco INTEGER DEFAULT 0,' +
    '  numagencia TEXT,' +
    '  numcontacorrente TEXT,' +
    '  numcheque TEXT,' +
    '  numcmc7 TEXT,' +
    '  cpf_cnpj_cheque TEXT,' +
    '  dtpredatado TEXT,' +
    '  codsupervisorautoriz INTEGER DEFAULT 0,' +
    '  codtipotransacao INTEGER DEFAULT 0,' +
    '  codmodotransacao INTEGER DEFAULT 0,' +
    '  codbandeira INTEGER DEFAULT 0,' +
    '  codrede INTEGER DEFAULT 0,' +
    '  codautorizacao TEXT,' +
    '  nsu TEXT,' +
    '  numparcela INTEGER DEFAULT 0,' +
    '  qtdeparcela INTEGER DEFAULT 0,' +
    '  valorparcela REAL DEFAULT 0,' +
    '  numcartao TEXT,' +
    '  codplpag INTEGER DEFAULT 0,' +
    '  dtvenc TEXT,' +
    '  impresso TEXT DEFAULT ''N'',' +
    '  vinculado TEXT DEFAULT ''N'',' +
    '  numvias INTEGER DEFAULT 1,' +
    '  cupomvinculadoloja TEXT,' +
    '  cupomvinculadocliente TEXT,' +
    '  dthroperacao TEXT,' +
    '  tipo_pos TEXT,' +
    '  numdocfinaliz TEXT' +
    ')'
  );

  // Numerario (Sangria/Suprimento)
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS numerario (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  tipo TEXT NOT NULL,' +
    '  valor REAL DEFAULT 0,' +
    '  dthora TEXT,' +
    '  codoperador INTEGER,' +
    '  codsupervisor INTEGER DEFAULT 0,' +
    '  motivo TEXT,' +
    '  codfilial TEXT,' +
    '  numcaixa INTEGER,' +
    '  codcob TEXT,' +
    '  sincronizado INTEGER DEFAULT 0' +
    ')'
  );

  // Credito do Cliente
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS creditos_cliente (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  codcli INTEGER,' +
    '  valor REAL DEFAULT 0,' +
    '  tipo TEXT,' +
    '  historico TEXT,' +
    '  numnota REAL DEFAULT 0,' +
    '  serie TEXT,' +
    '  dthora TEXT,' +
    '  numserieequip TEXT,' +
    '  cpf TEXT,' +
    '  sincronizado INTEGER DEFAULT 0' +
    ')'
  );

  // TEF Pendentes (transacoes TEF aguardando confirmacao/desfazimento)
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS tef_pendentes (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  cupom_id INTEGER NOT NULL REFERENCES cupons(id),' +
    '  controle TEXT NOT NULL,' +
    '  nsu TEXT,' +
    '  cod_autorizacao TEXT,' +
    '  valor REAL DEFAULT 0,' +
    '  tipo_transacao TEXT,' +
    '  bandeira TEXT,' +
    '  parcelas INTEGER DEFAULT 1,' +
    '  codcob TEXT,' +
    '  status TEXT DEFAULT ''PENDENTE'',' +
    '  dthr_transacao TEXT,' +
    '  dthr_confirmacao TEXT,' +
    '  comprovante_cliente TEXT DEFAULT '''',' +
    '  comprovante_loja TEXT DEFAULT ''''' +
    ')'
  );

  // Pre-vendas importadas
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS prevenda (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  numtrans INTEGER,' +
    '  numped INTEGER,' +
    '  data TEXT,' +
    '  codcob TEXT,' +
    '  codplpag INTEGER DEFAULT 0,' +
    '  codcli INTEGER DEFAULT 0,' +
    '  obs TEXT,' +
    '  conteudo TEXT,' +
    '  dt_importacao TEXT,' +
    '  processado INTEGER DEFAULT 0' +
    ')'
  );

  // Itens da Pre-Venda
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS prevenda_itens (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  prevenda_id INTEGER REFERENCES prevenda(id),' +
    '  numseqitem INTEGER,' +
    '  codprod INTEGER,' +
    '  codbarra TEXT,' +
    '  descricao TEXT,' +
    '  unidade TEXT,' +
    '  qt REAL DEFAULT 0,' +
    '  punit REAL DEFAULT 0,' +
    '  vlprod REAL DEFAULT 0,' +
    '  codvendedor INTEGER DEFAULT 0' +
    ')'
  );
end;

procedure TSQLiteDB.CriarTabelasControle;
begin
  // NFCe Contingencia (NOVO - correcao principal)
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS nfce_contingencia (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  cupom_id INTEGER REFERENCES cupons(id),' +
    '  tipo_contingencia TEXT NOT NULL,' +
    '  xml_path TEXT,' +
    '  xml_conteudo TEXT,' +
    '  chave_nfe TEXT,' +
    '  numnota INTEGER DEFAULT 0,' +
    '  dt_geracao TEXT NOT NULL,' +
    '  dt_contingencia_inicio TEXT,' +
    '  justificativa TEXT,' +
    '  status TEXT DEFAULT ''PENDENTE'',' +
    '  protocolo TEXT,' +
    '  motivo_rejeicao TEXT,' +
    '  dt_envio TEXT,' +
    '  tentativas INTEGER DEFAULT 0,' +
    '  ultimo_erro TEXT,' +
    '  dt_ultima_tentativa TEXT,' +
    '  dt_descarte TEXT,' +
    '  descartado_por INTEGER DEFAULT 0' +
    ')'
  );

  // Estado do Caixa (substitui TinyDB)
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS estado_caixa (' +
    '  chave TEXT PRIMARY KEY,' +
    '  valor TEXT,' +
    '  dt_atualizacao TEXT' +
    ')'
  );

  // Log de Sincronizacao
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS sync_log (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  tabela TEXT,' +
    '  operacao TEXT,' +
    '  registro_id TEXT,' +
    '  dt_operacao TEXT,' +
    '  status TEXT DEFAULT ''PENDENTE'',' +
    '  erro TEXT,' +
    '  tentativas INTEGER DEFAULT 0' +
    ')'
  );

  // Versao do banco
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS db_version (' +
    '  versao INTEGER PRIMARY KEY,' +
    '  dt_aplicacao TEXT,' +
    '  descricao TEXT' +
    ')'
  );

  // Sequencias (controle de numeracao)
  ExecutarSQL(
    'CREATE TABLE IF NOT EXISTS sequencias (' +
    '  nome TEXT PRIMARY KEY,' +
    '  valor_atual INTEGER DEFAULT 0,' +
    '  valor_reservado INTEGER DEFAULT 0,' +
    '  dt_reserva TEXT' +
    ')'
  );
end;

procedure TSQLiteDB.CriarIndices;
begin
  // Produtos
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_produtos_codbarra ON produtos(codbarra)');
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_produtos_descricao ON produtos(descricao)');

  // Clientes
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_clientes_cpf_cnpj ON clientes(cpf_cnpj)');
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_clientes_nome ON clientes(nome)');

  // Cupons
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_cupons_datamovto ON cupons(datamovto)');
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_cupons_numcupom ON cupons(numcupom)');
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_cupons_chavenfe ON cupons(chavenfe)');
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_cupons_sincronizado ON cupons(sincronizado)');
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_cupons_estadoenvio ON cupons(estadoenvio)');

  // Itens
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_cupom_itens_cupom_id ON cupom_itens(cupom_id)');
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_cupom_itens_codprod ON cupom_itens(codprod)');

  // Pagamentos
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_cupom_pagamentos_cupom_id ON cupom_pagamentos(cupom_id)');

  // NFCe Contingencia
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_nfce_cont_status ON nfce_contingencia(status)');
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_nfce_cont_chave ON nfce_contingencia(chave_nfe)');
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_nfce_cont_cupom ON nfce_contingencia(cupom_id)');

  // TEF Pendentes
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_tef_pendentes_cupom ON tef_pendentes(cupom_id)');
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_tef_pendentes_status ON tef_pendentes(status)');

  // Sync log
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_sync_log_status ON sync_log(status)');
  ExecutarSQL('CREATE INDEX IF NOT EXISTS idx_sync_log_tabela ON sync_log(tabela)');
end;

function TSQLiteDB.Ofuscar(const ATexto, AChave: string): string;
var
  I, J: Integer;
begin
  J := 1;
  Result := '';
  for I := 1 to Length(ATexto) do
  begin
    if J > Length(AChave) then
      J := 1;
    Result := Result + Chr(Ord(ATexto[I]) xor Ord(AChave[J]));
    Inc(J);
  end;
end;

procedure TSQLiteDB.InserirDadosTeste;
var
  LCount: Variant;
begin
  // So insere se as tabelas estiverem vazias
  LCount := ExecutarScalar('SELECT COUNT(*) FROM funcionarios');
  if VarToStr(LCount) <> '0' then
    Exit;

  // === FUNCIONARIOS ===
  // Senha de teste: '1' para todos
  // admin/1, caixa/1
  ExecutarSQL(
    'INSERT INTO funcionarios (matricula, nome, senhadb, usuario, cargo, ind_vendedor) VALUES ' +
    '(1, ''Administrador'', ''1'', ''admin'', ''Gerente'', ''S'')'
  );
  ExecutarSQL(
    'INSERT INTO funcionarios (matricula, nome, senhadb, usuario, cargo, ind_vendedor) VALUES ' +
    '(2, ''Operador Caixa'', ''1'', ''caixa'', ''Caixa'', ''N'')'
  );

  // === PERMISSOES ===
  // codcontrole segue a numeracao da rotina 8002 no Oracle (mssubrotina):
  // 2 = Desconto no item, 3 = Desconto no total da venda, 4 = Cancelar item,
  // 5 = Cancelamento da venda, 6 = Fechamento do caixa, 18 = Sangria.
  // A sincronizacao (msacesso codrotina=8002) sobrescreve esta tabela; o seed
  // apenas garante acesso total ao admin (matricula=1) para uso offline/1o acesso.
  ExecutarSQL('INSERT INTO permissoes (matricula, codcontrole) VALUES (1, 1)');
  ExecutarSQL('INSERT INTO permissoes (matricula, codcontrole) VALUES (1, 2)');  // Desconto no item
  ExecutarSQL('INSERT INTO permissoes (matricula, codcontrole) VALUES (1, 3)');  // Desconto na venda
  ExecutarSQL('INSERT INTO permissoes (matricula, codcontrole) VALUES (1, 4)');  // Cancelar item
  ExecutarSQL('INSERT INTO permissoes (matricula, codcontrole) VALUES (1, 5)');  // Cancelar venda
  ExecutarSQL('INSERT INTO permissoes (matricula, codcontrole) VALUES (1, 6)');  // Fechar caixa
  ExecutarSQL('INSERT INTO permissoes (matricula, codcontrole) VALUES (1, 7)');
  ExecutarSQL('INSERT INTO permissoes (matricula, codcontrole) VALUES (1, 18)'); // Sangria
  ExecutarSQL('INSERT INTO permissoes (matricula, codcontrole) VALUES (1, 99)');

  // === EMPRESA ===
  ExecutarSQL(
    'INSERT INTO empresa (id, razao_social, fantasia, cnpj, ie, ' +
    'endereco, bairro, cidade, uf, cep, cod_cidade_ibge, regime_tributario) VALUES ' +
    '(1, ''EMPRESA TESTE LTDA'', ''APOLO TESTE'', ''12345678000199'', ''123456789'', ' +
    '''Rua Teste 123'', ''Centro'', ''Sao Paulo'', ''SP'', ''01001000'', ''3550308'', 1)'
  );

  // === MEIOS DE PAGAMENTO ===
  ExecutarSQL('INSERT INTO meios_pagamento (codcob, descricao, tipo, ativo) VALUES (''01'', ''Dinheiro'', ''DINHEIRO'', 1)');
  ExecutarSQL('INSERT INTO meios_pagamento (codcob, descricao, tipo, ativo) VALUES (''02'', ''Cartao Debito'', ''CARTAO_DEBITO'', 1)');
  ExecutarSQL('INSERT INTO meios_pagamento (codcob, descricao, tipo, ativo) VALUES (''03'', ''Cartao Credito'', ''CARTAO_CREDITO'', 1)');
  ExecutarSQL('INSERT INTO meios_pagamento (codcob, descricao, tipo, ativo) VALUES (''04'', ''Cheque'', ''CHEQUE'', 1)');
  ExecutarSQL('INSERT INTO meios_pagamento (codcob, descricao, tipo, ativo) VALUES (''05'', ''PIX'', ''PIX'', 1)');
  ExecutarSQL('INSERT INTO meios_pagamento (codcob, descricao, tipo, ativo) VALUES (''06'', ''Cobranca'', ''COBRANCA'', 1)');

  // === PRODUTOS DE TESTE ===
  ExecutarSQL(
    'INSERT INTO produtos (codprod, codbarra, descricao, unidade, embalagem, ' +
    'pvenda, pvendaatac, poferta, qtminiatac, pesovariavel, ' +
    'permite_dig_preco, permite_dig_desc, permite_dig_qtde, maxperdesc, ' +
    'ncm, cfop, cest, icms_cst, csosn, aliqicms, ' +
    'pis_cst, cofins_cst, pis_ppis, cofins_pcofins, impleitransparencia, qtdisponivel) VALUES ' +
    '(1, ''7891000100101'', ''COCA-COLA 2L'', ''UN'', ''UN'', ' +
    '8.90, 7.50, 0, 0, ''N'', ' +
    '''S'', ''S'', ''S'', 10.0, ' +
    '''22021000'', ''5102'', ''0301100'', ''00'', ''0102'', 18.0, ' +
    '''01'', ''01'', 1.65, 7.60, 32.15, 500)'
  );
  ExecutarSQL(
    'INSERT INTO produtos (codprod, codbarra, descricao, unidade, embalagem, ' +
    'pvenda, pvendaatac, poferta, qtminiatac, pesovariavel, ' +
    'permite_dig_preco, permite_dig_desc, permite_dig_qtde, maxperdesc, ' +
    'ncm, cfop, cest, icms_cst, csosn, aliqicms, ' +
    'pis_cst, cofins_cst, pis_ppis, cofins_pcofins, impleitransparencia, qtdisponivel) VALUES ' +
    '(2, ''7891000200202'', ''ARROZ TIPO 1 5KG'', ''UN'', ''PCT'', ' +
    '22.90, 20.00, 19.90, 10, ''N'', ' +
    '''S'', ''S'', ''S'', 5.0, ' +
    '''10063021'', ''5102'', ''1703100'', ''00'', ''0102'', 7.0, ' +
    '''01'', ''01'', 1.65, 7.60, 22.30, 200)'
  );
  ExecutarSQL(
    'INSERT INTO produtos (codprod, codbarra, descricao, unidade, embalagem, ' +
    'pvenda, pvendaatac, poferta, qtminiatac, pesovariavel, ' +
    'permite_dig_preco, permite_dig_desc, permite_dig_qtde, maxperdesc, ' +
    'ncm, cfop, cest, icms_cst, csosn, aliqicms, ' +
    'pis_cst, cofins_cst, pis_ppis, cofins_pcofins, impleitransparencia, qtdisponivel) VALUES ' +
    '(3, ''7891000300303'', ''FEIJAO CARIOCA 1KG'', ''UN'', ''PCT'', ' +
    '7.49, 6.50, 0, 0, ''N'', ' +
    '''S'', ''S'', ''S'', 10.0, ' +
    '''07133319'', ''5102'', ''1703100'', ''00'', ''0102'', 0.0, ' +
    '''01'', ''01'', 1.65, 7.60, 18.50, 300)'
  );
  ExecutarSQL(
    'INSERT INTO produtos (codprod, codbarra, descricao, unidade, embalagem, ' +
    'pvenda, pvendaatac, poferta, qtminiatac, pesovariavel, ' +
    'permite_dig_preco, permite_dig_desc, permite_dig_qtde, maxperdesc, ' +
    'ncm, cfop, cest, icms_cst, csosn, aliqicms, ' +
    'pis_cst, cofins_cst, pis_ppis, cofins_pcofins, impleitransparencia, qtdisponivel) VALUES ' +
    '(4, ''7891000400404'', ''OLEO SOJA 900ML'', ''UN'', ''UN'', ' +
    '5.99, 5.20, 4.99, 12, ''N'', ' +
    '''S'', ''S'', ''S'', 8.0, ' +
    '''15079011'', ''5102'', ''1703100'', ''00'', ''0102'', 12.0, ' +
    '''01'', ''01'', 1.65, 7.60, 25.80, 150)'
  );
  ExecutarSQL(
    'INSERT INTO produtos (codprod, codbarra, descricao, unidade, embalagem, ' +
    'pvenda, pvendaatac, poferta, qtminiatac, pesovariavel, ' +
    'permite_dig_preco, permite_dig_desc, permite_dig_qtde, maxperdesc, ' +
    'ncm, cfop, cest, icms_cst, csosn, aliqicms, ' +
    'pis_cst, cofins_cst, pis_ppis, cofins_pcofins, impleitransparencia, qtdisponivel) VALUES ' +
    '(5, ''0000000000000'', ''PRODUTO GENERICO KG'', ''KG'', ''KG'', ' +
    '15.00, 12.00, 0, 0, ''S'', ' +
    '''S'', ''S'', ''S'', 15.0, ' +
    '''02013000'', ''5102'', ''0301100'', ''00'', ''0102'', 18.0, ' +
    '''01'', ''01'', 1.65, 7.60, 29.50, 1000)'
  );

  // === CLIENTES ===
  ExecutarSQL(
    'INSERT INTO clientes (codcli, cpf_cnpj, nome, endereco, bairro, cidade, uf, cep, telefone, limite_credito) VALUES ' +
    '(1, ''12345678000199'', ''EMPRESA CLIENTE TESTE'', ''Rua Cliente 100'', ''Centro'', ''Sao Paulo'', ''SP'', ''01001000'', ''1133334444'', 5000.00)'
  );
  ExecutarSQL(
    'INSERT INTO clientes (codcli, cpf_cnpj, nome, endereco, bairro, cidade, uf, cep, telefone, limite_credito) VALUES ' +
    '(2, ''98765432100'', ''JOAO CONSUMIDOR'', ''Av Brasil 500'', ''Jardim'', ''Campinas'', ''SP'', ''13000000'', ''1999998888'', 1000.00)'
  );

  // === PARAMETROS ===
  ExecutarSQL('INSERT INTO parametros (parametro, conteudo, numcaixa) VALUES (''NUMCAIXA'', ''1'', 1)');
  ExecutarSQL('INSERT INTO parametros (parametro, conteudo, numcaixa) VALUES (''SERIE_NFCE'', ''1'', 1)');
  ExecutarSQL('INSERT INTO parametros (parametro, conteudo, numcaixa) VALUES (''NUMSERIEEQUIP'', ''AW001'', 1)');

  // === ESTADO INICIAL DO CAIXA ===
  SalvarEstado('ESTADO', '0');      // ecFechado
  SalvarEstado('NUMCAIXA', '1');
  SalvarEstado('NUMSERIEEQUIP', 'AW001');
  SalvarEstado('PROX_NUM_CUPOM', '1');
  SalvarEstado('MATRICULA', '0');
  SalvarEstado('OPERADOR', '');
  SalvarEstado('TOTAL_DINHEIRO', '0');
end;

end.
