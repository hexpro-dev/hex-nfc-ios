---
title: Ler um cartão de transporte
description: Encoste um Suica, um PASMO ou outro cartão de transporte japonês no iPhone para ver o saldo e as viagens recentes no Hex NFC.
audience: user
pageKind: howto
navTitle: Cartões de transporte
tags:
  - scanning
---

Encoste um cartão de transporte IC japonês no iPhone e o Hex NFC mostra o
saldo que resta nele e as viagens que ele guarda na memória. Suica, PASMO,
ICOCA, TOICA, manaca, SUGOCA, nimoca, Kitaca e os demais cartões IC japoneses
usam todos o mesmo sistema. Todos eles são lidos da mesma forma. Um cartão de
transporte de outro país não é lido aqui, e
[Etiquetas que funcionam com o Hex NFC](tags-that-work.md) diz o que o app lê.

Antes de começar, você precisa do app instalado pela App Store em um iPhone
que leia etiquetas NFC. Também precisa do cartão fora da carteira.
[Ler sua primeira etiqueta](quick-start.md) explica como instalar o app e ler
uma etiqueta, e [Perguntas frequentes](faq.md) diz quais iPhones o app exige.
Um cartão de transporte só é lido, nunca alterado, então não há como
adicionar dinheiro a um cartão por aqui.

## Ler um cartão de transporte

::::steps
:::step[Abrir o Hex NFC]
Abra o Hex NFC. A tela inicial do Hex NFC se abre, com o bloco **Escanear**.
:::

:::step[Abrir a tela de leitura]
Toque em **Escanear**. A tela de leitura se abre e mostra “Encoste a etiqueta
na parte superior do iPhone”.
:::

:::step[Encostar o cartão no iPhone]
Encoste o cartão bem rente à parte de trás do iPhone, perto da borda
superior. Mantenha os dois parados até a tela mostrar “Etiqueta detectada”, o
que indica que a leitura terminou. Se nada acontecer depois de alguns
segundos, mova um pouco o cartão e aproxime-o de novo. Para parar, toque em
Cancelar no painel do iOS. Isso leva você de volta à tela inicial do Hex NFC. Se ficar sem nenhum
cartão encostado, a leitura termina sozinha e a tela mostra “Nenhuma etiqueta
encontrada”, com **Tentar de novo** abaixo.
:::

:::step[Esperar o cartão abrir]
Afaste o cartão. Depois de cerca de um segundo, a tela
**Cartão de transporte** se abre sozinha.
:::

:::step[Fechar o cartão]
Toque em **Fechar**. Você volta à tela inicial do Hex NFC.
:::
::::

:::note[Só sai do iPhone o nome que você dá a uma parada]
O saldo, as viagens e o UID do próprio cartão ficam no iPhone. A única coisa
que o app envia para algum lugar é um nome de parada que você digita e envia.
Esse envio também leva os códigos da parada e o tipo do cartão.
[Dar nome a uma parada que o app não conseguiu nomear](#name-a-stop) explica
isso.
:::

## Se o cartão não for encontrado

- Aproxime um cartão de cada vez, longe dos outros cartões da carteira.
- Encoste o cartão na parte de trás do iPhone, perto da borda superior, e não
  no meio da parte de trás.
- Confira se o cartão é um cartão de transporte IC japonês. Um cartão de outro
  sistema de transporte não abre a tela **Cartão de transporte**.
- Se uma leitura começar e depois falhar, a tela mostra “Falha ao escanear” e
  diz o que deu errado. Toque em **Tentar de novo** e mantenha o cartão parado
  por mais tempo.

[Se não for possível ler ou gravar uma etiqueta](troubleshooting.md) trata do
restante.

## O que a tela Cartão de transporte mostra

A tela tem três partes, nesta ordem:

1. O cartão, com o sistema a que ele pertence, como “Cartão de transporte IC
   (Suica / PASMO …)”, e “Saldo” acima do dinheiro que resta nele, em ienes.
2. O [cartão de informações da etiqueta](tags-that-work.md), que descreve o
   chip do cartão. Duas das linhas dele são exclusivas dos cartões de
   transporte: “Código do sistema” e “Transações”, com o número de entradas
   lidas.
3. “Histórico”, a lista do que o cartão guarda na memória. Um cartão de
   transporte guarda as suas 20 transações mais recentes, então 20 linhas é o
   máximo que essa lista mostra. Um cartão que não informa nenhuma mostra
   “Nenhum histórico de transações neste cartão”.

Abaixo da lista, nos dois casos, o app repete o que consegue e o que não
consegue nomear. O texto diz: “Os nomes das estações são exibidos quando
disponíveis; as demais paradas aparecem como seus códigos brutos de
transporte.”

## O que uma linha do histórico informa

Uma linha informa o que foi a transação, o dia em que ela aconteceu e o saldo
que restou depois dela. Uma viagem de trem mostra a parada em que você entrou
e, quando o cartão a registrou, a parada em que você saiu. Uma parada que o
app não consegue nomear mostra uma de duas coisas no lugar do nome da
estação. Uma é o nome da linha de trem, seguido de um ponto de interrogação.
A outra é o código bruto de transporte da parada.

Quando o cartão não registrou a parada de entrada, essa ponta mostra
“Desconhecido”. Quando não registrou a parada de saída, a linha mostra só a
parada que tem, sem uma seta depois dela. Uma linha sem data legível mostra
“Data desconhecida” abaixo do título.

Uma transação que não é uma viagem de trem indica o que aconteceu no lugar de
um trajeto:

- “Tarifa de ônibus”.
- “Recarga”, para dinheiro adicionado ao cartão.
- “Compra”, para algo comprado em uma loja.
- “Transação”, para um bloco do cartão que não se encaixa em nenhum desses
  casos.

O VoiceOver lê uma viagem de trem como “Viagem” antes das duas paradas e da
data.

## Dar nome a uma parada que o app não conseguiu nomear {#name-a-stop}

Uma parada ainda sem nome é uma em que você já esteve, porque ela está no seu
cartão. Você pode dizer ao app como ela se chama. Quando pelo menos uma
parada de trem está sem nome, um cartão acima do histórico mostra “Algumas
dessas paradas ainda não têm nome. Você esteve nelas: ajude a preencher
abaixo.” Uma linha abaixo dele diz o que um nome leva junto. Ela diz: “O nome
que você enviar chega até nós para revisão e pode entrar em uma atualização
futura. Ele inclui os códigos da parada, o tipo do cartão e o nome que você
digitou. Nada mais do cartão é enviado.”

Uma parada sem nome é aquela que mostra uma linha de trem e um ponto de
interrogação, ou um código bruto de transporte, onde estaria o nome de uma
estação.

::::steps
:::step[Encontrar uma linha do histórico com uma parada sem nome]
Role até a primeira linha que mostre uma. O campo dessa parada fica logo
abaixo da linha. O texto acima do campo indica a linha de trem em que a
parada fica. Quando a linha de trem também é desconhecida, esse texto mostra
“Parada desconhecida”.
:::

:::step[Digitar o nome]
Em **Dar nome a esta estação**, digite como a parada se chama.
:::

:::step[Enviar o nome]
Toque em **Enviar**. O app mostra “Obrigado!” no lugar do campo; depois, o
campo se fecha e continua fechado até você ler o cartão de novo.
:::
::::

Cada parada sem nome ganha um único campo, mesmo quando várias viagens passam
por ela. Um nome enviado não pode ser retirado. Se você enviou o nome errado,
leia o cartão de novo para o campo voltar e envie o nome certo. Todo nome
passa por revisão antes de entrar no app, então um erro não chega ao app
sozinho.

## Ver também

- [Ler sua primeira etiqueta](quick-start.md)
- [Ler uma etiqueta](scan-a-tag.md)
- [Etiquetas que funcionam com o Hex NFC](tags-that-work.md)
- [Se não for possível ler ou gravar uma etiqueta](troubleshooting.md)
- [Privacidade e seus dados](privacy.md)
