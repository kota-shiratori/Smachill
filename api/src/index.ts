import { Hono } from "hono";

const app = new Hono<{ Bindings: CloudflareBindings }>();

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

export default app;
