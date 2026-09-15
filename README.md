# Gen1Recomp — TikTok LIVE Interativa

Uma configuração Windows para deixar o chat do TikTok controlar o jogo em
tempo real, sem simular teclas e sem bloquear o teclado ou o controle local.

```text
Chat do TikTok LIVE → ponte local → receptor em 127.0.0.1 → jogo
```

Cada comando aceito no chat vira uma ação imediata de Game Boy. O teclado e o
gamepad continuam sendo entradas independentes para quem está transmitindo.

## Iniciar uma live

1. Feche qualquer instância do jogo que esteja aberta.
2. Dê duplo clique em [Play-TikTok-Live.bat](Play-TikTok-Live.bat).
3. Informe seu `@usuario` do TikTok e, se quiser, a duração de cada botão em
   milissegundos (o padrão é 120 ms).
4. O script abre o jogo com o receptor local habilitado e espera ele ficar
   pronto.
5. Inicie a transmissão no TikTok.
6. Volte à janela do lançador e pressione uma tecla para conectar ao chat.

O jogo e a ponte do TikTok ficam em janelas separadas. Para encerrar a ponte,
use `Ctrl+C` nessa janela; o jogo continua aberto normalmente.

> É necessário ter uma ROM compatível obtida legalmente para executar o jogo.
> Nenhuma ROM é fornecida por este repositório.

## Comandos do chat

O comentário precisa conter apenas um comando e começar com `!`.

| Comentário | Ação |
| --- | --- |
| `!cima` ou `!up` | Cima |
| `!baixo` ou `!down` | Baixo |
| `!esquerda` ou `!left` | Esquerda |
| `!direita` ou `!right` | Direita |
| `!a` ou `!confirmar` | Botão A |
| `!b` ou `!voltar` | Botão B |
| `!start` ou `!menu` | Start |
| `!select` | Select |

Exemplos: `!direita` movimenta o personagem e `!menu` abre o menu do jogo.

## Proteções e comportamento

- O receptor aceita conexões somente em `127.0.0.1`; ele não fica exposto à
  rede ou à internet.
- Um token aleatório é gerado a cada abertura da live e usado somente entre a
  ponte local e o jogo.
- O chat recebe até oito comandos por segundo no total, e cada espectador pode
  enviar um comando a cada 0,8 segundos.
- Os comandos são imediatos; não há votação nem emulação de teclado.
- A integração de chat usa TikTokLive, uma biblioteca não oficial. Se o
  TikTok modificar o protocolo de LIVE, pode ser necessário atualizar a
  dependência. Consulte [docs/tiktok-live.md](docs/tiktok-live.md) para os
  detalhes técnicos e solução de problemas.

## Projeto original e créditos

Esta configuração de live é uma adaptação local baseada no projeto
[bryanthaboi/gen1recomp](https://github.com/bryanthaboi/gen1recomp). O motor,
o importador de ROM, a recriação do jogo e a plataforma de mods pertencem ao
repositório original e aos respectivos colaboradores.

Consulte o [README original](https://github.com/bryanthaboi/gen1recomp) para
documentação geral, plataformas suportadas, modding, link play, licença e
créditos completos. Agradecimentos também ao projeto
[pret/pokered](https://github.com/pret/pokered), cuja pesquisa viabiliza a
preservação e o estudo do jogo original.
