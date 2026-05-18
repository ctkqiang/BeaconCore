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
	@echo "Launching BeaconCore Production with Real-time Logs..."
	@echo "========================================="
	erl -pa ebin/ \
		-name $(NODE_NAME) \
		-setcookie $(COOKIE) \
		-config config/sys \
		-eval "application:start(beacon_core), io:format('[BeaconCore] *** APP RUNNING - Listening on port 8080 ***~n'), timer:sleep(infinity)." \
		-noinput

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

.PHONY: kill
kill:
	@echo "========================================="
	@echo "Killing BeaconCore processes..."
	@echo "========================================="
	@taskkill /F /IM erl.exe /T 2>/dev/null || true
	@taskkill /F /IM beam.smp.exe /T 2>/dev/null || true
	@echo "Processes killed."
	@echo ""
	@echo "Running Erlang processes:"
	@tasklist | grep -E "erl|beam" || echo "None running"

.PHONY: clean
clean:
	@echo "Cleaning compiled beam files..."
	@rm -rf $(EBIN_DIR)/*.beam
	@echo "Clean done."