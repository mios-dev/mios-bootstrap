# profile/

User-space ignition profile applied by `install.sh`.

Layout (populate as the project grows):

- `dotfiles/`  -- skel-style dotfiles symlinked into `~` for the created user
- `systemd/`   -- per-user systemd units (`.config/systemd/user/`)
- `gnome/`     -- dconf snapshots and extension manifests
- `xdg/`       -- XDG config templates

Bootstrap's `install.sh` reads from this tree and stages files into the
created user's home and XDG dirs. Ownership and mode are preserved.
