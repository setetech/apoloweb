# Prompt para a nova sessão — motor tributário da rotina 2015 (Reforma Tributária)

Copie o bloco abaixo como primeira mensagem da nova sessão.

---

Quero recriar/afinar o **motor tributário de IBS/CBS da rotina 2015 (Reforma Tributária)** do ERP Colosso, com o objetivo de o PDV **ApoloWeb** parar de ter rejeição de NFC-e por tributação. Trate isto como projeto, não como correção pontual: primeiro levante o estado real, depois proponha o desenho, e só então implemente.

## Onde está cada coisa

| Camada | Caminho / objeto |
|---|---|
| Cadastro (rotina 2015) | `C:\Sete\Colosso\Fontes\Modulos\Cadastros\2015 - Reforma Tributaria\` — `uReformaTributaria.pas/.dfm`, `uSQLPadrao.pas` |
| Motor de cálculo do ERP | `C:\Sete\Colosso\Fontes\Modulos\NFe\Comun\uTributacaoNFe.pas` → `Bloco_Calcular_IBS_CBS` (PL/SQL gerado por string) |
| Carga do PDV | procedure Oracle `FERNANDES.gerartabelatemporaria_apolo` → `msapolo_produto_temp` → view `msapolo_produtos`. Fonte versionado em `C:\Sete\Colosso\Fontes\Modulos\ApoloWeb\docs\gerartabelatemporaria_apolo.sql` |
| Sync do PDV | `Modulos\ApoloWeb\uSincronizacao.pas` → `SincronizarTribIBSCBS` (espelha em SQLite `trib_ibs_cbs`, schema v24) |
| Emissão no PDV | `Modulos\ApoloWeb\uNFCeWeb.pas` → `ResolverIBSCBS` e `PreencherIBSCBSItem` |
| Tabelas Oracle | `MSNCM_IBS_CBS` (regra por filial) e `MS_TRIB_IBS_CBS` (catálogo de cClassTrib) |
| Banco | ORDOTY. Credenciais em `C:\Apolo\apoloweb.ini`, seção `[oracle]`. `sqlplus` em `/c/instantclient/sqlplus` (Git Bash). **Só SELECT sem me perguntar**; qualquer DDL/DML você me entrega como script |

Leia antes de propor: `Modulos\ApoloWeb\docs\gerartabelatemporaria_apolo.sql`, `docs\fix-ibscbs-ncm-conflitantes.sql` e `docs\tributar-ncms-sem-regra-ibscbs.sql` — são o diagnóstico de 05/09/2026 e explicam como o cadastro está hoje.

## Como o modelo funciona hoje

`MSNCM_IBS_CBS` (id, codfilial, idncm, ncm, codprod, id_ibs_cbs, cmunfg, codoper, modelo) diz qual classificação vale para quê; `MS_TRIB_IBS_CBS` guarda a tabela de cClassTrib da NT (cst, cclasstrib, ativo, indnfce, tipo_aliquota, aliq_ibs, aliq_cbs, pibsmun, predibs, predcbs, ibsuf_predaliq, ibsuf_paliqefet, ibsmun_*, cbs_*, dinivig, dfimvig).

A precedência que o PDV aplica é: **regra do codprod → regra da NCM → regra geral (codprod e ncm nulos)**, com `modelo in (0,65)`.

## Defeitos já mapeados (confirmados no ORDOTY em 05/09/2026)

1. **Sem chave única**: `id` vem de `select max(id)+1` (`uSQLPadrao.SQL_Salvar_NCM_IBS_CBS`), há ids repetidos, e nada impede duas regras para a mesma (filial, NCM). Deu tributação sorteada — o coco (NCM 0801.19.00) saiu como "dispositivos médicos" e a SEFAZ rejeitou.
2. **NCM desnormalizada e inconsistente**: a coluna `ncm` é texto, parte das linhas está sem o zero à esquerda (`8011900` × `08011900`), e a tela salva por `idncm` — mas a carga do PDV casa por `ncm`. Decidir uma chave só (provavelmente `idncm`) e fazer todo mundo usar ela.
3. **Cadastro duplicado**: as NCMs estavam triplicadas (459 linhas para 153 NCMs).
4. **Cobertura baixa**: produtos ativos usam 433 NCMs e só ~137 tinham regra; 296 por filial ficaram sem nada — sem regra a NFC-e é rejeitada com "IBS/CBS não informado".
5. **Regra geral quebrada**: a linha "todos os produtos" (id 1374, filial 1) está com `modelo` e `id_ibs_cbs` nulos, então nem entra na carga. Não existe fallback nenhum.
6. **Percentuais de redução incompletos**: as classificações reduzidas têm `PREDALIQ = 100` e `PALIQEFET` nulo. O motor do ERP (`if PALIQEFET > 0 then usa, else alíquota cheia`) gera um XML incoerente: "reduzi 100%" cobrando a alíquota cheia. O PDV já contorna derivando `efetiva = cheia × (1 − pRedAliq/100)`, mas o certo é o cadastro fechar isso.
7. **Colunas ignoradas**: `dinivig`/`dfimvig` (vigência), `indnfce` (a classificação vale para NFC-e?), `ativo`, `cmunfg`, `codoper` não são consideradas em lugar nenhum da resolução.
8. **Sem validação na entrada**: dá para gravar CST 200 sem redução, cClassTrib que não existe na NT, ou combinação CST × cClassTrib inválida — o erro só aparece na rejeição da SEFAZ.
9. **Sem visibilidade**: não há relatório de cobertura (quais NCMs de produtos ativos estão sem regra, quais têm regra ambígua). Hoje isso só aparece em `msapolo_erro` depois da carga.

## O que eu quero

1. **Diagnóstico atualizado** do cadastro nas filiais que têm caixa (`msapolo_caixa`), com números — não impressões.
2. **Desenho do modelo**: chave única de regra, precedência formal (produto → NCM → geral, com vigência e `indnfce`), o que fazer com `cmunfg`/`codoper`/`modelo`, e como a redução (`gRed`) deve ser cadastrada e derivada. Me apresente antes de codificar; se houver mais de um caminho razoável, recomende um.
3. **Rotina 2015 melhor**: validação na gravação (CST × cClassTrib × redução × vigência), impedir regra duplicada, aplicar em massa por faixa de NCM/capítulo, importar a tabela oficial de cClassTrib da NT, e uma aba de cobertura ("N NCMs de produtos ativos sem regra / M ambíguas") com atalho para resolver.
4. **Motor único**: `Bloco_Calcular_IBS_CBS` (ERP) e `PreencherIBSCBSItem` (PDV) precisam dar o mesmo resultado para o mesmo item. Aponte as divergências e proponha como manter os dois em sincronia.
5. **Migração** do cadastro atual para o modelo novo, com script reversível e conferência antes/depois.

## Regras de trabalho

- Compilar o ApoloWeb sempre de `C:\Sete\Colosso\Fontes\Modulos\ApoloWeb\`, `Debug/Win32` (só essa config publica em `C:\Apolo`); conferir o `LastWriteTime` do exe.
- **Não rodar DDL/DML no ORDOTY.** Me entregue script com backup, conferência antes/depois e o `COMMIT` no final, separado. SELECT à vontade.
- Não quebrar a emissão de NF-e do ERP, que usa as mesmas tabelas.
- Nada de mudança de tratamento tributário por conta própria: onde a decisão for do contador (cesta básica / Anexo I, alíquota reduzida), me liste para revisar em vez de escolher.
- O ambiente já está em produção (`tpAmb=1`) e os caixas emitem o dia inteiro — mudança que possa esvaziar a carga de produtos precisa de freio, como o que já existe na `gerartabelatemporaria_apolo`.

Comece pelo item 1 e me mostre o diagnóstico antes de partir para o desenho.
