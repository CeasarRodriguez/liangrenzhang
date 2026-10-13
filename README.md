# 两人账

夫妻二人一起记账、一起攒钱的 App。

- **同步记账**：两人各自记，实时同步。对方能看到金额和分类，**备注只有自己能看到**（服务器层面保证）。
- **攒钱目标**：设定计划期内的总收入和攒钱目标，App 按「动态限额」算出每月能花多少。
  - 本月超支，之后几个月的限额自动收紧；本月省下来，之后的限额就宽松一点。
- **友情提醒**：本月花到 80%、100%、120%，以及整个计划期超支时，两人都会收到提醒。
  - 提醒文案可以自定义，支持 `{限额}`、`{还差}` 等占位符，发送时自动替换成实际金额。
- **收入和支出都能记**，没网时也能记，联网后自动上传。

## 目录结构

```
app/        Flutter 客户端（Flutter-OH，一套代码出 Android APK 和鸿蒙 HAP）
server/     服务端：PocketBase 扩展（Go）+ Docker 部署脚本
shared/     服务端和客户端共用的预算计算测试用例
tools/      开发环境、构建、签名脚本
docs/       部署和安装说明
dist/       构建产物（镜像、安装包），不提交
```

## 常用命令

所有命令都在项目根目录执行。先加载开发环境（工具链默认在 `~/DevTools`，装在别处时见 `tools/dev-env.sh` 开头的说明）：

```bash
source tools/dev-env.sh
```

服务端测试：

```bash
cd server && go test ./...
```

客户端测试：

```bash
cd app && flutter test
```

构建 Android 安装包，产物在 `dist/android/`：

```bash
tools/build-android.sh
```

构建并签名鸿蒙安装包，产物在 `dist/ohos/`：

```bash
tools/build-ohos.sh
```

## 文档

- [服务器部署（Docker）](docs/服务器部署.md)
- [鸿蒙签名与推送](docs/鸿蒙签名与推送.md)
- [安装到手机](docs/安装到手机.md)
- [App 图标](docs/图标.md)

## 重要文件（务必备份，不在项目目录里）

| 位置 | 内容 |
|---|---|
| `~/.couple-ledger-ca/` | 自建根证书和私钥。App 用它校验服务器；迁移服务器时用它重新签发证书 |
| `~/.couple-ledger-keys/` | Android 和鸿蒙的签名密钥、密码。丢失后 App 升级前需要先卸载旧版 |

## 自己部署 / 二次开发

- 包名 `com.k1ngmew.liangrenzhang` 已被本项目占用。你自己发布时请换成自己的包名：Android 改 `app/android/app/build.gradle.kts` 里的 `namespace`、`applicationId` 和 Kotlin 包路径，鸿蒙改 `app/ohos/AppScope/app.json5` 里的 `bundleName`。
- 服务器地址、根证书、签名密钥、华为推送凭据都不在仓库里，按 `docs/` 里的文档自己生成。

## 许可证

[GPL-3.0](LICENSE)。基于本项目修改后发布的版本，也需要以 GPL-3.0 开源。
