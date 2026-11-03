---
title: Preguntas frecuentes
description: Respuestas sobre lo que cuesta Hex NFC, qué modelos de iPhone necesita, qué pasa con las etiquetas que escaneas y cómo pedir ayuda.
audience: user
pageKind: faq
navTitle: FAQ
tags:
  - privacy
---

Las demás páginas del manual explican cada tarea paso a paso. Esta página
responde a lo que surge alrededor de ellas: lo que cuesta la app y lo que
necesita del iPhone. También explica qué pasa con las etiquetas que
escaneas y cómo contactar con Hex Pro.

## Lo que cuesta

### ¿Hex NFC cuesta algo?

No. Hex NFC no cuesta nada, y no hay cuentas, suscripciones, compras dentro de
la app ni funciones de pago. Instala Hex NFC desde el
[App Store](https://apps.apple.com/app/id6801457461) y tendrás la app completa.

### ¿Qué es la tarjeta de costes de desarrollo?

Es una cifra de progreso que no te pide hacer nada. La pantalla de inicio de
Hex NFC tiene una tarjeta con el título **Costes de desarrollo recuperados** que
muestra cuánto del coste del proyecto se ha recuperado hasta ahora. **Ver el
desglose** abre en el navegador una página del sitio web de Hex Pro, donde
contribuir es voluntario. Nada de lo que hay en esa página desbloquea nada en la
app.

### ¿La app muestra anuncios?

Dentro de la app no funciona ninguna red publicitaria. La pantalla de inicio de
Hex NFC puede mostrar una tarjeta con el título **Más apps de Hex Pro** que presenta otra
app del mismo editor. Detrás de esa tarjeta no hay ninguna red publicitaria de terceros,
ningún seguimiento ni ninguna personalización: todo el mundo ve la misma.

## Lo que necesita el iPhone

### ¿Qué modelos de iPhone pueden usar Hex NFC?

Cualquier iPhone con iOS 17 o posterior, es decir, del iPhone XR y el iPhone XS
en adelante, además del iPhone SE de segunda y tercera generación. Todos ellos
tienen el lector NFC que usa la app, así que lo único que hay que comprobar es
la versión de iOS. Hex NFC es una app para iPhone y no funciona en el iPad. En
un dispositivo sin ese lector, un escaneo termina con «Este dispositivo no
admite NFC.» en lugar de buscar una etiqueta.

### ¿Necesito conexión a internet?

No. Leer, escribir y proteger una etiqueta son cosas que ocurren entre el iPhone
y la etiqueta. La app se conecta con Hex Pro para cuatro cosas. Dos son la cifra
de costes de desarrollo y la tarjeta de otra app de Hex Pro. Las otras dos solo
salen cuando tú las envías: un nombre de estación de una tarjeta de transporte y
un mensaje de comentarios. La sincronización con iCloud es el quinto uso de la
red, y está desactivada hasta que la activas. Consulta
[La privacidad y tus datos](privacy.md).

### ¿Por qué el iPhone no lee una de mis etiquetas?

Puede que su chip sea uno que el iPhone no puede leer en absoluto. MIFARE
Classic es el caso habitual, y se trata de una limitación de iOS, no de un fallo
de la etiqueta. Consulta [Etiquetas compatibles con Hex NFC](tags-that-work.md)
para ver los chips que reconoce la app.

## Las etiquetas que escaneas

### ¿Qué pasa con una etiqueta después de escanearla?

El escaneo se guarda en el iPhone, en **Historial**, en la pantalla Biblioteca.
Esa lista tiene un límite, y además una fila no fijada caduca con el tiempo; una
fila que has fijado se mantiene más allá de los dos límites. Al eliminar una
fila se elimina el escaneo guardado. Consulta
[Buscar una etiqueta que has escaneado antes](scan-history.md).

### ¿También se guardan los pasaportes y las tarjetas de transporte?

No es lo mismo en los dos casos. La lectura de un pasaporte se conserva solo
durante esa sesión y se descarta al cerrar el panel. Nada de ella llega a tu
historial, a una exportación ni a iCloud. La lectura de una tarjeta de
transporte se guarda como cualquier otro escaneo. La fila aparece en
**Historial**, en la pantalla Biblioteca, y cuenta para las 50 filas que admite
esa lista. Mientras la sincronización con iCloud está activada, se replica en
iCloud. Al abrir esa fila se ve la tarjeta tal como se leyó, y al eliminarla se
elimina el escaneo guardado. Consulta [Leer un pasaporte](passports.md) y
[Leer una tarjeta de transporte](transit-cards.md).

### ¿Sale del iPhone algún dato de mis etiquetas?

Solo si activas **Sincronización con iCloud**, que está en el grupo
**Sincronización** de la pantalla Ajustes de Hex NFC y viene desactivada.
Replica tus preajustes y tu historial de escaneos en tu base de datos privada de
iCloud, que gestiona Apple y que protege tu Apple ID. Las contraseñas de las
etiquetas nunca forman parte de ella: se quedan en el Llavero de iOS del iPhone
que las estableció. Consulta [Ajustes](settings.md#turn-on-icloud-sync) y
[La privacidad y tus datos](privacy.md).

### ¿Puede Hex NFC recuperar una contraseña de etiqueta que he olvidado?

No, y tampoco puede hacerlo nada más. Es la propia etiqueta la que comprueba la
contraseña, así que la memoria protegida de una etiqueta cuya contraseña se ha
perdido es irrecuperable. Una contraseña que estableces se guarda en el Llavero
del iPhone que la estableció. En otro iPhone, la misma etiqueta te pide que la
introduzcas. Consulta [Protección de etiquetas](tag-protection.md).

### ¿Puede Hex NFC leer mi pluma de insulina? {#insulin-pen}

Puede decirte qué pluma es, pero no lo que contiene. Una NovoPen 6 o NovoPen
Echo Plus abre una pantalla **Dispositivo de salud** que nombra una app capaz de
leer su historial de dosis. Hex NFC nunca escribe en un dispositivo de salud y
no guarda nada de él. Consulta
[Dispositivos de salud](tags-that-work.md#health-devices).

## Pedir ayuda {#getting-help}

### ¿Cómo informo de un problema o hago una pregunta? {#report-a-problem}

En Hex NFC, toca el botón del engranaje de la pantalla de inicio y luego
**Enviar comentarios**. El mensaje llega directamente a Hex Pro con la versión
de la app, la versión de iOS, el modelo del dispositivo y el idioma, y el
formulario los muestra antes de enviarlo. Si quieres una respuesta, añade tu
correo en **Dirección para responderte (opcional)**. También puedes escribir a
support@hex.pro.

Si un escaneo o una escritura fallan, busca el mensaje que has visto en
[Si no se puede escanear o escribir una etiqueta](troubleshooting.md).
