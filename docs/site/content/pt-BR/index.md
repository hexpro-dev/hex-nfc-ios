---
title: Documentação do Hex NFC
description: Comece por aqui para consultar o manual do usuário do Hex NFC, os documentos de engenharia, como pedir ajuda, as páginas legais e o contato de segurança.
audience: both
---

Este site reúne a documentação do Hex NFC, um app gratuito da Hex Pro que lê
e grava etiquetas NFC no iPhone. O manual do usuário é para quem usa o app. Os
documentos de engenharia são para quem lê ou altera o código dele.

## O manual do usuário

O [Manual do usuário do Hex NFC](guide/index.md) explica o que o app faz e do
que ele precisa, e cada tarefa tem a sua página: ler uma etiqueta, gravar
nela, protegê-la e o que fazer quando uma etiqueta não responde. Comece por
[Ler sua primeira etiqueta](guide/quick-start.md).

## Documentos de engenharia

[Arquitetura](developer/architecture.md) é para desenvolvedores que trabalham
no app. O documento percorre o pacote Swift target por target, incluindo como
os chips são identificados e como os simuladores de chip substituem as
etiquetas reais nos testes, e termina com as convenções que o código segue.

Leia a [matriz de compatibilidade de chips](developer/chip-support-matrix.md)
antes de comprar etiquetas para usar com o app, ou quando uma etiqueta não se
comportar como você espera. Cada família de etiquetas tem a sua própria
tabela. A tabela de FeliCa cobre somente leitura e gravação; as outras
acrescentam proteção por senha, bloqueio permanente e despejo de memória. A
página indica quais desses resultados foram confirmados em etiquetas reais e
quais não foram.

## Pedir ajuda {#get-help}

Quando uma etiqueta não é lida ou gravada,
[Se não for possível ler ou gravar uma etiqueta](guide/troubleshooting.md)
passa por cada mensagem que o app mostra e o que fazer em cada caso.
[Perguntas frequentes](guide/faq.md) explica quanto o app custa e em quais
iPhones ele roda.

No app, toque no botão de engrenagem da tela inicial e depois em
**Enviar feedback**. A mensagem vai direto para a Hex Pro, e o formulário
mostra antes do envio o que vai junto com ela (versão do app, versão do iOS,
modelo do dispositivo e idioma). Você também pode escrever para
[support@hex.pro](mailto:support@hex.pro) ou usar o
[formulário de contato do hex.pro](https://hex.pro/pt-BR/contact?topic=support).
Relatórios de bug e pedidos de novos chips são bem-vindos como
[issues no GitHub](https://github.com/hexpro-dev/hex-nfc-ios/issues), e a
[página de ajuda](https://apps.hex.pro/pt-BR/hex-nfc/support) reúne todas as
formas de falar com a Hex Pro.

## Política de privacidade e termos

A [política de privacidade](https://apps.hex.pro/hex-nfc/privacy) e os
[termos e condições](https://apps.hex.pro/hex-nfc/terms) do Hex NFC estão
publicados em apps.hex.pro. Envie perguntas sobre qualquer um deles para
[support@hex.pro](mailto:support@hex.pro).

## Relatar um problema de segurança

Comunique uma vulnerabilidade de forma privada para
[security@hex.pro](mailto:security@hex.pro), e não em um fórum público nem em
um rastreador de problemas. A Hex Pro confirma o recebimento do relato em até
72 horas e depois trabalha com quem o enviou em uma correção e em uma data
para a divulgação pública. O problema se torna público assim que a correção é
lançada, ou 90 dias após o relato, se isso acontecer antes, e quem o enviou
recebe o crédito, a menos que prefira não receber.
