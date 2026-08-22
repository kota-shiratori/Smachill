import { Hono } from 'hono'

const app = new Hono<{ Bindings: CloudflareBindings }>()

app.get('/api/hello', (c) => {
  return c.text('Hello Hono!')
})

app.get('/api/plans', async (c) => {
  const { results } = await c.env.smachill_db.prepare('SELECT * FROM plans').all()
  return c.json(results)
})

export default app
