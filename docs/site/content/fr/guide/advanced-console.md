---
title: Envoyer une commande brute à un tag
description: Identifiez une puce, exécutez un préréglage de commande et lisez ce que le tag renvoie, dans la console avancée de Hex NFC.
audience: user
pageKind: howto
navTitle: Console avancée
tags:
  - chips
---

La console avancée de Hex NFC envoie des octets de l'iPhone directement à un tag.
Elle affiche la commande envoyée, la réponse reçue et l'heure de chacune. Ouvrez-la
quand vous voulez voir les trames elles-mêmes plutôt qu'un résumé.

Avant de commencer, ayez le tag à portée de main et la fiche technique de sa puce
ouverte. La fiche technique est le document que le fabricant consacre à cette
puce. Elle est publiée sur le site du fabricant sous le nom de la puce, et l'étape
d'identification ci-dessous vous donne ce nom. Aucune page de ce guide n'en
reproduit, et la console envoie ce que vous saisissez, que vous l'ayez lue ou non.

La console tient sur un seul écran, et chaque élément que cite cette page s'y
trouve. En haut se trouvent l'indicateur d'état, avec **Identifier** à côté, et
l'interrupteur **Ignorer l'identification**. Viennent ensuite le champ
**Commande**, avec le bouton **Exécuter** à côté, et le sélecteur qui bascule
entre **Cette exécution** et **Tout le trafic NFC**. La zone de sortie suit, et
en bas se trouve **Préréglages**, avec **Rechercher** au-dessus des lignes de
préréglages.

## Identifier la puce

:::::steps
::::step[Ouvrir Hex NFC]
Ouvrez Hex NFC. L'écran d'accueil de Hex NFC apparaît.
::::

::::step[Ouvrir la console]
Sur cet écran, touchez **Avancé**, la dernière des quatre tuiles. La deuxième
ligne de la tuile indique « Console de commandes brutes ». La console s'ouvre, et
sa zone de sortie vide affiche « Console inactive. Touchez un préréglage à gauche,
ou saisissez une séquence et lancez-la. » La liste des préréglages se trouve en
bas de l'écran. Elle n'est pas à gauche.

:::figure[La console s'ouvre avec l'indicateur d'état sur « En attente », une zone de sortie vide et **Préréglages** en bas de l'écran.]
![La console avancée juste après son ouverture. L'indicateur d'état en haut à gauche indique « En attente », avec Identifier à sa droite et l'interrupteur Ignorer l'identification en dessous. Le champ Commande affiche sa séquence d'exemple, la zone de sortie ne contient que l'indication d'inactivité, et la liste des préréglages commence par Lire 16 octets, Écrire 4 octets et Mettre en HALT.](../../../assets/fr/advanced-console--idle.png)
:::
::::

::::step[Lancer le scan d'identification]
Touchez **Identifier**, la capsule à droite de l'indicateur d'état. La zone de
sortie ajoute « Identification du tag… », et le panneau de scan d'iOS apparaît
avec « Approchez le tag pour l'identifier. »
::::

::::step[Tenir le tag contre l'iPhone]
Posez le haut de l'iPhone à plat sur le tag et maintenez-le immobile. La zone de
sortie nomme la puce et l'UID du tag, et le nom de la puce apparaît à côté de
**Préréglages**. La ligne indique
« Identifié : NTAG213 · 04:4C:25:0A:30:1F:91 ».

:::figure[Après un scan d'identification, la zone de sortie nomme la puce et son UID, et le nom de la puce figure à côté de **Préréglages**, avec les préréglages de cette puce en tête de liste.]
![La console avancée après l'identification d'un NTAG213. La zone de sortie affiche deux lignes, « Identification du tag… » puis « Identifié : NTAG213 · 04:4C:25:0A:30:1F:91 ». Un badge vert NTAG213, avec un bouton pour le retirer, se trouve à côté de Préréglages, et les deux premiers préréglages de la liste sont écrits pour le NTAG213.](../../../assets/fr/advanced-console--identified.png)
:::
::::
:::::

Une puce identifiée réordonne la liste des préréglages. Les préréglages écrits
pour cette puce passent en tête. En dessous viennent ceux qui s'y appliquent
encore :

- les préréglages écrits pour tout le type de puce
- les préréglages d'une puce sœur de la même gamme, comme un préréglage NTAG215
  sur un NTAG216

Aucun de ces deux types n'est grisé. Les octets d'une puce sœur peuvent tout de
même adresser la mauvaise page sur votre puce : lisez-les donc d'abord dans
**Commande**. Un préréglage n'est grisé que s'il concerne une autre gamme de
puces, ou un tout autre type de tag. Un préréglage grisé se charge quand même
dans **Commande** lorsque vous le touchez. Pour oublier la puce, touchez son nom
à côté de **Préréglages** : la liste reprend son ordre habituel.

Quand l'app ne peut pas nommer la puce, la console affiche
« Tag connecté, mais la puce est inconnue · 04:BA:4A:92:1B:21:90 ». Elle affiche
ensuite ce que le tag a déclaré sur lui-même. La première ligne ressemble à
« Signalé : NXP · NTAG · 128-256 bytes · v1.0 ». Cette ligne indique le
fabricant de la puce, la famille de produits, la taille de mémoire que déclare la
puce et sa version de produit.
La seconde ligne donne les octets bruts dont la première a été tirée, par exemple
« GET_VERSION: 00:04:04:02:01:00:0F:03 ». Touchez une ligne pour la copier. Une
pastille « Copié » apparaît pendant environ une seconde, et les octets sont dans
le presse-papiers pour un rapport de bug.

## Contenu des préréglages

Un préréglage sous **Préréglages** est une séquence de commandes enregistrée,
fournie avec l'app. Chaque ligne porte trois éléments, et rien d'autre : le nom
du préréglage, un badge qui nomme la famille de puces pour laquelle il a été
écrit, et les octets eux-mêmes. Certains préréglages lisent un tag, d'autres
écrivent dessus, y compris sur des pages qu'une puce n'accepte d'écrire qu'une
seule fois.

Aucune description ne se cache derrière une ligne : les octets sont donc la seule
indication de ce que fait un préréglage. Lisez-les dans **Commande** en les
comparant à la fiche technique de votre puce avant d'exécuter quoi que ce soit.
Sur les puces Type 2 de la plupart des autocollants et des cartes, une commande
qui commence par `30` ou `3A` lit, et une commande qui commence par `A2` écrit.
Pour voir la console à l'œuvre sans modifier de tag, commencez par la ligne
**Lire 16 octets**, dont les octets sont `30:00`.

## Exécuter une commande

:::::steps
::::step[Charger un préréglage]
Touchez un préréglage dans la liste sous **Préréglages**. Ses octets vont dans
**Commande**, et la console note le nom du préréglage chargé. Rien n'a encore été
envoyé.
::::

::::step[Vérifier ce qui sera envoyé]
Lisez la séquence dans **Commande** et modifiez-la si besoin. Chaque paire de
chiffres hexadécimaux correspond à un octet, des deux-points séparent les octets
d'une même commande, et une virgule sépare une commande de la suivante. Un champ
vide affiche l'exemple « 21:60:00, A2:04:E1:10:06:00 ». Cet exemple est un texte
indicatif, et il ne se trouve pas dans le champ. Rien n'est envoyé tant que le
champ est vide, et **Exécuter** reste grisé jusqu'à ce que vous chargiez un
préréglage ou saisissiez une séquence. Lu comme un exemple, il s'agit de deux
commandes de trois et six octets, et la seconde écrit quatre octets sur une page.
::::

::::step[Envoyer la commande]
Touchez le bouton **Exécuter**. L'indicateur d'état affiche « Interrogation… », la
zone de sortie ajoute « Interrogation du tag… », et le panneau de scan d'iOS
apparaît avec « Approchez le tag pour envoyer la commande. »
::::

::::step[Tenir le tag contre l'iPhone]
Posez le haut de l'iPhone à plat sur le tag et maintenez-le immobile. La zone de
sortie ajoute une ligne de connexion qui porte l'UID du tag et la puce, par
exemple « Connecté : 04:4C:25:0A:30:1F:91 · ntag213 ». L'indicateur d'état
affiche ensuite « Exécution… » pendant l'envoi des commandes.

Pour arrêter avant qu'un octet n'atteigne un tag, touchez Annuler sur le panneau de scan d'iOS. L'exécution prend fin, l'indicateur d'état revient à « En attente », et la
zone de sortie affiche « Annulé avant qu'un tag soit trouvé. Rien n'a été
envoyé. » Si aucun tag ne lui est présenté, le panneau se ferme de lui-même et
l'indicateur d'état affiche « Aucun tag trouvé ». Une fois que la console a lu un
tag, depuis **Exécuter** ou **Identifier**, une annulation ou un délai expiré lors
d'une exécution ultérieure est plutôt consigné sous la forme d'une ligne d'erreur.
::::

::::step[Lire les réponses]
Chaque commande ajoute une ligne envoyée et une ligne reçue, et la ligne reçue
indique combien d'octets sont revenus. Après la dernière réponse, l'indicateur
d'état affiche « Terminé » et la zone de sortie se termine par « Terminé. »

:::figure[Après une exécution de **Lire 16 octets**, la zone de sortie contient une ligne envoyée et une ligne reçue de 16 octets, et l'indicateur d'état affiche « Terminé ».]
![La console avancée après une exécution du préréglage Lire 16 octets sur un NTAG213. L'indicateur d'état affiche « Terminé » et Commande contient 30:00. La zone de sortie, défilée jusqu'en bas, montre la fin de la ligne du préréglage chargé, « Interrogation du tag… », la ligne de connexion avec l'UID et ntag213, une ligne TX qui envoie 30:00, une ligne RX marquée 16 octets avec les octets renvoyés par le tag, et « Terminé. ».](../../../assets/fr/advanced-console--run-finished.png)
:::
::::
:::::

:::warning[La console ne vérifie rien avant d'envoyer]
Une commande d'écriture modifie le tag dès son envoi. Certaines pages d'une puce
n'acceptent qu'une seule écriture dans la vie du tag. Si un octet y est erroné,
aucune commande ultérieure ne pourra le rétablir.
:::

Pour trouver un préréglage parmi d'autres, saisissez une partie de son nom ou de
ses octets dans **Rechercher**, sous l'intitulé **Préréglages**. Vous pouvez aussi
ignorer la liste et saisir votre propre séquence dans **Commande**. Une commande
que le tag refuse met fin à l'exécution et au passage du tag, et chaque ligne déjà
présente dans la zone de sortie reste en place.

## Suivre toutes les trames, pas seulement cette exécution

Au-dessus de la zone de sortie, touchez **Tout le trafic NFC**. La console affiche
alors chaque trame que l'app échange avec un tag. Les trames des scans, des
écritures et des opérations sur les tags apparaissent, en plus de celles de cet
écran. Les nouvelles trames s'affichent au fur et à mesure. Touchez
**Cette exécution** pour revenir au journal propre à la console.

## Atteindre une puce qui refuse la sonde

Activez **Ignorer l'identification**, l'interrupteur situé entre l'indicateur
d'état et **Commande**, quand un tag ne répond plus rien une fois connecté. L'app
envoie alors vos commandes sans demander d'abord à la puce ce qu'elle est.
L'exécution signale le tag comme inconnu au lieu de nommer la puce. L'interrupteur
reste activé jusqu'à ce que vous le désactiviez ; il ne se désactive pas de
lui-même à la fin d'une exécution. Tant qu'il est activé, la raison s'affiche en
dessous :
« Les commandes vont directement à la puce. Nécessaire pour les puces qui refusent GET_VERSION : la sonde les met en veille et toutes les commandes suivantes échouent. »

Une vérification s'exécute encore, interrupteur activé. Quand un tag pourrait
être un appareil de santé NFC, comme un stylo à insuline, l'app en lit juste
assez pour le savoir, et n'envoie à un appareil de santé aucune de vos commandes.

## Si la console signale une erreur

Une ligne d'erreur met fin à l'exécution, et donc aussi au passage du tag. Le
panneau de scan d'iOS se ferme en même temps : pour envoyer autre chose, touchez à nouveau
**Exécuter** et présentez le tag.

- « Impossible d'interpréter la commande. » signifie que le texte de **Commande**
  n'est pas une séquence que l'app sait lire, et que rien n'a été envoyé.
  Vérifiez les trois règles. Chaque octet s'écrit avec deux chiffres
  hexadécimaux, et des deux-points séparent les octets d'une même commande. Une
  virgule sépare une commande de la suivante.
- « Impossible d'identifier le tag. » signifie que le scan d'identification s'est
  terminé sans résultat. Touchez **Identifier** et présentez à nouveau le tag.
- « Il s'agit d'un appareil de santé. Hex NFC n'écrit jamais sur les appareils
  de santé et ne leur envoie aucune commande. » signifie que le tag est un
  appareil médical, comme un stylo à insuline. Aucune de vos commandes ne lui a
  été envoyée.
- « Une erreur inattendue s'est produite. » signifie que l'exécution s'est arrêtée
  pour une raison que l'app ne sait pas décrire plus précisément. Le reste de la
  ligne en donne le détail.
- Tout autre message sur une ligne d'erreur est la description, par l'app
  elle-même, de ce qu'a fait le tag. C'est la même formulation qu'un scan ou une
  écriture vous aurait donnée.

Pour savoir ce que ces messages signifient le plus souvent en pratique, consultez
[Si un tag ne peut être ni scanné ni écrit](troubleshooting.md).

## Voir aussi

- [Enregistrer une copie de la mémoire d'un tag](memory-dump.md)
- [Tags compatibles avec Hex NFC](tags-that-work.md)
- [Matrice de prise en charge des puces](../developer/chip-support-matrix.md)
