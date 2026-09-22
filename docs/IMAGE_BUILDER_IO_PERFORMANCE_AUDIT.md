# Auditoria de I/O e desempenho do PMJS Image Builder

## Escopo e conclusão

Esta auditoria registrou primeiro o baseline de `main` em `build-image.sh` para
publicação direta em staging local, NFS ou Ventoy. A seção **Optimization Phase
1** documenta o pipeline atual depois da fusão conservadora de operações. O
formato, a generalização e a publicação não foram alterados.

No baseline observado em hardware real (`--ventoy-dir`, com o staging do build no
exFAT), depois de criado o `rootfs.tar.zst` é percorrido **12 vezes** antes do
commit. As 12 passagens leem os bytes comprimidos por inteiro; **6 também
descomprimem todo, ou efetivamente todo, o fluxo**. O `homefs.tar.zst` sofre
**11 passagens completas**, das quais **5 descomprimem** o fluxo.

Isso confirma a hipótese de múltiplas releituras no pendrive. Também existe um
custo antes não atribuído no resumo: `validate_image_directory` ocorre depois da
medição de `metadata` e adiciona quatro passagens por archive; em seguida,
`sync --file-system` pode aguardar a gravação de todos os dados sujos do
filesystem, não somente do `manifest.json` indicado na linha de comando.

## Linha do tempo lógica do baseline

```text
SOURCE_ROOT (filesystem Linux)
  -> validações da origem e overlay de generalização local
  -> GNU tar --create (lê árvore, metadados Unix, ACLs, xattrs e symlinks)
  -> zstd -3
  -> <destino>/.pmjs-*.build.*/rootfs.tar.zst.partial
  -> 4 passagens de validação do rootfs
  -> rename para rootfs.tar.zst dentro do staging

HOME_SOURCE
  -> du/find e cópia da whitelist por rsync para staging Linux local
  -> validação da árvore filtrada
  -> GNU tar --create -> zstd -3
  -> <destino>/.pmjs-*.build.*/homefs.tar.zst.partial
  -> 3 passagens de validação do homefs
  -> rename para homefs.tar.zst dentro do staging

rootfs.tar.zst + homefs.tar.zst
  -> SHA256SUMS: gerar e conferir
  -> manifest.json: calcular hashes, escrever e conferir schema/hash/tamanho
  -> validação completa do diretório: zstd, tar, SHA256SUMS e manifest
  -> syncfs antes do rename
  -> rename atômico do diretório oculto para pmjs-linux-<versão>
  -> syncfs depois do rename
```

Em `NFS e Ventoy`, o fluxo acima termina primeiro no NFS. O bundle NFS final é
validado novamente, lido uma vez pelo `rsync`, validado novamente nos bytes do
Ventoy e só então renomeado no Ventoy. Isso é diferente do build direto no
Ventoy usado na medição de 1h29min.

## Classificação de acesso

- **A**: leitura completa dos bytes comprimidos, sem descompressão.
- **B**: leitura e descompressão completa do archive. A vazão registrada usa o
  tamanho comprimido e não mede o volume lógico descomprimido.
- **C**: metadados ou conteúdo pequeno/parcial; `stat`, `findmnt`, JSON e nomes.
- **D**: percurso/leitura do filesystem-fonte ou do staging Linux local.
- **E**: escrita do archive ou bundle.
- **F**: operação pequena/desprezível para um bundle de vários GiB.

## Pipeline e comandos externos do baseline

Esta tabela preserva o inventário que fundamentou a otimização. Operações
removidas na fase 1 estão identificadas na seção correspondente ao final.

| Etapa | Função | Arquivo | Comando externo | Fonte lida | Destino escrito | Tipo | Archive completo? | Descompressão completa? | Motivo / garantia |
|---|---|---|---|---|---|---|---|---|---|
| Seleção/destino | `select_build_destination`, checks de identidade/espaço | `build-image.sh`, `lib/nfs.sh`, `lib/ventoy.sh`, `lib/checks.sh` | `findmnt`, `lsblk`, `blkid`, `mount`, `df`, `realpath`, `stat` | tabelas de mount/disco e metadados | mountpoint, somente quando automount foi solicitado | C/F | não | não | confirma origem/tipo/identidade do mount e espaço; não percorre archive |
| Descoberta da origem (`auto`) | `detect_capture_sources` e auxiliares | `lib/source_detect.sh` | `lsblk`, `blkid`, `mount` somente leitura, `umount`, `realpath`, `find` no cleanup | tabelas de blocos e candidatos montados temporariamente | staging de mount local | C/D | não | não | encontra root/home Linux e exclui mídias removíveis/Live |
| Preflight da home | `estimate_homefs_staging_size_mib` | `lib/homefs.sh` | `du -sb`, `find`, `stat`, `grep` | whitelist em `HOME_SOURCE` | — | D/C | não | não | estima somente o espaço local necessário |
| Generalização | `validate_generalization_source`, `prepare_*`, `validate_*` | `lib/generalize.sh` | `stat`, `install`, `find` no cleanup | arquivos essenciais e overlay local | overlay local pequeno | C/D | não | não | garante fonte válida e drop-in SSH correto |
| Rootfs: criação | `generate_rootfs` | `lib/rootfs.sh` | `tar --create --use-compress-program="zstd -3"` | árvore inteira de `SOURCE_ROOT`, respeitando exclusões e `--one-file-system` | `rootfs.tar.zst.partial` | D+E | n/a | n/a | captura metadados Unix e aplica a generalização |
| Rootfs: integridade | `validate_archive_compression` | `lib/archive.sh` | `zstd --test --quiet` | rootfs comprimido | — | B | sim | sim | valida todos os frames/checksums zstd |
| Rootfs: membros | `validate_rootfs` | `lib/rootfs.sh` | `tar --list --zstd` | rootfs comprimido | listagem em memória | B | sim | sim | valida estrutura tar e fornece nomes para paths, exclusões e presença |
| Rootfs: paths/exclusões | `validate_rootfs` | `lib/rootfs.sh` | shell + `grep` | listagem já em memória | — | F | não | não | proíbe identidades, pseudo-filesystems, home e output; exige arquivos essenciais |
| Rootfs: conteúdo SSH | `validate_rootfs` | `lib/rootfs.sh` | `tar --extract --to-stdout --zstd` | rootfs até o membro solicitado | stdout pequeno | B | efetivamente sim | efetivamente sim | confirma conteúdo exato do drop-in `ssh-keygen -A`; o membro é anexado no fim do tar |
| Rootfs: listagem final | `validate_rootfs` | `lib/rootfs.sh` | `tar --list --zstd` | rootfs comprimido | `/dev/null` | B | sim | sim | segunda confirmação de legibilidade integral do tar |
| Home: staging | `prepare_homefs_staging` | `lib/homefs.sh` | `find`, `readlink`, `realpath`, `rsync -aAX`, `install` | whitelist em `HOME_SOURCE` | staging Linux local | D | não | não | filtra conteúdo e preserva owner/ACL/xattr/symlink |
| Home: staging validado | `validate_homefs_staging` | `lib/homefs.sh` | `find`, `stat`, `du -sb`, `grep` | staging local | — | D/C | não | não | rejeita tipos/nomes/paths indevidos e limita tamanho |
| Home: criação | `generate_homefs` | `lib/homefs.sh` | `tar --create --use-compress-program="zstd -3"` | staging local | `homefs.tar.zst.partial` | D+E | n/a | n/a | cria contrato `usuario/` com metadados Unix |
| Home: integridade | `validate_archive_compression` | `lib/archive.sh` | `zstd --test --quiet` | homefs comprimido | — | B | sim | sim | valida zstd |
| Home: membros | `validate_homefs_archive` | `lib/homefs.sh` | `tar --list --zstd` | homefs comprimido | listagem em memória | B | sim | sim | valida estrutura tar, raiz, paths e whitelist |
| Home: semântica | `validate_homefs_archive` | `lib/homefs.sh` | shell + `grep` | listagem em memória | — | F | não | não | confirma raiz e diretórios obrigatórios |
| Home: listagem final | `validate_homefs_archive` | `lib/homefs.sh` | `tar --list --zstd` | homefs comprimido | `/dev/null` | B | sim | sim | segunda confirmação de legibilidade integral |
| SHA256SUMS: geração | `generate_checksums` | `lib/metadata.sh` | um `sha256sum` com os dois arquivos | rootfs e homefs | `SHA256SUMS.partial` | A | sim, ambos | não | cria hashes canônicos |
| SHA256SUMS: formato | `validate_checksums` | `lib/metadata.sh` | `wc`, `grep`, shell | arquivo de checksums | — | F | não | não | exige duas linhas e nomes canônicos, sem `.partial` |
| SHA256SUMS: verificação | `validate_checksums` | `lib/metadata.sh` | `sha256sum --check --strict` | rootfs e homefs | — | A | sim, ambos | não | confirma os bytes armazenados contra SHA256SUMS |
| Manifest: hashes | `generate_manifest` | `lib/metadata.sh` | dois `sha256sum`, `awk` | rootfs; depois homefs | — | A | sim, cada um | não | incorpora SHA-256 ao manifest |
| Manifest: escrita | `generate_manifest` | `lib/metadata.sh` | Python, `date`, `dpkg`/`uname`, `awk` em `os-release` | metadados pequenos | `manifest.json.partial` | C/F | não | não | gera schema 1 e tamanhos obtidos por `stat`/`getsize` |
| Manifest: validação | `validate_manifest` | `lib/metadata.sh` | Python `hashlib` | rootfs; depois homefs | — | A | sim, ambos | não | valida schema, nomes, tamanhos e hashes contra os bytes |
| Bundle: inventário | `validate_image_directory` | `lib/metadata.sh` | `find`, `sort`, `basename` | quatro entradas do staging | — | C/F | não | não | rejeita extras, links e ausências |
| Bundle: compressão | `validate_image_directory` | `lib/metadata.sh` | dois `zstd --test` | rootfs e homefs | — | B | sim, cada um | sim | revalida zstd no bundle completo |
| Bundle: tar | `validate_image_directory` | `lib/metadata.sh` | dois `tar --list --zstd` | rootfs e homefs | `/dev/null` | B | sim, cada um | sim | revalida tar no bundle completo |
| Bundle: checksums | `validate_image_directory` | `lib/metadata.sh` | `sha256sum --check --strict` | rootfs e homefs | — | A | sim, ambos | não | revalida SHA256SUMS |
| Bundle: manifest | `validate_image_directory` | `lib/metadata.sh` | Python `hashlib` | rootfs e homefs | — | A | sim, ambos | não | revalida schema, tamanho e hashes |
| Tamanhos finais | `format_file_size` | `lib/rootfs.sh` | `stat`, `awk` | inode/metadados | — | C/F | não | não | somente apresentação; não percorre archive |
| Durabilidade pré-commit | `finalize_build_workspace` | `lib/checks.sh` | `sync --file-system` | páginas sujas do filesystem | mídia | E | não é leitura | não | força durabilidade; pode descarregar muito mais que o manifest |
| Commit | `finalize_build_workspace` | `lib/checks.sh` | `mv -T --no-clobber` | metadados do staging | nome final | C/F | não | não | publicação atômica e imutável no mesmo filesystem |
| Durabilidade pós-commit | `finalize_build_workspace` | `lib/checks.sh` | `sync --file-system` | páginas sujas do filesystem | mídia | E | não é leitura | não | força persistência do rename |

Não existe chamada a `jq` no pipeline do build. `grep` opera sobre arquivos
pequenos ou listagens já capturadas em memória. `stat` e `findmnt` consultam
metadados; não leem os GiB do archive. `du` percorre somente as árvores da home
selecionada/staging, não os archives.

## Passagens completas no build direto

### rootfs.tar.zst

| # | Operação | Lê archive inteiro? | Descomprime? | Grupo do resumo atual | Propriedade verificada |
|---:|---|---|---|---|---|
| 1 | `zstd --test` em `validate_rootfs` | sim | sim | `rootfs_validação` | frames/checksum zstd |
| 2 | primeira `tar --list` em `validate_rootfs` | sim | sim | `rootfs_validação` | estrutura tar e lista de membros |
| 3 | extração do drop-in SSH | efetivamente sim | efetivamente sim | `rootfs_validação` | conteúdo exato do mecanismo de regeneração; o overlay está no fim |
| 4 | segunda `tar --list` em `validate_rootfs` | sim | sim | `rootfs_validação` | legibilidade integral repetida |
| 5 | geração de `SHA256SUMS` | sim | não | `metadata` | hash publicado |
| 6 | `sha256sum --check` | sim | não | `metadata` | hash armazenado confere |
| 7 | SHA-256 para gerar manifest | sim | não | `metadata` | hash embutido no manifest |
| 8 | Python `hashlib` ao validar manifest | sim | não | `metadata` | manifest confere com bytes armazenados |
| 9 | `zstd --test` no bundle | sim | sim | **não aparecia separado** | compressão final |
| 10 | `tar --list` no bundle | sim | sim | **não aparecia separado** | tar final |
| 11 | `sha256sum --check` no bundle | sim | não | **não aparecia separado** | SHA256SUMS final |
| 12 | Python `hashlib` no bundle | sim | não | **não aparecia separado** | manifest final |

Total: **12 passagens completas**, **6 com descompressão**. A passagem 3 é
classificada como efetivamente completa porque o drop-in vem da segunda árvore
passada ao tar e está no final do fluxo; chegar a esse membro exige atravessar o
rootfs anterior. O GNU tar ainda procura ocorrências aplicáveis no fluxo.

### homefs.tar.zst

| # | Operação | Lê archive inteiro? | Descomprime? | Grupo do resumo atual |
|---:|---|---|---|---|
| 1 | `zstd --test` em `validate_homefs_archive` | sim | sim | `homefs_validação` |
| 2 | primeira `tar --list` | sim | sim | `homefs_validação` |
| 3 | segunda `tar --list` | sim | sim | `homefs_validação` |
| 4 | geração de `SHA256SUMS` | sim | não | `metadata` |
| 5 | `sha256sum --check` | sim | não | `metadata` |
| 6 | SHA-256 para gerar manifest | sim | não | `metadata` |
| 7 | Python `hashlib` ao validar manifest | sim | não | `metadata` |
| 8 | `zstd --test` no bundle | sim | sim | não aparecia separado |
| 9 | `tar --list` no bundle | sim | sim | não aparecia separado |
| 10 | `sha256sum --check` no bundle | sim | não | não aparecia separado |
| 11 | Python `hashlib` no bundle | sim | não | não aparecia separado |

Total: **11 passagens completas**, **5 com descompressão**.

### Modos adicionais

- O build direto em filesystem local, NFS ou Ventoy executa as mesmas 12/11
  passagens; muda apenas o filesystem que atende as leituras.
- O modo `NFS e Ventoy` acrescenta no NFS uma validação completa (4 passagens)
  e a leitura do `rsync` (1), e no Ventoy mais uma validação completa
  (4 passagens). Contando as duas cópias físicas: rootfs = **21** leituras e
  **10** descompressões; homefs = **20** leituras e **9** descompressões.
- `publish-image.sh` e `sync-image-to-ventoy.sh` também validam antes/depois da
  cópia deliberadamente. Esses passes não participaram da captura direta real.

## O que compunha os tempos antigos

### `rootfs_geração=613s`

Somente o `tar --create` lendo `SOURCE_ROOT`, enviando o fluxo ao `zstd -3` e
gravando o `.partial` diretamente no exFAT. Preparação/validação do pequeno
overlay ocorre antes desse cronômetro.

### `rootfs_validação=1664s`

Incluía, sem divisão:

1. `zstd --test`;
2. primeira listagem tar completa;
3. verificações em memória de exclusões/paths/entradas obrigatórias;
4. nova travessia para extrair o drop-in SSH situado no fim;
5. comparação pequena do conteúdo do drop-in;
6. segunda listagem tar completa.

Assim, os 1664s incluem quatro descompressões práticas do rootfs.

### `homefs_geração` e `homefs_validação`

`homefs_geração` media somente tar+zstd. A preparação por `rsync` e a validação
do staging ficavam fora. `homefs_validação` incluía `zstd --test`, uma listagem
para validação semântica e outra listagem final: três descompressões.

### `metadata=1523s`

Media exatamente `build_metadata_artifacts`:

1. geração de SHA256SUMS — uma leitura de cada archive;
2. conferência de SHA256SUMS — outra leitura;
3. geração do manifest — novos SHA-256 de rootfs e homefs;
4. validação do manifest — Python recalcula ambos os hashes;
5. escritas/renames pequenos dos dois arquivos de metadados.

O manifest não usa o hash já escrito em SHA256SUMS; ele recalcula. Sua validação
também recalcula novamente. Portanto `metadata` contém quatro passagens do
rootfs e quatro do homefs.

### Tempo que não estava atribuído

Na amostra fornecida, a soma dos campos antigos é 3809s, mas o total é 5345s:
há aproximadamente **1536s não detalhados**. Nesse intervalo o código executa
principalmente:

1. `validate_image_directory` (mais quatro passagens por archive);
2. `sync --file-system` antes do rename;
3. rename atômico;
4. `sync --file-system` depois do rename;
5. checks pequenos de mount e apresentação.

Somente uma nova execução real instrumentada pode separar quanto desses 1536s
foi releitura e quanto foi flush do exFAT/USB.

## Instrumentação `[PERF]`

Os marcadores usam o logger existente. Cada operação tem `start` e `end`; o fim
registra `elapsed`, `status` e, quando há archive, tamanho, filesystem e vazão.
Falhas também produzem `end status!=0` antes de propagar o erro.

Exemplos do formato:

```text
[PERF] rootfs.create start source=/ archive=... size_bytes=unknown filesystem=unknown access=source_read+archive_write
[PERF] rootfs.create end elapsed=613.214s status=0 throughput_mib_s=8.68 throughput_basis=compressed_output archive=... size_bytes=5583457484 filesystem=exfat access=source_read+archive_write
[PERF] rootfs.integrity.zstd end elapsed=... status=0 throughput_mib_s=... throughput_basis=compressed_input archive=... size_bytes=5583457484 filesystem=exfat access=full_read+full_decompression
[PERF] metadata.sha256sums.generate end elapsed=... status=0 throughput_mib_s=... throughput_basis=compressed_input rootfs_archive=... access=two_full_reads
[PERF] metadata.manifest.hashes.reused end elapsed=... status=0 throughput_basis=none access=no_archive_read source=SHA256SUMS_generation
[PERF] bundle.validation.precommit end elapsed=... status=0 throughput_basis=none directory=...
[PERF] publication.sync.pre_rename end elapsed=... status=0 throughput_basis=none path=... filesystem=exfat access=filesystem_flush
```

Para operações de descompressão, `throughput_mib_s` é deliberadamente baseado
nos bytes comprimidos e aparece com `throughput_basis=compressed_input`; não é a
vazão do conteúdo lógico expandido. `stat` é usado para obter tamanho/tipo sem
uma leitura adicional. Nenhum `du` novo foi adicionado.

## Oportunidades levantadas no baseline

| Oportunidade | Passes teoricamente economizáveis | Garantia atual que deve ser preservada | Risco / condição para uma mudança segura |
|---|---:|---|---|
| Remover a segunda listagem em `validate_rootfs` | 1 descompressão | legibilidade tar até EOF | a primeira listagem já chegou ao EOF e seu status precisa ser preservado sem truncar/capturar incorretamente a saída |
| Remover a segunda listagem em `validate_homefs_archive` | 1 descompressão | legibilidade tar até EOF | mesma condição; provar por teste de truncamento/corrupção que a primeira passagem cobre EOF |
| Reutilizar uma única listagem para validações do archive e do bundle na mesma execução | até 1 descompressão por archive | objeto validado deve ser exatamente o mesmo objeto publicado | exige identidade forte/FD mantido ou hash do objeto e proteção contra substituição; path, tamanho e mtime não bastam |
| Compartilhar hashes entre SHA256SUMS e manifest | até 2 leituras por archive durante metadata | ambos os artefatos devem receber o SHA-256 dos bytes realmente armazenados | valores devem ser propagados sem parsing ambíguo e ainda verificados contra o arquivo persistido |
| Calcular SHA-256 durante a escrita | 1 leitura de geração | hash do fluxo produzido | não detecta corrupção posterior no armazenamento; ainda seria necessária ao menos uma releitura pós-gravação para manter a garantia atual |
| Alimentar várias validações por uma única descompressão/listagem | potencialmente 1–3 descompressões | zstd, estrutura tar, paths, exclusões, membros e conteúdo SSH são propriedades diferentes | pipeline único precisa propagar corretamente falhas de todos os consumidores, validar EOF e extrair o conteúdo exato sem deadlock/backpressure |
| Evitar `zstd -t` quando uma listagem tar comprovadamente chega ao EOF | 1 descompressão por ponto | `zstd -t` valida frames/checksums independentemente da semântica tar | provar que o descompressor usado pelo tar verifica checksum e trailing data com as mesmas garantias e que o status não é mascarado |
| Tornar o flush mais específico | não reduz leituras; pode reduzir espera | durabilidade do bundle e do rename antes de anunciar sucesso | `sync --file-system` usa `syncfs` no filesystem inteiro; substituir requer sequência de `fsync` de arquivos e diretórios com suporte/confiabilidade confirmados no exFAT |

`zstd -t` e `tar -t` não são automaticamente equivalentes: o primeiro valida o
contêiner comprimido; o segundo também interpreta a estrutura tar e seus
membros. Da mesma forma, hash durante escrita não substitui uma conferência dos
bytes depois de armazenados. As oportunidades acima só devem ser consideradas
numa tarefa futura com modelo de ameaça explícito e testes de corrupção,
substituição concorrente e falha de armazenamento.

## Risco existente observado, sem refatoração nesta tarefa

A publicação atômica impede que o nome final apareça antes do rename, mas o
staging oculto continua endereçável por path. Entre o fim da última validação e
o rename, não existe um descritor aberto/identidade de inode ou bloqueio que
prove que um processo concorrente não modificou um archive no staging. Os
checks de identidade de mount não cobrem mutação do arquivo dentro do mesmo
mount. Esse é um TOCTOU preexistente, não uma causa demonstrada da captura lenta
e não foi alterado aqui. Uma correção futura teria que manter a validação e o
commit vinculados ao mesmo objeto de forma forte, sem confiar apenas em path,
tamanho ou mtime.

## Optimization Phase 1

### Resultado

| Métrica do build direto | Antes | Depois |
|---|---:|---:|
| rootfs full reads | 12 | **7** |
| rootfs full decompressions | 6 | **5** |
| homefs full reads | 11 | **6** |
| homefs full decompressions | 5 | **4** |

Os números são derivados do pipeline conhecido e aparecem no resumo final como
`rootfs_full_reads`, `rootfs_full_decompressions`, `homefs_full_reads` e
`homefs_full_decompressions`, sem leitura adicional. No modo `NFS e Ventoy`, que
inclui validação NFS adicional, leitura pelo rsync e validação da cópia, os
totais são respectivamente `14/9` para rootfs e `13/8` para homefs.

### Pipeline atual

```text
rootfs: criar
  -> zstd --test
  -> tar --list até EOF + todas as verificações de membros/exclusões
  -> extrair e validar conteúdo do drop-in SSH

homefs: criar
  -> zstd --test
  -> tar --list até EOF + todas as verificações de raiz/path/whitelist

metadata
  -> sha256sum rootfs + homefs, depois de os archives estarem gravados
  -> escrever e validar SHA256SUMS com os digests mantidos em memória
  -> escrever e validar manifest com os mesmos digests

validação final independente do bundle
  -> zstd --test rootfs/homefs
  -> tar --list rootfs/homefs
  -> sha256sum --check rootfs/homefs (nova leitura dos bytes armazenados)
  -> validar manifest contra os digests que acabaram de ser verificados
  -> syncfs -> rename atômico -> syncfs
```

### Passagens removidas e garantias preservadas

| Operação antiga removida | Economia por archive | Por que era redundante | Operação que preserva a garantia | Propriedade preservada |
|---|---:|---|---|---|
| segunda `tar --list` em `validate_rootfs` | 1 leitura + descompressão | repetia exatamente a listagem anterior | primeira `tar --list`, cujo status só é aceito após chegar a EOF | estrutura tar legível integralmente e lista completa de membros |
| segunda `tar --list` em `validate_homefs_archive` | 1 leitura + descompressão | repetia o mesmo archive e conjunto de membros | primeira listagem até EOF, reutilizada por paths, raiz e whitelist | estrutura tar, nomes perigosos, raiz e whitelist |
| `sha256sum --check` imediatamente após gerar SHA256SUMS | 1 leitura | nenhum archive é legitimamente modificado entre geração e conferência | comparação das linhas canônicas com os digests pós-escrita mantidos em memória; validação final ainda relê os archives | conteúdo e ordem canônica de SHA256SUMS; verificação independente continua antes do commit |
| novos `sha256sum` durante geração do manifest | 1 leitura | digest era do mesmo objeto sem mutação intermediária | digest pós-escrita produzido para SHA256SUMS | manifest recebe exatamente o mesmo SHA-256 correto |
| Python `hashlib` durante primeira validação do manifest | 1 leitura | repetia o digest recém-calculado sem mutação intermediária | validação de schema/nome/tamanho e comparação com digest pós-escrita em memória | schema 1, filenames, sizes e hashes do manifest |
| Python `hashlib` na validação final, logo após `sha256sum --check` | 1 leitura | SHA256SUMS já tinha acabado de verificar os bytes armazenados | digest canônico lido de SHA256SUMS somente depois de `sha256sum --check --strict` ter sucesso | manifest e SHA256SUMS concordam com o mesmo artefato efetivamente relido |

O primeiro digest não é calculado durante tar/zstd: ele ainda exige uma leitura
do arquivo depois da escrita. A validação final executa outra leitura SHA-256
independente. Assim, corrupção ocorrida depois do primeiro cálculo continua
sendo detectada antes do commit.

### Operações caras mantidas deliberadamente

- `zstd --test` durante a validação inicial e durante a validação final: valida
  frames/checksums zstd independentemente da semântica tar.
- `tar --list` inicial e final: a primeira alimenta invariantes semânticas; a
  segunda valida o bundle imediatamente antes da publicação.
- extração do drop-in SSH: permanece uma passagem efetivamente completa porque
  confirma o conteúdo realmente armazenado do mecanismo `ssh-keygen -A`.
- um SHA-256 pós-escrita e outro na validação final: mantêm detecção independente
  de corrupção/modificação ocorrida entre metadata e commit.
- `sync --file-system` antes/depois do rename: política de durabilidade intacta.
- validações adicionais e rsync no modo NFS + Ventoy: garantias de cada cópia
  física permanecem independentes.

### Impacto esperado e limites

Para o rootfs real de 5,20 GiB, o novo pipeline deixa de solicitar cinco
passagens completas, uma delas com descompressão. Isso reduz I/O redundante em
arquitetura, mas não autoriza estimar minutos ou percentual: o ganho real
depende de cache, controlador USB, exFAT e custo de `syncfs`, e só poderá ser
medido numa nova captura real instrumentada.

Continuam fora desta fase: fusão da extração SSH com outra passagem, alteração
de `zstd --test`, troca de syncfs por fsync e solução do TOCTOU entre validação e
rename.
