.PHONY: all install deps release debug bootstrap test setup-dev release-artifacts release-cohort-check release-cohort-selftest

all: release
install: install-release

# CI entry: fetch the prebuilt librime/opencc/plum/Sparkle deps instead of
# building them from source (the `deps`/`librime` targets below remain the
# from-source path for local development).
bootstrap:
	bash action-install.sh

setup-dev:
	git config core.hooksPath .githooks
	@echo "Installed tracked pre-push privacy gate for this checkout."

RIME_BIN_DIR = librime/dist/bin
RIME_LIB_DIR = librime/dist/lib
DERIVED_DATA_PATH ?= build
RELEASE_OUTPUT_ROOT ?= $(DERIVED_DATA_PATH)
RELEASE_APP = $(RELEASE_OUTPUT_ROOT)/Build/Products/Release/Famo.app
RELEASE_OUTPUT_ROOT_ABSOLUTE = $(shell python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$(RELEASE_OUTPUT_ROOT)")
NOTARY_PROFILE ?= xw-notary

RIME_LIBRARY_FILE_NAME = librime.1.dylib
RIME_LIBRARY = lib/$(RIME_LIBRARY_FILE_NAME)

RIME_DEPS = librime/lib/libmarisa.a \
	librime/lib/libleveldb.a \
	librime/lib/libopencc.a \
	librime/lib/libyaml-cpp.a
PLUM_DATA = bin/rime-install \
	data/plum/default.yaml \
	data/plum/symbols.yaml \
	data/plum/essay.txt
OPENCC_DATA = data/opencc/TSCharacters.ocd2 \
	data/opencc/TSPhrases.ocd2 \
	data/opencc/t2s.json
SPARKLE_FRAMEWORK = Frameworks/Sparkle.framework
PACKAGE = package/Famo.pkg
DEPS_CHECK = $(RIME_LIBRARY) $(PLUM_DATA) $(OPENCC_DATA) $(SPARKLE_FRAMEWORK)

OPENCC_DATA_OUTPUT = librime/share/opencc/*.*
PLUM_DATA_OUTPUT = plum/output/*.*
PLUM_OPENCC_OUTPUT = plum/output/opencc/*.*
RIME_PACKAGE_INSTALLER = plum/rime-install

INSTALL_NAME_TOOL = $(shell xcrun -find install_name_tool)
INSTALL_NAME_TOOL_ARGS = -add_rpath @loader_path/../Frameworks

.PHONY: librime copy-rime-binaries

$(RIME_LIBRARY):
	$(MAKE) librime

$(RIME_DEPS):
	$(MAKE) -C librime deps

librime: $(RIME_DEPS)
	$(MAKE) -C librime release install
	$(MAKE) copy-rime-binaries

copy-rime-binaries:
	cp -L $(RIME_LIB_DIR)/$(RIME_LIBRARY_FILE_NAME) lib/
	cp -pR $(RIME_LIB_DIR)/rime-plugins lib/
	cp $(RIME_BIN_DIR)/rime_deployer bin/
	cp $(RIME_BIN_DIR)/rime_dict_manager bin/
	$(INSTALL_NAME_TOOL) $(INSTALL_NAME_TOOL_ARGS) bin/rime_deployer
	$(INSTALL_NAME_TOOL) $(INSTALL_NAME_TOOL_ARGS) bin/rime_dict_manager

.PHONY: data plum-data opencc-data copy-plum-data copy-opencc-data

data: plum-data opencc-data

$(PLUM_DATA):
	$(MAKE) plum-data

$(OPENCC_DATA):
	$(MAKE) opencc-data

plum-data:
	$(MAKE) -C plum
ifdef PLUM_TAG
	rime_dir=plum/output bash plum/rime-install $(PLUM_TAG)
endif
	$(MAKE) copy-plum-data

opencc-data:
	$(MAKE) -C librime deps/opencc
	$(MAKE) copy-opencc-data

copy-plum-data:
	mkdir -p data/plum
	cp $(PLUM_DATA_OUTPUT) data/plum/
	cp $(RIME_PACKAGE_INSTALLER) bin/

copy-opencc-data:
	mkdir -p data/opencc
	cp $(OPENCC_DATA_OUTPUT) data/opencc/
	cp $(PLUM_OPENCC_OUTPUT) data/opencc/ > /dev/null 2>&1 || true

deps: librime data

ifdef ARCHS
BUILD_SETTINGS += ARCHS="$(ARCHS)"
BUILD_SETTINGS += ONLY_ACTIVE_ARCH=NO
_=$() $()
export CMAKE_OSX_ARCHITECTURES = $(subst $(_),;,$(ARCHS))
endif

ifdef MACOSX_DEPLOYMENT_TARGET
BUILD_SETTINGS += MACOSX_DEPLOYMENT_TARGET="$(MACOSX_DEPLOYMENT_TARGET)"
endif

BUILD_SETTINGS += COMPILER_INDEX_STORE_ENABLE=YES

.PHONY: famo-seed copy-famo-seed
# ADR-0004: assemble Famo's self-contained Rime data (rime-ice + 五笔 + law layer).
famo-seed:
	bash scripts/famo-seed.sh

# Merge the assembled seed into the built app's SharedSupport (shared_data_dir).
# No-op with a note if the seed hasn't been generated (build still succeeds).
copy-famo-seed:
	@if [ -d data/famo-rime ]; then \
		expected=$$(grep -oE 'case \.pinyin: return "[a-z][a-z0-9_]*"' sources/Settings/FamoKeyboardPreferences.swift | sed -E 's/.*"([a-z0-9_]+)".*/\1/' | head -1); \
		if [ -n "$$expected" ] && [ ! -f "data/famo-rime/$$expected.schema.yaml" ]; then \
			echo "[famo] ERROR: seed 陈旧 — data/famo-rime/ 缺 $$expected.schema.yaml（代码默认拼音 schema = $${expected}，见 FamoKeyboardPreferences .pinyin）"; \
			echo "[famo]        运行 'make famo-seed' 重新生成自包含 Rime 种子后再构建（07-07-schema-consistency-guard）。"; \
			exit 1; \
		fi; \
		echo "[famo] bundling self-contained Rime seed -> SharedSupport ($(FAMO_CONFIG))"; \
		rsync -a --delete data/famo-rime/. "$(DERIVED_DATA_PATH)/Build/Products/$(FAMO_CONFIG)/Famo.app/Contents/SharedSupport/"; \
		echo "[famo] re-signing after seed copy (local ad-hoc)"; \
		codesign --force --deep --sign - "$(DERIVED_DATA_PATH)/Build/Products/$(FAMO_CONFIG)/Famo.app"; \
	else \
		echo "[famo] NOTE: data/famo-rime missing - run 'make famo-seed' for self-contained config"; \
	fi

release: $(DEPS_CHECK)
	mkdir -p "$(RELEASE_OUTPUT_ROOT)"
	bash package/add_data_files
	xcodebuild -project Owltype.xcodeproj -configuration Release -scheme Owltype -derivedDataPath "$(RELEASE_OUTPUT_ROOT)" $(BUILD_SETTINGS) \
		CODE_SIGNING_ALLOWED=NO \
		ENABLE_CODE_COVERAGE=NO \
		OTHER_SWIFT_FLAGS="-file-prefix-map $(CURDIR)=." \
		OTHER_CFLAGS="-ffile-prefix-map=$(CURDIR)=." \
		OTHER_CPLUSPLUSFLAGS="-ffile-prefix-map=$(CURDIR)=." \
		build
	$(MAKE) copy-famo-seed FAMO_CONFIG=Release DERIVED_DATA_PATH="$(RELEASE_OUTPUT_ROOT)"
	python3 scripts/finalize-release-bundle.py \
		"$(RELEASE_APP)"

debug: $(DEPS_CHECK)
	mkdir -p $(DERIVED_DATA_PATH)
	bash package/add_data_files
	xcodebuild -project Owltype.xcodeproj -configuration Debug -scheme Owltype -derivedDataPath $(DERIVED_DATA_PATH)  $(BUILD_SETTINGS) build
	$(MAKE) copy-famo-seed FAMO_CONFIG=Debug

.PHONY: sparkle copy-sparkle-framework

$(SPARKLE_FRAMEWORK):
	git submodule update --init --recursive Sparkle
	$(MAKE) sparkle

sparkle:
	xcodebuild -project Sparkle/Sparkle.xcodeproj -configuration Release $(BUILD_SETTINGS) build
	$(MAKE) copy-sparkle-framework

# Use the prebuilt Sparkle tools shipped in download/bin/ — the Sparkle source
# (Sparkle/Sparkle.xcodeproj) is not checked out, so building from it fails with
# "does not exist" (Error 66) and breaks appcast composition. The binaries are identical.
package/generate_keys:
	cp download/bin/generate_keys package/generate_keys

package/sign_update:
	cp download/bin/sign_update package/sign_update

copy-sparkle-framework:
	mkdir -p Frameworks
	cp -RP Sparkle/build/Release/Sparkle.framework Frameworks/

clean-sparkle:
	rm -rf Frameworks/* > /dev/null 2>&1 || true
	rm -rf Sparkle/build > /dev/null 2>&1 || true

.PHONY: notarized-app package $(PACKAGE)

notarized-app: release
	python3 scripts/release-cohort-state.py initialize "$(RELEASE_OUTPUT_ROOT)"
ifdef DEV_ID
	@test -n "$(NOTARY_PROFILE)" || { echo "ERROR: NOTARY_PROFILE is required when DEV_ID is set" >&2; exit 1; }
	bash package/sign_app "$(DEV_ID)" "$(RELEASE_OUTPUT_ROOT)" "$(NOTARY_PROFILE)"
endif
	@# 出厂盘点必须描述**最终出厂的那份 app**，所以固定排在 ifdef 块之后：签名会重写全部 12 个
	@# 原生二进制，staple 会往 Contents/CodeResources 写公证票，两者都发生在 finalize 之后。
	@# 盘点写在 bundle **外面**——写进 Contents/Resources 就会改变被盘点的对象本身，结果取决于
	@# 跑过几次、以及上一版在 DerivedData 里留下了什么（1.5.14 出厂清单记的就是上一版的公证票）。
	@# 未签名构建（CI 无 DEV_ID）同样出盘点，描述的就是那份未签名 app。
	python3 scripts/inventory-release-bundle.py record "$(RELEASE_OUTPUT_ROOT)"

$(PACKAGE): notarized-app
	DEV_ID="$(DEV_ID)" bash package/make_package "$(RELEASE_OUTPUT_ROOT_ABSOLUTE)"
ifdef DEV_ID
	python3 scripts/release-cohort-state.py seal "$(RELEASE_OUTPUT_ROOT)" installer-pkg "$(DEV_ID)" "$(NOTARY_PROFILE)"
	python3 scripts/release-cohort-state.py seal "$(RELEASE_OUTPUT_ROOT)" update-pkg "$(DEV_ID)" "$(NOTARY_PROFILE)"
endif

package: $(PACKAGE)

# The authoritative release entrypoint invokes this graph exactly once. Both packages come from
# make_package, then the versioned DMG reaches stapled before make_archive binds the appcast to the
# completed cohort. Keeping composition in one recipe avoids re-entering the phony package target.
release-artifacts: $(PACKAGE) package/sign_update
	DEV_ID="$(DEV_ID)" NOTARY_PROFILE="$(NOTARY_PROFILE)" bash package/make_dmg "$(RELEASE_OUTPUT_ROOT_ABSOLUTE)"
	RELEASE_OUTPUT_ROOT="$(RELEASE_OUTPUT_ROOT_ABSOLUTE)" bash package/make_archive

DSTROOT = /Library/Input Methods
FAMO_APP_ROOT = $(DSTROOT)/Famo.app

.PHONY: permission-check install-debug install-release

permission-check:
	[ -w "$(DSTROOT)" ] && { [ ! -e "$(FAMO_APP_ROOT)" ] || [ -w "$(FAMO_APP_ROOT)" ]; } || sudo chown -R ${USER} "$(DSTROOT)"

install-debug: debug permission-check
	rm -rf "$(FAMO_APP_ROOT)"
	cp -R $(DERIVED_DATA_PATH)/Build/Products/Debug/Famo.app "$(DSTROOT)"
	DSTROOT="$(DSTROOT)" RIME_NO_PREBUILD=1 bash scripts/postinstall

install-release: release permission-check
	rm -rf "$(FAMO_APP_ROOT)"
	cp -R "$(RELEASE_APP)" "$(DSTROOT)"
	DSTROOT="$(DSTROOT)" bash scripts/postinstall

.PHONY: clean clean-deps

clean:
	rm -rf build > /dev/null 2>&1 || true
	rm build.log > /dev/null 2>&1 || true
	rm bin/* > /dev/null 2>&1 || true
	rm lib/* > /dev/null 2>&1 || true
	rm lib/rime-plugins/* > /dev/null 2>&1 || true
	rm data/plum/* > /dev/null 2>&1 || true
	rm data/opencc/* > /dev/null 2>&1 || true

clean-package:
	rm -rf package/*appcast.xml > /dev/null 2>&1 || true
	rm -rf package/*.pkg > /dev/null 2>&1 || true
	rm -rf package/sign_update > /dev/null 2>&1 || true

clean-deps:
	$(MAKE) -C plum clean
	$(MAKE) -C librime clean
	rm -rf librime/dist > /dev/null 2>&1 || true
	$(MAKE) clean-sparkle

# ---------------------------------------------------------------------------
# Public CI build target. Release composition and all release gates have one owner:
# scripts/release.sh.

test: $(DEPS_CHECK)
	xcodebuild \
		-project Owltype.xcodeproj \
		-scheme Owltype \
		-configuration Debug \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		CODE_SIGNING_ALLOWED=YES \
		CODE_SIGN_IDENTITY=- \
		test \
		-skip-testing:OwltypeTests/FamoGoalBriefLiveTests \
		-skip-testing:OwltypeTests/FamoPromptOptimizeLiveTests \
		-skip-testing:OwltypeTests/FamoResponsesPromptEvaluationLiveTests \
		-skip-testing:OwltypeTests/FamoSkillsLiveTests \
		-skip-testing:OwltypeTests/FamoTriModelSelectionMatrixLiveTests

# Read-only cohort preflight. It deliberately has no build prerequisite: callers may invoke it
# repeatedly without rebuilding, re-signing or replacing the selected cohort.
release-cohort-check:
	python3 scripts/inventory-release-bundle.py check "$(RELEASE_OUTPUT_ROOT)"

release-cohort-selftest:
	python3 scripts/famo-distribution.selftest.py
	bash scripts/release-cohort.selftest.sh
	bash scripts/release-cohort-transition.selftest.sh
	bash scripts/release-chain.selftest.sh
