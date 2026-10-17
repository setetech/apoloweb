//! Binds nomeados -> posicionais.
//!
//! O oracle-rs so recebe binds por posicao. As consultas do ini usam nomes
//! (:matricula, :codrotina...) para quem as ajusta nao depender da ordem; aqui
//! cada ocorrencia vira :1, :2... e recebe o seu valor, o que tambem resolve o
//! mesmo bind usado duas vezes (ex.: :login no SQL de login padrao).

use oracle_rs::Value;

pub fn preparar(sql: &str, binds: &[(&str, Value)]) -> Result<(String, Vec<Value>), String> {
    let chars: Vec<char> = sql.chars().collect();
    let mut saida = String::with_capacity(sql.len());
    let mut valores = Vec::new();
    let mut i = 0;

    while i < chars.len() {
        let c = chars[i];
        let prox = chars.get(i + 1).copied();

        // Literal: copia ate o apostrofo de fechamento ('' e' escape e cai aqui
        // como dois literais vazios seguidos - o resultado e' o mesmo)
        if c == '\'' {
            let fim = chars[i + 1..]
                .iter()
                .position(|&x| x == '\'')
                .map(|p| i + 1 + p)
                .unwrap_or(chars.len() - 1);
            saida.extend(&chars[i..=fim]);
            i = fim + 1;
            continue;
        }
        if c == '-' && prox == Some('-') {
            let fim = chars[i..]
                .iter()
                .position(|&x| x == '\n')
                .map(|p| i + p)
                .unwrap_or(chars.len());
            saida.extend(&chars[i..fim]);
            i = fim;
            continue;
        }
        if c == '/' && prox == Some('*') {
            let fim = (i + 2..chars.len().saturating_sub(1))
                .find(|&j| chars[j] == '*' && chars[j + 1] == '/')
                .map(|j| j + 2)
                .unwrap_or(chars.len());
            saida.extend(&chars[i..fim]);
            i = fim;
            continue;
        }
        if c == ':' && prox.is_some_and(|p| p.is_ascii_alphabetic() || p == '_') {
            let inicio = i + 1;
            let fim = chars[inicio..]
                .iter()
                .position(|&x| !(x.is_ascii_alphanumeric() || x == '_'))
                .map(|p| inicio + p)
                .unwrap_or(chars.len());
            let nome: String = chars[inicio..fim].iter().collect::<String>().to_lowercase();
            let valor = binds
                .iter()
                .find(|(n, _)| n.eq_ignore_ascii_case(&nome))
                .map(|(_, v)| v.clone())
                .ok_or_else(|| format!("Bind :{nome} desconhecido no SQL do apolomenu.ini"))?;
            valores.push(valor);
            saida.push_str(&format!(":{}", valores.len()));
            i = fim;
            continue;
        }

        saida.push(c);
        i += 1;
    }

    Ok((saida, valores))
}

#[cfg(test)]
mod testes {
    use super::*;

    fn txt(v: &Value) -> String {
        v.to_string()
    }

    #[test]
    fn repete_bind_e_respeita_ordem() {
        let (sql, vals) = preparar(
            "SELECT 1 FROM t WHERE a = :login OR b = UPPER(:LOGIN) AND c = :senha",
            &[("senha", "x".into()), ("login", "joao".into())],
        )
        .unwrap();
        assert_eq!(sql, "SELECT 1 FROM t WHERE a = :1 OR b = UPPER(:2) AND c = :3");
        assert_eq!(vals.iter().map(txt).collect::<Vec<_>>(), ["joao", "joao", "x"]);
    }

    #[test]
    fn ignora_literais_e_comentarios() {
        let (sql, vals) = preparar(
            "SELECT TO_CHAR(d, 'HH24:MI') -- :nada\n FROM t /* :outro */ WHERE m = :matricula",
            &[("matricula", 7i64.into())],
        )
        .unwrap();
        assert_eq!(
            sql,
            "SELECT TO_CHAR(d, 'HH24:MI') -- :nada\n FROM t /* :outro */ WHERE m = :1"
        );
        assert_eq!(vals.len(), 1);
    }

    #[test]
    fn bind_desconhecido_e_erro() {
        assert!(preparar("SELECT :x FROM dual", &[]).is_err());
    }

    #[test]
    fn atribuicao_plsql_nao_e_bind() {
        let (sql, vals) = preparar("BEGIN v := :a; END;", &[("a", 1i64.into())]).unwrap();
        assert_eq!(sql, "BEGIN v := :1; END;");
        assert_eq!(vals.len(), 1);
    }
}
