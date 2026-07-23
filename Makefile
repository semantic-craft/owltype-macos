.PHONY: all bootstrap debug release test release-gate source-archive famo-seed copy-famo-seed

all: debug

DERIVED_DATA_PATH ?= build
RIME_LIBRARY := lib/librime.1.dylib
RIME_TOOLS := bin/rime_deployer bin/rime_dict_manager
RIME_DATA := data/plum/default.yaml data/opencc/t2s.json
DEPS_CHECK := $(RIME_LIBRARY) $(RIME_TOOLS) $(RIME_DATA)

$(DEPS_CHECK):
	bash action-install.sh

bootstrap:
	bash action-install.sh

debug: $(DEPS_CHECK)
	xcodebuild \
		-project Famo.xcodeproj \
		-scheme Famo \
		-configuration Debug \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		CODE_SIGNING_ALLOWED=NO \
		build
	$(MAKE) copy-famo-seed FAMO_CONFIG=Debug

release: $(DEPS_CHECK)
	xcodebuild \
		-project Famo.xcodeproj \
		-scheme Famo \
		-configuration Release \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		CODE_SIGNING_ALLOWED=NO \
		build
	$(MAKE) copy-famo-seed FAMO_CONFIG=Release
	python3 scripts/finalize-release-bundle.py \
		"$(DERIVED_DATA_PATH)/Build/Products/Release/Famo.app"

test: $(DEPS_CHECK)
	xcodebuild \
		-project Famo.xcodeproj \
		-scheme Famo \
		-configuration Debug \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		CODE_SIGNING_ALLOWED=YES \
		CODE_SIGN_IDENTITY=- \
		test

source-archive: release
	bash scripts/create-source-archive.sh \
		"$(DERIVED_DATA_PATH)/Build/Products/Release/Famo.app" \
		"$(DERIVED_DATA_PATH)/release"

release-gate: test source-archive
	bash scripts/check-public-source.sh
	bash scripts/check-secrets.sh
	bash -n action-install.sh scripts/*.sh

famo-seed:
	bash scripts/famo-seed.sh

# The seed is generated locally and intentionally ignored by Git.
copy-famo-seed:
	@if [ -d data/famo-rime ]; then \
		echo "[famotype] bundling local Rime seed"; \
		rsync -a --delete data/famo-rime/. "$(DERIVED_DATA_PATH)/Build/Products/$(FAMO_CONFIG)/Famo.app/Contents/SharedSupport/"; \
	else \
		echo "[famotype] data/famo-rime is absent; run 'make famo-seed' for a self-contained app"; \
	fi
