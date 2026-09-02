# PMJS Image Builder

Gerador de imagens de sistema consumidas pelo PMJS Deploy.

## Contrato da imagem

O builder gera archives em gzip ou Zstandard e publica metadados de integridade:

```text
output/pmjs-linux-<versão>/
├── rootfs.tar.zst       # ou rootfs.tar.gz
├── homefs.tar.zst       # ou homefs.tar.gz
├── SHA256SUMS
└── manifest.json
```

`SHA256SUMS` cobre somente os dois archives finais e é verificado pelo próprio
builder. `manifest.json` usa schema 1 e registra nomes, tamanhos, SHA-256,
compressão, versão, arquitetura, distribuição e kernel do builder, sem identidades da
máquina-modelo. Cada arquivo é criado como `.partial`, validado e publicado por
rename. Metadados antigos são retirados antes de substituir os archives, de modo
que uma falha nunca apresente uma combinação nova como imagem válida.

Zstandard nível 3 é o padrão por priorizar instalação e descompressão rápidas.
Gzip permanece disponível para compatibilidade. A escolha vale igualmente para
rootfs e homefs e é feita em `config/image.conf`:

```text
IMAGE_COMPRESSION="zstd"   # gera .tar.zst
ZSTD_LEVEL=3
ROOTFS_FILENAME="auto"
HOMEFS_FILENAME="auto"
```

Para gerar gzip, use `IMAGE_COMPRESSION="gzip"`; os nomes serão resolvidos
automaticamente para `.tar.gz`.

Antes de concluir o rootfs, o builder remove identidades da máquina-modelo sem
alterar a origem: `/etc/machine-id`, host keys SSH e o estado, cache e logs do
OCS Inventory não entram no archive. A configuração do OCS, `sshd_config` e a
senha institucional do x11vnc são preservadas. No sistema instalado, systemd
gera um novo `machine-id`, o agente OCS recria seu estado e um drop-in de
`ssh.service` executa `ssh-keygen -A` antes de validar e iniciar o servidor SSH.

Os pseudo-filesystems `/proc`, `/sys`, `/dev` e `/run` não fazem parte do
archive. Esses diretórios são recriados ou montados pelo sistema durante a
inicialização e não precisam ser armazenados na imagem.

O `homefs.tar.gz` possui como raiz o nome do usuário (`usuario/`), pois o PMJS
Deploy o extrai diretamente em `/home`. Somente configurações explicitamente
permitidas são copiadas; caches, navegadores, lixeira, históricos e arquivos
pessoais ficam fora da imagem. Os diretórios XDG padrão são incluídos vazios.
Como exceção explícita, arquivos regulares `*.desktop` diretamente no Desktop
detectado são preservados; nenhum outro conteúdo desse diretório é copiado.
O staging do homefs é criado em `/var/tmp` (com fallback para `/tmp`), separado
do `OUTPUT_DIR`, para preservar ownership, ACLs e xattrs mesmo quando os
artefatos finais são gravados em Ventoy, exFAT ou outro filesystem não POSIX.

## Requisitos

- Linux e Bash 4.3 ou superior
- execução como `root`
- GNU tar com suporte a ACLs e atributos estendidos
- gzip; para `IMAGE_COMPRESSION="zstd"`, também `zstd`
- rsync com suporte a ACLs e atributos estendidos
- Python 3 (serialização e validação robusta do manifest JSON)
- sha256sum
- diretório de saída montado em filesystem diferente de `/`
- ao menos `MIN_FREE_SPACE_GIB` livres no destino

Edite `config/image.conf` conforme necessário. `OUTPUT_DIR` e `LOG_DIR`
relativos são resolvidos a partir da raiz do projeto; `SOURCE_ROOT` deve ser
`auto` ou um caminho absoluto.

```bash
sudo ./build-image.sh
```

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

Ao final, o comando informa algoritmo, arquivos, tamanhos, tempos de preparação,
geração/validação e metadata, duração total e log. Um build
interrompido remove os arquivos `.partial`. Metadados de uma execução anterior
são invalidados antes da substituição dos archives.

> A captura ocorre sobre um sistema ativo. Para consistência forte, execute em
> um snapshot ou ambiente sem escritas concorrentes.
