# Apolo Menu (Rust)

Substituto do `menu.exe`: o usuario entra com matricula/usuario e senha, ve
as rotinas que o Oracle libera para ele e abre cada uma pelo codigo.

| Requisito | Como foi feito |
|---|---|
| 1. Oracle sem client | [`oracle-rs`](https://crates.io/crates/oracle-rs): protocolo TNS em Rust puro. Nenhum Oracle Client, Instant Client, OCI ou DLL - so o `apolomenu.exe`. |
| 2. Rotinas que o usuario tem acesso | A lista vem do Oracle (`[sql] rotinas`) e **cada abertura e' conferida de novo no banco** (`[sql] acesso_rotina`) antes de chamar o executavel. A tela nao decide nada. |
| 3. WebView como ponte | `wry` + `tao` (WebView2 no Windows, o mesmo runtime do ApoloWeb). A tela HTML/JS fica embutida no exe e conversa com o Rust pelo mesmo contrato do ApoloWeb: `{action, data, callbackId}` -> `{sucesso, mensagem, dados}`. |

## Como funciona

```
 web/ (HTML/JS embutido)          src/ (Rust)
 ┌──────────────────────┐  ipc   ┌─────────────┐   TNS   ┌────────┐
 │ bridge.js            │ ─────> │ bridge.rs   │ ──────> │ Oracle │
 │ window.ipc.postMessage│        │  db.rs      │ (thin)  └────────┘
 │ __apoloResolve(...)  │ <───── │  rotinas.rs │ ──spawn──> ROT6030.exe
 └──────────────────────┘ eval   └─────────────┘
```

- `main.rs` - janela, WebView, protocolo `apolo://` e o laco de eventos. As
  acoes rodam num runtime tokio fora da thread da janela (a tela nao trava
  esperando o Oracle) e a resposta volta por `evaluate_script`.
- `bridge.rs` - acoes da ponte: `iniciar`, `obterConfig`, `testarConexao`,
  `salvarConfig`, `login`, `logout`, `listarRotinas`, `executarRotina`
  (`fecharApp` e' tratada no `main.rs`).
- `db.rs` - uma conexao, aberta sob demanda e **reaberta sozinha** se a
  sessao cair (testado matando a sessao com `ALTER SYSTEM KILL SESSION`).
- `sql.rs` - converte os binds nomeados do ini (`:matricula`) para os
  posicionais que o driver aceita.
- `rotinas.rs` - monta o caminho do executavel e abre a rotina como processo
  independente; o menu continua aberto.
- A WebView so' navega na propria tela embutida: como a ponte abre
  executaveis, nenhuma pagina externa pode chegar ate ela.

Teclado no menu: digitar o codigo + `Enter` abre a rotina (mesmo fora da
lista - o Oracle decide); texto filtra por nome/modulo; setas/PgUp/PgDn
navegam; `Esc` limpa; `F5` recarrega a lista; duplo clique abre.

## Configuracao

`c:\apolo\apolomenu.ini` (ou o caminho em `APOLOMENU_INI`). Modelo comentado
em [`apolomenu.ini.exemplo`](apolomenu.ini.exemplo).

- Sem `[oracle]` no `apolomenu.ini`, o menu usa o `[oracle]` do
  `c:\apolo\apoloweb.ini` - terminal que ja roda o PDV nao precisa de nada.
- `server` aceita `host:porta/servico`, `host:porta:SID` ou `host/servico`
  (o mesmo formato do `Direct` do UniDAC).
- A tela "Configurar conexao" grava o `[oracle]` e pede a mesma senha de
  administrador do ApoloWeb (`br` + ddmmaa do dia).
- Log em `c:\apolo\logs\apolomenu.log` (login, rotina aberta/negada, erros;
  nunca senha).

### SQL - CONFERIR NO BANCO REAL

O `menu.exe` nao esta neste repositorio, entao as consultas padrao sao
**premissas** baseadas no que o ApoloWeb ja usa. Todas podem ser trocadas no
`[sql]` do ini sem recompilar:

| Chave | Padrao | Premissa |
|---|---|---|
| `login` | `msfunc` + `ofuscar(senhadb, usuariodb)` | Igual a sincronizacao do PDV (`uSincronizacao.pas`), mas a comparacao e' feita no Oracle com bind - a senha nao trafega de volta. Aceita matricula ou `usuariodb`. Colunas: matricula, nome, usuario. |
| `rotinas` | `msrotina (codrotina, descricao, modulo)` com `EXISTS` em `msacesso` | **Nome da tabela/colunas de cadastro de rotinas nao confirmado.** Considera liberada a rotina com qualquer linha em `msacesso` para a matricula. Colunas: codrotina, nome, modulo (opcional), executavel (opcional). |
| `acesso_rotina` | `COUNT(*)` em `msacesso` | Primeira coluna > 0 libera. |

### Chamada da rotina

`[rotinas] pasta` + `executavel` (`ROT{codrotina}.exe` por padrao; a 4a coluna
do SQL de rotinas sobrescreve por rotina). Argumentos em `parametros`
(`{matricula}`, `{codrotina}`, `{usuario}`). A rotina tambem recebe
`APOLO_MATRICULA`, `APOLO_USUARIO`, `APOLO_NOME`, `APOLO_ROTINA` e
`APOLO_INI` no ambiente. **Ajuste ao que as rotinas atuais esperam do
`menu.exe`** - senha nenhuma e' repassada.

## Compilar

Windows (recomendado, MSVC):

```
rustup default stable
cargo build --release
```

Saida: `target\release\apolomenu.exe` (~3 MB, sem DLL). Precisa do runtime
WebView2 (ja presente no Windows 10/11 e nos terminais com ApoloWeb).

Do Linux para Windows: `rustup target add x86_64-pc-windows-gnu`, instale o
`mingw-w64` e rode `cargo build --release --target x86_64-pc-windows-gnu`.

## Testes

```
cargo test
```

Teste com Oracle de verdade (`fluxo_completo_no_oracle` em `src/bridge.rs`),
num banco descartavel com a massa de [`tests/oracle-teste.sql`](tests/oracle-teste.sql):

```
docker run -d --name oracle-teste -p 1521:1521 -e ORACLE_PASSWORD=Sys123 \
  -e APP_USER=APOLO -e APP_USER_PASSWORD=apolo123 gvenzl/oracle-free:23-slim-faststart
docker cp tests/oracle-teste.sql oracle-teste:/tmp/
docker exec oracle-teste sqlplus -s APOLO/apolo123@//localhost/FREEPDB1 @/tmp/oracle-teste.sql
APOLOMENU_TESTE_ORACLE=localhost:1521/FREEPDB1 APOLOMENU_TESTE_USUARIO=APOLO \
APOLOMENU_TESTE_SENHA=apolo123 APOLOMENU_TESTE_SENHA_SYSTEM=Sys123 \
  cargo test -- --ignored
```

## Limites do driver thin (conferir no servidor do cliente)

- Oracle **12.1 ou superior**.
- Usuario do banco com verifier de senha 11g ou 12c. Contas so com verifier
  10g (`SEC_CASE_SENSITIVE_LOGON=FALSE` antigo) nao autenticam.
- Sem *Native Network Encryption*: se o `sqlnet.ora` do servidor exigir
  `SQLNET.ENCRYPTION_SERVER=REQUIRED`, use TLS (TCPS) ou relaxe para
  `ACCEPTED`.
- Erro de PL/SQL dentro do SELECT (ex.: funcao `ofuscar` invalida) chega
  como "Oracle closed the connection without providing error details" em
  vez do ORA- original; teste o SQL no SQL*Plus quando aparecer.

## Proximos passos (fora deste primeiro corte)

4. Conectar via API: `bridge.rs` so' depende de `Banco::consultar`; uma
   implementacao HTTP entra no lugar de `db.rs` sem mexer na tela.
5. ...
