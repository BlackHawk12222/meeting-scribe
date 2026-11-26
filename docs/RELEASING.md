# Releasing Scribe

A release **publishes the build you already tested**. It does not rebuild: the signed `Scribe`
artifact from the passing branch build is re-checked and published as `v<VERSION>`.
Approval to live (the in-app updater sees it) takes about 2 minutes.

## Before approval (on the branch)

1. Bump `VERSION` on the branch (the version is baked into the app at build time, so it must be
   right before the build; the release refuses a tag that already exists).
2. Build the branch tip (signs with the stable certificate, fills Supabase.plist, runs the tests):

   ```sh
   gh workflow run build.yml --ref <branch> -f selftest=targeted
   ```

   The release uses the newest **successful** build whose commit content (tree) equals the branch
   tip, so any new commit on the branch needs a new build.

## Release (one step)

```sh
gh workflow run release.yml --ref main -f branch=<branch> -f dry_run=false
```

(Equivalent API call: `POST /repos/BlackHawk12222/meeting-scribe/actions/workflows/release.yml/dispatches`
with `{"ref":"main","inputs":{"branch":"<branch>","dry_run":"false"}}`.)

It:

1. finds that passing build (or the one given with `-f run_id=<id>`);
2. checks the tag `v<VERSION>` is free and `main` can fast-forward to the branch tip;
3. downloads the build's artifact and checks the SHA-256s, `codesign --verify --deep --strict`,
   the pinned designated requirement (`identifier "com.blackhawk12222.Scribe" and certificate leaf
   = H"83ca46da…7333"`), that it matches the latest release's identity (`DR_MATCH yes`), the
   version, that `components.json` is the commit's model manifest, and that Supabase.plist is
   filled (values are never printed);
4. fast-forwards `main` and publishes `Scribe.zip`, `Scribe.dmg`, `Scribe.zip.sha256`,
   `SHA256SUMS.txt`, `components.json` as the **latest** release, then confirms
   `/releases/latest` (what the updater reads) serves it.

`dry_run` defaults to **true**: leave out `-f dry_run=false` to check everything without moving
`main` or publishing.

If `main` can't be moved by the workflow (a commit that edits `.github/workflows/` needs a token
with the `workflows` scope), the release still publishes with the tag on the exact commit, and
the log says to run `git push origin <sha>:main`.

## Fallback

`[release]` in a commit message pushed to `main` still does the old full rebuild + publish
(~9-10 min).
