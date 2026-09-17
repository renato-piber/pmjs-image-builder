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
`builder_version` no manifest. `IMAGE_VERSION` identifica a imagem produzida e
determina o nome `<IMAGE_NAME>-<IMAGE_VERSION>/`. Seu padrão vem de
`config/image.conf`; os dois valores são independentes e não precisam ser iguais.
No início do build, o log registra as versões e a origem efetiva da escolha
(configuração ou pergunta interativa). A opção `--nfs-dir` não altera a versão.

## Escolher o nome da nova imagem

Ao executar `build-image.sh` em terminal interativo, antes de qualquer mount,
staging ou captura, aparece a pergunta (com os padrões atuais):

```text
[INFO] Nome da nova imagem: pmjs-linux-<versão/sufixo>
Versão/sufixo ou nome completo [pmjs-linux-0.2.0]:
```

Digite `0.3.0` ou `pmjs-linux-0.3.0` para gerar `pmjs-linux-0.3.0/`. Também são
aceitos sufixos como `0.3.0-lab`. Enter mantém o padrão. O prefixo é sempre
`IMAGE_NAME` de `config/image.conf`, inclusive quando for diferente de
`pmjs-linux`. Espaços, separadores de paths e sufixos iniciados por ponto ou hífen
são rejeitados; a pergunta é repetida. EOF (Ctrl+D) cancela antes de iniciar o
build. Ctrl+C interrompe usando o cleanup existente.

A escolha altera apenas a execução atual: não grava `config/image.conf` nem
`VERSION`. O staging, a pasta final e o manifest recebem a mesma versão
selecionada. Se a pasta final já existir, o build aborta, sem sobrescrever.
Não é possível renomear uma captura em andamento por essa pergunta.

Sem stdin ligado a um terminal, a pergunta é omitida e o script usa a
configuração, sem consumir dados de pipes/redirecionamentos. O comportamento é
igual nos destinos local, NFS e Ventoy; nenhuma captura ou publicação é
realizada apenas por responder à pergunta.

## Compressão e generalização

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

## Build local, direto no NFS ou direto no Ventoy

Na configuração distribuída, o build monta automaticamente o servidor oficial:

```bash
NFS_ENABLED=1
NFS_SERVER="192.168.0.19"
NFS_EXPORT="/var/clone-pmjs"
NFS_MOUNTPOINT="/mnt/clone-pmjs"
```

Esses valores são definidos em `config/image.conf`. O build ocorre primeiro em
um diretório oculto `.pmjs-linux-<versão>.build.*` no destino; depois de validar
os archives, SHA256, manifest e o conjunto completo, esse diretório é renomeado
para `pmjs-linux-<versão>/`. Uma versão existente nunca é substituída.

```bash
sudo ./build-image.sh
```

O Builder cria o mountpoint se necessário e consulta o mount exato com
`findmnt`. Se existir, deve ser `nfs`/`nfs4` e ter a origem configurada (comparação
exata de `NFS_SERVER:NFS_EXPORT`). Caso contrário, o build é abortado. Se não
existir, executa `mount -t nfs` e exige nova confirmação por `findmnt` antes de
selecionar o destino. Uma falha jamais permite continuar no diretório local que
ficou sob o mountpoint. Não é necessário fazer ping ou montar manualmente.

Também é possível informar um destino NFS já montado explicitamente:

```bash
sudo mkdir -p /mnt/pmjs-images
sudo mount -t nfs 192.168.0.19:/var/clone-pmjs /mnt/pmjs-images
sudo ./build-image.sh --nfs-dir /mnt/pmjs-images
```

A seleção do destino é:

1. `--ventoy-dir CAMINHO`: usa diretamente um `pmjs-images` em mídia já
   montada, não acessa o NFS configurado e não monta nem desmonta o Ventoy.
   Com `--ventoy-dir auto`, descobre/monta a mídia offline configurada, sem NFS.
2. `--nfs-dir CAMINHO`: usa o NFS já montado, sem automount e sem desmontagem;
   mantém a validação existente e permite outro export ou subdiretório.
3. Sem opção explícita, `NFS_ENABLED=1`: monta/reutiliza o servidor, export e mountpoint
   de `config/image.conf`. Nesse modo, `NFS_IMAGES_DIR` não é usado.
4. `NFS_ENABLED=0` ou ausente: usa `NFS_IMAGES_DIR` legado, se preenchido, ou
   `OUTPUT_DIR` local. Configurações antigas sem os novos campos continuam válidas.

`--ventoy-dir` e `--nfs-dir` são mutuamente exclusivos.

Para build local, configure `NFS_ENABLED=0` e `NFS_IMAGES_DIR=""`.
O mountpoint automático deve ser absoluto, canônico, específico, sem symlinks,
espaços ou `..`; paths amplos como `/`, `/mnt`, `/var`, `/tmp` e diretórios de
sistema são rejeitados.

O Builder registra se realizou o mount (`NFS_MOUNTED_BY_BUILDER`) e sua identidade
(origem, tipo, alvo e ID). Em sucesso, erro, `SIGINT` ou `SIGTERM`, o cleanup
remove somente seu workspace validado e então desmonta apenas o mount criado
por ele. Um mount pré-existente nunca é desmontado. Se a identidade mudar ou
não puder ser confirmada, o staging e o mount são deixados intactos com aviso.
Falhas de `umount` geram aviso sem substituir o código de saída original. Não
há desmontagem forçada ou lazy; o diretório do mountpoint não é removido.
`SIGKILL` e desligamento abrupto não permitem executar cleanup; o mount pode
permanecer e será tratado como pré-existente na próxima execução.

Nesse modo, GNU tar lê `SOURCE_ROOT` ou o staging filtrado da home e envia o fluxo
comprimido pelo Zstandard diretamente para arquivos `.partial` no workspace NFS.
Os archives completos não passam por `/var/tmp`. A validação é feita sobre os
bytes gravados no NFS e o diretório final só aparece após um rename no mesmo
filesystem.

### Build direto no Ventoy sem NFS

Quando o servidor não estiver disponível, use a exceção explícita com descoberta:

```bash
sudo ./build-image.sh --ventoy-dir auto
```

Ou mantenha o caminho manual: monte primeiro a partição de dados do Ventoy e
crie o diretório `pmjs-images` nela. Depois use:

```bash
sudo mkdir -p /media/usuario/Ventoy/pmjs-images
sudo ./build-image.sh \
  --ventoy-dir /media/usuario/Ventoy/pmjs-images
```

O diretório deve existir, ser real, gravável, chamar-se exatamente
`pmjs-images` e estar em um filesystem montado diferente de `/`. O Builder usa
`findmnt` para registrar ID, origem, tipo e alvo desse mount. exFAT é aceito,
mas `OUTPUT_DIR` apontado manualmente para exFAT continua rejeitado: o acesso ao
Ventoy só é liberado pela opção explícita e validada.

O rootfs é lido de `SOURCE_ROOT` e comprimido diretamente para
`.pmjs-linux-<versão>.build.*` no Ventoy. O homefs é comprimido da mesma forma
após materializar sua whitelist em `LOCAL_TEMP_DIR`. O overlay de generalização
também permanece em `LOCAL_TEMP_DIR`; portanto ownership, modos, ACLs e xattrs
necessários à preparação nunca dependem do exFAT. Os metadados Unix finais são
armazenados dentro dos tars.

Após cada archive e antes do commit, a identidade do Ventoy é conferida
novamente. O bundle é relido do próprio Ventoy e validado integralmente; somente
então o workspace oculto é sincronizado e renomeado para
`pmjs-linux-<versão>/`. Uma versão existente nunca é substituída. Em erro ou
interrupção, o cleanup remove somente o `.build.*` validado e apenas se a mídia
continuar sendo o mesmo mount. Se a identidade mudar, preserva o path e avisa,
evitando apagar conteúdo no filesystem que tenha ocupado o mountpoint.

## Copiar uma imagem do NFS para o Ventoy

### Descoberta e automount do Ventoy

`config/image.conf` declara explicitamente os padrões alinhados ao Deploy:

```bash
VENTOY_AUTOMOUNT_ENABLED=1
VENTOY_MOUNTPOINT="/mnt/pmjs-offline"
VENTOY_VOLUME_LABEL="Ventoy"
VENTOY_ALLOWED_FSTYPES="exfat"
```

O mountpoint não é um dispositivo: a partição é descoberta por LABEL, filesystem
permitido e transporte USB (incluindo o transporte do disco pai). Só uma
partição pode se qualificar; nenhuma ou várias abortam sem montar/gravar.
Não há `/dev/sdX` fixo. O subdiretório de bundles é sempre `pmjs-images`, na
raiz do volume, exatamente onde o Deploy procura. Mudar label/filesystem no
Builder requer manter a configuração do consumidor compatível; o Deploy não é
alterado pelo Builder.

Se houver um único mount correto gravável, reutiliza-o, inclusive em
`/media/usuario/Ventoy`, e nunca o desmonta. Um mount somente leitura (como o
criado pelo Deploy) é rejeitado, sem remount e sem uma segunda montagem. Encerre
o Deploy/uso desse mount antes de tentar novamente. Uma mídia exFAT vazia é
aceita; não precisa conter uma versão anterior para ser identificada.

Se não estiver montado, prefere o mapper `/dev/mapper/<nome da partição>`, como
no Deploy. Na Live iniciada pelo Ventoy (`/run/live/medium` vindo de
`/dev/mapper/ventoy`), um mapper ausente aciona `udevadm trigger`/`settle` uma
única vez; se continuar ausente, aborta, sem montar a partição física. Fora
desse boot, usa a partição física caso não exista mapper. O mapper também deve
ter label e filesystem compatíveis.

O mountpoint deve ser específico, absoluto e canônico; caminhos amplos, de
sistema ou symlinks são rejeitados. Não encobre mounts ocupados nem diretórios
com arquivos locais. Executa `mount -t <filesystem> -o rw,nosuid,nodev` e exige
confirmação via `findmnt` de origem, tipo, ID e opção `rw`. Só depois cria
`pmjs-images`, se necessário. Mount falho ou não confirmado nunca causa build
ou cópia no diretório local sob o mountpoint.

O cleanup primeiro remove apenas seus stagings validados e depois desmonta
apenas o mount que o Builder criou (`VENTOY_MOUNTED_BY_BUILDER`). Reconfirma
origem, tipo e ID; se mudarem ou não puderem ser confirmados, não apaga staging
nem desmonta uma mídia incerta. Falha de umount gera aviso, sem mascarar o erro
principal. Não há remount, umount forçado/lazy ou remoção da pasta pmjs-images,
do mountpoint ou de versões finais. INT/TERM durante mount são adiados até
registrar a identidade e executar cleanup seguro. SIGKILL/desligamento abrupto
não permitem cleanup; o mount pode permanecer e será pré-existente na próxima
execução. Um mount não confirmado pode ser preservado com warning para inspeção.

`auto` funciona em `build-image.sh --also-ventoy-dir auto`,
`build-image.sh --ventoy-dir auto` e
`sync-image-to-ventoy.sh --image NOME --ventoy-dir auto`.
Paths explícitos continuam tendo precedência e não acionam discovery/mount,
mesmo com configuração automática habilitada. Configuração antiga com
`VENTOY_AUTOMOUNT_ENABLED` ausente mantém a pergunta manual; `0` também mantém
essa pergunta. `auto` explícito ainda exige os três parâmetros de descoberta.

### Gerar no NFS e copiar automaticamente na mesma execução

Ao clicar no lançador **PMJS Image Builder** da Live, o terminal chama
`build-image.sh` sem argumentos. Com NFS configurado, depois de escolher a versão
aparece a pergunta:

```text
Copiar também para o Ventoy após publicar no NFS? [S/n]:
```

Enter seleciona **Sim**. Com `VENTOY_AUTOMOUNT_ENABLED=1`, o preflight monta ou
reutiliza o Ventoy automaticamente conforme a configuração acima, mostra o
destino confirmado e cria `pmjs-images` apenas na mídia validada. Não pede o
caminho. Responder `n` mantém somente o NFS. EOF/Ctrl+D cancela a pergunta antes
de qualquer mount/captura. Nenhum mount real é feito apenas para perguntar.

Com automount `0`/ausente, a próxima pergunta continua sendo
`Diretório pmjs-images do Ventoy:`. Informe por exemplo
`/media/usuario/Ventoy/pmjs-images` (pasta existente na mídia montada). Nesse
modo não cria caminhos nem monta mídia; entradas inválidas repetem a pergunta.
O preflight mantém a identidade confirmada durante a pergunta manual.
O lançador/wrapper existente já é compatível; não precisa de argumentos novos.
Para disponibilizar esse fluxo na ISO, atualize os snapshots com
`pmjs-live-builder/tools/update-pmjs-snapshots.sh` antes da próxima build da Live.
Uma ISO existente mantém o snapshot antigo até ser atualizada/recriada.

Para o mesmo fluxo por comando, sem perguntar o destino:

```bash
sudo ./build-image.sh --also-ventoy-dir auto
```

Ou informe o caminho offline explícito (mídia já montada e pasta existente):

```bash
sudo ./build-image.sh \
  --also-ventoy-dir /media/usuario/Ventoy/pmjs-images
```

Usa o NFS automático de `config/image.conf`. Também aceita
`--nfs-dir /mnt/clone-pmjs --also-ventoy-dir /media/usuario/Ventoy/pmjs-images`
para um NFS já montado, inclusive outro export/subdiretório. A pergunta inicial
define a identidade única usada nos dois destinos. `--also-ventoy-dir` pula a
pergunta sobre cópia/caminho e usa o destino explícito. Sem terminal interativo,
nenhuma pergunta é feita e a cópia dupla continua exigindo essa opção.
Build local e `--ventoy-dir` também omitem a pergunta de cópia para não mudar
seu destino. Não combinar com `--ventoy-dir`: essa opção
continua sendo o build direto no Ventoy, sem NFS. Se a seleção produzir somente
OUTPUT_DIR local, a opção dupla aborta antes da captura.

Fluxo: preparar/validar destinos → gerar em staging NFS → validar e publicar no
NFS → revalidar bundle final → copiar para staging Ventoy → recalcular hashes e
validar a cópia → publicar no Ventoy. A mídia offline deve estar em um mount
separado, não em NFS. O preflight rejeita uma versão offline já existente e
confere a margem livre; assim que o tamanho real estiver disponível, exige a
soma dos quatro arquivos + `VENTOY_FREE_SPACE_MARGIN_MIB`. Confere novamente a
existência da versão antes da cópia e do rename, evitando sobrescrita por corrida.

**Não é uma transação atômica entre dois filesystems.** Cada publicação é atômica
individualmente e a cópia é sequencial, não uma segunda captura. Se o build NFS
falhar, não copia para o Ventoy. Se a cópia falhar ou for interrompida, o comando
retorna erro, informa o sucesso parcial e preserva a versão final válida no NFS.
O cleanup remove somente seu `.sync.*` validado (se o mount Ventoy não mudou) e
nunca remove a imagem final do NFS nem versões offline anteriores. A identidade
do NFS também é conferida ao longo do build/cópia, inclusive com `--nfs-dir`.
Mounts automáticos pertencentes ao Builder são desmontados somente no cleanup,
depois da cópia; mounts NFS/Ventoy pré-existentes não são desmontados.

Para repetir só a cópia do servidor oficial, sem refazer uma versão imutável:

```bash
sudo ./sync-image-to-ventoy.sh \
  --image pmjs-linux-0.3.0 \
  --ventoy-dir /media/usuario/Ventoy/pmjs-images
```

Esse sincronizador usa o NFS de `config/image.conf`; se o build usou outro export
ou subdiretório explícito, configure o sincronizador para a mesma raiz antes de
repetir a cópia. Não são assumidos silenciosamente paths da mídia.

### Copiar uma versão já publicada

Para preparar uma imagem offline já publicada no servidor, monte a partição de
dados do Ventoy e crie nela o diretório `pmjs-images/`. O script monta ou
reutiliza automaticamente o NFS definido por `NFS_SERVER`, `NFS_EXPORT` e
`NFS_MOUNTPOINT` em `config/image.conf`:

```bash
sudo ./sync-image-to-ventoy.sh \
  --image pmjs-linux-0.2.0 \
  --ventoy-dir /media/usuario/Ventoy/pmjs-images
```

`--image` aceita somente o nome de uma versão final sob a raiz do NFS; paths,
nomes ocultos e nomes de staging são rejeitados. Antes de copiar, o script
valida o bundle schema 1 completo no servidor, incluindo os archives Zstandard,
`SHA256SUMS`, hashes do manifest e identidade do diretório. O diretório Ventoy
deve existir, ser gravável, chamar-se exatamente `pmjs-images` e pertencer a um
filesystem montado diferente de `/`. exFAT é aceito.

O espaço exigido é a soma dos quatro arquivos mais
`VENTOY_FREE_SPACE_MARGIN_MIB` (64 MiB por padrão). A cópia usa
`rsync --info=progress2` sem tentar preservar ownership, ACLs ou xattrs do arquivo
externo; esses metadados já estão serializados dentro dos tars. Os arquivos são
gravados em `.pmjs-linux-<versão>.sync.XXXXXX`, no próprio Ventoy, e todo o
bundle é relido e validado ali. Somente então um rename no mesmo filesystem cria
o diretório final. Uma versão existente nunca é substituída.

O script registra as identidades dos mounts NFS e Ventoy. Em erro, `SIGINT` ou
`SIGTERM`, remove somente o staging `.sync.*` criado pela execução e apenas se o
Ventoy ainda for o mesmo mount. O NFS é desmontado no cleanup somente quando o
próprio script o montou; mounts previamente existentes permanecem montados.
Uma troca ou perda de identidade faz o cleanup preservar o path e emitir aviso.

Para copiar uma imagem já concluída em outro destino, a publicação genérica é
uma operação posterior e explícita. Informe a imagem e um ou ambos os destinos:

```bash
# Diretório offline existente na partição de dados montada do Ventoy
./publish-image.sh \
  --image-dir ./output/pmjs-linux-0.2.0 \
  --ventoy-dir /media/operador/Ventoy/pmjs-images

# Diretório existente dentro de um export NFS já montado
./publish-image.sh \
  --image-dir ./output/pmjs-linux-0.2.0 \
  --nfs-dir /mnt/pmjs-images

# Preparar e publicar nos dois destinos
./publish-image.sh \
  --image-dir ./output/pmjs-linux-0.2.0 \
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
- execução de `build-image.sh` e `sync-image-to-ventoy.sh` como `root`; o
  publisher genérico requer apenas acesso de escrita
- GNU tar com suporte a ACLs e atributos estendidos
- para automount NFS: `mount`, `umount`, `findmnt` (util-linux) e `mount.nfs`
  (cliente `nfs-common` no Debian/PMJS Live), verificados antes da montagem;
  `--nfs-dir` e `NFS_IMAGES_DIR` legado exigem `findmnt` e um NFS já montado;
  `--ventoy-dir` exige `findmnt` e o Ventoy já montado
- para Ventoy `auto`: `lsblk`, `blkid`, `mount`, `umount`, `findmnt`, Python 3 e
  suporte do kernel ao filesystem configurado (exFAT na PMJS Live); `udevadm`
  é necessário somente se faltar o mapper durante um boot Ventoy
- gzip (compatibilidade interna) e zstd
- rsync com suporte a ACLs e atributos estendidos
- Python 3 (serialização e validação robusta do manifest JSON)
- sha256sum
- `OUTPUT_DIR` em filesystem Linux local, `--nfs-dir`/`NFS_IMAGES_DIR` em NFS
  montado, ou `--ventoy-dir` apontando para um `pmjs-images` montado;
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

`test_image_naming.sh` usa pseudo-terminais para a pergunta real: padrão por
Enter, sufixo/nome completo, prefixo configurado, rejeição de paths inseguros,
cancelamento antes dos destinos, pipes sem consumo de stdin, versão no staging
e no manifest schema 1, independência de `VERSION` e versões imutáveis.
Também cobre o fluxo do lançador: cópia padrão Sim, somente NFS, path explícito
com espaços, mídia desmontada, cancelamento nas perguntas, precedência das
opções, configuração legada e omissão em build local/direto ou sem terminal.
Também confirma que automount habilitado pula a pergunta de caminho e encaminha
`auto` ao preflight, sem montar durante as perguntas.
`test_ventoy_automount.sh` simula dispositivos, udev e findmnt/mount/umount:
30 cenários de mídia ausente/ambígua/interna, fallback blkid, mapper/USB/NVMe,
reutilização rw, recusa ro, mount ocupado/local não vazio, falhas pós-mount,
interrupção durante mount, cleanup após erro/troca de ID e warning de umount.
Valida paths perigosos/symlinks e paths escapados com espaços/UTF-8.
`test_dual_destination.sh` executa o main com árvores sintéticas e mounts
simulados: NFS automático/pré-existente/explícito, mesmo bundle nos dois locais,
uma única geração, falhas de rootfs/homefs/SHA256/mount/cópia, falta de espaço,
interrupções antes do commit NFS e durante a cópia, corrupção, versões imutáveis,
corrida de destino, mudanças de mounts e cleanup sem apagar versões finais ou
stagings alheios. Não monta servidor nem copia imagens reais.

Eles cobrem gzip interno, formato Zstandard publicado, integridade cruzada do
manifest e SHA256SUMS, rejeição de corrupção, staging local, build NFS simulado,
falhas por fase, preservação de metadados, equivalência semântica do rootfs
generalizado nos caminhos local e NFS e publicação atômica/imutável.
`test_nfs_automount.sh` usa mocks de `mount`, `umount`, `findmnt` e do cliente
NFS. Cobre montagem/reutilização, origem ou filesystem errado, falhas de mount
e confirmação, paths perigosos, dependências, precedência, abortar o main antes
da captura e cleanup após sucesso, erro, interrupção ou substituição do mount.
Não monta servidor NFS real.
`test_sync_image_to_ventoy.sh` cobre o fluxo NFS → Ventoy com mounts simulados:
bundle válido ou inválido, SHA256 incorreto, espaço insuficiente, imutabilidade,
interrupção, corrupção durante a cópia, falha de mount, mídia ausente, cleanup
seguro e ausência do diretório final antes da validação completa.
`test_ventoy_build.sh` cobre o build direto em Ventoy simulado: seleção sem NFS,
rejeição do filesystem raiz, staging Linux separado, generalização SSH,
preservação de UID/GID, modo, ACL, xattr e symlink, imutabilidade, rejeição de
corrupção, commit atômico e cleanup condicionado à identidade do mount. Nenhuma
mídia real é acessada.

## Integração com o Deploy

O PMJS Deploy deste workspace reconhece o formato Zstandard/schema 1 e mantém o
fallback gzip legado. O diretório final publicado pelo Builder segue a identidade
`<image_name>-<image_version>` esperada no discovery.

> A captura ocorre sobre um sistema ativo. Para consistência forte, execute em
> um snapshot ou ambiente sem escritas concorrentes.
