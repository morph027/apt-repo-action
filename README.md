# create-apt-repo

Create an APT repo using [reprepro](https://manpages.debian.org/bookworm/reprepro/reprepro.1.en.html).
Can be deployed to GH pages using [upload-pages-artifact](https://github.com/actions/upload-pages-artifact) and [deploy-pages](https://github.com/actions/deploy-pages) actions.

## Inputs

| Input | Required? | Default | Description |
| ----- | --------- | ------- | ----------- |
| `repo-name` | `true` | | Repository name |
| `scan-dir` | `false` | `$PWD` | Scan this directory for packages to include in the repo. |
| `keyring-name` | `false` | `${{ inputs.repo-name }}-keyring` | Keyring package name |
| `origin` | `false` | `${{ inputs.repo-name }}` | [Origin](https://wiki.debian.org/DebianRepository/Format#Origin) |
| `suite` | `false` | `${{ inputs.repo-name }}` | [Suite](https://wiki.debian.org/DebianRepository/Format#Suite) |
| `label` | `false` | `${{ inputs.repo-name }}` | [Label](https://wiki.debian.org/DebianRepository/Format#Label) |
| `codename` | `false` | `${{ inputs.repo-name }}` | [Codename](https://wiki.debian.org/DebianRepository/Format#Codename) |
| `components` | `false` | `main` | [Components](https://wiki.debian.org/DebianRepository/Format#Components) |
| `architectures` | `false` | `amd64` | [Architectures](https://wiki.debian.org/DebianRepository/Format#Architectures) |
| `limit` | `false` | `0` | How many package versions to keep (0 = unlimited). |
| `signing-key` | `true` | `n/a` | Private gpg key for signing. Please use secrets! |
| `import-from-repo-url` | `false` | `n/a` | Import existing packages from this repo url. Workaround for immutable GH actions cache. |
| `maintainer` | `false` | `apt-repo-action@${GITHUB_REPOSITORY_OWNER}` | Package maintainer for keyring package. |
| `homepage` | `false` | `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}` | Homepage for keyring package. |

## Outputs

| Output | Description |
| ------ | ----------- |
| `dir` | The directory containing the ready to deploy APT repo |
| `keyring` | The name of the created keyring |

## Usage Example

```yaml

# yamllint disable rule:truthy
on:
  release:
    types:
      - published

permissions:
  contents: read
  pages: write
  id-token: write

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      artifact_id: ${{ steps.upload-artifact.outputs.artifact-id }}
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
      - name: Setup Pages
        uses: actions/configure-pages@v4
      - name: Create packages
        run: |
          ...
          do something funny to create your packages using e.g. fpm, nfpm, ....
          ...
      - uses: morph027/apt-repo-action@v1
        id: create-apt-repo
        with:
          repo-name: my-fancy-tool
          signing-key: ${{ secrets.SIGNING_KEY }}
          codename: jammy
          architectures: amd64 arm64
      - name: Upload Pages artifact
        uses: actions/upload-pages-artifact@v3
        with:
          name: github-pages
          path: ${{ steps.create-apt-repo.outputs.dir }}
  deploy:
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-latest
    needs: build
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```
