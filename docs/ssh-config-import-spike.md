# SSH Config Import — design notes

Status: implemented on `feature/ssh-config-import`. See `docs/TODO.md` for the
remaining backlog.

## Approach

The app runs **without App Sandbox** (see `macSCP/macSCP.entitlements`). That is
what makes a plain "read `~/.ssh/config` on click" flow possible: no NSOpenPanel
grant, no security-scoped bookmarks, and `Include` targets outside `~/.ssh` can be
read when the file is accessible.

Flow: toolbar button → parse `~/.ssh/config` → preview sheet (all hosts selected
by default) → Import → save through `ConnectionRepository` → refresh list and
select the first imported host.

## Files

| File | Purpose |
|---|---|
| `macSCP/Domain/Models/SSHConfigEntry.swift` | Parser output (`SSHConfigEntry`), `SSHConfigWarning` (with per-alias attribution), `SSHConfigParseResult` |
| `macSCP/Data/SSHConfig/SSHConfigParser.swift` | ssh_config reader: Host/HostName/User/Port/IdentityFile/Include, `=` syntax, quotes, comments, `%h/%r/%p/%d/%u/%%`, first-obtained-value-wins, wildcard/negation patterns, cycle-safe Include |
| `macSCP/Data/SSHConfig/SSHConfigImporter.swift` | Entry → `Connection` mapping (root level, `ssh-config` tag) |
| `macSCP/Data/SSH/SSHPrivateKeyLoader.swift` | OpenSSH header inspection (RSA/ed25519, encrypted or not) + Citadel auth method construction; shared by SFTP and terminal |
| `macSCP/Features/Connections/SSHConfigImportViewModel.swift` | Preview state: rows, selection, warnings |
| `macSCP/Features/Connections/Components/SSHConfigImportSheet.swift` | Preview UI: checkboxes, per-host warnings, Select All / Import |
| `macSCPTests/Services/SSHConfigParserTests.swift` | 22 parser tests, hermetic |
| `macSCPTests/Services/SSHConfigImporterTests.swift` | Mapping tests |
| `macSCPTests/Services/SSHPrivateKeyLoaderTests.swift` | Key detection/error tests; keys generated at runtime, none committed |
| `macSCPTests/Features/SSHConfigImportViewModelTests.swift` | Preview/selection tests |

## Supported ssh_config semantics

- `Host` with multiple aliases, `*`/`?` patterns, `!` negation.
- `HostName`, `User`, `Port`, `IdentityFile` (ordered), `Include` (recursive, glob, cycle-safe, depth-capped).
- `Keyword value` and `Keyword=value`, `#` comments, quoted values.
- ssh's first-obtained-value-wins rule across blocks, in file order.
- `Match` blocks are recognised but ignored.

Intentional divergences from ssh:

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
| Key file unreadable | "Cannot read the private key at …" |
| Legacy PEM / not OpenSSH | convert with `ssh-keygen -p -f` |
| Key type other than RSA/ed25519 | names the unsupported type |
| Encrypted key, no passphrase | "protected by a passphrase, which is not supported yet" |
| Encrypted key, wrong passphrase | "passphrase … is incorrect" |
| Encrypted key, bcrypt rounds >= 18 | actionable message with `ssh-keygen -p -a 16` (Citadel 0.11.x limit; OpenSSH 10 defaults to 24) |
| RSA rejected by the server | explains that Citadel signs with legacy `ssh-rsa` (SHA-1) and suggests ed25519 |

Passphrase input is intentionally out of scope for this change; the loader
already accepts the parameter and passes it to Citadel's `decryptionKey:`.

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

## Verification

Run the full suite:

```bash
xcodebuild test -project macSCP.xcodeproj -scheme macSCP -destination 'platform=macOS'
```

Compare parser output with real ssh, per alias:

```bash
for alias in $(grep -i '^host ' ~/.ssh/config | awk '{print $2}'); do
  echo "== $alias"
  ssh -G "$alias" | grep -Ei '^(hostname|user|port|identityfile) '
done
```

## Local config observations

Parsing the local `~/.ssh/config` yields 5 entries:

| alias | target | auth | note |
|---|---|---|---|
| `orb` | `default@127.0.0.1:32222` | ed25519 | comes from `Include ~/.orbstack/ssh/config`; needs `ProxyCommand`, so it imports but cannot connect |
| `devbox-wsl-lan` | `deploy@workstation.local:22` | rsa | |
| `devbox-wsl-tailnet` | `deploy@buildhost.example.net:22` | rsa | |
| `lab-host` | `deploy@lab.example.com:1185` | rsa | |
| `lab-host-codex` | `deploy@lab.example.com:1185` | rsa | same target as above |

Notes that shaped the parser: `HostName` values can carry trailing spaces, and
real configs do rely on `Include` pointing outside `~/.ssh`.
