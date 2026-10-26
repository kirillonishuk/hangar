# Monaco Editor

`vs/` is the AMD build (`min/vs`) of **monaco-editor 0.57.0** (https://github.com/microsoft/monaco-editor),
downloaded once from the npm registry (`monaco-editor-0.57.0.tgz`, sha512 checked) with the user's consent.
Removed to keep it small: the TS/CSS/HTML/JSON language-service workers (`assets/*.worker-*`), `language/`,
`*.d.ts` and every UI locale except `ru`. Nothing else is changed.

License: MIT, see `LICENSE.txt`; third-party notices in `ThirdPartyNotices.txt`. Decision `#80` in `docs/decisions.md`.

`hangar/` (index.html, hangar.js, hangar.css) is Hangar's own page around it.
