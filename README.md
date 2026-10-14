# fvuls-lockfile-uploader

[![CI](https://github.com/futurevuls/fvuls-lockfile-uploader/actions/workflows/ci.yml/badge.svg)](https://github.com/futurevuls/fvuls-lockfile-uploader/actions/workflows/ci.yml)

A GitHub Action that uploads a lockfile to [FutureVuls](https://vuls.biz/) through the Public API.
If a lockfile with the same path is already registered on the server, the action updates it; otherwise it creates a new one.

See the [FutureVuls manual](https://help.vuls.biz/manual/scan/cicd_image/) for how to prepare the server and the API token.

## Usage

### Inputs

| Input | Required | Description |
|---|---|---|
| `path` | yes | Path to the lockfile, relative to the workspace |
| `repoName` | no | Prefix added to the path registered in FutureVuls (e.g. `${{ github.repository }}`) |

### Environment variables

| Name | Required | Description |
|---|---|---|
| `FVULS_TOKEN` | yes | FutureVuls API token. Store it as a repository secret |
| `FVULS_SERVER_UUID` | yes | UUID of the FutureVuls server that owns the lockfile |
| `FVULS_BASE_URL` | no | Public API endpoint over https (default: `https://rest.vuls.biz`) |

### Registered path

| `repoName` | `path` | Registered path |
|---|---|---|
| (none) | `./go.mod` | `go.mod` |
| `owner/repo` | `./web/yarn.lock` | `owner/repo/web/yarn.lock` |
| `https://github.com/owner/repo` | `go.mod` | `https://github.com/owner/repo/go.mod` |

## Example

The workflow below uploads `go.mod` and `web/yarn.lock` when either file changes on the `main` branch.

```yaml
name: Upload lockfiles
on:
  push:
    branches:
      - main
    paths:
      - 'go.mod'
      - 'web/yarn.lock'

permissions:
  contents: read

jobs:
  upload:
    runs-on: ubuntu-26.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - name: Upload go.mod
        uses: futurevuls/fvuls-lockfile-uploader@<commit SHA> # v1
        env:
          FVULS_SERVER_UUID: ${{ secrets.FVULS_SERVER_UUID }}
          FVULS_TOKEN: ${{ secrets.FVULS_TOKEN }}
        with:
          repoName: ${{ github.repository }}
          path: './go.mod'
      - name: Upload web/yarn.lock
        uses: futurevuls/fvuls-lockfile-uploader@<commit SHA> # v1
        env:
          FVULS_SERVER_UUID: ${{ secrets.FVULS_SERVER_UUID }}
          FVULS_TOKEN: ${{ secrets.FVULS_TOKEN }}
        with:
          repoName: ${{ github.repository }}
          path: './web/yarn.lock'
```

Pass `FVULS_TOKEN` only to the steps that run this action, so that other actions in the job cannot read it.

Pin the action to a full commit SHA, as the example does. Find the SHA of a release on the [tags page](https://github.com/futurevuls/fvuls-lockfile-uploader/tags), or with `git ls-remote https://github.com/futurevuls/fvuls-lockfile-uploader 'refs/tags/v1^{}' refs/tags/v1`. When the output has a `refs/tags/v1^{}` line, use the SHA on that line: it is the commit, and the other line is the tag object.

## Running locally

Build the binary in this repository, then run it from the root of the repository that has the lockfile.
Use the same `INPUT_REPONAME` and `INPUT_PATH` as the workflow, so that the run updates the same lockfile in FutureVuls.

```bash
go build -o /path/to/fvuls-lockfile-uploader .

cd /path/to/your-repo
export FVULS_SERVER_UUID="CHANGE ME"
export FVULS_TOKEN="CHANGE ME"
export INPUT_REPONAME="owner/repo"
export INPUT_PATH="./go.mod"
/path/to/fvuls-lockfile-uploader
```
