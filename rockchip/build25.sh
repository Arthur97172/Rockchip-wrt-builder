#!/bin/bash
# ImmortalWrt 25.12.x Rockchip 构建脚本 (APK 格式 - GitHub Actions)
# 运行于 imagebuilder 目录内
# 注意：第三方插件同步已在 workflow 中完成，勿重复执行

PROFILE=${PROFILE:-"friendlyarm_nanopi-r3s"}
ROOTFS_PARTSIZE=${ROOTFS_PARTSIZE:-"1024"}
INCLUDE_DOCKER=${INCLUDE_DOCKER:-"no"}

echo "Target Profile: $PROFILE"
echo "Rootfs Size: $ROOTFS_PARTSIZE"

# ============================================
# 步骤1: 加载第三方插件配置
# ============================================
CUSTOM_PACKAGES=""
source apk-custom-packages.sh

# 检查是否有未注释的第三方包
HAS_CUSTOM_PACKAGES="no"
if [ -n "$CUSTOM_PACKAGES" ]; then
    HAS_CUSTOM_PACKAGES="yes"
    echo "✅ 检测到第三方插件: $CUSTOM_PACKAGES"
fi

# 定义所需安装的包列表
PACKAGES=""

# [核心系统 - 不含 libc/libgcc，由 base 系统提供]
PACKAGES="base-files uci ubus dropbear logd mtd bash htop curl wget ca-bundle ca-certificates"
PACKAGES="$PACKAGES dnsmasq-full firewall4 nftables kmod-nft-offload"
PACKAGES="$PACKAGES ip-full ipset iw ppp ppp-mod-pppoe wpad-openssl"
PACKAGES="$PACKAGES kmod-xdp-sockets-diag"

# [硬件驱动]
PACKAGES="$PACKAGES -kmod-ath10k-sdio kmod-ath10k"
PACKAGES="$PACKAGES kmod-ata-ahci kmod-ata-ahci-dwc kmod-mmc kmod-r8125 kmod-r8168 kmod-r8169 r8169-firmware"

# [磁盘与文件系统]
PACKAGES="$PACKAGES block-mount fdisk lsblk blkid parted resize2fs smartmontools"
PACKAGES="$PACKAGES kmod-fs-ext4 kmod-fs-vfat kmod-fs-ntfs3 kmod-fs-exfat kmod-fs-btrfs kmod-fs-f2fs"
PACKAGES="$PACKAGES kmod-usb-storage kmod-usb-storage-uas kmod-usb2 kmod-usb3"

# [USB 网卡驱动]
PACKAGES="$PACKAGES kmod-usb-net kmod-usb-net-rtl8150 kmod-usb-net-rtl8152 r8152-firmware"
PACKAGES="$PACKAGES kmod-usb-net-asix-ax88179 kmod-usb-net-aqc111"
PACKAGES="$PACKAGES kmod-usb-net-cdc-ether kmod-usb-net-cdc-ncm kmod-usb-net-cdc-mbim"

# [无线驱动]
PACKAGES="$PACKAGES kmod-brcmfmac kmod-brcmsmac"
PACKAGES="$PACKAGES brcmfmac-firmware-usb brcmfmac-firmware-43430-sdio brcmfmac-firmware-43455-sdio"
PACKAGES="$PACKAGES kmod-usb-ohci kmod-usb-ohci-pci kmod-usb-core kmod-usb2-pci usbutils"
PACKAGES="$PACKAGES kmod-mac80211"
PACKAGES="$PACKAGES kmod-mt7921-common kmod-mt7921-firmware kmod-mt7921e kmod-mt7921u"
PACKAGES="$PACKAGES kmod-mt7922-firmware kmod-mt7925-common kmod-mt7925-firmware kmod-mt7925e kmod-mt7925u"
PACKAGES="$PACKAGES kmod-mt792x-common kmod-mt792x-usb"
PACKAGES="$PACKAGES kmod-mt7992-23-firmware kmod-mt7992-firmware"
PACKAGES="$PACKAGES kmod-mt7996-233-firmware kmod-mt7996-firmware kmod-mt7996-firmware-common kmod-mt7996e kmod-mtk-t7xx"

# [Web 界面]
PACKAGES="$PACKAGES luci luci-base luci-i18n-base-zh-cn luci-mod-admin-full luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-app-cpufreq luci-i18n-cpufreq-zh-cn"
PACKAGES="$PACKAGES luci-app-ttyd luci-i18n-ttyd-zh-cn"

# [功能插件]
PACKAGES="$PACKAGES luci-app-samba4 luci-i18n-samba4-zh-cn"
PACKAGES="$PACKAGES luci-app-upnp luci-i18n-upnp-zh-cn"
PACKAGES="$PACKAGES luci-app-wol luci-i18n-wol-zh-cn"
PACKAGES="$PACKAGES luci-app-ddns luci-i18n-ddns-zh-cn"
PACKAGES="$PACKAGES luci-app-package-manager luci-i18n-package-manager-zh-cn"

# [Docker 插件]
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    echo "🐳 Docker enabled, adding docker packages"
    PACKAGES="$PACKAGES docker docker-compose luci-app-dockerman luci-i18n-dockerman-zh-cn"
fi

# ============================================
# 步骤2: 处理第三方插件(最佳努力,失败不阻断构建)
# ============================================
THIRD_PARTY_OK=0
if [ "$HAS_CUSTOM_PACKAGES" = "yes" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始处理第三方APK..."

    # 克隆 OpenWrt-App 仓库 (best-effort)
    echo "克隆 OpenWrt-App 仓库..."
    rm -rf /tmp/store-repo
    if git clone --depth=1 https://github.com/Arthur97172/OpenWrt-App.git /tmp/store-repo 2>/tmp/git-clone.log; then
        THIRD_PARTY_OK=1
    else
        echo "⚠️ git clone 失败(继续构建,不含第三方插件):"
        sed 's/^/    /' /tmp/git-clone.log
    fi
fi

if [ "$THIRD_PARTY_OK" = "1" ]; then
    # 创建临时目录存放第三方 APK
    mkdir -p thirdparty

    # 1. 更加安全的追加/插入配置方式 (兼容 busybox 和 GNU)
    echo "更新 repositories.conf 架构配置..."
    # 先创建临时文件，确保换行符跨平台一致
    printf "arch aarch64_generic 10\narch aarch64_cortex-a53 15\n" > repositories.conf.tmp
    if [ -f repositories.conf ]; then
        cat repositories.conf >> repositories.conf.tmp
    fi
    mv -f repositories.conf.tmp repositories.conf

    # 2. 复制第三方 APK 到临时目录 (显式循环，兼容 sh 且逻辑更清晰)
    echo "复制第三方 APK 到 thirdparty/ 目录..."
    
    # 显式拆开路径，防止 sh 不支持大括号展开
    for src_dir in /tmp/store-repo/apk/aarch64_generic /tmp/store-repo/apk/aarch64_cortex-a53; do
        if [ -d "$src_dir" ]; then
            # 找到并复制，2>/dev/null 隐藏找不到文件时的警告
            find "$src_dir" -name '*.apk' -exec cp -f {} thirdparty/ \; 2>/dev/null
        fi
    done

    # 3. 统一通过检查最终目录下的文件数量来判断有无成功
    APK_COUNT=$(find thirdparty -name '*.apk' 2>/dev/null | wc -l)
    echo "✅ 第三方目录现有 $APK_COUNT 个APK文件"
    
    if [ "$APK_COUNT" -eq 0 ]; then
        echo "⚠️ 未在仓库中找到任何有效的第三方 apk，跳过第三方"
        THIRD_PARTY_OK=0
    fi
fi

if [ "$THIRD_PARTY_OK" = "1" ]; then
    # 把第三方 APK 物理放入 ImageBuilder 的 packages/ 目录。
    # 关键: IB 自带的 `apk mkndx >(>|/dev/null) 2>/dev/null || true`
    # 会默默吞掉索引构建错误,导致后面 make image 时查不到包。本
    # 处显式重建索引并把 stderr 全部暴露,便于排查问题。
    echo "复制第三方 APK 到 imagebuilder/packages/ ..."
    mkdir -p packages

    # 排除已知不可用的部分(目前为空,作为占位)
    # 要忽略某些 apk 文件,把文件名加到 SKIP_APKS,空格的 glob
    SKIP_APKS=""
    # 删除旧版无 canonical 重命名的拷贝段,见下面"重命名 apk 为 canonical 名称"
    # 块(用 apk 内部 metadata 的 name+version 重新生成文件名,避免 mkndx 后
    # add 时 "package mentioned in index not found")。

    APK_BIN="staging_dir/host/bin/apk"
    APK_KEYS_DIR="keys"
    APK_SIGN_KEY="$APK_KEYS_DIR/local-private-key.pem"
    if [ ! -s "$APK_SIGN_KEY" ]; then
        APK_SIGN_KEY="$APK_KEYS_DIR/build_key.apk.sec"
    fi

    # 在拷贝阶段把 apk 重命名为 canonical 名称 (与 apk 内部 metadata
    # 里的 name/version 完全一致)。apk-tools 在 add 时按 "{name}-{version}.apk"
    # 在 repo 目录里查找 apk 文件,如果实际文件叫
    # "clashoo-2026.06.22.5b54b3a-r1-x86_64.apk" 但 adb 里记录的版本是
    # "2026.06.22~5b54b3a-r1"(点被 tilde 替换,还多了 -x86_64 后缀),
    # 就会抛出 "package mentioned in index not found"。
    # 解决办法: `apk adbdump` 读出每个 apk 块 info 段里的 name+version
    # (这是 apk 注册时的唯一身份),然后 cp 到 "packages/{name}-{version}.apk"。
    echo "🔖 重命名 apk 为 canonical 名称(name-version.apk)..."
    canoned=0
    cached=0
    skipped=0
    for f in thirdparty/*.apk; do
        [ -e "$f" ] || continue
        base=$(basename "$f")
        skip=0
        for s in $SKIP_APKS; do
            case "$base" in $s) skip=1 ;; esac
        done
        if [ "$skip" = "1" ]; then
            echo "  ↷ 跳过: $base"
            continue
        fi
        # 读 canonical 信息
        canon_name=$("$APK_BIN" adbdump "$f" 2>/dev/null \
            | awk '/^  name:/ {name=$2} /^  version:/ {ver=$2; print name; print ver}' | head -2)
        canon_pkg=$(echo "$canon_name" | head -1)
        canon_ver=$(echo "$canon_name" | sed -n '2p')
        if [ -z "$canon_pkg" ] || [ -z "$canon_ver" ]; then
            echo "  ⚠️ 无法读 metadata(可能是损坏的 apk):$base — 跳过"
            continue
        fi
        target="$canon_pkg-$canon_ver.apk"
        if [ -f "packages/$target" ] && [ "packages/$target" -nt "$f" ]; then
            cached=$((cached+1))
            continue
        fi
        # 用 cp 而不是 mv:原文件在 thirdparty/ 留着供本地诊断
        cp -f "$f" "packages/$target"
        canoned=$((canoned+1))
    done
    echo "📦 重命名 $canoned 新 apk,缓存 $cached 个,跳过 $skipped 个"
    PKG_IN_POOL=$(ls packages/*.apk 2>/dev/null | wc -l)
    echo "✅ 第三方 APK 已合并到 packages/ (池中现共 $PKG_IN_POOL 个文件)"

    # 在 mkndx 之前预生成 EC key,与 IB Makefile 的 _check_keys 目标
    # (target/imagebuilder/files/Makefile line ~344) 用完全相同的方式。
    # 原因: IB `make image:` 先 (1) _check_profile (2) _check_keys (3) _call_image,
    # keys 是在 mkndx 之前才创建。如果我们的 mkndx 跑得比 make image 早(就是
    # 当前 build25.sh 的执行位置), key 还不存在,我们的 mkndx 实际产出的 adb
    # 是**未签名**的。后面 apk add 时用 IB 后生成的 key 去验证,签名不匹配:
    #   WARNING: opening packages.adb: UNTRUSTED signature
    #   OK: 0 B in 0 packages → "package mentioned in index not found"
    # 先动手生成 keys 解决这个时序问题。IB 的 _check_keys 见到 keys 已存在
    # 会直接跳过,不会重复生成。
    OPENSSL_BIN="staging_dir/host/bin/openssl"
    NE_KEY="$APK_KEYS_DIR/local-private-key.pem"
    NEED_KEY_GEN=0
    if [ ! -s "$NE_KEY" ] && [ ! -s "$APK_KEYS_DIR/build_key.apk.sec" ]; then
        NEED_KEY_GEN=1
    fi
    if [ "$NEED_KEY_GEN" = "1" ] && [ -x "$OPENSSL_BIN" ]; then
        echo "🔑 预生成 EC 签名 key(与 IB _check_keys 一致)..."
        mkdir -p "$APK_KEYS_DIR"
        if ! "$OPENSSL_BIN" ecparam -name prime256v1 -genkey -noout -out "$NE_KEY" 2>/dev/null; then
            echo "⚠️ ecparam 生成私钥失败,继续依赖 IB 的 _check_keys"
        else
            # IB line 347: sed -i '1s/^/untrusted comment: Local build key\n/'
            sed -i '1s/^/untrusted comment: Local build key\n/' "$NE_KEY" 2>/dev/null
            if "$OPENSSL_BIN" ec -in "$NE_KEY" -pubout > "$APK_KEYS_DIR/local-public-key.pem" 2>/dev/null; then
                sed -i '1s/^/untrusted comment: Local build key\n/' "$APK_KEYS_DIR/local-public-key.pem" 2>/dev/null
                ls -la "$APK_KEYS_DIR/"
                echo "✅ EC key 就绪:$NE_KEY"
            else
                echo "⚠️ 导出公钥失败,继续依赖 IB 的 _check_keys"
            fi
        fi
    fi

    # 在 IB 子目录内运行 ../staging_dir/host/bin/apk mkndx。
    # 因为 (cd packages && ...) 改了 cwd,--keys-dir/--sign 相对于
    # process cwd 解析,所以这里把它们展开为绝对路径。
    run_mkndx() {
        local args=("$@")
        local cmd=(../"$APK_BIN" mkndx)
        if [ -s "$APK_SIGN_KEY" ]; then
            cmd+=(--keys-dir "$(pwd)/$APK_KEYS_DIR")
            cmd+=(--sign "$(pwd)/$APK_SIGN_KEY")
        fi
        cmd+=(--allow-untrusted --output packages.adb "${args[@]}")
        "${cmd[@]}"
    }

    if [ -x "$APK_BIN" ]; then
        # 关键: IB 25.12.x 默认 CONFIG_SIGNATURE_CHECK=y(.config 第 234 行),
        # apk 调用**没有** --allow-untrusted。所有 packages.adb 必须用
        # local-private-key.pem 签名,否则 apk 读到时:
        #   "WARNING: ./packages/packages.adb: UNTRUSTED signature"
        # → 整库丢弃("OK: 0 B in 0 packages") → "package mentioned in index not found"
        # 流程:
        #   1) 显式列 apk 给 mkndx(避免 *.apk glob 在某环境不展开 → 0 字节假签 adb)
        #   2) 整体失败逐个排错,坏 apk 移到 .bad 后用剩余的重建
        #   3) touch packages.adb 把 mtime 设到所有 *.apk 之后,IB 检测认为 adb
        #      是最新的,不会执行默认的 mkndx(默认调用无声覆盖,entails 0 字节)
        APK_FILES=()
        for f in packages/*.apk; do
            [ -e "$f" ] || continue
            APK_FILES+=("$(basename "$f")")
        done
        PKG_COUNT="${#APK_FILES[@]}"
        echo "🔧 显式重建 SIGNED packages.adb 索引(待索引 apk 数量: $PKG_COUNT)..."
        if [ "$PKG_COUNT" -eq 0 ]; then
            echo "⚠️ packages/ 是空的,没有 apk 可索引,跳过"
        elif (cd packages && run_mkndx "${APK_FILES[@]}"); then
            echo "✅ SIGNED packages.adb 已就绪 ($PKG_COUNT 个 apk)"
        else
            echo "⚠️ mkndx 整体失败,逐个诊断损坏的 apk ..."
            BAD=()
            for entry in "${APK_FILES[@]}"; do
                if ! (cd packages && run_mkndx "$entry"); then
                    echo "  ✗ 损坏: packages/$entry"
                    BAD+=("$entry")
                fi
            done
            if [ "${#BAD[@]}" -gt 0 ]; then
                echo "🚮 暂时移出损坏的 apk ..."
                mkdir -p packages/.bad
                for entry in "${BAD[@]}"; do
                    mv "packages/$entry" "packages/.bad/$entry"
                done
                APK_FILES=()
                for f in packages/*.apk; do
                    [ -e "$f" ] || continue
                    APK_FILES+=("$(basename "$f")")
                done
                if [ "${#APK_FILES[@]}" -eq 0 ]; then
                    echo "⚠️ 没有健康的 apk 留下来,跳过重建"
                elif (cd packages && run_mkndx "${APK_FILES[@]}"); then
                    echo "✅ 已用剩余的健康 apk 重建 SIGNED 索引(损坏 apk 的功能将不可用)"
                else
                    echo "⚠️ 即便移出损坏 apk 后仍无法生成索引,继续依赖 IB 自动重建"
                fi
            fi
        fi

        # 把 packages.adb 的 mtime 设到所有 *.apk 之后,避免 IB 内部因 mkndx 旧
        # 而重建。IB 逻辑:"[ find $(PACKAGE_DIR) -cnewer packages.adb ]" → 重建;
        # 我们的 adb mtime 更新后,find 不会返回新的文件,IB 跳过重建。
        if [ -f packages/packages.adb ]; then
            touch -d "@$(($(date +%s) + 60))" packages/packages.adb 2>/dev/null || \
                touch packages/packages.adb
            echo "🔒 packages.adb mtime 已更新,IB 不会重建"
        fi
    else
        echo "⚠️ 找不到 $APK_BIN,继续依赖 IB 自动重建(不推荐)"
    fi
fi

# ============================================
# 步骤3: 合并第三方插件到包列表
# ============================================
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

echo "$(date '+%Y-%m-%d %H:%M:%S') - 编译包列表:"
echo "$PACKAGES"

# ============================================
# 步骤4: 备份 config.bak
# ============================================
if [ -f .config ] && grep -q "^CONFIG_SIGNATURE_CHECK=y" .config; then
    cp .config .config.bak.imm
    sed -i 's/^CONFIG_SIGNATURE_CHECK=y$/CONFIG_SIGNATURE_CHECK=/' .config
    echo "🔓 .config: CONFIG_SIGNATURE_CHECK 已置空(原值备份到 .config.bak.imm)"
    grep -n '^CONFIG_SIGNATURE_CHECK' .config
fi

# ============================================
# 步骤5: 执行 make image
# ============================================
make image PROFILE=generic PACKAGES="$PACKAGES" FILES="files" ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
