# Vendored YAML editor

CodeMirror **5.65.21**, MIT licensed. These files are copied without modification from the npm release:

- `lib/codemirror.js` → `codemirror.js`
- `lib/codemirror.css` → `codemirror.css`
- `mode/yaml/yaml.js` → `yaml.js`
- `LICENSE` → `LICENSE`

Source: https://registry.npmjs.org/codemirror/-/codemirror-5.65.21.tgz

npm integrity: `sha512-6teYk0bA0nR3QP0ihGMoxuKzpl5W80FpnHpBJpgy66NK3cZv5b/d/HY8PnRvfSsCG1MTfr92u2WUl+wT0E40mQ==`

CodeMirror 5 is the legacy branch. Its prebuilt browser files let this small Ruby application provide YAML highlighting and indentation without introducing a frontend build or a Node runtime. Only the YAML mode is bundled; there are no CDN requests. CodeMirror 6 is more actively maintained but requires a different integration.

SHA-256 of the upstream files:

```text
e98aac5ffa07bae58acd4ff07c4293059f8921c0ae0eba506929d8c6f41c9288  codemirror.js
eb494ea972d2661ef86f7f6ac656dd6786d721e49c9c1b46e1eb967e4b6f9bf3  codemirror.css
7de73109e5bfb6951d53764f5210f00f7859b57525811fab6b6f843980a7726e  yaml.js
168a4becc968f5001e2ee2e0291b6e4daabafc1894a11ade1e11d56e96096e07  LICENSE
```

To update, use `npm pack codemirror@<reviewed-version>` in a temporary directory, verify the release, copy only these files, update this provenance, and rerun the editor/browser tests. Keep the license with the bundled files. Runtime installation is not needed.
