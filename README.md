# ATM10 DevKit para CC:Tweaked

Instale **na turtle** (e, se desejar, no computador):

```text
wget run https://raw.githubusercontent.com/Pedrok390/atm-10-cctweaks/main/install.lua
```

Se o DevKit ja estiver instalado, use `dev update`.


## Stations

O DevKit pode salvar pontos nomeados por coordenadas GPS:

```text
dev station set fuel <x> <y> <z>
dev station set unload <x> <y> <z>
dev station list
dev station show fuel
dev station clear unload
```

As coordenadas de `fuel` e `unload` representam o bloco do inventario.
A turtle usa o A* para chegar a uma posicao adjacente e ficar de frente para
esse bloco sem quebrar o caminho.

- `fuel`: substitui o antigo fuel place. `dev fuel set/show/clear` continua
  funcionando por compatibilidade e grava a station `fuel`.
- `unload`: quando configurada, os itens minerados sao levados ate essa
  station; depois a turtle volta ao GPS da origem da tarefa antes de continuar.
- A origem da mineracao continua sendo salva por tarefa em `baseGps`; ela nao
  depende de uma station global `home`.

Outros nomes de station podem ser salvos agora para futuras automacoes do ATM10.

## Mining turtle

Use uma turtle com picareta equipada. O modem wireless e opcional para este
programa: ele roda localmente, sem depender do computador da base.

### Preparacao

1. Coloque a turtle sobre o canto inicial da area, apontada para o comprimento.
   A largura cresce para a direita. A primeira camada fica **um bloco abaixo
   da turtle**, e cada camada tem um bloco de altura.
2. Coloque um bau normal ou duplo **imediatamente atras**, na mesma altura.
3. O bau imediatamente atras continua sendo o bau de descarga dos itens minerados.
   O combustivel pode ficar em outro bau, configurado por coordenadas GPS.
4. Dê um nome a turtle antes de usar, por exemplo `label set mineradora`.
5. Configure o bau de combustivel, se desejar separa-lo da base:

```text
dev fuel set <x> <y> <z>
dev fuel show
dev fuel map show
dev fuel map clear
```

   As coordenadas sao do proprio bau. A turtle precisa ter GPS funcionando.
   Depois execute `dev mine`. Escolha largura, comprimento, camadas e combustivel
   minimo quando solicitado. Confira a disposicao e digite `MINERAR`.

Vista de cima (seta = direcao inicial):

```text
       frente / comprimento
       ^
       T . . .  -> direita / largura
       B

T = turtle acima do primeiro bloco a minerar
B = bau, fora da area de mineracao
```

Tambem e possivel informar os valores diretamente:

```text
dev mine start 3 3 2 500
```

Esse exemplo minera 3 blocos de largura, 3 de comprimento e 2 camadas abaixo
da turtle, saindo da base com pelo menos 500 unidades de combustivel.
O programa ainda pede `MINERAR` antes de iniciar.

### Comportamento

- Ao concluir uma camada, a turtle retorna apenas pela area ja minerada ate a coluna inicial e desce para a proxima camada, sem subir a superficie.
- A superficie so e usada quando o inventario fica sem espaco util, quando o combustivel atinge o limite de retorno, no fim da tarefa ou por comando manual.
- `minecraft:cobblestone` e `minecraft:dirt` sao descartados automaticamente com `dropDown()` para liberar slots antes de decidir retornar.


- Antes de iniciar uma camada, verifica o bloco abaixo na coluna inicial.
  Se nao detectar bloco, desce diretamente e pula essa camada, sem percorrer
  o retangulo. Repete ate encontrar um bloco ou atingir a profundidade escolhida.
  **Isso e uma estimativa pela coluna inicial, nao uma varredura da camada:**
  pode deixar blocos isolados de lado se houver um buraco nessa coluna.
  As camadas de ar contam no limite escolhido; a turtle nunca desce alem dele.
  Ao encontrar bloco, minera a camada em zigue-zague normalmente.
- Volta ao bau quando restam dois slots vazios (reserva para bloqueios no
  caminho) ou quando o combustivel se aproxima do custo de retorno mais uma
  margem de 32 movimentos, incluindo a reserva necessaria para ir da base ate o bau de combustivel configurado. Descarrega e retoma a partir da ultima celula.
- Tambem volta ao bau ao concluir cada camada e no final da tarefa.
- Para sair da base, exige o maior valor entre o minimo escolhido e
  `2 * (largura + comprimento + camadas - 2) + 32`, suficiente para ida e volta
  ao ponto mais distante mais uma margem. Valores acima do tanque sao rejeitados.
- Se houver `dev fuel set x y z`, a turtle usa esse bau exclusivamente para
  abastecimento. Quando precisa de combustivel, primeiro retorna a base da tarefa,
  depois segue por GPS ate uma posicao adjacente ao bau, sem quebrar blocos.
  O trajeto usa A* em 3D. Ao encontrar um obstaculo, marca aquela coordenada
  como bloqueada e recalcula automaticamente a melhor rota conhecida, podendo
  contornar pelos lados ou por cima/baixo quando houver espaco. Os obstaculos
  descobertos sao salvos em `/dev/fuel-map`, entao viagens futuras ja evitam
  paredes conhecidas. Use `dev fuel map clear` se alterar fisicamente o caminho.
- Se nenhum fuel place estiver configurado, mantem compatibilidade com o
  abastecimento pelo bau da base.
- Qualquer item aceito por `turtle.refuel(0)` pode ser usado. No caso de
  `lava_bucket`, o balde vazio permanece no slot da turtle e e devolvido ao
  mesmo bau de combustivel antes de ela voltar para a base.
- Espera no bau se faltar combustivel ou espaco, verificando novamente a cada
  cinco segundos. Reponha o primeiro slot ou esvazie o bau para continuar.
- Verifica se ha um inventario a frente antes de descarregar; se o bau sumir,
  interrompe. Mantenha esse bau no lugar enquanto o programa estiver ativo.
- Se houver bedrock, protecao de terreno ou outro obstaculo persistente,
  interrompe com uma mensagem. Nao ataca entidades para liberar o caminho.

O intervalo aceito e 1-256 de largura/comprimento e 1-512 camadas. Isso nao
garante que todas as camadas caibam na altura do mundo: um bloco inquebravel
interrompe a tarefa. O percurso usa o poco na primeira celula e corredores
ja visitados para retornar; evite construir ou preencher a mina durante o uso.

### Interromper e retomar

Segure `Ctrl+T` para interromper. Depois:

```text
dev mine status
dev mine resume
```

Nao mova nem gire a turtle manualmente entre essas operacoes. O progresso e
salvo em `/dev/mine-state.a` e `/dev/mine-state.b`; `dev update` preserva esses
arquivos. A mineracao **nao** reinicia sozinha ao ligar o computador.

Se uma interrupcao acontecer durante um movimento/giro, o programa recusa
retomar com uma posicao incerta. Recoloque a **mesma turtle** exatamente na
origem, com a orientacao inicial e o bau atras, e execute:

```text
dev mine recover-home
```

Confirme com `ORIGEM` e execute `dev mine resume`. Esse comando registra
novamente a origem e, quando houver sinal, recalibra o GPS da base.

### Validacao

`tests/mine_test.lua` simula as APIs de CC:Tweaked e testa percursos pares e
impares, camadas vazias, retorno por inventario/combustivel, bau cheio/ausente,
retomada e recuperacao de interrupcoes. Execute com Lua 5.2 ou superior:

```text
lua tests/mine_test.lua
```

Os testes nao substituem a verificacao no jogo. Comece com a area 3x3x2 do
exemplo, confira o bau, o retorno a origem e o esvaziamento das duas camadas.

Referencias: [turtle](https://tweaked.cc/module/turtle.html) e
[inventarios](https://tweaked.cc/generic_peripheral/inventory.html).


## Trash blacklist

A mining turtle descarta automaticamente itens configurados na blacklist antes
de decidir que o inventario esta cheio.

```text
dev trash list
dev trash add minecraft:deepslate
dev trash remove minecraft:dirt
dev trash clear
dev trash reset
```

Na primeira instalacao, os padroes sao `minecraft:cobblestone` e
`minecraft:dirt`. `clear` deixa a lista vazia; `reset` restaura esses dois
padroes. A configuracao fica salva em `/dev/trash-list`.
