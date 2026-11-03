---
title: Modelo de amenazas
description: Frente a qué protege Hex NFC al manejar los datos de las etiquetas, las operaciones destructivas y las dependencias, y qué deja fuera del alcance.
audience: developer
tags:
  - security
---

Hex NFC es una herramienta que lee etiquetas NFC, escribe en ellas y las
modifica. Este documento enumera frente a qué protegemos y frente a qué no.

## Dentro del alcance

### Confidencialidad de los datos

- Las etiquetas escaneadas se guardan en SwiftData en el dispositivo, en un
  almacén que la app no excluye de las copias de seguridad del dispositivo. La
  sincronización con iCloud propia de la app es opcional y está desactivada
  por defecto. Cuando está activada, replica los preajustes y el historial de
  escaneos en la base de datos privada de iCloud del usuario. Una entrada del
  historial de escaneos contiene el UID y los registros de la etiqueta y, en
  el caso de una tarjeta de transporte, su IDm, su saldo y sus transacciones.
- Aparte de la sincronización con iCloud, la app solo envía por la red datos
  leídos de una etiqueta en un caso. Cuando una tarjeta de transporte muestra
  una estación que la app no sabe nombrar, el usuario puede escribir el nombre
  y tocar Enviar, con lo que se mandan a `api.apps.hex.pro` los códigos de
  línea, estación y región, el código de sistema de la tarjeta y el nombre
  escrito. Esa solicitud no lleva nada más de la tarjeta: ni su IDm, ni su
  saldo, ni su lista de transacciones.
- `PrivacyInfo.xcprivacy` no declara seguimiento ni tipos de datos
  recopilados, y en él no figuran ni la sugerencia de nombre de estación
  descrita arriba ni un mensaje de comentarios. La app hace otras cuatro
  solicitudes de red, y ninguna lleva nada leído de una etiqueta: la pantalla de
  inicio de la app obtiene una cifra de costes de desarrollo de
  `api.apps.hex.pro`, pide a `api.p.hex.pro` un banner de otra app de Hex Pro y
  descarga la imagen o el vídeo que indica esa respuesta; y el formulario de
  comentarios, solo cuando el usuario toca Enviar, envía a `api.hex.pro` el
  mensaje escrito, una dirección de respuesta opcional y la versión de la app,
  la versión de iOS, el modelo de dispositivo y el idioma de la app. Una
  solicitud de red que esta página no describa es un fallo de seguridad.
- Cada comando que la propia app envía a una etiqueta, y la respuesta de la
  etiqueta, se escribe también en el log del sistema del iPhone (subsistema
  `pro.hex.nfc`, categoría `apdu`), marcado como `.public` para que el sistema
  no lo oculte. Esto ocurre en las compilaciones de publicación, y ningún
  ajuste lo desactiva. Las tramas que llevan una contraseña o una clave se
  enmascaran, y también el EXTERNAL AUTHENTICATE de BAC de un pasaporte, su
  MSE:Set AT de PACE y el último GENERAL AUTHENTICATE de PACE, que lleva los
  tokens de autenticación. Los pasos de GENERAL AUTHENTICATE de PACE
  anteriores a ese se envían con encadenamiento de comandos (byte de clase
  `10`), que la regla de enmascaramiento no detecta, así que el nonce cifrado
  y los datos intercambiados para el mapeo y el acuerdo de claves quedan
  completos en el log. Quien grabe el intercambio por radio recibe también
  esas tramas. Todo lo demás queda completo en el log. Eso incluye el UID de
  cada etiqueta que detecta la app y el IDm de una tarjeta de transporte; las
  páginas de configuración que lee la app; los doce primeros bytes del área de
  datos de una etiqueta Type 2, que cada escaneo y cada escritura leen para
  comprobar que la etiqueta está presente; un volcado de memoria; cada
  registro que la app escribe en una etiqueta Type 2 cuyo chip identifica; y
  los bloques de los que se leen el saldo y las transacciones de una tarjeta
  de transporte. Cuando un NTAG424 DNA acepta la clave que lleva una
  escritura, como hace una etiqueta protegida solo contra escritura con esa
  clave, los registros que envía la escritura y los que relee para
  comprobarlos también quedan completos en el log. Si el archivo NDEF de la
  etiqueta está configurado para comunicación cifrada, que es como la app
  protege una etiqueta también contra lectura, esas tramas van cifradas. Los
  grupos de datos de un pasaporte solo llegan al log como las tramas cifradas
  de su sesión de mensajería segura. Los registros que iOS lee en nombre de la
  app no quedan en el log, salvo un recuento de registros y su tamaño en una
  etiqueta que iOS presenta como etiqueta MIFARE: todas las etiquetas Type 2,
  una tarjeta DESFire y un NTAG424 DNA cuando iOS lo presenta así. Cualquiera
  que pueda leer el log del iPhone, desde un Mac conectado o en un
  sysdiagnose, puede leer estas tramas.
- Los secretos de protección de las etiquetas solo se guardan en el Llavero,
  como elementos con `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` que nunca
  se sincronizan ni pasan a otro dispositivo. Son el PWD de 4 bytes y el PACK
  de 2 bytes de las etiquetas NTAG21x y Ultralight EV1, la clave AES-128 de
  NTAG424 DNA, la clave 3DES de 16 bytes de MIFARE Ultralight C y la
  contraseña de escritura de 4 bytes de ICODE SLIX2.
- Dos almacenes del Llavero los guardan. `KeychainProtectionCredentialStore`
  conserva el secreto de un preajuste guardado con la protección activada,
  indexado por el preajuste, y al eliminar el preajuste de la Biblioteca de
  este iPhone se elimina también ese secreto. `KeychainTagCredentialStore`
  está indexado por el UID de la etiqueta. Cuando una escritura desde la
  tarjeta Protección del editor aplica o quita la protección, o cuando la
  aplica un preajuste protegido escrito desde la Biblioteca, el secreto se
  guarda ahí después de escribir los registros nuevos y antes del comando que
  cambia la protección de la etiqueta, por delante de cualquier secreto ya
  guardado para esa etiqueta (hasta cuatro en total). Si falla el guardado, la
  escritura no se detiene. Eliminar un preajuste no afecta a estas entradas, y
  la app no tiene ningún control para eliminar una: una entrada solo se
  elimina cuando una relectura tras quitar la protección muestra la etiqueta
  abierta y de nuevo con su secreto de fábrica. Todavía no hay código que lea
  una entrada para desbloquear una etiqueta. Una contraseña escrita en la
  pantalla Operaciones no se guarda en ningún sitio.
- Solo los *parámetros* que no son secretos (como la página en la que empieza
  la protección y, en NTAG21x, Ultralight EV1 y NTAG424 DNA, si protege solo
  las escrituras o las lecturas y las escrituras) se guardan con un preajuste,
  se sincronizan o se escriben en una exportación `.hexnfc`; el secreto nunca
  viaja con ellos. Un preajuste protegido que llega a otro dispositivo,
  mediante la sincronización con iCloud o una copia de seguridad restaurada en
  un iPhone nuevo, conserva sus parámetros pero no su secreto. Su fila de la
  Biblioteca sigue mostrando el candado que lo identifica como un preajuste
  que aplica protección, pero al escribirlo allí no se aplica ninguna y no
  aparece ningún aviso. Lo mismo ocurre en este iPhone con un preajuste
  guardado con la protección activada y sin secreto, por ejemplo desde el
  editor de una etiqueta protegida escaneada cuya contraseña nunca se
  introdujo allí. El panel Guardar como preajuste sigue diciendo que el
  secreto se guarda solo en este dispositivo. La app puede compartir un
  preajuste como archivo `.hexnfc`, pero no tiene forma de importarlo. Hay dos
  cosas que se escriben en archivos del directorio temporal de la app, y la
  app no borra ninguna de ellas: el archivo `.hexnfc` de un preajuste
  compartido y el archivo `.bin` de un volcado de memoria, que se escribe en
  cuanto termina el volcado, se comparta o no.
- Un pasaporte electrónico solo se lee después de que el usuario introduzca el
  número de pasaporte, la fecha de nacimiento y la fecha de caducidad de su
  zona de lectura mecánica, escribiéndolos o escaneando la página de la
  fotografía con la cámara, que lee las líneas impresas en el dispositivo y no
  conserva ninguna imagen. La app no guarda esos datos, ni nada de lo que lee
  del pasaporte, incluida la imagen del rostro, en el historial de escaneos ni
  en ningún otro almacenamiento de la app, y no envía nada de ello por la red.
  El resultado solo se muestra durante esa sesión.

### Seguridad de las operaciones destructivas

- En la pantalla Operaciones, siete operaciones exigen que el usuario escriba
  el UID completo de la etiqueta antes de ejecutarse: Borrar, Formatear, Quitar
  configuración NDEF, Bloqueo permanente, Límite de intentos, Proteger con
  contraseña y Quitar contraseña. Límite de intentos es solo para NTAG21x y
  Ultralight EV1. Proteger con contraseña y Quitar contraseña cubren todos los
  chips que la app puede proteger (NTAG21x, Ultralight EV1, Ultralight C,
  NTAG424 DNA e ICODE SLIX2), y la tarjeta Protección del editor de etiquetas
  puede proteger y desproteger los mismos chips. Es una confirmación escrita, no
  un Sí/No: el UID que aparece junto al campo es el que se leyó en el primero
  de dos acercamientos, y se rechaza un segundo acercamiento que presente otra
  etiqueta.
- Quitar configuración NDEF envía FormatPICC, que elimina todas las
  aplicaciones de una tarjeta MIFARE DESFire. Se autentica una vez por
  acercamiento con la clave maestra DES de fábrica publicada, y solo después de
  que ese mismo acercamiento haya demostrado que la única aplicación de la
  tarjeta tiene la estructura NDEF de esta app y que su clave maestra es DES
  con versión 00. Formatear y Quitar configuración NDEF rechazan una tarjeta
  que tenga cualquier otra aplicación, como una tarjeta de transporte o de
  acceso, antes de enviar nada que la modifique.
- A una etiqueta reconocida como dispositivo de salud NFC no se le envía
  ninguna escritura, Borrar ni comando de consola: su perfil lleva solo
  `.personalHealthDevice`, y `refuseIfHealthDevice` rechaza las escrituras NDEF,
  las escrituras de memoria y los comandos en crudo antes de enviar ninguna
  trama. El escaneo nunca se guarda en el Historial.
- Fuera de la pantalla Operaciones, nada en una compilación de publicación pasa
  por esa confirmación. La protección que se aplica o se quita desde la
  tarjeta Protección del editor se ejecuta como parte de la siguiente
  escritura, igual que la protección de un preajuste escrito desde la
  Biblioteca; para quitarla sigue haciendo falta la contraseña o la clave
  actual de la etiqueta. Una escritura normal sustituye el contenido de la
  etiqueta, y una escritura con todos los registros eliminados vacía la
  etiqueta igual que Borrar. La Consola avanzada envía los comandos en crudo
  que el usuario escribe o carga de su lista integrada, incluidos los que
  bloquean memoria permanentemente o reescriben páginas de configuración, a
  una etiqueta por ejecución y sin confirmación.
- El límite de intentos (AUTH_LIM) es opcional, y la pantalla que lo
  configura muestra una advertencia. Aplicar protección con contraseña a un
  NTAG21x o un Ultralight EV1 siempre escribe un límite de 0 (ilimitado), lo
  que además borra cualquier límite que ya tuviera la etiqueta. Aparte de los
  comandos en crudo de la Consola avanzada, un límite distinto de cero solo se
  fija desde la pantalla Límite de intentos, en una etiqueta que ya está
  protegida. Un límite de N permite que la etiqueta rechace N contraseñas
  incorrectas. Con una contraseña incorrecta más, la etiqueta deja de aceptar
  su contraseña para siempre, incluida la correcta, así que su protección ya
  no se puede quitar nunca y la memoria que protege no se puede volver a
  escribir nunca, ni a leer si también se protegieron las lecturas. Es el
  comportamiento propio del chip, y lo señalamos de forma bien visible en lugar
  de ocultarlo. Hemos confirmado ese recuento en NTAG213. La pantalla Límite de
  intentos también funciona con NTAG213 TT, NTAG215, NTAG216 y Ultralight EV1,
  donde el recuento no se ha probado; las hojas de datos de NTAG215, NTAG216 y
  Ultralight EV1 enuncian la misma regla. La pantalla Límite de intentos
  muestra el límite que ya tiene una etiqueta cuando su configuración se puede
  leer sin contraseña, lo que excluye una etiqueta protegida contra lectura.
  La app nunca puede leer cuántas contraseñas incorrectas ha rechazado ya una
  etiqueta, porque ningún comando de estos chips lo indica.
- El bloqueo permanente nunca es un parámetro de un preajuste, y el límite de
  intentos tampoco: un preajuste escrito desde la Biblioteca puede aplicar
  protección, pero nunca puede bloquear permanentemente una etiqueta ni fijar
  un límite. Lo que sí hace es poner la misma contraseña o clave en todas las
  etiquetas en las que se escribe, y la app nunca muestra el secreto que ha
  guardado un preajuste. Un preajuste se elimina deslizando su fila de la
  Biblioteca, sin confirmación, y su secreto no pasa a un iPhone nuevo. Con la
  sincronización con iCloud activada, eliminar el preajuste en otro
  dispositivo, donde no tiene secreto, lo elimina también de este iPhone y
  deja su secreto en el Llavero de este iPhone, donde nada lo lee. Una vez
  eliminados el preajuste y cualquier duplicado suyo, o cuando el usuario se
  pasa a un iPhone nuevo, la app no conserva ninguna copia que vaya a
  presentar a una etiqueta (las entradas por etiqueta descritas arriba se
  quedan en el iPhone original, pero nada las vuelve a leer). Salvo que el
  usuario haya guardado el secreto en otro sitio, la memoria protegida de
  todas las etiquetas escritas con ese preajuste ya no se podrá volver a
  escribir nunca.
- La app nunca se salta la autenticación del lado de la etiqueta. Si una
  etiqueta Type 2 rechaza nuestro PWD_AUTH, comunicamos el fallo con
  franqueza y no enviamos una segunda contraseña en ese acercamiento; no
  reintentamos con una lista de contraseñas probables. Cuando se rechaza
  Proteger con contraseña o Quitar contraseña, la pantalla Operaciones ofrece un
  botón, **Probar el valor de fábrica**, que prueba la contraseña de fábrica
  publicada en una ejecución nueva, con la confirmación del UID escrito
  incluida. Nada da ese paso por su cuenta, y en una etiqueta con límite de
  intentos cuenta como un intento incorrecto si la contraseña de fábrica no es
  la que tiene la etiqueta. Proteger con contraseña, ejecutado en una etiqueta
  que ya está protegida solo contra escritura, presenta la contraseña nueva
  como si fuera la actual de la etiqueta, así que, en una etiqueta con límite
  de intentos, es un intento incorrecto salvo que la etiqueta ya tenga esa
  contraseña. Una escritura que lleva una contraseña o una clave la presenta
  antes de escribir nada. Eso incluye un preajuste con un secreto guardado y
  una escritura desde la tarjeta Protección del editor. En todos los chips que
  la app puede proteger, lee primero el estado de protección de la etiqueta y
  no envía ninguna contraseña ni clave a una etiqueta cuya lectura indica que
  está sin protección. En la tarjeta
  Protección, el valor que se presenta es el que se acaba de escribir allí,
  incluida una contraseña nueva pensada para sustituir a la actual de la
  etiqueta, así que, en una etiqueta con límite de intentos, cuenta como un
  intento incorrecto siempre que la etiqueta tenga otra distinta. El único
  recurso automático está en NTAG424 DNA: aplicar o quitar la protección
  recurre como máximo a tres claves en una misma sesión (la clave actual que
  se proporciona a la operación, la clave de fábrica publicada, toda a ceros,
  y, al aplicar la protección, la clave nueva). Eso limita las claves que se
  prueban, no los intentos. La lectura de una etiqueta recién salida de fábrica
  indica que está sin protección, así que una escritura no le envía ninguna
  clave antes de escribir. Un cambio de clave que falla suma hasta dos
  intentos más para averiguar qué clave tiene la etiqueta. No hemos
  establecido si ese chip cuenta las autenticaciones fallidas.

### Cadena de suministro de la compilación

- La compilación solo usa frameworks de Apple y código propio de Hex Pro, más
  una dependencia exclusiva de las pruebas
  (`pointfreeco/swift-snapshot-testing`): ningún SDK de analíticas ni de
  informes de cierres inesperados, y ninguna biblioteca de interfaz de
  terceros. Esa dependencia se declara como un rango de versiones que empieza
  en 1.17.0 y `Package.resolved` no está incluido en el repositorio, así que
  cada clon nuevo resuelve la versión más reciente de ese rango.
  `HexPromoKit` está copiado byte a byte desde otro repositorio de Hex Pro en
  un commit fijado. Cada dependencia adicional es una superficie de riesgo en
  la cadena de suministro que no aceptamos.
- El flujo de trabajo de publicación obtiene los recursos de firma en modo de
  solo lectura mediante fastlane Match desde un repositorio privado aparte.
  Clona ese repositorio con credenciales guardadas como secretos de GitHub
  Actions, y Match descifra los recursos con una frase de contraseña guardada
  del mismo modo. Las claves privadas de firma no están en el repositorio de
  la app. La cadena de herramientas de publicación no está fijada: el flujo de
  trabajo instala la versión actual de fastlane desde RubyGems en cada
  ejecución y hace referencia a las GitHub Actions por el tag de su versión
  principal y no por commit.

## Fuera del alcance

- Las garantías criptográficas del chip dependen del propio chip, que es un
  límite de confianza de hardware. Usamos la autenticación que ofrezca el chip; no
  afirmamos que nuestra app haga el chip más seguro de lo que es por sí mismo.
  Una contraseña de NTAG21x o Ultralight EV1 viaja por el aire en claro cada
  vez que se presenta o se escribe. Lo mismo ocurre con una clave de
  Ultralight C o una contraseña de escritura de ICODE SLIX2 cuando se escribe
  en la etiqueta. Cuando se presenta una contraseña de SLIX2, solo la
  enmascara un número aleatorio de 16 bits que la etiqueta acaba de enviar en
  claro. Cualquiera que grabe estos intercambios tiene el secreto.
- No se impide la clonación. Los UID de NTAG21x vienen fijados de fábrica,
  pero el resto de la memoria se puede copiar libremente en etiquetas vacías.
  Es una característica de todo el sector, y Hex NFC no pretende evitarla. La
  tarjeta de información de la etiqueta muestra «Firma de originalidad NXP»
  cuando un chip Type 2 devuelve una firma completa de 32 bytes, pero la app
  nunca la comprueba con la clave pública de NXP, así que esa fila no
  demuestra que una etiqueta sea auténtica. La fila Funciones incluye «Firma
  de originalidad» para cualquier chip identificado como un modelo que la
  tiene, devuelva lo que devuelva el chip. En NTAG424 DNA, la tarjeta incluye
  «Duplicado SUN» entre las funciones del chip, pero la app ni configura ni
  comprueba los mensajes SUN.
- La lectura de un pasaporte no demuestra que el documento sea auténtico. La
  app compara los grupos de datos que lee con la lista de hashes del objeto de
  seguridad del chip y muestra «Probablemente intacto» cuando coinciden, pero
  no verifica la firma de ese objeto (Passive Authentication), y no ejecuta ni
  Active Authentication ni Chip Authentication, las comprobaciones que
  detectan un chip copiado.
- Cualquiera que tenga acceso físico al iPhone desbloqueado puede llegar a los
  datos de tus etiquetas, igual que a los de cualquier otra app. También puede
  usar las contraseñas y claves guardadas con tus preajustes, porque al
  escribir un preajuste se presenta su secreto guardado a una etiqueta que ya
  esté protegida con él.
- Una etiqueta controlada por un atacante puede devolver cualquier dato en
  respuesta a nuestras lecturas. Analizamos los datos de forma defensiva, pero
  no tratamos la etiqueta como un oráculo de confianza para nada que vaya más
  allá de su propio contenido.

## Informar de vulnerabilidades

Informa de las vulnerabilidades en privado a
[security@hex.pro](mailto:security@hex.pro) y no en un foro público.
Confirmamos la recepción de cada informe en un plazo de 72 horas y después
trabajamos con quien lo ha enviado en una corrección y una fecha de
divulgación pública, según un calendario de divulgación coordinada de 90 días.
