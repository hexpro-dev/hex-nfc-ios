---
title: Perguntas frequentes
description: Respostas sobre quanto custa o Hex NFC, de quais iPhones ele precisa, o que acontece com as etiquetas que você lê e como pedir ajuda.
audience: user
pageKind: faq
navTitle: FAQ
tags:
  - privacy
---

As outras páginas do manual explicam cada tarefa passo a passo. Esta página
responde ao que surge em torno delas: quanto o app custa e o que ele exige do
iPhone. Ela também responde o que acontece com as etiquetas que você lê e
como falar com a Hex Pro.

## Quanto custa

### O Hex NFC custa alguma coisa?

Não. O Hex NFC não custa nada, e não há contas, assinaturas, compras dentro do
app nem recursos pagos. Instale o Hex NFC pela
[App Store](https://apps.apple.com/app/id6801457461) e o app inteiro já está
lá.

### O que é o cartão de custos de desenvolvimento?

Um indicador de progresso, e nada que exija alguma ação sua. A tela inicial do
Hex NFC tem um cartão com o título **Custos de desenvolvimento recuperados**,
que mostra quanto do custo do projeto já foi recuperado até agora. **Ver
detalhamento** abre uma página do site da Hex Pro no seu navegador, onde
contribuir é voluntário. Nada do que há nessa página desbloqueia algo no app.

### O app mostra anúncios?

Nenhuma rede de anúncios funciona dentro dele. A tela inicial do Hex NFC pode mostrar
um cartão com o título **Mais apps da Hex Pro**, sobre outro app da mesma
desenvolvedora. Não há rede de anúncios de terceiros, rastreamento nem
personalização por trás desse cartão: todo mundo vê o mesmo.

## Do que o iPhone precisa

### Quais iPhones podem rodar o Hex NFC?

Qualquer iPhone com iOS 17 ou posterior, ou seja, do iPhone XR e do iPhone XS
em diante, além do iPhone SE de segunda e de terceira geração. Todos eles têm
o leitor NFC que o app usa, então a versão do iOS é a única coisa a verificar.
O Hex NFC é um app para iPhone e não funciona no iPad. Em um dispositivo sem o
leitor, a leitura termina com “Este dispositivo não é compatível com NFC.” em
vez de procurar uma etiqueta.

### Preciso de conexão com a internet?

Não. Ler, gravar e proteger uma etiqueta são coisas que acontecem entre o
iPhone e a etiqueta. O app se conecta à Hex Pro para quatro coisas. Duas são o
indicador de custos de desenvolvimento e o cartão de outro app da Hex Pro. As
outras duas só saem quando você as envia: um nome de estação de um cartão de
transporte e uma mensagem de feedback. A sincronização com o iCloud é o quinto
uso da rede, e ela fica desativada até você ativá-la. Consulte
[Privacidade e seus dados](privacy.md).

### Por que o iPhone não lê uma das minhas etiquetas?

O chip dela pode ser um que o iPhone não consegue ler de forma alguma. MIFARE
Classic é o caso mais comum, e isso é uma limitação do iOS, não um defeito da
etiqueta. Consulte [Etiquetas que funcionam com o Hex NFC](tags-that-work.md)
para ver os chips que o app reconhece.

## As etiquetas que você lê

### O que acontece com uma etiqueta depois que eu a leio?

A leitura fica salva no iPhone, em **Histórico**, na tela Biblioteca. Essa
lista tem um limite, e uma linha não fixada também expira com o tempo; uma
linha que você fixou permanece além dos dois limites. Excluir uma linha remove
a leitura armazenada. Consulte
[Encontrar uma etiqueta que você leu antes](scan-history.md).

### Passaportes e cartões de transporte também são salvos?

Os dois são diferentes. A leitura de um passaporte é mantida apenas durante
aquela sessão e descartada quando você fecha o painel. Nada dela chega ao seu
histórico, a uma exportação nem ao iCloud. A leitura de um cartão de
transporte é salva como qualquer outra leitura. A linha fica em **Histórico**,
na tela Biblioteca, e conta entre as 50 linhas que essa lista comporta.
Enquanto a sincronização com o iCloud estiver ativada, ela é espelhada no
iCloud. Abrir essa linha mostra o cartão como ele foi lido, e excluir a linha
remove a leitura armazenada. Consulte [Ler um passaporte](passports.md) e
[Ler um cartão de transporte](transit-cards.md).

### Alguma coisa das minhas etiquetas sai do iPhone?

Só se você ativar **Sincronizar com iCloud**, que fica no grupo
**Sincronização** da tela Ajustes do Hex NFC e vem desativado. Essa opção
espelha os seus preajustes e o seu histórico de leitura no seu banco de dados
privado do iCloud, que a Apple opera e o seu ID Apple protege. As senhas das
etiquetas nunca fazem parte disso: elas ficam no Chaveiro do iOS, no iPhone
que as definiu. Consulte [Ajustes](settings.md#turn-on-icloud-sync) e
[Privacidade e seus dados](privacy.md).

### O Hex NFC consegue recuperar uma senha de etiqueta que eu esqueci?

Não, e nenhuma outra coisa consegue. A própria etiqueta verifica a senha,
então a memória protegida de uma etiqueta cuja senha foi perdida não pode ser
recuperada. Uma senha que você define fica guardada no Chaveiro do iPhone que
a definiu. Em um segundo iPhone, a mesma etiqueta pede que você a digite.
Consulte [Proteção de etiquetas](tag-protection.md).

### O Hex NFC consegue ler minha caneta de insulina? {#insulin-pen}

Ele consegue dizer que caneta é, mas não o que ela guarda. Uma NovoPen 6 ou
NovoPen Echo Plus abre a tela **Dispositivo de saúde**, que indica um app capaz
de ler o histórico de doses. O Hex NFC nunca grava em um dispositivo de saúde e
não salva nada dele. Consulte
[Dispositivos de saúde](tags-that-work.md#health-devices).

## Pedir ajuda {#getting-help}

### Como relato um problema ou faço uma pergunta? {#report-a-problem}

No Hex NFC, toque no botão de engrenagem da tela inicial e depois em
**Enviar feedback**. A mensagem vai direto para a Hex Pro com a versão do app,
a versão do iOS, o modelo do dispositivo e o idioma, e o formulário mostra essas
informações antes do envio. Se quiser resposta, coloque seu e-mail em
**Endereço para resposta (opcional)**. Você também pode escrever para
support@hex.pro.

Se uma leitura ou uma gravação falhar, procure a mensagem que você viu em
[Se não for possível ler ou gravar uma etiqueta](troubleshooting.md).
