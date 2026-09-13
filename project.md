# MadUTXO Umbrel App Store — Project Learnings & Agent Guide

## Overview
Community Umbrel App Store (`MadUTXO/MadUTXO-Umbrel-App-Store`) with 2 apps: `madutxo-liquid-electrs` (Liquid Electrum, SideSwap) and `madutxo-libretranslate` (self-hosted translation). Goal: **clean, minimal, Umbrel-compatible, secure, reproducible, CI-green** — like `4rkad/umbrel-app-store`.

## Repo Structure (4rkad-clean)
```
.
├── .github/workflows/build-electrs-liquid.yml  # SHA-pinned actions, GHCR_PAT, context: ./madutxo-liquid-electrs
├── .github/workflows/lint.yml                  # yq del app_proxy + both apps, env APP_DATA_DIR=/tmp
├── .gitignore                                  # */data/ — NEVER remove (security)
├── README.md                                   # minimal store add instructions + disclaimer
├── umbrel-app-store.yml                        # id: madutxo
├── scripts/lint.sh                             # yq checks both apps: images pinned, no-new-privileges, read_only
├── scripts/verify-digest.sh                    # both apps pinned, not latest
├── madutxo-libretranslate/                     # v1.9.5@sha256:b358e, hardened
│   ├── docker-compose.yml (expose 5000, read_only, tmpfs)
│   ├── umbrel-app.yml
│   └── ...
└── madutxo-liquid-electrs/
    ├── Dockerfile (rust:1.82@sha256:d9c3c6, debian@sha256:8820, ELECTRS_SHA 4615126, gosu)
    ├── entrypoint.sh (chown -R electrs:electrs /data, gosu)
    ├── docker-compose.yml (0.6.1@sha256:337460, user:0:0, 60601:60601, 3000/9130 expose)
    ├── umbrel-app.yml (0.7.38)
    └── web/ ...
```
**Rule:** Root only `README + umbrel-app-store.yml + .gitignore` + `scripts/.github`. `Dockerfile`/`entrypoint` live in `madutxo-liquid-electrs/` (not root) — `build` `context: ./madutxo-liquid-electrs`.

## How I Like Repos
- **Minimalism > clutter:** `6` root files → `3` like `4rkad`. Delete only proven unused (e.g., `compact-headers.patch` 23K merged). `false-positive deletion worse than keep`.
- **Umbrel compatibility first:** Only `umbrel-app-store.yml` + `madutxo-*/` matter to Umbrel. `Docker`/`CI` extras must not break `app install`.
- **Trace before delete:** `git ls-files` + `rg` + `yq` + `docker compose config` for every file. Assume used until proven unused.

## Workflows & CI
- **Lint (`lint.yml`):** Runs on `push` `madutxo-*/**` + `Dockerfile` + `scripts`. Steps: `yq` → `lint.sh` (both apps pinned, no-new-privileges, read_only) → `verify-digest.sh` (both pinned) → `Validate compose` (`yq del(.services.app_proxy)` > `/tmp/compose.test.yml` + `APP_DATA_DIR=/tmp TOR_DATA_DIR=/tmp ... docker compose config`). `app_proxy` has no `image` (Umbrel-injected) — must `del` before `config`.
- **Build (`build-electrs-liquid.yml`):** `paths: madutxo-liquid-electrs/Dockerfile,entrypoint.sh` → `context: ./madutxo-liquid-electrs` `file: ./madutxo-liquid-electrs/Dockerfile` → `ghcr.io/madutxo/electrs-liquid:0.6.1` `@sha256:337460` `SHA-pinned actions` (`checkout@fbc6f39` etc.), `provenance: false`, `GHCR_PAT` secret (`write:packages` + `repo` + `workflow`).
- **Keep only passed runs:** `DELETE /repos/.../actions/runs/{id}` for `conclusion: failure` → `Actions` shows only `success` (clean).

## Security (Preserve)
- **`.gitignore` `*/data/` is protection** — prevents `app-data/*/data/db` `RocksDB` `610GB` + `.elements_rpc_pass` `600` leak. Never weaken.
- **No secrets in repo:** `rg` `ghp_|PRIVATE KEY|seed` `0` hits. `GHCR_PAT` via `SealedBox` `key_id` `201` + `shred -u` after push. `ELECTRS_TOR_ADDRESS` sanitized `replace a-zA-Z0-9`.
- **Hardening (electrs 0.7.38 level):** `no-new-privileges:true` `cap_drop: ALL` `read_only:true` `tmpfs` `expose` not `ports` for `3000/9130/5000`, `CORS` `map` not `*`, `user: "0:0"` → `gosu electrs` (fixes `root:root /data` `Permission denied` `panic 130`), `libretranslate` same.

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

## Final Learns
- `Elements 30s idle close` → `electrs` `Mutex<Connection>` `EOF` → `daemon_rpc_conn_max_age 45` + `DAEMON 5/60/60/10` fixes `WARN disconnected`.
- `web` `Tor Loading...` → `baked` `ELECTRS_TOR_ADDRESS` empty + `app_proxy` `302` → `fetch /tor-address` `+` `TOR_DATA_DIR:/tor:ro` `+` `nginx /tor-address`.
- `USER electrs` `+` `root:root /data` → `Permission denied` `→` `user: "0:0"` `chown` `gosu` `→` `non-root` `runtime`.
- `app_proxy` no `image` → `Validate compose` must `yq del(.services.app_proxy)`.
- `LibreTranslate` `v1.6.5 → v1.9.5@b358e` `+` `read_only` `expose` `→` `same` `level` as `electrs`.
