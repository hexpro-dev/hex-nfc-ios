---
title: Arquitetura
description: Como o pacote Swift do Hex NFC se divide em targets e quais convenções todos os targets seguem.
audience: developer
tags:
  - architecture
---

Um panorama de como está organizado o Hex NFC, um app SwiftUI para iPhone
com iOS 17 ou posterior. Para os detalhes do dia a dia, leia o
[código-fonte](https://github.com/hexpro-dev/hex-nfc-ios).

## Grafo de módulos

```text
HexNFCApp ─┬─> HexNFCDesign  ──> HexNFCShaders
           ├─> HexNFCStorage ──> HexNFCRecords
           ├─> HexNFCKit     ──> HexNFCRecords
           ├─> HexPromoKit   (vendored, product-less)
           └─> HexNFCTestKit ──> HexNFCKit, HexNFCRecords
HexNFCTagSim ──> HexNFCKit  (test-only)
```

### `HexNFCRecords`

Tipos de valor e seus codecs. O enum `NDEFRecord` tem 18 casos, que cobrem
todos os tipos de registro que o app consegue ler ou gravar: Texto, URI, Link
de app, Social (22 plataformas), Busca, Arquivo, E-mail, vCard, Telefone, SMS,
FaceTime, Mapa, Cripto, handover Bluetooth, Wi-Fi WPS, Dados (um tipo MIME e
um payload bruto), Atalho e Bruto. O target também contém os modelos e os
decodificadores dos grupos de dados do passaporte e do histórico de transporte
do Suica, além de `StationDirectory`, que carrega os dados de estações e
linhas incluídos no app, usados por `TransitReader` para dar nome às
estações.

`NDEFCodec` faz a conversão de ida e volta entre `[NDEFRecord]`, o
`[NDEFPayload]` do nível de transmissão e os bytes brutos da mensagem; só o
`HexNFCKit` faz a ponte entre `NDEFPayload` e o CoreNFC. A tabela de prefixos
de URI (os 36 códigos identificadores de URI do NDEF, de `0x00` a `0x23`, em
que `0x00` significa sem prefixo) fica aqui, junto com uma busca reversa pela
correspondência do prefixo mais longo.

### `HexNFCKit`

A abstração de NFC. `TagSession` é o protocolo que o código de produção
conecta a `CoreNFCSession` (que encapsula `NFCTagReaderSession`) e que os
testes unitários conectam a `SimulatedSession`. Os testes de UI abrem o app
com `--useSimulatedNFC`, que coloca no lugar `MockTagSession`, um substituto
em `HexNFCKit` que devolve registros prontos e não tem modelo de chip. A
verificação do argumento de inicialização não fica atrás de `#if DEBUG`, então
o mock também é compilado nos builds de produção. `ConnectedTag` expõe as
capacidades do chip como um conjunto de opções `TagCapability`. Em uma
aproximação real, uma etiqueta que a sessão não conseguiu identificar recebe
leitura NDEF, gravação NDEF e transceive bruto. `permanentLock()` e os
comandos de senha do Type 2 são implementados uma única vez, em uma extensão
de `ConnectedTag`, e lançam `TagError.capabilityUnsupported` antes de enviar
qualquer quadro quando o chip não tem a capacidade. A etiqueta de produção,
`CoreNFCConnectedTag`, aplica a mesma verificação às leituras e gravações de
memória. O `transceive` bruto não passa por essa verificação.

`TagIdentifier` escolhe uma sondagem para cada tipo de etiqueta do CoreNFC, e
`ChipCatalog` decodifica o que a sondagem lê em um `ChipProfile` com a
família, as capacidades e o layout de memória do chip. NTAG213, NTAG215,
NTAG216, NTAG213 TT, NTAG 210µ e MIFARE Ultralight EV1 são identificados pelo
`GET_VERSION`. NTAG210, NTAG212, NTAG213F e NTAG216F também respondem ao
`GET_VERSION`, mas o decodificador os deixa sem identificação de propósito,
porque os mapas de memória deles não foram conferidos em chips reais. O
NTAG424 DNA é identificado pela APDU `GET_VERSION` encapsulada. Esse
decodificador confere apenas os bytes de fabricante e de tipo de hardware,
então qualquer chip NXP que informe o tipo de hardware NTAG 4xx é identificado
como NTAG424 DNA e recebe o perfil desse chip. O DESFire é identificado pelo
seu quadro `GET_VERSION` nativo. Uma etiqueta que o iOS entrega pela aplicação
NDEF do NFC Forum (`D2760000850101`, declarada depois do AID do eMRTD) é lida
primeiro com comandos SELECT e READ BINARY simples (`Type4NDEFProbe`). Uma
mensagem que começa com um registro PHD é um dispositivo de saúde NFC:
`PHDAssociation` analisa a solicitação de associação dele, `HealthDeviceMaker`
nomeia o fabricante pelo OUI e o perfil leva apenas `.personalHealthDevice`,
então gravações, Apagar e comandos do console são recusados antes do envio de
qualquer quadro. Qualquer outra etiqueta recebe um pedido de `GET_VERSION`, que
reconhece um NTAG424 DNA ou um DESFire que chegue por esse caminho
(`identify(type4Version:)`), e o restante recebe o perfil genérico
`genericType4`: leitura NDEF, gravação NDEF e comandos brutos.
O MIFARE Ultralight C recusa o `GET_VERSION`, o que paralisa a etiqueta, então
a sessão reinicia o polling e reconhece o chip por uma leitura das páginas 0 e
28h. As etiquetas ISO 15693 são resolvidas pelo código do fabricante do CI
mais o Get System Information: um chip NXP vira ICODE SLIX, ou SLIX2 quando
informa 80 blocos, e qualquer outro fabricante recebe um perfil ISO 15693
genérico. Os passaportes são reconhecidos pela seleção da aplicação eMRTD. Os
cartões FeliCa recebem um perfil genérico, com a leitura de transporte
acrescentada para o código de sistema `0003`.
O `ChipCatalog` também tem perfis e um decodificador
(`identify(emSignature:)`) para EM Microelectronic V10, V11 e V16, mas nada na
sessão de produção chama esse decodificador, então o app não identifica um
chip EM em uma aproximação real. Os bytes da página 0 que ele compara
(`E0 10`, `E0 11` e `E0 16`) são valores que os simuladores EM definem por
conta própria, e não valores lidos de chips EM reais.

Os comandos integrados do Console avançado ficam em `CommandPresetCatalog`,
cada um marcado com a família para a qual foi feito. Há preajustes para chips
Type 2 (entre eles os chips EM), NTAG424 DNA e ICODE SLIX, e nenhum para
DESFire, FeliCa ou passaportes. Os preajustes EM não foram testados em chips
reais: o comando de modo criptográfico do V10 e as leituras de status
antiviolação usam os valores que os simuladores definem, e cada cadeia de
personalização EM grava um Capability Container cujo byte de tamanho vem do
layout de memória em `ChipCatalog`, e não de uma folha de dados. O console
lista todos os preajustes e executa o que estiver carregado sem conferir a
família da etiqueta, então nada impede que um preajuste EM seja enviado a uma
etiqueta que não é um chip EM.

O target também contém o driver de proteção de cada família que tem um, o
`DESFireNDEFDriver`, que cria e remove a aplicação NDEF em um MIFARE DESFire
EV1, EV2 ou EV3 vazio e comprova pela própria estrutura do cartão se uma
configuração é deste app, o `TransitReader` do FeliCa e o leitor de
passaportes, que é somente leitura. O
`EPassportReader` executa o PACE quando o `EF.CardAccess` do documento anuncia
uma configuração compatível, e o BAC nos demais casos. Se um PACE anunciado
falhar, a leitura falha; ela não tenta de novo com BAC. Quando consegue ler o
objeto de segurança do chip (`EF.SOD`), ele calcula o hash de cada grupo de
dados lido e compara o resultado com a lista de hashes desse objeto, e a tela
de resultado marca os dados como “Provavelmente intacto” ou “Provavelmente
alterado”. Se não houver objeto de segurança legível, ou se ele não listar
nenhum dos grupos de dados lidos, a tela não mostra nenhum rótulo de
integridade. O leitor não verifica a assinatura nem a cadeia de certificados
do objeto de segurança, então isto não é Passive Authentication: um objeto de
segurança regravado para coincidir com dados alterados passa na verificação,
e nada do que o app faz estabelece que um passaporte é autêntico.

### `HexNFCStorage`

Stack do SwiftData (`SwiftDataStack`) para três modelos:
- `Preset`: imagens de etiqueta com nome (uma lista de registros e requisitos
  de capacidade opcionais).
- `HistoryEntry`: o registro de uma leitura, gravado pelo fluxo de leitura
  depois de cada leitura bem-sucedida de etiqueta ou de cartão de transporte e
  nunca para um passaporte ou um dispositivo de saúde. A repetição de uma leitura idêntica atualiza o
  horário da linha existente em vez de acrescentar outra. As entradas não
  fixadas além das 50 mais recentes são removidas depois de cada inserção, e
  as entradas não fixadas com mais de 90 dias são apagadas na inicialização.
- `SavedCommandPreset`: a forma armazenada do `CommandPreset` do HexNFCKit,
  pensada para comandos do console salvos pelo usuário. Ele está no schema,
  mas nada no app o lê ou grava ainda, e o Console avançado lista apenas os
  preajustes integrados.

O espelhamento no banco de dados privado do iCloud é uma única flag de
configuração por trás do botão de ativação nos Ajustes do app (desativado por
padrão). A flag é lida quando o armazenamento é aberto, na inicialização,
então uma mudança só vale na próxima vez que o app for iniciado. Se nesse
momento não for possível abrir o armazenamento com espelhamento, o app o abre
sem espelhamento e os Ajustes informam que a sincronização não está ativa. Os
segredos de proteção nunca vão para o SwiftData:
`KeychainProtectionCredentialStore` (indexado pelo preajuste) e
`KeychainTagCredentialStore` (indexado pelo UID da etiqueta) os guardam no
Chaveiro como itens `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, que não
sincronizam.

### `HexNFCShaders`

Shaders Metal e padrões do CoreHaptics para os momentos marcantes de leitura,
gravação e console. Os shaders são arquivos de código-fonte `.metal`
compilados pela toolchain Metal do SPM; os padrões hápticos são JSON `.ahap`.
O modificador SwiftUI `.hexHero(...)` toca o padrão háptico de um dado
momento. A metade visual de cada um desses momentos é um modificador separado
(`hexScanReveal`, `hexWriteBurst`, `hexConsolePulse`) que a tela aplica com o
mesmo gatilho.

### `HexNFCDesign`

Tokens de design (`HexTokens`), predefinições de animação, a `HexTransition`
característica (o logotipo hexagonal desenhado como três fatias, que entram
animadas com uma mola escalonada quando o `state` dela muda de `.hidden` para
`.present`; todos os lugares do app que a usam passam `.present`, então o
escalonamento nunca é exibido) e componentes primitivos: `HexCard`,
`HexButton`, `HexField`, `HexBadge`, `HexRecordRow` e `HexConsole`.

### `HexNFCApp`

As telas SwiftUI e os modelos de fluxo, compilados como biblioteca. O shell do
app no Xcode (`HexNFC.xcodeproj`), que contém os entitlements e o
`Info.plist`, cria o `AppModel` e exibe o `RootView`. Modelos `@Observable`
por fluxo (`ScanFlowModel`, `EditFlowModel` etc.) controlam as telas. O
`RootView` mantém um único `NavigationStack` em volta do `HomeView` e
apresenta cada fluxo como um painel. O ciclo que vai da leitura à edição e à
gravação é uma cadeia de painéis (`ScanSheet`, depois `TagEditorSheet`, que
apresenta `WriteSheet`), então a pilha raiz nunca é desempilhada entre os
passos. Entre as telas está `RecordEditorSheet`, que é polimórfico conforme o
tipo de registro.

O target também contém três clientes HTTP próprios. O `CostsClient` busca o
valor dos custos de desenvolvimento exibido na tela inicial do Hex NFC quando a view raiz
aparece, sem nenhuma ação do usuário. O `StationSubmissionClient` só é
executado quando o usuário envia um nome para uma estação de transporte que os
dados incluídos no app não conseguem nomear, e envia esse nome com os códigos
de linha, estação e região da estação e o código de sistema do cartão. Ele não
envia o IDm, o saldo nem o histórico do cartão. O `FeedbackClient` só é
executado quando o usuário toca em Enviar no formulário de feedback, e envia
para `api.hex.pro` a mensagem digitada, um endereço opcional para resposta e a
versão do app, a versão do iOS, o modelo do dispositivo e o idioma do app que o
formulário exibe. Ele não envia nada lido de uma etiqueta nem nada do
Histórico.

A chave do passaporte também pode vir da câmera. O `MRZCameraView` passa os
quadros para o reconhecimento de texto do Vision no dispositivo, o
`MRZLineReader`, no `HexNFCRecords`, transforma as linhas reconhecidas em chaves
candidatas, e o `MRZScanConsensus` faz uma votação entre quadros antes de fixar
uma. Nenhum quadro é armazenado.

### `HexPromoKit`

O cliente por trás do banner de promoção cruzada da tela inicial do Hex NFC. O
`PromoManager` busca a promoção ativa na API de promoções da Hex Pro e a
guarda em cache no disco, junto com a mídia dela; o `HexNFCApp` desenha o
banner por conta própria. O target é copiado sem alterações locais do SDK de
promoções da própria Hex Pro, e um arquivo de procedência ao lado do
código-fonte registra o commit fixado e um hash de cada arquivo. O pacote não
declara nenhum produto para ele, porque o `HexNFCApp` é o único consumidor
dele.

### `HexNFCTestKit`

Planos de teste independentes de sessão e um executor que acionam tanto o
hardware NFC real quanto os simuladores por um único caminho de código. É um
target de biblioteca de verdade, vinculado ao app, mas todo arquivo do
`HexNFCApp` que o importa só é compilado sob `#if DEBUG`, onde uma ferramenta
de testes de hardware dentro do app executa os planos em etiquetas reais. Um
XCTest headless (`TestKitPlanTests`) executa os mesmos planos em todos os
simuladores que têm perfil de chip. O desvio de um simulador em relação ao
chip real aparece quando um passo ao vivo falha onde o simulador
correspondente passa, então esse desvio só é detectado quando alguém executa a
ferramenta de testes em etiquetas reais. Os builds de produção vinculam o
target, mas não têm nenhuma tela que chegue até ele.

### `HexNFCTagSim` (somente testes)

Simuladores de chip em processo para NTAG 210µ, NTAG213/215/216, NTAG213 TT,
NTAG424 DNA, MIFARE Ultralight C, MIFARE Ultralight EV1 (48 e 128 bytes),
MIFARE DESFire EV3, ICODE SLIX e SLIX2 (um único simulador ISO 15693 com 28 ou
80 blocos), EM Microelectronic V10/V11/V16, Suica, um passaporte eletrônico
(eMRTD), uma etiqueta NFC Forum Type 4 de outro fabricante que não a NXP e um
dispositivo de saúde NFC (`Type4NDEFSimulator`, `PHDCDeviceSimulator`), e um
fallback para Type 2 não reconhecido. Cada um é uma classe que
adota `ChipSimulator`, cuja superfície de transceive bruto é
`func handle(command: Data) -> Data`. Os simuladores são tipos de referência,
para que as mutações provocadas por um teste (contadores, limites de
tentativas, bytes de bloqueio) fiquem visíveis para o teste que os criou. Os
targets de teste injetam um deles via `SimulatedSession(chip:)`. Uma etiqueta
simulada recebe o perfil de chip do seu simulador, e não da identificação,
então, em um teste, todo simulador com perfil aparece como identificado,
inclusive os simuladores EM, embora o app não reconheça um chip EM em uma
aproximação real. Os simuladores EM Microelectronic usam valores de byte que
eles mesmos definem, e não valores de folha de dados, para o identificador na
página 0, para a página de status antiviolação de cada variante e para a
resposta de modo criptográfico do V10, porque o conjunto completo de comandos
desses chips não é público. Eles também respondem ao `GET_VERSION` com oito
bytes zero, enquanto o conjunto de comandos publicado do chip EM mais próximo
não tem nenhum `GET_VERSION`. Nenhum chip EM foi testado em hardware, então um
teste de simulador EM que passa não é evidência sobre chips EM reais.

## Convenções

- Todo acesso ao CoreNFC fica dentro do `HexNFCKit`. Nenhum outro target
  importa `CoreNFC`.
- As cores da marca são tokens (`HexTokens.Color.primary`), nunca literais
  hexadecimais fora de `HexTokens.swift`.
- As strings exibidas ao usuário passam pelo `Localizable.xcstrings`, e as
  strings do `Info.plist` (o nome do app e os pedidos de permissão), pelo
  `InfoPlist.xcstrings`.
- `TagError`, o tipo de erro da camada NFC, contém tanto
  `userMessage: LocalizedStringResource` quanto `diagnostics: String`, para
  que um relatório de bug possa incluir os detalhes do nível de transmissão.
- O único pacote Swift de terceiros é `pointfreeco/swift-snapshot-testing`, e
  só os targets de teste o usam. O `HexPromoKit` é código da própria Hex Pro,
  incorporado ao repositório em vez de baixado. O app também inclui a fonte
  IBM Plex Mono, sob a SIL OFL 1.1.
