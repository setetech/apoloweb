//! Conexao Oracle sem client.
//!
//! Uma conexao unica, aberta sob demanda e reaberta se cair (o menu fica
//! horas parado na tela e firewall/servidor derrubam sessoes ociosas).

use std::time::Duration;

use oracle_rs::{Connection, Row, Value};
use tokio::sync::Mutex;

use crate::config::OracleCfg;
use crate::sql;

const TAMANHO_FETCH: u32 = 200;

#[derive(Default)]
pub struct Banco {
    conexao: Mutex<Option<Connection>>,
}

impl Banco {
    pub async fn conectar(cfg: &OracleCfg) -> Result<Connection, String> {
        let driver = cfg.driver()?;
        let limite = Duration::from_secs(cfg.timeout_seg.max(1));
        match tokio::time::timeout(limite, Connection::connect_with_config(driver)).await {
            Ok(Ok(conn)) => Ok(conn),
            Ok(Err(e)) => Err(format!("Falha ao conectar no Oracle: {}", texto_erro(&e))),
            Err(_) => Err(format!(
                "Oracle nao respondeu em {}s ({})",
                limite.as_secs(),
                cfg.server
            )),
        }
    }

    /// SELECT com binds nomeados; traz todas as linhas (fetch_more ate o fim).
    pub async fn consultar(
        &self,
        cfg: &OracleCfg,
        sql_nomeado: &str,
        binds: &[(&str, Value)],
    ) -> Result<Vec<Row>, String> {
        let (sql, params) = sql::preparar(sql_nomeado, binds)?;
        let mut guarda = self.conexao.lock().await;

        for tentativa in 0..2 {
            if guarda.as_ref().is_none_or(|c| c.is_closed()) {
                *guarda = Some(Self::conectar(cfg).await?);
            }
            let conn = guarda.as_ref().expect("conexao aberta acima");

            match buscar_tudo(conn, &sql, &params).await {
                Ok(linhas) => return Ok(linhas),
                Err(e) => {
                    // Erro de SQL com a sessao viva (ORA-00942 etc.) volta direto;
                    // sessao morta e' descartada e a consulta repetida uma vez.
                    if conn.ping().await.is_ok() || tentativa == 1 {
                        return Err(texto_erro(&e));
                    }
                    if let Some(morta) = guarda.take() {
                        morta.mark_closed();
                    }
                }
            }
        }
        unreachable!("o laco sempre retorna na segunda tentativa")
    }

    pub async fn desconectar(&self) {
        if let Some(conn) = self.conexao.lock().await.take() {
            let _ = conn.close().await;
        }
    }
}

/// Consulta avulsa numa conexao ja aberta (diagnostico do "Testar conexao").
pub async fn consultar_em(
    conn: &Connection,
    sql_nomeado: &str,
    binds: &[(&str, Value)],
) -> Result<Vec<Row>, String> {
    let (sql, params) = sql::preparar(sql_nomeado, binds)?;
    buscar_tudo(conn, &sql, &params).await.map_err(|e| texto_erro(&e))
}

/// O texto do ORA- ja traz o codigo; o Display do driver repetiria.
fn texto_erro(e: &oracle_rs::Error) -> String {
    match e {
        oracle_rs::Error::OracleError { message, .. } if message.starts_with("ORA-") => message.clone(),
        outro => outro.to_string(),
    }
}

async fn buscar_tudo(conn: &Connection, sql: &str, params: &[Value]) -> oracle_rs::Result<Vec<Row>> {
    let mut resultado = conn.query(sql, params).await?;
    let colunas = resultado.columns.clone();
    let mut linhas = std::mem::take(&mut resultado.rows);
    while resultado.has_more_rows {
        resultado = conn
            .fetch_more(resultado.cursor_id, &colunas, TAMANHO_FETCH)
            .await?;
        linhas.append(&mut resultado.rows);
    }
    Ok(linhas)
}

/// Valor da coluna como texto (NULL vira vazio; NUMBER sai sem ".0").
pub fn texto(linha: &Row, coluna: usize) -> String {
    match linha.get(coluna) {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.trim_end().to_string(),
        Some(v) => match v.as_i64() {
            Some(n) if v.as_f64() == Some(n as f64) => n.to_string(),
            _ => v.to_string(),
        },
    }
}

pub fn inteiro(linha: &Row, coluna: usize) -> Option<i64> {
    let v = linha.get(coluna)?;
    v.as_i64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
}
