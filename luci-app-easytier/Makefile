#
# Copyright (C) 2008-2014 The LuCI Team <luci@lists.subsignal.org>
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk
-include $(dir $(lastword $(MAKEFILE_LIST)))../version.mk

PKG_VERSION:=$(or $(EASYTIER_VERSION),2.7.0)
# 注意：openwrt-22.03 的 luci.mk 用 PKG_VERSION 作为 ipk 的 Version 字段（忽略 PKG_RELEASE），
# 所以打包修订号必须并进 PKG_VERSION，opkg 才会把它当成比 2.7.0-fix1 更新的版本。
PKG_RELEASE:=2
PKG_VERSION:=$(PKG_VERSION)-r2

PKG_PO_VERSION:=$(PKG_VERSION)

LUCI_TITLE:=LuCI support for EasyTier
LUCI_DEPENDS:=+kmod-tun +luci-compat
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-easytier

define Package/$(PKG_NAME)/conffiles
/etc/config/easytier
/etc/easytier/
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
if [ -f /etc/config/easytier ] ; then
  echo "备份luci配置文件/etc/config/easytier到/tmp/easytier_backup"
  echo "不重启设备之前再次安装luci-app-easytier 配置不丢失,无需重新配置"
  cp -rf /etc/config/easytier /tmp/easytier_backup
fi

if ls /etc/easytier/* >/dev/null 2>&1; then
  echo "备份easytier配置目录/etc/easytier到/tmp/et_config_backup"
  echo "不重启设备之前再次安装luci-app-easytier 配置不丢失,无需重新配置"
  cp -rf /etc/easytier /tmp/et_config_backup
fi

endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
chmod +x /etc/init.d/easytier
chmod +x /usr/bin/et_route_guard.sh 2>/dev/null
if [ -z "$${IPKG_INSTROOT}" ]; then
	# 先删掉可能存在的旧行（1 分钟版/手工版），再写 3 分钟版，保证升级后计划任务被归一化
	sed -i '/et_route_guard/d' /etc/crontabs/root 2>/dev/null
	echo '*/3 * * * * sh /usr/bin/et_route_guard.sh >/dev/null 2>&1' >> /etc/crontabs/root
	/etc/init.d/cron reload >/dev/null 2>&1
	echo "EasyTier 路由守卫已启用：每 3 分钟核对 tun0 路由，日志 /var/log/et_route_guard.log"
fi
if [ -f /tmp/easytier_backup ] ; then
  echo "发现luci备份配置文件/tmp/easytier_backup，开始恢复到/etc/config/easytier"
  rm -rf /etc/config/easytier
  mv -f /tmp/easytier_backup /etc/config/easytier
  echo "请前往 VPN - EasyTier 界面进行重启插件"
fi
if [ -d /tmp/et_config_backup ] ; then
  echo "发现easytier备份配置目录/tmp/et_config_backup，开始恢复到/etc/easytier"
  rm -rf /etc/easytier
  mv -f /tmp/et_config_backup /etc/easytier
  echo "请前往 VPN - EasyTier 界面进行重启插件"
fi
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
