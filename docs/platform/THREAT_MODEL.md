# Threat model (v1)

Assets, in priority order:
1. The player's PC and game installs (the launcher writes into them).
2. Players' trust that a package is what was reviewed.
3. Rights holders' content (no game files distributed).
4. Accounts, tokens and the platform signing key.
5. Online games and other players (no cheats, no anti-cheat targets).

Trust boundaries:
- creator → upload pipeline;
- pipeline → reviewer;
- platform → launcher (signature);
- launcher → player disk;
- launcher → third-party dependency hosts.

| # | Threat (STRIDE) | Where | Mitigation | Verified by |
|---|---|---|---|---|
| T-1 | Malware in a package (E/T) | upload | ClamAV + optional VirusTotal hash lookup. No executables, scripts or installers in payloads. DLLs get elevated review. Human review before anything goes public. Reports can quickly yank a version, which prompts uninstall in launchers. | scanner fixtures incl. EICAR (Phase 3) |
| T-2 | Package swapped after review (T) | storage / CDN / MITM | Platform Ed25519 signature over manifest + checksums. Launcher pins public keys and verifies every file before writing. Packages are served only via short-lived signed URLs. | launcher tests: tampered byte, wrong key, unsigned (Phase 1) |
| T-3 | Path traversal / writing outside the game (E) | install engine | Schema forbids `..`, absolute paths, drive letters and ADS. The engine canonicalizes, rejects symlink/junction/reparse escapes, and only writes to the game root or declared user dirs. No registry ops, no exec of creator code. | schema test (done), engine tests (Phase 1) |
| T-4 | Zip bombs / resource exhaustion (D) | scanner, launcher | Entry count, total size and ratio limits, enforced while streaming, not after. Upload URLs are size-capped. Per-user upload rate limits. | scanner fixtures |
| T-5 | Redistributing game files (legal) | upload | `known_file_hashes` (sha256+sha1) match → reject. Engine archives rejected in v1. Moderator checklist. DMCA flow with repeat-infringer policy. | scanner fixtures; `um publish check` parity |
| T-6 | Malicious or swapped dependency (T) | dependency fetch | Only allow-listed official sources. sha256 pinned in the signed manifest and re-verified by the launcher after download. The scanner verifies once at upload. `manual` deps are hash-checked when the player supplies them. | launcher + scanner tests |
| T-7 | Unreversible damage / data loss (D) | install engine | Write-ahead journal, content-addressed backup vault, atomic replace, rollback on failure, crash recovery at startup. Uninstall verifies every restored hash. Repair falls back to the store's own verify. | backup/restore tests on fixture game (Phase 1) |
| T-8 | Privilege abuse via RLS gaps (E/I) | Postgres | RLS on every table (tested). Column-level grants for roles, counters and token hashes. Triggers for moderator-only transitions. State changes only in Edge Functions. | `platform/supabase/tests/run.sh` (32 checks, passing) |
| T-9 | Mods used against online games / anti-cheat (policy) | catalog, scanner, launcher | `online.mode` has no "official matchmaking" value. Catalog flags anti-cheat and online-only games, and mashups for online-only games are rejected. The launcher shows a blocking warning naming the anti-cheat and refuses to launch protected modes. Cheat functionality (aimbot/ESP/speed) is a rejection reason in review. | scanner + launcher tests; review checklist |
| T-10 | Ownership bypass (policy) | launcher | Detection is presence-based (we can't prove a licence offline). Play needs every game detected and launches through the store when possible. We never ship game files, so nothing works without a real install. The launcher is explicit that this isn't DRM. | detection tests |
| T-11 | Token / key theft (S/I) | CLI, CI, signer | API tokens are stored hashed, scoped and revocable, and shown once. CLI keeps them in the OS keychain (fallback: 0600 file). GitHub publishing uses OIDC instead of stored secrets. The signing key lives in Supabase Vault/KMS and is used only by the sign function, with key ids + rotation. | unit tests, review |
| T-12 | Malicious deep links (S/E) | launcher | `mashworks://` only selects a mashup id/version or invite code. It never triggers install or launch without a click in the launcher, and parameters are validated against strict patterns. | deep link parser tests (Phase 4) |
| T-13 | Malicious auto-update (T) | updater | Tauri updater with its own minisign key (separate from package signing), HTTPS only, signed installer. | Phase 6 |
| T-14 | XSS / injection on the marketplace (T/I) | web | React escaping, markdown rendered with a sanitizer allow-list, strict CSP, media served from a separate origin, no user HTML. | Playwright + CSP checks (Phase 2) |
| T-15 | Spam / review flooding (D) | web, pipeline | Rate limits per account and IP, new-account upload limits, report triage queue. | Phase 3 |
| T-16 | Moderator account compromise (E) | auth | Moderators must use 2FA (Supabase MFA). Every review action is logged in `review_actions`. Publishing needs approve + sign (two steps, both logged). | Phase 3 |

Out of scope for v1, with reasons recorded in DECISIONS.md:
- sandboxing DLL mods at runtime (they run in the game process by design; review + scanning is the control);
- proving game ownership beyond local detection.
