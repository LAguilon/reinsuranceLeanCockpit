# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Stage 1 — build the kernel-checked engine and refuse to ship a broken image
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS lean-builder

# The Debian mirror occasionally serves a truncated package; retry once from a
# clean cache rather than failing the whole image on a transient hash mismatch.
RUN set -eux; \
    # HTTPS: some environments front deb.debian.org with a proxy that truncates
    # large .debs over plain HTTP (hash-sum mismatch). TLS avoids it.
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; do \
      [ -f "$f" ] && sed -i 's|http://deb.debian.org|https://deb.debian.org|' "$f" || true; \
    done; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl git ca-certificates build-essential \
      || (apt-get clean && apt-get update && apt-get install -y --fix-missing --no-install-recommends \
            curl git ca-certificates build-essential); \
    rm -rf /var/lib/apt/lists/*

ENV ELAN_HOME=/root/.elan
RUN curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
      | sh -s -- -y --default-toolchain none
ENV PATH=/root/.elan/bin:$PATH

WORKDIR /app
COPY lean-toolchain lakefile.toml ./
RUN elan toolchain install "$(cat lean-toolchain)"

COPY . .
RUN lake build
RUN python3 scripts/generate_sample_pdfs.py
# The image cannot be produced unless every theorem passes with zero sorryAx.
RUN python3 scripts/paranoid_audit.py

# ---------------------------------------------------------------------------
# Stage 2 — runtime
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS runtime

RUN useradd --create-home --shell /usr/sbin/nologin app
WORKDIR /app

COPY --from=lean-builder /app/.lake/build/bin/cockpit /app/.lake/build/bin/cockpit
COPY --from=lean-builder /app/server ./server
COPY --from=lean-builder /app/web ./web
COPY --from=lean-builder /app/examples ./examples
COPY --from=lean-builder /app/docs ./docs
COPY --from=lean-builder /app/scripts ./scripts

USER app
ENV HOST=0.0.0.0 PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/api/health')"
CMD ["python3", "server/app.py"]
