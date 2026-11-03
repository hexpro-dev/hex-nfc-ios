---
title: Ler um passaporte
description: Leia o chip de um passaporte eletrônico com o Hex NFC, usando os dados da página com a foto, apenas durante uma sessão.
audience: user
pageKind: howto
navTitle: Passaportes
tags:
  - scanning
  - privacy
---

Um passaporte eletrônico guarda a página com a foto em um chip: o nome, o
número, as datas e a fotografia. O Hex NFC lê esse chip e mostra o que
encontrou em uma única tela. O chip só se abre com três dados impressos
dentro do passaporte. O app pede esses dados depois que a primeira
aproximação encontra o chip. Ele guarda o resultado enquanto a tela estiver
aberta, e não por mais tempo que isso.

Antes de começar, você precisa do app instalado pela App Store em um iPhone
que leia etiquetas NFC, e do próprio passaporte.
[Ler sua primeira etiqueta](quick-start.md) explica como instalar o app e ler
uma etiqueta.

Abra o passaporte na página com a foto e deixe-o à mão. O número do
passaporte, a data de nascimento e a data de validade estão impressos ali.
Você pode escaneá-los com a câmera ou digitá-los. A página com a foto é onde
você lê esses dados, não onde o telefone deve ficar. O símbolo do chip, um
pequeno retângulo com um círculo dentro, vem impresso na capa de um
passaporte eletrônico. Um passaporte sem esse símbolo não tem chip, e nada
aqui vai conseguir lê-lo.

## Ler um passaporte {#read-a-passport}

::::steps
:::step[Abrir a tela de leitura]
Toque em **Escanear** na tela inicial do Hex NFC. A tela de leitura se abre e mostra
“Encoste a etiqueta na parte superior do iPhone”.
:::

:::step[Encostar o passaporte no iPhone]
Feche o passaporte, encoste a parte superior do iPhone na capa da frente, bem
rente, e mantenha-o parado. A antena fica na capa da frente, na capa de trás
ou na página com a foto, dependendo do passaporte. Se nada acontecer depois de
alguns segundos, tente a capa de trás e depois a página com a foto aberta.
Esta primeira aproximação identifica o chip e termina, e o painel do iOS se
fecha junto. A tela de leitura passa a mostrar “Passaporte
detectado” e os três campos de que o chip precisa para se abrir:
**Número do passaporte**, **Data de nascimento** e **Data de validade**. Acima
deles fica **Escanear a página com a foto**, que preenche os três com a
câmera. [Escanear os dados com a câmera](#scan-the-details-with-the-camera)
explica esse caminho, que substitui os dois próximos passos.
:::

:::step[Digitar o número do passaporte]
Em **Número do passaporte**, digite o número da página com a foto, incluindo
as letras. O campo mostra “ex.: PA1234567” até você começar a digitar.
:::

:::step[Escolher as duas datas]
Toque em **Data de nascimento** e escolha a data impressa na página com a
foto; depois, faça o mesmo em **Data de validade**. Cada seletor abre em uma
data inicial escolhida pelo app, então confira o ano, além do dia. A data de
validade é aquela em que o passaporte vence, não a data em que ele foi
emitido.
:::

:::step[Iniciar a leitura]
Toque em **Ler passaporte**. O botão não inicia a leitura enquanto o campo do
número do passaporte estiver vazio.
:::

:::step[Encostar o passaporte no iPhone de novo]
Encoste-o na parte superior do iPhone e mantenha-o ali. O painel do iOS
acompanha a leitura com “Conectando ao seu passaporte…”, “Desbloqueando com
seus dados…”, “Lendo os dados do passaporte…” e “Quase lá…”. A tela
**Passaporte** se abre quando a leitura termina.
:::
::::

Toque em **Fechar** quando tiver lido o que precisava.

## Escanear os dados com a câmera {#scan-the-details-with-the-camera}

**Escanear a página com a foto** lê o número do passaporte e as duas datas nas
duas linhas de leitura mecânica da parte inferior da página com a foto,
aquelas formadas por letras maiúsculas, números e sequências de sinais <. Não
há botão de disparo: os dados são capturados assim que a câmera os lê.

::::steps
:::step[Abrir a câmera]
Na tela de leitura, depois que a primeira aproximação encontrar o passaporte,
toque em **Escanear a página com a foto**. Na primeira vez, o iOS pergunta se
o Hex NFC pode usar a câmera. A câmera se abre sob o título “Escaneie a
página com a foto”. Se você não permitir o uso da câmera, a tela mostra
“Acesso à câmera necessário”.
:::

:::step[Enquadrar a página com a foto]
Abra o passaporte na página com a foto e segure o iPhone sobre ela. A tela
mostra o contorno de uma página com foto, com uma área de enquadramento ao
longo da borda inferior, e diz “Enquadre as duas linhas de letras e <<< da
parte inferior da página com a foto.” Mova o telefone até a página coincidir
com o contorno e as duas linhas ficarem dentro da área de enquadramento.
Quando a tela mostrar “Mantenha o iPhone parado”, mantenha o telefone firme.
Aparece uma marca de confirmação, a tela mostra “Pronto” com o número e as
duas datas, e logo depois você volta à tela de leitura.
:::

:::step[Conferir os dados]
Um cartão com o título “Dados lidos da página com a foto” passa a ocupar o
lugar dos campos e mostra o número e as duas datas. Confira cada um na página
com a foto. Para corrigir algum, toque em **Editar**: o cartão dá lugar aos
campos, preenchidos com o que a câmera leu. **Editar** não aparece quando uma
data da página não tem o dia ou o mês impresso. Para usar a câmera de novo,
toque em **Escanear de novo**.
:::

:::step[Iniciar a leitura]
Toque em **Ler passaporte**. Feche o passaporte e encoste-o na parte superior
do iPhone, como no último passo de [Ler um passaporte](#read-a-passport).
:::
::::

Se a área de enquadramento não encontrar nada por alguns segundos, a tela
mostra “Ainda procurando. Incline a página para longe de luzes fortes ou
experimente a lanterna.” O reflexo no plástico que cobre a página com a foto
costuma ser a causa, e o botão da lanterna no alto da tela ilumina a página.
Para sair da câmera e digitar os dados, toque em **Digitar os dados**.

Se o acesso à câmera estiver desativado para o Hex NFC, a tela mostra “Acesso
à câmera necessário”. Toque em **Abrir Ajustes** para ativá-lo ou em
**Digitar os dados**.

## O que a tela Passaporte mostra

A tela é somente leitura. As linhas só aparecem quando o chip respondeu,
então um passaporte com menos dados mostra uma tela mais curta.

- A caderneta no topo traz a fotografia do chip e as duas linhas de leitura
  mecânica como estão impressas no passaporte. Alguns passaportes guardam a
  fotografia em um formato que o iOS não lê, e então a caderneta mostra uma
  silhueta cinza no lugar dela. Nada mais na tela muda.
- Em **Dados do passaporte** ficam o sobrenome, os nomes, o número do
  passaporte, a nacionalidade, o país emissor, a data de nascimento, o sexo e
  a data de validade.
- Um cartão **Integridade dos dados** aparece quando o chip tinha um objeto de
  segurança.
- Um cartão **Assinatura** aparece quando o chip tinha uma imagem de
  assinatura e o iPhone conseguiu exibi-la. Alguns passaportes guardam essa
  imagem em um formato que o iOS não lê, e então nenhum cartão aparece.
- Em **Detalhes adicionais** ficam os extras que alguns passaportes trazem,
  entre eles local de nascimento, endereço, telefone, profissão, autoridade
  emissora e data de emissão.
- O cartão no fim da tela dá ao chip o nome “Passaporte eletrônico” e à
  família o nome “eMRTD (ISO/IEC 14443-4)”. Outros chips informam mais coisas,
  como mostra a
  [matriz de compatibilidade de chips](../developer/chip-support-matrix.md).

## O que a verificação de integridade dos dados informa

Quando o chip fornece uma lista de hashes, o app calcula os seus próprios
hashes para os dados que leu e compara as duas listas. O cartão
**Integridade dos dados** então mostra “Provavelmente intacto” ou
“Provavelmente alterado”, e as mesmas palavras aparecem na caderneta no topo
da tela. O cartão também lista os grupos de dados que verificou, o algoritmo de hash usado
e qualquer grupo que não tenha correspondido.

O cartão diz quanto vale essa comparação: “Os grupos de dados correspondem à
lista de hashes do objeto de segurança do chip. A assinatura desse objeto não
é verificada, então isto não prova que os dados estejam inalterados nem
confere a autenticidade do passaporte.”

:::important[Nenhum dos dois vereditos diz que um passaporte é autêntico]
O Hex NFC não verifica quem assinou os dados do chip. “Provavelmente intacto”
significa que o chip está de acordo consigo mesmo, algo que qualquer pessoa
que tenha gravado o chip inteiro conseguiria fazer.
:::

## Se os dados não desbloquearem o passaporte

A tela de leitura troca a instrução por uma mensagem em vermelho: “Esses dados
não desbloquearam o passaporte. Confira-os na página com a foto e tente de
novo.” O que você digitou continua nos campos, e os dados lidos pela câmera
continuam no cartão. Confira cada um na página com a foto, toque em
**Ler passaporte** e aproxime o passaporte de novo.

Quando os dados vieram da câmera e ela encontrou outra leitura possível do
número, a mensagem passa a ser “Esses dados não desbloquearam o passaporte. A
câmera pode ter lido um caractere errado, então a próxima tentativa usa outra
leitura do número.” O cartão então mostra essa leitura. Confira-a na página
com a foto, toque em **Ler passaporte** e aproxime o passaporte de novo.
Depois que todas as leituras forem tentadas, o cartão volta para a primeira e
a mensagem volta a ser a de cima. Se o cartão ainda não corresponder à página
com a foto, toque em **Editar** para corrigi-lo ou em **Escanear de novo**.

- Digite o número do passaporte caractere por caractere, incluindo as letras
  e sem espaços.
- Confira o ano nas duas datas. Um seletor de data deixado na década errada
  parece certo numa olhada rápida.
- Tente mais uma vez sem mudar os dados. A mesma mensagem aparece quando uma
  leitura é interrompida no meio, e uma segunda aproximação mais firme
  costuma resolver.

Se nada acontecer enquanto você aproxima o passaporte, o chip não está
respondendo. [Se não for possível ler ou gravar uma etiqueta](troubleshooting.md)
trata disso. A primeira aproximação também pode mostrar “Etiqueta detectada”
e abrir a tela **Etiqueta**. Isso significa que o iPhone alcançou um chip, mas
não o reconheceu como passaporte. O Hex NFC não consegue ler esse chip como
passaporte. Um cartão de transporte japonês abre a tela
**Cartão de transporte**, e [Ler um cartão de transporte](transit-cards.md)
trata desses cartões.

## O que o app guarda

Nada. Os três dados desbloqueiam o chip apenas para aquela leitura. Quando
você escaneia a página com a foto, a imagem da câmera é analisada no próprio
iPhone para encontrá-los, e nenhuma imagem é salva ou enviada a lugar nenhum.
Há uma nota abaixo dos dados. Ela diz: “Esses dados ficam no seu dispositivo,
são usados apenas nesta leitura e nunca são salvos nem enviados a lugar
algum.”

O que o chip devolve recebe o mesmo tratamento. A leitura de um passaporte
nunca é adicionada ao seu histórico de leitura, nunca é exportada e nunca é
enviada a lugar nenhum. Tocar em **Fechar** descarta os dados junto com a
tela. Para vê-los de novo, é preciso ler o passaporte outra vez. A tela
**Passaporte** traz uma nota parecida no rodapé. Ela diz: “Lido do chip e exibido
aqui apenas nesta sessão: nada é salvo, nada é enviado e a autenticidade não
é verificada.”

## Ver também

- [Ler um cartão de transporte](transit-cards.md)
- [Privacidade e seus dados](privacy.md)
- [Encontrar uma etiqueta que você leu antes](scan-history.md)
