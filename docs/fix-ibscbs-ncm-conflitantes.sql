-- =====================================================================
-- ORDOTY - limpeza das NCMs com regra de IBS/CBS conflitante
-- Gerado em 05/09/2026 a partir do diagnostico da rejeicao
-- "Nao informado o grupo de reducao de aliquota Estadual"
--
-- SINTOMA: o coco ralado (EAN 7895099540529, codprod 9087, NCM 0801.19.00)
-- saia na NFC-e com CST 200 / cClassTrib 200004 = "Venda de dispositivos
-- medicos (Anexo XII)".
--
-- CAUSA: em MSNCM_IBS_CBS a mesma NCM tem DUAS regras diferentes - 3 linhas
-- apontando para a regra 1 (000/000001, tributacao integral) e 3 linhas
-- apontando para uma classificacao especial. Como as duas sao regra de NCM,
-- empatam em prioridade e o PDV escolhia uma delas.
--
-- Este script APAGA as linhas da regra especial das NCMs que tambem tem a
-- regra integral, deixando so a integral.
--
-- >>> RODAR NO SQL DO ORDOTY, USUARIO FERNANDES. Nada e' commitado
-- >>> automaticamente: confira o passo 4 antes do COMMIT do passo 5.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) ANTES: o que existe hoje (10 NCMs, 3 linhas por regra)
-- ---------------------------------------------------------------------
select lpad(trim(n.ncm),8,'0') ncm,
       n.id_ibs_cbs,
       t.cst,
       t.cclasstrib,
       substr(t.nome_cclasstrib,1,45) regra,
       count(*) linhas
  from msncm_ibs_cbs n, ms_trib_ibs_cbs t
 where t.id = n.id_ibs_cbs
   and n.codfilial = 1
   and n.ncm is not null
   and lpad(trim(n.ncm),8,'0') in (
         select lpad(trim(ncm),8,'0')
           from msncm_ibs_cbs
          where codfilial = 1 and ncm is not null
          group by lpad(trim(ncm),8,'0')
         having count(distinct id_ibs_cbs) > 1)
 group by lpad(trim(n.ncm),8,'0'), n.id_ibs_cbs, t.cst, t.cclasstrib,
          substr(t.nome_cclasstrib,1,45)
 order by 1, 2;

-- Esperado (05/09/2026):
--   08011900 -> 1 (integral) e 15  (dispositivos medicos)      <= o coco
--   17019900 -> 1 e 14  (alimentacao humana, Anexo I)
--   17049010 -> 1 e 70  (bonificacoes, CST 410)
--   17049020 -> 1 e 70
--   18063210 -> 1 e 70
--   19053200 -> 1 e 70
--   20081100 -> 1 e 45  (alimentos p/ consumo, Anexo ...)
--   21069050 -> 1 e 70
--   48119019 -> 1 e 101 (operacoes nao onerosas)
--   48181000 -> 1, 14 e 46 (higiene pessoal)
--
-- ATENCAO DO CONTADOR: 17019900, 20081100 e 48181000 podem ser cesta basica
-- de verdade (regras 14/45/46). Se alguma delas DEVE ficar reduzida, tire a
-- NCM da lista do passo 3 e, em vez de apagar a linha especial, apague as
-- linhas da regra 1 dessa NCM.

-- ---------------------------------------------------------------------
-- 2) BACKUP das linhas que serao apagadas
-- ---------------------------------------------------------------------
create table msncm_ibs_cbs_bkp_20260905 as
select n.*
  from msncm_ibs_cbs n
 where n.codfilial = 1
   and n.ncm is not null
   and n.id_ibs_cbs <> 1
   and exists (select 1
                 from msncm_ibs_cbs x
                where x.codfilial  = n.codfilial
                  and x.ncm is not null
                  and lpad(trim(x.ncm),8,'0') = lpad(trim(n.ncm),8,'0')
                  and x.id_ibs_cbs = 1);

-- Para voltar atras depois do commit:
--   insert into msncm_ibs_cbs select * from msncm_ibs_cbs_bkp_20260905;
--   commit;

-- ---------------------------------------------------------------------
-- 3) DELETE (deve apagar 30 linhas = 10 NCMs x 3)
-- ---------------------------------------------------------------------
delete from msncm_ibs_cbs n
 where n.codfilial = 1
   and n.ncm is not null
   and n.id_ibs_cbs <> 1
   and exists (select 1
                 from msncm_ibs_cbs x
                where x.codfilial  = n.codfilial
                  and x.ncm is not null
                  and lpad(trim(x.ncm),8,'0') = lpad(trim(n.ncm),8,'0')
                  and x.id_ibs_cbs = 1);

-- ---------------------------------------------------------------------
-- 4) DEPOIS: nao pode sobrar nenhuma NCM com mais de uma regra
-- ---------------------------------------------------------------------
select lpad(trim(ncm),8,'0') ncm, count(distinct id_ibs_cbs) regras
  from msncm_ibs_cbs
 where codfilial = 1 and ncm is not null
 group by lpad(trim(ncm),8,'0')
having count(distinct id_ibs_cbs) > 1;
-- Esperado: nenhuma linha.

-- E o coco tem que sobrar so com a regra 1:
select n.ncm, n.id_ibs_cbs, t.cst, t.cclasstrib
  from msncm_ibs_cbs n, ms_trib_ibs_cbs t
 where t.id = n.id_ibs_cbs
   and n.codfilial = 1
   and trim(n.ncm) in ('08011900','8011900');
-- Esperado: 3 linhas, todas com CST 000 / cClassTrib 000001.

-- ---------------------------------------------------------------------
-- 5) Confirmar
-- ---------------------------------------------------------------------
commit;
-- (ou  rollback;  se o passo 4 nao bater)


-- =====================================================================
-- OPCIONAL A - regra geral (fallback) da filial
-- ---------------------------------------------------------------------
-- Existe a linha id 1374 (codfilial 1, ncm e codprod nulos), que seria a
-- regra "vale para todos os produtos", mas ela esta com MODELO e ID_IBS_CBS
-- NULOS: nao passa no filtro modelo in (0,65) nem no join, entao a carga do
-- PDV nem ve essa linha. Resultado: produto cuja NCM nao esta cadastrada sai
-- SEM o grupo IBS/CBS e a nota e' rejeitada com "IBS/CBS nao informado" -
-- foi o que aconteceu com o codprod 314 (NCM 0402.99.00) no cupom 132.
--
-- Preenchendo a linha, todo produto sem regra passa a sair como tributacao
-- integral em vez de derrubar a venda:
--
-- update msncm_ibs_cbs
--    set modelo = 0, id_ibs_cbs = 1
--  where codfilial = 1 and ncm is null and codprod is null;
-- commit;

-- =====================================================================
-- OPCIONAL B - cadastro triplicado
-- ---------------------------------------------------------------------
-- A filial 1 tem 459 linhas para 153 NCMs (cada NCM cadastrada 3x). Nao
-- quebra nada depois da limpeza acima - as 3 linhas apontam para a mesma
-- regra - mas engorda a carga do PDV. Para conferir:
--
-- select lpad(trim(ncm),8,'0') ncm, count(*) linhas
--   from msncm_ibs_cbs where codfilial = 1 and ncm is not null
--  group by lpad(trim(ncm),8,'0') having count(*) > 1 order by 2 desc;
