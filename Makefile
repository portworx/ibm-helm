PX_VERSION      := 3.3.1.3
ICR_DESTINATION := icr.io/ext/portworx
SCRIPT_PATH     := /tmp/air-gapped.sh
COMMAND         := bash $(SCRIPT_PATH)
GIT_BRANCH      ?= $(shell git branch --show-current)

.PHONY: clean pull publish fetch-script

pull: fetch-script
	$(COMMAND) pull

publish: fetch-script
	$(COMMAND) push $(ICR_DESTINATION)

fetch-script: clean
	@curl -fsSL https://install.portworx.com/$(PX_VERSION)/air-gapped -o $(SCRIPT_PATH)

clean:
	@rm -f $(SCRIPT_PATH)

lint:
	helm lint chart/portworx --set kvdb="etcd:http://<your-kvdb-endpoint>:2379"

package-helm: lint
	cd repo/stable; \
	helm package ../../chart/portworx; \
	helm repo index . --url "https://raw.githubusercontent.com/portworx/ibm-helm/$(GIT_BRANCH)/repo/stable"
