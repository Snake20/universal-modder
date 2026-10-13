# Progress

**Phase:** 0 (Plan) is complete and **waiting at the gate for owner approval**. Nothing from Phase 1 has started.

## Done in Phase 0
- `docs/platform/PLAN.md`: how the platform builds on this repo; architecture (Mermaid); repo layout; Play,
  install-engine and publish flows; Play-button state machine; API list; per-phase verification strategy;
  gate questions.
- `docs/platform/PACKAGE_FORMAT.md` + `platform/packages/manifest/mashup.schema.json`: the `.mashup` format,
  file policy, signing.
  - The examples are `hello-mod` (valid) and `bad/traversal.json` (rejected).
- `platform/supabase/migrations/20261013000000_init.sql`: the full schema with RLS on every table.
  - `platform/supabase/tests/run.sh` runs 32 RLS checks, all passing on Postgres 16 (local socket and TCP).
- `docs/platform/SCHEMA.md` (ER diagram + access matrix) and `docs/platform/THREAT_MODEL.md` (16 threats).
- `DECISIONS.md` (D-001…D-012), `tasks.json` (47 tasks, each with a verify step), `platform/brand.json`.
- `tests/test_platform_plan.py` (13 tests). The CI workflow gained `--with jsonschema` and a `platform-db` job.

## Verification run
- `uv run --with pytest --with jsonschema pytest -q tests` → 71 passed
- `bash platform/supabase/tests/run.sh` → ALL RLS TESTS PASSED (32 checks); a deliberately broken assertion makes it exit non-zero
- `./bin/um kb check --index` → PASS (53 notes); `./bin/um publish check .` → 0 failures (1 existing warning in a KB note)

## Next step
Owner answers the gate questions in `docs/platform/PLAN.md` §6. Then Phase 1 starts with tasks P1-1 → P1-15:
`mashup-core` crate, detection, verify, install engine, and the hello-mod end-to-end run.
