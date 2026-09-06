when defined(windows):
  import winim/lean, winim/inc/winhttp
  import strformat, strutils

  const
    HOST = "ipapi.co"
    PATH = "/json/"
    USER_AGENT = "NimWinHTTP"

  proc fetchJson(): string =
    let hSession = WinHttpOpen(
      USER_AGENT,
      WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
      WINHTTP_NO_PROXY_NAME,
      WINHTTP_NO_PROXY_BYPASS,
      0
    )
    if hSession.isNil: return ""
    defer: WinHttpCloseHandle(hSession)

    let hConnect = WinHttpConnect(
      hSession,
      HOST,
      INTERNET_DEFAULT_HTTPS_PORT,
      0
    )
    if hConnect.isNil: return ""
    defer: WinHttpCloseHandle(hConnect)

    let hRequest = WinHttpOpenRequest(
      hConnect,
      "GET",
      PATH,
      nil,
      WINHTTP_NO_REFERER,
      WINHTTP_DEFAULT_ACCEPT_TYPES,
      WINHTTP_FLAG_SECURE
    )
    if hRequest.isNil: return ""
    defer: WinHttpCloseHandle(hRequest)

    discard WinHttpSendRequest(hRequest, nil, 0, nil, 0, 0, 0)
    discard WinHttpReceiveResponse(hRequest, nil)

    var buf = newString(4096)
    var acc = newString(0)
    var bytesRead: DWORD

    while (WinHttpReadData(hRequest, addr buf[0], buf.len.DWORD, addr bytesRead) != 0) and bytesRead > 0:
      acc.add(buf[0 ..< int(bytesRead)])

    acc

when defined(windows):
  import winim/lean, winim/inc/winhttp, strformat

  proc getLocation*(): string =
    try:
      let raw = fetchJson()
      if "ip" notin raw: return "IP: Unknown"
      result = raw 
    except:
      result = "Error: Location Fetch Failed"
else:
  proc getLocation*(): string = "OS: Non-Windows"
