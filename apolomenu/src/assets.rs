//! Tela embutida no executavel e servida pelo protocolo apolo:// - nada de
//! pasta web solta no terminal (mesma ideia do ApoloWebAssets.rc do PDV).

use std::borrow::Cow;

use wry::http::{header::CONTENT_TYPE, Request, Response};

const ARQUIVOS: &[(&str, &str, &[u8])] = &[
    ("index.html", "text/html; charset=utf-8", include_bytes!("../web/index.html")),
    ("css/menu.css", "text/css; charset=utf-8", include_bytes!("../web/css/menu.css")),
    ("js/bridge.js", "text/javascript; charset=utf-8", include_bytes!("../web/js/bridge.js")),
    ("js/app.js", "text/javascript; charset=utf-8", include_bytes!("../web/js/app.js")),
];

pub fn responder(req: Request<Vec<u8>>) -> Response<Cow<'static, [u8]>> {
    let caminho = req.uri().path().trim_start_matches('/');
    let caminho = if caminho.is_empty() { "index.html" } else { caminho };

    match ARQUIVOS.iter().find(|(nome, _, _)| *nome == caminho) {
        Some((_, tipo, corpo)) => Response::builder()
            .header(CONTENT_TYPE, *tipo)
            .body(Cow::Borrowed(*corpo))
            .expect("resposta valida"),
        None => Response::builder()
            .status(404)
            .header(CONTENT_TYPE, "text/plain")
            .body(Cow::Borrowed(&b"nao encontrado"[..]))
            .expect("resposta valida"),
    }
}
