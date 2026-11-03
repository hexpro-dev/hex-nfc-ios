---
title: Matriz de compatibilidade de chips
description: Quais chips NFC o Hex NFC consegue ler, gravar, proteger com senha e bloquear no iPhone, e quanto disso foi confirmado em etiquetas reais.
audience: developer
tags:
  - chips
---

Esta página mostra quais chips NFC o Hex NFC consegue ler, gravar, proteger
com senha e bloquear no iPhone, e quanto disso já foi confirmado em etiquetas
reais. Se faltar um chip do qual você depende, ou se ele se comportar de um
jeito diferente do que a página diz, envie um e-mail para
[support@hex.pro](mailto:support@hex.pro) com o nome do chip e o que
aconteceu.

## Legenda

| Status | Significado |
|---|---|
| ✅ | Funciona e foi confirmado em etiquetas reais |
| ⚠️ | Implementado, com uma ressalva nas notas da linha ou no texto em volta da tabela (muitas vezes, a de que não foi confirmado em uma etiqueta real) |
| ❌ | O app recusa ou não consegue fazer isso |
| — | Não se aplica |

NTAG 210µ, NTAG213, NTAG216, NTAG424 DNA, MIFARE Ultralight EV1 de 128
bytes, MIFARE Ultralight C, ICODE SLIX2 e MIFARE DESFire EV3 foram testados
em etiquetas físicas em agosto de 2026, e o leitor de transporte foi
confirmado em cartões Suica e PASMO reais. A configuração do MIFARE DESFire
EV3 como etiqueta NDEF, uma gravação, uma leitura e a remoção dessa
configuração foram confirmadas em um cartão real em outubro de 2026. As
sequências de proteção e de remoção da proteção foram reformuladas para
todas as famílias em setembro de 2026, e o NTAG213 é o único chip que
executou o código de proteção reformulado em uma etiqueta real, e só para
proteção contra gravação, por isso nenhuma célula de Senha tem ✅. Nenhum
despejo de memória foi feito ainda a partir de uma etiqueta real, por isso
nenhuma célula de Despejo de memória tem ✅. A própria operação Despejo de
memória só foi executada nos simuladores de NTAG213 e NTAG215. Algumas das
etiquetas testadas não se comportam como peças da NXP: as etiquetas
Ultralight C repetem bytes de UID de uma etiqueta para outra, e um NTAG216
devolveu uma assinatura de originalidade curta, então os resultados nesses
dois chips podem não valer para chips NXP autênticos.

Uma linha marcada como somente simulador se baseia apenas nos simuladores de
chip em nível de protocolo, e uma linha marcada como não testada não foi
executada em uma etiqueta real nem, quando a nota diz isso, em um simulador.
Trate as células ⚠️ dessas linhas como algo que deve funcionar, e não como
algo confirmado em laboratório.

A coluna **Bloqueio** é verificada de outro jeito: o bloqueio não tem volta,
então ele é testado em etiquetas descartáveis, em uma rodada separada, e não
como parte da validação de um chip. Em agosto de 2026, essa rodada cobriu
NTAG 210µ, NTAG213, NTAG216, MIFARE Ultralight EV1 de 128 bytes, MIFARE
Ultralight C e ICODE SLIX2. A sequência de bloqueio do Type 2 foi
reformulada em setembro de 2026 e, desde então, foi executada de novo no
NTAG213 e no NTAG 210µ. No NTAG216, no Ultralight EV1 de 128 bytes e no
Ultralight C, a confirmação é anterior a essa reformulação, por isso as
células de Bloqueio deles têm ⚠️. O bloqueio do ICODE SLIX2 ainda envia os
comandos que foram confirmados, e a célula dele tem ⚠️ apenas por causa do
fallback de identificação descrito na linha dele. Todos os outros ⚠️ da
coluna Bloqueio se baseiam nos simuladores de chip, exceto o do NTAG213 TT,
em que só a máscara de bits de bloqueio é testada e nenhum simulador executou
um bloqueio permanente.

## Type 2 (ISO 14443-3A)

| Chip | Leitura | Gravação | Senha | Bloqueio | Despejo de memória | Notas |
|---|---|---|---|---|---|---|
| NTAG 210µ | ✅ | ✅ | — | ✅ | ⚠️ | 48 bytes de memória do usuário (64 no total). :more[Sem suporte a senha: o die “micro” não tem páginas de configuração, então não há onde guardar uma. Também não tem FAST_READ nem contador. Sai de fábrica com formatação NDEF] |
| NTAG213 | ✅ | ✅ | ⚠️ | ✅ | ⚠️ | 144 bytes de memória do usuário. :more[Proteção contra gravação confirmada em etiquetas reais depois da reformulação de setembro de 2026; a proteção contra leitura não foi executada com o código reformulado] |
| NTAG215 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | 504 bytes de memória do usuário. Somente simulador: nenhum NTAG215 foi testado em uma etiqueta real |
| NTAG216 | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | 888 bytes de memória do usuário. :more[Senha e bloqueio confirmados pela última vez em etiquetas reais antes da reformulação de setembro de 2026, por meio de uma ferramenta de testes em um build de depuração] |
| NTAG213 TT | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | 144 bytes de memória do usuário. Somente simulador. :more[O status antiviolação da etiqueta aparece no cartão de informações da etiqueta, no editor de etiquetas, e como preajuste do Console avançado] |
| MIFARE Ultralight EV1 de 48 bytes | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | 48 bytes de memória do usuário. Somente simulador. Sai de fábrica sem formatação: execute Formatar antes de gravar |
| MIFARE Ultralight EV1 de 128 bytes | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | 128 bytes de memória do usuário. Sai de fábrica sem formatação: execute Formatar antes de gravar. :more[Senha e bloqueio confirmados pela última vez em etiquetas reais antes da reformulação de setembro de 2026, por meio de uma ferramenta de testes em um build de depuração] |
| MIFARE Ultralight C | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | 144 bytes de memória do usuário. Protegido por uma chave 3DES de 16 bytes, no modo de duas chaves, com handshake mútuo, e não por uma senha PWD/PACK. :more[A proteção por chave e o bloqueio foram confirmados pela última vez em etiquetas reais antes da reformulação de setembro de 2026, por meio de uma ferramenta de testes em um build de depuração, e não pelo cartão Proteção nem por Operações. Proteger com senha, em Operações, e o cartão Proteção, no editor de etiquetas, configuram a chave como proteção contra gravação. Os dois caminhos conferem o estado de proteção da etiqueta antes de apresentar qualquer coisa, então uma etiqueta que aparece como aberta não recebe chave nenhuma. Sai de fábrica sem formatação: execute Formatar antes de gravar. Não tem GET_VERSION, FAST_READ, READ_CNT nem assinatura de originalidade (o contador de 16 bits dele fica na página 29h e é lido com um READ comum, então o recurso de contador do app não se aplica). Um despejo de memória para na página 2Bh, porque o chip não decodifica leituras das páginas da chave] |
| NTAG210 / NTAG212 | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | O app não informa o modelo: o cartão de informações da etiqueta mostra o que o chip informou sobre si mesmo em vez de um palpite. :more[Preferimos dizer que não sabemos a usar o mapa de páginas errado. Um chip não reconhecido fica limitado a leitura NDEF, gravação NDEF e comandos brutos, então são recusadas a proteção por senha e as operações Bloqueio permanente, Despejo de memória e Formatar, e as gravações passam pelo gravador NDEF do próprio iOS em vez do gravador de páginas do app. O gravador do iOS é o caminho que o app deixou de usar nas etiquetas Type 2 reconhecidas, porque ele falha em etiquetas pré-formatadas com um Lock Control TLV, então uma gravação em um desses chips pode falhar se a etiqueta tiver esse TLV.] Não testado em etiquetas reais |
| NTAG213F / NTAG216F | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | Como acima. As variantes com detecção de campo ficam sem reconhecimento até serem verificadas em chips reais |
| EM Microelectronic V10 / V11 / V16 | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | O app tem perfis para os três, mas a identificação de produção nunca os seleciona, então uma etiqueta EM real fica sem reconhecimento e recebe o mesmo tratamento que o NTAG210 acima. :more[Nem é certo que se chegue a esse ponto: se a etiqueta recusar o GET_VERSION, o app faz polling de novo para despertá-la e depois lê a página 28h, além do fim de um chip de 16 páginas, e uma etiqueta que recusa essa leitura para de responder pelo resto da aproximação. Nenhuma etiqueta EM real foi testada, e os simuladores EM usam valores de byte que eles mesmos definem, e não valores de folha de dados. As cadeias de personalização dos três estão no Console avançado; o tamanho do Capability Container que elas gravam vem do layout de memória que o app tem para o chip, e não de uma folha de dados] |
| MIFARE Classic 1K/4K | ❌ | ❌ | — | ❌ | ❌ | O iOS não expõe o MIFARE Classic aos apps (não há acesso ao CRYPTO1), então a etiqueta não pode ser lida em nenhum iPhone. :more[Se o iOS entregar a etiqueta e a conexão falhar, o app diz que ela parece ser MIFARE Classic; se, em vez disso, a leitura atingir o tempo limite, a mensagem de tempo esgotado aponta o MIFARE Classic como causa provável] |

Nos chips Type 2, **Senha** é o esquema do NTAG21x (um PWD de 4 bytes e um
PACK de 2 bytes, mais um limite de página AUTH0 e o bit PROT), que tanto
Proteger com senha, em Operações, quanto o cartão Proteção, no editor de
etiquetas, configuram, para proteger só as gravações ou as leituras e as
gravações. O app só reconhece uma proteção contra leitura quando ela começa
na página 4, que é onde Operações sempre a inicia e onde o cartão Proteção a
inicia, a menos que uma página inicial personalizada seja definida. Ele
detecta a proteção contra leitura pela forma como responde uma leitura das
páginas 3 a 6, então uma proteção contra leitura que comece em qualquer outra
página da memória do chip, definida com a página inicial personalizada do
cartão Proteção, deixa o app sem conseguir desbloqueá-la ou removê-la.
**Bloqueio** é a gravação irreversível dos bytes de bloqueio estáticos e
dinâmicos (Bloqueio permanente). **Despejo de memória** é Operações >
Despejo de memória, que só funciona em chips Type 2 e salva em um arquivo
`.bin` todas as páginas que o chip aceita decodificar. No MIFARE Ultralight
C, **Senha** é o esquema 3DES do próprio chip: uma chave de 16 bytes
programada nas páginas 2Ch a 2Fh, com a proteção delimitada pelo AUTH0, que
Proteger com senha, em Operações, e o cartão Proteção, no editor de
etiquetas, configuram apenas como proteção contra gravação. Uma proteção contra
leitura nesse chip cobriria as páginas que o app lê para reconhecê-lo, então
o app não oferece essa opção. A chave pode ser gerada, colada ou derivada de
uma frase secreta.

## Type 5 (ISO 15693)

**A proteção por senha do SLIX2 passa pelo modo Selected do ISO 15693.**
Definir uma senha no SLIX2 exige `SET_PASSWORD`, que o chip só aceita no
modo Addressed ou Selected: sem endereçamento, a etiqueta ignora o comando
sem avisar, e o daemon NFC recusa uma flag Address explícita antes da
transmissão, tanto pelo `customCommand` quanto pela API bruta `sendRequest`.
O caminho que funciona (confirmado em chip real em 7 de agosto de 2026) é o
modo Selected: `NFCISO15693Tag.select(requestFlags:)` coloca a etiqueta no
estado Selected, e depois disso os comandos de senha são enviados com a flag
Select e sem UID. O ciclo completo (proteger uma etiqueta, verificar que a
proteção é aplicada de fato e depois removê-la) foi validado em hardware em
agosto de 2026. Desde então, a sequência de proteção e remoção foi
reformulada, e a versão reformulada ainda não foi executada em uma etiqueta
real.

| Chip | Leitura | Gravação | Senha | Bloqueio | Despejo de memória | Notas |
|---|---|---|---|---|---|---|
| NXP ICODE SLIX2 | ✅ | ✅ | ⚠️ | ⚠️ | ❌ | Sai de fábrica sem formatação: execute Formatar antes de gravar. :more[Somente senha de gravação, pelo modo Selected (veja acima), confirmada pela última vez em etiquetas reais antes da reformulação de setembro de 2026, por meio de uma ferramenta de testes em um build de depuração, e não pelo cartão Proteção. Ela é definida por Proteger com senha, em Operações, ou pelo cartão Proteção. Os dois caminhos conferem o estado de proteção da etiqueta antes de apresentar qualquer coisa, então uma etiqueta que aparece como aberta não recebe senha nenhuma. Reconhecido pela memória de 80 blocos. Em uma sessão em que a etiqueta não responde ao Get System Information, ela é tratada como um SLIX de 28 blocos: a proteção não é oferecida, Formatar grava um Capability Container para 28 blocos e Bloqueio permanente bloqueia apenas os blocos 0 a 27 e mesmo assim informa sucesso] |
| NXP ICODE SLIX (28 blocos) | ⚠️ | ⚠️ | ❌ | ⚠️ | ❌ | Sai de fábrica sem formatação: execute Formatar antes de gravar. :more[Toda etiqueta ISO 15693 da NXP que não informa 80 blocos recebe este perfil, seja qual for o tamanho dela. Um ICODE de 28 blocos não pode ser diferenciado de SLI, SLIX-S ou SLIX-L, então o app não oferece proteção a nenhum deles.] Somente simulador, exceto a identificação em um SLIX real |
| ST M24LR | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | Recebe o perfil ISO 15693 genérico, como toda etiqueta ISO 15693 que não é da NXP. Não testado: nenhuma etiqueta real e nenhum simulador |

Nos chips ICODE, **Senha** é a senha de gravação do SLIX2, definida por
Proteger com senha, em Operações, ou pelo cartão Proteção no editor de
etiquetas. As leituras continuam abertas: uma proteção contra leitura
no SLIX2 é o modo de privacidade, e uma etiqueta em modo de privacidade não
responde a nenhum inventário, então um iPhone nunca conseguiria encontrá-la
de novo para remover a proteção. **Bloqueio** é `LOCK_BLOCK` em cada bloco
da geometria que o app identificou naquela sessão (a quantidade de blocos
que a etiqueta informou, ou 28 blocos quando ela não respondeu ao Get System
Information), pulando os blocos que já estão bloqueados e, no SLIX2, o bloco
do contador, que o chip não bloqueia. A operação Despejo de memória não
funciona em etiquetas ISO 15693.

## Type 3 (FeliCa)

| Chip | Leitura | Gravação | Notas |
|---|---|---|---|
| FeliCa Lite-S | ❌ | ❌ | O app declara apenas o código de sistema `0003`, e um Lite-S responde a `88B4`, então o iOS nunca deveria entregar um Lite-S ao app. Não testado: nenhuma etiqueta Lite-S foi experimentada |
| Suica / PASMO / ICOCA e o resto da família `0003` | ✅ | ❌ | Somente leitura: saldo e as 20 transações mais recentes, exibidos em uma tela de transporte que não oferece gravação. Confirmado em cartões Suica e PASMO reais |
| iD / QUICPay | — | — | Serviços de pagamento para os quais o app não tem leitor; fora do escopo |

## Type 4 (ISO 14443-4)

| Chip | Leitura | Gravação | Senha | Bloqueio | Despejo de memória | Notas |
|---|---|---|---|---|---|---|
| NTAG424 DNA | ✅ | ✅ | ⚠️ | ❌ | ❌ | Proteção por chave confirmada pela última vez em etiquetas reais antes da reformulação de setembro de 2026. :more[Sem bloqueio permanente e sem despejo de memória: o chip guarda os dados em arquivos endereçados por APDU, e não em páginas] |
| MIFARE DESFire EV3 | ✅ | ✅ | ❌ | ❌ | ❌ | Leitura e Gravação dependem do cartão, e não do modelo do chip (`ChipProfile.ndefDependsOnCard`). :more[O app pergunta ao cartão qual é o estado NDEF dele (`ConnectedTag.queryNDEFAccess()`, com a resposta em um `NDEFAccess`), e `TagCapability.resolved(declared:chip:ndefAccess:)` concede Leitura e Gravação a um cartão configurado como etiqueta NFC Forum Type 4, apenas Leitura quando a aplicação NDEF dele é somente leitura, e nenhuma das duas a um cartão no estado de fábrica ou a um cartão de transporte. A operação Formatar, descrita em [Formatar uma etiqueta](../guide/erase-or-format.md#format-a-tag), configura um cartão em branco (sem nenhuma aplicação, e que permite criar aplicações sem a chave mestra) criando a NDEF Tag Application da nota de aplicação AN11004 da NXP: um arquivo Capability Container e depois um arquivo NDEF de até 4 KB, dimensionado pela memória livre medida no cartão. O Capability Container é gravado por último, e o resultado é relido com comandos ISO (`DESFireNDEFDriver.setUp()`, chamado a partir de `OperationsFlowModel.setUpDESFireNDEFApplication`). Depois da configuração, o iOS lê o cartão e grava nele pelo próprio leitor NDEF. A operação Remover configuração NDEF, descrita em [Remover a configuração NDEF de um cartão](../guide/erase-or-format.md#remove-ndef-setup), deixa em branco de novo um cartão com a estrutura NDEF deste app, seja qual for o conteúdo do Capability Container dele: ela se autentica uma vez com a chave mestra DES de fábrica (AuthenticateISO) e envia FormatPICC, e só faz isso em um cartão cuja única aplicação tem a estrutura deste app e cuja chave mestra é DES na versão 00 (`DESFireNDEFDriver.remove()` e `checkRemovable()`). A configuração é reconhecida como deste app pela estrutura do cartão (a aplicação, as configurações de chave e os arquivos dele), e não por quem o configurou (`DESFireNDEFState`, obtido de `readState()`). Antes de gravar qualquer coisa, a operação Formatar recusa um cartão que tenha qualquer outra aplicação, como um cartão de transporte ou de acesso; um cartão que exige a chave mestra para criar novas aplicações; e uma configuração NDEF feita por outra ferramenta, inclusive uma com a estrutura deste app mas com outro Capability Container. A operação Remover configuração NDEF recusa um cartão que tenha qualquer outra aplicação ou uma aplicação NDEF com estrutura diferente da deste app, e informa que um cartão sem nenhuma aplicação já está em branco. A identificação continua informando a geração e o tamanho de armazenamento, e os comandos brutos seguem disponíveis no Console avançado. Confirmado em cartões EV3 4K reais: configuração, uma mensagem NDEF gravada e relida, apagamento, remoção com toda a memória devolvida, nova configuração e a recusa de um cartão de transporte usando apenas quadros de leitura] |
| MIFARE DESFire EV1 / EV2 | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | :more[Leitura e Gravação seguem o estado NDEF do cartão, como no EV3, e as operações Formatar e Remover configuração NDEF aceitam as duas gerações com a mesma sequência (`Type4Variant.isDESFire`, `ConnectedTag.desfireNDEFDriver`). Essa sequência ainda não foi executada em nenhuma das duas gerações, nem em um cartão real nem em um simulador: o único simulador de DESFire, `DESFireEV3Simulator`, modela um EV3.] Identificação e comandos brutos como no EV3 |
| MIFARE DESFire D40 e outras gerações | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | O nome exibido é “MIFARE DESFire”. :more[`ChipCatalog.identify(desFireVersion:)` atribui o perfil genérico `ChipCatalog.genericMifareDESFire` (`Type4Variant.desfireGeneric`) a um cartão cuja versão principal de hardware informada pelo GET_VERSION não é 01h (EV1), 12h (EV2) nem 33h (EV3), como o D40 original. Um cartão cujo GET_VERSION se perde no transporte duas vezes na mesma aproximação recebe o mesmo perfil, seja qual for a geração dele (`MiFareTagIdentifier`, `Type2ProbePolicy`). Leitura e Gravação seguem o estado NDEF do cartão, como no EV3 (`Type4Variant.isDESFire`, `ChipProfile.ndefDependsOnCard`), então um cartão que já tem uma aplicação NDEF pode ser lido e, quando essa aplicação permite, também gravado. As operações Formatar e Remover configuração NDEF recusam o cartão antes de enviar qualquer coisa que o altere, com “Isso só funciona com cartões MIFARE DESFire EV1, EV2 e EV3.” (`ConnectedTag.desfireNDEFDriver` é nil, então quem responde é `OperationsFlowModel.unsupportedGeneration`). Os comandos brutos seguem disponíveis no Console avançado.] Ainda sem suporte e não testado: nenhum cartão D40 foi experimentado e nenhum simulador modela um |
| Outras etiquetas NFC Forum Type 4 (de fabricantes que não são a NXP, ou um celular Android que emula uma etiqueta) | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | O nome exibido é “NFC Forum Type 4” (`ChipCatalog.genericType4`). :more[O iOS só entrega essas etiquetas ao app porque o app declara o AID da aplicação NDEF do NFC Forum (`D2760000850101`) depois do AID do eMRTD. O app lê o começo da mensagem NDEF com SELECT e READ BINARY simples (`Type4NDEFProbe`) e depois pede GET_VERSION, para que um NTAG424 DNA ou um DESFire que chegue por esse caminho continue sendo reconhecido (`ChipCatalog.identify(type4Version:)`). Qualquer outra mantém o perfil genérico: leitura NDEF, gravação NDEF pelo próprio suporte NDEF do iOS e comandos brutos, sem layout de memória nem fabricante. Confirmado em outubro de 2026 em um celular Android que emulava uma etiqueta Type 4 (leitura, gravação e releitura). Nenhuma etiqueta física de outro fabricante que não a NXP foi testada] |
| Dispositivos de saúde NFC (NFC Forum PHDC, como a NovoPen 6 e a NovoPen Echo Plus) | ❌ | ❌ | — | ❌ | ❌ | O nome exibido é “Dispositivo de saúde”. :more[Reconhecidos por um registro PHD no começo da mensagem NDEF (`PHDAssociation`), com o fabricante nomeado pelo OUI quando o app o conhece (`HealthDeviceMaker`). Só essa solicitação de associação é lida, nunca medições nem o histórico de doses. Gravações, Apagar e comandos do console são recusados antes do envio de qualquer quadro (`refuseIfHealthDevice`), mesmo com Pular a identificação ativado, e a leitura nunca é salva no Histórico. Confirmado em outubro de 2026 em um celular Android que servia uma mensagem publicada de uma NovoPen 6. Nenhuma caneta real foi testada] |

No NTAG424 DNA, **Senha** é a autenticação AES-128 do próprio chip, e não o
esquema PWD/PACK do Type 2: Proteger com senha, em Operações, e o cartão
Proteção, no editor de etiquetas, recebem uma chave de 16 bytes, e qualquer um
dos dois pode proteger as leituras além das gravações. O cartão Proteção
aplica a chave na próxima gravação.

## Confiabilidade do hardware

O Hex NFC exige o iOS 17, então não funciona no iPhone X nem em modelos
anteriores. Nenhuma geração de iPhone foi testada em comparação com outra,
então não há números de confiabilidade por modelo para publicar.

O código trata o ISO 15693 como um transporte pouco confiável: a
identificação recorre ao perfil do catálogo quando uma etiqueta não responde
ao Get System Information, e o bloqueio permanente confere o status de
segurança de um bloco antes de acreditar em uma resposta de erro. Quando uma
leitura falha, a tela de leitura informa isso e oferece uma nova tentativa.
