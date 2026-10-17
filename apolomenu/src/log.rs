//! Log simples em logs\apolomenu.log ao lado do ini. Nunca recebe senha.

use std::io::Write;
use std::path::PathBuf;
use std::sync::OnceLock;

static ARQUIVO: OnceLock<PathBuf> = OnceLock::new();

pub fn iniciar(pasta_ini: Option<&std::path::Path>) {
    let pasta = pasta_ini.unwrap_or(std::path::Path::new(".")).join("logs");
    let _ = std::fs::create_dir_all(&pasta);
    let _ = ARQUIVO.set(pasta.join("apolomenu.log"));
}

/// Pasta dos logs (para arquivos de diagnostico ao lado do apolomenu.log)
pub fn pasta() -> Option<PathBuf> {
    ARQUIVO.get().and_then(|a| a.parent().map(|p| p.to_path_buf()))
}

pub fn registrar(msg: impl AsRef<str>) {
    let agora = chrono::Local::now().format("%Y-%m-%d %H:%M:%S");
    let linha = format!("{agora} {}\r\n", msg.as_ref());
    if cfg!(debug_assertions) {
        eprint!("{linha}");
    }
    if let Some(caminho) = ARQUIVO.get() {
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(caminho) {
            let _ = f.write_all(linha.as_bytes());
        }
    }
}
