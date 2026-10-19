# SSH Config Import — design notes

Status: implemented on `feature/ssh-config-import`. See `docs/TODO.md` for the
remaining backlog.

## Approach

The app keeps **App Sandbox** enabled and only receives access to a file the user
explicitly picks:

1. Toolbar button → `NSOpenPanel` (opens at `~/.ssh`) → user selects a config file.
2. That file — and nothing else — is parsed.
3. A preview sheet lists the hosts (all selected by default); confirming writes
   them to SwiftData and selects the first imported host.

`Include` directives are **not followed**: the sandbox grant covers only the
selected file, so referenced files are never opened. Each `Include` produces an
`includeSkipped` warning that the preview displays, so hosts living in included
files are visibly missing rather than silently dropped.

## Files

| File | Purpose |
|---|---|
| `macSCP/Domain/Models/SSHConfigEntry.swift` | Parser output (`SSHConfigEntry`), `SSHConfigWarning` (with per-alias attribution), `SSHConfigParseResult` |
| `macSCP/Data/SSHConfig/SSHConfigParser.swift` | ssh_config reader: Host/HostName/User/Port/IdentityFile, `=` syntax, quotes, comments, `%h/%r/%p/%d/%u/%%`, first-obtained-value-wins, wildcard/negation patterns; `Include` reported and skipped |
| `macSCP/Data/SSHConfig/SSHConfigImporter.swift` | Entry → `Connection` mapping (root level, `ssh-config` tag) |
| `macSCP/Data/SSH/SSHPrivateKeyLoader.swift` | OpenSSH header inspection (RSA/ed25519, encrypted or not) + Citadel auth method construction; shared by SFTP and terminal |
| `macSCP/Features/Connections/SSHConfigFilePicker.swift` | Sandbox-friendly `NSOpenPanel` that starts in `~/.ssh` |
| `macSCP/Features/Connections/SSHConfigImportViewModel.swift` | Preview state: rows, selection, warnings |
| `macSCP/Features/Connections/Components/SSHConfigImportSheet.swift` | Preview UI: checkboxes, per-host warnings, Select All / Import, empty-state notes |
| `macSCP/Data/SwiftData/SwiftDataStoreMigrator.swift` | Moves a legacy `default.store` into the app-specific location |

## Supported ssh_config semantics

- `Host` with multiple aliases, `*`/`?` patterns, `!` negation.
- `HostName`, `User`, `Port`, `IdentityFile` (ordered), `Include` (reported, skipped).
- `Keyword value` and `Keyword=value`, `#` comments, quoted values.
- ssh's first-obtained-value-wins rule across blocks, in file order; global
  directives take their position in that order.
- `Match` blocks are recognised but ignored.

Intentional divergences from ssh:

- `Include` targets are never read.
- Wildcard `Host` patterns (`*.example.com`) are not importable; they are skipped with a warning.
- Unknown `%` tokens pass through literally.
- Host patterns are matched case-insensitively.
- `ProxyJump` / `ProxyCommand` / forwarding directives are not executed; they surface as warnings.

## Authentication

`SSHPrivateKeyLoader` sniffs the OpenSSH key header instead of hardcoding an
algorithm, so RSA and ed25519 both work in SFTP and terminal sessions. Failure
modes are distinct and actionable:

| Condition | Error |
|---|---|
| Key file unreadable (including sandbox denial) | "Cannot read the private key at …" |
| Legacy PEM / not OpenSSH | convert with `ssh-keygen -p -f` |
| Key type other than RSA/ed25519 | names the unsupported type |
| Encrypted key, no passphrase | "protected by a passphrase, which is not supported yet" |
| Encrypted key, wrong passphrase | "passphrase … is incorrect" |
| Encrypted key, bcrypt rounds >= 18 | actionable message with `ssh-keygen -p -a 16` (Citadel 0.11.x limit; OpenSSH 10 defaults to 24) |
| RSA rejected by the server | explains that Citadel signs with legacy `ssh-rsa` (SHA-1) and suggests ed25519 |

Known library limit: Citadel (0.11.x and 0.12.x) signs RSA authentication with
SHA-1 and labels the signature `ssh-rsa`. OpenSSH 8.8+ disables that algorithm by
default, so servers that require `rsa-sha2-256/512` reject RSA keys. Verified
against the local server: the default OpenSSH client authenticates with
`rsa-sha2-512`, while forcing `PubkeyAcceptedAlgorithms=ssh-rsa` is denied.
The connection error explains this and points at ed25519 keys.

Known library limit: Citadel 0.11.x rejects bcrypt KDF rounds >= 18, while
OpenSSH 10 (macOS 27) defaults to 24. Encrypted keys from this machine therefore
fail even with the correct passphrase; the loader detects the rounds up front and
tells the user to re-encrypt with `-a 16` or use an unencrypted key.

Passphrase input is intentionally out of scope; the loader already accepts the
parameter and passes it to Citadel's `decryptionKey:`.

## Data location

Inside App Sandbox the store lives in the app container:

```
~/Library/Containers/com.macscp.macSCP/Data/Library/Application Support/macSCP/macSCP.store
```

On first launch the app moves SwiftData's default `default.store` from the same
Application Support directory (where pre-change builds kept it) into that
app-specific file. The migration moves `-wal`/`-shm` first and the main file last,
rolls back partial moves, and only adopts a shared `default.store` when it
contains macSCP's schema (`ZCONNECTIONENTITY`).

## Verification

```bash
xcodebuild test -project macSCP.xcodeproj -scheme macSCP \
  -destination 'platform=macOS' -only-testing:macSCPTests
```

Compare parser output with real ssh, per alias (excluding included files):

```bash
for alias in $(grep -i '^host ' ~/.ssh/config | awk '{print $2}'); do
  echo "== $alias"
  ssh -G "$alias" | grep -Ei '^(hostname|user|port|identityfile) '
done
```

## Local config observations

Selecting the local `~/.ssh/config` yields 4 entries, plus one warning because the
file starts with `Include ~/.orbstack/ssh/config`:

| alias | target | auth |
|---|---|---|
| `devbox-wsl-lan` | `deploy@workstation.local:22` | rsa |
| `devbox-wsl-tailnet` | `deploy@buildhost.example.net:22` | rsa |
| `lab-host` | `deploy@lab.example.com:1185` | rsa |
| `lab-host-codex` | `deploy@lab.example.com:1185` | rsa |

Notes that shaped the parser: `HostName` values can carry trailing spaces, and
the `Include` line is skipped rather than resolved.
