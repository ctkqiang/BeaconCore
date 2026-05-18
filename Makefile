EBIN_DIR  = ebin
SRC_DIR   = src
ERL       = erl
NODE_NAME = beacon_core@127.0.0.1
COOKIE    = beacon_secret

.PHONY: all
all: init compile

.PHONY: init
init:
	@mkdir -p $(EBIN_DIR)

.PHONY: compile
compile: init
	@echo "========================================="
	@echo "Compiling BeaconCore source..."
	@echo "========================================="
	@$(ERL) -noshell \
		-eval 'compile:file("main.erl", [{outdir,"ebin"}, return_errors])' \
		-eval 'compile:file("beacon_core_supervisor.erl", [{outdir,"ebin"}, return_errors])' \
		-s init stop
	@if [ -d "$(SRC_DIR)" ]; then \
		for f in $(SRC_DIR)/*.erl; do \
			$(ERL) -noshell -eval "compile:file(\"$$f\", [{outdir,\"$(EBIN_DIR)\"}, return_errors])" -s init stop; \
		done; \
	fi
	@echo "Compile done. Output: $(EBIN_DIR)/"


.PHONY: run
run: all
	@echo "========================================="
	@echo "Launching BeaconCore cluster node..."
	@echo "========================================="
	$(ERL) -pa $(EBIN_DIR)/ \
	       -name $(NODE_NAME) \
	       -setcookie $(COOKIE) \
	       -config config/sys \
	       -eval "application:start(beacon_core)."


.PHONY: clean
clean:
	@echo "Cleaning compiled beam files..."
	@rm -rf $(EBIN_DIR)/*.beam
	@echo "Clean done."