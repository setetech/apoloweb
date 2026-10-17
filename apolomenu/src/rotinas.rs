//! Rotinas liberadas ao usuario e chamada do executavel.

use std::path::PathBuf;
use std::process::Command;

use serde::Serialize;

use crate::config::{expandir, RotinasCfg};
use crate::sessao::Usuario;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Rotina {
    pub codrotina: i64,
    pub nome: String,
    pub modulo: String,
    /// Vazio = usa [rotinas] executavel do ini
    #[serde(skip_serializing_if = "String::is_empty")]
    pub executavel: String,
}

fn valores(rotina: &Rotina, usuario: &Usuario) -> Vec<(&'static str, String)> {
    vec![
        ("codrotina", rotina.codrotina.to_string()),
        ("matricula", usuario.matricula.to_string()),
        ("usuario", usuario.usuario.clone()),
    ]
}

pub fn caminho_executavel(cfg: &RotinasCfg, rotina: &Rotina, usuario: &Usuario) -> PathBuf {
    let modelo = if rotina.executavel.trim().is_empty() {
        cfg.executavel.as_str()
    } else {
        rotina.executavel.trim()
    };
    let nome = PathBuf::from(expandir(modelo, &valores(rotina, usuario)));
    if nome.is_absolute() {
        nome
    } else {
        cfg.pasta.join(nome)
    }
}

/// Abre a rotina como processo independente (o menu continua aberto, como no
/// menu.exe). A rotina recebe os parametros do ini e, nas variaveis de
/// ambiente APOLO_*, quem chamou - sem senha nenhuma.
pub fn executar(
    cfg: &RotinasCfg,
    arquivo_ini: &std::path::Path,
    rotina: &Rotina,
    usuario: &Usuario,
) -> Result<u32, String> {
    let exe = caminho_executavel(cfg, rotina, usuario);
    if !exe.is_file() {
        return Err(format!(
            "Executavel da rotina {} nao encontrado: {}",
            rotina.codrotina,
            exe.display()
        ));
    }

    let args: Vec<String> = expandir(&cfg.parametros, &valores(rotina, usuario))
        .split_whitespace()
        .map(str::to_string)
        .collect();

    let mut cmd = Command::new(&exe);
    cmd.args(&args)
        .env("APOLO_MATRICULA", usuario.matricula.to_string())
        .env("APOLO_USUARIO", &usuario.usuario)
        .env("APOLO_NOME", &usuario.nome)
        .env("APOLO_ROTINA", rotina.codrotina.to_string())
        .env("APOLO_INI", arquivo_ini);
    if let Some(pasta) = exe.parent() {
        cmd.current_dir(pasta);
    }

    cmd.spawn()
        .map(|filho| filho.id())
        .map_err(|e| format!("Falha ao abrir {}: {e}", exe.display()))
}

#[cfg(test)]
mod testes {
    use super::*;

    fn usuario() -> Usuario {
        Usuario { matricula: 15, nome: "MARIA".into(), usuario: "MARIA".into() }
    }

    fn cfg() -> RotinasCfg {
        RotinasCfg {
            pasta: PathBuf::from("rotinas"),
            executavel: "ROT{codrotina}.exe".into(),
            parametros: "{matricula}".into(),
        }
    }

    #[test]
    fn usa_modelo_do_ini_ou_o_da_rotina() {
        let mut r = Rotina { codrotina: 6030, nome: "Acerto".into(), modulo: String::new(), executavel: String::new() };
        assert_eq!(caminho_executavel(&cfg(), &r, &usuario()), PathBuf::from("rotinas").join("ROT6030.exe"));
        r.executavel = "acerto\\Acerto{codrotina}.exe".into();
        assert_eq!(
            caminho_executavel(&cfg(), &r, &usuario()),
            PathBuf::from("rotinas").join("acerto\\Acerto6030.exe")
        );
    }

    #[test]
    fn executavel_inexistente_e_erro_legivel() {
        let r = Rotina { codrotina: 1, nome: "x".into(), modulo: String::new(), executavel: String::new() };
        let erro = executar(&cfg(), std::path::Path::new("a.ini"), &r, &usuario()).unwrap_err();
        assert!(erro.contains("nao encontrado"), "{erro}");
    }
}
