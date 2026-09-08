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
          v
OUTPUT_DIR/.pmjs-linux-<versão>.build.*   (filesystem Linux local)
          |  gera rootfs + homefs + metadados
          |  valida archives + SHA256SUMS + manifest + diretório
          v
OUTPUT_DIR/pmjs-linux-<versão>            (rename local)
          |
          | publish-image.sh com paths explícitos
          v
destino/.pmjs-linux-<versão>.partial.*    (cópia no filesystem do destino)
          |  repete toda a validação e sincroniza
          v
destino/pmjs-linux-<versão>               (rename atômico por destino)
```

O build nunca escreve archives diretamente no Ventoy ou no NFS. Isso evita
perder semântica POSIX durante a criação e impede que consumidores observem uma
imagem incompleta. `OUTPUT_DIR` inteiro é excluído do rootfs, inclusive builds
locais anteriores.

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
diretório, validação do conjunto e publicação imutável. O PMJS Deploy deste
workspace continua limitado a gzip e precisa ser migrado separadamente; nenhum
arquivo dele ou do PMJS Live Builder foi alterado.
