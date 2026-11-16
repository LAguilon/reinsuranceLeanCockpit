# Deploying the ReinsuranceLean Cockpit — v1.1.0

The cockpit is a single Python process plus one compiled Lean binary. There is
no database, no Node build step, and no third-party service. That makes it cheap
to host and hard to misconfigure.

---

## Run it locally (one command)

```bash
lake build && python3 server/app.py
# → http://localhost:8080
```

If `lake` is not installed, install it once with:

```bash
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y
```

The server rebuilds `cockpit` on startup if the binary is missing, so a fresh
clone with only Python will still come up — it will simply take a minute longer.

---

## Deploy to Render (free tier, ~5 minutes)

1. Push this repository to GitHub.
2. In Render: **New → Blueprint**, point at the repository. Render reads
   `render.yaml` and builds the `Dockerfile`.
3. Wait for the first build. The image build runs `lake build` **and**
   `python3 scripts/paranoid_audit.py`, so a deployment cannot succeed unless
   every theorem still checks out.
4. Open the service URL. `GET /api/health` is the health check.

Free instances sleep after inactivity; the first request afterwards takes a few
seconds to wake.

---

## Deploy to Fly.io (~5 minutes)

```bash
fly launch --no-deploy --dockerfile Dockerfile
fly deploy
```

`fly.toml` needs only:

```toml
[http_service]
  internal_port = 8080
  force_https = true
```

Fly builds the same multi-stage image. Set `HOST=0.0.0.0` and `PORT=8080`
(the Dockerfile already does).

---

## Deploy to Railway

1. **New Project → Deploy from GitHub repo.**
2. Railway detects the `Dockerfile` automatically.
3. Set the service port to `8080`.

No environment variables are required.

---

## Deploy to a VPS (any $5 box)

```bash
# on the server
git clone <repo> && cd reinsuranceLeanCockpit
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y
export PATH=$HOME/.elan/bin:$PATH
lake build
python3 scripts/paranoid_audit.py      # optional but recommended
HOST=127.0.0.1 PORT=8080 python3 server/app.py
```

Put nginx or Caddy in front for TLS. Caddy is one line:

```
cockpit.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

---

## Build the image yourself

```bash
docker build -t reinsurance-lean-cockpit:v1.0.0 .
docker run --rm -p 8080:8080 reinsurance-lean-cockpit:v1.0.0
```

The build is two stages:

* **lean-builder** installs elan, builds the library, generates the sample PDFs,
  and runs the paranoid audit. A failing proof fails the image build.
* **runtime** copies only the compiled binary, the Python server, the static
  front end, the examples and the docs. It runs as a non-root user and exposes
  `8080`.

Expect the first build to take several minutes (Lean toolchain download); later
builds reuse the Docker layer cache.

---

## Operational notes

| Concern | Behaviour |
|---|---|
| Stale assets after deploy | every response carries `Cache-Control: no-store` |
| Oversized uploads | rejected with `413` above 2 MB, body drained so the client sees it |
| XML entity attacks | `DOCTYPE`/`ENTITY` rejected with `400` before parsing |
| Path traversal | static paths resolved and confined to `web/` |
| Memory | the Lean binary is ~230 MB on disk, a few MB resident per request |
| Concurrency | `ThreadingHTTPServer`; each request spawns one short-lived Lean process |
| Secrets | none required; `OPENAI_API_KEY` is optional and only annotates intake |
| Audit ledger | SQLite at `data/cockpit_audit.db`; mount a volume to persist the hash chain across restarts |
| CI | `.github/workflows/ci.yml` builds and runs all four gates on every push |

### Verifying a deployment

```bash
curl -s https://your-host/api/health
curl -s -X POST https://your-host/api/executive-summary -d '{}' -H 'Content-Type: application/json' | head -c 400
```

The second call returns the desk roll-up: 980,000 USD of leakage prevented on
the sample book. If it does, the binary, the Python layer and the static front
end are all alive.
