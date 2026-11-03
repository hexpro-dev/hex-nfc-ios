---
title: Questions fréquentes
description: "Réponses sur le coût de Hex NFC, les iPhone qu'il nécessite, ce que deviennent les tags que vous scannez et comment obtenir de l'aide."
audience: user
pageKind: faq
navTitle: FAQ
tags:
  - privacy
---

Les autres pages du guide détaillent chaque tâche. Cette page répond aux questions
qui se posent autour d'elles : ce que coûte l'app et ce qu'elle demande à
l'iPhone. Elle explique aussi ce que devient un tag une fois que vous l'avez
scanné, et comment joindre Hex Pro.

## Ce que coûte l'app

### Hex NFC est-il payant ?

Non. Hex NFC ne coûte rien, et il n'y a ni compte, ni abonnement, ni achat
intégré, ni fonctionnalité payante. Installez Hex NFC depuis
l'[App Store](https://apps.apple.com/app/id6801457461) et vous disposez de l'app
complète.

### Qu'est-ce que la carte des coûts de développement ?

Un indicateur de progression, qui n'appelle aucune action de votre part. L'écran
d'accueil de Hex NFC affiche une carte intitulée
**Coûts de développement couverts**, qui montre la part du coût du projet déjà
couverte à ce jour. **Voir le détail** ouvre dans votre navigateur une page du
site web de Hex Pro, où toute contribution est volontaire. Rien de ce que propose
cette page ne débloque quoi que ce soit dans l'app.

### L'app affiche-t-elle des publicités ?

Aucune régie publicitaire n'y fonctionne. L'écran d'accueil de Hex NFC peut
afficher une carte intitulée **Plus d'apps Hex Pro**, pour une autre app du même
éditeur. Aucune régie publicitaire tierce, aucun suivi et aucune personnalisation
ne se cachent derrière cette carte : tout le monde voit la même.

## Ce dont l'iPhone a besoin

### Quels iPhone peuvent utiliser Hex NFC ?

Tout iPhone sous iOS 17 ou version ultérieure, c'est-à-dire à partir de
l'iPhone XR et de l'iPhone XS, ainsi que les iPhone SE de deuxième et troisième
génération. Tous ces modèles intègrent le lecteur NFC qu'utilise l'app : la
version d'iOS est donc la seule chose à vérifier. Hex NFC est une app pour iPhone
et ne fonctionne pas sur iPad. Sur un appareil dépourvu de ce lecteur, un scan se
termine par « Cet appareil ne prend pas en charge le NFC. » au lieu de chercher un
tag.

### Ai-je besoin d'une connexion Internet ?

Non. Lire, écrire et protéger un tag se passent entièrement entre l'iPhone et le
tag. L'app contacte Hex Pro pour quatre choses. Les deux premières sont
l'indicateur des coûts de développement et la carte d'une autre app Hex Pro. Les
deux autres ne partent que lorsque vous les envoyez : un nom de station depuis
une carte de transport, et un commentaire. La synchronisation iCloud est le
cinquième usage du réseau, et elle reste désactivée tant que vous ne l'activez
pas. Consultez
[Confidentialité et vos données](privacy.md).

### Pourquoi l'iPhone ne lit-il pas l'un de mes tags ?

Sa puce est peut-être de celles qu'un iPhone ne peut pas lire du tout. Le
MIFARE Classic est le cas le plus courant, et il s'agit d'une limite d'iOS plutôt
que d'un défaut du tag. Consultez
[Tags compatibles avec Hex NFC](tags-that-work.md) pour connaître les puces que
l'app reconnaît.

## Les tags que vous scannez

### Que devient un tag une fois scanné ?

Le scan est enregistré sur l'iPhone, sous **Historique** dans l'écran
« Bibliothèque ». Cette liste est limitée en taille, et une ligne non épinglée expire
aussi avec le temps ; une ligne que vous avez épinglée échappe à ces deux limites.
Supprimer une ligne supprime le scan enregistré. Consultez
[Retrouver un tag scanné auparavant](scan-history.md).

### Les passeports et les cartes de transport sont-ils aussi enregistrés ?

Les deux diffèrent. La lecture d'un passeport n'est conservée que pendant cette
session et disparaît quand vous fermez le panneau. Rien n'en parvient à votre
historique, à un export ou à iCloud. La lecture d'une carte de transport est
enregistrée comme n'importe quel autre scan. La ligne figure sous **Historique**
dans l'écran « Bibliothèque » et compte parmi les 50 lignes que contient cette liste.
Tant que la synchronisation iCloud est activée, elle est répliquée sur iCloud.
Ouvrir cette ligne affiche la carte telle qu'elle a été lue, et supprimer la ligne
supprime le scan enregistré. Consultez [Lire un passeport](passports.md) et
[Lire une carte de transport](transit-cards.md).

### Des informations sur mes tags quittent-elles l'iPhone ?

Seulement si vous activez l'option **Synchronisation iCloud**, qui se trouve dans
le groupe **Synchronisation** de l'écran « Réglages » de Hex NFC et qui est désactivée
au départ. Elle réplique vos préréglages et votre historique de scan dans votre
base de données iCloud privée, gérée par Apple et protégée par votre Apple ID. Les mots de passe des tags n'en font jamais partie : ils restent dans le
trousseau d'iOS, sur l'iPhone qui les a définis. Consultez
[Réglages](settings.md#turn-on-icloud-sync) et
[Confidentialité et vos données](privacy.md).

### Hex NFC peut-il récupérer un mot de passe de tag que j'ai oublié ?

Non, et rien d'autre ne le peut. C'est le tag lui-même qui vérifie le mot de
passe : la mémoire protégée d'un tag dont le mot de passe est perdu est donc
irrécupérable. Un mot de passe que vous définissez est conservé dans le trousseau
de l'iPhone qui l'a défini. Sur un autre iPhone, le même tag vous demande de le
saisir. Consultez [Protection des tags](tag-protection.md).

### Hex NFC peut-il lire mon stylo à insuline ? {#insulin-pen}

Il peut vous dire de quel stylo il s'agit, mais pas ce qu'il contient. Un
NovoPen 6 ou un NovoPen Echo Plus ouvre un écran **Appareil de santé** qui nomme
une app capable de lire son historique des doses. Hex NFC n'écrit jamais sur un
appareil de santé et n'en enregistre rien. Consultez
[Appareils de santé](tags-that-work.md#health-devices).

## Obtenir de l'aide {#getting-help}

### Comment signaler un problème ou poser une question ? {#report-a-problem}

Dans Hex NFC, touchez le bouton en forme d'engrenage de l'écran d'accueil, puis
**Envoyer un commentaire**. Le message arrive directement chez Hex Pro avec la
version de l'app, la version d'iOS, le modèle de l'appareil et la langue, que le
formulaire affiche avant l'envoi. Indiquez votre adresse e-mail dans
**Adresse de réponse (facultatif)** si vous voulez une réponse. Vous pouvez aussi
écrire à support@hex.pro.

Si un scan ou une écriture échoue, retrouvez le message que vous avez vu dans
[Si un tag ne peut être ni scanné ni écrit](troubleshooting.md).
