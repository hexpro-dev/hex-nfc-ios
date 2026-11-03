---
title: Etiquetas compatibles con Hex NFC
description: Qué chips reconoce la app, qué te dice de cada uno la tarjeta de información de la etiqueta y qué no puede leer un iPhone.
audience: user
pageKind: article
navTitle: Etiquetas compatibles
tags:
  - chips
---

Una pegatina de un paquete de etiquetas vacías, la tarjeta llave de un hotel y
la etiqueta de un libro de biblioteca parecen iguales en la mano. El chip que
llevan dentro no es el mismo, y de él depende cuánto puede contener la etiqueta
y si admite una contraseña. También depende de él que el iPhone pueda leer la
etiqueta o no.

Para tus propias etiquetas, compra etiquetas vacías de la familia NTAG. Una
etiqueta NTAG213 almacena 144 bytes, suficientes para una dirección web o un
contacto breve. Una NTAG215 almacena 504 bytes y una NTAG216, 888, que es lo
que necesita una nota larga o un montón de registros. Las tres admiten una
contraseña y se pueden bloquear. Una etiqueta que no has comprado vacía suele
estar llena de datos que solo entiende quien la emitió. La llave de un hotel,
una tarjeta de transporte y una tarjeta de acceso a un edificio son etiquetas
de ese tipo.

Para saber qué etiqueta tienes en la mano, escanéala. Lo que ha leído la app se
abre en la pantalla Etiqueta. La tarjeta de la parte superior de esa pantalla
es la tarjeta de información de la etiqueta, que lleva como título el nombre
del propio chip. [Escanear una etiqueta](scan-a-tag.md) explica paso a paso el
escaneo.

Ese nombre es una referencia de fabricante, así que es lo que debes buscar
cuando quieras saber qué admite una etiqueta. Lo que hace la app con cada chip
se detalla, chip a chip, en la
[matriz de compatibilidad de chips](../developer/chip-support-matrix.md). Esa
página forma parte de la documentación para desarrolladores y no de este
manual, por eso habla de comandos y de ejecuciones de pruebas.

## Los nombres que muestra la app

El título de la tarjeta de información de la etiqueta es el nombre del propio
chip. Estos son los nombres que puede mostrar.

:::table[Los nombres de chip que puede mostrar la tarjeta de información de la etiqueta]
| Familia | Nombres en la tarjeta de información de la etiqueta |
| --- | --- |
| NTAG | NTAG 210µ, NTAG213, NTAG213 TT, NTAG215, NTAG216, NTAG424 DNA |
| MIFARE Ultralight | MIFARE Ultralight EV1 (48b), MIFARE Ultralight EV1 (128b), MIFARE Ultralight C |
| MIFARE DESFire | MIFARE DESFire, MIFARE DESFire EV1, MIFARE DESFire EV2, MIFARE DESFire EV3 |
| EM Microelectronic | EM V10, EM V11, EM V16 |
| ICODE | ICODE SLIX, ICODE SLIX2 |
| Solo con el nombre de la familia | ISO 15693, FeliCa, Pasaporte electrónico, NFC Forum Type 4, Dispositivo de salud |
:::

La última fila es lo que ves cuando el chip responde como miembro de una
familia pero no dice qué modelo es. Una tarjeta de transporte japonesa aparece
como FeliCa y abre su propio resultado, que se explica en
[Leer una tarjeta de transporte](transit-cards.md). Un pasaporte aparece como
Pasaporte electrónico, un caso que se explica en
[Leer un pasaporte](passports.md).

Una etiqueta Type 4 de un fabricante que no es NXP aparece como NFC Forum Type 4,
igual que un teléfono Android configurado para actuar como etiqueta. La app lee
y escribe sus registros como los de cualquier otra etiqueta. No puede saber qué
chip lleva dentro, así que la tarjeta no muestra la fila **Memoria**, y no hay
contraseña, bloqueo permanente ni **Volcado de memoria** para ella. Un
dispositivo de salud aparece como Dispositivo de salud, un caso que se explica
más abajo en [Dispositivos de salud](#health-devices).

Algunos chips no dicen nada que una app NFC pueda asociar a una referencia. En
ese caso, la tarjeta muestra una fila **Reportado** y una fila
**Bytes de versión** en lugar de un nombre, que son lo que la etiqueta dice de
sí misma. Esa etiqueta se puede seguir leyendo y escribiendo como una etiqueta
normal. Lo que pierde es todo lo que depende de conocer la organización de la
memoria del chip. Eso descarta una contraseña, un bloqueo permanente y
**Volcado de memoria**, la operación que explica
[Guardar una copia de la memoria de una etiqueta](memory-dump.md).

## Lo que dice la tarjeta sobre el chip

Dos filas resumen el chip. **Admite** enumera lo que la app puede hacer con él,
como «Lectura», «Escritura», «Contraseña» o «Bloqueo». «Escritura» significa
que la etiqueta acepta un mensaje nuevo, como en
[Escribir un enlace en una etiqueta](write-a-link.md). «Contraseña» significa
que puede tener una propia, como se explica en
[Proteger una etiqueta con contraseña](protect-a-tag.md). «Bloqueo» significa
que la etiqueta se puede dejar de solo lectura. Eso no se puede deshacer en
ninguna etiqueta, y por eso
[Bloquear una etiqueta permanentemente](permanent-lock.md) tiene una página
propia. **Funciones** enumera los extras que lleva el chip, como «Contador de
lecturas» o «Bucle antimanipulación».

Debajo aparecen filas que solo se muestran cuando el chip ha respondido sobre
ellas. Si falta una fila, significa que el chip no ha dicho nada al respecto, nunca
que el escaneo haya fallado.

Una fila **Manipulación** corresponde a un chip con bucle antimanipulación, que
hoy en día significa un NTAG213 TT. Muestra «Precinto intacto» mientras el
bucle está entero, y «Abierto» una vez que se ha roto. Un bucle roto no se
recupera. Si la app indica que un precinto está abierto, ya lo estaba cuando
has encontrado la etiqueta. Ningún escaneo tuyo lo ha roto.

Una fila **Veces leída** procede de un chip con contador de lecturas y muestra
el número de lecturas que ha contado el chip. «Contador desactivado» no es lo
mismo que una fila que falta: el contador existe y está desactivado, que es
como salen de fábrica la mayoría de las etiquetas.

Una fila **Contadores** procede de un MIFARE Ultralight EV1, en cualquiera de
sus dos tamaños. Ese chip tiene tres contadores propios, y la fila muestra los
tres en una sola línea. Una segunda fila **Contadores** que dice «Se detectó
una interrupción de escritura» significa que el chip informa de que esos
contadores no están intactos. Un MIFARE Ultralight C no muestra ninguna de las
dos filas, porque su contador responde a un comando que la app no envía.

Una fila **Firma** muestra «Firma de originalidad NXP» cuando el chip ha
respondido con una firma de 32 bytes. Muestra «No es una firma NXP estándar»
cuando la respuesta era más corta. Ninguna de las dos líneas es un veredicto
sobre si una etiqueta es auténtica. La app anota lo que ha respondido el chip y
no lo compara con nada.

## Dispositivos de salud {#health-devices}

Algunos dispositivos médicos responden al iPhone como lo hace una etiqueta,
como las plumas de insulina NovoPen 6 y NovoPen Echo Plus. Hex NFC reconoce uno
por lo que dice de sí mismo y abre una pantalla **Dispositivo de salud** en
lugar de la pantalla Etiqueta. Para una pluma que sabe nombrar, el título es
**Pluma inteligente de Novo Nordisk**. La pantalla dice que Hex NFC no lee el
historial de dosis de la pluma, y una tarjeta debajo nombra una app que sí lo
lee, con un botón para descargarla del App Store y un enlace a la lista de apps
del fabricante de la pluma que la leen. Cualquier otro dispositivo de salud
lleva el título **Dispositivo de salud** y ninguna sugerencia de app.

Hex NFC solo lee lo que el dispositivo dice de sí mismo y nunca escribe en él.
Una escritura, una operación o un comando de la consola de **Avanzado** dirigido
a un dispositivo de salud se detiene antes de escribir o enviar nada. No se
guarda nada del dispositivo, así que no aparece en tu historial. Toca
**Cerrar** para salir de la pantalla.

## Lo que un iPhone no puede leer

Hay una tarjeta muy común que ningún iPhone puede leer. Una MIFARE Classic
detiene el escaneo con un mensaje que lo indica: la etiqueta no está
defectuosa, y ninguna app NFC de iOS llega más lejos.
[¿Por qué el iPhone no puede leer esta etiqueta en absoluto?](troubleshooting.md#tag-not-readable)
muestra el mensaje y el motivo.

Con una tarjeta MIFARE DESFire, el límite es el mismo pero menos estricto.
Hex NFC muestra el nombre de la tarjeta y puede enviarle comandos en crudo. Lee
registros cuando la tarjeta tiene una aplicación NDEF, y los escribe cuando esa
aplicación lo permite. A una tarjeta MIFARE DESFire EV1, EV2 o EV3 en blanco se
le puede añadir una con **Formatear**, y **Quitar configuración NDEF** la vuelve
a quitar. Las dos están en **Acciones peligrosas**, en la pantalla
**Operaciones**: consulta
[Formatear una etiqueta](erase-or-format.md#format-a-tag) y
[Quitar la configuración NDEF de una tarjeta](erase-or-format.md#remove-ndef-setup).
Una tarjeta emitida para otro uso, como una tarjeta de transporte o de acceso,
tiene sus datos protegidos por claves que guarda quien la emitió. La app se
niega a configurarla y la deja como está.

Si una etiqueta que crees compatible sigue sin escanearse, la causa suele ser
la forma de acercarla más que el chip. Consulta
[Si no se puede escanear o escribir una etiqueta](troubleshooting.md).
