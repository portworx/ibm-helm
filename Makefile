PX_VERSION := 3.3.1.3

SHELL := /bin/bash
.ONESHELL:
ICR_DESTINATION := icr.io/ext/portworx
SCRIPT_PATH     := /tmp/air-gapped.sh
COMMAND         := bash $(SCRIPT_PATH)
GIT_BRANCH      ?= $(shell git branch --show-current)

.PHONY: clean pull publish fetch-script

pull: fetch-script
	$(COMMAND) pull

publish: fetch-script
	$(COMMAND) push $(ICR_DESTINATION)

fetch-script:
	@set -euo pipefail
	@curl -fsSL "https://install.portworx.com/$(PX_VERSION)/air-gapped" -o "$(SCRIPT_PATH)"
	@TMP=$$(mktemp)
	@curl -fsSL "https://install.portworx.com/$(PX_VERSION)/version" \
		| docker run --rm -i mikefarah/yq:4 -r '.components[]' - \
		| awk '{ if ($$0 !~ /^[^\/]+\.[^\/]+\//) print "IMAGES=\"$$IMAGES docker.io/"$$0"\""; else print "IMAGES=\"$$IMAGES " $$0 "\""; }' > $$TMP
	@sed '/^IMAGES=""$$/ r '$$TMP'' "$(SCRIPT_PATH)" > "$(SCRIPT_PATH).new"
	@mv "$(SCRIPT_PATH).new" "$(SCRIPT_PATH)"
	@awk '/^IMAGES=""$$/ {print; insec=1; next} insec && /^IMAGES="/ {if (!seen[$$0]++) print; next} {if (insec && $$0 !~ /^IMAGES="/) insec=0; print}' "$(SCRIPT_PATH)" > "$(SCRIPT_PATH).new"
	@mv "$(SCRIPT_PATH).new" "$(SCRIPT_PATH)"
	@rm -f $$TMP

clean:
	@rm -f $(SCRIPT_PATH)

lint:
	helm lint chart/portworx --set kvdb="etcd:http://<your-kvdb-endpoint>:2379"

package-helm: lint
	cd repo/stable; \
	helm package ../../chart/portworx; \
	helm repo index . --url "https://raw.githubusercontent.com/portworx/ibm-helm/$(GIT_BRANCH)/repo/stable"
