Name:       rustadmin
Version:    1.4.6
Release:    0
Summary:    RPM package
License:    GPL-3.0
URL:        https://github.com/RustAdministrator/rustadmin
Vendor:     RustAdministrator <rustadministrator@users.noreply.github.com>
Requires:   gtk3 libxcb libXfixes alsa-lib libva2 pam gstreamer1-plugins-base
Recommends: libayatana-appindicator-gtk3 libxdo

# https://docs.fedoraproject.org/en-US/packaging-guidelines/Scriptlets/

%description
The best open-source remote desktop client software, written in Rust.

%prep
# we have no source, so nothing here

%build
# we have no source, so nothing here

%global __python %{__python3}

%install
mkdir -p %{buildroot}/usr/bin/
mkdir -p %{buildroot}/usr/share/rustadmin/
mkdir -p %{buildroot}/usr/share/rustadmin/files/
mkdir -p %{buildroot}/usr/share/icons/hicolor/256x256/apps/
mkdir -p %{buildroot}/usr/share/icons/hicolor/scalable/apps/
install -m 755 $HBB/target/release/rustadmin %{buildroot}/usr/bin/rustadmin
install $HBB/libsciter-gtk.so %{buildroot}/usr/share/rustadmin/libsciter-gtk.so
install $HBB/res/rustadmin.service %{buildroot}/usr/share/rustadmin/files/
install $HBB/res/128x128@2x.png %{buildroot}/usr/share/icons/hicolor/256x256/apps/rustadmin.png
install $HBB/res/scalable.svg %{buildroot}/usr/share/icons/hicolor/scalable/apps/rustadmin.svg
install $HBB/res/rustadmin.desktop %{buildroot}/usr/share/rustadmin/files/
install $HBB/res/rustadmin-link.desktop %{buildroot}/usr/share/rustadmin/files/

%files
/usr/bin/rustadmin
/usr/share/rustadmin/libsciter-gtk.so
/usr/share/rustadmin/files/rustadmin.service
/usr/share/icons/hicolor/256x256/apps/rustadmin.png
/usr/share/icons/hicolor/scalable/apps/rustadmin.svg
/usr/share/rustadmin/files/rustadmin.desktop
/usr/share/rustadmin/files/rustadmin-link.desktop
/usr/share/rustadmin/files/__pycache__/*

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
    rm /usr/share/applications/rustadmin.desktop || true
    rm /usr/share/applications/rustadmin-link.desktop || true
    update-desktop-database
  ;;
  1)
    # for upgrade
  ;;
esac
