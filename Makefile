.PHONY: all install deps release debug bootstrap test setup-dev release-artifacts release-cohort-check release-cohort-selftest

all: release

# CI entry: build the pinned Rust FFI archive and fetch the reviewed Sparkle
# framework. The retired librime/OpenCC/plum runtime is no longer installed.
bootstrap:
	bash action-install.sh

setup-dev:
	git config core.hooksPath .githooks
	@echo "Installed tracked pre-push privacy gate for this checkout."

DERIVED_DATA_PATH ?= build
RELEASE_OUTPUT_ROOT ?= $(DERIVED_DATA_PATH)
RELEASE_APP = $(RELEASE_OUTPUT_ROOT)/Build/Products/Release/Owltype.app
RELEASE_OUTPUT_ROOT_ABSOLUTE = $(shell python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$(RELEASE_OUTPUT_ROOT)")
NOTARY_PROFILE ?= xw-notary

RUST_FFI_LIBRARY = lib/libowl_msime_ffi.a

SPARKLE_FRAMEWORK = Frameworks/Sparkle.framework
PACKAGE = package/Owltype.pkg
DEPS_CHECK = $(RUST_FFI_LIBRARY) sparkle

# Cargo owns the Rust dependency graph, including source deletions and branch
# switches. An existing archive alone must never bypass its incremental check.
.PHONY: rust-ffi-check
rust-ffi-check:

$(RUST_FFI_LIBRARY): rust-ffi-check
	bash scripts/build-rust-ffi.sh

.PHONY: deps
deps: $(RUST_FFI_LIBRARY) sparkle

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
# Assemble the pinned dictionary inputs, including the Rust SQLite resources.
owl-seed:
	bash scripts/owl-seed.sh
	python3 scripts/fetch-rerank-models.py

# Merge the assembled seed into the built app's SharedSupport. The Rust engine
# cannot start without its SQLite resources, so a missing seed is a hard failure.
copy-owl-seed:
	@test -s data/owl-rime/msime/msime-pinyin.db || { echo "[owltype] ERROR: missing data/owl-rime/msime/msime-pinyin.db; run 'make owl-seed'" >&2; exit 1; }
	@test -s data/owl-rime/msime/msime-wubi.db || { echo "[owltype] ERROR: missing official Wubi resource; run 'make owl-seed'" >&2; exit 1; }
	@test -s data/owl-rime/msime/msime-english.db || { echo "[owltype] ERROR: missing data/owl-rime/msime/msime-english.db; run 'make owl-seed'" >&2; exit 1; }
	@test -s data/owl-rime/msime/msime-others.db || { echo "[owltype] ERROR: missing data/owl-rime/msime/msime-others.db; run 'make owl-seed'" >&2; exit 1; }
	@echo "[owltype] bundling generated resources -> SharedSupport ($(OWL_CONFIG))"
	@rsync -a --delete data/owl-rime/. "$(DERIVED_DATA_PATH)/Build/Products/$(OWL_CONFIG)/Owltype.app/Contents/SharedSupport/"
	@echo "[owltype] re-signing after seed copy (local ad-hoc)"
	@codesign --force --deep --sign - "$(DERIVED_DATA_PATH)/Build/Products/$(OWL_CONFIG)/Owltype.app"

release: $(DEPS_CHECK)
	mkdir -p "$(RELEASE_OUTPUT_ROOT)"
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
	@# 出厂盘点必须描述**最终出厂的那份 app**，所以固定排在 ifdef 块之后：签名会重写全部
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
	rm -rf lib/rime-plugins data/plum data/opencc > /dev/null 2>&1 || true

clean-package:
	rm -rf package/*appcast.xml > /dev/null 2>&1 || true
	rm -rf package/*.pkg > /dev/null 2>&1 || true
	rm -rf package/sign_update > /dev/null 2>&1 || true

clean-deps:
	$(MAKE) clean-sparkle

# ---------------------------------------------------------------------------
# Public CI build target. Release composition and all release gates have one owner:
# scripts/release.sh.

# Rust integration tests need the same SQLite seed as the shipped app. Populate it after
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
