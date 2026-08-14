# Single stage on purpose: there is nothing to compile, and a builder stage that
# only runs `pip install` for four pure-Python deps buys nothing but a second layer
# cache to invalidate. (Amber's image IS multi-stage — she pulls git dependencies,
# so her builder needs git that her runtime must not carry.)
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    SYNC_STORE_DB_PATH=/data/sync-store.db

# sqlite3 is here for backup/backup-sqlite.sh, which runs `.backup` INSIDE the
# container: a `cp` of a WAL-mode database is a corrupt snapshot, not a backup.
RUN apt-get update \
 && apt-get install -y --no-install-recommends sqlite3 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /srv
COPY pyproject.toml README.md ./
COPY app ./app
RUN pip install .

RUN useradd --system --uid 10001 --no-create-home sync \
 && mkdir -p /data \
 && chown sync:sync /data
USER sync

VOLUME ["/data"]
EXPOSE 8080

# python -c, not curl: the slim image has no curl, and adding one is ~10MB for a
# job the interpreter already does. Hitting /health rather than opening a socket,
# because /health touches the database — an unlinked db file should mean unhealthy.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import sys,urllib.request as u; sys.exit(0 if u.urlopen('http://127.0.0.1:8080/health', timeout=2).status == 200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
