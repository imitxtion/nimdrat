# Ensure the `dimscord_nossl` is used instead of the `dimscord` nimble package
switch("path", "$projectDir/../dimscord_nossl")

switch("threads", "on")
switch("mm", "orc")
switch("define", "release")
switch("opt", "speed")

when defined(windows):
    switch("define", "windowsNativeTls") # Use WinHTTP/SChannel on Windows.
    switch("out", "build/windows/watcher")
    switch("nimcache", "build/windows/nimcache")

switch("define", "release")
switch("threads", "on")