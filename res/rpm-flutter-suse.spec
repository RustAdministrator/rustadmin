Name:       rustadmin
Version:    1.4.6
Release:    0
Summary:    RPM package
License:    GPL-3.0
URL:        https://github.com/RustAdministrator/rustadmin
Vendor:     RustAdministrator <rustadministrator@users.noreply.github.com>
Requires:   gtk3 libxcb1 libXfixes3 alsa-utils libXtst6 libva2 pam gstreamer-plugins-base gstreamer-plugin-pipewire
Recommends: libayatana-appindicator3-1 xdotool
Provides:   libdesktop_drop_plugin.so()(64bit), libdesktop_multi_window_plugin.so()(64bit), libfile_selector_linux_plugin.so()(64bit), libflutter_custom_cursor_plugin.so()(64bit), libflutter_linux_gtk.so()(64bit), libscreen_retriever_plugin.so()(64bit), libtray_manager_plugin.so()(64bit), liburl_launcher_linux_plugin.so()(64bit), libwindow_manager_plugin.so()(64bit), libwindow_size_plugin.so()(64bit), libtexture_rgba_renderer_plugin.so()(64bit)

# https://docs.fedoraproject.org/en-US/packaging-guidelines/Scriptlets/

%description
The best open-source remote desktop client software, written in Rust.

%prep
# we have no source, so nothing here

%build
# we have no source, so nothing here

# %global __python %{__python3}

%install

mkdir -p "%{buildroot}/usr/share/rustadmin" && cp -r ${HBB}/flutter/build/linux/x64/release/bundle/* -t "%{buildroot}/usr/share/rustadmin"
mkdir -p "%{buildroot}/usr/bin"
install -Dm 644 $HBB/res/rustadmin.service -t "%{buildroot}/usr/share/rustadmin/files"
install -Dm 644 $HBB/res/rustadmin.desktop -t "%{buildroot}/usr/share/rustadmin/files"
install -Dm 644 $HBB/res/rustadmin-link.desktop -t "%{buildroot}/usr/share/rustadmin/files"
install -Dm 644 $HBB/res/128x128@2x.png "%{buildroot}/usr/share/icons/hicolor/256x256/apps/rustadmin.png"
install -Dm 644 $HBB/res/scalable.svg "%{buildroot}/usr/share/icons/hicolor/scalable/apps/rustadmin.svg"

%files
/usr/share/rustadmin/*
/usr/share/rustadmin/files/rustadmin.service
/usr/share/icons/hicolor/256x256/apps/rustadmin.png
/usr/share/icons/hicolor/scalable/apps/rustadmin.svg
/usr/share/rustadmin/files/rustadmin.desktop
/usr/share/rustadmin/files/rustadmin-link.desktop

%changelog
# let's skip this for now

%pre
# can do something for centos7
case "$1" in
  1)
    # for install
  ;;
  2)
    # for upgrade
    systemctl stop rustadmin || true
  ;;
esac

%post
cp /usr/share/rustadmin/files/rustadmin.service /etc/systemd/system/rustadmin.service
cp /usr/share/rustadmin/files/rustadmin.desktop /usr/share/applications/
cp /usr/share/rustadmin/files/rustadmin-link.desktop /usr/share/applications/
ln -sf /usr/share/rustadmin/rustadmin /usr/bin/rustadmin
systemctl daemon-reload
systemctl enable rustadmin
systemctl start rustadmin
update-desktop-database

%preun
case "$1" in
  0)
    # for uninstall
    systemctl stop rustadmin || true
    systemctl disable rustadmin || true
    rm /etc/systemd/system/rustadmin.service || true
  ;;
  1)
    # for upgrade
  ;;
esac

%postun
case "$1" in
  0)
    # for uninstall
    rm /usr/bin/rustadmin || true
    rmdir /usr/lib/rustadmin || true
    rmdir /usr/local/rustadmin || true
    rmdir /usr/share/rustadmin || true
    rm /usr/share/applications/rustadmin.desktop || true
    rm /usr/share/applications/rustadmin-link.desktop || true
    update-desktop-database
  ;;
  1)
    # for upgrade
    rmdir /usr/lib/rustadmin || true
    rmdir /usr/local/rustadmin || true
  ;;
esac
