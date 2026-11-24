<div align="center">

<img src="../../assets/icon.png" width="120" alt="Ícone do RenderDock">

# RenderDock

**Todos os renders do seu Mac, em uma cápsula flutuante.**

[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · **Português** · [Русский](README.ru.md)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![Dependências: nenhuma](https://img.shields.io/badge/dependencies-none-4FEDB0)
![Licença: MIT](https://img.shields.io/badge/license-MIT-42C2FF)

<img src="../../assets/demo.gif" width="820" alt="Demonstração do RenderDock: a cápsula se expande em um painel, é arrastada pela tela e se encaixa em um canto">

<sub>A interface acima é desenhada pelo próprio app em modo de demonstração. As tarefas, os números e o ponteiro seguem um roteiro; o fundo é uma área de trabalho simulada.</sub>

</div>

---

O RenderDock é um pequeno app nativo de macOS para quem inicia renders a partir de scripts e terminais. Ele encontra todas as tarefas do Blender sem interface em execução na máquina, mostra em que ponto cada uma está e fica de olho no hardware que faz o trabalho. Não precisa de configuração e nunca mexe nas suas tarefas.

## Por quê

Um render iniciado por um script de shell não tem janela. Você acaba rodando `ps`, contando arquivos em uma pasta de saída e se perguntando se o Mac entrou em repouso há uma hora. O RenderDock reúne tudo isso em um só lugar, que está sempre na tela e nunca atrapalha.

## O que ele oferece

<table>
<tr>
<td width="50%" valign="top">

**Uma cápsula que fica em qualquer lugar**

Arraste-a para qualquer tela. Ela se encaixa nas bordas, nos cantos e no centro da borda superior ou inferior, e lembra onde você a deixou. Flutua sobre apps em tela cheia e acompanha você de um Space a outro.

<img src="../../assets/capsule-en.png" width="380" alt="A cápsula recolhida">

**Um clique para ver tudo**

- Cada cadeia de tarefas em um cartão: título, projeto, script, tempo decorrido
- Uma barra de segmentos para filas com vários shots: concluído (Done), renderizando (Rendering), pausado (Paused), a seguir (Up next)
- Para o shot em andamento: miniatura do último quadro, número de quadros, segundos por quadro, tempo restante, núcleos de CPU e memória
- Estados que ele distingue: em execução (Running), pausado (`SIGSTOP`), travado (Stalled), na fila (Queued)

**A máquina, de relance**

CPU, uso de GPU e memória de GPU, memória e pressão de memória, temperatura do SoC, swap, espaço livre em disco, fonte de energia e se algo está mantendo o Mac acordado.

</td>
<td width="50%" valign="top">

<img src="../../assets/panel-en.png" width="400" alt="O painel expandido, com cartões de tarefas e métricas do sistema">

</td>
</tr>
</table>

Também inclui: um item na barra de menus com um anel de progresso, uma opção **Manter ativo durante o render** (Keep Awake While Rendering) e **Abrir ao iniciar sessão** (Launch at Login).

Novidades da versão 0.2: progresso exato para qualquer render com [`renderdock run`](../EXACT-PROGRESS.md), [notificações](../NOTIFICATIONS.md) no Mac e no celular quando uma tarefa termina, falha ou trava, e uma [API local](../API.md) para que outros displays mostrem o mesmo progresso. Esses três documentos estão, por enquanto, apenas em inglês.

Novidades da versão 0.3: um [histórico](../HISTORY.md) com estimativas de tempo restante para uma fila inteira; as [sessões de agentes de programação](../AGENT-TASKS.md) ao lado dos seus renders; progresso real para [codificações com ffmpeg](../EXACT-PROGRESS.md#ffmpeg-from-03), e a fila do [ComfyUI](../COMFYUI.md). Há mais coisas que ficam desligadas até você ligá-las: [responder ao pedido de permissão de um agente](../ANSWERING-AGENTS.md) pelo painel, um [pequeno display Bluetooth para a mesa](../DEVICES.md) com [firmware aberto](../../firmware/desk-display/README.md) para uma placa, uma [entrada para outros programas](../AGENT-ENTRY.md), para que qualquer script ou agente possa enviar um aviso, informar o progresso ou fazer uma pergunta a você, e [MQTT](../MQTT.md) para o Home Assistant. Dois [exemplos](../../examples) usam a API local: uma fita de LED como barra de progresso e uma tecla do Stream Deck. Esses documentos estão, por enquanto, apenas em inglês.

## Início rápido

Requisitos: macOS 14 ou posterior e a toolchain do Swift 6 (Xcode 16+ ou apenas as Command Line Tools: `xcode-select --install`).

```bash
git clone https://github.com/JarnoNiu/RenderDock.git
cd RenderDock
zsh scripts/install.sh
```

Isso compila o app, copia para `/Applications/RenderDock.app` e o abre. Sem senha de administrador, sem dependências para baixar. Adicione `--login` para ativar também a abertura ao iniciar sessão.

Nenhum render rodando? Veja como ele fica com tarefas fictícias:

```bash
open -n /Applications/RenderDock.app --args --demo
```

Ou veja-o detectar um processo real, sem Blender e sem GPU envolvidos:

```bash
zsh scripts/fake-render.sh 60 1
```

> Ainda não há um download pré-compilado. O app não é notarizado, e um download não assinado dá mais trabalho do que uma compilação de 30 segundos. Versões assinadas e um cask do Homebrew estão no roadmap.

## Como ele encontra seus renders

O RenderDock lê a tabela de processos e as pastas de saída. Ele não se acopla ao Blender, e você não precisa alterar seus scripts.

| O que ele vê | O que ele mostra |
|---|---|
| Um processo do Blender iniciado com `-b` / `--background` | Um **shot** |
| O script mais externo acima dele na árvore de processos (`zsh render_all.sh`, `python queue.py`, …) | Uma **cadeia de tarefas**: um cartão. O título é a primeira linha de comentário desse script |
| Argumentos `scene:shot` na linha de comando de um script de fila | A **fila**: quais shots estão concluídos, quais estão renderizando e quais vêm a seguir |
| Um script envolvido por `caffeinate`, ainda sem processo de render | **Na fila** |
| Um processo parado com `kill -STOP` | **Pausado** |
| Nenhum quadro novo por 10 vezes o tempo habitual por quadro (no mínimo 5 minutos) | **Travado** |
| Arquivos de imagem na pasta de saída, sem duplicatas por número de quadro | **Quadros concluídos**, segundos por quadro, miniatura do último quadro |

A pasta de saída vem do `-o` / `--render-output` do próprio Blender (incluindo caminhos `//` relativos ao `.blend`) ou de um argumento de script `--out PASTA` depois de `--`. As etapas do seu próprio pipeline que não são um simples render do Blender podem ser descritas em um pequeno [arquivo de regras](../ADAPTERS.md).

### De onde vem a porcentagem

O RenderDock só mostra uma porcentagem quando conhece o total. Ele não tenta adivinhar.

| Fonte | Exibido como |
|---|---|
| `render-progress.json` na pasta de saída (veja abaixo) | exato: `412/720 frames · 57%` e tempo restante |
| Um intervalo de quadros na linha de comando: `-s 1 -e 250 -a` ou `-f 1..250` | exato |
| Iniciado com `renderdock run --`, ou com o hook do Blender carregado | exato, mesmo quando não há nada na linha de comando. Também distingue uma tarefa concluída de uma que falhou |
| Um clipe mais antigo com o mesmo nome ao lado da pasta de saída | estimativa, marcada com `≈`. Descartada assim que a contagem de quadros a ultrapassa |
| Nenhuma dessas | apenas contagem de quadros e segundos por quadro, com uma barra indeterminada |

```bash
# progresso exato, sem configuração
blender -b shot_010.blend -o //render/frame_#### -s 1 -e 250 -a
```

### `render-progress.json`: progresso exato para qualquer pipeline

Se o intervalo fica dentro do `.blend` ou se o seu script renderiza os quadros por conta própria, grave um pequeno arquivo na pasta de saída depois de cada quadro:

```json
{"done": 12, "total": 720}
```

```python
# em um script Python do Blender
(out_dir / "render-progress.json").write_text(json.dumps({"done": i + 1, "total": len(frames)}))
```

Qualquer coisa capaz de gravar um arquivo pode informar o progresso assim, não só o Blender.

## O que ele não faz

- **Nunca mexe nos seus renders**: não envia sinais a eles e nunca grava nas suas pastas de render. Tudo o que vai além de observar fica desligado até você ligar: os canais de notificação, a API local (apenas em `127.0.0.1`), o Bluetooth para um display de mesa, responder aos pedidos dos agentes, a entrada para outros programas e o MQTT. Não faz conexões de rede, a menos que você adicione um canal de notificação ou um broker MQTT.
- Ainda não há botões de pausar, retomar ou parar. Scripts de fila costumam gerenciar `STOP`/`CONT` por conta própria, e duas mãos no mesmo interruptor é uma má ideia.
- Se nem a pasta de saída nem o intervalo de quadros estiverem na linha de comando, a tarefa aparece mesmo assim, com CPU, memória e tempo decorrido, mas sem quadros.
- A temperatura do SoC é lida de sensores IOHID, uma interface privada disponível no Apple Silicon. Em Macs com Intel, ou depois de uma atualização do sistema que mude os sensores de lugar, o indicador mostra `–`. A velocidade dos ventiladores e a potência consumida não são lidas.
- Compilado e testado no macOS 26 com um M5 Max. Ele compila para o macOS 14, mas as versões 14 e 15 e os Macs com Intel não foram testados. Relatos são bem-vindos.
- Idiomas da interface: inglês e chinês simplificado (segue o idioma do sistema; force um deles com `--lang en` ou `--lang zh`).

## Roadmap

A lista completa de pendências, com um cronograma, está em **[ROADMAP.md](../../ROADMAP.md)**.

Em resumo (planos, não promessas):

- Acesso pela rede: a API protegida por um token, o display de mesa por Wi-Fi
- Mais renderizadores com progresso próprio
- Controles opcionais: pausar, retomar, reduzir a prioridade
- Versões assinadas e notarizadas, Homebrew, mais idiomas de interface

## Desenvolvimento

| Comando | O que faz |
|---|---|
| `zsh scripts/build-app.sh` | Compila `build/RenderDock.app` (assinatura ad hoc; o ícone é desenhado pelo próprio app) |
| `zsh scripts/install.sh [--login]` | Compila, instala em `/Applications` e reabre |
| `swift run rd-checks` | Verifica o núcleo: parsing, eventos, API, notificações, agentes e o protocolo de dispositivos (534 verificações) |
| `.build/release/RenderDock --dump` | Imprime as tarefas detectadas e as métricas como texto, sem interface |
| `.build/release/RenderDock --snapshot PASTA [--demo]` | Renderiza a cápsula e o painel em PNG |
| `zsh scripts/make-demo.sh` | Gera novamente as capturas de tela e o GIF em `assets/` |
| `zsh scripts/fake-render.sh [quadros] [s/quadro]` | Um render simulado para testar a detecção |
| `python3 scripts/verify-interactions.py <binário>` | Injeta cliques e arrastos em uma instância iniciada com `--debug` e verifica a expansão, o recolhimento e o encaixe (12 verificações) |

O código é Swift e SwiftUI puros, com AppKit para a janela: cerca de 9.000 linhas, sem pacotes. Veja [CONTRIBUTING.md](../../CONTRIBUTING.md).

## Agradecimentos

O RenderDock não compartilha código com estes projetos, mas eles mostraram o que é possível sem `sudo`: [Stats](https://github.com/exelban/stats) e [macmon](https://github.com/vladkens/macmon), pela leitura de dados de GPU e de sensores, e [boring.notch](https://github.com/TheBoredTeam/boring.notch), por fazer uma interface pequena e sempre presente parecer em casa no Mac.

Um projeto com objetivo parecido: o [Blender Render Monitor](https://github.com/DUBSON0/blender-render-monitor) também lista os renders do Blender em um Mac e já tem pausa, retomada e fila. Ele obtém o progresso a partir de um script de hook do Blender ou de um arquivo de log. O RenderDock 0.1 foi escrito sem conhecimento dele; os dois não compartilham código.

## Licença

[MIT](../../LICENSE)
