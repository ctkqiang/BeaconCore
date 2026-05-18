EBIN_DIR = ebin
SRC_DIR  = src
ERLC = erlc
ERL  = erl
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
	@echo "正在编译 BeaconCore 原生源代码..."
	@echo "========================================="
	$(ERLC) -o $(EBIN_DIR)/ main.erl beacon_core_supervisor.erl
	@if [ -d "$(SRC_DIR)" ]; then \
		$(ERLC) -o $(EBIN_DIR)/ $(SRC_DIR)/**/*.erl; \
	fi
	@echo "编译完成.输出目录: /$(EBIN_DIR)"


.PHONY: run
run: all
	@echo "========================================="
	@echo "正在启动 BeaconCore 集群节点..."
	@echo "========================================="
	$(ERL) -pa $(EBIN_DIR)/ \
	       -name $(NODE_NAME) \
	       -setcookie $(COOKIE) \
	       -config config/sys \
	       -eval "application:start(beacon_core)."


.PHONY: clean
clean:
	@echo "正在清理编译后的 beam 文件..."
	@rm -rf $(EBIN_DIR)/*.beam
	@echo "清理完成."