# Project maintenance

- Prefer an already paired Wi-Fi SSH/SFTP connection for Kindle diagnosis, backups and plugin updates. Check the paired host and its pinned host fingerprint first; request USB only if the wireless path is unavailable and cannot be restored normally.
- Reuse credentials inside their existing credential store/client process. Do not export private keys, disable host verification or publish device settings/logs.
- Back up the installed plugin before replacement, verify uploaded file hashes, and preserve settings and hidden records. Avoid rewriting settings while KOReader is running.
- A transferred package is not proof of runtime acceptance. Ask for restart/visual feedback and distinguish it from automated regression checks.
- Before release run tests/test_customizations.py, tests/test_refresh_lifecycle.py, tests/test_weread_lifecycle.py, locale validation and scripts/package.py. Upload only the installable ZIP and SHA256SUMS; dist/installation-receipt-private.json stays local.
- Also run tests/test_arrivals.py, tests/test_home_controls.py and tests/test_news.py for shelf/news changes. Keep news caches, device screenshots and settings out of Git and installation ZIPs. Verify actual Kindle HTTPS separately from desktop requests.
