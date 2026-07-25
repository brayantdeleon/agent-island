# Petdex-compatible Codex pets

Open Island can render the user's locally installed Codex pet in the closed
island while a Codex session is running. This integration is local-only: the
app never downloads, bundles, or redistributes community pet artwork.

## Selection

Open Island follows Petdex's active selection in `~/.petdex/active.json`:

```json
{"slug":"null-signal"}
```

It looks for that slug under `~/.petdex/pets/` and then `~/.codex/pets/`.
If there is no valid active selection, it uses the first valid installed pet.
If no package can be loaded, the code-drawn Codex companion remains the
fallback.

Pet selection is read when the app process starts. Relaunch Open Island after
changing `active.json` or installing a different pet.

## Package validation

A usable package contains `pet.json` and either `spritesheet.webp` or
`spritesheet.png`. Open Island accepts the standard 8-column, 9-row v1 atlas
and the 8-column, 11-row v2 atlas. Active work uses the six frames in row 7.

The loader rejects path traversal, oversized manifests, spritesheets larger
than 32 MB, and atlases whose dimensions do not match their declared grid.
