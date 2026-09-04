-- 開発用の初期データ
-- 実行: npx wrangler d1 execute smachill-db --local --file=seed.sql
--
-- INSERT OR REPLACE を使っているので、何度流し直しても同じ状態になる（冪等）。
-- 外部キーがあるため、親（plans）→ 子（inventory_items）の順で並べること。
--
-- ※ 名称・価格・送料はすべて仮の値。実際のサービス内容に合わせて書き換えること。

-- ─────────────────────────────────────────
-- プランマスタ
-- ─────────────────────────────────────────
-- 現状はプラン1つ。base_price は included_days(2日) ぶんを含む。
-- 3日目以降は extra_day_price を日数ぶん加算する。
-- 日帰り（1日）でも base_price を下回らない ＝ 実質これが最低料金になる。
-- max_days は受付上限。NULL にすれば無制限。
-- turnaround_days は返送到着後の乾燥・整備日数。
INSERT OR REPLACE INTO plans
  (id, name, capacity, base_price, included_days, extra_day_price, max_days, turnaround_days) VALUES
  ('morzh-4p', 'MORZH テントサウナ', 4, 30000, 2, 8000, 7, 1);

-- ─────────────────────────────────────────
-- 物理個体マスタ
-- ─────────────────────────────────────────
-- 現状は実機1台。
-- 2台目を導入したら行を足すだけでよい（item_days の占有台帳がそのまま機能する）。
INSERT OR REPLACE INTO inventory_items (id, plan_id, status) VALUES
  ('MORZH-001', 'morzh-4p', 'AVAILABLE');

-- ─────────────────────────────────────────
-- 配送ゾーン（v1 は関東〜東海）
-- ─────────────────────────────────────────
-- days は片道日数。往復の占有日数の計算に使う（出荷 + 利用 + 返送 + 整備）。
-- fee はサウナ本体ぶんの往復送料。オプションぶんは options.shipping_surcharge で加算する。
--
-- 実機1台なので、遠方を受けるほど1件あたりの拘束日数が伸びて月の回転数が落ちる。
-- v1 は SEO の主戦場（関東）＋隣接の東海までに絞る。ここに無い都道府県は 404 = 対象外。
-- 山梨県は関東でも東海でもないが、富士五湖のキャンプ需要があるため含めた。外すなら1行削るだけ。
INSERT OR REPLACE INTO shipping_zones (prefecture, days, fee) VALUES
  ('東京都',   1,  8000),
  ('神奈川県', 1,  8000),
  ('千葉県',   1,  8000),
  ('埼玉県',   1,  8000),
  ('茨城県',   1,  8000),
  ('栃木県',   1,  9000),
  ('群馬県',   1,  9000),
  ('山梨県',   2, 10000),
  ('静岡県',   2, 12000),
  ('愛知県',   2, 12000),
  ('岐阜県',   2, 12000),
  ('三重県',   2, 12000);

-- ─────────────────────────────────────────
-- オプションマスタ
-- ─────────────────────────────────────────
-- price は「1個あたり・1レンタルにつき固定」。日数を掛けない。
-- shipping_surcharge は1個あたりの往復送料加算。同梱で済むものは 0。
-- max_quantity は1予約あたりの上限個数。
--
-- coffee-kit を UNAVAILABLE にしてある。
-- 「提供停止中のオプションは選択肢に出さない」フィルタの動作確認用。
INSERT OR REPLACE INTO options (id, name, price, shipping_surcharge, max_quantity, status, sort_order) VALUES
  ('chair',       'アウトドアチェア',   2000, 1000, 4, 'AVAILABLE',   10),
  ('poncho',      'サウナポンチョ',     1500,    0, 4, 'AVAILABLE',   20),
  ('firewood',    '薪 追加1束',         3000,  500, 3, 'AVAILABLE',   30),
  ('coffee-kit',  'コーヒー器具セット', 2500,    0, 1, 'UNAVAILABLE', 40);

-- ─────────────────────────────────────────
-- bookings / booking_items / booking_options / item_days は意図的に空のまま
-- ─────────────────────────────────────────
-- これらはアプリが予約のたびに作るトランザクションデータ。
-- 初期状態が空であることが正しい。
