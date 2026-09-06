import os, strutils

when defined(windows):
    import winim/lean
    import winim/inc/gdiplus

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

    proc captureScreen*(outputPath: string): bool =
        var token: ULONG_PTR
        var input: GdiplusStartupInput
        input.GdiplusVersion = 1
        
        if GdiplusStartup(addr token, addr input, nil) != Ok:
            return false
        
        defer: GdiplusShutdown(token)

        let width = GetSystemMetrics(SM_CXSCREEN)
        let height = GetSystemMetrics(SM_CYSCREEN)
        
        let hdcScreen = GetDC(0)
        let hdcMem = CreateCompatibleDC(hdcScreen)
        let hBitmap = CreateCompatibleBitmap(hdcScreen, width, height)
        
        let hOld = SelectObject(hdcMem, hBitmap)
        BitBlt(hdcMem, 0, 0, width, height, hdcScreen, 0, 0, SRCCOPY)
        
        var bitmap: ptr GpBitmap
        var status = GdipCreateBitmapFromHBITMAP(hBitmap, 0, addr bitmap)
        
        var success = false
        if status == Ok:
            var clsid: CLSID
            if GetEncoderClsid("image/png", addr clsid) != -1:
                status = GdipSaveImageToFile(cast[ptr GpImage](bitmap), newWideCString(outputPath), addr clsid, nil)
                success = (status == Ok)
            GdipDisposeImage(cast[ptr GpImage](bitmap))
            
        SelectObject(hdcMem, hOld)
        DeleteObject(hBitmap)
        DeleteDC(hdcMem)
        ReleaseDC(0, hdcScreen)
        
        return success

    proc getScreenshotAsTempFile*(): string =
        let path = getTempDir() / "scr_" & $GetCurrentProcessId() & ".png"
        if captureScreen(path):
            return path
        return ""

else:
    proc captureScreen*(outputPath: string): bool =
        return false

    proc getScreenshotAsTempFile*(): string =
        return ""
