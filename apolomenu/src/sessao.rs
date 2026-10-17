use serde::Serialize;

use crate::rotinas::Rotina;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Usuario {
    pub matricula: i64,
    pub nome: String,
    pub usuario: String,
}

/// Usuario logado e as rotinas que o Oracle liberou para ele na ultima
/// listagem (a liberacao e' conferida de novo no banco a cada chamada).
#[derive(Debug, Clone)]
pub struct Sessao {
    pub usuario: Usuario,
    pub rotinas: Vec<Rotina>,
}
