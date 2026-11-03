---
title: Modelo de ameaças
description: Contra o que o Hex NFC se protege no tratamento de dados de etiquetas, operações destrutivas e dependências, e o que fica fora do escopo.
audience: developer
tags:
  - security
---

O Hex NFC é uma ferramenta que lê, grava e modifica etiquetas NFC. Este
documento enumera contra o que nos protegemos e contra o que não nos
protegemos.

## Dentro do escopo

### Confidencialidade dos dados

- As etiquetas lidas ficam armazenadas no SwiftData, no dispositivo, em um
  armazenamento que o app não exclui dos backups do dispositivo. A
  sincronização com o iCloud do próprio app é opcional e vem desativada por
  padrão. Quando ativada, ela espelha os preajustes e o histórico de leitura
  no banco de dados privado do iCloud do usuário. Uma entrada do histórico de
  leitura contém o UID e os registros da etiqueta e, no caso de um cartão de
  transporte, o IDm, o saldo e as transações.
- Fora a sincronização com o iCloud, o app envia pela rede dados lidos de uma
  etiqueta em um único caso. Quando um cartão de transporte mostra uma
  estação que o app não consegue nomear, o usuário pode digitar o nome e
  tocar em Enviar, o que manda os códigos de linha, estação e região, o
  código de sistema do cartão e o nome digitado para `api.apps.hex.pro`. Essa
  requisição não leva mais nada do cartão: nem o IDm, nem o saldo, nem a
  lista de transações.
- O `PrivacyInfo.xcprivacy` não declara rastreamento nem tipos de dados
  coletados, e nem a sugestão de nome de estação descrita acima nem uma
  mensagem de feedback estão listadas nele. O app faz outras quatro requisições
  de rede, e nenhuma leva nada lido de uma etiqueta: a tela inicial do Hex NFC
  busca um valor de custos de desenvolvimento em `api.apps.hex.pro`, pede a
  `api.p.hex.pro` um banner de outro app da Hex Pro e baixa a imagem ou o vídeo
  que essa resposta indica; e o formulário de feedback, só quando o usuário toca
  em Enviar, envia a `api.hex.pro` a mensagem digitada, um endereço de resposta
  opcional e a versão do app, a versão do iOS, o modelo do dispositivo e o
  idioma do app. Uma requisição de rede que esta página não descreve é um bug
  de segurança.
- Todo comando que o próprio app envia a uma etiqueta, e a resposta da
  etiqueta, também vai para o log do sistema do iPhone (subsistema
  `pro.hex.nfc`, categoria `apdu`), marcado como `.public` para que o sistema
  não o oculte. Isso acontece nos builds de produção, e nenhum ajuste desliga
  esse log. Os quadros que levam uma senha ou uma chave são mascarados, assim
  como o BAC EXTERNAL AUTHENTICATE de um passaporte, o PACE MSE:Set AT dele e
  o último PACE GENERAL AUTHENTICATE, que leva os tokens de autenticação. Os
  passos do PACE GENERAL AUTHENTICATE anteriores a esse são enviados com
  encadeamento de comandos (byte de classe `10`), que a regra de mascaramento
  não reconhece, então o nonce criptografado e os dados trocados no
  mapeamento e no acordo de chaves vão para o log por inteiro. Quem capturar
  a troca de rádio também recebe esses quadros. Todo o resto vai para o log
  por inteiro. Isso inclui o UID de toda etiqueta que o app detecta e o IDm
  de um cartão de transporte; as páginas de configuração que o app lê; os
  primeiros doze bytes da área de dados de uma etiqueta Type 2, que cada
  leitura e cada gravação leem para confirmar que a etiqueta está presente;
  um despejo de memória; todo registro que o app grava em uma etiqueta Type 2
  cujo chip ele identifica; e os blocos dos quais são lidos o saldo e as
  transações de um cartão de transporte. Quando um NTAG424 DNA aceita a chave
  que uma gravação leva, como faz uma etiqueta protegida só contra gravação
  com essa chave, os registros que a gravação envia e os registros que ela
  relê para conferi-los também vão para o log por inteiro.
  Se o arquivo NDEF da etiqueta estiver configurado para comunicação
  criptografada, que é como o app protege uma etiqueta também contra leitura,
  esses quadros são criptografados. Os grupos de dados de um passaporte só
  chegam ao log como os quadros criptografados da sessão de secure messaging
  dele. Os registros que o iOS lê em nome do app não vão para o log, exceto a
  quantidade e o tamanho dos registros em uma etiqueta que o iOS apresenta
  como etiqueta MIFARE: toda etiqueta Type 2, um cartão DESFire e um NTAG424
  DNA quando o iOS o apresenta assim. Qualquer pessoa que consiga ler o log
  do iPhone, em um Mac conectado ou em um sysdiagnose, consegue ler esses
  quadros.
- Os segredos de proteção das etiquetas ficam armazenados apenas no
  Chaveiro, como itens com `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
  que nunca sincronizam nem passam para outro dispositivo. Eles são o PWD de
  4 bytes e o PACK de 2 bytes das etiquetas NTAG21x e Ultralight EV1, a chave
  AES-128 do NTAG424 DNA, a chave 3DES de 16 bytes do MIFARE Ultralight C e a
  senha de gravação de 4 bytes do ICODE SLIX2.
- Dois armazenamentos do Chaveiro guardam esses segredos.
  `KeychainProtectionCredentialStore` guarda o segredo de um preajuste salvo
  com a proteção ativada, indexado pelo preajuste, e apagar o preajuste na
  tela Biblioteca deste iPhone apaga esse segredo.
  `KeychainTagCredentialStore` é indexado pelo UID da etiqueta. Quando uma
  gravação feita pelo cartão Proteção do editor aplica ou remove a proteção,
  ou quando um preajuste protegido gravado a partir da tela Biblioteca a
  aplica, o
  segredo é salvo ali depois que os novos registros são gravados e antes do
  comando que muda a proteção da etiqueta, à frente de quaisquer segredos já
  guardados para essa etiqueta (até quatro no total). Uma falha ao salvar não
  interrompe a gravação. Apagar um preajuste não mexe nessas entradas, e o
  app não tem nenhum controle para remover uma delas: uma entrada só é
  apagada quando uma releitura depois de uma remoção mostra a etiqueta aberta
  e de volta ao segredo padrão de fábrica. Ainda não há código que leia uma
  dessas entradas para desbloquear uma etiqueta. Uma senha digitada na tela
  Operações não é salva em lugar nenhum.
- Somente as *configurações* não secretas (como a página em que a proteção
  começa e, para NTAG21x, Ultralight EV1 e NTAG424 DNA, se ela protege só as
  gravações ou as leituras e as gravações) são salvas com um preajuste,
  sincronizadas ou gravadas em uma exportação `.hexnfc`; o segredo nunca vai
  junto. Um preajuste protegido que chega a outro dispositivo, pela
  sincronização com o iCloud ou por um backup restaurado em um iPhone novo,
  leva as configurações, mas não o segredo. A linha dele na tela Biblioteca
  continua mostrando o cadeado que o marca como um preajuste que aplica
  proteção, mas gravá-lo ali não aplica proteção nenhuma e não mostra nenhum
  aviso. O mesmo acontece neste iPhone com um preajuste salvo com a proteção
  ativada e sem segredo, por exemplo a partir do editor de uma etiqueta
  protegida que foi lida e cuja senha nunca foi digitada ali. O painel Salvar
  como preajuste continua dizendo que o segredo fica armazenado só neste
  dispositivo. O app consegue compartilhar um preajuste como arquivo
  `.hexnfc`, mas não tem como importar um. Duas coisas são gravadas em
  arquivos no diretório temporário do app, e o app não apaga nenhuma delas: o
  arquivo `.hexnfc` de um preajuste compartilhado e o arquivo `.bin` de um
  despejo de memória, que é gravado assim que o despejo termina, seja ele
  compartilhado ou não.
- Um passaporte eletrônico só é lido depois que o usuário informa o número do
  passaporte, a data de nascimento e a data de validade da zona de leitura
  mecânica, digitando esses dados ou escaneando a página da foto com a câmera,
  que lê as linhas impressas no dispositivo e não guarda nenhuma imagem. O app não salva esses dados, nem nada do que lê do passaporte,
  incluindo a imagem do rosto, no histórico de leitura nem em nenhum outro
  armazenamento do app, e não envia nada disso pela rede. O resultado é
  exibido só durante aquela sessão.

### Segurança das operações destrutivas

- Na tela Operações, sete operações exigem que o usuário digite o UID
  completo da etiqueta antes de serem executadas: Apagar, Formatar, Remover
  configuração NDEF, Bloqueio permanente, Limite de tentativas, Proteger com
  senha e Remover senha. Limite de tentativas é só para NTAG21x e Ultralight
  EV1. Proteger com senha e Remover senha cobrem todos os chips que o app
  consegue proteger (NTAG21x, Ultralight EV1, Ultralight C, NTAG424 DNA e
  ICODE SLIX2), e o cartão Proteção, no editor de etiquetas, consegue proteger
  e desproteger os mesmos chips. É uma confirmação digitada, e não um
  Sim/Não: o UID exibido ao lado do campo é o que foi lido na primeira de
  duas aproximações, e uma segunda aproximação que apresente outra etiqueta é
  recusada.
- Remover configuração NDEF envia FormatPICC, que apaga todas as aplicações
  de um cartão MIFARE DESFire. A operação se autentica uma vez por aproximação
  com a chave mestra DES de fábrica publicada, e só depois que essa mesma
  aproximação mostrou que a única aplicação do cartão tem a estrutura NDEF
  deste app e que a chave mestra dele é DES na versão 00. Formatar e Remover
  configuração NDEF recusam um cartão que tenha qualquer outra aplicação, como
  um cartão de transporte ou de acesso, antes de enviar qualquer coisa que o
  altere.
- Uma etiqueta reconhecida como dispositivo de saúde NFC não recebe nenhuma
  gravação, Apagar nem comando do console: o perfil dela leva apenas
  `.personalHealthDevice`, e `refuseIfHealthDevice` recusa gravações NDEF,
  gravações de memória e comandos brutos antes do envio de qualquer quadro. A
  leitura nunca é salva no Histórico.
- Fora da tela Operações, nada em um build de produção tem essa exigência.
  A proteção aplicada ou removida pelo cartão Proteção do editor é executada
  como parte da próxima gravação, assim como a proteção de um preajuste
  gravado a partir da tela Biblioteca; removê-la continua exigindo a senha ou a
  chave atual da etiqueta. Uma gravação comum substitui o conteúdo da
  etiqueta, e uma gravação com todos os registros apagados limpa a etiqueta
  do mesmo jeito que Apagar. O Console avançado envia os comandos brutos que
  o usuário digita ou carrega da lista integrada, inclusive os que bloqueiam
  a memória permanentemente ou regravam páginas de configuração, a uma
  etiqueta por execução, sem confirmação.
- O limite de tentativas (AUTH_LIM) é opcional, e a tela que o define mostra
  um aviso. Aplicar proteção por senha a um NTAG21x ou Ultralight EV1 sempre
  grava um limite de 0 (ilimitado), o que também apaga um limite que a
  etiqueta já tinha. Fora os comandos brutos no Console avançado, um limite
  diferente de zero só é definido na tela Limite de tentativas, em uma
  etiqueta que já está protegida. Um limite de N permite que a etiqueta
  recuse N senhas incorretas. Mais uma senha incorreta e a etiqueta deixa de
  aceitar a senha para sempre, inclusive a correta, então a proteção dela
  nunca mais pode ser removida e a memória que ela protege nunca mais pode
  ser regravada, nem lida de novo se as leituras também estavam protegidas.
  Esse é o comportamento do próprio chip, que deixamos bem visível em vez de
  esconder. Confirmamos essa contagem no NTAG213. A tela Limite de tentativas
  também funciona no NTAG213 TT, no NTAG215, no NTAG216 e no Ultralight EV1,
  em que a contagem não foi testada; as folhas de dados do NTAG215, do
  NTAG216 e do Ultralight EV1 afirmam a mesma regra. A tela Limite de
  tentativas mostra o limite que uma etiqueta já tem quando a configuração da
  etiqueta pode ser lida sem senha, o que exclui uma etiqueta protegida
  contra leitura. O app nunca consegue ler quantas senhas incorretas uma
  etiqueta já recusou, porque nenhum comando desses chips informa isso.
- O bloqueio permanente nunca é uma configuração de preajuste, e o limite de
  tentativas também não: um preajuste gravado a partir da tela Biblioteca
  pode aplicar proteção, mas nunca pode bloquear uma etiqueta permanentemente nem
  definir um limite. Ele coloca, sim, a mesma senha ou chave em todas as
  etiquetas em que é gravado, e o app nunca exibe o segredo que um preajuste
  guardou. Para apagar um preajuste, basta deslizar a linha dele na
  tela Biblioteca, sem confirmação, e o segredo dele não passa para um iPhone
  novo. Com a sincronização com o iCloud ativada, apagar o preajuste em outro
  dispositivo, onde ele não tem segredo, também o remove deste iPhone e deixa
  o segredo dele no Chaveiro deste iPhone, onde nada o lê. Depois que o
  preajuste e qualquer cópia dele são apagados, ou que o usuário passa para
  um iPhone novo, o app não guarda nenhuma cópia que vá apresentar a uma
  etiqueta (as entradas por etiqueta descritas acima continuam no iPhone
  original, mas nada as relê).
  A menos que o usuário tenha guardado o segredo em outro lugar, a memória
  protegida de todas as etiquetas gravadas com esse preajuste nunca mais
  poderá ser regravada.
- O app nunca contorna a autenticação do lado da etiqueta. Se uma etiqueta
  Type 2 recusar o nosso PWD_AUTH, informamos a falha com honestidade e não
  enviamos uma segunda senha naquela aproximação; não tentamos de novo com
  uma lista de palpites. Depois que Proteger com senha ou Remover senha é
  recusado, a tela Operações oferece um botão, **Testar o padrão de
  fábrica**, que testa a senha padrão de fábrica publicada em uma nova
  execução, incluindo a exigência do UID digitado. Nada dá esse passo por
  conta própria, e, em uma etiqueta com limite de tentativas, ele conta como
  tentativa incorreta se a senha padrão de fábrica não for a que a etiqueta
  tem. Proteger com senha, executado em uma etiqueta que já está protegida
  só contra gravação, apresenta a nova senha como se fosse a atual da
  etiqueta, então, em uma etiqueta com limite de tentativas, isso é uma
  tentativa incorreta, a menos que a etiqueta já tenha essa senha. Uma
  gravação que leva uma senha ou uma chave a apresenta antes de gravar
  qualquer coisa. Isso vale para um preajuste com um segredo guardado e para
  uma gravação feita pelo cartão Proteção do editor. Em todos os chips que o
  app consegue proteger, ele lê primeiro o estado de proteção da etiqueta e
  não envia senha nem chave a uma etiqueta que aparece como sem proteção. No cartão Proteção, o valor apresentado é o que
  acabou de ser digitado ali, inclusive uma nova senha que deveria substituir
  a atual da etiqueta, então, em uma etiqueta com limite de tentativas, ele
  conta como tentativa incorreta sempre que a etiqueta tem outra senha. O
  único fallback automático é no NTAG424 DNA: aplicar ou remover a proteção
  recorre a no máximo três chaves em uma sessão (a chave atual fornecida à
  operação, a chave padrão de fábrica publicada, toda em zeros, e, ao
  aplicar, a nova chave). Isso limita as chaves testadas, não as tentativas.
  Uma etiqueta nova de fábrica aparece como sem proteção, então uma gravação
  não envia chave nenhuma a ela antes de gravar. Uma troca de chave que falha
  acrescenta até mais duas tentativas para descobrir qual chave a etiqueta
  tem. Não verificamos se esse chip conta as autenticações que falham.

### Cadeia de suprimentos do build

- O build usa apenas frameworks da Apple e código da própria Hex Pro, além
  de uma dependência só de teste (`pointfreeco/swift-snapshot-testing`):
  nenhum SDK de analytics ou de relatórios de falhas, e nenhuma biblioteca de
  UI de terceiros. Essa dependência é declarada como um intervalo de versões
  a partir da 1.17.0, e o `Package.resolved` não é incluído no repositório,
  então todo checkout novo resolve a versão mais recente desse intervalo. O
  `HexPromoKit` é copiado byte a byte de outro repositório da Hex Pro, em um
  commit fixado. Toda dependência adicional é uma superfície de risco na
  cadeia de suprimentos que não aceitamos.
- O workflow de publicação busca os arquivos de assinatura em modo somente
  leitura, via fastlane Match, em um repositório privado separado. Ele clona
  esse repositório com credenciais guardadas como secrets do GitHub Actions,
  e o Match descriptografa os arquivos com uma frase secreta guardada do
  mesmo jeito. As chaves privadas de assinatura não ficam no repositório do
  app. A toolchain de publicação não é fixada: o workflow instala a versão
  atual do fastlane pelo RubyGems a cada execução e referencia as GitHub
  Actions pela tag de versão principal, e não pelo commit.

## Fora do escopo

- As garantias criptográficas do chip pertencem ao chip, que é uma fronteira
  de confiança de hardware. Usamos a autenticação que o chip oferecer; não
  afirmamos que o nosso app deixa o chip mais seguro do que o próprio hardware
  dele. Uma senha de NTAG21x ou Ultralight EV1 trafega pelo ar em texto claro
  sempre que é apresentada ou gravada. O mesmo vale para uma chave do
  Ultralight C ou uma senha de gravação do ICODE SLIX2 quando ela é gravada
  na etiqueta. Quando uma senha do SLIX2 é apresentada, ela é mascarada
  apenas por um número aleatório de 16 bits que a etiqueta acabou de enviar
  em texto claro. Quem capturar essas trocas obtém o segredo.
- A clonagem não é impedida. Os UIDs do NTAG21x são fixados de forma
  permanente na fábrica, mas o resto da memória pode ser copiado livremente
  para etiquetas em branco. Essa é uma característica de todo o setor, e o
  Hex NFC não finge impedi-la. O cartão de informações da etiqueta mostra
  “Assinatura de originalidade NXP” quando um chip Type 2 devolve uma
  assinatura completa de 32 bytes, mas o app nunca a confere com a chave
  pública da NXP, então essa linha não prova que uma etiqueta é autêntica. A
  linha Recursos lista “Assinatura de originalidade” para qualquer chip
  identificado como um modelo que tem uma, seja o que for que o chip tenha
  devolvido. No NTAG424 DNA, o cartão lista “Espelhamento SUN” entre os
  recursos do chip, mas o app não configura nem confere mensagens SUN.
- A leitura de um passaporte não prova que o documento é autêntico. O app
  compara os grupos de dados que lê com a lista de hashes do objeto de
  segurança do chip e mostra “Provavelmente intacto” quando eles coincidem,
  mas não verifica a assinatura desse objeto (Passive Authentication) e não
  executa nem Active Authentication nem Chip Authentication, as verificações
  que detectam um chip copiado.
- Qualquer pessoa com acesso físico ao iPhone desbloqueado pode chegar aos
  seus dados de etiquetas, assim como aos dados de qualquer outro app. Ela
  também pode usar as senhas e chaves salvas com os seus preajustes, porque
  gravar um preajuste apresenta o segredo guardado a uma etiqueta que já está
  protegida com ele.
- Uma etiqueta controlada por um adversário pode devolver quaisquer dados em
  resposta às nossas leituras. Analisamos os dados de forma defensiva, mas
  não tratamos a etiqueta como um oráculo confiável para nada além do próprio
  conteúdo dela.

## Relatar vulnerabilidades

Comunique vulnerabilidades de forma privada para
[security@hex.pro](mailto:security@hex.pro), e não em um fórum público.
Confirmamos o recebimento de um relato em até 72 horas e depois trabalhamos
com quem fez o relato em uma correção e em uma data de divulgação pública,
seguindo um prazo de divulgação coordenada de 90 dias.
