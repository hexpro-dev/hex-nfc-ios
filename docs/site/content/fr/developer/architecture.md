---
title: Architecture
description: Comment le package Swift de Hex NFC se répartit en cibles, et les conventions que suit chaque cible.
audience: developer
tags:
  - architecture
---

Ce tour d'horizon présente l'organisation de Hex NFC, une app SwiftUI pour
iPhone sous iOS 17 ou version ultérieure. Pour le détail au quotidien,
reportez-vous au [code source](https://github.com/hexpro-dev/hex-nfc-ios).

## Graphe des modules

```text
HexNFCApp ─┬─> HexNFCDesign  ──> HexNFCShaders
           ├─> HexNFCStorage ──> HexNFCRecords
           ├─> HexNFCKit     ──> HexNFCRecords
           ├─> HexPromoKit   (vendored, product-less)
           └─> HexNFCTestKit ──> HexNFCKit, HexNFCRecords
HexNFCTagSim ──> HexNFCKit  (test-only)
```

### `HexNFCRecords`

Les types valeur et leurs codecs. L'enum `NDEFRecord` compte 18 cas, qui
couvrent chaque type d'enregistrement que l'app sait lire ou écrire : texte,
URI, lien d'app, réseau social (22 plateformes), recherche, fichier, e-mail,
vCard, téléphone, SMS, FaceTime, plan, crypto, handover Bluetooth, Wi-Fi WPS,
données (un type MIME et une charge utile brute), raccourci et brut. La cible
contient aussi les modèles et les décodeurs des groupes de données des
passeports et de l'historique des cartes de transport Suica, ainsi que
`StationDirectory`, qui charge les données de stations et de lignes intégrées
à l'app dont `TransitReader` se sert pour nommer les stations.

`NDEFCodec` fait l'aller-retour entre `[NDEFRecord]`, le `[NDEFPayload]` de
niveau protocolaire et les octets bruts du message ; seul `HexNFCKit` fait le
pont entre `NDEFPayload` et CoreNFC. La table des préfixes d'URI (les 36 codes
d'identifiant d'URI NDEF, de `0x00` à `0x23`, où `0x00` signifie aucun
préfixe) se trouve ici, avec une recherche inverse par correspondance du plus
long préfixe.

### `HexNFCKit`

L'abstraction NFC. `TagSession` est le protocole que le code de production
branche sur `CoreNFCSession` (qui enveloppe `NFCTagReaderSession`) et que les
tests unitaires branchent sur `SimulatedSession`. Les tests d'interface
lancent l'app avec `--useSimulatedNFC`, qui met en place `MockTagSession`, une
doublure située dans `HexNFCKit` qui renvoie des enregistrements prédéfinis et
n'a aucun modèle de puce. La vérification de cet argument de lancement n'est
pas placée derrière `#if DEBUG` : le mock est donc compilé aussi dans les
builds de production. `ConnectedTag` expose les capacités de la puce sous la
forme d'un ensemble d'options `TagCapability`. Lors d'un passage réel, un tag
que la session n'a pas pu identifier reçoit la lecture NDEF, l'écriture NDEF
et le transceive brut. `permanentLock()` et les commandes de mot de passe Type
2 sont écrites une seule fois, dans une extension de `ConnectedTag`, et lèvent
`TagError.capabilityUnsupported` avant d'envoyer la moindre trame lorsque la
puce n'a pas la capacité requise. Le tag de production, `CoreNFCConnectedTag`,
soumet de la même façon les lectures et les écritures mémoire à cette
vérification. Le `transceive` brut n'y est pas soumis.

`TagIdentifier` choisit une sonde pour chaque type de tag CoreNFC, et
`ChipCatalog` décode ce que lit la sonde en un `ChipProfile` qui porte la
famille, les capacités et l'organisation mémoire de la puce. Les NTAG213,
NTAG215, NTAG216, NTAG213 TT, NTAG 210µ et MIFARE Ultralight EV1 sont
identifiés à partir de `GET_VERSION`. Les NTAG210, NTAG212, NTAG213F et
NTAG216F répondent eux aussi à `GET_VERSION`, mais le décodeur les laisse
délibérément non identifiés, car leurs tables mémoire n'ont pas été vérifiées
sur des puces réelles. Le NTAG424 DNA est identifié à partir de l'APDU
`GET_VERSION` encapsulée. Ce décodeur ne vérifie que les octets du fabricant
et du type de matériel : toute puce NXP qui annonce le type de matériel NTAG
4xx est donc identifiée comme un NTAG424 DNA et reçoit le profil de cette
puce. Le DESFire est identifié à partir de sa trame `GET_VERSION` native. Un
tag qu'iOS remet par l'application NDEF du NFC Forum (`D2760000850101`,
déclarée après l'AID eMRTD) est d'abord lu par de simples commandes SELECT et
READ BINARY (`Type4NDEFProbe`). Un message qui commence par un enregistrement
PHD provient d'un appareil de santé NFC : `PHDAssociation` analyse sa demande
d'association, `HealthDeviceMaker` nomme le fabricant d'après son OUI, et le
profil ne porte que `.personalHealthDevice`, si bien que les écritures,
Effacer et les commandes de console sont refusés avant l'envoi de toute trame.
Tout autre tag reçoit une demande `GET_VERSION`, qui reconnaît un NTAG424 DNA
ou un DESFire arrivé par cette voie (`identify(type4Version:)`), et le reste
reçoit le profil générique `genericType4` : lecture NDEF, écriture NDEF et
commandes brutes. Le
MIFARE Ultralight C refuse `GET_VERSION`, ce qui met le tag à l'arrêt : la
session relance donc la détection et reconnaît la puce en lisant les pages 0
et 28h. Les tags ISO 15693 sont résolus à partir du code fabricant du circuit
et de Get System Information : une puce NXP devient un ICODE SLIX, ou un SLIX2
lorsqu'elle annonce 80 blocs, et tout autre fabricant reçoit un profil ISO
15693 générique. Les passeports sont reconnus par la sélection de
l'application eMRTD. Les cartes FeliCa reçoivent un profil générique, auquel
s'ajoute la lecture des cartes de transport pour le code système `0003`.
`ChipCatalog` contient aussi des profils et un décodeur
(`identify(emSignature:)`) pour les EM Microelectronic V10, V11 et V16, mais
rien dans la session de production n'appelle ce décodeur : l'app n'identifie
donc pas une puce EM lors d'un passage réel. Les octets de la page 0 qu'il
compare (`E0 10`, `E0 11` et `E0 16`) sont des valeurs que les simulateurs EM
définissent eux-mêmes, et non des valeurs lues sur des puces EM réelles.

Les commandes intégrées de la console avancée se trouvent dans
`CommandPresetCatalog`, chacune associée à la famille pour laquelle elle est
écrite. Il existe des préréglages pour les puces Type 2 (dont les puces EM),
le NTAG424 DNA et l'ICODE SLIX, et aucun pour le DESFire, le FeliCa ou les
passeports. Les préréglages EM n'ont pas été testés sur des puces réelles : la
commande de mode crypto du V10 et les lectures de l'état d'inviolabilité
utilisent les valeurs que définissent les simulateurs, et chaque chaîne de
personnalisation EM écrit un Capability Container dont l'octet de taille
provient de l'organisation mémoire de `ChipCatalog` plutôt que d'une fiche
technique. La console liste tous les préréglages et exécute ce qui est chargé
sans vérifier la famille du tag : rien n'empêche donc d'envoyer un préréglage
EM à un tag qui n'est pas une puce EM.

La cible contient aussi le pilote de protection de chaque famille qui en a un,
`DESFireNDEFDriver`, qui crée et retire l'application NDEF sur un MIFARE
DESFire EV1, EV2 ou EV3 vierge et prouve d'après la structure même de la carte
si une configuration vient de cette app, le `TransitReader` FeliCa et le
lecteur de passeport en lecture seule.
`EPassportReader` exécute PACE lorsque le `EF.CardAccess` du document annonce
une configuration qu'il prend en charge, et BAC sinon. Si un PACE annoncé
échoue, la lecture échoue ; elle ne retente pas avec BAC. Lorsqu'il peut lire
l'objet de sécurité de la puce (`EF.SOD`), il calcule l'empreinte de chaque
groupe de données lu et compare le résultat avec la liste d'empreintes de cet
objet, et l'écran de résultat affiche pour les données la mention
« Probablement intact » ou « Probablement altéré ». Si aucun objet de sécurité
n'est lisible, ou s'il ne liste aucun des groupes de données lus, l'écran
n'affiche aucune mention d'intégrité. Le lecteur ne vérifie ni la signature de
l'objet de sécurité ni sa chaîne de certificats : il ne s'agit donc pas d'une
Passive Authentication. Un objet de sécurité réécrit pour correspondre à des
données modifiées passe la vérification, et rien de ce que fait l'app
n'établit qu'un passeport est authentique.

### `HexNFCStorage`

La pile SwiftData (`SwiftDataStack`) qui gère trois modèles :
- `Preset` : des images de tag nommées (une liste d'enregistrements et des
  exigences de capacités facultatives).
- `HistoryEntry` : une entrée de l'historique de scan, écrite par le flux de
  scan après chaque lecture réussie d'un tag ou d'une carte de transport, et
  jamais pour un passeport ou un appareil de santé. Un scan identique répété met à jour l'heure de la
  ligne existante au lieu d'en ajouter une. Les entrées non épinglées au-delà
  des 50 plus récentes sont élaguées après chaque insertion, et les entrées
  non épinglées de plus de 90 jours sont supprimées au lancement.
- `SavedCommandPreset` : la forme stockée du `CommandPreset` de HexNFCKit,
  prévue pour les commandes de console enregistrées par l'utilisateur. Il
  figure dans le schéma, mais rien dans l'app ne le lit ni ne l'écrit encore,
  et la console avancée ne liste que les préréglages intégrés.

La réplication dans la base de données privée iCloud tient à un seul
indicateur de configuration, derrière l'interrupteur des Réglages de l'app
(désactivé par défaut). L'indicateur est lu à l'ouverture de la base, au
lancement : une modification prend donc effet au prochain démarrage de l'app.
Si la base ne peut pas alors être ouverte avec la réplication, l'app l'ouvre
sans réplication et les Réglages de l'app indiquent que la synchronisation ne
fonctionne pas. Les secrets de protection ne vont jamais dans SwiftData :
`KeychainProtectionCredentialStore` (indexé par préréglage) et
`KeychainTagCredentialStore` (indexé par UID de tag) les conservent dans le
trousseau sous forme d'éléments
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, qui ne se synchronisent pas.

### `HexNFCShaders`

Les shaders Metal et les motifs CoreHaptics des moments signature du scan, de
l'écriture et de la console. Les shaders sont des fichiers source `.metal`
compilés par la chaîne d'outils Metal de SPM ; les motifs haptiques sont du
JSON `.ahap`. Le modificateur SwiftUI `.hexHero(...)` joue le motif haptique
d'un moment donné. La moitié visuelle de chacun de ces moments est un
modificateur distinct (`hexScanReveal`, `hexWriteBurst`, `hexConsolePulse`)
que l'écran attache au même déclencheur.

### `HexNFCDesign`

Les jetons de design (`HexTokens`), les préréglages d'animation, la
`HexTransition` signature (le logo hexagonal dessiné en trois tranches, qui
apparaissent en cascade avec une animation à ressort lorsque son `state` passe
de `.hidden` à `.present` ; partout où l'app l'utilise, elle passe `.present`,
si bien que la cascade ne se joue jamais) et les composants de base :
`HexCard`, `HexButton`, `HexField`, `HexBadge`, `HexRecordRow` et
`HexConsole`.

### `HexNFCApp`

Les écrans SwiftUI et les modèles de flux, compilés sous forme de
bibliothèque. L'app hôte Xcode (`HexNFC.xcodeproj`), qui porte les
entitlements et `Info.plist`, crée l'`AppModel` et affiche `RootView`. Des
modèles `@Observable` propres à chaque flux (`ScanFlowModel`, `EditFlowModel`,
etc.) pilotent les écrans. `RootView` contient un seul `NavigationStack`
autour de `HomeView` et présente chaque flux sous forme de panneau. La boucle
qui va du scan à la modification puis à l'écriture est une chaîne de panneaux
(`ScanSheet`, puis `TagEditorSheet`, qui présente `WriteSheet`) : la pile
racine n'est donc jamais dépilée entre les étapes. Parmi les écrans figure
`RecordEditorSheet`, polymorphe selon le type d'enregistrement.

La cible contient aussi trois clients HTTP qui lui sont propres. `CostsClient`
récupère le chiffre des coûts de développement affiché sur l'écran d'accueil
de Hex NFC lorsque la vue racine apparaît, sans aucune action de
l'utilisateur. `StationSubmissionClient` ne s'exécute que lorsque
l'utilisateur envoie un nom pour une station de transport que les données
intégrées ne savent pas nommer, et transmet ce nom avec les codes de ligne, de
station et de région de la station et le code système de la carte. Il n'envoie
ni l'IDm de la carte, ni son solde, ni son historique. `FeedbackClient` ne
s'exécute que lorsque l'utilisateur touche Envoyer dans le formulaire de
commentaire, et transmet à `api.hex.pro` le message saisi, une adresse de
réponse facultative et la version de l'app, la version d'iOS, le modèle de
l'appareil et la langue de l'app qu'affiche le formulaire. Il n'envoie rien de
ce qui a été lu sur un tag ni rien de l'historique.

La clé du passeport peut aussi venir de l'appareil photo. `MRZCameraView`
transmet les images à la reconnaissance de texte de Vision sur l'appareil,
`MRZLineReader`, dans `HexNFCRecords`, transforme les lignes reconnues en clés
candidates, et `MRZScanConsensus` vote sur plusieurs images avant d'en retenir
une. Aucune image n'est conservée.

### `HexPromoKit`

Le client de la bannière de promotion croisée de l'écran d'accueil de Hex NFC.
`PromoManager` récupère la promotion active auprès de l'API promo de Hex Pro
et la met en cache sur le disque, avec ses médias ; c'est `HexNFCApp` qui
dessine la bannière. La cible est copiée sans modification locale depuis le
SDK promo de Hex Pro, et un fichier de provenance placé à côté des sources
consigne le commit épinglé et une empreinte de chaque fichier. Le package ne
déclare aucun produit pour elle, car `HexNFCApp` est son seul consommateur.

### `HexNFCTestKit`

Des plans de test indépendants de la session et un exécuteur qui pilotent à la
fois le matériel NFC réel et les simulateurs par un même chemin de code. C'est
une véritable cible de bibliothèque, liée à l'app, mais chaque fichier de
`HexNFCApp` qui l'importe n'est compilé que sous `#if DEBUG`, où un banc de
test matériel intégré à l'app exécute les plans sur des tags réels. Un XCTest
sans interface (`TestKitPlanTests`) exécute les mêmes plans sur chaque
simulateur doté d'un profil de puce. Une étape réelle qui échoue là où son
simulateur réussit révèle la dérive d'un simulateur par rapport à la puce
réelle : une dérive n'est donc détectée que lorsque quelqu'un exécute le banc
de test sur des tags réels. Les builds de production lient la cible, mais
aucun écran n'y donne accès.

### `HexNFCTagSim` (tests uniquement)

Des simulateurs de puces, exécutés dans le processus, pour NTAG 210µ,
NTAG213/215/216, NTAG213 TT, NTAG424 DNA, MIFARE Ultralight C, MIFARE
Ultralight EV1 (48 et 128 octets), MIFARE DESFire EV3, ICODE SLIX et SLIX2 (un
seul simulateur ISO 15693, à 28 ou 80 blocs), EM Microelectronic V10/V11/V16,
Suica, un passeport électronique (eMRTD), un tag NFC Forum Type 4 d'un autre
fabricant que NXP et un appareil de santé NFC (`Type4NDEFSimulator`,
`PHDCDeviceSimulator`), et un Type 2 non reconnu servant de repli. Chacun est une classe conforme à `ChipSimulator`, dont la surface de
transceive brute est `func handle(command: Data) -> Data`. Les simulateurs
sont des types référence, pour que les mutations que pilote un test
(compteurs, limites de tentatives, octets de verrouillage) soient visibles du
test qui les a construits. Les cibles de test en injectent un via
`SimulatedSession(chip:)`. Un tag simulé tient son profil de puce de son
simulateur et non de l'identification : dans un test, chaque simulateur doté
d'un profil apparaît donc comme identifié, simulateurs EM compris, alors que
l'app ne reconnaît pas une puce EM lors d'un passage réel. Les simulateurs EM
Microelectronic utilisent des valeurs d'octets qu'ils définissent eux-mêmes,
et non des valeurs de fiche technique, pour l'identifiant de la page 0, la
page d'état d'inviolabilité de chaque variante et la réponse de mode crypto du
V10, car le jeu de commandes complet de ces puces n'est pas publié. Ils
répondent aussi à `GET_VERSION` par huit octets nuls, alors que le jeu de
commandes publié de la puce EM la plus proche ne comporte aucun `GET_VERSION`.
Aucune puce EM n'a été testée sur du matériel : un test de simulateur EM qui
réussit n'apporte donc aucune preuve sur les puces EM réelles.

## Conventions

- Tout accès à CoreNFC se fait dans `HexNFCKit`. Aucune autre cible n'importe
  `CoreNFC`.
- Les couleurs de la marque sont des jetons (`HexTokens.Color.primary`),
  jamais des littéraux hexadécimaux en dehors de `HexTokens.swift`.
- Les chaînes visibles par l'utilisateur passent par `Localizable.xcstrings`,
  et les chaînes d'`Info.plist` (le nom de l'app et les demandes
  d'autorisation) par `InfoPlist.xcstrings`.
- `TagError`, le type d'erreur de la couche NFC, porte à la fois
  `userMessage: LocalizedStringResource` et `diagnostics: String`, pour qu'un
  rapport de bug puisse inclure le détail au niveau des trames.
- Le seul package Swift tiers est `pointfreeco/swift-snapshot-testing`, et
  seules les cibles de test l'utilisent. `HexPromoKit` est du code propre à
  Hex Pro, intégré au dépôt (vendored) plutôt que récupéré comme dépendance.
  L'app embarque aussi la police IBM Plex Mono, sous licence SIL OFL 1.1.
