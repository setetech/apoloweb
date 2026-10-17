//! Ponte JS <-> Rust.
//!
//! Mesmo contrato do ApoloWeb (uBridge.pas): o JS manda {action, data,
//! callbackId} e recebe {sucesso, mensagem, dados}. Toda regra (login,
//! liberacao de rotina, gravacao do ini) fica aqui - a tela so' pede.

use std::sync::{Mutex, RwLock};

use oracle_rs::Value as Ora;
use serde_json::{json, Value};

use crate::config::{Config, OracleCfg};
use crate::db::{self, Banco};
use crate::log;
use crate::rotinas::{self, Rotina};
use crate::sessao::{Sessao, Usuario};

pub struct App {
    cfg: RwLock<Config>,
    banco: Banco,
    sessao: Mutex<Option<Sessao>>,
}

type Resultado = Result<(String, Value), String>;

fn ok(mensagem: &str, dados: Value) -> Resultado {
    Ok((mensagem.to_string(), dados))
}

impl App {
    pub fn new(cfg: Config) -> Self {
        App { cfg: RwLock::new(cfg), banco: Banco::default(), sessao: Mutex::new(None) }
    }

    fn cfg(&self) -> Config {
        self.cfg.read().expect("cfg envenenada").clone()
    }

    fn sessao(&self) -> Result<Sessao, String> {
        self.sessao
            .lock()
            .expect("sessao envenenada")
            .clone()
            .ok_or_else(|| "Sessao expirada. Entre novamente.".to_string())
    }

    /// Executa a acao e devolve o JSON de resposta (nunca falha: erro vira
    /// sucesso=false, como no ApoloWeb).
    pub async fn processar(&self, acao: &str, dados: Value) -> String {
        let resultado = match acao {
            "iniciar" => self.iniciar(),
            "obterConfig" => self.obter_config(),
            "testarConexao" => self.testar_conexao(&dados).await,
            "salvarConfig" => self.salvar_config(&dados).await,
            "login" => self.login(&dados).await,
            "logout" => self.logout(),
            "listarRotinas" => self.listar_rotinas().await,
            "executarRotina" => self.executar_rotina(&dados).await,
            _ => Err(format!("Acao desconhecida: {acao}")),
        };
        let resposta = match resultado {
            Ok((mensagem, dados)) => json!({ "sucesso": true, "mensagem": mensagem, "dados": dados }),
            Err(mensagem) => {
                log::registrar(format!("[{acao}] {mensagem}"));
                json!({ "sucesso": false, "mensagem": mensagem, "dados": {} })
            }
        };
        resposta.to_string()
    }

    fn iniciar(&self) -> Resultado {
        let cfg = self.cfg();
        let usuario = self.sessao().ok().map(|s| s.usuario);
        ok(
            "",
            json!({
                "versao": env!("CARGO_PKG_VERSION"),
                "configurado": cfg.configurado(),
                "arquivoIni": cfg.arquivo.display().to_string(),
                "origemOracle": cfg.origem_oracle.display().to_string(),
                "servidor": cfg.oracle.server,
                "usuario": usuario,
            }),
        )
    }

    fn obter_config(&self) -> Resultado {
        let cfg = self.cfg();
        ok(
            "",
            json!({
                "server": cfg.oracle.server,
                "port": cfg.oracle.port,
                "username": cfg.oracle.username,
                "timeout": cfg.oracle.timeout_seg,
                // A senha nao volta para a tela; vazio no salvar = manter
                "temSenha": !cfg.oracle.password.is_empty(),
                "arquivoIni": cfg.arquivo.display().to_string(),
                "origemOracle": cfg.origem_oracle.display().to_string(),
            }),
        )
    }

    /// Monta a OracleCfg da tela; senha em branco reaproveita a gravada.
    fn oracle_da_tela(&self, dados: &Value) -> OracleCfg {
        let atual = self.cfg().oracle;
        let senha = texto(dados, "password");
        OracleCfg {
            server: texto(dados, "server"),
            port: inteiro(dados, "port").and_then(|p| u16::try_from(p).ok()),
            username: texto(dados, "username"),
            password: if senha.is_empty() { atual.password } else { senha },
            timeout_seg: inteiro(dados, "timeout")
                .and_then(|t| u64::try_from(t).ok())
                .filter(|&t| t > 0)
                .unwrap_or(atual.timeout_seg),
        }
    }

    /// Conecta com os dados da tela e roda as 3 consultas do ini com valores
    /// que nao existem: sem linha nenhuma, mas com tabela/coluna/funcao
    /// erradas o ORA- aparece aqui, antes de alguem tentar entrar.
    async fn testar_conexao(&self, dados: &Value) -> Resultado {
        let oracle = self.oracle_da_tela(dados);
        let sql = self.cfg().sql;
        let conn = Banco::conectar(&oracle).await?;

        // Copia dos pacotes so' deste teste (ja autenticado, binds ficticios):
        // e' o que permite diagnosticar o driver num servidor que nao temos aqui
        let trace = log::pasta().map(|p| p.join("oracle-trace.log"));
        if let Some(arq) = &trace {
            let _ = std::fs::remove_file(arq);
            if let Err(e) = conn.set_trace(Some(arq)).await {
                log::registrar(format!("Trace Oracle indisponivel ({}): {e}", arq.display()));
            }
        }

        let primeiro = |linhas: Result<Vec<oracle_rs::Row>, String>| {
            linhas.ok().and_then(|l| l.first().map(|r| db::texto(r, 0)))
        };
        conn.trace_note("SQL versao").await;
        let versao = primeiro(
            db::consultar_em(
                &conn,
                "SELECT version FROM product_component_version \
                  WHERE UPPER(product) LIKE 'ORACLE%' AND ROWNUM = 1",
                &[],
            )
            .await,
        )
        .unwrap_or_default();
        conn.trace_note("SQL charset").await;
        let charset = primeiro(
            db::consultar_em(
                &conn,
                "SELECT value FROM nls_database_parameters WHERE parameter = 'NLS_CHARACTERSET'",
                &[],
            )
            .await,
        )
        .unwrap_or_default();

        let consultas = [
            ("dual", "SELECT 1 FROM dual", vec![]),
            ("login", &sql.login, vec![("login", Ora::from("~teste~")), ("senha", Ora::from("~"))]),
            ("rotinas", &sql.rotinas, vec![("matricula", Ora::Integer(-1))]),
            (
                "acesso_rotina",
                &sql.acesso,
                vec![("matricula", Ora::Integer(-1)), ("codrotina", Ora::Integer(-1))],
            ),
        ];
        let mut verificacoes = Vec::new();
        let mut falhas = 0;
        for (nome, consulta, binds) in consultas {
            conn.trace_note(&format!("SQL {nome}: {consulta}")).await;
            let erro = db::consultar_em(&conn, consulta, &binds).await.err();
            if let Some(e) = &erro {
                falhas += 1;
                log::registrar(format!("[testarConexao] SQL {nome}: {e}"));
            }
            verificacoes.push(json!({ "nome": nome, "ok": erro.is_none(), "mensagem": erro }));
        }
        let _ = conn.set_trace(None).await;
        let _ = conn.close().await;

        let mensagem = if falhas == 0 {
            "Conexao OK".to_string()
        } else {
            format!("Conectou, mas {falhas} consulta(s) do [sql] falharam")
        };
        ok(
            &mensagem,
            json!({
                "versao": versao,
                "charset": charset,
                "falhas": falhas,
                "verificacoes": verificacoes,
                "trace": trace.map(|t| t.display().to_string()),
            }),
        )
    }

    async fn salvar_config(&self, dados: &Value) -> Resultado {
        if !senha_admin_valida(&texto(dados, "senhaAdmin")) {
            return Err("Senha de administrador incorreta.".into());
        }
        let oracle = self.oracle_da_tela(dados);
        if oracle.server.is_empty() || oracle.username.is_empty() {
            return Err("Informe o servidor e o usuario do Oracle.".into());
        }

        let cfg = self.cfg();
        cfg.salvar_oracle(&oracle)?;
        let nova = Config::carregar_de(&cfg.arquivo);
        *self.cfg.write().expect("cfg envenenada") = nova;

        // Banco pode ter mudado: derruba a conexao e a sessao
        self.banco.desconectar().await;
        *self.sessao.lock().expect("sessao envenenada") = None;
        log::registrar(format!("Configuracao Oracle gravada em {}", cfg.arquivo.display()));
        ok("Configuracao salva", json!({}))
    }

    async fn login(&self, dados: &Value) -> Resultado {
        let cfg = self.cfg();
        if !cfg.configurado() {
            return Err("Conexao com o Oracle nao configurada.".into());
        }
        let login = texto(dados, "login");
        let senha = texto(dados, "senha");
        if login.is_empty() {
            return Err("Informe o usuario ou a matricula.".into());
        }

        let linhas = self
            .banco
            .consultar(
                &cfg.oracle,
                &cfg.sql.login,
                &[("login", Ora::from(login.as_str())), ("senha", Ora::from(senha.as_str()))],
            )
            .await?;

        let Some(linha) = linhas.first() else {
            log::registrar(format!("Login recusado: {login}"));
            return Err("Usuario ou senha invalida.".into());
        };
        let usuario = Usuario {
            matricula: db::inteiro(linha, 0).ok_or("SQL de login sem matricula na 1a coluna")?,
            nome: db::texto(linha, 1),
            usuario: db::texto(linha, 2),
        };

        log::registrar(format!("Login: {} ({})", usuario.matricula, usuario.nome));
        *self.sessao.lock().expect("sessao envenenada") =
            Some(Sessao { usuario: usuario.clone(), rotinas: Vec::new() });
        ok("Login realizado com sucesso", json!({ "usuario": usuario }))
    }

    fn logout(&self) -> Resultado {
        if let Some(s) = self.sessao.lock().expect("sessao envenenada").take() {
            log::registrar(format!("Logout: {}", s.usuario.matricula));
        }
        ok("", json!({}))
    }

    async fn listar_rotinas(&self) -> Resultado {
        let cfg = self.cfg();
        let sessao = self.sessao()?;
        let linhas = self
            .banco
            .consultar(
                &cfg.oracle,
                &cfg.sql.rotinas,
                &[("matricula", Ora::Integer(sessao.usuario.matricula))],
            )
            .await?;

        let rotinas: Vec<Rotina> = linhas
            .iter()
            .filter_map(|l| {
                Some(Rotina {
                    codrotina: db::inteiro(l, 0)?,
                    nome: db::texto(l, 1),
                    modulo: db::texto(l, 2),
                    executavel: db::texto(l, 3),
                })
            })
            .collect();

        if let Some(s) = self.sessao.lock().expect("sessao envenenada").as_mut() {
            if s.usuario.matricula == sessao.usuario.matricula {
                s.rotinas = rotinas.clone();
            }
        }
        ok("", json!({ "rotinas": rotinas }))
    }

    async fn executar_rotina(&self, dados: &Value) -> Resultado {
        let cfg = self.cfg();
        let sessao = self.sessao()?;
        let codrotina = inteiro(dados, "codrotina").ok_or("Informe o codigo da rotina.")?;

        // A lista da tela nao vale como autorizacao: confere no Oracle agora
        let linhas = self
            .banco
            .consultar(
                &cfg.oracle,
                &cfg.sql.acesso,
                &[
                    ("matricula", Ora::Integer(sessao.usuario.matricula)),
                    ("codrotina", Ora::Integer(codrotina)),
                ],
            )
            .await?;
        let liberada = linhas.first().is_some_and(|l| db::inteiro(l, 0).is_none_or(|n| n > 0));
        if !liberada {
            log::registrar(format!(
                "Rotina {codrotina} negada para {}",
                sessao.usuario.matricula
            ));
            return Err(format!("Rotina {codrotina} nao liberada para este usuario."));
        }

        let rotina = sessao
            .rotinas
            .iter()
            .find(|r| r.codrotina == codrotina)
            .cloned()
            .unwrap_or(Rotina {
                codrotina,
                nome: String::new(),
                modulo: String::new(),
                executavel: String::new(),
            });

        let pid = rotinas::executar(&cfg.rotinas, &cfg.arquivo, &rotina, &sessao.usuario)?;
        log::registrar(format!(
            "Rotina {codrotina} aberta por {} (pid {pid})",
            sessao.usuario.matricula
        ));
        ok(
            &format!("Rotina {codrotina} aberta"),
            json!({ "pid": pid, "codrotina": codrotina }),
        )
    }
}

/// Mesma regra da tela de configuracao do ApoloWeb: "br" + ddmmyy do dia.
fn senha_admin_valida(senha: &str) -> bool {
    senha == format!("br{}", chrono::Local::now().format("%d%m%y"))
}

fn texto(dados: &Value, chave: &str) -> String {
    match dados.get(chave) {
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

fn inteiro(dados: &Value, chave: &str) -> Option<i64> {
    match dados.get(chave)? {
        Value::Number(n) => n.as_i64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

#[cfg(test)]
mod testes {
    use super::*;

    fn app() -> App {
        App::new(Config::carregar_de(std::path::Path::new("nao-existe/apolomenu.ini")))
    }

    fn resposta(json: &str) -> Value {
        serde_json::from_str(json).unwrap()
    }

    #[tokio::test]
    async fn sem_login_nao_lista_nem_executa() {
        let app = app();
        let r = resposta(&app.processar("listarRotinas", json!({})).await);
        assert_eq!(r["sucesso"], false);
        let r = resposta(&app.processar("executarRotina", json!({"codrotina": 1})).await);
        assert_eq!(r["sucesso"], false);
    }

    #[tokio::test]
    async fn salvar_exige_senha_admin() {
        let app = app();
        let r = resposta(
            &app.processar("salvarConfig", json!({"server": "x/y", "username": "u", "senhaAdmin": "errada"}))
                .await,
        );
        assert_eq!(r["sucesso"], false);
        assert_eq!(r["mensagem"], "Senha de administrador incorreta.");
    }

    #[tokio::test]
    async fn acao_desconhecida() {
        let r = resposta(&app().processar("xyz", json!({})).await);
        assert_eq!(r["sucesso"], false);
    }

    /// Contra um Oracle de verdade (ver README, "Teste com Oracle"):
    /// APOLOMENU_TESTE_ORACLE=host:1521/FREEPDB1 APOLOMENU_TESTE_USUARIO=APOLO
    /// APOLOMENU_TESTE_SENHA=apolo123 cargo test -- --ignored
    #[cfg(unix)]
    #[tokio::test]
    #[ignore]
    async fn fluxo_completo_no_oracle() {
        let var = |n: &str| std::env::var(n).unwrap_or_else(|_| panic!("defina {n}"));
        let dir = std::env::temp_dir().join(format!("apolomenu-oracle-{}", std::process::id()));
        let pasta_rotinas = dir.join("rotinas");
        std::fs::create_dir_all(&pasta_rotinas).unwrap();

        // "Executavel" da rotina 6030: grava os argumentos e o ambiente recebidos
        let saida = dir.join("chamada.txt");
        let exe = pasta_rotinas.join("ROT6030.exe");
        std::fs::write(
            &exe,
            format!("#!/bin/sh\necho \"$@ $APOLO_ROTINA $APOLO_USUARIO\" > {}\n", saida.display()),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();

        let ini = dir.join("apolomenu.ini");
        std::fs::write(
            &ini,
            format!(
                "[oracle]\nserver={}\nusername={}\npassword={}\n[rotinas]\npasta={}\nparametros={{matricula}} {{codrotina}}\n",
                var("APOLOMENU_TESTE_ORACLE"),
                var("APOLOMENU_TESTE_USUARIO"),
                var("APOLOMENU_TESTE_SENHA"),
                pasta_rotinas.display()
            ),
        )
        .unwrap();
        let app = App::new(Config::carregar_de(&ini));
        log::iniciar(Some(&dir));
        let chamar = |acao: &'static str, dados: Value| {
            let app = &app;
            async move { resposta(&app.processar(acao, dados).await) }
        };

        let r = chamar("testarConexao", json!({"server": var("APOLOMENU_TESTE_ORACLE"),
            "username": var("APOLOMENU_TESTE_USUARIO")})).await;
        assert_eq!(r["sucesso"], true, "{r}");
        assert_eq!(r["dados"]["falhas"], 0, "{r}");
        // Trace do teste: pacotes das consultas, nada da autenticacao
        let trace = std::fs::read_to_string(dir.join("logs").join("oracle-trace.log")).unwrap();
        assert!(trace.contains("# SQL dual: SELECT 1 FROM dual"), "{trace}");
        assert!(trace.starts_with("# protocolo="), "{trace}");
        assert!(!trace.contains("AUTH_"), "trace nao pode ter a autenticacao");
        assert!(r["dados"]["versao"].as_str().unwrap().starts_with("23"), "{r}");

        // SQL do ini com coluna errada: o ORA- chega inteiro e a sessao segue
        let ini_errado = dir.join("errado.ini");
        let conteudo = std::fs::read_to_string(&ini).unwrap()
            + "[sql]\nrotinas=SELECT codrotina, coluna_errada FROM msrotina WHERE :matricula = 1\n";
        std::fs::write(&ini_errado, conteudo).unwrap();
        let app_errado = App::new(Config::carregar_de(&ini_errado));
        let r = resposta(&app_errado.processar("testarConexao", json!({"server": var("APOLOMENU_TESTE_ORACLE"),
            "username": var("APOLOMENU_TESTE_USUARIO")})).await);
        assert_eq!(r["dados"]["falhas"], 1, "{r}");
        assert!(r["dados"]["verificacoes"][2]["mensagem"].as_str().unwrap().starts_with("ORA-00904"), "{r}");
        let r = resposta(&app_errado.processar("login", json!({"login": "15", "senha": "segredo"})).await);
        assert_eq!(r["sucesso"], true, "{r}");
        let r = resposta(&app_errado.processar("listarRotinas", json!({})).await);
        assert!(r["mensagem"].as_str().unwrap().starts_with("ORA-00904"), "{r}");
        let r = resposta(&app_errado.processar("executarRotina", json!({"codrotina": 8002})).await);
        assert_eq!(r["mensagem"], "Rotina 8002 nao liberada para este usuario.", "sessao viva apos o erro: {r}");

        let r = chamar("login", json!({"login": "maria", "senha": "errada"})).await;
        assert_eq!(r["mensagem"], "Usuario ou senha invalida.", "{r}");
        let r = chamar("login", json!({"login": "16", "senha": "x"})).await;
        assert_eq!(r["sucesso"], false, "funcionario excluido nao entra: {r}");

        let r = chamar("login", json!({"login": "15", "senha": "SEGREDO"})).await;
        assert_eq!(r["sucesso"], true, "{r}");
        assert_eq!(r["dados"]["usuario"]["nome"], "MARIA SILVA");

        let r = chamar("listarRotinas", json!({})).await;
        let cods: Vec<i64> = r["dados"]["rotinas"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["codrotina"].as_i64().unwrap())
            .collect();
        assert_eq!(cods, [2015, 6030], "{r}");
        assert_eq!(r["dados"]["rotinas"][1]["modulo"], "Financeiro");

        // Sessao derrubada no servidor (firewall/DBA): a proxima acao reconecta
        if let Ok(senha_system) = std::env::var("APOLOMENU_TESTE_SENHA_SYSTEM") {
            let mut cfg = Config::carregar_de(&ini).oracle;
            cfg.username = "SYSTEM".into();
            cfg.password = senha_system;
            let dba = Banco::conectar(&cfg).await.unwrap();
            let sessoes = dba
                .query("SELECT sid, serial# FROM v$session WHERE username = :1", &["APOLO".into()])
                .await
                .unwrap();
            assert!(!sessoes.rows.is_empty());
            for s in &sessoes.rows {
                let sql = format!(
                    "ALTER SYSTEM KILL SESSION '{},{}' IMMEDIATE",
                    db::texto(s, 0),
                    db::texto(s, 1)
                );
                dba.execute(&sql, &[]).await.unwrap();
            }
            let r = chamar("listarRotinas", json!({})).await;
            assert_eq!(r["sucesso"], true, "reconexao: {r}");
        }

        let r = chamar("executarRotina", json!({"codrotina": 8002})).await;
        assert_eq!(r["mensagem"], "Rotina 8002 nao liberada para este usuario.", "{r}");

        let r = chamar("executarRotina", json!({"codrotina": 2015})).await;
        assert!(r["mensagem"].as_str().unwrap().contains("nao encontrado"), "{r}");

        let r = chamar("executarRotina", json!({"codrotina": "6030"})).await;
        assert_eq!(r["sucesso"], true, "{r}");
        for _ in 0..50 {
            if saida.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        assert_eq!(std::fs::read_to_string(&saida).unwrap().trim(), "15 6030 6030 MARIA");

        chamar("logout", json!({})).await;
        let r = chamar("listarRotinas", json!({})).await;
        assert_eq!(r["sucesso"], false);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn le_campos_numero_ou_texto() {
        let d = json!({"a": "12", "b": 7, "c": " x "});
        assert_eq!(inteiro(&d, "a"), Some(12));
        assert_eq!(inteiro(&d, "b"), Some(7));
        assert_eq!(texto(&d, "c"), "x");
        assert_eq!(texto(&d, "nada"), "");
    }
}
