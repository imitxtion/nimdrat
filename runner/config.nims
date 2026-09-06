# Ensure the `dimscord_nossl` is used instead of the `dimscord` nimble package
switch("path", "$projectDir/../dimscord_nossl")

when defined(windows):
    switch("define", "windowsNativeTls") # Use WinHTTP/SChannel on Windows.
    switch("out", "bin/installer")
    switch("nimcache", "bin/nimcache")
elif defined(linux):
    switch("out", "bin/installer")
    switch("nimcache", "bin/nimcache")

switch("hints", "off")
switch("verbosity", "0")

switch("define", "strip")
switch("define", "danger")
switch("threads", "on")
switch("app", "gui")
switch("opt", "size")

#switch("cc", "vcc")