---
title: Tags compatibles avec Hex NFC
description: Les puces que l'app reconnaît, ce que la carte d'informations du tag vous apprend sur chacune et ce qu'un iPhone ne peut pas lire du tout.
audience: user
pageKind: article
navTitle: Tags compatibles
tags:
  - chips
---

Un autocollant tiré d'un lot de tags vides, une carte-clé d'hôtel et une
étiquette de bibliothèque se ressemblent quand on les tient en main. La puce
qu'ils contiennent n'est pas la même, et c'est elle qui détermine la quantité
de données que le tag contient et s'il peut recevoir un mot de passe. Elle
détermine même si l'iPhone peut lire le tag.

Pour vos propres tags, achetez des tags vides de la famille NTAG. Un NTAG213
contient 144 octets, assez pour une adresse web ou un contact court. Un NTAG215
contient 504 octets et un NTAG216 en contient 888, ce qu'il faut pour une
longue note ou une série d'enregistrements. Chacun des trois peut recevoir un
mot de passe et être verrouillé. Un tag que vous n'avez pas acheté vide
contient généralement des données que seul son émetteur sait interpréter. Une
clé d'hôtel, une carte de transport et un badge d'accès à un bâtiment sont
tous des tags de ce type.

Pour savoir quel tag vous avez en main, scannez-le. Ce que l'app a lu s'ouvre
sur l'écran « Tag ». La carte en haut de cet écran est la carte d'informations du
tag, qui a pour titre le nom même de la puce.
[Scanner un tag](scan-a-tag.md) détaille le scan lui-même.

Ce nom est une référence de composant : c'est donc lui qu'il faut rechercher
pour savoir ce qu'un tag accepte. Puce par puce, ce que l'app fait de chacune
est détaillé dans la
[matrice de prise en charge des puces](../developer/chip-support-matrix.md).
Cette page fait partie de la documentation pour les développeurs et non de ce
guide : elle parle donc de commandes et d'exécutions de tests.

## Les noms affichés par l'app

Le titre de la carte d'informations du tag est le nom même de la puce. Voici
les noms qu'elle peut afficher.

:::table[Les noms de puce que peut afficher la carte d'informations du tag]
| Famille | Noms sur la carte d'informations du tag |
| --- | --- |
| NTAG | NTAG 210µ, NTAG213, NTAG213 TT, NTAG215, NTAG216, NTAG424 DNA |
| MIFARE Ultralight | MIFARE Ultralight EV1 (48b), MIFARE Ultralight EV1 (128b), MIFARE Ultralight C |
| MIFARE DESFire | MIFARE DESFire, MIFARE DESFire EV1, MIFARE DESFire EV2, MIFARE DESFire EV3 |
| EM Microelectronic | EM V10, EM V11, EM V16 |
| ICODE | ICODE SLIX, ICODE SLIX2 |
| Nommées uniquement par leur famille | ISO 15693, FeliCa, Passeport électronique, NFC Forum Type 4, Appareil de santé |
:::

La dernière ligne correspond à une puce qui se présente comme membre d'une
famille sans indiquer de quel modèle il s'agit. Une carte de transport
japonaise apparaît comme FeliCa et ouvre son propre résultat, décrit dans
[Lire une carte de transport](transit-cards.md). Un passeport apparaît comme
Passeport électronique, décrit dans [Lire un passeport](passports.md).

Un tag Type 4 d'un fabricant autre que NXP apparaît comme NFC Forum Type 4, tout
comme un téléphone Android configuré pour se comporter comme un tag. L'app lit et
écrit ses enregistrements comme ceux de n'importe quel autre tag. Elle ne peut
pas savoir quelle puce il contient : la carte n'affiche donc pas de ligne
**Mémoire**, et ni mot de passe, ni verrouillage définitif, ni
**Extraction mémoire** ne sont disponibles pour lui. Un appareil de santé
apparaît comme Appareil de santé, décrit plus bas dans
[Appareils de santé](#health-devices).

Certaines puces ne disent rien qu'une app NFC puisse rapprocher d'une référence
de composant. La carte affiche alors, à la place d'un nom, une ligne
**Signalé** et une ligne **Octets de version**, qui reprennent ce que le tag
dit de lui-même. Un tel tag peut toujours être lu et écrit comme un tag
ordinaire. Il perd tout ce qui suppose de connaître l'organisation de la
mémoire de la puce. Cela exclut un mot de passe, un verrouillage permanent et
**Extraction mémoire**, l'opération qu'explique
[Enregistrer une copie de la mémoire d'un tag](memory-dump.md).

## Ce que la carte dit de la puce

Deux lignes résument la puce. **Prend en charge** liste ce que l'app peut en
faire, par exemple « Lecture », « Écriture », « Mot de passe » ou
« Verrouillage ». « Écriture » signifie que le tag accepte un nouveau message,
comme dans [Écrire un lien sur un tag](write-a-link.md). « Mot de passe »
signifie qu'il peut porter son propre mot de passe, comme l'explique
[Protéger un tag par mot de passe](protect-a-tag.md). « Verrouillage » signifie
que le tag peut être passé en lecture seule. Cela ne peut pas être annulé,
quel que soit le tag, et c'est pourquoi [Verrouiller un tag définitivement](permanent-lock.md) a
sa propre page. **Fonctionnalités** liste les fonctions supplémentaires que
porte la puce, par exemple « Compteur de lectures » ou « Boucle
d'inviolabilité ».

En dessous figurent des lignes qui n'apparaissent que si la puce a répondu à
leur sujet. Une ligne absente signifie que la puce n'a rien dit à ce sujet,
jamais que le scan a échoué.

Une ligne **Inviolabilité** appartient à une puce munie d'une boucle
d'inviolabilité, ce qui désigne aujourd'hui un NTAG213 TT. Elle affiche
« Scellé intact » tant que la boucle est entière, et « Ouverte » une fois la
boucle rompue. Une boucle rompue le reste. Un scellé que l'app signale comme
ouvert l'était déjà quand vous avez trouvé le tag. Aucun de vos scans ne l'a
rompu.

Une ligne **Nombre de lectures** provient d'une puce munie d'un compteur de
lectures et indique le nombre de lectures que la puce a comptées.
« Compteur désactivé » n'équivaut pas à une ligne absente : le compteur existe
mais il est désactivé, comme sur la plupart des tags à leur sortie d'usine.

Une ligne **Compteurs** provient d'un MIFARE Ultralight EV1, dans l'une ou
l'autre de ses deux tailles. Cette puce tient trois compteurs, et la ligne les
affiche tous les trois côte à côte. Une deuxième ligne **Compteurs** affichant
« Coupure détectée pendant une écriture » signifie que la puce signale que ces
compteurs ne sont pas intacts. Un MIFARE Ultralight C n'affiche aucune de ces
lignes, car son compteur répond à une commande que l'app n'envoie pas.

Une ligne **Signature** affiche « Signature d'originalité NXP » quand la puce a
répondu par une signature de 32 octets. Elle affiche
« Signature NXP non standard » quand la réponse était plus courte. Aucune de
ces deux mentions ne dit si un tag est authentique. L'app note ce que la puce a
répondu, et ne le compare à rien.

## Appareils de santé {#health-devices}

Certains appareils médicaux répondent à l'iPhone comme le ferait un tag, comme
les stylos à insuline NovoPen 6 et NovoPen Echo Plus. Hex NFC en reconnaît un à
ce qu'il dit de lui-même et ouvre un écran **Appareil de santé** à la place de
l'écran « Tag ». Pour un stylo qu'il sait nommer, le titre est
**Stylo connecté Novo Nordisk**. L'écran précise que Hex NFC ne lit pas
l'historique des doses du stylo, et une carte en dessous nomme une app qui le
lit, avec un bouton pour l'obtenir sur l'App Store et un lien vers la liste des
apps du fabricant qui le lisent. Tout autre appareil de santé porte le titre
**Appareil de santé**, sans suggestion d'app.

Hex NFC ne lit que ce que l'appareil dit de lui-même et n'y écrit jamais. Une
écriture, une opération ou une commande de la console **Avancé** qui vise un
appareil de santé s'arrête avant que quoi que ce soit ne soit écrit ou envoyé.
Rien de l'appareil n'est enregistré : il n'apparaît donc pas dans votre
historique. Touchez **Fermer** pour quitter l'écran.

## Ce qu'un iPhone ne peut pas lire

Un type de carte courant reste hors de portée de tout iPhone. Un MIFARE Classic
interrompt le scan avec un message qui le signale : le tag n'est pas
défectueux, et aucune app NFC sur iOS ne va plus loin.
[Pourquoi l'iPhone ne parvient-il pas du tout à lire ce tag ?](troubleshooting.md#tag-not-readable)
donne le message et la raison.

La même limite s'applique, sous une forme atténuée, à une carte MIFARE DESFire.
Hex NFC nomme la carte et peut lui envoyer des commandes brutes. Il lit les
enregistrements de la carte quand celle-ci porte une application NDEF, et y
écrit quand cette application le permet. Une carte MIFARE DESFire EV1, EV2 ou EV3
vierge peut en recevoir une avec l'opération **Formater**, et l'opération
**Retirer la configuration NDEF** la lui enlève. Toutes deux se trouvent sous
**Actions dangereuses**, sur l'écran **Opérations** : consultez
[Formater un tag](erase-or-format.md#format-a-tag) et
[Retirer la configuration NDEF d'une carte](erase-or-format.md#remove-ndef-setup).
Une carte déjà émise pour un autre usage, comme une carte de transport ou un
badge d'accès, garde ses données derrière des clés que détient son émetteur :
l'app refuse de la configurer et la laisse telle quelle.

Si un tag que vous pensez compatible refuse toujours de se laisser scanner, la cause est généralement la façon dont vous le tenez, plutôt que la puce. Consultez
[Si un tag ne peut être ni scanné ni écrit](troubleshooting.md).
