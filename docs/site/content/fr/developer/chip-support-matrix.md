---
title: Matrice de prise en charge des puces
description: Les puces NFC que Hex NFC peut lire, écrire, protéger par mot de passe et verrouiller sur iPhone, et ce qui en a été confirmé sur des tags réels.
audience: developer
tags:
  - chips
---

Cette page indique, pour chaque puce NFC, si Hex NFC peut la lire, écrire
dessus, la protéger par mot de passe et la verrouiller sur un iPhone, et ce qui
en a été confirmé sur des tags réels. Si une puce dont vous dépendez manque,
ou se comporte autrement que ce qu'indique la page, écrivez à
[support@hex.pro](mailto:support@hex.pro) en précisant le nom de la puce et ce
qui s'est passé.

## Légende

| État | Signification |
|---|---|
| ✅ | Fonctionne, et confirmé sur des tags réels |
| ⚠️ | Implémenté, avec une réserve dans les remarques de la ligne ou dans le texte qui entoure son tableau (souvent, l'absence de confirmation sur un tag réel) |
| ❌ | L'app refuse ou ne sait pas le faire |
| — | Sans objet |

Les NTAG 210µ, NTAG213, NTAG216, NTAG424 DNA, MIFARE Ultralight EV1 128
octets, MIFARE Ultralight C, ICODE SLIX2 et MIFARE DESFire EV3 ont été testés
sur des tags physiques en août 2026, et le lecteur de cartes de transport a
été confirmé sur de vraies cartes Suica et PASMO. Sur une vraie carte
MIFARE DESFire EV3, la configuration en tag NDEF, une écriture, une lecture et
le retrait de cette configuration ont été confirmés en octobre 2026. Les séquences de protection et de suppression ont été retravaillées pour chaque famille en septembre 2026, et
le NTAG213 est la seule puce à avoir exécuté le code de protection retravaillé
sur un tag réel, pour la seule protection en écriture : aucune cellule Mot de
passe n'est donc ✅. Aucune extraction mémoire n'a encore été réalisée sur un
tag réel : aucune cellule Extraction mémoire n'est donc ✅. L'opération
Extraction mémoire elle-même n'a été exécutée que sur les simulateurs NTAG213
et NTAG215. Certains des tags testés ne se comportent pas comme des composants
NXP : les tags Ultralight C répètent des octets d'UID d'un tag à l'autre, et
un NTAG216 a renvoyé une signature d'originalité tronquée, si bien que les
résultats sur ces deux puces ne se transposent pas forcément aux puces NXP
authentiques.

Une ligne signalée comme testée sur simulateur uniquement repose sur les
simulateurs de puces de niveau protocolaire, et une ligne signalée comme non
testée n'a été exécutée ni sur un tag réel ni, lorsque la remarque le précise,
sur un simulateur. Considérez leurs cellules ⚠️ comme devant fonctionner
plutôt que comme confirmées en laboratoire.

La colonne **Verrouillage** est vérifiée autrement : le verrouillage est
irréversible, il est donc testé sur des tags sacrifiés, lors d'une série de
tests distincte et non dans le cadre de la validation d'une puce. En août
2026, cette série a couvert les NTAG 210µ, NTAG213, NTAG216, MIFARE Ultralight
EV1 128 octets, MIFARE Ultralight C et ICODE SLIX2. La séquence de
verrouillage Type 2 a été retravaillée en septembre 2026 et a depuis été
réexécutée sur NTAG213 et NTAG 210µ. Sur NTAG216, Ultralight EV1 128 octets et
Ultralight C, la confirmation est antérieure à cette refonte : leurs cellules
Verrouillage sont donc ⚠️. Le verrouillage de l'ICODE SLIX2 envoie toujours
les commandes qui ont été confirmées, et sa cellule n'est ⚠️ qu'en raison du
repli d'identification décrit dans sa ligne. Tous les autres ⚠️ de la colonne
Verrouillage reposent sur les simulateurs de puces, sauf pour le NTAG213 TT,
dont seul le masque des bits de verrouillage est testé et sur lequel aucun
simulateur n'a exécuté de verrouillage permanent.

## Type 2 (ISO 14443-3A)

| Puce | Lecture | Écriture | Mot de passe | Verrouillage | Extraction mémoire | Remarques |
|---|---|---|---|---|---|---|
| NTAG 210µ | ✅ | ✅ | — | ✅ | ⚠️ | 48 octets de mémoire utilisateur (64 au total). :more[Pas de prise en charge des mots de passe : la puce « micro » n'a pas de pages de configuration, il n'y a donc nulle part où en stocker un. N'a pas non plus de FAST_READ ni de compteur. Livré formaté NDEF] |
| NTAG213 | ✅ | ✅ | ⚠️ | ✅ | ⚠️ | 144 octets de mémoire utilisateur. :more[Protection en écriture confirmée sur des tags réels après la refonte de septembre 2026 ; la protection en lecture n'a pas été exécutée avec le code retravaillé] |
| NTAG215 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | 504 octets de mémoire utilisateur. Simulateur uniquement : aucun NTAG215 n'a été testé sur un tag réel |
| NTAG216 | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | 888 octets de mémoire utilisateur. :more[Mot de passe et verrouillage confirmés pour la dernière fois sur des tags réels avant la refonte de septembre 2026, au moyen d'un banc de test dans un build de débogage] |
| NTAG213 TT | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | 144 octets de mémoire utilisateur. Simulateur uniquement. :more[L'état d'inviolabilité du tag s'affiche sur la carte d'informations du tag dans l'éditeur de tag, ainsi que sous forme de préréglage de la console avancée] |
| MIFARE Ultralight EV1 48 octets | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | 48 octets de mémoire utilisateur. Simulateur uniquement. Livré non formaté : exécutez Formater avant d'écrire |
| MIFARE Ultralight EV1 128 octets | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | 128 octets de mémoire utilisateur. Livré non formaté : exécutez Formater avant d'écrire. :more[Mot de passe et verrouillage confirmés pour la dernière fois sur des tags réels avant la refonte de septembre 2026, au moyen d'un banc de test dans un build de débogage] |
| MIFARE Ultralight C | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | 144 octets de mémoire utilisateur. Protégé par une clé 3DES à deux clés de 16 octets, avec une authentification mutuelle, et non par un mot de passe PWD/PACK. :more[Protection par clé et verrouillage confirmés pour la dernière fois sur des tags réels avant la refonte de septembre 2026, au moyen d'un banc de test dans un build de débogage plutôt que par la carte Protection ou par Opérations. Protéger par mot de passe dans Opérations et la carte Protection de l'éditeur de tag définissent tous deux la clé comme protection en écriture. Chaque voie vérifie l'état de protection du tag avant de présenter quoi que ce soit : un tag qui apparaît ouvert ne reçoit aucune clé. Livré non formaté : exécutez Formater avant d'écrire. N'a ni GET_VERSION, ni FAST_READ, ni READ_CNT, ni signature d'originalité (son compteur 16 bits se trouve en page 29h et se lit par un READ ordinaire, si bien que la fonction compteur de l'app ne s'applique pas). Une extraction mémoire s'arrête à la page 2Bh, car la puce ne décode pas les lectures de ses pages de clé] |
| NTAG210 / NTAG212 | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | L'app ne nomme pas le modèle : la carte d'informations du tag affiche ce que la puce a annoncé d'elle-même plutôt qu'une supposition. :more[Nous préférons dire que nous ne savons pas plutôt que d'appliquer la mauvaise table de pages. Une puce non reconnue est limitée à la lecture NDEF, à l'écriture NDEF et aux commandes brutes : la protection par mot de passe, le Verrouillage permanent, l'Extraction mémoire et Formater sont donc refusés, et les écritures passent par le module d'écriture NDEF d'iOS plutôt que par l'écriture page par page de l'app. Le module d'écriture d'iOS est le chemin que l'app a cessé d'emprunter pour les tags Type 2 reconnus, car il échoue sur les tags préformatés avec un Lock Control TLV : une écriture sur l'une de ces puces peut donc échouer si le tag porte ce TLV.] Non testé sur des tags réels |
| NTAG213F / NTAG216F | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | Comme ci-dessus. Les variantes à détection de champ restent non reconnues en attendant une vérification sur des puces réelles |
| EM Microelectronic V10 / V11 / V16 | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | L'app dispose de profils pour les trois, mais son identification en production ne les sélectionne jamais : un tag EM réel n'est donc pas reconnu et est traité comme le NTAG210 ci-dessus. :more[Rien ne garantit d'ailleurs d'en arriver là : si le tag refuse GET_VERSION, l'app relance la détection pour le réveiller puis lit la page 28h, au-delà de la fin d'une puce de 16 pages, et un tag qui refuse cette lecture cesse de répondre pour le reste du passage. Aucun tag EM réel n'a été testé, et les simulateurs EM utilisent des valeurs d'octets qu'ils définissent eux-mêmes, et non des valeurs de fiche technique. Des chaînes de personnalisation pour les trois figurent dans la console avancée ; la taille de Capability Container qu'elles écrivent provient de l'organisation mémoire que l'app attribue à la puce, et non d'une fiche technique] |
| MIFARE Classic 1K/4K | ❌ | ❌ | — | ❌ | ❌ | iOS n'expose pas MIFARE Classic aux apps (pas d'accès CRYPTO1) : le tag est donc illisible sur tout iPhone. :more[Si iOS transmet le tag et que la connexion échoue, l'app indique qu'il ressemble à un MIFARE Classic ; si le scan expire à la place, le message d'expiration cite MIFARE Classic comme cause probable] |

Pour les puces Type 2, **Mot de passe** désigne le schéma NTAG21x (un PWD de 4
octets et un PACK de 2 octets, plus un seuil de page AUTH0 et le bit PROT),
que définissent à la fois Protéger par mot de passe dans Opérations et la
carte Protection de l'éditeur de tag, pour protéger soit les écritures seules,
soit les lectures et les écritures. L'app ne reconnaît une protection en
lecture que si elle commence à la page 4, là où Opérations la fait
toujours commencer et où la carte Protection la fait commencer sauf si une
page de départ personnalisée est définie. Elle détecte la protection en
lecture d'après la réponse à une lecture des pages 3 à 6 : une protection en
lecture qui commence à toute autre page de la mémoire de la puce, définie avec
la page de départ personnalisée de la carte Protection, empêche l'app de la
déverrouiller ou de la retirer. **Verrouillage** désigne la gravure
irréversible des octets de verrouillage statiques et dynamiques (Verrouillage
permanent). **Extraction mémoire** correspond à Opérations > Extraction
mémoire, qui ne fonctionne que sur les puces Type 2 et enregistre dans un
fichier `.bin` chaque page que la puce accepte de décoder. Pour le MIFARE
Ultralight C, **Mot de passe** désigne le schéma 3DES propre à la puce : une
clé de 16 octets programmée dans les pages 2Ch à 2Fh, avec une protection
délimitée par AUTH0, que Protéger par mot de passe dans Opérations et la carte
Protection de l'éditeur de tag définissent uniquement comme protection en
écriture. Une protection en lecture sur cette puce couvrirait les pages que l'app
lit pour la reconnaître : l'app n'en propose donc pas. La clé peut être
générée, collée ou dérivée d'une phrase secrète.

## Type 5 (ISO 15693)

**La protection par mot de passe du SLIX2 passe par le mode Selected d'ISO
15693.** Définir un mot de passe SLIX2 nécessite `SET_PASSWORD`, que la puce
n'accepte qu'en mode Addressed ou Selected : sans adressage, le tag ignore la
commande sans rien signaler, et le démon NFC refuse un indicateur Address
explicite avant la transmission, aussi bien par `customCommand` que par l'API
brute `sendRequest`. La voie qui fonctionne (confirmée sur une puce réelle le
7 août 2026) est le mode Selected : `NFCISO15693Tag.select(requestFlags:)`
place le tag dans l'état Selected, après quoi les commandes de mot de passe
sont envoyées avec l'indicateur Select et sans UID. Le cycle complet (protéger
un tag, vérifier que la protection est effectivement appliquée, puis la
retirer) a été validé sur du matériel en août 2026. La séquence de protection et de suppression a depuis été retravaillée, et la version retravaillée n'a pas
encore été exécutée sur un tag réel.

| Puce | Lecture | Écriture | Mot de passe | Verrouillage | Extraction mémoire | Remarques |
|---|---|---|---|---|---|---|
| NXP ICODE SLIX2 | ✅ | ✅ | ⚠️ | ⚠️ | ❌ | Livré non formaté : exécutez Formater avant d'écrire. :more[Mot de passe d'écriture uniquement, via le mode Selected (voir plus haut), confirmé pour la dernière fois sur des tags réels avant la refonte de septembre 2026, au moyen d'un banc de test dans un build de débogage plutôt que par la carte Protection. Il se définit depuis Protéger par mot de passe dans Opérations ou depuis la carte Protection. Chaque voie vérifie l'état de protection du tag avant de présenter quoi que ce soit : un tag qui apparaît ouvert ne reçoit aucun mot de passe. Reconnu par sa mémoire de 80 blocs. Lors d'une session où le tag ne répond pas à Get System Information, il est traité comme un SLIX de 28 blocs : la protection n'est pas proposée, Formater écrit un Capability Container pour 28 blocs, et Verrouillage permanent ne verrouille que les blocs 0 à 27 tout en signalant une réussite] |
| NXP ICODE SLIX (28 blocs) | ⚠️ | ⚠️ | ❌ | ⚠️ | ❌ | Livré non formaté : exécutez Formater avant d'écrire. :more[Tout tag ISO 15693 NXP qui n'annonce pas 80 blocs reçoit ce profil, quelle que soit sa taille. Un ICODE de 28 blocs ne se distingue pas d'un SLI, d'un SLIX-S ou d'un SLIX-L : l'app ne propose donc la protection à aucun d'entre eux.] Simulateur uniquement, à part l'identification sur un SLIX réel |
| ST M24LR | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | Reçoit le profil ISO 15693 générique, comme tout tag ISO 15693 non NXP. Non testé : ni tag réel ni simulateur |

Pour les puces ICODE, **Mot de passe** désigne le mot de passe d'écriture du
SLIX2, défini depuis Protéger par mot de passe dans Opérations ou depuis la
carte Protection de l'éditeur de tag. Les lectures restent ouvertes : une
protection en lecture sur un SLIX2 correspond au mode confidentialité (privacy
mode), et un tag en mode confidentialité ne répond à aucun inventaire, si bien
qu'un iPhone ne pourrait plus jamais le retrouver pour retirer la protection.
**Verrouillage** désigne `LOCK_BLOCK` sur chaque bloc de la géométrie que
l'app a identifiée lors de cette session (le nombre de blocs annoncé par le
tag, ou 28 blocs s'il n'a pas répondu à Get System Information), en sautant
les blocs déjà verrouillés et, sur un SLIX2, le bloc compteur que la puce
refuse de verrouiller. L'opération Extraction mémoire ne fonctionne pas sur
les tags ISO 15693.

## Type 3 (FeliCa)

| Puce | Lecture | Écriture | Remarques |
|---|---|---|---|
| FeliCa Lite-S | ❌ | ❌ | L'app ne déclare que le code système `0003`, et un Lite-S répond à `88B4` : iOS ne devrait donc jamais en transmettre un à l'app. Non testé : aucun tag Lite-S n'a été essayé |
| Suica / PASMO / ICOCA et le reste de la famille `0003` | ✅ | ❌ | Lecture seule : le solde et les 20 transactions les plus récentes, affichés dans une vue de carte de transport qui ne propose aucune écriture. Confirmé sur de vraies cartes Suica et PASMO |
| iD / QUICPay | — | — | Services de paiement pour lesquels l'app n'a pas de lecteur ; hors périmètre |

## Type 4 (ISO 14443-4)

| Puce | Lecture | Écriture | Mot de passe | Verrouillage | Extraction mémoire | Remarques |
|---|---|---|---|---|---|---|
| NTAG424 DNA | ✅ | ✅ | ⚠️ | ❌ | ❌ | Protection par clé confirmée pour la dernière fois sur des tags réels avant la refonte de septembre 2026. :more[Pas de verrouillage permanent ni d'extraction mémoire : la puce conserve ses données dans des fichiers adressés par APDU, et non dans des pages] |
| MIFARE DESFire EV3 | ✅ | ✅ | ❌ | ❌ | ❌ | Lecture et Écriture dépendent de la carte, et non du modèle de puce (`ChipProfile.ndefDependsOnCard`). :more[Hex NFC interroge la carte sur son état NDEF (`ConnectedTag.queryNDEFAccess()`, dont la réponse est un `NDEFAccess`), et `TagCapability.resolved(declared:chip:ndefAccess:)` accorde Lecture et Écriture à une carte configurée comme tag NFC Forum Type 4, Lecture uniquement lorsque son application NDEF est en lecture seule, et ni l'une ni l'autre à une carte sortie d'usine ou à une carte de transport. L'opération Formater, décrite dans [Formater un tag](../guide/erase-or-format.md#format-a-tag), configure une carte vierge (aucune application, et création de nouvelles applications autorisée sans la clé maître) en créant la NDEF Tag Application de la note d'application NXP AN11004 : un fichier Capability Container, puis un fichier NDEF de 4 Ko au plus, dimensionné d'après la mémoire libre mesurée de la carte, le Capability Container étant écrit en dernier et le résultat relu au moyen de commandes ISO (`DESFireNDEFDriver.setUp()`, appelé depuis `OperationsFlowModel.setUpDESFireNDEFApplication`). Une fois la carte configurée, iOS la lit et y écrit au moyen de son propre lecteur NDEF. L'opération Retirer la configuration NDEF, décrite dans [Retirer la configuration NDEF d'une carte](../guide/erase-or-format.md#remove-ndef-setup), rend vierge une carte qui porte la structure NDEF de Hex NFC, quel que soit le contenu de son Capability Container : elle s'authentifie une seule fois avec la clé maître DES d'usine (AuthenticateISO) et envoie FormatPICC, et uniquement sur une carte dont la seule application a la structure de Hex NFC et dont la clé maître est une clé DES en version 00 (`DESFireNDEFDriver.remove()` et `checkRemovable()`). Hex NFC reconnaît sa propre configuration à la structure de la carte (l'application qu'elle contient, ses paramètres de clé et ses fichiers), et non à l'outil qui l'a créée (`DESFireNDEFState`, obtenu par `readState()`). Avant toute écriture, Formater refuse une carte qui contient une autre application (une carte de transport ou un badge d'accès, par exemple), une carte dont la clé maître protège l'ajout de nouvelles applications, et la configuration NDEF d'un autre outil, y compris une configuration qui a la structure de Hex NFC mais un Capability Container différent. Retirer la configuration NDEF refuse une carte qui contient une autre application ou une application NDEF dont la structure diffère de celle de Hex NFC, et signale qu'une carte sans application est déjà vierge. L'identification indique toujours la génération et la taille de stockage, et les commandes brutes restent disponibles dans la console avancée. Confirmé sur de vraies cartes EV3 4K : configuration, écriture et relecture d'un message NDEF, effacement, retrait libérant toute la mémoire, nouvelle configuration, et refus d'une carte de transport au moyen de trames de lecture seule] |
| MIFARE DESFire EV1 / EV2 | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | :more[Lecture et Écriture suivent l'état NDEF de la carte, comme sur un EV3, et les opérations Formater et Retirer la configuration NDEF acceptent les deux générations avec la même séquence (`Type4Variant.isDESFire`, `ConnectedTag.desfireNDEFDriver`). Aucune des deux générations n'a exécuté cette séquence sur une carte réelle ni sur un simulateur : le seul simulateur DESFire, `DESFireEV3Simulator`, modélise un EV3.] Identification et commandes brutes comme pour l'EV3 |
| MIFARE DESFire D40 et autres générations | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | Le nom affiché est « MIFARE DESFire ». :more[`ChipCatalog.identify(desFireVersion:)` attribue le profil générique `ChipCatalog.genericMifareDESFire` (`Type4Variant.desfireGeneric`) à une carte dont la version majeure du matériel renvoyée par GET_VERSION n'est ni 01h (EV1), ni 12h (EV2), ni 33h (EV3), par exemple le D40 d'origine. Une carte dont la commande GET_VERSION se perd deux fois dans le transport au cours d'un même passage reçoit le même profil, quelle que soit sa génération (`MiFareTagIdentifier`, `Type2ProbePolicy`). Lecture et Écriture suivent l'état NDEF de la carte, comme sur un EV3 (`Type4Variant.isDESFire`, `ChipProfile.ndefDependsOnCard`) : une carte qui porte déjà une application NDEF peut donc être lue, et écrite lorsque cette application le permet. Les opérations Formater et Retirer la configuration NDEF refusent la carte avant d'envoyer quoi que ce soit qui la modifie, avec le message « Cela ne fonctionne qu'avec les cartes MIFARE DESFire EV1, EV2 et EV3. » (`ConnectedTag.desfireNDEFDriver` vaut nil, donc `OperationsFlowModel.unsupportedGeneration` répond). Les commandes brutes restent disponibles dans la console avancée.] Pas encore pris en charge, et non testé : aucune carte D40 n'a été essayée et aucun simulateur n'en modélise |
| Autres tags NFC Forum Type 4 (de fabricants autres que NXP, ou un téléphone Android qui émule un tag) | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | Le nom affiché est « NFC Forum Type 4 » (`ChipCatalog.genericType4`). :more[iOS ne remet ces tags à l'app que parce que l'app déclare l'AID de l'application NDEF du NFC Forum (`D2760000850101`) après celui d'eMRTD. L'app lit le début du message NDEF par de simples SELECT et READ BINARY (`Type4NDEFProbe`), puis demande GET_VERSION, afin qu'un NTAG424 DNA ou un DESFire arrivé par cette voie soit toujours reconnu (`ChipCatalog.identify(type4Version:)`). Tout autre tag garde le profil générique : lecture NDEF, écriture NDEF par la prise en charge NDEF d'iOS elle-même et commandes brutes, sans organisation mémoire ni fabricant. Confirmé en octobre 2026 sur un téléphone Android émulant un tag Type 4 (lecture, écriture et relecture). Aucun tag physique d'un autre fabricant que NXP n'a été essayé] |
| Appareils de santé NFC (NFC Forum PHDC, comme les NovoPen 6 et NovoPen Echo Plus) | ❌ | ❌ | — | ❌ | ❌ | Le nom affiché est « Appareil de santé ». :more[Reconnus par un enregistrement PHD au début du message NDEF (`PHDAssociation`), avec le fabricant nommé d'après son OUI lorsque l'app le connaît (`HealthDeviceMaker`). Seule cette demande d'association est lue, jamais les mesures ni l'historique des doses. Les écritures, Effacer et les commandes de console sont refusés avant l'envoi de toute trame (`refuseIfHealthDevice`), même avec Ignorer l'identification activé, et le scan n'est jamais enregistré dans l'historique. Confirmé en octobre 2026 sur un téléphone Android qui servait un message publié d'un NovoPen 6. Aucun vrai stylo n'a été essayé] |

Pour le NTAG424 DNA, **Mot de passe** désigne l'authentification AES-128
propre à la puce, et non le schéma PWD/PACK de Type 2 : Protéger par mot de
passe dans Opérations et la carte Protection de l'éditeur de tag prennent une
clé de 16 octets, et chacun peut protéger les lectures comme les écritures. La
carte Protection applique la clé lors de l'écriture suivante.

## Fiabilité du matériel

Hex NFC nécessite iOS 17 : il ne fonctionne donc pas sur l'iPhone X ni sur les
modèles antérieurs. Aucune génération d'iPhone n'a été comparée à une autre,
si bien qu'il n'existe aucun chiffre de fiabilité par modèle à publier.

Le code traite ISO 15693 comme un transport peu fiable : l'identification se
rabat sur le profil du catalogue lorsqu'un tag ne répond pas à Get System
Information, et le verrouillage permanent vérifie l'état de sécurité d'un bloc
avant de croire une réponse d'erreur. Lorsqu'un scan échoue, l'écran de scan
le signale et propose de réessayer.
