---
title: Lire un passeport
description: Lisez la puce d'un passeport électronique avec Hex NFC, à l'aide des informations de sa page photo, pour une seule session.
audience: user
pageKind: howto
navTitle: Passeports
tags:
  - scanning
  - privacy
---

Un passeport électronique conserve le contenu de sa page photo sur une puce : le
nom, le numéro, les dates et la photographie. Hex NFC lit cette puce et
présente ce qu'il a trouvé sur un seul écran. La puce ne s'ouvre qu'avec trois
informations imprimées dans le passeport. L'app vous les demande une fois que
le premier passage a trouvé la puce. Elle conserve le résultat tant que l'écran
est ouvert, et pas plus longtemps.

Avant de commencer, il vous faut l'app installée depuis l'App Store sur un
iPhone capable de lire les tags NFC, ainsi que le passeport lui-même.
[Lire votre premier tag](quick-start.md) explique comment installer l'app et
lire un tag.

Ouvrez le passeport à la page photo et gardez-le à portée de main. Le numéro de
passeport, la date de naissance et la date d'expiration y sont imprimés. Vous
pouvez les scanner avec la caméra ou les saisir. La page photo sert à lire ces
informations, pas à y poser le téléphone. Le symbole de la puce, un petit
rectangle contenant un cercle, est imprimé sur la couverture d'un passeport
électronique. Un passeport sans ce symbole ne contient pas de puce, et rien ici
ne pourra le lire.

## Lire un passeport {#read-a-passport}

::::steps
:::step[Ouvrir l'écran de scan]
Touchez **Scanner** sur l'écran d'accueil de Hex NFC. L'écran de scan s'ouvre
et affiche « Tenez le tag près du haut de l'iPhone ».
:::

:::step[Tenir le passeport contre l'iPhone]
Fermez le passeport, posez le haut de l'iPhone à plat sur la couverture avant et
maintenez-le immobile. Selon le passeport, l'antenne se trouve dans la
couverture avant, dans la couverture arrière ou dans la page photo. Si rien ne
se passe au bout de quelques secondes, essayez la couverture arrière, puis la
page photo ouverte. Ce premier passage identifie la puce puis se termine, et le
panneau de scan d'iOS se ferme avec lui. L'écran de scan affiche maintenant
« Passeport détecté » et présente les trois champs des informations qui ouvrent la puce :
**Numéro de passeport**, **Date de naissance** et **Date d'expiration**.
Au-dessus se trouve **Scanner la page photo**, qui remplit les trois avec la
caméra.
[Scanner les informations avec la caméra](#scan-the-details-with-the-camera)
décrit cette méthode, qui remplace les deux étapes suivantes.
:::

:::step[Saisir le numéro de passeport]
Dans **Numéro de passeport**, saisissez le numéro qui figure sur la page photo,
lettres comprises. Le champ affiche « par ex. PA1234567 » tant que vous n'avez
rien saisi.
:::

:::step[Choisir les deux dates]
Touchez **Date de naissance** et choisissez la date imprimée sur la page photo,
puis faites de même pour **Date d'expiration**. Chaque sélecteur s'ouvre sur
une date de départ choisie par l'app : vérifiez donc l'année autant que le
jour. La date d'expiration est celle à laquelle le passeport cesse d'être
valable, pas sa date de délivrance.
:::

:::step[Lancer la lecture]
Touchez **Lire le passeport**. Le bouton ne lance pas de lecture tant que le
champ du numéro de passeport est vide.
:::

:::step[Tenir de nouveau le passeport contre l'iPhone]
Tenez-le contre le haut de l'iPhone sans le bouger. Le panneau de scan d'iOS
suit la lecture avec « Connexion à votre passeport… »,
« Déverrouillage avec vos informations… »,
« Lecture des données du passeport… » et « Presque terminé… ». L'écran
**Passeport** s'ouvre à la fin.
:::
::::

Touchez **Fermer** une fois que vous avez lu ce qui vous intéressait.

## Scanner les informations avec la caméra {#scan-the-details-with-the-camera}

**Scanner la page photo** lit le numéro de passeport et les deux dates dans les
deux lignes de lecture automatique en bas de la page photo, celles composées de
lettres majuscules, de chiffres et de suites de signes <. Il n'y a pas de
bouton de déclenchement : les informations sont retenues dès que la caméra les
a lues.

::::steps
:::step[Ouvrir la caméra]
Sur l'écran de scan, une fois que le premier passage a trouvé le passeport,
touchez **Scanner la page photo**. La première fois, iOS vous demande si
Hex NFC peut utiliser la caméra. La caméra s'ouvre sous le titre
« Scannez la page photo ». Si vous n'autorisez pas la caméra, l'écran affiche à
la place « Accès à la caméra requis ».
:::

:::step[Placer la page photo dans le cadre]
Ouvrez le passeport à la page photo et tenez l'iPhone au-dessus. L'écran
montre le contour d'une page photo, avec un cadre le long de son bord
inférieur, et affiche
« Placez dans le cadre les deux lignes de lettres et de <<< en bas de la page photo. »
Déplacez le téléphone jusqu'à ce que la page
coïncide avec le contour et que ces deux lignes se trouvent dans le cadre.
Quand l'écran affiche « Ne bougez plus », gardez le téléphone immobile. Une
coche apparaît, l'écran affiche « C'est bon » avec le numéro et les deux dates,
et un instant plus tard vous revenez à l'écran de scan.
:::

:::step[Vérifier les informations]
Une carte intitulée « Informations lues sur la page photo » remplace maintenant
les champs et présente le numéro et les deux dates. Comparez chacun avec la
page photo. Pour en corriger un, touchez **Modifier** : la carte laisse place
aux champs, remplis avec ce que la caméra a lu. **Modifier** n'apparaît pas
lorsqu'une date de la page ne comporte pas de jour ou de mois imprimé. Pour
utiliser de nouveau la caméra, touchez **Scanner à nouveau**.
:::

:::step[Lancer la lecture]
Touchez **Lire le passeport**. Fermez le passeport et tenez-le contre le haut
de l'iPhone, comme à la dernière étape de [Lire un passeport](#read-a-passport).
:::
::::

Si le cadre ne trouve rien pendant quelques secondes, l'écran affiche
« Recherche en cours. Inclinez la page pour éviter les lumières vives, ou
essayez la lampe torche. » Les reflets sur le film plastique de la page photo
en sont la cause habituelle, et le bouton de la lampe torche en haut de l'écran
éclaire la page. Pour quitter la caméra et saisir les informations, touchez
**Saisir les informations**.

Si l'accès à la caméra est désactivé pour Hex NFC, l'écran affiche
« Accès à la caméra requis ». Touchez **Ouvrir Réglages** pour l'activer, ou
**Saisir les informations**.

## Ce que montre l'écran « Passeport »

L'écran est en lecture seule. Les lignes n'apparaissent que là où la puce a
répondu : un passeport qui contient moins de données affiche donc un écran plus
court.

- Le livret en haut présente la photographie lue sur la puce et les deux lignes
  de lecture automatique telles qu'elles sont imprimées dans le passeport.
  Certains passeports stockent la photographie dans un format qu'iOS ne lit
  pas ; le livret affiche alors une silhouette grise à la place. Rien d'autre ne
  change à l'écran.
- Sous **Détails du passeport** figurent le nom, les prénoms, le numéro de
  passeport, la nationalité, l'État émetteur, la date de naissance, le sexe et
  la date d'expiration.
- Une carte **Intégrité des données** apparaît lorsque la puce contenait un
  objet de sécurité.
- Une carte **Signature** apparaît lorsque la puce contenait une image de
  signature et que l'iPhone a pu l'afficher. Certains passeports stockent cette
  image dans un format qu'iOS ne lit pas, et aucune carte n'apparaît alors.
- Sous **Détails supplémentaires** figurent les informations complémentaires
  que portent certains passeports, notamment le lieu de naissance, l'adresse,
  le téléphone, la profession, l'autorité de délivrance et la date de
  délivrance.
- La carte en bas nomme la puce « Passeport électronique » et sa famille
  « eMRTD (ISO/IEC 14443-4) ». D'autres puces en indiquent davantage, comme le
  détaille la
  [matrice de prise en charge des puces](../developer/chip-support-matrix.md).

## Ce qu'indique le contrôle d'intégrité des données

Lorsque la puce a fourni une liste d'empreintes, l'app calcule les siennes pour
les données qu'elle a lues et compare les deux. La carte
**Intégrité des données** affiche alors « Probablement intact » ou
« Probablement altéré », et la même mention figure sur le livret en haut de
l'écran. La carte liste aussi les groupes de données vérifiés, l'algorithme
d'empreinte utilisé et tout groupe qui ne correspondait pas.

La carte précise la portée de cette comparaison : « Les groupes de données
correspondent à la liste d'empreintes de l'objet de sécurité de la puce. La
signature de cet objet n'est pas vérifiée : ce n'est donc pas une preuve que
les données sont intactes, ni un contrôle d'authenticité du passeport. »

:::important[Aucun des deux verdicts ne dit qu'un passeport est authentique]
Hex NFC ne vérifie pas qui a signé les données de la puce.
« Probablement intact » signifie que la puce est cohérente avec elle-même, ce
que n'importe qui ayant écrit l'intégralité de la puce pourrait obtenir.
:::

## Si les informations ne déverrouillent pas le passeport

L'écran de scan remplace son instruction par un message en rouge : « Ces
informations n'ont pas déverrouillé le passeport. Vérifiez-les sur la page
photo et réessayez. » Ce que vous avez saisi reste dans les champs, et les
informations issues de la caméra restent dans leur carte. Comparez chacune avec
la page photo, puis touchez **Lire le passeport** et présentez de nouveau le
passeport.

Lorsque les informations viennent de la caméra et qu'elle a trouvé une autre
lecture possible du numéro, le message affiche à la place « Ces informations
n'ont pas déverrouillé le passeport. La caméra a peut-être mal lu un caractère,
donc le prochain essai utilisera une autre lecture du numéro. » La carte
présente alors cette lecture. Comparez-la avec la page photo, puis touchez
**Lire le passeport** et présentez de nouveau le passeport. Une fois toutes les
lectures essayées, la carte revient à la première et le message à celui cité
plus haut. Si la carte ne correspond toujours pas à la page photo, touchez
**Modifier** pour la corriger, ou **Scanner à nouveau**.

- Saisissez le numéro de passeport caractère par caractère, lettres comprises
  et sans espaces.
- Vérifiez l'année des deux dates. Un sélecteur de date resté sur la mauvaise
  décennie semble correct au premier coup d'œil.
- Réessayez une fois sans modifier les informations. Le même message couvre une
  lecture interrompue en cours de route, qu'un second passage plus stable
  corrige souvent.

Si rien ne se passe pendant que vous tenez le passeport, la puce ne répond pas.
[Si un tag ne peut être ni scanné ni écrit](troubleshooting.md) traite ce cas.
Le premier passage peut aussi afficher « Tag détecté » et ouvrir l'écran
**Tag**. Cela signifie que l'iPhone a atteint une puce sans la reconnaître
comme celle d'un passeport. Hex NFC ne peut pas lire cette puce comme un
passeport. Une carte de transport japonaise ouvre l'écran
**Carte de transport**, et [Lire une carte de transport](transit-cards.md)
traite ces cartes.

## Ce que l'app conserve

Rien. Les trois informations déverrouillent la puce pour cette seule lecture.
Lorsque vous scannez la page photo, l'image de la caméra est analysée sur
l'iPhone pour les trouver, et aucune image n'est enregistrée ni envoyée où que
ce soit. Une note figure sous les informations. Elle indique : « Ces
informations restent sur votre appareil, ne servent qu'à cette lecture, et ne
sont jamais enregistrées ni envoyées où que ce soit. »

Ce que renvoie la puce est traité de la même façon. La lecture d'un passeport
n'est jamais ajoutée à votre historique de scan, jamais exportée et jamais
envoyée nulle part. Toucher **Fermer** efface les données en même temps que
l'écran. Pour les revoir, il faut lire de nouveau le passeport. L'écran
**Passeport** porte une note semblable en bas. Elle indique : « Lu depuis la puce et
affiché ici pour cette session uniquement : rien n'est enregistré, rien n'est
envoyé, et l'authenticité n'est pas vérifiée. »

## Voir aussi

- [Lire une carte de transport](transit-cards.md)
- [Confidentialité et vos données](privacy.md)
- [Retrouver un tag scanné auparavant](scan-history.md)
