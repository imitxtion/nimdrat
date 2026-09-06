import strutils, tables, os, times, random, asyncdispatch, crypto
import zippy/ziparchives
import constants

when defined(windows):
    import winim/lean, winim/inc/winhttp
    import uri
else:
    import httpclient

when defined(windows):
    proc fetchUrlSync(url: string): string =
        ## Download using WinHTTP to avoid OpenSSL requirement.
        let parsed = parseUri(url)
        if parsed.hostname.len == 0: return ""

        let scheme = parsed.scheme.toLowerAscii()
        var port: int
        if parsed.port.len > 0:
            try:
                port = parseInt(parsed.port)
            except ValueError:
                port = if scheme == "https": INTERNET_DEFAULT_HTTPS_PORT else: INTERNET_DEFAULT_HTTP_PORT
        else:
            port = if scheme == "https": INTERNET_DEFAULT_HTTPS_PORT else: INTERNET_DEFAULT_HTTP_PORT

        var path = parsed.path
        if parsed.query.len > 0: path &= "?" & parsed.query

        let hostW = parsed.hostname.newWideCString()
        let pathW = path.newWideCString()
        let methodW = "GET".newWideCString()

        let hSession = WinHttpOpen(
            "DecryptorWinHTTP",
            WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
            WINHTTP_NO_PROXY_NAME,
            WINHTTP_NO_PROXY_BYPASS,
            0
        )
        if hSession.isNil: return ""
        defer: WinHttpCloseHandle(hSession)

        let hConnect = WinHttpConnect(hSession, hostW, INTERNET_PORT(port), 0)
        if hConnect.isNil: return ""
        defer: WinHttpCloseHandle(hConnect)

        var flags: DWORD = 0
        if scheme == "https": flags = WINHTTP_FLAG_SECURE

        let hRequest = WinHttpOpenRequest(
            hConnect,
            methodW,
            pathW,
            nil,
            WINHTTP_NO_REFERER,
            WINHTTP_DEFAULT_ACCEPT_TYPES,
            flags
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

    type
        FetchThreadArgs = object
            url: string
            chan: ptr Channel[string]

    proc fetchThreadEntry(args: FetchThreadArgs) {.thread.} =
        try:
            let res = fetchUrlSync(args.url)
            args.chan[].send(res)
        except CatchableError as e:
            args.chan[].send("") # Send empty on failure

    proc fetchUrl(url: string): Future[string] {.async.} =
        ## Run WinHTTP download in separate thread and poll for completion.
        let chanPtr = cast[ptr Channel[string]](allocShared0(sizeof(Channel[string])))
        chanPtr[].open()
        
        var thr: Thread[FetchThreadArgs]
        createThread(thr, fetchThreadEntry, FetchThreadArgs(url: url, chan: chanPtr))

        while chanPtr[].peek() == 0:
            await sleepAsync(20)
        
        result = chanPtr[].recv()
        joinThread(thr)
        chanPtr[].close()
        deallocShared(chanPtr)
else:
    proc fetchUrl(url: string): Future[string] {.async.} =
        var client = newAsyncHttpClient()
        try:
            result = await client.getContent(url)
        finally:
            client.close()

proc processWorker(data: string): seq[(string, string)] =
    ## Background task to decrypt and unzip without blocking the main event loop.
    if data.len == 0: return @[]
    
    let plain = decryptAes256(data, SharedKey)
    if plain.len == 0: return @[]

    let tempDir = getTempDir()
    let tempPath = joinPath(tempDir, "runner_payload_" & $getTime().toUnix() & "_" & $rand(1_000_000) & ".zip")

    writeFile(tempPath, plain)

    var files: seq[(string, string)] = @[]
    try:
        let reader = openZipArchive(tempPath)
        for path in reader.walkFiles:
            files.add((path, reader.extractFile(path)))
        reader.close()
    except CatchableError:
        discard # Return partial or empty if zip is invalid
    finally:
        try: removeFile(tempPath) except: discard

    result = files

type
    ProcessThreadArgs = object
        dataPtr: pointer
        dataLen: int
        chan: ptr Channel[seq[(string, string)]]

proc processThreadEntry(args: ProcessThreadArgs) {.thread.} =
    randomize()
    try:
        var dataStr = newString(args.dataLen)
        if args.dataLen > 0:
            copyMem(addr dataStr[0], args.dataPtr, args.dataLen)
        
        let res = processWorker(dataStr)
        args.chan[].send(res)
    except CatchableError:
        args.chan[].send(@[]) # Send empty on crash

proc processPackage*(url: string): Future[Table[string, string]] {.async.} =
    ## Download, decrypt, and unzip a runner payload in background threads
    ## so the gateway event loop is never blocked.
    let data = await fetchUrl(url)
    if data.len == 0: return initTable[string, string]()
    
    # Copy data to shared memory to pass safely to thread
    let dataPtr = allocShared(data.len)
    copyMem(dataPtr, unsafeAddr data[0], data.len)

    let chanPtr = cast[ptr Channel[seq[(string, string)]]](allocShared0(sizeof(Channel[seq[(string, string)]])))
    chanPtr[].open()

    var thr: Thread[ProcessThreadArgs]
    createThread(thr, processThreadEntry, ProcessThreadArgs(dataPtr: dataPtr, dataLen: data.len, chan: chanPtr))
    
    while chanPtr[].peek() == 0:
        await sleepAsync(20)
    
    let rawSeq = chanPtr[].recv()
    joinThread(thr)
    chanPtr[].close()
    
    deallocShared(chanPtr)
    deallocShared(dataPtr)
    
    result = initTable[string, string]()
    for (k, v) in rawSeq:
        result[k] = v
