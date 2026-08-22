-- 表示用プランマスタ
CREATE TABLE plans (
  id          TEXT PRIMARY KEY,      -- 'morzh-4p'
  name        TEXT NOT NULL,         -- 'MORZH 4人用'
  capacity    INTEGER NOT NULL,
  base_price  INTEGER NOT NULL,      -- 円・税込。nights 泊ぶんを含んだ基本料金
  nights      INTEGER NOT NULL,      -- base_price に含まれる標準レンタル泊数
  extra_night_price INTEGER NOT NULL, -- nights を超えた分、1泊あたりの追加料金
  max_nights  INTEGER,               -- 受付可能な最大泊数。NULL なら上限なし
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

-- 物理個体マスタ（同一プランでも個体で管理する）
CREATE TABLE inventory_items (
  id       TEXT PRIMARY KEY,         -- 'MORZH-001'
  plan_id  TEXT NOT NULL REFERENCES plans(id),
  status   TEXT NOT NULL             -- AVAILABLE / MAINTENANCE / RETIRED
);

-- 都道府県 → 片道配送日数・送料
CREATE TABLE shipping_zones (
  prefecture TEXT PRIMARY KEY,       -- '千葉県'
  days       INTEGER NOT NULL,       -- 片道日数
  fee        INTEGER NOT NULL        -- 往復送料（円）。サウナ本体ぶん
);

-- オプションマスタ（チェア・コーヒー器具など）
-- 単品貸しは行わない前提。必ずサウナ本体と一緒に発送される。
-- サウナが1台＝同時進行の予約は1件なので、日付単位の在庫管理は不要。
CREATE TABLE options (
  id                 TEXT PRIMARY KEY,  -- 'chair', 'coffee-kit'
  name               TEXT NOT NULL,
  price              INTEGER NOT NULL,  -- 1個あたり・1レンタルにつき固定（泊数と無関係）
  shipping_surcharge INTEGER NOT NULL DEFAULT 0,  -- 1個あたりの往復送料加算（円）
  max_quantity       INTEGER NOT NULL DEFAULT 1,  -- 1予約あたりの上限個数
  status             TEXT NOT NULL,     -- AVAILABLE / UNAVAILABLE
  sort_order         INTEGER NOT NULL DEFAULT 0,  -- 画面表示順
  created_at         TEXT NOT NULL DEFAULT (datetime('now'))
);

-- 予約トランザクション
CREATE TABLE bookings (
  id            TEXT PRIMARY KEY,
  status        TEXT NOT NULL,       -- HOLD / PAID / CANCELLED
  plan_id       TEXT NOT NULL REFERENCES plans(id),
  use_start     TEXT NOT NULL,       -- YYYY-MM-DD
  use_end       TEXT NOT NULL,
  prefecture    TEXT NOT NULL REFERENCES shipping_zones(prefecture),
  address       TEXT,                -- PAID確定時までNULL可
  customer_name TEXT,
  customer_email TEXT,

  -- 金額の内訳。すべてサーバー計算値で、確定時点の値を保存する。
  -- 「あとで計算し直せばいい」は成立しない。マスタの価格が変われば再現できないため。
  base_amount    INTEGER NOT NULL,   -- プラン基本料金 + 延長料金
  options_amount INTEGER NOT NULL,   -- オプション合計
  shipping_fee   INTEGER NOT NULL,   -- 送料合計（zones.fee + オプション加算）
  total_amount   INTEGER NOT NULL,   -- 上3つの合計。AIは計算しない

  weather_note  TEXT,                -- 天候リスクの所見（7日以内のみ）
  expires_at    TEXT,                -- HOLD の失効時刻（作成+30分）
  stripe_session_id TEXT UNIQUE,
  created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

-- 予約に引き当てた具体的な物理個体
CREATE TABLE booking_items (
  booking_id        TEXT NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  inventory_item_id TEXT NOT NULL REFERENCES inventory_items(id),
  PRIMARY KEY (booking_id, inventory_item_id)
);

-- 予約に付けたオプション
-- unit_price / unit_shipping_surcharge は予約成立時点の値を焼き付ける。
-- options マスタを値上げしても、過去の予約の請求額が変わってはいけないため。
CREATE TABLE booking_options (
  booking_id              TEXT NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  option_id               TEXT NOT NULL REFERENCES options(id),
  quantity                INTEGER NOT NULL CHECK (quantity > 0),
  unit_price              INTEGER NOT NULL,
  unit_shipping_surcharge INTEGER NOT NULL,
  PRIMARY KEY (booking_id, option_id)
);

-- ★ 個体 × 日付 の占有台帳。このテーブルが二重予約を物理的に不可能にする
CREATE TABLE item_days (
  inventory_item_id TEXT NOT NULL REFERENCES inventory_items(id),
  date              TEXT NOT NULL,   -- YYYY-MM-DD
  booking_id        TEXT NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  kind              TEXT NOT NULL,   -- SHIP_OUT / USE / SHIP_BACK
  PRIMARY KEY (inventory_item_id, date)
);
CREATE INDEX idx_item_days_booking ON item_days(booking_id);
CREATE INDEX idx_item_days_date    ON item_days(date);   -- 空き日検索用
