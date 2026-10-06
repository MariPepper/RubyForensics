# File Integrity Comparator

Aplicação Ruby para comparar dois ficheiros e documentar diferenças de forma adequada a um projeto de análise de integridade/ciberforense.

## Versão

Este README corresponde à versão **0.4.0** do código.

## Funcionalidades

- SHA-256 dos bytes originais de cada ficheiro.
- Determinação rápida de igualdade byte-a-byte através do SHA-256.
- Comparação textual linha a linha quando os hashes são diferentes.
- Deteção de:
  - linhas modificadas;
  - linhas acrescentadas;
  - linhas eliminadas.
- Alinhamento de linhas por LCS (Longest Common Subsequence).
- Emparelhamento de linhas modificadas por Levenshtein, com duas estratégias:
  - **greedy** — cada linha eliminada escolhe o melhor par disponível (rápido);
  - **hungarian** — atribuição de custo total mínimo, óptima e simétrica (default).
- Threshold adaptativo: `min(max_absolute, relative_ratio × comprimento da linha)`.
- Normalização Unicode configurável antes de comparar: **NFC** (default), **NFD** ou **nenhuma**.
- Identificação da primeira coluna diferente.
- Diff de caracteres para explicar alterações dentro da linha.
- Relatório de texto e relatório JSON.
- Log de auditoria encadeado por SHA-256.
- Menu interactivo (quando o terminal é um TTY).
- Código sem dependências externas em runtime.

## Requisitos

Ruby 3.x recomendado.

Não são necessárias gems adicionais para executar o comparador.

## Execução

```bash
ruby bin/filecompare ficheiro_original.txt copia.txt
```

Se o terminal for interactivo, aparece um menu que permite escolher:

1. Estratégia de emparelhamento (greedy ou hungarian).
2. Normalização Unicode (NFC, NFD ou nenhuma).
3. Threshold absoluto máximo.
4. Threshold relativo.

Código de saída:

- `0`: ficheiros idênticos;
- `1`: ficheiros diferentes;
- `2`: erro de utilização ou ficheiro.

### Guardar relatório

```bash
ruby bin/filecompare original.txt copia.txt \
  --output relatorio.txt \
  --json relatorio.json \
  --audit auditoria.jsonl
```

### Especificar codificação

Por defeito é utilizada UTF-8:

```bash
ruby bin/filecompare original.txt copia.txt --encoding ISO-8859-1
```

### Escolher estratégia de emparelhamento

```bash
ruby bin/filecompare original.txt copia.txt --strategy greedy
ruby bin/filecompare original.txt copia.txt --strategy hungarian
```

Sem `--strategy`, o default é `hungarian`.

### Escolher normalização Unicode

```bash
ruby bin/filecompare original.txt copia.txt --normalize nfc
ruby bin/filecompare original.txt copia.txt --normalize nfd
ruby bin/filecompare original.txt copia.txt --normalize none
```

Sem `--normalize`, o default é `nfc`.

### Ajustar o threshold

```bash
ruby bin/filecompare original.txt copia.txt \
  --max-absolute 3 \
  --relative-ratio 0.20
```

O threshold efectivo de cada par é `min(max_absolute, ceil(relative_ratio × comprimento))`.
Um par só é classificado como `modified` se a distância de Levenshtein for menor ou igual a este threshold.

### Desactivar o menu interactivo

Útil em scripts, pipelines ou CI:

```bash
ruby bin/filecompare original.txt copia.txt --no-menu
```

Também fica automaticamente desactivado se `--strategy` ou `--normalize` forem passados, ou se o stdin/stdout não forem um TTY.

## Exemplo

Original:

```text
nome=Joao
idade=30
cidade=Lisboa
```

Cópia:

```text
nome=Joana
idade=30
cidade=Lisboa
```

A ferramenta indica:

- modificação na linha 1;
- primeira coluna diferente;
- distância de Levenshtein;
- threshold aplicado;
- alterações de caracteres dentro da linha.

## Arquitetura

```text
CLI (bin/filecompare)
 |
 +--> Menu (se TTY e não desactivado) --> strategy, normalize, thresholds
 |
 v
Comparator
 |
 +--> SHA-256 -------------------------> igualdade global (bytes)
 |
 +--> Normalização Unicode (NFC/NFD) --> aplicada após leitura, antes de comparar
 |
 +--> SequenceDiff (LCS) --------------> alinhamento de linhas
 |         |
 |         +--> LineMatcher -----------> emparelhamento de blocos
 |                  |
 |                  +--> GreedyAssigner
 |                  +--> HungarianSolver
 |                  +--> Threshold adaptativo
 |                  |
 |                  +--> Levenshtein ---> distância (decide modified vs deleted/added)
 |
 +--> Character Diff (LCS) ------------> alterações/colunas dentro da linha
 |
 +--> Report --------------------------> TXT / JSON
 |
 +--> AuditLog ------------------------> JSONL encadeado por SHA-256
```

## Porque usar SHA-256, LCS e Levenshtein?

São mecanismos diferentes e complementares.

**SHA-256** verifica a integridade global dos bytes. Se os hashes forem iguais, os ficheiros são considerados idênticos e nada mais é analisado. O hash é sempre calculado sobre os bytes originais, **independentemente da normalização Unicode** escolhida — porque a normalização é uma decisão textual, não binária.

**LCS** alinha as linhas dos dois ficheiros, produzindo uma sequência de operações `equal`, `delete` e `insert`. É o que permite distinguir uma linha eliminada de uma simples alteração de posição.

**Levenshtein** mede a distância de edição entre duas linhas. Nesta versão, não é apenas um número decorativo: é usado para **decidir** se duas linhas de um bloco de mudança são a mesma linha modificada ou se são, de facto, uma eliminação e uma inserção independentes. A decisão depende do threshold adaptativo.

## Nota sobre o emparelhamento

Quando existe um bloco de eliminações e inserções, a aplicação emparelha as linhas desse bloco para tentar classificá-las como modificações. Há duas estratégias:

- **greedy** — cada linha eliminada escolhe o melhor insert ainda disponível. Rápido (O(D×I×L²)), mas pode falhar em blocos ambíguos.
- **hungarian** — algoritmo Húngaro (Kuhn-Munkres) para atribuição de custo total mínimo. Óptimo e simétrico (A→B e B→A produzem o mesmo resultado), mas com custo O(n³) por bloco.

Esta heurística é útil para leitura humana, mas não deve ser interpretada como uma reconstrução sem ambiguidades da história do ficheiro.

## Nota sobre a normalização Unicode

Em Unicode, o mesmo caracter visual pode ter várias representações. Por exemplo, `é` pode ser `U+00E9` (NFC) ou `U+0065 U+0301` (NFD). Sem normalização, a comparação pode reportar diferenças que não existem visualmente.

- **NFC** compõe (`e` + acento → `é`). É o default e o que os sistemas modernos usam.
- **NFD** decompõe (`é` → `e` + acento). Útil para comparar com sistemas que usam NFD.
- **Nenhuma** compara os caracteres como estão. Útil quando a codificação é ela própria objecto de análise.

A normalização **não afecta o SHA-256**: dois ficheiros com o mesmo texto mas codificação diferente continuam a ter hashes diferentes, e isso é o correcto em contexto forense.

## Considerações forenses

A aplicação não pretende, isoladamente, estabelecer autenticidade jurídica.

Num procedimento forense real devem ser considerados, entre outros:

- preservação da evidência original;
- aquisição adequada;
- cadeia de custódia;
- hashes calculados e registados no momento apropriado;
- documentação dos equipamentos e ferramentas;
- versões da ferramenta;
- data/hora e fuso horário;
- controlo de acesso;
- documentação de todas as operações;
- armazenamento seguro dos relatórios e logs.

O log produzido pela aplicação utiliza uma cadeia de hashes entre eventos. Isso permite detetar alterações posteriores no próprio log, mas não substitui mecanismos externos de preservação e validação.

O relatório e o log registam:

- a estratégia de emparelhamento usada (`greedy` ou `hungarian`);
- a normalização Unicode aplicada (`nfc`, `nfd` ou `none`);
- os thresholds (`max_absolute` e `relative_ratio`);
- a versão da ferramenta e a versão do Ruby.

Esta informação é essencial para reprodutibilidade: os mesmos ficheiros com os mesmos parâmetros produzem sempre o mesmo resultado.

## Limitações atuais

1. O conteúdo é tratado como texto para a análise de diferenças.
2. O hash continua a ser calculado sobre os bytes originais.
3. Ficheiros binários podem ser comparados por hash, mas não são adequados à análise textual.
4. O algoritmo LCS tem custo de memória/tempo O(n*m). Ficheiros de texto enormes deverão ser tratados com uma estratégia de streaming ou um algoritmo de diff mais eficiente.
5. O emparelhamento Húngaro tem custo O(n³) por bloco. Para blocos com milhares de linhas pode tornar-se lento; nesse caso, `--strategy greedy` é uma alternativa.
6. O emparelhamento é um-para-um: não lida com fusões (`2 → 1`) nem divisões (`1 → 2`).
7. A aplicação não assina digitalmente o relatório.
8. O timestamp depende do relógio do sistema; num contexto forense deverá existir uma política adequada de sincronização temporal.
9. A normalização Unicode é aplicada ao texto lido, mas não altera o hash nem os bytes do ficheiro.

## Evolução recomendada

Para uma versão futura:

- interface gráfica;
- comparação de diretórios;
- suporte a vários algoritmos de hash (SHA-256, SHA-512);
- deteção automática de encoding;
- modo binário/hexadecimal;
- assinatura digital do relatório;
- verificação da cadeia do audit log;
- exportação PDF;
- testes de desempenho;
- proteção contra ficheiros alterados durante a leitura;
- identificação de links simbólicos e metadados;
- modo somente-leitura;
- opção para gerar um manifesto de evidência antes da análise;
- Damerau-Levenshtein (transposições contam 1 edição);
- deteção automática de blocos ambíguos (correr as duas estratégias e comparar).