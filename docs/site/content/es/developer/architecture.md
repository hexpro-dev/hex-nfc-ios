---
title: Arquitectura
description: Cómo se divide en targets el paquete Swift de Hex NFC y qué convenciones sigue cada target.
audience: developer
tags:
  - architecture
---

Un recorrido general por la organización de Hex NFC, una app SwiftUI para
iPhone con iOS 17 o posterior. Para el detalle del día a día, consulta el
[código fuente](https://github.com/hexpro-dev/hex-nfc-ios).

## Grafo de módulos

```text
HexNFCApp ─┬─> HexNFCDesign  ──> HexNFCShaders
           ├─> HexNFCStorage ──> HexNFCRecords
           ├─> HexNFCKit     ──> HexNFCRecords
           ├─> HexPromoKit   (vendored, product-less)
           └─> HexNFCTestKit ──> HexNFCKit, HexNFCRecords
HexNFCTagSim ──> HexNFCKit  (test-only)
```

### `HexNFCRecords`

Tipos de valor y sus códecs. El enum `NDEFRecord` tiene 18 casos que cubren
todos los tipos de registro que la app puede leer o escribir: Texto, URI,
Enlace de app, Social (22 plataformas), Buscar, Archivo, Correo, vCard,
Teléfono, SMS, FaceTime, Mapa, Cripto, traspaso Bluetooth, Wi-Fi WPS, Datos
(un tipo MIME y una carga útil en crudo), Atajo y En crudo. El target también
contiene los modelos y decodificadores de los grupos de datos del pasaporte y
del historial de transporte de Suica, además de `StationDirectory`, que carga
los datos de estaciones y líneas incluidos en la app que `TransitReader` usa
para poner nombre a las estaciones.

`NDEFCodec` convierte en ambos sentidos entre `[NDEFRecord]`, el
`[NDEFPayload]` del nivel de transmisión y los bytes en crudo del mensaje;
solo `HexNFCKit` hace de puente entre `NDEFPayload` y CoreNFC. La tabla de
prefijos URI (los 36 códigos identificadores de URI de NDEF, de `0x00` a
`0x23`, donde `0x00` significa sin prefijo) está aquí, junto con una búsqueda
inversa por coincidencia del prefijo más largo.

### `HexNFCKit`

La abstracción de NFC. `TagSession` es el protocolo que el código de
producción conecta a `CoreNFCSession` (que envuelve `NFCTagReaderSession`) y
las pruebas unitarias, a `SimulatedSession`. Las pruebas de interfaz abren la
app con `--useSimulatedNFC`, que pone en su lugar `MockTagSession`, una sesión
de reemplazo dentro de `HexNFCKit` que devuelve registros predefinidos y no
tiene modelo de chip. La comprobación del argumento de arranque no queda dentro
de un `#if DEBUG`, así que el mock también se compila en las compilaciones de
publicación. `ConnectedTag` expone las capacidades del chip como un conjunto
de opciones `TagCapability`. En un acercamiento real, una etiqueta que la
sesión no ha podido identificar obtiene lectura NDEF, escritura NDEF y
transceive en crudo. `permanentLock()` y los comandos de contraseña de Type 2
se escriben una sola vez, en una extensión de `ConnectedTag`, y lanzan
`TagError.capabilityUnsupported` antes de enviar ninguna trama cuando el chip
carece de esa capacidad. La etiqueta de producción, `CoreNFCConnectedTag`,
aplica la misma comprobación a las lecturas y escrituras de memoria. El
`transceive` en crudo no pasa por esa comprobación.

`TagIdentifier` elige una sonda para cada tipo de etiqueta de CoreNFC, y
`ChipCatalog` decodifica lo que lee la sonda en un `ChipProfile` con la
familia, las capacidades y la disposición de memoria del chip. NTAG213,
NTAG215, NTAG216, NTAG213 TT, NTAG 210µ y MIFARE Ultralight EV1 se
identifican a partir de `GET_VERSION`. NTAG210, NTAG212, NTAG213F y NTAG216F
también responden a `GET_VERSION`, pero el decodificador los deja sin
identificar a propósito, porque sus mapas de memoria no se han contrastado con
chips reales. NTAG424 DNA se identifica a partir de la APDU `GET_VERSION`
encapsulada. Ese decodificador solo comprueba los bytes de fabricante y de
tipo de hardware, así que cualquier chip de NXP que informe del tipo de
hardware NTAG 4xx se identifica como un NTAG424 DNA y recibe el perfil de ese
chip. DESFire se identifica a partir de su trama `GET_VERSION` nativa. Una
etiqueta que iOS entrega por la aplicación NDEF del NFC Forum
(`D2760000850101`, declarada después del AID de eMRTD) se lee primero con
comandos SELECT y READ BINARY normales (`Type4NDEFProbe`). Un mensaje que
empieza con un registro PHD es un dispositivo de salud NFC: `PHDAssociation`
analiza su solicitud de asociación, `HealthDeviceMaker` nombra al fabricante a
partir de su OUI y el perfil lleva solo `.personalHealthDevice`, así que las
escrituras, Borrar y los comandos de consola se rechazan antes de enviar
ninguna trama. A cualquier otra etiqueta se le pide `GET_VERSION`, que
reconoce un NTAG424 DNA o una DESFire que llegue por esta vía
(`identify(type4Version:)`), y el resto recibe el perfil genérico
`genericType4`: lectura NDEF, escritura NDEF y comandos en crudo.
MIFARE Ultralight C rechaza `GET_VERSION`, lo que detiene la etiqueta, así que
la sesión reinicia el sondeo y reconoce el chip a partir de una lectura de las
páginas 0 y 28h. Las etiquetas ISO 15693 se resuelven a partir del código de
fabricante del circuito integrado más Get System Information: un chip de NXP
pasa a ser ICODE SLIX, o SLIX2 cuando informa de 80 bloques, y cualquier otro
fabricante recibe un perfil ISO 15693 genérico. Los pasaportes se reconocen
seleccionando la aplicación eMRTD. Las tarjetas FeliCa reciben un perfil
genérico, al que se añade la lectura de transporte con el código de sistema
`0003`. `ChipCatalog` también tiene perfiles y un decodificador
(`identify(emSignature:)`) para EM Microelectronic V10, V11 y V16, pero nada en
la sesión de producción llama a ese decodificador, así que la app no
identifica un chip EM en un acercamiento real. Los bytes de la página 0 que
compara (`E0 10`, `E0 11` y `E0 16`) son valores que definen los propios
simuladores de EM, no valores leídos de un chip EM real.

Los comandos integrados de la Consola avanzada están en
`CommandPresetCatalog`, cada uno marcado con la familia para la que está
escrito. Hay preajustes para chips Type 2 (entre ellos los chips EM), NTAG424
DNA e ICODE SLIX, y ninguno para DESFire, FeliCa ni pasaportes. Los preajustes
de EM no se han probado en chips reales: el comando de modo criptográfico del
V10 y las lecturas del estado antimanipulación usan los valores que definen
los simuladores, y cada cadena de personalización de EM escribe un Capability
Container cuyo byte de tamaño procede de la disposición de memoria de
`ChipCatalog` y no de una hoja de datos. La consola muestra todos los
preajustes y ejecuta lo que esté cargado sin comprobar la familia de la
etiqueta, así que nada impide enviar un preajuste de EM a una etiqueta que no
lleve un chip EM.

El target también contiene el controlador de protección de cada familia que
tiene uno; `DESFireNDEFDriver`, que crea y quita la aplicación NDEF en una
MIFARE DESFire EV1, EV2 o EV3 vacía y demuestra a partir de la propia
estructura de la tarjeta si una configuración es de esta app; el
`TransitReader` de FeliCa, y el lector de pasaportes, que es de solo lectura. `EPassportReader` ejecuta PACE cuando el `EF.CardAccess` del
documento anuncia una configuración que admite, y BAC en caso contrario. Si
falla un PACE anunciado, la lectura falla; no se reintenta con BAC. Cuando
puede leer el objeto de seguridad del chip (`EF.SOD`), calcula el hash de cada
grupo de datos que ha leído y compara el resultado con la lista de hashes de
ese objeto, y la pantalla de resultados marca los datos como «Probablemente
intacto» o «Probablemente alterado». Si no hay un objeto de seguridad legible,
o no incluye ninguno de los grupos de datos leídos, la pantalla no muestra
ninguna indicación de integridad. El lector no verifica la firma ni la cadena
de certificados del objeto de seguridad, así que esto no es Passive
Authentication: un objeto de seguridad reescrito para que coincida con datos
alterados supera la comprobación, y nada de lo que hace la app establece que
un pasaporte sea auténtico.

### `HexNFCStorage`

Pila de SwiftData (`SwiftDataStack`) para tres modelos:
- `Preset`: imágenes de etiqueta con nombre (una lista de registros y
  requisitos de capacidad opcionales).
- `HistoryEntry`: un registro de escaneo, que el flujo de escaneo escribe
  después de cada lectura correcta de una etiqueta o una tarjeta de transporte
  y nunca para un pasaporte ni un dispositivo de salud. Si se repite un escaneo idéntico, se actualiza la
  hora de la fila existente en lugar de añadir otra. Tras cada inserción se
  recortan las entradas no fijadas que quedan más allá de las 50 más
  recientes, y al arrancar se eliminan las entradas no fijadas de más de 90
  días.
- `SavedCommandPreset`: la forma almacenada del `CommandPreset` de HexNFCKit,
  pensada para los comandos de consola que guarde el usuario. Está en el
  esquema, pero nada en la app lo lee ni lo escribe todavía, y la Consola
  avanzada solo muestra los preajustes integrados.

La réplica en la base de datos privada de iCloud depende de un único indicador
de configuración, controlado por el interruptor de Ajustes (desactivado por
defecto). El indicador se lee cuando se abre el almacén al arrancar, así que
un cambio surte efecto la próxima vez que se inicia la app. Si en ese momento
el almacén no se puede abrir con la réplica, la app lo abre sin ella y Ajustes
indica que la sincronización no está funcionando. Los secretos de protección
nunca van a SwiftData: `KeychainProtectionCredentialStore` (indexado por
preajuste) y `KeychainTagCredentialStore` (indexado por el UID de la etiqueta)
los guardan en el Llavero como elementos
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, que no se sincronizan.

### `HexNFCShaders`

Shaders de Metal y patrones de CoreHaptics para los momentos característicos
de escaneo, escritura y consola. Los shaders son archivos fuente `.metal` que
compila la cadena de herramientas de Metal de SPM; los patrones hápticos son
JSON `.ahap`. El modificador de SwiftUI `.hexHero(...)` reproduce el patrón
háptico de un momento concreto. La mitad visual de cada uno de esos momentos
es un modificador aparte (`hexScanReveal`, `hexWriteBurst`, `hexConsolePulse`)
que la pantalla añade con el mismo disparador.

### `HexNFCDesign`

Tokens de diseño (`HexTokens`), preajustes de movimiento, la `HexTransition`
característica (el logotipo del hexágono dibujado en tres porciones, que
entran con una animación de muelle escalonada cuando su `state` pasa de
`.hidden` a `.present`; todos los lugares de la app que la usan pasan
`.present`, así que el escalonado nunca se reproduce) y componentes básicos:
`HexCard`, `HexButton`, `HexField`, `HexBadge`, `HexRecordRow` y
`HexConsole`.

### `HexNFCApp`

Las pantallas de SwiftUI y los modelos de flujo, compilados como biblioteca.
El contenedor de la app en Xcode (`HexNFC.xcodeproj`), que lleva los
entitlements y el `Info.plist`, crea el `AppModel` y muestra `RootView`. Los
modelos `@Observable` de cada flujo (`ScanFlowModel`, `EditFlowModel`, etc.)
controlan las pantallas. `RootView` contiene un `NavigationStack` alrededor de
`HomeView` y presenta cada flujo como un panel. El ciclo de escanear, editar y
escribir es una cadena de paneles (`ScanSheet` y luego `TagEditorSheet`, que
presenta `WriteSheet`), así que la pila raíz nunca se desapila entre un paso y
el siguiente. Entre las pantallas está `RecordEditorSheet`, que es polimórfica
según el tipo de registro.

El target también contiene tres clientes HTTP propios. `CostsClient` obtiene la
cifra de costes de desarrollo que se muestra en la pantalla de inicio de la app cuando
aparece la vista raíz, sin ninguna acción del usuario.
`StationSubmissionClient` solo se ejecuta cuando el usuario envía un nombre
para una estación de transporte que los datos incluidos no saben nombrar, y
envía ese nombre junto con los códigos de línea, estación y región de la
estación y el código de sistema de la tarjeta. No envía el IDm, el saldo ni el
historial de la tarjeta. `FeedbackClient` solo se ejecuta cuando el usuario
toca Enviar en el formulario de comentarios, y envía a `api.hex.pro` el mensaje
escrito, una dirección de respuesta opcional y la versión de la app, la versión
de iOS, el modelo del dispositivo y el idioma de la app que muestra el
formulario. No envía nada leído de una etiqueta ni nada del Historial.

La clave del pasaporte también puede venir de la cámara. `MRZCameraView` pasa
los fotogramas al reconocimiento de texto de Vision en el dispositivo,
`MRZLineReader`, de `HexNFCRecords`, convierte las líneas reconocidas en
claves candidatas y `MRZScanConsensus` vota entre fotogramas antes de fijar
una. No se guarda ningún fotograma.

### `HexPromoKit`

El cliente que hay detrás del banner de promoción cruzada de la pantalla de
inicio de la app. `PromoManager` obtiene la promoción activa de la API de promociones de
Hex Pro y la guarda en caché en el disco, junto con sus archivos multimedia;
el banner lo dibuja el propio `HexNFCApp`. El target es una copia sin
modificaciones locales del SDK de promociones de Hex Pro, y un archivo de
procedencia junto a las fuentes registra el commit fijado y un hash de cada
archivo. El paquete no declara ningún producto para él, porque `HexNFCApp` es
su único consumidor.

### `HexNFCTestKit`

Planes de prueba independientes de la sesión y un ejecutor que manejan tanto
el hardware NFC real como los simuladores por una misma ruta de código. Es un
target de biblioteca de verdad que se enlaza en la app, pero todos los
archivos de `HexNFCApp` que lo importan solo se compilan con `#if DEBUG`,
donde un arnés de pruebas de hardware dentro de la app ejecuta los planes con
etiquetas reales. Un XCTest sin interfaz (`TestKitPlanTests`) ejecuta los
mismos planes con todos los simuladores que tienen perfil de chip. Cuando un
paso real falla donde su simulador pasa, eso revela que el simulador se ha
desviado del chip real, así que la desviación solo se detecta cuando alguien
ejecuta el arnés con etiquetas reales. Las compilaciones de publicación
enlazan el target, pero no tienen ninguna pantalla que llegue a él.

### `HexNFCTagSim` (solo para pruebas)

Simuladores de chip dentro del proceso para NTAG 210µ, NTAG213/215/216,
NTAG213 TT, NTAG424 DNA, MIFARE Ultralight C, MIFARE Ultralight EV1 (de 48 y
128 bytes), MIFARE DESFire EV3, ICODE SLIX y SLIX2 (un único simulador ISO
15693 de 28 u 80 bloques), EM Microelectronic V10/V11/V16, Suica, un pasaporte
electrónico (eMRTD), una etiqueta NFC Forum Type 4 que no es de NXP y un
dispositivo de salud NFC (`Type4NDEFSimulator`, `PHDCDeviceSimulator`) y, como
reserva, un chip Type 2 no reconocido. Cada
uno es una clase que cumple `ChipSimulator`, cuya superficie de transceive en
crudo es `func handle(command: Data) -> Data`. Los simuladores son tipos por
referencia para que las mutaciones que provoca una prueba (contadores, límites
de intentos, bytes de bloqueo) sean visibles para la prueba que los creó. Los
targets de prueba inyectan uno mediante `SimulatedSession(chip:)`. Una
etiqueta simulada toma su perfil de chip de su simulador y no de la
identificación, así que en una prueba todos los simuladores con perfil
aparecen como identificados, incluidos los de EM, aunque la app no reconoce un
chip EM en un acercamiento real. Los simuladores de EM Microelectronic usan
valores de bytes que definen ellos mismos, no valores de la hoja de datos,
para el identificador de la página 0, la página de estado antimanipulación de
cada variante y la respuesta del modo criptográfico del V10, porque el juego
de comandos completo de esos chips no está publicado. También responden a
`GET_VERSION` con ocho bytes a cero, mientras que el juego de comandos
publicado del chip EM más parecido no tiene `GET_VERSION` en absoluto. No se
ha probado ningún chip EM en hardware, así que una prueba superada con un
simulador de EM no demuestra nada sobre los chips EM reales.

## Convenciones

- Todo el acceso a CoreNFC está dentro de `HexNFCKit`. Ningún otro target
  importa `CoreNFC`.
- Los colores de la marca son tokens (`HexTokens.Color.primary`), nunca
  literales hexadecimales fuera de `HexTokens.swift`.
- Las cadenas que ve el usuario pasan por `Localizable.xcstrings`, y las de
  `Info.plist` (el nombre de la app y las solicitudes de permiso), por
  `InfoPlist.xcstrings`.
- `TagError`, el tipo de error de la capa NFC, lleva a la vez
  `userMessage: LocalizedStringResource` y `diagnostics: String`, para que un
  informe de errores pueda incluir el detalle del nivel de transmisión.
- El único paquete Swift de terceros es `pointfreeco/swift-snapshot-testing`, y
  solo lo usan los targets de prueba. `HexPromoKit` es código propio de Hex
  Pro, copiado en el repositorio en lugar de descargarse como dependencia. La
  app también incluye la fuente IBM Plex Mono, con la licencia SIL OFL 1.1.
