# Vigil 1.0 App Store screenshots

These assets use only the fictional values in `DemoData`; never replace them
with a real account capture. The canonical order and captions are in
`captions/en-US.json`.

The raw English (US) captures target Apple’s current highest-resolution
portrait wells:

- iPhone 17 Pro Max: `1320 x 2868`
- iPad Pro 13-inch: `2064 x 2752`

Generate the captioned sets with pinned Koubou `0.18.1`:

```sh
kou generate .asc/koubou-iphone.yaml
kou generate .asc/koubou-ipad.yaml
```

`upload_enabled` remains `false` in `.asc/shots.settings.json`. Generate a
review report and obtain release-owner approval before any screenshot apply or
upload. The iPhone set uses `IPHONE_69`; the iPad set uses
`IPAD_PRO_3GEN_129`.
