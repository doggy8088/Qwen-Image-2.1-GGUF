# Qwen-Image 2.1 GGUF × OpenAI 相容圖片 API
#
# 以 stable-diffusion.cpp 的 sd-server 推論 abenzerps/Qwen-Image-2.1-Turbo-Quantized，
# 並提供 /v1/images/generations 與 /v1/images/edits 端點。
#
# 執行 make help 查看所有指令。所有變數都可以在命令列覆寫，例如：
#   make download QUANT=Q8_0
#   make serve PORT=8080 STEPS=30
# 或寫入 .env（參考 .env.example）永久覆寫。

-include .env

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# 模型檔案
# ---------------------------------------------------------------------------
# 擴散模型量化版本：Q4_0 | Q4_K_M | Q5_K_M | Q6_K | Q8_0
QUANT      ?= Q4_K_M
# 文字編碼器（Qwen3-VL-8B）：
#   gguf  Qwen 官方 GGUF + mmproj 視覺權重（預設，量化版本由 TE_QUANT 決定）
#   bf16  abenzerps 倉庫的 BF16 safetensors（17.53 GB）
#   int8  abenzerps 倉庫的 int8 convrot safetensors（sd.cpp 目前無法載入，詳見 README）
TE         ?= gguf
# TE=gguf 時的量化版本：Q4_K_M（5.03 GB）| Q8_0（8.71 GB）| F16（16.39 GB）
TE_QUANT   ?= Q8_0
# 擴散模型來源：原 abenzerps/Qwen-Image-2.1-GGUF 已由作者更名
# （曾名 Qwen-Image-2.1-Uncensored-GGUF，舊名在 HF 上皆 redirect 到此倉庫），
# 檔名也改為 qwen-image-2.1-turbo-<QUANT>.gguf，舊的無前綴與 UC- 檔名已不存在。
HF_REPO    ?= abenzerps/Qwen-Image-2.1-Turbo-Quantized
TE_REPO    ?= Qwen/Qwen3-VL-8B-Instruct-GGUF
MODELS_DIR ?= models

# 擴散模型檔名前綴（不含量化版本）。使用其他來源或本機已有的舊版檔案時覆寫，
# 例如舊版非 Turbo 檔案：DIFFUSION_PREFIX=qwen-image-2.1-
DIFFUSION_PREFIX ?= qwen-image-2.1-turbo-
DIFFUSION_FILE := $(DIFFUSION_PREFIX)$(QUANT).gguf
VAE_FILE       := vae/qwen_image_2.1_vae_bf16.safetensors
VISION_FILE    :=
ifeq ($(TE),gguf)
  LLM_FILE     := text_encoders/Qwen3VL-8B-Instruct-$(TE_QUANT).gguf
  VISION_FILE  := text_encoders/mmproj-Qwen3VL-8B-Instruct-F16.gguf
  TE_FILES     := $(LLM_FILE) $(VISION_FILE)
else ifeq ($(TE),bf16)
  LLM_FILE     := text_encoders/qwen3vl_8b_bf16.safetensors
else ifeq ($(TE),int8)
  LLM_FILE     := text_encoders/qwen3vl_8b_int8_convrot.safetensors
else
  $(error 不支援的 TE=$(TE)，可用值：gguf、bf16、int8)
endif
# HF_FILES 來自 HF_REPO（有 SHA256SUMS）；TE_FILES 來自 TE_REPO
HF_FILES    := $(DIFFUSION_FILE) $(VAE_FILE) $(if $(TE_FILES),,$(LLM_FILE))
MODEL_FILES := $(DIFFUSION_FILE) $(LLM_FILE) $(VISION_FILE) $(VAE_FILE)

HF     ?= $(shell command -v hf 2>/dev/null || echo "uvx --from huggingface_hub hf")
SHA256 ?= $(shell command -v sha256sum 2>/dev/null || echo "shasum -a 256")

# ---------------------------------------------------------------------------
# LoRA（.safetensors，與 GGUF 擴散模型分開存放）
# ---------------------------------------------------------------------------
# 目錄存在時，SERVER_CMD 會自動加上 --lora-model-dir；請求時再由用戶端
# 以結構化 lora 欄位指定要用哪個 LoRA（sd-server 不支援 prompt 內 <lora:...>）。
LORA_DIR  ?= models/loras
# make download-lora 的預設來源：Qwen-Image-2.1 專用的 Lightning 4 步 LoRA
# （針對原版非 Turbo 底模訓練；目前預設的 Turbo 底模本身已蒸餾，不需要它）
LORA_REPO ?= lightx2v/Qwen-Image-2.1-Lightning
LORA_FILE ?= pytorch_lora_weights.safetensors

# ---------------------------------------------------------------------------
# stable-diffusion.cpp
# ---------------------------------------------------------------------------
BIN_DIR           ?= bin
SDCPP_VERSION     ?= master-898-2bb7294
SDCPP_VARIANT     ?= auto
SDCPP_SRC_DIR     ?= .sdcpp-src
SDCPP_GIT_REF     ?= master
SDCPP_CMAKE_FLAGS ?= $(if $(filter Darwin,$(shell uname -s)),-DSD_METAL=ON,$(if $(shell command -v nvcc 2>/dev/null),-DSD_CUDA=ON,))
SD_SERVER         := $(BIN_DIR)/sd-server

# ---------------------------------------------------------------------------
# sd-server 預設生成參數（OpenAI 請求未指定時使用）
# ---------------------------------------------------------------------------
HOST        ?= 127.0.0.1
PORT        ?= 1234
WIDTH       ?= 1024
HEIGHT      ?= 1024
STEPS       ?= 20
CFG         ?= 1.0
SAMPLER     ?= euler
SEED        ?= -1
SERVER_ARGS ?= --diffusion-fa

LOG_DIR  ?= logs
LOG_FILE := $(LOG_DIR)/sd-server.log
PID_FILE := $(LOG_DIR)/sd-server.pid

SERVER_CMD = $(SD_SERVER) \
	--listen-ip $(HOST) --listen-port $(PORT) \
	--diffusion-model $(MODELS_DIR)/$(DIFFUSION_FILE) \
	--llm $(MODELS_DIR)/$(LLM_FILE) \
	$(if $(VISION_FILE),--llm_vision $(MODELS_DIR)/$(VISION_FILE)) \
	--vae $(MODELS_DIR)/$(VAE_FILE) \
	$(if $(wildcard $(LORA_DIR)),--lora-model-dir $(LORA_DIR)) \
	-W $(WIDTH) -H $(HEIGHT) --steps $(STEPS) --cfg-scale $(CFG) \
	--sampling-method $(SAMPLER) --seed $(SEED) \
	$(SERVER_ARGS)

# ---------------------------------------------------------------------------
# 用戶端
# ---------------------------------------------------------------------------
CLIENT_HOST := $(if $(filter 0.0.0.0,$(HOST)),127.0.0.1,$(HOST))
BASE_URL    ?= http://$(CLIENT_HOST):$(PORT)/v1
PROMPT      ?= A neon shop sign that reads "QWEN IMAGE 2.1", rainy night, reflections on wet pavement
SIZE        ?= $(WIDTH)x$(HEIGHT)
N           ?= 1
IMAGE       ?=
# LoRA 規格（空白分隔，可多個）：檔名[:權重]，例如 LORA='style.safetensors:0.8'
LORA        ?=
OUT_DIR     ?= outputs
CLIENT_ARGS ?=
UV          ?= uv
CLIENT       = $(UV) run --quiet scripts/client.py --base-url $(BASE_URL)

# ---------------------------------------------------------------------------

.PHONY: help
help: ## 顯示所有可用指令
	@printf '\n\033[1mQwen-Image 2.1 GGUF × OpenAI 相容圖片 API\033[0m\n\n'
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\n目前設定：QUANT=%s TE=%s PORT=%s STEPS=%s CFG=%s（詳見 make config）\n\n' '$(QUANT)' '$(TE)$(if $(TE_FILES),:$(TE_QUANT))' '$(PORT)' '$(STEPS)' '$(CFG)'

.PHONY: config
config: ## 顯示目前的設定值與模型路徑
	@echo "sd.cpp 版本       : $$(cat $(BIN_DIR)/.sdcpp-version 2>/dev/null || echo 未安裝)（目標 $(SDCPP_VERSION)）"
	@echo "擴散模型          : $(MODELS_DIR)/$(DIFFUSION_FILE)"
	@echo "文字編碼器        : $(MODELS_DIR)/$(LLM_FILE)"
	@echo "視覺權重          : $(if $(VISION_FILE),$(MODELS_DIR)/$(VISION_FILE),（內含於文字編碼器）)"
	@echo "VAE               : $(MODELS_DIR)/$(VAE_FILE)"
	@echo "模型來源          : $(HF_REPO)"
	@echo "LoRA 目錄         : $(LORA_DIR)（$(if $(wildcard $(LORA_DIR)),啟動時會傳 --lora-model-dir,目錄不存在，不啟用)）"
	@echo "監聽位址          : $(HOST):$(PORT)"
	@echo "預設尺寸/步數/CFG : $(WIDTH)x$(HEIGHT) / $(STEPS) / $(CFG)"
	@echo "取樣器/種子       : $(SAMPLER) / $(SEED)"
	@echo "額外伺服器參數    : $(SERVER_ARGS)"
	@echo "API 位址          : $(BASE_URL)"

.PHONY: setup
setup: install download ## 一次完成安裝 sd.cpp 與下載模型

# ---- 安裝 ------------------------------------------------------------------

.PHONY: install
install: ## 下載 stable-diffusion.cpp 預先編譯版本到 bin/
	@SDCPP_VERSION='$(SDCPP_VERSION)' SDCPP_VARIANT='$(SDCPP_VARIANT)' BIN_DIR='$(BIN_DIR)' \
		./scripts/install-sdcpp.sh

.PHONY: build-sdcpp
build-sdcpp: ## 從原始碼編譯 sd.cpp（CUDA 等無預先編譯版本的平台）
	@command -v cmake >/dev/null || { echo "需要 cmake"; exit 1; }
	@if [ -d $(SDCPP_SRC_DIR)/.git ]; then \
		git -C $(SDCPP_SRC_DIR) fetch --depth 1 origin $(SDCPP_GIT_REF) && \
		git -C $(SDCPP_SRC_DIR) checkout -q FETCH_HEAD && \
		git -C $(SDCPP_SRC_DIR) submodule update --init --recursive --depth 1; \
	else \
		git clone --depth 1 --branch $(SDCPP_GIT_REF) --recurse-submodules --shallow-submodules \
			https://github.com/leejet/stable-diffusion.cpp $(SDCPP_SRC_DIR); \
	fi
	cmake -S $(SDCPP_SRC_DIR) -B $(SDCPP_SRC_DIR)/build -DCMAKE_BUILD_TYPE=Release $(SDCPP_CMAKE_FLAGS)
	cmake --build $(SDCPP_SRC_DIR)/build --config Release -j --target sd-server sd-cli
	@mkdir -p $(BIN_DIR)
	@cp -f $(SDCPP_SRC_DIR)/build/bin/sd-* $(BIN_DIR)/
	@find $(SDCPP_SRC_DIR)/build -maxdepth 3 \( -name 'libstable-diffusion*' -o -name 'libggml*' \) \
		\( -name '*.dylib' -o -name '*.so*' \) -exec cp -f {} $(BIN_DIR)/ \;
	@echo "source-$$(git -C $(SDCPP_SRC_DIR) rev-parse --short HEAD)" > $(BIN_DIR)/.sdcpp-version
	@$(SD_SERVER) -h 2>&1 | head -1

# ---- 模型 ------------------------------------------------------------------

.PHONY: download
download: ## 從 Hugging Face 下載模型（QUANT、TE、TE_QUANT 可調整）
	$(HF) download $(HF_REPO) $(HF_FILES) SHA256SUMS --local-dir $(MODELS_DIR) || { \
		echo "下載失敗：請確認 HF_REPO=$(HF_REPO) 存在，且其中有 $(DIFFUSION_FILE) 等檔案（QUANT=$(QUANT)、DIFFUSION_PREFIX=$(DIFFUSION_PREFIX)）。原 abenzerps/Qwen-Image-2.1-GGUF 已更名為 abenzerps/Qwen-Image-2.1-Turbo-Quantized，詳見 README 的「模型檔案」。"; exit 1; }
ifneq ($(TE_FILES),)
	$(HF) download $(TE_REPO) $(notdir $(TE_FILES)) --local-dir $(MODELS_DIR)/text_encoders
endif

.PHONY: download-lora
download-lora: ## 下載 LoRA 到 LORA_DIR（預設 Qwen-Image-2.1 Lightning；LORA_REPO、LORA_FILE 可覆寫）
	$(HF) download $(LORA_REPO) $(LORA_FILE) --local-dir $(LORA_DIR) || { \
		echo "下載失敗：請確認 LORA_REPO=$(LORA_REPO) 存在，且其中有 $(LORA_FILE)。"; exit 1; }
	@echo "已下載：$(LORA_DIR)/$(LORA_FILE)"
	@echo "重新啟動伺服器（make restart）後，以 LORA='$(LORA_FILE):1.0' 傳給 make generate 使用；LoRA 必須與底模版本相容。"

.PHONY: verify
verify: ## 驗證已下載模型檔案的 SHA256
	@test -f $(MODELS_DIR)/SHA256SUMS || { echo "找不到 $(MODELS_DIR)/SHA256SUMS，請先執行 make download"; exit 1; }
	@cd $(MODELS_DIR) && for f in $(HF_FILES); do grep -E "  $$f$$" SHA256SUMS; done | $(SHA256) -c -
ifneq ($(TE_FILES),)
	@# TE_REPO 沒有 SHA256SUMS，改用 Hugging Face API 回傳的 LFS SHA256
	@curl -sf https://huggingface.co/api/models/$(TE_REPO)/tree/main \
		| python3 -c 'import json, sys; want = set(sys.argv[1:]); [print(x["lfs"]["oid"] + "  " + x["path"]) for x in json.load(sys.stdin) if x["path"] in want]' $(notdir $(TE_FILES)) \
		| (cd $(MODELS_DIR)/text_encoders && $(SHA256) -c -)
endif

.PHONY: check
check:
	@test -x $(SD_SERVER) || { echo "找不到 $(SD_SERVER)，請先執行 make install"; exit 1; }
	@for f in $(MODEL_FILES); do \
		test -f "$(MODELS_DIR)/$$f" || { echo "找不到 $(MODELS_DIR)/$$f，請先執行 make download"; exit 1; }; \
	done

# ---- 伺服器 ----------------------------------------------------------------

.PHONY: serve
serve: check ## 在前景啟動 sd-server（Ctrl+C 結束）
	$(SERVER_CMD)

.PHONY: start
start: check ## 在背景啟動 sd-server 並等待就緒
	@mkdir -p $(LOG_DIR)
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		echo "sd-server 已在執行（PID $$(cat $(PID_FILE))）"; exit 0; \
	fi
	@nohup $(SERVER_CMD) > $(LOG_FILE) 2>&1 & echo $$! > $(PID_FILE)
	@printf '啟動 sd-server（PID %s），記錄檔：%s\n' "$$(cat $(PID_FILE))" '$(LOG_FILE)'
	@for i in $$(seq 1 300); do \
		if curl -sf $(BASE_URL)/models >/dev/null 2>&1; then echo "就緒：$(BASE_URL)"; exit 0; fi; \
		kill -0 $$(cat $(PID_FILE)) 2>/dev/null || { echo "sd-server 已結束，最後的記錄："; tail -n 30 $(LOG_FILE); rm -f $(PID_FILE); exit 1; }; \
		sleep 1; \
	done; echo "等待逾時，請執行 make logs 查看記錄"; exit 1

.PHONY: stop
stop: ## 停止背景執行的 sd-server
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		pid=$$(cat $(PID_FILE)); kill $$pid; \
		for i in $$(seq 1 20); do kill -0 $$pid 2>/dev/null || break; sleep 0.5; done; \
		echo "已停止 sd-server（PID $$pid）"; \
	else \
		echo "sd-server 未在執行"; \
	fi
	@rm -f $(PID_FILE)

.PHONY: restart
restart: ## 重新啟動背景的 sd-server
	@$(MAKE) --no-print-directory stop
	@$(MAKE) --no-print-directory start

.PHONY: status
status: ## 顯示 sd-server 的執行狀態
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		echo "執行中（PID $$(cat $(PID_FILE))）"; \
	else \
		echo "未在背景執行"; \
	fi
	@curl -sf $(BASE_URL)/models >/dev/null 2>&1 && echo "API 可用：$(BASE_URL)" || echo "API 無回應：$(BASE_URL)"

.PHONY: logs
logs: ## 即時查看 sd-server 記錄檔
	@tail -n 50 -f $(LOG_FILE)

# ---- 用戶端 ----------------------------------------------------------------

.PHONY: models
models: ## 呼叫 GET /v1/models
	@curl -sf $(BASE_URL)/models && echo

.PHONY: loras
loras: ## 列出 sd-server 已發現的 LoRA（GET /sdapi/v1/loras）
	@curl -sf http://$(CLIENT_HOST):$(PORT)/sdapi/v1/loras && echo

.PHONY: generate
generate: ## 以 OpenAI SDK 文字生圖（PROMPT、SIZE、N、LORA 可調整）
	$(CLIENT) generate '$(subst ','\'',$(PROMPT))' --size $(SIZE) -n $(N) -o $(OUT_DIR) $(foreach l,$(LORA),--lora '$(l)') $(CLIENT_ARGS)

.PHONY: edit
edit: ## 以 OpenAI SDK 編輯圖片（必須指定 IMAGE；PROMPT、LORA 可調整）
	@test -n '$(IMAGE)' || { echo "請指定 IMAGE，例如：make edit IMAGE=outputs/in.png PROMPT='把背景換成夕陽海灘'"; exit 1; }
	$(CLIENT) edit '$(subst ','\'',$(PROMPT))' $(foreach img,$(IMAGE),-i $(img)) -n $(N) -o $(OUT_DIR) $(foreach l,$(LORA),--lora '$(l)') $(CLIENT_ARGS)

.PHONY: curl-test
curl-test: ## 以 curl 直接呼叫 /v1/images/generations 做煙霧測試
	@mkdir -p $(OUT_DIR)
	@out="$(OUT_DIR)/curl-$$(date +%Y%m%d-%H%M%S).png"; \
	curl -sf $(BASE_URL)/images/generations \
		-H 'Content-Type: application/json' \
		-d '{"model":"sd-cpp-local","prompt":"a lovely cat holding a sign says hello <sd_cpp_extra_args>{\"sample_params\":{\"sample_steps\":20}}</sd_cpp_extra_args>","size":"512x512","n":1}' \
		| python3 -c 'import sys, json, base64; sys.stdout.buffer.write(base64.b64decode(json.load(sys.stdin)["data"][0]["b64_json"]))' > "$$out"; \
	echo "已儲存：$$out"

# ---- 開發 ------------------------------------------------------------------

.PHONY: lint
lint: ## 檢查 shell 與 Python 腳本
	shellcheck scripts/*.sh
	$(UV) run --quiet --with ruff ruff check scripts
	$(UV) run --quiet --with ruff ruff format --check scripts

.PHONY: clean
clean: ## 刪除產生的圖片與記錄檔
	rm -rf $(OUT_DIR) $(LOG_DIR)

.PHONY: distclean
distclean: stop clean ## 另外刪除 sd.cpp 執行檔與原始碼（保留模型）
	rm -rf $(BIN_DIR) $(SDCPP_SRC_DIR)
