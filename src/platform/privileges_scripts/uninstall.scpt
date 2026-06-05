set sh1 to "launchctl unload -w /Library/LaunchDaemons/io.github.rustadministrator.rustadmin_service.plist;"
set sh2 to "/bin/rm /Library/LaunchDaemons/io.github.rustadministrator.rustadmin_service.plist;"
set sh3 to "/bin/rm /Library/LaunchAgents/io.github.rustadministrator.rustadmin_server.plist;"

set sh to sh1 & sh2 & sh3
do shell script sh with prompt "RustAdmin wants to unload daemon" with administrator privileges