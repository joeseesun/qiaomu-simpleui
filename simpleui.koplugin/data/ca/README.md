# News CA bundle

The unmodified Mozilla CA store in cacert.pem was obtained from [curl CA Extract](https://curl.se/docs/caextract.html) and verified against the upstream SHA-256. The dated source and checksum are in bundle.json. This data is covered by MPL-2.0, reproduced in LICENSE-MPL-2.0.txt.

Kindle news API requests and news images pass this file with `--cacert`. The initial `-q` skips device curl configuration, keeping certificate and hostname verification enabled. A missing or unusable CA file fails the request.

To refresh the bundle, review the dated PEM and its HTTPS checksum on curl CA Extract, compare the full digest and inspect additions and removals. Replace the PEM unmodified, update bundle.json, and run the TLS test and packaging checks. Distribute the bundle with a reviewed plugin update.
