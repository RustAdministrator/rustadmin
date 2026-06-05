on run {daemon_file, agent_file, user}

  set sh1 to "echo " & quoted form of daemon_file & " > /Library/LaunchDaemons/io.github.rustadministrator.rustadmin_service.plist && chown root:wheel /Library/LaunchDaemons/io.github.rustadministrator.rustadmin_service.plist;"

  set sh2 to "echo " & quoted form of agent_file & " > /Library/LaunchAgents/io.github.rustadministrator.rustadmin_server.plist && chown root:wheel /Library/LaunchAgents/io.github.rustadministrator.rustadmin_server.plist;"

  set sh3 to "cp -rf /Users/" & user & "/Library/Preferences/io.github.rustadministrator.rustadmin/RustAdmin.toml /var/root/Library/Preferences/io.github.rustadministrator.rustadmin/;"

  set sh4 to "cp -rf /Users/" & user & "/Library/Preferences/io.github.rustadministrator.rustadmin/RustAdmin2.toml /var/root/Library/Preferences/io.github.rustadministrator.rustadmin/;"

  set sh5 to "launchctl load -w /Library/LaunchDaemons/io.github.rustadministrator.rustadmin_service.plist;"

  set sh to sh1 & sh2 & sh3 & sh4 & sh5

  do shell script sh with prompt "RustAdmin wants to install daemon and agent" with administrator privileges
end run
