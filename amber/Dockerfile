# Amber's image.
#
# The canonical copy of this file lives in amber-infra/amber/Dockerfile; an
# identical copy is committed to the amber repo because a Docker build context has
# to contain the source. Change them together.
#
# MULTI-STAGE, and that is not optional here (sync-store's single stage is). Amber's
# pyproject pins agent-runtime and agent-mcp-py as `git+https` URLs, so pip needs
# git at build time — and a runtime image carrying git and a package index cache for
# no reason is a worse image. The builder resolves everything into a venv; the
# runtime stage copies the venv and nothing else.
#
# No ffmpeg: STT and TTS are HTTP calls to OpenAI, not local audio processing. If
# that ever changes, this is the line that has to change with it.

FROM python:3.11-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /build
COPY pyproject.toml README.md ./
COPY app ./app
# One RUN, so any source change re-resolves the git dependencies too — they are the
# slow part of this build by a wide margin. Splitting deps from the package would
# fix that, but setuptools has no "install my dependencies only" step short of
# maintaining a second requirements file that can drift from pyproject. Not worth
# it for a build that runs on a tag push.
RUN pip install --upgrade pip && pip install .


FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/venv/bin:$PATH" \
    AMBER_MEMORY_DB_PATH=/data/amber.db

# sqlite3 for backup/backup-sqlite.sh, which runs `.backup` inside this container —
# amber.db is WAL with three co-tenant writers, so a `cp` of it is a corrupt
# snapshot. tzdata because AMBER_TIMEZONE feeds zoneinfo for the date/time line
# injected into every prompt, and slim ships no zone database.
RUN apt-get update \
 && apt-get install -y --no-install-recommends sqlite3 tzdata \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv

WORKDIR /srv
COPY app ./app
# Baked in so install/lib/env.sh::env_reconcile can key-diff a live env file against
# it — the container-era replacement for update.sh reading .env.example out of the
# checkout next to the code.
COPY .env.example /srv/.env.example

RUN useradd --system --uid 10002 --no-create-home amber \
 && mkdir -p /data /signals \
 && chown amber:amber /data /signals
USER amber

VOLUME ["/data"]
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import sys,urllib.request as u; sys.exit(0 if u.urlopen('http://127.0.0.1:8000/health', timeout=2).status == 200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
