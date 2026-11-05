# Legacy Kindle news TLS

In [#11](https://github.com/joeseesun/qiaomu-simpleui/issues/11), the reporter observed curl 60 on both routes after .20 and successfully refreshed on the same PW1 using curl's 2026-10-20 Mozilla bundle with `--cacert`. That experiment preceded this package.

The plugin uses that exact bundle for the origin, public fallback and news images. The original URL, Host and SNI still identify rss.qiaomu.ai when routing to the origin. The first curl option is the short `-q` so the old curl skips .curlrc. Missing or invalid CA data fails closed. See the [packaged CA notes](../simpleui.koplugin/data/ca/README.md) for provenance and updates.

The loopback TLS regression exercises the actual Lua request command and checks trusted, untrusted, wrong-host and expired certificates, missing/empty/invalid CA, and a fixture .curlrc containing insecure. The build checks the bundled bytes and includes the MPL notice. Desktop regression is separate from curl 7.33 device acceptance.

Before closing #11, record model, firmware, KOReader, plugin version, device time and curl/TLS backend. Back up the installed plugin via the paired and pinned connection, install the complete package and verify the bundled CA checksum. Restart KOReader, refresh News and open an uncached article with an HTTPS image. Check the origin and public routes separately and confirm cached articles still open offline. The original PW1 acceptance is pending.
