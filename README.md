# PMJS Image Builder

Gerador e publicador de imagens de sistema PMJS.

## Formato PMJS

Uma imagem PMJS schema 1 é um diretório imutável com exatamente estes arquivos:

```text
pmjs-linux-<versão>/
├── rootfs.tar.zst
├── homefs.tar.zst
├── SHA256SUMS
└── manifest.json
```

Os dois archives são tar comprimidos com Zstandard. `SHA256SUMS` contém, nesta
ordem, somente as entradas canônicas de `rootfs.tar.zst` e `homefs.tar.zst`.
`manifest.json` registra schema, nome e versão da imagem, instante UTC, versão do
builder, compressão, arquitetura, distribuição, kernel do builder e, para cada
archive, nome, tamanho e SHA-256. Ele não contém identidades da máquina-modelo.

Zstandard nível 3 é o padrão por priorizar instalação e descompressão rápidas:

```text
IMAGE_COMPRESSION="zstd"   # gera .tar.zst
ZSTD_LEVEL=3
ROOTFS_FILENAME="auto"
HOMEFS_FILENAME="auto"
```

O formato publicado exige `IMAGE_COMPRESSION="zstd"`. Os helpers de archive
continuam aceitando gzip apenas para compatibilidade interna e testes legados;
gzip não é aceito por `validate_image_directory` nem por `publish-image.sh`.

Antes de concluir o rootfs, o builder remove identidades da máquina-modelo sem
alterar a origem: `/etc/machine-id`, host keys SSH e o estado, cache e logs do
OCS Inventory não entram no archive. A configuração do OCS, `sshd_config` e a
senha institucional do x11vnc são preservadas. No sistema instalado, systemd
gera um novo `machine-id`, o agente OCS recria seu estado e um drop-in de
`ssh.service` executa `ssh-keygen -A` antes de validar e iniciar o servidor SSH.

Os pseudo-filesystems `/proc`, `/sys`, `/dev` e `/run` não fazem parte do
archive. Esses diretórios são recriados ou montados pelo sistema durante a
inicialização e não precisam ser armazenados na imagem.

O `homefs.tar.zst` possui como raiz o nome do usuário (`usuario/`), pois o PMJS
Deploy o extrai diretamente em `/home`. Somente configurações explicitamente
permitidas são copiadas; caches, navegadores, lixeira, históricos e arquivos
pessoais ficam fora da imagem. Os diretórios XDG padrão são incluídos vazios.
Como exceção explícita, arquivos regulares `*.desktop` diretamente no Desktop
detectado são preservados; nenhum outro conteúdo desse diretório é copiado.
O staging do homefs é criado em `/var/tmp` (com fallback para `/tmp`), separado
do `OUTPUT_DIR`, para preservar ownership, ACLs e xattrs.

## Build local e publicação

`OUTPUT_DIR` é exclusivamente o staging Linux local. O build ocorre primeiro em
um diretório oculto `.pmjs-linux-<versão>.build.*`; depois de validar os archives,
o SHA256, o manifest e o conjunto completo, esse diretório é renomeado para
`pmjs-linux-<versão>/`. Uma versão existente nunca é substituída.

```bash
sudo ./build-image.sh
```

A publicação é uma operação posterior e explícita. Informe sempre a imagem já
concluída e um ou ambos os destinos:

```bash
# Diretório offline existente na partição de dados montada do Ventoy
./publish-image.sh \
  --image-dir ./output/pmjs-linux-0.1.0 \
  --ventoy-dir /media/operador/Ventoy/pmjs-images

# Diretório existente dentro de um export NFS já montado
./publish-image.sh \
  --image-dir ./output/pmjs-linux-0.1.0 \
  --nfs-dir /mnt/pmjs-images

# Preparar e publicar nos dois destinos
./publish-image.sh \
  --image-dir ./output/pmjs-linux-0.1.0 \
  --ventoy-dir /media/operador/Ventoy/pmjs-images \
  --nfs-dir /mnt/pmjs-images
```

O publisher não possui paths padrão, não monta NFS e não tenta localizar o
Ventoy. O diretório Ventoy deve já existir, chamar-se exatamente `pmjs-images`
e estar fora do filesystem raiz. O destino NFS deve já existir em um filesystem
`nfs`/`nfs4`. Em cada destino, a cópia é feita em um diretório oculto no mesmo
filesystem, validada integralmente, sincronizada e exposta por um único rename.
A atomicidade é por destino; não existe transação atômica entre Ventoy e NFS.

## Requisitos

- Linux e Bash 4.3 ou superior
- execução do `build-image.sh` como `root`; o publisher requer apenas acesso de escrita
- GNU tar com suporte a ACLs e atributos estendidos
- gzip (compatibilidade interna) e zstd
- rsync com suporte a ACLs e atributos estendidos
- Python 3 (serialização e validação robusta do manifest JSON)
- sha256sum
- `OUTPUT_DIR` em filesystem Linux local (não NFS, SMB, FUSE, FAT/exFAT ou NTFS)
- ao menos `MIN_FREE_SPACE_GIB` livres no staging local

Edite `config/image.conf` conforme necessário. `OUTPUT_DIR` e `LOG_DIR`
relativos são resolvidos a partir da raiz do projeto; `SOURCE_ROOT` deve ser
`auto` ou um caminho absoluto.

### Captura Live/offline

No modo automático, configure:

```text
SOURCE_ROOT="auto"
HOME_SOURCE="auto"
```

O builder enumera dispositivos com `lsblk`/`blkid`, ignora mídia removível,
transporte USB e filesystems já montados, e monta cada candidato somente para
leitura. Ele reconhece BTRFS com `@rootfs` e raízes tradicionais em ext2/3/4 ou
XFS. Deve existir exatamente uma instalação válida; zero ou múltiplas opções
causam falha segura.

A home pode estar no mesmo BTRFS do root:

```text
partição BTRFS
├── @rootfs/
└── home/usuario/
```

ou em outra partição BTRFS:

```text
partição root                 partição home
└── @rootfs/                  └── home/usuario/
```

Após localizar o root, o builder procura `home/$HOME_USER` separadamente. Para
uma partição de home distinta, monta diretamente o subvolume `home` (ou
`@home`) e usa `<mount-home>/$HOME_USER` como `HOME_SOURCE`.

Os mounts temporários são criados em `/var/tmp` (fallback `/tmp`) e desmontados
em sucesso, erro, `SIGINT` ou `SIGTERM`. Como somente mounts criados pelo
builder são registrados, partições já montadas pelo usuário nunca são
desmontadas.

No modo manual, `SOURCE_ROOT` aceita tanto uma raiz Linux montada diretamente quanto o ponto de
montagem superior de um filesystem BTRFS. Se o caminho configurado não contiver
diretamente `etc/`, `usr/` e `var/`, o builder procura exatamente o subvolume
`@rootfs` logo abaixo dele e usa esse diretório como raiz efetiva.

Exemplo com a partição BTRFS montada sem selecionar subvolume:

```text
SOURCE_ROOT="/mnt/root"          # resolve para /mnt/root/@rootfs
HOME_SOURCE="/mnt/root/home/usuario"
```

Também é permitido apontar diretamente para o subvolume:

```text
SOURCE_ROOT="/mnt/root/@rootfs"
HOME_SOURCE="/mnt/root/home/usuario"
```

`HOME_SOURCE` é independente de `SOURCE_ROOT`: no modo manual, deve apontar para
a home real montada e acessível.

Ao final, o comando informa arquivos, tamanhos, tempos de preparação,
geração/validação e metadata, duração total e log. Um build interrompido remove
o staging oculto; uma imagem anterior com a mesma versão não é tocada.

## Testes

Os testes não capturam o sistema real e usam árvores temporárias sintéticas:

```bash
./tests/run.sh
```

Eles cobrem gzip interno, formato Zstandard publicado, integridade cruzada do
manifest e SHA256SUMS, rejeição de corrupção, staging local e publicação
atômica/imutável.

## Limite atual de integração

O PMJS Deploy presente neste workspace ainda procura e extrai exclusivamente
`rootfs.tar.gz` e `homefs.tar.gz`. Por restrição deste trabalho ele não foi
alterado; portanto, embora as imagens possam ser publicadas nos diretórios que
ele enumera, esse Deploy ainda não consome o novo formato Zstandard/schema 1.
Essa migração deve ocorrer no próprio projeto Deploy antes do uso em produção.

> A captura ocorre sobre um sistema ativo. Para consistência forte, execute em
> um snapshot ou ambiente sem escritas concorrentes.
