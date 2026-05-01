# profile/

Per-user dotfile and config skeleton staged into `~<user>/` by
`install.sh:trigger_mios_install` after the Total Root Merge. The contents
are copied verbatim, then `chown`'d to the new user.

## Layout

```
profile/
├── .bashrc                          # shell init (optional)
├── .config/
│   └── mios/
│       └── profile.toml             # per-user copy of /etc/mios/profile.toml
└── .ssh/                            # optional placeholder; installer populates id_*
```

The system-wide profile at `/etc/mios/profile.toml` is the source of truth;
per-user `~/.config/mios/profile.toml` overrides specific fields. Run
`mios init-user-space` on first login to reseed per-user state from the
system profile.
