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
		-eval 'compile:file("beacon_core.erl", [{outdir,"ebin"}, return_errors])' \
		-eval 'compile:file("beacon_core_supervisor.erl", [{outdir,"ebin"}, return_errors])' \
		-s init stop
	@if [ -d "$(SRC_DIR)" ]; then \
		for f in $(SRC_DIR)/*.erl; do \
			$(ERL) -noshell -eval "compile:file(\"$$f\", [{outdir,\"$(EBIN_DIR)\"}, return_errors])" -s init stop; \
		done; \
	fi
	@echo "Compile done. Output: $(EBIN_DIR)/"

.PHONY: run
run: compile
	@echo "========================================="
	@echo "Launching BeaconCore Production..."
	@echo "========================================="
	@nohup erl -pa ebin/ \
		-name $(NODE_NAME) \
		-setcookie $(COOKIE) \
		-config config/sys \
		-eval "application:start(beacon_core), io:format('~nApp running~n'), timer:sleep(infinity)." \
		-noinput > beacon.log 2>&1 &
	@echo "Started. PID: $$! - Check beacon.log for details."

.PHONY: dev
dev: compile
	@echo "========================================="
	@echo "Launching BeaconCore Development Node..."
	@echo "========================================="
	erl -pa ebin/ \
		-name $(NODE_NAME) \
		-setcookie $(COOKIE) \
		-config config/sys \
		-eval "application:start(beacon_core)."

.PHONY: clean
clean:
	@echo "Cleaning compiled beam files..."
	@rm -rf $(EBIN_DIR)/*.beam
	@echo "Clean done."