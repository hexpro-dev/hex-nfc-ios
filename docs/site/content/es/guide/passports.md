---
title: Leer un pasaporte
description: Lee el chip de un pasaporte electrónico con Hex NFC, con los datos de su página de la fotografía, solo durante una sesión.
audience: user
pageKind: howto
navTitle: Pasaportes
tags:
  - scanning
  - privacy
---

Un pasaporte electrónico guarda su página de la fotografía en un chip: el
nombre, el número, las fechas y la fotografía. Hex NFC lee ese chip y muestra
lo que encuentra en una sola pantalla. El chip solo se abre con tres datos
impresos en el interior del pasaporte. La app te los pide después de que el
primer acercamiento encuentre el chip. Conserva el resultado mientras la
pantalla esté abierta, y no más.

Antes de empezar, necesitas la app instalada desde el App Store en un iPhone
que lea etiquetas NFC, y el propio pasaporte.
[Leer tu primera etiqueta](quick-start.md) explica cómo instalar la app y leer
una etiqueta.

Abre el pasaporte por la página de la fotografía y tenlo a mano. Ahí están
impresos el número de pasaporte, la fecha de nacimiento y la fecha de
caducidad. Puedes escanearlos con la cámara o escribirlos. En la página de la
fotografía lees esos datos, pero no es ahí donde se coloca el teléfono. El
símbolo del chip, un pequeño rectángulo con un círculo dentro, está impreso en
la cubierta de los pasaportes electrónicos. Un pasaporte sin ese símbolo no
lleva chip, y nada de lo que se explica aquí podrá leerlo.

## Leer un pasaporte {#read-a-passport}

::::steps
:::step[Abrir la pantalla de escaneo]
Toca **Escanear** en la pantalla de inicio de Hex NFC. Se abre la pantalla de
escaneo, que muestra «Acerca la etiqueta a la parte superior del iPhone».
:::

:::step[Acercar el pasaporte al iPhone]
Cierra el pasaporte, apoya el borde superior del iPhone en plano sobre la
cubierta delantera y mantenlo quieto. Según el pasaporte, la antena está en la
cubierta delantera, en la trasera o en la página de la fotografía. Si no pasa
nada al cabo de unos segundos, prueba con la cubierta trasera y después con la
página de la fotografía abierta. Este primer acercamiento identifica el chip y
termina, y el panel de escaneo de iOS se cierra con él. La pantalla de escaneo
muestra ahora «Pasaporte detectado» y los tres campos con los que se abre el
chip: **Número de pasaporte**, **Fecha de nacimiento** y
**Fecha de caducidad**. Encima está
**Escanear la página de la fotografía**, que rellena los tres con la cámara.
[Escanear los datos con la cámara](#scan-the-details-with-the-camera) explica
ese método, que sustituye a los dos pasos siguientes.
:::

:::step[Introducir el número de pasaporte]
En **Número de pasaporte**, introduce el número de la página de la fotografía,
con las letras incluidas. El campo muestra «p. ej. PA1234567» hasta que
escribes algo.
:::

:::step[Elegir las dos fechas]
Toca **Fecha de nacimiento** y elige la fecha impresa en la página de la
fotografía; después haz lo mismo con **Fecha de caducidad**. Cada selector se
abre en una fecha que la app ha elegido como punto de partida, así que
comprueba el año además del día. La fecha de caducidad es la fecha en que vence
el pasaporte, no la de expedición.
:::

:::step[Iniciar la lectura]
Toca **Leer pasaporte**. El botón no inicia ninguna lectura mientras el campo
del número de pasaporte esté vacío.
:::

:::step[Volver a acercar el pasaporte al iPhone]
Acércalo a la parte superior del iPhone y mantenlo ahí. El panel de escaneo de
iOS muestra el avance de la lectura con «Conectando con tu pasaporte…»,
«Desbloqueando con tus datos…», «Leyendo los datos del pasaporte…» y «Casi
listo…». La pantalla **Pasaporte** se abre cuando termina.
:::
::::

Toca **Cerrar** cuando hayas leído lo que buscabas.

## Escanear los datos con la cámara {#scan-the-details-with-the-camera}

**Escanear la página de la fotografía** lee el número de pasaporte y las dos
fechas de las dos líneas de lectura mecánica de la parte inferior de la página
de la fotografía, las formadas por letras mayúsculas, cifras y series de
signos <. No hay botón de disparo: los datos se capturan en cuanto la cámara
los ha leído.

::::steps
:::step[Abrir la cámara]
En la pantalla de escaneo, después de que el primer acercamiento haya
encontrado el pasaporte, toca **Escanear la página de la fotografía**. La
primera vez, iOS pregunta si Hex NFC puede usar la cámara. La cámara se abre
bajo el título «Escanea la página de la fotografía». Si no permites el acceso a
la cámara, la pantalla muestra en su lugar «Se necesita acceso a la cámara».
:::

:::step[Colocar la página de la fotografía en el marco]
Abre el pasaporte por la página de la fotografía y sostén el iPhone sobre ella.
La pantalla muestra el contorno de una página de la fotografía, con un marco a
lo largo de su borde inferior, y dice «Encaja dentro del marco las dos líneas
de letras y <<< de la parte inferior de la página de la fotografía.» Mueve el
teléfono hasta que la página coincida con el contorno y esas dos líneas queden
dentro del marco. Cuando la pantalla muestre «Mantén el iPhone quieto», no
muevas el teléfono. Aparece una marca de verificación, la pantalla muestra
«Listo» con el número y las dos fechas y, un momento después, vuelves a la
pantalla de escaneo.
:::

:::step[Comprobar los datos]
Una tarjeta con el título «Datos leídos de la página de la fotografía» ocupa
ahora el lugar de los campos y muestra el número y las dos fechas. Compara cada
uno con la página de la fotografía. Para corregir alguno, toca **Editar**: la
tarjeta deja paso a los campos, rellenados con lo que ha leído la cámara.
**Editar** no aparece cuando una fecha de la página no lleva impreso el día o
el mes. Para volver a usar la cámara, toca **Volver a escanear**.
:::

:::step[Iniciar la lectura]
Toca **Leer pasaporte**. Cierra el pasaporte y acércalo a la parte superior del
iPhone, como en el último paso de [Leer un pasaporte](#read-a-passport).
:::
::::

Si el marco no encuentra nada durante unos segundos, la pantalla muestra
«Seguimos buscando. Inclina la página para apartarla de las luces intensas o
prueba la linterna.» La causa habitual son los reflejos en la lámina de
plástico de la página de la fotografía, y el botón de la linterna de la parte
superior de la pantalla ilumina la página. Para salir de la cámara y escribir
los datos, toca **Introducir los datos a mano**.

Si el acceso a la cámara está desactivado para Hex NFC, la pantalla muestra
«Se necesita acceso a la cámara». Toca **Abrir Ajustes** para activarlo, o
**Introducir los datos a mano**.

## Qué muestra la pantalla Pasaporte

La pantalla es de solo lectura. Las filas solo aparecen cuando el chip ha
respondido, así que un pasaporte con menos datos muestra una pantalla más
corta.

- El cuadernillo de la parte superior muestra la fotografía del chip y las dos
  líneas de lectura mecánica tal como están impresas en el pasaporte. Algunos
  pasaportes guardan la fotografía en un formato que iOS no lee, y entonces el
  cuadernillo muestra en su lugar una silueta gris. Nada más cambia en la
  pantalla.
- En **Datos del pasaporte** aparecen los apellidos, el nombre, el número de
  pasaporte, la nacionalidad, el Estado emisor, la fecha de nacimiento, el sexo
  y la fecha de caducidad.
- Aparece una tarjeta **Integridad de los datos** cuando el chip lleva un
  objeto de seguridad.
- Aparece una tarjeta **Firma** cuando el chip contiene una imagen de la firma
  y el iPhone puede mostrarla. Algunos pasaportes guardan esa imagen en un
  formato que iOS no lee, y entonces no aparece ninguna tarjeta.
- En **Datos adicionales** aparecen los datos extra que llevan algunos
  pasaportes, entre ellos el lugar de nacimiento, la dirección, el teléfono, la
  profesión, la autoridad expedidora y la fecha de expedición.
- La tarjeta del pie llama al chip «Pasaporte electrónico» y a su familia
  «eMRTD (ISO/IEC 14443-4)». Otros chips informan de más datos, como explica la
  [matriz de compatibilidad de chips](../developer/chip-support-matrix.md).

## Qué te dice la comprobación de integridad de los datos

Cuando el chip proporciona una lista de hashes, la app calcula los suyos a
partir de los datos que ha leído y compara las dos listas. La tarjeta
**Integridad de los datos** muestra entonces «Probablemente intacto» o
«Probablemente alterado», y las mismas palabras aparecen en el cuadernillo de
la parte superior de la pantalla. La tarjeta también enumera los grupos de
datos que ha comprobado, el algoritmo de hash que ha usado y cualquier grupo que no
coincida.

La tarjeta indica lo que vale la comparación: «Los grupos de datos coinciden
con la lista de hashes del objeto de seguridad del chip. La firma de ese objeto
no se verifica, así que esto no prueba que los datos estén inalterados ni
comprueba la autenticidad del pasaporte.»

:::important[Ningún veredicto indica que un pasaporte sea auténtico]
Hex NFC no comprueba quién firmó los datos del chip. «Probablemente intacto»
significa que el chip es coherente consigo mismo, algo que podría conseguir
cualquiera que hubiera escrito el chip entero.
:::

## Si los datos no desbloquean el pasaporte

La pantalla de escaneo sustituye su indicación, en rojo, por «Esos datos no
desbloquearon el pasaporte. Compáralos con la página de la fotografía e
inténtalo de nuevo.» Lo que has escrito se queda en los campos, y los datos de
la cámara se quedan en su tarjeta. Compara cada uno con la página de la
fotografía, toca **Leer pasaporte** y vuelve a acercar el pasaporte.

Si los datos proceden de la cámara y esta ha encontrado otra lectura posible
del número, el mensaje dice en cambio «Esos datos no desbloquearon el pasaporte.
Puede que la cámara haya leído mal un carácter, así que el siguiente intento
usará otra lectura del número.» La tarjeta muestra entonces esa lectura.
Compárala con la página de la fotografía, toca **Leer pasaporte** y vuelve a
acercar el pasaporte. Cuando se han probado todas las lecturas, la tarjeta
vuelve a la primera y el mensaje, al anterior. Si la tarjeta sigue sin
coincidir con la página de la fotografía, toca **Editar** para corregirla, o
**Volver a escanear**.

- Introduce el número de pasaporte carácter por carácter, con las letras y sin
  espacios.
- Comprueba el año de las dos fechas. Un selector de fecha que se ha quedado en
  la década equivocada parece correcto a simple vista.
- Vuelve a intentarlo sin cambiar los datos. El mismo mensaje aparece cuando
  una lectura se interrumpe a medias, algo que suele resolverse con un segundo
  acercamiento más estable.

Si no pasa nada mientras acercas el pasaporte, el chip no está respondiendo.
[Si no se puede escanear o escribir una etiqueta](troubleshooting.md) trata ese
caso. El primer acercamiento también puede mostrar «Etiqueta detectada» y abrir
la pantalla **Etiqueta**. Eso significa que el iPhone ha llegado a un chip,
pero no lo ha reconocido como pasaporte. Hex NFC no puede leer ese chip como un
pasaporte. Una tarjeta de transporte japonesa abre la pantalla
**Tarjeta de transporte**, y
[Leer una tarjeta de transporte](transit-cards.md) explica esas tarjetas.

## Lo que guarda la app

Nada. Los tres datos desbloquean el chip solo para esa lectura. Cuando escaneas
la página de la fotografía, la imagen de la cámara se analiza en el iPhone para
encontrarlos, y no se guarda ni se envía ninguna imagen a ningún sitio. Debajo
de los datos hay una nota. Dice: «Estos datos permanecen en tu dispositivo, se
usan solo para esta lectura y nunca se guardan ni se envían a ningún sitio.»

Lo que devuelve el chip recibe el mismo trato. La lectura de un pasaporte nunca
se añade a tu historial de escaneos, nunca se exporta y nunca se envía a ningún
sitio. Al tocar **Cerrar**, los datos desaparecen con la pantalla. Para
volver a verlos, hay que leer de nuevo el pasaporte. La pantalla **Pasaporte**
lleva al pie una nota similar. Dice: «Leído del chip y mostrado aquí solo
durante esta sesión: no se guarda, no se envía y no se verifica su
autenticidad.»

## Ver también

- [Leer una tarjeta de transporte](transit-cards.md)
- [La privacidad y tus datos](privacy.md)
- [Buscar una etiqueta que has escaneado antes](scan-history.md)
