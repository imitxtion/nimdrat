import os, strutils, dynlib

when defined(windows):
    import winim/lean
    import winim/inc/gdiplus

    # Resource ID for the DLL, matches resources.rc
    const EscapiResourceId = 2 

    type
        SimpleCapParams = object
            mTargetBuf: ptr int32
            mWidth: int32
            mHeight: int32

    # Global/Module level proc types
    type
        CountCaptureDevices = proc(): int32 {.stdcall.}
        InitCapture = proc(deviceno: int32, params: ptr SimpleCapParams): int32 {.stdcall.}
        DeinitCapture = proc(deviceno: int32) {.stdcall.}
        DoCapture = proc(deviceno: int32) {.stdcall.}
        IsCaptureDone = proc(deviceno: int32): int32 {.stdcall.}

    # Helper to get encoder CLSID (e.g. for PNG)
    proc GetEncoderClsid(format: string, pClsid: ptr CLSID): int =
        var num: UINT = 0
        var size: UINT = 0
        
        discard GdipGetImageEncodersSize(addr num, addr size)
        if size == 0: return -1
        
        var pImageCodecInfo = cast[ptr UncheckedArray[ImageCodecInfo]](alloc(size))
        defer: dealloc(pImageCodecInfo)
        
        discard GdipGetImageEncoders(num, size, cast[ptr ImageCodecInfo](pImageCodecInfo))
        
        for i in 0 ..< int(num):
             var mime = $cast[WideCString](pImageCodecInfo[i].MimeType)
             if mime == format:
                pClsid[] = pImageCodecInfo[i].Clsid
                return i
        return -1

    proc extractEscapi(destPath: string): bool =
        var hRes = FindResource(0, MAKEINTRESOURCE(EscapiResourceId), RT_RCDATA)
        if hRes == 0: 
            return false
        
        var hLoaded = LoadResource(0, hRes)
        if hLoaded == 0: 
            return false

        var pData = LockResource(hLoaded)
        var size = SizeofResource(0, hRes)
        
        if pData == nil or size == 0: 
            return false

        try:
            var f = open(destPath, fmWrite)
            defer: f.close()
            
            var buf = newString(size)
            copyMem(addr buf[0], pData, size)
            f.write(buf)
            return true
        except:
            return false

    proc captureWebcam*(outputPath: string): bool =
        let dllPath = joinPath(getTempDir(), "escapi.dll")
        
        # Always try to extract if not present or just check existence
        if not fileExists(dllPath):
            if not extractEscapi(dllPath):
                return false
        
        let lib = loadLib(dllPath)
        if lib == nil: 
            return false
        defer: unloadLib(lib)

        let countDevices = cast[CountCaptureDevices](lib.symAddr("countCaptureDevices"))
        let initCapt = cast[InitCapture](lib.symAddr("initCapture"))
        let deinitCapt = cast[DeinitCapture](lib.symAddr("deinitCapture"))
        let doCapt = cast[DoCapture](lib.symAddr("doCapture"))
        let isCaptDone = cast[IsCaptureDone](lib.symAddr("isCaptureDone"))

        if countDevices == nil or initCapt == nil: return false

        if countDevices() == 0: return false

        let width: int32 = 640
        let height: int32 = 480
        var buffer = newSeq[int32](width * height)
        
        var params = SimpleCapParams(mTargetBuf: addr buffer[0], mWidth: width, mHeight: height)

        if initCapt(0, addr params) == 0: 
            return false
        
        doCapt(0)
        
        var attempts = 0
        # Wait up to 5 seconds
        while isCaptDone(0) == 0 and attempts < 100:
            os.sleep(50)
            inc attempts
        
        if isCaptDone(0) == 0:
            deinitCapt(0)
            return false

        # Save using GDI+
        var token: ULONG_PTR
        var input: GdiplusStartupInput
        input.GdiplusVersion = 1
        
        if GdiplusStartup(addr token, addr input, nil) != Ok:
            deinitCapt(0)
            return false
        defer: GdiplusShutdown(token)

        var bmp: ptr GpBitmap
        # ESCAPI buffer is 0x00RRGGBB (0, R, G, B in memory) -> B, G, R, 0 as integer little-endian typically?
        # Actually standard win32 int is 0xAARRGGBB.
        # If Escapi follows standard int packing, it should be fine.
        # PixelFormat32bppRGB allows us to treat 32-bit pixel as RGB (ignoring alpha).
        
        let status = GdipCreateBitmapFromScan0(width, height, width * 4, pixelFormat32bppRGB, cast[ptr BYTE](addr buffer[0]), addr bmp)
        
        var success = false
        if status == Ok:
             var pngClsid: CLSID
             if GetEncoderClsid("image/png", addr pngClsid) != -1:
                 let saveStat = GdipSaveImageToFile(cast[ptr GpImage](bmp), newWideCString(outputPath), addr pngClsid, nil)
                 success = (saveStat == Ok)
             GdipDisposeImage(cast[ptr GpImage](bmp))
        
        deinitCapt(0)
        return success
else:
    proc captureWebcam*(outputPath: string): bool =
        return false
