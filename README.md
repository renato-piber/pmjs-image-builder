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

`VERSION` identifica a versão do software PMJS Image Builder e é gravado em
`builder_version` no manifest. `IMAGE_VERSION`, carregado exclusivamente de
`config/image.conf`, identifica a imagem produzida e determina o nome
`pmjs-linux-<versão>/`. Os dois valores são independentes e não precisam ser
iguais.
No início do build, o log registra os dois valores e os respectivos arquivos de
origem. Assim, o nome `.pmjs-linux-0.1.0.build.*` indica necessariamente que a
cópia executada carregou `IMAGE_VERSION=0.1.0` do seu próprio
`config/image.conf`; a opção `--nfs-dir` não altera a versão.

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
O drop-in é criado em um overlay Linux local, validado antes do tar e inserido
como membro explícito e único. Uma cópia de mesmo nome eventualmente existente
na máquina-modelo é excluída, portanto não pode preceder nem substituir o
mecanismo gerado pelo Builder.

Os pseudo-filesystems `/proc`, `/sys`, `/dev` e `/run` não fazem parte do
archive. Esses diretórios são recriados ou montados pelo sistema durante a
inicialização e não precisam ser armazenados na imagem.

O `homefs.tar.zst` possui como raiz o nome do usuário (`usuario/`), pois o PMJS
Deploy o extrai diretamente em `/home`. Somente configurações explicitamente
permitidas são copiadas; caches, navegadores, lixeira, históricos e arquivos
pessoais ficam fora da imagem. Os diretórios XDG padrão são incluídos vazios.
Como exceção explícita, arquivos regulares `*.desktop` diretamente no Desktop
detectado são preservados; nenhum outro conteúdo desse diretório é copiado.
O staging filtrado do homefs permanece em filesystem Linux local, separado do
destino dos archives, para preservar ownership, ACLs e xattrs. O local é
configurado por `LOCAL_TEMP_DIR` e seu tamanho máximo continua limitado por
`HOMEFS_MAX_SIZE_MIB`.

## Build local ou direto no NFS

Sem argumentos, `OUTPUT_DIR` continua sendo o staging Linux local. O build ocorre
primeiro em um diretório oculto `.pmjs-linux-<versão>.build.*`; depois de validar
os archives, SHA256, manifest e o conjunto completo, esse diretório é renomeado
para `pmjs-linux-<versão>/`. Uma versão existente nunca é substituída.

```bash
sudo ./build-image.sh
```

Na PMJS Live, o destino NFS pode ser informado explicitamente. O diretório deve
existir dentro de um NFS já montado:

```bash
sudo mkdir -p /mnt/pmjs-images
sudo mount -t nfs 192.168.0.19:/var/clone-pmjs /mnt/pmjs-images
sudo ./build-image.sh --nfs-dir /mnt/pmjs-images
```

Também é possível definir `NFS_IMAGES_DIR` em `config/image.conf`. Não há servidor
ou mountpoint implícito no código.

Nesse modo, GNU tar lê `SOURCE_ROOT` ou o staging filtrado da home e envia o fluxo
comprimido pelo Zstandard diretamente para arquivos `.partial` no workspace NFS.
Os archives completos não passam por `/var/tmp`. A validação é feita sobre os
bytes gravados no NFS e o diretório final só aparece após um rename no mesmo
filesystem.

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
- `OUTPUT_DIR` em filesystem Linux local, ou `--nfs-dir`/`NFS_IMAGES_DIR` em NFS
  montado;
- ao menos `MIN_FREE_SPACE_GIB` livres no destino dos archives;
- em `LOCAL_TEMP_DIR`, apenas a estimativa do conteúdo selecionado da home mais
  `LOCAL_TEMP_RESERVE_MIB`; `HOMEFS_MAX_SIZE_MIB` continua sendo o teto.

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
manifest e SHA256SUMS, rejeição de corrupção, staging local, build NFS simulado,
falhas por fase, preservação de metadados, equivalência semântica do rootfs
generalizado nos caminhos local e NFS e publicação atômica/imutável.

## Integração com o Deploy

O PMJS Deploy deste workspace reconhece o formato Zstandard/schema 1 e mantém o
fallback gzip legado. O diretório final publicado pelo Builder segue a identidade
`<image_name>-<image_version>` esperada no discovery.

> A captura ocorre sobre um sistema ativo. Para consistência forte, execute em
> um snapshot ou ambiente sem escritas concorrentes.
