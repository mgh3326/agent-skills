These stdout and stderr captures are the devin-swe2 and grok outputs from the
pre-1488 bin/wrk at base commit 8a914eb5b584d8383b7169ac9583b77160f635ee.
They use the landing-marker scenario and the test herdr, panewire, scopefuel,
and handoffkeep fixtures. A focused derived run compared the captured base
outputs with the current implementation byte for byte before recording them.

The suite replaces its unique temporary root with TEST_TMP and the checkout
root with TEST_ROOT. Devin's trust diagnostic includes both paths; all other
stdout and stderr bytes remain part of the comparison.
