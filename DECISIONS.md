# Decisions

Format: ID, decision, why, alternatives considered, status. "Proposed" = awaiting the Phase 0 gate.

**D-001 Working brand values.**
- The brief's placeholders are unfilled, so I use Mashworks / `mash` / `mashworks://`, ember `#FF5A1F` + teal `#14E3C0` on ink `#12100E`.
- Everything reads `platform/brand.json`, so a rename is one file.
- Contrast on ink: ember 6.09:1 and teal 11.55:1 (both pass AA for body text).
- Ember on the light paper `#F6F1EA` is 2.78:1 and fails, so light surfaces use ember only for fills, with ink text. Text-ember on light needs a darker shade (≤ `#C2410C`, checked in Phase 4).
- *Proposed.*

**D-002 Build the platform inside this repo, under `platform/`.**
- The repo's skills, knowledge base and lint rules are the creator half of the product. The README already promises the hub.
- One repo keeps the shared signature tables and scan rules in sync, and the existing Python CI keeps running unchanged.
- Alternative: a new repo, which is cleaner for permissions but duplicates the rule tables.
- *Proposed.*

**D-003 Keep the requested stack: Tauri 2, Next.js on Vercel, Supabase, Node CLI.** No swaps. Two additions:
- **(a)** A shared Rust library crate (`mashup-core`) separate from the Tauri shell, so detection, verification and install logic are unit-tested on Linux CI without a WebView.
- **(b)** A small scanner container, because Edge Functions (Deno, 2 s CPU / 150 MB-ish limits) cannot run ClamAV or unpack 500 MB archives. Edge Functions orchestrate, and the container does the heavy scan.
- *Proposed.*

**D-004 Manifest is declarative file ops only (copy, json-merge, ini-set, remove).**
- No registry writes, no running creator executables, no installers in v1. This makes every install reversible and reviewable, and the threat model tractable.
- Loaders that need an installer (e.g. some script extenders) are modelled as dependencies extracted from their official archive.
- *Proposed.*

**D-005 Dependencies are never bundled.**
- Each names an official source with a pinned sha256. The scanner verifies once, and the launcher verifies again after download.
- Sites without a download API (Nexus Mods) are `manual`: the player downloads it themselves and the launcher hash-checks the file. This respects those sites' terms and authors' download counts.
- *Proposed.*

**D-006 Steam sign-in via our own OpenID 2.0 Edge Function.**
- Supabase Auth has no Steam provider; Discord and email are built in.
- The function verifies the assertion with `check_authentication` against Steam, then signs in or links a Supabase user through the admin API.
- Steam login is OpenID 2.0, not OAuth, so a generic OIDC provider can't be used.
- *Proposed.*

**D-007 Platform Ed25519 signature after human review, with the launcher pinning keys.**
- Creator signatures (minisign) are recorded but not trusted for install, because the guarantee players need is "this is what was reviewed".
- The Tauri updater uses a separate key.
- *Proposed.*

**D-008 Ownership gate is local detection, not licence proof.**
- No store offers an offline licence check to third parties.
- We detect Steam (libraryfolders.vdf + appmanifest), Epic (`ProgramData/Epic/.../Manifests/*.item`), GOG (registry `HKLM\SOFTWARE\WOW6432Node\GOG.com\Games\*` + `goggame-*.info`) and Xbox/MS Store (`XboxGames` folders + `Get-AppxPackage`).
- Many MS Store titles have locked WindowsApps folders. Those are detected but marked mod-unfriendly unless installed to an `XboxGames` folder with "advanced management".
- Since we never distribute game files, nothing runs without a real install.
- *Proposed.*

**D-009 Engine archives are rejected in v1.** This follows the non-negotiable literally. It blocks most Unreal `_P.pak` mods, so gate question 3 asks whether to allow creator-built archives with hash checks + moderator sign-off. *Open.*

**D-010 Schema bug found by tests: auto-generated handles collided.**
- The first draft derived `user_<12 hex>` from the uuid prefix, which collides when ids share a prefix.
- Now it uses `md5(id)`. Found by `tests/rls.sql` seeding three users.
- *Done.*

**D-011 Column grants + triggers for moderator-only fields.**
- RLS policies can't restrict *which columns* change. Column-level `GRANT UPDATE (...)` covers counters, roles and token hashes.
- Two transitions need triggers: un-hiding a moderated comment, and relisting a `removed` mashup. Both were exploitable in the first draft, and both are now tested.
- *Done.*

**D-012 Windows verification strategy.**
- This environment is Linux. Platform-specific code sits behind `Fs`/`Registry`/`Process` traits, tested with fixtures here.
- A GitHub Actions `windows-latest` job runs the real-registry tests and builds the installer.
- I will mark anything verified only on fixtures as "Partial" in the scorecard until the Windows job has run it.
- *Proposed.*
