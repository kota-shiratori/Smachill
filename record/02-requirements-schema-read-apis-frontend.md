# 02. 要件からDB設計を導き、読み取りAPIとフロントを繋ぐまで

- **日付**: 2026-08-22
- **成果**: 実際の運用条件に合わせてスキーマを拡張し、読み取り系API 3本とフロント表示を本番稼働させた
- **前回**: [01. Cloudflare Workers 1つで Astro + Hono + D1 を動かすまで](01-cloudflare-worker-monorepo-d1.md)

---

## この回でやったこと

```
① 要件の言語化      「このAPIが何をするのか分からない」から始まった
② DB設計の見直し     実機1台・プラン1つ・オプションあり、という実態に合わせる
③ 読み取りAPI 3本    plans / options / shipping
④ フロント接続       相対パス1本で開発・本番の両方が動くことを確認
```

出発点は「`GET /api/shipping/:prefecture` が何をしようとしているのか分からない」という詰まりだった。**コードの書き方ではなく、ドメインの理解が足りていなかった。** そこで一度手を止めて要件を言語化したのが、この回で一番価値のあった判断。

---

## 1. サービスの本質を言語化する

### モバイルサウナのレンタルが難しい理由

ホテルの部屋なら「10日の客」と「11日の客」は独立している。しかしサウナは**モノを送る**ので、輸送日も在庫を占有する。

**千葉県（片道1日）で2泊レンタルする場合:**

```
8/10  SHIP_OUT   出荷。この日もう他の人に貸せない
8/11  USE        利用
8/12  USE        利用
8/13  SHIP_BACK  返送。この日もまだ塞がっている
```

**客が使うのは2泊なのに、個体は4日間ロックされる。**

**北海道（片道3日）なら同じ2泊で8日間ロック。**

```
8/10 8/11 8/12  出荷（3日）
8/13 8/14       利用（2泊）
8/15 8/16 8/17  返送（3日）
```

> **同じ商品・同じ泊数でも、届け先の県によって占有日数が倍以上変わる。**
> これがこのサービスの本質的な複雑さであり、`shipping_zones.days` が存在する理由。

### 各テーブルの役割

| テーブル | 役割 | 例え |
|---|---|---|
| `plans` | 商品カタログ | メニュー表 |
| `inventory_items` | 物理的な個体 | 倉庫の棚にある実物 |
| `shipping_zones` | 県ごとの片道日数と送料 | 配送料金表 |
| `options` | オプションのカタログ | 追加メニュー |
| `bookings` | 予約1件 | 注文書 |
| `booking_items` | 予約 ↔ 実機の紐付け | 注文書と実物の対応 |
| `booking_options` | 予約 ↔ オプションの紐付け | 追加注文の明細 |
| `item_days` | 個体 × 日付の占有台帳 | 倉庫の壁のカレンダー |

**`plans` と `inventory_items` を分ける理由**: 「MORZH 4人用」という**商品**は1種類でも、**実物**は複数台ありうる。カタログ（何を売るか）と在庫（何台あるか）は別概念。EC でも図書貸出でも共通する設計。

**`item_days` が心臓部**:

```sql
PRIMARY KEY (inventory_item_id, date)
```

「MORZH-001 の 8/11」という行は DB 上に1つしか存在できない。だから2件目の予約が同じ個体・同じ日を取ろうとすると **DB が制約違反で弾く**。アプリのコードにバグがあっても二重予約は物理的に起こらない。

---

## 2. 要件変更とその影響分析

### 判明した実態

- テントサウナは**1機のみ**
- プランも**1つだけ**
- オプション（チェア、コーヒー器具など）を追加できる
- オプション課金は**1レンタルにつき固定**（泊数と無関係）
- **オプションを積むと送料が変わる**
- **単品貸しはなし**（必ずサウナ本体と一緒）
- 泊数は**客の希望による**（延長あり）

### 影響分析

| 要件 | 設計への影響 |
|---|---|
| 実機1台・プラン1つ | **構造は変えない。** 1行ずつになるだけ |
| 単品貸しなし | **オプションに日付単位の在庫管理は不要** |
| 課金が泊数と無関係 | `price × quantity` の掛け算だけ。追加考慮なし |
| オプションで送料変動 | `options.shipping_surcharge` を追加 |
| 泊数が可変 | `plans.extra_night_price` を追加 |

#### なぜ `plans` / `inventory_items` を消さなかったか

1行ずつになるので無駄に見えるが、残す判断をした。

- **残すコスト**: ほぼゼロ（1行ずつ + JOIN 1回）
- **消すコスト**: 2台目を買った瞬間、稼働中の予約データを抱えたままスキーマ移行が必要

レンタル業で「機材を増やす」は十分ありうる。今の抽象化はその保険として安すぎる。

#### 1台であることの嬉しい帰結

**同時に走る予約は最大1件**になる。つまり「チェア4脚」の在庫が競合することは原理的に起きない。

→ オプションに `item_days` のような占有台帳は不要。必要なのは「1予約あたり最大何個」という `max_quantity` だけ。**台数が増えたらこの前提は崩れるが、そのときに考えれば十分。**

#### 送料の設計で選んだ道

| | 方式 | 精度 | 複雑さ | 採用 |
|---|---|---|---|---|
| A | `options.shipping_surcharge`（全国一律の加算額） | ざっくり | 低 | ✅ |
| B | オプション × 県 の組み合わせ表 | 正確 | 高 | |
| C | 重量・サイズから計算 | 正確 | 高 | |

送料 = `zone.fee + Σ(option.shipping_surcharge × quantity)`

Bにすると **47県 × オプション数のデータを手で埋める**ことになる。不満が出てから移行すればいい。

---

## 3. スキーマ拡張

### 追加したテーブル

**`options`** — `id` / `name` / `price` / `shipping_surcharge` / `max_quantity` / `status` / `sort_order`

**`booking_options`** — `booking_id` / `option_id` / `quantity` / `unit_price` / `unit_shipping_surcharge`、PK は `(booking_id, option_id)`

### 既存テーブルへの列追加

- `plans` … `extra_night_price`（延長1泊あたり）、`max_nights`（受付上限、NULL で無制限）
- `bookings` … `base_amount` / `options_amount` / `shipping_fee`（`total_amount` の内訳）

### ★ 設計思想1: 価格の「焼き付け」

`booking_options` に `unit_price` を持たせた。「価格は `options` にあるのに重複では？」と思うが、**違う**。

> チェアを 2,000円 → 2,500円 に値上げしたとき、`options` だけを参照していると
> **3ヶ月前の予約の請求額まで遡って変わってしまう。**

だから予約成立時点の価格を明細側にコピーする。既存スキーマの `total_amount` のコメントと同じ思想。

```sql
total_amount  INTEGER NOT NULL,    -- サーバー計算値。AIは計算しない
```

**計算できるのに保存するのは、その時点の事実を固定するため。マスタは変わるが、履歴は変わってはいけない。**

### ★ 設計思想2: 金額の「内訳」を残す

`total_amount` だけでは「なぜ46,000円なのか」を後から説明できない。

- 客から問い合わせが来たとき
- 返金額を計算するとき
- 領収書を出すとき

**「あとで計算し直せばいい」は成立しない。** マスタの値が変わっていたら再現できないから。

### ★ 設計思想3: 金額は整数（円単位）

`INTEGER` で保持する。浮動小数点数は誤差が出る（`0.1 + 0.2 !== 0.3`）。**保持は最小単位の整数、整形は表示時だけ。**

フロントでは `toLocaleString()` で `30000` → `30,000` にした。

---

## 4. 読み取りAPI 3本 — 段階的に要素が増える

意図的に難易度順に並べた。各段階で新しい要素が1〜2個ずつ増える。

### `GET /api/plans` — 基本形

```ts
app.get("/api/plans", async (c) => {
  const { results } = await c.env.smachill_db.prepare("SELECT * FROM plans").all();
  return c.json(results);
});
```

学んだこと: `async/await`、`.all()` は `{ results, success, meta }` を返す、`c.json()`

### `GET /api/options` — 絞り込みと並び替え

```ts
const { results } = await c.env.smachill_db
  .prepare("SELECT id, name, price, shipping_surcharge, max_quantity FROM options WHERE status = 'AVAILABLE' ORDER BY sort_order")
  .all();
```

**seed に `coffee-kit` を `UNAVAILABLE` で1件混ぜておいた**ので、「4件中3件だけ返る」ことでフィルタの動作を検証できた。全部正常なデータだったら `WHERE` を書き忘れても気づけない。

> **`SELECT *` をやめた理由**
> 最初は `SELECT *` で書いたが、レスポンスに `status`（常に AVAILABLE で無意味）、`sort_order`（配列順で表現済み）、`created_at`（内部記録）が混ざっていた。
> 実害は3つ: ①無駄な転送量 ②内部構造の露出 ③将来 `cost`（仕入れ値）のような列を足したら自動的に公開される。
> **「DB にあるもの」と「客に見せるもの」は違う。その差を埋めるのが API の仕事。**

### `GET /api/shipping/:prefecture` — パラメータと異常系

```ts
app.get("/api/shipping/:prefecture", async (c) => {
  const prefecture = c.req.param("prefecture");

  const zone = await c.env.smachill_db
    .prepare("SELECT prefecture, days, fee FROM shipping_zones WHERE prefecture = ?")
    .bind(prefecture)
    .first();

  if (zone === null) {
    return c.json({ error: "配送対象外の地域です", prefecture }, 404);
  }

  return c.json(zone);
});
```

新要素3つ:

**① パスパラメータ** — ルートに `:名前`、ハンドラで `c.req.param("名前")`

**② `.bind()` とプレースホルダ** — 外部から来た値を SQL に渡す唯一の安全な方法

```ts
// ❌ 絶対にやらない
.prepare(`SELECT * FROM shipping_zones WHERE prefecture = '${pref}'`)
// ✅
.prepare("SELECT * FROM shipping_zones WHERE prefecture = ?").bind(pref)
```

`?` に渡した値は SQLite が**必ず「値」として扱う**。`'; DROP TABLE bookings; --` が来ても「そういう名前の県を探す」で終わる。

**③ `.first()`** — `.all()` との違いを実地で確認

| | 返り値 | 該当なし |
|---|---|---|
| `.all()` | `{ results: [...], success, meta }` | `results` が `[]` |
| `.first()` | **行オブジェクトそのもの** | **`null`** |

**設計判断: 見つからなかったら何を返すか**

「沖縄県は配送対象外」は業務的には正常な答えだが、HTTP の意味論では 404 が適切。`c.json(データ, 404)` の第2引数でステータスコードを指定する。

レスポンスに `prefecture` を含めたのは、フロントで「沖縄県は配送対象外です」と**具体的な地名を出せる**ようにするため。

> **正常系だけ確認して満足しない。** `千葉県`（seed にある）と `沖縄県`（無い）の両方を叩く。
> ブラウザだと 404 の本文が見にくいので `curl -i` を使う。

---

## 5. フロント接続 — `.astro` の2つの実行領域

### 最重要の判断: どこで `fetch` するか

```astro
---
// ① フロントマター … ビルド時に Node で実行される
---

<div>...</div>

<script>
  // ② script タグの中 … ブラウザで実行される
</script>
```

**① は使えない。** 静的サイトなので、この領域が走るのは `astro build` の瞬間だけ。

- ビルド時には Worker が起動していない → 叩く相手がいない
- 相対パスの基準になるオリジンが存在しない
- 絶対URLで取得できたとしても、**ビルド時点のデータが HTML に焼き付く**

**② を使う。** ブラウザで実行されるので相対パスが使え、ページを開くたびに最新データを取る。

### 最終的なコード

```astro
<Layout>
  <ul id="plans"></ul>
</Layout>

<script>
  const list = document.getElementById("plans");

  try {
    const response = await fetch("/api/plans");
    if (!response.ok) {
      throw new Error(`レスポンスステータス: ${response.status}`);
    }

    const plans = await response.json();

    if (list) {
      list.innerHTML = plans
        .map((plan) => `<li>${plan.name} / 定員${plan.capacity}名 / ${plan.base_price.toLocaleString()}円（${plan.nights}泊）</li>`)
        .join("");
    }
  } catch (error) {
    console.error(error);
    if (list) {
      list.innerHTML = "<li>プランを読み込めませんでした</li>";
    }
  }
</script>
```

**構造の要点**: 要素の取得は `try` の外、使用は中。成功時と失敗時で**書く内容を変える**——これが `try/catch` を使う本当の理由。エラーを握りつぶすのではなく、ユーザーに状況を伝える。

### ★ 3日間の設計がここで回収された

デプロイされたコードを見ると、相対パスのまま動いている。

```javascript
let t = await fetch(`/api/plans`);
```

```
開発 … localhost:4321/api/plans              → Vite proxy → :8787
本番 … smachill.swan-kouta.workers.dev/api/plans → アセット層フォールバック → Hono
```

**環境ごとの URL 切り替えも、`.env` も、CORS 設定も一切書いていない。**
Worker 1つにまとめる判断と「必ず相対パス」の作法だけで実現している。

ついでに Astro が `<script>` を自動でバンドル・minify していた（変数名が `e`, `t`, `n` に短縮され `type="module"` が付く）。設定は何も書いていない。

---

## 詰まったポイント集

### 1. スキーマ変更で既存 DB を作り直す必要があった

`CREATE TABLE` は既存テーブルがあると失敗する。まだ本物の予約データが無いので、作り直すのが一番簡単だった。

**ローカル** — D1 はただのファイルなので消せばいい。

```bash
rm -rf .wrangler/state/v3/d1
npx wrangler d1 execute smachill-db --local --file=schema.sql
npx wrangler d1 execute smachill-db --local --file=seed.sql
```

**リモート** — ファイル削除ができないので DROP する。**外部キーがあるので子テーブルから先に。**

```bash
npx wrangler d1 execute smachill-db --remote --command="DROP TABLE IF EXISTS item_days; DROP TABLE IF EXISTS booking_options; DROP TABLE IF EXISTS booking_items; DROP TABLE IF EXISTS bookings; DROP TABLE IF EXISTS options; DROP TABLE IF EXISTS shipping_zones; DROP TABLE IF EXISTS inventory_items; DROP TABLE IF EXISTS plans;"
```

> ⚠️ **この手が使えるのは本番稼働前だけ。** 実際の予約が入り始めたら `ALTER TABLE` で差分だけ適用する**マイグレーション**方式に切り替える必要がある。`wrangler d1 migrations` という仕組みがあるので、リリース前に調べること。

**副作用**: `extra_night_price` を `NOT NULL` にしたので、既存の `seed.sql` の `INSERT` が壊れた。**列を追加したら seed も直す。**

### 2. 全角スペースが混入して SQL が壊れた ★見えないバグ

```sql
"WHERE status = 'AVAILABLE'　ORDER BY sort_order"
                           ↑ 全角スペース（U+3000）
```

SQLite は全角スペースを区切り文字として認識しないので、`'AVAILABLE'　ORDER` を1つの塊として読もうとして構文エラー。

**見た目でほぼ判別できないのが最悪な点。** 日本語入力のまま打つと起きる。

**対策**:
- エディタで不可視文字を表示する（VS Code: `editor.renderWhitespace`、`editor.unicodeHighlight.ambiguousCharacters`）
- エラーの `near "..."` に見覚えのない塊が出ていたら疑う
- SQL は英数入力モードに切り替えてから打つ

### 3. SQL 文が途中から始まっていた

```sql
"WHERE status = 'AVAILABLE' ORDER BY sort_order"   -- SELECT ... FROM が無い
```

`WHERE` は単体では文にならない。句の順序は **SELECT → FROM → WHERE → ORDER BY**。

### 4. 絶対URLを書いてしまった

```javascript
const url = "http://localhost:4321/api/plans";   // ❌ 本番で壊れる
const url = "/api/plans";                        // ✅
```

3日間ずっと言われ続けた「必ず相対パス」を、いざ自分で書く段になって踏んだ。**知識として知っていることと、手が覚えていることは違う。**

### 5. `const` のブロックスコープ

```javascript
try {
  const result = await response.json();   // try ブロックの中で宣言
} catch { }

plans.innerHTML = result;                 // ここでは存在しない
```

`const` / `let` は `{ }` の中でしか生きない。

**解決の考え方**: 「fetch が失敗したとき DOM を書き換えるべきか？」→ いいえ → **DOM 操作を `try` の中に移す**。位置を変えるだけでスコープ問題も同時に消える。

### 6. `?.` は代入の左辺に使えない

```javascript
plans?.innerHTML = result;   // 構文エラー
if (plans) { plans.innerHTML = result; }   // ✅
```

`?.` は「読むとき、途中が null なら全体を undefined にする」演算子。書き込む側には使えない。

`if` で絞ると TypeScript も「この中では null でない」と理解してくれる（**型の絞り込み**）。

### 7. 配列をそのまま `innerHTML` に入れると `[object Object]`

```
[{name:"MORZH…"}, {…}]
  → .map(p => `<li>${p.name}</li>`)  →  ["<li>…</li>", "<li>…</li>"]
  → .join("")                        →  "<li>…</li><li>…</li>"
```

`join("")` を忘れると要素の間にカンマが入る。

### 8. `pnpm deploy` を再び踏んだ

```
ERR_PNPM_NOTHING_TO_DEPLOY
```

`record/01` の詰まったポイント5に書いてあった。**記録が早速役に立った回。** 次に同じエラーを見たら自分の record を検索する。

---

## 覚えたこと

### D1 の3メソッド

| メソッド | 返り値 | 用途 |
|---|---|---|
| `.all()` | `{ results, success, meta }` | 複数行 |
| `.first()` | 行そのもの / `null` | 1件取得 |
| `.run()` | 実行結果のみ | INSERT / UPDATE / DELETE |

### Hono

```ts
c.req.param("name")      // パスパラメータ
c.json(data)             // 200
c.json(data, 404)        // ステータス指定
c.text("...")            // プレーンテキスト
```

### ブラウザ側のデバッグ

サーバー側は `wrangler tail` / `curl`、**ブラウザ側は開発者ツール**が同じ役割を果たす。

- **Console** … JavaScript のエラー
- **Network** … リクエストが飛んでいるか、ステータス、レスポンス本文

「どの層で失敗しているか」を切り分ける道具がもう1つ増えた。

### `fetch` の落とし穴

- `fetch()` が返すのは `Response` オブジェクト。データ本体ではない。`.json()` でもう一段変換が要る（`await` が2回登場する）
- **404 や 500 でも `fetch` は例外を投げない。** 「通信できた」と「成功した」は別物。`response.ok` を必ず見る

### セキュリティの原則

**表示用の価格と、確定する価格は別物。**

フロントが「合計 ¥42,000」と出しても、それは概算。確定金額は必ずサーバーが `options` マスタを引き直して計算する。ブラウザ側の値は改ざんできるから。

---

## 現在地と残タスク

```
[✅] インフラ / 開発環境 / モノレポ / D1
[✅] スキーマ        8テーブル。オプションと金額内訳に対応
[✅] 読み取りAPI     plans / options / shipping
[✅] フロント接続     相対パス1本で開発・本番の両方が動作
[⬜] GET  /api/availability   ← 次の難所
[⬜] POST /api/bookings
[⬜] Stripe
```

### 次: `GET /api/availability`

ここからは**日付計算**という新しい種類の難しさ。SQL だけでは完結せず、TypeScript 側のロジックが主役になる初めての回。

```
「8/11〜8/12 に千葉県で使いたい」
  → 片道1日なので 8/10(出荷) 8/11 8/12(利用) 8/13(返送) を押さえる必要がある
  → その4日間、MORZH-001 が item_days に登録されていないか確認する
```

### 確定した要件（2026-08-22）

- **`use_start` 〜 `use_end` は両端を含む利用日。泊数 = 日数。**
  8/11〜8/12 は「2泊」（宿泊業の1泊カウントではなく、機材が手元にある日数で数える）
  → `nights = 日数差 + 1`。**`+1` を忘れると全部1泊ズレる**
- **出荷日・返送日も在庫を占有する。**
  片道1日・2泊なら `8/10 SHIP_OUT / 8/11 USE / 8/12 USE / 8/13 SHIP_BACK` の4日ロック

```
lock_from = use_start - shipping_days
lock_to   = use_end   + shipping_days
lock日数  = nights + shipping_days × 2
```

### 未確定の要件

- `max_nights` を 7 にしたが仮の値
- オプションの価格・`shipping_surcharge` はすべて仮
- HOLD の失効30分は妥当か

### 積み残し

- `/api/plans` がまだ `SELECT *` のまま。`POST /api/bookings` を作る前に列を絞る
- エラーハンドリングの共通化（Hono の `app.onError()`）
- バインディング名 `smachill_db` を大文字（`DB`）に揃えるか
- `not_found_handling` / `observability.enabled` / 独自ドメイン

---

## この回の収穫

**「分からない」を放置せずに、いったん手を止めたこと。**

`GET /api/shipping/:prefecture` を書き始める前に「これは何をする API なのか」で詰まった。そこでコードを書かずに要件を言語化したことで、

- テーブルが8つある理由が繋がった
- 実態（1台・1プラン・オプションあり）とのズレが見つかった
- **ズレを、実装が進む前に直せた**

もし分からないまま書き進めていたら、オプションのテーブルが無いことに `POST /api/bookings` の途中で気づき、作り直しになっていた。

> **設計のズレは、見つかるのが早いほど安い。**
> 「よく分からないけど動いている」は、いつか必ず高い利息をつけて返ってくる。
