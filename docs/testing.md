# Testing

## Quick checks

```bash
curl http://localhost:8888/health
curl http://localhost:8888/metrics | grep gateii_
bash scripts/smoke-test.sh
```

## Suite layout

| Suite | What | Run |
|-------|------|-----|
| `spec/*_spec.lua` | 73 `busted` tests over the Lua modules | see below |
| `spec/admin_sh_test.sh` | 29-test bash suite for `scripts/admin.sh` | `bash spec/admin_sh_test.sh` |

Both are wired into CI (`.github/workflows/ci.yml`).

## Local CI parity via throwaway containers

Run the same checks CI runs, using `bash scripts/docker-colima.sh run …` so
`DOCKER_HOST` is set correctly for Colima.

### luacheck

Image `pipelinecomponents/luacheck`, target `luacheck config/openresty/lua/`.
The vendored `resty/` tree is excluded via `.luacheckrc` — expect 0 warnings /
0 errors.

### busted

Use **Alpine + apk**, NOT apt/ubuntu. In the colima network `apt-get` fails to
fetch `.deb` pool packages, and compiling cjson through luarocks needs
`build-base`. Alpine is reliable:

```
alpine:3.20
apk add lua5.1 lua5.1-cjson lua5.1-busted lua5.1-bitop
busted-5.1 spec/
```

Two traps:

- **Binaries are versioned** — `busted-5.1`, not `busted`.
- **`lua5.1-bitop` is required.** `bootstrap.lua` needs the `bit` module.
  LuaJIT (production) has it built in; CI's PUC lua5.1 does not — without
  `lua5.1-bitop`, `bootstrap_spec` errors on load. Keep it installed in
  `ci.yml`.

## Related

- [key-files.md](key-files.md) — what each module under test does
- [architecture.md](architecture.md) — design decisions the specs pin
