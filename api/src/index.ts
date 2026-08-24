import { Hono } from "hono";

const app = new Hono<{ Bindings: CloudflareBindings }>();

const MS_PER_DAY = 86400000; // 1日のミリ秒数

// 'YYYY-MM-DD' を n 日ずらして 'YYYY-MM-DD' で返す（n が負なら過去へ）
function addDays(dateStr: string, n: number): string {
  const d = new Date(dateStr);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

// 2つの日付の差を日数で返す
function diffDays(from: string, to: string): number {
  return (new Date(to).getTime() - new Date(from).getTime()) / MS_PER_DAY;
}

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

// 'YYYY-MM-DD' として妥当か（2026-02-31 のような存在しない日付も弾く）
function isValidDate(s: string): boolean {
  if (!DATE_RE.test(s)) return false;
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) return false;
  return d.toISOString().slice(0, 10) === s;
}
// 今日の日付を 'YYYY-MM-DD' で返す
function today(): string {
  return new Date().toISOString().slice(0, 10);
}

// from 〜 to（両端含む）の日付を 'YYYY-MM-DD' の配列で返す。from > to なら空配列
function dateRange(from: string, to: string): string[] {
  const out: string[] = [];
  for (let d = from; d <= to; d = addDays(d, 1)) out.push(d);
  return out;
}

app.get("/api/hello", (c) => {
  return c.text("Hello Hono!");
});

app.get("/api/plans", async (c) => {
  const { results } = await c.env.smachill_db
    .prepare("SELECT * FROM plans")
    .all();
  return c.json(results);
});

app.get("/api/options", async (c) => {
  const { results } = await c.env.smachill_db
    .prepare(
      "SELECT id, name, price, shipping_surcharge, max_quantity FROM options WHERE status = 'AVAILABLE' ORDER BY sort_order",
    )
    .all();
  return c.json(results);
});

app.get("/api/shipping/:prefecture", async (c) => {
  const prefecture = c.req.param("prefecture");

  const zone = await c.env.smachill_db
    .prepare(
      "SELECT prefecture, days, fee FROM shipping_zones WHERE prefecture = ?",
    )
    .bind(prefecture)
    .first();

  if (zone === null) {
    return c.json({ error: "配送対象外の地域です", prefecture }, 404);
  }

  return c.json(zone);
});

app.get("/api/availability", async (c) => {
  const use_start = c.req.query("use_start");
  const use_end = c.req.query("use_end");
  const prefecture = c.req.query("prefecture");
  const plan_id = c.req.query("plan_id");

  // ① 必須
  if (!use_start || !use_end || !prefecture || !plan_id) {
    return c.json(
      { error: "use_start, use_end, prefecture, plan_id は必須です" },
      400,
    );
  }

  // ② 日付の形式
  if (!isValidDate(use_start) || !isValidDate(use_end)) {
    return c.json(
      { error: "日付は YYYY-MM-DD 形式の実在する日付で指定してください" },
      400,
    );
  }

  // ③ 前後関係
  const nights = diffDays(use_start, use_end) + 1;
  if (nights < 1) {
    return c.json(
      { error: "use_end は use_start 以降の日付を指定してください" },
      400,
    );
  }

  // ④ 過去の日付
  if (use_start < today()) {
    return c.json({ error: "過去の日付は指定できません" }, 400);
  }

  // ⑤ プランの存在確認と泊数の上限
  const plan = await c.env.smachill_db
    .prepare("SELECT id, max_nights FROM plans WHERE id = ?")
    .bind(plan_id)
    .first<{ id: string; max_nights: number | null }>();

  if (plan === null) {
    return c.json({ error: "プランが見つかりません", plan_id }, 404);
  }

  if (plan.max_nights !== null && nights > plan.max_nights) {
    return c.json(
      { error: `レンタルは最大${plan.max_nights}泊までです`, nights },
      400,
    );
  }

  // ⑥ 配送ゾーン
  const zone = await c.env.smachill_db
    .prepare(
      "SELECT prefecture, days, fee FROM shipping_zones WHERE prefecture = ?",
    )
    .bind(prefecture)
    .first<{ prefecture: string; days: number; fee: number }>();

  if (zone === null) {
    return c.json({ error: "配送対象外の地域です", prefecture }, 404);
  }

  // ⑦ 空き判定
  const lock_from = addDays(use_start, -zone.days);
  const lock_to = addDays(use_end, zone.days);

  const { results } = await c.env.smachill_db
    .prepare(
      `SELECT id FROM inventory_items
       WHERE plan_id = ?
         AND status = 'AVAILABLE'
         AND id NOT IN (
           SELECT inventory_item_id FROM item_days WHERE date BETWEEN ? AND ?
         )`,
    )
    .bind(plan_id, lock_from, lock_to)
    .all<{ id: string }>();

  const available_item_ids = results.map((row) => row.id);

  return c.json({
    use_start,
    use_end,
    nights,
    prefecture,
    shipping_days: zone.days,
    lock_from,
    lock_to,
    available: available_item_ids.length > 0,
    available_item_ids,
  });
});

type OptionInput = { option_id: string; quantity: number };

type BookingBody = {
  plan_id?: string;
  use_start?: string;
  use_end?: string;
  prefecture?: string;
  options?: OptionInput[];
  address?: string;
  customer_name?: string;
  customer_email?: string;
};

app.post("/api/bookings", async (c) => {
  const db = c.env.smachill_db;

  // ① リクエストボディの読み取り
  let body: BookingBody;
  try {
    body = await c.req.json<BookingBody>();
  } catch {
    return c.json({ error: "JSON の形式が正しくありません" }, 400);
  }

  const { plan_id, use_start, use_end, prefecture } = body;
  const optionInputs = body.options ?? [];

  if (!plan_id || !use_start || !use_end || !prefecture) {
    return c.json(
      { error: "plan_id, use_start, use_end, prefecture は必須です" },
      400,
    );
  }
  if (!Array.isArray(optionInputs)) {
    return c.json({ error: "options は配列で指定してください" }, 400);
  }

  // ② 日付の検証（availability と同じ規則）
  if (!isValidDate(use_start) || !isValidDate(use_end)) {
    return c.json(
      { error: "日付は YYYY-MM-DD 形式の実在する日付で指定してください" },
      400,
    );
  }

  const nights = diffDays(use_start, use_end) + 1;
  if (nights < 1) {
    return c.json(
      { error: "use_end は use_start 以降の日付を指定してください" },
      400,
    );
  }
  if (use_start < today()) {
    return c.json({ error: "過去の日付は指定できません" }, 400);
  }

  // ③ プラン
  const plan = await db
    .prepare(
      "SELECT id, base_price, nights, extra_night_price, max_nights FROM plans WHERE id = ?",
    )
    .bind(plan_id)
    .first<{
      id: string;
      base_price: number;
      nights: number;
      extra_night_price: number;
      max_nights: number | null;
    }>();

  if (plan === null) {
    return c.json({ error: "プランが見つかりません", plan_id }, 404);
  }
  if (plan.max_nights !== null && nights > plan.max_nights) {
    return c.json(
      { error: `レンタルは最大${plan.max_nights}泊までです`, nights },
      400,
    );
  }

  // ④ 配送ゾーン
  const zone = await db
    .prepare("SELECT prefecture, days, fee FROM shipping_zones WHERE prefecture = ?")
    .bind(prefecture)
    .first<{ prefecture: string; days: number; fee: number }>();

  if (zone === null) {
    return c.json({ error: "配送対象外の地域です", prefecture }, 404);
  }

  // ⑤ オプションの検証と金額の積み上げ
  //    価格はリクエストの値を信用せず、必ずマスタから引き直す
  const { results: optionRows } = await db
    .prepare(
      "SELECT id, price, shipping_surcharge, max_quantity FROM options WHERE status = 'AVAILABLE'",
    )
    .all<{
      id: string;
      price: number;
      shipping_surcharge: number;
      max_quantity: number;
    }>();

  const optionMaster = new Map(optionRows.map((o) => [o.id, o]));
  const seen = new Set<string>();
  const optionLines: {
    option_id: string;
    quantity: number;
    unit_price: number;
    unit_shipping_surcharge: number;
  }[] = [];

  let options_amount = 0;
  let option_shipping = 0;

  for (const input of optionInputs) {
    const master = optionMaster.get(input?.option_id);
    if (!master) {
      return c.json(
        { error: "指定のオプションは利用できません", option_id: input?.option_id },
        400,
      );
    }
    if (seen.has(master.id)) {
      return c.json(
        { error: "同じオプションが重複しています", option_id: master.id },
        400,
      );
    }
    seen.add(master.id);

    if (!Number.isInteger(input.quantity) || input.quantity < 1) {
      return c.json(
        { error: "個数は1以上の整数で指定してください", option_id: master.id },
        400,
      );
    }
    if (input.quantity > master.max_quantity) {
      return c.json(
        {
          error: `${master.id} は最大${master.max_quantity}個までです`,
          option_id: master.id,
        },
        400,
      );
    }

    options_amount += master.price * input.quantity;
    option_shipping += master.shipping_surcharge * input.quantity;
    optionLines.push({
      option_id: master.id,
      quantity: input.quantity,
      unit_price: master.price,
      unit_shipping_surcharge: master.shipping_surcharge,
    });
  }

  // ⑥ 金額の確定（すべてサーバー側で計算する）
  const extra_nights = Math.max(0, nights - plan.nights);
  const base_amount = plan.base_price + extra_nights * plan.extra_night_price;
  const shipping_fee = zone.fee + option_shipping;
  const total_amount = base_amount + options_amount + shipping_fee;

  // ⑦ 空き個体を1つ選ぶ
  const lock_from = addDays(use_start, -zone.days);
  const lock_to = addDays(use_end, zone.days);

  const { results: freeItems } = await db
    .prepare(
      `SELECT id FROM inventory_items
       WHERE plan_id = ?
         AND status = 'AVAILABLE'
         AND id NOT IN (
           SELECT inventory_item_id FROM item_days WHERE date BETWEEN ? AND ?
         )
       ORDER BY id
       LIMIT 1`,
    )
    .bind(plan_id, lock_from, lock_to)
    .all<{ id: string }>();

  if (freeItems.length === 0) {
    return c.json(
      { error: "指定の期間は空きがありません", lock_from, lock_to },
      409,
    );
  }
  const inventory_item_id = freeItems[0].id;

  // ⑧ 占有台帳に入れる行を組み立てる
  const itemDays = [
    ...dateRange(lock_from, addDays(use_start, -1)).map((date) => ({
      date,
      kind: "SHIP_OUT",
    })),
    ...dateRange(use_start, use_end).map((date) => ({ date, kind: "USE" })),
    ...dateRange(addDays(use_end, 1), lock_to).map((date) => ({
      date,
      kind: "SHIP_BACK",
    })),
  ];

  // ⑨ すべてまとめて1つのトランザクションで書き込む
  const booking_id = crypto.randomUUID();

  const statements = [
    db
      .prepare(
        `INSERT INTO bookings (
           id, status, plan_id, use_start, use_end, prefecture,
           address, customer_name, customer_email,
           base_amount, options_amount, shipping_fee, total_amount, expires_at
         ) VALUES (?, 'HOLD', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now', '+30 minutes'))`,
      )
      .bind(
        booking_id,
        plan_id,
        use_start,
        use_end,
        prefecture,
        body.address ?? null,
        body.customer_name ?? null,
        body.customer_email ?? null,
        base_amount,
        options_amount,
        shipping_fee,
        total_amount,
      ),

    db
      .prepare(
        "INSERT INTO booking_items (booking_id, inventory_item_id) VALUES (?, ?)",
      )
      .bind(booking_id, inventory_item_id),

    ...optionLines.map((line) =>
      db
        .prepare(
          `INSERT INTO booking_options
             (booking_id, option_id, quantity, unit_price, unit_shipping_surcharge)
           VALUES (?, ?, ?, ?, ?)`,
        )
        .bind(
          booking_id,
          line.option_id,
          line.quantity,
          line.unit_price,
          line.unit_shipping_surcharge,
        ),
    ),

    ...itemDays.map((row) =>
      db
        .prepare(
          "INSERT INTO item_days (inventory_item_id, date, booking_id, kind) VALUES (?, ?, ?, ?)",
        )
        .bind(inventory_item_id, row.date, booking_id, row.kind),
    ),
  ];

  try {
    await db.batch(statements);
  } catch (e) {
    // item_days の複合主キー違反 = 直前に別の予約が同じ日を押さえた
    console.error("booking failed", e);
    return c.json(
      { error: "指定の期間は空きがありません（他の予約と競合しました）" },
      409,
    );
  }

  return c.json(
    {
      booking_id,
      status: "HOLD",
      plan_id,
      use_start,
      use_end,
      nights,
      prefecture,
      shipping_days: zone.days,
      lock_from,
      lock_to,
      inventory_item_id,
      options: optionLines,
      base_amount,
      options_amount,
      shipping_fee,
      total_amount,
    },
    201,
  );
});

export default app;
