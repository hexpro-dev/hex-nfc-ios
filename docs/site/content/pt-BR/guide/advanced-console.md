---
title: Enviar um comando bruto a uma etiqueta
description: Identifique um chip, execute um preajuste de comando e leia o que a etiqueta devolve, no Console avançado do Hex NFC.
audience: user
pageKind: howto
navTitle: Console avançado
tags:
  - chips
---

O Console avançado do Hex NFC envia bytes do iPhone direto para uma etiqueta.
Ele exibe o comando que saiu, a resposta que chegou e o horário de cada um.
Abra-o quando quiser ver os próprios quadros em vez de um resumo deles.

Antes de começar, tenha a etiqueta em mãos e a folha de dados do chip aberta.
A folha de dados é o documento do próprio fabricante sobre aquele chip. Ela é
publicada no site do fabricante com o nome do chip, e o passo de identificação
abaixo informa esse nome. Nenhuma página deste manual reproduz uma folha de
dados, e o console envia o que você digitar, quer você a tenha lido, quer não.

O console ocupa uma única tela, e todos os controles que esta página cita
estão nela. No topo ficam o indicador de status, com **Identificar** ao lado,
e o botão de ativação **Pular a identificação**. Depois vêm o campo
**Comando**, com o botão **Executar** ao lado, e o seletor entre **Esta
execução** e **Todo o tráfego NFC**. Em seguida vem a área de saída e, no pé
da tela, **Preajustes**, com **Buscar** acima das linhas de preajustes.

## Identificar o chip

:::::steps
::::step[Abrir o Hex NFC]
Abra o Hex NFC. A tela inicial do Hex NFC aparece.
::::

::::step[Abrir o console]
Na tela inicial do Hex NFC, toque em **Avançado**, o último dos quatro blocos.
A segunda linha do bloco diz “Console de comandos brutos”. O console se abre, e a área
de saída vazia mostra “Console ocioso. Toque em um preajuste à esquerda, ou
digite uma sequência e execute.” A lista de preajustes fica no pé da tela. Ela
não fica à esquerda.

:::figure[O console se abre com o indicador de status mostrando “Ocioso”, a área de saída vazia e **Preajustes** no pé da tela.]
![O Console avançado logo depois de abrir. O indicador de status no canto superior esquerdo mostra “Ocioso”, com Identificar à direita e o botão de ativação Pular a identificação abaixo. O campo Comando mostra a sequência de exemplo, a área de saída contém só a dica de console ocioso, e a lista de preajustes começa com Ler 16 bytes, Gravar 4 bytes e Colocar em HALT.](../../../assets/pt-BR/advanced-console--idle.png)
:::
::::

::::step[Iniciar a leitura de identificação]
Toque em **Identificar**, a cápsula à direita do indicador de status. A área
de saída acrescenta “Identificando a etiqueta…”, e o painel do iOS
aparece com “Aproxime a etiqueta para identificá-la.”
::::

::::step[Encostar a etiqueta no iPhone]
Encoste a parte superior do iPhone na etiqueta, bem rente, e mantenha-o
parado. A área de saída mostra o nome do chip e o UID da etiqueta, e o nome do
chip aparece ao lado de **Preajustes**. A linha diz
“Identificada: NTAG213 · 04:4C:25:0A:30:1F:91”.

:::figure[Depois de uma leitura de identificação, a área de saída mostra o nome do chip e o UID, e o nome do chip fica ao lado de **Preajustes**, com os preajustes desse chip no topo da lista.]
![O Console avançado depois de identificar uma NTAG213. A área de saída mostra duas linhas, “Identificando a etiqueta…” e depois “Identificada: NTAG213 · 04:4C:25:0A:30:1F:91”. Um selo verde NTAG213 com um botão para limpar fica ao lado de Preajustes, e os dois primeiros preajustes da lista foram feitos para o NTAG213.](../../../assets/pt-BR/advanced-console--identified.png)
:::
::::
:::::

Um chip identificado reordena a lista de preajustes. Os preajustes feitos para
esse chip vêm primeiro. Abaixo deles ficam os que ainda se aplicam a ele:

- preajustes feitos para todo o tipo de chip
- preajustes para um chip irmão da mesma linha, como um preajuste de NTAG215
  em um NTAG216

Nenhum dos dois tipos fica esmaecido. Os bytes de um chip irmão ainda podem
acessar a página errada do seu chip, então leia-os em **Comando** primeiro. Um
preajuste só fica esmaecido quando é de outra linha de chips ou de um tipo de
etiqueta totalmente diferente. Um preajuste esmaecido continua sendo carregado
em **Comando** quando você toca nele. Para esquecer o chip, toque no nome dele
ao lado de **Preajustes**, e a lista volta à ordem de sempre.

Quando o app não consegue dar nome ao chip, o console mostra
“Etiqueta conectada, mas o chip é desconhecido · 04:BA:4A:92:1B:21:90”. Em
seguida, exibe o que a etiqueta informou sobre si mesma. A primeira linha é
algo como “Relatado: NXP · NTAG · 128-256 bytes · v1.0”. Essa linha traz o
fabricante do chip, a família do produto, o tamanho de memória que o chip
declara e a versão do produto.
A segunda linha são os bytes brutos dos quais a primeira foi lida, como
“GET_VERSION: 00:04:04:02:01:00:0F:03”. Toque em uma linha para copiá-la. Uma
cápsula “Copiado” aparece por cerca de um segundo, e os bytes ficam na área de
transferência para um relatório de bug.

## O que os preajustes contêm

Um preajuste em **Preajustes** é uma sequência de comandos salva que já vem
com o app. Cada linha traz três coisas e nada mais: o nome do preajuste, um
selo com a família de chips para a qual ele foi feito e os próprios bytes.
Alguns leem uma etiqueta, e outros gravam nela, inclusive em páginas que um
chip só aceita gravar uma vez.

Não há nenhuma descrição por trás de uma linha, então os bytes são a única
indicação do que um preajuste faz. Leia-os em **Comando**, comparando com a
folha de dados do seu chip, antes de executar qualquer coisa. Nos chips Type 2
da maioria dos adesivos e cartões, um comando que começa com `30` ou `3A` lê,
e um que começa com `A2` grava. Para ver o console funcionando sem alterar uma
etiqueta, comece pela linha chamada **Ler 16 bytes**, cujos bytes são `30:00`.

## Executar um comando

:::::steps
::::step[Carregar um preajuste]
Toque em um preajuste da lista em **Preajustes**. Os bytes dele vão para
**Comando**, e o console anota o nome do preajuste que você carregou. Nada foi
enviado.
::::

::::step[Conferir o que será enviado]
Leia a sequência em **Comando** e edite-a se precisar. Cada par de dígitos
hexadecimais é um byte, os dois-pontos separam os bytes dentro de um comando,
e uma vírgula separa um comando do seguinte. Um campo vazio mostra o exemplo
“21:60:00, A2:04:E1:10:06:00”. Esse exemplo é um texto indicativo e não está
de fato no campo. Nada é enviado enquanto o campo estiver vazio, e
**Executar** continua esmaecido até você carregar um preajuste ou digitar uma
sequência. Lido como exemplo, são dois comandos, de três e de seis bytes, e o
segundo grava quatro bytes em uma página.
::::

::::step[Enviar a sequência]
Toque no botão **Executar**. O indicador de status mostra “Sondando…”, a área
de saída acrescenta “Sondando a etiqueta…”, e o painel do iOS
aparece com “Aproxime a etiqueta para enviar o comando.”
::::

::::step[Encostar a etiqueta no iPhone]
Encoste a parte superior do iPhone na etiqueta, bem rente, e mantenha-o
parado. A área de saída acrescenta uma linha de conexão com o UID da etiqueta
e o chip, como em “Conectada: 04:4C:25:0A:30:1F:91 · ntag213”. Depois, o
indicador de status mostra “Executando…” enquanto os comandos são enviados.

Para parar antes que qualquer byte chegue a uma etiqueta, toque em Cancelar no
painel do iOS. A execução termina, o indicador de status volta para “Ocioso”,
e a área de saída mostra “Cancelado antes de encontrar uma etiqueta. Nada foi
enviado.” Se ficar sem nenhuma etiqueta encostada, o painel se fecha sozinho e
o indicador de status mostra “Nenhuma etiqueta encontrada”. Depois que o
console já leu uma etiqueta, por **Executar** ou por **Identificar**, um
cancelamento ou um tempo esgotado em uma execução posterior passa a ser
registrado como uma linha de erro.
::::

::::step[Ler as respostas]
Cada comando acrescenta uma linha de envio e uma linha de recebimento, e a
linha de recebimento informa quantos bytes voltaram. Depois da última
resposta, o indicador de status mostra “Concluído” e a área de saída termina
com “Concluído.”

:::figure[Depois de uma execução de **Ler 16 bytes**, a área de saída tem uma linha de envio e uma linha de recebimento de 16 bytes, e o indicador de status mostra “Concluído”.]
![O Console avançado depois de executar o preajuste Ler 16 bytes em uma NTAG213. O indicador de status mostra “Concluído” e Comando contém 30:00. A área de saída, rolada até o fim, mostra a parte de baixo da linha do preajuste carregado, “Sondando a etiqueta…”, a linha de conexão com o UID e ntag213, uma linha TX que envia 30:00, uma linha RX marcada com 16 bytes e os bytes que a etiqueta devolveu, e a linha final Concluído.](../../../assets/pt-BR/advanced-console--run-finished.png)
:::
::::
:::::

:::warning[O console não verifica nada antes de enviar]
Um comando de gravação altera a etiqueta no momento em que sai. Algumas
páginas de um chip aceitam uma única gravação em toda a vida útil da etiqueta.
Um byte errado ali não pode ser desfeito por nenhum comando posterior.
:::

Para encontrar um preajuste entre muitos, digite parte do nome ou parte dos
bytes dele em **Buscar**, abaixo do título **Preajustes**. Você também pode
ignorar a lista e digitar sua própria sequência em **Comando**. Um comando que
a etiqueta recusa encerra a execução e a aproximação, e todas as linhas que já
estão na área de saída continuam onde estão.

## Ver todos os quadros, não só os desta execução

Acima da área de saída, toque em **Todo o tráfego NFC**. O console passa a
mostrar todos os quadros que o app troca com uma etiqueta. Aparecem os quadros
de leituras, gravações e operações em etiquetas, além dos desta tela. Os
novos quadros chegam à medida que acontecem. Toque em **Esta execução** para
voltar ao log do próprio console.

## Acessar um chip que recusa a sondagem

Ative **Pular a identificação**, o botão de ativação entre o indicador de
status e **Comando**, quando uma etiqueta não responde nada depois de se
conectar. O app passa então a enviar seus comandos sem antes perguntar ao chip
o que ele é. A execução informa a etiqueta como desconhecida em vez de dar o
nome do chip. O botão continua ativado até você desativá-lo; ele não volta
sozinho ao fim de uma execução. O motivo aparece abaixo do botão enquanto ele
está ativado:
“Os comandos vão direto para o chip. Necessário para chips que recusam GET_VERSION: a sondagem os interrompe e todos os comandos seguintes falham.”

Uma verificação continua acontecendo com o botão ativado. Quando uma etiqueta
pode ser um dispositivo de saúde NFC, como uma caneta de insulina, o app lê só
o bastante para saber, e não envia a um dispositivo de saúde nenhum dos seus
comandos.

## Se o console informar um erro

Uma linha de erro encerra a execução e, com ela, a aproximação. O painel do
iOS se fecha junto, então, para enviar mais alguma coisa, toque em
**Executar** de novo e aproxime a etiqueta.

- “Não foi possível interpretar o comando.” significa que o texto em
  **Comando** não é uma sequência que o app consegue ler, e nada foi enviado.
  Confira as três regras. Cada byte tem dois dígitos hexadecimais, e os
  dois-pontos ficam entre os bytes de um comando. Uma vírgula fica entre um
  comando e o seguinte.
- “Não foi possível identificar a etiqueta.” significa que a leitura de
  identificação terminou sem resultado. Toque em **Identificar** e aproxime a
  etiqueta de novo.
- “Este é um dispositivo de saúde. O Hex NFC nunca grava em dispositivos de
  saúde nem envia comandos a eles.” significa que a etiqueta é um dispositivo
  médico, como uma caneta de insulina. Nenhum dos seus comandos foi enviado a
  ele.
- “Ocorreu um erro inesperado.” significa que a execução parou por um motivo
  que o app não sabe descrever melhor. O resto da linha traz os detalhes.
- Qualquer outra mensagem em uma linha de erro é a descrição do próprio app
  sobre o que a etiqueta fez. O texto é o mesmo que uma leitura ou uma
  gravação teria mostrado.

Para saber o que essas mensagens costumam significar na prática, consulte
[Se não for possível ler ou gravar uma etiqueta](troubleshooting.md).

## Ver também

- [Salvar uma cópia da memória de uma etiqueta](memory-dump.md)
- [Etiquetas que funcionam com o Hex NFC](tags-that-work.md)
- [Matriz de compatibilidade de chips](../developer/chip-support-matrix.md)
