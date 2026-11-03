---
title: Documentación de Hex NFC
description: Empieza aquí para ir al manual de uso de Hex NFC, los documentos técnicos, cómo pedir ayuda y las páginas legales y el contacto de seguridad de la app.
audience: both
---

Este sitio reúne la documentación de Hex NFC, una app gratuita de Hex Pro
que lee etiquetas NFC y escribe en ellas desde un iPhone. El manual de uso es
para quienes usan la app. Los documentos técnicos son para quienes leen o
modifican su código.

## El manual de uso

El [Manual de uso de Hex NFC](guide/index.md) explica qué hace la app y qué
necesita, y cada tarea tiene su propia página: leer una etiqueta, escribir en
ella, protegerla y qué hacer cuando una etiqueta no responde. Empieza por
[Leer tu primera etiqueta](guide/quick-start.md).

## Documentos técnicos

[Arquitectura](developer/architecture.md) es para los desarrolladores que
trabajan en la app. Recorre el paquete Swift target por target, incluido cómo
se identifican los chips y cómo los simuladores de chips sustituyen a las
etiquetas reales en las pruebas, y termina con las convenciones que sigue el
código.

Consulta la [matriz de compatibilidad de chips](developer/chip-support-matrix.md)
antes de comprar etiquetas para usarlas con la app, o cuando una etiqueta no
se comporte como esperas. Cada familia de etiquetas tiene su propia tabla. La
tabla de FeliCa solo cubre la lectura y la escritura; las demás añaden la
protección con contraseña, el bloqueo permanente y el volcado de memoria. La
página indica cuáles de esos resultados se han confirmado con etiquetas reales
y cuáles no.

## Pedir ayuda {#get-help}

Cuando una etiqueta no se escanea o no se escribe,
[Si no se puede escanear o escribir una etiqueta](guide/troubleshooting.md)
repasa cada mensaje que muestra la app y qué hacer en cada caso.
[Preguntas frecuentes](guide/faq.md) explica lo que cuesta la app y en qué
modelos de iPhone funciona.

En la app, toca el botón del engranaje de la pantalla de inicio y luego
**Enviar comentarios**. El mensaje llega directamente a Hex Pro, y el formulario
muestra antes de enviarlo lo que va con él (la versión de la app, la versión de
iOS, el modelo del dispositivo y el idioma). También puedes escribir a
[support@hex.pro](mailto:support@hex.pro) o usar el
[formulario de contacto de hex.pro](https://hex.pro/es/contact?topic=support).
Los informes de fallos y las solicitudes de chips nuevos son bienvenidos como
[incidencias en GitHub](https://github.com/hexpro-dev/hex-nfc-ios/issues), y la
[página de ayuda](https://apps.hex.pro/es/hex-nfc/support) reúne todas las
formas de contactar con Hex Pro.

## Política de privacidad y términos

La [política de privacidad](https://apps.hex.pro/hex-nfc/privacy) y los
[términos y condiciones](https://apps.hex.pro/hex-nfc/terms) de Hex NFC están
publicados en apps.hex.pro. Envía cualquier pregunta sobre ellos a
[support@hex.pro](mailto:support@hex.pro).

## Informar de un problema de seguridad

Comunica cualquier vulnerabilidad en privado a
[security@hex.pro](mailto:security@hex.pro), no en un foro público ni en un
gestor de incidencias. Hex Pro acusa recibo de cada informe en un plazo de 72
horas y después trabaja con quien lo ha enviado en una corrección y en una
fecha para hacerlo público. El problema se hace público cuando la corrección
ya está disponible, o 90 días después del informe si ese plazo llega antes, y
se menciona a quien lo ha comunicado, salvo que prefiera no aparecer.
