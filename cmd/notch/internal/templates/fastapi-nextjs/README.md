# __NAME__

FastAPI + Next.js + Postgres, scaffolded by `notch new` and deployed on Notch.

- `backend/`: FastAPI under `/api`, Postgres via `DATABASE_URL` (Notch sets it).
- `frontend/`: Next.js at `/`, calls `/api` on the same host.

Notch builds each Dockerfile into one service and routes `/` and `/api` on
`http://__NAME__.notch.localhost:8080`. Redeploy after changes:

```bash
notch add <path-to-this-repo> --name __NAME__ --postgres
```
