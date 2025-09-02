PX_VERSION      := 3.3.1.3
ICR_DESTINATION := icr.io/ext/portworx
SCRIPT_PATH     := /tmp/air-gapped.sh
COMMAND         := bash $(SCRIPT_PATH)

.PHONY: clean pull publish fetch-script

pull: fetch-script
	$(COMMAND) pull

publish: fetch-script
	$(COMMAND) push $(ICR_DESTINATION)

fetch-script: clean
	@curl -fsSL https://install.portworx.com/$(PX_VERSION)/air-gapped -o $(SCRIPT_PATH)

clean:
	@rm -f $(SCRIPT_PATH)
