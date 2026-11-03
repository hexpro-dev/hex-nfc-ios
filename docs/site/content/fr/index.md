---
title: Documentation de Hex NFC
description: Commencez ici pour trouver le guide d'utilisation de Hex NFC, les documents techniques, l'aide, les pages juridiques de l'app et le contact sécurité.
audience: both
---

Ce site rassemble la documentation de Hex NFC, une app gratuite de Hex Pro
qui lit et écrit des tags NFC sur un iPhone. Le guide d'utilisation
s'adresse aux personnes qui utilisent l'app. Les documents techniques
s'adressent à celles qui lisent ou modifient son code.

## Le guide d'utilisation

Le [Guide d'utilisation de Hex NFC](guide/index.md) explique ce que fait
l'app et ce dont elle a besoin, et chaque tâche y a sa page : lire un tag,
écrire dessus, le protéger, et savoir quoi faire quand un tag ne répond pas.
Commencez par [Lire votre premier tag](guide/quick-start.md).

## Documents techniques

[Architecture](developer/architecture.md) s'adresse aux développeurs qui
travaillent sur l'app. La page parcourt le package Swift cible par cible, y
compris la façon dont les puces sont identifiées et dont les simulateurs de
puces remplacent les tags réels dans les tests, et se termine par les
conventions que suit le code.

Consultez la [matrice de prise en charge des
puces](developer/chip-support-matrix.md) avant d'acheter des tags à utiliser
avec l'app, ou quand un tag ne se comporte pas comme prévu. Chaque famille
de tags a son propre tableau. Le tableau FeliCa ne couvre que la lecture et
l'écriture ; les autres ajoutent la protection par mot de passe, le
verrouillage permanent et l'extraction mémoire. La page indique lesquels de
ces résultats ont été confirmés sur des tags réels et lesquels ne l'ont pas
été.

## Obtenir de l'aide {#get-help}

Quand un tag ne se scanne pas ou ne s'écrit pas,
[Si un tag ne peut être ni scanné ni écrit](guide/troubleshooting.md) passe en
revue chaque message de l'app et ce qu'il faut faire.
[Questions fréquentes](guide/faq.md) indique ce que coûte l'app et sur quels
iPhone elle fonctionne.

Dans l'app, touchez le bouton en forme d'engrenage de l'écran d'accueil, puis
**Envoyer un commentaire**. Le message arrive directement chez Hex Pro, et le
formulaire indique avant l'envoi ce qui l'accompagne (version de l'app, version
d'iOS, modèle de l'appareil et langue). Vous pouvez aussi écrire à
[support@hex.pro](mailto:support@hex.pro) ou utiliser le
[formulaire de contact de hex.pro](https://hex.pro/fr/contact?topic=support).
Les rapports de bug et les demandes de nouvelles puces sont les bienvenus sous
forme de [tickets sur GitHub](https://github.com/hexpro-dev/hex-nfc-ios/issues),
et la [page d'aide](https://apps.hex.pro/fr/hex-nfc/support) réunit tous les
moyens de joindre Hex Pro.

## Politique de confidentialité et conditions générales

La [politique de confidentialité](https://apps.hex.pro/hex-nfc/privacy) et
les [conditions générales](https://apps.hex.pro/hex-nfc/terms) de Hex NFC
sont publiées sur apps.hex.pro. Envoyez vos questions sur l'un ou l'autre de
ces documents à [support@hex.pro](mailto:support@hex.pro).

## Signaler un problème de sécurité

Signalez une vulnérabilité en privé à
[security@hex.pro](mailto:security@hex.pro), et non sur un forum public ou
dans un outil de suivi des tickets. Hex Pro accuse réception d'un
signalement sous 72 heures, puis travaille avec son auteur sur un correctif
et sur une date de divulgation publique. Le problème est rendu public une
fois le correctif publié, ou 90 jours après le signalement si cette date
arrive plus tôt, et l'auteur du signalement est cité, sauf s'il préfère ne
pas l'être.
