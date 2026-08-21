# 09 分发上线证据（2026-08-21）

本文件是脱敏、可随 Git 复核的 09 号票发布证据。原始 appcast 正文、HTTP 响应摘要及发布前后操作流水另保存在执行机的 `.scratch/rename-owltype/`；本文件不包含凭据、token 或签名私钥。

## 发布身份

- 源码提交：`f63a4b5614d249914aa13f3f964daf61a54ca7d2`
- release cohort：`ec3586783d3cc25dd9db9cf6711f4e0e376fdb3af65df3a1232e1485e5b090a3`
- 版本 / build：`2.0.0` / `2.0.0`
- `scripts/release.sh`：8/8 通过
- Developer ID：App、installer pkg、update pkg、DMG 均签名通过
- Apple 公证：App、installer pkg、update pkg、DMG 均公证并 stapling 通过
- Sparkle：appcast enclosure 的 EdDSA 签名已使用同 cohort App 的 `SUPublicEDKey` 完成密码学验证
- 发布顺序：版本化不可变对象 → `owltype/latest.json` → 四个站点别名公开读回 → `owltype/appcast.xml`（最后）→ 稳定 feed 公开读回

## 发布前基线

- `owltype/`：0 个对象；公开 appcast 最终为 404 HTML，不是 XML。
- `famo/`：12 个对象、69,807,317 字节；逐对象基线见下表。
- Famo feed：1.6.3；1,581 字节；SHA-256 `5196552a5c4038e154860d7f4b53efb8eb88e423826d310be52d8039cbda5c6b`。
- Responsay 根 feed：1.9.2（build 157）；24,810 字节；SHA-256 `09b3ecbc641ecd48c639175a1b3bd0340631382244cbf7c35602cd09a444186d`。

## 发布后的 Owltype 对象

以下 12 个 URL 均返回 HTTP 200，字节数和 SHA-256 与本地发布计划一致。

| R2 key | 字节数 | SHA-256 |
|---|---:|---|
| `owltype/releases/2.0.0/Owltype.pkg` | 12,076,630 | `31ad2afafee9d9a5f0a6687da79ef4646c5bcaad058afe7c02b545028e907260` |
| `owltype/releases/2.0.0/Owltype-update.pkg` | 12,074,257 | `e8531bca5e7b9e9d102ddfb77f6ebea3ab418ed369cec4ad225fa6fa7bacb549` |
| `owltype/releases/2.0.0/Owltype-2.0.0.dmg` | 15,034,671 | `a4336fd1e49a453cd0ff11f5201ba04691d8042fc42d4cb061b43e70c012dff3` |
| `owltype/releases/2.0.0/appcast.xml` | 1,603 | `342f385b8cc2dc2e68c762c77597dcd26e9a23eee5524e87aa2279385b2cbf0a` |
| `owltype/releases/2.0.0/Owltype-macOS-2.0.0-source.tar.gz` | 31,314,609 | `a3aef6094992970f8ca254a9be47b32d6cd6af7b31ea0b905969c10f908bf5fb` |
| `owltype/releases/2.0.0/Owltype-macOS-2.0.0-source.tar.gz.sha256` | 100 | `56def3526bfe44b044024007a90c15b74220c47a010afca91ac12fcf235ddb15` |
| `owltype/releases/2.0.0/OWLTYPE-FILE-MANIFEST.sha256` | 32,157 | `b73af3de084acd31a86ff8fd9b726c506cf44d7e6f79871f292498b34571201c` |
| `owltype/releases/2.0.0/OWLTYPE-SBOM.spdx.json` | 105,671 | `05251d488837b7f4d8ba794118f70c4930b0d99d57dbf74be82992a5a650ee44` |
| `owltype/releases/2.0.0/OWLTYPE-APP-PROVENANCE.txt` | 156 | `74ef62e6945088a14c299b30e6fa11c35fe18f1b1deeee9c050c1b5a016a3ab3` |
| `owltype/releases/2.0.0/OWLTYPE-RELEASE-COHORT.json` | 2,793 | `c0b0064d7dd9d078940d62011bcb61313f1f5799429c5b40afa4f8257677a754` |
| `owltype/latest.json` | 2,793 | `c0b0064d7dd9d078940d62011bcb61313f1f5799429c5b40afa4f8257677a754` |
| `owltype/appcast.xml` | 1,603 | `342f385b8cc2dc2e68c762c77597dcd26e9a23eee5524e87aa2279385b2cbf0a` |

四个站点别名 `Owltype.pkg`、`Owltype-update.pkg`、`Owltype.dmg`、`source.tar.gz` 均跳转到上述同 cohort 版本化对象；最终下载的字节数和 SHA-256 与对应对象一致。

稳定 feed `https://responsay.com/owltype/appcast.xml`：

- `302` → `https://downloads.responsay.com/owltype/appcast.xml`
- 最终 `200 application/xml; charset=utf-8`
- 1,603 字节；SHA-256 `342f385b8cc2dc2e68c762c77597dcd26e9a23eee5524e87aa2279385b2cbf0a`
- Sparkle 版本 `2.0.0` / `2.0.0`
- enclosure：`https://downloads.responsay.com/owltype/releases/2.0.0/Owltype-update.pkg`
- enclosure 长度：12,074,257 字节

## 发布前后完全相同的 Famo 对象

发布后重新下载全部 12 个对象；12/12 的大小和 SHA-256 均等于发布前基线，总字节仍为 69,807,317。

| R2 key | 字节数 | SHA-256 |
|---|---:|---|
| `famo/appcast.xml` | 1,581 | `5196552a5c4038e154860d7f4b53efb8eb88e423826d310be52d8039cbda5c6b` |
| `famo/latest.json` | 2,782 | `0be9a79004bd435ea92a03cf61bf27e4602ba330caea5a55de1726f0709db4fa` |
| `famo/releases/1.6.3/FAMOTYPE-APP-PROVENANCE.txt` | 156 | `608dbaf43d0ee3e95ab4b0a368dbce22c3261c96e859771ecf43848c9a71b9d9` |
| `famo/releases/1.6.3/FAMOTYPE-FILE-MANIFEST.sha256` | 32,150 | `cc0161f136dae047c50c9de4c46ccf58e299777d55469bbcd75979234573f59a` |
| `famo/releases/1.6.3/FAMOTYPE-RELEASE-COHORT.json` | 2,782 | `0be9a79004bd435ea92a03cf61bf27e4602ba330caea5a55de1726f0709db4fa` |
| `famo/releases/1.6.3/FAMOTYPE-SBOM.spdx.json` | 105,661 | `c47c830f74af4c6f30f7c84700c71f61488733e1a8e40603731d8414f470c646` |
| `famo/releases/1.6.3/Famo-1.6.3.dmg` | 14,750,586 | `e7d3f45607ffe3b46c88b1a0114f6202089f1b8d3cd3e5e8bf46b64f9f08c4ac` |
| `famo/releases/1.6.3/Famo-update.pkg` | 11,901,324 | `0c4a7d67196b9dca9af3cda2658b46022eaf2c244f13acf9935fe1108094bba2` |
| `famo/releases/1.6.3/Famo.pkg` | 11,903,683 | `7459c60afb4b75e96275649a5433f3ebe3e32ee0f333e824718c0d3991c6b004` |
| `famo/releases/1.6.3/Famotype-macOS-1.6.3-source.tar.gz` | 31,104,930 | `2e6a2d3974aaddc9f81ffb9b305ac2c24fa81d302aaa75ccf0cb4740c16270c9` |
| `famo/releases/1.6.3/Famotype-macOS-1.6.3-source.tar.gz.sha256` | 101 | `24405784a7d18f1a4ef007047ffb627af0b6470cfde206441693b5658041e1da` |
| `famo/releases/1.6.3/appcast.xml` | 1,581 | `5196552a5c4038e154860d7f4b53efb8eb88e423826d310be52d8039cbda5c6b` |

稳定 feed `https://responsay.com/famo/appcast.xml` 仍为 1.6.3，正文 SHA-256 仍为 `5196552a5c4038e154860d7f4b53efb8eb88e423826d310be52d8039cbda5c6b`。09 发布没有写入任何 `famo/` key。

## Responsay 根 feed

`https://responsay.com/appcast.xml` 发布前后正文均为 24,810 字节，SHA-256 均为 `09b3ecbc641ecd48c639175a1b3bd0340631382244cbf7c35602cd09a444186d`。因此最新版本仍为 1.9.2（build 157），没有回退。

## 结论与后续边界

- PASS：Owltype 2.0.0 分发面上线，完整发布 cohort 与 feed 一致。
- PASS：旧 Famo 对象逐字节冻结，未被发布波及。
- PASS：Responsay 根 feed 逐字节不变。
- `famo/` 仍不得删除；删除必须等待所有机器完成 10 号票及 2.0.x 新 feed 更新证明，再由 11 号票执行。
