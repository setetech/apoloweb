# oracle-rs 0.1.7 (copia corrigida para o apolomenu)

Copia do crate publicado `oracle-rs` 0.1.7 (MIT/Apache-2.0, ver LICENSE-*),
usada via `[patch.crates-io]` no `Cargo.toml` do apolomenu. Alteracoes, todas
em `src/connection.rs` e marcadas com "apolomenu":

1. `send_marker`: o pacote de reset que o cliente manda depois de um erro
   escrevia o tamanho em 2 bytes mesmo com large SDU (Oracle 12c+). O
   servidor lia um tamanho errado e derrubava a sessao, e todo ORA- virava
   "Oracle closed the connection without providing error details".
2. `read_error_message`: o texto do ORA- e' localizado pelo proprio "ORA-".
   O original nao pulava os campos que o servidor 20c+ manda antes do texto
   e a mensagem saia vazia.

Para atualizar o driver: trocar esta pasta pela versao nova do crate e
conferir se as duas correcoes ainda sao necessarias (teste
`fluxo_completo_no_oracle` + consulta com erro proposital).
