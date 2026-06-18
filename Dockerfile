# Node (pnpm) ------------------------------------------------------------------
FROM node:22-slim AS ui
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack prepare pnpm@10.0.0 --activate && corepack enable
COPY . /usr/src/yt-dlp-webui

WORKDIR /usr/src/yt-dlp-webui/frontend

RUN rm -rf node_modules

RUN pnpm install
RUN pnpm run build
# -----------------------------------------------------------------------------

# Go --------------------------------------------------------------------------
FROM golang AS build

WORKDIR /usr/src/yt-dlp-webui

COPY . .
COPY --from=ui /usr/src/yt-dlp-webui/frontend /usr/src/yt-dlp-webui/frontend

RUN CGO_ENABLED=0 GOOS=linux go build -o yt-dlp-webui
# -----------------------------------------------------------------------------

# Runtime ---------------------------------------------------------------------
FROM python:3.13.2-alpine3.21

RUN apk update && \
apk add ffmpeg ca-certificates curl wget gnutls --no-cache && \
pip install "yt-dlp[default,curl-cffi,mutagen,pycryptodomex,phantomjs,secretstorage]"

VOLUME /downloads /config

WORKDIR /app

COPY --from=build /usr/src/yt-dlp-webui/yt-dlp-webui /app

# helper to split a downloaded audio file into tracks at silent gaps,
# invoked via yt-dlp --exec (see README/CLAUDE.md). POSIX sh, uses busybox awk + ffmpeg.
COPY scripts/split-by-silence.sh /usr/local/bin/split-by-silence.sh
RUN chmod +x /usr/local/bin/split-by-silence.sh

ENV JWT_SECRET=secret

EXPOSE 3033

# Run as a non-root uid so downloaded files are owned by 1000:1000.
# Across the unprivileged LXC hosts this matches the shared media-library
# user (AzuraCast and other consumers also run as uid 1000), so files written
# to the shared library are usable without any post-download chown.
# Must come after all RUN/COPY/chmod steps above, which require root.
USER 1000:1000

ENTRYPOINT [ "./yt-dlp-webui" , "--out", "/downloads", "--conf", "/config/config.yml", "--db", "/config/local.db" ]
