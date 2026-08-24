# 03. 空き判定と予約作成 — 日付計算とトランザクション

- **期間**: 2026-08-23 〜 2026-08-24
- **成果**: `GET /api/availability` と `POST /api/bookings` が完成。予約が DB に書き込まれ、二重予約が防がれることを確認
- **前回**: [02. 要件からDB設計を導き、読み取りAPIとフロントを繋ぐまで](02-requirements-schema-read-apis-frontend.md)

---

## この回でやったこと

```
GET  /api/availability   配送日を含む占有範囲を計算し、空きを判定する
POST /api/bookings       HOLD予約を作成し、在庫を押さえる
```

読み取り3本（plans / options / shipping）は「テーブルを引いて返す」だけだったが、この2本は**ロジックが主役**になる。特に `POST` は初めての**書き込み**で、質が変わる。

---

## 1. 段階的に作る — 5ステップに分割した

`/api/availability` は一度に書こうとすると詰まる。**各段階で動作確認できる単位**に割った。

| Step | 内容 | DBアクセス |
|---|---|---|
| 1 | クエリパラメータを受け取ってそのまま返す | なし |
| 2 | `shipping_zones` から `days` を引く | あり |
| 3 | 日付計算（`nights` / `lock_from` / `lock_to`） | なし |
| 4 | `NOT IN` で空き個体を判定 | あり |
| 5 | バリデーション | あり |

**この分割自体が今回の学び。** Step 1 で「値が届いているか」だけ確認したおかげで、クエリパラメータ名のタイポ（`use_prefecture` と書いていたが URL は `prefecture`）を即座に見つけられた。

> `c.req.query()` は**キー名が一致しないと静かに `undefined` を返す**。エラーは出ない。
> だから「まず値をそのまま返す」段階が要る。**タイポを目で見つけるための工程。**

---

## 2. 日付計算

### 確定した仕様（再掲）

```
nights    = (use_end - use_start) の日数差 + 1     ← 両端を含むので +1
lock_from = use_start - shipping_days
lock_to   = use_end   + shipping_days
lock日数  = nights + shipping_days × 2
```

| 県 | days | 利用 | lock | 日数 |
|---|---|---|---|---|
| 千葉県 | 1 | 9/11〜9/12（2泊） | 9/10〜9/13 | 4 |
| 北海道 | 3 | 9/11〜9/12（2泊） | 9/08〜9/15 | 8 |

### ヘルパー関数

```ts
const MS_PER_DAY = 86400000;

// 'YYYY-MM-DD' を n 日ずらして返す（n が負なら過去へ）
function addDays(dateStr: string, n: number): string {
  const d = new Date(dateStr);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

function diffDays(from: string, to: string): number {
  return (new Date(to).getTime() - new Date(from).getTime()) / MS_PER_DAY;
}

// from 〜 to（両端含む）の日付を配列で返す。from > to なら空配列
function dateRange(from: string, to: string): string[] {
  const out: string[] = [];
  for (let d = from; d <= to; d = addDays(d, 1)) out.push(d);
  return out;
}
```

**`addDays` を1つ作れば符号を変えるだけで前後に動かせる。** 関数を2つに分ける必要はない。

```ts
const lock_from = addDays(use_start, -zone.days);   // マイナス → 前へ
const lock_to   = addDays(use_end,    zone.days);   // プラス   → 後ろへ
```

### ★ 必ず UTC 系メソッドを使う

`getDate()` / `setDate()`（ローカル時刻版）ではなく **`getUTCDate()` / `setUTCDate()`**。

`new Date('2026-09-11')` は **UTC の 0時**として解釈される。ここでローカル時刻のメソッドを混ぜるとタイムゾーン分ズレうる。日本時間（UTC+9）では偶然動いてしまうことも多いが、**入口から出口まで UTC で統一**しておけば考えなくて済む。

> `setUTCDate(d.getUTCDate() - 1)` は**月・年をまたいでも正しく動く**。9/1 の前日は自動で 8/31。自分で月末日数を判定する必要はない。

### ★★ JavaScript は存在しない日付を黙って繰り上げる

実際に動かして確かめた結果:

```
'2026-02-31'  →  new Date()  →  2026-03-03   ← エラーにならず3月3日に化ける
'2026-02-29'  →  new Date()  →  2026-03-01   ← 2026年は閏年ではない
'2026-13-45'  →  new Date()  →  Invalid Date
'2026-00-10'  →  new Date()  →  Invalid Date
```

月・日が範囲外（13月、45日）なら `Invalid Date` になるが、**「2月31日」のように月内で溢れる場合は静かに繰り上がる**。

だから形式チェックと `NaN` チェックだけでは足りない。

```ts
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

function isValidDate(s: string): boolean {
  if (!DATE_RE.test(s)) return false;
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) return false;
  return d.toISOString().slice(0, 10) === s;   // ★ 往復させて一致を見る
}
```

**変換して戻したら元と同じか。** `2026-02-31` は `2026-03-03` になって戻るので不一致 → 弾ける。この手のチェックの定石。

### `YYYY-MM-DD` は文字列比較がそのまま日付比較になる

```ts
if (use_start < today()) { ... }         // 過去チェック
WHERE date BETWEEN ? AND ?               // 範囲検索
```

**桁数が固定なので、辞書順 = 日付順**。書式を最初に揃えておくと何度も得をする。`dateRange` のループ条件 `d <= to` もこれに依存している。

---

## 3. 空き判定の SQL

```sql
SELECT id FROM inventory_items
WHERE plan_id = ?
  AND status = 'AVAILABLE'
  AND id NOT IN (
    SELECT inventory_item_id FROM item_days WHERE date BETWEEN ? AND ?
  )
```

**読み方**: 内側の `SELECT` が先に実行され「ロック範囲に予定が入っている個体IDのリスト」を作る。外側はそのリストに**含まれていない**個体を選ぶ。

`item_days` が「1個体 × 1日 = 1行」という設計なので、**範囲の重なり判定が `BETWEEN` だけで済む**。日付範囲同士の重なり判定（`a.start <= b.end AND b.start <= a.end`）を書く必要がない。

> `.bind(plan_id, lock_from, lock_to)` は `?` の**出現順**に渡す。
> 順番を間違えるとエラーは出ず、**間違った結果が静かに返る。**

### ★ 検証データが無ければ検証にならない

`item_days` が空の状態では、何を叩いても必ず `available: true` になる。**一度も `false` を見ていない状態で「できた」と判断しかけた。**

判定ロジックが動いているのか、`NOT IN` が常に全件返しているだけなのか、区別がつかない。

ダミー予約を投入して検証:

```bash
# bookings を先に入れる（item_days が参照しているため）
npx wrangler d1 execute smachill-db --local --command="INSERT INTO bookings (id, status, plan_id, use_start, use_end, prefecture, base_amount, options_amount, shipping_fee, total_amount) VALUES ('test-001','PAID','morzh-4p','2026-09-20','2026-09-21','千葉県',30000,0,8000,38000);"

npx wrangler d1 execute smachill-db --local --command="INSERT INTO item_days (inventory_item_id, date, booking_id, kind) VALUES ('MORZH-001','2026-09-19','test-001','SHIP_OUT'),('MORZH-001','2026-09-20','test-001','USE'),('MORZH-001','2026-09-21','test-001','USE'),('MORZH-001','2026-09-22','test-001','SHIP_BACK');"
```

**検証結果（9/19〜9/22 が埋まった状態）:**

| 入力（千葉県） | lock範囲 | 空き個体 | |
|---|---|---|---|
| 9/11〜9/12 | 9/10〜9/13 | 1 | 貸せる |
| 9/20〜9/21 | 9/19〜9/22 | 0 | 貸せない（ど真ん中） |
| **9/23〜9/24** | **9/22〜9/25** | **0** | ★**利用日は空きだが配送日が被る** |
| 9/24〜9/25 | 9/23〜9/26 | 1 | ぎりぎり貸せる |

**3つ目が今回の成果。** 「9/23〜9/24 に使いたい」客は利用日だけ見れば空いているが、前の客の返送日(9/22)と自分の出荷日(9/22)がぶつかる。このサービスの本質的な難しさが、動くコードとして検証された。

> **境界値（1日だけ重なる / 1日だけ空く）を両方試すのが、この手のロジックの鉄則。**

---

## 4. バリデーション

### 順序 — 安いものから

```
① 必須チェック          DBアクセスなし
② 日付の形式            DBアクセスなし
③ 前後関係（nights < 1）  DBアクセスなし
④ 過去の日付            DBアクセスなし
⑤ plans の存在 + max_nights   DB
⑥ shipping_zones の存在       DB
⑦ 空き判定                   DB
```

**形式が壊れた入力に対して DB を叩く必要はない。弾けるものは早く弾く。**

### 早期リターンの副産物

`if (!use_start || ...) return ...` を通過した後、TypeScript は「`use_start` は `string` だ」と理解する（**型の絞り込み**）。`c.req.query()` の戻り値は `string | undefined` なので、この early return が無いと `new Date(use_start)` で型エラーになる。

**バリデーションが型エラーの解決も兼ねている。**

### ステータスコードの使い分け

| コード | 意味 | 例 |
|---|---|---|
| **400** | リクエストの書き方が悪い | 日付が逆転、形式不正、泊数超過 |
| **404** | 指定されたものが存在しない | プランなし、配送対象外の県 |
| **409** | 状態が競合している | その期間はもう埋まっている |

**エラーの種類が分かれば、フロントで出すメッセージも変えられる。** 全部 400 で返すと「何を直せばいいか」が伝わらない。

### 全10パターンの検証結果

```
正常 9/11-9/12        200  available: true
満室 9/20-9/21        200  available: false
配送衝突 9/23-9/24     200  available: false
逆転                  400  use_end は use_start 以降の日付を指定してください
過去                  400  過去の日付は指定できません
泊数超過               400  レンタルは最大7泊までです
存在しない日付(2/31)    400  日付は YYYY-MM-DD 形式の実在する日付で指定してください
プランなし             404  プランが見つかりません
配送対象外(沖縄県)      404  配送対象外の地域です
必須欠落               400  use_start, use_end, prefecture, plan_id は必須です
```

---

## 5. `POST /api/bookings` — 初めての書き込み

### ★★ `batch()` — 全部成功か、全部なかったことにするか

1件の予約で**最低6行**を書く。

```
bookings          1行
booking_items     1行
booking_options   オプションの数だけ
item_days         lock日数ぶん（千葉2泊なら4行、北海道なら8行）
```

途中で失敗したら、**`bookings` は入ったのに `item_days` が入っていない**——予約は存在するのに在庫が押さえられていない不整合が生まれる。

```ts
const statements = [ /* 全部の INSERT 文を配列に組み立てる */ ];
await db.batch(statements);
```

`batch()` は渡された文を**1つのトランザクション**として実行する。1つでも失敗すれば全部が取り消される。

> **コードの形が変わる。** 「1つずつ `await` していく」のではなく、
> **「先に全部の文を配列に組み立てて、最後に一度 `batch()` を呼ぶ」。**

### ★★ チェックは楽観的、保証は制約

409 を返す箇所が**2つ**ある。

```ts
// ⑦ 事前チェック
if (freeItems.length === 0) {
  return c.json({ error: "指定の期間は空きがありません" }, 409);
}

// ⑨ batch の失敗を捕まえる
catch (e) {
  return c.json({ error: "...（他の予約と競合しました）" }, 409);
}
```

なぜ二重に必要か。**チェックと書き込みの間に、別のリクエストが同じ個体を押さえうる。**

```
リクエストA: 空きチェック → OK
リクエストB: 空きチェック → OK    ← A はまだ書き込んでいない
リクエストA: 書き込み → 成功
リクエストB: 書き込み → item_days の複合主キー違反！
```

⑦は**普段の応答を親切にするため**（早く分かりやすいエラーを返す）。本当に二重予約を防いでいるのは **`item_days` の `PRIMARY KEY (inventory_item_id, date)`**。

> **アプリのチェックは通り抜けられる。DB の制約は通り抜けられない。**
> 重要な不変条件は必ず DB 側に置く。`schema.sql` の「このテーブルが二重予約を物理的に不可能にする」というコメントが、実装として完結した。

### ★ 価格をリクエストから信用しない

ボディで受け取るのは **`option_id` と `quantity` だけ**。価格は必ず `options` マスタから引き直す。

```ts
const master = optionMaster.get(input.option_id);
options_amount += master.price * input.quantity;   // ← マスタの価格
```

クライアントが `{"option_id":"chair","quantity":2,"price":1}` を送ってきても無視される。

同時に、引いた価格を `booking_options.unit_price` に**焼き付けて**保存する。値上げしても過去の予約の金額は変わらない（`record/02` の設計思想）。

### 金額の計算式

```ts
const extra_nights   = Math.max(0, nights - plan.nights);
const base_amount    = plan.base_price + extra_nights * plan.extra_night_price;
const shipping_fee   = zone.fee + option_shipping;
const total_amount   = base_amount + options_amount + shipping_fee;
```

**検証（千葉県・2泊・チェア2個）:**

```
base_amount     30000   2泊 = plan.nights なので延長料金 0
options_amount   4000   チェア 2000円 × 2個
shipping_fee    10000   千葉8000 + チェア送料1000 × 2個
total_amount    44000
```

### `item_days` の組み立て

```ts
const itemDays = [
  ...dateRange(lock_from, addDays(use_start, -1)).map((date) => ({ date, kind: "SHIP_OUT" })),
  ...dateRange(use_start, use_end).map((date) => ({ date, kind: "USE" })),
  ...dateRange(addDays(use_end, 1), lock_to).map((date) => ({ date, kind: "SHIP_BACK" })),
];
```

3つの区間をそれぞれ日付配列にして連結する。`dateRange` は `from > to` なら空配列を返すので、`shipping_days` が 0 のケースも自然に処理される。

### その他の判断

**`crypto.randomUUID()`** — Workers に標準搭載。連番だと「1件前の予約IDを推測して他人の予約を覗く」ことができるので、**外部に出る識別子はランダムにする。**

**`datetime('now', '+30 minutes')`** — `expires_at` を JavaScript ではなく SQL 側で計算。`created_at` の `datetime('now')` と書式が揃い、サーバーの時計に依存しない。

**`Map` と `Set`** — `Map` はオプションIDからマスタを引くため、`Set` は重複検出のため。配列を毎回 `find` で探すより意図が明確。

**`?? null`** — `.bind()` は `undefined` を扱えない。未指定の任意項目は `null` に変換する。

**`201 Created`** — 200 ではなく 201。「リクエストは成功し、**新しいリソースが作られた**」。GET は 200、作成系は 201。

### 動作確認

```
POST /api/bookings          201  booking_id 発行、total_amount 44000
item_days                   4行  10/09 SHIP_OUT / 10/10 USE / 10/11 USE / 10/12 SHIP_BACK
同じ日付でもう一度            409  指定の期間は空きがありません
GET /api/availability       available: false
```

---

## 詰まったポイント集

### 1. `tsconfig.json` の `include` が `compilerOptions` の中にあった

```json
{
  "compilerOptions": {
    "strict": true,
    "include": ["src/**/*", "../worker-configuration.d.ts"]   ← ここでは無視される
  }
}
```

`include` は `compilerOptions` と**並列**のトップレベル項目。

- `compilerOptions` … **どうコンパイルするか**
- `include` / `exclude` / `extends` … **どのファイルを対象にするか**

種類が違う設定なので階層も別。丸ごと無視されていたため `CloudflareBindings` が見つからなかった。

> **`record/01` の Astro `server` vs `vite.server` と同じパターン。**
> **「キー名は合っているが、置く場所が違う」** ——設定ファイルで一番見つけにくいバグ。
> エラーは「見つからない」としか言わないので、キー名だけ見ていても気づけない。
>
> **見分け方**: 設定ファイル自体を開いて診断を見る。エディタは tsconfig のスキーマを知っているので、知らないキーがあれば警告を出す。**「対象のファイル」ではなく「設定ファイル自身」のエラーを見に行く。**

### 2. エディタが Zed だった（VS Code のコマンドが通じない）

| VS Code | Zed |
|---|---|
| `Developer: Reload Window` | Zed 再起動、または `editor: restart language server` |
| `TypeScript: Restart TS Server` | `editor: restart language server` |
| Problems パネル | `Cmd+Shift+M`（プロジェクト診断） |
| `editor.renderWhitespace` | `settings.json` の `show_whitespaces` |

全角スペース混入（`record/02` の詰まり2）対策として、Zed の設定に入れておくとよい:

```json
"show_whitespaces": "all"
```

### 3. ヘルパー関数を貼り忘れて `Cannot find name`

回答が「まずヘルパー2つ」「ハンドラ全体はこう」の2ブロックに分かれていて、後半だけコピーした。

```
Cannot find name 'isValidDate'.
Cannot find name 'today'.
```

`CloudflareBindings` のときと**同じメッセージ**。原因は毎回違う（あれは tsconfig のスコープ、これは単に未定義）が、**エラーが指す名前を検索して定義があるか確認する**という調べ方は共通。

### 4. `c.json()` に引数を3つ渡した

```ts
c.json(use_start, use_end, use_prefecture);   // ❌
```

`c.json()` の形は **`c.json(データ, ステータスコード?, ヘッダー?)`**。第2引数はステータスコード。複数の値を返すなら**1つのオブジェクトにまとめる**。

```ts
c.json({ use_start, use_end, prefecture });   // ✅
```

キー名と変数名が同じなら省略できる（**ショートハンドプロパティ**）。

### 5. クエリパラメータ名の不一致

```
URL側:   ?prefecture=千葉県
コード側: c.req.query("use_prefecture")
```

**一致しないと静かに `undefined` が入る。エラーは出ない。** Step 1 で「値をそのまま返す」確認をしていたので即座に見つかった。

---

## 覚えたこと

### D1

```ts
.all<T>()          // 複数行。{ results, success, meta }
.first<T>()        // 1行 or null
.batch([...])      // 複数文を1トランザクションで実行
```

`< >` の型引数を渡すと、結果のプロパティに型が付く。`zone.days` を**計算に使う**ようになった時点で必須になる（`unknown` のままでは演算できない）。

### Hono

```ts
c.req.query("name")        // クエリパラメータ（?a=1&b=2）
c.req.param("name")        // パスパラメータ（/api/x/:name）
await c.req.json<T>()      // リクエストボディ
c.json(data, 201)          // ステータスコード指定
```

### SQL

```sql
NOT IN (SELECT ...)                  -- サブクエリによる除外
BETWEEN ? AND ?                      -- 範囲（両端を含む）
datetime('now', '+30 minutes')       -- SQLite の日時計算
```

複数行の SQL は**バッククォート**で改行して書くと読みやすい。

---

## 現在地と残タスク

```
[✅] インフラ / 開発環境 / モノレポ / D1
[✅] スキーマ        8テーブル
[✅] 読み取りAPI     plans / options / shipping / availability
[✅] 予約作成        POST /api/bookings（HOLD まで）
[⬜] HOLD の失効処理  ← 放置すると在庫が永久に埋まる
[⬜] Stripe 連携
[⬜] 予約フォーム（フロント）
```

### 次: HOLD の失効処理

`expires_at` を過ぎた HOLD を解放する仕組みが無いと、**決済せずに離脱した客の予約で在庫が永久に埋まる。**

- `status = 'HOLD' AND expires_at < now` の予約を CANCELLED にする
- 対応する `item_days` を削除する（`ON DELETE CASCADE` があるので `bookings` を消せば連動するが、履歴は残したいので `item_days` だけ消す設計も要検討）
- 定期実行は Cloudflare の **Cron Triggers**（`wrangler.jsonc` の `triggers.crons`）

### その後: Stripe 連携

- 決済成功 → `status` を `PAID` に更新
- 失敗・離脱 → CANCELLED にして `item_days` を解放
- Webhook の署名検証が必要

### 積み残し

- `/api/plans` がまだ `SELECT *`
- `GET /api/bookings/:id`（予約内容の確認画面用）が未実装
- エラーハンドリングの共通化（Hono の `app.onError()`）
- バインディング名 `smachill_db` を大文字（`DB`）に揃えるか
- ローカルDBにテストデータ（`test-001` と 10/10 の予約）が残っている
- `not_found_handling` / `observability.enabled` / 独自ドメイン

---

## この回の収穫

**「一度も失敗を見ていない」状態を疑ったこと。**

`item_days` が空のまま `available: true` だけを見て「完成」と判断しかけた。**成功だけを確認しても、ロジックが動いている証明にはならない。**

- `WHERE status = 'AVAILABLE'` が効いているか → **停止中のデータを1件混ぜる**（`record/02`）
- 空き判定が効いているか → **埋まっている期間を作る**
- 404 の分岐が動くか → **存在しない県を叩く**

いずれも「異常系のデータを意図的に用意する」という同じ発想。**seed に `coffee-kit`（UNAVAILABLE）と `MORZH-003`（MAINTENANCE）を混ぜておいたのは、この日のためだった。**

> テストとは「動くこと」ではなく「**動かないべきときに動かないこと**」を確かめる作業でもある。
