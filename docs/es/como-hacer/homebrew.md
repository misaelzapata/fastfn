# Instalar y Publicar (Homebrew)

Esta pagina cubre:

- Como instalar FastFN con Homebrew (recomendado).
- Como publicar un release y actualizar el tap de Homebrew (mantenedores).

## Instalar (usuarios)

```bash
brew tap misaelzapata/homebrew-fastfn
brew install fastfn
fastfn --version
```

Actualizar:

```bash
brew upgrade fastfn
```

Desinstalar:

```bash
brew uninstall fastfn
```

## Instalar desde el codigo fuente (contributors)

Requisitos: Go y Docker.

```bash
git clone https://github.com/misaelzapata/fastfn
cd fastfn
bash cli/build.sh
./bin/fastfn --help
```

## Publicar un release (mantenedores)

FastFN usa GoReleaser y GitHub Actions:

- CI corre en pushes a `main`.
- Releases corren cuando pusheas tags que matchean `v*` (por ejemplo `v0.1.0`).

### 1) Configurar secrets (una vez)

Si quieres que GoReleaser actualice Homebrew automaticamente, agrega:

- `HOMEBREW_TAP_GITHUB_TOKEN`: un token de GitHub con permiso de push a `misaelzapata/homebrew-fastfn`.

Si el secret no existe, el release igual publica los assets en GitHub, pero **omite** actualizar Homebrew.

### 2) Crear tag y pushear

Desde la raiz del repo:

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

### 3) Verificar

Cuando termina el workflow:

- En GitHub Releases aparece la nueva version y los binarios.
- En `misaelzapata/homebrew-fastfn` se actualiza `Formula/fastfn.rb`.

