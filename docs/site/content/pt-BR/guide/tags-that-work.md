---
title: Etiquetas que funcionam com o Hex NFC
description: Quais chips o app reconhece, o que o cartão de informações da etiqueta diz sobre cada um e o que um iPhone não consegue ler.
audience: user
pageKind: article
navTitle: Etiquetas compatíveis
tags:
  - chips
---

Um adesivo de um pacote de etiquetas em branco, um cartão-chave de hotel e uma
etiqueta de livro de biblioteca parecem iguais na mão. O chip dentro deles não
é o mesmo, e é ele que define quanto a etiqueta guarda e se ela aceita uma
senha. Ele também define se o iPhone consegue, de fato, ler a etiqueta.

Para as suas próprias etiquetas, compre etiquetas em branco da família NTAG.
Uma NTAG213 guarda 144 bytes, o suficiente para um endereço da web ou um
contato curto. Uma NTAG215 guarda 504 bytes e uma NTAG216 guarda 888, que é o
que uma nota longa ou um conjunto de vários registros exige. Qualquer uma das
três aceita uma senha e pode ser bloqueada. Uma etiqueta que você não comprou
em branco costuma vir cheia de dados que só quem a emitiu consegue
interpretar. Um cartão-chave de hotel, um cartão de transporte e um crachá de
acesso a um prédio são todos esse tipo de etiqueta.

Para saber que etiqueta você tem na mão, leia-a. O que o app leu abre na tela
Etiqueta. O cartão no topo dessa tela é o cartão de informações da etiqueta,
que tem como título o nome do próprio chip.
[Ler uma etiqueta](scan-a-tag.md) explica a leitura passo a passo.

O nome é um código de componente, então é ele que você deve pesquisar quando
quiser saber o que uma etiqueta aceita. O que o app faz com cada chip, um a
um, está descrito na
[Matriz de compatibilidade de chips](../developer/chip-support-matrix.md).
Essa página faz parte da documentação para desenvolvedores, e não deste
manual, por isso fala de comandos e de execuções de teste.

## Os nomes que o app mostra

O título do cartão de informações da etiqueta é o nome do próprio chip. Estes
são os nomes que ele pode mostrar.

:::table[Os nomes de chip que o cartão de informações da etiqueta pode mostrar]
| Família | Nomes no cartão de informações da etiqueta |
| --- | --- |
| NTAG | NTAG 210µ, NTAG213, NTAG213 TT, NTAG215, NTAG216, NTAG424 DNA |
| MIFARE Ultralight | MIFARE Ultralight EV1 (48b), MIFARE Ultralight EV1 (128b), MIFARE Ultralight C |
| MIFARE DESFire | MIFARE DESFire, MIFARE DESFire EV1, MIFARE DESFire EV2, MIFARE DESFire EV3 |
| EM Microelectronic | EM V10, EM V11, EM V16 |
| ICODE | ICODE SLIX, ICODE SLIX2 |
| Identificados só pela família | ISO 15693, FeliCa, Passaporte eletrônico, NFC Forum Type 4, Dispositivo de saúde |
:::

A última linha é o que aparece quando o chip responde como parte de uma
família, mas não diz qual é o modelo. Um cartão de transporte japonês aparece
como FeliCa e abre um resultado próprio, explicado em
[Ler um cartão de transporte](transit-cards.md). Um passaporte aparece como
Passaporte eletrônico, explicado em [Ler um passaporte](passports.md).

Uma etiqueta Type 4 de um fabricante que não é a NXP aparece como NFC Forum
Type 4, e o mesmo acontece com um celular Android configurado para funcionar
como etiqueta. O app lê e grava os registros dela como os de qualquer outra
etiqueta. Ele não consegue saber qual chip está dentro, então o cartão não
mostra a linha **Memória**, e senha, bloqueio permanente e
**Despejo de memória** não estão disponíveis para ela. Um dispositivo de saúde
aparece como Dispositivo de saúde, explicado mais abaixo em
[Dispositivos de saúde](#health-devices).

Alguns chips não dizem nada que um app de NFC consiga associar a um código de
componente. O cartão então mostra uma linha **Relatado** e uma linha
**Bytes de versão** no lugar de um nome, que são as palavras da própria
etiqueta sobre si mesma. Uma etiqueta assim ainda pode ser lida e gravada como
uma etiqueta comum. O que ela perde é tudo o que depende de conhecer a
organização da memória do chip. Isso exclui uma senha, um bloqueio permanente
e o **Despejo de memória**, a operação que
[Salvar uma cópia da memória de uma etiqueta](memory-dump.md) explica.

## O que o cartão diz sobre o chip

Duas linhas resumem o chip. **Compatível com** lista o que o app consegue
fazer com ele, como “Leitura”, “Gravação”, “Senha” ou “Bloqueio”. “Gravação”
significa que a etiqueta aceita uma nova mensagem, como em
[Gravar um link em uma etiqueta](write-a-link.md). “Senha” significa que ela
pode ter uma senha própria, assunto de
[Proteger uma etiqueta com senha](protect-a-tag.md). “Bloqueio” significa que
a etiqueta pode se tornar somente leitura. Isso não pode ser desfeito em
nenhuma etiqueta, e é por isso que
[Bloquear uma etiqueta permanentemente](permanent-lock.md) é uma página à
parte. **Recursos** lista os extras que o chip traz, como “Contador de
leituras” ou “Laço antiviolação”.

Abaixo delas ficam linhas que só aparecem quando o chip respondeu sobre elas.
Uma linha ausente significa que o chip não disse nada a respeito, nunca que a
leitura deu errado.

Uma linha **Violação** pertence a um chip com laço antiviolação, o que hoje
significa um NTAG213 TT. Ela mostra “Lacre intacto” enquanto o laço está
inteiro e “Aberto” depois que o laço foi rompido. Um laço rompido continua
rompido. Um lacre que o app informa como aberto já estava aberto quando você
encontrou a etiqueta. Nenhuma leitura sua o rompeu.

Uma linha **Vezes lida** vem de um chip com contador de leituras e mostra o
número de leituras que o chip contou. “Contador desativado” é diferente de uma
linha ausente: o contador existe e está desativado, que é como a maioria das
etiquetas sai da fábrica.

Uma linha **Contadores** vem de um MIFARE Ultralight EV1, em qualquer um dos
seus dois tamanhos. Esse chip tem três contadores próprios, e a linha mostra
os três lado a lado. Uma segunda linha **Contadores** com “Interrupção de
gravação detectada” significa que o chip informa que esses contadores não
estão íntegros. Um MIFARE Ultralight C não mostra nenhuma das duas linhas,
porque o contador dele responde a um comando que o app não envia.

Uma linha **Assinatura** mostra “Assinatura de originalidade NXP” quando o chip
respondeu com uma assinatura de 32 bytes. Ela mostra “Não é uma assinatura NXP
padrão” quando a resposta foi mais curta que isso. Nenhum dos dois textos é um
veredito sobre a autenticidade da etiqueta. O app anota o que o chip respondeu
e não compara isso com nada.

## Dispositivos de saúde {#health-devices}

Alguns dispositivos médicos respondem ao iPhone como uma etiqueta responde,
como as canetas de insulina NovoPen 6 e NovoPen Echo Plus. O Hex NFC reconhece
um deles pelo que ele diz sobre si mesmo e abre a tela **Dispositivo de saúde**
no lugar da tela Etiqueta. Para uma caneta que ele sabe identificar, o título é
**Caneta inteligente da Novo Nordisk**. A tela diz que o Hex NFC não lê o
histórico de doses da caneta, e um cartão abaixo indica um app que lê, com um
botão para baixá-lo na App Store e um link para a lista de apps do fabricante
da caneta que fazem essa leitura. Qualquer outro dispositivo de saúde recebe o
título **Dispositivo de saúde** e nenhuma sugestão de app.

O Hex NFC lê só o que o dispositivo diz sobre si mesmo e nunca grava nele. Uma
gravação, uma operação ou um comando do console do **Avançado** dirigido a um
dispositivo de saúde para antes que qualquer coisa seja gravada ou enviada.
Nada do dispositivo é salvo, então ele não aparece no seu histórico. Toque em
**Fechar** para sair da tela.

## O que um iPhone não consegue ler

Um cartão comum está fora do alcance de qualquer iPhone. Uma MIFARE Classic
interrompe a leitura com uma mensagem que diz isso: a etiqueta não está com
defeito, e nenhum app de NFC no iOS vai além disso.
[Por que o iPhone não consegue ler esta etiqueta de forma alguma?](troubleshooting.md#tag-not-readable)
traz a mensagem e o motivo.

Um cartão MIFARE DESFire é uma versão mais branda do mesmo limite. O app
identifica o cartão pelo nome e pode enviar comandos brutos a ele. Também lê
registros quando o cartão tem uma aplicação NDEF e os grava quando essa
aplicação permite. Um cartão MIFARE DESFire EV1, EV2 ou EV3 em branco pode
receber uma aplicação NDEF com **Formatar**, e **Remover configuração NDEF** a
retira de novo. As duas operações ficam em **Ações perigosas**, na tela
**Operações**: consulte [Formatar uma etiqueta](erase-or-format.md#format-a-tag)
e [Remover a configuração NDEF de um cartão](erase-or-format.md#remove-ndef-setup).
Um cartão já emitido para outra finalidade, como um cartão de transporte ou de
acesso, guarda os dados protegidos por chaves que só quem o emitiu tem, e o
app se recusa a configurá-lo e o deixa como está.

Se uma etiqueta que você acredita ser compatível ainda assim não for lida, a
causa costuma estar na forma como ela é aproximada, e não no chip. Consulte
[Se não for possível ler ou gravar uma etiqueta](troubleshooting.md).
