# ssh_config import — design notes

Status: implemented on `feature/ssh-config-import`. See `docs/TODO.md` for the
remaining backlog.

## Approach

The app does not assume where an `ssh_config` file lives. The user picks it:

1. Toolbar button → `NSOpenPanel` → user selects an `ssh_config` file.
2. That file — and nothing else — is parsed. `Include` is ignored; referenced
   files are never opened.
3. Hosts already in the database (matched on `host|port|username`) are skipped.
4. The remaining hosts are saved and the first one is selected in the list.

There is no preview step. Unsupported directives and ignored constructs are not
surfaced in the UI.

App Sandbox is disabled so the private key referenced by `IdentityFile` can be
read at connection time.

## Files

| File | Purpose |
|---|---|
| `macSCP/Domain/Models/SSHConfigEntry.swift` | Parser output: alias, host, user, port, absolute identity-file path |
| `macSCP/Data/SSHConfig/SSHConfigParser.swift` | ssh_config reader: Host/HostName/User/Port/IdentityFile, `=` syntax, quotes, comments, `%h/%r/%p/%d/%u/%%`, first-obtained-value-wins, wildcard/negation patterns; `Include` and unsupported directives are ignored silently |
| `macSCP/Data/SSHConfig/SSHConfigImporter.swift` | Entry → `Connection` mapping plus the `host|port|username` deduplication key |
| `macSCP/Features/Connections/SSHConfigFilePicker.swift` | `NSOpenPanel` used to select the file |
| `macSCP/Data/SSH/SSHPrivateKeyLoader.swift` | OpenSSH header inspection (RSA/ed25519, encrypted or not) + Citadel auth method construction; shared by SFTP and terminal |

## Supported ssh_config semantics

- `Host` with multiple aliases, `*`/`?` patterns, `!` negation.
- `HostName`, `User`, `Port`, `IdentityFile` (first one only).
- `Keyword value` and `Keyword=value`, `#` comments, quoted values.
- ssh's first-obtained-value-wins rule across blocks, in file order; global
  directives take their position in that order.
- `Match` blocks are recognised but ignored.

Ignored without diagnostics: `Include`, `ProxyJump`, `ProxyCommand`, forwarding
directives, wildcard-only `Host` blocks, malformed lines, invalid ports (falls
back to 22).

## Identity file handling

The stored path is always absolute, so it stays valid when the key is opened:

| In the file | Stored as |
|---|---|
| `~/.ssh/id_ed25519` | `<home>/.ssh/id_ed25519` |
| `keys/id_ed25519` | `<config directory>/keys/id_ed25519` |
| `/opt/keys/id_rsa` | unchanged |

`%h`, `%r`, `%p`, `%d`, `%u` are expanded before resolving. The key itself is only
read when connecting.

## Deduplication

Imported hosts are compared with what is already stored using
`host|port|username`, lowercased. Duplicates are skipped, including duplicates
within the same import batch. The comparison deliberately ignores the alias, so
re-importing a file whose aliases changed does not create a second connection.

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
| RSA rejected by the server | lists the offered algorithms (`rsa-sha2-512`, `rsa-sha2-256`, `ssh-rsa`) |

RSA authentication uses RFC 8332: Citadel PR #135 (pinned by revision from its
fork) adds `SSHAuthenticationMethod.rsaSHA2`, which offers `rsa-sha2-512`, then
`rsa-sha2-256`, and finally legacy `ssh-rsa` for old servers. Verified live: the
same RSA key that previously failed with `allAuthenticationOptionsFailed`
authenticates successfully against a server that rejects SHA-1.

## Data location

The container keeps SwiftData's default configuration, so the store stays at the
location it has always used (`ModelConfiguration` without an explicit URL). No
custom path, migration or schema probing is involved.

## Verification

```bash
xcodebuild test -project macSCP.xcodeproj -scheme macSCP \
  -destination 'platform=macOS' -only-testing:macSCPTests
```

Parser output can be compared with real ssh, per alias (excluding included files):

```bash
config=/path/to/ssh_config
for alias in $(grep -i '^host ' "$config" | awk '{print $2}'); do
  echo "== $alias"
  ssh -G "$alias" | grep -Ei '^(hostname|user|port|identityfile) '
done
```

## Local config observations

A local ssh_config used for testing yields 4 entries; its `Include` line is
ignored, so hosts defined in the included file are not imported:

| alias | target | auth |
|---|---|---|
| `devbox-wsl-lan` | `deploy@workstation.local:22` | rsa |
| `devbox-wsl-tailnet` | `deploy@buildhost.example.net:22` | rsa |
| `lab-host` | `deploy@lab.example.com:1185` | rsa |
| `lab-host-codex` | `deploy@lab.example.com:1185` | rsa |
