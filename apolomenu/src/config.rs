//! Configuracao do menu (apolomenu.ini).
//!
//! Mesmo layout de secao [oracle] do apoloweb.ini, para que um terminal que ja
//! roda o PDV nao precise ser configurado de novo: se o apolomenu.ini nao tiver
//! servidor, a conexao e' lida do apoloweb.ini da mesma pasta.

use std::path::{Path, PathBuf};
use std::time::Duration;

use ini::{EscapePolicy, Ini, LineSeparator, ParseOption, WriteOption};

#[cfg(windows)]
const PASTA_PADRAO: &str = r"c:\apolo";
#[cfg(not(windows))]
const PASTA_PADRAO: &str = ".";

const ARQUIVO_INI: &str = "apolomenu.ini";
const ARQUIVO_INI_PDV: &str = "apoloweb.ini";

// Consultas padrao. Os binds sao NOMEADOS (:login, :senha, :matricula,
// :codrotina) e viram posicionais em sql::preparar - quem ajustar o SQL no ini
// pode usar o mesmo bind mais de uma vez, em qualquer ordem.

/// Colunas por posicao: matricula, nome, usuario.
/// A senha e' comparada como no PDV (uSincronizacao: ofuscar(senhadb,usuariodb)
/// contra o digitado, sem diferenciar maiusculas), mas aqui dentro do Oracle
/// e com bind - a senha nunca vem para o terminal.
pub const SQL_LOGIN_PADRAO: &str = "\
SELECT f.matricula, f.nome, f.usuariodb \
  FROM msfunc f \
 WHERE f.dtexclusao IS NULL \
   AND (TO_CHAR(f.matricula) = :login OR UPPER(f.usuariodb) = UPPER(:login)) \
   AND UPPER(ofuscar(f.senhadb, f.usuariodb)) = UPPER(:senha)";

/// Colunas por posicao: codrotina, nome, modulo (opcional), executavel (opcional).
pub const SQL_ROTINAS_PADRAO: &str = "\
SELECT r.codrotina, r.descricao, r.modulo \
  FROM msrotina r \
 WHERE EXISTS (SELECT 1 FROM msacesso a \
                WHERE a.codrotina = r.codrotina \
                  AND a.matricula = :matricula) \
 ORDER BY r.codrotina";

/// Primeira coluna > 0 (ou qualquer linha retornada) libera a rotina.
pub const SQL_ACESSO_PADRAO: &str = "\
SELECT COUNT(*) FROM msacesso \
 WHERE matricula = :matricula AND codrotina = :codrotina";

#[derive(Debug, Clone, Default)]
pub struct OracleCfg {
    /// host:porta/servico, host:porta:SID ou host/servico (mesmo formato do
    /// Direct do UniDAC usado no ApoloWeb)
    pub server: String,
    /// Usada quando o server nao traz porta
    pub port: Option<u16>,
    pub username: String,
    pub password: String,
    pub timeout_seg: u64,
}

#[derive(Debug, Clone)]
pub struct RotinasCfg {
    pub pasta: PathBuf,
    /// Nome do executavel; aceita {codrotina}
    pub executavel: String,
    /// Argumentos separados por espaco; aceitam {codrotina} {matricula} {usuario}
    pub parametros: String,
}

#[derive(Debug, Clone)]
pub struct SqlCfg {
    pub login: String,
    pub rotinas: String,
    pub acesso: String,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub arquivo: PathBuf,
    /// De qual arquivo veio a secao [oracle] (apolomenu.ini ou apoloweb.ini)
    pub origem_oracle: PathBuf,
    pub oracle: OracleCfg,
    pub rotinas: RotinasCfg,
    pub sql: SqlCfg,
}

impl Config {
    /// Caminho do ini: APOLOMENU_INI ou c:\apolo\apolomenu.ini
    pub fn caminho_padrao() -> PathBuf {
        std::env::var_os("APOLOMENU_INI")
            .map(PathBuf::from)
            .unwrap_or_else(|| Path::new(PASTA_PADRAO).join(ARQUIVO_INI))
    }

    pub fn carregar() -> Config {
        Self::carregar_de(&Self::caminho_padrao())
    }

    pub fn carregar_de(arquivo: &Path) -> Config {
        let ini = ler_ini(arquivo).unwrap_or_default();
        let mut origem_oracle = arquivo.to_path_buf();
        let mut oracle = ler_oracle(&ini);

        if oracle.server.trim().is_empty() {
            let pdv = arquivo
                .parent()
                .unwrap_or_else(|| Path::new(PASTA_PADRAO))
                .join(ARQUIVO_INI_PDV);
            if let Some(ini_pdv) = ler_ini(&pdv) {
                let oracle_pdv = ler_oracle(&ini_pdv);
                if !oracle_pdv.server.trim().is_empty() {
                    oracle = oracle_pdv;
                    origem_oracle = pdv;
                }
            }
        }

        let pasta_padrao = Path::new(PASTA_PADRAO).join("rotinas");
        let rotinas = RotinasCfg {
            pasta: valor(&ini, "rotinas", "pasta")
                .map(PathBuf::from)
                .unwrap_or(pasta_padrao),
            executavel: valor(&ini, "rotinas", "executavel")
                .unwrap_or_else(|| "ROT{codrotina}.exe".into()),
            parametros: valor(&ini, "rotinas", "parametros")
                .unwrap_or_else(|| "{matricula}".into()),
        };

        let sql = SqlCfg {
            login: valor(&ini, "sql", "login").unwrap_or_else(|| SQL_LOGIN_PADRAO.into()),
            rotinas: valor(&ini, "sql", "rotinas").unwrap_or_else(|| SQL_ROTINAS_PADRAO.into()),
            acesso: valor(&ini, "sql", "acesso_rotina")
                .unwrap_or_else(|| SQL_ACESSO_PADRAO.into()),
        };

        Config {
            arquivo: arquivo.to_path_buf(),
            origem_oracle,
            oracle,
            rotinas,
            sql,
        }
    }

    pub fn configurado(&self) -> bool {
        !self.oracle.server.trim().is_empty() && !self.oracle.username.trim().is_empty()
    }

    /// Grava a secao [oracle] no apolomenu.ini preservando as demais secoes.
    pub fn salvar_oracle(&self, oracle: &OracleCfg) -> Result<(), String> {
        let mut ini = ler_ini(&self.arquivo).unwrap_or_default();
        ini.with_section(Some("oracle"))
            .set("server", oracle.server.trim())
            .set("port", oracle.port.map(|p| p.to_string()).unwrap_or_default())
            .set("username", oracle.username.trim())
            .set("password", oracle.password.as_str())
            .set("timeout", oracle.timeout_seg.to_string());
        if let Some(pasta) = self.arquivo.parent() {
            std::fs::create_dir_all(pasta).map_err(|e| format!("{}: {e}", pasta.display()))?;
        }
        let mut texto = Vec::new();
        ini.write_to_opt(
            &mut texto,
            WriteOption {
                // Caminho do Windows e SQL vao como estao, sem \\ nem aspas
                escape_policy: EscapePolicy::Nothing,
                line_separator: LineSeparator::CRLF,
                ..WriteOption::default()
            },
        )
        .map_err(|e| e.to_string())?;
        std::fs::write(&self.arquivo, para_ansi(&String::from_utf8_lossy(&texto)))
            .map_err(|e| format!("{}: {e}", self.arquivo.display()))
    }
}

impl OracleCfg {
    /// Config do driver thin. Nenhuma biblioteca Oracle e' carregada: o
    /// oracle-rs fala TNS direto no socket.
    pub fn driver(&self) -> Result<oracle_rs::Config, String> {
        let server = self.server.trim();
        if server.is_empty() {
            return Err("Servidor Oracle nao configurado".into());
        }
        let mut cfg: oracle_rs::Config = server
            .parse()
            .map_err(|e| format!("Servidor Oracle invalido ({server}): {e}"))?;
        if let Some(porta) = self.port {
            if !server_tem_porta(server) {
                cfg.port = porta;
            }
        }
        cfg.set_username(self.username.trim());
        cfg.set_password(self.password.as_str());
        Ok(cfg.connect_timeout(Duration::from_secs(self.timeout_seg.max(1))))
    }
}

/// "host:1521/ORCL" e "host:1521:ORCL" trazem porta; "host/ORCL" e "host" nao.
fn server_tem_porta(server: &str) -> bool {
    let host_porta = server.trim_start_matches('/').split('/').next().unwrap_or("");
    host_porta.contains(':')
}

fn ler_oracle(ini: &Ini) -> OracleCfg {
    OracleCfg {
        server: valor(ini, "oracle", "server").unwrap_or_default(),
        port: valor(ini, "oracle", "port").and_then(|p| p.trim().parse().ok()),
        username: valor(ini, "oracle", "username").unwrap_or_default(),
        password: valor(ini, "oracle", "password").unwrap_or_default(),
        timeout_seg: valor(ini, "oracle", "timeout")
            .and_then(|t| t.trim().parse().ok())
            .unwrap_or(15),
    }
}

fn valor(ini: &Ini, secao: &str, chave: &str) -> Option<String> {
    ini.section(Some(secao))
        .and_then(|s| s.get(chave))
        .map(str::to_string)
        .filter(|v| !v.trim().is_empty())
}

/// Os ini do Apolo sao gravados pelo TIniFile do Delphi (ANSI/cp1252). Sem
/// isso uma senha acentuada derrubaria a leitura do arquivo inteiro.
fn ler_ini(arquivo: &Path) -> Option<Ini> {
    let bytes = std::fs::read(arquivo).ok()?;
    let texto = match String::from_utf8(bytes) {
        Ok(t) => t,
        Err(e) => e.into_bytes().iter().map(|&b| b as char).collect(),
    };
    let opcoes = ParseOption {
        // TIniFile nao tem escape: c:\apolo\rotinas e' literal, e 'S' no SQL
        // nao pode perder os apostrofos
        enabled_quote: false,
        enabled_escape: false,
        ..ParseOption::default()
    };
    Ini::load_from_str_opt(texto.trim_start_matches('\u{feff}'), opcoes).ok()
}

/// Grava em Latin-1 quando possivel, para o TIniFile das rotinas Delphi ler a
/// senha acentuada certo; caractere fora do Latin-1 mantem o arquivo em UTF-8.
fn para_ansi(texto: &str) -> Vec<u8> {
    if texto.chars().all(|c| (c as u32) <= 0xFF) {
        texto.chars().map(|c| c as u8).collect()
    } else {
        texto.as_bytes().to_vec()
    }
}

/// Troca {chave} pelos valores; chave desconhecida fica como esta.
pub fn expandir(modelo: &str, valores: &[(&str, String)]) -> String {
    let mut saida = modelo.to_string();
    for (chave, valor) in valores {
        saida = saida.replace(&format!("{{{chave}}}"), valor);
    }
    saida
}

#[cfg(test)]
mod testes {
    use super::*;

    #[test]
    fn porta_no_server() {
        assert!(server_tem_porta("10.0.0.1:1521/ORCL"));
        assert!(server_tem_porta("10.0.0.1:1521:ORCL"));
        assert!(server_tem_porta("//10.0.0.1:1521/ORCL"));
        assert!(!server_tem_porta("10.0.0.1/ORCL"));
        assert!(!server_tem_porta("10.0.0.1"));
    }

    #[test]
    fn driver_usa_porta_do_ini_so_sem_porta_no_server() {
        let mut cfg = OracleCfg {
            server: "srv/ORCL".into(),
            port: Some(1522),
            username: "apolo".into(),
            password: "x".into(),
            timeout_seg: 5,
        };
        assert_eq!(cfg.driver().unwrap().port, 1522);
        cfg.server = "srv:1530/ORCL".into();
        assert_eq!(cfg.driver().unwrap().port, 1530);
    }

    #[test]
    fn expande_modelo() {
        let s = expandir(
            "ROT{codrotina}.exe {matricula} {x}",
            &[("codrotina", "6030".into()), ("matricula", "12".into())],
        );
        assert_eq!(s, "ROT6030.exe 12 {x}");
    }

    #[test]
    fn le_oracle_do_pdv_quando_menu_nao_tem() {
        let dir = std::env::temp_dir().join(format!("apolomenu-teste-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // ANSI como o TIniFile grava, com secao em maiuscula como o ApoloWeb salva
        std::fs::write(
            dir.join(ARQUIVO_INI_PDV),
            b"[Oracle]\r\nserver=srv:1521/ORCL\r\nusername=APOLO\r\npassword=s\xe9nha\r\n",
        )
        .unwrap();
        std::fs::write(dir.join(ARQUIVO_INI), "[rotinas]\npasta=d:\\rot\n").unwrap();

        let cfg = Config::carregar_de(&dir.join(ARQUIVO_INI));
        assert_eq!(cfg.oracle.server, "srv:1521/ORCL");
        assert_eq!(cfg.oracle.password, "s\u{e9}nha");
        assert_eq!(cfg.origem_oracle, dir.join(ARQUIVO_INI_PDV));
        assert_eq!(cfg.rotinas.pasta, PathBuf::from("d:\\rot"));
        assert_eq!(cfg.sql.login, SQL_LOGIN_PADRAO);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn salva_oracle_sem_escape_e_mantem_outras_secoes() {
        let dir = std::env::temp_dir().join(format!("apolomenu-salvar-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let arq = dir.join(ARQUIVO_INI);
        std::fs::write(&arq, "[rotinas]\r\npasta=c:\\apolo\\rotinas\r\n[sql]\r\nacesso_rotina=SELECT 1 FROM dual WHERE 'S' = 'S'\r\n").unwrap();

        let cfg = Config::carregar_de(&arq);
        assert_eq!(cfg.sql.acesso, "SELECT 1 FROM dual WHERE 'S' = 'S'");
        let oracle = OracleCfg {
            server: "srv:1521/ORCL".into(),
            port: None,
            username: "APOLO".into(),
            password: "s\u{e9}nha".into(),
            timeout_seg: 20,
        };
        cfg.salvar_oracle(&oracle).unwrap();

        let bytes = std::fs::read(&arq).unwrap();
        assert!(bytes.windows(5).any(|w| w == b"s\xe9nha"), "senha em Latin-1");
        let relido = Config::carregar_de(&arq);
        assert_eq!(relido.oracle.password, "s\u{e9}nha");
        assert_eq!(relido.oracle.timeout_seg, 20);
        assert_eq!(relido.rotinas.pasta, PathBuf::from("c:\\apolo\\rotinas"));
        assert_eq!(relido.sql.acesso, cfg.sql.acesso);

        std::fs::remove_dir_all(&dir).ok();
    }
}
