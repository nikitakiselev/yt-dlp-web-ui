# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is a personal fork / hobby project, single-user and self-hosted — AI-assisted changes are welcome without the upstream's review restriction.

## What this is

A self-hosted web UI + RPC server for `yt-dlp` (Go backend, React frontend). The Go binary embeds the built frontend and the OpenAPI spec via `go:embed`, so a release is a single static binary. Module path: `github.com/marcopiovanello/yt-dlp-web-ui/v3`.

## Build & run

The frontend must be built **before** the Go binary because `main.go` embeds `frontend/dist/`. A clean `go build` fails if `frontend/dist/index.html` is absent.

```sh
make all          # build frontend (pnpm) then the Go binary -> ./yt-dlp-webui
make fe           # frontend only: cd frontend && pnpm install && pnpm build
make dev          # frontend Vite dev server (proxies to a running backend)
make default      # go run main.go  (run backend from source)
make multiarch    # cross-compile linux amd64/arm64/armv6/armv7 into ./build
go test ./...     # Go tests (only server/internal/livestream/ has tests today)
```

Runtime/build dependencies: `yt-dlp`, `ffmpeg`, `nodejs` + `pnpm@10`, `go 1.24`, `make`.

Run from source: `go run main.go --out /some/downloads`. Key flags (see `main.go` / README): `--out` (download dir), `--driver` (yt-dlp binary path), `--conf` (YAML config), `--db`, `--port`, `--qs` (queue size), `--auth`/`--user`/`--pass`. A YAML config file (`--conf`) **overrides** CLI flags.

Docker build mirrors `make all`: a `node` stage builds the frontend, a `golang` stage builds the binary, and the runtime stage is `python:alpine` with `yt-dlp` + `ffmpeg`. The container entrypoint is `./yt-dlp-webui --out /downloads --conf /config/config.yml --db /config/local.db` with `/downloads` and `/config` as volumes, **cwd `/app`**.

## Architecture

### Backend (`server/`)
- `server/server.go` — `RunBlocking()` wires everything: a chi router with CORS + JWT (`middleware/`) + OpenID (`openid/`), mounts REST (`/api/v1/*`), JSON-RPC over WebSocket (`/rpc/ws`) and HTTP (`/rpc/http`), filebrowser, archive, subscriptions, twitch, log/status routes. Also starts a 5-minute auto-persist goroutine and graceful shutdown.
- `server/internal/` — the download engine:
  - `memory_db.go` — `MemoryDB`, a thread-safe `map[string]*Process` (the live state); persisted to `session.dat` via gob.
  - `message_queue.go` — EventBus-backed queue with a concurrency semaphore. Two consumers: a metadata fetcher (`yt-dlp -J`) and the download runner.
  - `process.go` — `Process` type; builds the yt-dlp argv and spawns the process (see below).
  - `common_types.go` — `DownloadRequest{ URL, Path, Rename, Params []string }` (the API payload) and `DownloadOutput{ Path, Filename }`.
- Feature modules follow a `domain/repository/service/rest` layering: `archive/` (completed downloads → SQLite), `subscription/` (cron channel subs), `twitch/`, `filebrowser/`, `formats/`, `playlist/`.
- `server/config/config.go` — singleton `config.Instance()`; loaded from flags in `main.go`, then merged/overridden by the YAML file.
- `server/dbutil/migrate.go` — SQLite (`modernc.org/sqlite`, pure-Go, CGO off) schema: `templates`, `archive`, `subscriptions`. DB path defaults to `local.db`.

### Frontend (`frontend/src/`)
React 19 + TypeScript + Vite (`@vitejs/plugin-react-swc`), MUI 6 (`@emotion`), **Jotai** for state (`atoms/`), **RxJS** + `fp-ts` for the RPC client (`services/`). Structure: `views/` (pages), `components/`, `atoms/` (global state), `hooks/`, `services/` (talks to the backend RPC/REST). Built output lands in `frontend/dist/` and is embedded by the Go binary.

### API surfaces
The same operations are exposed three ways — REST (`server/rest/`), JSON-RPC over WS and over HTTP (`server/rpc/`). There is also a planned gRPC interface (`proto/yt-dlp.proto`). OpenAPI lives in `openapi/openapi.json` and is served at `/openapi`.

## How the yt-dlp command is built (important)

All argv construction lives in **`server/internal/process.go`** (`Process.Start`). The flow:

1. User `Params` are lightly sanitized — only entries matching `(\$\{)|(\&\&)` (shell expansion / chaining) and empty strings are dropped. There is **no quote handling**: each `Params` element is passed to `exec.Command` as one argv token, so quotes typed in the UI are passed to yt-dlp **literally**. Do not wrap values in quotes from the UI.
2. Fixed base flags are always prepended: the URL (with `?list…` stripped), `--newline --no-colors --no-playlist`, two `--progress-template` (JSON progress lines the backend parses), and `--no-exec`.
3. Output is forced by the backend: **unless** the user passes `-P`/`--paths`, the code appends `-o "<DownloadPath>/<Filename>"` (default filename `%(title)s.%(ext)s`). It does **not** check for a user-supplied `-o`, so a user `-o` and the auto `-o` can both end up on the line.
4. `exec.Command(config.DownloaderPath, params...)` runs with `Setpgid` and **no explicit working directory** — it inherits the server's cwd (`/app` in Docker). Consequently any yt-dlp output without an absolute path (e.g. `--split-chapters` files when no `chapter:` output template is set) is written relative to `/app`, not `/downloads`.

This function is the place to change behavior such as per-type output templates (e.g. injecting `-o "chapter:<DownloadPath>/…"` for `--split-chapters`).

## Splitting audio into tracks

Two ways, both driven from the UI's custom-args field (no app code involved):

- **Has chapters** (e.g. YouTube videos whose description has timestamps — note only `--extractor-args youtube:player_client=android` exposes them): `--split-chapters` + a typed `-o "chapter:<dir>/%(title)s/%(section_number)02d-%(section_title)s.%(ext)s"`.
- **No chapters / no tracklist, but pauses between tracks**: download audio normally, then `--exec "after_move:split-by-silence.sh -D %(filepath)q"`. `scripts/split-by-silence.sh` (baked into the image at `/usr/local/bin/`, see Dockerfile) uses ffmpeg `silencedetect` to cut at the midpoint of each pause; `-D` deletes the source only after a successful split. POSIX sh — runs under busybox, no bash needed.
