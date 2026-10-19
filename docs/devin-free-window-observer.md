# Devin SWE-2 free-window observer

Install scopefuel before agent-skills. The minimum scopefuel commit that accepts `observe devin-free-limit` is `99abef2b3b8636d06b04080b90b047dad79a0ec7`. Older scopefuel versions reject the command; the completion sentinel records the failure and continues the job lifecycle.

For the six free Devin SWE-2 spellings, wrk reads only the pane's bounded `recent-unwrapped` transcript. It records a matching rate-limit message once per job/reset, with the observed time, reset, source rung, and job id. The observer does not read agent configuration or credentials and does not send pane input. Other providers and paid Devin spellings do not enter this read path.

Scopefuel uses a cached, credential-free account-kind fingerprint when available. Until then it keys the observation by a host and Unix-user hash. That fallback is host-local and can group multiple Devin accounts used by the same Unix user. The existing quota-share channel has no typed observation record or gate-time reader, so this limit does not propagate across hosts.
