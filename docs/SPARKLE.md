# Sparkle updates (Skagway)

Skagway uses [Sparkle 2](https://sparkle-project.org) for **Check for Updates…** and optional automatic checks. There is no SaaS fee — only hosting bandwidth for the DMG + a tiny appcast.

## Canonical URLs

| Asset | URL |
|-------|-----|
| DMG (download + Sparkle enclosure) | `https://downloads.machiilabs.com/Skagway.dmg` |
| Appcast (`SUFeedURL`) | `https://downloads.machiilabs.com/Skagway.appcast.xml` |

Public EdDSA key is embedded in the app as `SUPublicEDKey` (see `project.yml`). Automatic checks default to **off** (`SUEnableAutomaticChecks = false`); users enable them in **Settings → Library → Automatically check for updates**.

## Keys (one-time)

Keys were generated with Sparkle’s `generate_keys` using Keychain account `machiilabs.skagway`.

- **Public key** — committed in `project.yml` (`SUPublicEDKey`).
- **Private key** — in the login Keychain (account `machiilabs.skagway`) and optionally exported to `secrets/sparkle_ed25519` (gitignored). **Never commit the private key.**

Export / import later:

```bash
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' | head -1)
"$SPARKLE_BIN/generate_keys" --account machiilabs.skagway -p          # print public
"$SPARKLE_BIN/generate_keys" --account machiilabs.skagway -x secrets/sparkle_ed25519
"$SPARKLE_BIN/generate_keys" --account machiilabs.skagway -f secrets/sparkle_ed25519
```

## Release checklist

**Every release — do not ship without steps 2–4.**

1. Cut the usual release / run packaging:

   ```bash
   bash scripts/package_dmg.sh
   ```

   After notarization, the script emits `dist/Skagway.appcast.xml` (and ensures `dist/Skagway.dmg`).

   Or emit the appcast alone from an existing DMG:

   ```bash
   bash scripts/emit_sparkle_appcast.sh dist/Skagway.dmg
   ```

2. **Publish both files together** to the downloads host (overwrite in place):

   - `https://downloads.machiilabs.com/Skagway.dmg`
   - `https://downloads.machiilabs.com/Skagway.appcast.xml`

   **Critical:** The appcast `length` and `sparkle:edSignature` are computed from the **exact DMG bytes** you upload. If the appcast is new but `Skagway.dmg` on the CDN is still an older build, Sparkle shows **“The update is improperly signed and could not be validated.”** Upload the DMG first (or both in the same session), then verify:

   ```bash
   bash scripts/verify_sparkle_publish.sh dist/Skagway.appcast.xml
   ```

3. **Cloudflare:** A **Bypass cache** rule applies to `/Skagway.dmg` and `/Skagway.appcast.xml` — no manual purge on normal releases. (One-time purge was needed before that rule existed.)

4. **Verify (required):**

   ```bash
   bash scripts/verify_sparkle_publish.sh dist/Skagway.appcast.xml
   ```

5. Smoke-test: install the previous build → **Skagway → Check for Updates…** → should offer the new build.

## In-app surfaces

- **Skagway → Check for Updates…** (manual)
- **Settings → Library → Automatically check for updates** (scheduled; daily interval when on)

## Privacy

Sparkle only fetches the appcast (and, when updating, the DMG). No usage analytics. Auto-check does not run until the user turns it on.
