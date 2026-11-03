---
title: Modèle de menaces
description: Ce contre quoi Hex NFC protège dans son traitement des données des tags, des opérations destructives et des dépendances, et ce qu'il laisse hors périmètre.
audience: developer
tags:
  - security
---

Hex NFC est un outil qui lit, écrit et modifie des tags NFC. Ce document
énumère ce contre quoi nous protégeons, et ce contre quoi nous ne protégeons
pas.

## Dans le périmètre

### Confidentialité des données

- Les tags scannés sont stockés dans SwiftData sur l'appareil, dans une base
  que l'app n'exclut pas des sauvegardes de l'appareil. La synchronisation
  iCloud propre à l'app est facultative et désactivée par défaut. Lorsqu'elle
  est activée, elle réplique les préréglages et l'historique de scan dans la
  base de données iCloud privée de l'utilisateur. Une entrée de l'historique
  de scan contient l'UID et les enregistrements du tag et, pour une carte de
  transport, son IDm, son solde et ses transactions.
- En dehors de la synchronisation iCloud, l'app n'envoie sur le réseau des
  données lues sur un tag que dans un seul cas. Lorsqu'une carte de transport
  affiche une station que l'app ne sait pas nommer, l'utilisateur peut en
  saisir le nom et toucher Envoyer, ce qui transmet à `api.apps.hex.pro` les
  codes de ligne, de station et de région, le code système de la carte et le
  nom saisi. Cette requête ne transporte rien d'autre de la carte : ni son
  IDm, ni son solde, ni sa liste de transactions.
- `PrivacyInfo.xcprivacy` ne déclare aucun suivi ni aucun type de données
  collectées, et ni la suggestion de nom de station décrite ci-dessus ni un
  commentaire n'y figurent. L'app effectue quatre autres requêtes réseau, et
  aucune ne transporte quoi que ce soit lu sur un tag : l'écran d'accueil de
  Hex NFC récupère un chiffre de coûts de développement auprès de
  `api.apps.hex.pro`, demande à `api.p.hex.pro` une bannière pour une autre app
  Hex Pro, et télécharge l'image ou la vidéo que désigne cette réponse ; et le
  formulaire de commentaire, uniquement quand l'utilisateur touche Envoyer,
  envoie à `api.hex.pro` le message saisi, une adresse de réponse facultative,
  ainsi que la version de l'app, la version d'iOS, le modèle de l'appareil et la
  langue de l'app. Toute requête réseau que
  cette page ne décrit pas est un bug de sécurité.
- Chaque commande que l'app envoie elle-même à un tag, ainsi que la réponse du
  tag, est aussi écrite dans le journal système de l'iPhone (sous-système
  `pro.hex.nfc`, catégorie `apdu`), marquée `.public` pour que le système ne
  la caviarde pas. Cela se produit dans les builds de production, et aucun
  réglage ne le désactive. Les trames qui portent un mot de passe ou une clé
  sont masquées, de même que l'EXTERNAL AUTHENTICATE BAC d'un passeport, son
  MSE:Set AT PACE et le dernier GENERAL AUTHENTICATE PACE, qui porte les
  jetons d'authentification. Les étapes GENERAL AUTHENTICATE PACE qui
  précèdent celle-ci sont envoyées en chaînage de commandes (octet de classe
  `10`), que la règle de masquage ne détecte pas : le nonce chiffré et les
  données échangées pour le mapping et l'accord de clé sont donc journalisés
  en entier. Quiconque enregistre l'échange radio reçoit aussi ces trames.
  Tout le reste est journalisé en entier. Cela comprend l'UID de chaque tag
  que l'app détecte et l'IDm d'une carte de transport ; les pages de
  configuration que l'app lit ; les douze premiers octets de la zone de
  données d'un tag Type 2, que chaque scan et chaque écriture lisent pour
  vérifier que le tag est présent ; une extraction mémoire ; chaque
  enregistrement que l'app écrit sur un tag Type 2 dont elle identifie la
  puce ; et les blocs à partir desquels sont lus le solde et les transactions
  d'une carte de transport. Lorsqu'un NTAG424 DNA accepte la clé que porte une
  écriture, comme le fait un tag protégé en écriture seule avec cette clé, les
  enregistrements qu'envoie l'écriture et ceux qu'elle relit pour les vérifier
  sont eux aussi journalisés en entier. Si le fichier NDEF du tag est
  configuré pour une communication chiffrée, ce qui est la façon dont l'app
  protège aussi un tag en lecture, ces trames sont chiffrées. Les groupes de
  données d'un passeport n'arrivent dans le journal que sous la forme des
  trames chiffrées de sa session de messagerie sécurisée (secure messaging).
  Les enregistrements qu'iOS lit pour le compte de l'app ne sont pas
  journalisés, à part leur nombre et leur taille sur un tag qu'iOS présente
  comme un tag MIFARE : tout tag Type 2, une carte DESFire, et un NTAG424 DNA
  lorsqu'iOS le présente ainsi. Quiconque peut lire le journal de l'iPhone,
  depuis un Mac connecté ou dans un sysdiagnose, peut lire ces trames.
- Les secrets de protection des tags sont stockés uniquement dans le
  trousseau, sous forme d'éléments
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` qui ne se synchronisent
  jamais et ne passent jamais sur un autre appareil. Il s'agit du PWD de 4
  octets et du PACK de 2 octets des tags NTAG21x et Ultralight EV1, de la clé
  AES-128 du NTAG424 DNA, de la clé 3DES de 16 octets du MIFARE Ultralight C
  et du mot de passe d'écriture de 4 octets de l'ICODE SLIX2.
- Deux magasins du trousseau les conservent.
  `KeychainProtectionCredentialStore` conserve le secret d'un préréglage
  enregistré avec la protection activée, indexé par le préréglage, et
  supprimer le préréglage de la Bibliothèque de cet iPhone supprime ce secret.
  `KeychainTagCredentialStore` est indexé par l'UID du tag. Lorsqu'une
  écriture depuis la carte Protection de l'éditeur applique ou retire une
  protection, ou qu'un préréglage protégé écrit depuis la Bibliothèque en
  applique une, le secret y est enregistré après l'écriture des nouveaux
  enregistrements et avant la commande qui modifie la protection du tag,
  devant les secrets déjà consignés pour ce tag (jusqu'à quatre au total). Un
  échec de cet enregistrement n'arrête pas l'écriture. Supprimer un préréglage
  laisse ces entrées intactes, et l'app n'offre aucun moyen d'en retirer une :
  une entrée n'est supprimée que lorsqu'une relecture après une suppression montre
  le tag ouvert et revenu à son secret d'usine. Aucun code ne relit encore une
  entrée pour déverrouiller un tag. Un mot de passe saisi sur l'écran
  Opérations n'est enregistré nulle part.
- Seuls les *paramètres* non secrets (comme la page à partir de laquelle
  commence la protection et, pour NTAG21x, Ultralight EV1 et NTAG424 DNA, le
  fait qu'elle protège les écritures seules ou les lectures et les écritures)
  sont enregistrés avec un préréglage, synchronisés ou écrits dans un export
  `.hexnfc` ; le secret ne les accompagne jamais. Un préréglage protégé qui
  arrive sur un autre appareil, par la synchronisation iCloud ou par une
  sauvegarde restaurée sur un nouvel iPhone, emporte ses paramètres mais pas
  son secret. Sa ligne dans la Bibliothèque affiche toujours le cadenas qui
  indique qu'il applique une protection, mais l'écrire depuis cet autre
  appareil n'en applique aucune et ne donne aucun avertissement. Il en va de
  même sur cet iPhone pour un préréglage enregistré avec la protection activée
  mais sans secret, par exemple depuis l'éditeur d'un tag protégé scanné dont
  le mot de passe n'y a jamais été saisi. Le panneau Enregistrer comme
  préréglage indique pourtant toujours que le secret est stocké uniquement sur
  cet appareil. L'app peut partager un préréglage sous forme de fichier
  `.hexnfc`, mais n'a aucun moyen d'en importer un. Deux choses sont écrites
  dans des fichiers du répertoire temporaire de l'app, et l'app ne supprime ni
  l'une ni l'autre : le fichier `.hexnfc` d'un préréglage partagé, et le
  fichier `.bin` d'une extraction mémoire, écrit dès la fin de l'extraction,
  qu'il soit partagé ou non.
- Un passeport électronique n'est lu qu'après que l'utilisateur a indiqué le
  numéro de passeport, la date de naissance et la date d'expiration figurant
  dans sa zone de lecture automatique, en les saisissant ou en scannant la page
  photo avec l'appareil photo, qui lit les lignes imprimées sur l'appareil et
  ne conserve aucune image. L'app n'enregistre pas ces
  informations, ni rien de ce qu'elle lit sur le passeport, image du visage
  comprise, dans l'historique de scan ni dans aucun autre stockage de l'app,
  et n'en envoie rien sur le réseau. Le résultat n'est affiché que pour cette
  session.

### Sécurité des opérations destructives

- Sur l'écran Opérations, sept opérations exigent que l'utilisateur
  saisisse l'UID complet du tag avant de s'exécuter : Effacer, Formater,
  Retirer la configuration NDEF, Verrouillage permanent, Limite de tentatives,
  Protéger par mot de passe et Retirer le mot de passe. Limite de tentatives
  est réservée aux NTAG21x et Ultralight EV1. Protéger par mot de passe et
  Retirer le mot de passe couvrent toutes les puces que l'app sait protéger
  (NTAG21x, Ultralight EV1, Ultralight C, NTAG424 DNA et ICODE SLIX2), et la
  carte Protection de l'éditeur de tag peut protéger et déprotéger les mêmes
  puces. Il
  s'agit d'une confirmation par saisie, et non d'un Oui/Non : l'UID affiché à
  côté du champ est celui qu'a lu le premier de deux passages, et un second
  passage qui présente un autre tag est refusé.
- Retirer la configuration NDEF envoie FormatPICC, qui supprime toutes les
  applications d'une carte MIFARE DESFire. L'opération s'authentifie une seule
  fois par passage avec la clé maîtresse DES d'usine publiée, et seulement
  après que ce même passage a montré que l'unique application de la carte a la
  structure NDEF de cette app et que sa clé maîtresse est une clé DES en
  version 00. Formater et Retirer la configuration NDEF refusent une carte qui
  porte toute autre application, comme une carte de transport ou d'accès,
  avant d'envoyer quoi que ce soit qui la modifie.
- Un tag reconnu comme appareil de santé NFC ne reçoit aucune écriture, aucun
  Effacer ni aucune commande de console : son profil ne porte que
  `.personalHealthDevice`, et `refuseIfHealthDevice` refuse les écritures NDEF,
  les écritures mémoire et les commandes brutes avant l'envoi de toute trame.
  Le scan n'est jamais enregistré dans l'historique.
- En dehors de l'écran Opérations, rien, dans un build de production, n'est
  soumis à ce contrôle. La protection appliquée ou retirée depuis la carte
  Protection de l'éditeur s'exécute dans le cadre de l'écriture suivante, tout
  comme la protection d'un préréglage écrit depuis la Bibliothèque ; la
  retirer exige toujours le mot de passe ou la clé actuels du tag. Une
  écriture ordinaire remplace le contenu du tag, et une écriture dont tous les
  enregistrements ont été supprimés vide le tag comme le fait Effacer. La
  console avancée envoie les commandes brutes que l'utilisateur saisit ou
  charge depuis sa liste intégrée, y compris celles qui verrouillent
  définitivement la mémoire ou réécrivent des pages de configuration, à un tag
  par exécution, sans confirmation.
- La limite de tentatives (AUTH_LIM) est facultative, et l'écran qui la
  définit affiche un avertissement. Appliquer une protection par mot de passe
  à un NTAG21x ou à un Ultralight EV1 écrit toujours une limite de 0
  (illimité), ce qui efface aussi une limite que le tag portait déjà. En
  dehors des commandes brutes de la console avancée, une limite non nulle ne
  se définit que depuis l'écran « Limite de tentatives », sur un tag déjà protégé.
  Une limite de N permet au tag de refuser N mots de passe incorrects. Un mot
  de passe incorrect de plus, et le tag cesse définitivement d'accepter son
  mot de passe, le bon compris : sa protection ne peut alors plus jamais être
  retirée, et la mémoire qu'elle protège ne peut plus jamais être réécrite, ni
  relue si les lectures étaient protégées elles aussi. C'est le comportement
  propre à la puce, que nous signalons haut et fort au lieu de le cacher. Nous
  avons confirmé ce décompte sur NTAG213. L'écran « Limite de tentatives »
  fonctionne aussi sur NTAG213 TT, NTAG215, NTAG216 et Ultralight EV1, où le
  décompte n'a pas été testé ; les fiches techniques des NTAG215, NTAG216 et
  Ultralight EV1 énoncent la même règle. L'écran « Limite de tentatives » affiche
  la limite que porte déjà un tag lorsque la configuration du tag peut être
  lue sans mot de passe, ce qui exclut un tag protégé en lecture. L'app ne
  peut jamais savoir combien de mots de passe incorrects un tag a déjà
  refusés, car aucune commande de ces puces ne le communique.
- Le verrouillage permanent n'est jamais un paramètre de préréglage, pas plus
  que la limite de tentatives : un préréglage écrit depuis la Bibliothèque
  peut appliquer une protection, mais ne peut jamais verrouiller
  définitivement un tag ni définir une limite. Il place en revanche le même
  mot de passe ou la même clé sur chaque tag sur lequel il est écrit, et l'app
  n'affiche jamais le secret qu'un préréglage a stocké. Supprimer un
  préréglage se fait d'un balayage sur sa ligne dans la Bibliothèque, sans
  confirmation, et son secret ne passe pas sur un nouvel iPhone. Avec la
  synchronisation iCloud activée, supprimer le préréglage sur un autre
  appareil, où il ne détient aucun secret, le retire aussi de cet iPhone et
  laisse son secret dans le trousseau de cet iPhone, où rien ne le lit. Une
  fois le préréglage et ses éventuels doublons supprimés, ou si l'utilisateur
  passe à un nouvel iPhone, l'app ne détient plus aucune copie qu'elle
  présentera à un tag (les entrées par tag décrites plus haut restent sur
  l'iPhone d'origine, mais rien ne les relit). À moins que l'utilisateur n'ait
  conservé le secret ailleurs, la mémoire protégée de chaque tag écrit avec ce
  préréglage ne peut alors plus jamais être réécrite.
- L'app ne contourne jamais l'authentification côté tag. Si un tag Type 2
  refuse notre PWD_AUTH, nous signalons l'échec honnêtement et n'envoyons
  aucun deuxième mot de passe pendant ce passage ; nous ne réessayons pas avec
  une liste de mots de passe devinés. Après le refus de Protéger par mot de
  passe ou de Retirer le mot de passe, l'écran Opérations propose un
  bouton, **Essayer la valeur d'usine**, qui essaie le mot de passe d'usine
  publié lors d'une nouvelle exécution, contrôle par saisie de l'UID compris.
  Rien ne déclenche cette étape automatiquement, et sur un tag doté d'une
  limite de tentatives, elle compte comme un essai incorrect si le mot de
  passe d'usine n'est pas celui que détient le tag. Protéger par mot de passe,
  exécuté sur un tag déjà protégé en écriture seule, présente le nouveau mot
  de passe comme mot de passe actuel du tag : sur un tag doté d'une limite de
  tentatives, c'est un essai incorrect, sauf si le tag détient déjà ce mot de
  passe. Une écriture qui porte un mot de passe ou une clé présente ce secret
  avant d'écrire quoi que ce soit. Cela couvre un préréglage avec un secret
  stocké et une écriture depuis la carte Protection de l'éditeur. Sur toutes
  les puces que l'app sait protéger, elle lit d'abord l'état de protection du
  tag et n'envoie aucun mot de passe ni aucune clé à un tag qui apparaît non
  protégé. Sur la carte Protection, la valeur présentée est
  celle qui vient d'y être saisie, y compris un nouveau mot de passe destiné à
  remplacer celui du tag : sur un tag doté d'une limite de tentatives, elle
  compte comme un essai incorrect chaque fois que le tag en détient un autre.
  Le seul repli automatique concerne le NTAG424 DNA : appliquer ou retirer une
  protection fait appel à trois clés au plus dans une même session (la clé
  actuelle fournie à l'opération, la clé d'usine publiée, entièrement à zéro,
  et, lors d'une application, la nouvelle clé). Cela limite les clés essayées,
  pas le nombre de tentatives. Un tag sortant d'usine apparaît non protégé :
  une écriture ne lui envoie donc aucune clé avant d'écrire. Un changement de clé qui échoue ajoute jusqu'à
  deux tentatives de plus pour déterminer quelle clé le tag détient. Nous
  n'avons pas établi si cette puce compte les authentifications échouées.

### Chaîne d'approvisionnement du build

- Le build n'utilise que les frameworks d'Apple et le code propre à Hex Pro,
  plus une dépendance réservée aux tests
  (`pointfreeco/swift-snapshot-testing`) : aucun SDK d'analyse d'usage ou de
  rapports de plantage, et aucune bibliothèque d'interface tierce. Cette
  dépendance est déclarée sous forme de plage de versions à partir de 1.17.0,
  et `Package.resolved` n'est pas versionné : chaque nouveau checkout résout
  donc la version la plus récente de cette plage. `HexPromoKit` est intégré au
  dépôt (vendored) octet pour octet depuis un autre dépôt Hex Pro, à un commit
  épinglé. Toute dépendance supplémentaire est une surface de risque pour la
  chaîne d'approvisionnement que nous n'acceptons pas.
- Le workflow de publication récupère les ressources de signature en lecture
  seule via fastlane Match, depuis un dépôt privé distinct. Il clone ce dépôt
  avec des identifiants conservés en tant que secrets GitHub Actions, et Match
  déchiffre les ressources avec une phrase secrète conservée de la même façon.
  Les clés privées de signature ne se trouvent pas dans le dépôt de l'app. La
  chaîne d'outils de publication n'est pas figée : le workflow installe la
  version actuelle de fastlane depuis RubyGems à chaque exécution et fait
  référence aux GitHub Actions par tag de version majeure plutôt que par
  commit.

## Hors périmètre

- Les garanties cryptographiques de la puce relèvent de la puce, qui constitue
  une frontière de confiance matérielle. Nous utilisons l'authentification que
  fournit la puce, quelle qu'elle soit ; nous ne prétendons pas que notre app
  rend la puce plus sûre que ne le permet le matériel. Un mot de passe NTAG21x
  ou Ultralight EV1 transite en clair par radio chaque fois qu'il est présenté
  ou écrit. Il en va de même d'une clé Ultralight C ou d'un mot de passe
  d'écriture ICODE SLIX2 lorsqu'il est écrit sur le tag. Lorsqu'un mot de
  passe SLIX2 est présenté, il n'est masqué que par un nombre aléatoire de 16
  bits que le tag vient d'envoyer en clair. Quiconque enregistre ces échanges
  dispose du secret.
- Le clonage n'est pas empêché. Les UID des NTAG21x sont figés en usine, mais
  le reste de la mémoire peut être copié librement sur des tags vides. C'est
  une propriété commune à tout le secteur, et Hex NFC ne prétend pas la
  contrer. La carte d'informations du tag affiche « Signature d'originalité
  NXP » lorsqu'une puce Type 2 renvoie une signature complète de 32 octets,
  mais l'app ne la vérifie jamais avec la clé publique de NXP : cette ligne ne
  prouve donc pas qu'un tag est authentique. La ligne Fonctionnalités indique
  « Signature d'originalité » pour toute puce identifiée comme un modèle qui
  en possède une, quoi que la puce ait renvoyé. Pour le NTAG424 DNA, la carte
  indique « Miroir SUN » parmi les fonctionnalités de la puce, mais l'app ne
  configure ni ne vérifie les messages SUN.
- La lecture d'un passeport ne prouve pas que le document est authentique.
  L'app compare les groupes de données qu'elle lit avec la liste d'empreintes
  de l'objet de sécurité de la puce et affiche « Probablement intact »
  lorsqu'ils correspondent, mais elle ne vérifie pas la signature de cet objet
  (Passive Authentication), et n'exécute ni Active Authentication ni Chip
  Authentication, les vérifications qui détectent une puce copiée.
- Toute personne qui a physiquement accès à l'iPhone déverrouillé peut accéder
  à vos données de tags, comme aux données de n'importe quelle autre app. Elle
  peut aussi utiliser les mots de passe et les clés enregistrés avec vos
  préréglages, car l'écriture d'un préréglage présente son secret stocké à un
  tag déjà protégé par ce secret.
- Un tag contrôlé par un attaquant peut renvoyer n'importe quelles données en
  réponse à nos lectures. Nous analysons ses réponses de manière défensive,
  mais nous ne considérons pas le tag comme un oracle de confiance pour quoi
  que ce soit au-delà de son propre contenu.

## Signalement

Signalez les vulnérabilités en privé à
[security@hex.pro](mailto:security@hex.pro) plutôt que sur un forum public.
Nous accusons réception d'un signalement sous 72 heures, puis nous travaillons
avec la personne qui l'a fait à un correctif et à une date de divulgation
publique, selon un calendrier de divulgation coordonnée de 90 jours.
