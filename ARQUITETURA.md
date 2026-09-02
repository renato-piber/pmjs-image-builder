# Contrato e compressão

`IMAGE_COMPRESSION` é uma propriedade da imagem inteira. Rootfs e homefs usam
o mesmo algoritmo para manter um contrato simples e previsível. `gzip` usa o
fluxo GNU tar já existente; `zstd` usa tar + Zstandard no nível configurado
(`ZSTD_LEVEL=3` por padrão). ACLs, xattrs e owners numéricos são opções do tar e
permanecem iguais nos dois formatos.

Os filenames configurados são `auto` e resultam em `rootfs.tar.gz` e
`homefs.tar.gz`, ou `rootfs.tar.zst` e `homefs.tar.zst`.

Após ambos os archives serem publicados e validados:

1. `SHA256SUMS.partial` é criado apenas com os dois nomes finais e verificado
   com `sha256sum --check --strict`;
2. `manifest.json.partial` é serializado e validado com Python 3;
3. somente então os dois metadados são renomeados para os nomes finais.

O manifest schema 1 não contém machine-id, UUIDs, serial de disco, DEVICEID do
OCS, fingerprints SSH ou dados do perfil do usuário. Ele contém somente dados
do contrato e auditoria não sensível: versão, instante UTC, compressão,
arquitetura, distribuição, kernel do builder, nomes, tamanhos e hashes.
