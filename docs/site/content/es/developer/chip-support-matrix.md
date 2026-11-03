---
title: Matriz de compatibilidad de chips
description: Qué chips NFC lee Hex NFC en el iPhone, en cuáles escribe, cuáles protege con contraseña y bloquea, y cuánto se ha confirmado con etiquetas reales.
audience: developer
tags:
  - chips
---

Esta página recoge qué chips NFC puede leer Hex NFC en el iPhone, en cuáles
puede escribir, cuáles puede proteger con contraseña y cuáles puede bloquear, y
hasta qué punto se ha confirmado todo ello con etiquetas reales. Si falta un
chip del que dependes, o se comporta de forma distinta a lo que dice la
página, escribe a [support@hex.pro](mailto:support@hex.pro) con el nombre del
chip y lo que ha pasado.

## Leyenda

| Estado | Significado |
|---|---|
| ✅ | Funciona, y se ha confirmado con etiquetas reales |
| ⚠️ | Implementado, con una salvedad en las notas de la fila o en el texto que rodea su tabla (a menudo, que no se ha confirmado con una etiqueta real) |
| ❌ | La app lo rechaza o no puede hacerlo |
| — | No aplicable |

NTAG 210µ, NTAG213, NTAG216, NTAG424 DNA, MIFARE Ultralight EV1 de 128 bytes,
MIFARE Ultralight C, ICODE SLIX2 y MIFARE DESFire EV3 se probaron con
etiquetas físicas en agosto de 2026, y el lector de transporte se ha
confirmado con tarjetas Suica y PASMO reales. En octubre de 2026 se
confirmaron con una tarjeta real la configuración de una MIFARE DESFire EV3
como etiqueta NDEF, una escritura, una lectura y la eliminación de esa
configuración. Las secuencias para proteger y
para quitar la protección se reescribieron para todas las familias en
septiembre de 2026, y NTAG213 es el único chip que ha ejecutado el código de
protección reescrito en una etiqueta real, y solo para la protección contra
escritura, así que ninguna celda de Contraseña lleva ✅. Todavía no se ha
hecho ningún volcado de memoria de una etiqueta real, así que ninguna celda de
Volcado lleva ✅. La propia operación Volcado de memoria solo se ha ejecutado
con los simuladores de NTAG213 y NTAG215. Algunas de las etiquetas probadas no
se comportan como piezas de NXP: las etiquetas Ultralight C repiten bytes del
UID de una etiqueta a otra, y un NTAG216 devolvió una firma de originalidad
corta, así que puede que los resultados con esos dos chips no sean
extrapolables a chips NXP auténticos.

Las filas marcadas como solo simulador se basan únicamente en los simuladores
de chip a nivel de protocolo, y las marcadas como sin probar no se han
ejecutado con una etiqueta real ni, cuando la nota lo indica, tampoco con un
simulador. Trata sus celdas ⚠️ como algo que se espera que funcione, no como
algo confirmado en laboratorio.

La columna **Bloqueo** se verifica de otra manera: el bloqueo es irreversible,
así que se prueba con etiquetas de sacrificio en una pasada aparte y no como
parte de la validación de un chip. En agosto de 2026 esa pasada cubrió NTAG
210µ, NTAG213, NTAG216, MIFARE Ultralight EV1 de 128 bytes, MIFARE Ultralight
C e ICODE SLIX2. La secuencia de bloqueo de Type 2 se reescribió en septiembre
de 2026 y desde entonces se ha vuelto a ejecutar en NTAG213 y NTAG 210µ. En
NTAG216, Ultralight EV1 de 128 bytes y Ultralight C, la confirmación es
anterior a esa reescritura, así que sus celdas de Bloqueo llevan ⚠️. El
bloqueo de ICODE SLIX2 sigue enviando los comandos que se confirmaron, y su
celda lleva ⚠️ solo por el mecanismo de reserva de la identificación que se
describe en su fila. Todos los demás ⚠️ de la columna Bloqueo se basan en los
simuladores de chip, salvo el de NTAG213 TT, en el que solo se prueba la
máscara de bits de bloqueo y ningún simulador ha ejecutado un bloqueo
permanente.

## Type 2 (ISO 14443-3A)

| Chip | Lectura | Escritura | Contraseña | Bloqueo | Volcado | Notas |
|---|---|---|---|---|---|---|
| NTAG 210µ | ✅ | ✅ | — | ✅ | ⚠️ | 48 bytes de memoria de usuario (64 en total). :more[No admite contraseña: el die «micro» no tiene páginas de configuración, así que no hay dónde guardarla. Tampoco tiene FAST_READ ni contador. Sale de fábrica con formato NDEF] |
| NTAG213 | ✅ | ✅ | ⚠️ | ✅ | ⚠️ | 144 bytes de memoria de usuario. :more[Protección contra escritura confirmada con etiquetas reales después de la reescritura de septiembre de 2026; la protección contra lectura no se ha ejecutado con el código reescrito] |
| NTAG215 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | 504 bytes de memoria de usuario. Solo simulador: no se ha probado ninguna etiqueta NTAG215 real |
| NTAG216 | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | 888 bytes de memoria de usuario. :more[La contraseña y el bloqueo se confirmaron por última vez con etiquetas reales antes de la reescritura de septiembre de 2026, mediante un arnés de pruebas en una compilación de depuración] |
| NTAG213 TT | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | 144 bytes de memoria de usuario. Solo simulador. :more[El estado antimanipulación de la etiqueta aparece en la tarjeta de información de la etiqueta, en el editor de etiquetas, y como preajuste de la Consola avanzada] |
| MIFARE Ultralight EV1 de 48 bytes | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | 48 bytes de memoria de usuario. Solo simulador. Sale de fábrica sin formatear: ejecuta Formatear antes de escribir |
| MIFARE Ultralight EV1 de 128 bytes | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | 128 bytes de memoria de usuario. Sale de fábrica sin formatear: ejecuta Formatear antes de escribir. :more[La contraseña y el bloqueo se confirmaron por última vez con etiquetas reales antes de la reescritura de septiembre de 2026, mediante un arnés de pruebas en una compilación de depuración] |
| MIFARE Ultralight C | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | 144 bytes de memoria de usuario. Se protege con una clave de 16 bytes para 3DES de dos claves y una autenticación mutua, no con una contraseña PWD/PACK. :more[La protección con clave y el bloqueo se confirmaron por última vez con etiquetas reales antes de la reescritura de septiembre de 2026, mediante un arnés de pruebas en una compilación de depuración y no desde la tarjeta Protección ni desde Operaciones. Proteger con contraseña, en Operaciones, y la tarjeta Protección del editor de etiquetas configuran la clave como protección contra escritura. Los dos caminos comprueban el estado de protección de la etiqueta antes de presentar nada, así que a una etiqueta cuya lectura indica que está abierta no se le envía ninguna clave. Sale de fábrica sin formatear: ejecuta Formatear antes de escribir. No tiene GET_VERSION, FAST_READ, READ_CNT ni firma de originalidad (su contador de 16 bits está en la página 29h y se lee con un READ normal, así que la función de contador de la app no se aplica). Un volcado de memoria se detiene en la página 2Bh, porque el chip no decodifica las lecturas de sus páginas de clave] |
| NTAG210 / NTAG212 | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | La app no indica el modelo: la tarjeta de información de la etiqueta muestra lo que el chip ha informado de sí mismo en lugar de una suposición. :more[Preferimos decir que no lo sabemos antes que usar el mapa de páginas equivocado. Un chip no reconocido se limita a la lectura NDEF, la escritura NDEF y los comandos en crudo, así que se rechazan la protección con contraseña y las operaciones Bloqueo permanente, Volcado de memoria y Formatear, y las escrituras pasan por el escritor NDEF del propio iOS en lugar del escritor de páginas de la app. El escritor de iOS es la ruta que la app dejó de usar con las etiquetas Type 2 reconocidas, porque falla con etiquetas preformateadas con un Lock Control TLV, así que una escritura en uno de estos chips puede fallar si la etiqueta lleva ese TLV.] Sin probar en etiquetas reales |
| NTAG213F / NTAG216F | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | Como en la fila anterior. Las variantes con detección de campo se dejan sin reconocer hasta que se verifiquen en chips reales |
| EM Microelectronic V10 / V11 / V16 | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | La app tiene perfiles para los tres, pero su identificación de producción nunca los selecciona, así que una etiqueta EM real queda sin reconocer y recibe el mismo trato que NTAG210, más arriba. :more[Ni siquiera es seguro que se llegue a ese punto: si la etiqueta rechaza GET_VERSION, la app vuelve a sondear para despertarla y luego lee la página 28h, más allá del final de un chip de 16 páginas, y una etiqueta que rechaza esa lectura deja de responder durante el resto del acercamiento. No se ha probado ninguna etiqueta EM real, y los simuladores de EM usan valores de bytes que definen ellos mismos, no valores de la hoja de datos. Las cadenas de personalización de los tres están en la Consola avanzada; el tamaño del Capability Container que escriben procede de la disposición de memoria que la app tiene para el chip, no de una hoja de datos] |
| MIFARE Classic 1K/4K | ❌ | ❌ | — | ❌ | ❌ | iOS no expone MIFARE Classic a las apps (no hay acceso a CRYPTO1), así que la etiqueta no se puede leer en ningún iPhone. :more[Si iOS entrega la etiqueta y la conexión falla, la app indica que parece una MIFARE Classic; si en cambio el escaneo agota el tiempo de espera, el mensaje de tiempo agotado menciona MIFARE Classic como causa probable] |

En los chips Type 2, **Contraseña** es el esquema de NTAG21x (un PWD de 4
bytes y un PACK de 2 bytes, más un umbral de página AUTH0 y el bit PROT), que
configuran tanto Proteger con contraseña, en Operaciones, como la tarjeta
Protección del editor de etiquetas, para proteger solo las escrituras o las
lecturas y las escrituras. La app solo reconoce una protección contra lectura
cuando empieza en la página 4, que es donde siempre la empieza Operaciones y
donde la empieza la tarjeta Protección salvo que se fije una página inicial
personalizada. Detecta la protección contra lectura por cómo responde una
lectura de las páginas 3 a 6, así que una protección contra lectura que
empiece en cualquier otra página de la memoria del chip, fijada con la página
inicial personalizada de la tarjeta Protección, deja a la app sin poder
desbloquearla ni quitarla. **Bloqueo** es la grabación irreversible de los
bytes de bloqueo estáticos y dinámicos (Bloqueo permanente). **Volcado** es
Operaciones > Volcado de memoria, que solo funciona con chips Type 2 y guarda
en un archivo `.bin` todas las páginas que el chip decodifica. En MIFARE
Ultralight C, **Contraseña** se refiere al esquema 3DES propio del chip: una
clave de 16 bytes programada en las páginas 2Ch a 2Fh y cuyo alcance determina
AUTH0, que Proteger con contraseña, en Operaciones, y la tarjeta Protección
del editor de etiquetas configuran solo como protección contra escritura. Una
protección contra lectura en este chip cubriría las páginas que la app lee
para reconocerlo, así que la app no la ofrece. La clave se puede generar,
pegar o derivar de una frase de contraseña.

## Type 5 (ISO 15693)

**La protección con contraseña de SLIX2 pasa por el modo Selected de ISO
15693.** Para fijar una contraseña en un SLIX2 hace falta `SET_PASSWORD`, que
el chip solo acepta en modo Addressed o Selected: sin direccionamiento, la
etiqueta ignora el comando sin avisar, y el daemon de NFC rechaza un indicador
Address explícito antes de la transmisión, tanto con `customCommand` como con
la API en crudo `sendRequest`. La vía que funciona (confirmada en un chip real
el 7 de agosto de 2026) es el modo Selected:
`NFCISO15693Tag.select(requestFlags:)` pone la etiqueta en el estado Selected,
tras lo cual los comandos de contraseña se envían con el indicador Select y
sin UID. El ciclo completo (proteger una etiqueta, verificar que la protección
se aplica de verdad y después quitarla) se validó en hardware en agosto
de 2026. Desde entonces, la secuencia para proteger y quitar la protección se
ha reescrito, y la versión reescrita todavía no se ha ejecutado en una etiqueta
real.

| Chip | Lectura | Escritura | Contraseña | Bloqueo | Volcado | Notas |
|---|---|---|---|---|---|---|
| NXP ICODE SLIX2 | ✅ | ✅ | ⚠️ | ⚠️ | ❌ | Sale de fábrica sin formatear: ejecuta Formatear antes de escribir. :more[Solo contraseña de escritura, mediante el modo Selected (descrito arriba), confirmada por última vez con etiquetas reales antes de la reescritura de septiembre de 2026, mediante un arnés de pruebas en una compilación de depuración y no desde la tarjeta Protección. Se fija desde Proteger con contraseña, en Operaciones, o desde la tarjeta Protección. Los dos caminos comprueban el estado de protección de la etiqueta antes de presentar nada, así que a una etiqueta cuya lectura indica que está abierta no se le envía ninguna contraseña. Se reconoce por su memoria de 80 bloques. En una sesión en la que la etiqueta no responde a Get System Information, se trata como un SLIX de 28 bloques: no se ofrece protección, Formatear escribe un Capability Container para 28 bloques y Bloqueo permanente bloquea solo los bloques 0 a 27 y aun así informa de que ha terminado correctamente] |
| NXP ICODE SLIX (28 bloques) | ⚠️ | ⚠️ | ❌ | ⚠️ | ❌ | Sale de fábrica sin formatear: ejecuta Formatear antes de escribir. :more[Toda etiqueta ISO 15693 de NXP que no informe de 80 bloques recibe este perfil, sea cual sea su tamaño. Un ICODE de 28 bloques no se puede distinguir de SLI, SLIX-S o SLIX-L, así que la app no ofrece protección a ninguno de ellos.] Solo simulador, salvo la identificación en un SLIX real |
| ST M24LR | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | Recibe el perfil ISO 15693 genérico, como toda etiqueta ISO 15693 que no sea de NXP. Sin probar: ni etiqueta real ni simulador |

En los chips ICODE, **Contraseña** es la contraseña de escritura de SLIX2, que
se fija desde Proteger con contraseña, en Operaciones, o desde la tarjeta
Protección del editor de etiquetas. Las lecturas quedan abiertas: una protección
contra lectura en un SLIX2 es el modo de privacidad, y una etiqueta en modo de
privacidad no responde a ningún inventario, así que un iPhone nunca podría
volver a encontrarla para quitar la protección. **Bloqueo** es `LOCK_BLOCK` en
cada bloque de la geometría que la app identificó en esa sesión (el número de
bloques del que informó la etiqueta, o 28 bloques si no respondió a Get System
Information), saltándose los bloques que ya están bloqueados y, en un SLIX2,
el bloque del contador, que el chip no bloquea. La operación Volcado de
memoria no funciona con etiquetas ISO 15693.

## Type 3 (FeliCa)

| Chip | Lectura | Escritura | Notas |
|---|---|---|---|
| FeliCa Lite-S | ❌ | ❌ | La app solo declara el código de sistema `0003` y una Lite-S responde a `88B4`, así que iOS nunca debería entregarle una a la app. Sin probar: no se ha intentado con ninguna etiqueta Lite-S |
| Suica / PASMO / ICOCA y el resto de la familia `0003` | ✅ | ❌ | Solo lectura: el saldo y las 20 transacciones más recientes, en una vista de transporte que no ofrece escritura. Confirmado con tarjetas Suica y PASMO reales |
| iD / QUICPay | — | — | Servicios de pago para los que la app no tiene lector; fuera del alcance |

## Type 4 (ISO 14443-4)

| Chip | Lectura | Escritura | Contraseña | Bloqueo | Volcado | Notas |
|---|---|---|---|---|---|---|
| NTAG424 DNA | ✅ | ✅ | ⚠️ | ❌ | ❌ | La protección con clave se confirmó por última vez con etiquetas reales antes de la reescritura de septiembre de 2026. :more[Sin bloqueo permanente ni volcado de memoria: el chip guarda sus datos en archivos a los que se accede por APDU, no en páginas] |
| MIFARE DESFire EV3 | ✅ | ✅ | ❌ | ❌ | ❌ | Lectura y Escritura dependen de la tarjeta y no del modelo de chip (`ChipProfile.ndefDependsOnCard`). :more[Hex NFC pregunta a la tarjeta por su estado NDEF (`ConnectedTag.queryNDEFAccess()`, que devuelve la respuesta como un `NDEFAccess`), y `TagCapability.resolved(declared:chip:ndefAccess:)` concede Lectura y Escritura a una tarjeta configurada como etiqueta Type 4 del NFC Forum, únicamente Lectura cuando su aplicación NDEF es de solo lectura, y ninguna de las dos a una tarjeta en estado de fábrica o de transporte. La operación Formatear, descrita en [Formatear una etiqueta](../guide/erase-or-format.md#format-a-tag), configura una tarjeta en blanco (sin aplicaciones y en la que se pueden crear aplicaciones nuevas sin la clave maestra) creando la aplicación NDEF (NDEF Tag Application) de la nota de aplicación AN11004 de NXP: un archivo de Capability Container y después un archivo NDEF de hasta 4 KB, cuyo tamaño se calcula a partir de la memoria libre medida en la tarjeta; el Capability Container se escribe en último lugar y el resultado se relee con comandos ISO (`DESFireNDEFDriver.setUp()`, al que llama `OperationsFlowModel.setUpDESFireNDEFApplication`). Una vez configurada la tarjeta, iOS la lee y escribe en ella mediante su propio lector NDEF. La operación Quitar configuración NDEF, descrita en [Quitar la configuración NDEF de una tarjeta](../guide/erase-or-format.md#remove-ndef-setup), deja en blanco una tarjeta con la estructura NDEF que crea Hex NFC, contenga lo que contenga su Capability Container: se autentica una vez con la clave maestra DES de fábrica (AuthenticateISO) y envía FormatPICC, y solo lo hace en una tarjeta cuya única aplicación tenga esa estructura y cuya clave maestra sea DES con la versión 00 (`DESFireNDEFDriver.remove()` y `checkRemovable()`). Hex NFC demuestra que una configuración es suya a partir de la estructura de la tarjeta (su aplicación, sus ajustes de clave y sus archivos) y no de quién la configuró (`DESFireNDEFState`, devuelto por `readState()`). Formatear rechaza, antes de escribir nada, una tarjeta que tenga cualquier otra aplicación (una tarjeta de transporte o de acceso, por ejemplo), una tarjeta cuya clave maestra proteja la creación de aplicaciones nuevas, y la configuración NDEF de otra herramienta, incluso una con la estructura que crea Hex NFC pero con otro Capability Container. Quitar configuración NDEF rechaza una tarjeta que tenga cualquier otra aplicación o una aplicación NDEF cuya estructura difiera de la que crea Hex NFC, e informa de que una tarjeta sin aplicaciones ya está en blanco. La identificación sigue indicando la generación y el tamaño de almacenamiento, y los comandos en crudo siguen disponibles en la Consola avanzada. Confirmado con tarjetas EV3 4K reales: la configuración, un mensaje NDEF escrito y releído, el borrado, la eliminación de la configuración con toda la memoria devuelta a la tarjeta, una nueva configuración y el rechazo de una tarjeta de transporte enviando solo tramas de lectura] |
| MIFARE DESFire EV1 / EV2 | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | :more[Lectura y Escritura siguen el estado NDEF de la tarjeta, como en una EV3, y las operaciones Formatear y Quitar configuración NDEF aceptan las dos generaciones con la misma secuencia (`Type4Variant.isDESFire`, `ConnectedTag.desfireNDEFDriver`). Esa secuencia no se ha ejecutado con ninguna de las dos generaciones, ni en una tarjeta real ni en un simulador: el único simulador de DESFire, `DESFireEV3Simulator`, modela una EV3.] La identificación y los comandos en crudo, como en EV3 |
| MIFARE DESFire D40 y otras generaciones | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | Se muestra como «MIFARE DESFire». :more[`ChipCatalog.identify(desFireVersion:)` asigna el perfil genérico `ChipCatalog.genericMifareDESFire` (`Type4Variant.desfireGeneric`) a una tarjeta cuya versión principal de hardware según GET_VERSION no es 01h (EV1), 12h (EV2) ni 33h (EV3), como la D40 original. Una tarjeta cuyo GET_VERSION se pierde en el transporte dos veces en un mismo acercamiento recibe el mismo perfil, sea cual sea su generación (`MiFareTagIdentifier`, `Type2ProbePolicy`). Lectura y Escritura siguen el estado NDEF de la tarjeta, como en una EV3 (`Type4Variant.isDESFire`, `ChipProfile.ndefDependsOnCard`), así que una tarjeta que ya lleva una aplicación NDEF se puede leer y, si esa aplicación lo permite, también escribir. Las operaciones Formatear y Quitar configuración NDEF rechazan la tarjeta antes de enviar nada que la modifique, con «Esto solo funciona con tarjetas MIFARE DESFire EV1, EV2 y EV3.» (`ConnectedTag.desfireNDEFDriver` es nil, así que responde `OperationsFlowModel.unsupportedGeneration`). Los comandos en crudo siguen disponibles en la Consola avanzada.] Aún no compatible y sin probar: no se ha usado ninguna tarjeta D40 y ningún simulador la modela |
| Otras etiquetas NFC Forum Type 4 (de fabricantes que no son NXP, o un teléfono Android que emula una etiqueta) | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | Se muestran como «NFC Forum Type 4» (`ChipCatalog.genericType4`). :more[iOS las entrega a la app solo porque la app declara el AID de la aplicación NDEF del NFC Forum (`D2760000850101`) después del de eMRTD. La app lee el comienzo del mensaje NDEF con SELECT y READ BINARY normales (`Type4NDEFProbe`) y después pide GET_VERSION, para que un NTAG424 DNA o una DESFire que llegue por esta vía se siga reconociendo (`ChipCatalog.identify(type4Version:)`). Cualquier otra conserva el perfil genérico: lectura NDEF, escritura NDEF mediante el propio soporte NDEF de iOS y comandos en crudo, sin disposición de memoria ni fabricante. Confirmado en octubre de 2026 con un teléfono Android que emulaba una etiqueta Type 4 (lectura, escritura y relectura). No se ha probado ninguna etiqueta física que no sea de NXP] |
| Dispositivos de salud NFC (NFC Forum PHDC, como la NovoPen 6 y la NovoPen Echo Plus) | ❌ | ❌ | — | ❌ | ❌ | Se muestran como «Dispositivo de salud». :more[Se reconocen por un registro PHD al comienzo del mensaje NDEF (`PHDAssociation`), y el fabricante se nombra a partir de su OUI cuando la app lo conoce (`HealthDeviceMaker`). Solo se lee esa solicitud de asociación, nunca mediciones ni el historial de dosis. Las escrituras, Borrar y los comandos de consola se rechazan antes de enviar ninguna trama (`refuseIfHealthDevice`), incluso con Omitir la identificación activado, y el escaneo nunca se guarda en el Historial. Confirmado en octubre de 2026 con un teléfono Android que servía un mensaje publicado de una NovoPen 6. No se ha probado ninguna pluma real] |

En NTAG424 DNA, **Contraseña** se refiere a la autenticación AES-128 propia del
chip, no al esquema PWD/PACK de Type 2: Proteger con contraseña, en
Operaciones, y la tarjeta Protección del editor de etiquetas aceptan una clave
de 16 bytes, y cualquiera de los dos puede proteger las lecturas además de las
escrituras. La tarjeta Protección aplica la clave con la siguiente escritura.

## Fiabilidad del hardware

Hex NFC requiere iOS 17, así que no funciona en el iPhone X ni en modelos
anteriores. No se ha comparado ninguna generación de iPhone con otra, así que
no hay cifras de fiabilidad por modelo que publicar.

El código trata ISO 15693 como un transporte poco fiable: la identificación
recurre al perfil del catálogo cuando una etiqueta no responde a Get System
Information, y el bloqueo permanente comprueba el estado de seguridad de un
bloque antes de dar crédito a una respuesta de error. Cuando un escaneo falla,
la pantalla de escaneo lo indica y ofrece volver a intentarlo.
