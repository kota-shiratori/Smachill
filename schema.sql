-- 表示用プランマスタ
CREATE TABLE plans (
  id          TEXT PRIMARY KEY,      -- 'morzh-4p'
  name        TEXT NOT NULL,         -- 'MORZH 4人用'
  capacity    INTEGER NOT NULL,
  base_price  INTEGER NOT NULL,      -- 円・税込
  nights      INTEGER NOT NULL,      -- 標準レンタル泊数
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
  fee        INTEGER NOT NULL        -- 往復送料（円）
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
  total_amount  INTEGER NOT NULL,    -- サーバー計算値。AIは計算しない
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

-- ★ 個体 × 日付 の占有台帳。このテーブルが二重予約を物理的に不可能にする
CREATE TABLE item_days (
  inventory_item_id TEXT NOT NULL REFERENCES inventory_items(id),
  date              TEXT NOT NULL,   -- YYYY-MM-DD
  booking_id        TEXT NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  kind              TEXT NOT NULL,   -- SHIP_OUT / USE / SHIP_BACK
  PRIMARY KEY (inventory_item_id, date)
);
CREATE INDEX idx_item_days_booking ON item_days(booking_id);
