// Sem console atras da janela no executavel de producao
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Apolo Menu: substituto em Rust do menu.exe.
//!
//! - Oracle pelo protocolo TNS em Rust puro (oracle-rs): sem Oracle Client
//! - Login e rotinas liberadas lidos do Oracle; a rotina e' conferida de novo
//!   no banco antes de abrir o executavel
//! - Tela em HTML/JS dentro de um WebView (WebView2 no Windows), falando com o
//!   Rust pela ponte window.ipc.postMessage -> evaluate_script

mod assets;
mod bridge;
mod config;
mod db;
mod log;
mod rotinas;
mod sessao;
mod sql;

use std::sync::Arc;

use serde_json::Value;
use tao::dpi::LogicalSize;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tao::window::WindowBuilder;
use wry::http::Request;
use wry::WebViewBuilder;

use crate::bridge::App;
use crate::config::Config;

enum Evento {
    /// Resposta pronta de uma acao: devolve ao callback do JS
    Resposta { callback: String, json: String },
    Sair,
}

/// Mensagem do JS: {action, data, callbackId}. data pode vir como objeto ou
/// como texto JSON (formato do bridge.js do ApoloWeb).
fn ler_mensagem(corpo: &str) -> Option<(String, Value, String)> {
    let msg: Value = serde_json::from_str(corpo).ok()?;
    let acao = msg.get("action")?.as_str()?.to_string();
    let callback = msg.get("callbackId")?.as_str()?.to_string();
    let dados = match msg.get("data") {
        Some(Value::String(s)) => serde_json::from_str(s).unwrap_or(Value::Null),
        Some(v) => v.clone(),
        None => Value::Null,
    };
    Some((acao, dados, callback))
}

/// So' a tela embutida navega; qualquer outra URL e' bloqueada (a ponte abre
/// executaveis, entao nenhuma pagina de fora pode chegar ate ela).
fn navegacao_permitida(url: &str) -> bool {
    ["apolo://localhost/", "http://apolo.localhost/", "https://apolo.localhost/"]
        .iter()
        .any(|origem| url.starts_with(origem))
        || url == "about:blank"
}

fn main() {
    let cfg = Config::carregar();
    log::iniciar(cfg.arquivo.parent());
    log::registrar(format!(
        "Apolo Menu {} iniciado (ini: {})",
        env!("CARGO_PKG_VERSION"),
        cfg.arquivo.display()
    ));

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime tokio");
    let app = Arc::new(App::new(cfg));

    let event_loop = EventLoopBuilder::<Evento>::with_user_event().build();
    let proxy = event_loop.create_proxy();

    let window = WindowBuilder::new()
        .with_title("Apolo - Menu")
        .with_inner_size(LogicalSize::new(1100.0, 720.0))
        .with_min_inner_size(LogicalSize::new(720.0, 480.0))
        .build(&event_loop)
        .expect("janela");

    let handle = runtime.handle().clone();
    let app_ipc = Arc::clone(&app);
    let builder = WebViewBuilder::new()
        .with_custom_protocol("apolo".into(), |_id, req| assets::responder(req))
        .with_navigation_handler(|url| navegacao_permitida(&url))
        .with_devtools(cfg!(debug_assertions))
        .with_ipc_handler(move |req: Request<String>| {
            let Some((acao, dados, callback)) = ler_mensagem(req.body()) else {
                log::registrar("Mensagem invalida recebida da tela");
                return;
            };
            if acao == "fecharApp" {
                let _ = proxy.send_event(Evento::Sair);
                return;
            }
            // Oracle fora da thread da janela: a tela nao congela esperando o banco
            let app = Arc::clone(&app_ipc);
            let proxy = proxy.clone();
            handle.spawn(async move {
                let json = app.processar(&acao, dados).await;
                let _ = proxy.send_event(Evento::Resposta { callback, json });
            });
        })
        .with_url("apolo://localhost/index.html");

    #[cfg(any(target_os = "windows", target_os = "macos"))]
    let webview = builder.build(&window).expect("webview");
    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    let webview = {
        use tao::platform::unix::WindowExtUnix;
        use wry::WebViewBuilderExtUnix;
        builder
            .build_gtk(window.default_vbox().expect("vbox gtk"))
            .expect("webview")
    };

    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
        // O runtime precisa viver enquanto a janela existir
        let _ = &runtime;

        match event {
            Event::UserEvent(Evento::Resposta { callback, json }) => {
                let id = serde_json::to_string(&callback).unwrap_or_default();
                if let Err(e) = webview.evaluate_script(&format!("window.__apoloResolve({id}, {json})")) {
                    log::registrar(format!("Falha ao responder a tela: {e}"));
                }
            }
            Event::UserEvent(Evento::Sair)
            | Event::WindowEvent { event: WindowEvent::CloseRequested, .. } => {
                log::registrar("Apolo Menu encerrado");
                *control_flow = ControlFlow::Exit;
            }
            _ => {}
        }
    });
}

#[cfg(test)]
mod testes {
    use super::*;

    #[test]
    fn mensagem_com_data_objeto_ou_texto() {
        let (a, d, c) =
            ler_mensagem(r#"{"action":"login","data":{"login":"x"},"callbackId":"cb_1"}"#).unwrap();
        assert_eq!((a.as_str(), c.as_str()), ("login", "cb_1"));
        assert_eq!(d["login"], "x");

        let (_, d, _) =
            ler_mensagem(r#"{"action":"login","data":"{\"login\":\"y\"}","callbackId":"cb_2"}"#).unwrap();
        assert_eq!(d["login"], "y");

        assert!(ler_mensagem("lixo").is_none());
    }

    #[test]
    fn so_navega_na_tela_embutida() {
        assert!(navegacao_permitida("apolo://localhost/index.html"));
        assert!(navegacao_permitida("http://apolo.localhost/index.html"));
        assert!(!navegacao_permitida("https://exemplo.com"));
        assert!(!navegacao_permitida("http://apolo.localhost.exemplo.com"));
    }
}
