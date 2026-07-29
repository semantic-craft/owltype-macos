.PHONY: all install deps release debug bootstrap test release-gate source-archive update-package setup-dev privacy-gate

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
	mkdir -p $(DERIVED_DATA_PATH)
	bash package/add_data_files
	xcodebuild -project Famo.xcodeproj -configuration Release -scheme Famo -derivedDataPath $(DERIVED_DATA_PATH) $(BUILD_SETTINGS) \
		CODE_SIGNING_ALLOWED=NO \
		ENABLE_CODE_COVERAGE=NO \
		OTHER_SWIFT_FLAGS="-file-prefix-map $(CURDIR)=." \
		OTHER_CFLAGS="-ffile-prefix-map=$(CURDIR)=." \
		OTHER_CPLUSPLUSFLAGS="-ffile-prefix-map=$(CURDIR)=." \
		build
	$(MAKE) copy-famo-seed FAMO_CONFIG=Release
	python3 scripts/finalize-release-bundle.py \
		"$(DERIVED_DATA_PATH)/Build/Products/Release/Famo.app"

debug: $(DEPS_CHECK)
	mkdir -p $(DERIVED_DATA_PATH)
	bash package/add_data_files
	xcodebuild -project Famo.xcodeproj -configuration Debug -scheme Famo -derivedDataPath $(DERIVED_DATA_PATH)  $(BUILD_SETTINGS) build
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
# "does not exist" (Error 66) and breaks `make archive`. The binaries are identical.
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

.PHONY: notarized-app package archive $(PACKAGE)

notarized-app: release
ifdef DEV_ID
	@test -n "$(NOTARY_PROFILE)" || { echo "ERROR: NOTARY_PROFILE is required when DEV_ID is set" >&2; exit 1; }
	bash package/sign_app "$(DEV_ID)" "$(DERIVED_DATA_PATH)"
	rm -f package/Famo-app.zip
	ditto -c -k --keepParent "$(DERIVED_DATA_PATH)/Build/Products/Release/Famo.app" package/Famo-app.zip
	@for i in 1 2 3; do xcrun notarytool submit package/Famo-app.zip --keychain-profile "$(NOTARY_PROFILE)" --wait && break || { echo "[famo] notary(app) 超时/失败，重试 $$i/3（20s）…"; sleep 20; }; done
	xcrun stapler staple "$(DERIVED_DATA_PATH)/Build/Products/Release/Famo.app"
	rm package/Famo-app.zip
endif
	@# 出厂盘点必须描述**最终出厂的那份 app**，所以固定排在 ifdef 块之后：签名会重写全部 12 个
	@# 原生二进制，staple 会往 Contents/CodeResources 写公证票，两者都发生在 finalize 之后。
	@# 盘点写在 bundle **外面**——写进 Contents/Resources 就会改变被盘点的对象本身，结果取决于
	@# 跑过几次、以及上一版在 DerivedData 里留下了什么（1.5.14 出厂清单记的就是上一版的公证票）。
	@# 未签名构建（CI 无 DEV_ID）同样出盘点，描述的就是那份未签名 app。
	python3 scripts/inventory-release-bundle.py \
		"$(DERIVED_DATA_PATH)/Build/Products/Release/Famo.app" \
		"$(DERIVED_DATA_PATH)/release"

$(PACKAGE): notarized-app
	bash package/make_package "$(DERIVED_DATA_PATH)"
ifdef DEV_ID
	@for i in 1 2 3 4 5; do rm -f package/Famo-signed.pkg; productsign --sign "Developer ID Installer: $(DEV_ID)" package/Famo.pkg package/Famo-signed.pkg && break || { echo "[famo] productsign 时间戳抖动(TSA -67882)，重试 $$i/5…"; sleep 8; }; done; test -f package/Famo-signed.pkg
	rm package/Famo.pkg
	mv package/Famo-signed.pkg package/Famo.pkg
	@for i in 1 2 3; do xcrun notarytool submit package/Famo.pkg --keychain-profile "$(NOTARY_PROFILE)" --wait && break || { echo "[famo] notary(pkg) 超时/失败，重试 $$i/3（20s）…"; sleep 20; }; done
	xcrun stapler staple package/Famo.pkg
	# Famo-update.pkg（Sparkle 更新载荷，无 RequireLogout）同样签名 + 公证 + staple。
	@for i in 1 2 3 4 5; do rm -f package/Famo-update-signed.pkg; productsign --sign "Developer ID Installer: $(DEV_ID)" package/Famo-update.pkg package/Famo-update-signed.pkg && break || { echo "[famo] productsign(update) 时间戳抖动(TSA -67882)，重试 $$i/5…"; sleep 8; }; done; test -f package/Famo-update-signed.pkg
	rm package/Famo-update.pkg
	mv package/Famo-update-signed.pkg package/Famo-update.pkg
	@for i in 1 2 3; do xcrun notarytool submit package/Famo-update.pkg --keychain-profile "$(NOTARY_PROFILE)" --wait && break || { echo "[famo] notary(update pkg) 超时/失败，重试 $$i/3（20s）…"; sleep 20; }; done
	xcrun stapler staple package/Famo-update.pkg
endif

package: $(PACKAGE)

# make_archive 现在需要已签名+公证的 package/Famo-update.pkg（Sparkle 更新载荷，无 RequireLogout）
# 来生成真 enclosure（edSignature/length），所以 archive 依赖 package（不再是 notarized-app）。
# 也依赖 package/sign_update：make_archive 第 43 行直接调 ./sign_update 签 pkg。scripts/release.sh
# 本来显式跑 `make package/sign_update` 补这一步，直接 `make archive`（CI 的 action-build.sh 走这条）
# 却没人补，于是撞 "./sign_update: No such file or directory" (Error 127)。
archive: package package/sign_update
	bash package/make_archive

# DMG = 新用户首装下载物：主入口 FamoInstaller.app（GUI 安装器，内嵌已 staple 的 Famo.app，
# 首装免注销）+ 卸载法墨.command + uninstall-famo.sh。make_dmg 自己跑 xcodegen+xcodebuild 构建
# 安装器、外层单签（无 --deep）、DMG 签名+公证+staple（安装器无独立公证，随 DMG 公证覆盖）。
# 仍依赖 package：①保证内嵌用的 Famo.app 已签名+公证+staple（notarized-app 链）；②Famo.pkg /
# Famo-update.pkg 照常链式产出（pkg 是备用直装链 + Sparkle 载荷，只是不再进 DMG）。
# 透传 DEV_ID/NOTARY_PROFILE 给 make_dmg（脚本从环境读取，未设则跳过签名/公证、仍组出未签名 DMG 供本地验证）。
.PHONY: dmg
dmg: package
	DEV_ID="$(DEV_ID)" NOTARY_PROFILE="$(NOTARY_PROFILE)" bash package/make_dmg "$(DERIVED_DATA_PATH)"

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
	cp -R $(DERIVED_DATA_PATH)/Build/Products/Release/Famo.app "$(DSTROOT)"
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
# Public CI targets (single-repo era): test, reproducible source archive and
# the boundary/secret gate that hosted CI runs on every push and pull request.

test: $(DEPS_CHECK)
	xcodebuild \
		-project Famo.xcodeproj \
		-scheme Famo \
		-configuration Debug \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		CODE_SIGNING_ALLOWED=YES \
		CODE_SIGN_IDENTITY=- \
		test

# 刻意**不**依赖 `release`：那个目标会重跑 finalize，把已经签名+公证+staple 的 bundle 重新剥
# 签名，于是源码包记的 provenance 描述的是一份从未出厂的中间态（1.5.14 就是这么错位的）。
# 这里只消费 notarized-app 已经写好的出厂盘点；盘点不存在时 create-source-archive.sh 报错并
# 指明先跑 make notarized-app / make dmg。
source-archive:
	bash scripts/create-source-archive.sh \
		"$(DERIVED_DATA_PATH)/Build/Products/Release/Famo.app" \
		"$(DERIVED_DATA_PATH)/release"

update-package: release
	bash package/make_update_package "$(DERIVED_DATA_PATH)"

privacy-gate:
	bash scripts/check-public-source.sh
	bash scripts/check-public-privacy.selftest.sh
	bash scripts/check-secrets.sh
	@# 产物侧的密钥扫描只能挂在这里：`release` 目标会被没装扫描器的 build job 走到
	@# （action-build.sh package → make package → release），而 gitleaks/trufflehog 只在
	@# source-ci 的 release-gate job 里 brew install。privacy-gate 本身就硬依赖这两个工具，
	@# 且在 `release-gate: test notarized-app source-archive privacy-gate` 里排在产物都生成之后。
	@# 产物不存在时脚本打 SKIP 而非报错，所以单独跑 `make privacy-gate` 仍然可用。
	@# 盘点那两份从 bundle 内挪到了 release/，它们照样是上架产物 —— 跟着一起扫，别让这次搬家
	@# 悄悄缩小密钥扫描面。产物不存在时 check-artifact-secrets.sh 打 SKIP，不影响单独跑本目标。
	bash scripts/check-secrets.sh --artifacts \
		"$(DERIVED_DATA_PATH)/Build/Products/Release/Famo.app" \
		"$(DERIVED_DATA_PATH)"/release/*-source.tar.gz \
		"$(DERIVED_DATA_PATH)/release/FAMOTYPE-FILE-MANIFEST.sha256" \
		"$(DERIVED_DATA_PATH)/release/FAMOTYPE-SBOM.spdx.json"

# notarized-app 顶替了原来 source-archive 自带的 `release` 依赖：CI 无 DEV_ID 时它就等于
# 「构建 + finalize + 出厂盘点」，正是 source-archive 消费盘点所需，并不比原来多构建一次。
release-gate: test notarized-app source-archive privacy-gate
	bash -n action-install.sh scripts/*.sh
