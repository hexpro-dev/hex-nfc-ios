---
title: Leer una tarjeta de transporte
description: Acerca al iPhone una tarjeta Suica, PASMO u otra tarjeta de transporte japonesa para ver su saldo y sus últimos viajes en Hex NFC.
audience: user
pageKind: howto
navTitle: Tarjetas de transporte
tags:
  - scanning
---

Acerca al iPhone una tarjeta de transporte IC japonesa y Hex NFC te muestra el
saldo que le queda y los viajes que recuerda. Suica, PASMO, ICOCA, TOICA,
manaca, SUGOCA, nimoca, Kitaca y el resto de la familia de tarjetas IC
japonesas funcionan sobre un mismo sistema. Todas se leen de la misma forma.
Aquí no se leen tarjetas de transporte de otros países, y
[Etiquetas compatibles con Hex NFC](tags-that-work.md) indica lo que sí lee la
app.

Antes de empezar, necesitas la app instalada desde el App Store en un iPhone
que lea etiquetas NFC. También necesitas sacar la tarjeta de la cartera.
[Leer tu primera etiqueta](quick-start.md) explica cómo instalar la app y leer
una etiqueta, y [Preguntas frecuentes](faq.md) indica qué modelos de iPhone
necesita la app. Una tarjeta de transporte solo se lee, nunca se modifica, así
que aquí no hay forma de recargar una tarjeta.

## Leer una tarjeta de transporte

::::steps
:::step[Abrir Hex NFC]
Abre Hex NFC. Se abre la pantalla de inicio de Hex NFC, con el recuadro
**Escanear**.
:::

:::step[Abrir la pantalla de escaneo]
Toca **Escanear**. Se abre la pantalla de escaneo, que muestra «Acerca la
etiqueta a la parte superior del iPhone».
:::

:::step[Acercar la tarjeta al iPhone]
Acerca la tarjeta en plano a la parte trasera del iPhone, cerca de su borde
superior. Mantén los dos quietos hasta que la pantalla muestre «Etiqueta
detectada», que indica que la lectura ha terminado. Si no pasa nada al cabo de
unos segundos, mueve un poco la tarjeta y vuelve a acercarla. Si prefieres
parar, toca Cancelar en el panel de escaneo de iOS. Así vuelves a la
pantalla de inicio de Hex NFC. Si no
acercas ninguna tarjeta, la lectura termina por sí sola y la pantalla muestra
«No se encontró ninguna etiqueta» con **Reintentar** debajo.
:::

:::step[Esperar a que se abra la tarjeta]
Aparta la tarjeta. Al cabo de un segundo, más o menos, la pantalla
**Tarjeta de transporte** se abre sola.
:::

:::step[Cerrar la tarjeta]
Toca **Cerrar**. Vuelves a la pantalla de inicio de Hex NFC.
:::
::::

:::note[Solo sale del iPhone una parada a la que pongas nombre]
El saldo, los viajes y el UID de la propia tarjeta se quedan en el iPhone. Lo
único que la app envía a algún sitio es el nombre de una parada que escribes y
envías. Ese envío incluye también los códigos de la parada y el tipo de
tarjeta. [Poner nombre a una parada que la app no conoce](#name-a-stop) lo
explica.
:::

## Si no se encuentra la tarjeta

- Acerca una sola tarjeta cada vez, lejos de las demás tarjetas de tu cartera.
- Acerca la tarjeta a la parte trasera del iPhone cerca de su borde superior,
  no al centro de la parte trasera.
- Comprueba que la tarjeta es una tarjeta de transporte IC japonesa. Una
  tarjeta de otro sistema de transporte no abre la pantalla
  **Tarjeta de transporte**.
- Si una lectura empieza y luego falla, la pantalla muestra «Error al
  escanear» e indica qué ha fallado. Toca **Reintentar** y mantén la tarjeta
  quieta durante más tiempo.

[Si no se puede escanear o escribir una etiqueta](troubleshooting.md) trata el
resto de casos.

## Qué muestra la pantalla Tarjeta de transporte

La pantalla tiene tres partes, en este orden:

1. La tarjeta, con el sistema al que pertenece, como «Tarjeta de transporte IC
   (Suica / PASMO …)», y «Saldo» sobre el dinero que le queda, en yenes.
2. La [tarjeta de información de la etiqueta](tags-that-work.md), que describe
   el chip de la tarjeta. Dos de sus filas son exclusivas de las tarjetas de
   transporte: «Código de sistema» y «Transacciones», con el número de entradas
   leídas.
3. «Historial», la lista de lo que recuerda la tarjeta. Una tarjeta de
   transporte guarda sus 20 transacciones más recientes, así que esta lista
   tiene como máximo 20 filas. Una tarjeta que no informa de ninguna muestra en
   su lugar «No hay historial de transacciones en esta tarjeta».

Debajo de la lista, en ambos casos, la app recuerda lo que puede nombrar y lo
que no. El texto dice: «Se muestran los nombres de estación cuando están
disponibles; el resto de paradas aparecen con sus códigos de transporte en
crudo.»

## Qué indica una fila del historial

Una fila indica qué fue la transacción, el día en que se hizo y el saldo que
quedó después. Un viaje en tren muestra la parada por la que has entrado y, si la
tarjeta la ha registrado, la parada por la que has salido. Una parada que la app no puede
nombrar muestra una de dos cosas en lugar del nombre de la estación. Una es el
nombre de su línea seguido de un signo de interrogación. La otra es el código
de transporte en crudo de la parada.

Si la tarjeta no ha registrado la parada de entrada, ese extremo muestra
«Desconocido». Si no ha registrado la parada de salida, la fila muestra solo esa
parada, sin ninguna flecha detrás. Una fila sin fecha legible muestra «Fecha
desconocida» bajo su título.

Una transacción que no es un viaje en tren indica lo que ha ocurrido en lugar
de un trayecto:

- «Tarifa de autobús».
- «Recarga», cuando se añade dinero a la tarjeta.
- «Compra», cuando se compra algo en una tienda.
- «Transacción», para un bloque de la tarjeta que no encaja en ninguno de los
  casos anteriores.

VoiceOver lee un viaje en tren como «Viaje» antes de las dos paradas y la
fecha.

## Poner nombre a una parada que la app no conoce {#name-a-stop}

Una parada que todavía no tiene nombre es una en la que has estado, porque
figura en tu tarjeta. Puedes decirle a la app cómo se llama. Cuando al menos
una parada de tren no tiene nombre, una tarjeta encima del historial dice
«Algunas de estas paradas aún no tienen nombre. Tú has estado en ellas:
ayúdanos a completarlas abajo.» Una línea debajo indica lo que incluye un
nombre. Dice: «El nombre que envíes nos llega para revisarlo y puede incluirse
en una actualización posterior. Incluye los códigos de la parada, el tipo de
tarjeta y el nombre que escribiste. No se envía nada más de la tarjeta.»

Una parada sin nombre es la que muestra una línea de tren y un signo de
interrogación, o un código de transporte en crudo, donde iría el nombre de la
estación.

::::steps
:::step[Buscar una fila del historial con una parada sin nombre]
Desplázate hasta la primera fila que muestre una. El campo de esa parada está
justo debajo de la fila. El texto que hay encima del campo indica la línea de
tren en la que está la parada. Si la línea también es desconocida, dice
«Parada desconocida».
:::

:::step[Introducir el nombre]
En **Poner nombre a esta estación**, introduce cómo se llama la parada.
:::

:::step[Enviar el nombre]
Toca **Enviar**. La app muestra «¡Gracias!» en lugar del campo; después, el
campo se cierra y sigue cerrado hasta que vuelvas a escanear la tarjeta.
:::
::::

Cada parada sin nombre tiene un solo campo, aunque pasen por ella varios
viajes. Un nombre que ya has enviado no se puede retirar. Si has enviado uno
equivocado, vuelve a escanear la tarjeta para que reaparezca el campo y envía
el nombre correcto. Todos los nombres se revisan antes de incluirse en la app,
así que un error no llega a la app por sí solo.

## Ver también

- [Leer tu primera etiqueta](quick-start.md)
- [Escanear una etiqueta](scan-a-tag.md)
- [Etiquetas compatibles con Hex NFC](tags-that-work.md)
- [Si no se puede escanear o escribir una etiqueta](troubleshooting.md)
- [La privacidad y tus datos](privacy.md)
