# Roteiro de narração — Instalação do ApoloWeb (suporte técnico)

Um bloco por cena, na MESMA ordem das cenas do video.html. Só o texto abaixo do título é falado.
Siglas e números escritos como se falam (veja a tabela de pronúncia no SKILL.md). 15 a 45 palavras por cena.

Público: suporte técnico (uso interno). Serial de disco, IPs e números das cenas são ilustrativos.
A regra da senha de administrador não aparece no vídeo de propósito.

---

## Cena 1 — Instalar um caixa ApoloWeb
Este vídeo é para o suporte. Vamos instalar o ApoloWeb, a frente de caixa do Colosso, numa máquina nova, em cinco etapas: preparar o Windows, copiar os arquivos, ligar ao banco, configurar os periféricos e testar.

## Cena 2 — Pré-requisitos da máquina
O ApoloWeb é um programa de trinta e dois bits que desenha a tela com o Web View dois, o motor do Edge. Confira se o Runtime do Web View dois está instalado, na versão oitenta e nove ou superior, e se a máquina alcança o servidor Oracle pela rede.

## Cena 3 — A pasta C:\Apolo
Tudo fica na pasta Apolo, no disco cê. Copie o executável, a Web View dois Loader de trinta e dois bits, versão um ponto zero, as bibliotecas do Open SSL e do lib XML, que assinam a nota, e a pasta Schemas. Sem elas, a nota não sai.

## Cena 4 — O primeiro boot
Na primeira execução, o próprio executável extrai a pasta web, cria o banco local ésse quê lite, lê o número de série do disco cê e o arquivo apoloweb ponto ini, e conecta ao Oracle em modo direto. Não precisa instalar o client da Oracle.

## Cena 5 — apoloweb.ini: a conexão
A seção oracle do ini guarda servidor, porta, usuário e senha. Se o caixa não conecta e ainda não tem os dados guardados localmente, abre a janela de configuração: teste a conexão, informe a próxima ene éfe cê é e salve com a senha de administrador do suporte.

## Cena 6 — Cadastrar o caixa
O caixa é reconhecido pelo número de série do disco. Na primeira vez, a tela avisa que o caixa não está cadastrado e mostra o serial. Cadastre esse serial na tabela eme ésse apolo caixa, com a filial, o número do caixa e a série da ene éfe cê é.

## Cena 7 — Os dados fiscais vêm da filial
Certificado, cê ésse cê, ambiente e logotipo vêm do cadastro da filial no Oracle. O certificado é gravado como arquivo pê éfe xis na pasta Apolo: não precisa instalá-lo no Windows. Tudo fica em cache, para o caixa abrir mesmo sem servidor.

## Cena 8 — Impressora do cupom
Na seção impressão, o modo ésse cê pós imprime direto na térmica: escolha o modelo, a porta e as colunas, quarenta e oito para bobina de oitenta milímetros e trinta e duas para cinquenta e oito. Confira em éfe dez, impressora, imprimir teste.

## Cena 9 — TEF
O tef tem três modos. Http fala com a Scope á pê í pela url. Arquivo troca pedidos pelas pastas do Tef Dial. Cli Sitef chama a dll da Fiserv direto, com IP, loja e terminal. Ligue o habilitado e confira em éfe dez, tef.

## Cena 10 — Teste de aceite
Antes de liberar o caixa, faça o teste completo: login, sincronização de produtos, abertura com troco, uma venda de teste e a nota autorizada. Confira também se a venda subiu para o servidor.

## Cena 11 — Quando dá errado
Tela branca é quase sempre o Web View dois ou a pasta web: rode o diagnóstico do cliente. Falha ao abrir o banco local indica outra cópia aberta. Para sincronização e tef, os logs do dia estão em cê dois pontos barra Apolo barra logs.

## Cena 12 — Atualizar é trocar o executável
Para atualizar, feche o caixa, guarde uma cópia do executável atual e troque só ele: a tela web já vem dentro do executável. O passo a passo completo, com os comandos, está no help de instalação.
