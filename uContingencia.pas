unit uContingencia;

interface

uses
  System.SysUtils, System.Classes, System.DateUtils, System.JSON,
  System.Variants, Uni, uSQLiteDB, uTypesApoloWeb, uConstantesWeb;

type
  TContingenciaManager = class
  private
    FSQLite: TSQLiteDB;
    FTipoAtual: TTipoContingencia;
    FJustificativa: string;
    FDtInicio: TDateTime;
    FTentativasConexao: Integer;
  public
    constructor Create(ASQLite: TSQLiteDB);

    // Entrar/sair de contingencia
    procedure EntrarContingencia(ATipo: TTipoContingencia; const AJustificativa: string);
    procedure SairContingencia;
    function EstaEmContingencia: Boolean;

    // Registrar documento em contingencia
    function RegistrarDocContingencia(ACupomId: Integer; const AChaveNFe: string;
      ANumNota: Integer; const AXmlPath, AXmlConteudo: string): Integer;

    // Atualizar status de documento
    procedure AtualizarStatusDoc(ADocId: Integer; AStatus: TStatusContingencia;
      const AProtocolo: string = ''; const AErro: string = '');

    // Listar documentos pendentes
    function ListarPendentes: TJSONArray;
    function QtdePendentes: Integer;

    // Descarte manual: tira da fila os documentos REJEITADOS escolhidos pelo
    // operador. Nao envia nada a SEFAZ - documento rejeitado nunca chegou a
    // ser autorizado, entao nao existe cancelamento a fazer. So PENDENTE fica
    // de fora: esse ainda tem envio a fazer e sumir com ele perderia a venda.
    function DescartarDocs(const AIds: TArray<Integer>; AMatricula: Integer): Integer;

    // Retransmissao
    function ObterProximoDocParaEnvio: Integer;
    procedure IncrementarTentativa(ADocId: Integer; const AErro: string);
    // Zera o contador de tentativas dos PENDENTES. ObterProximoDocParaEnvio
    // ignora quem passou de MAX_TENTATIVAS_CONTINGENCIA; sem este reset uma
    // retransmissao manual nao alcancava os documentos ja esgotados.
    procedure ReiniciarTentativas;

    // Helpers
    function TipoContingenciaParaACBr: Integer;

    property TipoAtual: TTipoContingencia read FTipoAtual;
    property Justificativa: string read FJustificativa;
    property DtInicio: TDateTime read FDtInicio;
    property TentativasConexao: Integer read FTentativasConexao write FTentativasConexao;
  end;

implementation

{ TContingenciaManager }

constructor TContingenciaManager.Create(ASQLite: TSQLiteDB);
var
  LDtInicio: string;
  LFmt: TFormatSettings;
begin
  inherited Create;
  FSQLite := ASQLite;
  FTentativasConexao := 0;

  // Restaurar o estado gravado: sem isso o app reabria sempre em modo normal
  // enquanto o SQLite continuava marcado como OFFLINE, e os dois estados
  // (memoria x banco) divergiam a cada reinicio
  FTipoAtual := TTipoContingencia.FromString(
    FSQLite.ObterEstado('CONTINGENCIA_TIPO', 'NORMAL'));
  FJustificativa := FSQLite.ObterEstado('CONTINGENCIA_JUSTIFICATIVA', '');

  FDtInicio := 0;
  LDtInicio := FSQLite.ObterEstado('CONTINGENCIA_DT_INICIO', '');
  if LDtInicio <> '' then
  begin
    // Gravado como 'yyyy-mm-dd hh:nn:ss'
    LFmt := TFormatSettings.Invariant;
    LFmt.DateSeparator := '-';
    LFmt.TimeSeparator := ':';
    LFmt.ShortDateFormat := 'yyyy-mm-dd';
    LFmt.ShortTimeFormat := 'hh:nn:ss';
    if not TryStrToDateTime(LDtInicio, FDtInicio, LFmt) then
      FDtInicio := 0;
  end;

  if FTipoAtual = tcNenhuma then Exit;

  // Se nao sobrou nenhum pendente, a contingencia ficou presa de um ciclo
  // anterior - voltar ao normal para nao emitir offline sem necessidade
  if QtdePendentes = 0 then
    SairContingencia;
end;

procedure TContingenciaManager.EntrarContingencia(ATipo: TTipoContingencia;
  const AJustificativa: string);
begin
  if ATipo = tcNenhuma then
    raise Exception.Create('Tipo de contingencia invalido');
  if AJustificativa = '' then
    raise Exception.Create('Justificativa e obrigatoria para entrar em contingencia');

  FTipoAtual := ATipo;
  FJustificativa := AJustificativa;
  FDtInicio := Now;
  FTentativasConexao := 0;

  // Persistir estado no SQLite
  FSQLite.SalvarEstado('CONTINGENCIA_TIPO', FTipoAtual.ToString);
  FSQLite.SalvarEstado('CONTINGENCIA_JUSTIFICATIVA', FJustificativa);
  FSQLite.SalvarEstado('CONTINGENCIA_DT_INICIO', FormatDateTime('yyyy-mm-dd hh:nn:ss', FDtInicio));
end;

procedure TContingenciaManager.SairContingencia;
var
  LPendentes: Integer;
begin
  LPendentes := QtdePendentes;
  if LPendentes > 0 then
    raise Exception.CreateFmt(
      'Existem %d documento(s) pendente(s) de envio. Retransmita antes de sair da contingencia.',
      [LPendentes]);

  FTipoAtual := tcNenhuma;
  FJustificativa := '';
  FDtInicio := 0;

  // Limpar estado
  FSQLite.SalvarEstado('CONTINGENCIA_TIPO', 'NORMAL');
  FSQLite.SalvarEstado('CONTINGENCIA_JUSTIFICATIVA', '');
  FSQLite.SalvarEstado('CONTINGENCIA_DT_INICIO', '');
end;

function TContingenciaManager.EstaEmContingencia: Boolean;
begin
  Result := FTipoAtual <> tcNenhuma;
end;

function TContingenciaManager.RegistrarDocContingencia(ACupomId: Integer;
  const AChaveNFe: string; ANumNota: Integer;
  const AXmlPath, AXmlConteudo: string): Integer;
begin
  FSQLite.ExecutarSQL(
    'INSERT INTO nfce_contingencia ' +
    '(cupom_id, tipo_contingencia, xml_path, xml_conteudo, chave_nfe, numnota, ' +
    'dt_geracao, dt_contingencia_inicio, justificativa, status) ' +
    'VALUES (:p0, :p1, :p2, :p3, :p4, :p5, ' +
    'datetime(''now'',''localtime''), :p6, :p7, ''PENDENTE'')',
    [
      ACupomId,
      FTipoAtual.ToString,
      AXmlPath,
      AXmlConteudo,
      AChaveNFe,
      ANumNota,
      FormatDateTime('yyyy-mm-dd hh:nn:ss', FDtInicio),
      FJustificativa
    ]
  );

  Result := FSQLite.ExecutarScalar('SELECT last_insert_rowid()');
end;

procedure TContingenciaManager.AtualizarStatusDoc(ADocId: Integer;
  AStatus: TStatusContingencia; const AProtocolo, AErro: string);
var
  LStatusStr: string;
begin
  case AStatus of
    scPendente:   LStatusStr := 'PENDENTE';
    scEnviado:    LStatusStr := 'ENVIADO';
    scAutorizado: LStatusStr := 'AUTORIZADO';
    scRejeitado:  LStatusStr := 'REJEITADO';
    scCancelado:  LStatusStr := 'CANCELADO';
    scDescartado: LStatusStr := 'DESCARTADO';
  end;

  FSQLite.ExecutarSQL(
    'UPDATE nfce_contingencia SET status = :p0, protocolo = :p1, ' +
    'motivo_rejeicao = :p2, dt_envio = datetime(''now'',''localtime'') ' +
    'WHERE id = :p3',
    [LStatusStr, AProtocolo, AErro, ADocId]
  );

  // Atualizar cupom se autorizado
  if AStatus = scAutorizado then
  begin
    FSQLite.ExecutarSQL(
      'UPDATE cupons SET protocolo_nfe = :p0 WHERE id = ' +
      '(SELECT cupom_id FROM nfce_contingencia WHERE id = :p1)',
      [AProtocolo, ADocId]
    );

    // Zerou a fila: sair da contingencia sozinho. Sem isso o operador ficava
    // preso - "sair" exigia zero pendentes e as vendas novas continuavam
    // entrando como pendentes
    if EstaEmContingencia and (QtdePendentes = 0) then
      SairContingencia;
  end;
end;

function TContingenciaManager.ListarPendentes: TJSONArray;
var
  LQuery: TUniQuery;
  LObj: TJSONObject;
begin
  Result := TJSONArray.Create;

  LQuery := FSQLite.ExecutarSelect(
    'SELECT nc.id, nc.tipo_contingencia, nc.chave_nfe, nc.numnota, ' +
    'nc.dt_geracao, nc.status, nc.tentativas, nc.ultimo_erro, nc.protocolo, ' +
    'c.valorvenda, c.numcupom ' +
    'FROM nfce_contingencia nc ' +
    'LEFT JOIN cupons c ON nc.cupom_id = c.id ' +
    'WHERE nc.status IN (''PENDENTE'', ''REJEITADO'') ' +
    'ORDER BY nc.dt_geracao ASC'
  );
  try
    while not LQuery.Eof do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('id', TJSONNumber.Create(LQuery.FieldByName('id').AsInteger));
      LObj.AddPair('tipo', LQuery.FieldByName('tipo_contingencia').AsString);
      LObj.AddPair('chaveNFe', LQuery.FieldByName('chave_nfe').AsString);
      LObj.AddPair('numNota', TJSONNumber.Create(LQuery.FieldByName('numnota').AsInteger));
      LObj.AddPair('numCupom', TJSONNumber.Create(LQuery.FieldByName('numcupom').AsInteger));
      LObj.AddPair('dtGeracao', LQuery.FieldByName('dt_geracao').AsString);
      LObj.AddPair('status', LQuery.FieldByName('status').AsString);
      LObj.AddPair('tentativas', TJSONNumber.Create(LQuery.FieldByName('tentativas').AsInteger));
      LObj.AddPair('erro', LQuery.FieldByName('ultimo_erro').AsString);
      LObj.AddPair('valor', TJSONNumber.Create(LQuery.FieldByName('valorvenda').AsFloat));
      Result.AddElement(LObj);
      LQuery.Next;
    end;
  finally
    LQuery.Free;
  end;
end;

// Conta apenas o que ainda tem envio a fazer. REJEITADO fica de fora de
// proposito: o SEFAZ ja respondeu negando, reenviar o mesmo XML repete a
// rejeicao, e contar esses documentos deixava o caixa preso em contingencia
// para sempre (nao dava para sair nem retransmitir).
function TContingenciaManager.QtdePendentes: Integer;
var
  LVal: Variant;
begin
  LVal := FSQLite.ExecutarScalar(
    'SELECT COUNT(*) FROM nfce_contingencia WHERE status = ''PENDENTE'''
  );
  Result := VarToIntDef(LVal, 0);
end;

{ Descarte manual dos rejeitados. Trabalha so' com status REJEITADO: o SEFAZ ja
  respondeu negando, entao nao ha envio pendente nem autorizacao a cancelar -
  o documento apenas para de aparecer na fila. O filtro na propria UPDATE (e
  nao so' na tela) evita que um id de PENDENTE mandado pelo front derrube uma
  nota que ainda tem envio a fazer. }
function TContingenciaManager.DescartarDocs(const AIds: TArray<Integer>;
  AMatricula: Integer): Integer;
var
  LLista: string;
  I: Integer;
  LVal: Variant;
begin
  Result := 0;
  if Length(AIds) = 0 then
    Exit;

  // Os ids vem do JS: remontar a lista com IntToStr garante que so' inteiro
  // entra no SQL, sem depender de o front ter mandado numero mesmo
  LLista := '';
  for I := 0 to High(AIds) do
  begin
    if AIds[I] <= 0 then
      Continue;
    if LLista <> '' then
      LLista := LLista + ',';
    LLista := LLista + IntToStr(AIds[I]);
  end;

  if LLista = '' then
    Exit;

  LVal := FSQLite.ExecutarScalar(
    'SELECT COUNT(*) FROM nfce_contingencia ' +
    'WHERE id IN (' + LLista + ') AND status = ''REJEITADO'''
  );
  Result := VarToIntDef(LVal, 0);
  if Result = 0 then
    Exit;

  FSQLite.ExecutarSQL(
    'UPDATE nfce_contingencia ' +
    'SET status = ''DESCARTADO'', ' +
    '    dt_descarte = datetime(''now'',''localtime''), ' +
    '    descartado_por = ' + IntToStr(AMatricula) + ' ' +
    'WHERE id IN (' + LLista + ') AND status = ''REJEITADO'''
  );
end;

function TContingenciaManager.ObterProximoDocParaEnvio: Integer;
var
  LVal: Variant;
begin
  // Pegar o mais antigo com menos de MAX_TENTATIVAS_CONTINGENCIA tentativas
  LVal := FSQLite.ExecutarScalar(
    'SELECT id FROM nfce_contingencia WHERE status = ''PENDENTE'' ' +
    'AND tentativas < ' + IntToStr(MAX_TENTATIVAS_CONTINGENCIA) + ' ' +
    'ORDER BY dt_geracao ASC LIMIT 1'
  );
  if VarIsNull(LVal) or VarIsEmpty(LVal) then
    Result := 0
  else
    Result := LVal;
end;

procedure TContingenciaManager.ReiniciarTentativas;
begin
  FSQLite.ExecutarSQL(
    'UPDATE nfce_contingencia SET tentativas = 0 WHERE status = ''PENDENTE'''
  );
end;

procedure TContingenciaManager.IncrementarTentativa(ADocId: Integer; const AErro: string);
begin
  FSQLite.ExecutarSQL(
    'UPDATE nfce_contingencia SET tentativas = tentativas + 1, ' +
    'ultimo_erro = :p0, dt_ultima_tentativa = datetime(''now'',''localtime'') ' +
    'WHERE id = :p1',
    [AErro, ADocId]
  );
end;

function TContingenciaManager.TipoContingenciaParaACBr: Integer;
begin
  Result := FTipoAtual.ToACBrTpEmis;
end;

end.
