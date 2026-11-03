---
title: Lire une carte de transport
description: Tenez une carte Suica, PASMO ou une autre carte de transport japonaise contre l'iPhone pour voir son solde et ses trajets récents dans Hex NFC.
audience: user
pageKind: howto
navTitle: Cartes de transport
tags:
  - scanning
---

Tenez une carte de transport IC japonaise contre l'iPhone, et Hex NFC affiche
le solde qui y reste et les trajets qu'elle a gardés en mémoire. Suica, PASMO,
ICOCA, TOICA, manaca, SUGOCA, nimoca, Kitaca et les autres cartes IC
japonaises reposent toutes sur un même système. Elles se lisent toutes de la
même façon. Une carte de transport d'un autre pays n'est pas lue ici, et
[Tags compatibles avec Hex NFC](tags-that-work.md) indique ce que l'app lit.

Avant de commencer, il vous faut l'app installée depuis l'App Store sur un
iPhone capable de lire les tags NFC. Il vous faut aussi la carte, sortie de
votre portefeuille. [Lire votre premier tag](quick-start.md) explique comment
installer l'app et lire un tag, et [Questions fréquentes](faq.md) indique les
iPhone dont l'app a besoin. Une carte de transport est uniquement lue, jamais
modifiée : il est donc impossible de recharger une carte ici.

## Lire une carte de transport

::::steps
:::step[Ouvrir Hex NFC]
Ouvrez Hex NFC. L'écran d'accueil de l'app s'ouvre, avec la tuile **Scanner**.
:::

:::step[Ouvrir l'écran de scan]
Touchez **Scanner**. L'écran de scan s'ouvre et affiche
« Tenez le tag près du haut de l'iPhone ».
:::

:::step[Tenir la carte contre l'iPhone]
Tenez la carte à plat contre le dos de l'iPhone, près de son bord supérieur.
Gardez-les immobiles jusqu'à ce que l'écran affiche « Tag détecté », signe que
la lecture est terminée. Si rien ne se passe au bout de quelques secondes,
déplacez légèrement la carte et présentez-la à nouveau. Pour arrêter, touchez
plutôt Annuler sur le panneau de scan d'iOS. Vous revenez alors à l'écran d'accueil de l'app. Si aucune
carte n'est approchée, la lecture s'arrête d'elle-même et l'écran affiche
« Aucun tag trouvé », avec **Réessayer** en dessous.
:::

:::step[Attendre l'ouverture de la carte]
Éloignez la carte. Au bout d'une seconde environ, l'écran
**Carte de transport** s'ouvre de lui-même.
:::

:::step[Fermer la carte]
Touchez **Fermer**. Vous revenez à l'écran d'accueil de l'app.
:::
::::

:::note[Seul un arrêt que vous nommez quitte l'iPhone]
Le solde, les trajets et l'UID de la carte restent sur l'iPhone. La seule chose
que l'app envoie est un nom d'arrêt que vous saisissez et envoyez. Il transmet
aussi les codes de l'arrêt et le type de carte.
[Nommer un arrêt que l'app n'a pas su nommer](#name-a-stop) explique comment
faire.
:::

## Si la carte n'est pas détectée

- Tenez une seule carte à la fois, à l'écart des autres cartes de votre
  portefeuille.
- Tenez la carte contre le dos de l'iPhone, près de son bord supérieur, et non
  contre le milieu du dos.
- Vérifiez qu'il s'agit bien d'une carte de transport IC japonaise. Une carte
  d'un autre réseau de transport n'ouvre pas l'écran **Carte de transport**.
- Si une lecture commence puis échoue, l'écran affiche « Échec du scan » et
  indique ce qui n'a pas fonctionné. Touchez **Réessayer** et tenez la carte
  immobile plus longtemps.

[Si un tag ne peut être ni scanné ni écrit](troubleshooting.md) traite les
autres cas.

## Ce que montre l'écran « Carte de transport »

L'écran comporte trois parties, dans cet ordre :

1. La carte, avec le système auquel elle appartient, par exemple
   « Carte de transport IC (Suica / PASMO …) », et « Solde » au-dessus du
   montant restant, en yens.
2. La [carte d'informations du tag](tags-that-work.md), qui décrit la puce de
   la carte. Deux de ses lignes sont propres aux cartes de transport :
   « Code système », et « Transactions » pour le nombre d'entrées lues.
3. « Historique », la liste de ce que la carte a gardé en mémoire. Une carte de
   transport conserve ses 20 transactions les plus récentes : cette liste
   contient donc 20 lignes au maximum. Une carte qui n'en signale aucune
   affiche à la place « Aucun historique de transactions sur cette carte ».

Sous la liste, dans les deux cas, l'app rappelle ce qu'elle peut nommer et ce
qu'elle ne peut pas nommer. Le texte indique : « Les noms de station sont
affichés lorsqu'ils sont connus ; les autres arrêts apparaissent sous forme de
codes bruts. »

## Ce qu'indique une ligne de l'historique

Une ligne indique la nature de la transaction, le jour où elle a eu lieu et le
solde restant après elle. Un trajet en train affiche l'arrêt d'entrée et, si la
carte l'a enregistré, l'arrêt de sortie. Un arrêt que l'app ne sait pas nommer
affiche l'une de deux choses à la place du nom de la station. La première est
le nom de sa ligne de train, suivi d'un point d'interrogation. La seconde est
le code de transport brut de l'arrêt.

Si la carte n'a enregistré aucun arrêt d'entrée, ce côté du trajet affiche
« Inconnu ». Si elle n'a enregistré aucun arrêt de sortie, la ligne affiche
l'arrêt seul, sans flèche après lui. Une ligne sans date lisible affiche
« Date inconnue » sous son titre.

Une transaction qui n'est pas un trajet en train indique ce qui s'est passé à
la place d'un itinéraire :

- « Trajet en bus ».
- « Rechargement » pour de l'argent ajouté sur la carte.
- « Achat » pour un achat en magasin.
- « Transaction » pour un bloc de la carte qui ne correspond à aucun de ces
  cas.

VoiceOver annonce un trajet en train par « Trajet », suivi des deux arrêts et
de la date.

## Nommer un arrêt que l'app n'a pas su nommer {#name-a-stop}

Un arrêt encore sans nom est un arrêt où vous êtes passé, puisqu'il figure sur
votre carte. Vous pouvez indiquer à l'app comment il s'appelle. Lorsqu'au moins
un arrêt de train n'a pas de nom, une carte au-dessus de l'historique affiche
« Certains de ces arrêts n'ont pas encore de nom. Vous y êtes passé : aidez-nous
à compléter ci-dessous. » Une ligne en dessous précise ce que transmet un nom.
Elle indique : « Le nom que vous envoyez nous parvient pour vérification et
pourra être intégré à une mise à jour ultérieure. Il comprend les codes de
l'arrêt, le type de carte et le nom que vous avez saisi. Rien d'autre de la
carte n'est envoyé. »

Un arrêt sans nom est celui qui affiche une ligne de train et un point
d'interrogation, ou un code de transport brut, à l'endroit où figurerait le nom
d'une station.

::::steps
:::step[Trouver une ligne de l'historique avec un arrêt sans nom]
Faites défiler jusqu'à la première ligne qui en affiche un. Le champ de cet
arrêt se trouve juste sous la ligne. Le texte au-dessus du champ indique la
ligne de train sur laquelle se trouve l'arrêt. Si cette ligne de train est elle
aussi inconnue, il affiche « Arrêt inconnu ».
:::

:::step[Saisir le nom]
Dans **Nommer cette station**, saisissez le nom de l'arrêt.
:::

:::step[Envoyer le nom]
Touchez **Envoyer**. L'app affiche « Merci ! » à la place du champ, puis le
champ se ferme et reste fermé jusqu'à ce que vous scanniez de nouveau la carte.
:::
::::

Chaque arrêt sans nom dispose d'un seul champ, même lorsque plusieurs trajets y
passent. Un nom envoyé ne peut pas être retiré. Si vous avez envoyé un nom
erroné, scannez de nouveau la carte pour faire réapparaître le champ, puis
envoyez le bon nom. Chaque nom est vérifié avant d'être intégré à l'app : une
erreur n'y parvient donc pas d'elle-même.

## Voir aussi

- [Lire votre premier tag](quick-start.md)
- [Scanner un tag](scan-a-tag.md)
- [Tags compatibles avec Hex NFC](tags-that-work.md)
- [Si un tag ne peut être ni scanné ni écrit](troubleshooting.md)
- [Confidentialité et vos données](privacy.md)
