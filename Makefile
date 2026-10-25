.PHONY: all install deps release debug bootstrap test setup-dev release-artifacts release-cohort-check release-cohort-selftest

all: release

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
RELEASE_APP = $(RELEASE_OUTPUT_ROOT)/Build/Products/Release/Owltype.app
RELEASE_OUTPUT_ROOT_ABSOLUTE = $(shell python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$(RELEASE_OUTPUT_ROOT)")
NOTARY_PROFILE ?= xw-notary

RIME_LIBRARY_FILE_NAME = librime.1.dylib
RIME_LIBRARY = lib/$(RIME_LIBRARY_FILE_NAME)
RUST_FFI_LIBRARY = lib/libowl_msime_ffi.a

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
PACKAGE = package/Owltype.pkg
DEPS_CHECK = $(RIME_LIBRARY) $(RUST_FFI_LIBRARY) $(PLUM_DATA) $(OPENCC_DATA) sparkle

OPENCC_DATA_OUTPUT = librime/share/opencc/*.*
PLUM_DATA_OUTPUT = plum/output/*.*
PLUM_OPENCC_OUTPUT = plum/output/opencc/*.*
RIME_PACKAGE_INSTALLER = plum/rime-install

INSTALL_NAME_TOOL = $(shell xcrun -find install_name_tool)
INSTALL_NAME_TOOL_ARGS = -add_rpath @loader_path/../Frameworks

.PHONY: librime copy-rime-binaries

# Cargo owns the Rust dependency graph, including source deletions and branch
# switches. An existing archive alone must never bypass its incremental check.
.PHONY: rust-ffi-check
rust-ffi-check:

$(RUST_FFI_LIBRARY): rust-ffi-check
	bash scripts/build-rust-ffi.sh

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

.PHONY: owl-seed copy-owl-seed
# ADR-0004: assemble Owltype's self-contained Rime data (rime-ice + 五笔 + law layer).
owl-seed:
	bash scripts/owl-seed.sh

# Merge the assembled seed into the built app's SharedSupport (shared_data_dir).
# No-op with a note if the seed hasn't been generated (build still succeeds).
copy-owl-seed:
	@if [ -d data/owl-rime ]; then \
		expected=$$(grep -oE 'case \.pinyin: return "[a-z][a-z0-9_]*"' sources/Settings/OwlKeyboardPreferences.swift | sed -E 's/.*"([a-z0-9_]+)".*/\1/' | head -1); \
		if [ -n "$$expected" ] && [ ! -f "data/owl-rime/$$expected.schema.yaml" ]; then \
			echo "[owltype] ERROR: seed 陈旧 — data/owl-rime/ 缺 $$expected.schema.yaml（代码默认拼音 schema = $${expected}，见 OwlKeyboardPreferences .pinyin）"; \
			echo "[owltype]        运行 'make owl-seed' 重新生成自包含 Rime 种子后再构建（07-07-schema-consistency-guard）。"; \
			exit 1; \
		fi; \
		echo "[owltype] bundling self-contained Rime seed -> SharedSupport ($(OWL_CONFIG))"; \
		rsync -a --delete data/owl-rime/. "$(DERIVED_DATA_PATH)/Build/Products/$(OWL_CONFIG)/Owltype.app/Contents/SharedSupport/"; \
		echo "[owltype] re-signing after seed copy (local ad-hoc)"; \
		codesign --force --deep --sign - "$(DERIVED_DATA_PATH)/Build/Products/$(OWL_CONFIG)/Owltype.app"; \
	else \
		echo "[owltype] NOTE: data/owl-rime missing - run 'make owl-seed' for self-contained config"; \
	fi

release: $(DEPS_CHECK)
	mkdir -p "$(RELEASE_OUTPUT_ROOT)"
	bash package/add_data_files
	xcodebuild -project Owltype.xcodeproj -configuration Release -scheme Owltype -derivedDataPath "$(RELEASE_OUTPUT_ROOT)" $(BUILD_SETTINGS) \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
		CODE_SIGNING_ALLOWED=NO \
		ENABLE_CODE_COVERAGE=NO \
		OTHER_SWIFT_FLAGS="-file-prefix-map $(CURDIR)=." \
		OTHER_CFLAGS="-ffile-prefix-map=$(CURDIR)=." \
		OTHER_CPLUSPLUSFLAGS="-ffile-prefix-map=$(CURDIR)=." \
		build
	lipo "$(RELEASE_APP)/Contents/MacOS/Owltype" -verify_arch arm64
	lipo "$(RELEASE_APP)/Contents/MacOS/Owltype" -verify_arch x86_64
	strip -S "$(RELEASE_APP)/Contents/MacOS/Owltype"
	$(MAKE) copy-owl-seed OWL_CONFIG=Release DERIVED_DATA_PATH="$(RELEASE_OUTPUT_ROOT)"
	python3 scripts/finalize-release-bundle.py \
		"$(RELEASE_APP)"

debug: $(DEPS_CHECK)
	mkdir -p $(DERIVED_DATA_PATH)
	bash package/add_data_files
	xcodebuild -project Owltype.xcodeproj -configuration Debug -scheme Owltype -derivedDataPath $(DERIVED_DATA_PATH)  $(BUILD_SETTINGS) build
	$(MAKE) copy-owl-seed OWL_CONFIG=Debug

.PHONY: sparkle

sparkle:
	@if [ -e .git ]; then git submodule update --init --recursive Sparkle; fi
	python3 scripts/build-sparkle.py

# Use the prebuilt Sparkle tools shipped in download/bin/ — the Sparkle source
# (Sparkle/Sparkle.xcodeproj) is not checked out, so building from it fails with
# "does not exist" (Error 66) and breaks appcast composition. The binaries are identical.
package/generate_keys:
	cp download/bin/generate_keys package/generate_keys

package/sign_update:
	cp download/bin/sign_update package/sign_update

clean-sparkle:
	python3 scripts/cleanup_app_registrations.py --remove Frameworks
	python3 scripts/cleanup_app_registrations.py --remove Sparkle/build
	python3 scripts/cleanup_app_registrations.py --remove build/sparkle-patched

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

.PHONY: install-debug install-release

# These targets used to copy the ad hoc (Debug) or unsigned (Release) build product over
# /Library/Input Methods/Owltype.app, replacing the notarized input method. An ad hoc
# install pins Keychain grants to a per-build cdhash and shadows the real input method in
# LaunchServices, so they now refuse and name the supported paths.
install install-debug install-release:
	@echo "ERROR: 'make $@' no longer installs an unsigned or ad hoc build." >&2
	@echo "Development install (stable signing identity): bash scripts/install-dev.sh" >&2
	@echo "Shipped install: the notarized Owltype pkg from 'make release-artifacts'." >&2
	@exit 2

.PHONY: clean clean-deps

clean:
	python3 scripts/cleanup_app_registrations.py --remove build
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

# Real-Rime integration tests need the same seed as the shipped app. Populate it after
# Xcode creates the test host, then run without rebuilding away that prepared bundle.
test: $(DEPS_CHECK)
	$(MAKE) owl-seed
	xcodebuild \
		-project Owltype.xcodeproj \
		-scheme Owltype \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA_PATH)" \
		CODE_SIGNING_ALLOWED=YES \
		CODE_SIGN_IDENTITY=- \
		build-for-testing
	$(MAKE) copy-owl-seed DERIVED_DATA_PATH="$(DERIVED_DATA_PATH)" OWL_CONFIG=Debug
	xcodebuild \
		-project Owltype.xcodeproj \
		-scheme Owltype \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA_PATH)" \
		CODE_SIGNING_ALLOWED=YES \
		CODE_SIGN_IDENTITY=- \
		test-without-building $(foreach test,$(TEST_ONLY),-only-testing:OwltypeTests/$(test)) \
		-skip-testing:OwltypeTests/OwlGoalBriefLiveTests \
		-skip-testing:OwltypeTests/OwlPromptOptimizeLiveTests \
		-skip-testing:OwltypeTests/OwlResponsesPromptEvaluationLiveTests \
		-skip-testing:OwltypeTests/OwlSkillsLiveTests \
		-skip-testing:OwltypeTests/OwlTriModelSelectionMatrixLiveTests

# Read-only cohort preflight. It deliberately has no build prerequisite: callers may invoke it
# repeatedly without rebuilding, re-signing or replacing the selected cohort.
release-cohort-check:
	python3 scripts/inventory-release-bundle.py check "$(RELEASE_OUTPUT_ROOT)"

release-cohort-selftest:
	python3 scripts/owl-distribution.selftest.py
	bash scripts/release-cohort.selftest.sh
	bash scripts/release-cohort-transition.selftest.sh
	bash scripts/release-chain.selftest.sh
