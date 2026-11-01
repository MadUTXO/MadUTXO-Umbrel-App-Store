# MadUTXO Umbrel App Store — Project Learnings & Agent Guide

## Overview
Community Umbrel App Store (`MadUTXO/MadUTXO-Umbrel-App-Store`) with 3 apps: `madutxo-liquid-electrs` (Liquid Electrum, SideSwap), `madutxo-libretranslate` (self-hosted translation), and `madutxo-torlink` (torrent finder/downloader). Goal: **clean, minimal, Umbrel-compatible, secure, reproducible, CI-green** — like `4rkad/umbrel-app-store`.

## Repo Structure (4rkad-clean)
```
.
├── .github/workflows/build-electrs-liquid.yml  # SHA-pinned actions, GHCR_PAT, context: ./madutxo-liquid-electrs
├── .github/workflows/build-torlink.yml         # SHA-pinned actions, GHCR_PAT, context: ./madutxo-torlink
├── .github/workflows/lint.yml                  # yq del app_proxy + all apps, env APP_DATA_DIR=/tmp
├── .gitignore                                  # */data/ — NEVER remove (security)
├── README.md                                   # minimal store add instructions + disclaimer
├── umbrel-app-store.yml                        # id: madutxo
├── scripts/lint.sh                             # yq checks all apps: images pinned, no-new-privileges, read_only
├── scripts/verify-digest.sh                    # all apps pinned, not latest
├── madutxo-libretranslate/                     # v1.9.5@sha256:b358e, hardened
│   ├── docker-compose.yml (expose 5000, read_only, tmpfs)
│   ├── umbrel-app.yml
│   └── ...
├── madutxo-torlink/                            # 1.10.1, ttyd+tmux TUI (Games disabled)
│   ├── Dockerfile (node:22.23.4, torlink df05931, ttyd 1.7.7, games+memory patched)
│   ├── entrypoint.sh (state/config, ttyd attach, downloads -> /downloads)
│   ├── hooks/pre-start (mkdir/chown state)
│   ├── docker-compose.yml (expose 7681, no peer port)
│   └── umbrel-app.yml (port 3065, STORAGE_DOWNLOADS)
└── madutxo-liquid-electrs/
    ├── Dockerfile (rust:1.82@sha256:d9c3c6, debian@sha256:8820, ELECTRS_SHA 4615126, gosu)
    ├── entrypoint.sh (chown /data, non-fatal password persist + warning, gosu)
    ├── docker-compose.yml (0.6.2@sha256:e31b97b, user:0:0, mem_limit:12g, 60601:60601, 3000/9130 expose)
    ├── umbrel-app.yml (0.7.48 + memory WARNING)
    └── web/ ...
```
**Rule:** Root only `README + umbrel-app-store.yml + .gitignore` + `scripts/.github`. `Dockerfile`/`entrypoint` live in `madutxo-liquid-electrs/` (not root) — `build` `context: ./madutxo-liquid-electrs`.

## How I Like Repos
- **Minimalism > clutter:** `6` root files → `3` like `4rkad`. Delete only proven unused (e.g., `compact-headers.patch` 23K merged). `false-positive deletion worse than keep`.
- **Umbrel compatibility first:** Only `umbrel-app-store.yml` + `madutxo-*/` matter to Umbrel. `Docker`/`CI` extras must not break `app install`.
- **Trace before delete:** `git ls-files` + `rg` + `yq` + `docker compose config` for every file. Assume used until proven unused.

## Workflows & CI
- **Lint (`lint.yml`):** Runs on `push` `madutxo-*/**` + `Dockerfile` + `scripts`. Steps: `yq` → `lint.sh` (all apps pinned, no-new-privileges, read_only; torlink no host ports, `1000:1000`, hardening env) → `verify-digest.sh` (all pinned) → `Validate compose` (`yq del(.services.app_proxy)` > `/tmp/compose.test.yml` + `APP_DATA_DIR=/tmp TOR_DATA_DIR=/tmp ... docker compose config`). `app_proxy` has no `image` (Umbrel-injected) — must `del` before `config`.
- **Build (`build-electrs-liquid.yml`, `build-torlink.yml`):** `paths: <app>/Dockerfile,entrypoint.sh` → `context: ./<app>` `file: ./<app>/Dockerfile` → `ghcr.io/madutxo/<app>:<version>` `@sha256:<manifest-list>` `SHA-pinned actions` (`checkout@fbc6f39` etc.), `provenance: false`, `GHCR_PAT` secret (`write:packages` + `repo` + `workflow`). Trigger by `workflow_dispatch` (no code push) when possible; verify digest + arch list (`amd64+arm64`) via `crane` before wiring the pin.
- **Keep only passed runs:** `DELETE /repos/.../actions/runs/{id}` for `conclusion: failure` → `Actions` shows only `success` (clean).

## Torlink Packaging Constraints

- **One engine only.** TUI, `serve`, `watch`, and `seed` all call `startRuntime()` and share `queue.json` + `boot.marker`; two engine processes in one state dir corrupt state and can trigger false safe-mode. The package runs only the TUI.
- **ttyd runs `torlnk attach`, not bare `torlnk`.** `attach` owns a persistent tmux session (`tmux new-session -A -s torlink`), so closing the browser tab detaches and downloads continue. Pressing `Ctrl-C` inside the TUI quits the engine.
- **No peer port is published.** WebTorrent is constructed without `torrentPort`, so the TCP port is random; inbound seeding is not guaranteed. WebRTC and uTP are disabled (`TORLINK_NO_WEBRTC=1`, `TORLINK_NO_UTP=1`) to avoid native builds; `TORLINK_NO_UPDATE_CHECK=1` keeps runtime code pinned to the image digest.
- **Games category disabled.** FitGirl game repacks are useless for Jellyfin and can execute code; the Games tab/source group is patched out at build time (movies, TV, anime remain; FitGirl shows under "All" only). Source patching is applied in the Dockerfile after the pinned `git checkout`: `git apply torlink-memory.patch` plus the Games `sed` step.
- **Memory bounded.** `TORLINK_STORE_CACHE_SLOTS=0` makes torlink pass `storeCacheSlots: 0` to WebTorrent, disabling the 20-piece-per-torrent cache that retained `20 × piece length` per seeded download. Measured with 10 × 400 MB seeds: ~3.4 GB RSS before, ~100 MB after.
- **Downloads go to the native Umbrel Downloads folder.** `downloadDir` is `/downloads` (mounted from `${UMBREL_ROOT}/data/storage/downloads`), matching the Transmission app — not a `/downloads/torlink` subfolder.
- **State mapping.** `TORLINK_STATE_DIR=/state` → `/state/data` + `/state/config`; `hooks/pre-start` creates and chowns the state dirs because `*/data/` is gitignored and cannot carry `.gitkeep`.
- **Interface is a terminal.** Browser terminal UX is the v1 tradeoff; a custom web UI is a possible later phase, not part of this package.

## Security (Preserve)
- **`.gitignore` `*/data/` is protection** — prevents `app-data/*/data/db` `RocksDB` `610GB` + `.elements_rpc_pass` `600` leak. Never weaken.
- **No secrets in repo:** `rg` `ghp_|PRIVATE KEY|seed` `0` hits. `GHCR_PAT` via `SealedBox` `key_id` `201` + `shred -u` after push. `ELECTRS_TOR_ADDRESS` sanitized `replace a-zA-Z0-9`.
- **Hardening (electrs 0.7.38 level):** `no-new-privileges:true` `cap_drop: ALL` `read_only:true` `tmpfs` `expose` not `ports` for `3000/9130/5000/7681`, `CORS` `map` not `*`, `user: "0:0"` → `gosu electrs` (fixes `root:root /data` `Permission denied` `panic 130`), `libretranslate` same, `torlink` runs `1000:1000` with no host/peer ports.

## Handling Secrets & Tokens
- `PAT classic` `repo + workflow + write:packages` for `GHCR_PAT` + `git push`. `shred -u /tmp/gh_token.txt` after use. `secret scanning` revokes `~1m` → rotate.
- Never paste `ghp_` in `logs`/`commit` messages. Use `Nostr-mail` encrypted or `oauth2:token@github.com` transient `remote set-url`.

## Standing Rules (never need reminding — always apply)

- **Pre-validate builds before pushing:** never push anything that triggers `build-electrs-liquid.yml` without first proving login will pass — check token scopes (`repo, workflow, write:packages`) via `x-oauth-scopes` AND fetch a GHCR bearer token for the target repo. A failed build must never be discovered by CI.
- **Actions stay green-only:** if any run fails, `DELETE /repos/.../actions/runs/{id}` immediately after green. No failure traces kept, ever.
- **Release notes always match the release:** every version bump lists every user-facing change in that version (tor, memory, proxy, startup — all of them). Never ship a version with stale notes.
- **Traceability over shortcuts:** fixes go through reviewed source → artifact → digest. No runtime-only overrides that make running code differ from the pinned digest. A false shortcut is worse than a slow rebuild.
- **No release push before test-env confirm:** new app versions stay unpushed until confirmed running in the Umbrel test environment.

## Agent Workflow (How I Like Projects Done)
1. **READ-ANALYZE-PROPOSE-WAIT FOR YES-IMPLEMENT-TEST-REVIEW DIFF-COMMIT YES-PUSH YES** — never `edit`/`push` without `YES`.
2. **Read-only first:** `AGENTS.md` is `READ-ONLY` default. `WebFetch` `docs` + `rg` + `read` before `propose`.
3. **One logical group at a time:** `check` → `build` → `make`, `supply-chain` + `CI` + `network` `separately` `unless` `YES ALL`.
4. **Verify via execution:** `npm run check` `yq` `docker compose config` `scripts/lint.sh` `verify-digest.sh` `git diff --check` `git status` before `commit`.
5. **Preserve functionality > minimalism:** If uncertain, `KEEP` + explain `why`. `Umbrel` `install` + `SideSwap` `Personal` `umbrel.local:60601` must stay.
6. **Commit style:** `type: message` `+` `bump` `version` `0.7.x` `in` `umbrel-app.yml` + `releaseNotes` generic. `git log --oneline` clean like `4rkad`.
7. **Clean history:** `gh api` `DELETE` `failed` `runs` → `Actions` `only` `success` `like` `4rkad`.

## Final Learns- `Elements 30s idle close` → `electrs` `Mutex<Connection>` `EOF` → `daemon_rpc_conn_max_age 45` + `DAEMON 5/60/60/10` fixes `WARN disconnected`.
- `web` `Tor Loading...` → `baked` `ELECTRS_TOR_ADDRESS` empty + `app_proxy` `302` → `fetch /tor-address` `+` `TOR_DATA_DIR:/tor:ro` `+` `nginx /tor-address`.
- `USER electrs` `+` `root:root /data` → `Permission denied` `→` `user: "0:0"` `chown` `gosu` `→` `non-root` `runtime`.
- `app_proxy` no `image` → `Validate compose` must `yq del(.services.app_proxy)`.
- `LibreTranslate` `v1.6.5 → v1.9.5@b358e` `+` `read_only` `expose` `→` `same` `level` as `electrs`.
- `Repo file ≠ running code:` `entrypoint.sh` lives *inside* the image — a repo fix needs an image rebuild (`0.6.2`) + pin update before any box sees it. Never assume a merged script is live.
- `Tor 0.4.9 strictness:` new Tor fails fast on `Unparseable address` when the target hostname has no DNS yet (first boot), then self-heals on restart. Old Tor just started anyway. One scary log line, then `100% Done` — normal.

## Incident Log 0.7.39–0.7.48 (what actually happened)

- `0.7.39:` Tor `0.4.7.8 → 0.4.9.11` (EOL/CVE/30% stall). Notes missed it — process gap, led to the release-notes rule.
- `0.7.40:` tried to fix 10GB steady RAM by shrinking everything (`16/16/1/50` + 3g cap). Fixed nothing, started the restart loop. Lesson: never tune blind — measure first.
- `0.7.41:` full container names for proxy upstreams (DNS round-robin fix, mirrors 4rkad). Correct, tiny, no behavior change.
- `0.7.43/0.6.2:` entrypoint password-persist made non-fatal (exit-2 loop → warning). Rebuilt image so digest matches source (traceability).
- `0.7.44–0.7.46:` buffer rebalancing attempts, all guesses until the diagnostic build.
- `0.7.47 (diagnostic):` cap removed on purpose, 23GB test box measured **9.3GB peak**, `restarts=0`, both servers up. Proof beats theory.
- `0.7.48:` cap re-set to **12g** from measured data + memory WARNING in notes (10GB on first indexing and every boot, 8GB boxes may restart during catch-up, 16GB+ recommended).

## Debugging Playbook (evidence order that works)

1. `inspect` first: `exit=` + `oom=` + `restarts=` + `status=` — separates crash (non-zero, no oom) vs OOM-kill (137 + true) vs graceful stop (0) vs watchdog SIGKILL (137, oom false).
2. `docker stats` second: actual usage vs cap at the moment of death. A 124MB death is never memory.
3. `docker events` third: `container die ... exitCode=137 execDuration=49` names the killer and the lifespan. Filter noise from other apps.
4. `ls -la` host paths fourth: root-owned files recreated by `exports.sh` on every start explain surviving `Permission denied`.
5. `docker update --memory` experiment: proves/​kills a cap theory in minutes with zero repo changes.
6. Never trust a single snapshot: browser UI only refreshes on reload; `docker logs --tail` shows the current incarnation only.
