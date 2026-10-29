.PHONY: check lint test

check: lint test

lint:
	shellcheck -s bash release.sh test/helpers/bin/gh test/helpers/bin/curl

test:
	bats test/
