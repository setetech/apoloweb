---
titulo: "Frente de Caixa (PDV)"
rotina: "ApoloWeb"
modulo: "ApoloWeb"
sistema: "Colosso ERP"
tipo: "manual do usuário (aba Ajuda / F1)"
idioma: "pt-BR"
fonte: "ApoloWeb/web/index.html (aba Ajuda)"
gerado_em: "2026-10-16"
---

<!-- Gerado pela skill colosso-ajuda-rag a partir da aba Ajuda da ApoloWeb. Não edite à mão: altere a ajuda da rotina e gere de novo. -->
# Frente de Caixa (PDV) — ApoloWeb

## Visão geral da tela

O ApoloWeb é a frente de caixa (PDV) da loja: registra os itens, recebe o pagamento e emite a NFC-e. Tudo se faz pelo teclado: o leitor de código de barras e as teclas `F1` a `F12` resolvem a venda inteira, sem precisar do mouse.

| Parte da tela | O que mostra |
| --- | --- |
| Cabeçalho (esquerda) | Logotipo da loja, versão do programa e número do caixa. Um duplo clique no logotipo abre esta ajuda. |
| Cabeçalho (centro) | Situação da conexão (**ONLINE** ou **CONTINGENCIA**), cupom em andamento e o consumidor identificado. |
| Cabeçalho (direita) | Operador logado, relógio e o botão 🎨 para trocar o tema de cores. |
| Itens do Cupom | Os itens da venda. Item cancelado fica riscado; a linha marcada é o item selecionado. |
| Resumo | Subtotal, desconto, acréscimo e o TOTAL da venda. No pagamento aparecem também Total Pago, Restante e Troco. |
| Código de Barras / Produto | Campo onde se lê ou digita o produto, e o campo **Vend** para a matrícula do vendedor. |
| Barra de funções | Os atalhos F1 a F12. Clicar no botão faz o mesmo que a tecla. |

## O dia do caixa, passo a passo

1. **Login**: informe a matrícula e a senha. O PDV sincroniza os dados com o servidor antes de liberar a tela.
2. **Abertura do caixa**: se o caixa estiver fechado, informe o valor do suprimento inicial (o troco que está na gaveta) e tecle `Enter`.
3. **Vendas**: leia o primeiro produto e a venda começa sozinha. Feche cada venda com `F4` (pagamento).
4. **Durante o dia**: retire dinheiro com `F8` (sangria) e reforce o troco com `F9` (suprimento).
5. **Fechamento**: com o caixa livre, tecle `F11`, confira o resumo e confirme.

> **Dica:** Se faltar energia ou o PDV for fechado no meio de uma venda, basta entrar de novo: a venda em andamento é restaurada com os itens e pagamentos já registrados.

## Registrar itens

- Leia o código de barras ou digite o código do produto e tecle `Enter`.
- Não sabe o código? Tecle `F1`, procure pelo nome, código ou código de barras, escolha com as setas e tecle `Enter`.
- **Quantidade**: digite a quantidade, o asterisco e depois o produto. Exemplo: `3*` e em seguida o código lança 3 unidades. A quantidade pendente aparece em **Qtd** embaixo do campo; `*` sozinho volta para 1.
- **Quantidade fracionada** (ex.: `0,750*`) só é aceita para produtos vendidos em KG ou metro.
- **Etiqueta de balança** (13 dígitos começando com 2): o PDV lê o preço da etiqueta e calcula o peso sozinho.
- **Produto de peso variável** lido sem etiqueta: o PDV pede o peso.
- **Vendedor**: informe a matrícula no campo **Vend** antes de ler os itens; o nome aparece ao lado e vale para os itens seguintes.
- Clique numa linha da grade para selecionar o item: ele passa a ser o sugerido no desconto por item e no cancelamento de item.

## Teclas de função

| Tecla | Função | Quando usar |
| --- | --- | --- |
| `F1` | Produto | Buscar produto pelo nome, código ou código de barras. |
| `F2` | Cliente | Identificar o consumidor (CPF/CNPJ na nota) ou escolher um cliente cadastrado. |
| `F3` | Desconto | Desconto em valor sobre o total da venda. |
| `Shift`+`F3` | Desc. Item | Desconto em um item, em R$ ou em %. |
| `F4` | Pagamento | Abrir a tela de pagamento da venda em andamento. |
| `F5` | Carga Geral | Baixar de novo todos os dados do servidor (produtos, preços, clientes). Use com o caixa livre. |
| `F6` | Cancelar Item | Cancelar um item da venda pelo número dele. |
| `F7` | Pré-Venda | Ainda em desenvolvimento. |
| `F8` | Sangria | Retirar dinheiro do caixa. |
| `F9` | Suprimento | Colocar dinheiro (troco) no caixa. |
| `F10` | NFCe | Documentos fiscais e configurações do caixa (TEF, impressora, logotipo). |
| `F11` | Fechar Cx | Fechamento do caixa no fim do expediente. |
| `F12` | Cancelar Venda | Cancelar a venda inteira. |
| `Esc` | Voltar | Fecha a janela aberta e devolve o cursor ao campo do código de barras. |
| `Alt`+`F4` | Sair | Encerrar o PDV. |

## Descontos e cancelamentos

- **Desconto na venda** (`F3`): informe o valor em reais. Vale durante o registro e no pagamento.
- **Desconto no item** (`Shift`+`F3`): confirme o número do item (já vem o selecionado) e digite o desconto em reais (`2,50`) ou em percentual (`10%`). Zero remove o desconto do item. Só durante o registro.
- **Cancelar item** (`F6`): informe o número do item. Ele continua na grade, riscado, e sai do total.
- **Cancelar venda** (`F12`): confirma e cancela a venda inteira.

> **Atenção:** Desconto, cancelamento, sangria e fechamento podem exigir **autorização**. Quando o operador não tem a permissão, o PDV pede a matrícula e a senha de um autorizador (supervisor) e só segue depois que ela for aceita.

> **Dica:** `F12` com o caixa livre também serve para destravar o caixa que ficou marcado como "venda em andamento" depois de uma queda de energia.

## CPF/CNPJ na nota e cliente

Tecle `F2` com a venda já iniciada (pelo menos um item lido). Digite o CPF ou CNPJ e clique em **Identificar**:

- Se o cliente é cadastrado, o nome aparece no cabeçalho do PDV.
- Se não é, o documento é gravado na venda e a nota sai com o consumidor padrão.

Para escolher um cliente cadastrado, use a busca da mesma tela, pelo nome, CPF/CNPJ ou código.

## Pagamento

Tecle `F4`. Escolha a forma de pagamento, informe o valor e registre com `Enter` ou `F8`. Dá para combinar várias formas na mesma venda: cada pagamento entra na lista e o **Restante** diminui. Com tudo pago, finalize com `F5`. `Esc` volta para o registro de itens sem perder o que já foi pago.

| Tecla | Forma | Observações |
| --- | --- | --- |
| `F1` | Dinheiro | Informe o valor recebido; o troco aparece no resumo. |
| `F2` | Cheque | Banco, agência, conta e número do cheque são obrigatórios. |
| `F3` | Cartão ou TEF | Com TEF habilitado, o pinpad é acionado. Sem TEF, digite os dados do comprovante (tipo, bandeira, parcelas, NSU, autorização). |
| `F4` | PIX | Mostra o QR Code para o cliente pagar (quando o TEF está habilitado, o PIX vai pelo TEF). |
| `F5` | Cobrança | Na aba, escolha o meio de pagamento, o plano e os vencimentos das parcelas. Fora da aba, a tecla finaliza a venda. |
| `F6` | POS | Cartão passado numa maquininha que não é integrada ao PDV. |

### Atalhos do TEF

Com TEF habilitado, `F9` (crédito), `F10` (débito) e `F11` (PIX) já trazem o valor restante: confirme com `Enter` e o pinpad é acionado na hora. O atalho é sempre à vista; para parcelar, use a aba (`F3`). Quando o TEF aprova e não sobra nada a pagar, a venda é finalizada sozinha. `Esc` pede o cancelamento da transação em curso.

### PIX com QR Code

- Com a cobrança PIX dinâmica configurada, a confirmação é automática: a tela fecha sozinha quando o banco confirma.
- Sem ela, o QR é o da chave da loja e o operador confirma com `Enter`.
- `F7` imprime o QR Code para o cliente.

> **Atenção:** No PIX com confirmação manual, só tecle `Enter` depois de ver o pagamento recebido. Confirmar antes registra uma venda que pode não ter sido paga.

Ao finalizar, a NFC-e é gerada e impressa, e o caixa volta a ficar livre.

## Sangria, suprimento e fechamento

- **Sangria** (`F8`): informe o valor retirado e o motivo.
- **Suprimento** (`F9`): informe o valor colocado no caixa.
- Os dois mostram o comprovante antes de imprimir; saem 2 vias, uma para o caixa e outra para o cofre.
- **Fechamento** (`F11`): só com o caixa livre (sem venda aberta). Mostra a quantidade e o total de vendas, as sangrias, os suprimentos e o saldo em dinheiro. Confira e clique em **Confirmar Fechamento**.

## NFC-e e configurações do caixa (F10)

| Aba | Para que serve |
| --- | --- |
| Pendentes | Notas que ainda não foram autorizadas pela SEFAZ. **Retransmitir Pendentes** envia de novo; as rejeitadas podem ser marcadas para **Regerar** ou **Descartar**. |
| Notas do Dia | NFC-e autorizadas hoje. **Reimprimir** tira a 2ª via a qualquer momento. **Cancelar** só é aceito pela SEFAZ até 30 minutos depois da autorização, e estorna também o cartão da venda. Venda fechada sem nota aparece aqui com o botão **Emitir NFCe**. |
| Contingência | Quando a SEFAZ está fora do ar: escolha o tipo, escreva a justificativa e entre em contingência. Ao normalizar, saia da contingência e retransmita as pendentes. |
| Logotipo | Imagem impressa no topo do DANFCe e mostrada no cabeçalho do PDV. Aqui também se liga o protetor de tela, que mostra o logotipo com o caixa parado. |
| TEF | Configuração da integração com o pinpad, menu administrativo do gerenciador e as transações do dia, com **Estornar** e 2ª via do comprovante. |
| Impressora | Impressora do cupom e o modo de impressão; **Imprimir Teste** confere a configuração. |

> **Atenção:** Não use o menu administrativo do TEF para vender nem para estornar: a transação feita lá não passa pelo caixa e não gera cupom. Para desfazer um cartão, use **Estornar** na linha da transação, na aba TEF.

## Dúvidas e problemas comuns

### O cabeçalho mostra CONTINGENCIA. E agora?

O PDV continua vendendo normalmente e as notas ficam guardadas. Quando a comunicação voltar, abra `F10` › **Contingência**, saia da contingência e retransmita as pendentes.

### Apareceu "Venda fechada sem NFCe".

A venda foi gravada, mas a nota não saiu. Abra `F10` › **Notas do Dia** e use **Emitir NFCe** na linha do cupom.

### O TEF não respondeu.

Confira no pinpad e no gerenciador se a transação foi aprovada antes de tentar de novo. Em `F10` › **TEF**, as transações do dia mostram o que foi aprovado.

### "Produto não permite quantidade fracionada".

Quantidade com vírgula só vale para produto vendido em KG ou metro. Lance a quantidade inteira.

### O preço ou o produto está desatualizado no caixa.

Com o caixa livre, tecle `F5` (Carga Geral) para baixar de novo todos os dados do servidor.

### O PDV diz que já existe uma venda em andamento, mas a tela está vazia.

Tecle `F12` com o caixa livre. O PDV restaura o estado do caixa, pedindo autorização se encontrar um cupom aberto.

### Como troco as cores da tela?

Clique no botão 🎨 no canto direito do cabeçalho e escolha o tema. A escolha fica gravada neste caixa.
