# 04. なぜ API を作るのか — HTML を返す実験と、7日物の dev サーバー

- **期間**: 2026-08-30
- **成果**: 「API を作らずに Web アプリは作れるか」を実験で確かめた。`GET /plans-html` を追加し、同じ SQL から JSON と HTML を返して比較
- **前回**: [03. 空き判定と予約作成 — 日付計算とトランザクション](03-availability-and-booking.md)

---

## この回でやったこと

コードはほとんど書いていない。**『Web API The Good Parts』を読んでいて浮かんだ疑問を潰した回。**

> ここで作っている API はなぜ必要か？ API を作らずに Web アプリケーションは作れるのか？

結論から言うと **作れる**。そして「作れる」と分かったうえで、**それでも API にする理由**が何なのかを、自分のコードで確認した。

---

## 1. 問いの立て直し — 「サーバーの理由」と「APIの理由」は別

最初に整理が必要だった。API が必要な理由として挙がりがちな3つは、**実は「サーバーが必要な理由」であって「API が必要な理由」ではない。**

| | 理由 | 該当箇所 |
|---|---|---|
| ① | **信頼境界** — クライアントの値を信用できない | `index.ts` の「価格はリクエストの値を信用せず、必ずマスタから引き直す」 |
| ② | **資格情報** — DB に触れる権限をブラウザに渡せない | `c.env.smachill_db` |
| ③ | **調停** — 同時アクセスの勝敗を一箇所で決める | `db.batch()` と複合主キー違反の catch |

**この3つは HTML を返すサーバーでも全部満たせる。** だから API を作る理由にはならない。

> **「サーバーが要るか」ではなく「サーバー側の処理をどういう形で呼ぶか」が論点。**

---

## 2. API を作らない構成は実在する（3パターン）

| | 構成 | 実態 |
|---|---|---|
| **A** | SSR + フォーム POST（Rails / PHP / Django） | JSON を返す口が1つも無い。サーバーは常に HTML を返す |
| **B** | Server Actions / RPC（Next.js / Remix / tRPC） | **API が消えたのではなく、API 設計をフレームワークに委譲した**。裏では HTTP が飛んでいる |
| **C** | BaaS（Supabase / Firebase） | **API を他人が作ってくれている**。①② は RLS で代替 |

C は魅力的に見えるが、**このサービスには届かない。** 「配送日数を引いて `lock_from`/`lock_to` を計算し、空き個体を選び、`item_days` を数十行 INSERT し、衝突したら 409」——これを RLS ポリシーで書くのは不可能。結局 Edge Function を書くことになり、**それは API そのもの**。

> **どの構成を選んでも `POST /api/bookings` の中身 280 行は1行も減らない。**
> 変わるのは最後の `return` だけ。

---

## 3. 実験 — `GET /plans-html`

「出力形式が違うだけ」を口で言っても腹落ちしないので、**同じデータを HTML で返すエンドポイントを隣に作った。**

```ts
import { html } from "hono/html";

app.get("/plans-html", async (c) => {
  const { results } = await c.env.smachill_db
    .prepare("SELECT * FROM plans")     // ← /api/plans と完全に同一
    .all<PlanRow>();

  return c.html(html`
    <table>
      ${results.map((p) => html`
        <tr><td>${p.id}</td><td>${p.name}</td></tr>
      `)}
    </table>
  `);
});
```

`.ts` のまま動く。JSX を使うなら `index.ts` → `index.tsx` のリネームと `wrangler.jsonc` の `main` 変更が要るので、実験にはテンプレートリテラル版が軽い。

> **`tsconfig.json` には最初から `jsx: "react-jsx"` / `jsxImportSource: "hono/jsx"` が入っていた。**
> Hono の JSX は追加パッケージ不要。React も Astro も要らない。

### 実測結果

```
GET /api/plans                        GET /plans-html
Content-Type: application/json        Content-Type: text/html; charset=UTF-8
Content-Length: 171                   Transfer-Encoding: chunked
```

### ★ Hono は API フレームワークではない

`c` が持つレスポンスの作り方:

| メソッド | 返るもの |
|---|---|
| `c.json()` | JSON |
| `c.text()` | プレーンテキスト |
| **`c.html()`** | **HTML** |
| `c.redirect()` | 302 / 303 |
| `c.body()` | 任意（画像、CSV、PDF） |

**`c.json()` は数ある選択肢のひとつにすぎない。** Hono が API 専用に見えるのは、チュートリアルが `c.json()` から始まるから。

`index.ts` の `/api/hello` は最初から `c.text()` を使っていた。**すでに JSON 以外を返していた。**

### ★ `Content-Length` ではなく `Transfer-Encoding: chunked`

JSON は長さが確定してから送るので `Content-Length: 171`。`hono/html` は**ストリーミング**するので長さを決めずに送り出す。

大きなページでは、ブラウザが `<head>` の到着時点で CSS の読み込みを始められる。**JSON では原理的に得られない特性**（全部揃わないとパースできない）。

### ★ `html` タグは自動エスケープする

`${}` に入った値は HTML エスケープされる。プラン名が `<script>alert(1)</script>` でも `&lt;script&gt;` になって実行されない。

**これが XSS 対策。** 生の文字列連結で HTML を組み立てると、DB の中身がそのままスクリプトとして動く穴が開く。`html` タグを使う理由の半分はこれ（テンプレートリテラルを書くだけならタグは要らない）。

---

## 4. 判定基準 — 「その答えを誰が使うのか」

- 答えを使うのが**今まさに描いているページだけ** → SSR でいい
- 答えを使うのが**それ以外** → API にするしかない

「それ以外」は3つ。**別のマシン**（Webhook）、**読み込み済みページの JS**（部分更新）、**別のクライアント**（管理画面・アプリ）。

### 自分のエンドポイントを仕分けてみた

| エンドポイント | 答えを使うのは | 判定 |
|---|---|---|
| `GET /api/plans` | 初回表示のページだけ | ❌ **API である必要なし** |
| `GET /api/options` | 初回表示 + 金額再計算 | 🔺 微妙 |
| `GET /api/shipping/:prefecture` | 県を選んだ**瞬間**の JS | ⭕️ API |
| `GET /api/availability` | 日付を選ぶ**たび**の JS | ⭕️⭕️ **最も明確に API** |
| `POST /api/bookings` | フォーム送信 → 決済へ | ⭕️ |

**「全部 API にすべき」ではなかった。** `/api/plans` は SSR で十分だった。

---

## 5. それでも API にする、動かせない理由

### ★★ 決済 Webhook — 選択の余地がない

`bookings` に `status='HOLD'` と `expires_at`（30分後）を入れている以上、この先に必ず決済が来る。

Stripe に「支払いが完了したら教えて」と登録するとき、渡せるのは **URL だけ**。Astro のコンポーネントも SSR のページ関数も渡せない。

```
[Stripe] --- POST /api/webhooks/stripe ---> [Worker]
                                            status: HOLD → CONFIRMED
```

**ここには「ブラウザ」も「ページ」も登場しない。機械が機械を呼ぶ。** HTML を返す発想が最初から成り立たない領域。

> **この一点で、このプロジェクトに API 層は確定する。**

### `/api/availability` — 全ページ再読み込みでは成立しない

```
日付を選ぶ → 空いてる？ → 別の日付 → 泊数変更 → …
```

SSR だと毎回ページ全体が再読み込みされ、カレンダーの位置もオプションの選択もスクロール位置も飛ぶ。

返している `available` / `available_item_ids` / `lock_from` / `lock_to` は **「ページ」ではなく「問い合わせへの答え」**。返すべきものが最初からデータであって文書ではない。

### テストできる

`POST /api/bookings` は 280 行のロジックの塊。JSON in / JSON out なので **curl だけで全部検証できる**。409 の再現も curl 2本を同時に投げるだけ。

HTML を返す実装だと、レスポンスの HTML をパースして検証することになり、テストが格段に書きにくい。

> **JSON は人間だけでなくテストコードにとっても読みやすい。**

### 逆に払っているコスト（公平に）

| コスト | 具体例 |
|---|---|
| **検証ロジックの二重化** | `max_nights` チェックはフロントにも書くことになる。同じルールが2箇所 |
| **型の断絶** | レスポンスの型を変えてもフロントはコンパイルエラーにならない。実行時に `undefined` で気づく |
| **往復が増える** | HTML を取ってから JS が API を叩くので2往復 |
| **開発時のサーバーが2つ** | ← **詰まりポイント2の伏線** |

---

## 詰まったポイント集

### 1. `localhost:4321/plans-html` が 404

`web/astro.config.mjs`:

```js
vite: { server: { proxy: { '/api': 'http://localhost:8787' } } }
```

`pnpm dev` は**2つのサーバーを起動する**。

```
localhost:4321  ← Astro dev server（ブラウザで見ているのはこっち）
localhost:8787  ← wrangler dev（Hono が動いているのはこっち）
```

Astro は **`/api` で始まるリクエストだけ**を 8787 に転送する。`/plans-html` は転送されず Astro が 404 を返す。

> **皮肉:** 「`/api/` プレフィックスを付けないのが正しい命名」という判断が、そのまま原因になった。
> **命名の正しさとプロキシ設定は別問題。**

対処は `http://localhost:8787/plans-html` を直接開く。実験のために設定ファイルを触るのは割に合わない。

### 2. ★★ 7日前から動きっぱなしの `wrangler dev` が壊れていた

**ポートを直しても `curl` が一生返ってこない。**

```
curl -i http://localhost:8787/plans-html   → 無限に待つ
curl -i http://localhost:8787/api/hello    → これも返らない
```

`/api/hello` すら返らない = ルーティングの問題ではない。**プロセスを見に行った。**

```
$ ps -o pid,ppid,etime,command -p 98895,98930,4792

PID    PPID   ELAPSED       COMMAND
98895  98887  07-13:59:58   wrangler dev
98930  98895  07-13:59:57   workerd ... --socket-addr=entry=localhost:8787
 4792  98895  02-15:14:07   workerd ... --socket-addr=entry=127.0.0.1:0
```

**1つの `wrangler dev` が workerd を2つ抱えていた。**

- `98930` … 7日前に起動し、**`localhost:8787` を握っている**
- `4792` … 2日前に起動。`entry=127.0.0.1:0`（**ポート0 = 適当な空きポート**）

wrangler はファイル変更時に新しい workerd を立てて差し替える。その差し替えが失敗していて:

```
:8787 を握っているのは  → 7日前の workerd（誰も更新していない）
実際に動いているコードは → 2日前の workerd（8787 では待ち受けていない）
```

**7日間放置されて誰にも面倒を見られていない workerd を叩いていた。**

`ELAPSED` の `07-13:59:58` = 7日と約14時間。逆算すると **2026-08-23** — `record/03` の作業初日。**そのとき起動した `pnpm dev` を一度も止めていなかった。**

#### なぜ気づきにくいか

| | 状態 |
|---|---|
| プロセス | 生きている（`ps` に出る） |
| ポート | LISTEN している（`lsof` に出る） |
| ログ | エラーが出ない |

**「起動しているのに応答しない」ので、コードを疑い続けて時間を溶かす。** 実際、原因をプロキシ設定だと誤診しかけた。

#### 対処

```bash
pkill -f wrangler; pkill -f workerd
pnpm dev
```

> **`ELAPSED` が想定より桁違いに長かったら、それ自体が異常のサイン。**
> 今回は「7日」で気づけた。**dev サーバーは日をまたいだら一度落とす。**

---

## 副産物: `/api/plans` の `SELECT *` が `created_at` を漏らしている

実験中に JSON レスポンスを目視して気づいた。

```json
{"id":"morzh-4p", ..., "max_nights":7, "created_at":"2026-08-22 11:08:23"}
```

**クライアントが絶対に使わない `created_at` が返っている。**

`SELECT *` なので、テーブルにカラムを足すと**自動的にレスポンスに漏れる**。将来 `cost_price`（仕入れ値）や `internal_memo` を足したら、そのまま公開 API に出る。

HTML で返した側では表示カラムを明示的に選んでいたので、この事故は起きなかった。偶然だが示唆的。

`/api/options` は最初からカラムを明示していて、**`/api/plans` より一段良い設計だった。**

```sql
SELECT id, name, price, shipping_surcharge, max_quantity FROM options ...
```

> **レスポンスに何を含めるかは契約であり、DB のスキーマとは独立に決めるもの。**
> `SELECT *` はその決定をサボって、**DB のスキーマをそのまま外部に晒す。**

---

## 覚えたこと

### Hono

```ts
import { html } from "hono/html";

c.html(html`<h1>${title}</h1>`)   // 自動エスケープ + ストリーミング
c.text("...")                      // text/plain
c.redirect("/path", 303)           // PRG パターン用
```

### プロセスの診断

```bash
ps -o pid,ppid,etime,command -p <pid>        # ELAPSED = いつから動いているか
ps aux | grep -Ei "wrangler|workerd"
lsof -nP -iTCP -sTCP:LISTEN | grep workerd   # 誰がポートを握っているか
curl -m 10 ...                                # タイムアウトを付けて無限待ちを防ぐ
```

**`curl` にはとりあえず `-m` を付ける。** ハングと 404 は切り分けたい。

### MPA にするなら必要だったもの（今回は採用しなかった）

- **PRG（Post / Redirect / Get）** — POST の結果を直接 HTML で返すと、リロードで「再送信しますか？」が出て**二重予約が起きうる**。POST の後は必ずリダイレクトする
- **エラー時のフォーム再描画** — `c.json({error}, 400)` 一撃で済んでいたものが、「エラーメッセージ付き + 入力値保持でフォーム全体を描き直す」になる。`index.ts` のエラー返却は **10箇所**ある

---

## 現在地と残タスク

```
[✅] インフラ / 開発環境 / モノレポ / D1
[✅] スキーマ        8テーブル
[✅] 読み取りAPI     plans / options / shipping / availability
[✅] 予約作成        POST /api/bookings（HOLD まで）
[⬜] HOLD の失効処理  ← 予約のライフサイクルが片道のまま
[⬜] Stripe 連携
[⬜] 予約フォーム（フロント）
```

### 次: HOLD の失効処理（`record/03` から持ち越し）

`HOLD` を作る口はあるが、そこから出る道が `CONFIRMED` も `CANCELLED` も無い。`expires_at` に30分後を入れているのに、それを見る人が誰もいない。

**今やるのが一番安い。** 予約0件の今は実害がないが、Stripe 連携後は実データが入った状態で `item_days` を消す処理を書くことになる。そして失効処理は **Stripe の異常系（決済失敗・離脱）の受け皿**でもあるので、順番として先。

#### 設計の分岐 — Cron か遅延失効か

| | 定期実行（Cron Triggers） | 遅延失効（読むときに判定） |
|---|---|---|
| 仕組み | 5分ごとに期限切れ HOLD を掃除 | クエリのたびに期限切れを無視 / その場で掃除 |
| 在庫の正確さ | 最大5分ズレる | 常に正確 |
| 実装 | `wrangler.jsonc` の `triggers.crons` + `scheduled` ハンドラ | 既存クエリの条件追加 |
| 落とし穴 | ローカルで確認しづらい | `item_days` が残るので**主キー衝突が起きる** |

**409 判定が `item_days` の複合主キー違反に依存している**ため、遅延失効だけだと「期限切れなのに主キーで弾かれる」という噛み合わせの悪さが出る。**Cron で定期掃除しつつ、予約作成時に対象期間だけ先に掃除する**という併用も選択肢。

#### 新しく触ることになるもの

- **Cron Triggers** — HTTP 以外で Worker が起動する経路。`export default app` を `export default { fetch, scheduled }` の形に変える必要がある
- **`wrangler dev --test-scheduled`** — Cron はブラウザから叩けないので確認手段が別
- **削除を含むトランザクション** — `bookings` は履歴として残し、`item_days` だけ消す

### 積み残し

- `/api/plans` の `SELECT *`（**今回、実害が具体化した**）
- `/plans-html` の去就 — 実験用。役目を終えたら削除
- `GET /api/bookings/:id`（確認画面用）が未実装
- エラーハンドリングの共通化（`app.onError()`）
- バインディング名 `smachill_db` を大文字（`DB`）に揃えるか
- ローカル DB のテストデータ（`test-001` と 10/10 の予約）
  - → **失効処理の検証には、むしろ「期限切れ HOLD」を意図的に仕込むべき**（`record/03` の収穫そのまま）
- `not_found_handling` / `observability.enabled` / 独自ドメイン

---

## この回の収穫

**「作らない選択肢」を実際に動かして比較したこと。**

`/plans-html` を書くまで、「API を作らないと Web アプリは作れない」と思い込んでいた。実際に動かしてみると、**同じ SQL の最後の1行が違うだけ**だった。

そのうえで分かったのは:

- **API は「Web アプリに必要」なのではない。** 機械に呼ばれる口（Webhook）と、ページを再読み込みせずに答える口が要るからそうなる
- **自分の6本のうち、`/api/plans` は API である必要がなかった。** 一貫性のために揃える判断はアリだが、**「必要だから」ではなく「揃えるため」だと自覚して選ぶ**のとは違う
- 『Web API The Good Parts』は「JSON を返せ」という本ではなく、**「JSON を返すと決めたとき、その契約をどう設計するか」**の本

> **選択肢を1つしか知らない状態は「選んで」いない。**
> 比較対象を実際に動かして初めて、いま採っている構成が判断になる。

そして、その実験の最大の障害が **7日前から壊れていた dev サーバー**だったのは示唆的だった。

> **動かないとき、まず疑うべきは自分のコードとは限らない。**
> `ELAPSED` を見る、`lsof` でポートの持ち主を見る——**環境そのものを診断する手札**を持っておく。
