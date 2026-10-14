# fvuls-lockfile-uploader — AI 開発ガイド

lockfile を FutureVuls の Public API へ登録する GitHub Action。
Docker container action で、Go で書いた単一バイナリを distroless image で実行する。

## 公開リポジトリ

この repo は一般公開する。コード・コメント・commit message・PR 本文に次の情報を書かない。

- 社内の repo 名、チャットのチャンネル名や URL、issue tracker の番号、監視基盤の名前
- token・server UUID・顧客名などの実データ。テストでは `example.com` や架空の UUID を使う

## 構成

| ファイル | 役割 |
|---|---|
| `action.yml` | Action の入力定義 |
| `Dockerfile` | builder stage で Go をビルドし、`distroless/static` で実行する |
| `main.go` | 環境変数から入力を読み、終了コードを返す |
| `uploader.go` | Public API client と lockfile の登録ロジック |
| `uploader_test.go` | `httptest` で Public API を差し替えたテスト |

## Public API との契約

- 使う endpoint は `GET /v1/server/uuid/{serverUuid}`・`GET /v1/lockfiles`・`POST /v1/lockfile`・`PUT /v1/lockfile/{lockfileID}` の 4 つ
- `GET /v1/lockfiles` の `filterPath` は完全一致で照合される
- 認証は `Authorization` header に token をそのまま入れる
- FutureVuls は登録 path の先頭の `/` を除いて保存する。`resolvePath` は path を正規化し、先頭の `/` を除いた値を返して、検索と登録の両方に使う
- 登録 path(`resolvePath` の結果)を変えると、既存利用者の lockfile が update されず新規作成になる。変えるときは PR 本文で互換性への影響を説明する

## セキュリティ

- `FVULS_TOKEN` をログ・エラーメッセージに出さない
- 依存は標準ライブラリだけにする。外部 module を足すときは PR 本文で理由を書く
- `Dockerfile` の base image は digest で、workflow の `uses:` は commit SHA で固定する

## テスト(必須)

- ロジックを変えたら同じ PR でテストを付ける。table-driven + `t.Run()` で書く
- Public API は `httptest` で差し替える。テストから prd / stg の Public API に接続しない
- Action としての動作は、`gh act` でローカルのモック API に向けて実行して確認する

## コードコメント(書く前フィルタ)

コメントを書く前に How / What / Why / Why not のどれかを判定し、置き場所を決める(t_wada の 4 分割):

- **How**(どう実装したか)→ **コード自体**。命名・関数分割で語らせ、コメントに書かない
- **What**(何をするか)→ **godoc の 1 文** / テスト名
- **Why**(なぜこの変更をしたか)→ **commit message / PR 本文**
- **Why not**(なぜ自明な書き方を避けたか=コードから読めない制約)→ **コメント。これが唯一の居場所**、1〜2 行

## ブランチ / リリース / コミット

- `main` は保護ブランチ。feature ブランチを切って PR を出す
- リリースは `main` の commit に `v1` などの tag を付けて行う。利用者は `@v1` で参照するので、互換性を壊す変更では major を上げる
- tag の作成と push は人が行う
- コミットは英語・conventional commits

## ビルド / テスト / Lint

CI 必須は **Lint**(golangci-lint)・**Test**(`go test -race`)・**Docker build** の 3 つ。

```bash
gofmt -l .
go vet ./...
go test -race ./...
golangci-lint run ./...
docker build -t fvuls-lockfile-uploader .
```
