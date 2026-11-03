---
title: Enviar un comando en crudo a una etiqueta
description: Identifica un chip, ejecuta un preajuste de comandos y lee lo que devuelve la etiqueta en la Consola avanzada de Hex NFC.
audience: user
pageKind: howto
navTitle: Consola avanzada
tags:
  - chips
---

La Consola avanzada de Hex NFC envía bytes desde el iPhone directamente a una
etiqueta. Muestra el comando que ha salido, la respuesta que ha llegado y la
hora de cada uno. Ábrela cuando quieras ver las tramas en sí y no un resumen de
ellas.

Antes de empezar, ten la etiqueta a mano y la hoja de datos de su chip abierta.
La hoja de datos es el documento del propio fabricante sobre ese chip. Se
publica en el sitio web del fabricante con el nombre del chip, y el paso de
identificación que se describe más abajo te da ese nombre. Ninguna página de
este manual reproduce la hoja de datos, y la consola envía lo que escribas tanto
si la has leído como si no.

La consola ocupa una sola pantalla, y todos los controles que nombra esta página
están en ella. Arriba están el indicador de estado, con **Identificar** al lado,
y el interruptor **Omitir la identificación**. Después vienen el campo
**Comando**, con el botón **Ejecutar** al lado, y el selector entre **Esta
ejecución** y **Todo el tráfico NFC**. A continuación está el área de salida y,
al pie, **Preajustes**, con **Buscar** encima de las filas de preajustes.

## Identificar el chip

:::::steps
::::step[Abrir Hex NFC]
Abre Hex NFC. Aparece la pantalla de inicio de Hex NFC.
::::

::::step[Abrir la consola]
En esa pantalla, toca **Avanzado**, el último de los cuatro recuadros.
La segunda línea del recuadro dice «Consola de comandos en crudo». Se abre la
consola, y su área de salida vacía dice «Consola inactiva. Toca un preajuste a
la izquierda, o escribe una secuencia y ejecútala.» La lista de preajustes está
al pie de la pantalla. No está a la izquierda.

:::figure[La consola se abre con el indicador de estado en «Inactivo», el área de salida vacía y **Preajustes** al pie de la pantalla.]
![La Consola avanzada nada más abrirse. El indicador de estado de la esquina superior izquierda dice «Inactivo», con Identificar a su derecha y el interruptor Omitir la identificación debajo. El campo Comando muestra su secuencia de ejemplo, el área de salida solo contiene el texto de consola inactiva, y la lista de preajustes empieza por Leer 16 bytes, Escribir 4 bytes y Poner en HALT.](../../../assets/es/advanced-console--idle.png)
:::
::::

::::step[Iniciar el escaneo de identificación]
Toca **Identificar**, la cápsula a la derecha del indicador de estado. El área
de salida añade «Identificando la etiqueta…» y aparece el panel de escaneo de
iOS con «Acerca la etiqueta para identificarla.»
::::

::::step[Acercar la etiqueta al iPhone]
Apoya el borde superior del iPhone en plano sobre la etiqueta y mantenlo quieto.
El área de salida muestra el nombre del chip y el UID de la etiqueta, y el
nombre del chip aparece junto a **Preajustes**. La línea dice
«Identificada: NTAG213 · 04:4C:25:0A:30:1F:91».

:::figure[Tras un escaneo de identificación, el área de salida muestra el nombre del chip y su UID, y el nombre del chip aparece junto a **Preajustes**, con los preajustes de ese chip al principio de la lista.]
![La Consola avanzada tras identificar un NTAG213. El área de salida muestra dos líneas, «Identificando la etiqueta…» y después «Identificada: NTAG213 · 04:4C:25:0A:30:1F:91». Una insignia verde NTAG213 con un botón para quitarla aparece junto a Preajustes, y los dos primeros preajustes de la lista son para el NTAG213.](../../../assets/es/advanced-console--identified.png)
:::
::::
:::::

Un chip identificado reordena la lista de preajustes. Los preajustes escritos
para ese chip encabezan la lista. Debajo están los que también se le aplican:

- los preajustes escritos para todo el tipo de chip
- los preajustes de un chip hermano de la misma línea, como un preajuste de
  NTAG215 en un NTAG216

Ninguno de los dos tipos aparece atenuado. Aun así, los bytes de un chip hermano
pueden apuntar a una página equivocada de tu chip, así que léelos primero en
**Comando**. Un preajuste solo aparece atenuado cuando es para otra línea de
chips o para un tipo de etiqueta completamente distinto. Un preajuste atenuado
se carga igualmente en **Comando** al tocarlo. Para olvidar el chip, toca su
nombre junto a **Preajustes** y la lista vuelve a su orden habitual.

Cuando la app no sabe qué chip es, la consola dice
«Etiqueta conectada, pero el chip es desconocido · 04:BA:4A:92:1B:21:90».
Después muestra lo que la etiqueta ha dicho de sí misma. La primera línea dice
algo como «Reportado: NXP · NTAG · 128-256 bytes · v1.0». Esa línea contiene el
fabricante del chip, la familia de productos, el tamaño de memoria que declara
el chip y su versión de producto.
La segunda línea son los bytes en crudo de los que se ha leído la primera, como
«GET_VERSION: 00:04:04:02:01:00:0F:03». Toca una línea para copiarla. Aparece
una cápsula «Copiado» durante un segundo, más o menos, y los bytes quedan en el
portapapeles para un informe de errores.

## Qué contienen los preajustes

Un preajuste de **Preajustes** es una secuencia de comandos guardada que viene
incluida en la app. Cada fila contiene tres cosas y nada más: el nombre del
preajuste, una insignia con la familia de chips para la que se escribió y los
propios bytes. Algunos leen una etiqueta y otros escriben en ella, incluso en
páginas en las que un chip solo admite una escritura.

Detrás de una fila no hay ninguna descripción, así que los bytes son la única
explicación de lo que hace un preajuste. Léelos en **Comando** y compáralos con
la hoja de datos de tu chip antes de ejecutar nada. En los chips Type 2 que
llevan la mayoría de las pegatinas y tarjetas, un comando que empieza por `30` o
`3A` lee, y uno que empieza por `A2` escribe. Para ver la consola en
funcionamiento sin cambiar ninguna etiqueta, empieza por la fila llamada **Leer
16 bytes**, cuyos bytes son `30:00`.

## Ejecutar un comando

:::::steps
::::step[Cargar un preajuste]
Toca un preajuste de la lista de **Preajustes**. Sus bytes pasan a **Comando** y
la consola anota el nombre del preajuste que has cargado. No se ha enviado nada.
::::

::::step[Comprobar lo que se va a enviar]
Lee la secuencia de **Comando** y modifícala si hace falta. Cada par de dígitos
hexadecimales es un byte, los dos puntos separan los bytes dentro de un comando
y una coma separa un comando del siguiente. Con el campo vacío se ve el ejemplo
«21:60:00, A2:04:E1:10:06:00». Ese ejemplo es un texto de marcador de posición y
no está dentro del campo. No se envía nada mientras el campo está vacío, y
**Ejecutar** sigue atenuado hasta que cargas un preajuste o escribes una
secuencia. Leído como ejemplo, son dos comandos de tres y seis bytes, y el
segundo escribe cuatro bytes en una página.
::::

::::step[Enviarlo]
Toca el botón **Ejecutar**. El indicador de estado dice «Sondeando…», el área de
salida añade «Sondeando la etiqueta…» y aparece el panel de escaneo de iOS con
«Acerca la etiqueta para enviar el comando.»
::::

::::step[Acercar la etiqueta al iPhone]
Apoya el borde superior del iPhone en plano sobre la etiqueta y mantenlo quieto.
El área de salida añade una línea de conexión con el UID de la etiqueta y el
chip, como «Conectada: 04:4C:25:0A:30:1F:91 · ntag213». Después, el indicador de
estado dice «Ejecutando…» mientras salen los comandos.

Para detenerte antes de que ningún byte llegue a una etiqueta, toca Cancelar en
el panel de escaneo de iOS. La ejecución termina, el indicador de estado vuelve a
«Inactivo» y el área de salida dice «Cancelado antes de encontrar una etiqueta.
No se envió nada.» Si lo dejas sin ninguna etiqueta delante, el panel se cierra
solo y el indicador de estado dice «No se encontró ninguna etiqueta». Una vez
que la consola ha leído una etiqueta, desde **Ejecutar** o **Identificar**, una
cancelación o un tiempo de espera agotado en una ejecución posterior se registra
en cambio como una línea de error.
::::

::::step[Leer las respuestas]
Cada comando añade una línea de envío y una línea de recepción, y la de
recepción indica cuántos bytes han vuelto. Después de la última respuesta, el
indicador de estado dice «Listo» y el área de salida termina con «Listo.»

:::figure[Tras ejecutar **Leer 16 bytes**, el área de salida contiene una línea de envío y una línea de recepción de 16 bytes, y el indicador de estado dice «Listo».]
![La Consola avanzada tras ejecutar el preajuste Leer 16 bytes en un NTAG213. El indicador de estado dice «Listo» y Comando contiene 30:00. El área de salida, desplazada hasta el final, muestra el pie de la línea del preajuste cargado, «Sondeando la etiqueta…», la línea de conexión con el UID y ntag213, una línea TX que envía 30:00, una línea RX marcada con 16 bytes con los bytes que devolvió la etiqueta y, por último, «Listo.»](../../../assets/es/advanced-console--run-finished.png)
:::
::::
:::::

:::warning[La consola no comprueba nada antes de enviar]
Un comando de escritura cambia la etiqueta en el momento en que sale. Algunas
páginas de un chip admiten una sola escritura en toda la vida de la etiqueta.
Un byte equivocado ahí no lo puede deshacer ningún comando posterior.
:::

Para encontrar un preajuste entre muchos, introduce parte de su nombre o de sus
bytes en **Buscar**, bajo el título **Preajustes**. También puedes prescindir de
la lista y escribir tu propia secuencia en **Comando**. Un comando que la
etiqueta rechaza termina la ejecución y el acercamiento, y todas las líneas que
ya están en el área de salida se quedan donde están.

## Ver todas las tramas, no solo las de esta ejecución

Encima del área de salida, toca **Todo el tráfico NFC**. La consola muestra
entonces todas las tramas que la app intercambia con una etiqueta. Aparecen
tanto las tramas de escaneos, escrituras y operaciones con etiquetas como las de
esta pantalla. Las tramas nuevas llegan a medida que se producen. Toca **Esta
ejecución** para volver al registro propio de la consola.

## Llegar a un chip que rechaza el sondeo

Activa **Omitir la identificación**, el interruptor que está entre el indicador
de estado y **Comando**, cuando una etiqueta no responde nada después de
conectarse. La app envía entonces tus comandos sin preguntar antes al chip qué
es. La ejecución indica que la etiqueta es desconocida en lugar de dar el nombre
del chip. El interruptor sigue activado hasta que lo desactivas; no se desactiva
solo cuando termina una ejecución. Mientras está activado, debajo del
interruptor aparece el motivo:
«Los comandos van directos al chip. Necesario para chips que rechazan GET_VERSION: el sondeo los detiene y todos los comandos posteriores fallan.»

Con el interruptor activado sigue haciéndose una comprobación. Cuando una
etiqueta podría ser un dispositivo de salud NFC, como una pluma de insulina, la
app lee solo lo justo para saberlo, y a un dispositivo de salud no le envía
ninguno de tus comandos.

## Si la consola informa de un error

Una línea de error termina la ejecución y, con ella, el acercamiento. El panel
de escaneo de iOS se cierra a la vez, así que, para enviar algo más, vuelve a
tocar **Ejecutar** y acerca la etiqueta.

- «No se pudo interpretar el comando.» significa que el texto de **Comando** no
  es una secuencia que la app pueda leer, y que no se ha enviado nada. Comprueba
  las tres reglas. Cada byte son dos dígitos hexadecimales, y los dos puntos van
  entre los bytes de un comando. Una coma va entre un comando y el siguiente.
- «No se pudo identificar la etiqueta.» significa que el escaneo de
  identificación ha terminado sin resultado. Toca **Identificar** y vuelve a
  acercar la etiqueta.
- «Esto es un dispositivo de salud. Hex NFC nunca escribe en dispositivos de
  salud ni les envía comandos.» significa que la etiqueta es un dispositivo
  médico, como una pluma de insulina. No se le ha enviado ninguno de tus
  comandos.
- «Ha ocurrido un error inesperado.» significa que la ejecución se ha detenido
  por un motivo para el que la app no tiene mejores palabras. El resto de la
  línea contiene el detalle.
- Cualquier otro mensaje en una línea de error es la explicación de la propia
  app sobre lo que ha hecho la etiqueta. El texto es el mismo que te habría dado
  un escaneo o una escritura.

Para saber qué suelen significar esos mensajes en la práctica, consulta
[Si no se puede escanear o escribir una etiqueta](troubleshooting.md).

## Ver también

- [Guardar una copia de la memoria de una etiqueta](memory-dump.md)
- [Etiquetas compatibles con Hex NFC](tags-that-work.md)
- [Matriz de compatibilidad de chips](../developer/chip-support-matrix.md)
