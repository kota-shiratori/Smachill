# 01. Cloudflare Workers 1つで Astro + Hono + D1 を動かすまで

- **期間**: 2026-08-20 〜 2026-08-22
- **成果**: フロント・API・DB が1つの Worker で動き、本番デプロイ済み
- **本番URL**: https://smachill.swan-kouta.workers.dev

---

## ゴールと最終構成

### 本番

```
        smachill.swan-kouta.workers.dev  ← Worker 1つ
          ├─ /*      → アセット層が web/dist を配信（Worker 起動せず・課金なし）
          └─ /api/*  → フォールバック → Hono → D1 (smachill-db)
```

### 開発

```
        pnpm dev（concurrently が2プロセス同時起動）
          :4321 astro dev ── /api/* を proxy ──▶ :8787 wrangler dev
                 ↑ここを開く                        └─ D1（ローカル SQLite）
```

**本番は同一オリジンなので CORS 設定が不要。** 開発は2プロセスに分かれるが、フロントのコードは `fetch('/api/...')` という相対パス1通りで両環境に対応できる。これがこの構成を選んだ最大の見返り。

### ディレクトリ

```
smachill/
├── package.json               ワークスペースのルート。dev/build/deploy を統括
├── pnpm-workspace.yaml        api と web をメンバー登録
├── wrangler.jsonc             Worker 1つ分の定義（main / assets / d1_databases）
├── worker-configuration.d.ts  自動生成。CloudflareBindings 型
├── schema.sql                 テーブル定義（6テーブル）
├── seed.sql                   開発用の初期データ
├── record/                    この記録
├── api/                       Hono。依存は hono のみ
│   ├── package.json
│   ├── tsconfig.json
│   └── src/index.ts
└── web/                       Astro。依存は astro のみ
    ├── astro.config.mjs       vite.server.proxy で /api を 8787 へ
    └── src/
```

---

## 技術選定と、その理由

### なぜ Worker 1つにまとめたか

選択肢は2つあった。

| | 構成 | 利点 | 欠点 |
|---|---|---|---|
| 案A | Worker 2つ（api用 / web用） | 責務が分離 | **CORS 必須**、デプロイ2回、URL 2つ |
| 案B | Worker 1つ | 同一オリジン、1デプロイ、CORS 不要 | 開発時にプロキシが必要 |

**案Bを採用。** Cloudflare の Workers Static Assets が「アセット優先・外れたら Worker」というルーティングを自動でやってくれるため、**振り分けコードを1行も書かずに**両立できる。これは Cloudflare 自身が推している構成でもある。

### アセット優先ルーティングの仕組み

```
リクエスト到着
   ↓
静的ファイルに一致する？
   ├─ YES → そのファイルを返す（Worker は起動すらしない・課金対象外）
   └─ NO  → Worker (Hono) に渡される
```

`/api/hello` は `web/dist` に存在しないので自動的に Hono へ落ちる。設定は `wrangler.jsonc` の `assets.directory` だけ。

**確認方法**: `npx wrangler tail` を起動した状態で `/` と `/api/hello` を交互に叩くと、**`/api/hello` でだけログが出る**。静的ファイルが Worker を起動していない証拠が目で見える。

### Astro は静的（SSR にしない）

- **静的 + Hono** → アセット配信と Worker が綺麗に分離される。簡単
- **SSR + Hono** → 両方が `fetch` ハンドラを持つため、1つの Worker に2つのエントリポイントを共存させる必要があり複雑化

必要になるまで静的で進める判断。

---

## 作業フェーズ

### フェーズ1: とにかく1つデプロイする

`create-hono` の cloudflare-workers テンプレートを使っていたため、**wrangler は最初から devDependencies に入っていた**。インストール作業は不要だった。

```bash
npx wrangler login    # 認証情報はホーム配下にグローバル保存。どのディレクトリで実行してもよい
npx wrangler whoami   # Account ID と Token Permissions を確認
npm run deploy
```

`api.swan-kouta.workers.dev` で `Hello Hono!` が表示された。**ビルド設定を1行も書いていない**のがポイント。`main` が `src/index.ts` を指していれば wrangler が esbuild でバンドルまでやる。

> **メモ**: `login` / `whoami` はどこで実行してもよいが、`deploy` / `dev` / `types` は `wrangler.jsonc` を探すので実行ディレクトリが重要。

### フェーズ2: 1 Worker に web を同居させる

1. `web/` を `astro build` して `dist/` を生成
2. Hono のルートを `/` から `/api/hello` へ退避
3. `wrangler.jsonc` に `assets` を追加
4. Worker 名を `api` → `smachill` に変更

> **注意**: Worker の `name` を変えると**別の Worker が新規作成される**。古い方はダッシュボードに残るので手動削除が必要。

`/` は index.html に必ず勝たれるので、Hono 側のルートは静的ファイルと衝突しないパスに置く必要がある。

### フェーズ3: 開発環境を作る

`astro build` → `wrangler deploy` を毎回やるのは非現実的なので、開発時のみ2プロセス構成にする。

`web/astro.config.mjs`:

```js
export default defineConfig({
  vite: {
    server: {
      proxy: {
        '/api': 'http://localhost:8787',
      }
    }
  }
});
```

**この設定は開発時のみ有効で、本番ビルドには一切影響しない。** 本番は同一オリジンなのでプロキシ自体が不要、という対称性。

> **最重要の作法**: フロントから API を呼ぶときは**必ず相対パス** `fetch('/api/hello')`。絶対URL (`http://localhost:8787/...`) を書くと本番で壊れる。相対パスなら、開発では Vite のプロキシが、本番ではアセット層のフォールバックが処理してくれる。

### フェーズ4: モノレポとして整える

一番地味で、一番効いた工程。

**Before**: 3つの独立プロジェクトが同居していた
- `wrangler` が2バージョン（api に 4.110.0、ルートに 4.124.0）
- `pnpm-lock.yaml` が3つ（ルート・api・web）
- 仮想ストア `.pnpm` が3箇所に重複
- `wrangler.jsonc` が `api/` にあり、`"directory": "../web/dist"` と親を飛び出していた

**After**: pnpm workspace 1つ
- ロックファイル1つ、ストア1つ
- `wrangler.jsonc` はルート。`./api/src/index.ts` と `./web/dist` で `..` が消えた
- `hono` は api の依存、`astro` は web の依存、`wrangler` と `concurrently` はルート——**所有者が明確**

`pnpm-workspace.yaml`:

```yaml
packages:
  - api/
  - web/
```

ルート `package.json` のスクリプト:

```json
{
  "name": "smachill",
  "private": true,
  "scripts": {
    "dev": "concurrently --names \"api,web\" --prefix-colors \"yellow,cyan\" \"wrangler dev\" \"pnpm --filter web dev\"",
    "build": "pnpm --filter web build",
    "deploy": "pnpm run build && wrangler deploy --minify",
    "cf-typegen": "wrangler types --env-interface CloudflareBindings"
  }
}
```

> **`&&` の使い分け**: `deploy` は「ビルドが**終わって成功したら**デプロイ」なので `&&` が正解。しかも失敗時に右が実行されないので、**壊れたサイトをデプロイする事故も防げる**。一方 `dev` は両方が終わらないプロセスなので `&&` では動かない。並列実行には `concurrently` が要る。

### フェーズ5: D1 を繋ぐ

```bash
# ローカルにスキーマとデータを投入
npx wrangler d1 execute smachill-db --local --file=schema.sql
npx wrangler d1 execute smachill-db --local --file=seed.sql

# 型を生成（wrangler.jsonc のバインディング定義から CloudflareBindings 型を作る）
pnpm run cf-typegen
```

`wrangler.jsonc`:

```jsonc
"d1_databases": [
  {
    "binding": "smachill_db",
    "database_name": "smachill-db",
    "database_id": "e1184d4f-..."
  }
]
```

Hono にバインディングの型を渡す:

```ts
const app = new Hono<{ Bindings: CloudflareBindings }>()

app.get('/api/plans', async (c) => {
  const { results } = await c.env.smachill_db.prepare('SELECT * FROM plans').all()
  return c.json(results)
})
```

これで `localhost:4321/api/plans` が実データを返した。**ブラウザ → Astro dev → proxy → wrangler dev → Hono → D1 → JSON** の全経路が開通。

---

## 詰まったポイント集

ブログにするならここが本体。全部実際に踏んだもの。

### 1. `/api/hello` が 404 — その404は誰が返したのか

**症状**: `assets` 設定後、`/api/hello` が 404。

**切り分け**: 404 を返しうる主体は2つある。

| 返した主体 | 意味 | 見分け方 |
|---|---|---|
| アセット層（Cloudflare） | Worker まで届いていない | `wrangler tail` にログが**出ない** |
| Hono | Worker は動いた。ルートが一致しなかった | ログが**出る**。本文はプレーンテキストで `404 Not Found` |

```bash
npx wrangler tail                                    # ログが出るか
curl -i https://smachill.swan-kouta.workers.dev/api/hello  # ヘッダと本文を見る
```

**原因**: Hono のルートを `/` のまま放置していた。Hono が動いて404を返していたので、実は「アセット層は正しく機能している」証拠でもあった。

**教訓**: エラーは「どの層が出したか」を最初に特定する。これが以降すべての場面で効いた。

### 2. Astro と Vite の両方に `server` がある

`proxy` は `vite.server.proxy` にある。Astro のトップレベルにも `server` が存在するが、そちらは `host` / `port` 用で `proxy` は無い。

```
defineConfig({
  server: { ... }    ← Astro の設定。host/port 用。proxy は無い
  vite: {
    server: { ... }  ← Vite の設定。ここに proxy がある
  }
})
```

同じ名前で階層が違う、という間違えやすいパターン。`// @ts-check` があればエディタが赤線で教えてくれる。

### 3. pnpm workspace のグロブ記法

```yaml
# テンプレートの初期値
packages:
  - apps/*        # 「apps の中に並んでいる各ディレクトリ」がパッケージ

# 最初の修正（間違い）
  - api/*         # 「api の中の各ディレクトリ」= api/src, api/node_modules

# 正解
  - api/
```

`*` は「**この位置にパッケージのディレクトリが複数並んでいる**」という意味。`api` 自体がパッケージなので `*` は不要。

**検証コマンド**: `pnpm ls -r --depth -1` でメンバーが列挙される。ルートしか出なければマッチゼロ。

### 4. node_modules の残骸 — 日付と構造で見抜く

ワークスペース化しても、旧構成時代の `node_modules` が残っていた。

```bash
$ ls -la api/node_modules/
.pnpm                          Jul 25 20:37   ← 古い（プロジェクト作成日）
.modules.yaml                  Jul 25 20:37   ← 古い
hono -> ../../node_modules/... Aug 20 19:25   ← 新しい
```

**見分け方1（タイムスタンプ）**: `ls -la` の日付で新旧が混在しているか見る。

**見分け方2（構造）**: pnpm ワークスペースでは **`.pnpm`（仮想ストア）はルートに1つだけ**。パッケージ配下に `.pnpm` があったら非ワークスペース時代の残骸。

**対処**: `node_modules` はディレクトリごと削除して `pnpm install` し直す。`package.json` と `pnpm-lock.yaml` からいつでも完全再生成できるので、消しても失うものは無い。

> **正しい姿**: 各パッケージの `node_modules` にはシンボリックリンクと `.bin` だけがある。実体はルートに1つ。「宣言していない依存を誤って import する事故」を防ぐ設計。

### 5. `pnpm deploy` が動かない — 組み込みコマンドとの名前衝突

```
ERR_PNPM_NOTHING_TO_DEPLOY  No project was selected for deployment
```

**原因**: `deploy` は **pnpm 自身の組み込みコマンド**。スクリプトは見に行かれてすらいない。

**対処**: `pnpm run deploy` と `run` を明示する。

`pnpm dev` が動いていたのは `dev` という組み込みコマンドが無いから。**たまたま無事だっただけ。**

> **衝突しやすい名前**: `install` `add` `remove` `link` `publish` `pack` `list` `why` `deploy`
> スクリプト内で他のスクリプトを呼ぶときも `pnpm run build` と書く癖をつけると、将来の pnpm バージョンアップでも壊れない。

### 6. ゾンビプロセスがポートを占拠していた ★最大のハマり

**症状**: 設定は全部正しいのに `/api/hello` が動かない。

**診断**:

```bash
lsof -nP -iTCP -sTCP:LISTEN
ps -o pid,lstart,command -p <PID>
```

**判明したこと**:

| PID | 起動 | 正体 | ポート |
|---|---|---|---|
| 19161 | **8月13日** | `Downloads/GihyoAstro/...` の**別プロジェクト** | :4321 |
| 65630 | 8月20日 19:04 | **削除済みの** `api/node_modules` から起動した workerd | :8787 |
| 66893 | 8月20日 19:18 | 正しい workerd（8787 が埋まっていたので**隣にずれた**） | :8788 |

- ブラウザで 4321 を開くと、**1週間前から動いている無関係なチュートリアル用サイト**が表示されていた
- proxy が向いている 8787 は、足元の node_modules を消された**壊れた workerd**。`curl` が2分待っても応答しない
- 本物の smachill は 8788 と 4322 に押し出されていた

**教訓**:

> **「設定が間違っている」より「環境が汚れている」ほうが原因として多い。**
>
> 1. プロセスは意図したものが動いているか（`lsof` でポートの持ち主を確認）
> 2. ポートは想定どおりか（**サーバー起動ログのポート番号を必ず読む**）
> 3. それから設定を疑う

再発防止として `wrangler.jsonc` に `dev.port` を明示してポートを固定する手もある。ずれたら「起動失敗」になるので、静かに隣へ逃げるより気づきやすい。

### 7. `JSX.IntrinsicElements` が見つからない — 言語サーバーが古い世界を見ていた

**症状**: `.astro` ファイルで型エラー。設定はどこも正しい。

**タイムライン**:
```
19:25  言語サーバー（TS Server / Astro LS）が起動
19:28  web/node_modules を削除して再作成   ← 足元が消えた
```

**対処**: `Cmd+Shift+P → Developer: Reload Window`

Astro は独自の言語サーバーを持つので、TS Server だけ再起動しても直らないことがある。

> **パターン**: `node_modules` を作り直したら、それを見ている長寿命プロセスを全部再起動する（dev サーバー、エディタの言語サーバー、型チェックのウォッチャー）。**6番とまったく同じ病気。**

### 8. `CloudflareBindings` が見つからない — モノレポ化の副作用

**症状**: `Cannot find name 'CloudflareBindings'`

**原因**: `wrangler.jsonc` をルートに移したので、`cf-typegen` の出力 `worker-configuration.d.ts` もルートに生成される。しかし `api/tsconfig.json` は `include` 未指定 = **暗黙のスコープが `api/` 配下だけ**。1つ上の階層のファイルは視界に入らない。

**対処**: `api/tsconfig.json` に `include` を追加。

```json
"include": ["src/**/*", "../worker-configuration.d.ts"]
```

> **注意**: `include` を明示した瞬間、暗黙のスコープは無効になる。`src/**/*` も自分で書く必要がある。
> 直したあとは**必ず TS Server を再起動**（7番と同じ理由）。

### 9. D1 の `--local` と `--remote`

```
Resource location: local
🌀 ... from .wrangler/state/v3/d1
🌀 To execute on your remote database, add a --remote flag
```

`--local` は `.wrangler/state/v3/d1/` のローカル SQLite ファイル。**本番の D1 には何も起きていない。**

さらに `wrangler.jsonc` のバインディングに `"remote": true` を書くと、`wrangler dev` が本番 D1 に接続する。ローカルにスキーマを流したのにこれが有効だと**噛み合わない**（開発中はローカル運用にするなら外す）。

> **定番事故**: 「ローカルでは動くのに本番で `no such table`」。デプロイ前に `--remote` でスキーマを流すのを忘れないこと。

### 10. `SELECT * FROM smachill-db` が構文エラー

```
✘ [ERROR] near "-": syntax error at offset 22: SQLITE_ERROR
```

**原因は2つ重なっていた**。

1. `smachill-db` は**データベース名**であってテーブル名ではない。DB はコマンドの第1引数で既に指定済み。`FROM` に書くのはその中のテーブル（`plans` など）
2. SQL パーサーはハイフンを**引き算**として解釈する。`smachill - db` と読まれた

`offset 22` を数えると、ちょうど `-` の位置。**エラーメッセージは詰まった文字位置まで教えてくれる。**

`SQLITE_ERROR` という接頭辞も情報で、「wrangler の使い方ではなく SQL 文そのものが悪い」という切り分けになる。

### 11. `1 command executed successfully` は「1行返った」ではない

```
🌀 Executing on local database ...
🚣 1 command executed successfully.
（結果テーブルが表示されない）
```

これは「**SQL 文を1つ実行した**」という意味。結果が表示されないのは**該当行が0件**だから。`schema.sql` には `CREATE TABLE` しかなく `INSERT` が無いので、テーブルは空だった。

**切り分け方**: `SELECT COUNT(*) FROM plans` は0件でも**必ず1行返す**ので、`0` が表示される。「0行だから出ない」のか「クエリが壊れている」のかを区別できる。

**テーブル一覧の確認**:

```bash
npx wrangler d1 execute smachill-db --local --command="SELECT name FROM sqlite_master WHERE type='table'"
```

`_cf_METADATA` という見覚えのないテーブルが混じるが、これは D1 が内部管理用に自動作成するもの。触らない。

### 12. `await` 忘れ — 型チェックを通り抜けるバグ

```ts
// ❌ Promise をそのまま JSON 化してしまう
const result = c.env.smachill_db.prepare('SELECT * FROM plans').all()
return c.json(result)

// ✅
const { results } = await c.env.smachill_db.prepare('SELECT * FROM plans').all()
return c.json(results)
```

`c.json()` は JSON 化できるものなら何でも受け取るので、Promise を渡しても**型エラーにならない**。実行して初めて `{}` が返ることに気づく。

**エディタが赤線を出さないからといって正しいとは限らない。**

あわせて、`.all()` の戻り値は `{ results, success, meta }` という形。そのまま返すと **D1 の内部構造が外部インターフェースに漏れる**ので、`results` だけを取り出して返す。

> **D1 の3メソッド**
> - `.all()` … 複数行。`{ results, success, meta }` が返る
> - `.first()` … 1行そのもの（無ければ `null`）
> - `.run()` … INSERT / UPDATE / DELETE

---

## 覚えたコマンド

### 診断

```bash
lsof -nP -iTCP -sTCP:LISTEN          # ポートを掴んでいるプロセスを特定
ps -o pid,lstart,command -p <PID>    # そのプロセスの起動時刻と実体パス
curl -i <URL>                        # ステータス行・ヘッダ・本文を全部見る
npx wrangler tail                    # 本番 Worker のログをリアルタイムで見る
pnpm ls -r --depth -1                # ワークスペースのメンバー一覧
pnpm ls -r <pkg>                     # どのパッケージがそれに依存しているか
git diff / git status --short        # 保存できたか自分で確かめる
```

### D1

```bash
npx wrangler d1 execute <db> --local --file=schema.sql
npx wrangler d1 execute <db> --local --command="SELECT ..."
npx wrangler d1 execute <db> --remote --file=schema.sql   # 本番に流す
```

> **クォートの使い分け**: 外側はダブルクォート、SQL の文字列リテラルはシングルクォート。
> `--command="SELECT name FROM sqlite_master WHERE type='table'"`

### pnpm workspace

```bash
pnpm add -D concurrently -w     # -w = ワークスペースのルートに入れる
pnpm --filter web dev           # web パッケージの文脈でスクリプトを実行
pnpm run <script>               # 組み込みコマンドとの衝突を避ける
```

---

## 設計上のメモ

### スキーマの核心

```sql
CREATE TABLE item_days (
  inventory_item_id TEXT NOT NULL REFERENCES inventory_items(id),
  date              TEXT NOT NULL,
  booking_id        TEXT NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  kind              TEXT NOT NULL,   -- SHIP_OUT / USE / SHIP_BACK
  PRIMARY KEY (inventory_item_id, date)
);
```

**同じ個体・同じ日は1行しか存在できない**——複合主キーで二重予約を DB レベルで物理的に不可能にしている。アプリのロジックにバグがあっても DB が最後の砦になる。

`POST /api/bookings` を書くときは、複数の INSERT を「まとめて成功か失敗か」にする必要がある（D1 の `batch()`）。

### 金額は整数（円単位）

`base_price INTEGER` としている。浮動小数点数は誤差が出る（`0.1 + 0.2 !== 0.3`）ので、金額は最小単位の整数で保持し、表示時にだけ整形する。

### seed.sql の作法

- `INSERT OR REPLACE` で**冪等**に（何度流し直しても同じ状態）
- 外部キーがあるので**親 → 子**の順に並べる
- **異常系のデータを1件混ぜる**（`MORZH-003` を `MAINTENANCE` に）。全部正常だとフィルタが効いているか判別できない
- 同一プランに**複数個体**を用意する。1個体だと在庫割り当てロジックが試せない
- トランザクションテーブル（`bookings` など）は**空が正しい初期状態**
- `.gitignore` に入れず**コミットする**。これがあるから他の環境で同じ DB を再現できる

---

## 現在地と残タスク

```
[✅] インフラ      Worker 1つで web + api、デプロイ経路確立
[✅] 開発環境      pnpm dev で両方起動、HMR + API
[✅] モノレポ      pnpm workspace、依存が整理済み
[✅] DB(ローカル)  スキーマ + seed + 型 + 疎通確認
[⬜] DB(本番)      まだ空。デプロイすると 500 になる
[⬜] API           6本中1本（/api/plans のみ）
[⬜] フロント      Astro の初期テンプレートのまま。API を1度も叩いていない
```

### すぐやる

1. `api/src/index.ts`（plans エンドポイント）をコミット
2. 本番 D1 にスキーマと seed を流す（`--local` を `--remote` に変えるだけ）

### 次の実装（難易度順）

| 順 | エンドポイント | 学ぶこと |
|---|---|---|
| 1 | `GET /api/plans` ✅ | Worker → D1 → JSON の経路 |
| 2 | `GET /api/shipping/:prefecture` | パスパラメータ、`.bind()`、`.first()` |
| 3 | `GET /api/availability` | 日付範囲の計算、`item_days` との照合 |
| 4 | `POST /api/bookings`（HOLD） | **本丸**。`batch()` によるトランザクション |
| 5 | Stripe 連携 | 外部 API、Webhook |

> **`.bind()` は必須の作法**。文字列連結で SQL を組むと SQL インジェクションを許す。
> ```ts
> // ❌ 絶対にやらない
> .prepare(`SELECT * FROM shipping_zones WHERE prefecture = '${pref}'`)
> // ✅
> .prepare('SELECT * FROM shipping_zones WHERE prefecture = ?').bind(pref)
> ```

### 仕上げ

- フロントから `fetch('/api/plans')` して画面に出す（構成の見返りを体感できるので早めが良い）
- `not_found_handling` / `html_handling` で404の挙動を調整
- `observability.enabled` でログをダッシュボードに出す
- 独自ドメイン（Custom Domain）
- エラーハンドリングの共通化（Hono の `app.onError()`）
- バインディング名 `smachill_db` を大文字（`DB`）に揃えるか検討。Cloudflare の慣例は大文字

---

## この3日間で一番の収穫

**「設定を睨む前に、環境と経路を疑う」**

12個の詰まりポイントのうち、**純粋な設定ミスは半分以下**だった。残りはゾンビプロセス、古い node_modules、言語サーバーのキャッシュ、コマンド名の衝突——つまり「書いたものは正しいが、動いている実体が違う」類。

エラーを見たら順に問う:

1. **どの層が出したエラーか**（アセット層 / Worker / SQLite / pnpm / TypeScript）
2. **実際に動いているプロセスは意図したものか**（`lsof`、起動時刻、実体パス）
3. **設定は保存され、読み込まれたか**（`git diff`、言語サーバーの再起動）
4. それから設定の中身を疑う
