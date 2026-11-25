unit uDocEletronicoNF;

{ O XML da nota fica na MSDOCELETRONICO com o MESMO NUMTRANS da MSNF.

  A NFC-e do PDV sobe o XML com um NUMTRANS novo da SEQ_PROX_NUMTRANS_MOV
  quando a nota ainda nao existe; o job MSAPOLO_GERAR_NF (passo 4.7) religa
  esse XML ao criar a MSNF. Mas o XML que sobe DEPOIS da nota ficava no
  NUMTRANS do PDV para sempre (FERNANDES, 28/10/2026: 17.110 XML). Aqui o
  upload descobre a nota pela chave e grava ja no NUMTRANS dela, e o XML
  que ja estava no Oracle e religado quando o cupom sobe de novo.

  Script do que ja foi gravado: docs\religar-msdoceletronico-msnf.sql. }

interface

uses
  Uni;

/// NUMTRANS da MSNF da chave, quando ela e a UNICA nota com essa chave e
/// ainda nao tem linha na MSDOCELETRONICO (o NUMTRANS e a PK); senao 0.
function NumTransNotaSemXml(AConn: TUniConnection; const AChave: string): Int64;

/// Religa a nota o XML tipo 'P' da chave que esta num NUMTRANS que nao e de
/// MSNF. Devolve o NUMTRANS da nota, ou 0 quando nao havia o que religar.
function ReligarXmlNaNota(AConn: TUniConnection; const AChave: string): Int64;

implementation

uses
  System.SysUtils;

const
  // a MSNF guarda a chave com ou sem o prefixo NFe, conforme quem gravou
  SQL_NOTA_DA_CHAVE =
    'SELECT COUNT(*) QTD, MAX(numtrans) NT, SUM(ocup) OCUP FROM (' +
    '  SELECT n.numtrans, (SELECT COUNT(*) FROM msdoceletronico d' +
    '                       WHERE d.numtrans = n.numtrans) ocup' +
    '    FROM msnf n WHERE n.chavenfe IN (:chave, :chave_nfe))';

  SQL_RELIGAR =
    'UPDATE msdoceletronico d SET d.numtrans = :nt ' +
    // uma linha so: com o XML gravado em duplicidade, as duas iriam para o
    // mesmo NUMTRANS (ORA-00001 na PK_MSDOCELETRONICO)
    ' WHERE d.numtrans = (SELECT MIN(k.numtrans) FROM msdoceletronico k ' +
    '   WHERE k.chavenfe IN (:chave, :chave_nfe) AND k.tipo = ''P'' ' +
    '     AND NOT EXISTS (SELECT 1 FROM msnf x WHERE x.numtrans = k.numtrans))';

function SoDigitos(const S: string): string;
var
  C: Char;
begin
  Result := '';
  for C in S do
    if CharInSet(C, ['0'..'9']) then
      Result := Result + C;
end;

function NumTransNotaSemXml(AConn: TUniConnection; const AChave: string): Int64;
var
  Q: TUniQuery;
  LChave: string;
begin
  Result := 0;
  LChave := SoDigitos(AChave);
  if Length(LChave) <> 44 then
    Exit;
  Q := TUniQuery.Create(nil);
  try
    Q.Connection := AConn;
    Q.SQL.Text := SQL_NOTA_DA_CHAVE;
    Q.ParamByName('chave').AsString := LChave;
    Q.ParamByName('chave_nfe').AsString := 'NFe' + LChave;
    Q.Open;
    if (Q.FieldByName('QTD').AsInteger = 1) and (Q.FieldByName('OCUP').AsInteger = 0) then
      Result := Q.FieldByName('NT').AsLargeInt;
  finally
    Q.Free;
  end;
end;

function ReligarXmlNaNota(AConn: TUniConnection; const AChave: string): Int64;
var
  Q: TUniQuery;
  LNumTrans: Int64;
begin
  Result := 0;
  LNumTrans := NumTransNotaSemXml(AConn, AChave);
  if LNumTrans = 0 then
    Exit;
  Q := TUniQuery.Create(nil);
  try
    Q.Connection := AConn;
    Q.SQL.Text := SQL_RELIGAR;
    Q.ParamByName('nt').AsLargeInt := LNumTrans;
    Q.ParamByName('chave').AsString := SoDigitos(AChave);
    Q.ParamByName('chave_nfe').AsString := 'NFe' + SoDigitos(AChave);
    Q.ExecSQL;
    if Q.RowsAffected = 1 then
      Result := LNumTrans;
  finally
    Q.Free;
  end;
end;

end.
