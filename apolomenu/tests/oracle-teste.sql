-- Massa do teste fluxo_completo_no_oracle (src/bridge.rs). Rodar como o
-- usuario de aplicacao num banco DESCARTAVEL, ex.:
--   sqlplus APOLO/apolo123@//localhost/FREEPDB1 @tests/oracle-teste.sql
CREATE TABLE msfunc (matricula NUMBER(8) PRIMARY KEY, nome VARCHAR2(60),
  usuariodb VARCHAR2(30), senhadb VARCHAR2(60), dtexclusao DATE);
CREATE TABLE msrotina (codrotina NUMBER(6) PRIMARY KEY, descricao VARCHAR2(80),
  modulo VARCHAR2(40));
CREATE TABLE msacesso (matricula NUMBER(8), codrotina NUMBER(6), controle NUMBER(4));

-- ofuscar de mentira: no teste a senha "ofuscada" e' so' a senha invertida
CREATE OR REPLACE FUNCTION ofuscar(p_senha VARCHAR2, p_usuario VARCHAR2) RETURN VARCHAR2 IS
  r VARCHAR2(200);
BEGIN
  FOR i IN REVERSE 1 .. NVL(LENGTH(p_senha), 0) LOOP r := r || SUBSTR(p_senha, i, 1); END LOOP;
  RETURN r;
END;
/

INSERT INTO msfunc VALUES (15, 'MARIA SILVA', 'MARIA', ofuscar('segredo', NULL), NULL);
INSERT INTO msfunc VALUES (16, 'JOAO DEMITIDO', 'JOAO', ofuscar('x', NULL), SYSDATE);
INSERT INTO msrotina VALUES (6030, 'Acerto de caixa', 'Financeiro');
INSERT INTO msrotina VALUES (2015, 'Cadastro de mercadorias', 'Estoque');
INSERT INTO msrotina VALUES (8002, 'PDV', 'Vendas');
INSERT INTO msacesso VALUES (15, 6030, 0);
INSERT INTO msacesso VALUES (15, 2015, 0);
INSERT INTO msacesso VALUES (15, 2015, 1);
COMMIT;
EXIT
