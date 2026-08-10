# PMJS Image Builder

Gerador de imagens de sistema consumidas pelo PMJS Deploy.

## Sprint 1

O escopo atual gera somente:

```text
output/pmjs-linux-<versão>/rootfs.tar.gz
```

Não são gerados `homefs.tar.gz`, `manifest.json`, `SHA256SUMS` ou ISO. O build
também não remove `machine-id`, logs, chaves SSH host ou caches.

Os pseudo-filesystems `/proc`, `/sys`, `/dev` e `/run` não fazem parte do
archive. Esses diretórios são recriados ou montados pelo sistema durante a
inicialização e não precisam ser armazenados na imagem.

## Requisitos

- Linux e Bash 4.3 ou superior
- execução como `root`
- GNU tar com suporte a ACLs e atributos estendidos
- diretório de saída montado em filesystem diferente de `/`
- ao menos `MIN_FREE_SPACE_GIB` livres no destino

Edite `config/image.conf` conforme necessário. Caminhos relativos são resolvidos
a partir da raiz do projeto.

```bash
sudo ./build-image.sh
```

Ao final, o comando informa o arquivo, tamanho, duração e log. Um build
interrompido remove apenas o arquivo `.partial`; artefatos válidos anteriores
não são apagados.

> A captura ocorre sobre um sistema ativo. Para consistência forte, execute em
> um snapshot ou ambiente sem escritas concorrentes.
