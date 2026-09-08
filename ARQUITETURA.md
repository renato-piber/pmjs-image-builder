# Formato, staging e publicação

## Decisões do formato

O formato PMJS schema 1 usa obrigatoriamente `rootfs.tar.zst` e
`homefs.tar.zst`. Rootfs e homefs compartilham o algoritmo Zstandard e o nível
configurado (`ZSTD_LEVEL=3` por padrão). ACLs, xattrs e owners numéricos são
propriedades do tar e permanecem preservados. O suporte gzip dos helpers não faz
parte do formato publicado e é mantido somente para chamadas internas antigas.

`SHA256SUMS` tem exatamente duas linhas, em ordem determinística, sem paths e
sem nomes temporários. O `manifest.json` mantém o schema 1 já introduzido pelo
builder e seus campos existentes; a validação agora confere o conjunto de
campos, tipos, nomes, tamanhos e hashes, sem depender de `assert` do Python.

O diretório da imagem contém somente os quatro arquivos do contrato. A validação
completa testa os dois fluxos Zstandard, lista os dois tars, verifica
`SHA256SUMS`, cruza o manifest com os bytes e exige que o nome do diretório seja
`<image_name>-<image_version>` (ou o padrão oculto de staging controlado).

## Pipeline

```text
origem montada/auto-detectada
          |
          +--> staging local pequeno
          |    - overlay de generalização
          |    - home filtrada (limitada por HOMEFS_MAX_SIZE_MIB)
          |
          v
DESTINO/.pmjs-linux-<versão>.build.*      (OUTPUT_DIR local ou NFS)
          |  SOURCE_ROOT -> tar -> zstd -> rootfs.tar.zst.partial
          |  home staging -> tar -> zstd -> homefs.tar.zst.partial
          |  renomeia cada archive dentro do staging
          |  gera metadados
          |  valida archives + SHA256SUMS + manifest + diretório
          v
DESTINO/pmjs-linux-<versão>               (rename no mesmo filesystem)
          |
          | publish-image.sh opcional para destinos adicionais/Ventoy
          v
destino/.pmjs-linux-<versão>.partial.*    (cópia no filesystem do destino)
          |  repete toda a validação e sincroniza
          v
destino/pmjs-linux-<versão>               (rename atômico por destino)
```

O build nunca escreve diretamente no Ventoy/exFAT. Para NFS, os archives podem
ser produzidos diretamente no staging oculto porque tar é um formato de fluxo:
UID/GID, modos, ACLs, xattrs e symlinks são serializados pelo GNU tar a partir da
origem, independentemente do filesystem que armazena o arquivo `.tar.zst`. O NFS
armazena somente o fluxo comprimido e os metadados do contrato.

O nome final permanece ausente durante toda a geração. A validação relê os bytes
no NFS e o commit usa rename no mesmo filesystem. Se o processo cair, pode restar
no máximo um diretório oculto `.build.*`; consumidores que procuram
`pmjs-linux-*` não o tratam como imagem. `OUTPUT_DIR` inteiro é excluído do
rootfs, inclusive builds anteriores.

O staging da home continua local porque a whitelist é materializada com
`rsync -aAX --numeric-ids` antes de gerar o archive. O overlay de generalização
também continua local, mas contém apenas o drop-in de regeneração das host keys.
Logs e diretórios temporários de detecção/mount permanecem locais e pequenos.

## Política de publicação

- a imagem de origem deve estar completa antes de iniciar;
- não existem destinos default nem descoberta automática de mídia/servidor;
- Ventoy recebe um path explícito terminado em `pmjs-images/` e já montado;
- NFS recebe um path explícito em filesystem `nfs` ou `nfs4` já montado;
- todos os destinos são preparados e validados antes do primeiro rename;
- uma versão existente é imutável e causa falha, inclusive em condição de corrida;
- a atomicidade vale individualmente em cada filesystem; não há atomicidade
  distribuída entre Ventoy e NFS.

O manifest não contém machine-id, UUIDs, serial de disco, DEVICEID do OCS,
fingerprints SSH ou dados do perfil do usuário. Ele contém apenas informações
do contrato e auditoria não sensível.

## Auditoria da implementação anterior

Antes desta alteração, cada archive era renomeado dentro do `OUTPUT_DIR` logo
após sua validação individual. Como o diretório final já estava visível, uma
falha posterior podia deixar um conjunto sem metadados ou misturado com arquivos
de execução anterior. Além disso, `OUTPUT_DIR` podia apontar diretamente para
Ventoy/NFS e não havia uma operação de publicação nem revalidação da cópia.

A implementação atual elimina esses estados intermediários por staging de
diretório, validação do conjunto e publicação imutável. O modo NFS reutiliza a
mesma transação, sem cópia local dos archives. Nenhum arquivo do PMJS Deploy ou
do PMJS Live Builder foi alterado.
