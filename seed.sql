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
-- 現状はプラン1つ。base_price は nights(2泊) ぶんを含む。
-- 3泊目以降は extra_night_price を泊数ぶん加算する。
-- max_nights は受付上限。NULL にすれば無制限。
INSERT OR REPLACE INTO plans (id, name, capacity, base_price, nights, extra_night_price, max_nights) VALUES
  ('morzh-4p', 'MORZH テントサウナ', 4, 30000, 2, 8000, 7);

-- ─────────────────────────────────────────
-- 物理個体マスタ
-- ─────────────────────────────────────────
-- 現状は実機1台。
-- 2台目を導入したら行を足すだけでよい（item_days の占有台帳がそのまま機能する）。
INSERT OR REPLACE INTO inventory_items (id, plan_id, status) VALUES
  ('MORZH-001', 'morzh-4p', 'AVAILABLE');

-- ─────────────────────────────────────────
-- 配送ゾーン
-- ─────────────────────────────────────────
-- days は片道日数。往復の占有日数の計算に使う（出荷 + 利用 + 返送）。
-- fee はサウナ本体ぶんの往復送料。オプションぶんは options.shipping_surcharge で加算する。
-- 全47都道府県は不要。距離の異なる代表例だけあれば計算ロジックは検証できる。
INSERT OR REPLACE INTO shipping_zones (prefecture, days, fee) VALUES
  ('東京都',   1,  8000),
  ('千葉県',   1,  8000),
  ('神奈川県', 1,  8000),
  ('埼玉県',   1,  8000),
  ('静岡県',   2, 12000),
  ('愛知県',   2, 12000),
  ('大阪府',   2, 14000),
  ('福岡県',   3, 18000),
  ('北海道',   3, 20000);

-- ─────────────────────────────────────────
-- オプションマスタ
-- ─────────────────────────────────────────
-- price は「1個あたり・1レンタルにつき固定」。泊数を掛けない。
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
