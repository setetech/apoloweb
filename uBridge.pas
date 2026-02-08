unit uBridge;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Variants, System.DateUtils, System.Math, System.StrUtils, Uni,
  uSQLiteDB, uConstantesWeb, uTypesApoloWeb,Data.DB;


type
  TOnGerarNFCeEvent = procedure(ACupomId: Integer; var AChaveNFe, AProtocolo: string) of object;
  TOnRetransmitirEvent = procedure(var AQtdEnviados, AQtdErros: Integer) of object;
  TOnSincronizarEvent = procedure of object;

  TApoloBridge = class
  private
    FSQLite: TSQLiteDB;
    FCupomAtualId: Integer;
    FMatriculaLogada: Integer;
    FNomeOperador: string;
    FEstadoCaixa: TEstadoCaixa;
    FContingencia: TTipoContingencia;
    FOnGerarNFCe: TOnGerarNFCeEvent;
    FOnRetransmitir: TOnRetransmitirEvent;
    FOnSincronizar: TOnSincronizarEvent;

    // Autenticacao
    function DoLogin(const AData: string): string;
    function DoObterPermissoes(const AData: string): string;

    // Produtos
    function DoBuscarProduto(const AData: string): string;
    function DoListarProdutos(const AData: string): string;

    // Venda
    function DoIniciarVenda(const AData: string): string;
    function DoAdicionarItem(const AData: string): string;
    function DoRemoverItem(const AData: string): string;
    function DoAplicarDesconto(const AData: string): string;
    function DoCancelarVenda(const AData: string): string;
    function DoObterItensCupom(const AData: string): string;
    function DoObterResumoCupom(const AData: string): string;

    // Pagamento
    function DoRegistrarPagamento(const AData: string): string;
    function DoRemoverPagamento(const AData: string): string;
    function DoFinalizarVenda(const AData: string): string;
    function DoListarMeiosPagamento(const AData: string): string;
    function DoObterResumoPagamento(const AData: string): string;

    // Caixa
    function DoAbrirCaixa(const AData: string): string;
    function DoFecharCaixa(const AData: string): string;
    function DoEfetuarSangria(const AData: string): string;
    function DoEfetuarSuprimento(const AData: string): string;
    function DoObterEstadoCaixa(const AData: string): string;

    // NFCe
    function DoGerarNFCe(const AData: string): string;
    function DoListarNFCePendentes(const AData: string): string;
    function DoRetransmitirContingencia(const AData: string): string;

    // Contingencia
    function DoObterStatusConexao(const AData: string): string;
    function DoEntrarContingencia(const AData: string): string;
    function DoSairContingencia(const AData: string): string;
    function DoListarDocContingencia(const AData: string): string;

    // Clientes
    function DoBuscarCliente(const AData: string): string;
    function DoIdentificarConsumidor(const AData: string): string;
    function DoVincularCliente(const AData: string): string;

    // Vendedor
    function DoBuscarVendedor(const AData: string): string;

    // Pre-Venda
    function DoListarPreVendas(const AData: string): string;
    function DoImportarPreVenda(const AData: string): string;

    // Utilidades internas
    function CriarRespostaSucesso(const AMensagem: string; ADados: TJSONValue = nil): string;
    function CriarRespostaErro(const AMensagem: string): string;
    function ObterProximoNumCupom: Integer;
    function CalcularTotalCupom(ACupomId: Integer): Double;
    function CalcularTotalPago(ACupomId: Integer): Double;
    function ValidarSenha(AMatricula: Integer; const ASenha: string): Boolean;
    function PossuiAcesso(AMatricula, ACodControle: Integer): Boolean;
  public
    constructor Create(AOwner: TComponent; ASQLite: TSQLiteDB);
    destructor Destroy; override;

    function ProcessarAcao(const AAction, AData: string): string;

    property SQLite: TSQLiteDB read FSQLite;
    property CupomAtualId: Integer read FCupomAtualId;
    property MatriculaLogada: Integer read FMatriculaLogada;
    property NomeOperador: string read FNomeOperador;
    property EstadoCaixa: TEstadoCaixa read FEstadoCaixa;
    property Contingencia: TTipoContingencia read FContingencia;
    property OnGerarNFCe: TOnGerarNFCeEvent read FOnGerarNFCe write FOnGerarNFCe;
    property OnRetransmitir: TOnRetransmitirEvent read FOnRetransmitir write FOnRetransmitir;
    property OnSincronizar: TOnSincronizarEvent read FOnSincronizar write FOnSincronizar;
  end;

implementation

{ TApoloBridge }

constructor TApoloBridge.Create(AOwner: TComponent; ASQLite: TSQLiteDB);
begin
  inherited Create;
  FSQLite := ASQLite;
  FCupomAtualId := 0;
  FMatriculaLogada := 0;
  FEstadoCaixa := ecFechado;
  FContingencia := tcNenhuma;

  // Restaurar estado do caixa
  FEstadoCaixa := TEstadoCaixa.FromInteger(
    StrToIntDef(FSQLite.ObterEstado(KEY_ESTADO, '0'), 0)
  );
  FMatriculaLogada := StrToIntDef(FSQLite.ObterEstado(KEY_MATRICULA, '0'), 0);
  FNomeOperador := FSQLite.ObterEstado(KEY_OPERADOR, '');
end;

destructor TApoloBridge.Destroy;
begin
  inherited;
end;

function TApoloBridge.ProcessarAcao(const AAction, AData: string): string;
begin
  try
    // Autenticacao
    if AAction = 'login' then Result := DoLogin(AData)
    else if AAction = 'obterPermissoes' then Result := DoObterPermissoes(AData)
    // Produtos
    else if AAction = 'buscarProduto' then Result := DoBuscarProduto(AData)
    else if AAction = 'listarProdutos' then Result := DoListarProdutos(AData)
    // Venda
    else if AAction = 'iniciarVenda' then Result := DoIniciarVenda(AData)
    else if AAction = 'adicionarItem' then Result := DoAdicionarItem(AData)
    else if AAction = 'removerItem' then Result := DoRemoverItem(AData)
    else if AAction = 'aplicarDesconto' then Result := DoAplicarDesconto(AData)
    else if AAction = 'cancelarVenda' then Result := DoCancelarVenda(AData)
    else if AAction = 'obterItensCupom' then Result := DoObterItensCupom(AData)
    else if AAction = 'obterResumoCupom' then Result := DoObterResumoCupom(AData)
    // Pagamento
    else if AAction = 'registrarPagamento' then Result := DoRegistrarPagamento(AData)
    else if AAction = 'removerPagamento' then Result := DoRemoverPagamento(AData)
    else if AAction = 'finalizarVenda' then Result := DoFinalizarVenda(AData)
    else if AAction = 'listarMeiosPagamento' then Result := DoListarMeiosPagamento(AData)
    else if AAction = 'obterResumoPagamento' then Result := DoObterResumoPagamento(AData)
    // Caixa
    else if AAction = 'abrirCaixa' then Result := DoAbrirCaixa(AData)
    else if AAction = 'fecharCaixa' then Result := DoFecharCaixa(AData)
    else if AAction = 'efetuarSangria' then Result := DoEfetuarSangria(AData)
    else if AAction = 'efetuarSuprimento' then Result := DoEfetuarSuprimento(AData)
    else if AAction = 'obterEstadoCaixa' then Result := DoObterEstadoCaixa(AData)
    // NFCe
    else if AAction = 'gerarNFCe' then Result := DoGerarNFCe(AData)
    else if AAction = 'listarNFCePendentes' then Result := DoListarNFCePendentes(AData)
    else if AAction = 'retransmitirContingencia' then Result := DoRetransmitirContingencia(AData)
    // Contingencia
    else if AAction = 'obterStatusConexao' then Result := DoObterStatusConexao(AData)
    else if AAction = 'entrarContingencia' then Result := DoEntrarContingencia(AData)
    else if AAction = 'sairContingencia' then Result := DoSairContingencia(AData)
    else if AAction = 'listarDocContingencia' then Result := DoListarDocContingencia(AData)
    // Clientes
    else if AAction = 'buscarCliente' then Result := DoBuscarCliente(AData)
    else if AAction = 'identificarConsumidor' then Result := DoIdentificarConsumidor(AData)
    else if AAction = 'vincularCliente' then Result := DoVincularCliente(AData)
    // Vendedor
    else if AAction = 'buscarVendedor' then Result := DoBuscarVendedor(AData)
    // Pre-venda
    else if AAction = 'listarPreVendas' then Result := DoListarPreVendas(AData)
    else if AAction = 'importarPreVenda' then Result := DoImportarPreVenda(AData)
    else
      Result := CriarRespostaErro('Acao desconhecida: ' + AAction);
  except
    on E: Exception do
      Result := CriarRespostaErro('Erro: ' + E.Message);
  end;
end;

// =========================================================================
// RESPOSTAS
// =========================================================================

function TApoloBridge.CriarRespostaSucesso(const AMensagem: string;
  ADados: TJSONValue): string;
var
  LJson: TJSONObject;
begin
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('sucesso', TJSONBool.Create(True));
    LJson.AddPair('mensagem', AMensagem);
    if ADados <> nil then
      LJson.AddPair('dados', ADados)
    else
      LJson.AddPair('dados', TJSONObject.Create);
    Result := LJson.ToJSON;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.CriarRespostaErro(const AMensagem: string): string;
var
  LJson: TJSONObject;
begin
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('sucesso', TJSONBool.Create(False));
    LJson.AddPair('mensagem', AMensagem);
    LJson.AddPair('dados', TJSONObject.Create);
    Result := LJson.ToJSON;
  finally
    LJson.Free;
  end;
end;

// =========================================================================
// AUTENTICACAO
// =========================================================================

function TApoloBridge.DoLogin(const AData: string): string;
var
  LJson: TJSONObject;
  LMatricula: Integer;
  LSenha: string;
  LQuery: TUniQuery;
  LDados: TJSONObject;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LMatricula := LJson.GetValue<Integer>('matricula', 0);
    LSenha := LJson.GetValue<string>('senha', '');

    if LMatricula = 0 then
      Exit(CriarRespostaErro('Informe a matricula'));

    if not ValidarSenha(LMatricula, LSenha) then
      Exit(CriarRespostaErro('Matricula ou senha invalida'));

    // Obter dados do funcionario
    LQuery := FSQLite.ExecutarSelect(
      'SELECT matricula, nome, cargo FROM funcionarios WHERE matricula = ' +
      IntToStr(LMatricula)
    );
    try
      if LQuery.IsEmpty then
        Exit(CriarRespostaErro('Funcionario nao encontrado'));

      FMatriculaLogada := LMatricula;
      FNomeOperador := LQuery.FieldByName('nome').AsString;

      FSQLite.SalvarEstado(KEY_MATRICULA, IntToStr(LMatricula));
      FSQLite.SalvarEstado(KEY_OPERADOR, FNomeOperador);

      // Sincronizar dados (produtos, funcionarios, etc.) do Oracle
      if Assigned(FOnSincronizar) then
      begin
        try
          FOnSincronizar;
        except
          // Falha na sync nao impede o login (pode estar offline)
        end;
      end;

      LDados := TJSONObject.Create;
      LDados.AddPair('matricula', TJSONNumber.Create(LMatricula));
      LDados.AddPair('nome', LQuery.FieldByName('nome').AsString);
      LDados.AddPair('cargo', LQuery.FieldByName('cargo').AsString);
      LDados.AddPair('estadoCaixa', TJSONNumber.Create(Ord(FEstadoCaixa)));

      Result := CriarRespostaSucesso('Login realizado com sucesso', LDados);
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.ValidarSenha(AMatricula: Integer;
  const ASenha: string): Boolean;
var
  LQuery: TUniQuery;
  LSenhaDB, LUsuario: string;
begin
  Result := False;

  LQuery := FSQLite.ExecutarSelect(
    'SELECT senhadb, usuario FROM funcionarios WHERE matricula = ' +
    IntToStr(AMatricula)
  );
  try
    if LQuery.IsEmpty then Exit;

    LSenhaDB := LQuery.FieldByName('senhadb').AsString;
    LUsuario := LQuery.FieldByName('usuario').AsString;
    Result := (UpperCase(ASenha) = UpperCase(LSenhaDB));

    // Ofuscar a senha informada com a mesma logica do sistema original
    //LSenhaOfuscada := Ofuscar(ASenha, LUsuario);
    //Result := (LSenhaOfuscada = LSenhaDB);
  finally
    LQuery.Free;
  end;
end;


function TApoloBridge.PossuiAcesso(AMatricula, ACodControle: Integer): Boolean;
var
  LVal: Variant;
begin
  LVal := FSQLite.ExecutarScalar(
    'SELECT COUNT(*) FROM permissoes WHERE matricula = ' +
    IntToStr(AMatricula) + ' AND codcontrole = ' + IntToStr(ACodControle)
  );
  Result := (not VarIsNull(LVal)) and (LVal > 0);
end;

function TApoloBridge.DoObterPermissoes(const AData: string): string;
var
  LJson: TJSONObject;
  LMatricula: Integer;
  LQuery: TUniQuery;
  LArr: TJSONArray;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LMatricula := LJson.GetValue<Integer>('matricula', FMatriculaLogada);

    LQuery := FSQLite.ExecutarSelect(
      'SELECT codcontrole FROM permissoes WHERE matricula = ' +
      IntToStr(LMatricula)
    );
    try
      LArr := TJSONArray.Create;
      while not LQuery.Eof do
      begin
        LArr.Add(LQuery.FieldByName('codcontrole').AsInteger);
        LQuery.Next;
      end;

      Result := CriarRespostaSucesso('OK', LArr);
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

// =========================================================================
// PRODUTOS
// =========================================================================

function TApoloBridge.DoBuscarProduto(const AData: string): string;
var
  LJson: TJSONObject;
  LCodigo: string;
  LQuery: TUniQuery;
  LProd, LItem: TJSONObject;
  LArray: TJSONArray;
  LSQL: string;
  LEhNumerico: Boolean;
  I: Integer;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LCodigo := Trim(LJson.GetValue<string>('codigo', ''));
    if LCodigo = '' then
      Exit(CriarRespostaErro('Informe o codigo ou codigo de barras'));

    // Verificar se o texto eh numerico (codigo/barras) ou descricao
    LEhNumerico := True;
    for I := 1 to Length(LCodigo) do
      if not CharInSet(LCodigo[I], ['0'..'9']) then
      begin
        LEhNumerico := False;
        Break;
      end;

    // Peso variavel: codigo de barras com 13 digitos comecando com 2
    if LEhNumerico and (Length(LCodigo) = 13) and (LCodigo[1] = '2') then
    begin
      LSQL := 'SELECT * FROM produtos WHERE codbarra LIKE ''' +
        Copy(LCodigo, 1, 7) + '%'' OR codbarra = ''' + LCodigo + ''' LIMIT 20';
    end
    else if LEhNumerico then
    begin
      // Busca exata por codigo de barras ou codprod
      LSQL := 'SELECT * FROM produtos WHERE codbarra = ''' +
        LCodigo + ''' OR CAST(codprod AS TEXT) = ''' + LCodigo + ''' LIMIT 20';
    end
    else
    begin
      // Busca parcial por descricao (case-insensitive)
      LSQL := 'SELECT * FROM produtos WHERE UPPER(descricao) LIKE ''%' +
        AnsiUpperCase(StringReplace(LCodigo, '''', '''''', [rfReplaceAll])) +
        '%'' LIMIT 20';
    end;

    LQuery := FSQLite.ExecutarSelect(LSQL);
    try
      if LQuery.IsEmpty then
        Exit(CriarRespostaErro('Produto nao encontrado'));

      // Se retornou exatamente 1 registro, devolver como produto unico
      // Se retornou varios, devolver como lista para o frontend escolher
      if (LQuery.RecordCount = 1) or LEhNumerico then
      begin
        // Resultado unico (compativel com fluxo existente)
        LProd := TJSONObject.Create;
        LProd.AddPair('codprod', TJSONNumber.Create(LQuery.FieldByName('codprod').AsLargeInt));
        LProd.AddPair('codbarra', LQuery.FieldByName('codbarra').AsString);
        LProd.AddPair('descricao', LQuery.FieldByName('descricao').AsString);
        LProd.AddPair('unidade', LQuery.FieldByName('unidade').AsString);
        LProd.AddPair('embalagem', LQuery.FieldByName('embalagem').AsString);
        LProd.AddPair('pvenda', TJSONNumber.Create(LQuery.FieldByName('pvenda').AsFloat));
        LProd.AddPair('pvendaatac', TJSONNumber.Create(LQuery.FieldByName('pvendaatac').AsFloat));
        LProd.AddPair('poferta', TJSONNumber.Create(LQuery.FieldByName('poferta').AsFloat));
        LProd.AddPair('dtfimoferta', LQuery.FieldByName('dtfimoferta').AsString);
        LProd.AddPair('qtminiatac', TJSONNumber.Create(LQuery.FieldByName('qtminiatac').AsInteger));
        LProd.AddPair('pesovariavel', LQuery.FieldByName('pesovariavel').AsString);
        LProd.AddPair('permite_dig_preco', LQuery.FieldByName('permite_dig_preco').AsString);
        LProd.AddPair('permite_dig_desc', LQuery.FieldByName('permite_dig_desc').AsString);
        LProd.AddPair('permite_dig_qtde', LQuery.FieldByName('permite_dig_qtde').AsString);
        LProd.AddPair('maxperdesc', TJSONNumber.Create(LQuery.FieldByName('maxperdesc').AsFloat));
        LProd.AddPair('ncm', LQuery.FieldByName('ncm').AsString);
        LProd.AddPair('cfop', TJSONNumber.Create(LQuery.FieldByName('cfop').AsFloat));
        LProd.AddPair('cest', LQuery.FieldByName('cest').AsString);
        LProd.AddPair('icms_cst', LQuery.FieldByName('icms_cst').AsString);
        LProd.AddPair('csosn', LQuery.FieldByName('csosn').AsString);
        LProd.AddPair('aliqicms', TJSONNumber.Create(LQuery.FieldByName('aliqicms').AsFloat));
        LProd.AddPair('pis_cst', LQuery.FieldByName('pis_cst').AsString);
        LProd.AddPair('cofins_cst', LQuery.FieldByName('cofins_cst').AsString);
        LProd.AddPair('pis_ppis', TJSONNumber.Create(LQuery.FieldByName('pis_ppis').AsFloat));
        LProd.AddPair('cofins_pcofins', TJSONNumber.Create(LQuery.FieldByName('cofins_pcofins').AsFloat));
        LProd.AddPair('impleitransparencia', TJSONNumber.Create(LQuery.FieldByName('impleitransparencia').AsFloat));

        if (LQuery.FieldByName('poferta').AsFloat > 0) and
           (LQuery.FieldByName('dtfimoferta').AsString >= FormatDateTime('yyyy-mm-dd', Now)) then
          LProd.AddPair('emOferta', TJSONBool.Create(True))
        else
          LProd.AddPair('emOferta', TJSONBool.Create(False));

        Result := CriarRespostaSucesso('Produto encontrado', LProd);
      end
      else
      begin
        // Multiplos resultados - devolver lista para o frontend exibir
        LProd := TJSONObject.Create;
        LArray := TJSONArray.Create;
        while not LQuery.Eof do
        begin
          LItem := TJSONObject.Create;
          LItem.AddPair('codprod', TJSONNumber.Create(LQuery.FieldByName('codprod').AsLargeInt));
          LItem.AddPair('codbarra', LQuery.FieldByName('codbarra').AsString);
          LItem.AddPair('descricao', LQuery.FieldByName('descricao').AsString);
          LItem.AddPair('unidade', LQuery.FieldByName('unidade').AsString);
          LItem.AddPair('pvenda', TJSONNumber.Create(LQuery.FieldByName('pvenda').AsFloat));
          LArray.AddElement(LItem);
          LQuery.Next;
        end;
        LProd.AddPair('produtos', LArray);
        LProd.AddPair('total', TJSONNumber.Create(LArray.Count));
        Result := CriarRespostaSucesso('lista', LProd);
      end;
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoListarProdutos(const AData: string): string;
var
  LJson: TJSONObject;
  LFiltro: string;
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LProd: TJSONObject;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LFiltro := LJson.GetValue<string>('filtro', '');

    if LFiltro = '' then
      Exit(CriarRespostaErro('Informe um filtro de busca'));

    LQuery := FSQLite.ExecutarSelect(
      'SELECT codprod, codbarra, descricao, unidade, embalagem, ' +
      'pvenda, pvendaatac, poferta, dtfimoferta, qtminiatac, qtdisponivel ' +
      'FROM produtos WHERE ' +
      'descricao LIKE ''%' + LFiltro + '%'' OR ' +
      'codbarra LIKE ''%' + LFiltro + '%'' ' +
      'ORDER BY descricao LIMIT 100'
    );
    try
      LArr := TJSONArray.Create;
      while not LQuery.Eof do
      begin
        LProd := TJSONObject.Create;
        LProd.AddPair('codprod', TJSONNumber.Create(LQuery.FieldByName('codprod').AsLargeInt));
        LProd.AddPair('codbarra', LQuery.FieldByName('codbarra').AsString);
        LProd.AddPair('descricao', LQuery.FieldByName('descricao').AsString);
        LProd.AddPair('unidade', LQuery.FieldByName('unidade').AsString);
        LProd.AddPair('embalagem', LQuery.FieldByName('embalagem').AsString);
        LProd.AddPair('pvenda', TJSONNumber.Create(LQuery.FieldByName('pvenda').AsFloat));
        LProd.AddPair('pvendaatac', TJSONNumber.Create(LQuery.FieldByName('pvendaatac').AsFloat));
        LProd.AddPair('poferta', TJSONNumber.Create(LQuery.FieldByName('poferta').AsFloat));
        LProd.AddPair('qtdisponivel', TJSONNumber.Create(LQuery.FieldByName('qtdisponivel').AsFloat));
        LArr.AddElement(LProd);
        LQuery.Next;
      end;

      Result := CriarRespostaSucesso('OK', LArr);
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

// =========================================================================
// VENDA
// =========================================================================

function TApoloBridge.DoIniciarVenda(const AData: string): string;
var
  LNumCupom: Integer;
  LDados: TJSONObject;
begin
  if FEstadoCaixa = ecFechado then
    Exit(CriarRespostaErro('Abra o caixa antes de iniciar uma venda'));

  // Recuperar de venda interrompida (crash/fechamento inesperado)
  if (FEstadoCaixa = ecRegistrando) or (FEstadoCaixa = ecPagamento) then
  begin
    if FCupomAtualId > 0 then
    begin
      FSQLite.ExecutarSQL(
        'UPDATE cupons SET codoper = ''C'', dthrfimvenda = datetime(''now'',''localtime''), ' +
        'obscancel = ''Cancelado automaticamente - venda interrompida'' WHERE id = ' +
        IntToStr(FCupomAtualId)
      );
    end;
    FEstadoCaixa := ecLivre;
    FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));
    FCupomAtualId := 0;
  end;

  if FEstadoCaixa <> ecLivre then
    Exit(CriarRespostaErro('Caixa nao esta livre para nova venda'));

  if FMatriculaLogada = 0 then
    Exit(CriarRespostaErro('Nenhum operador logado'));

  LNumCupom := ObterProximoNumCupom;

  FSQLite.ExecutarSQL(
    'INSERT INTO cupons (codoper, numcaixa, datamovto, dthriniciovenda, ' +
    'codoperador, numcupom, numserieequip, versao, codfilial) ' +
    'VALUES (:p0, :p1, :p2, :p3, :p4, :p5, :p6, :p7, :p8)',
    [
      'V',
      StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '1'), 1),
      FormatDateTime('yyyy-mm-dd', Now),
      FormatDateTime('yyyy-mm-dd hh:nn:ss', Now),
      FMatriculaLogada,
      LNumCupom,
      FSQLite.ObterEstado(KEY_NUMSERIE, ''),
      VERSAO_SISTEMA,
      '01'
    ]
  );

  // Obter o ID gerado
  FCupomAtualId := FSQLite.ExecutarScalar('SELECT last_insert_rowid()');

  // Atualizar estado
  FEstadoCaixa := ecRegistrando;
  FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));

  LDados := TJSONObject.Create;
  LDados.AddPair('cupomId', TJSONNumber.Create(FCupomAtualId));
  LDados.AddPair('numCupom', TJSONNumber.Create(LNumCupom));
  LDados.AddPair('dataInicio', FormatDateTime('dd/mm/yyyy hh:nn:ss', Now));

  Result := CriarRespostaSucesso('Venda iniciada', LDados);
end;

function TApoloBridge.DoAdicionarItem(const AData: string): string;
var
  LJson: TJSONObject;
  LCodProd: Int64;
  LQtde, LPrecoUnit, LValorTotal, LDesconto: Double;
  LQuery: TUniQuery;
  LNumSeq: Integer;
  LDados: TJSONObject;
  LDescricao, LUnidade, LCodBarra: string;
begin
  if FEstadoCaixa <> ecRegistrando then
    Exit(CriarRespostaErro('Nao esta no modo de registro de itens'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LCodProd := LJson.GetValue<Int64>('codprod', 0);
    LQtde := LJson.GetValue<Double>('quantidade', 1);

    if LCodProd = 0 then
      Exit(CriarRespostaErro('Codigo do produto invalido'));
    if LQtde <= 0 then
      Exit(CriarRespostaErro('Quantidade invalida'));

    // Buscar produto
    LQuery := FSQLite.ExecutarSelect(
      'SELECT * FROM produtos WHERE codprod = ' + IntToStr(LCodProd)
    );
    try
      if LQuery.IsEmpty then
        Exit(CriarRespostaErro('Produto nao encontrado'));

      LDescricao := LQuery.FieldByName('descricao').AsString;
      LUnidade := LQuery.FieldByName('unidade').AsString;
      LCodBarra := LQuery.FieldByName('codbarra').AsString;

      // Verificar oferta
      LPrecoUnit := LQuery.FieldByName('pvenda').AsFloat;
      if (LQuery.FieldByName('poferta').AsFloat > 0) and
         (LQuery.FieldByName('dtfimoferta').AsString >= FormatDateTime('yyyy-mm-dd', Now)) then
        LPrecoUnit := LQuery.FieldByName('poferta').AsFloat;

      // Preco manual
      if LJson.GetValue<Double>('precoManual', 0) > 0 then
        LPrecoUnit := LJson.GetValue<Double>('precoManual', 0);

      LDesconto := LJson.GetValue<Double>('desconto', 0);
      LValorTotal := RoundTo(LQtde * LPrecoUnit - LDesconto, -2);

      // Proximo sequencial
      LNumSeq := FSQLite.ExecutarScalar(
        'SELECT COALESCE(MAX(numseqitem), 0) + 1 FROM cupom_itens WHERE cupom_id = ' +
        IntToStr(FCupomAtualId)
      );

      // Inserir item
      FSQLite.ExecutarSQL(
        'INSERT INTO cupom_itens (cupom_id, numseqitem, codprod, codbarra, ' +
        'descricao, unidade, embalagem, qt, punit, vlprod, vldesconto, vldescitem, ' +
        'ncm, cfop, cest, icms_cst, csosn, aliqicms, pis_cst, cofins_cst, ' +
        'aliqpis, aliqcofins, valorpis, valorcofins, impleitransparencia, ' +
        'codvendedor, emoferta, ptabela, prod_origem, codfilial, numcaixa, numserieequip) ' +
        'VALUES (:p0,:p1,:p2,:p3,:p4,:p5,:p6,:p7,:p8,:p9,:p10,:p11,' +
        ':p12,:p13,:p14,:p15,:p16,:p17,:p18,:p19,:p20,:p21,:p22,:p23,:p24,' +
        ':p25,:p26,:p27,:p28,:p29,:p30,:p31)',
        [
          FCupomAtualId, LNumSeq, LCodProd, LCodBarra,
          LDescricao, LUnidade, LQuery.FieldByName('embalagem').AsString,
          LQtde, LPrecoUnit, LValorTotal, LDesconto, LDesconto,
          LQuery.FieldByName('ncm').AsString,
          LQuery.FieldByName('cfop').AsString,
          LQuery.FieldByName('cest').AsString,
          LQuery.FieldByName('icms_cst').AsString,
          LQuery.FieldByName('csosn').AsString,
          LQuery.FieldByName('aliqicms').AsFloat,
          LQuery.FieldByName('pis_cst').AsString,
          LQuery.FieldByName('cofins_cst').AsString,
          LQuery.FieldByName('pis_ppis').AsFloat,
          LQuery.FieldByName('cofins_pcofins').AsFloat,
          RoundTo(LValorTotal * LQuery.FieldByName('pis_ppis').AsFloat / 100, -2),
          RoundTo(LValorTotal * LQuery.FieldByName('cofins_pcofins').AsFloat / 100, -2),
          RoundTo(LValorTotal * LQuery.FieldByName('impleitransparencia').AsFloat / 100, -2),
          IfThen(LJson.GetValue<Integer>('codvendedor', 0) > 0,
            LJson.GetValue<Integer>('codvendedor', 0), FMatriculaLogada),
          IfThen((LQuery.FieldByName('poferta').AsFloat > 0) and
            (LQuery.FieldByName('dtfimoferta').AsString >= FormatDateTime('yyyy-mm-dd', Now)), 'S', 'N'),
          LQuery.FieldByName('pvenda').AsFloat,
          LQuery.FieldByName('prod_origem').AsString,
          '01',
          StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '1'), 1),
          FSQLite.ObterEstado(KEY_NUMSERIE, '')
        ]
      );

      // Atualizar totais do cupom
      FSQLite.ExecutarSQL(
        'UPDATE cupons SET qtdeitens = (SELECT COUNT(*) FROM cupom_itens WHERE cupom_id = ' +
        IntToStr(FCupomAtualId) + ' AND dtcancel IS NULL), ' +
        'valorvenda = (SELECT COALESCE(SUM(vlprod), 0) FROM cupom_itens WHERE cupom_id = ' +
        IntToStr(FCupomAtualId) + ' AND dtcancel IS NULL) ' +
        'WHERE id = ' + IntToStr(FCupomAtualId)
      );

      LDados := TJSONObject.Create;
      LDados.AddPair('numSeqItem', TJSONNumber.Create(LNumSeq));
      LDados.AddPair('codprod', TJSONNumber.Create(LCodProd));
      LDados.AddPair('descricao', LDescricao);
      LDados.AddPair('unidade', LUnidade);
      LDados.AddPair('quantidade', TJSONNumber.Create(LQtde));
      LDados.AddPair('precoUnit', TJSONNumber.Create(LPrecoUnit));
      LDados.AddPair('valorTotal', TJSONNumber.Create(LValorTotal));
      LDados.AddPair('totalCupom', TJSONNumber.Create(CalcularTotalCupom(FCupomAtualId)));

      Result := CriarRespostaSucesso('Item adicionado', LDados);
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoRemoverItem(const AData: string): string;
var
  LJson: TJSONObject;
  LSeqItem: Integer;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LSeqItem := LJson.GetValue<Integer>('numSeqItem', 0);

    FSQLite.ExecutarSQL(
      'UPDATE cupom_itens SET dtcancel = datetime(''now'',''localtime''), ' +
      'obscancel = ''Cancelado pelo operador'' ' +
      'WHERE cupom_id = ' + IntToStr(FCupomAtualId) +
      ' AND numseqitem = ' + IntToStr(LSeqItem)
    );

    // Atualizar totais
    FSQLite.ExecutarSQL(
      'UPDATE cupons SET qtdeitens = (SELECT COUNT(*) FROM cupom_itens WHERE cupom_id = ' +
      IntToStr(FCupomAtualId) + ' AND dtcancel IS NULL), ' +
      'valorvenda = (SELECT COALESCE(SUM(vlprod), 0) FROM cupom_itens WHERE cupom_id = ' +
      IntToStr(FCupomAtualId) + ' AND dtcancel IS NULL) ' +
      'WHERE id = ' + IntToStr(FCupomAtualId)
    );

    Result := CriarRespostaSucesso('Item removido');
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoAplicarDesconto(const AData: string): string;
var
  LJson: TJSONObject;
  LValor: Double;
  LTipo: string;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LValor := LJson.GetValue<Double>('valor', 0);
    LTipo := LJson.GetValue<string>('tipo', 'valor'); // 'valor' ou 'percentual'

    if LTipo = 'percentual' then
      LValor := RoundTo(CalcularTotalCupom(FCupomAtualId) * LValor / 100, -2);

    FSQLite.ExecutarSQL(
      'UPDATE cupons SET valordesc = :p0, valordescsubtotal = :p0 WHERE id = :p1',
      [LValor, FCupomAtualId]
    );

    Result := CriarRespostaSucesso('Desconto aplicado');
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoCancelarVenda(const AData: string): string;
begin
  if (FEstadoCaixa <> ecRegistrando) and (FEstadoCaixa <> ecPagamento) then
    Exit(CriarRespostaErro('Nao ha venda em andamento'));

  FSQLite.ExecutarSQL(
    'UPDATE cupons SET codoper = ''C'', dthrfimvenda = datetime(''now'',''localtime''), ' +
    'obscancel = ''Cancelado pelo operador'' WHERE id = ' + IntToStr(FCupomAtualId)
  );

  FEstadoCaixa := ecLivre;
  FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));
  FCupomAtualId := 0;

  Result := CriarRespostaSucesso('Venda cancelada');
end;

function TApoloBridge.DoObterItensCupom(const AData: string): string;
var
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LItem: TJSONObject;
begin
  if FCupomAtualId = 0 then
    Exit(CriarRespostaErro('Nenhuma venda em andamento'));

  LQuery := FSQLite.ExecutarSelect(
    'SELECT numseqitem, codprod, codbarra, descricao, unidade, ' +
    'qt, punit, vlprod, vldesconto, emoferta, dtcancel ' +
    'FROM cupom_itens WHERE cupom_id = ' + IntToStr(FCupomAtualId) +
    ' ORDER BY numseqitem'
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('seq', TJSONNumber.Create(LQuery.FieldByName('numseqitem').AsInteger));
      LItem.AddPair('codprod', TJSONNumber.Create(LQuery.FieldByName('codprod').AsInteger));
      LItem.AddPair('codbarra', LQuery.FieldByName('codbarra').AsString);
      LItem.AddPair('descricao', LQuery.FieldByName('descricao').AsString);
      LItem.AddPair('unidade', LQuery.FieldByName('unidade').AsString);
      LItem.AddPair('quantidade', TJSONNumber.Create(LQuery.FieldByName('qt').AsFloat));
      LItem.AddPair('precoUnit', TJSONNumber.Create(LQuery.FieldByName('punit').AsFloat));
      LItem.AddPair('valorTotal', TJSONNumber.Create(LQuery.FieldByName('vlprod').AsFloat));
      LItem.AddPair('desconto', TJSONNumber.Create(LQuery.FieldByName('vldesconto').AsFloat));
      LItem.AddPair('emOferta', LQuery.FieldByName('emoferta').AsString = 'S');
      LItem.AddPair('cancelado', not LQuery.FieldByName('dtcancel').IsNull);
      LArr.AddElement(LItem);
      LQuery.Next;
    end;

    Result := CriarRespostaSucesso('OK', LArr);
  finally
    LQuery.Free;
  end;
end;

function TApoloBridge.DoObterResumoCupom(const AData: string): string;
var
  LQuery: TUniQuery;
  LDados: TJSONObject;
begin
  if FCupomAtualId = 0 then
    Exit(CriarRespostaErro('Nenhuma venda em andamento'));

  LQuery := FSQLite.ExecutarSelect(
    'SELECT qtdeitens, valorvenda, valordesc, valorencargo, valortroco ' +
    'FROM cupons WHERE id = ' + IntToStr(FCupomAtualId)
  );
  try
    LDados := TJSONObject.Create;
    LDados.AddPair('qtdeitens', TJSONNumber.Create(LQuery.FieldByName('qtdeitens').AsInteger));
    LDados.AddPair('subtotal', TJSONNumber.Create(LQuery.FieldByName('valorvenda').AsFloat));
    LDados.AddPair('desconto', TJSONNumber.Create(LQuery.FieldByName('valordesc').AsFloat));
    LDados.AddPair('acrescimo', TJSONNumber.Create(LQuery.FieldByName('valorencargo').AsFloat));
    LDados.AddPair('total', TJSONNumber.Create(CalcularTotalCupom(FCupomAtualId)));
    LDados.AddPair('totalPago', TJSONNumber.Create(CalcularTotalPago(FCupomAtualId)));

    Result := CriarRespostaSucesso('OK', LDados);
  finally
    LQuery.Free;
  end;
end;

// =========================================================================
// PAGAMENTO
// =========================================================================

function TApoloBridge.DoRegistrarPagamento(const AData: string): string;
var
  LJson: TJSONObject;
  LCodCob: string;
  LValor: Double;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LCodCob := LJson.GetValue<string>('codcob', '');
    LValor := LJson.GetValue<Double>('valor', 0);

    if LValor <= 0 then
      Exit(CriarRespostaErro('Valor invalido'));

    if FEstadoCaixa = ecRegistrando then
    begin
      FEstadoCaixa := ecPagamento;
      FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));
    end;

    FSQLite.ExecutarSQL(
      'INSERT INTO cupom_pagamentos (cupom_id, codcob, valor, ' +
      'numbanco, numagencia, numcontacorrente, numcheque, numcmc7, ' +
      'cpf_cnpj_cheque, dtpredatado, ' +
      'codtipotransacao, codmodotransacao, codbandeira, codrede, ' +
      'codautorizacao, nsu, numparcela, qtdeparcela, ' +
      'codplpag, dtvenc, dthroperacao) ' +
      'VALUES (:p0, :p1, :p2, ' +
      ':p3, :p4, :p5, :p6, :p7, :p8, :p9, ' +
      ':p10, :p11, :p12, :p13, :p14, :p15, :p16, :p17, ' +
      ':p18, :p19, datetime(''now'',''localtime''))',
      [
        FCupomAtualId, LCodCob, LValor,
        LJson.GetValue<Integer>('numbanco', 0),
        LJson.GetValue<string>('numagencia', ''),
        LJson.GetValue<string>('numcontacorrente', ''),
        LJson.GetValue<string>('numcheque', ''),
        LJson.GetValue<string>('numcmc7', ''),
        LJson.GetValue<string>('cpf_cnpj_cheque', ''),
        LJson.GetValue<string>('dtpredatado', ''),
        LJson.GetValue<Integer>('codtipotransacao', 0),
        LJson.GetValue<Integer>('codmodotransacao', 0),
        LJson.GetValue<Integer>('codbandeira', 0),
        LJson.GetValue<Integer>('codrede', 0),
        LJson.GetValue<string>('codautorizacao', ''),
        LJson.GetValue<string>('nsu', ''),
        LJson.GetValue<Integer>('numparcela', 0),
        LJson.GetValue<Integer>('qtdeparcela', 0),
        LJson.GetValue<Integer>('codplpag', 0),
        LJson.GetValue<string>('dtvenc', '')
      ]
    );

    Result := DoObterResumoPagamento('{}');
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoRemoverPagamento(const AData: string): string;
var
  LJson: TJSONObject;
  LId: Integer;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LId := LJson.GetValue<Integer>('id', 0);
    FSQLite.ExecutarSQL(
      'DELETE FROM cupom_pagamentos WHERE id = ' + IntToStr(LId) +
      ' AND cupom_id = ' + IntToStr(FCupomAtualId)
    );
    Result := DoObterResumoPagamento('{}');
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoFinalizarVenda(const AData: string): string;
var
  LTotal, LTotalPago, LTroco: Double;
  LDados: TJSONObject;
begin
  if FEstadoCaixa <> ecPagamento then
    Exit(CriarRespostaErro('Nao esta no modo de pagamento'));

  LTotal := CalcularTotalCupom(FCupomAtualId);
  LTotalPago := CalcularTotalPago(FCupomAtualId);

  if LTotalPago < LTotal then
    Exit(CriarRespostaErro('Pagamento insuficiente. Faltam R$ ' +
      FormatFloat('#,##0.00', LTotal - LTotalPago)));

  LTroco := RoundTo(LTotalPago - LTotal, -2);

  // Atualizar cupom
  FSQLite.ExecutarSQL(
    'UPDATE cupons SET dthrfimvenda = datetime(''now'',''localtime''), ' +
    'valortroco = :p0, codoper = ''V'' WHERE id = :p1',
    [LTroco, FCupomAtualId]
  );

  // Atualizar saldo dinheiro
  FSQLite.SalvarEstado(KEY_TOTAL_DINHEIRO,
    FloatToStr(StrToFloatDef(FSQLite.ObterEstado(KEY_TOTAL_DINHEIRO, '0'), 0) +
      LTotalPago - LTroco)
  );

  LDados := TJSONObject.Create;
  LDados.AddPair('cupomId', TJSONNumber.Create(FCupomAtualId));
  LDados.AddPair('total', TJSONNumber.Create(LTotal));
  LDados.AddPair('totalPago', TJSONNumber.Create(LTotalPago));
  LDados.AddPair('troco', TJSONNumber.Create(LTroco));

  // Voltar para estado livre
  FEstadoCaixa := ecLivre;
  FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));

  // Guardar o cupomId antes de resetar
  Result := CriarRespostaSucesso('Venda finalizada', LDados);

  FCupomAtualId := 0;
end;

function TApoloBridge.DoListarMeiosPagamento(const AData: string): string;
var
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT codcob, descricao, tipo FROM meios_pagamento WHERE ativo = 1 ORDER BY codcob'
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('codcob', LQuery.FieldByName('codcob').AsString);
      LObj.AddPair('descricao', LQuery.FieldByName('descricao').AsString);
      LObj.AddPair('tipo', LQuery.FieldByName('tipo').AsString);
      LArr.AddElement(LObj);
      LQuery.Next;
    end;
    Result := CriarRespostaSucesso('OK', LArr);
  finally
    LQuery.Free;
  end;
end;

function TApoloBridge.DoObterResumoPagamento(const AData: string): string;
var
  LTotal, LTotalPago, LRestante: Double;
  LDados: TJSONObject;
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
begin
  LTotal := CalcularTotalCupom(FCupomAtualId);
  LTotalPago := CalcularTotalPago(FCupomAtualId);
  LRestante := Max(LTotal - LTotalPago, 0);

  LDados := TJSONObject.Create;
  LDados.AddPair('total', TJSONNumber.Create(LTotal));
  LDados.AddPair('totalPago', TJSONNumber.Create(LTotalPago));
  LDados.AddPair('restante', TJSONNumber.Create(LRestante));
  LDados.AddPair('troco', TJSONNumber.Create(Max(LTotalPago - LTotal, 0)));

  // Listar pagamentos registrados
  LQuery := FSQLite.ExecutarSelect(
    'SELECT p.id, p.codcob, m.descricao, p.valor ' +
    'FROM cupom_pagamentos p LEFT JOIN meios_pagamento m ON p.codcob = m.codcob ' +
    'WHERE p.cupom_id = ' + IntToStr(FCupomAtualId)
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('id', TJSONNumber.Create(LQuery.FieldByName('id').AsInteger));
      LObj.AddPair('codcob', LQuery.FieldByName('codcob').AsString);
      LObj.AddPair('descricao', LQuery.FieldByName('descricao').AsString);
      LObj.AddPair('valor', TJSONNumber.Create(LQuery.FieldByName('valor').AsFloat));
      LArr.AddElement(LObj);
      LQuery.Next;
    end;
    LDados.AddPair('pagamentos', LArr);
  finally
    LQuery.Free;
  end;

  Result := CriarRespostaSucesso('OK', LDados);
end;

// =========================================================================
// CAIXA
// =========================================================================

function TApoloBridge.DoAbrirCaixa(const AData: string): string;
var
  LJson: TJSONObject;
  LValorSuprimento: Double;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LValorSuprimento := LJson.GetValue<Double>('valorSuprimento', 0);

    // Sincronizar precos/dados antes de abrir o caixa
    if Assigned(FOnSincronizar) then
    begin
      try
        FOnSincronizar;
      except
        // Falha na sync nao impede abertura (pode estar offline)
      end;
    end;

    // Registrar suprimento inicial
    FSQLite.ExecutarSQL(
      'INSERT INTO numerario (tipo, valor, dthora, codoperador, motivo, codfilial, numcaixa) ' +
      'VALUES (''SUPRIMENTO'', :p0, datetime(''now'',''localtime''), :p1, ' +
      '''Suprimento de abertura'', ''01'', :p2)',
      [LValorSuprimento, FMatriculaLogada,
       StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '1'), 1)]
    );

    FSQLite.SalvarEstado(KEY_TOTAL_DINHEIRO, FloatToStr(LValorSuprimento));

    FEstadoCaixa := ecLivre;
    FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));

    Result := CriarRespostaSucesso('Caixa aberto com sucesso');
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoFecharCaixa(const AData: string): string;
var
  LDados: TJSONObject;
  LQuery: TUniQuery;
  LTotalVendas, LTotalSangrias, LTotalSuprimentos, LSaldoDinheiro: Double;
  LQtdVendas: Integer;
begin
  if FEstadoCaixa <> ecLivre then
    Exit(CriarRespostaErro('Finalize a venda em andamento antes de fechar o caixa'));

  // Calcular resumo do dia
  LQuery := FSQLite.ExecutarSelect(
    'SELECT COUNT(*) as qtd, COALESCE(SUM(valorvenda - valordesc + valorencargo), 0) as total ' +
    'FROM cupons WHERE codoper = ''V'' AND datamovto = ''' +
    FormatDateTime('yyyy-mm-dd', Now) + ''''
  );
  try
    LQtdVendas := LQuery.FieldByName('qtd').AsInteger;
    LTotalVendas := LQuery.FieldByName('total').AsFloat;
  finally
    LQuery.Free;
  end;

  LTotalSangrias := VarToFloatDef(FSQLite.ExecutarScalar(
    'SELECT COALESCE(SUM(valor), 0) FROM numerario WHERE tipo = ''SANGRIA'' AND ' +
    'DATE(dthora) = ''' + FormatDateTime('yyyy-mm-dd', Now) + ''''), 0);

  LTotalSuprimentos := VarToFloatDef(FSQLite.ExecutarScalar(
    'SELECT COALESCE(SUM(valor), 0) FROM numerario WHERE tipo = ''SUPRIMENTO'' AND ' +
    'DATE(dthora) = ''' + FormatDateTime('yyyy-mm-dd', Now) + ''''), 0);

  LSaldoDinheiro := StrToFloatDef(FSQLite.ObterEstado(KEY_TOTAL_DINHEIRO, '0'), 0);

  FEstadoCaixa := ecFechado;
  FSQLite.SalvarEstado(KEY_ESTADO, IntToStr(Ord(FEstadoCaixa)));
  FSQLite.SalvarEstado(KEY_DT_FECHAMENTO, FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));

  LDados := TJSONObject.Create;
  LDados.AddPair('qtdVendas', TJSONNumber.Create(LQtdVendas));
  LDados.AddPair('totalVendas', TJSONNumber.Create(LTotalVendas));
  LDados.AddPair('totalSangrias', TJSONNumber.Create(LTotalSangrias));
  LDados.AddPair('totalSuprimentos', TJSONNumber.Create(LTotalSuprimentos));
  LDados.AddPair('saldoDinheiro', TJSONNumber.Create(LSaldoDinheiro));

  Result := CriarRespostaSucesso('Caixa fechado', LDados);
end;

function TApoloBridge.DoEfetuarSangria(const AData: string): string;
var
  LJson: TJSONObject;
  LValor: Double;
  LMotivo: string;
  LSaldoAtual: Double;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LValor := LJson.GetValue<Double>('valor', 0);
    LMotivo := LJson.GetValue<string>('motivo', 'Sangria');

    if LValor <= 0 then
      Exit(CriarRespostaErro('Valor invalido'));

    LSaldoAtual := StrToFloatDef(FSQLite.ObterEstado(KEY_TOTAL_DINHEIRO, '0'), 0);
    if LValor > LSaldoAtual then
      Exit(CriarRespostaErro('Valor da sangria maior que o saldo em caixa'));

    FSQLite.ExecutarSQL(
      'INSERT INTO numerario (tipo, valor, dthora, codoperador, motivo, codfilial, numcaixa) ' +
      'VALUES (''SANGRIA'', :p0, datetime(''now'',''localtime''), :p1, :p2, ''01'', :p3)',
      [LValor, FMatriculaLogada, LMotivo,
       StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '1'), 1)]
    );

    FSQLite.SalvarEstado(KEY_TOTAL_DINHEIRO, FloatToStr(LSaldoAtual - LValor));

    Result := CriarRespostaSucesso('Sangria realizada: R$ ' + FormatFloat('#,##0.00', LValor));
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoEfetuarSuprimento(const AData: string): string;
var
  LJson: TJSONObject;
  LValor: Double;
  LSaldoAtual: Double;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LValor := LJson.GetValue<Double>('valor', 0);

    if LValor <= 0 then
      Exit(CriarRespostaErro('Valor invalido'));

    FSQLite.ExecutarSQL(
      'INSERT INTO numerario (tipo, valor, dthora, codoperador, motivo, codfilial, numcaixa) ' +
      'VALUES (''SUPRIMENTO'', :p0, datetime(''now'',''localtime''), :p1, ''Suprimento'', ''01'', :p2)',
      [LValor, FMatriculaLogada,
       StrToIntDef(FSQLite.ObterEstado(KEY_NUMCAIXA, '1'), 1)]
    );

    LSaldoAtual := StrToFloatDef(FSQLite.ObterEstado(KEY_TOTAL_DINHEIRO, '0'), 0);
    FSQLite.SalvarEstado(KEY_TOTAL_DINHEIRO, FloatToStr(LSaldoAtual + LValor));

    Result := CriarRespostaSucesso('Suprimento realizado: R$ ' + FormatFloat('#,##0.00', LValor));
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoObterEstadoCaixa(const AData: string): string;
var
  LDados: TJSONObject;
begin
  LDados := TJSONObject.Create;
  LDados.AddPair('estado', TJSONNumber.Create(Ord(FEstadoCaixa)));
  LDados.AddPair('estadoTexto', TEstadoCaixa(FEstadoCaixa).ToString);
  LDados.AddPair('numCaixa', FSQLite.ObterEstado(KEY_NUMCAIXA, '0'));
  LDados.AddPair('operador', FNomeOperador);
  LDados.AddPair('matricula', TJSONNumber.Create(FMatriculaLogada));
  LDados.AddPair('saldoDinheiro', TJSONNumber.Create(
    StrToFloatDef(FSQLite.ObterEstado(KEY_TOTAL_DINHEIRO, '0'), 0)));
  LDados.AddPair('contingencia', FContingencia.ToString);
  LDados.AddPair('cupomAtualId', TJSONNumber.Create(FCupomAtualId));

  Result := CriarRespostaSucesso('OK', LDados);
end;

// =========================================================================
// NFCE
// =========================================================================

function TApoloBridge.DoGerarNFCe(const AData: string): string;
var
  LJson: TJSONObject;
  LCupomId: Integer;
  LNumNota, LSerieNFCe: Integer;
  LDados: TJSONObject;
  LChaveNFe, LProtocolo: string;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then
    LCupomId := FCupomAtualId
  else
  begin
    try
      LCupomId := LJson.GetValue<Integer>('cupomId', FCupomAtualId);
    finally
      LJson.Free;
    end;
  end;

  if LCupomId = 0 then
    Exit(CriarRespostaErro('Nenhum cupom informado para gerar NFCe'));

  if Assigned(FOnGerarNFCe) then
  begin
    try
      // Atribuir proximo numero de nota e serie ao cupom antes de gerar
      LNumNota := StrToIntDef(FSQLite.ObterEstado(KEY_PROX_NUM_NOTA, '1'), 1);
      LSerieNFCe := StrToIntDef(FSQLite.ObterEstado(KEY_SERIE_NFCE, '1'), 1);
      FSQLite.ExecutarSQL(
        'UPDATE cupons SET numnota = :p0, serienfce = :p1 WHERE id = :p2',
        [LNumNota, LSerieNFCe, LCupomId]
      );

      // Incrementar proximo numero (consumido independente do resultado)
      FSQLite.SalvarEstado(KEY_PROX_NUM_NOTA, IntToStr(LNumNota + 1));

      FOnGerarNFCe(LCupomId, LChaveNFe, LProtocolo);

      // Atualizar cupom com chave e protocolo
      FSQLite.ExecutarSQL(
        'UPDATE cupons SET chavenfe = :p0, protocolo_nfe = :p1 WHERE id = :p2',
        [LChaveNFe, LProtocolo, LCupomId]
      );

      LDados := TJSONObject.Create;
      LDados.AddPair('cupomId', TJSONNumber.Create(LCupomId));
      LDados.AddPair('chaveNFe', LChaveNFe);
      LDados.AddPair('protocolo', LProtocolo);
      LDados.AddPair('status', 'AUTORIZADA');

      Result := CriarRespostaSucesso('NFCe gerada com sucesso', LDados);
    except
      on E: Exception do
      begin
        // Se falhou e estamos em contingencia, registrar como pendente
        if FContingencia <> tcNenhuma then
        begin
          LDados := TJSONObject.Create;
          LDados.AddPair('cupomId', TJSONNumber.Create(LCupomId));
          LDados.AddPair('status', 'CONTINGENCIA');
          LDados.AddPair('mensagem', 'NFCe salva em contingencia: ' + E.Message);
          Result := CriarRespostaSucesso('NFCe registrada em contingencia', LDados);
        end
        else
          Result := CriarRespostaErro('Erro ao gerar NFCe: ' + E.Message);
      end;
    end;
  end
  else
    Result := CriarRespostaErro('Modulo NFCe nao configurado. Verifique a integracao com ACBr.');
end;

function TApoloBridge.DoListarNFCePendentes(const AData: string): string;
var
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT nc.id, nc.tipo_contingencia, nc.chave_nfe, nc.numnota, ' +
    'nc.dt_geracao, nc.status, nc.tentativas, nc.ultimo_erro, ' +
    'c.valorvenda, c.numcupom ' +
    'FROM nfce_contingencia nc ' +
    'LEFT JOIN cupons c ON nc.cupom_id = c.id ' +
    'WHERE nc.status IN (''PENDENTE'', ''REJEITADO'') ' +
    'ORDER BY nc.dt_geracao DESC'
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('id', TJSONNumber.Create(LQuery.FieldByName('id').AsInteger));
      LObj.AddPair('tipoContingencia', LQuery.FieldByName('tipo_contingencia').AsString);
      LObj.AddPair('chaveNFe', LQuery.FieldByName('chave_nfe').AsString);
      LObj.AddPair('numNota', TJSONNumber.Create(LQuery.FieldByName('numnota').AsInteger));
      LObj.AddPair('numCupom', TJSONNumber.Create(LQuery.FieldByName('numcupom').AsInteger));
      LObj.AddPair('dtGeracao', LQuery.FieldByName('dt_geracao').AsString);
      LObj.AddPair('status', LQuery.FieldByName('status').AsString);
      LObj.AddPair('tentativas', TJSONNumber.Create(LQuery.FieldByName('tentativas').AsInteger));
      LObj.AddPair('ultimoErro', LQuery.FieldByName('ultimo_erro').AsString);
      LObj.AddPair('valorVenda', TJSONNumber.Create(LQuery.FieldByName('valorvenda').AsFloat));
      LArr.AddElement(LObj);
      LQuery.Next;
    end;
    Result := CriarRespostaSucesso('OK', LArr);
  finally
    LQuery.Free;
  end;
end;

function TApoloBridge.DoRetransmitirContingencia(const AData: string): string;
var
  LQtdEnviados, LQtdErros: Integer;
  LDados: TJSONObject;
begin
  if FContingencia <> tcNenhuma then
    Exit(CriarRespostaErro('Saia da contingencia antes de retransmitir. ' +
      'A conexao com o SEFAZ deve estar ativa.'));

  if Assigned(FOnRetransmitir) then
  begin
    try
      LQtdEnviados := 0;
      LQtdErros := 0;
      FOnRetransmitir(LQtdEnviados, LQtdErros);

      LDados := TJSONObject.Create;
      LDados.AddPair('enviados', TJSONNumber.Create(LQtdEnviados));
      LDados.AddPair('erros', TJSONNumber.Create(LQtdErros));

      if LQtdErros = 0 then
        Result := CriarRespostaSucesso(
          'Retransmissao concluida. ' + IntToStr(LQtdEnviados) + ' documento(s) enviado(s).', LDados)
      else
        Result := CriarRespostaSucesso(
          'Retransmissao parcial. ' + IntToStr(LQtdEnviados) + ' enviado(s), ' +
          IntToStr(LQtdErros) + ' erro(s).', LDados);
    except
      on E: Exception do
        Result := CriarRespostaErro('Erro na retransmissao: ' + E.Message);
    end;
  end
  else
    Result := CriarRespostaErro('Modulo de retransmissao nao configurado.');
end;

// =========================================================================
// CONTINGENCIA
// =========================================================================

function TApoloBridge.DoObterStatusConexao(const AData: string): string;
var
  LDados: TJSONObject;
begin
  LDados := TJSONObject.Create;
  LDados.AddPair('online', TJSONBool.Create(FContingencia = tcNenhuma));
  LDados.AddPair('tipo', FContingencia.ToString);

  Result := CriarRespostaSucesso('OK', LDados);
end;

function TApoloBridge.DoEntrarContingencia(const AData: string): string;
var
  LJson: TJSONObject;
  LTipo, LJustificativa: string;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LTipo := LJson.GetValue<string>('tipo', 'OFFLINE');
    LJustificativa := LJson.GetValue<string>('justificativa', '');

    if LJustificativa = '' then
      Exit(CriarRespostaErro('Informe a justificativa para entrar em contingencia'));

    if LTipo = 'OFFLINE' then FContingencia := tcOffLine
    else if LTipo = 'SVC_AN' then FContingencia := tcSVCAN
    else if LTipo = 'SVC_RS' then FContingencia := tcSVCRS
    else if LTipo = 'SVC_SP' then FContingencia := tcSVCSP
    else Exit(CriarRespostaErro('Tipo de contingencia invalido'));

    Result := CriarRespostaSucesso('Contingencia ativada: ' + FContingencia.ToString);
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoSairContingencia(const AData: string): string;
var
  LPendentes: Variant;
begin
  // Verificar se ha documentos pendentes
  LPendentes := FSQLite.ExecutarScalar(
    'SELECT COUNT(*) FROM nfce_contingencia WHERE status = ''PENDENTE'''
  );

  if (not VarIsNull(LPendentes)) and (LPendentes > 0) then
  begin
    Result := CriarRespostaErro('Existem ' + VarToStr(LPendentes) +
      ' documento(s) pendente(s) de envio. Retransmita antes de sair da contingencia.');
    Exit;
  end;

  FContingencia := tcNenhuma;
  Result := CriarRespostaSucesso('Modo normal restaurado');
end;

function TApoloBridge.DoListarDocContingencia(const AData: string): string;
begin
  Result := DoListarNFCePendentes(AData);
end;

// =========================================================================
// CLIENTES
// =========================================================================

function TApoloBridge.DoBuscarCliente(const AData: string): string;
var
  LJson: TJSONObject;
  LFiltro: string;
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LFiltro := LJson.GetValue<string>('filtro', '');

    LQuery := FSQLite.ExecutarSelect(
      'SELECT codcli, cpf_cnpj, nome, cidade, uf, limite_credito ' +
      'FROM clientes WHERE ' +
      'nome LIKE ''%' + LFiltro + '%'' OR ' +
      'cpf_cnpj LIKE ''%' + LFiltro + '%'' OR ' +
      'CAST(codcli AS TEXT) = ''' + LFiltro + ''' ' +
      'ORDER BY nome LIMIT 50'
    );
    try
      LArr := TJSONArray.Create;
      while not LQuery.Eof do
      begin
        LObj := TJSONObject.Create;
        LObj.AddPair('codcli', TJSONNumber.Create(LQuery.FieldByName('codcli').AsInteger));
        LObj.AddPair('cpf_cnpj', LQuery.FieldByName('cpf_cnpj').AsString);
        LObj.AddPair('nome', LQuery.FieldByName('nome').AsString);
        LObj.AddPair('cidade', LQuery.FieldByName('cidade').AsString);
        LObj.AddPair('uf', LQuery.FieldByName('uf').AsString);
        LObj.AddPair('limiteCredito', TJSONNumber.Create(LQuery.FieldByName('limite_credito').AsFloat));
        LArr.AddElement(LObj);
        LQuery.Next;
      end;
      Result := CriarRespostaSucesso('OK', LArr);
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoBuscarVendedor(const AData: string): string;
var
  LJson: TJSONObject;
  LMatricula: Integer;
  LQuery: TUniQuery;
  LDados: TJSONObject;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LMatricula := LJson.GetValue<Integer>('matricula', 0);
    if LMatricula = 0 then
      Exit(CriarRespostaErro('Informe a matricula'));

    LQuery := FSQLite.ExecutarSelect(
      'SELECT matricula, nome FROM funcionarios WHERE matricula = ' +
      IntToStr(LMatricula)
    );
    try
      if LQuery.IsEmpty then
        Exit(CriarRespostaErro('Vendedor nao encontrado'));

      LDados := TJSONObject.Create;
      LDados.AddPair('matricula', TJSONNumber.Create(LMatricula));
      LDados.AddPair('nome', LQuery.FieldByName('nome').AsString);

      Result := CriarRespostaSucesso('OK', LDados);
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoIdentificarConsumidor(const AData: string): string;
var
  LJson: TJSONObject;
  LCpfCnpj, LCpfCnpjLimpo: string;
  LQuery: TUniQuery;
  LDados: TJSONObject;
  LCodCli: Integer;
  LNomeCliente: string;
  I: Integer;
begin
  if FCupomAtualId = 0 then
    Exit(CriarRespostaErro('Inicie uma venda antes de identificar o consumidor'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LCpfCnpj := Trim(LJson.GetValue<string>('cpfCnpj', ''));

    if LCpfCnpj = '' then
      Exit(CriarRespostaErro('Informe o CPF ou CNPJ'));

    // Limpar formatacao (remover pontos, tracos, barras)
    LCpfCnpjLimpo := '';
    for I := 1 to Length(LCpfCnpj) do
      if CharInSet(LCpfCnpj[I], ['0'..'9']) then
        LCpfCnpjLimpo := LCpfCnpjLimpo + LCpfCnpj[I];

    if (Length(LCpfCnpjLimpo) <> 11) and (Length(LCpfCnpjLimpo) <> 14) then
      Exit(CriarRespostaErro('CPF deve ter 11 digitos ou CNPJ deve ter 14 digitos'));

    // Buscar na tabela de clientes (sincronizada do mscliente)
    LQuery := FSQLite.ExecutarSelect(
      'SELECT codcli, cpf_cnpj, nome, endereco, bairro, cidade, uf ' +
      'FROM clientes WHERE REPLACE(REPLACE(REPLACE(REPLACE(cpf_cnpj, ''.'', ''''), ''-'', ''''), ''/'', ''''), '' '', '''') = ''' +
      LCpfCnpjLimpo + ''' LIMIT 1'
    );
    try
      LDados := TJSONObject.Create;

      if not LQuery.IsEmpty then
      begin
        // Cliente encontrado no cadastro (mscliente)
        LCodCli := LQuery.FieldByName('codcli').AsInteger;
        LNomeCliente := LQuery.FieldByName('nome').AsString;

        // Atualizar cupom com dados do cliente cadastrado
        FSQLite.ExecutarSQL(
          'UPDATE cupons SET codcli = :p0, cpf_cnpj = :p1, descnomecliente = :p2 WHERE id = :p3',
          [LCodCli, LCpfCnpjLimpo, LNomeCliente, FCupomAtualId]
        );

        LDados.AddPair('encontrado', TJSONBool.Create(True));
        LDados.AddPair('codcli', TJSONNumber.Create(LCodCli));
        LDados.AddPair('cpfCnpj', LCpfCnpjLimpo);
        LDados.AddPair('nome', LNomeCliente);
        LDados.AddPair('cidade', LQuery.FieldByName('cidade').AsString);
        LDados.AddPair('uf', LQuery.FieldByName('uf').AsString);

        Result := CriarRespostaSucesso('Cliente identificado: ' + LNomeCliente, LDados);
      end
      else
      begin
        // Cliente NAO encontrado - usar codconsumidor da msfilial
        LCodCli := StrToIntDef(FSQLite.ObterEstado(KEY_CODCONSUMIDOR, '0'), 0);

        if LCodCli = 0 then
          Exit(CriarRespostaErro('Codigo do consumidor padrao nao configurado na filial (msfilial.codconsumidor)'));

        // Atualizar cupom com consumidor generico + CPF/CNPJ informado
        FSQLite.ExecutarSQL(
          'UPDATE cupons SET codcli = :p0, cpf_cnpj = :p1, descnomecliente = :p2 WHERE id = :p3',
          [LCodCli, LCpfCnpjLimpo, 'CONSUMIDOR', FCupomAtualId]
        );

        LDados.AddPair('encontrado', TJSONBool.Create(False));
        LDados.AddPair('codcli', TJSONNumber.Create(LCodCli));
        LDados.AddPair('cpfCnpj', LCpfCnpjLimpo);
        LDados.AddPair('nome', 'CONSUMIDOR');
        LDados.AddPair('cidade', '');
        LDados.AddPair('uf', '');

        Result := CriarRespostaSucesso(
          'CPF/CNPJ registrado. Cliente nao cadastrado, usando consumidor padrao.', LDados);
      end;
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

function TApoloBridge.DoVincularCliente(const AData: string): string;
var
  LJson: TJSONObject;
  LCodCli: Integer;
  LQuery: TUniQuery;
  LDados: TJSONObject;
begin
  if FCupomAtualId = 0 then
    Exit(CriarRespostaErro('Inicie uma venda antes de vincular o cliente'));

  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LCodCli := LJson.GetValue<Integer>('codcli', 0);

    if LCodCli = 0 then
      Exit(CriarRespostaErro('Codigo do cliente invalido'));

    // Buscar dados do cliente
    LQuery := FSQLite.ExecutarSelect(
      'SELECT codcli, cpf_cnpj, nome, cidade, uf FROM clientes WHERE codcli = ' +
      IntToStr(LCodCli)
    );
    try
      if LQuery.IsEmpty then
        Exit(CriarRespostaErro('Cliente nao encontrado'));

      // Atualizar cupom com dados do cliente
      FSQLite.ExecutarSQL(
        'UPDATE cupons SET codcli = :p0, cpf_cnpj = :p1, descnomecliente = :p2 WHERE id = :p3',
        [LCodCli,
         LQuery.FieldByName('cpf_cnpj').AsString,
         LQuery.FieldByName('nome').AsString,
         FCupomAtualId]
      );

      LDados := TJSONObject.Create;
      LDados.AddPair('codcli', TJSONNumber.Create(LCodCli));
      LDados.AddPair('cpfCnpj', LQuery.FieldByName('cpf_cnpj').AsString);
      LDados.AddPair('nome', LQuery.FieldByName('nome').AsString);
      LDados.AddPair('cidade', LQuery.FieldByName('cidade').AsString);
      LDados.AddPair('uf', LQuery.FieldByName('uf').AsString);

      Result := CriarRespostaSucesso('Cliente vinculado: ' + LQuery.FieldByName('nome').AsString, LDados);
    finally
      LQuery.Free;
    end;
  finally
    LJson.Free;
  end;
end;

// =========================================================================
// PRE-VENDA
// =========================================================================

function TApoloBridge.DoListarPreVendas(const AData: string): string;
var
  LQuery: TUniQuery;
  LArr: TJSONArray;
  LObj: TJSONObject;
begin
  LQuery := FSQLite.ExecutarSelect(
    'SELECT id, numtrans, numped, data, codcob, obs ' +
    'FROM prevenda WHERE processado = 0 ORDER BY data DESC'
  );
  try
    LArr := TJSONArray.Create;
    while not LQuery.Eof do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('id', TJSONNumber.Create(LQuery.FieldByName('id').AsInteger));
      LObj.AddPair('numtrans', TJSONNumber.Create(LQuery.FieldByName('numtrans').AsInteger));
      LObj.AddPair('numped', TJSONNumber.Create(LQuery.FieldByName('numped').AsInteger));
      LObj.AddPair('data', LQuery.FieldByName('data').AsString);
      LObj.AddPair('codcob', LQuery.FieldByName('codcob').AsString);
      LObj.AddPair('obs', LQuery.FieldByName('obs').AsString);
      LArr.AddElement(LObj);
      LQuery.Next;
    end;
    Result := CriarRespostaSucesso('OK', LArr);
  finally
    LQuery.Free;
  end;
end;

function TApoloBridge.DoImportarPreVenda(const AData: string): string;
var
  LJson: TJSONObject;
  LPreVendaId, LNumTrans: Integer;
  LQuery: TUniQuery;
  LConteudo: string;
  LCodProd: Int64;
  LQtde, LPreco: Double;
begin
  LJson := TJSONObject.ParseJSONValue(AData) as TJSONObject;
  if LJson = nil then Exit(CriarRespostaErro('Dados invalidos'));

  try
    LPreVendaId := LJson.GetValue<Integer>('id', 0);
    if LPreVendaId = 0 then
      Exit(CriarRespostaErro('ID da pre-venda nao informado'));

    // Buscar pre-venda no SQLite
    LQuery := FSQLite.ExecutarSelect(
      'SELECT * FROM prevenda WHERE id = ' + IntToStr(LPreVendaId) + ' AND processado = 0'
    );
    try
      if LQuery.IsEmpty then
        Exit(CriarRespostaErro('Pre-venda nao encontrada ou ja processada'));

      LNumTrans := LQuery.FieldByName('numtrans').AsInteger;
      LConteudo := LQuery.FieldByName('conteudo').AsString;
    finally
      LQuery.Free;
    end;

    // Iniciar venda com base na pre-venda
    Result := DoIniciarVenda('{}');

    // Parsear o conteudo da pre-venda (XML armazenado como texto)
    // A pre-venda contem os itens no formato do sistema original
    // Processar cada item e adicionar ao cupom
    LQuery := FSQLite.ExecutarSelect(
      'SELECT codprod, qt, punit FROM prevenda_itens WHERE prevenda_id = ' + IntToStr(LPreVendaId)
    );
    try
      while not LQuery.Eof do
      begin
        LCodProd := LQuery.FieldByName('codprod').AsLargeInt;
        LQtde := LQuery.FieldByName('qt').AsFloat;
        LPreco := LQuery.FieldByName('punit').AsFloat;

        DoAdicionarItem(
          '{"codprod":' + IntToStr(LCodProd) +
          ',"quantidade":' + FloatToStr(LQtde) +
          ',"precoManual":' + FloatToStr(LPreco) + '}'
        );

        LQuery.Next;
      end;
    finally
      LQuery.Free;
    end;

    // Vincular cliente se existir
    LQuery := FSQLite.ExecutarSelect(
      'SELECT codcli FROM prevenda WHERE id = ' + IntToStr(LPreVendaId)
    );
    try
      if (not LQuery.IsEmpty) and (LQuery.FieldByName('codcli').AsInteger > 0) then
      begin
        FSQLite.ExecutarSQL(
          'UPDATE cupons SET codcli = :p0 WHERE id = :p1',
          [LQuery.FieldByName('codcli').AsInteger, FCupomAtualId]
        );
      end;
    finally
      LQuery.Free;
    end;

    // Marcar pre-venda como processada
    FSQLite.ExecutarSQL(
      'UPDATE prevenda SET processado = 1, dt_importacao = datetime(''now'',''localtime'') ' +
      'WHERE id = ' + IntToStr(LPreVendaId)
    );

    Result := CriarRespostaSucesso('Pre-venda ' + IntToStr(LNumTrans) + ' importada com sucesso');
  finally
    LJson.Free;
  end;
end;

// =========================================================================
// UTILIDADES
// =========================================================================

function TApoloBridge.ObterProximoNumCupom: Integer;
var
  LNum: Integer;
begin
  LNum := StrToIntDef(FSQLite.ObterEstado(KEY_PROX_NUM_CUPOM, '1'), 1);
  FSQLite.SalvarEstado(KEY_PROX_NUM_CUPOM, IntToStr(LNum + 1));
  Result := LNum;
end;

function TApoloBridge.CalcularTotalCupom(ACupomId: Integer): Double;
var
  LVal: Variant;
  LSubtotal, LDesconto, LAcrescimo: Double;
begin
  // Subtotal dos itens ativos
  LVal := FSQLite.ExecutarScalar(
    'SELECT COALESCE(SUM(vlprod), 0) FROM cupom_itens WHERE cupom_id = ' +
    IntToStr(ACupomId) + ' AND dtcancel IS NULL'
  );
  LSubtotal := VarToFloatDef(LVal, 0);

  // Desconto do cupom
  LVal := FSQLite.ExecutarScalar(
    'SELECT COALESCE(valordesc, 0) FROM cupons WHERE id = ' + IntToStr(ACupomId)
  );
  LDesconto := VarToFloatDef(LVal, 0);

  // Acrescimo
  LVal := FSQLite.ExecutarScalar(
    'SELECT COALESCE(valorencargo, 0) FROM cupons WHERE id = ' + IntToStr(ACupomId)
  );
  LAcrescimo := VarToFloatDef(LVal, 0);

  Result := RoundTo(LSubtotal - LDesconto + LAcrescimo, -2);
end;

function TApoloBridge.CalcularTotalPago(ACupomId: Integer): Double;
var
  LVal: Variant;
begin
  LVal := FSQLite.ExecutarScalar(
    'SELECT COALESCE(SUM(valor), 0) FROM cupom_pagamentos WHERE cupom_id = ' +
    IntToStr(ACupomId)
  );
  Result := VarToFloatDef(LVal, 0);
end;

end.
