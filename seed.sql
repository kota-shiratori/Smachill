-- 開発用の初期データ
-- 実行: npx wrangler d1 execute smachill-db --local --file=seed.sql
--
-- INSERT OR REPLACE を使っているので、何度流し直しても同じ状態になる（冪等）。
-- 外部キーがあるため、親（plans）→ 子（inventory_items）の順で並べること。

-- ─────────────────────────────────────────
-- プランマスタ
-- ─────────────────────────────────────────
-- created_at は DEFAULT (datetime('now')) があるので省略できる
INSERT OR REPLACE INTO plans (id, name, capacity, base_price, nights) VALUES
  ('morzh-4p', 'MORZH 4人用',      4, 30000, 2),
  ('morzh-6p', 'MORZH 6人用',      6, 38000, 2),
  ('solo-1p',  'ソロサウナ 1人用', 1, 18000, 2);

-- ─────────────────────────────────────────
-- 物理個体マスタ
-- ─────────────────────────────────────────
-- 同一プランに複数個体を持たせる。1個体しかないと
-- 「1件予約したら即満室」になり、在庫の割り当てロジックを検証できない。
--
-- MORZH-003 だけ MAINTENANCE にしてある。
-- 「故障中の個体は予約可能枠に出さない」というフィルタの動作確認用。
INSERT OR REPLACE INTO inventory_items (id, plan_id, status) VALUES
  ('MORZH-001', 'morzh-4p', 'AVAILABLE'),
  ('MORZH-002', 'morzh-4p', 'AVAILABLE'),
  ('MORZH-003', 'morzh-4p', 'MAINTENANCE'),
  ('MORZH-101', 'morzh-6p', 'AVAILABLE'),
  ('MORZH-102', 'morzh-6p', 'AVAILABLE'),
  ('SOLO-001',  'solo-1p',  'AVAILABLE'),
  ('SOLO-002',  'solo-1p',  'AVAILABLE');

-- ─────────────────────────────────────────
-- 配送ゾーン
-- ─────────────────────────────────────────
-- days は片道日数。往復の占有日数の計算に使う（出荷 + 利用 + 返送）。
-- fee は往復送料。
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
-- bookings / booking_items / item_days は意図的に空のまま
-- ─────────────────────────────────────────
-- これらはアプリが予約のたびに作るトランザクションデータ。
-- 初期状態が空であることが正しい。
