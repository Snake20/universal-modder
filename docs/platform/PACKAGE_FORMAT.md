# `.mashup` package format, v1

A `.mashup` file is a ZIP (deflate or store only; no encryption, no ZIP64 multi-disk) with this layout:

```
mashup.json          manifest, validated by platform/packages/manifest/mashup.schema.json
payload/...          the creator's own files, referenced by ops[].from
media/...            optional: cover.png (16:9, ≤ 2 MB), screenshots, a ≤ 60 s mp4/webm trailer
LICENSE              required when license is LicenseRef-*; recommended always
CREDITS.md           optional free-form credits (the structured list lives in mashup.json)
checksums.json       written by `mash pack`: { "files": { "<path>": "<sha256>" }, "algo": "sha256" }
signature.json       written by the platform after review (never by the creator, see below)
```

## Manifest essentials

See the schema for every field; `examples/hello-mod/mashup.json` is the minimal valid package.

- `requires.games[]`: each entry has a local `key`, at least one store id (`steam` app id, `epic` app name,
  `gog` product id, `xbox` package family name), optional `fingerprint` (sha256 of specific game files to pin
  supported builds) and `user_dirs` (extra writable roots such as `Documents/My Games/<Game>`).
- `requires.dependencies[]`: never bundled. Each names an official `source` (`github-release`, `thunderstore`,
  `modrinth`, `curseforge`, `manual` for sites without a download API, or `url` on an allow-listed host), a
  pinned `sha256`, its `license` and `authors`, and where to extract it.
- `ops[]`: the only things the launcher will do to the player's disk:
  - `copy` a payload file to `root/target`;
  - `json-merge` a patch into a JSON file;
  - `ini-set` one key;
  - `remove` (moves the file to the backup vault).
  - `root` is a game key or `<game>:<user_dir>`. Targets are relative, forward-slash, no `..`, no drive
    letters, no ADS (`:`), and the launcher re-checks after resolving symlinks and junctions.
  - v1 has no registry ops, no running of creator executables, and no installers.
- `launch`: which game to start (`store` URI by default, or a relative `exe`) with sanitized args; `also_start`
  covers passthrough mashups that run two games.
- `online.mode`: one of `offline`, `lan`, `self-hosted`, `mod-friendly-online`. There is no value for official
  matchmaking. The scanner additionally cross-checks the game catalog's anti-cheat flags.

## File policy (enforced by `mash validate` and the scanner)

| Rule | Result |
|---|---|
| Package > 512 MB, > 10 000 entries, or uncompressed/compressed ratio > 100 (zip bomb) | reject |
| Entry path absolute, with `..`, a drive letter, a device name (`CON`, `NUL`...), or duplicate after case-folding | reject |
| Any payload file whose sha256 (or sha1, for parity with `um publish check`) is in `known_file_hashes` | reject: game file |
| `.exe .msi .scr .com .bat .cmd .ps1 .vbs .js(wsh) .lnk .sys` in payload | reject |
| Engine asset archives (`.pak .utoc .ucas .bsa .ba2 .vpk .rpf .pck .assets .bundle .big .wad` ...) | reject in v1 (see PLAN.md gate question 3) |
| `.dll` / `.asi` / `.so` | allowed, ClamAV-scanned, flagged for elevated review |
| Secrets (`.env`, API key patterns from `um/publish.py`) | reject |
| Decompiler fingerprints (Ghidra/IDA auto-names, ILSpy headers) | flag for review |
| ClamAV hit, or VirusTotal hash detection (if enabled) | reject + creator notified |
| Dependency: host not allow-listed, download fails, or sha256 mismatch | reject |
| Manifest references a payload file that is missing, or the payload has files no op uses | reject / warn |

## Signing

1. `mash pack` writes `checksums.json`. Creators may also attach a detached minisign signature, which is
   recorded but not trusted for install.
2. After a moderator approves, the `sign` step:
   - recomputes every hash;
   - builds the canonical statement
     `{"package": "<id>", "version": "<v>", "manifest_sha256": "...", "checksums_sha256": "...", "approved_at": "...", "key_id": "..."}`
     (JSON, keys sorted, no whitespace);
   - signs it with the platform Ed25519 key;
   - writes `signature.json` = `{statement, sig}`, then stores the package under `packages/` (served via signed URLs only).
3. The launcher ships the platform public keys (with `key_id`, supporting rotation and a revocation list
   fetched over TLS). Before install it:
   - verifies the signature;
   - verifies `manifest_sha256` and `checksums_sha256`;
   - verifies every file against `checksums.json`;
   - refuses packages whose version is yanked.

## Versioning

Semver. A new version is a new upload going through the full pipeline. Players see "Update available" only
for approved versions; the installed version stays installable until yanked (yanking a version for
malware also triggers an uninstall prompt in launchers that have it).
